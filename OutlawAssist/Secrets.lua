local ADDON_NAME, OA = ...

-- ============================================================================
-- SECRET-VALUE AUDIT  --  /oa secrets
-- ============================================================================
-- Answers, from the live client, the only question that decides whether this addon
-- can work: WHICH of the values it depends on are actually readable RIGHT NOW?
--
-- Static research says energy is secret unconditionally, combo points are not, and
-- cooldown timers go secret under combat/encounter/keystone/PvP restrictions -- but
-- Blizzard reverses these between builds (12.0.5 flagged six AuraData booleans
-- NeverSecret; 12.1.0 then declared AuraData "always fully secret"). Documentation is
-- a hypothesis. This command is the measurement.
--
-- Run it in the three places that matter and compare:
--   1. standing in a city, out of combat
--   2. on a training dummy, in combat
--   3. mid-pull inside a mythic keystone
-- ============================================================================

OA.Secrets = OA.Secrets or {}

local function statusOf(v)
	if v == nil then return "|cff888888absent|r", false end
	if OA.isSecret(v) then return "|cffff5555SECRET|r", false end
	return "|cff55ff55readable|r", true
end

-- Render a value without ever performing a disallowed operation on it. Anything that
-- is secret or non-primitive is described, never formatted -- string.format on a
-- secret yields a secret string, and Blizzard patched readback of those as
-- "declassification", so we do not even try.
local function describe(v)
	if v == nil then return "nil" end
	if OA.isSecret(v) then return "<secret>" end
	local t = type(v)
	if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
	return "<" .. t .. ">"
end

local function line(label, v)
	local status, readable = statusOf(v)
	OA.print(string.format("  %-26s %s  (%s)", label, status, describe(v)))
	return readable
end

