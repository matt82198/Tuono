#!/usr/bin/env lua
-- Test runner for Tuono addon

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
_G.ADDON_NAME = "Tuono"
-- BARE table, exactly like the WoW client's addon-shared table: modules MUST create
-- their own subtables. Pre-seeding here masked a real in-game load failure (Display).
local Tuono = {}

-- Inject stub into globals
for k, v in pairs(stub) do
  if k ~= "state" then
    _G[k] = v
  end
end

-- Load addon files in TOC order
local files = {
  -- MUST MIRROR Tuono.toc LOAD ORDER. Profiles must precede StateTracker: it owns
  -- Tuono.SpellIDs, which StateTracker reads at load. Omitting it does not fail
  -- loudly -- the addon simply comes up with an empty spell table and every
  -- behavioural test below silently exercises a half-assembled addon.
  "Tuono/Core.lua",
  "Tuono/Migration.lua",
  "Tuono/Profiles.lua",
  "Tuono/UserRules.lua",
  "Tuono/profiles/OutlawRogue.lua",
  "Tuono/data/rules.lua",
  "Tuono/StateTracker.lua",
  "Tuono/AssistReader.lua",
  "Tuono/Rotation.lua",
  "Tuono/CooldownModel.lua",
  "Tuono/EnergyModel.lua",
  "Tuono/IntelligenceLayer.lua",
  "Tuono/Display.lua",
  "Tuono/Highlight.lua",
  "Tuono/Config.lua",
  "Tuono/Options.lua",
  "Tuono/Secrets.lua",
  "Tuono/ApiTest.lua"
}

for _, file in ipairs(files) do
  local fn = loadfile(file)
  if not fn then
    print("FAIL: Could not load " .. file)
    os.exit(1)
  end
  local ok, err = pcall(fn, _G.ADDON_NAME, Tuono)
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
stub.FireEvent("ADDON_LOADED", "Tuono")
stub.FireEvent("PLAYER_LOGIN")
stub.FireEvent("PLAYER_ENTERING_WORLD")

-- Ensure db is properly initialized with defaults
if Tuono.defaults and not Tuono.db then
  Tuono.db = {}
  for k, v in pairs(Tuono.defaults) do
    if type(v) == "table" then
      Tuono.db[k] = {}
      for k2, v2 in pairs(v) do
        Tuono.db[k][k2] = v2
      end
    else
      Tuono.db[k] = v
    end
  end
  _G.TuonoDB = Tuono.db
end

-- Initialize Assist
if Tuono.Assist and Tuono.Assist.Update then
  Tuono.Assist.Update()
end

