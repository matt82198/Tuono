-- ============================================================================
-- COOLDOWN RECONSTRUCTION
-- ============================================================================
-- Defect C1: an unobserved cooldown was re-armed with a one-second placeholder and then
-- handed out as if it were a measurement. Display refused to draw the number (correctly),
-- but the SIMULATOR reads `remaining` straight off the state and decrements one GCD per
-- step -- so a 180-second Adrenaline Rush we never saw cast reported "ready" at step 2 of
-- the lookahead, rendered solid. Confidently wrong is the worst thing this addon can do.
--
-- The rule these tests enforce: the model may report a remainder it DERIVED from an
-- observation, and must report "unknown" for one it invented.
-- ============================================================================

local harness = require("harness")

local ADRENALINE_RUSH = 13750    -- cd 180
local BLADE_RUSH      = 271877   -- cd 60
local DISPATCH        = 2098     -- finisher, cpSpend = -1

describe("cooldown: an invented remainder is not a measurement", function()
  it("reports an unobserved cooldown's remainder as unknown", function()
    local Tuono = harness.boot({ inCombat = true })
    local CM = Tuono.CooldownModel

    -- Ground truth says "not ready", but we never saw the cast, so we have no idea how
    -- long is left. That is the honest answer and it must survive to the caller.
    CM.Reconcile("adrenalineRush", false)
    local rem, known = CM.Predict("adrenalineRush")
    expect.falsy(known,
      "Predict claimed to know the remainder of a cooldown it never observed; "
        .. "StateTracker.lua:141 only trusts `remaining` when this says known")
    expect.truthy(CM.IsInferred("adrenalineRush"),
      "the entry should still be marked inferred so callers can tell why")
  end)

  it("does not re-arm the placeholder on every tick", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    local CM = Tuono.CooldownModel

    CM.Reconcile("adrenalineRush", false)
    -- Well past the old one-second placeholder. The old code re-armed here, which is why
    -- the reported remainder sawtoothed between 1 and 0 forever instead of decaying.
    stub.state.time = stub.state.time + 5
    CM.Reconcile("adrenalineRush", false)

    local _, known = CM.Predict("adrenalineRush")
    expect.falsy(known, "the placeholder came back as a knowable remainder after 5s")
  end)

  it("still reports a real remainder for a cooldown it actually saw start", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    local CM = Tuono.CooldownModel

    CM.OnCast(ADRENALINE_RUSH)
    stub.state.time = stub.state.time + 10

    local rem, known = CM.Predict("adrenalineRush")
    expect.truthy(known, "an observed cast must still produce a knowable countdown")
    expect.falsy(CM.IsInferred("adrenalineRush"), "an observed cast is not inferred")
    -- 180s base, 10s elapsed. Loose bound: Restless Blades may have shortened it.
    expect.truthy(rem and rem > 100 and rem <= 170,
      "expected ~170s remaining, got " .. tostring(rem))
  end)

  it("clears an inferred cooldown when ground truth says it is ready", function()
    local Tuono = harness.boot({ inCombat = true })
    local CM = Tuono.CooldownModel

    CM.Reconcile("adrenalineRush", false)
    CM.Reconcile("adrenalineRush", true)

    expect.falsy(CM.IsInferred("adrenalineRush"), "readiness must retire the inference")
    local rem, known = CM.Predict("adrenalineRush")
    expect.falsy(known, "a cleared cooldown has no remainder to predict")
  end)

  it("leaves an unreadable readiness alone rather than inventing state", function()
    local Tuono = harness.boot({ inCombat = true })
    local CM = Tuono.CooldownModel

    -- nil means the never-secret boolean itself was unavailable. Unknown is never "no":
    -- it must not create an inferred cooldown out of nothing.
    CM.Reconcile("adrenalineRush", nil)
    expect.falsy(CM.IsInferred("adrenalineRush"),
      "a missing readiness reading was treated as evidence of a running cooldown")
  end)
end)

