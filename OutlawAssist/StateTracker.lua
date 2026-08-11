local ADDON_NAME, OA = ...

-- OA.SpellIDs is OWNED BY THE ACTIVE PROFILE (see Profiles.lua) and is already
-- populated by the time this file loads. It used to be defined here, which hardcoded
-- Outlaw into the state tracker; redefining it here now would silently overwrite the
-- active profile's spell table. The tracker is spec-agnostic and follows whatever keys
-- the profile declares.

OA.RTB_BUFF_NAMES = {
	"Roll the Bones", -- TODO(M0): verify names
	"Broadside", -- TODO(M0): verify names
	"True Bearing", -- TODO(M0): verify names
	"Ruthless Precision", -- TODO(M0): verify names
	"Buried Treasure", -- TODO(M0): verify names
	"Grand Melee", -- TODO(M0): verify names
	"Skull and Crossbones" -- TODO(M0): verify names
}

OA.State = {
	energy = 0,
	energyMax = 0,
	comboPoints = 0,
	comboPointsMax = 0,
	-- Readability flags. `energy == 0` and "energy is unreadable" are DIFFERENT states
	-- and must never be conflated -- see OA.readNum in Core.lua. Start false (unknown)
	-- so nothing trusts a resource before the first successful read.
	energyKnown = false,
	energyMaxKnown = false,
	comboPointsKnown = false,
	comboPointsMaxKnown = false,
	lastKnownCPMax = nil,
	buffs = {
		rtb = { stage = 0, expires = 0, names = {} },
		opportunity = { up = false, expires = 0, stacks = 0 },
		adrenalineRush = { up = false, expires = 0 },
		degraded = false
	},
	cooldowns = {
		adrenalineRush = { known = false, ready = false, remaining = 0 },
		bladeRush = { known = false, ready = false, remaining = 0 },
		preparation = { known = false, ready = false, remaining = 0 },
		betweenTheEyes = { known = false, ready = false, remaining = 0 },
		bladeFlurry = { known = false, ready = false, remaining = 0 },
		rollTheBones = { known = false, ready = false, remaining = 0 },
		killingSpree = { known = false, ready = false, remaining = 0 },
		dispatch = { known = false, ready = false, remaining = 0 },
		keepItRolling = { known = false, ready = false, remaining = 0 }
	},
	trinkets = {
		[13] = { itemID = nil, ready = false, remaining = 0, onUse = false },
		[14] = { itemID = nil, ready = false, remaining = 0, onUse = false }
	},
	tier = { twoPc = false, fourPc = false },
	inCombat = false,
	stealthed = false,
	enemyCount = nil,
	knownSpells = {},
	knownUnavailable = false
}

local lastBuffScan = -1
local lastEnemyCountRefresh = -1
local trinketSpellCache = {}
local trinketCacheSentinel = {}

-- Secret-value helpers. issecretvalue itself may not exist on every build, so probe it
-- once. NOTE: aura NAMES are secret in combat too, not just spellIds -- comparing one
-- throws "attempt to compare local auraName (secret)". Every string that comes out of an
-- aura must pass through safeStr before it is compared to anything.
local hasIsSecret = type(_G.issecretvalue) == "function"
local function isSecret(v)
	if not hasIsSecret then return false end
	local ok, res = pcall(_G.issecretvalue, v)
	return ok and res == true
end

local function safeStr(v)
	if v == nil or type(v) ~= "string" or isSecret(v) then return "" end
	return v
end

-- TIER 1: Instance ID delta-map (auraInstanceID -> tracked-aura key)
local instanceMap = {}
-- TIER 1: Last cast tracking for correlation (~0.8s window)
local lastCast = { spellID = nil, t = 0 }
local castCorrelationWindow = 0.8

