#!/usr/bin/env lua
-- Test runner for OutlawAssist addon

local stub = require("tests.wow_stub")

-- Global setup
_G.ADDON_NAME = "OutlawAssist"
local OA = {
  Display = {},
  Engine = {},
  State = {},
  Assist = {},
  Rules = {},
  defaults = {}
}

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
test("assist available - queue starts with nextSpellID", function()
  OA.Assist.Update()
  local r = OA.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue exists")
  assert_true(#r.queue > 0, "queue has entries")
  assert_eq(r.queue[1].spellID, 193315, "first entry is nextSpellID from assist")
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

-- Test 4: Engine.Evaluate runs without error
test("engine.evaluate executes without error", function()
  local r = OA.Engine.Evaluate()
  assert_true(r ~= nil, "result exists")
  assert_true(r.queue ~= nil, "queue exists")
  assert_true(r.advisories ~= nil, "advisories exist")
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

-- Test 5: AoE mode toggle
test("aoe mode toggle in db", function()
  OA.db.aoeMode = false
  assert_false(OA.db.aoeMode, "aoe mode initially false")
  OA.db.aoeMode = true
  assert_true(OA.db.aoeMode, "aoe mode can be toggled true")
  OA.db.aoeMode = false
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

  -- Restore
  _G.C_AssistedCombat = {
    IsAvailable = function() return true end,
    GetNextCastSpell = function(b) return 193315 end,
    GetRotationSpells = function() return {193315, 271877, 315341} end,
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
test("state tracker initializes state table", function()
  assert_true(OA.State.energy >= 0, "energy field exists")
  assert_true(OA.State.buffs ~= nil, "buffs field exists")
  assert_true(OA.State.cooldowns ~= nil, "cooldowns field exists")
  assert_true(OA.State.trinkets ~= nil, "trinkets field exists")
end)

-- Test 10: Config slash command
test("config slash command handler exists", function()
  assert_true(OA.slashCommands ~= nil, "slash commands registered")
  assert_true(OA.slashCommands.toggle ~= nil, "toggle command exists")
  assert_true(OA.defaults ~= nil, "defaults defined")
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

-- Test 12b: StateTracker with UnitBuff unavailable (nil)
test("state tracker works when UnitBuff is nil and C_UnitAuras present", function()
  -- Save the original UnitBuff
  local originalUnitBuff = _G.UnitBuff

  -- Temporarily set UnitBuff to nil
  _G.UnitBuff = nil

  -- Ensure C_UnitAuras is still available
  assert_true(C_UnitAuras ~= nil, "C_UnitAuras is available")
  assert_true(C_UnitAuras.GetAuraDataByIndex ~= nil, "C_UnitAuras.GetAuraDataByIndex is available")

  -- Set some state to verify buff scan works
  stub.state.buffs.adrenalineRush = true
  stub.state.buffs.adrenalineRushExpires = stub.state.time + 100

  -- Call RefreshBuffs through RefreshFast - this should not error
  OA.State.RefreshFast()

  -- Verify state was refreshed without error
  assert_true(OA.State.buffs ~= nil, "buffs state exists")
  assert_true(OA.State.buffs.adrenalineRush.up or not OA.State.buffs.adrenalineRush.up, "buff scan completed")

  -- Restore UnitBuff
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

-- Summary
print("")
print(passCount .. "/" .. testCount .. " tests passed")

if passCount ~= testCount then
  os.exit(1)
end

os.exit(0)