describe("cooldown: the simulator must not resurrect an unknown cooldown", function()
  -- This is the payload of C1. StateTracker now emits `remaining = 0` for a cooldown
  -- whose remainder is unknown (it falls through to its own default row once Predict
  -- reports unknown), and Rotation.Predict only decrements entries with remaining > 0.
  -- So an unknown cooldown stays not-ready for the whole lookahead instead of coming
  -- up two steps in. That coupling is the reason Predict must never hand out an
  -- invented number.
  it("never recommends an ability whose cooldown is not ready and not measurable", function()
    local Tuono = harness.boot({ inCombat = true })

    local S = harness.fakeState()
    S.cooldowns.adrenalineRush =
      { known = true, ready = false, remaining = 0, remainingKnown = false }
    S.comboPoints = 0   -- the low-CP condition Adrenaline Rush is gated on

    local ids = {}
    for _, step in ipairs(Tuono.Rotation.Predict(S, 4) or {}) do
      table.insert(ids, step.spellID)
    end
    expect.truthy(#ids > 0, "vacuous: the lookahead was empty")
    expect.notContains(ids, ADRENALINE_RUSH,
      "a cooldown we know is running, with an unknown remainder, became ready inside "
        .. "the simulation")
  end)

  it("still recommends it once ground truth says it is ready", function()
    local Tuono = harness.boot({ inCombat = true })

    local S = harness.fakeState()
    S.cooldowns.adrenalineRush =
      { known = true, ready = true, remaining = 0, remainingKnown = false }
    S.comboPoints = 0

    local ids = {}
    for _, step in ipairs(Tuono.Rotation.Predict(S, 4) or {}) do
      table.insert(ids, step.spellID)
    end
    -- The guard above must not become blanket suppression: an unmeasurable countdown is
    -- not a reason to hide an ability the client says is usable right now.
    expect.contains(ids, ADRENALINE_RUSH,
      "declining to guess a remainder must not suppress a ready cooldown")
  end)
end)

describe("cooldown: Restless Blades", function()
  it("applies combo-point CDR from the tick-captured combo points", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    local CM = Tuono.CooldownModel

    CM.OnCast(BLADE_RUSH)
    local before = select(1, CM.Predict("bladeRush"))
    expect.truthy(before and before > 55, "Blade Rush did not start a 60s cooldown")

    -- UNIT_SPELLCAST_SUCCEEDED fires AFTER the finisher has consumed the points, so the
    -- model has to use the PREVIOUS tick's value. NoteTick is what captures it; if it
    -- were never called from the tick loop, prevCP would be 0 and CDR would never apply.
    Tuono.State.comboPoints = 6
    Tuono.State.comboPointsKnown = true
    CM.NoteTick()

    CM.OnCast(DISPATCH)

    local after = select(1, CM.Predict("bladeRush"))
    expect.truthy(after and (before - after) >= 5.5,
      "expected ~6s of Restless Blades CDR from 6 combo points, got "
        .. tostring(before and after and (before - after)))
  end)

  it("does not claim the boosted rate on an unreadable Roll the Bones stage", function()
    local Tuono = harness.boot({ inCombat = true })
    local CM = Tuono.CooldownModel

    CM.OnCast(BLADE_RUSH)
    local before = select(1, CM.Predict("bladeRush"))

    Tuono.State.comboPoints = 6
    Tuono.State.comboPointsKnown = true
    Tuono.State.buffs.rtb.stage = 4
    Tuono.State.buffs.rtb.stageKnown = false   -- Triple Threat may or may not be up
    CM.NoteTick()
    CM.OnCast(DISPATCH)

    local after = select(1, CM.Predict("bladeRush"))
    local cdr = before - after
    -- 1.0/CP, not 1.3/CP. Assuming the better rate on a stage we cannot read would make
    -- every cooldown look shorter than it is.
    expect.truthy(cdr <= 6.5,
      "claimed the Triple Threat rate on an unreadable stage: " .. tostring(cdr) .. "s")
  end)
end)
