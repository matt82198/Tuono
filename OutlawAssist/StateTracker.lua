local ADDON_NAME, OA = ...

OA.SpellIDs = {
	adrenalineRush = 13750, -- TODO(M0): verify in-game
	bladeRush = 271877, -- TODO(M0): verify in-game
	preparation = 14185, -- TODO(M0): verify in-game
	betweenTheEyes = 315341, -- TODO(M0): verify in-game
	rollTheBones = 315508, -- TODO(M0): verify in-game
	sinisterStrike = 193315, -- TODO(M0): verify in-game
	bladeFlurry = 13877, -- TODO(M0): verify in-game
	stealth = 1784, -- TODO(M0): verify in-game
	pistolShot = 185763, -- TODO(M0): verify in-game
	opportunity = 195627, -- VERIFIED: Opportunity buff (enables free Pistol Shot), hardcoded 3x in StateTracker before fix
	ambush = 8676 -- VERIFIED: Stealth opener ability, primary damage button from Stealth
}

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
	buffs = {
		rtb = { stage = 0, expires = 0, names = {} },
		opportunity = { up = false, expires = 0 },
		adrenalineRush = { up = false, expires = 0 },
		degraded = false
	},
	cooldowns = {
		adrenalineRush = { known = false, ready = false, remaining = 0 },
		bladeRush = { known = false, ready = false, remaining = 0 },
		preparation = { known = false, ready = false, remaining = 0 }
	},
	trinkets = {
		[13] = { itemID = nil, ready = false, remaining = 0, onUse = false },
		[14] = { itemID = nil, ready = false, remaining = 0, onUse = false }
	},
	tier = { twoPc = false, fourPc = false },
	inCombat = false,
	stealthed = false,
	enemyCount = nil
}

local lastBuffScan = -1
local lastEnemyCountRefresh = -1
local trinketSpellCache = {}
local trinketCacheSentinel = {}

-- TIER 1: Instance ID delta-map (auraInstanceID -> tracked-aura key)
local instanceMap = {}
-- TIER 1: Last cast tracking for correlation (~0.8s window)
local lastCast = { spellID = nil, t = 0 }
local castCorrelationWindow = 0.8

local function NormalizeCooldown(startTime, duration)
	startTime = OA.num(startTime, 0)
	duration = OA.num(duration, 0)
	if startTime == 0 or duration == 0 then
		return { known = true, ready = true, remaining = 0 }
	end
	local now = GetTime()
	local remaining = (startTime + duration) - now
	return {
		known = true,
		ready = remaining <= 0,
		remaining = math.max(0, remaining)
	}
end

local function RefreshCooldowns()
	local ar_cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(OA.SpellIDs.adrenalineRush)
	if ar_cd then
		OA.State.cooldowns.adrenalineRush = NormalizeCooldown(ar_cd.startTime, ar_cd.duration)
	elseif GetSpellCooldown then
		local start, duration = GetSpellCooldown(OA.SpellIDs.adrenalineRush)
		OA.State.cooldowns.adrenalineRush = NormalizeCooldown(start, duration)
	end

	local br_cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(OA.SpellIDs.bladeRush)
	if br_cd then
		OA.State.cooldowns.bladeRush = NormalizeCooldown(br_cd.startTime, br_cd.duration)
	elseif GetSpellCooldown then
		local start, duration = GetSpellCooldown(OA.SpellIDs.bladeRush)
		OA.State.cooldowns.bladeRush = NormalizeCooldown(start, duration)
	end

	local prep_cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(OA.SpellIDs.preparation)
	if prep_cd then
		OA.State.cooldowns.preparation = NormalizeCooldown(prep_cd.startTime, prep_cd.duration)
	elseif GetSpellCooldown then
		local start, duration = GetSpellCooldown(OA.SpellIDs.preparation)
		OA.State.cooldowns.preparation = NormalizeCooldown(start, duration)
	end
end

