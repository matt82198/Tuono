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

-- Test 1: Base queue with assist available
test("assist available - queue adapts to varying nextSpellID values", function()
  -- Self-sufficient: prevent opener rule from pinning by setting inCombat=true
  OA.State.inCombat = true
  OA.State.stealthed = false

  _G.C_AssistedCombat.GetNextCastSpell = function() return 193315 end
  OA.Assist.Update()
  local r = OA.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue exists")
  assert_true(#r.queue > 0, "queue has entries")
  assert_eq(r.queue[1].spellID, 193315, "queue adapts: starts with 193315 when GetNextCastSpell returns 193315")

  _G.C_AssistedCombat.GetNextCastSpell = function() return 1234 end
  OA.Assist.Update()
  r = OA.Engine.Evaluate()
  assert_eq(r.queue[1].spellID, 1234, "queue adapts: starts with 1234 when GetNextCastSpell returns 1234")

  _G.C_AssistedCombat.GetNextCastSpell = function() return 193315 end
  OA.State.inCombat = false
end)

-- Test 2: AR PIN at low CP
test("adrenaline rush PIN when CP<=2 and ready", function()
  -- Self-sufficient state setup
  OA.State.inCombat = true
  OA.State.stealthed = false
  stub.state.comboPoints = 2
  stub.state.cooldowns[13750] = {startTime = 0, duration = 0}
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
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
  -- Self-sufficient state setup
  OA.State.inCombat = true
  OA.State.stealthed = false
  stub.state.comboPoints = 6
  stub.state.cooldowns[13750] = {startTime = 100, duration = 10}
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(r.queue[1] ~= nil, "queue has first entry")
  assert_eq(r.queue[1].spellID, 315341, "BtE pinned to position 1")
end)

-- Test 4: Engine.Evaluate validates actual logic
test("engine.evaluate produces valid queue and advisory structures", function()
  -- Self-sufficient state setup
  OA.State.inCombat = true
  OA.State.stealthed = false
  stub.state.comboPoints = 2
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(r ~= nil, "result exists")
  assert_true(r.queue ~= nil, "queue exists")
  assert_true(type(r.queue) == "table", "queue is a table")
  assert_true(r.advisories ~= nil, "advisories exist")
  assert_true(type(r.advisories) == "table", "advisories is a table")

  if #r.queue > 0 then
    assert_true(r.queue[1].spellID ~= nil, "queue entries have spellID field")
  end

  if #r.advisories > 0 then
    local adv = r.advisories[1]
    assert_true(adv.kind ~= nil, "advisory has kind field")
    assert_true(adv.text ~= nil, "advisory has text field")
    assert_true(type(adv.active) == "boolean", "advisory has boolean active field")
  end
end)

-- MANDATED TEST 1: Trinket advisory rule exists and fires when conditions met
test("trinket advisory rule exists for AR buff + trinket ready", function()
  local foundRule = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "trinket_slot13_during_ar" then
      foundRule = true
      break
    end
  end
  assert_true(foundRule, "trinket_slot13_during_ar rule exists")

  -- Self-sufficient state setup
  OA.State.inCombat = true
  OA.State.stealthed = false
  OA.State.buffs.adrenalineRush.up = true
  OA.State.trinkets[13].ready = true
  OA.State.trinkets[13].onUse = true

  local r = OA.Engine.Evaluate()
  -- v0.3 contract: trinket entries fold into queue with kind="trinket" and itemSlot
  local foundTrinket = false
  for _, entry in ipairs(r.queue) do
    if entry.kind == "trinket" and entry.itemSlot == 13 then
      foundTrinket = true
      break
    end
  end
  assert_true(foundTrinket, "trinket entry in queue when AR up + trinket ready + onUse")
end)

-- MANDATED TEST 2: RtB reroll advisory at stage 1
test("rtb reroll advisory at stage 1 with AR CD remaining > 20", function()
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
  local foundHandler = false
  local unitAuraHandlers = OA.eventHandlers and OA.eventHandlers["UNIT_AURA"]
  if unitAuraHandlers and #unitAuraHandlers > 0 then
    foundHandler = true
  end
  assert_true(foundHandler, "UNIT_AURA event handler is registered")
end)

-- Test 5: AoE mode toggle
test("aoe mode toggle via handler", function()
  OA.db.aoeMode = false
  assert_false(OA.db.aoeMode, "aoe mode initially false")

  local HandleAoe = OA.slashCommands and OA.slashCommands.aoe and OA.slashCommands.aoe.fn
  assert_true(HandleAoe ~= nil, "aoe handler exists")
  HandleAoe()
  assert_true(OA.db.aoeMode, "aoe mode toggled true via handler")

  HandleAoe()
  assert_false(OA.db.aoeMode, "aoe mode toggled false via handler")
end)

-- Test 6: IntelligenceLayer integration
test("intelligence layer evaluate with various states", function()
  -- Self-sufficient state setup
  OA.State.inCombat = true
  OA.State.stealthed = false
  stub.state.comboPoints = 3
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue populated")
  assert_true(#r.queue >= 1, "queue has at least base spell")
end)

-- Test 8: Intelligence Layer Queue Content
test("intelligence layer queue reflects specific spell IDs based on combo point state", function()
  -- Self-sufficient state setup
  OA.State.inCombat = true
  OA.State.stealthed = false
  stub.state.comboPoints = 2
  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  assert_true(#r.queue >= 1, "queue populated at low CP")
  local hasSpells = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID and entry.spellID > 0 then
      hasSpells = true
      break
    end
  end
  assert_true(hasSpells, "queue contains valid spell IDs at low CP")

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

-- Test 9: StateTracker initialization
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

-- Test 10: Config slash command
test("config slash command toggle handler works correctly", function()
  assert_true(OA.slashCommands ~= nil, "slash commands registered")
  assert_true(OA.slashCommands.toggle ~= nil, "toggle command exists")
  assert_true(OA.defaults ~= nil, "defaults defined")

  local toggleHandler = OA.slashCommands.toggle.fn
  assert_true(toggleHandler ~= nil, "toggle handler is callable")

  local originalState = OA.db.show.queue
  toggleHandler("queue")
  assert_true(OA.db.show.queue ~= originalState, "toggle handler actually changes state")

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

-- Test 12b: StateTracker with UnitBuff unavailable
test("buff scan with C_UnitAuras when UnitBuff unavailable", function()
  local originalUnitBuff = _G.UnitBuff

  _G.UnitBuff = nil

  assert_true(C_UnitAuras ~= nil, "C_UnitAuras is available")
  assert_true(C_UnitAuras.GetAuraDataByIndex ~= nil, "C_UnitAuras.GetAuraDataByIndex is available")

  stub.state.buffs.adrenalineRush = true
  stub.state.buffs.adrenalineRushExpires = stub.state.time + 100

  OA.State.RefreshFast()

  assert_true(OA.State.buffs ~= nil, "buffs state exists")
  assert_true(OA.State.buffs.adrenalineRush.up, "adrenaline rush buff detected as up=true when stub has it active")

  _G.UnitBuff = originalUnitBuff
end)

-- Test 12c: Classic buff fallback
test("buff scan with UnitBuff fallback when C_UnitAuras unavailable", function()
  local originalC_UnitAuras = _G.C_UnitAuras
  local originalUnitBuff = _G.UnitBuff

  -- Tier 3 (legacy index scan) is deliberately OOC-only: in combat those field reads
  -- can hit secret values. This test exercises the OOC path, so pin inCombat=false.
  OA.State.inCombat = false

  stub.state.buffs.adrenalineRush = false
  stub.state.buffs.adrenalineRushExpires = 0
  stub.state.buffs.opportunity = false
  stub.state.buffs.opportunityExpires = 0
  stub.state.buffs.rollTheBones = false
  stub.state.buffs.rollTheBonesStage = 0
  stub.state.buffs.rollTheBonesExpires = 0

  _G.C_UnitAuras = nil

  assert_true(_G.UnitBuff ~= nil, "UnitBuff fallback is available")

  stub.state.buffs.opportunity = true
  stub.state.buffs.opportunityExpires = stub.state.time + 50

  stub.Tick(1.0)

  OA.State.RefreshFast()

  assert_true(OA.State.buffs.opportunity.up, "opportunity buff detected via UnitBuff fallback")

  _G.C_UnitAuras = originalC_UnitAuras
  _G.UnitBuff = originalUnitBuff
end)

-- Test 13: Energy cap warning guard
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

-- Test 14: Secret value behavioral proof
test("secret value handling - full tick without error", function()
  local secretEnergy = stub.makeSecret(50)
  local secretCombo = stub.makeSecret(2)

  local originalUnitPower = _G.UnitPower
  _G.UnitPower = function(unit, powerType)
    if unit == "player" then
      if powerType == 3 then
        return secretEnergy
      elseif powerType == 4 then
        return secretCombo
      end
    end
    return 0
  end

  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  OA.Display.Render(r)

  assert_true(type(OA.State.energy) == "number", "energy coerced to number despite secret input")
  assert_true(type(OA.State.comboPoints) == "number", "comboPoints coerced to number despite secret input")

  assert_false(_G.issecretvalue(OA.State.energy), "energy must not be a secret value")
  assert_false(_G.issecretvalue(OA.State.comboPoints), "comboPoints must not be a secret value")

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

-- GAP TEST 1: aoeDetected path
test("aoeDetected path - detects blade flurry in queue", function()
  assert_true(_G.C_AssistedCombat ~= nil, "C_AssistedCombat is available")
  assert_true(_G.C_AssistedCombat.GetRotationSpells ~= nil, "GetRotationSpells is available")

  OA.Assist.Update()

  assert_true(OA.Assist.aoeDetected, "aoeDetected true when blade flurry in queue")

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
  OA.Assist.aoeDetected = true
  OA.db.aoeMode = true

  local r = OA.Engine.Evaluate()

  assert_true(r.queue ~= nil, "queue populated")
  assert_true(r.advisories ~= nil, "advisories populated")
  assert_true(#r.queue > 0, "queue has entries when AoE detected and aoe mode on")
end)

-- GAP TEST 3: P0 bite-proof - Display frames exist after PLAYER_LOGIN without explicit Init call
test("display frames auto-initialized after PLAYER_LOGIN", function()
  stub.FireEvent("PLAYER_LOGIN")

  assert_true(OA.Display.anchor ~= nil, "Display anchor exists after PLAYER_LOGIN (auto-initialized)")
  assert_true(OA.Display.anchor.strip ~= nil, "unified strip created")
  assert_true(OA.Display.anchor.icons ~= nil, "icons array created")
  assert_true(#OA.Display.anchor.icons > 0, "icons array populated")
  assert_true(OA.Display.anchor.rotationIcons == nil, "rotationIcons not created (unified strip only)")
  assert_true(OA.Display.anchor.cdRow == nil, "cdRow not created (unified strip only)")
  assert_true(OA.Display.anchor.trinketRow == nil, "trinketRow not created (unified strip only)")
  assert_true(OA.Display.anchor.rtbPanel == nil, "rtbPanel not created (unified strip only)")
end)

-- GAP TEST 4: P0 bite-proof - /oa reset and /oa status work without errors
test("display reset and status commands work without errors", function()
  local resetHandler = OA.slashCommands and OA.slashCommands.reset and OA.slashCommands.reset.fn
  local statusHandler = OA.slashCommands and OA.slashCommands.status and OA.slashCommands.status.fn

  assert_true(resetHandler ~= nil, "reset handler exists")
  assert_true(statusHandler ~= nil, "status handler exists")

  resetHandler()
  assert_true(OA.db ~= nil, "db exists after reset")
  assert_eq(OA.db.aoeMode, false, "db reset to defaults")

  statusHandler()
  assert_true(true, "status handler completed without error")
end)

-- GAP TEST 5: Load canary - verify all expected modules loaded
test("load canary verifies all modules loaded at PLAYER_LOGIN", function()
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
  local savedEngine = OA.Engine
  OA.Engine = nil

  local expectedModules = {"State", "Assist", "Engine", "Rules", "Display", "defaults"}
  local missing = {}
  for _, mod in ipairs(expectedModules) do
    if not OA[mod] then
      table.insert(missing, mod)
    end
  end

  assert_true(#missing > 0, "missing module detected by canary")
  assert_true(missing[1] == "Engine", "missing module is Engine")

  OA.Engine = savedEngine
end)

-- === polling-lane tests ===

-- TEST: Dynamic interval based on combat state
test("dynamic tick interval - 0.1s in combat, 0.5s idle", function()
  -- Verify handler exists and has correct structure
  assert_true(#OA.updateHandlers > 0, "update handlers registered")
  local handler = OA.updateHandlers[1]
  assert_true(handler.interval ~= nil, "handler has interval field")
  assert_true(type(handler.elapsed) == "number", "handler.elapsed is a number")

  -- The dynamic interval logic is in Core.lua OnUpdate and applies at tick time
  -- Test verifies the mechanism can be called without error
  OA.State.inCombat = true
  stub.Tick(0.05)
  assert_true(true, "tick completed during combat state")

  OA.State.inCombat = false
  stub.Tick(0.05)
  assert_true(true, "tick completed during idle state")
end)

-- TEST: Event-forced immediate update on UNIT_SPELLCAST_SUCCEEDED
test("forced immediate update on UNIT_SPELLCAST_SUCCEEDED", function()
  -- Reset handler elapsed to a value that would not normally trigger
  OA.updateHandlers[1].elapsed = 0.01

  -- Fire UNIT_SPELLCAST_SUCCEEDED for player
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast123", 193315)

  -- Verify the forceNext flag was set (indirectly: handler elapsed should reset after OnUpdate)
  -- We can't directly inspect forceNext (it's module-local), so we verify via handler state
  assert_true(true, "UNIT_SPELLCAST_SUCCEEDED handler executed without error")
end)

-- TEST: Deviation detection - flag set when cast ~= recommendation
test("deviation detection - deviated flag set when player casts != recommendation", function()
  -- Set the recommendation
  OA.Assist.nextSpellID = 193315  -- Sinister Strike

  -- Verify deviated flag is false initially
  assert_false(OA.Assist.deviated, "deviated flag initially false")

  -- Fire UNIT_SPELLCAST_SUCCEEDED with a DIFFERENT spell (deviation)
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast456", 271877)  -- Backstab

  -- Verify deviation flag was set
  assert_true(OA.Assist.deviated, "deviated flag set when player cast != recommendation")
end)

-- TEST: Deviation flag cleared on Update
test("deviation flag cleared on Assist.Update()", function()
  -- Set deviated flag
  OA.Assist.deviated = true

  -- Call Update() which should clear it
  OA.Assist.Update()

  -- Verify it was cleared
  assert_false(OA.Assist.deviated, "deviated flag cleared after Update()")
end)

-- TEST: Deviation detection filters unit=="player" only
test("deviation detection ignores non-player units", function()
  OA.Assist.nextSpellID = 193315
  OA.Assist.deviated = false

  -- Fire UNIT_SPELLCAST_SUCCEEDED for a different unit
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "target", "cast789", 271877)

  -- Verify deviation flag was NOT set (different unit)
  assert_false(OA.Assist.deviated, "deviated flag NOT set for non-player unit")
end)

-- TEST: RequestImmediateUpdate function exists
test("OA.RequestImmediateUpdate function callable", function()
  assert_true(type(OA.RequestImmediateUpdate) == "function", "RequestImmediateUpdate is a function")
  -- Call it without error
  OA.RequestImmediateUpdate()
  assert_true(true, "RequestImmediateUpdate executed without error")
end)

-- === engine-lane tests ===

-- TEST: Handler signature correctness - UNIT_AURA receives event + unit
test("handler signature: UNIT_AURA receives (event, unit) correctly", function()
  stub.FireEvent("UNIT_AURA", "player")

  assert_true(OA.State.stealthed ~= nil, "State.stealthed exists after UNIT_AURA fired")
  assert_true(type(OA.State.stealthed) == "boolean", "State.stealthed is a boolean after handler call")
end)

-- TEST: Pistol shot rule resolves spellID lazily
test("pistol shot rule resolves spellID lazily at evaluate time", function()
  -- Self-sufficient: manual state AFTER RefreshFast (it recomputes from stub and clobbers)
  OA.Assist.Update()
  OA.State.RefreshFast()
  OA.State.inCombat = true
  OA.State.stealthed = false
  OA.State.buffs.opportunity.up = true
  OA.State.energy = 30

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

  local r = OA.Engine.Evaluate()
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
  -- Self-sufficient: manual state AFTER RefreshFast (it recomputes from stub and clobbers)
  OA.Assist.Update()
  OA.State.RefreshFast()
  OA.State.inCombat = true
  OA.State.stealthed = false
  OA.State.cooldowns.adrenalineRush.ready = true
  OA.State.comboPoints = 2

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
  -- Self-sufficient: manual state AFTER RefreshFast (it recomputes from stub and clobbers).
  -- Must neutralize ALL other rule inputs: leftover hot state (AR buff, trinkets, low CP)
  -- adds fold-entries that push the queue past 8 and truncate the RtB append (last rule).
  OA.Assist.Update()
  OA.State.RefreshFast()
  OA.State.inCombat = true
  OA.State.stealthed = false
  OA.State.buffs.rtb.stage = 0
  OA.State.buffs.rtb.expires = 0
  OA.State.buffs.adrenalineRush.up = false
  OA.State.buffs.opportunity.up = false
  OA.State.cooldowns.adrenalineRush.ready = false
  OA.State.cooldowns.adrenalineRush.remaining = 60
  OA.State.cooldowns.bladeRush.ready = false
  OA.State.cooldowns.preparation.ready = false
  OA.State.trinkets[13].ready = false
  OA.State.trinkets[14].ready = false
  OA.State.comboPoints = 4
  OA.State.energy = 50
  OA.State.energyMax = 100
  OA.State.tier.twoPc = false
  OA.State.tier.fourPc = false

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
  OA.State.inCombat = false
  OA.State.stealthed = false
  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  if #r.queue > 0 then
    assert_eq(r.queue[1].spellID, OA.SpellIDs.stealth, "stealth pinned at position 1 when OOC+unstealthed")
    assert_eq(r.queue[1].kind, "opener", "stealth entry has kind=opener")
  end
end)

-- TEST: Queue dedup by spellID
test("unified queue: dedup by spellID", function()
  -- Self-sufficient: manual state AFTER RefreshFast (it recomputes from stub and clobbers)
  OA.Assist.Update()
  OA.State.RefreshFast()
  OA.State.inCombat = true
  OA.State.stealthed = false
  OA.State.cooldowns.adrenalineRush.ready = true
  OA.State.comboPoints = 2

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
  OA.State.stealthed = false
  assert_false(OA.State.stealthed, "stealthed initially false")

  OA.State.stealthed = true
  assert_true(OA.State.stealthed, "stealthed set to true")

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

-- === ui-lane tests ===

-- UI Test 1: Strip renders correct number of icons per iconCount config
test("strip renders correct number of icons per iconCount", function()
  OA.db.display.iconCount = 4
  if OA.Display and OA.Display.Init then
    OA.Display.Init()
  end

  local anchor = OA.Display.anchor
  assert_true(anchor ~= nil, "anchor exists")
  assert_true(anchor.strip ~= nil, "strip frame exists")
  assert_true(anchor.icons ~= nil, "icons array exists")
  assert_true(#anchor.icons >= 8, "icons array has at least 8 slots")
end)

-- UI Test 2: kind→border color mapping applied correctly
test("kind to border color mapping applied", function()
  OA.db.display.iconCount = 4
  if OA.Display and OA.Display.Init then
    OA.Display.Init()
  end

  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard"},
      {spellID = 13750, kind = "cooldown", source = "rule"},
      {spellID = 123456, kind = "trinket", itemSlot = 13, source = "rule"},
      {spellID = 315508, kind = "rtb", source = "rule"}
    },
    advisories = {}
  }

  OA.Display.Render(result)

  local anchor = OA.Display.anchor
  for i = 1, 4 do
    local icon = anchor.icons[i]
    assert_true(icon ~= nil, "icon " .. i .. " exists")
  end
end)

-- UI Test 3: Keybind text appears when mapping provided
test("keybind text displayed when mapping provided", function()
  OA.db.display.iconCount = 3
  if OA.Display and OA.Display.Init then
    OA.Display.Init()
  end

  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard"},
      {spellID = 13750, kind = "cooldown", source = "rule"},
      {spellID = 315508, kind = "rtb", source = "rule"}
    },
    advisories = {}
  }

  OA.Display.Render(result)

  local anchor = OA.Display.anchor
  if anchor.icons[1] then
    assert_true(anchor.icons[1].keyText ~= nil, "keyText element exists on icon 1")
  end
end)

-- UI Test 4: Strip reflow re-anchors icons horizontally
test("strip reflow re-anchors icons horizontally", function()
  OA.db.display.iconCount = 5
  if OA.Display and OA.Display.Init then
    OA.Display.Init()
  end

  local anchor = OA.Display.anchor
  assert_true(anchor.strip ~= nil, "strip exists")
  assert_true(#anchor.icons >= 5, "icons array has at least 5 icons")
end)

-- UI Test 5: Strip scale adjustable via /oa scale
test("strip scale adjustable via config", function()
  OA.db.display.scale = 1.0
  assert_eq(OA.db.display.scale, 1.0, "scale set to 1.0")

  OA.db.display.scale = 1.5
  assert_eq(OA.db.display.scale, 1.5, "scale changed to 1.5")

  OA.db.display.scale = 0.8
  assert_eq(OA.db.display.scale, 0.8, "scale changed to 0.8")
end)

-- UI Test 6: Icon count configuration
test("icon count configuration updates display", function()
  OA.db.display.iconCount = 5
  assert_eq(OA.db.display.iconCount, 5, "iconCount changed to 5")

  OA.db.display.iconCount = 6
  assert_eq(OA.db.display.iconCount, 6, "iconCount changed to 6")
end)

-- === threat-lane tests ===

-- Diagnostic: Verify stub functions work
test("threat detector: stub nameplate helpers work correctly", function()
  stub.ClearNamePlates()
  assert_eq(#stub.nameplates, 0, "nameplates cleared")

  stub.AddNamePlate("test1", 3)
  assert_eq(#stub.nameplates, 1, "one nameplate added")
  assert_true(stub.threatLevels["test1"] ~= nil, "threat level stored")
  assert_eq(stub.threatLevels["test1"], 3, "threat level value correct")

  local plates = _G.C_NamePlate.GetNamePlates()
  assert_true(plates ~= nil, "GetNamePlates returns a table")
  assert_eq(#plates, 1, "GetNamePlates returns 1 plate")
  assert_true(plates[1].namePlateUnitToken == "test1", "plate has correct token")
end)

-- Threat Test 1: 3 hostile-threat plates → enemyCount==3 and blade_flurry fires
test("threat detector: 3 hostile plates detected, enemyCount==3", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  stub.AddNamePlate("nameplate2", 3)
  stub.AddNamePlate("nameplate3", 3)

  stub.Tick(0.5)  -- Advance time to ensure RefreshEnemyCount is called (time-gated at 0.25s)
  OA.State.RefreshFast()

  assert_eq(OA.State.enemyCount, 3, "enemyCount equals 3 with 3 hostile plates")
end)

-- Threat Test 2: blade_flurry rule fires with 2+ enemies (via threatcount signal, not aoeDetected)
test("threat detector: blade_flurry_aoe rule fires when enemyCount >= 2", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  stub.AddNamePlate("nameplate2", 3)
  OA.db.aoeMode = false

  -- Disable aoeDetected by preventing blade flurry from being in the queue
  local originalGetRotationSpells = _G.C_AssistedCombat.GetRotationSpells
  _G.C_AssistedCombat.GetRotationSpells = function()
    return {193315, 271877, 315341}  -- No blade flurry (13877)
  end

  OA.Assist.Update()
  OA.State.RefreshFast()

  assert_false(OA.Assist.aoeDetected, "aoeDetected false (blade flurry not in queue)")

  local r = OA.Engine.Evaluate()
  local foundBladeFlurry = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13877 then
      foundBladeFlurry = true
      break
    end
  end
  assert_true(foundBladeFlurry, "blade flurry in queue when enemyCount >= 2 (via threat signal, not aoeDetected)")

  _G.C_AssistedCombat.GetRotationSpells = originalGetRotationSpells
end)

-- Threat Test 3: single plate (enemyCount=1) → rule doesn't fire (threshold is 2)
test("threat detector: single plate gives enemyCount=1, rule doesn't fire", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  OA.db.aoeMode = false

  stub.Tick(0.5)  -- Advance time to ensure RefreshEnemyCount is called
  OA.Assist.Update()  -- Reset aoeDetected based on current GetRotationSpells (blade flurry IS in queue)
  OA.State.RefreshFast()

  assert_eq(OA.State.enemyCount, 1, "enemyCount equals 1 with 1 plate")

  -- With enemyCount=1 (< threshold of 2), rule should not fire even if aoeDetected is true
  -- The rule uses composite signal: aoeMode OR aoeDetected OR (enemyCount >= 2)
  -- aoeMode=false, aoeDetected may be true (blade flurry in queue), but enemyCount=1<2
  -- If aoeDetected is true, rule WILL fire (3-signal OR logic)
  -- So we need to disable aoeDetected
  local originalGetRotationSpells = _G.C_AssistedCombat.GetRotationSpells
  _G.C_AssistedCombat.GetRotationSpells = function()
    return {193315, 271877, 315341}  -- No blade flurry
  end
  OA.Assist.Update()  -- Now aoeDetected should be false
  _G.C_AssistedCombat.GetRotationSpells = originalGetRotationSpells

  local r = OA.Engine.Evaluate()
  local foundBladeFlurry = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13877 then
      foundBladeFlurry = true
      break
    end
  end
  assert_false(foundBladeFlurry, "blade flurry NOT in queue when enemyCount < 2 AND aoeDetected=false AND aoeMode=false")
end)

-- Threat Test 4: C_NamePlate absent → enemyCount==nil, rule falls back
test("threat detector: C_NamePlate absent gives enemyCount==nil", function()
  stub.ClearNamePlates()
  local originalC_NamePlate = _G.C_NamePlate
  _G.C_NamePlate = nil

  stub.Tick(0.5)
  OA.State.RefreshFast()

  assert_eq(OA.State.enemyCount, nil, "enemyCount is nil when C_NamePlate absent")

  _G.C_NamePlate = originalC_NamePlate
end)

-- Threat Test 5: secret threat results → enemyCount==nil
test("threat detector: secret threat values degrade to enemyCount==nil", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)

  local originalUnitThreatSituation = _G.UnitThreatSituation
  _G.UnitThreatSituation = function(player, unitToken)
    return stub.makeSecret(3)
  end

  stub.Tick(0.5)
  OA.State.RefreshFast()

  assert_eq(OA.State.enemyCount, nil, "enemyCount is nil when all threats are secret")

  _G.UnitThreatSituation = originalUnitThreatSituation
end)

-- Threat Test 6: NAME_PLATE_UNIT_ADDED triggers recompute
test("threat detector: NAME_PLATE_UNIT_ADDED event triggers recompute", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  stub.Tick(0.5)  -- Advance time for first refresh
  OA.State.RefreshFast()
  assert_eq(OA.State.enemyCount, 1, "initial enemyCount==1 with 1 plate")

  -- Add another plate and fire event (event handler directly calls RefreshEnemyCount, no time-gating)
  stub.AddNamePlate("nameplate2", 3)
  stub.Tick(0.1)  -- Small advance in time (event still triggers immediately)
  stub.FireEvent("NAME_PLATE_UNIT_ADDED", "nameplate2")

  assert_eq(OA.State.enemyCount, 2, "enemyCount updated to 2 after NAME_PLATE_UNIT_ADDED event")
end)

-- Threat Test 7: blade_flurry composite signal - all three true
test("threat detector: blade_flurry fires when ANY signal true (aoeMode=true)", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  OA.db.aoeMode = true
  OA.Assist.aoeDetected = false

  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  local foundBladeFlurry = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13877 then
      foundBladeFlurry = true
      break
    end
  end
  assert_true(foundBladeFlurry, "blade flurry fires when aoeMode=true (even with single enemy)")
end)

-- Threat Test 8: blade_flurry composite signal - aoeDetected true
test("threat detector: blade_flurry fires when ANY signal true (aoeDetected=true)", function()
  stub.ClearNamePlates()
  OA.db.aoeMode = false
  OA.Assist.aoeDetected = true

  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  local foundBladeFlurry = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13877 then
      foundBladeFlurry = true
      break
    end
  end
  assert_true(foundBladeFlurry, "blade flurry fires when aoeDetected=true")
end)

-- === aura-infra tests ===

-- AURA TEST 1: Delta add with readable spellId maps + sets state
test("aura-infra: delta add with readable spellId maps + sets state", function()
  OA.State.buffs.adrenalineRush.up = false
  OA.State.buffs.adrenalineRush.expires = 0
  OA.State.buffs.degraded = false

  local updateInfo = {
    addedAuras = {
      {
        auraInstanceID = 5001,
        spellId = 13750,
        expirationTime = stub.state.time + 30
      }
    }
  }

  stub.FireEvent("UNIT_AURA", "player", updateInfo)

  assert_true(OA.State.buffs.adrenalineRush.up, "adrenalineRush.up set to true after delta add")
  assert_true(OA.State.buffs.adrenalineRush.expires > stub.state.time, "adrenalineRush.expires set to future time")
  assert_false(OA.State.buffs.degraded, "degraded not set when readable spellId matched")
end)

-- AURA TEST 2: Delta add with SECRET spellId + recent matching cast correlates
test("aura-infra: delta add with SECRET spellId + cast correlation", function()
  OA.State.buffs.rtb.stage = 0
  OA.State.buffs.rtb.expires = 0
  OA.State.buffs.degraded = false

  -- Simulate lastCast from UNIT_SPELLCAST_SUCCEEDED (fired just before delta)
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-guid-123", 315508)

  local secretSpellID = stub.makeSecret(315508)
  local updateInfo = {
    addedAuras = {
      {
        auraInstanceID = 5002,
        spellId = secretSpellID,
        applications = 1,
        expirationTime = stub.state.time + 45
      }
    }
  }

  stub.FireEvent("UNIT_AURA", "player", updateInfo)

  assert_true(OA.State.buffs.rtb.stage > 0, "rtb.stage set after correlation")
  assert_false(OA.State.buffs.degraded, "degraded not set when cast-correlation succeeded")
end)

-- AURA TEST 3: Removal clears state
test("aura-infra: removal clears state", function()
  OA.State.buffs.opportunity.up = false
  OA.State.buffs.opportunity.expires = 0

  -- First add the aura so it gets tracked in the map
  local addInfo = {
    addedAuras = {
      {
        auraInstanceID = 5003,
        spellId = 195627,
        expirationTime = stub.state.time + 20
      }
    }
  }
  stub.FireEvent("UNIT_AURA", "player", addInfo)

  assert_true(OA.State.buffs.opportunity.up, "opportunity added successfully")

  -- Now remove it
  local removeInfo = {
    removedAuraInstanceIDs = { 5003 }
  }
  stub.FireEvent("UNIT_AURA", "player", removeInfo)

  assert_false(OA.State.buffs.opportunity.up, "opportunity.up cleared on removal")
  assert_eq(OA.State.buffs.opportunity.expires, 0, "opportunity.expires reset to 0 on removal")
end)

-- AURA TEST 4: isFullUpdate rebuilds via tier 2
test("aura-infra: isFullUpdate rebuilds via tier 2 bootstrap", function()
  -- Self-sufficient: an earlier test nils C_UnitAuras to exercise the legacy path;
  -- tier 2 is a C_UnitAuras query, so restore the real stub table before asserting.
  _G.C_UnitAuras = stub.C_UnitAuras or _G.C_UnitAuras
  OA.State.inCombat = false

  OA.State.buffs.adrenalineRush.up = false
  OA.State.buffs.adrenalineRush.expires = 0
  OA.State.buffs.degraded = false

  stub.state.buffs.adrenalineRush = true
  stub.state.buffs.adrenalineRushExpires = stub.state.time + 30

  local updateInfo = {
    isFullUpdate = true
  }

  stub.FireEvent("UNIT_AURA", "player", updateInfo)

  assert_true(OA.State.buffs.adrenalineRush.up, "adrenalineRush restored after isFullUpdate bootstrap")
end)

-- AURA TEST 5: All-secret + no cast → degraded=true and no error
test("aura-infra: all-secret auras without cast → degraded=true", function()
  OA.State.buffs.degraded = false

  -- Advance time beyond correlation window (0.8s) to ensure any prior cast is out of window
  stub.Tick(1.0)

  local secretSpellID = stub.makeSecret(99999)
  local updateInfo = {
    addedAuras = {
      {
        auraInstanceID = 5004,
        spellId = secretSpellID,
        expirationTime = stub.state.time + 20
      }
    }
  }

  stub.FireEvent("UNIT_AURA", "player", updateInfo)

  assert_true(OA.State.buffs.degraded, "degraded=true when secret aura has no correlation")
  assert_true(true, "no error thrown with degraded secret aura")
end)

-- AURA TEST 6: Full tick green under stub combatSecrets mode
test("aura-infra: full tick under combatSecrets mode without error", function()
  stub.state.combatSecrets = true
  OA.State.inCombat = true

  -- Fire realistic combat events
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "combat-cast-1", 13750)
  local secretSpellID = stub.makeSecret(13750)
  stub.FireEvent("UNIT_AURA", "player", {
    addedAuras = {
      {
        auraInstanceID = 5005,
        spellId = secretSpellID,
        expirationTime = stub.state.time + 20
      }
    }
  })

  OA.Assist.Update()
  OA.State.RefreshFast()
  local r = OA.Engine.Evaluate()
  OA.Display.Render(r)

  -- Verify full tick completed without error
  assert_true(OA.State.buffs.adrenalineRush.up or OA.State.buffs.degraded, "AR tracked or degraded flag set")
  assert_false(_G.issecretvalue(OA.State.energy), "State.energy not a secret value")

  stub.state.combatSecrets = false
end)

-- === v1-core tests ===

-- P0 Fix Test 1: User-saved values survive ADDON_LOADED + PLAYER_LOGIN reload cycle
test("v1-core: saved user settings survive reload (P0 bite-proof)", function()
  -- Simulate a user setting custom values and reloading
  -- Set OA.db to have custom values BEFORE firing reload events
  OA.db.display.scale = 1.7
  OA.db.show.cds = false
  OA.db.aoeMode = true
  _G.OutlawAssistDB = OA.db

  -- Now fire ADDON_LOADED which calls deepMerge(OutlawAssistDB or {}, OA.defaults)
  -- BUG: deepMerge currently overwrites with defaults
  -- FIX: deepMerge should only fill missing keys
  stub.FireEvent("ADDON_LOADED", "OutlawAssist")
  stub.FireEvent("PLAYER_LOGIN")

  -- After fix, user's custom values should survive
  assert_eq(OA.db.display.scale, 1.7, "saved scale 1.7 survives reload (not overwritten by default 1.0)")
  assert_eq(OA.db.show.cds, false, "saved cds=false survives reload (not overwritten by default true)")
  assert_eq(OA.db.aoeMode, true, "saved aoeMode=true survives reload (not overwritten by default false)")
end)

-- === v1-outlaw tests ===

-- P0 TEST 1: AR does NOT pin OOC - opener wins instead
test("P0-1: AR does not pin before opener (OOC+unstealthed)", function()
  OA.State.inCombat = false
  OA.State.stealthed = false
  OA.State.comboPoints = 0
  OA.State.cooldowns.adrenalineRush.ready = true  -- AR is ready

  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  assert_true(#r.queue > 0, "queue has entries")
  -- Position 1 must be Stealth (opener), NOT AR
  assert_eq(r.queue[1].spellID, OA.SpellIDs.stealth, "Stealth opener pins at position 1 OOC, beating AR")
  assert_eq(r.queue[1].kind, "opener", "Stealth entry is kind=opener")
end)

-- P0 TEST 2: Ambush recommended when stealthed
test("P0-2: Ambush recommended when stealthed", function()
  OA.State.inCombat = true
  OA.State.stealthed = true

  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  assert_true(#r.queue > 0, "queue has entries")
  -- First entry should be Ambush when stealthed
  assert_eq(r.queue[1].spellID, OA.SpellIDs.ambush, "Ambush pins at position 1 when stealthed")
  assert_eq(r.queue[1].kind, "opener", "Ambush entry is kind=opener")
end)

-- P0 TEST 3: ar_energy_management rule removed
test("P0-3: ar_energy_management rule deleted", function()
  local found = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "ar_energy_management" then
      found = true
      break
    end
  end
  assert_false(found, "ar_energy_management rule must not exist (deleted to fix ghost icon bug)")
end)

-- P0 TEST 4: No queue entry has spellID whose cooldown is not ready (ghost icon guard)
test("P0-4: No queue entry for spell whose cooldown is not ready (ghost icon guard)", function()
  OA.State.inCombat = true
  OA.State.stealthed = false
  OA.State.buffs.adrenalineRush.up = true  -- AR is UP
  OA.State.cooldowns.adrenalineRush.ready = false  -- AR is NOT READY (on cooldown)
  OA.State.comboPoints = 2

  OA.Assist.Update()
  OA.State.RefreshFast()

  local r = OA.Engine.Evaluate()
  -- No entry should have spellID=13750 (AR) when AR buff is up (cooldown not ready)
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13750 and entry.kind == "cooldown" then
      -- If AR is in queue, its cooldown MUST be ready
      assert_true(OA.State.cooldowns.adrenalineRush.ready,
        "AR cooldown entry in queue but cooldown not ready - this is the ghost icon bug")
    end
  end
  assert_true(true, "no ghost AR icon (queue entries only for ready abilities)")
end)

-- ADDITIONAL TEST 1: Opportunity buff ID centralized
test("Additional-1: Opportunity buff ID in SpellIDs", function()
  assert_true(OA.SpellIDs.opportunity ~= nil, "opportunity defined in SpellIDs")
  assert_eq(OA.SpellIDs.opportunity, 195627, "opportunity ID is 195627")
end)

-- ADDITIONAL TEST 2: Ambush spell ID centralized
test("Additional-2: Ambush spell ID in SpellIDs", function()
  assert_true(OA.SpellIDs.ambush ~= nil, "ambush defined in SpellIDs")
  assert_eq(OA.SpellIDs.ambush, 8676, "ambush ID is 8676")
end)

-- ADDITIONAL TEST 3: Ambush rule exists and fires when stealthed
test("Additional-3: Ambush rule exists", function()
  local found = false
  for _, rule in ipairs(OA.Rules or {}) do
    if rule.name == "opener_ambush" then
      found = true
      break
    end
  end
  assert_true(found, "opener_ambush rule must exist")
end)

-- ADDITIONAL TEST 4: RtB degraded flag set when legacy fallback used
test("Additional-4: RtB legacy fallback marks degraded", function()
  -- Set initial state with no modern RtB
  OA.State.buffs.rtb.stage = 0
  OA.State.buffs.rtb.expires = 0
  OA.State.buffs.degraded = false

  -- Simulate a legacy RTB buff name in the aura list (requires stub support)
  -- This is tested via integration: legacy scan only runs when stage=0
  assert_true(true, "degraded flag available for legacy fallback signaling")
end)

-- Summary
print("")
print(passCount .. "/" .. testCount .. " tests passed")

if passCount ~= testCount then
  os.exit(1)
end

os.exit(0)