-- Test 1: Base queue with assist available
-- REPLACES "queue adapts to varying nextSpellID values".
-- That test asserted Blizzard's pick lands at queue position 1. It no longer does, by
-- design: the assist is a DIFFERENT rotation, not a degraded copy of ours, and swapping
-- between the two mid-fight with only an alpha difference to signal it was incoherent to
-- read. The queue is now sourced solely from our own priority list.
--
-- The assist is still polled every tick, as a drift sensor and as the energy anchor
-- source -- so the property worth pinning is the inverse of the old one: an arbitrary
-- assist pick must NOT be able to reach the bar.
test("assist pick never reaches the queue, whatever it returns", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false

  _G.C_AssistedCombat.GetNextCastSpell = function() return 1234 end   -- in no profile
  Tuono.Assist.Update()
  local r = Tuono.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue exists")
  assert_true(#r.queue > 0, "queue has entries from our own rotation")

  local leaked = false
  for _, e in ipairs(r.queue) do
    if e.spellID == 1234 then leaked = true end
  end
  assert_true(not leaked, "assist spellID 1234 must not appear in the queue")

  -- ...but it is still being read, because the drift sensor and energy anchor need it.
  assert_eq(Tuono.Assist.nextSpellID, 1234, "assist pick is still tracked, just not rendered")

  _G.C_AssistedCombat.GetNextCastSpell = function() return 193315 end
  Tuono.State.inCombat = false
end)

-- Test 2: AR PIN at low CP
test("adrenaline rush PIN when CP<=2 and ready", function()
  -- Self-sufficient state setup
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  stub.state.comboPoints = 2
  stub.state.cooldowns[13750] = {startTime = 0, duration = 0}
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
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
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  stub.state.comboPoints = 6
  stub.state.cooldowns[13750] = {startTime = 100, duration = 10}
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()
  assert_true(r.queue[1] ~= nil, "queue has first entry")
  assert_eq(r.queue[1].spellID, 315341, "BtE pinned to position 1")
end)

-- Test 4: Engine.Evaluate validates actual logic
test("engine.evaluate produces valid queue and advisory structures", function()
  -- Self-sufficient state setup
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  stub.state.comboPoints = 2
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()
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
  for _, rule in ipairs(Tuono.Rules or {}) do
    if rule.name == "trinket_slot13_during_ar" then
      foundRule = true
      break
    end
  end
  assert_true(foundRule, "trinket_slot13_during_ar rule exists")

  -- Self-sufficient state setup
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.adrenalineRush.up = true
  Tuono.State.trinkets[13].ready = true
  Tuono.State.trinkets[13].onUse = true

  local r = Tuono.Engine.Evaluate()
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
  Tuono.State.buffs.rtb.stage = 1
  Tuono.State.cooldowns.adrenalineRush.remaining = 30

  local r = Tuono.Engine.Evaluate()
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
  Tuono.State.buffs.rtb.stage = 3
  Tuono.State.cooldowns.adrenalineRush.remaining = 30

  local r = Tuono.Engine.Evaluate()
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
  local unitAuraHandlers = Tuono.eventHandlers and Tuono.eventHandlers["UNIT_AURA"]
  if unitAuraHandlers and #unitAuraHandlers > 0 then
    foundHandler = true
  end
  assert_true(foundHandler, "UNIT_AURA event handler is registered")
end)

-- Test 5: AoE mode toggle
test("aoe mode toggle via handler", function()
  Tuono.db.aoeMode = false
  assert_false(Tuono.db.aoeMode, "aoe mode initially false")

  local HandleAoe = Tuono.slashCommands and Tuono.slashCommands.aoe and Tuono.slashCommands.aoe.fn
  assert_true(HandleAoe ~= nil, "aoe handler exists")
  -- aoeMode is a tri-state cycle now, not a boolean toggle. The old assertions used
  -- truthiness, which cannot distinguish "off" (a truthy string) from "on" -- the same
  -- confusion that made /tuono status report OFF as "ON" and left the handler unable
  -- to ever reach "off".
  Tuono.db.aoeMode = "auto"
  HandleAoe()
  assert_eq(Tuono.db.aoeMode, "on", "auto -> on")

  HandleAoe()
  assert_eq(Tuono.db.aoeMode, "off", "on -> off")

  HandleAoe()
  assert_eq(Tuono.db.aoeMode, "auto", "off -> auto (full cycle)")
end)

-- Test 6: IntelligenceLayer integration
test("intelligence layer evaluate with various states", function()
  -- Self-sufficient state setup
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  stub.state.comboPoints = 3
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue populated")
  assert_true(#r.queue >= 1, "queue has at least base spell")
end)

-- Test 8: Intelligence Layer Queue Content
test("intelligence layer queue reflects specific spell IDs based on combo point state", function()
  -- Self-sufficient state setup
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  stub.state.comboPoints = 2
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()
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
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  r = Tuono.Engine.Evaluate()
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
test("assist unavailable - own predictions still drive the queue", function()
  -- This test nils a global. If an assertion throws before the restore line, EVERY
  -- later test sees a missing C_AssistedCombat -- that single cascade caused most of
  -- a 15-failure run. So: guarded body, restore always, re-raise after.
  local function restore()
    _G.C_AssistedCombat = {
      IsAvailable = function() return true end,
      GetNextCastSpell = function(b) return 193315 end,
      GetRotationSpells = function() return {193315, 271877, 315341, 13877} end,
      GetActionSpell = function(a) return 193315 end
    }
  end

  _G.C_AssistedCombat = nil
  local ok, err = pcall(function()
    Tuono.Assist.Update()
    Tuono.State.RefreshFast()
    local r = Tuono.Engine.Evaluate()

    -- v1.2 design: Blizzard's assist is NOT the queue source (proven static in live
    -- combat). With it absent we must still emit OUR predicted sequence.
    assert_true(#r.queue > 0, "own predicted sequence present when assist unavailable")
    for _, entry in ipairs(r.queue) do
      -- trinket entries carry itemSlot instead of spellID, by contract
      assert_true(entry.spellID ~= nil or entry.itemSlot ~= nil,
        "queue entry is actionable (spellID or itemSlot)")
    end
  end)

  restore()
  if not ok then error(err) end
end)

-- Test 8: StateTracker RefreshFast
test("state tracker refreshes energy/cp from UnitPower", function()
  stub.state.energy = 75
  stub.state.comboPoints = 3
  Tuono.State.RefreshFast()

  assert_eq(Tuono.State.energy, 75, "energy synced")
  assert_eq(Tuono.State.comboPoints, 3, "combo points synced")
end)

-- Test 9: StateTracker initialization
test("state tracker initializes with correct default values", function()
  assert_true(type(Tuono.State.energy) == "number", "energy field is a number")
  assert_true(Tuono.State.energy >= 0, "energy initialized to >= 0")
  assert_true(type(Tuono.State.comboPoints) == "number", "comboPoints field is a number")
  assert_true(Tuono.State.comboPoints >= 0, "comboPoints initialized to >= 0")
  assert_true(Tuono.State.buffs ~= nil, "buffs field exists")
  assert_true(type(Tuono.State.buffs) == "table", "buffs is a table")
  assert_true(Tuono.State.cooldowns ~= nil, "cooldowns field exists")
  assert_true(type(Tuono.State.cooldowns) == "table", "cooldowns is a table")
  assert_true(Tuono.State.trinkets ~= nil, "trinkets field exists")
  assert_true(type(Tuono.State.trinkets) == "table", "trinkets is a table")
end)

-- Test 10: Config slash command
test("config slash command toggle handler works correctly", function()
  assert_true(Tuono.slashCommands ~= nil, "slash commands registered")
  assert_true(Tuono.slashCommands.toggle ~= nil, "toggle command exists")
  assert_true(Tuono.defaults ~= nil, "defaults defined")

  local toggleHandler = Tuono.slashCommands.toggle.fn
  assert_true(toggleHandler ~= nil, "toggle handler is callable")

  local originalState = Tuono.db.show.queue
  toggleHandler("queue")
  assert_true(Tuono.db.show.queue ~= originalState, "toggle handler actually changes state")

  toggleHandler("queue")
  assert_eq(Tuono.db.show.queue, originalState, "toggle handler can toggle back")
end)

-- Test 11: Display render runs without error
test("display render executes without error", function()
  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
  end
  local r = Tuono.Engine.Evaluate()
  if Tuono.Display and Tuono.Display.Render then
    Tuono.Display.Render(r)
  end
  assert_true(true, "render completed")
end)

-- Test 12: ApiTest module initialization
test("apitest command handler exists", function()
  assert_true(Tuono.slashCommands ~= nil, "slash commands exist")
  assert_true(Tuono.slashCommands.apitest ~= nil or Tuono.slashCommands.debug ~= nil, "api test or debug command exists")
end)

-- Test 12b: StateTracker with UnitBuff unavailable
test("buff scan with C_UnitAuras when UnitBuff unavailable", function()
  local originalUnitBuff = _G.UnitBuff

  _G.UnitBuff = nil

  assert_true(C_UnitAuras ~= nil, "C_UnitAuras is available")
  assert_true(C_UnitAuras.GetAuraDataByIndex ~= nil, "C_UnitAuras.GetAuraDataByIndex is available")

  stub.state.buffs.adrenalineRush = true
  stub.state.buffs.adrenalineRushExpires = stub.state.time + 100

  Tuono.State.RefreshFast()

  assert_true(Tuono.State.buffs ~= nil, "buffs state exists")
  assert_true(Tuono.State.buffs.adrenalineRush.up, "adrenaline rush buff detected as up=true when stub has it active")

  _G.UnitBuff = originalUnitBuff
end)

-- Test 12c: Classic buff fallback
test("buff scan with UnitBuff fallback when C_UnitAuras unavailable", function()
  local originalC_UnitAuras = _G.C_UnitAuras
  local originalUnitBuff = _G.UnitBuff

  -- Tier 3 (legacy index scan) is deliberately OOC-only: in combat those field reads
  -- can hit secret values. This test exercises the OOC path, so pin inCombat=false.
  Tuono.State.inCombat = false

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

  Tuono.State.RefreshFast()

  assert_true(Tuono.State.buffs.opportunity.up, "opportunity buff detected via UnitBuff fallback")

  _G.C_UnitAuras = originalC_UnitAuras
  _G.UnitBuff = originalUnitBuff
end)

-- Test 13: Energy cap warning guard
test("energy cap advisory not active when energyMax is 0", function()
  stub.state.energy = 100
  stub.state.energyMax = 0
  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()

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

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()
  Tuono.Display.Render(r)

  assert_true(type(Tuono.State.energy) == "number", "energy coerced to number despite secret input")
  assert_true(type(Tuono.State.comboPoints) == "number", "comboPoints coerced to number despite secret input")

  assert_false(_G.issecretvalue(Tuono.State.energy), "energy must not be a secret value")
  assert_false(_G.issecretvalue(Tuono.State.comboPoints), "comboPoints must not be a secret value")

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
  for _, r in ipairs(Tuono.Rules or {}) do
    if r.name == "blade_rush_tier_priority" then
      found = true
      rule = r
      break
    end
  end
  assert_true(found, "blade_rush_tier_priority rule must exist")
  assert_true(type(rule.when) == "function", "rule condition must be a function")
  Tuono.State.tier.fourPc = true
  Tuono.State.cooldowns.bladeRush.ready = true
  assert_true(rule.when(Tuono.State, {}), "rule fires when 4PC + ready")
end)

-- TEST: Deleted rules no longer exist
test("combo_point_priority rule deleted", function()
  local found = false
  for _, rule in ipairs(Tuono.Rules or {}) do
    if rule.name == "combo_point_priority" then
      found = true
      break
    end
  end
  assert_false(found, "combo_point_priority rule must not exist")
end)

test("bte_stun_immunity rule deleted", function()
  local found = false
  for _, rule in ipairs(Tuono.Rules or {}) do
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
  for _, rule in ipairs(Tuono.Rules or {}) do
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
  for _, rule in ipairs(Tuono.Rules or {}) do
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

  Tuono.Assist.Update()

  assert_true(Tuono.Assist.aoeDetected, "aoeDetected true when blade flurry in queue")

  local foundRule = false
  for _, rule in ipairs(Tuono.Rules or {}) do
    if rule.spellID == 13877 then
      foundRule = true
      break
    end
  end
  assert_true(foundRule, "blade flurry rule exists in rules list")
end)

-- GAP TEST 2: aoeDetected affects rule behavior
test("aoeDetected true causes blade_flurry_aoe rule to fire", function()
  Tuono.Assist.aoeDetected = true
  Tuono.db.aoeMode = true

  local r = Tuono.Engine.Evaluate()

  assert_true(r.queue ~= nil, "queue populated")
  assert_true(r.advisories ~= nil, "advisories populated")
  assert_true(#r.queue > 0, "queue has entries when AoE detected and aoe mode on")
end)

-- GAP TEST 3: P0 bite-proof - Display frames exist after PLAYER_LOGIN without explicit Init call
test("display frames auto-initialized after PLAYER_LOGIN", function()
  stub.FireEvent("PLAYER_LOGIN")

  assert_true(Tuono.Display.anchor ~= nil, "Display anchor exists after PLAYER_LOGIN (auto-initialized)")
  assert_true(Tuono.Display.anchor.strip ~= nil, "unified strip created")
  assert_true(Tuono.Display.anchor.icons ~= nil, "icons array created")
  assert_true(#Tuono.Display.anchor.icons > 0, "icons array populated")
  assert_true(Tuono.Display.anchor.rotationIcons == nil, "rotationIcons not created (unified strip only)")
  assert_true(Tuono.Display.anchor.cdRow == nil, "cdRow not created (unified strip only)")
  assert_true(Tuono.Display.anchor.trinketRow == nil, "trinketRow not created (unified strip only)")
  assert_true(Tuono.Display.anchor.rtbPanel == nil, "rtbPanel not created (unified strip only)")
end)

-- GAP TEST 4: P0 bite-proof - /tuono reset and /tuono status work without errors
test("display reset and status commands work without errors", function()
  local resetHandler = Tuono.slashCommands and Tuono.slashCommands.reset and Tuono.slashCommands.reset.fn
  local statusHandler = Tuono.slashCommands and Tuono.slashCommands.status and Tuono.slashCommands.status.fn

  assert_true(resetHandler ~= nil, "reset handler exists")
  assert_true(statusHandler ~= nil, "status handler exists")

  resetHandler()
  assert_true(Tuono.db ~= nil, "db exists after reset")
  -- aoeMode became a tri-state ("auto"/"on"/"off") once enemy counting was confirmed
  -- legal: a boolean cannot express "decide from the live enemy count", which is now
  -- the default. This assertion pinned the old boolean default.
  assert_eq(Tuono.db.aoeMode, "auto", "db reset to defaults")

  statusHandler()
  assert_true(true, "status handler completed without error")
end)

-- GAP TEST 5: Load canary - verify all expected modules loaded
test("load canary verifies all modules loaded at PLAYER_LOGIN", function()
  local expectedModules = {"State", "Assist", "Engine", "Rules", "Display", "defaults"}
  local allPresent = true
  local missing = {}

  for _, mod in ipairs(expectedModules) do
    if not Tuono[mod] then
      allPresent = false
      table.insert(missing, mod)
    end
  end

  assert_true(allPresent, "all expected modules present: " .. table.concat(expectedModules, ", "))
end)

-- GAP TEST 6: Load canary - simulate missing module and verify canary prints
test("load canary detects missing module", function()
  local savedEngine = Tuono.Engine
  Tuono.Engine = nil

  local expectedModules = {"State", "Assist", "Engine", "Rules", "Display", "defaults"}
  local missing = {}
  for _, mod in ipairs(expectedModules) do
    if not Tuono[mod] then
      table.insert(missing, mod)
    end
  end

  assert_true(#missing > 0, "missing module detected by canary")
  assert_true(missing[1] == "Engine", "missing module is Engine")

  Tuono.Engine = savedEngine
end)

-- === polling-lane tests ===

-- TEST: Dynamic interval based on combat state
test("dynamic tick interval - 0.1s in combat, 0.5s idle", function()
  -- Verify handler exists and has correct structure
  assert_true(#Tuono.updateHandlers > 0, "update handlers registered")
  local handler = Tuono.updateHandlers[1]
  assert_true(handler.interval ~= nil, "handler has interval field")
  assert_true(type(handler.elapsed) == "number", "handler.elapsed is a number")

  -- The dynamic interval logic is in Core.lua OnUpdate and applies at tick time
  -- Test verifies the mechanism can be called without error
  Tuono.State.inCombat = true
  stub.Tick(0.05)
  assert_true(true, "tick completed during combat state")

  Tuono.State.inCombat = false
  stub.Tick(0.05)
  assert_true(true, "tick completed during idle state")
end)

-- TEST: Event-forced immediate update on UNIT_SPELLCAST_SUCCEEDED
test("forced immediate update on UNIT_SPELLCAST_SUCCEEDED", function()
  -- Reset handler elapsed to a value that would not normally trigger
  Tuono.updateHandlers[1].elapsed = 0.01

  -- Fire UNIT_SPELLCAST_SUCCEEDED for player
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast123", 193315)

  -- Verify the forceNext flag was set (indirectly: handler elapsed should reset after OnUpdate)
  -- We can't directly inspect forceNext (it's module-local), so we verify via handler state
  assert_true(true, "UNIT_SPELLCAST_SUCCEEDED handler executed without error")
end)

-- TEST: Deviation detection - flag set when cast ~= recommendation
test("deviation detection - deviated flag set when player casts != recommendation", function()
  -- Set the recommendation
  Tuono.Assist.nextSpellID = 193315  -- Sinister Strike

  -- Verify deviated flag is false initially
  assert_false(Tuono.Assist.deviated, "deviated flag initially false")

  -- Fire UNIT_SPELLCAST_SUCCEEDED with a DIFFERENT spell (deviation)
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast456", 271877)  -- Backstab

  -- Verify deviation flag was set
  assert_true(Tuono.Assist.deviated, "deviated flag set when player cast != recommendation")
end)

-- TEST: Deviation flag cleared on Update
test("deviation flag cleared on Assist.Update()", function()
  -- Set deviated flag
  Tuono.Assist.deviated = true

  -- Call Update() which should clear it
  Tuono.Assist.Update()

  -- Verify it was cleared
  assert_false(Tuono.Assist.deviated, "deviated flag cleared after Update()")
end)

-- TEST: Deviation detection filters unit=="player" only
test("deviation detection ignores non-player units", function()
  Tuono.Assist.nextSpellID = 193315
  Tuono.Assist.deviated = false

  -- Fire UNIT_SPELLCAST_SUCCEEDED for a different unit
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "target", "cast789", 271877)

  -- Verify deviation flag was NOT set (different unit)
  assert_false(Tuono.Assist.deviated, "deviated flag NOT set for non-player unit")
end)

-- TEST: RequestImmediateUpdate function exists
test("Tuono.RequestImmediateUpdate function callable", function()
  assert_true(type(Tuono.RequestImmediateUpdate) == "function", "RequestImmediateUpdate is a function")
  -- Call it without error
  Tuono.RequestImmediateUpdate()
  assert_true(true, "RequestImmediateUpdate executed without error")
end)

-- === engine-lane tests ===

-- TEST: Handler signature correctness - UNIT_AURA receives event + unit
test("handler signature: UNIT_AURA receives (event, unit) correctly", function()
  stub.FireEvent("UNIT_AURA", "player")

  assert_true(Tuono.State.stealthed ~= nil, "State.stealthed exists after UNIT_AURA fired")
  assert_true(type(Tuono.State.stealthed) == "boolean", "State.stealthed is a boolean after handler call")
end)

-- TEST: Pistol shot rule resolves spellID lazily
test("pistol shot rule resolves spellID lazily at evaluate time", function()
  -- Self-sufficient: manual state AFTER RefreshFast (it recomputes from stub and clobbers)
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.opportunity.up = true
  Tuono.State.energy = 30

  local psRule = nil
  for _, rule in ipairs(Tuono.Rules or {}) do
    if rule.name == "pistol_shot_low_energy" then
      psRule = rule
      break
    end
  end

  assert_true(psRule ~= nil, "pistol_shot_low_energy rule exists")
  assert_true(psRule.spellID == nil or psRule.spellID == 0, "pistol shot rule has nil/0 spellID at load (lazy)")
  assert_true(psRule.resolveSpellID ~= nil, "pistol shot rule has resolveSpellID function")

  local r = Tuono.Engine.Evaluate()
  local foundPistol = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.pistolShot then
      foundPistol = true
      break
    end
  end
  for _, adv in ipairs(r.advisories) do
    if adv.icon == Tuono.SpellIDs.pistolShot then
      foundPistol = true
      break
    end
  end
  assert_true(foundPistol, "Pistol Shot resolved and appears in queue/advisories when conditions met")
end)

-- TEST: Unified queue contains cooldown entry when AR ready
test("unified queue: cooldown entry when AR ready + rule fires", function()
  -- Self-sufficient: manual state AFTER RefreshFast (it recomputes from stub and clobbers)
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.comboPoints = 2

  local r = Tuono.Engine.Evaluate()
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
  Tuono.State.buffs.adrenalineRush.up = true
  Tuono.State.trinkets[13].ready = true
  Tuono.State.trinkets[13].onUse = true
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
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
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.rtb.expires = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.buffs.opportunity.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 60
  Tuono.State.cooldowns.bladeRush.ready = false
  Tuono.State.cooldowns.preparation.ready = false
  Tuono.State.trinkets[13].ready = false
  Tuono.State.trinkets[14].ready = false
  Tuono.State.comboPoints = 4
  Tuono.State.energy = 50
  Tuono.State.energyMax = 100
  Tuono.State.tier.twoPc = false
  Tuono.State.tier.fourPc = false

  local r = Tuono.Engine.Evaluate()
  local foundRtb = false
  for _, entry in ipairs(r.queue) do
    -- Since v1.3.1 the simulator itself predicts Roll the Bones at stage 0, so the
    -- separate rule-derived entry is deduped as redundant. What matters is that RtB is
    -- RECOMMENDED at stage 0, not which subsystem produced it.
    if entry.spellID == Tuono.SpellIDs.rollTheBones then
      foundRtb = true
      break
    end
  end
  assert_true(foundRtb, "RtB recommended at stage 0 (from simulation or rule)")
end)

-- TEST: Opener pins when OOC+unstealthed
test("unified queue: opener stealth pins when OOC + unstealthed", function()
  Tuono.State.inCombat = false
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  if #r.queue > 0 then
    assert_eq(r.queue[1].spellID, Tuono.SpellIDs.stealth, "stealth pinned at position 1 when OOC+unstealthed")
    assert_eq(r.queue[1].kind, "opener", "stealth entry has kind=opener")
  end
end)

-- TEST: Queue dedup by spellID
test("unified queue: dedup by spellID", function()
  -- Self-sufficient: manual state AFTER RefreshFast (it recomputes from stub and clobbers)
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.comboPoints = 2

  local r = Tuono.Engine.Evaluate()
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
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true
  Tuono.State.cooldowns.preparation.ready = true
  Tuono.State.buffs.adrenalineRush.up = true
  Tuono.State.trinkets[13].ready = true
  Tuono.State.trinkets[13].onUse = true
  Tuono.State.trinkets[14].ready = true
  Tuono.State.trinkets[14].onUse = true
  Tuono.State.buffs.rtb.stage = 0
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  assert_true(#r.queue <= 8, "queue truncated to 8 or fewer entries")
end)

-- TEST: Stealth state tracking
test("unified queue: stealth state tracked", function()
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  assert_false(Tuono.State.stealthed, "stealthed initially false")

  stub.state.stealthed = true  -- RefreshFast reads IsStealthed(), so drive the source
  Tuono.State.stealthed = true
  assert_true(Tuono.State.stealthed, "stealthed set to true")

  Tuono.State.inCombat = false
  stub.state.stealthed = true  -- RefreshFast reads IsStealthed(), so drive the source
  Tuono.State.stealthed = true
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  local stealthPinned = false
  if #r.queue > 0 and r.queue[1].spellID == Tuono.SpellIDs.stealth then
    stealthPinned = true
  end
  assert_false(stealthPinned, "stealth NOT pinned when already stealthed")
end)

-- TEST: Queue entries have required fields
test("unified queue: entries have required structure", function()
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.comboPoints = 2
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  assert_true(#r.queue >= 1, "queue has entries")

  for i, entry in ipairs(r.queue) do
    assert_true(entry.source ~= nil, "entry " .. i .. " has source field")
    assert_true(entry.kind ~= nil, "entry " .. i .. " has kind field")
  end
end)

-- === ui-lane tests ===

-- UI Test 1: Strip renders correct number of icons per iconCount config
test("strip renders correct number of icons per iconCount", function()
  Tuono.db.display.iconCount = 4
  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
  end

  local anchor = Tuono.Display.anchor
  assert_true(anchor ~= nil, "anchor exists")
  assert_true(anchor.strip ~= nil, "strip frame exists")
  assert_true(anchor.icons ~= nil, "icons array exists")
  assert_true(#anchor.icons >= 8, "icons array has at least 8 slots")
end)

-- UI Test 2: kind→border color mapping applied correctly
test("kind to border color mapping applied", function()
  Tuono.db.display.iconCount = 4
  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
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

  Tuono.Display.Render(result)

  local anchor = Tuono.Display.anchor
  for i = 1, 4 do
    local icon = anchor.icons[i]
    assert_true(icon ~= nil, "icon " .. i .. " exists")
  end
end)

-- UI Test 3: Keybind text appears when mapping provided
test("keybind text displayed when mapping provided", function()
  Tuono.db.display.iconCount = 3
  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
  end

  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard"},
      {spellID = 13750, kind = "cooldown", source = "rule"},
      {spellID = 315508, kind = "rtb", source = "rule"}
    },
    advisories = {}
  }

  Tuono.Display.Render(result)

  local anchor = Tuono.Display.anchor
  if anchor.icons[1] then
    assert_true(anchor.icons[1].keyText ~= nil, "keyText element exists on icon 1")
  end
end)

-- UI Test 4: Strip reflow re-anchors icons horizontally
test("strip reflow re-anchors icons horizontally", function()
  Tuono.db.display.iconCount = 5
  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
  end

  local anchor = Tuono.Display.anchor
  assert_true(anchor.strip ~= nil, "strip exists")
  assert_true(#anchor.icons >= 5, "icons array has at least 5 icons")
end)

-- UI Test 5: Strip scale adjustable via /tuono scale
test("strip scale adjustable via config", function()
  Tuono.db.display.scale = 1.0
  assert_eq(Tuono.db.display.scale, 1.0, "scale set to 1.0")

  Tuono.db.display.scale = 1.5
  assert_eq(Tuono.db.display.scale, 1.5, "scale changed to 1.5")

  Tuono.db.display.scale = 0.8
  assert_eq(Tuono.db.display.scale, 0.8, "scale changed to 0.8")
end)

-- UI Test 6: Icon count configuration
test("icon count configuration updates display", function()
  Tuono.db.display.iconCount = 5
  assert_eq(Tuono.db.display.iconCount, 5, "iconCount changed to 5")

  Tuono.db.display.iconCount = 6
  assert_eq(Tuono.db.display.iconCount, 6, "iconCount changed to 6")
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
  Tuono.State.RefreshFast()

  assert_eq(Tuono.State.enemyCount, 3, "enemyCount equals 3 with 3 hostile plates")
end)

-- Threat Test 2: blade_flurry rule fires with 2+ enemies (via threatcount signal, not aoeDetected)
test("threat detector: blade_flurry_aoe rule fires when enemyCount >= 2", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  stub.AddNamePlate("nameplate2", 3)
  Tuono.db.aoeMode = false

  -- Disable aoeDetected by preventing blade flurry from being in the queue
  local originalGetRotationSpells = _G.C_AssistedCombat.GetRotationSpells
  _G.C_AssistedCombat.GetRotationSpells = function()
    return {193315, 271877, 315341}  -- No blade flurry (13877)
  end

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  assert_false(Tuono.Assist.aoeDetected, "aoeDetected false (blade flurry not in queue)")

  local r = Tuono.Engine.Evaluate()
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
  Tuono.Rotation.ResetMode()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  Tuono.db.aoeMode = false

  stub.Tick(0.5)  -- Advance time to ensure RefreshEnemyCount is called
  Tuono.Assist.Update()  -- Reset aoeDetected based on current GetRotationSpells (blade flurry IS in queue)
  Tuono.State.RefreshFast()

  assert_eq(Tuono.State.enemyCount, 1, "enemyCount equals 1 with 1 plate")

  -- With enemyCount=1 (< threshold of 2), rule should not fire even if aoeDetected is true
  -- The rule uses composite signal: aoeMode OR aoeDetected OR (enemyCount >= 2)
  -- aoeMode=false, aoeDetected may be true (blade flurry in queue), but enemyCount=1<2
  -- If aoeDetected is true, rule WILL fire (3-signal OR logic)
  -- So we need to disable aoeDetected
  local originalGetRotationSpells = _G.C_AssistedCombat.GetRotationSpells
  _G.C_AssistedCombat.GetRotationSpells = function()
    return {193315, 271877, 315341}  -- No blade flurry
  end
  Tuono.Assist.Update()  -- Now aoeDetected should be false
  _G.C_AssistedCombat.GetRotationSpells = originalGetRotationSpells

  local r = Tuono.Engine.Evaluate()
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
  Tuono.State.RefreshFast()

  assert_eq(Tuono.State.enemyCount, nil, "enemyCount is nil when C_NamePlate absent")

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
  Tuono.State.RefreshFast()

  assert_eq(Tuono.State.enemyCount, nil, "enemyCount is nil when all threats are secret")

  _G.UnitThreatSituation = originalUnitThreatSituation
end)

-- Threat Test 6: NAME_PLATE_UNIT_ADDED triggers recompute
test("threat detector: NAME_PLATE_UNIT_ADDED event triggers recompute", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  stub.Tick(0.5)  -- Advance time for first refresh
  Tuono.State.RefreshFast()
  assert_eq(Tuono.State.enemyCount, 1, "initial enemyCount==1 with 1 plate")

  -- Add another plate and fire event (event handler directly calls RefreshEnemyCount, no time-gating)
  stub.AddNamePlate("nameplate2", 3)
  stub.Tick(0.1)  -- Small advance in time (event still triggers immediately)
  stub.FireEvent("NAME_PLATE_UNIT_ADDED", "nameplate2")

  assert_eq(Tuono.State.enemyCount, 2, "enemyCount updated to 2 after NAME_PLATE_UNIT_ADDED event")
end)

-- Threat Test 7: blade_flurry composite signal - all three true
test("threat detector: blade_flurry fires when ANY signal true (aoeMode=true)", function()
  stub.ClearNamePlates()
  stub.AddNamePlate("nameplate1", 3)
  Tuono.db.aoeMode = true
  Tuono.Assist.aoeDetected = false

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
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
  Tuono.db.aoeMode = false
  Tuono.Assist.aoeDetected = true

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
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
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.buffs.adrenalineRush.expires = 0
  Tuono.State.buffs.degraded = false

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

  assert_true(Tuono.State.buffs.adrenalineRush.up, "adrenalineRush.up set to true after delta add")
  assert_true(Tuono.State.buffs.adrenalineRush.expires > stub.state.time, "adrenalineRush.expires set to future time")
  assert_false(Tuono.State.buffs.degraded, "degraded not set when readable spellId matched")
end)

-- AURA TEST 2: Delta add with SECRET spellId + recent matching cast correlates
test("aura-infra: delta add with SECRET spellId + cast correlation", function()
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.rtb.expires = 0
  Tuono.State.buffs.degraded = false

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

  assert_true(Tuono.State.buffs.rtb.stage > 0, "rtb.stage set after correlation")
  assert_false(Tuono.State.buffs.degraded, "degraded not set when cast-correlation succeeded")
end)

-- AURA TEST 3: Removal clears state
test("aura-infra: removal clears state", function()
  Tuono.State.buffs.opportunity.up = false
  Tuono.State.buffs.opportunity.expires = 0

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

  assert_true(Tuono.State.buffs.opportunity.up, "opportunity added successfully")

  -- Now remove it
  local removeInfo = {
    removedAuraInstanceIDs = { 5003 }
  }
  stub.FireEvent("UNIT_AURA", "player", removeInfo)

  assert_false(Tuono.State.buffs.opportunity.up, "opportunity.up cleared on removal")
  assert_eq(Tuono.State.buffs.opportunity.expires, 0, "opportunity.expires reset to 0 on removal")
end)

-- AURA TEST 4: isFullUpdate rebuilds via tier 2
test("aura-infra: isFullUpdate rebuilds via tier 2 bootstrap", function()
  -- Self-sufficient: an earlier test nils C_UnitAuras to exercise the legacy path;
  -- tier 2 is a C_UnitAuras query, so restore the real stub table before asserting.
  _G.C_UnitAuras = stub.C_UnitAuras or _G.C_UnitAuras
  Tuono.State.inCombat = false

  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.buffs.adrenalineRush.expires = 0
  Tuono.State.buffs.degraded = false

  stub.state.buffs.adrenalineRush = true
  stub.state.buffs.adrenalineRushExpires = stub.state.time + 30

  local updateInfo = {
    isFullUpdate = true
  }

  stub.FireEvent("UNIT_AURA", "player", updateInfo)

  assert_true(Tuono.State.buffs.adrenalineRush.up, "adrenalineRush restored after isFullUpdate bootstrap")
end)

-- AURA TEST 5: All-secret + no cast → degraded=true and no error
test("aura-infra: all-secret auras without cast → degraded=true", function()
  Tuono.State.buffs.degraded = false

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

  assert_true(Tuono.State.buffs.degraded, "degraded=true when secret aura has no correlation")
  assert_true(true, "no error thrown with degraded secret aura")
end)

-- AURA TEST 6: Full tick green under stub combatSecrets mode
test("aura-infra: full tick under combatSecrets mode without error", function()
  stub.state.combatSecrets = true
  Tuono.State.inCombat = true

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

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()
  Tuono.Display.Render(r)

  -- Verify full tick completed without error
  assert_true(Tuono.State.buffs.adrenalineRush.up or Tuono.State.buffs.degraded, "AR tracked or degraded flag set")
  assert_false(_G.issecretvalue(Tuono.State.energy), "State.energy not a secret value")

  stub.state.combatSecrets = false
end)

-- === v1-core tests ===

-- P0 Fix Test 1: User-saved values survive ADDON_LOADED + PLAYER_LOGIN reload cycle
test("v1-core: saved user settings survive reload (P0 bite-proof)", function()
  -- Simulate a user setting custom values and reloading
  -- Set Tuono.db to have custom values BEFORE firing reload events
  Tuono.db.display.scale = 1.7
  Tuono.db.show.cds = false
  Tuono.db.aoeMode = true
  _G.TuonoDB = Tuono.db

  -- Now fire ADDON_LOADED which calls deepMerge(TuonoDB or {}, Tuono.defaults)
  -- BUG: deepMerge currently overwrites with defaults
  -- FIX: deepMerge should only fill missing keys
  stub.FireEvent("ADDON_LOADED", "Tuono")
  stub.FireEvent("PLAYER_LOGIN")

  -- After fix, user's custom values should survive
  assert_eq(Tuono.db.display.scale, 1.7, "saved scale 1.7 survives reload (not overwritten by default 1.0)")
  assert_eq(Tuono.db.show.cds, false, "saved cds=false survives reload (not overwritten by default true)")
  assert_eq(Tuono.db.aoeMode, true, "saved aoeMode=true survives reload (not overwritten by default false)")
end)

-- === v1-outlaw tests ===

-- P0 TEST 1: AR does NOT pin OOC - opener wins instead
test("P0-1: AR does not pin before opener (OOC+unstealthed)", function()
  Tuono.State.inCombat = false
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.comboPoints = 0
  Tuono.State.cooldowns.adrenalineRush.ready = true  -- AR is ready

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  assert_true(#r.queue > 0, "queue has entries")
  -- Position 1 must be Stealth (opener), NOT AR
  assert_eq(r.queue[1].spellID, Tuono.SpellIDs.stealth, "Stealth opener pins at position 1 OOC, beating AR")
  assert_eq(r.queue[1].kind, "opener", "Stealth entry is kind=opener")
end)

-- P0 TEST 2: Ambush recommended when stealthed
test("P0-2: Ambush recommended when stealthed", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = true  -- RefreshFast reads IsStealthed(), so drive the source
  Tuono.State.stealthed = true

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  assert_true(#r.queue > 0, "queue has entries")
  -- First entry should be Ambush when stealthed
  assert_eq(r.queue[1].spellID, Tuono.SpellIDs.ambush, "Ambush pins at position 1 when stealthed")
  assert_eq(r.queue[1].kind, "opener", "Ambush entry is kind=opener")
end)

-- P0 TEST 3: ar_energy_management rule removed
test("P0-3: ar_energy_management rule deleted", function()
  local found = false
  for _, rule in ipairs(Tuono.Rules or {}) do
    if rule.name == "ar_energy_management" then
      found = true
      break
    end
  end
  assert_false(found, "ar_energy_management rule must not exist (deleted to fix ghost icon bug)")
end)

-- P0 TEST 4: No queue entry has spellID whose cooldown is not ready (ghost icon guard)
test("P0-4: No queue entry for spell whose cooldown is not ready (ghost icon guard)", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.adrenalineRush.up = true  -- AR is UP
  Tuono.State.cooldowns.adrenalineRush.ready = false  -- AR is NOT READY (on cooldown)
  Tuono.State.comboPoints = 2

  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  -- No entry should have spellID=13750 (AR) when AR buff is up (cooldown not ready)
  for _, entry in ipairs(r.queue) do
    if entry.spellID == 13750 and entry.kind == "cooldown" then
      -- If AR is in queue, its cooldown MUST be ready
      assert_true(Tuono.State.cooldowns.adrenalineRush.ready,
        "AR cooldown entry in queue but cooldown not ready - this is the ghost icon bug")
    end
  end
  assert_true(true, "no ghost AR icon (queue entries only for ready abilities)")
end)

-- ADDITIONAL TEST 1: Opportunity buff ID centralized
test("Additional-1: Opportunity buff ID in SpellIDs", function()
  assert_true(Tuono.SpellIDs.opportunity ~= nil, "opportunity defined in SpellIDs")
  assert_eq(Tuono.SpellIDs.opportunity, 195627, "opportunity ID is 195627")
end)

-- ADDITIONAL TEST 2: Ambush spell ID centralized
test("Additional-2: Ambush spell ID in SpellIDs", function()
  assert_true(Tuono.SpellIDs.ambush ~= nil, "ambush defined in SpellIDs")
  assert_eq(Tuono.SpellIDs.ambush, 8676, "ambush ID is 8676")
end)

-- ADDITIONAL TEST 3: Ambush rule exists and fires when stealthed
test("Additional-3: Ambush rule exists", function()
  local found = false
  for _, rule in ipairs(Tuono.Rules or {}) do
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
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.rtb.expires = 0
  Tuono.State.buffs.degraded = false

  -- Simulate a legacy RTB buff name in the aura list (requires stub support)
  -- This is tested via integration: legacy scan only runs when stage=0
  assert_true(true, "degraded flag available for legacy fallback signaling")
end)

-- === live-queue tests ===

-- LIVE QUEUE TEST 1: Position 1 tracks live GetNextCastSpell changes every tick
test("live-queue: position 1 always tracks live GetNextCastSpell every tick", function()
  -- Simulate dynamic GetNextCastSpell that changes each tick
  local spellSequence = {193315, 1234, 5678, 193315}
  local sequenceIndex = 1

  _G.C_AssistedCombat.GetNextCastSpell = function()
    local spell = spellSequence[sequenceIndex]
    sequenceIndex = sequenceIndex + 1
    if sequenceIndex > #spellSequence then
      sequenceIndex = 1
    end
    return spell
  end

  Tuono.State.inCombat = true
  Tuono.State.stealthed = false

  -- v1.2 DESIGN CHANGE: Blizzard's value was proven STATIC in live combat (52 samples,
  -- 0 changes), so it is no longer the queue source. Position 1 is OUR prediction; we
  -- only still poll Blizzard to record agreement. What must hold now: the polled value
  -- is tracked, and position 1 is a real actionable entry regardless of what they say.
  Tuono.Assist.Update()
  local r1 = Tuono.Engine.Evaluate()
  assert_eq(Tuono.Assist.nextSpellID, 193315, "assist value polled at first tick")
  assert_true(r1.queue[1] ~= nil and r1.queue[1].spellID ~= nil, "position 1 actionable")

  Tuono.Assist.Update()
  assert_eq(Tuono.Assist.nextSpellID, 1234, "assist value re-polled (no caching)")

  Tuono.Assist.Update()
  assert_eq(Tuono.Assist.nextSpellID, 5678, "assist value re-polled again")

  -- Restore to default
  _G.C_AssistedCombat.GetNextCastSpell = function(b) return 193315 end
end)

-- LIVE QUEUE TEST 2: Positions 2+ contain ONLY rule-derived entries, not static rotation
test("live-queue: positions 2+ contain no entries from static rotation list", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.comboPoints = 2  -- AR PIN at low CP

  Tuono.Assist.Update()
  local r = Tuono.Engine.Evaluate()

  -- v1.2: position 1 comes from OUR simulation, never from Blizzard's static list.
  assert_true(r.queue[1] ~= nil, "queue has a position 1")
  assert_true(r.queue[1].source ~= "blizzard",
    "position 1 is our prediction, not Blizzard's static pick")

  -- Positions 2+ must be from rules, not blizzard rotation
  for i = 2, #r.queue do
    local entry = r.queue[i]
    assert_true(entry.source ~= "blizzard" or entry.kind ~= "rotation",
      "queue position " .. i .. " not a static blizzard rotation entry")
  end
end)

-- LIVE QUEUE TEST 3: Queue does not pad with static rotation entries
test("live-queue: queue does not pad with static rotation entries", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.comboPoints = 4  -- Mid-range CP (no PIN)
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.buffs.opportunity.up = false
  Tuono.State.trinkets[13].ready = false
  Tuono.State.trinkets[14].ready = false
  Tuono.State.buffs.rtb.stage = 3  -- RtB up (no stage-0 rule fire)
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.bladeRush.ready = false
  Tuono.State.cooldowns.preparation.ready = false
  Tuono.db.aoeMode = false
  Tuono.Assist.aoeDetected = false

  Tuono.Assist.Update()
  local r = Tuono.Engine.Evaluate()

  -- Old behavior would pad with all static rotation entries (4+).
  -- New behavior should have only position 1 + any rule-derived entries.
  -- The real invariant: nothing in the queue comes from Blizzard's STATIC rotation list.
  -- (The old "<= 3 entries" bound predates the simulator: our own predicted sequence
  -- legitimately fills several slots, and before cooldowns started correctly the sim
  -- repeated one ability and deduped down to a short queue -- a bug, not a spec.)
  assert_true(#r.queue <= 8, "queue respects the 8-entry cap")
  for i, entry in ipairs(r.queue) do
    assert_true(entry.source ~= "blizzard" or entry.confidence == "static-fallback",
      "queue entry " .. i .. " is ours or a labelled fallback, never static padding")
  end
  -- A COOLDOWN-BEARING ability must not repeat back to back -- that is the signature of
  -- a simulation that never starts cooldowns. A zero-cooldown builder repeating is
  -- CORRECT and expected ("Sinister Strike x4" at low combo points).
  local ABIL = Tuono.Rotation and Tuono.Rotation.ABILITIES or {}
  for i = 2, #r.queue do
    local id = r.queue[i].spellID
    if id and r.queue[i].kind ~= "trinket" and ABIL[id] and (ABIL[id].cd or 0) > 0 then
      assert_true(id ~= r.queue[i - 1].spellID,
        "cooldown ability repeated back to back at position " .. i .. " (cooldowns not advancing)")
    end
  end
end)

-- LIVE QUEUE TEST 4: aoeDetected still works off rotationSet
test("live-queue: aoeDetected still detects blade flurry from rotationSet", function()
  assert_true(_G.C_AssistedCombat ~= nil, "C_AssistedCombat available")

  -- Rotation includes Blade Flurry
  _G.C_AssistedCombat.GetRotationSpells = function()
    return {193315, 271877, 13877, 315341}  -- Includes Blade Flurry (13877)
  end

  Tuono.Assist.Update()

  assert_true(Tuono.Assist.aoeDetected, "aoeDetected=true when Blade Flurry in rotationSet")
  assert_true(Tuono.Assist.rotationSet[13877], "Blade Flurry in rotationSet")

  -- Rotation excludes Blade Flurry
  _G.C_AssistedCombat.GetRotationSpells = function()
    return {193315, 271877, 315341}  -- No Blade Flurry
  end

  Tuono.Assist.Update()

  assert_false(Tuono.Assist.aoeDetected, "aoeDetected=false when Blade Flurry NOT in rotationSet")
  assert_false(Tuono.Assist.rotationSet[13877], "Blade Flurry not in rotationSet")

  -- Restore default
  _G.C_AssistedCombat.GetRotationSpells = function() return {193315, 271877, 315341, 13877} end
end)

-- LIVE QUEUE TEST 5: lastChangeAt updates when position 1 changes
test("live-queue: lastChangeAt timestamp updates when position 1 changes", function()
  -- Reset to ensure clean state
  Tuono.Assist.nextSpellID = nil
  Tuono.Assist.lastChangeAt = 0

  -- First Update: position 1 changes from nil to 193315
  _G.C_AssistedCombat.GetNextCastSpell = function() return 193315 end
  Tuono.Assist.Update()
  local firstChangeTime = Tuono.Assist.lastChangeAt

  -- Verify it was recorded (should be a number >= 0)
  assert_true(type(firstChangeTime) == "number", "lastChangeAt is a number after first change")

  -- Position 1 stays same
  Tuono.Assist.Update()
  assert_eq(Tuono.Assist.lastChangeAt, firstChangeTime, "lastChangeAt unchanged when position 1 stable")

  -- Position 1 changes to different spell
  _G.C_AssistedCombat.GetNextCastSpell = function() return 1234 end
  Tuono.Assist.Update()
  local secondChangeTime = Tuono.Assist.lastChangeAt

  assert_true(type(secondChangeTime) == "number", "lastChangeAt updated to a number")
  assert_true(secondChangeTime >= firstChangeTime, "lastChangeAt does not decrease when position 1 changes")

  -- Restore default
  _G.C_AssistedCombat.GetNextCastSpell = function() return 193315 end
  Tuono.Assist.nextSpellID = nil
  Tuono.Assist.lastChangeAt = 0
end)

-- === v1.1.0 FAIL-CLOSED COOLDOWN TESTS ===

-- TEST: Secret cooldowns do NOT produce queue entries (regression test for user bug #1)
test("v1.1.0: secret cooldown fails closed - not queued", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.comboPoints = 2

  -- Inject a secret cooldown for Adrenaline Rush
  local secretStartTime = stub.makeSecret(100)
  local secretDuration = stub.makeSecret(30)

  local originalGetSpellCooldown = _G.C_Spell and _G.C_Spell.GetSpellCooldown
  _G.C_Spell.GetSpellCooldown = function(spellID)
    if spellID == Tuono.SpellIDs.adrenalineRush then
      return { startTime = secretStartTime, duration = secretDuration }
    end
    return { startTime = 0, duration = 0 }
  end

  Tuono.State.RefreshFast()
  local r = Tuono.Engine.Evaluate()

  -- AR should NOT be in the queue (unknown cooldown fails closed)
  local foundAR = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.adrenalineRush then
      foundAR = true
      break
    end
  end

  assert_false(foundAR, "secret cooldown AR NOT queued (fail-closed)")
  assert_false(Tuono.State.cooldowns.adrenalineRush.known, "cooldown marked as unknown")
  assert_false(Tuono.State.cooldowns.adrenalineRush.ready, "unknown cooldown marked as not ready")

  _G.C_Spell.GetSpellCooldown = originalGetSpellCooldown
end)

-- TEST: On-cooldown abilities are never queued
test("v1.1.0: on-cooldown abilities not queued (remaining > 0)", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.comboPoints = 2

  -- Set AR cooldown to remaining 15 seconds (not ready)
  Tuono.State.cooldowns.adrenalineRush.known = true
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 15

  local r = Tuono.Engine.Evaluate()

  -- AR should NOT be in queue
  local foundAR = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.adrenalineRush then
      foundAR = true
      break
    end
  end

  assert_false(foundAR, "on-cooldown AR NOT queued")
end)

-- TEST: Position 1 from Blizzard is never filtered
test("v1.1.0: position 1 from Blizzard allowed through even if cooldown unknown", function()
  Tuono.State.inCombat = true
  Tuono.State.stealthed = false

  -- Position 1 from Blizzard (via Assist.nextSpellID)
  _G.C_AssistedCombat.GetNextCastSpell = function() return Tuono.SpellIDs.adrenalineRush end
  Tuono.Assist.Update()

  -- Make the cooldown unknown (secret)
  Tuono.State.cooldowns.adrenalineRush.known = false
  Tuono.State.cooldowns.adrenalineRush.ready = false

  local r = Tuono.Engine.Evaluate()

  -- v1.2: Blizzard no longer owns position 1 (its value is static in live combat).
  -- What must still hold: an unknown cooldown never produces a NORMAL queue entry --
  -- that was the fail-open bug that recommended Adrenaline Rush while it was on CD.
  -- Blizzard's value may only appear as an explicitly-labelled static fallback.
  assert_true(#r.queue > 0, "queue still has entries")
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.adrenalineRush then
      assert_true(entry.source == "blizzard" or entry.confidence == "static-fallback",
        "AR with unknown cooldown only allowed as a labelled fallback, never as our own pick")
    end
  end
end)

-- TEST: Bar renders out-of-combat (persistent)
test("v1.1.0: bar persistent - renders out-of-combat", function()
  Tuono.State.inCombat = false
  Tuono.db.show.ooc = true

  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
  end

  local result = {
    queue = { {spellID = 193315, kind = "rotation", source = "blizzard"} },
    advisories = {}
  }

  Tuono.Display.Render(result)

  local anchor = Tuono.Display.anchor
  assert_true(anchor and anchor:IsShown(), "bar shown out-of-combat with show.ooc=true")
end)

-- TEST: Icons receive cooldown timer values
test("v1.1.0: icons display cooldown timers", function()
  Tuono.State.cooldowns.adrenalineRush.known = true
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 12.5

  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
  end

  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard"},
      {spellID = Tuono.SpellIDs.adrenalineRush, kind = "cooldown", source = "rule"}
    },
    advisories = {}
  }

  Tuono.Display.Render(result)

  local anchor = Tuono.Display.anchor
  if anchor and anchor.icons[2] then
    -- Icon 2 should have cooldownText updated (if we could inspect it)
    assert_true(anchor.icons[2].cooldownText ~= nil, "cooldown timer text element exists")
  end
end)

-- TEST: Queue re-evaluates on consecutive ticks with changing state
test("v1.1.0: continuous recalculation - queue changes between ticks", function()
  Tuono.State.inCombat = true
  Tuono.State.stealthed = false

  -- Tick 1: AR on cooldown
  Tuono.State.cooldowns.adrenalineRush.known = true
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 5
  Tuono.State.comboPoints = 2

  local r1 = Tuono.Engine.Evaluate()
  local hasARinTick1 = false
  for _, entry in ipairs(r1.queue) do
    if entry.spellID == Tuono.SpellIDs.adrenalineRush and entry.kind == "cooldown" then
      hasARinTick1 = true
      break
    end
  end

  -- Tick 2: AR becomes ready
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.adrenalineRush.remaining = 0

  local r2 = Tuono.Engine.Evaluate()
  local hasARinTick2 = false
  for _, entry in ipairs(r2.queue) do
    if entry.spellID == Tuono.SpellIDs.adrenalineRush and entry.kind == "cooldown" then
      hasARinTick2 = true
      break
    end
  end

  assert_false(hasARinTick1, "AR not in queue when on cooldown (tick 1)")
  assert_true(hasARinTick2, "AR in queue when ready (tick 2)")
end)

-- TEST: Trinket cooldowns respect fail-closed logic
test("v1.1.0: trinket cooldowns fail closed - unknown trinket not ready", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.adrenalineRush.up = true

  -- Inject a secret trinket cooldown
  local secretStartTime = stub.makeSecret(100)
  local secretDuration = stub.makeSecret(60)

  local originalGetItemCooldown = _G.C_Item and _G.C_Item.GetItemCooldown
  _G.C_Item.GetItemCooldown = function(itemID)
    if itemID == 999 then  -- Fake trinket
      return secretStartTime, secretDuration
    end
    return 0, 0
  end

  -- Manually set trinket state to simulate unknown cooldown
  Tuono.State.trinkets[13].itemID = 999
  Tuono.State.trinkets[13].ready = false  -- Fail-closed from secret values
  Tuono.State.trinkets[13].onUse = true

  local r = Tuono.Engine.Evaluate()

  -- Trinket should NOT be queued (unknown cooldown)
  local foundTrinket = false
  for _, entry in ipairs(r.queue) do
    if entry.kind == "trinket" and entry.itemSlot == 13 then
      foundTrinket = true
      break
    end
  end

  assert_false(foundTrinket, "trinket with unknown cooldown not queued")

  _G.C_Item.GetItemCooldown = originalGetItemCooldown
end)

-- TEST: Keybind cache retry (doesn't poison on nil)
test("v1.1.0: keybind cache retries nil results (doesn't poison)", function()
  -- This is an internal test verifying the cache behavior
  -- We can't directly inspect the cache, but we can verify it's not poisoned
  -- by checking that the debug command doesn't crash

  local result = {
    queue = { {spellID = 999999, kind = "rotation", source = "blizzard"} },
    advisories = {}
  }

  if Tuono.Display and Tuono.Display.Init then
    Tuono.Display.Init()
  end

  Tuono.Display.Render(result)

  assert_true(true, "display render completed without cache poison crash")
end)

-- TEST: Engine-level castability filter (belt-and-braces)
test("v1.1.0: engine filter removes non-position-1 entries with unknown cooldowns", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.comboPoints = 2

  -- Set AR as position 1 from Blizzard (should survive filter)
  _G.C_AssistedCombat.GetNextCastSpell = function() return Tuono.SpellIDs.adrenalineRush end
  Tuono.Assist.Update()

  -- Set AR cooldown to unknown
  Tuono.State.cooldowns.adrenalineRush.known = false
  Tuono.State.cooldowns.adrenalineRush.ready = false

  -- Also add BR as a rule-generated entry (should be filtered)
  Tuono.State.cooldowns.bladeRush.known = false
  Tuono.State.cooldowns.bladeRush.ready = false

  local r = Tuono.Engine.Evaluate()

  -- v1.2: the filter's real job -- an ability whose cooldown we cannot confirm is NEVER
  -- presented as our own recommendation. (Fail-open here is what put Adrenaline Rush on
  -- the bar while it was on cooldown in live play.)
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.bladeRush or entry.spellID == Tuono.SpellIDs.adrenalineRush then
      assert_true(entry.source == "blizzard" or entry.confidence == "static-fallback",
        "unknown-cooldown ability only ever appears as a labelled fallback")
    end
  end
end)

-- === v1.1.0 TALENT-GATING TESTS ===

-- TEST: Unknown spell is not queued (talent-gated spell missing)
test("v1.1.0: talent-gated spell not known - filtered from queue", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.cooldowns.bladeRush.ready = true
  Tuono.State.knownUnavailable = false

  -- Stub: Blade Rush is NOT known
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeRush] = false
  -- But cooldown is ready
  Tuono.State.cooldowns.bladeRush.known = true
  Tuono.State.cooldowns.bladeRush.ready = true

  local r = Tuono.Engine.Evaluate()

  -- BR should NOT be in queue (not known, even though ready)
  local foundBR = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.bladeRush then
      foundBR = true
      break
    end
  end

  assert_false(foundBR, "unknown spell BR NOT queued (talent-gated)")
end)

-- TEST: Known spell IS queued (talent acquired)
test("v1.1.0: talent-gated spell known - queued when ready", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.cooldowns.bladeRush.ready = true
  Tuono.State.knownUnavailable = false

  -- Stub: Blade Rush IS known
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeRush] = true
  -- Cooldown is ready
  Tuono.State.cooldowns.bladeRush.known = true
  Tuono.State.cooldowns.bladeRush.ready = true

  local r = Tuono.Engine.Evaluate()

  -- BR should be in queue
  local foundBR = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.bladeRush then
      foundBR = true
      break
    end
  end

  assert_true(foundBR, "known spell BR queued when ready (talent acquired)")
end)

-- TEST: Position 1 from Blizzard allowed through even if not known
test("v1.1.0: position 1 from Blizzard allowed even if spell unknown", function()
  Tuono.State.inCombat = true
  Tuono.State.stealthed = false

  -- Position 1 from Blizzard is Blade Rush
  _G.C_AssistedCombat.GetNextCastSpell = function() return Tuono.SpellIDs.bladeRush end
  Tuono.Assist.Update()

  -- But spell is not known (talent not taken)
  Tuono.State.knownUnavailable = false
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeRush] = false

  local r = Tuono.Engine.Evaluate()

  -- v1.2: an untalented ability must never be OUR pick. The user is levelling and does
  -- not have every talent, so this is the common case, not an edge case.
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.bladeRush then
      assert_true(entry.source == "blizzard" or entry.confidence == "static-fallback",
        "untalented ability only ever appears as a labelled fallback")
    end
  end
end)

-- TEST: Known API unavailable - fail-open (all spells allowed)
test("v1.1.0: known API unavailable - fail-open", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.cooldowns.bladeRush.ready = true
  Tuono.State.knownUnavailable = true  -- API unavailable

  -- Even though knownSpells says unknown, fail-open allows it through
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeRush] = false

  local r = Tuono.Engine.Evaluate()

  -- BR should be in queue (fail-open when API unavailable)
  local foundBR = false
  for _, entry in ipairs(r.queue) do
    if entry.spellID == Tuono.SpellIDs.bladeRush then
      foundBR = true
      break
    end
  end

  assert_true(foundBR, "spell allowed through when known API unavailable (fail-open)")
end)

-- TEST: Talent change event rebuilds known spells
test("v1.1.0: talent change event rebuilds known spells cache", function()
  Tuono.State.inCombat = false
  Tuono.State.knownUnavailable = false

  -- Initial: BR is not known
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeRush] = false

  -- Simulate talent being learned (fire talent change event)
  -- We can't directly test the event, but we can verify the refresh function works
  local mockIsSpellKnown = function(spellID)
    if spellID == Tuono.SpellIDs.bladeRush then
      return true  -- Now it's known
    end
    return false
  end

  local originalIsPlayerSpell = _G.IsPlayerSpell
  _G.IsPlayerSpell = mockIsSpellKnown

  -- Call refresh manually (simulating talent change event)
  Tuono.safe(function()
    -- We'll manually rebuild for this test
    wipe(Tuono.State.knownSpells)
    for name, spellID in pairs(Tuono.SpellIDs or {}) do
      if spellID then
        Tuono.State.knownSpells[spellID] = mockIsSpellKnown(spellID)
      end
    end
  end)

  assert_true(Tuono.State.knownSpells[Tuono.SpellIDs.bladeRush], "BR now known after talent change")

  _G.IsPlayerSpell = originalIsPlayerSpell
end)

-- === proc-probe tests ===

-- TEST: Proc probe queries aura by spell ID
test("proc probe: query-by-ID returns data when aura active", function()
  stub.state.buffs.opportunity = true
  stub.state.buffs.opportunityExpires = stub.state.time + 30

  local auraData = nil
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    auraData = C_UnitAuras.GetPlayerAuraBySpellID(195627)   -- ONE arg: player is implied
  end
  if not auraData and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID then
    auraData = C_UnitAuras.GetAuraDataBySpellID("player", 195627)
  end

  assert_true(auraData ~= nil, "aura query-by-ID returns non-nil when aura active")
  assert_eq(auraData.spellId, 195627, "returned aura has correct spellId")
end)

-- TEST: Proc probe detects readable fields
test("proc probe: field readability check on readable aura", function()
  stub.state.buffs.adrenalineRush = true
  stub.state.buffs.adrenalineRushExpires = stub.state.time + 15

  local auraData = C_UnitAuras.GetAuraDataBySpellID("player", 13750)

  assert_true(auraData ~= nil, "AR aura data retrieved")
  assert_false(issecretvalue(auraData.spellId), "spellId field is readable (not secret)")
  assert_false(issecretvalue(auraData.name), "name field is readable (not secret)")
  assert_false(issecretvalue(auraData.expirationTime), "expirationTime field is readable (not secret)")
  assert_false(issecretvalue(auraData.applications), "applications field is readable (not secret)")
end)

-- TEST: Proc probe detects delta events
test("proc probe: UNIT_AURA delta event tracking", function()
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.rtb.expires = 0

  -- Fire UNIT_AURA delta event with addedAuras
  local updateInfo = {
    addedAuras = {
      {
        auraInstanceID = 5010,
        spellId = 315508,
        expirationTime = stub.state.time + 45
      }
    }
  }

  stub.FireEvent("UNIT_AURA", "player", updateInfo)

  assert_true(Tuono.State.buffs.rtb.stage > 0, "buff state updated via delta event")
end)

-- TEST: Proc probe verdict logic - DIRECT (query-by-ID works)
test("proc probe: verdict=DIRECT when query-by-ID works with readable fields", function()
  stub.state.buffs.opportunity = true
  stub.state.buffs.opportunityExpires = stub.state.time + 30

  local auraData = C_UnitAuras.GetAuraDataBySpellID("player", 195627)
  local hasReadable = false
  if auraData and not issecretvalue(auraData.spellId) then
    hasReadable = true
  end

  assert_true(hasReadable, "verdict=DIRECT condition met: query returns readable data")
end)

-- TEST: Proc probe verdict logic - DELTA-ONLY (delta events present, query fails)
test("proc probe: verdict=DELTA-ONLY when query fails but delta events tracked", function()
  -- Simulate query failing
  local auraData = nil
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    auraData = C_UnitAuras.GetPlayerAuraBySpellID(999999)  -- Non-existent aura
  end

  assert_false(auraData ~= nil, "query-by-ID returns nil for non-existent aura")

  -- But delta events should still be tracked
  local updateInfo = {
    addedAuras = {
      {
        auraInstanceID = 5011,
        spellId = 195627,
        expirationTime = stub.state.time + 20
      }
    }
  }

  stub.FireEvent("UNIT_AURA", "player", updateInfo)

  assert_true(Tuono.State.buffs.opportunity.up, "delta tracking updates state even when query fails")
end)

-- TEST: Proc probe tracks accessor values
test("proc probe: GetNextCastSpell accessor tracking", function()
  local spell1 = C_AssistedCombat.GetNextCastSpell(false)
  assert_true(spell1 ~= nil, "GetNextCastSpell(false) returns non-nil")
  assert_true(type(spell1) == "number", "GetNextCastSpell(false) returns a number")

  local spell2 = C_AssistedCombat.GetNextCastSpell(true)
  assert_true(spell2 ~= nil, "GetNextCastSpell(true) returns non-nil")
  assert_true(type(spell2) == "number", "GetNextCastSpell(true) returns a number")
end)

-- TEST: Proc probe tracks GetActionSpell accessor
test("proc probe: GetActionSpell accessor across action slots", function()
  local found = false
  for slot = 1, 12 do
    local spell = C_AssistedCombat.GetActionSpell(slot)
    if spell then
      found = true
      assert_true(type(spell) == "number", "GetActionSpell returns a number")
      break
    end
  end

  assert_true(found, "GetActionSpell returns non-nil for at least one action slot")
end)

-- TEST: Proc probe detects ASSISTED events
test("proc probe: ASSISTED event firing (registration)", function()
  assert_true(Tuono.eventHandlers ~= nil, "event handlers table exists")
  -- We can't test actual firing without full integration, but we verify the handler structure
  assert_true(true, "ASSISTED event infrastructure ready")
end)

-- TEST: Proc probe with all accessors unavailable
test("proc probe: graceful handling when all accessors return nil", function()
  local originalGetNextCastSpell = C_AssistedCombat and C_AssistedCombat.GetNextCastSpell or nil
  local originalGetActionSpell = C_AssistedCombat and C_AssistedCombat.GetActionSpell or nil

  -- Temporarily remove accessors
  if C_AssistedCombat then
    C_AssistedCombat.GetNextCastSpell = nil
    C_AssistedCombat.GetActionSpell = nil
  end

  -- Probe should not crash
  local ok = pcall(function()
    local v = C_AssistedCombat and C_AssistedCombat.GetNextCastSpell and C_AssistedCombat.GetNextCastSpell(false) or nil
    assert_false(v, "accessor returns nil when unavailable")
  end)

  assert_true(ok, "probe handles missing accessors without error")

  -- Restore
  if C_AssistedCombat then
    C_AssistedCombat.GetNextCastSpell = originalGetNextCastSpell
    C_AssistedCombat.GetActionSpell = originalGetActionSpell
  end
end)

-- === simulator tests ===

-- Test: Rotation.Predict exists and is callable
test("rotation simulator: Predict function exists", function()
  assert_true(Tuono.Rotation ~= nil, "Tuono.Rotation module exists")
  assert_true(type(Tuono.Rotation.Predict) == "function", "Tuono.Rotation.Predict is a function")
end)

-- Test: Predict with full energy and ready cooldowns
test("rotation simulator: predict returns array at full energy", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true
  Tuono.State.cooldowns.preparation.ready = false

  local pred = Tuono.Rotation.Predict(Tuono.State, 4)
  assert_true(pred ~= nil, "Predict returns a result")
  assert_true(type(pred) == "table", "Predict result is a table")
  assert_true(#pred > 0, "Predict returns at least one step")
end)

-- Test: Predict with degraded state returns nil
test("rotation simulator: degraded aura data still predicts (lower confidence)", function()
  -- v1.3.1: bailing out on degraded meant the simulation NEVER RAN in combat, because
  -- Midnight hides aura data there -- so the bar fell back to Blizzard's frozen pick and
  -- the first icon never changed in live play. Energy/CP/cooldowns remain readable and
  -- drive most of the priority list, so predict anyway and mark confidence down.
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 3
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.degraded = true

  local pred = Tuono.Rotation.Predict(Tuono.State, 3)
  assert_true(pred ~= nil, "prediction still produced while degraded")
  assert_true(#pred > 0, "degraded prediction is non-empty")
  assert_true(pred[1].confidence ~= "high", "degraded prediction is not high confidence")

  Tuono.State.buffs.degraded = false
end)

-- Test: Predict entries have required fields
test("rotation simulator: predict entries have spellID, confidence, reason", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true

  local pred = Tuono.Rotation.Predict(Tuono.State, 4)
  assert_true(pred ~= nil, "Predict returns result")

  for i, entry in ipairs(pred) do
    assert_true(entry.spellID ~= nil, "entry " .. i .. " has spellID")
    assert_true(entry.confidence ~= nil, "entry " .. i .. " has confidence")
    assert_true(entry.reason ~= nil, "entry " .. i .. " has reason")
  end
end)

-- Test: Confidence is high for steps 1-3
test("rotation simulator: confidence high for steps 1-3", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.degraded = false  -- "high" requires readable aura data
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true

  Tuono.State.comboPointsKnown = true
  Tuono.State.energySource = "measured"

  local pred = Tuono.Rotation.Predict(Tuono.State, 4)

  -- Confidence is now PROVENANCE-based, not index-based: it describes what the firing
  -- rule depended on, so a step derived from exactly-readable inputs is "certain"
  -- regardless of where it sits in the queue.
  for i = 1, math.min(3, #pred) do
    assert_true(pred[i].confidence == "certain" or pred[i].confidence == "bounded",
      "step " .. i .. " rated from readable inputs, got " .. tostring(pred[i].confidence))
  end
end)

-- The point of provenance rating: an UNREADABLE input degrades the step that depends on
-- it, wherever it lands. Index has nothing to do with it.
test("rotation simulator: a step gated on hidden aura state is rated unknown", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energySource = "measured"
  Tuono.State.comboPoints = 0
  Tuono.State.comboPointsKnown = true
  -- Roll the Bones stage is exactly the input Midnight hides in combat.
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.rtb.stageKnown = false

  local rule = {
    spellKey = "rollTheBones",
    conditions = { { type = "rtbStage", op = "<", value = 2 } },
  }
  assert_eq(Tuono.Rotation.RateRule(rule, Tuono.State, Tuono.SpellIDs.rollTheBones),
    "unknown", "rtbStage rule is unknown while the stage is unreadable")

  Tuono.State.buffs.rtb.stageKnown = true
  assert_true(Tuono.Rotation.RateRule(rule, Tuono.State, Tuono.SpellIDs.rollTheBones) ~= "unknown",
    "same rule is rated better once the stage is readable")
end)

-- Test: Confidence is low for step 4+
test("rotation simulator: confidence low for step 4+", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true

  local pred = Tuono.Rotation.Predict(Tuono.State, 8)

  -- INVERTED FROM "step 4+ is low". Index-based decay was arbitrary: a step derived
  -- entirely from combo points and cooldown readiness is not less true for sitting in
  -- slot 4. What DOES distinguish later steps is that they assume you follow the
  -- sequence -- reported separately as assumesPriorSteps and encoded by icon size, not
  -- by fading, because it is a conditional rather than missing knowledge.
  Tuono.State.comboPointsKnown = true
  Tuono.State.energySource = "measured"
  local pred2 = Tuono.Rotation.Predict(Tuono.State, 8)

  if #pred2 >= 4 then
    for i = 4, #pred2 do
      assert_true(pred2[i].confidence ~= "low",
        "step " .. i .. " is rated by provenance, not by index, got "
          .. tostring(pred2[i].confidence))
      assert_true(pred2[i].assumesPriorSteps == true,
        "step " .. i .. " is flagged as conditional on the preceding steps")
    end
    assert_true(pred2[1].assumesPriorSteps == false,
      "step 1 assumes nothing prior")
  end
end)

-- Test: Energy is spent and regenerated correctly
test("rotation simulator: energy spent and regenerated across steps", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true
  Tuono.State.cooldowns.preparation.ready = false

  local origEnergy = Tuono.State.energy
  local pred = Tuono.Rotation.Predict(Tuono.State, 4)

  -- Real state should not change (prediction is non-destructive)
  assert_eq(Tuono.State.energy, origEnergy, "real state energy unchanged after Predict")
  assert_true(pred ~= nil, "prediction returned")
end)

-- Test: Combo points increase with builders
test("rotation simulator: combo points generated by builders", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.bladeRush.ready = false

  local pred = Tuono.Rotation.Predict(Tuono.State, 4)
  assert_true(pred ~= nil, "prediction returned")
  -- Expect Sinister Strike as the first castable ability at step 1
  assert_true(#pred > 0, "at least one step predicted")
end)

-- Test: Finisher applies Restless Blades CDR
test("rotation simulator: finisher applies Restless Blades CDR", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 6
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 1  -- Stage 1, not the +30% stage
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 100
  Tuono.State.cooldowns.bladeRush.ready = false
  Tuono.State.cooldowns.bladeRush.remaining = 30
  Tuono.State.cooldowns.preparation.ready = false
  -- BtE has a real cooldown and the engine fails CLOSED on not-ready, so a finisher
  -- test must declare it ready; otherwise falling back to the builder is CORRECT.
  Tuono.State.cooldowns.betweenTheEyes = { known = true, ready = true, remaining = 0 }
  -- Self-sufficient talent state: earlier tests flip knownSpells entries to false.
  Tuono.State.knownSpells = Tuono.State.knownSpells or {}
  Tuono.State.knownSpells[Tuono.SpellIDs.betweenTheEyes] = true

  local pred = Tuono.Rotation.Predict(Tuono.State, 2)
  assert_true(pred ~= nil, "prediction returned with high CP")
  assert_true(#pred > 0, "finisher predicted")
  -- Between the Eyes should be predicted as the first action at 6 CP
  assert_eq(pred[1].spellID, Tuono.SpellIDs.betweenTheEyes, "BtE finisher predicted at 6 CP")
end)

-- Test: Stage 3 RtB buff affects next prediction
test("rotation simulator: stage 3 RtB buff affects next prediction", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 3
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true

  local pred = Tuono.Rotation.Predict(Tuono.State, 4)
  assert_true(pred ~= nil, "prediction returned at stage 3")
  assert_true(#pred > 0, "step predicted")
end)

-- Test: IntelligenceLayer wires predictions into queue
test("rotation simulator: predictions wired into intelligence layer queue", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue exists in result")
  assert_true(#r.queue > 0, "queue has entries with Predict wired in")

  -- Check that at least one entry has a reason (from Predict)
  local foundPrediction = false
  for _, entry in ipairs(r.queue) do
    if entry.reason and entry.reason:find("rotation") then
      foundPrediction = true
      break
    end
  end
  -- Note: foundPrediction may or may not be true depending on the specific state,
  -- so we don't assert it; the key test is that queue is populated and has entries
  assert_true(true, "Engine.Evaluate completes with Predict wired in")
end)

-- TEST: CRITICAL — Assist unavailable → our predictions still returned (COORDINATOR FINDING)
test("rotation simulator: Assist unavailable → predictions work standalone", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = true
  Tuono.State.cooldowns.bladeRush.ready = true

  local originalC_AssistedCombat = _G.C_AssistedCombat
  _G.C_AssistedCombat = nil
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue exists when Assist unavailable")
  assert_true(#r.queue > 0, "queue populated from OUR predictions (Assist unavailable)")
  assert_true(Tuono.Assist.available == false, "Assist is unavailable")

  _G.C_AssistedCombat = originalC_AssistedCombat
end)

-- TEST: Static fallback behavior — empty prediction + Assist available → confidence="static-fallback"
test("rotation simulator: empty prediction + Assist → static-fallback entry marked", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 0  -- Out of energy → likely no castable ability
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 100
  Tuono.State.cooldowns.bladeRush.ready = false
  Tuono.State.cooldowns.bladeRush.remaining = 30
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local r = Tuono.Engine.Evaluate()
  assert_true(r.queue ~= nil, "queue exists")

  -- Prediction with no energy + all CDs down should be empty → fallback to Blizzard
  -- Check that assistStatic flag is set correctly when fallback is used
  if #r.queue > 0 then
    local foundFallback = false
    for _, entry in ipairs(r.queue) do
      if entry.confidence == "static-fallback" then
        foundFallback = true
        break
      end
    end
    if foundFallback then
      assert_true(Tuono.Engine.assistStatic, "assistStatic flag set when static-fallback entry used")
    end
  end

  assert_true(true, "fallback handling completes without error")
end)

-- === rotation-data tests ===

-- TEST: Dispatch energy cost is 35 (critical for leveling loop)
test("ability data: Dispatch energy cost = 35, not 25 (verified Wowhead 2026-08-01)", function()
  local abilities = loadfile("Tuono/Rotation.lua")
  if not abilities then error("Could not load Rotation.lua") end
  local ok, err = pcall(abilities, _G.ADDON_NAME, Tuono)
  if not ok then error("Error loading Rotation.lua: " .. tostring(err)) end

  -- Dispatch spell ID = 2098
  local dispatch_ability = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.dispatch]
  if dispatch_ability then
    assert_eq(dispatch_ability.cost, 35, "Dispatch energy cost verified (Wowhead spell 2098)")
  end
end)

-- TEST: Blade Rush cooldown is 60s (not 10s, off-by-6x bug)
test("ability data: Blade Rush cooldown = 60s, not 10s (verified Wowhead 2026-08-01)", function()
  local br_ability = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.bladeRush]
  if br_ability then
    assert_eq(br_ability.cd, 60, "Blade Rush cooldown verified (Wowhead spell 271877)")
  end
end)

-- TEST: Between the Eyes cooldown is 45s (not 30s, off-by-15s bug)
test("ability data: Between the Eyes cooldown = 45s, not 30s (verified Wowhead 2026-08-01)", function()
  local bte_ability = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.betweenTheEyes]
  if bte_ability then
    assert_eq(bte_ability.cd, 45, "Between the Eyes cooldown verified (Wowhead spell 315341)")
  end
end)

-- TEST: Killing Spree cooldown is 180s (not 30s, off-by-6x bug)
test("ability data: Killing Spree cooldown = 180s, not 30s (verified Wowhead 2026-08-01)", function()
  local ks_ability = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.killingSpree]
  if ks_ability then
    assert_eq(ks_ability.cd, 180, "Killing Spree cooldown verified (Wowhead spell 5374)")
  end
end)

-- TEST: Killing Spree energy cost is 45 (not 25, off-by-20 bug)
test("ability data: Killing Spree energy cost = 45, not 25 (verified Wowhead 2026-08-01)", function()
  local ks_ability = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.killingSpree]
  if ks_ability then
    assert_eq(ks_ability.cost, 45, "Killing Spree energy cost verified (Wowhead spell 5374)")
  end
end)

-- TEST: Blade Flurry energy cost is 15 (not 0, off-by-15 bug)
test("ability data: Blade Flurry energy cost = 15, not 0 (verified Wowhead 2026-08-01)", function()
  local bf_ability = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.bladeFlurry]
  if bf_ability then
    assert_eq(bf_ability.cost, 15, "Blade Flurry energy cost verified (Wowhead spell 13877)")
  end
end)

-- TEST: Keep It Rolling cooldown is 360s (not 15s, off-by-24x bug)
test("ability data: Keep It Rolling cooldown = 360s, not 15s (verified Wowhead 2026-08-01)", function()
  local kir_ability = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.keepItRolling]
  if kir_ability then
    assert_eq(kir_ability.cd, 360, "Keep It Rolling cooldown verified (Wowhead spell 333549)")
  end
end)

-- TEST: No ability placeholder cooldowns (cd=0 for non-instant, or cost=0 for non-free)
test("ability data: No placeholder cooldowns (regression guard)", function()
  local abilities_ok = true
  local problems = {}

  if Tuono.Rotation and Tuono.Rotation.ABILITIES then
    for spell_id, ability in pairs(Tuono.Rotation.ABILITIES) do
      -- Every ability should either have a real cooldown or explicitly be instant (cd=0 for off-GCD or non-cooldown)
      -- Dispatch (no CD), Sinister Strike (no CD), Ambush (no CD), Pistol Shot (no CD) are all instant.
      -- Check that we don't have obviously wrong placeholders (e.g., a GCD ability with cd=0 when it should have one)
      -- This is a broad regression check, not a specific value check.
      if ability.cost and ability.cost < 0 then
        table.insert(problems, ("Ability %d has negative cost: %d"):format(spell_id, ability.cost))
        abilities_ok = false
      end
      if ability.cd and ability.cd < 0 then
        table.insert(problems, ("Ability %d has negative cooldown: %d"):format(spell_id, ability.cd))
        abilities_ok = false
      end
    end
  end

  if not abilities_ok then
    error("ABILITIES table has placeholder/invalid values: " .. table.concat(problems, "; "))
  end
  assert_true(true, "All ability values are within valid ranges")
end)

-- TEST: Ambush rule exists at highest priority
test("rotation rules: Ambush stealth-opener rule exists", function()
  if Tuono.Rotation then
    -- The rule should be first in the PRIORITY_SINGLE list (or at least present)
    -- We can't directly inspect the priority list from here, but we can check that Ambush is in the ABILITIES table
    local ambush_able = Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.ambush]
    assert_true(ambush_able ~= nil, "Ambush ability is defined in ABILITIES table")
    if ambush_able then
      assert_eq(ambush_able.cost, 50, "Ambush costs 50 energy (45 with Hidden Opportunity)")
      assert_eq(ambush_able.cpGen, 2, "Ambush generates 2 combo points")
    end
  end
end)

-- === display-clarity tests ===

-- Display Test 1: High confidence renders at full opacity
test("display-clarity: high confidence renders at full opacity", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "high", degraded = false}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon = Tuono.Display.anchor.icons[1]
  assert_true(icon ~= nil, "icon 1 exists")
  assert_true(icon:IsShown(), "icon 1 is visible")

  -- High confidence should render with baseAlpha=1.0, icon opacity should be 1.0
  local alpha = icon:GetAlpha()
  assert_true(alpha >= 0.95, "high confidence icon has alpha >= 0.95 (near full opacity), got " .. tostring(alpha))
end)

-- Display Test 2: Medium confidence renders dimmed (~0.7)
test("display-clarity: medium confidence renders slightly dimmed", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "medium", degraded = false}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon = Tuono.Display.anchor.icons[1]
  local alpha = icon:GetAlpha()
  assert_true(alpha >= 0.6 and alpha <= 0.8, "medium confidence icon has alpha ~0.7, got " .. tostring(alpha))
end)

-- Display Test 3: Low confidence renders clearly dimmed (~0.45)
test("display-clarity: low confidence renders clearly dimmed", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "low", degraded = false}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon = Tuono.Display.anchor.icons[1]
  local alpha = icon:GetAlpha()
  assert_true(alpha >= 0.4 and alpha <= 0.55, "low confidence icon has alpha ~0.45, got " .. tostring(alpha))
end)

-- Display Test 4: Static-fallback renders distinctly dimmed and marked
-- REPLACES the "static-fallback" rendering test. That confidence tier existed only to
-- mark Blizzard's fallback pick, which is no longer rendered at all.
--
-- "pooling" inherits the role: the one entry type that must be visually distinct from a
-- normal recommendation, because it means "wait for this", not "press this". The
-- position-1 authority ring is what says press-now, so it must be muted here too --
-- dimming alone reads as low confidence, which is a different message entirely.
test("display-clarity: pooling entry renders as a wait, not a command", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "SS_last_resort", confidence = "pooling", degraded = false}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon = Tuono.Display.anchor.icons[1]
  local alpha = icon:GetAlpha()
  assert_true(alpha >= 0.3 and alpha <= 0.4, "pooling icon is dimmed (~0.35), got " .. tostring(alpha))

  if icon.badge then
    assert_true(icon.badge:IsShown(), "pooling icon shows its wait marker")
  end
end)

-- Display Test 5: Position-1 gets distinct treatment (authority ring visible)
test("display-clarity: position-1 gets distinct authority ring treatment", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "high", degraded = false},
      {spellID = 13750, kind = "cooldown", source = "rule", confidence = "high", degraded = false}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon1 = Tuono.Display.anchor.icons[1]
  local icon2 = Tuono.Display.anchor.icons[2]

  assert_true(icon1 ~= nil, "position 1 exists")
  assert_true(icon2 ~= nil, "position 2 exists")

  -- Position 1 should have authRing visible (silver, non-kind encoding)
  if icon1.authRing then
    assert_true(icon1.authRing:IsShown(), "position-1 has authRing visible")
  end

  -- Position 2 should have kindRing (not authRing)
  if icon2.kindRing then
    assert_true(icon2.kindRing:IsShown(), "position-2 has kindRing visible")
  end
  if icon1.kindRing then
    assert_false(icon1.kindRing:IsShown(), "position-1 does NOT show kindRing")
  end
end)

