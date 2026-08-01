local ADDON_NAME, OA = ...

local function apitest()
  local passed = 0
  local total = 0

  -- Print client info at the top
  local okHeader, headerMsg = pcall(function()
    local v, b, d, t = GetBuildInfo()
    return "Client: " .. tostring(v) .. " build " .. tostring(b) .. " interface " .. tostring(t)
  end)
  OA.print(okHeader and headerMsg or "Client: unavailable (values restricted)")

  local function test(name, fn)
    total = total + 1
    local ok, result = pcall(fn)
    if ok then
      OA.print("PASS: " .. name .. " (" .. type(result) .. ")")
      passed = passed + 1
    else
      OA.print("FAIL: " .. name .. " - " .. tostring(result))
    end
  end

  test("C_AssistedCombat", function()
    if not C_AssistedCombat then error("C_AssistedCombat not found") end
    return C_AssistedCombat
  end)

  test("C_AssistedCombat.IsAvailable", function()
    if not C_AssistedCombat or not C_AssistedCombat.IsAvailable then
      error("C_AssistedCombat.IsAvailable not found")
    end
    return C_AssistedCombat.IsAvailable
  end)

  test("C_AssistedCombat.GetNextCastSpell", function()
    if not C_AssistedCombat or not C_AssistedCombat.GetNextCastSpell then
      error("C_AssistedCombat.GetNextCastSpell not found")
    end
    return C_AssistedCombat.GetNextCastSpell
  end)

  test("C_AssistedCombat.GetRotationSpells", function()
    if not C_AssistedCombat or not C_AssistedCombat.GetRotationSpells then
      error("C_AssistedCombat.GetRotationSpells not found")
    end
    return C_AssistedCombat.GetRotationSpells
  end)

  test("C_AssistedCombat.GetActionSpell", function()
    if not C_AssistedCombat or not C_AssistedCombat.GetActionSpell then
      error("C_AssistedCombat.GetActionSpell not found")
    end
    return C_AssistedCombat.GetActionSpell
  end)

  test("UnitPower (Energy)", function()
    local energy = UnitPower("player", 3)
    return energy
  end)

  test("UnitPower (ComboPoints)", function()
    local cp = UnitPower("player", 4)
    return cp
  end)

  test("C_UnitAuras.GetAuraDataByIndex", function()
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then
      error("C_UnitAuras.GetAuraDataByIndex not found")
    end
    return C_UnitAuras.GetAuraDataByIndex
  end)

  test("UnitBuff (fallback)", function()
    if UnitBuff == nil then
      error("SKIP: legacy UnitBuff absent/nonfunctional (OK - modern C_UnitAuras path in use)")
    end
    local ok, buff = pcall(UnitBuff, "player", 1)
    if not ok then
      error("SKIP: legacy UnitBuff absent/nonfunctional (OK - modern C_UnitAuras path in use)")
    end
    -- Only fail if BOTH UnitBuff fails AND C_UnitAuras is missing
    if buff == nil and (not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex) then
      error("UnitBuff returned nil and C_UnitAuras unavailable")
    end
    return buff
  end)

  test("C_Spell.GetSpellCooldown", function()
    if not C_Spell or not C_Spell.GetSpellCooldown then
      error("C_Spell.GetSpellCooldown not found")
    end
    local result = C_Spell.GetSpellCooldown(13750)
    return result
  end)

  test("GetInventoryItemID (slot 13)", function()
    local itemID = GetInventoryItemID("player", 13)
    return itemID
  end)

  test("GetInventoryItemID (slot 14)", function()
    local itemID = GetInventoryItemID("player", 14)
    return itemID
  end)

  test("C_Item.GetItemCooldown", function()
    if not C_Item or not C_Item.GetItemCooldown then
      error("C_Item.GetItemCooldown not found")
    end
    return C_Item.GetItemCooldown
  end)

  test("GetSpecialization", function()
    local spec = GetSpecialization()
    return spec
  end)

  test("UnitHealth (player)", function()
    local health = UnitHealth("player")
    return health
  end)

  test("UnitHealthMax (player)", function()
    local maxHealth = UnitHealthMax("player")
    return maxHealth
  end)

  test("UnitHealth (party1)", function()
    if UnitExists("party1") then
      local health = UnitHealth("party1")
      OA.print("  -> party1 exists, health = " .. tostring(health))
      return health
    else
      OA.print("  -> SKIP: no party member at party1")
      return "SKIP"
    end
  end)

  test("Blade Flurry in GetRotationSpells", function()
    if not C_AssistedCombat or not C_AssistedCombat.GetRotationSpells then
      error("C_AssistedCombat.GetRotationSpells not found")
    end
    local spells = C_AssistedCombat.GetRotationSpells()
    if not spells then error("GetRotationSpells returned nil") end

    local bladeFlurrySpellID = OA.SpellIDs and OA.SpellIDs.bladeFlurry
    if not bladeFlurrySpellID then
      error("OA.SpellIDs.bladeFlurry not defined")
    end

    local found = false
    for _, entry in ipairs(spells) do
      local id = nil
      if type(entry) == "number" then
        id = entry
      elseif type(entry) == "table" and entry.spellID then
        id = entry.spellID
      end
      if id == bladeFlurrySpellID then
        found = true
        break
      end
    end

    if found then
      return "Blade Flurry found in queue"
    else
      return "Blade Flurry NOT in current queue"
    end
  end)

  test("C_NamePlate.GetNamePlates", function()
    if not C_NamePlate or not C_NamePlate.GetNamePlates then
      error("C_NamePlate.GetNamePlates not found")
    end
    local namePlates = C_NamePlate.GetNamePlates()
    if not namePlates then return "nil" end
    local count = #namePlates
    if count == 0 then return "empty" end
    local np = namePlates[1]
    local token = np.namePlateUnitToken or "nameplate1"
    local uf_str = tostring(np.UnitFrame or "nil")
    local exists_str = tostring(UnitExists(token) or "nil")
    local canAttack_str = tostring(UnitCanAttack("player", token) or "nil")
    local inCombat_str = tostring(UnitAffectingCombat(token) or "nil")
    local hasSecret = uf_str:find("SECRET") or exists_str:find("SECRET") or canAttack_str:find("SECRET") or inCombat_str:find("SECRET")
    return "count=" .. count .. "|UnitFrame=" .. (hasSecret and "SECRET" or uf_str) .. "|Exists=" .. exists_str .. "|CanAttack=" .. canAttack_str .. "|InCombat=" .. inCombat_str
  end)

  test("UnitThreatSituation", function()
    if not UnitThreatSituation then error("not found") end
    local result = UnitThreatSituation("player", "nameplate1")
    local resultStr = tostring(result or "nil")
    return resultStr:find("SECRET") and "SECRET" or result
  end)

  test("IsEncounterInProgress + encounter context", function()
    if not IsEncounterInProgress then error("not found") end
    local inEnc = IsEncounterInProgress()
    local hasScenario = C_Scenario ~= nil
    local hasChallenge = C_ChallengeMode ~= nil and C_ChallengeMode.IsChallengeModeActive ~= nil
    return "InEncounter=" .. tostring(inEnc) .. "|Scenario=" .. tostring(hasScenario) .. "|ChallengeMode=" .. tostring(hasChallenge)
  end)

  test("GetRotationSpells LIVENESS", function()
    if not C_AssistedCombat or not C_AssistedCombat.GetRotationSpells then
      error("not found")
    end
    local spells1 = C_AssistedCombat.GetRotationSpells()
    local spells2 = C_AssistedCombat.GetRotationSpells()
    if not spells1 then return "nil" end
    local ids = {}
    for i = 1, math.min(10, #spells1) do
      local entry = spells1[i]
      local id = type(entry) == "number" and entry or (type(entry) == "table" and entry.spellID)
      if id then table.insert(ids, tostring(id)) end
    end
    OA.print("  -> LIVENESS: run /oa apitest on single dummy, then mid multi-target pull - compare lists (esp. Blade Flurry 13877)")
    return table.concat(ids, ",")
  end)

  OA.print(passed .. "/" .. total .. " PASS - paste this output into a GitHub issue if anything FAILs (SKIPs are OK)")
end

local function debug()
  local db = OA.db or {}
  OA.print("=== Debug Dump ===")
  if OA.State then
    OA.print("Energy: " .. (OA.State.energy or 0) .. "/" .. (OA.State.energyMax or 0))
    OA.print("ComboPoints: " .. (OA.State.comboPoints or 0) .. "/" .. (OA.State.comboPointsMax or 0))
    if OA.State.buffs and OA.State.buffs.rtb then
      OA.print("RtB Stage: " .. (OA.State.buffs.rtb.stage or 0))
    end
    if OA.State.cooldowns then
      OA.print("AR CD: " .. (OA.State.cooldowns.adrenalineRush and OA.State.cooldowns.adrenalineRush.remaining or "unknown"))
    end
    if OA.State.trinkets then
      OA.print("Trinket 13: " .. tostring(OA.State.trinkets[13] and "ready" or "cooldown"))
      OA.print("Trinket 14: " .. tostring(OA.State.trinkets[14] and "ready" or "cooldown"))
    end
  end
  if OA.Assist then
    OA.print("Assist NextSpellID: " .. (OA.Assist.nextSpellID or "none"))
    OA.print("Assist Queue Length: " .. (OA.Assist.queue and #OA.Assist.queue or 0))
  end
end

OA.RegisterSlash("apitest", apitest, "Run API compatibility probe")
OA.RegisterSlash("debug", debug, "Print one-shot state dump")