-- COOLDOWN READABILITY IS TWO SEPARATE QUESTIONS, AND MIDNIGHT ANSWERS THEM DIFFERENTLY:
--   "is it ready?"       -> SpellCooldownInfo.isEnabled/.isActive are flagged NeverSecret
--   "how long is left?"  -> .startTime/.duration are SecretWhenCooldownsRestricted
--                           (secret in combat, encounters, mythic keystones and PvP)
-- The old code checked only startTime/duration, and on a secret returned
-- {known=false, ready=false}. Treating "I can't read the timer" as "the ability is NOT
-- ready" made IntelligenceLayer's castability filter drop every cooldown ability in
-- exactly the content this addon is for. Readiness survives; only the countdown dies.
-- `remainingKnown` tells the UI whether it may draw a number.
local function NormalizeCooldown(startTime, duration, isEnabled, isActive)
	local now = GetTime()

	local st, stKnown = OA.readNum(startTime)
	local dur, durKnown = OA.readNum(duration)

	-- Exact path: the timer is readable, so derive everything from it.
	if stKnown and durKnown then
		if st == 0 or dur == 0 then
			return { known = true, ready = true, remaining = 0, remainingKnown = true }
		end
		local remaining = (st + dur) - now
		return {
			known = true,
			ready = remaining <= 0,
			remaining = math.max(0, remaining),
			remainingKnown = true
		}
	end

	-- Degraded path: timer hidden, but the never-secret booleans still answer "ready?".
	-- isActive is authoritative when present (a cooldown is running). isEnabled==false
	-- means the spell is currently unusable/locked out.
	local active, activeKnown = OA.readBool(isActive)
	local enabled, enabledKnown = OA.readBool(isEnabled)

	if activeKnown then
		return { known = true, ready = not active, remaining = 0, remainingKnown = false }
	end
	if enabledKnown then
		-- Legacy semantics: isEnabled==0/false while a cooldown blocks the cast.
		return { known = true, ready = enabled, remaining = 0, remainingKnown = false }
	end

	-- Nothing readable at all: genuinely unknown. Callers must not treat this as ready
	-- OR as not-ready; it is an absence of information.
	return { known = false, ready = false, remaining = 0, remainingKnown = false }
end

-- Which spell keys are worth polling a cooldown for. Derived from the active profile
-- rather than hardcoded, and limited to abilities that actually HAVE a cooldown so a
-- 14-spell profile does not cost 14 API calls per tick at 10Hz.
local cooldownKeyCache = nil
local function cooldownKeys()
	if cooldownKeyCache then return cooldownKeyCache end
	cooldownKeyCache = {}
	local profile = OA.Profiles and OA.Profiles.Active()
	if not profile then return cooldownKeyCache end
	for key, spellID in pairs(profile.spells or {}) do
		local ability = (profile.abilities or {})[spellID]
		if ability and (ability.cd or 0) > 0 then
			table.insert(cooldownKeyCache, key)
		end
	end
	table.sort(cooldownKeyCache)   -- deterministic order for reproducible tests
	return cooldownKeyCache
end

if OA.Profiles then
	OA.Profiles.OnActivate(function() cooldownKeyCache = nil end)
end

local function RefreshCooldowns()
	for _, key in ipairs(cooldownKeys()) do
		local spellID = OA.SpellIDs[key]
		if spellID then
			local handled = false
			-- Try modern API first
			if C_Spell and C_Spell.GetSpellCooldown then
				local ok, cd = pcall(C_Spell.GetSpellCooldown, spellID)
				if ok and type(cd) == "table" then
					OA.State.cooldowns[key] =
						NormalizeCooldown(cd.startTime, cd.duration, cd.isEnabled, cd.isActive)
					handled = true
				end
			end
			-- Fallback to legacy API: (start, duration, enabled, modRate)
			if not handled and GetSpellCooldown then
				local ok, start, duration, enabled = pcall(GetSpellCooldown, spellID)
				if ok then
					OA.State.cooldowns[key] = NormalizeCooldown(start, duration, enabled, nil)
					handled = true
				end
			end
			if not handled then
				OA.State.cooldowns[key] =
					{ known = false, ready = false, remaining = 0, remainingKnown = false }
			end
		end
	end
end

-- TIER 2: Bootstrap/rescan via GetPlayerAuraBySpellID
local function BootstrapBuffState()
	local now = GetTime()
	wipe(instanceMap)
	OA.State.buffs.degraded = false

	-- Query-by-ID bootstrap. The live client exposes GetPlayerAuraBySpellID; some
	-- builds/docs also carry GetAuraDataBySpellID. Prefer the former, accept either --
	-- calling only one name is how a rename silently disables this whole tier.
	local queryByID = C_UnitAuras and
		(C_UnitAuras.GetPlayerAuraBySpellID or C_UnitAuras.GetAuraDataBySpellID)
	if queryByID then
		local trackedSpells = {
			{ spellID = OA.SpellIDs.adrenalineRush, key = "adrenalineRush" },
			{ spellID = OA.SpellIDs.rollTheBones, key = "rtb" },
			{ spellID = 195627, key = "opportunity" },
			{ spellID = OA.SpellIDs.stealth, key = "stealthed" }
		}

		local foundAny = false
		for _, item in ipairs(trackedSpells) do
			local aura = queryByID("player", item.spellID)
			if aura then
				foundAny = true
				local instanceID = OA.num(aura.auraInstanceID, 0)
				if instanceID > 0 then
					instanceMap[instanceID] = item.key
				end
				-- Update state from this aura
				if item.key == "adrenalineRush" then
					OA.State.buffs.adrenalineRush.up = true
					OA.State.buffs.adrenalineRush.expires = OA.num(aura.expirationTime, now)
				elseif item.key == "rtb" then
					OA.State.buffs.rtb.stage = OA.num(aura.applications, 1)
					OA.State.buffs.rtb.expires = OA.num(aura.expirationTime, now)
				elseif item.key == "opportunity" then
					OA.State.buffs.opportunity.up = true
					OA.State.buffs.opportunity.stacks = OA.num(aura.applications, 0)
					OA.State.buffs.opportunity.expires = OA.num(aura.expirationTime, now)
				elseif item.key == "stealthed" then
					OA.State.stealthed = true
				end
			end
		end

		if not foundAny then
			OA.State.buffs.degraded = true
		end
	else
		OA.State.buffs.degraded = true
	end
