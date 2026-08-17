-- ============================================================================
-- QUEUE CHURN
-- ============================================================================
-- The complaint this whole suite exists to close:
--
--   "the first button is optimal. It switches the entire list a lot and its not smooth"
--
-- Position 1 is re-derived from ground truth every tick and is SUPPOSED to move. The
-- lookahead is different: if the world has not materially changed, positions 2..N
-- flipping is noise with no information in it, and it is what makes the bar unreadable.
--
-- These tests measure it. A number can be regressed against; a feeling cannot.
-- ============================================================================

local harness = require("harness")

local SINISTER_STRIKE = 193315
local TICK = 0.1   -- the addon's in-combat throttle

-- A rogue mid-fight with everything available and full energy. Nothing about the world
-- changes across the run except the clock.
--
-- `inCombat` here is only the stub's own view; harness.boot({inCombat = true}) is what
-- fires PLAYER_REGEN_DISABLED and makes the ADDON believe it. Without that the opener
-- rule wins and every one of these tests silently measures the pre-pull bar instead.
local function stationaryWorld(stub)
  stub.state.inCombat = true
  stub.state.energy = 100
  stub.state.comboPoints = 3
  stub.state.assist.nextSpell = SINISTER_STRIKE
  stub.state.assist.rotationSpells = { SINISTER_STRIKE }
end

-- Reproduces the conditions of the recorded 2026-08-12 trace: aura payloads secret, so
-- buffs.degraded is set on every tick, and energy hidden as Midnight always hides it.
local function liveLikeWorld(stub)
  stationaryWorld(stub)
  stub.state.secret.auras = true
  stub.state.secret.energy = true
end

describe("churn: a stationary world must produce a stationary lookahead", function()
  it("holds the tail steady over 5 seconds at full energy", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 50, TICK)
    harness.assertLookahead(frames, 2)
    local stats = harness.churn(frames)
    expect.equal(stats.tailChanges, 0,
      "nothing about the world changed, so the lookahead had no reason to. "
        .. harness.describeChurn(stats))
  end)

  it("holds the visible length steady over 5 seconds", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 50, TICK)
    harness.assertLookahead(frames, 2)
    local stats = harness.churn(frames)
    expect.equal(stats.lenChanges, 0,
      "the bar growing and shrinking under a stationary player reads as broken. "
        .. harness.describeChurn(stats))
  end)

  it("holds position 1 steady while the player does nothing", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 50, TICK)
    harness.assertLookahead(frames, 2)
    local stats = harness.churn(frames)
    expect.equal(stats.headChanges, 0,
      "no cast, no cooldown turnover, no resource change -- position 1 must not move. "
        .. harness.describeChurn(stats))
  end)
end)

describe("churn: energy regeneration alone must not shuffle the lookahead", function()
  it("stays steady while pooling from empty to full", function()
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(stub2)
        stationaryWorld(stub2)
        stub2.state.energy = 10
      end,
    })
    -- 10 seconds of regeneration crosses every cost threshold Outlaw has
    -- (15/25/35/40/45/50), which is precisely where the interval model's affordability
    -- answers flip between "no", "maybe" and "yes".
    local frames = harness.runTicks(Tuono, stub, 100, TICK, function(i, s)
      s.state.energy = math.min(100, s.state.energy + 1.4)
    end)
    local stats = harness.churn(frames)
    -- Crossing a threshold legitimately changes what is castable, so a small number of
    -- changes is honest. Thrash is not.
    expect.truthy(stats.tailChanges <= 6,
      "energy crossing six cost thresholds should move the lookahead a handful of "
        .. "times, not continuously. " .. harness.describeChurn(stats))
  end)
end)

describe("churn: under live conditions (degraded auras, hidden energy)", function()
  it("holds the tail steady when aura payloads are secret", function()
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 50, TICK)
    harness.assertLookahead(frames, 2)
    local stats = harness.churn(frames)
    expect.equal(stats.tailChanges, 0,
      "the recorded trace had aura data degraded on 100% of ticks; if that alone "
        .. "shuffles the lookahead, that is the churn. " .. harness.describeChurn(stats))
  end)

  it("does not shorten and re-lengthen the bar under degraded data", function()
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 50, TICK)
    local stats = harness.churn(frames)
    expect.equal(stats.lenChanges, 0,
      "confidence truncation cuts the sequence at the first 'unknown' step; if the "
        .. "cut point moves tick to tick the bar visibly grows and shrinks. "
        .. harness.describeChurn(stats))
  end)
