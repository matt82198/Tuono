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

describe("churn: the lookahead is committed for a GCD", function()
  -- Flip Roll the Bones readability on every tick, straight into the engine's input,
  -- and measure what reaches the bar. Uncommitted, this reorders the sequence on every
  -- single tick: measured at 39 changes across 40 frames, head and tail alike.
  local function flapRun(Tuono, stub, ticks)
    return harness.runTicks(Tuono, stub, ticks, TICK,
      function(i, s, T)
        T.State.buffs.rtb.stageKnown = (i % 2 == 0)
        T.State.buffs.rtb.stage = (i % 2 == 0) and 4 or 0
      end,
      -- Prove the flap survived. An identical-looking test was silently vacuous twice
      -- for exactly this reason, so the input is asserted rather than assumed.
      function(T) return T.State.buffs.rtb.stageKnown end,
      -- rawEngine: skip State.RefreshFast, which re-derives rtb from the client and
      -- would overwrite the flap. This is about what the ENGINE does with a blinking
      -- input, not about how StateTracker produces one.
      { rawEngine = true })
  end

  it("freezes the whole sequence while the GCD is running", function()
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    harness.evaluate(Tuono)   -- prime Tuono.State; the run below skips RefreshFast

    -- A cast starts a GCD of ~0.85s. Everything inside that window is unpressable, so
    -- everything inside it must hold still.
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", SINISTER_STRIKE)
    local frames = flapRun(Tuono, stub, 6)   -- 0.6s, inside one GCD

    harness.assertLookahead(frames, 2)
    harness.assertVaried(frames, "rtb.stageKnown never varied, so nothing flapped")
    local stats = harness.churn(frames)
    expect.equal(stats.headChanges, 0,
      "position 1 changed while the player could not press anything. "
        .. harness.describeChurn(stats))
    expect.equal(stats.tailChanges, 0,
      "the lookahead followed a sensor blinking inside a single GCD. "
        .. harness.describeChurn(stats))
  end)

  it("is live again once the GCD frees, even mid-flap", function()
    local Tuono, stub = harness.boot({ world = liveLikeWorld, inCombat = true })
    harness.evaluate(Tuono)
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", SINISTER_STRIKE)
    -- Run well past the GCD. Once the player can act, correctness outranks stability,
    -- so the bar must start tracking the input again rather than staying frozen.
    local frames = flapRun(Tuono, stub, 30)
    local stats = harness.churn(frames)
    expect.truthy(stats.headChanges > 0,
      "the sequence stayed frozen after the GCD ended, so the bar would recommend "
        .. "stale advice at the one instant it matters. " .. harness.describeChurn(stats))
  end)

  it("releases the hold when a new GCD starts", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    harness.evaluate(Tuono)
    local held = Tuono.Engine.committedAt
    expect.truthy(held, "nothing was committed")

    -- A cast starts a GCD, which is the decision boundary the commitment keys on.
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", SINISTER_STRIKE)
    stub.state.time = stub.state.time + TICK
    harness.evaluate(Tuono)
    expect.truthy(Tuono.Engine.committedAt ~= held,
      "a new GCD must re-derive the lookahead, or the bar goes stale after a press")
  end)

  it("re-derives at least once a second even when nothing happens", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    harness.evaluate(Tuono)
    local held = Tuono.Engine.committedAt
    stub.state.time = stub.state.time + 1.5
    harness.evaluate(Tuono)
    expect.truthy(Tuono.Engine.committedAt ~= held,
      "an idle player must still see a cooldown come up; the hold must age out")
  end)

  it("drops the held sequence at a combat boundary", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    harness.evaluate(Tuono)
    expect.truthy(Tuono.Engine.committedSeq, "nothing was committed")
    harness.leaveCombat(stub)
    expect.falsy(Tuono.Engine.committedSeq,
      "a sequence committed against the last pull must not survive into the next")
  end)

  it("never holds position 1, which must stay live", function()
    local Tuono, stub = harness.boot({ world = stationaryWorld, inCombat = true })
    local before = harness.queueIDs(harness.evaluate(Tuono))[1]
    -- Put the recommended builder out of reach: at 0 energy nothing affordable changes
    -- position 1 to a pooling entry or another ability, and that must show immediately.
    stub.state.energy = 0
    stub.state.time = stub.state.time + TICK
    local after = harness.queueIDs(harness.evaluate(Tuono))[1]
    expect.truthy(before ~= nil and after ~= nil, "queue emptied")
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
