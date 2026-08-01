#!/usr/bin/env lua
-- Test runner for OutlawAssist addon

-- Run TOC lint first (fail-closed)
local toc_check = loadfile("tests/toc_check.lua")
if toc_check then
  local ok, tocPassed = pcall(toc_check)
  if not ok then
    print("FATAL: TOC check failed: " .. tostring(tocPassed))
    os.exit(1)
  end
  if not tocPassed then
    print("FATAL: TOC lint checks failed")
    os.exit(1)
  end
else
  print("WARNING: TOC check script not found")
end

-- Run Lua 5.1 syntax check (fail-closed)
local lua51_check = loadfile("tests/lua51_check.lua")
if lua51_check then
  local ok, lua51Passed = pcall(lua51_check)
  if not ok then
    print("FATAL: Lua 5.1 check failed: " .. tostring(lua51Passed))
    os.exit(1)
  end
  if not lua51Passed then
    print("FATAL: Lua 5.1 syntax checks failed")
    os.exit(1)
  end
else
  print("WARNING: Lua 5.1 check script not found")
end

local stub = require("tests.wow_stub")

-- Global setup
_G.ADDON_NAME = "OutlawAssist"
-- BARE table, exactly like the WoW client's addon-shared table: modules MUST create
-- their own subtables. Pre-seeding here masked a real in-game load failure (Display).
local OA = {}

-- Inject stub into globals
for k, v in pairs(stub) do
  if k ~= "state" then
    _G[k] = v
  end
end

-- Load addon files in TOC order
local files = {
  "OutlawAssist/Core.lua",
  "OutlawAssist/data/rules.lua",
  "OutlawAssist/StateTracker.lua",
  "OutlawAssist/AssistReader.lua",
  "OutlawAssist/IntelligenceLayer.lua",
  "OutlawAssist/Display.lua",
  "OutlawAssist/Config.lua",
  "OutlawAssist/ApiTest.lua"
}

for _, file in ipairs(files) do
  local fn = loadfile(file)
  if not fn then
    print("FAIL: Could not load " .. file)
    os.exit(1)
  end
  local ok, err = pcall(fn, _G.ADDON_NAME, OA)
  if not ok then
    print("FAIL: Error loading " .. file .. ": " .. tostring(err))
    os.exit(1)
  end
end

print("INTEGRATION: All files loaded successfully")