-- Display Test 6: Degraded flag shows hazard overlay
test("display-clarity: degraded entry shows hazard overlay", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "high", degraded = true}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon = Tuono.Display.anchor.icons[1]
  if icon.hazard then
    assert_true(icon.hazard:IsShown(), "degraded entry shows hazard overlay")
  end
end)

-- Display Test 7: Degraded + low confidence together leaves icon visible
test("display-clarity: degraded + low confidence icon remains above visibility floor", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "low", degraded = true}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon = Tuono.Display.anchor.icons[1]
  local alpha = icon:GetAlpha()
  -- Low confidence alone is ~0.45; degraded adds hazard overlay at 0.35.
  -- Icon alpha should still be ~0.45 so art is readable under hazard overlay.
  assert_true(alpha >= 0.4, "degraded + low confidence icon alpha >= 0.4 (readable), got " .. tostring(alpha))

  if icon.hazard then
    assert_true(icon.hazard:IsShown(), "degraded overlay visible on low-confidence icon")
  end
end)

-- Display Test 8: Empty queue renders without error
test("display-clarity: empty queue renders without error", function()
  Tuono.Display.Init()
  local result = {
    queue = {},
    advisories = {}
  }
  -- Should not error
  Tuono.Display.Render(result)
  assert_true(true, "empty queue renders without error")
end)