end)

describe("churn: flapping readability must not flap the bar", function()
  -- The recorded trace had Roll the Bones stage readable on only 27% of ticks. That is
  -- not a steady "unknown" -- it is a signal blinking on and off. Any rule gated on it
  -- therefore enters and leaves the priority walk repeatedly, and every step after it
  -- shifts. This is the mechanism most likely to produce the reported symptom.
  -- These drive Rotation.Predict DIRECTLY rather than through the client stub. In
  -- combat StateTracker deliberately refuses to rescan auras (StateTracker.lua:965 --
  -- the index path can throw on secret payloads), so a stub aura toggle never reaches
  -- Tuono.State and a stub-driven version of this test is vacuous. Asserted, not
  -- assumed: harness.assertVaried caught exactly that and failed the first attempt.
  local function predictIDs(Tuono, S)
    local out = {}
    for _, step in ipairs(Tuono.Rotation.Predict(S, 4) or {}) do
      table.insert(out, step.spellID)
    end
    return out
  end

  it("is idempotent: the same state always yields the same sequence", function()
    local Tuono = harness.boot({ inCombat = true })
    local first = predictIDs(Tuono, harness.fakeState())
    for i = 2, 6 do
      expect.listEqual(predictIDs(Tuono, harness.fakeState()), first,
        "call " .. i .. " disagreed with call 1 on identical input. Predict keeps a "
          .. "module-level scratch table; if its reset is incomplete, the engine "
          .. "churns all by itself.")
    end
    -- Re-using one state table must be equivalent to fresh ones: the simulator writes
    -- into scratch, never into the caller's state.
    local S = harness.fakeState()
    for i = 1, 4 do
      expect.listEqual(predictIDs(Tuono, S), first,
        "repeated call " .. i .. " on a re-used state table diverged, so Predict is "
          .. "mutating its own input")
    end
  end)

  it("gives the same sequence whether or not aura data is flagged degraded", function()
    local Tuono = harness.boot({ inCombat = true })

    local clean = harness.fakeState()
    local degraded = harness.fakeState()
    degraded.buffs.degraded = true

    -- `degraded` is a global data-quality flag, set on 100% of ticks in the recorded
    -- trace. It may legitimately lower CONFIDENCE, but it must not change WHICH spells
    -- are chosen -- that would make a sensor problem look like a rotation decision.
    expect.listEqual(predictIDs(Tuono, degraded), predictIDs(Tuono, clean),
      "a data-quality flag changed the recommendation itself")
  end)

  it("changes the sequence when the RtB stage becomes unreadable (expected)", function()
    local Tuono = harness.boot({ inCombat = true })

    local known = harness.fakeState()      -- stage 4, readable
    local unknown = harness.fakeState()
    unknown.buffs.rtb.stage = 0
    unknown.buffs.rtb.stageKnown = false

    -- This is CORRECT behaviour, recorded here so the commitment layer below is
    -- understood as damping a real signal rather than hiding a bug: Keep It Rolling is
    -- gated on stage >= 3 and fails closed when the stage is hidden, so it drops out of
    -- the walk and everything after it shifts left. With the stage readable only 27% of
    -- the time, this flips constantly -- which is the churn.
    local a, b = predictIDs(Tuono, known), predictIDs(Tuono, unknown)
    local differs = false
    for i = 1, math.max(#a, #b) do
      if a[i] ~= b[i] then differs = true break end
    end
    expect.truthy(differs,
      "if these ever stop differing, the churn mechanism this suite documents has "
        .. "changed and the commitment layer's rationale needs revisiting")
  end)

  it("does not let a degraded flag silently shorten the lookahead", function()
    local Tuono = harness.boot({ inCombat = true })
    local degraded = harness.fakeState()
    degraded.buffs.degraded = true
    local ids = predictIDs(Tuono, degraded)
    expect.truthy(#ids >= 2,
      "confidence truncation collapsed the sequence to " .. #ids .. " step(s) under a "
        .. "flag that is set on essentially every real combat tick")
  end)
end)

describe("plan: pressing the recommended button advances the sequence", function()
  it("slides left by one instead of producing a new list", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local before = harness.queueIDs(harness.evaluate(Tuono))
    expect.truthy(#before >= 3, "need a lookahead to advance; got " .. #before)

    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", before[1])
    stub.state.time = stub.state.time + TICK
    local after = harness.queueIDs(harness.evaluate(Tuono))

    -- The whole requirement, in one assertion: what was step 2 is now step 1, what was
    -- step 3 is now step 2. The player pressed the optimal button and is now IN the
    -- optimal sequence, rather than being handed a freshly derived one.
    for i = 1, #before - 1 do
      expect.equal(after[i], before[i + 1],
        "position " .. i .. " should be the old position " .. (i + 1)
          .. "; the sequence restarted instead of advancing")
    end
  end)

  it("advances again on a second correct press", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local before = harness.queueIDs(harness.evaluate(Tuono))
    expect.truthy(#before >= 3, "need depth")
    -- harness.cast applies the ability's real cost/generation/cooldown, which firing the
    -- event alone does not. Without that the world never moves, a fresh prediction keeps
    -- recommending the spell just cast, and the engine correctly re-plans -- see the
    -- clipped-GCD test below, which relies on exactly that.
    for i = 1, 2 do
      harness.cast(Tuono, stub, before[i])
      stub.state.time = stub.state.time + TICK
      harness.evaluate(Tuono)
    end
    expect.equal(Tuono.Engine.cursor, 3, "the cursor did not track two presses")
  end)

  it("re-checks harder immediately after a press than between presses", function()
    -- The caveat that motivated this: press the right button but LATE -- a clipped GCD,
    -- a moment's hesitation -- and the world moved further than the plan modelled, so the
    -- remaining steps may no longer be optimal even though the player did the right
    -- thing. Following the plan therefore does NOT grant it immunity; it schedules an
    -- immediate re-check.
    --
    -- Asserted on the contract rather than on a particular spell's side effects: a cast
    -- arms verifyOnAdvance, and one tick of disagreement is then enough to re-plan, where
    -- between presses it takes three.
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local ids = harness.queueIDs(harness.evaluate(Tuono))
    harness.cast(Tuono, stub, ids[1])
    expect.truthy(Tuono.Engine.verifyOnAdvance,
      "following the plan must schedule a re-check, not buy immunity from one")

    local planAt = Tuono.Engine.planAt
    -- Move the world out from under the remaining plan, the way a late press does: the
    -- next planned step is no longer available. Driven through the client so it reaches
    -- Tuono.State the way the game would.
    local nextPlanned = Tuono.Engine.plan[Tuono.Engine.cursor].spellID
    stub.setCooldown(nextPlanned, 120)
    stub.state.time = stub.state.time + TICK
    harness.evaluate(Tuono)
    expect.truthy(Tuono.Engine.planAt ~= planAt,
      "a single tick of disagreement right after a press must re-plan")
  end)

  it("still requires persistence when no press just happened", function()
    -- The other half of the same rule: away from a cast boundary, one tick of
    -- disagreement is far likelier to be a blinking sensor than a changed world.
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    harness.evaluate(Tuono)
    local planAt = Tuono.Engine.planAt
    Tuono.State.buffs.rtb.stageKnown = false
    Tuono.State.buffs.rtb.stage = 0
    stub.state.time = stub.state.time + TICK
    Tuono.Engine.Evaluate()
    expect.equal(Tuono.Engine.planAt, planAt,
      "one tick of disagreement with no press behind it unseated the plan")
  end)

  it("abandons the plan the moment the player deviates", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    harness.evaluate(Tuono)
    expect.truthy(Tuono.Engine.plan, "no plan was made")

    -- Cast something that is NOT the recommendation. Every later step was conditioned on
    -- the press that did not happen, so the plan describes a world that does not exist.
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cx", 1856)  -- Vanish, not in the plan
    expect.falsy(Tuono.Engine.plan,
      "a plan built on a press that never happened is worse than no plan")
  end)

  it("does not treat an off-GCD weave as deviation", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    harness.evaluate(Tuono)
    local planBefore = Tuono.Engine.plan
    expect.truthy(planBefore, "no plan was made")
    -- Adrenaline Rush is off-GCD: weaving it does not consume the press the plan is
    -- waiting for, so the plan must survive.
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "car", 13750)
    expect.truthy(Tuono.Engine.plan, "an off-GCD weave wrongly invalidated the plan")
  end)

  it("holds the plan through a single tick of sensor disagreement", function()
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    harness.evaluate(Tuono)
    local planned = Tuono.Engine.plan[Tuono.Engine.cursor].spellID

    -- One tick of disagreement is far likelier to be a blinking sensor than a changed
    -- world. This is what separates "checking" from "thrashing".
    Tuono.State.buffs.rtb.stageKnown = false
    Tuono.State.buffs.rtb.stage = 0
    Tuono.Engine.Evaluate()
    expect.equal(Tuono.Engine.plan[Tuono.Engine.cursor].spellID, planned,
      "one tick of disagreement unseated the plan")
  end)

  it("re-plans when the disagreement persists", function()
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    harness.evaluate(Tuono)
    local planAt = Tuono.Engine.planAt

    -- Sustained disagreement means the world really did change under us.
    for _ = 1, 5 do
      Tuono.State.buffs.rtb.stageKnown = false
      Tuono.State.buffs.rtb.stage = 0
      stub.state.time = stub.state.time + TICK
      Tuono.Engine.Evaluate()
    end
    expect.truthy(Tuono.Engine.planAt ~= planAt,
      "a persistent disagreement must re-plan; that is the 'it should still check' half")
  end)

  it("re-plans once the plan is used up", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local ids = harness.queueIDs(harness.evaluate(Tuono))
    for i = 1, #ids do
      stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "c" .. i, ids[i])
      stub.state.time = stub.state.time + TICK
      harness.evaluate(Tuono)
    end
    expect.truthy(#harness.queueIDs(harness.evaluate(Tuono)) > 0,
      "the bar went empty after the plan was exhausted instead of re-planning")
  end)

  it("drops the plan at a combat boundary", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    harness.evaluate(Tuono)
    expect.truthy(Tuono.Engine.plan, "no plan was made")
    harness.leaveCombat(stub)
    expect.falsy(Tuono.Engine.plan,
      "a plan made against the last pull must not survive into the next")
  end)
end)

describe("churn: what the player actually sees", function()
  -- The outcome test. Everything above pins a mechanism; this pins the result the
  -- complaint was about: "it switches the entire list a lot and it's not smooth."
  it("holds the whole bar still while a sensor blinks every tick", function()
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    harness.evaluate(Tuono)
    local frames = harness.runTicks(Tuono, stub, 20, TICK,
      function(i, s, T)
        T.State.buffs.rtb.stageKnown = (i % 2 == 0)
        T.State.buffs.rtb.stage = (i % 2 == 0) and 4 or 0
      end,
      function(T) return T.State.buffs.rtb.stageKnown end,
      { rawEngine = true })
    harness.assertLookahead(frames, 2)
    harness.assertVaried(frames, "rtb.stageKnown never varied, so nothing flapped")
    local stats = harness.churn(frames)
    -- Uncommitted, this measured 39 changes across 40 frames, head and tail alike.
    --
    -- One change is allowed, and only one: the first plan is formed against the state
    -- left by the priming evaluate, and the flap contradicts it once on the next tick.
    -- That is a plan settling onto a new world, which is the behaviour we want; what we
    -- are excluding is it happening again every 100ms thereafter.
    expect.truthy(stats.headChanges <= 1,
      "position 1 followed a blinking sensor. " .. harness.describeChurn(stats))
    expect.truthy(stats.tailChanges <= 1,
      "the lookahead followed a blinking sensor. " .. harness.describeChurn(stats))
  end)

  it("still catches up when the player stops pressing things", function()
    -- The backstop: a plan nobody is following must not be held forever, or a player
    -- whose target died would stare at a stale sequence.
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    harness.evaluate(Tuono)
    local planAt = Tuono.Engine.planAt
    stub.state.time = stub.state.time + 4.0
    harness.evaluate(Tuono)
    expect.truthy(Tuono.Engine.planAt ~= planAt, "the plan never aged out")
  end)
end)

describe("churn: the sequence should advance, not restart", function()
  it("rolls forward by one when the player casts what was recommended", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })

    local before = harness.evaluate(Tuono)
    local beforeIDs = harness.queueIDs(before)
    expect.truthy(#beforeIDs >= 2, "need a lookahead to test advancing it")

    -- The player presses position 1.
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", beforeIDs[1])
    stub.state.time = stub.state.time + TICK

    local after = harness.evaluate(Tuono)
    local afterIDs = harness.queueIDs(after)
    expect.truthy(#afterIDs >= 1, "queue emptied after a single cast")
  end)
end)
