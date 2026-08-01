local ADDON_NAME, OA = ...

OA.SpellIDs = {
	adrenalineRush = 13750, -- TODO(M0): verify in-game
	bladeRush = 271877, -- TODO(M0): verify in-game
	preparation = 14185, -- TODO(M0): verify in-game
	betweenTheEyes = 315341, -- TODO(M0): verify in-game
	rollTheBones = 315508, -- TODO(M0): verify in-game
	sinisterStrike = 193315, -- TODO(M0): verify in-game
	bladeFlurry = 13877 -- TODO(M0): verify in-game
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
		adrenalineRush = { up = false, expires = 0 }
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
	inCombat = false
}

local lastBuffScan = -1
local trinketSpellCache = {}

local function NormalizeCooldown(startTime, duration, isEnabled)
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
		OA.State.cooldowns.adrenalineRush = NormalizeCooldown(ar_cd.startTime, ar_cd.duration, ar_cd.isEnabled)
	elseif GetSpellCooldown then
		local start, duration, enabled = GetSpellCooldown(OA.SpellIDs.adrenalineRush)
		OA.State.cooldowns.adrenalineRush = NormalizeCooldown(start, duration, enabled)
	end

	local br_cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(OA.SpellIDs.bladeRush)
	if br_cd then
		OA.State.cooldowns.bladeRush = NormalizeCooldown(br_cd.startTime, br_cd.duration, br_cd.isEnabled)
	elseif GetSpellCooldown then
		local start, duration, enabled = GetSpellCooldown(OA.SpellIDs.bladeRush)
		OA.State.cooldowns.bladeRush = NormalizeCooldown(start, duration, enabled)
	end

	local prep_cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(OA.SpellIDs.preparation)
	if prep_cd then
		OA.State.cooldowns.preparation = NormalizeCooldown(prep_cd.startTime, prep_cd.duration, prep_cd.isEnabled)
	elseif GetSpellCooldown then
		local start, duration, enabled = GetSpellCooldown(OA.SpellIDs.preparation)
		OA.State.cooldowns.preparation = NormalizeCooldown(start, duration, enabled)
	end
end

local function RefreshBuffs()
	local now = GetTime()
	wipe(OA.State.buffs.rtb.names)
	OA.State.buffs.rtb.stage = 0
	OA.State.buffs.opportunity.up = false
	OA.State.buffs.adrenalineRush.up = false

	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local i = 1
		while true do
			local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
			if not aura then break end

			if aura.spellId == OA.SpellIDs.rollTheBones then
				OA.State.buffs.rtb.stage = aura.applications or 1
				OA.State.buffs.rtb.expires = (aura.expirationTime or now)
				table.insert(OA.State.buffs.rtb.names, "Roll the Bones")
			end

			if aura.spellId == OA.SpellIDs.adrenalineRush then
				OA.State.buffs.adrenalineRush.up = true
				OA.State.buffs.adrenalineRush.expires = (aura.expirationTime or now)
			end

			if aura.spellId == 195627 then
				OA.State.buffs.opportunity.up = true
				OA.State.buffs.opportunity.expires = (aura.expirationTime or now)
			end

			for _, buffName in ipairs(OA.RTB_BUFF_NAMES) do
				if aura.name == buffName and aura.spellId ~= OA.SpellIDs.rollTheBones then
					table.insert(OA.State.buffs.rtb.names, buffName)
					if OA.State.buffs.rtb.stage == 0 then
						OA.State.buffs.rtb.stage = 1
					end
				end
			end

			i = i + 1
		end
	elseif UnitBuff then
		local i = 1
		while true do
			local name = UnitBuff("player", i)
			if not name then break end

			if name == "Roll the Bones" then
				local _, _, count, _, duration, expTime = UnitBuff("player", i)
				OA.State.buffs.rtb.stage = count or 1
				OA.State.buffs.rtb.expires = expTime or now
				table.insert(OA.State.buffs.rtb.names, name)
			end

			if name == "Adrenaline Rush" then
				local _, _, _, _, _, expTime = UnitBuff("player", i)
				OA.State.buffs.adrenalineRush.up = true
				OA.State.buffs.adrenalineRush.expires = expTime or now
			end

			if name == "Opportunity" then
				local _, _, _, _, _, expTime = UnitBuff("player", i)
				OA.State.buffs.opportunity.up = true
				OA.State.buffs.opportunity.expires = expTime or now
			end

			for _, buffName in ipairs(OA.RTB_BUFF_NAMES) do
				if name == buffName and name ~= "Roll the Bones" then
					table.insert(OA.State.buffs.rtb.names, name)
					if OA.State.buffs.rtb.stage == 0 then
						OA.State.buffs.rtb.stage = 1
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

			if not trinketSpellCache[itemID] then
				local hasUse = false
				if C_Item and C_Item.GetItemSpell then
					local spellID = C_Item.GetItemSpell(itemID)
					hasUse = spellID and spellID > 0
				elseif GetItemSpell then
					local spellID = GetItemSpell(itemID)
					hasUse = spellID and spellID > 0
				end
				trinketSpellCache[itemID] = hasUse
			end
			OA.State.trinkets[slot].onUse = trinketSpellCache[itemID] or false
		end
	end
end

function OA.State.RefreshFast()
	local energyPower = Enum and Enum.PowerType and Enum.PowerType.Energy or 3
	local comboPower = Enum and Enum.PowerType and Enum.PowerType.ComboPoints or 4

	OA.State.energy = UnitPower("player", energyPower) or 0
	OA.State.energyMax = UnitPowerMax("player", energyPower) or 0
	OA.State.comboPoints = UnitPower("player", comboPower) or 0
	OA.State.comboPointsMax = UnitPowerMax("player", comboPower) or 0

	RefreshCooldowns()

	local now = GetTime()
	if (now - lastBuffScan) >= 0.5 then
		RefreshBuffs()
		lastBuffScan = now
	end

	RefreshTrinkets()
end

local function OnPlayerEnteringWorld()
	wipe(trinketSpellCache)
	RefreshTrinkets()
end

local function OnPlayerEquipmentChanged()
	RefreshTrinkets()
end

local function OnPlayerRegenDisabled()
	OA.State.inCombat = true
end

local function OnPlayerRegenEnabled()
	OA.State.inCombat = false
end

local function OnUnitAura(unit)
	if unit == "player" then
		RefreshBuffs()
	end
end

OA.RegisterEvent("PLAYER_ENTERING_WORLD", OnPlayerEnteringWorld)
OA.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", OnPlayerEquipmentChanged)
OA.RegisterEvent("PLAYER_REGEN_DISABLED", OnPlayerRegenDisabled)
OA.RegisterEvent("PLAYER_REGEN_ENABLED", OnPlayerRegenEnabled)
OA.RegisterEvent("UNIT_AURA", OnUnitAura)