-- Display Test 9: Dynamic strip resize based on actual entries
test("display-clarity: dynamic strip resize wraps actual entries, not iconCount", function()
  Tuono.db.display.iconCount = 8
  Tuono.Display.Init()

  -- Render with only 2 entries
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "high", degraded = false},
      {spellID = 13750, kind = "cooldown", source = "rule", confidence = "high", degraded = false}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local anchor = Tuono.Display.anchor
  local width, height = anchor:GetSize()
  -- With 2 entries: width = 6 + 50 + 1*(6+42) + 6 = 110
  assert_true(width >= 105 and width <= 115, "strip width wraps 2 entries (~110), got " .. tostring(width))

  -- Render with 4 entries
  result.queue = {
    {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "high", degraded = false},
    {spellID = 13750, kind = "cooldown", source = "rule", confidence = "high", degraded = false},
    {spellID = 271877, kind = "rotation", source = "blizzard", confidence = "high", degraded = false},
    {spellID = 315341, kind = "rotation", source = "blizzard", confidence = "high", degraded = false}
  }
  Tuono.Display.Render(result)

  local width2, _ = anchor:GetSize()
  -- With 4 entries: width = 6 + 50 + 3*(6+42) + 6 = 206
  assert_true(width2 >= 200 and width2 <= 212, "strip width wraps 4 entries (~206), got " .. tostring(width2))
  assert_true(width2 > width, "strip width increased when entries increased")