end

-- TIER 1: Process UNIT_AURA delta payload (updateInfo structure)
local function ProcessAuraDelta(updateInfo)
	if not updateInfo then return end

	local now = GetTime()

	-- isFullUpdate: rebuild map + Tier 2
	if updateInfo.isFullUpdate then
		BootstrapBuffState()
		return
	end

	-- removedAuraInstanceIDs: clear mapped state + remove from map
	if updateInfo.removedAuraInstanceIDs then
		for _, instanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
			local key = instanceMap[instanceID]
			if key == "adrenalineRush" then
				OA.State.buffs.adrenalineRush.up = false
				OA.State.buffs.adrenalineRush.expires = 0
			elseif key == "rtb" then
				OA.State.buffs.rtb.stage = 0
				OA.State.buffs.rtb.expires = 0
				wipe(OA.State.buffs.rtb.names)
			elseif key == "opportunity" then
				OA.State.buffs.opportunity.up = false
				OA.State.buffs.opportunity.stacks = 0
				OA.State.buffs.opportunity.expires = 0
			elseif key == "stealthed" then
				OA.State.stealthed = false
			end
			instanceMap[instanceID] = nil
		end
	end

	-- addedAuras: match by spellId (readable-first check) or correlation
	if updateInfo.addedAuras then
		for _, auraData in ipairs(updateInfo.addedAuras) do
			local instanceID = OA.num(auraData.auraInstanceID, 0)
			if instanceID > 0 then
				-- Try to read spellId (not secret)
				local spellID = nil
				if not isSecret(auraData.spellId) then
					spellID = OA.num(auraData.spellId, 0)
				end

				-- Match by readable spellId
				if spellID == OA.SpellIDs.adrenalineRush then
					instanceMap[instanceID] = "adrenalineRush"
					OA.State.buffs.adrenalineRush.up = true
					OA.State.buffs.adrenalineRush.expires = OA.num(auraData.expirationTime, now)
					OA.State.buffs.degraded = false
				elseif spellID == OA.SpellIDs.rollTheBones then
					instanceMap[instanceID] = "rtb"
					OA.State.buffs.rtb.stage = OA.num(auraData.applications, 1)
					OA.State.buffs.rtb.expires = OA.num(auraData.expirationTime, now)
					OA.State.buffs.degraded = false
				elseif spellID == 195627 then
					instanceMap[instanceID] = "opportunity"
					OA.State.buffs.opportunity.up = true
					OA.State.buffs.opportunity.stacks = OA.num(auraData.applications, 0)
					OA.State.buffs.opportunity.expires = OA.num(auraData.expirationTime, now)
					OA.State.buffs.degraded = false
				elseif spellID == OA.SpellIDs.stealth then
					instanceMap[instanceID] = "stealthed"
					OA.State.stealthed = true
					OA.State.buffs.degraded = false
				elseif spellID == 0 or spellID == nil then
					-- Secret spellId: try CAST-CORRELATION
					if lastCast.spellID and (now - lastCast.t) <= castCorrelationWindow then
						if lastCast.spellID == OA.SpellIDs.adrenalineRush then
							instanceMap[instanceID] = "adrenalineRush"
							OA.State.buffs.adrenalineRush.up = true
							OA.State.buffs.adrenalineRush.expires = OA.num(auraData.expirationTime, now)
							OA.State.buffs.degraded = false
						elseif lastCast.spellID == OA.SpellIDs.rollTheBones then
							instanceMap[instanceID] = "rtb"
							OA.State.buffs.rtb.stage = OA.num(auraData.applications, 1)
							OA.State.buffs.rtb.expires = OA.num(auraData.expirationTime, now)
							OA.State.buffs.degraded = false
						elseif lastCast.spellID == 195627 then
							instanceMap[instanceID] = "opportunity"
							OA.State.buffs.opportunity.up = true
							OA.State.buffs.opportunity.stacks = OA.num(auraData.applications, 0)
							OA.State.buffs.opportunity.expires = OA.num(auraData.expirationTime, now)
							OA.State.buffs.degraded = false
						end
					else
						-- No correlation possible: mark degraded
						OA.State.buffs.degraded = true
					end
				end
			end
		end
	end

	-- updatedAuraInstanceIDs: refresh mapped entries via GetAuraDataByAuraInstanceID
	if updateInfo.updatedAuraInstanceIDs then
		if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
			for _, instanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
				if instanceMap[instanceID] then
					local aura = C_UnitAuras.GetAuraDataByAuraInstanceID("player", instanceID)
					if aura then
						OA.State.buffs[instanceMap[instanceID]].expires = OA.num(aura.expirationTime, now)
					end
				end
			end
		end
	end
