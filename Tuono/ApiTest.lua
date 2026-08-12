local ADDON_NAME, Tuono = ...

local function apitest()
  local passed = 0
  local total = 0

  -- Print client info at the top
  local okHeader, headerMsg = pcall(function()
    local v, b, d, t = GetBuildInfo()
    return "Client: " .. tostring(v) .. " build " .. tostring(b) .. " interface " .. tostring(t)
  end)
  Tuono.print(okHeader and headerMsg or "Client: unavailable (values restricted)")

  local function test(name, fn)
    total = total + 1
    local ok, result = pcall(fn)
    if ok then
      Tuono.print("PASS: " .. name .. " (" .. type(result) .. ")")
      passed = passed + 1
    else
      Tuono.print("FAIL: " .. name .. " - " .. tostring(result))
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
      Tuono.print("  -> party1 exists, health = " .. tostring(health))
      return health
    else
      Tuono.print("  -> SKIP: no party member at party1")
      return "SKIP"
    end
  end)

  test("Blade Flurry in GetRotationSpells", function()
    if not C_AssistedCombat or not C_AssistedCombat.GetRotationSpells then
      error("C_AssistedCombat.GetRotationSpells not found")
    end
    local spells = C_AssistedCombat.GetRotationSpells()
    if not spells then error("GetRotationSpells returned nil") end

    local bladeFlurrySpellID = Tuono.SpellIDs and Tuono.SpellIDs.bladeFlurry
    if not bladeFlurrySpellID then
      error("Tuono.SpellIDs.bladeFlurry not defined")
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
    Tuono.print("  -> LIVENESS: run /tuono apitest on single dummy, then mid multi-target pull - compare lists (esp. Blade Flurry 13877)")
    return table.concat(ids, ",")
  end)

  Tuono.print(passed .. "/" .. total .. " PASS - paste this output into a GitHub issue if anything FAILs (SKIPs are OK)")
end