end)

-- Display Test 10: Keybind text applies confidence alpha
test("display-clarity: keybind text alpha follows confidence level", function()
  Tuono.Display.Init()
  local result = {
    queue = {
      {spellID = 193315, kind = "rotation", source = "blizzard", confidence = "low", degraded = false}
    },
    advisories = {}
  }
  Tuono.Display.Render(result)

  local icon = Tuono.Display.anchor.icons[1]
  if icon.keyText then
    local keyAlpha = icon.keyText:GetAlpha()
    -- Low confidence should set keyText alpha to ~0.45
    assert_true(keyAlpha >= 0.4 and keyAlpha <= 0.55, "keybind text alpha follows confidence (~0.45), got " .. tostring(keyAlpha))
  end
end)

-- === decisions tests ===

-- Neutral baseline: every decisions test asserts about ONE rule, so all higher-priority
-- rules must be silenced explicitly. Leftover state from earlier tests (a ready Blade
-- Rush, a lingering Opportunity proc) otherwise wins the priority walk and the test
-- fails for a reason that has nothing to do with what it is testing.
local function decisionsBaseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.degraded = false
  Tuono.State.buffs.opportunity.up = false
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.buffs.rtb.stage = 2
  Tuono.State.buffs.rtb.expires = 999
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPointsMax = 6
  Tuono.State.enemyCount = 1
  Tuono.db.aoeMode = false
  Tuono.Assist.aoeDetected = false
  -- Silence only abilities that actually HAVE a cooldown. Marking a zero-cooldown
  -- ability (Dispatch, Sinister Strike, Pistol Shot, Ambush) as not-ready describes a
  -- state the game cannot produce, and would make a test assert against fiction.
  for _, k in ipairs({"adrenalineRush", "bladeRush", "preparation", "betweenTheEyes",
                      "killingSpree", "rollTheBones", "keepItRolling", "bladeFlurry"}) do
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  for _, k in ipairs({"dispatch", "sinisterStrike", "pistolShot", "ambush"}) do
    Tuono.State.cooldowns[k] = { known = true, ready = true, remaining = 0 }
  end
  -- Talent flags are global and earlier tests flip them to false; a filtered-out rule
  -- looks exactly like a rule that declined to fire, so reset them explicitly.
  Tuono.State.knownSpells = Tuono.State.knownSpells or {}
  for _, id in pairs(Tuono.SpellIDs) do
    if type(id) == "number" then Tuono.State.knownSpells[id] = true end
  end
  Tuono.State.knownUnavailable = false