end

-- TIER 3: Fallback full scan (only as last-resort when delta tracking yielded nothing for RtB)
-- PRECEDENCE: applications/stage (from modern delta tracking) is AUTHORITATIVE.
-- Legacy RTB_BUFF_NAMES scan only runs if RtB stage is still 0 and should mark degraded.
-- SAFETY: Guard all field reads with issecretvalue, mark degraded on any fallback use.
local function RefreshBuffsFallback()
	local now = GetTime()
	-- NOTE: Do NOT wipe state unconditionally. Only use this as fallback when delta tracking found nothing.
	-- Only refresh RtB legacy names if stage is still 0 (modern aura not found by delta tracking).
	local rtbStageFromModern = OA.State.buffs.rtb.stage

	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local i = 1
		while true do
			local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
			if not aura then break end

			-- Guard against secret values in aura.spellId
			local auraSpellId = 0
			if aura.spellId and not isSecret(aura.spellId) then
				auraSpellId = OA.num(aura.spellId, 0)
			end

			-- Modern path: spell IDs take precedence; only update if delta didn't already set it
			if auraSpellId == OA.SpellIDs.rollTheBones and rtbStageFromModern == 0 then
				OA.State.buffs.rtb.stage = OA.num(aura.applications, 1)
				OA.State.buffs.rtb.expires = OA.num(aura.expirationTime, now)
			end

			-- Non-RtB tracked auras: fill only what the modern tiers did NOT already set.
			if auraSpellId == OA.SpellIDs.adrenalineRush and not OA.State.buffs.adrenalineRush.up then
				OA.State.buffs.adrenalineRush.up = true
				OA.State.buffs.adrenalineRush.expires = OA.num(aura.expirationTime, now)
			end
			if auraSpellId == OA.SpellIDs.opportunity and not OA.State.buffs.opportunity.up then
				OA.State.buffs.opportunity.up = true
				OA.State.buffs.opportunity.stacks = OA.num(aura.applications, 0)
				OA.State.buffs.opportunity.expires = OA.num(aura.expirationTime, now)
			end
			if auraSpellId == OA.SpellIDs.stealth then
				OA.State.stealthed = true
			end

			-- Legacy name scan: ONLY if stage is still 0 (modern spellID path didn't find it)
			local auraName = safeStr(aura.name)
			if rtbStageFromModern == 0 then
				for _, buffName in ipairs(OA.RTB_BUFF_NAMES) do
					if auraName == buffName and auraSpellId ~= OA.SpellIDs.rollTheBones then
						table.insert(OA.State.buffs.rtb.names, buffName)
						OA.State.buffs.rtb.stage = 1
						OA.State.buffs.degraded = true  -- Mark degraded when using legacy fallback
					end
				end
			end

			i = i + 1
		end
	elseif UnitBuff then
		-- Classic UnitBuff fallback (when C_UnitAuras unavailable)
		local i = 1
		while true do
			-- Break on the RAW value: safeStr returns "" for secret/absent, and "" is
			-- truthy in Lua, so sanitizing before the nil-check loops forever.
			local rawName = UnitBuff("player", i)
			if not rawName then break end
			local name = safeStr(rawName)

			if name == "Roll the Bones" and rtbStageFromModern == 0 then
				local _, _, count, _, duration, expTime = UnitBuff("player", i)
				OA.State.buffs.rtb.stage = OA.num(count, 1)
				OA.State.buffs.rtb.expires = OA.num(expTime, now)
				table.insert(OA.State.buffs.rtb.names, name)
			end

			-- Non-RtB tracked auras by name. Names are localization-dependent, so anything
			-- learned here marks degraded: it is the least-trusted source we have.
			if name == "Adrenaline Rush" and not OA.State.buffs.adrenalineRush.up then
				local _, _, _, _, _, expTime = UnitBuff("player", i)
				OA.State.buffs.adrenalineRush.up = true
				OA.State.buffs.adrenalineRush.expires = OA.num(expTime, now)
				OA.State.buffs.degraded = true
			end
			if name == "Opportunity" and not OA.State.buffs.opportunity.up then
				local _, _, count, _, _, expTime = UnitBuff("player", i)
				OA.State.buffs.opportunity.up = true
				OA.State.buffs.opportunity.stacks = OA.num(count, 0)
				OA.State.buffs.opportunity.expires = OA.num(expTime, now)
				OA.State.buffs.degraded = true
			end
			if name == "Stealth" then
				OA.State.stealthed = true
				OA.State.buffs.degraded = true
			end

			-- Legacy name scan: ONLY if stage is still 0
			if rtbStageFromModern == 0 then
				for _, buffName in ipairs(OA.RTB_BUFF_NAMES) do
					if name == buffName and name ~= "Roll the Bones" then
						table.insert(OA.State.buffs.rtb.names, name)
						OA.State.buffs.rtb.stage = 1
						OA.State.buffs.degraded = true  -- Mark degraded when using legacy fallback
					end
				end
			end

			i = i + 1
		end
	end
end

local function RefreshTrinkets()
	for slot = 13, 14 do
		local itemID = GetInventoryItemID("player", slot)
		OA.State.trinkets[slot].itemID = itemID

		if itemID then
			local cd_start, cd_duration
			if C_Item and C_Item.GetItemCooldown then
				cd_start, cd_duration = C_Item.GetItemCooldown(itemID)
			else
				cd_start, cd_duration = GetItemCooldown(itemID)
			end

			-- FAIL-CLOSED: Check for secret values BEFORE coercing
			if isSecret(cd_start) or isSecret(cd_duration) then
				-- Unknown cooldown: mark as not ready
				OA.State.trinkets[slot].ready = false
				OA.State.trinkets[slot].remaining = 0
			else
				cd_start = OA.num(cd_start, 0)
				cd_duration = OA.num(cd_duration, 0)
				if cd_start ~= nil and cd_duration ~= nil then
					local now = GetTime()
					if cd_start == 0 or cd_duration == 0 then
						OA.State.trinkets[slot].ready = true
						OA.State.trinkets[slot].remaining = 0
					else
						OA.State.trinkets[slot].remaining = math.max(0, (cd_start + cd_duration) - now)
						OA.State.trinkets[slot].ready = OA.State.trinkets[slot].remaining <= 0
					end
				end
			end

			if trinketSpellCache[itemID] == nil then
				local hasUse = false
				if C_Item and C_Item.GetItemSpell then
					local spellName, spellID = C_Item.GetItemSpell(itemID)
					hasUse = OA.num(spellID, 0) > 0
				elseif GetItemSpell then
					local spellName, spellID = GetItemSpell(itemID)
					hasUse = OA.num(spellID, 0) > 0
				end
				trinketSpellCache[itemID] = hasUse or trinketCacheSentinel
			end
			local cached = trinketSpellCache[itemID]
			OA.State.trinkets[slot].onUse = (cached ~= trinketCacheSentinel) and cached or false
		end
	end
end

-- ENEMY COUNTING IS LEGAL AND WORTH DOING PROPERLY.
-- Nameplates and player-vs-nameplate threat are both never-secret, so this is real
-- data, not an inference from whether Blade Flurry showed up in Blizzard's queue.
-- (The README's "cannot count nearby enemies legally" is out of date.)
--
-- The old version counted every nameplate it could touch, which over-counted badly:
-- friendly units, critters, dead bodies, and everything out to the ~40yd nameplate
-- range all scored. An 8yd Blade Flurry decision built on a 40yd count is noise. Each
-- unit must now be attackable, alive, and actually in melee range.
local function unitInMeleeRange(token)
	-- Prefer a real range check against a melee ability from the active profile.
	local profile = OA.Profiles and OA.Profiles.Active()
	local meleeSpell = profile and profile.meleeRangeSpell and profile.spells[profile.meleeRangeSpell]
	if meleeSpell then
		local fn = (C_Spell and C_Spell.IsSpellInRange) or _G.IsSpellInRange
		if fn then
			local ok, inRange = pcall(fn, meleeSpell, token)
			if ok then
				local b, known = OA.readBool(inRange)
				if known then return b end
				local n, numKnown = OA.readNum(inRange)   -- legacy API returns 1/0
				if numKnown then return n == 1 end
			end
		end
	end
	-- Fall back to the interact-distance probe (4 == ~28yd "follow"; the tightest
	-- generally-available bracket). Better than no filter at all.
	if _G.CheckInteractDistance then
		local ok, res = pcall(_G.CheckInteractDistance, token, 4)
		if ok then
			local b, known = OA.readBool(res)
			if known then return b end
		end
	end
	return true
end

local function RefreshEnemyCount()
	OA.State.enemyCount = nil
	OA.State.enemyCountKnown = false

	local api = _G.C_NamePlate
	if not api or not api.GetNamePlates then return end

	local ok, plates = pcall(api.GetNamePlates)
	if not ok or type(plates) ~= "table" then return end

	local count = 0
	local considered = 0
	local poisoned = 0

	for _, plate in ipairs(plates) do
		local token = plate.namePlateUnitToken
			or (plate.UnitFrame and plate.UnitFrame.unit)

		if token then
			considered = considered + 1

			local attackable = true
			if _G.UnitCanAttack then
				local okA, res = pcall(_G.UnitCanAttack, "player", token)
				local b, known = OA.readBool(okA and res)
				attackable = known and b or false
			end

			local alive = true
			if _G.UnitIsDead then
				local okD, res = pcall(_G.UnitIsDead, token)
				local b, known = OA.readBool(okD and res)
				if known then alive = not b end
			end

			-- Threat is the engagement signal: a unit we have no threat relationship
			-- with is usually not one we are fighting. A SECRET threat value means we
			-- cannot judge this unit, which is a gap in the count, not a zero.
			local engaged = true
			local okT, threat = pcall(UnitThreatSituation, "player", token)
			if not okT then
				poisoned = poisoned + 1
				engaged = false
			elseif isSecret(threat) then
				poisoned = poisoned + 1
				engaged = false
			end

			if attackable and alive and engaged and unitInMeleeRange(token) then
				count = count + 1
			end
		end
	end

	-- Distinguish "zero enemies" from "could not tell". If every plate we looked at was
	-- unreadable, we know nothing -- and nil must never be treated as 0 downstream.
	if considered > 0 and poisoned == considered then
		OA.State.enemyCount = nil
		OA.State.enemyCountKnown = false
	else
		OA.State.enemyCount = count
		OA.State.enemyCountKnown = true
	end
end

-- SPELL OVERRIDES: talents/procs/stealth can swap the spell actually castable/on the
-- action bar for a different (override) spellID than the base ID this addon reasons
-- about (OA.SpellIDs always holds base IDs). Both directions must resolve so a lookup
-- succeeds whether we hold the base or the override ID:
--   ResolveOverrideSpell(base)     -> override (or base itself if none active)
--   ResolveBaseSpell(override)     -> base (or the same ID if it is not an override)
-- VERIFIED (warcraft.wiki.gg, 2026-08-01): C_Spell.GetOverrideSpell(spellID) and the
-- legacy globals FindSpellOverrideByID/FindBaseSpellByID exist with this contract,
-- including the documented example that a stealth-granted talent (Shadowrunner)
-- overrides Stealth itself -- i.e. overrides can change on a STEALTH transition, not
-- only on talent change. NOT verified against the live client this addon actually
-- targets (Interface 120005/120007/120100, an unreleased build); every call is
-- pcall-guarded and falls back to the input ID unchanged.
function OA.ResolveOverrideSpell(spellID)
	if not spellID then return spellID end
	if _G.C_Spell and _G.C_Spell.GetOverrideSpell then
		local ok, id = pcall(_G.C_Spell.GetOverrideSpell, spellID)
		if ok and type(id) == "number" and id > 0 then return id end
	end
	if _G.FindSpellOverrideByID then
		local ok, id = pcall(_G.FindSpellOverrideByID, spellID)
		if ok and type(id) == "number" and id > 0 then return id end
	end
	return spellID
end

function OA.ResolveBaseSpell(spellID)
	if not spellID then return spellID end
	if _G.FindBaseSpellByID then
		local ok, id = pcall(_G.FindBaseSpellByID, spellID)
		if ok and type(id) == "number" and id > 0 then return id end
	end
	return spellID
end

-- True if actionID (whatever GetActionInfo/etc. reports as actually sitting on a
-- slot) is spellID itself, spellID's currently active override, or an override whose
-- base is spellID. Used by Display/Highlight to resolve a base spellID to its bar
-- slot regardless of which direction the client currently reports.
function OA.SpellMatchesAction(spellID, actionID)
	if not spellID or not actionID then return false end
	if actionID == spellID then return true end
	if OA.ResolveOverrideSpell(spellID) == actionID then return true end
	if OA.ResolveBaseSpell(actionID) == spellID then return true end
	return false
end

local function RefreshKnownSpells()
	-- Probe for known-spell APIs in order of preference
	local checkFn = nil
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		checkFn = function(spellID) return C_SpellBook.IsSpellKnown(spellID) end
	elseif IsPlayerSpell then
		checkFn = function(spellID) return IsPlayerSpell(spellID) end
	elseif IsSpellKnownOrOverridesKnown then
		checkFn = function(spellID) return IsSpellKnownOrOverridesKnown(spellID) end
	elseif IsSpellKnown then
		checkFn = function(spellID) return IsSpellKnown(spellID) end
	else
		-- No known-spell API available: fail-open (assume all are known)
		OA.State.knownUnavailable = true
		return
	end

	OA.State.knownUnavailable = false
	wipe(OA.State.knownSpells)

	-- Probe a spellID AND its live override/base pair, marking ALL of them known when
	-- EITHER form checks true. A talented-and-overridden ability must not read as
	-- "unknown" just because we probed the base ID while only the override reports
	-- known (or vice versa) -- this is the gating half of the override-resolution fix
	-- (state-dependent availability must survive a base<->override swap).
	local function probeAndMark(spellID)
		if not spellID or OA.State.knownSpells[spellID] ~= nil then return end
		local ok, isKnown = pcall(checkFn, spellID)
		isKnown = ok and isKnown or false

		local override = OA.ResolveOverrideSpell(spellID)
		local base = OA.ResolveBaseSpell(spellID)

		if not isKnown and override ~= spellID then
			local ok2, isKnown2 = pcall(checkFn, override)
			isKnown = isKnown or (ok2 and isKnown2 or false)
		end
		if not isKnown and base ~= spellID then
			local ok3, isKnown3 = pcall(checkFn, base)
			isKnown = isKnown or (ok3 and isKnown3 or false)
		end

		OA.State.knownSpells[spellID] = isKnown
		if override ~= spellID then OA.State.knownSpells[override] = isKnown end
		if base ~= spellID then OA.State.knownSpells[base] = isKnown end
	end

	-- Check all spells from OA.SpellIDs
	for name, spellID in pairs(OA.SpellIDs or {}) do
		if spellID then probeAndMark(spellID) end
	end

	-- Also check all spells referenced by rules
	for _, rule in ipairs(OA.Rules or {}) do
		if rule.spellID then probeAndMark(rule.spellID) end
	end
end

function OA.State.RefreshFast()
	local energyPower = Enum and Enum.PowerType and Enum.PowerType.Energy or 3
	local comboPower = Enum and Enum.PowerType and Enum.PowerType.ComboPoints or 4

	-- STEALTH comes from IsStealthed(), not the aura scan. Aura data goes secret in
	-- combat, so an aura-derived flag never CLEARS once set -- which pinned Ambush to
	-- position 1 permanently. IsStealthed is a plain boolean and stays readable.
	if _G.IsStealthed then
		local ok, stealthed = pcall(_G.IsStealthed)
		if ok then OA.State.stealthed = stealthed and true or false end
	end

	-- RESOURCES MUST REPORT READABILITY, NOT JUST A NUMBER.
	-- The old code was OA.num(UnitPower(...), 0). When Midnight makes a resource secret
	-- that yields a confident "0 energy / 0 combo points" -- and every canAfford() gate
	-- in Rotation.lua then fails, Predict() returns an EMPTY sequence, and the bar falls
	-- back to a stale Blizzard pick. Unreadable must be UNKNOWN, so the predictor can
	-- drop the gate instead of asserting zero.
	local energy, energyKnown = OA.readNum(UnitPower("player", energyPower))
	local energyMax, energyMaxKnown = OA.readNum(UnitPowerMax("player", energyPower))
	local cp, cpKnown = OA.readNum(UnitPower("player", comboPower))
	local cpMax, cpMaxKnown = OA.readNum(UnitPowerMax("player", comboPower))

	OA.State.energyMax = energyMax or 0
	OA.State.energyMaxKnown = energyMaxKnown

	-- THE SHADOW MODEL IS THE SINGLE SOURCE OF ENERGY, ALWAYS -- not just a fallback.
	-- It measures directly whenever the API is readable and integrates forward when it
	-- is not. Running it only on the unreadable path was a seeding bug: the model never
	-- saw a real measurement to anchor to, so the moment energy went secret it had
	-- nothing to extrapolate from and reported "unknown" forever.
	if OA.Energy then
		pcall(OA.Energy.Advance)
		local est, usable, conf = OA.Energy.Get()
		OA.State.energy = est
		OA.State.energyKnown = usable
		OA.State.energySource = usable and conf or "unknown"
	elseif energyKnown then
		OA.State.energy = energy or 0
		OA.State.energyKnown = true
		OA.State.energySource = "measured"
	else
		OA.State.energy = 0
		OA.State.energyKnown = false
		OA.State.energySource = "unknown"
	end
	OA.State.comboPoints = cp or 0
	OA.State.comboPointsKnown = cpKnown
	-- comboPointsMax is a character constant (5/6/7), not combat state. If it ever reads
	-- secret, keeping the last known value beats collapsing to 0 -- `cp < cpMax` with
	-- cpMax==0 is false for every cp, which silently disables the builder rule.
	if cpMaxKnown and cpMax and cpMax > 0 then
		OA.State.comboPointsMax = cpMax
		OA.State.lastKnownCPMax = cpMax
	elseif OA.State.lastKnownCPMax then
		OA.State.comboPointsMax = OA.State.lastKnownCPMax
	end
	OA.State.comboPointsMaxKnown = cpMaxKnown

	RefreshCooldowns()

	local now = GetTime()
	-- TIER 3 Fallback: only safe to run NOT in combat (aura scanning can throw on secret values in combat)
	-- When inCombat=true, skip Tier 3 and trust Tier 1 delta tracking.
	-- If Tier 1 failed (degraded), stay degraded; Tier 3 won't fix it mid-combat.
	if (now - lastBuffScan) >= 0.5 and not OA.State.inCombat then
		-- Periodic fallback scan in case delta tracking lost sync (out of combat only).
		-- ISOLATED pcall: as of 12.1.0 the index/slot/instanceID aura paths do not merely
		-- return secrets, they raise an immediate Lua ERROR while auras are restricted.
		-- Sharing RefreshFast's outer pcall meant one such throw skipped everything after
		-- it -- enemy count and trinket state included -- so a hidden aura silently took
		-- out unrelated, still-readable subsystems.
		local ok = pcall(RefreshBuffsFallback)
		if not ok then OA.State.buffs.degraded = true end
		lastBuffScan = now
	end

	if (now - lastEnemyCountRefresh) >= 0.25 then
		pcall(RefreshEnemyCount)
		lastEnemyCountRefresh = now
	end

	pcall(RefreshTrinkets)
end

local function OnPlayerEnteringWorld(event)
	wipe(trinketSpellCache)
	wipe(instanceMap)
	RefreshTrinkets()
	BootstrapBuffState()
end

local function OnPlayerEquipmentChanged(event)
	RefreshTrinkets()
end

local function OnPlayerRegenDisabled(event)
	OA.State.inCombat = true
end

local function OnPlayerRegenEnabled(event)
	OA.State.inCombat = false
end

local function OnUnitAura(event, unit, updateInfo)
	if unit == "player" then
		-- TIER 1: Process delta updates if updateInfo available
		if updateInfo then
			ProcessAuraDelta(updateInfo)
		elseif not OA.State.inCombat then
			-- Fallback: full refresh if no updateInfo. Same combat gate as the periodic
			-- path -- this call site was the hole that let the index scan run in combat.
			RefreshBuffsFallback()
		end
	end
end

local function OnUnitSpellcastSucceeded(event, unit, castGUID, spellID)
	if unit == "player" then
		lastCast.spellID = OA.num(spellID, 0)
		lastCast.t = GetTime()
	end
end

local function OnNamePlateUnitAdded(event, unitToken)
	RefreshEnemyCount()
end

local function OnNamePlateUnitRemoved(event, unitToken)
	RefreshEnemyCount()
end

local function OnPlayerEnteringWorldFull(event)
	OnPlayerEnteringWorld(event)
	RefreshKnownSpells()
end

local function OnTalentChange(event)
	RefreshKnownSpells()
end

OA.RegisterEvent("PLAYER_ENTERING_WORLD", OnPlayerEnteringWorldFull)
OA.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", OnPlayerEquipmentChanged)
OA.RegisterEvent("PLAYER_REGEN_DISABLED", OnPlayerRegenDisabled)
OA.RegisterEvent("PLAYER_REGEN_ENABLED", OnPlayerRegenEnabled)
OA.RegisterEvent("UNIT_AURA", OnUnitAura)
OA.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", OnUnitSpellcastSucceeded)
OA.RegisterEvent("NAME_PLATE_UNIT_ADDED", OnNamePlateUnitAdded)
OA.RegisterEvent("NAME_PLATE_UNIT_REMOVED", OnNamePlateUnitRemoved)

-- Register for talent/spell changes. These used to be guarded by `if _G.EVENT_NAME
-- then ... end` -- that tests for a GLOBAL VARIABLE happening to share the event's
-- name, which WoW does not define for these events, so the guard was always false
-- and NONE of these handlers were ever registered (dead code; talent respecs never
-- refreshed knownSpells/overrides). All four are VERIFIED real, current WoW events
-- (warcraft.wiki.gg, 2026-08-01) and are registered directly, same as every other
-- event in this file.
if not OA._RegisteredTalentEvents then
	OA._RegisteredTalentEvents = true
	OA.RegisterEvent("PLAYER_TALENT_UPDATE", OnTalentChange)
	OA.RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", OnTalentChange)
	OA.RegisterEvent("TRAIT_CONFIG_UPDATED", OnTalentChange)
	OA.RegisterEvent("SPELLS_CHANGED", OnTalentChange)

	-- STEALTH can flip which override is active for a spell (VERIFIED example from
	-- FindBaseSpellByID's own docs: a Shadowrunner-style talent overrides Stealth
	-- itself while stealthed). Re-probe known/override state on the same trigger
	-- Display/Highlight use to invalidate their caches, so a talented-and-overridden
	-- ability is never read as "unknown" mid-transition.
	OA.RegisterEvent("UPDATE_STEALTH", OnTalentChange)
end