local function debug()
  local db = Tuono.db or {}
  Tuono.print("=== Debug Dump ===")
  if Tuono.State then
    Tuono.print("Energy: " .. (Tuono.State.energy or 0) .. "/" .. (Tuono.State.energyMax or 0))
    Tuono.print("ComboPoints: " .. (Tuono.State.comboPoints or 0) .. "/" .. (Tuono.State.comboPointsMax or 0))
    if Tuono.State.buffs and Tuono.State.buffs.rtb then
      Tuono.print("RtB Stage: " .. (Tuono.State.buffs.rtb.stage or 0))
    end
    if Tuono.State.cooldowns then
      local function cdState(name, cd)
        local state = "unknown"
        if cd.known then
          state = cd.ready and "ready" or ("CD: " .. string.format("%.1f", cd.remaining) .. "s")
        end
        return name .. ": " .. state
      end
      Tuono.print(cdState("AR", Tuono.State.cooldowns.adrenalineRush))
      Tuono.print(cdState("BladeRush", Tuono.State.cooldowns.bladeRush))
      Tuono.print(cdState("Prep", Tuono.State.cooldowns.preparation))
    end
    if Tuono.State.trinkets then
      Tuono.print("Trinket 13: " .. tostring(Tuono.State.trinkets[13] and Tuono.State.trinkets[13].ready and "ready" or ("CD: " .. string.format("%.1f", Tuono.State.trinkets[13].remaining) .. "s")))
      Tuono.print("Trinket 14: " .. tostring(Tuono.State.trinkets[14] and Tuono.State.trinkets[14].ready and "ready" or ("CD: " .. string.format("%.1f", Tuono.State.trinkets[14].remaining) .. "s")))
    end
  end
  if Tuono.Assist then
    Tuono.print("Assist NextSpellID: " .. (Tuono.Assist.nextSpellID or "none"))
    Tuono.print("Assist Queue Length: " .. (Tuono.Assist.queue and #Tuono.Assist.queue or 0))
  end

  -- KEYBIND & TALENT DIAGNOSTICS
  Tuono.print("=== Keybind & Talent Diagnostics ===")
  if Tuono.State and Tuono.State.knownSpells then
    Tuono.print("Known Spells API: " .. (Tuono.State.knownUnavailable and "unavailable (fail-open)" or "available"))
  end

  if Tuono.Engine then
    local result = Tuono.safe(function() return Tuono.Engine.Evaluate() end)
    if result and result.queue then
      for i, entry in ipairs(result.queue) do
        if entry.spellID then
          -- Check if spell is known
          local knownStatus = "unknown"
          if Tuono.State and Tuono.State.knownUnavailable then
            knownStatus = "unavailable"
          elseif Tuono.State and Tuono.State.knownSpells then
            knownStatus = Tuono.State.knownSpells[entry.spellID] and "known" or "unknown"
          end

          -- Check cooldown status
          local cdStatus = "none"
          if entry.kind == "cooldown" and entry.spellID then
            local cd = Tuono.State.cooldowns[entry.spellID == Tuono.SpellIDs.adrenalineRush and "adrenalineRush" or
                                        entry.spellID == Tuono.SpellIDs.bladeRush and "bladeRush" or
                                        entry.spellID == Tuono.SpellIDs.preparation and "preparation" or nil]
            if cd then
              if not cd.known then
                cdStatus = "unknown"
              elseif cd.ready then
                cdStatus = "ready"
              else
                cdStatus = string.format("%.1f", cd.remaining) .. "s"
              end
            end
          end

          -- Try to resolve keybind
          local keytext = nil
          if C_ActionBar and C_ActionBar.FindSpellActionButtons then
            local ok, buttons = pcall(function() return C_ActionBar.FindSpellActionButtons(entry.spellID) end)
            if ok and buttons and #buttons > 0 then
              local slot = buttons[1]
              local bindingName = nil
              if slot >= 1 and slot <= 12 then
                bindingName = "ACTIONBUTTON" .. slot
              elseif slot >= 61 and slot <= 72 then
                bindingName = "MULTIACTIONBAR1BUTTON" .. (slot - 60)
              elseif slot >= 73 and slot <= 84 then
                bindingName = "MULTIACTIONBAR2BUTTON" .. (slot - 72)
              elseif slot >= 85 and slot <= 96 then
                bindingName = "MULTIACTIONBAR3BUTTON" .. (slot - 84)
              elseif slot >= 97 and slot <= 108 then
                bindingName = "MULTIACTIONBAR4BUTTON" .. (slot - 96)
              end
              if bindingName and GetBindingKey then
                keytext = GetBindingKey(bindingName)
              end
              Tuono.print("  [" .. i .. "] spellID=" .. entry.spellID .. " known=" .. knownStatus .. " cd=" .. cdStatus .. " key=" .. (keytext or "unbound"))
            else
              Tuono.print("  [" .. i .. "] spellID=" .. entry.spellID .. " known=" .. knownStatus .. " cd=" .. cdStatus .. " (keybind resolution failed)")
            end
          else
            Tuono.print("  [" .. i .. "] spellID=" .. entry.spellID .. " known=" .. knownStatus .. " cd=" .. cdStatus)
          end
        elseif entry.itemSlot then
          Tuono.print("  [" .. i .. "] trinket slot=" .. entry.itemSlot)
        end
      end
    end
  end

  if Tuono.errorCount and Tuono.errorCount > 0 then
    Tuono.print("Errors since load: " .. Tuono.errorCount)
  end
end

local watchState = nil

local function watch()
  if watchState and watchState.active then
    Tuono.print("Watch already running - wait for current run to finish or restart WoW")
    return
  end

  watchState = {
    active = true,
    startTime = GetTime(),
    endTime = GetTime() + 15,
    samples = {},
    rotationSnapshots = {},
    sampleCount = 0,
    lastSampleTime = GetTime() - 0.25
  }

  -- Wrap Assist.Update to collect samples
  local originalUpdate = Tuono.Assist.Update
  function Tuono.Assist.Update()
    originalUpdate()

    local now = GetTime()
    if not watchState.active then return end

    -- Sample every 0.25s
    if (now - watchState.lastSampleTime) >= 0.25 then
      watchState.lastSampleTime = now
      watchState.sampleCount = watchState.sampleCount + 1

      -- Record nextSpellID
      table.insert(watchState.samples, Tuono.Assist.nextSpellID or 0)

      -- Record rotation list snapshot
      local rotationSpells = Tuono.safe(function()
        return C_AssistedCombat and C_AssistedCombat.GetRotationSpells() or {}
      end) or {}
      local snapshot = {}
      for _, entry in ipairs(rotationSpells) do
        local spellID = nil
        if type(entry) == "number" then
          spellID = entry
        elseif type(entry) == "table" and entry.spellID then
          spellID = entry.spellID
        end
        if spellID then
          table.insert(snapshot, spellID)
        end
      end
      table.insert(watchState.rotationSnapshots, snapshot)
    end

    if now >= watchState.endTime then
      watchState.active = false

      -- Restore original Update
      Tuono.Assist.Update = originalUpdate

      -- Analyze results
      local samples = watchState.samples
      local rotationSnapshots = watchState.rotationSnapshots

      -- Count distinct nextSpellID values
      local distinctSet = {}
      local changeCount = 0
      local prevSpellID = samples[1]
      for i, spellID in ipairs(samples) do
        distinctSet[spellID] = true
        if spellID ~= prevSpellID then
          changeCount = changeCount + 1
          prevSpellID = spellID
        end
      end
      local distinctCount = 0
      for _ in pairs(distinctSet) do
        distinctCount = distinctCount + 1
      end

      -- Check if rotation list changed
      local rotationChanged = false
      if #rotationSnapshots > 1 then
        local first = rotationSnapshots[1]
        for i = 2, #rotationSnapshots do
          local curr = rotationSnapshots[i]
          if #curr ~= #first then
            rotationChanged = true
            break
          end
          for j = 1, #first do
            if curr[j] ~= first[j] then
              rotationChanged = true
              break
            end
          end
          if rotationChanged then break end
        end
      end

      Tuono.print("=== /tuono watch results (15 second sample) ===")
      Tuono.print("Distinct nextSpellID values: " .. distinctCount)
      Tuono.print("Position 1 changes: " .. changeCount)
      Tuono.print("Rotation list changed: " .. (rotationChanged and "YES (list is live)" or "NO (list is static)"))
      Tuono.print("Samples collected: " .. watchState.sampleCount)
      Tuono.print("Last change timestamp: " .. string.format("%.2f", Tuono.Assist.lastChangeAt or 0))
      Tuono.print("Paste this output if queue appears frozen in combat")

      watchState = nil
    end
  end

  Tuono.print("Watch started - sampling queue liveness for 15 seconds")
  Tuono.print("Run this during combat or while casting off-rotation for best results")
end

-- === Proc Observability Probe ===
local procProbeState = nil

local function procProbe()
  if procProbeState and procProbeState.active then
    Tuono.print("Proc probe already running - wait for current run to finish or restart WoW")
    return
  end

  procProbeState = {
    active = true,
    startTime = GetTime(),
    endTime = GetTime() + 15,
    auras = {},
    deltaEvents = 0,
    deltaFullUpdate = 0,
    sampleCount = 0,
    lastSampleTime = GetTime() - 0.25,
    -- Accessor tracking
    accessors = {
      getNextSpellFalse = { values = {}, lastValue = nil, changes = 0, lastChangeTime = 0 },
      getNextSpellTrue = { values = {}, lastValue = nil, changes = 0, lastChangeTime = 0 },
      getActionSpells = { values = {}, lastValue = nil, changes = 0, lastChangeTime = 0 },
      actionBarFuncs = {}
    },
    assistedEvents = 0,
    procTimes = {}
  }

  -- Initialize aura tracking
  local auraList = {
    { name = "opportunity", spellID = 195627 },
    -- Audacity: talent-based proc, spell ID not found in docs; skipping per task instruction
    { name = "adrenalineRush", spellID = 13750 },
    { name = "rollTheBones", spellID = 315508 },
    { name = "stealth", spellID = 1784 }
  }

  for _, aura in ipairs(auraList) do
    procProbeState.auras[aura.name] = {
      spellID = aura.spellID,
      queryWorks = false,
      fieldsReadable = 0,
      fieldsSecret = 0,
      fieldsMixed = false,
      deltaAddedCount = 0,
      deltaRemovedCount = 0,
      deltaAddedReadable = 0,
      deltaAddedSecret = 0,
      lastProc = 0
    }
  end

  -- Install probe UNIT_AURA interceptor to track proc timing
  local function probeUnitAuraHandler(event, unit, updateInfo)
    if not procProbeState.active or unit ~= "player" then return end

    if updateInfo then
      -- `if updateInfo.isFullUpdate then` is a BOOLEAN TEST ON A SECRET and raises. This
      -- is the exact line, in the pre-rename copy of this file, that the live client is
      -- still throwing from -- StateTracker had the same bug and was fixed; the proc probe
      -- kept its own unguarded copy because it is only reachable from /tuono probe.
      -- Reading the field is safe; testing its truth is not.
      local okFull, full = pcall(function() return updateInfo.isFullUpdate end)
      if okFull and full ~= nil and not Tuono.isSecret(full) and full == true then
        procProbeState.deltaFullUpdate = procProbeState.deltaFullUpdate + 1
      end

      if updateInfo.addedAuras then
        for _, auraData in ipairs(updateInfo.addedAuras) do
          for _, aura in ipairs(auraList) do
            if auraData.spellId == aura.spellID then
              procProbeState.auras[aura.name].deltaAddedCount = procProbeState.auras[aura.name].deltaAddedCount + 1
              procProbeState.auras[aura.name].lastProc = GetTime()
              if issecretvalue(auraData.spellId) then
                procProbeState.auras[aura.name].deltaAddedSecret = procProbeState.auras[aura.name].deltaAddedSecret + 1
              else
                procProbeState.auras[aura.name].deltaAddedReadable = procProbeState.auras[aura.name].deltaAddedReadable + 1
              end
              table.insert(procProbeState.procTimes, GetTime())
              break
            end
          end
        end
        procProbeState.deltaEvents = procProbeState.deltaEvents + 1
      end

      if updateInfo.removedAuraInstanceIDs then
        procProbeState.deltaEvents = procProbeState.deltaEvents + 1
      end
    end
  end

  if not Tuono.eventHandlers then Tuono.eventHandlers = {} end
  if not Tuono.eventHandlers["UNIT_AURA"] then Tuono.eventHandlers["UNIT_AURA"] = {} end
  table.insert(Tuono.eventHandlers["UNIT_AURA"], probeUnitAuraHandler)

  -- Track ASSISTED events
  local assistedEventHandler = function(event, ...)
    if procProbeState.active and event:find("ASSISTED") then
      procProbeState.assistedEvents = procProbeState.assistedEvents + 1
    end
  end
  if not Tuono.eventHandlers["ASSISTED_COMBAT_ACTION_CHANGED"] then
    Tuono.eventHandlers["ASSISTED_COMBAT_ACTION_CHANGED"] = {}
  end
  table.insert(Tuono.eventHandlers["ASSISTED_COMBAT_ACTION_CHANGED"], assistedEventHandler)

  -- Enumerate available API functions
  local assistedFuncs = {}
  if C_AssistedCombat then
    for k in pairs(C_AssistedCombat) do
      table.insert(assistedFuncs, k)
    end
  end
  local actionBarFuncs = {}
  if C_ActionBar then
    for k in pairs(C_ActionBar) do
      if type(k) == "string" and k:find("Assisted", 1, true) then
        table.insert(actionBarFuncs, k)
      end
    end
  end

  -- Wrap Assist.Update to collect samples
  local originalUpdate = Tuono.Assist.Update
  function Tuono.Assist.Update()
    originalUpdate()

    local now = GetTime()
    if not procProbeState.active then return end

    -- Sample every 0.25s
    if (now - procProbeState.lastSampleTime) >= 0.25 then
      procProbeState.lastSampleTime = now
      procProbeState.sampleCount = procProbeState.sampleCount + 1

      -- Sample accessors
      pcall(function()
        local v1 = C_AssistedCombat and C_AssistedCombat.GetNextCastSpell(false) or nil
        if v1 and v1 ~= procProbeState.accessors.getNextSpellFalse.lastValue then
          procProbeState.accessors.getNextSpellFalse.changes = procProbeState.accessors.getNextSpellFalse.changes + 1
          procProbeState.accessors.getNextSpellFalse.lastChangeTime = now
        end
        procProbeState.accessors.getNextSpellFalse.lastValue = v1
        procProbeState.accessors.getNextSpellFalse.values[v1 or 0] = true
      end)

      pcall(function()
        local v2 = C_AssistedCombat and C_AssistedCombat.GetNextCastSpell(true) or nil
        if v2 and v2 ~= procProbeState.accessors.getNextSpellTrue.lastValue then
          procProbeState.accessors.getNextSpellTrue.changes = procProbeState.accessors.getNextSpellTrue.changes + 1
          procProbeState.accessors.getNextSpellTrue.lastChangeTime = now
        end
        procProbeState.accessors.getNextSpellTrue.lastValue = v2
        procProbeState.accessors.getNextSpellTrue.values[v2 or 0] = true
      end)

      -- Sample GetActionSpell across slots
      pcall(function()
        local actionVals = {}
        for slot = 1, 12 do
          local v = C_AssistedCombat and C_AssistedCombat.GetActionSpell(slot) or nil
          if v then
            actionVals[slot] = v
          end
        end
        local actionStr = ""
        for slot = 1, 12 do
          if actionVals[slot] then
            actionStr = actionStr .. slot .. ":" .. actionVals[slot] .. ";"
          end
        end
        if actionStr ~= procProbeState.accessors.getActionSpells.lastValue then
          procProbeState.accessors.getActionSpells.changes = procProbeState.accessors.getActionSpells.changes + 1
          procProbeState.accessors.getActionSpells.lastChangeTime = now
        end
        procProbeState.accessors.getActionSpells.lastValue = actionStr
        if actionStr ~= "" then
          procProbeState.accessors.getActionSpells.values[actionStr] = true
        end
      end)

      -- Query each aura by spell ID
      for _, aura in ipairs(auraList) do
        pcall(function()
          local auraData = nil
          -- GetPlayerAuraBySpellID takes ONE arg (player is implied); only
          -- GetAuraDataBySpellID takes a unit. Passing "player" to the former put a
          -- string in the spellID slot and returned nil for every aura.
          if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
            auraData = C_UnitAuras.GetPlayerAuraBySpellID(aura.spellID)
          end
          if not auraData and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID then
            auraData = C_UnitAuras.GetAuraDataBySpellID("player", aura.spellID)
          end

          if auraData then
            procProbeState.auras[aura.name].queryWorks = true

            -- Check field readability
            local readableCount = 0
            local secretCount = 0
            if auraData.spellId and not issecretvalue(auraData.spellId) then
              readableCount = readableCount + 1
            elseif auraData.spellId and issecretvalue(auraData.spellId) then
              secretCount = secretCount + 1
            end

            if auraData.name and not issecretvalue(auraData.name) then
              readableCount = readableCount + 1
            elseif auraData.name and issecretvalue(auraData.name) then
              secretCount = secretCount + 1
            end

            if auraData.expirationTime and not issecretvalue(auraData.expirationTime) then
              readableCount = readableCount + 1
            elseif auraData.expirationTime and issecretvalue(auraData.expirationTime) then
              secretCount = secretCount + 1
            end

            if auraData.applications and not issecretvalue(auraData.applications) then
              readableCount = readableCount + 1
            elseif auraData.applications and issecretvalue(auraData.applications) then
              secretCount = secretCount + 1
            end

            procProbeState.auras[aura.name].fieldsReadable = math.max(procProbeState.auras[aura.name].fieldsReadable, readableCount)
            procProbeState.auras[aura.name].fieldsSecret = math.max(procProbeState.auras[aura.name].fieldsSecret, secretCount)
            if readableCount > 0 and secretCount > 0 then
              procProbeState.auras[aura.name].fieldsMixed = true
            end
          end
        end)
      end
    end

    if now >= procProbeState.endTime then
      procProbeState.active = false

      -- Restore original Update and handlers
      Tuono.Assist.Update = originalUpdate
      if Tuono.eventHandlers and Tuono.eventHandlers["UNIT_AURA"] then
        for i = #Tuono.eventHandlers["UNIT_AURA"], 1, -1 do
          if Tuono.eventHandlers["UNIT_AURA"][i] == probeUnitAuraHandler then
            table.remove(Tuono.eventHandlers["UNIT_AURA"], i)
          end
        end
      end
      if Tuono.eventHandlers and Tuono.eventHandlers["ASSISTED_COMBAT_ACTION_CHANGED"] then
        for i = #Tuono.eventHandlers["ASSISTED_COMBAT_ACTION_CHANGED"], 1, -1 do
          if Tuono.eventHandlers["ASSISTED_COMBAT_ACTION_CHANGED"][i] == assistedEventHandler then
            table.remove(Tuono.eventHandlers["ASSISTED_COMBAT_ACTION_CHANGED"], i)
          end
        end
      end

      -- Report results
      Tuono.print("=== /tuono watch proc-observability probe (15 second sample) ===")
      Tuono.print("")

      -- Aura observability section
      local verdict = "NONE"
      local directWorks = false
      local deltaWorks = false

      for _, aura in ipairs(auraList) do
        local auraState = procProbeState.auras[aura.name]
        local observable = auraState.queryWorks and "yes" or "no"
        local fields = "unknown"
        if auraState.fieldsReadable > 0 and auraState.fieldsSecret == 0 then
          fields = "readable"
          if auraState.queryWorks then directWorks = true end
        elseif auraState.fieldsSecret > 0 and auraState.fieldsReadable == 0 then
          fields = "secret"
        elseif auraState.fieldsReadable > 0 and auraState.fieldsSecret > 0 then
          fields = "mixed"
        end

        Tuono.print(string.format("%s: observable=%s, fields=%s, delta_added=%d(readable=%d,secret=%d)",
          aura.name, observable, fields,
          auraState.deltaAddedCount, auraState.deltaAddedReadable, auraState.deltaAddedSecret))

        if auraState.deltaAddedCount > 0 or auraState.deltaAddedReadable > 0 or auraState.deltaAddedSecret > 0 then
          deltaWorks = true
        end
      end

      Tuono.print("")
      Tuono.print(string.format("Delta events: total=%d, fullUpdate=%d", procProbeState.deltaEvents, procProbeState.deltaFullUpdate))

      if directWorks then
        verdict = "DIRECT"
      elseif deltaWorks then
        verdict = "DELTA-ONLY"
      end

      Tuono.print("PROC OBSERVABILITY: " .. verdict)

      -- Accessor liveness section
      Tuono.print("")
      Tuono.print("=== Accessor Liveness ===")

      local distinctFalse = 0
      for _ in pairs(procProbeState.accessors.getNextSpellFalse.values) do
        distinctFalse = distinctFalse + 1
      end
      Tuono.print(string.format("GetNextCastSpell(false): distinct=%d, changes=%d", distinctFalse, procProbeState.accessors.getNextSpellFalse.changes))

      local distinctTrue = 0
      for _ in pairs(procProbeState.accessors.getNextSpellTrue.values) do
        distinctTrue = distinctTrue + 1
      end
      Tuono.print(string.format("GetNextCastSpell(true): distinct=%d, changes=%d", distinctTrue, procProbeState.accessors.getNextSpellTrue.changes))

      local distinctActions = 0
      for _ in pairs(procProbeState.accessors.getActionSpells.values) do
        distinctActions = distinctActions + 1
      end
      Tuono.print(string.format("GetActionSpell(...): distinct=%d, changes=%d", distinctActions, procProbeState.accessors.getActionSpells.changes))

      -- API inventory
      Tuono.print("")
      Tuono.print("C_AssistedCombat functions: " .. table.concat(assistedFuncs, ", "))
      if #actionBarFuncs > 0 then
        Tuono.print("C_ActionBar Assisted-related functions: " .. table.concat(actionBarFuncs, ", "))
      else
        Tuono.print("C_ActionBar Assisted-related functions: (none found)")
      end
      Tuono.print("ASSISTED-prefixed events: " .. procProbeState.assistedEvents)

      -- Determine best accessor
      local liveAccessor = "NONE"
      if procProbeState.accessors.getNextSpellTrue.changes > procProbeState.accessors.getNextSpellFalse.changes then
        liveAccessor = "GetNextCastSpell(true)"
      elseif procProbeState.accessors.getNextSpellFalse.changes > 0 then
        liveAccessor = "GetNextCastSpell(false)"
      end
      if procProbeState.accessors.getActionSpells.changes > 0 and procProbeState.accessors.getActionSpells.changes > (procProbeState.accessors.getNextSpellTrue.changes or 0) then
        liveAccessor = "GetActionSpell(...)"
      end

      Tuono.print("")
      Tuono.print("LIVE ACCESSOR: " .. liveAccessor)
      Tuono.print("Paste this output to Claude")

      procProbeState = nil
    end
  end

  Tuono.print("Proc probe started - sampling aura observability and accessor liveness for 15 seconds")
  Tuono.print("Run this during active combat with proc-triggering actions for best results")
end

Tuono.RegisterSlash("apitest", apitest, "Run API compatibility probe")
Tuono.RegisterSlash("debug", debug, "Print one-shot state dump")
Tuono.RegisterSlash("watch", watch, "Sample queue liveness for 15s; run during combat when queue frozen")
Tuono.RegisterSlash("probe", procProbe, "Sample proc observability for 15s; run during combat")