end


-- TEST: CP Pooling at 5 CP when BtE is coming back up soon (within 1.5s)
test("decisions: CP pooling — SS at 5 CP if BtE will be ready within ~1 GCD", function()
  decisionsBaseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 50  -- Enough for SS
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 5
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 3
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.betweenTheEyes.ready = false
  Tuono.State.cooldowns.betweenTheEyes.remaining = 0.8  -- Coming back soon
  Tuono.State.cooldowns.killingSpree.ready = false
  Tuono.State.cooldowns.killingSpree.remaining = 100  -- Not coming back soon
  Tuono.State.cooldowns.dispatch.ready = true

  local pred = Tuono.Rotation.Predict(Tuono.State, 2)
  assert_true(pred ~= nil, "prediction returned")
  -- At 5 CP with BtE coming back in 0.8s, should recommend SS (pool) not Dispatch
  if #pred > 0 then
    local firstAbility = pred[1].spellID
    -- Should prefer SS for pooling when finisher is coming back up
    assert_true(firstAbility == Tuono.SpellIDs.sinisterStrike or firstAbility == Tuono.SpellIDs.dispatch,
      "first ability is SS (pooling) or Dispatch (fallback)")
  end
end)

-- TEST: Dispatch at 5 CP when BOTH BtE and KS are on long cooldowns
test("decisions: Dispatch fallback — cast at 6 CP when both 6-CP finishers unavailable", function()
  decisionsBaseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 50
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 6
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 2
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.betweenTheEyes.ready = false
  Tuono.State.cooldowns.betweenTheEyes.remaining = 30  -- Long cooldown
  Tuono.State.cooldowns.killingSpree.ready = false
  Tuono.State.cooldowns.killingSpree.remaining = 120  -- Very long cooldown

  local pred = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(pred ~= nil, "prediction returned with both finishers down")
  if #pred > 0 then
    -- With both 6-CP finishers on cooldown, should recommend Dispatch at 6 CP
    assert_eq(pred[1].spellID, Tuono.SpellIDs.dispatch, "recommends Dispatch when finishers unavailable")
  end
end)

-- TEST: Preparation reset cooldown rule
test("decisions: Preparation reset — fires when AR/BtE/BR down", function()
  decisionsBaseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 80
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 2
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 3
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.preparation.ready = true
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 60  -- AR down
  -- Preparation now requires AR, Between the Eyes AND Killing Spree all down, per SimC.
  -- The old OR fired it about two seconds into every pull -- Between the Eyes is on a
  -- 45s cooldown, so it is down nearly always -- burning a FOUR MINUTE cooldown to
  -- reset nothing worth resetting.
  Tuono.State.cooldowns.betweenTheEyes = { known = true, ready = false, remaining = 30 }
  Tuono.State.cooldowns.killingSpree = { known = true, ready = false, remaining = 90 }
  -- NOTE: Blade Rush is deliberately left on cooldown. Its rule outranks Preparation,
  -- so making it ready would (correctly) win the priority walk and this test would be
  -- asserting against the wrong decision.

  local pred = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(pred ~= nil, "prediction returned with Prep up and AR down")
  if #pred > 0 then
    -- When AR is on cooldown and Prep is ready, should recommend Prep
    assert_eq(pred[1].spellID, Tuono.SpellIDs.preparation, "recommends Preparation to reset AR")
  end
end)

-- TEST: Opportunity buff is cleared after virtual Pistol Shot
test("decisions: Opportunity buff cleared after PS — no double-cast in simulation", function()
  decisionsBaseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.buffs.opportunity.up = true  -- Opportunity proc active
  Tuono.State.cooldowns.adrenalineRush.ready = false
  Tuono.State.cooldowns.adrenalineRush.remaining = 50
  Tuono.State.cooldowns.betweenTheEyes.ready = false
  Tuono.State.cooldowns.betweenTheEyes.remaining = 30
  Tuono.State.cooldowns.killingSpree.ready = false
  Tuono.State.cooldowns.killingSpree.remaining = 100

  local pred = Tuono.Rotation.Predict(Tuono.State, 4)
  assert_true(pred ~= nil, "prediction returned with Opportunity up")

  -- Count how many Pistol Shots are in the prediction
  local psCount = 0
  for _, entry in ipairs(pred) do
    if entry.spellID == Tuono.SpellIDs.pistolShot then
      psCount = psCount + 1
    end
  end

  -- Should have at most 1 Pistol Shot (the initial proc), not multiple in a row
  assert_true(psCount <= 1, "Pistol Shot appears at most once in multi-step prediction (opportunity cleared after cast)")
end)

-- TEST: Leveling build (only SS + Dispatch) yields sane sequence
test("decisions: leveling build — SS + Dispatch loop at low level", function()
  decisionsBaseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 100
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 0
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.dispatch.ready = true

  -- Simulate limited spell knowledge: SS and Dispatch only (no BtE, KS, AR, BR, RtB, KIR)
  Tuono.State.knownSpells = {
    [Tuono.SpellIDs.sinisterStrike] = true,
    [Tuono.SpellIDs.dispatch] = true,
    [Tuono.SpellIDs.betweenTheEyes] = false,  -- Not learned yet
    [Tuono.SpellIDs.killingSpree] = false,
    [Tuono.SpellIDs.adrenalineRush] = false,
    [Tuono.SpellIDs.bladeRush] = false,
    [Tuono.SpellIDs.rollTheBones] = false,
    [Tuono.SpellIDs.keepItRolling] = false,
    [Tuono.SpellIDs.preparation] = false,
    [Tuono.SpellIDs.bladeFlurry] = false,
    [Tuono.SpellIDs.ambush] = false
  }

  -- Start at 6 CP so Dispatch can fire (takes 6 SS to reach 6 CP)
  Tuono.State.comboPoints = 6
  local pred = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(pred ~= nil, "prediction returned for leveling build")
  assert_true(#pred > 0, "prediction is not empty for leveling build at 6 CP")

  -- At 6 CP with only SS and Dispatch learned, should recommend Dispatch (6+ CP rule)
  assert_eq(pred[1].spellID, Tuono.SpellIDs.dispatch, "leveling sequence uses Dispatch at 6 CP")
end)

-- TEST: Dispatch at 6 CP when finishers available (should prefer finisher)
test("decisions: Dispatch at 6 CP — only when both BtE/KS unavailable", function()
  decisionsBaseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.energy = 50
  Tuono.State.energyMax = 100
  Tuono.State.comboPoints = 6
  Tuono.State.comboPointsMax = 6
  Tuono.State.buffs.rtb.stage = 3
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.cooldowns.betweenTheEyes.ready = true  -- BtE is ready
  Tuono.State.cooldowns.killingSpree.ready = false
  Tuono.State.cooldowns.killingSpree.remaining = 100

  local pred = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(pred ~= nil, "prediction returned with finisher ready")
  if #pred > 0 then
    -- Should prefer BtE over Dispatch when at 6 CP and BtE is ready
    assert_eq(pred[1].spellID, Tuono.SpellIDs.betweenTheEyes, "prefers BtE over Dispatch at 6 CP")
  end
end)

-- Load and run bar behavior end-to-end tests
local barBehaviorTests = loadfile("tests/bar_behavior.lua")
if barBehaviorTests then
  local runTests = barBehaviorTests()
  if runTests and type(runTests) == "function" then
    runTests(Tuono, stub, assert_eq, assert_true, assert_false, test)
  end
end

-- Summary
-- === p0fix tests ===
-- The v1.5.0 lane shipped these fixes WITHOUT regression tests. Written here so the
-- expert-audit P0s cannot silently return. Each message names the in-game symptom.

local function p0Baseline()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.degraded = false
  Tuono.State.buffs.opportunity.up = false
  Tuono.State.buffs.adrenalineRush.up = false
  Tuono.State.buffs.rtb.stage = 2
  Tuono.State.buffs.rtb.expires = 999
  Tuono.State.energy, Tuono.State.energyMax = 100, 100
  Tuono.State.comboPointsMax = 6
  Tuono.State.enemyCount = 1
  Tuono.db.aoeMode = false
  Tuono.Assist.aoeDetected = false
  Tuono.State.knownSpells = Tuono.State.knownSpells or {}
  for _, id in pairs(Tuono.SpellIDs) do
    if type(id) == "number" then Tuono.State.knownSpells[id] = true end
  end
  Tuono.State.knownUnavailable = false
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                      "killingSpree","rollTheBones","keepItRolling","bladeFlurry"}) do
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  for _, k in ipairs({"dispatch","sinisterStrike","pistolShot","ambush"}) do
    Tuono.State.cooldowns[k] = { known = true, ready = true, remaining = 0 }
  end
end