-- TIER 2: Bootstrap/rescan via GetPlayerAuraBySpellID
local function BootstrapBuffState()
	local now = GetTime()
	wipe(instanceMap)
	OA.State.buffs.degraded = false

	-- Try to seed instanceMap via GetPlayerAuraBySpellID for all tracked spells
	if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID then
		local trackedSpells = {
			{ spellID = OA.SpellIDs.adrenalineRush, key = "adrenalineRush" },
			{ spellID = OA.SpellIDs.rollTheBones, key = "rtb" },
			{ spellID = 195627, key = "opportunity" },
			{ spellID = OA.SpellIDs.stealth, key = "stealthed" }
		}

		local foundAny = false
		for _, item in ipairs(trackedSpells) do
			local aura = C_UnitAuras.GetAuraDataBySpellID("player", item.spellID)
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
				if not _G.issecretvalue(auraData.spellId) then
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
			if aura.spellId and not _G.issecretvalue(aura.spellId) then
				auraSpellId = OA.num(aura.spellId, 0)
			end

			-- Modern path: spell IDs take precedence; only update if delta didn't already set it
			if auraSpellId == OA.SpellIDs.rollTheBones and rtbStageFromModern == 0 then
				OA.State.buffs.rtb.stage = OA.num(aura.applications, 1)
				OA.State.buffs.rtb.expires = OA.num(aura.expirationTime, now)
			end

			-- Legacy name scan: ONLY if stage is still 0 (modern spellID path didn't find it)
			local auraName = aura.name or ""
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
			local name = UnitBuff("player", i)
			if not name then break end

			if name == "Roll the Bones" and rtbStageFromModern == 0 then
				local _, _, count, _, duration, expTime = UnitBuff("player", i)
				OA.State.buffs.rtb.stage = OA.num(count, 1)
				OA.State.buffs.rtb.expires = OA.num(expTime, now)
				table.insert(OA.State.buffs.rtb.names, name)
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

local function RefreshEnemyCount()
	OA.State.enemyCount = nil

	local api = _G.C_NamePlate
	if not api or not api.GetNamePlates then
		return
	end

	local plates = api.GetNamePlates()
	if not plates then
		return
	end

	local count = 0
	local poisoned = 0

	for _, plate in ipairs(plates) do
		local token = nil
		if plate.namePlateUnitToken then
			token = plate.namePlateUnitToken
		elseif plate.UnitFrame and plate.UnitFrame.unit then
			token = plate.UnitFrame.unit
		end

		if token then
			local ok, threat = pcall(function()
				return UnitThreatSituation("player", token)
			end)

			if ok and threat ~= nil then
				if _G.issecretvalue and _G.issecretvalue(threat) then
					poisoned = poisoned + 1
				else
					count = count + 1
				end
			else
				poisoned = poisoned + 1
			end
		end
	end

	if #plates == 0 or poisoned == #plates then
		OA.State.enemyCount = nil
	else
		OA.State.enemyCount = count
	end
end

function OA.State.RefreshFast()
	local energyPower = Enum and Enum.PowerType and Enum.PowerType.Energy or 3
	local comboPower = Enum and Enum.PowerType and Enum.PowerType.ComboPoints or 4

	OA.State.energy = OA.num(UnitPower("player", energyPower), 0)
	OA.State.energyMax = OA.num(UnitPowerMax("player", energyPower), 0)
	OA.State.comboPoints = OA.num(UnitPower("player", comboPower), 0)
	OA.State.comboPointsMax = OA.num(UnitPowerMax("player", comboPower), 0)

	RefreshCooldowns()

	local now = GetTime()
	-- TIER 3 Fallback: only safe to run NOT in combat (aura scanning can throw on secret values in combat)
	-- When inCombat=true, skip Tier 3 and trust Tier 1 delta tracking.
	-- If Tier 1 failed (degraded), stay degraded; Tier 3 won't fix it mid-combat.
	if (now - lastBuffScan) >= 0.5 and not OA.State.inCombat then
		-- Periodic fallback scan in case delta tracking lost sync (out of combat only)
		RefreshBuffsFallback()
		lastBuffScan = now
	end

	if (now - lastEnemyCountRefresh) >= 0.25 then
		RefreshEnemyCount()
		lastEnemyCountRefresh = now
	end

	RefreshTrinkets()
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
		else
			-- Fallback: full refresh if no updateInfo
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

OA.RegisterEvent("PLAYER_ENTERING_WORLD", OnPlayerEnteringWorld)
OA.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", OnPlayerEquipmentChanged)
OA.RegisterEvent("PLAYER_REGEN_DISABLED", OnPlayerRegenDisabled)
OA.RegisterEvent("PLAYER_REGEN_ENABLED", OnPlayerRegenEnabled)
OA.RegisterEvent("UNIT_AURA", OnUnitAura)
OA.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", OnUnitSpellcastSucceeded)
OA.RegisterEvent("NAME_PLATE_UNIT_ADDED", OnNamePlateUnitAdded)
OA.RegisterEvent("NAME_PLATE_UNIT_REMOVED", OnNamePlateUnitRemoved)