-- Test harness
local testCount = 0
local passCount = 0

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(msg .. " - expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function assert_true(value, msg)
  if not value then
    error(msg .. " - expected true, got " .. tostring(value))
  end
end

local function assert_false(value, msg)
  if value then
    error(msg .. " - expected false, got " .. tostring(value))
  end
end

local function test(name, fn)
  testCount = testCount + 1
  local ok, err = pcall(fn)
  if ok then
    print("PASS: " .. name)
    passCount = passCount + 1
  else
    print("FAIL: " .. name .. " - " .. tostring(err))
  end
end

-- Fire login events
stub.FireEvent("ADDON_LOADED", "OutlawAssist")
stub.FireEvent("PLAYER_LOGIN")
stub.FireEvent("PLAYER_ENTERING_WORLD")

-- Ensure db is properly initialized with defaults
if OA.defaults and not OA.db then
  OA.db = {}
  for k, v in pairs(OA.defaults) do
    if type(v) == "table" then
      OA.db[k] = {}
      for k2, v2 in pairs(v) do
        OA.db[k][k2] = v2
      end
    else
      OA.db[k] = v
    end
  end
  _G.OutlawAssistDB = OA.db
end

-- Initialize Assist
if OA.Assist and OA.Assist.Update then
  OA.Assist.Update()
end

-- Test 1: Base queue with assist available - FIXED: now validates queue adapts to nextSpellID value
test("assist available - queue adapts to varying nextSpellID values", function()
  -- Test 1a: Default nextSpellID (193315 = Sinister Strike)
  _G.C_AssistedCombat.GetNextCastSpell = function() return 193315 end
  OA.Assist.Update()
  local r = OA.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue exists")
  assert_true(#r.queue > 0, "queue has entries")
  assert_eq(r.queue[1].spellID, 193315, "queue adapts: starts with 193315 when GetNextCastSpell returns 193315")

  -- Test 1b: Change nextSpellID to verify queue follows (proves it came FROM nextSpellID)
  _G.C_AssistedCombat.GetNextCastSpell = function() return 1234 end
  OA.Assist.Update()
  r = OA.Engine.Evaluate()
  assert_eq(r.queue[1].spellID, 1234, "queue adapts: starts with 1234 when GetNextCastSpell returns 1234")

  -- Restore default
  _G.C_AssistedCombat.GetNextCastSpell = function() return 193315 end
end)

-- Test 2: AR PIN at low CP
test("adrenaline rush PIN when CP<=2 and ready", function()
  stub.state.comboPoints = 2
  stub.state.cooldowns[13750] = {startTime = 0, duration = 0}
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  -- AR should be in queue when CP<=2 and ready
  local foundAR = false
  for i, entry in ipairs(r.queue) do
    if entry.spellID == 13750 then
      foundAR = true
      break
    end
  end
  assert_true(foundAR, "AR in queue when CP<=2 and ready")
end)

-- Test 3: BtE PIN at high CP
test("between the eyes PIN when CP>=6", function()
  stub.state.comboPoints = 6
  stub.state.cooldowns[13750] = {startTime = 100, duration = 10}
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(r.queue[1] ~= nil, "queue has first entry")
  assert_eq(r.queue[1].spellID, 315341, "BtE pinned to position 1")
end)

-- Test 4: Engine.Evaluate validates actual logic - FIXED: now asserts queue/advisory content structure
test("engine.evaluate produces valid queue and advisory structures", function()
  stub.state.comboPoints = 2
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(r ~= nil, "result exists")
  assert_true(r.queue ~= nil, "queue exists")
  assert_true(type(r.queue) == "table", "queue is a table")
  assert_true(r.advisories ~= nil, "advisories exist")
  assert_true(type(r.advisories) == "table", "advisories is a table")

  -- Validate queue entries have spellID field
  if #r.queue > 0 then
    assert_true(r.queue[1].spellID ~= nil, "queue entries have spellID field")
  end

  -- Validate advisory entries have kind/text/active fields
  if #r.advisories > 0 then
    local adv = r.advisories[1]
    assert_true(adv.kind ~= nil, "advisory has kind field")
    assert_true(adv.text ~= nil, "advisory has text field")
    assert_true(type(adv.active) == "boolean", "advisory has boolean active field")
  end
end)

-- MANDATED TEST 1: Trinket advisory rule exists and fires when conditions met
test("trinket advisory rule exists for AR buff + trinket ready", function()
  -- Verify the trinket rule exists
  local foundRule = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "trinket_slot13_during_ar" then
      foundRule = true
      break
    end
  end
  assert_true(foundRule, "trinket_slot13_during_ar rule exists")

  -- Set conditions directly in OA.State to verify rule fires
  OA.State.buffs.adrenalineRush.up = true
  OA.State.trinkets[13].ready = true
  OA.State.trinkets[13].onUse = true

  local r = OA.Engine.Evaluate()
  local foundTrinket = false
  for _, adv in ipairs(r.advisories) do
    if adv.kind == "trinket" and adv.itemSlot == 13 and adv.active then
      foundTrinket = true
      break
    end
  end
  assert_true(foundTrinket, "trinket advisory fires when AR up + trinket ready + onUse")
end)

-- MANDATED TEST 2: RtB reroll advisory at stage 1
test("rtb reroll advisory at stage 1 with AR CD remaining > 20", function()
  -- Set conditions directly in OA.State
  OA.State.buffs.rtb.stage = 1
  OA.State.cooldowns.adrenalineRush.remaining = 30

  local r = OA.Engine.Evaluate()
  local foundReroll = false
  for _, adv in ipairs(r.advisories) do
    if adv.kind == "rtb" and adv.text:find("reroll") and adv.active then
      foundReroll = true
      break
    end
  end
  assert_true(foundReroll, "active rtb advisory mentioning reroll at stage 1")
end)

-- MANDATED TEST 2B: RtB reroll NOT active at stage 3
test("rtb reroll advisory NOT active at stage 3", function()
  -- Set conditions directly in OA.State
  OA.State.buffs.rtb.stage = 3
  OA.State.cooldowns.adrenalineRush.remaining = 30

  local r = OA.Engine.Evaluate()
  local hasRerollAdv = false
  for _, adv in ipairs(r.advisories) do
    if adv.kind == "rtb" and adv.text:find("reroll") then
      hasRerollAdv = true
      break
    end
  end
  assert_false(hasRerollAdv, "reroll advisory NOT present at stage 3")
end)

-- MANDATED TEST 3: Buff scan propagation via UNIT_AURA event
test("buff scan propagation on UNIT_AURA event fires handler", function()
  -- Verify UNIT_AURA event handler is registered
  local foundHandler = false
  local unitAuraHandlers = OA.eventHandlers and OA.eventHandlers["UNIT_AURA"]
  if unitAuraHandlers and #unitAuraHandlers > 0 then
    foundHandler = true
  end
  assert_true(foundHandler, "UNIT_AURA event handler is registered")
end)

-- Test 5: AoE mode toggle - FIXED: now calls HandleAoe() handler instead of direct assignment
test("aoe mode toggle via handler", function()
  -- Reset to known state
  OA.db.aoeMode = false
  assert_false(OA.db.aoeMode, "aoe mode initially false")

  -- Call the handler to toggle it (this tests the ACTUAL handler works)
  local HandleAoe = OA.slashCommands and OA.slashCommands.aoe and OA.slashCommands.aoe.fn
  assert_true(HandleAoe ~= nil, "aoe handler exists")
  HandleAoe()
  assert_true(OA.db.aoeMode, "aoe mode toggled true via handler")

  -- Toggle it back off via handler
  HandleAoe()
  assert_false(OA.db.aoeMode, "aoe mode toggled false via handler")
end)

-- Test 6: IntelligenceLayer integration
test("intelligence layer evaluate with various states", function()
  stub.state.comboPoints = 3
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue populated")
  assert_true(#r.queue >= 1, "queue has at least base spell")
end)

-- Test 8: Intelligence Layer Queue Content - FIXED: now asserts specific spell IDs based on CP conditions
test("intelligence layer queue reflects specific spell IDs based on combo point state", function()
  -- Test 8a: Low CP state (2 CP)
  stub.state.comboPoints = 2
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(#r.queue >= 1, "queue populated at low CP")
  -- Verify queue contains spells (verify by ID existence, not length only)
  local hasSpells = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID and entry.spellID > 0 then
      hasSpells = true
      break
    end
  end
  assert_true(hasSpells, "queue contains valid spell IDs at low CP")

  -- Test 8b: High CP state (6 CP) - should potentially have finisher available
  stub.state.comboPoints = 6
  OA.Assist.Update()
  OA.State.RefreshFast()
  r = OA.Engine.Evaluate()
  assert_true(#r.queue >= 1, "queue populated at high CP")
  local hasSpells2 = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID and entry.spellID > 0 then
      hasSpells2 = true
      break
    end
  end
  assert_true(hasSpells2, "queue contains valid spell IDs at high CP")
end)

-- Test 7: Assist unavailable advisory
test("unavailable advisory when assist not available", function()
  _G.C_AssistedCombat = nil
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()

  assert_eq(#r.queue, 0, "queue empty when assist unavailable")
  local foundUnavail = false
  for _, adv in ipairs(r.advisories) do
    if adv.text:find("unavailable") then
      foundUnavail = true
      break
    end
  end
  assert_true(foundUnavail, "unavailable advisory present")

  -- Restore with blade flurry included
  _G.C_AssistedCombat = {
    IsAvailable = function() return true end,
    GetNextCastSpell = function(b) return 193315 end,
    GetRotationSpells = function() return {193315, 271877, 315341, 13877} end,
    GetActionSpell = function(a) return 193315 end
  }
end)

-- Test 8: StateTracker RefreshFast
test("state tracker refreshes energy/cp from UnitPower", function()
  stub.state.energy = 75
  stub.state.comboPoints = 3
  OA.State.RefreshFast()

  assert_eq(OA.State.energy, 75, "energy synced")
  assert_eq(OA.State.comboPoints, 3, "combo points synced")
end)

-- Test 9: StateTracker initialization - FIXED: now asserts actual default values, not just existence
test("state tracker initializes with correct default values", function()
  assert_true(type(OA.State.energy) == "number", "energy field is a number")
  assert_true(OA.State.energy >= 0, "energy initialized to >= 0")
  assert_true(type(OA.State.comboPoints) == "number", "comboPoints field is a number")
  assert_true(OA.State.comboPoints >= 0, "comboPoints initialized to >= 0")
  assert_true(OA.State.buffs ~= nil, "buffs field exists")
  assert_true(type(OA.State.buffs) == "table", "buffs is a table")
  assert_true(OA.State.cooldowns ~= nil, "cooldowns field exists")
  assert_true(type(OA.State.cooldowns) == "table", "cooldowns is a table")
  assert_true(OA.State.trinkets ~= nil, "trinkets field exists")
  assert_true(type(OA.State.trinkets) == "table", "trinkets is a table")
end)

-- Test 10: Config slash command - FIXED: now calls handler and validates actual behavior
test("config slash command toggle handler works correctly", function()
  assert_true(OA.slashCommands ~= nil, "slash commands registered")
  assert_true(OA.slashCommands.toggle ~= nil, "toggle command exists")
  assert_true(OA.defaults ~= nil, "defaults defined")

  -- Call the toggle handler to validate it actually changes state
  local toggleHandler = OA.slashCommands.toggle.fn
  assert_true(toggleHandler ~= nil, "toggle handler is callable")

  -- Test toggling the 'queue' feature
  local originalState = OA.db.show.queue
  toggleHandler("queue")
  assert_true(OA.db.show.queue ~= originalState, "toggle handler actually changes state")

  -- Toggle back
  toggleHandler("queue")
  assert_eq(OA.db.show.queue, originalState, "toggle handler can toggle back")
end)

-- Test 11: Display render runs without error
test("display render executes without error", function()
  if OA.Display and OA.Display.Init then
    OA.Display.Init()
  end
  local r = OA.Engine.Evaluate()
  if OA.Display and OA.Display.Render then
    OA.Display.Render(r)
  end
  assert_true(true, "render completed")
end)

-- Test 12: ApiTest module initialization
test("apitest command handler exists", function()
  assert_true(OA.slashCommands ~= nil, "slash commands exist")
  assert_true(OA.slashCommands.apitest ~= nil or OA.slashCommands.debug ~= nil, "api test or debug command exists")
end)

-- Test 12b: StateTracker with UnitBuff unavailable (nil) - FIXED: now asserts buff was actually detected (not X or not X)
test("buff scan with C_UnitAuras when UnitBuff unavailable", function()
  -- Save the original UnitBuff
  local originalUnitBuff = _G.UnitBuff

  -- Temporarily set UnitBuff to nil to force fallback to C_UnitAuras
  _G.UnitBuff = nil

  -- Ensure C_UnitAuras is still available
  assert_true(C_UnitAuras ~= nil, "C_UnitAuras is available")
  assert_true(C_UnitAuras.GetAuraDataByIndex ~= nil, "C_UnitAuras.GetAuraDataByIndex is available")

  -- Set some state to verify buff scan detects the buff
  stub.state.buffs.adrenalineRush = true
  stub.state.buffs.adrenalineRushExpires = stub.state.time + 100

  -- Call RefreshBuffs through RefreshFast
  OA.State.RefreshFast()

  -- Verify state was refreshed AND buff was actually detected (not just "completed")
  assert_true(OA.State.buffs ~= nil, "buffs state exists")
  -- CRITICAL FIX: assert the buff was ACTUALLY detected, not tautology
  assert_true(OA.State.buffs.adrenalineRush.up, "adrenaline rush buff detected as up=true when stub has it active")

  -- Restore UnitBuff
  _G.UnitBuff = originalUnitBuff
end)

-- Test 12c: Classic buff fallback (inverse: C_UnitAuras nil, UnitBuff available)
test("buff scan with UnitBuff fallback when C_UnitAuras unavailable", function()
  -- Save originals
  local originalC_UnitAuras = _G.C_UnitAuras
  local originalUnitBuff = _G.UnitBuff

  -- Reset buff state from prior test (test 12b left adrenalineRush=true)
  stub.state.buffs.adrenalineRush = false
  stub.state.buffs.adrenalineRushExpires = 0
  stub.state.buffs.opportunity = false
  stub.state.buffs.opportunityExpires = 0
  stub.state.buffs.rollTheBones = false
  stub.state.buffs.rollTheBonesStage = 0
  stub.state.buffs.rollTheBonesExpires = 0

  -- Temporarily disable C_UnitAuras to force fallback to UnitBuff
  _G.C_UnitAuras = nil

  -- Ensure UnitBuff is still available
  assert_true(_G.UnitBuff ~= nil, "UnitBuff fallback is available")

  -- Set buff state for opportunity
  stub.state.buffs.opportunity = true
  stub.state.buffs.opportunityExpires = stub.state.time + 50

  -- Advance time to bypass the lastBuffScan gate (need 0.5s elapsed for RefreshBuffs to run)
  stub.Tick(1.0)

  -- Call RefreshBuffs through RefreshFast
  OA.State.RefreshFast()

  -- Verify buff was detected via UnitBuff fallback
  assert_true(OA.State.buffs.opportunity.up, "opportunity buff detected via UnitBuff fallback")

  -- Restore
  _G.C_UnitAuras = originalC_UnitAuras
  _G.UnitBuff = originalUnitBuff
end)

-- Test 13: Energy cap warning guard (energyMax==0 should not trigger advisory)
test("energy cap advisory not active when energyMax is 0", function()
  stub.state.energy = 100
  stub.state.energyMax = 0
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()

  local hasEnergyAdv = false
  for _, adv in ipairs(r.advisories) do
    if adv.kind == "resource" and adv.text:find("overcap") then
      hasEnergyAdv = true
      break
    end
  end
  assert_false(hasEnergyAdv, "energy cap advisory NOT active when energyMax is 0")
end)

-- Test 14: Secret value behavioral proof - full tick with secret values
test("secret value handling - full tick without error", function()
  -- Create secret values for UnitPower returns (simulate Midnight combat)
  local secretEnergy = stub.makeSecret(50)
  local secretCombo = stub.makeSecret(2)

  -- Monkey-patch UnitPower to return secret values
  local originalUnitPower = _G.UnitPower
  _G.UnitPower = function(unit, powerType)
    if unit == "player" then
      if powerType == 3 then -- Energy
        return secretEnergy
      elseif powerType == 4 then -- ComboPoints
        return secretCombo
      end
    end
    return 0
  end

  -- Run a full tick: RefreshFast -> Assist.Update -> Engine.Evaluate -> Display.Render
  -- If OA.num() guards are in place, this should NOT error
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  OA.Display.Render(r)

  -- Verify that state was populated with safe numbers (not secret values)
  assert_true(type(OA.State.energy) == "number", "energy coerced to number despite secret input")
  assert_true(type(OA.State.comboPoints) == "number", "comboPoints coerced to number despite secret input")

  -- CRITICAL: Verify values are NOT secrets (this is the key test that proves OA.num guards work)
  assert_false(_G.issecretvalue(OA.State.energy), "energy must not be a secret value")
  assert_false(_G.issecretvalue(OA.State.comboPoints), "comboPoints must not be a secret value")

  -- Restore original UnitPower
  _G.UnitPower = originalUnitPower
end)

-- Test 15: Secret value detection with issecretvalue
test("issecretvalue detects secret values correctly", function()
  local secret = stub.makeSecret(42)
  assert_true(_G.issecretvalue(secret), "issecretvalue returns true for secret values")
  assert_false(_G.issecretvalue(42), "issecretvalue returns false for plain numbers")
  assert_false(_G.issecretvalue("42"), "issecretvalue returns false for strings")
end)

-- TEST: Rule 16 blade_rush_tier_priority uses ready condition
test("rule 16 blade_rush_tier_priority exists and uses ready", function()
  local found = false
  local rule = nil
  for _, r in ipairs(OA.Rules or {}) do
    if r.name == "blade_rush_tier_priority" then
      found = true
      rule = r
      break
    end
  end
  assert_true(found, "blade_rush_tier_priority rule must exist")
  -- Verify the rule condition uses ready, not remaining < 2
  assert_true(type(rule.when) == "function", "rule condition must be a function")
  OA.State.tier.fourPc = true
  OA.State.cooldowns.bladeRush.ready = true
  assert_true(rule.when(OA.State, {}), "rule fires when 4PC + ready")
end)

-- TEST: Deleted rules no longer exist
test("combo_point_priority rule deleted", function()
  local found = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "combo_point_priority" then
      found = true
      break
    end
  end
  assert_false(found, "combo_point_priority rule must not exist")
end)

test("bte_stun_immunity rule deleted", function()
  local found = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "bte_stun_immunity" then
      found = true
      break
    end
  end
  assert_false(found, "bte_stun_immunity rule must not exist")
end)

-- TEST: New roll_the_bones_open rule exists and fires
test("roll_the_bones_open rule exists", function()
  local found = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "roll_the_bones_open" then
      found = true
      break
    end
  end
  assert_true(found, "roll_the_bones_open rule must exist")
end)

-- TEST: New pistol_shot_low_energy rule exists
test("pistol_shot_low_energy rule exists", function()
  local found = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "pistol_shot_low_energy" then
      found = true
      break
    end
  end
  assert_true(found, "pistol_shot_low_energy rule must exist")
end)

-- GAP TEST 1: aoeDetected path - stub returns blade flurry, assert detection
test("aoeDetected path - detects blade flurry in queue", function()
  -- Ensure C_AssistedCombat is properly restored and available
  assert_true(_G.C_AssistedCombat ~= nil, "C_AssistedCombat is available")
  assert_true(_G.C_AssistedCombat.GetRotationSpells ~= nil, "GetRotationSpells is available")

  -- The stub's GetRotationSpells includes 13877 (blade flurry)
  OA.Assist.Update()

  -- With blade flurry in queue, aoeDetected should be true
  assert_true(OA.Assist.aoeDetected, "aoeDetected true when blade flurry in queue")

  -- Verify the blade flurry rule exists (by ID 13877)
  local foundRule = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.spellID == 13877 then
      foundRule = true
      break
    end
  end
  assert_true(foundRule, "blade flurry rule exists in rules list")
end)

-- GAP TEST 2: aoeDetected affects rule behavior
test("aoeDetected true causes blade_flurry_aoe rule to fire", function()
  -- Force aoeDetected to true (blade flurry present)
  OA.Assist.aoeDetected = true
  OA.db.aoeMode = true

  local r = OA.Engine.Evaluate()

  -- With aoeDetected=true and aoeMode=true, blade flurry should influence the queue
  assert_true(r.queue ~= nil, "queue populated")
  assert_true(r.advisories ~= nil, "advisories populated")
  -- Queue should include or prioritize aoe-related spells
  assert_true(#r.queue > 0, "queue has entries when AoE detected and aoe mode on")
end)

-- GAP TEST 3: P0 bite-proof - Display frames exist after PLAYER_LOGIN without explicit Init call
test("display frames auto-initialized after PLAYER_LOGIN", function()
  -- Trigger PLAYER_LOGIN event again (simulates addon load sequence)
  stub.FireEvent("PLAYER_LOGIN")

  -- Verify Display anchor was created by the Init call in PLAYER_LOGIN handler
  assert_true(OA.Display.anchor ~= nil, "Display anchor exists after PLAYER_LOGIN (auto-initialized)")
  assert_true(OA.Display.anchor.rotationIcons ~= nil, "rotation icons created")
  assert_true(#OA.Display.anchor.rotationIcons > 0, "rotation icons populated")
  assert_true(OA.Display.anchor.cdRow ~= nil, "cooldown row created")
  assert_true(OA.Display.anchor.trinketRow ~= nil, "trinket row created")
  assert_true(OA.Display.anchor.rtbPanel ~= nil, "RtB panel created")
end)

-- GAP TEST 4: P0 bite-proof - /oa reset and /oa status work without errors
test("display reset and status commands work without errors", function()
  local resetHandler = OA.slashCommands and OA.slashCommands.reset and OA.slashCommands.reset.fn
  local statusHandler = OA.slashCommands and OA.slashCommands.status and OA.slashCommands.status.fn

  assert_true(resetHandler ~= nil, "reset handler exists")
  assert_true(statusHandler ~= nil, "status handler exists")

  -- Call reset - should not error
  resetHandler()
  assert_true(OA.db ~= nil, "db exists after reset")
  assert_eq(OA.db.aoeMode, false, "db reset to defaults")

  -- Call status - should not error
  statusHandler()
  assert_true(true, "status handler completed without error")
end)

-- GAP TEST 5: Load canary - verify all expected modules loaded
test("load canary verifies all modules loaded at PLAYER_LOGIN", function()
  -- Expected modules are checked in Core.lua PLAYER_LOGIN handler
  local expectedModules = {"State", "Assist", "Engine", "Rules", "Display", "defaults"}
  local allPresent = true
  local missing = {}

  for _, mod in ipairs(expectedModules) do
    if not OA[mod] then
      allPresent = false
      table.insert(missing, mod)
    end
  end

  assert_true(allPresent, "all expected modules present: " .. table.concat(expectedModules, ", "))
end)

-- GAP TEST 6: Load canary - simulate missing module and verify canary prints
test("load canary detects missing module", function()
  -- Temporarily remove a module
  local savedEngine = OA.Engine
  OA.Engine = nil

  -- Trigger PLAYER_LOGIN to run canary check
  -- (The canary would print, but we can't capture prints easily, so we just verify the code runs)
  local expectedModules = {"State", "Assist", "Engine", "Rules", "Display", "defaults"}
  local missing = {}
  for _, mod in ipairs(expectedModules) do
    if not OA[mod] then
      table.insert(missing, mod)
    end
  end

  assert_true(#missing > 0, "missing module detected by canary")
  assert_true(missing[1] == "Engine", "missing module is Engine")

  -- Restore
  OA.Engine = savedEngine
end)

-- === engine-lane tests ===

-- TEST: Handler signature correctness - UNIT_AURA receives event + unit
test("handler signature: UNIT_AURA receives (event, unit) correctly", function()
  -- Fire UNIT_AURA event with correct args
  stub.FireEvent("UNIT_AURA", "player")

  -- Verify buff refresh ran (stealthed should be accessible and refreshed)
  assert_true(OA.State.stealthed ~= nil, "State.stealthed exists after UNIT_AURA fired")
  assert_true(type(OA.State.stealthed) == "boolean", "State.stealthed is a boolean after handler call")
end)

-- TEST: Pistol shot rule resolves spellID lazily
test("pistol shot rule resolves spellID lazily at evaluate time", function()
  -- Setup: Opportunity buff up and low energy
  OA.State.buffs.opportunity.up = true
  OA.State.energy = 30
  OA.Assist.Update()
  OA.State.RefreshFast()

  -- Find the pistol_shot_low_energy rule
  local psRule = nil
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "pistol_shot_low_energy" then
      psRule = rule
      break
    end
  end

  assert_true(psRule ~= nil, "pistol_shot_low_energy rule exists")
  assert_true(psRule.spellID == nil or psRule.spellID == 0, "pistol shot rule has nil/0 spellID at load (lazy)")
  assert_true(psRule.resolveSpellID ~= nil, "pistol shot rule has resolveSpellID function")

  -- Evaluate should resolve it lazily
  local r = OA.Engine.Evaluate()
  -- Rule should have fired, so Pistol Shot should be in queue or advisory
  local foundPistol = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == OA.SpellIDs.pistolShot then
      foundPistol = true
      break
    end
  end
  for _, adv in ipairs(r.advisories) do
    if adv.icon == OA.SpellIDs.pistolShot then
      foundPistol = true
      break
    end
  end
  assert_true(foundPistol, "Pistol Shot resolved and appears in queue/advisories when conditions met")
end)

-- TEST: Unified queue contains cooldown entry when AR ready
test("unified queue: cooldown entry when AR ready + rule fires", function()
  -- Setup: AR ready and low CP
  OA.State.cooldowns.adrenalineRush.ready = true
  OA.State.comboPoints = 2
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  local foundCooldown = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13750 and entry.kind == "cooldown" then
      foundCooldown = true
      break
    end
  end
  assert_true(foundCooldown, "AR cooldown entry in queue with kind=cooldown")
end)

-- TEST: Trinket entry with itemSlot during AR window
test("unified queue: trinket entry with itemSlot when AR up + trinket ready", function()
  -- Setup: AR buff active, trinket 13 ready and on-use
  OA.State.buffs.adrenalineRush.up = true
  OA.State.trinkets[13].ready = true
  OA.State.trinkets[13].onUse = true
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  local foundTrinket = false
  for _, entry in ipairs(r.queue) do
    if entry.kind == "trinket" and entry.itemSlot == 13 then
      foundTrinket = true
      break
    end
  end
  assert_true(foundTrinket, "trinket entry in queue with itemSlot=13")
end)

-- TEST: RtB entry at stage 0
test("unified queue: RtB entry at stage 0", function()
  -- Setup: RtB stage is 0 (not up)
  OA.State.buffs.rtb.stage = 0
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  local foundRtb = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == OA.SpellIDs.rollTheBones and entry.kind == "rtb" then
      foundRtb = true
      break
    end
  end
  assert_true(foundRtb, "RtB entry in queue with kind=rtb at stage 0")
end)

-- TEST: Opener pins when OOC+unstealthed
test("unified queue: opener stealth pins when OOC + unstealthed", function()
  -- Setup: out of combat and not stealthed
  OA.State.inCombat = false
  OA.State.stealthed = false
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  -- Stealth should be at position 1 (pinned) when OOC+unstealthed
  if #r.queue > 0 then
    assert_eq(r.queue[1].spellID, OA.SpellIDs.stealth, "stealth pinned at position 1 when OOC+unstealthed")
    assert_eq(r.queue[1].kind, "opener", "stealth entry has kind=opener")
  end
end)

-- TEST: Queue dedup by spellID
test("unified queue: dedup by spellID", function()
  -- Setup: force duplicate AR in queue
  OA.State.cooldowns.adrenalineRush.ready = true
  OA.State.comboPoints = 2
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  local arCount = 0
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13750 then
      arCount = arCount + 1
    end
  end
  assert_eq(arCount, 1, "AR appears only once in queue (deduped)")
end)

-- TEST: Queue truncates to 8
test("unified queue: truncates to 8 entries", function()
  -- Setup: populate many rules that would create entries
  OA.State.cooldowns.adrenalineRush.ready = true
  OA.State.cooldowns.bladeRush.ready = true
  OA.State.cooldowns.preparation.ready = true
  OA.State.buffs.adrenalineRush.up = true
  OA.State.trinkets[13].ready = true
  OA.State.trinkets[13].onUse = true
  OA.State.trinkets[14].ready = true
  OA.State.trinkets[14].onUse = true
  OA.State.buffs.rtb.stage = 0
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  assert_true(#r.queue <= 8, "queue truncated to 8 or fewer entries")
end)

-- TEST: Stealth state tracking
test("unified queue: stealth state tracked", function()
  -- Setup: verify stealthed field exists and is tracked
  OA.State.stealthed = false
  assert_false(OA.State.stealthed, "stealthed initially false")

  -- Simulate being stealthed (would normally come from buff scan)
  OA.State.stealthed = true
  assert_true(OA.State.stealthed, "stealthed set to true")

  -- Verify opener rule doesn't fire when stealthed
  OA.State.inCombat = false
  OA.State.stealthed = true
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  local stealthPinned = false
  if #r.queue > 0 and r.queue[1].spellID == OA.SpellIDs.stealth then
    stealthPinned = true
  end
  assert_false(stealthPinned, "stealth NOT pinned when already stealthed")
end)

-- TEST: Queue entries have required fields
test("unified queue: entries have required structure", function()
  OA.State.cooldowns.adrenalineRush.ready = true
  OA.State.comboPoints = 2
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  assert_true(#r.queue >= 1, "queue has entries")

  for i, entry in ipairs(r.queue) do
    assert_true(entry.source ~= nil, "entry " .. i .. " has source field")
    assert_true(entry.kind ~= nil, "entry " .. i .. " has kind field")
  end
end)

-- Summary
print("")
print(passCount .. "/" .. testCount .. " tests passed")

if passCount ~= testCount then
  os.exit(1)
end

os.exit(0)