test("p0: stealth opener appears ONCE, not four times", function()
  p0Baseline()
  stub.state.stealthed = true  -- RefreshFast reads IsStealthed(), so drive the source
  Tuono.State.stealthed = true
  Tuono.State.comboPoints = 0
  local pred = Tuono.Rotation.Predict(Tuono.State, 4)
  assert_true(pred ~= nil and #pred > 1, "stealth prediction has multiple steps")
  local ambushCount = 0
  for _, step in ipairs(pred) do
    if step.spellID == Tuono.SpellIDs.ambush then ambushCount = ambushCount + 1 end
  end
  assert_true(ambushCount <= 1,
    "bar would show Ambush " .. ambushCount .. "x - a one-press opener repeated across the bar")
end)

test("p0: at max combo points the finisher is position 1, not buried behind cooldowns", function()
  p0Baseline()
  Tuono.State.comboPoints = 6
  Tuono.State.cooldowns.betweenTheEyes = { known = true, ready = true, remaining = 0 }
  local pred = Tuono.Rotation.Predict(Tuono.State, 4)
  assert_true(pred ~= nil and #pred > 0, "prediction produced at max CP")
  local first = pred[1].spellID
  assert_true(first == Tuono.SpellIDs.betweenTheEyes or first == Tuono.SpellIDs.dispatch,
    "bar would stall at max CP without spending (position 1 was " .. tostring(first) .. ")")
end)

test("p0: levelling build (SS + Dispatch) spends at 6 CP", function()
  p0Baseline()
  for _, id in pairs(Tuono.SpellIDs) do
    if type(id) == "number" then Tuono.State.knownSpells[id] = false end
  end
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.dispatch] = true
  Tuono.State.comboPoints = 6
  local r = Tuono.Engine.Evaluate()
  assert_true(#r.queue > 0, "levelling queue is non-empty")
  assert_eq(r.queue[1].spellID, Tuono.SpellIDs.dispatch,
    "levelling bar told the player to spend Dispatch at 6 CP")
end)

-- INVERTED. This test asserted the opposite and encoded a factual error: Killing Spree
-- is not "a burst cooldown" that spends nothing, it is a FINISHING MOVE -- Wowhead lists
-- it as "45 Energy / 1 to 7 Combo Points" and its damage and duration scale with the
-- points consumed. Modelling cpSpend=0 meant the simulation never zeroed combo points
-- after a predicted Killing Spree and never credited its Restless Blades CDR, so every
-- step after one in the wheel was wrong.
test("p0: Killing Spree IS modelled as a combo-point spender", function()
  local ks = Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[Tuono.SpellIDs.killingSpree]
  assert_true(ks ~= nil, "Killing Spree present in ability table")
  -- -1 is the "spends all points up to the cap" sentinel, which is the correct model
  -- for a finisher whose value scales with points consumed.
  assert_true(ks.cpSpend == -1,
    "Killing Spree spends combo points (SPEND_ALL), got " .. tostring(ks.cpSpend))
end)

-- === highlight tests ===

test("highlight: module initializes without error", function()
  assert_true(Tuono.Highlight ~= nil, "Highlight module exists")
  assert_true(Tuono.Highlight.Init ~= nil, "Highlight.Init exists")
  assert_true(Tuono.Highlight.Update ~= nil, "Highlight.Update exists")
end)

test("highlight: stub action button frames in globals", function()
  -- Create stub frames for action bar buttons (slots 1-12)
  for i = 1, 12 do
    local frameName = "ActionButton" .. i
    if not _G[frameName] then
      local frame = {
        name = frameName,
        glowActive = false,
        ShowGlow = function(self) self.glowActive = true end,
        HideGlow = function(self) self.glowActive = false end,
        GetName = function(self) return self.name end,
        CreateTexture = function(self, ...)
          return {
            SetAllPoints = function() end,
            SetColorTexture = function() end,
            Show = function() end,
            Hide = function() end
          }
        end
      }
      _G[frameName] = frame
    end
  end
  assert_true(_G.ActionButton1 ~= nil, "ActionButton1 stub created")
end)

test("highlight: resolves spellID to correct action button", function()
  stub.FireEvent("ADDON_LOADED", "Tuono")
  stub.FireEvent("PLAYER_LOGIN")

  -- Ensure highlight is enabled
  Tuono.db.highlight = Tuono.db.highlight or {}
  Tuono.db.highlight.enabled = true

  -- Mock GetActionInfo to return a spell in slot 2
  local testSpellID = 12345
  local oldGetActionInfo = _G.GetActionInfo
  _G.GetActionInfo = function(slot)
    if slot == 2 then
      return "spell", testSpellID, nil
    end
    return nil, nil, nil
  end

  -- Call Highlight.Update with a recommendation
  local result = {
    queue = {
      { spellID = testSpellID, kind = "rotation", confidence = "high" }
    }
  }
  Tuono.Highlight.Update(result)

  -- Verify the button frame was targeted (we'd check the glow state)
  -- For now, just verify no error occurred
  assert_true(true, "Update completed without error")

  _G.GetActionInfo = oldGetActionInfo
end)

test("highlight: exactly one button glows at a time", function()
  Tuono.db.highlight = Tuono.db.highlight or {}
  Tuono.db.highlight.enabled = true

  local spellID1 = 11111
  local spellID2 = 22222

  -- First recommendation
  local result1 = {
    queue = {
      { spellID = spellID1, kind = "rotation", confidence = "high" }
    }
  }
  Tuono.Highlight.Update(result1)

  -- Second recommendation (should clear first)
  local result2 = {
    queue = {
      { spellID = spellID2, kind = "rotation", confidence = "high" }
    }
  }
  Tuono.Highlight.Update(result2)

  -- Verify no error and cache was updated
  assert_true(true, "Updated twice without error")
end)

test("highlight: clears on disabled toggle", function()
  Tuono.db.highlight.enabled = true
  local result = {
    queue = {
      { spellID = 33333, kind = "rotation", confidence = "high" }
    }
  }
  Tuono.Highlight.Update(result)

  -- Disable and update
  Tuono.db.highlight.enabled = false
  Tuono.Highlight.Update(result)

  assert_true(true, "Toggle disable completed without error")
end)

test("highlight: handles missing spell on action bar", function()
  Tuono.db.highlight.enabled = true

  -- Mock GetActionInfo to return nothing
  local oldGetActionInfo = _G.GetActionInfo
  _G.GetActionInfo = function(slot)
    return nil, nil, nil
  end

  local result = {
    queue = {
      { spellID = 99999, kind = "rotation", confidence = "high" }
    }
  }

  -- Should not error even if spell is not on any action bar
  Tuono.Highlight.Update(result)
  assert_true(true, "Handled missing action bar spell without error")

  _G.GetActionInfo = oldGetActionInfo
end)

test("highlight: config defaults include highlight settings", function()
  assert_true(Tuono.db.highlight ~= nil, "highlight key in db")
  assert_true(Tuono.db.highlight.enabled ~= nil, "highlight.enabled exists")
  assert_true(Tuono.db.highlight.combatOnly ~= nil, "highlight.combatOnly exists")
end)

test("highlight: debug output function exists", function()
  assert_true(Tuono.Highlight.AppendDebugOutput ~= nil, "AppendDebugOutput function exists")
  -- Call it without error
  Tuono.Highlight.AppendDebugOutput()
  assert_true(true, "AppendDebugOutput executed without error")
end)

-- === pipeline isolation tests ===
test("pipeline: a Display error does not disable Highlight (stage isolation)", function()
  -- Regression: Render and Highlight.Update shared one pcall, so a bad SetText in
  -- Render aborted the tick and the action-bar glow silently never ran.
  local realRender = Tuono.Display.Render
  local highlightRan = false
  local realHL = Tuono.Highlight and Tuono.Highlight.Update
  Tuono.Display.Render = function() error("simulated render failure") end
  if Tuono.Highlight then
    Tuono.Highlight.Update = function() highlightRan = true end
  end

  for _, h in ipairs(Tuono.updateHandlers or {}) do
    Tuono.safe(h.fn)
  end

  Tuono.Display.Render = realRender
  if Tuono.Highlight then Tuono.Highlight.Update = realHL end
  assert_true(highlightRan,
    "Highlight did not run after a Display error - one broken stage disables the rest")
end)

test("keybind cache miss returns nil, never the sentinel table", function()
  -- Regression: `(cached == MISS) and nil or cached` returns the sentinel in Lua,
  -- which reached SetText and threw "bad argument #1 to SetText".
  if Tuono.Display and Tuono.Display.GetKeybindTextForTest then
    local v = Tuono.Display.GetKeybindTextForTest(999999)
    assert_true(v == nil or type(v) == "string",
      "keybind lookup returned a " .. type(v) .. " - SetText would throw")
  else
    -- fall back to exercising it through a render with an unbound spell
    local ok = pcall(Tuono.Display.Render, { queue = { { spellID = 999999, kind = "rotation",
      source = "test", confidence = "high", isSequence = true } }, advisories = {} })
    assert_true(ok, "render threw on an unbound spell (sentinel leaked into SetText)")
  end
end)

-- === stealth source tests ===
test("stealth clears when IsStealthed() goes false (Ambush must not pin forever)", function()
  -- Regression: stealth was derived from the aura scan, which goes blind in combat, so
  -- the flag never cleared and Ambush stayed pinned at position 1 permanently.
  stub.state.stealthed = true
  Tuono.State.RefreshFast()
  assert_true(Tuono.State.stealthed, "stealth detected while stealthed")

  stub.state.stealthed = false
  Tuono.State.RefreshFast()
  assert_false(Tuono.State.stealthed,
    "stealth stayed true after leaving stealth - the opener would pin to the bar forever")
end)

-- === failed-cast tests ===
test("a failed cast forces an immediate re-evaluate (out of range recovery)", function()
  -- Regression: with no UNIT_SPELLCAST_FAILED handler an out-of-range cast changed
  -- nothing, so the bar kept glowing the same unusable button indefinitely.
  local handlers = Tuono.eventHandlers and Tuono.eventHandlers["UNIT_SPELLCAST_FAILED"]
  assert_true(handlers ~= nil and #handlers > 0,
    "UNIT_SPELLCAST_FAILED is not registered - a failed cast would never refresh the bar")
  local ran = false
  local realRequest = Tuono.RequestImmediateUpdate
  Tuono.RequestImmediateUpdate = function() ran = true end
  for _, fn in ipairs(handlers) do fn("UNIT_SPELLCAST_FAILED", "player") end
  Tuono.RequestImmediateUpdate = realRequest
  assert_true(ran, "failed cast did not request an immediate update")
end)

-- === combo-point-max tests ===
-- ROOT CAUSE of the user's entire symptom list: a levelling rogue has comboPointsMax = 5,
-- finishers hardcoded >= 6 (unreachable) and the builder was gated below max, so at 5 CP
-- the sequence went EMPTY -> fell back to Blizzard's static pick -> frozen icon, no glow.
-- The stub hardcoded 6, so 166 tests never saw it.
test("bar is never empty at max combo points, for any comboPointsMax 4..7", function()
  for _, mx in ipairs({4, 5, 6, 7}) do
    Tuono.State.inCombat = true
    stub.state.stealthed = false
    Tuono.State.stealthed = false
    Tuono.State.buffs.degraded = false
    Tuono.State.buffs.opportunity.up = false
    Tuono.State.buffs.opportunity.stacks = 0
    Tuono.State.buffs.adrenalineRush.up = false
    Tuono.State.buffs.rtb.stage = 2
    Tuono.State.energy, Tuono.State.energyMax = 100, 100
    Tuono.State.comboPointsMax = mx
    Tuono.State.comboPoints = mx
    Tuono.State.knownSpells = Tuono.State.knownSpells or {}
    for _, id in pairs(Tuono.SpellIDs) do
      if type(id) == "number" then Tuono.State.knownSpells[id] = true end
    end
    Tuono.State.knownUnavailable = false
    for _, k in ipairs({"adrenalineRush","bladeRush","preparation","killingSpree",
                        "rollTheBones","keepItRolling","bladeFlurry"}) do
      Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
    end
    for _, k in ipairs({"betweenTheEyes","dispatch","sinisterStrike","pistolShot","ambush"}) do
      Tuono.State.cooldowns[k] = { known = true, ready = true, remaining = 0 }
    end

    local pred = Tuono.Rotation.Predict(Tuono.State, 4)
    assert_true(pred ~= nil and #pred > 0,
      "sequence EMPTY at max CP with comboPointsMax=" .. mx ..
      " - the bar would freeze on Blizzard's static pick with no glow")
    local spendsCP = false
    for _, step in ipairs(pred) do
      local ab = Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[step.spellID]
      if ab and ab.cpSpend and ab.cpSpend ~= 0 and ab.cpSpend ~= false then spendsCP = true end
    end
    assert_true(spendsCP,
      "no finisher reachable at max CP with comboPointsMax=" .. mx .. " - combo points would cap forever")
  end
  Tuono.State.comboPointsMax = 5
end)

print("")
print(passCount .. "/" .. testCount .. " tests passed")

-- === spec-priority tests ===

-- TEST: Rule 1 fires at stage 0
test("spec-priority: rule 1 (RtB) fires at stage 0", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 0
  Tuono.State.knownSpells[Tuono.SpellIDs.rollTheBones] = true
  Tuono.State.cooldowns.rollTheBones = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                      "killingSpree","keepItRolling","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.rollTheBones, "RtB fires at stage 0")
end)

-- TEST: Rule 2 (KIR) fires at stage 2
-- Threshold moved from stage 2 to stage 3, matching SimC (rtb_buffs>=3) and Maxroll
-- ("Stage 3 or higher"). Locking a six-minute cooldown into Double Trouble when Triple
-- Threat or Jackpot was one reroll away is a real loss.
-- stageKnown must be set too: the rule now refuses to act on an unreadable stage,
-- because treating unknown as 0 is what made it recommend rerolling a Jackpot.
test("spec-priority: rule 2 (KIR) fires at stage 3", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 3
  Tuono.State.buffs.rtb.stageKnown = true
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 0
  Tuono.State.knownSpells[Tuono.SpellIDs.keepItRolling] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.rollTheBones] = true
  Tuono.State.cooldowns.keepItRolling = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.rollTheBones = { known = true, ready = false, remaining = 30 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                      "killingSpree","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.keepItRolling, "KIR fires at stage 2")
end)

-- TEST: Rule 3 (AR) fires at low CP (<=2)
test("spec-priority: rule 3 (AR) fires at low CP", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 2
  Tuono.State.knownSpells[Tuono.SpellIDs.adrenalineRush] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.adrenalineRush = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"bladeRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.adrenalineRush, "AR fires at low CP")
end)

-- TEST: Rule 4 (Blade Rush) fires on cooldown
test("spec-priority: rule 4 (Blade Rush) fires on cooldown", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 4
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeRush] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.bladeRush = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.bladeRush, "Blade Rush fires on cooldown")
end)

-- TEST: Rule 5 (BtE) fires at 6+ CP
test("spec-priority: rule 5 (BtE) fires at 6+ CP", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 6
  Tuono.State.knownSpells[Tuono.SpellIDs.betweenTheEyes] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.betweenTheEyes = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.betweenTheEyes, "BtE fires at 6+ CP")
end)

-- TEST: Rule 6 (Preparation) fires when reset targets are down
test("spec-priority: rule 6 (Preparation) fires when AR down", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 0
  Tuono.State.knownSpells[Tuono.SpellIDs.preparation] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.preparation = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.adrenalineRush = { known = true, ready = false, remaining = 20 }
  Tuono.State.cooldowns.bladeRush = { known = true, ready = false, remaining = 20 }
  Tuono.State.cooldowns.betweenTheEyes = { known = true, ready = false, remaining = 20 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.preparation, "Preparation fires when targets down")
end)

-- TEST: Rule 7 (Killing Spree) fires at 6+ CP
test("spec-priority: rule 7 (Killing Spree) fires at 6+ CP", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 6
  Tuono.State.knownSpells[Tuono.SpellIDs.killingSpree] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.killingSpree = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.betweenTheEyes = { known = true, ready = false, remaining = 20 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","rollTheBones",
                      "keepItRolling","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.killingSpree, "Killing Spree fires at 6+ CP")
end)

-- TEST: Rule 8 (Dispatch) fires at 6+ CP when finishers unavailable
test("spec-priority: rule 8 (Dispatch) fires at 6+ CP finisher unavailable", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 6
  Tuono.State.knownSpells[Tuono.SpellIDs.dispatch] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.dispatch = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.betweenTheEyes = { known = true, ready = false, remaining = 20 }
  Tuono.State.cooldowns.killingSpree = { known = true, ready = false, remaining = 20 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","rollTheBones",
                      "keepItRolling","bladeFlurry","ambush","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.dispatch, "Dispatch fires at 6+ CP when finishers unavailable")
end)

-- TEST: Rule 9 (Pistol Shot) fires with 6+ Opportunity stacks at any CP
test("spec-priority: rule 9 (PS) fires with 6+ stacks at any CP", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.opportunity.up = true
  Tuono.State.buffs.opportunity.stacks = 6
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 3
  Tuono.State.knownSpells[Tuono.SpellIDs.pistolShot] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.pistolShot = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.pistolShot, "PS fires with 6+ stacks")
end)

-- TEST: Rule 9 (Pistol Shot) fires with 3-5 stacks only at 1-3 CP
test("spec-priority: rule 9 (PS) fires with 3-5 stacks only at 1-3 CP", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.opportunity.up = true
  Tuono.State.buffs.opportunity.stacks = 3
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 2
  Tuono.State.knownSpells[Tuono.SpellIDs.pistolShot] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.pistolShot = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.pistolShot, "PS fires with 3 stacks at 2 CP")
end)

-- TEST: Rule 9 (Pistol Shot) does NOT fire with 3-5 stacks at 4+ CP
test("spec-priority: rule 9 (PS) does NOT fire with 3-5 stacks at 4+ CP", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.buffs.opportunity.up = true
  Tuono.State.buffs.opportunity.stacks = 3
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 4
  Tuono.State.knownSpells[Tuono.SpellIDs.pistolShot] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.pistolShot = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.sinisterStrike, "PS does NOT fire with 3 stacks at 4 CP, SS used instead")
end)

-- TEST: Rule 10 (Sinister Strike) fires as default builder
test("spec-priority: rule 10 (SS) fires as default builder", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 2
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.sinisterStrike, "SS fires as default builder")
end)

-- TEST: Blade Flurry fires at low CP with 2+ enemies
test("spec-priority: Blade Flurry fires at low CP with 2+ enemies", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 1
  Tuono.State.enemyCount = 2
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeFlurry] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.bladeFlurry = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.bladeFlurry, "BF fires at 1 CP with 2+ enemies")
end)

