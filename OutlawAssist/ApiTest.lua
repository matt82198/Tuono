local ADDON_NAME, OA = ...

local function apitest()
  local passed = 0
  local total = 0

  -- Print client info at the top
  local buildOk, version, build, date, toc = pcall(GetBuildInfo)
  if buildOk and version and build and toc then
    OA.print("Client: " .. tostring(version) .. " build " .. tostring(build) .. " interface " .. tostring(toc))
  else
    OA.print("Client: unavailable (restricted)")
  end

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
    for _, spellID in ipairs(spells) do
      if spellID == bladeFlurrySpellID then
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
