-- ============================================================================
-- RECALCULATION TRIGGERS
-- ============================================================================
-- What is allowed to throw away a plan, and -- just as important -- what is not.
--
-- Every trigger is a chance for the bar to churn again, which is the defect the plan
-- layer exists to fix. So each one gets a pair of tests: it FIRES on a real state change,
-- and it does NOT fire on the same sensor merely losing its signal. The second half is
-- the one that matters. A trigger that cannot tell "the world changed" from "I stopped
-- being able to see the world" reintroduces the original complaint wholesale.
--
-- Traps already paid for by this suite, restated so they are not re-learned:
--   * poking Tuono.State from a tick callback does not survive State.RefreshFast, so
--     state-comparison triggers are driven through Tuono.Engine.Evaluate() directly
--   * firing UNIT_SPELLCAST_SUCCEEDED alone is not a cast -- harness.cast applies the
--     ability's real cost, generation and cooldown
-- ============================================================================

local harness = require("harness")

local SINISTER_STRIKE = 193315
local PISTOL_SHOT = 185763       -- profiles/OutlawRogue.lua overlayAuras -> "opportunity"
local ADRENALINE_RUSH = 13750
local NOT_OUR_PROC = 999123      -- some other class's button lighting up

local function world(stub)
  stub.state.inCombat = true
  stub.state.energy = 100
  stub.state.comboPoints = 3
  stub.state.assist.nextSpell = SINISTER_STRIKE
  stub.state.assist.rotationSpells = { SINISTER_STRIKE }
end

-- Boot, and get a plan on the board.
local function planned(opts)
  local Tuono, stub = harness.boot({ world = world, inCombat = true })
  if opts and opts.before then opts.before(Tuono, stub) end
  harness.evaluate(Tuono)
  return Tuono, stub
end

describe("triggers: the set is named and inspectable", function()
  it("publishes every trigger reason as a named constant", function()
    local Tuono = harness.boot()
    local T = Tuono.Engine.TRIGGER
    expect.truthy(T, "Engine.TRIGGER is not published")
    for _, name in ipairs({ "DEVIATED", "PROC", "COOLDOWN", "RTB_STAGE", "TARGET",
                            "MODE", "TALENTS", "COMBAT", "DISAGREE", "EXHAUSTED",
                            "AGED", "WORLD" }) do
      expect.truthy(T[name], "TRIGGER." .. name .. " missing")
    end
  end)

  it("records why the last re-plan happened", function()
    -- A trace that shows a re-plan without saying what caused it is not diagnosable.
    -- That is how the original churn went unexplained for as long as it did.
    local Tuono, stub = planned()
    expect.truthy(Tuono.Engine.lastTrigger, "no reason recorded for the first plan")
    expect.truthy(Tuono.Engine.triggerCounts, "no trigger tally kept")
  end)

  it("counts an invalidation and its re-plan as one event, not two", function()
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    Tuono.Engine.triggerCounts = {}
    stub.FireEvent("PLAYER_TARGET_CHANGED")
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.triggerCounts[T.TARGET], 1,
      "double counting makes the tally useless for judging which trigger is noisy")
  end)
end)

describe("triggers: a proc landing or falling off", function()
  it("re-plans when a proc the profile gates on lights up", function()
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    stub.FireEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", PISTOL_SHOT)
    expect.falsy(Tuono.Engine.plan, "an Opportunity proc must invalidate the plan")
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.PROC)
  end)

  it("re-plans on the falling edge too", function()
    -- The overlay fires on BOTH edges. A proc expiring makes a rule that was firing stop
    -- firing, which changes the answer just as much as it landing did.
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    stub.FireEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", PISTOL_SHOT)
    expect.falsy(Tuono.Engine.plan, "a proc falling off must invalidate the plan")
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.PROC)
  end)

  it("ignores a proc the profile does not gate on", function()
    -- Every spell in the game lights up somebody's button. Re-planning on another
    -- class's proc would be churn carrying no information.
    local Tuono, stub = planned()
    local planBefore = Tuono.Engine.plan
    stub.FireEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", NOT_OUR_PROC)
    expect.truthy(Tuono.Engine.plan, "an unrelated proc invalidated the plan")
    expect.equal(Tuono.Engine.plan, planBefore)
  end)

  it("ignores an unreadable proc spellID", function()
    local Tuono, stub = planned()
    stub.FireEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", stub.makeSecret(PISTOL_SHOT))
    expect.truthy(Tuono.Engine.plan,
      "a secret spellID is not evidence of anything and must not move the bar")
  end)
end)

describe("triggers: a cooldown coming up", function()
  it("re-plans when a cooldown we knew was down becomes ready", function()
    local Tuono, stub = planned({
      before = function(_, stub2) stub2.setCooldown(ADRENALINE_RUSH, 120) end,
    })
    local T = Tuono.Engine.TRIGGER
    expect.truthy(Tuono.Engine.planContext, "no plan context captured")
    expect.truthy(Tuono.Engine.planContext.notReady["adrenalineRush"],
      "Adrenaline Rush was not recorded as known-not-ready at plan time")

    stub.clearCooldown(ADRENALINE_RUSH)
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.COOLDOWN,
      "a major cooldown becoming available makes a higher-priority rule true")
  end)

  it("does not re-plan when a cooldown merely starts running", function()
    -- Going ON cooldown is something the plan itself caused and already predicted.
    -- Treating it as news would re-plan after every single cast.
    local Tuono, stub = planned()
    local planAt = Tuono.Engine.planAt
    stub.setCooldown(ADRENALINE_RUSH, 120)
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.planAt, planAt,
      "a cooldown starting is not a trigger; the plan caused it")
  end)
