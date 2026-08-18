local ADDON_NAME, Tuono = ...

-- Tuono.SpellIDs is OWNED BY THE ACTIVE PROFILE (see Profiles.lua) and is already
-- populated by the time this file loads. It used to be defined here, which hardcoded
-- Outlaw into the state tracker; redefining it here now would silently overwrite the
-- active profile's spell table. The tracker is spec-agnostic and follows whatever keys
-- the profile declares.

Tuono.RTB_BUFF_NAMES = {
	"Roll the Bones", -- TODO(M0): verify names
	"Broadside", -- TODO(M0): verify names
	"True Bearing", -- TODO(M0): verify names
	"Ruthless Precision", -- TODO(M0): verify names
	"Buried Treasure", -- TODO(M0): verify names
	"Grand Melee", -- TODO(M0): verify names
	"Skull and Crossbones" -- TODO(M0): verify names
}

Tuono.State = {
	energy = 0,
	energyMax = 0,
	comboPoints = 0,
	comboPointsMax = 0,
	-- Readability flags. `energy == 0` and "energy is unreadable" are DIFFERENT states
	-- and must never be conflated -- see Tuono.readNum in Core.lua. Start false (unknown)
	-- so nothing trusts a resource before the first successful read.
	energyKnown = false,
	energyMaxKnown = false,
	comboPointsKnown = false,
	comboPointsMaxKnown = false,
	lastKnownCPMax = nil,
	buffs = {
		-- stageKnown distinguishes "no Roll the Bones buff is up" from "we could not
		-- read the stage". They are NOT the same, and conflating them made the profile
		-- recommend rerolling a Jackpot every 45s. Starts FALSE: nothing may assume a
		-- stage until an aura read actually succeeds.
		rtb = { stage = 0, stageKnown = false, expires = 0, names = {} },
		opportunity = { up = false, expires = 0, stacks = 0 },
		adrenalineRush = { up = false, expires = 0 },
		degraded = false,
		-- The UNIT_AURA delta payload is secret throughout combat. That is expected and
		-- handled (overlay glow, modelled RtB stage, modelled AR window), so it is
		-- recorded separately from `degraded` and is diagnostic only -- see ProcessAuraDelta.
		deltaBlind = false
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
local lastTrinketRefresh = -1
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
local function NormalizeCooldown(startTime, duration, isEnabled, isActive, key)
	local now = GetTime()

	local st, stKnown = Tuono.readNum(startTime)
	local dur, durKnown = Tuono.readNum(duration)

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
	local active, activeKnown = Tuono.readBool(isActive)
	local enabled, enabledKnown = Tuono.readBool(isEnabled)

	local ready = nil
	if activeKnown then ready = not active
	elseif enabledKnown then ready = enabled end

	if ready ~= nil then
		-- THE COUNTDOWN IS HIDDEN, NOT UNKNOWABLE. CooldownModel reconstructs it from
		-- our own observations -- when we saw the cast, the ability's static duration,
		-- and Restless Blades CDR derived from combo points (which are never secret).
		-- The readiness boolean above is ground truth, so it corrects the model rather
		-- than the model overriding it.
		if key and Tuono.CooldownModel then
			Tuono.CooldownModel.Reconcile(key, ready)
			if not ready then
				local rem, known = Tuono.CooldownModel.Predict(key)
				if known and rem and rem > 0 then
					return {
						known = true, ready = false, remaining = rem,
						-- "reconstructed" is not "measured": flagged inferred when the
						-- model had to guess because it never saw the cast.
						remainingKnown = not Tuono.CooldownModel.IsInferred(key),
					}
				end
			end
		end
		return { known = true, ready = ready, remaining = 0, remainingKnown = false }
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
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
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

if Tuono.Profiles then
	Tuono.Profiles.OnActivate(function() cooldownKeyCache = nil end)
end

local function RefreshCooldowns()
	for _, key in ipairs(cooldownKeys()) do
		local spellID = Tuono.SpellIDs[key]
		if spellID then
			local handled = false
			-- Try modern API first
			if C_Spell and C_Spell.GetSpellCooldown then
				local ok, cd = pcall(C_Spell.GetSpellCooldown, spellID)
				if ok and type(cd) == "table" then
					-- isOnGCD is flagged NeverSecret, so the client tells us outright
					-- when a "cooldown" is merely the global one. Ground truth for the
					-- GCD model, which otherwise runs on haste-derived dead reckoning.
					if Tuono.CooldownModel and Tuono.CooldownModel.NoteGCDFromCooldownInfo then
						Tuono.CooldownModel.NoteGCDFromCooldownInfo(cd.isActive, cd.isOnGCD)
					end
					Tuono.State.cooldowns[key] =
						NormalizeCooldown(cd.startTime, cd.duration, cd.isEnabled, cd.isActive, key)
					handled = true
				end
			end
			-- Fallback to legacy API: (start, duration, enabled, modRate)
			if not handled and GetSpellCooldown then
				local ok, start, duration, enabled = pcall(GetSpellCooldown, spellID)
				if ok then
					Tuono.State.cooldowns[key] = NormalizeCooldown(start, duration, enabled, nil, key)
					handled = true
				end
			end
			if not handled then
				Tuono.State.cooldowns[key] =
					{ known = false, ready = false, remaining = 0, remainingKnown = false }
			end
		end
	end
end

-- TIER 2: Bootstrap/rescan via GetPlayerAuraBySpellID
local function BootstrapBuffState()
	local now = GetTime()
	wipe(instanceMap)
	Tuono.State.buffs.degraded = false
	-- Re-prove the stage on every bootstrap rather than inheriting a stale "known".
	Tuono.State.buffs.rtb.stageKnown = false

	-- Query-by-ID bootstrap. The live client exposes GetPlayerAuraBySpellID; some
	-- builds/docs also carry GetAuraDataBySpellID. Prefer the former, accept either --
	-- calling only one name is how a rename silently disables this whole tier.
	-- THE TWO FUNCTIONS HAVE DIFFERENT ARITY AND MUST NOT BE CALLED INTERCHANGEABLY.
	--   C_UnitAuras.GetPlayerAuraBySpellID(spellID)          -- ONE arg; player implied
	--   C_UnitAuras.GetAuraDataBySpellID(unit, spellID)      -- two args
	-- This used to pick either and call it with ("player", spellID). Against the
	-- one-arg form that puts the STRING "player" in the spellID slot, so every lookup
	-- returned nil, foundAny was never true, and buffs.degraded was pinned true for the
	-- entire session -- which killed RtB stage, Adrenaline Rush and Opportunity
	-- tracking, forced the legacy name scan, and held every prediction at "medium"
	-- confidence. Verified signature: warcraft.wiki.gg API_C_UnitAuras.GetPlayerAuraBySpellID.
	local queryByID = nil
	if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
		queryByID = function(spellID) return C_UnitAuras.GetPlayerAuraBySpellID(spellID) end
	elseif C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID then
		queryByID = function(spellID) return C_UnitAuras.GetAuraDataBySpellID("player", spellID) end
	end
	if queryByID then
		local trackedSpells = {
			{ spellID = Tuono.SpellIDs.adrenalineRush, key = "adrenalineRush" },
			{ spellID = Tuono.SpellIDs.rollTheBones, key = "rtb" },
			{ spellID = 195627, key = "opportunity" },
			{ spellID = Tuono.SpellIDs.stealth, key = "stealthed" }
		}

		-- ABSENCE IS AN ANSWER, NOT A FAILURE.
		--
		-- This used to set `degraded` whenever NO tracked buff was found. But the common
		-- case in combat is that the player legitimately has none up -- no Adrenaline
		-- Rush, no Roll the Bones, no Opportunity proc, not stealthed -- and a query that
		-- ran cleanly and returned nil is a DEFINITIVE "you do not have this buff".
		-- Conflating the two pinned the flag on for most of every fight: a live trace had
		-- it true on 100% of ticks. A warning that is always on conveys nothing, and via
		-- inputConfidence it also rated every buff-gated step "unknown", which is what
		-- made the lookahead collapse.
		--
		-- This is the mirror of the defect this codebase keeps shipping. The usual form is
		-- unknown-as-no; this is no-as-unknown, and it is just as wrong.
		--
		-- Only a query that could not RUN is degradation. `foundAny` is retained purely
		-- as a diagnostic; it is deliberately not an input to the flag any more.
		local foundAny = false
		local readFailed = false
		for _, item in ipairs(trackedSpells) do
			local ok, aura = pcall(queryByID, item.spellID)
			if not ok then
				readFailed = true
				aura = nil
			end
			if aura then
				foundAny = true
				local instanceID = Tuono.num(aura.auraInstanceID, 0)
				if instanceID > 0 then
					instanceMap[instanceID] = item.key
				end
				-- Update state from this aura
				if item.key == "adrenalineRush" then
					Tuono.State.buffs.adrenalineRush.up = true
					Tuono.State.buffs.adrenalineRush.expires = Tuono.num(aura.expirationTime, now)
				elseif item.key == "rtb" then
					Tuono.State.buffs.rtb.stage = Tuono.num(aura.applications, 1)
					Tuono.State.buffs.rtb.stageKnown = true
					Tuono.State.buffs.rtb.expires = Tuono.num(aura.expirationTime, now)
				elseif item.key == "opportunity" then
					Tuono.State.buffs.opportunity.up = true
					Tuono.State.buffs.opportunity.stacks = Tuono.num(aura.applications, 0)
					Tuono.State.buffs.opportunity.expires = Tuono.num(aura.expirationTime, now)
				elseif item.key == "stealthed" then
					Tuono.State.stealthed = true
				end
			end
		end

		Tuono.State.buffsFoundAny = foundAny
		if readFailed then
			Tuono.State.buffs.degraded = true
		end
	else
		-- No aura query function exists at all. This is genuine inability to read.
		Tuono.State.buffs.degraded = true
	end
end

-- TIER 1: Process UNIT_AURA delta payload (updateInfo structure)
-- Read one field off a possibly-secret table. INDEXING a secret table throws, so even
-- getting at the field has to be protected -- a plain `t.k` is not safe here.
-- Returns (value, ok). ok=false means "could not read", never "the value was false".
local function safeField(t, k)
	local ok, v = pcall(function() return t[k] end)
	if not ok then return nil, false end
	return v, true
end

-- Iterate a possibly-secret array safely. ipairs and # both throw on a secret table,
-- so the iteration itself is protected and a failure yields nothing rather than
-- exploding the caller.
local function safeEach(arr, fn)
	if arr == nil then return true end
	if Tuono.isSecret(arr) then return false end
	return pcall(function()
		for _, v in ipairs(arr) do fn(v) end
	end)
end

local function ProcessAuraDelta(updateInfo)
	if not updateInfo then return end

	local now = GetTime()

	-- THE WHOLE UNIT_AURA PAYLOAD GOES SECRET IN COMBAT (confirmed in-game, 12.1.0:
	-- isFullUpdate reads as a secret). This mattered far more than it looks:
	--
	--   `if updateInfo.isFullUpdate then`
	--
	-- is a BOOLEAN TEST ON A SECRET, which raises immediately. OnUnitAura runs inside
	-- Tuono.safe, so the throw was swallowed and the entire Tier-1 delta path silently
	-- died on every aura event in combat -- the exact same failure shape as the
	-- IsAvailable() freeze in AssistReader. Nothing looked broken; buffs just never
	-- updated.
	--
	-- Indexing a secret TABLE throws too, so the field read is protected as well as
	-- the test.
	-- A DARK DELTA CHANNEL IS NOT DEGRADATION. IT IS TUESDAY.
	--
	-- The UNIT_AURA payload is secret for the whole of combat, so these branches fire on
	-- essentially every aura event in every fight -- which is why `degraded` was true on
	-- 100% of ticks in a recorded trace, why the bar showed "~ degraded data"
	-- permanently, and why inputConfidence rated buff-gated steps "unknown" forever.
	--
	-- But we do not depend on this channel any more. Opportunity comes from the spell
	-- activation overlay, which is never-secret and fires on both edges. Roll the Bones
	-- stage is modelled from the roll we observe plus the profile's duration constants.
	-- Adrenaline Rush is modelled by EnergyModel from the cast. Announcing degradation
	-- because a REPLACED channel went dark reports our own architecture as a fault.
	--
	-- So: record that the delta channel is blind, which is true and diagnostic, and stop
	-- claiming the addon's knowledge is degraded when it is not. `degraded` is reserved
	-- for genuine loss -- no aura API, or a query that could not run.
	if Tuono.isSecret(updateInfo) then
		Tuono.State.buffs.deltaBlind = true
		return
	end

	local rawFull, gotFull = safeField(updateInfo, "isFullUpdate")
	if not gotFull then
		Tuono.State.buffs.deltaBlind = true
		return
	end

	-- ABSENT IS NOT SECRET. A normal delta payload simply omits isFullUpdate, and
	-- readBool reports nil as "not known" -- which is correct for a secret but wrong
	-- here. Bailing on absence killed every ordinary delta, which is the same
	-- unknown-vs-missing conflation this file keeps having to unlearn.
	if rawFull == nil then
		-- omitted => this is a delta, not a rebuild. Fall through.
	elseif Tuono.isSecret(rawFull) then
		-- Genuinely unreadable: we cannot tell a rebuild from a delta, and applying a
		-- delta to a map that may have just been invalidated would corrupt state.
		-- Refuse, and let the out-of-combat bootstrap re-establish the truth. Blind on
		-- this channel, not degraded overall -- see the note above.
		Tuono.State.buffs.deltaBlind = true
		return
	else
		local isFull = Tuono.readBool(rawFull)
		if isFull then
			BootstrapBuffState()
			return
		end
	end

	-- removedAuraInstanceIDs: clear mapped state + remove from map.
	-- Walked through safeEach: ipairs and # both throw on a secret table, and any of
	-- these three arrays can be secret independently of the payload as a whole.
	local removed = safeField(updateInfo, "removedAuraInstanceIDs")
	if not safeEach(removed, function(instanceID)
			local key = instanceMap[instanceID]
			if key == "adrenalineRush" then
				Tuono.State.buffs.adrenalineRush.up = false
				Tuono.State.buffs.adrenalineRush.expires = 0
			elseif key == "rtb" then
				Tuono.State.buffs.rtb.stage = 0
				Tuono.State.buffs.rtb.stageKnown = true
				Tuono.State.buffs.rtb.expires = 0
				wipe(Tuono.State.buffs.rtb.names)
			elseif key == "opportunity" then
				Tuono.State.buffs.opportunity.up = false
				Tuono.State.buffs.opportunity.stacks = 0
				Tuono.State.buffs.opportunity.expires = 0
			elseif key == "stealthed" then
				Tuono.State.stealthed = false
			end
			instanceMap[instanceID] = nil
		end) then
		-- The array itself is secret, which is the normal state in combat. Blind on this
		-- channel, not degraded overall -- see the note in ProcessAuraDelta's header.
		Tuono.State.buffs.deltaBlind = true
	end

	-- addedAuras: match by spellId (readable-first check) or correlation
	local added = safeField(updateInfo, "addedAuras")
	if not safeEach(added, function(auraData)
			local instanceID = Tuono.num(auraData.auraInstanceID, 0)
			if instanceID > 0 then
				-- Try to read spellId (not secret)
				local spellID = nil
				if not isSecret(auraData.spellId) then
					spellID = Tuono.num(auraData.spellId, 0)
				end

				-- Match by readable spellId
				if spellID == Tuono.SpellIDs.adrenalineRush then
					instanceMap[instanceID] = "adrenalineRush"
					Tuono.State.buffs.adrenalineRush.up = true
					Tuono.State.buffs.adrenalineRush.expires = Tuono.num(auraData.expirationTime, now)
					Tuono.State.buffs.degraded = false
				elseif Tuono.Profiles.MatchesSpell("rollTheBones", spellID) then
					instanceMap[instanceID] = "rtb"
					Tuono.State.buffs.rtb.stage = Tuono.num(auraData.applications, 1)
					Tuono.State.buffs.rtb.stageKnown = true
					Tuono.State.buffs.rtb.expires = Tuono.num(auraData.expirationTime, now)
					Tuono.State.buffs.degraded = false
				elseif spellID == 195627 then
					instanceMap[instanceID] = "opportunity"
					Tuono.State.buffs.opportunity.up = true
					Tuono.State.buffs.opportunity.stacks = Tuono.num(auraData.applications, 0)
					Tuono.State.buffs.opportunity.expires = Tuono.num(auraData.expirationTime, now)
					Tuono.State.buffs.degraded = false
				elseif spellID == Tuono.SpellIDs.stealth then
					instanceMap[instanceID] = "stealthed"
					Tuono.State.stealthed = true
					Tuono.State.buffs.degraded = false
				elseif spellID == 0 or spellID == nil then
					-- Secret spellId: try CAST-CORRELATION
					if lastCast.spellID and (now - lastCast.t) <= castCorrelationWindow then
						if lastCast.spellID == Tuono.SpellIDs.adrenalineRush then
							instanceMap[instanceID] = "adrenalineRush"
							Tuono.State.buffs.adrenalineRush.up = true
							Tuono.State.buffs.adrenalineRush.expires = Tuono.num(auraData.expirationTime, now)
							Tuono.State.buffs.degraded = false
						elseif Tuono.Profiles.MatchesSpell("rollTheBones", lastCast.spellID) then
							instanceMap[instanceID] = "rtb"
							Tuono.State.buffs.rtb.stage = Tuono.num(auraData.applications, 1)
							Tuono.State.buffs.rtb.stageKnown = true
							Tuono.State.buffs.rtb.expires = Tuono.num(auraData.expirationTime, now)
							Tuono.State.buffs.degraded = false
						elseif lastCast.spellID == 195627 then
							instanceMap[instanceID] = "opportunity"
							Tuono.State.buffs.opportunity.up = true
							Tuono.State.buffs.opportunity.stacks = Tuono.num(auraData.applications, 0)
							Tuono.State.buffs.opportunity.expires = Tuono.num(auraData.expirationTime, now)
							Tuono.State.buffs.degraded = false
						end
					else
						-- AN UNIDENTIFIED BUFF IS NOT OUR BUFF.
						-- This marked the whole state degraded whenever an added aura
						-- could not be correlated to a recent cast -- which fires for
						-- every food, flask, raid buff, trinket proc and world buff the
						-- player gains. None of those say anything about the four auras
						-- we actually track, and all of them arrive constantly.
						Tuono.State.buffs.deltaBlind = true
					end
				end
			end
		end) then
		-- Secret array; see above.
		Tuono.State.buffs.deltaBlind = true
	end

	-- updatedAuraInstanceIDs: refresh mapped entries via GetAuraDataByAuraInstanceID
	local updated = safeField(updateInfo, "updatedAuraInstanceIDs")
	if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
		if not safeEach(updated, function(instanceID)
				if instanceMap[instanceID] then
					-- 12.1.0: the by-instance-ID path RAISES while auras are restricted,
					-- rather than returning a secret. pcall, not a nil check.
					local okA, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", instanceID)
					if okA and aura then
						local exp = Tuono.readNum(aura.expirationTime)
						if exp then
							Tuono.State.buffs[instanceMap[instanceID]].expires = exp
						end
					end
				end
			end) then
			-- Secret array; see above.
			Tuono.State.buffs.deltaBlind = true
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
	local rtbStageFromModern = Tuono.State.buffs.rtb.stage

	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local i = 1
		while true do
			local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
			if not aura then break end

			-- THE GUARD MUST NOT RUN AFTER THE TEST IT PROTECTS.
			-- This was `if aura.spellId and not isSecret(aura.spellId) then`, which
			-- boolean-tests the value BEFORE asking whether it is secret -- so a secret
			-- spellId raises on the very line written to defend against it. readNum
			-- answers both questions at once and in the right order.
			local auraSpellId = Tuono.readNum(aura.spellId) or 0

			-- Modern path: spell IDs take precedence; only update if delta didn't already set it
			if auraSpellId == Tuono.SpellIDs.rollTheBones and rtbStageFromModern == 0 then
				Tuono.State.buffs.rtb.stage = Tuono.num(aura.applications, 1)
				Tuono.State.buffs.rtb.stageKnown = true
				Tuono.State.buffs.rtb.expires = Tuono.num(aura.expirationTime, now)
			end

			-- Non-RtB tracked auras: fill only what the modern tiers did NOT already set.
			if auraSpellId == Tuono.SpellIDs.adrenalineRush and not Tuono.State.buffs.adrenalineRush.up then
				Tuono.State.buffs.adrenalineRush.up = true
				Tuono.State.buffs.adrenalineRush.expires = Tuono.num(aura.expirationTime, now)
			end
			if auraSpellId == Tuono.SpellIDs.opportunity and not Tuono.State.buffs.opportunity.up then
				Tuono.State.buffs.opportunity.up = true
				Tuono.State.buffs.opportunity.stacks = Tuono.num(aura.applications, 0)
				Tuono.State.buffs.opportunity.expires = Tuono.num(aura.expirationTime, now)
			end
			if auraSpellId == Tuono.SpellIDs.stealth then
				Tuono.State.stealthed = true
			end

			-- Legacy name scan: ONLY if stage is still 0 (modern spellID path didn't find it)
			local auraName = safeStr(aura.name)
			if rtbStageFromModern == 0 then
				for _, buffName in ipairs(Tuono.RTB_BUFF_NAMES) do
					if auraName == buffName and auraSpellId ~= Tuono.SpellIDs.rollTheBones then
						table.insert(Tuono.State.buffs.rtb.names, buffName)
						Tuono.State.buffs.rtb.stage = 1
						Tuono.State.buffs.degraded = true  -- Mark degraded when using legacy fallback
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
				Tuono.State.buffs.rtb.stage = Tuono.num(count, 1)
				Tuono.State.buffs.rtb.stageKnown = true
				Tuono.State.buffs.rtb.expires = Tuono.num(expTime, now)
				table.insert(Tuono.State.buffs.rtb.names, name)
			end

			-- Non-RtB tracked auras by name. Names are localization-dependent, so anything
			-- learned here marks degraded: it is the least-trusted source we have.
			if name == "Adrenaline Rush" and not Tuono.State.buffs.adrenalineRush.up then
				local _, _, _, _, _, expTime = UnitBuff("player", i)
				Tuono.State.buffs.adrenalineRush.up = true
				Tuono.State.buffs.adrenalineRush.expires = Tuono.num(expTime, now)
				Tuono.State.buffs.degraded = true
			end
			if name == "Opportunity" and not Tuono.State.buffs.opportunity.up then
				local _, _, count, _, _, expTime = UnitBuff("player", i)
				Tuono.State.buffs.opportunity.up = true
				Tuono.State.buffs.opportunity.stacks = Tuono.num(count, 0)
				Tuono.State.buffs.opportunity.expires = Tuono.num(expTime, now)
				Tuono.State.buffs.degraded = true
			end
			if name == "Stealth" then
				Tuono.State.stealthed = true
				Tuono.State.buffs.degraded = true
			end

			-- Legacy name scan: ONLY if stage is still 0
			if rtbStageFromModern == 0 then
				for _, buffName in ipairs(Tuono.RTB_BUFF_NAMES) do
					if name == buffName and name ~= "Roll the Bones" then
						table.insert(Tuono.State.buffs.rtb.names, name)
						Tuono.State.buffs.rtb.stage = 1
						Tuono.State.buffs.degraded = true  -- Mark degraded when using legacy fallback
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
		Tuono.State.trinkets[slot].itemID = itemID

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
				Tuono.State.trinkets[slot].ready = false
				Tuono.State.trinkets[slot].remaining = 0
			else
				cd_start = Tuono.num(cd_start, 0)
				cd_duration = Tuono.num(cd_duration, 0)
				if cd_start ~= nil and cd_duration ~= nil then
					local now = GetTime()
					if cd_start == 0 or cd_duration == 0 then
						Tuono.State.trinkets[slot].ready = true
						Tuono.State.trinkets[slot].remaining = 0
					else
						Tuono.State.trinkets[slot].remaining = math.max(0, (cd_start + cd_duration) - now)
						Tuono.State.trinkets[slot].ready = Tuono.State.trinkets[slot].remaining <= 0
					end
				end
			end

			if trinketSpellCache[itemID] == nil then
				local hasUse = false
				if C_Item and C_Item.GetItemSpell then
					local spellName, spellID = C_Item.GetItemSpell(itemID)
					hasUse = Tuono.num(spellID, 0) > 0
				elseif GetItemSpell then
					local spellName, spellID = GetItemSpell(itemID)
					hasUse = Tuono.num(spellID, 0) > 0
				end
				trinketSpellCache[itemID] = hasUse or trinketCacheSentinel
			end
			local cached = trinketSpellCache[itemID]
			Tuono.State.trinkets[slot].onUse = (cached ~= trinketCacheSentinel) and cached or false
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
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	local meleeSpell = profile and profile.meleeRangeSpell and profile.spells[profile.meleeRangeSpell]
	if meleeSpell then
		local fn = (C_Spell and C_Spell.IsSpellInRange) or _G.IsSpellInRange
		if fn then
			local ok, inRange = pcall(fn, meleeSpell, token)
			if ok then
				local b, known = Tuono.readBool(inRange)
				if known then return b end
				local n, numKnown = Tuono.readNum(inRange)   -- legacy API returns 1/0
				if numKnown then return n == 1 end
			end
		end
	end
	-- Fall back to the interact-distance probe (4 == ~28yd "follow"; the tightest
	-- generally-available bracket). Better than no filter at all.
	if _G.CheckInteractDistance then
		local ok, res = pcall(_G.CheckInteractDistance, token, 4)
		if ok then
			local b, known = Tuono.readBool(res)
			if known then return b end
		end
	end
	return true
end

local function RefreshEnemyCount()
	Tuono.State.enemyCount = nil
	Tuono.State.enemyCountKnown = false

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
				local b, known = Tuono.readBool(okA and res)
				attackable = known and b or false
			end

			local alive = true
			if _G.UnitIsDead then
				local okD, res = pcall(_G.UnitIsDead, token)
				local b, known = Tuono.readBool(okD and res)
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
		Tuono.State.enemyCount = nil
		Tuono.State.enemyCountKnown = false
	else
		Tuono.State.enemyCount = count
		Tuono.State.enemyCountKnown = true
	end
end

-- SPELL OVERRIDES: talents/procs/stealth can swap the spell actually castable/on the
-- action bar for a different (override) spellID than the base ID this addon reasons
-- about (Tuono.SpellIDs always holds base IDs). Both directions must resolve so a lookup
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
function Tuono.ResolveOverrideSpell(spellID)
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

function Tuono.ResolveBaseSpell(spellID)
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
function Tuono.SpellMatchesAction(spellID, actionID)
	if not spellID or not actionID then return false end
	if actionID == spellID then return true end
	if Tuono.ResolveOverrideSpell(spellID) == actionID then return true end
	if Tuono.ResolveBaseSpell(actionID) == spellID then return true end
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
		Tuono.State.knownUnavailable = true
		return
	end

	Tuono.State.knownUnavailable = false
	wipe(Tuono.State.knownSpells)

	-- Probe a spellID AND its live override/base pair, marking ALL of them known when
	-- EITHER form checks true. A talented-and-overridden ability must not read as
	-- "unknown" just because we probed the base ID while only the override reports
	-- known (or vice versa) -- this is the gating half of the override-resolution fix
	-- (state-dependent availability must survive a base<->override swap).
	local function probeAndMark(spellID)
		if not spellID or Tuono.State.knownSpells[spellID] ~= nil then return end
		local ok, isKnown = pcall(checkFn, spellID)
		isKnown = ok and isKnown or false

		local override = Tuono.ResolveOverrideSpell(spellID)
		local base = Tuono.ResolveBaseSpell(spellID)

		if not isKnown and override ~= spellID then
			local ok2, isKnown2 = pcall(checkFn, override)
			isKnown = isKnown or (ok2 and isKnown2 or false)
		end
		if not isKnown and base ~= spellID then
			local ok3, isKnown3 = pcall(checkFn, base)
			isKnown = isKnown or (ok3 and isKnown3 or false)
		end

		Tuono.State.knownSpells[spellID] = isKnown
		if override ~= spellID then Tuono.State.knownSpells[override] = isKnown end
		if base ~= spellID then Tuono.State.knownSpells[base] = isKnown end
	end

	-- Check all spells from Tuono.SpellIDs
	for name, spellID in pairs(Tuono.SpellIDs or {}) do
		if spellID then probeAndMark(spellID) end
	end

	-- Also check all spells referenced by rules
	for _, rule in ipairs(Tuono.Rules or {}) do
		if rule.spellID then probeAndMark(rule.spellID) end
	end
end

function Tuono.State.RefreshFast()
	local energyPower = Enum and Enum.PowerType and Enum.PowerType.Energy or 3
	local comboPower = Enum and Enum.PowerType and Enum.PowerType.ComboPoints or 4

	-- STEALTH comes from IsStealthed(), not the aura scan. Aura data goes secret in
	-- combat, so an aura-derived flag never CLEARS once set -- which pinned Ambush to
	-- position 1 permanently. IsStealthed is a plain boolean and stays readable.
	if _G.IsStealthed then
		local ok, stealthed = pcall(_G.IsStealthed)
		if ok then Tuono.State.stealthed = stealthed and true or false end
	end

	-- RESOURCES MUST REPORT READABILITY, NOT JUST A NUMBER.
	-- The old code was Tuono.num(UnitPower(...), 0). When Midnight makes a resource secret
	-- that yields a confident "0 energy / 0 combo points" -- and every canAfford() gate
	-- in Rotation.lua then fails, Predict() returns an EMPTY sequence, and the bar falls
	-- back to a stale Blizzard pick. Unreadable must be UNKNOWN, so the predictor can
	-- drop the gate instead of asserting zero.
	local energy, energyKnown = Tuono.readNum(UnitPower("player", energyPower))
	local energyMax, energyMaxKnown = Tuono.readNum(UnitPowerMax("player", energyPower))
	local cp, cpKnown = Tuono.readNum(UnitPower("player", comboPower))
	local cpMax, cpMaxKnown = Tuono.readNum(UnitPowerMax("player", comboPower))

	Tuono.State.energyMax = energyMax or 0
	Tuono.State.energyMaxKnown = energyMaxKnown

	-- THE SHADOW MODEL IS THE SINGLE SOURCE OF ENERGY, ALWAYS -- not just a fallback.
	-- It measures directly whenever the API is readable and integrates forward when it
	-- is not. Running it only on the unreadable path was a seeding bug: the model never
	-- saw a real measurement to anchor to, so the moment energy went secret it had
	-- nothing to extrapolate from and reported "unknown" forever.
	if Tuono.Energy then
		pcall(Tuono.Energy.Advance)
		local est, usable, conf = Tuono.Energy.Get()
		Tuono.State.energy = est
		Tuono.State.energyKnown = usable
		Tuono.State.energySource = usable and conf or "unknown"
	elseif energyKnown then
		Tuono.State.energy = energy or 0
		Tuono.State.energyKnown = true
		Tuono.State.energySource = "measured"
	else
		Tuono.State.energy = 0
		Tuono.State.energyKnown = false
		Tuono.State.energySource = "unknown"
	end
	Tuono.State.comboPoints = cp or 0
	Tuono.State.comboPointsKnown = cpKnown
	-- comboPointsMax is a character constant (5/6/7), not combat state. If it ever reads
	-- secret, keeping the last known value beats collapsing to 0 -- `cp < cpMax` with
	-- cpMax==0 is false for every cp, which silently disables the builder rule.
	if cpMaxKnown and cpMax and cpMax > 0 then
		Tuono.State.comboPointsMax = cpMax
		Tuono.State.lastKnownCPMax = cpMax
	elseif Tuono.State.lastKnownCPMax then
		Tuono.State.comboPointsMax = Tuono.State.lastKnownCPMax
	end
	Tuono.State.comboPointsMaxKnown = cpMaxKnown

	-- Roll the Bones stage, resolved through the observation channels rather than the
	-- aura payload: never-secret whitelist first, then the known stage-buff map, then
	-- the learner. Only overwrite when the answer is genuinely KNOWN -- a nil result
	-- must leave the previous belief alone rather than silently resetting stage to 0,
	-- which is the same unknown-as-zero mistake in a new place.
	if Tuono.Observers and Tuono.Observers.ResolveRtbStage then
		Tuono.safe(Tuono.Observers.PollRtbLearner)
		local stage, known = Tuono.Observers.ResolveRtbStage()
		if known then
			Tuono.State.buffs.rtb.stage = stage
			Tuono.State.buffs.rtb.stageKnown = true
			Tuono.Observers.rtbUnknownPresent = false
		elseif Tuono.Observers.rtbUnknownPresent then
			-- A roll landed but we cannot identify which stage. Presence is real,
			-- the stage is not -- so the reroll rule must refuse to fire.
			Tuono.State.buffs.rtb.stageKnown = false
		end
	end

	-- PROVING ABSENCE FROM THE CAST STREAM.
	--
	-- Aura payloads go secret in combat, so `stageKnown` reads false for most of a fight,
	-- and the profile's Roll the Bones rule fails CLOSED on an unknown stage. That guard is
	-- right for REROLLING -- never reroll a Jackpot you cannot see -- but it is catastrophic
	-- for the case that matters most: with no Roll the Bones buff at all, the rule that says
	-- "go roll" also refuses to fire, so the core ability of the spec is never recommended
	-- in combat. Live trace: `rtb=0(false)` on every in-combat tick, and Roll the Bones
	-- never reached the bar.
	--
	-- But absence is PROVABLE without reading a single aura. Roll the Bones only ever starts
	-- from a cast, casts are readable (UNIT_SPELLCAST_SUCCEEDED carries a plain spellID), and
	-- the buff has a known duration. If no Roll the Bones cast has landed within that
	-- duration, there is no buff -- whatever the aura layer can or cannot see. Same
	-- reconstruction the cooldown model already runs, pointed at a buff instead of a timer.
	--
	-- This only ever establishes stage ZERO. It can never claim a stage, so it cannot
	-- resurrect the reroll-a-Jackpot bug: the moment a roll lands, `rtbUnknownPresent` takes
	-- over and the stage goes unknown again until something identifies it.
	if not Tuono.State.buffs.rtb.stageKnown then
		local lastRoll = Tuono.State.buffs.rtb.lastCastAt or 0
		local duration = (Tuono.Profiles and Tuono.Profiles.Active()
			and Tuono.Profiles.Active().rtbDuration) or 30
		if lastRoll <= 0 or (GetTime() - lastRoll) > duration then
			Tuono.State.buffs.rtb.stage = 0
			Tuono.State.buffs.rtb.stageKnown = true
			Tuono.State.buffs.rtb.stageFromAbsence = true
		else
			-- Within the buff window: absence is NOT provable this tick. Clear the flag
			-- rather than leaving the previous tick's proof standing -- a provenance marker
			-- that outlives the thing it describes is worse than no marker, because
			-- everything downstream trusts it.
			Tuono.State.buffs.rtb.stageFromAbsence = nil
		end
	else
		Tuono.State.buffs.rtb.stageFromAbsence = nil
	end

	-- Snapshot combo points BEFORE anything can consume them. UNIT_SPELLCAST_SUCCEEDED
	-- fires after a finisher has already spent them, so the live value reads 0 at
	-- exactly the moment CooldownModel needs to know what was spent for Restless Blades.
	if Tuono.CooldownModel then Tuono.CooldownModel.NoteTick() end

	RefreshCooldowns()

	local now = GetTime()
	-- TIER 3 Fallback: only safe to run NOT in combat (aura scanning can throw on secret values in combat)
	-- When inCombat=true, skip Tier 3 and trust Tier 1 delta tracking.
	-- If Tier 1 failed (degraded), stay degraded; Tier 3 won't fix it mid-combat.
	if (now - lastBuffScan) >= 0.5 and not Tuono.State.inCombat then
		-- Periodic fallback scan in case delta tracking lost sync (out of combat only).
		-- ISOLATED pcall: as of 12.1.0 the index/slot/instanceID aura paths do not merely
		-- return secrets, they raise an immediate Lua ERROR while auras are restricted.
		-- Sharing RefreshFast's outer pcall meant one such throw skipped everything after
		-- it -- enemy count and trinket state included -- so a hidden aura silently took
		-- out unrelated, still-readable subsystems.
		local ok = pcall(RefreshBuffsFallback)
		if not ok then Tuono.State.buffs.degraded = true end
		lastBuffScan = now
	end

	if (now - lastEnemyCountRefresh) >= 0.25 then
		pcall(RefreshEnemyCount)
		lastEnemyCountRefresh = now
	end

	-- Trinkets were the one expensive subsystem in here with NO throttle, while the buff
	-- scan (0.5s) and enemy count (0.25s) both had one. Trinket cooldowns move on a scale
	-- of minutes; polling four API calls for them at 10Hz is pure waste.
	if (now - lastTrinketRefresh) >= 0.5 then
		pcall(RefreshTrinkets)
		lastTrinketRefresh = now
	end
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
	Tuono.State.inCombat = true
end

local function OnPlayerRegenEnabled(event)
	Tuono.State.inCombat = false
end

local function OnUnitAura(event, unit, updateInfo)
	if unit == "player" then
		-- TIER 1: Process delta updates if updateInfo available
		if updateInfo then
			ProcessAuraDelta(updateInfo)
		elseif not Tuono.State.inCombat then
			-- Fallback: full refresh if no updateInfo. Same combat gate as the periodic
			-- path -- this call site was the hole that let the index scan run in combat.
			RefreshBuffsFallback()
		end
	end
end

local function OnUnitSpellcastSucceeded(event, unit, castGUID, spellID)
	if unit == "player" then
		local id = Tuono.readNum(spellID)
		lastCast.spellID = id or 0
		lastCast.t = GetTime()

		-- Timestamp the roll itself. This is what lets the absence proof in RefreshFast
		-- conclude "there is no Roll the Bones buff" without reading an aura: the buff can
		-- only start from a cast, and casts are readable even when auras are not.
		-- Alias-aware, because the cast can arrive under a renumbered sibling ID.
		if id and Tuono.Profiles and Tuono.Profiles.MatchesSpell
			and Tuono.Profiles.MatchesSpell("rollTheBones", id) then
			Tuono.State.buffs.rtb.lastCastAt = GetTime()
			-- The stage is unknown again until something identifies it; the absence proof
			-- must not immediately re-conclude "no buff" off a stale timestamp.
			Tuono.State.buffs.rtb.stageKnown = false
			Tuono.State.buffs.rtb.stageFromAbsence = nil
		end
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

Tuono.RegisterEvent("PLAYER_ENTERING_WORLD", OnPlayerEnteringWorldFull)
Tuono.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", OnPlayerEquipmentChanged)
Tuono.RegisterEvent("PLAYER_REGEN_DISABLED", OnPlayerRegenDisabled)
Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", OnPlayerRegenEnabled)
Tuono.RegisterUnitEvent("UNIT_AURA", "player", OnUnitAura)
Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", OnUnitSpellcastSucceeded)
Tuono.RegisterEvent("NAME_PLATE_UNIT_ADDED", OnNamePlateUnitAdded)
Tuono.RegisterEvent("NAME_PLATE_UNIT_REMOVED", OnNamePlateUnitRemoved)

-- Register for talent/spell changes. These used to be guarded by `if _G.EVENT_NAME
-- then ... end` -- that tests for a GLOBAL VARIABLE happening to share the event's
-- name, which WoW does not define for these events, so the guard was always false
-- and NONE of these handlers were ever registered (dead code; talent respecs never
-- refreshed knownSpells/overrides). All four are VERIFIED real, current WoW events
-- (warcraft.wiki.gg, 2026-08-01) and are registered directly, same as every other
-- event in this file.
if not Tuono._RegisteredTalentEvents then
	Tuono._RegisteredTalentEvents = true
	Tuono.RegisterEvent("PLAYER_TALENT_UPDATE", OnTalentChange)
	Tuono.RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", OnTalentChange)
	Tuono.RegisterEvent("TRAIT_CONFIG_UPDATED", OnTalentChange)
	Tuono.RegisterEvent("SPELLS_CHANGED", OnTalentChange)

	-- STEALTH can flip which override is active for a spell (VERIFIED example from
	-- FindBaseSpellByID's own docs: a Shadowrunner-style talent overrides Stealth
	-- itself while stealthed). Re-probe known/override state on the same trigger
	-- Display/Highlight use to invalidate their caches, so a talented-and-overridden
	-- ability is never read as "unknown" mid-transition.
	Tuono.RegisterEvent("UPDATE_STEALTH", OnTalentChange)
end