-- Which of Blizzard's restriction contexts are live? This is the switch that flips
-- most of the secret predicates, so it explains every other row in the report.
local function reportRestrictions()
	OA.print("|cffffcc00-- Active restrictions --|r")
	local api = _G.C_RestrictedActions
	if not (api and api.IsAddOnRestrictionActive and Enum and Enum.AddOnRestrictionType) then
		OA.print("  C_RestrictedActions unavailable on this build")
		return
	end
	local names = { "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }
	for _, name in ipairs(names) do
		local enumVal = Enum.AddOnRestrictionType[name]
		if enumVal ~= nil then
			local ok, active = pcall(api.IsAddOnRestrictionActive, enumVal)
			local shown = "?"
			if ok then
				local b, known = OA.readBool(active)
				if known then shown = b and "|cffff5555ACTIVE|r" or "inactive" end
			end
			OA.print(string.format("  %-26s %s", name, shown))
		end
	end
end

local function reportResources()
	OA.print("|cffffcc00-- Resources --|r")
	local energyType = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3
	local cpType = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4

	line("UnitPower Energy", UnitPower("player", energyType))
	line("UnitPowerMax Energy", UnitPowerMax("player", energyType))
	line("UnitPower ComboPoints", UnitPower("player", cpType))
	line("UnitPowerMax ComboPoints", UnitPowerMax("player", cpType))

	if _G.C_Secrets and _G.C_Secrets.ShouldUnitPowerBeSecret then
		local ok, res = pcall(_G.C_Secrets.ShouldUnitPowerBeSecret, "player")
		OA.print("  C_Secrets.ShouldUnitPowerBeSecret('player') = " ..
			(ok and describe(res) or "call failed"))
	end

	-- What the shadow model is currently reporting, and how far it has drifted.
	if OA.Energy then
		local val, usable, conf = OA.Energy.Get()
		OA.print(string.format("  |cff88ccffshadow energy|r          %s  (confidence=%s, drift=%.1fs)",
			usable and string.format("%.0f", val) or "unusable",
			tostring(conf), OA.Energy.driftSeconds or 0))
	end
end

local function reportCooldowns()
	OA.print("|cffffcc00-- Cooldowns --|r")
	local probes = { "adrenalineRush", "bladeRush", "betweenTheEyes", "rollTheBones" }
	for _, key in ipairs(probes) do
		local spellID = OA.SpellIDs and OA.SpellIDs[key]
		if spellID and C_Spell and C_Spell.GetSpellCooldown then
			local ok, cd = pcall(C_Spell.GetSpellCooldown, spellID)
			if ok and type(cd) == "table" then
				local stStatus = select(1, statusOf(cd.startTime))
				local enStatus = select(1, statusOf(cd.isEnabled))
				local acStatus = select(1, statusOf(cd.isActive))
				OA.print(string.format("  %-18s start=%s enabled=%s active=%s",
					key, stStatus, enStatus, acStatus))
			else
				OA.print(string.format("  %-18s call failed", key))
			end
		end
	end

	if _G.C_Secrets and _G.C_Secrets.GetSpellCooldownSecrecy and OA.SpellIDs then
		local id = OA.SpellIDs.adrenalineRush
		local ok, level = pcall(_G.C_Secrets.GetSpellCooldownSecrecy, id)
		if ok then
			OA.print("  GetSpellCooldownSecrecy(AR) = " .. describe(level) ..
				"  (0=Never 1=Always 2=Contextual)")
		end
	end

	OA.print("|cffffcc00-- Trinkets (expected never-secret) --|r")
	for slot = 13, 14 do
		local itemID = GetInventoryItemID("player", slot)
		if itemID then
			local getCD = (C_Item and C_Item.GetItemCooldown) or _G.GetItemCooldown
			if getCD then
				local ok, start = pcall(getCD, itemID)
				line("slot " .. slot .. " cooldown", ok and start or nil)
			end
		else
			OA.print("  slot " .. slot .. ": empty")
		end
	end
end

local function reportAuras()
	OA.print("|cffffcc00-- Auras --|r")
	local api = C_UnitAuras
	if not api then OA.print("  C_UnitAuras absent") return end

	local byID = api.GetPlayerAuraBySpellID or api.GetAuraDataBySpellID
	if byID and OA.SpellIDs then
		local ok, aura = pcall(byID, "player", OA.SpellIDs.rollTheBones)
		if not ok then
			OA.print("  GetPlayerAuraBySpellID(RtB) |cffff5555THREW|r (aura access restricted)")
		elseif aura == nil then
			OA.print("  GetPlayerAuraBySpellID(RtB) returned nothing (not up, or secret spell)")
		else
			line("RtB .applications", aura.applications)
			line("RtB .expirationTime", aura.expirationTime)
			line("RtB .spellId", aura.spellId)
		end
	else
		OA.print("  no query-by-spellID function on this build")
	end

	-- The index path is documented to ERROR (not merely return secrets) while auras are
	-- restricted, which is why the tracker only ever calls it out of combat.
	if api.GetAuraDataByIndex then
		local ok = pcall(api.GetAuraDataByIndex, "player", 1, "HELPFUL")
		OA.print("  GetAuraDataByIndex path: " ..
			(ok and "|cff55ff55callable|r" or "|cffff5555THROWS|r (restricted)"))
	end

	OA.print("  tracker aura state: " ..
		((OA.State and OA.State.buffs and OA.State.buffs.degraded) and
			"|cffff5555degraded|r" or "|cff55ff55tracking|r"))
end

local function reportMisc()
	OA.print("|cffffcc00-- Always-readable expectations --|r")
	if _G.IsStealthed then line("IsStealthed()", _G.IsStealthed()) end
	line("GetTime()", GetTime())

	OA.print("|cffffcc00-- Enemy counting --|r")
	local np = _G.C_NamePlate
	if np and np.GetNamePlates then
		local ok, plates = pcall(np.GetNamePlates)
		if ok and type(plates) == "table" then
			OA.print("  nameplates visible: " .. tostring(#plates))
			for _, plate in ipairs(plates) do
				local token = plate.namePlateUnitToken
					or (plate.UnitFrame and plate.UnitFrame.unit)
				if token then
					local ok2, threat = pcall(UnitThreatSituation, "player", token)
					line("UnitThreatSituation", ok2 and threat or nil)
					break
				end
			end
		else
			OA.print("  GetNamePlates failed")
		end
	end
	OA.print("  tracker enemyCount: " ..
		tostring(OA.State and OA.State.enemyCount or "nil"))

	OA.print("|cffffcc00-- Assisted Combat substrate --|r")
	if not _G.C_AssistedCombat then
		OA.print("  |cffff5555C_AssistedCombat ABSENT|r")
		return
	end
	if C_AssistedCombat.IsAvailable then
		local ok, avail = pcall(C_AssistedCombat.IsAvailable)
		line("IsAvailable()", ok and avail or nil)
	end
	if C_AssistedCombat.GetNextCastSpell then
		local ok, id = pcall(C_AssistedCombat.GetNextCastSpell, false)
		line("GetNextCastSpell()", ok and id or nil)
	end
	OA.print("  assist pick tracked: " .. tostring(OA.Assist and OA.Assist.nextSpellID or "nil"))
end

function OA.Secrets.Report()
	OA.print("=== SECRET-VALUE AUDIT ===")
	OA.print("Context: " ..
		((OA.State and OA.State.inCombat) and "|cffff5555IN COMBAT|r" or "out of combat"))
	if _G.GetInstanceInfo then
		local ok, name, instType, diffID, diffName = pcall(_G.GetInstanceInfo)
		if ok then
			OA.print("Instance: " .. describe(name) ..
				" type=" .. describe(instType) .. " difficulty=" .. describe(diffName))
		end
	end
	OA.print("issecretvalue available: " ..
		(type(_G.issecretvalue) == "function" and "yes" or "|cffff5555NO|r"))

	reportRestrictions()
	reportResources()
	reportCooldowns()
	reportAuras()
	reportMisc()

	OA.print("=== END AUDIT ===")
	OA.print("Run this out of combat, on a dummy, and mid-pull in a keystone, then compare.")
end

OA.RegisterSlash("secrets", function() OA.safe(OA.Secrets.Report) end,
	"Audit which combat values are readable vs secret right now.")