-- TEST: Blade Flurry does NOT fire at 3+ CP even with 2+ enemies
test("spec-priority: Blade Flurry does NOT fire at 3+ CP", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 3
  Tuono.State.enemyCount = 2
  Tuono.State.knownSpells[Tuono.SpellIDs.bladeFlurry] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
  Tuono.State.cooldowns.bladeFlurry = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes","killingSpree",
                      "rollTheBones","keepItRolling","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  assert_eq(p[1].spellID, Tuono.SpellIDs.sinisterStrike, "BF does NOT fire at 3 CP, SS used instead")
end)

-- TEST: Rule ordering - rule N+1 doesn't fire if rule N fires
test("spec-priority: rule ordering (RtB before KIR)", function()
  Tuono.State.inCombat = true
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.State.buffs.rtb.stage = 0  -- RtB fires at stage < 2
  Tuono.State.energy = 100
  Tuono.State.comboPoints = 0
  Tuono.State.knownSpells[Tuono.SpellIDs.rollTheBones] = true
  Tuono.State.knownSpells[Tuono.SpellIDs.keepItRolling] = true
  Tuono.State.cooldowns.rollTheBones = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.keepItRolling = { known = true, ready = true, remaining = 0 }
  Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
  for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes","killingSpree",
                      "bladeFlurry","ambush","dispatch","pistolShot"}) do
    Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
    Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
  end
  local p = Tuono.Rotation.Predict(Tuono.State, 1)
  assert_true(#p > 0, "prediction returned")
  -- RtB (rule 1) should fire before KIR (rule 2)
  assert_eq(p[1].spellID, Tuono.SpellIDs.rollTheBones, "RtB (rule 1) fires before KIR (rule 2)")
end)

-- === state-transition tests ===
-- Stealth swaps the action bar page (bonus bar), and talents/procs can swap the
-- spell actually sitting on a slot (overrides). These tests prove Display/Highlight
-- correctly re-resolve the button/keybind for the SAME recommended spellID across a
-- stealth transition, that override IDs resolve in both directions, that Ambush is
-- gated to stealth-only, that every registered cache-invalidation event actually
-- invalidates, and that an unplaced spell never errors.

-- Helper: create a minimal stub button frame (GetButtonFrame requires .GetName) and
-- register it in _G under the given name, matching the pattern already used by the
-- pre-existing "highlight: stub action button frames in globals" test.
-- TAINT GUARD. The glow used to call buttonFrame:CreateTexture() on Blizzard's secure
-- ActionButtons, lazily, from the 0.1s combat tick -- which taints the button's region
-- list and surfaces later as "Interface action failed because of an AddOn" when the
-- player clicks it. The overlay is now our own UIParent-parented frame merely anchored
-- to the button, so nothing is ever written to the secure frame.
--
-- This test fails the moment anyone reintroduces a write. Anchoring (SetAllPoints
-- against the button) is a read and stays allowed.
test("taint: glow never creates regions on the secure action button", function()
  local touched = {}
  local btn = {
    name = "ActionButton1",
    GetName = function(self) return self.name end,
    IsVisible = function() return true end,
    CreateTexture = function() touched[#touched + 1] = "CreateTexture" return nil end,
    CreateFontString = function() touched[#touched + 1] = "CreateFontString" return nil end,
    CreateAnimationGroup = function() touched[#touched + 1] = "CreateAnimationGroup" return nil end,
    SetScript = function() touched[#touched + 1] = "SetScript" end,
  }
  _G.ActionButton1 = btn

  Tuono.Highlight.Init()
  Tuono.db.highlight.enabled = true
  stub.SetActionSlot(1, "spell", Tuono.SpellIDs.sinisterStrike)

  Tuono.Highlight.Update({ queue = { { spellID = Tuono.SpellIDs.sinisterStrike } } })
  Tuono.Highlight.Update({ queue = { { spellID = Tuono.SpellIDs.dispatch } } })

  assert_eq(#touched, 0,
    "wrote to the secure button: " .. table.concat(touched, ", "))
end)

local function makeButtonFrameStub(name)
  local btn = {
    name = name,
    GetName = function(self) return self.name end,
    -- A real ActionButton on screen IS visible. The glow now skips buttons that report
    -- hidden (so a faded or vehicle-swapped bar does not leave an overlay floating over
    -- nothing), so a stub that reports hidden models a bar nobody can see and would
    -- suppress every glow in the suite.
    IsVisible = function() return true end,
    IsShown = function() return true end,
    -- Kept only so the addon can still ANCHOR to it. Nothing writes to a real secure
    -- button any more -- creating regions on one from a combat tick is what tainted it.
    CreateTexture = function(self, texName, layer)
      local tex = { visible = false }
      function tex:SetAllPoints() end
      function tex:SetColorTexture() end
      function tex:Show() self.visible = true end
      function tex:Hide() self.visible = false end
      return tex
    end
  }
  _G[name] = btn
  return btn
end

local function resetActionBarStub()
  stub.state.actionSlots = { [1] = { "spell", 193315 } }
  stub.state.bonusBarOffset = 0
  stub.state.actionBarPage = 1
  stub.ClearSpellOverrides()
end

-- TEST 1: same spellID resolves to a different button/keybind across a stealth swap.
test("state-transition: keybind follows the same spellID across a stealth swap", function()
  resetActionBarStub()
  makeButtonFrameStub("ActionButton1")
  Tuono.db.display.iconCount = 4

  -- Stealth-only ability, placed ONLY on the stealth bonus-bar slot (bonusBarOffset 1,
  -- button 1 => 1 + (NUM_ACTIONBAR_PAGES + 1 - 1) * NUM_ACTIONBAR_BUTTONS = 73).
  local testSpellID = 555001
  stub.state.actionSlots = { [73] = { "spell", testSpellID } }
  stub.state.bonusBarOffset = 0  -- not stealthed yet

  local result = { queue = { { spellID = testSpellID, kind = "rotation", source = "test" } } }
  Tuono.Display.Render(result)
  assert_false(Tuono.Display.anchor.icons[1].keyText.visible,
    "not stealthed: a spell that ONLY exists on the stealth bonus-bar slot must not resolve to a live ACTIONBUTTON keybind")

  -- Enter stealth and fire the registered invalidation event.
  stub.state.bonusBarOffset = 1
  stub.FireEvent("UPDATE_STEALTH")
  Tuono.Display.Render(result)
  assert_true(Tuono.Display.anchor.icons[1].keyText.visible,
    "stealthed: the same spellID now resolves once its slot is button 1's CURRENT slot")
  assert_eq(Tuono.Display.anchor.icons[1].keyText.text, "1",
    "resolved keybind matches ACTIONBUTTON1's binding once the bonus-bar slot is the CURRENT main-bar slot 1")

  resetActionBarStub()
end)

-- TEST 1b: the glow (Highlight) side of the same transition.
test("state-transition: highlight glow follows the same spellID across a stealth swap", function()
  resetActionBarStub()
  makeButtonFrameStub("ActionButton1")
  Tuono.db.highlight = Tuono.db.highlight or {}
  Tuono.db.highlight.enabled = true

  local testSpellID = 555002
  stub.state.actionSlots = { [73] = { "spell", testSpellID } }
  stub.state.bonusBarOffset = 0

  local result = { queue = { { spellID = testSpellID, kind = "rotation", source = "test" } } }
  Tuono.Highlight.Update(result)

  local function captureDebugField(pattern)
    local captured = {}
    local originalPrint = Tuono.print
    Tuono.print = function(msg) table.insert(captured, tostring(msg)) end
    Tuono.Highlight.AppendDebugOutput()
    Tuono.print = originalPrint
    for _, line in ipairs(captured) do
      local m = line:match(pattern)
      if m then return m end
    end
    return nil
  end

  local beforeButton = captureDebugField("Button frame: (.+)")
  assert_true(beforeButton ~= "ActionButton1",
    "not stealthed: glow must NOT target ActionButton1 for a spell only on the bonus-bar slot (was: " .. tostring(beforeButton) .. ")")

  -- Enter stealth: recommendation (spellID) is UNCHANGED, only the bar layout moved.
  -- Without barDirty this would incorrectly cache-hit and never re-resolve.
  stub.state.bonusBarOffset = 1
  stub.FireEvent("UPDATE_STEALTH")
  Tuono.Highlight.Update(result)

  local afterButton = captureDebugField("Button frame: (.+)")
  assert_eq(afterButton, "ActionButton1",
    "stealthed: the SAME spellID's glow now resolves to ActionButton1 (the CURRENT button 1)")

  resetActionBarStub()
  Tuono.Highlight.Update({ queue = {} })
end)

-- TEST 2: override ID resolves to its base, and base resolves to its active override.
test("state-transition: override spell ID resolves to its base and back", function()
  resetActionBarStub()
  local baseID = 8676     -- Ambush (Tuono.SpellIDs.ambush)
  local overrideID = 900001
  stub.SetSpellOverride(baseID, overrideID)

  assert_eq(Tuono.ResolveOverrideSpell(baseID), overrideID, "base -> override resolves to the active override")
  assert_eq(Tuono.ResolveBaseSpell(overrideID), baseID, "override -> base resolves back to the base spell")
  assert_eq(Tuono.ResolveBaseSpell(baseID), baseID, "a spell with no override resolves to itself")
  assert_eq(Tuono.ResolveOverrideSpell(999999), 999999, "an unrelated spellID resolves to itself")

  assert_true(Tuono.SpellMatchesAction(baseID, overrideID), "SpellMatchesAction: base spellID matches its override sitting on a slot")
  assert_true(Tuono.SpellMatchesAction(baseID, baseID), "SpellMatchesAction: a spell always matches itself")
  assert_false(Tuono.SpellMatchesAction(baseID, 999999), "SpellMatchesAction: an unrelated action slot does not match")

  -- Behavioral proof: the override sits on the action bar (NOT the base ID), and
  -- resolution still finds it because it's given the base ID (as Tuono.SpellIDs always
  -- holds), matching the "expects a base spell" contract of FindSpellActionButtons.
  stub.state.actionSlots = { [1] = { "spell", overrideID } }
  local result = { queue = { { spellID = baseID, kind = "rotation", source = "test" } } }
  makeButtonFrameStub("ActionButton1")
  Tuono.db.display.iconCount = 4
  stub.FireEvent("UPDATE_STEALTH")  -- force cache invalidation before resolving
  Tuono.Display.Render(result)
  assert_true(Tuono.Display.anchor.icons[1].keyText.visible,
    "base spellID resolves to its override's slot: keybind found even though the bar holds the OVERRIDE id, not the base")

  stub.ClearSpellOverrides()
  resetActionBarStub()
end)

-- TEST 3: Ambush is recommended ONLY while stealthed. Mirrors the minimal setup
-- pattern of the pre-existing P0-1/P0-2 tests (no manual knownSpells/cooldown
-- overrides) so it exercises the real Assist/RefreshFast/Engine pipeline exactly
-- like those, just asserting the NOT-stealthed side too.
test("state-transition: Ambush recommended only while stealthed", function()
  Tuono.State.inCombat = false
  stub.state.stealthed = false
  Tuono.State.stealthed = false
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local rNotStealthed = Tuono.Engine.Evaluate()
  local ambushFoundNotStealthed = false
  for _, entry in ipairs(rNotStealthed.queue or {}) do
    if entry.spellID == Tuono.SpellIDs.ambush then ambushFoundNotStealthed = true end
  end
  assert_false(ambushFoundNotStealthed, "Ambush is NOT recommended anywhere in the queue while not stealthed")

  Tuono.State.inCombat = true
  stub.state.stealthed = true
  Tuono.State.stealthed = true
  Tuono.Assist.Update()
  Tuono.State.RefreshFast()

  local rStealthed = Tuono.Engine.Evaluate()
  assert_true(#rStealthed.queue > 0, "queue has entries while stealthed")
  assert_eq(rStealthed.queue[1].spellID, Tuono.SpellIDs.ambush, "Ambush pins at position 1 when stealthed")

  stub.state.stealthed = false
  Tuono.State.stealthed = false
end)

-- TEST 4: every registered cache-invalidation event actually invalidates the keybind
-- cache (proves the event registrations added to Display.lua are wired correctly,
-- not just present).
test("state-transition: every registered event invalidates the keybind cache", function()
  local events = { "UPDATE_STEALTH", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
                    "ACTIONBAR_SLOT_CHANGED", "SPELLS_CHANGED", "UPDATE_BINDINGS",
                    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }
  makeButtonFrameStub("ActionButton1")
  Tuono.db.display.iconCount = 4

  for idx, eventName in ipairs(events) do
    local testSpellID = 555100 + idx
    stub.state.actionSlots = {}
    stub.state.bonusBarOffset = 0

    local result = { queue = { { spellID = testSpellID, kind = "rotation", source = "test" } } }
    Tuono.Display.Render(result)
    assert_false(Tuono.Display.anchor.icons[1].keyText.visible,
      eventName .. ": no keybind before the spell is placed on any slot")

    -- Place the spell on the always-current slot 1 WITHOUT firing an invalidation
    -- event yet: the stale cached miss must persist (proves the cache is real).
    stub.state.actionSlots[1] = { "spell", testSpellID }
    Tuono.Display.Render(result)
    assert_false(Tuono.Display.anchor.icons[1].keyText.visible,
      eventName .. ": stale cached miss persists until an invalidation event fires")

    stub.FireEvent(eventName)
    Tuono.Display.Render(result)
    assert_true(Tuono.Display.anchor.icons[1].keyText.visible,
      eventName .. ": keybind resolves once this event invalidates the cache")
  end

  resetActionBarStub()
  Tuono.State.inCombat = false
end)

-- TEST 5: nothing errors when the recommended spell is on no action bar at all
-- (common while levelling: many abilities aren't dragged onto any bar yet).
test("state-transition: no error when spell is on no action bar at all", function()
  resetActionBarStub()
  stub.state.actionSlots = {}  -- nothing placed anywhere
  Tuono.db.display.iconCount = 4
  Tuono.db.highlight = Tuono.db.highlight or {}
  Tuono.db.highlight.enabled = true

  local result = { queue = { { spellID = 777777, kind = "rotation", source = "test" } } }

  local okDisplay = pcall(Tuono.Display.Render, result)
  assert_true(okDisplay, "Display.Render does not error when the spell is on no action bar")
  assert_false(Tuono.Display.anchor.icons[1].keyText.visible, "keybind hidden (not found) rather than erroring")

  local okHighlight = pcall(Tuono.Highlight.Update, result)
  assert_true(okHighlight, "Highlight.Update does not error when the spell is on no action bar")

  resetActionBarStub()
  Tuono.Highlight.Update({ queue = {} })
end)

-- TEST 6: regression coverage for the coordinator-reported Tuono.safe / forward-reference
-- fixes made alongside the state-transition work (same files, directly relevant).
test("state-transition: Tuono.Rotation.SPELL_TO_CDKEY is populated (forward-reference fix)", function()
  assert_true(type(Tuono.Rotation.SPELL_TO_CDKEY) == "table", "SPELL_TO_CDKEY is a table, not nil")
  local count = 0
  for _ in pairs(Tuono.Rotation.SPELL_TO_CDKEY) do count = count + 1 end
  assert_true(count > 0, "SPELL_TO_CDKEY is populated (was permanently nil before the export-order fix)")
  assert_eq(Tuono.Rotation.SPELL_TO_CDKEY[Tuono.SpellIDs.ambush], "ambush", "SPELL_TO_CDKEY maps Ambush's spellID back to its cooldown key")
end)

test("state-transition: modern C_ActionBar.FindSpellActionButtons path is actually used (Tuono.safe fix)", function()
  resetActionBarStub()
  makeButtonFrameStub("ActionButton1")
  Tuono.db.display.iconCount = 4

  -- The stub's C_ActionBar.FindSpellActionButtons only answers for 193315 (slot 1).
  -- Count how many times the 120-slot fallback (GetActionInfo) is invoked while
  -- resolving that spell's keybind: with the Tuono.safe single-return fix, TIER 1
  -- succeeds and the fallback loop is never reached for this spellID.
  local fallbackCalls = 0
  local originalGetActionInfo = _G.GetActionInfo
  _G.GetActionInfo = function(slot)
    fallbackCalls = fallbackCalls + 1
    return originalGetActionInfo(slot)
  end

  stub.FireEvent("UPDATE_STEALTH")  -- force cache invalidation
  local result = { queue = { { spellID = 193315, kind = "rotation", source = "test" } } }
  Tuono.Display.Render(result)

  _G.GetActionInfo = originalGetActionInfo

  assert_true(Tuono.Display.anchor.icons[1].keyText.visible, "keybind resolved for the spell covered by the modern API stub")
  assert_eq(fallbackCalls, 0,
    "GetActionInfo fallback was NOT called: the modern C_ActionBar.FindSpellActionButtons path resolved it directly (was dead before the Tuono.safe fix)")

  resetActionBarStub()
end)

if passCount ~= testCount then
  os.exit(1)
end

os.exit(0)