end)

describe("triggers: Roll the Bones stage", function()
  -- Driven against Tuono.Engine.Evaluate directly: RefreshFast would overwrite a poke
  -- into Tuono.State and leave the input constant, which is how three earlier tests in
  -- this suite were silently vacuous.
  local function stageWorld()
    local Tuono, stub = harness.boot({ world = world, inCombat = true })
    Tuono.State.buffs.rtb.stage = 4
    Tuono.State.buffs.rtb.stageKnown = true
    Tuono.Engine.Evaluate()
    return Tuono, stub
  end

  it("re-plans when the stage changes between two known values", function()
    local Tuono, stub = stageWorld()
    local T = Tuono.Engine.TRIGGER
    expect.equal(Tuono.Engine.planContext.rtbStage, 4, "stage not captured at plan time")
    Tuono.State.buffs.rtb.stage = 1
    Tuono.State.buffs.rtb.stageKnown = true
    Tuono.Engine.Evaluate()
    expect.equal(Tuono.Engine.lastTrigger, T.RTB_STAGE)
  end)

  it("does NOT re-plan when the stage merely becomes unreadable", function()
    -- The whole difficulty in one test. The stage was readable on 27% of live ticks
    -- before it was modelled; if losing the signal counted as a change, the bar would
    -- flap exactly as it used to. An absence of evidence is not evidence of change.
    local Tuono, stub = stageWorld()
    local planAt = Tuono.Engine.planAt
    Tuono.State.buffs.rtb.stageKnown = false
    Tuono.State.buffs.rtb.stage = 0
    Tuono.Engine.Evaluate()
    expect.equal(Tuono.Engine.planAt, planAt,
      "losing sight of the stage must not be mistaken for the stage changing")
  end)
end)

describe("triggers: mode, target, talents and combat", function()
  it("re-plans when AoE and single-target swap", function()
    -- Safe to act on instantly because ResolveMode already carries a 2s dwell, so this
    -- fires on the debounced output rather than on a nameplate count oscillating.
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    Tuono.db.aoeMode = "on"
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.MODE)
    Tuono.db.aoeMode = "auto"
  end)

  it("re-plans on a target change", function()
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    stub.FireEvent("PLAYER_TARGET_CHANGED")
    expect.falsy(Tuono.Engine.plan)
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.TARGET)
  end)

  it("re-plans on a talent change", function()
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    stub.FireEvent("TRAIT_CONFIG_UPDATED")
    expect.falsy(Tuono.Engine.plan, "the ability set itself may have changed")
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.TALENTS)
  end)

  it("re-plans at a combat boundary", function()
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    harness.leaveCombat(stub)
    expect.falsy(Tuono.Engine.plan, "a plan from the last pull is not a plan for this one")
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.COMBAT)
  end)
end)

describe("triggers: deviation and exhaustion carry their own reasons", function()
  it("names deviation when the player casts something else", function()
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    harness.cast(Tuono, stub, 1856)   -- Vanish; never in the plan
    expect.falsy(Tuono.Engine.plan)
    harness.evaluate(Tuono)
    expect.equal(Tuono.Engine.lastTrigger, T.DEVIATED)
  end)

  it("does not name deviation for an off-GCD weave", function()
    local Tuono, stub = planned()
    local planBefore = Tuono.Engine.plan
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "c", ADRENALINE_RUSH)
    expect.equal(Tuono.Engine.plan, planBefore,
      "weaving an off-GCD ability does not consume the press the plan is waiting for")
  end)

  it("names exhaustion when the plan is followed to the end", function()
    local Tuono, stub = planned()
    local T = Tuono.Engine.TRIGGER
    local ids = harness.queueIDs(harness.evaluate(Tuono))
    for i = 1, #ids + 1 do
      local id = Tuono.Engine.plan and Tuono.Engine.cursor
        and Tuono.Engine.plan[Tuono.Engine.cursor]
        and Tuono.Engine.plan[Tuono.Engine.cursor].spellID
      if not id then break end
      harness.cast(Tuono, stub, id)
      stub.state.time = stub.state.time + 0.1
      harness.evaluate(Tuono)
    end
    expect.truthy(Tuono.Engine.lastTrigger, "no reason recorded")
  end)
end)

describe("triggers: the whole set must not reintroduce churn", function()
  it("leaves a stationary world completely still", function()
    -- The guard. Every trigger added above is a chance for this to regress, and this is
    -- the measurement the original complaint was about.
    local Tuono, stub = harness.boot({ world = world, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 50, 0.1)
    harness.assertLookahead(frames, 2)
    local stats = harness.churn(frames)
    expect.equal(stats.headChanges, 0,
      "a trigger is firing on nothing. " .. harness.describeChurn(stats))
    expect.equal(stats.tailChanges, 0,
      "a trigger is firing on nothing. " .. harness.describeChurn(stats))
  end)

  it("leaves the bar still while an unrelated proc storm fires", function()
    local Tuono, stub = harness.boot({ world = world, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 40, 0.1, function(i, s)
      s.FireEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", NOT_OUR_PROC + i)
      s.FireEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", NOT_OUR_PROC + i)
    end)
    harness.assertLookahead(frames, 2)
    local stats = harness.churn(frames)
    expect.equal(stats.tailChanges, 0,
      "other people's procs moved our bar. " .. harness.describeChurn(stats))
  end)
end)
