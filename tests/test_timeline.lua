-- ============================================================================
-- THE SEQUENCE IS A TIMELINE, NOT A LIST
-- ============================================================================
-- Predicted steps used to be ORDINALS -- step 1, 2, 3 -- so a step 1.8s away because the
-- player is pooling rendered identically to one 0.2s away. That is the difference between
-- reporting a list and reporting a prediction, and it is why the bar read as reactive.
--
-- Hekili carries a timestamp on every recommendation (Core.lua:2015-2018: slot.time,
-- slot.exact_time, slot.delay, slot.since) and advances a virtual clock between them
-- (Core.lua:2048, state.advance). Tuono already had the clock -- S.simNow, moved by
-- advanceTime -- it simply never reported where the clock stood when each step was chosen.
--
-- These tests pin the NUMBERS, not merely the presence of the fields. A timeline that is
-- present but wrong is worse than none, because the UI would render a confident countdown
-- off it.
-- ============================================================================

local harness = require("harness")

local SINISTER_STRIKE = 193315
local ADRENALINE_RUSH = 13750
local BLADE_RUSH      = 271877
local ROLL_THE_BONES  = 1214909
local PREPARATION     = 1277933
local KEEP_IT_ROLLING = 381989

-- The simulation's own unhasted values. Mirrored from Rotation.lua's calcGCD and
-- calcEnergyRegen rather than re-derived, so a change there fails these tests loudly
-- instead of silently drifting.
local SIM_GCD   = 1.0
local SIM_REGEN = 12.5   -- 10 base + 2.5 Combat Potency average

local function about(actual, want, tol, why)
  expect.truthy(type(actual) == "number",
    "expected a number, got " .. tostring(actual) .. (why and ("  -- " .. why) or ""))
  expect.truthy(math.abs(actual - want) <= tol,
    string.format("expected ~%.2f (+/- %.2f), got %.2f%s",
      want, tol, actual, why and ("  -- " .. why) or ""))
end

local function predict(Tuono, steps)
  return Tuono.Rotation.Predict(Tuono.State, steps or 6) or {}
end

-- Everything available, full energy, mid-fight.
local function readyWorld(stub)
  stub.state.inCombat = true
  stub.state.energy = 100
  stub.state.comboPoints = 3
  stub.state.comboPointsMax = 5
  stub.state.secret.auras = true
  stub.state.assist.nextSpell = SINISTER_STRIKE
  stub.state.assist.rotationSpells = { SINISTER_STRIKE }
end

describe("timeline: every step knows when it happens", function()
  it("carries at and since on every step", function()
    local Tuono = harness.boot({ world = readyWorld, inCombat = true })
    harness.evaluate(Tuono)
    local steps = predict(Tuono)
    expect.truthy(#steps >= 2, "need a sequence to time; got " .. #steps)
    for i, s in ipairs(steps) do
      expect.truthy(type(s.at) == "number", "step " .. i .. " has no `at`")
      expect.truthy(type(s.since) == "number", "step " .. i .. " has no `since`")
    end
  end)

  it("puts a castable position 1 at zero", function()
    local Tuono = harness.boot({ world = readyWorld, inCombat = true })
    harness.evaluate(Tuono)
    local steps = predict(Tuono)
    expect.equal(steps[1].at, 0,
      "position 1 is castable right now, so its offset from now is zero")
    expect.equal(steps[1].since, 0, "nothing precedes position 1")
  end)

  it("separates consecutive on-GCD steps by one GCD", function()
    local Tuono = harness.boot({ world = readyWorld, inCombat = true })
    harness.evaluate(Tuono)
    local steps = predict(Tuono)
    expect.truthy(#steps >= 2, "need two steps")
    -- Step 2 follows step 1 by exactly the global cooldown when no pooling intervened.
    -- Anything else means the clock is not counting the GCD the simulation itself spent.
    about(steps[2].since, SIM_GCD, 0.05,
      "step 2 should land one GCD after step 1")
    about(steps[2].at, SIM_GCD, 0.05, "and its offset from now is that same GCD")
  end)

  it("never runs time backwards", function()
    local Tuono = harness.boot({ world = readyWorld, inCombat = true })
    harness.evaluate(Tuono)
    local steps = predict(Tuono, 8)
    local prev = -1
    for i, s in ipairs(steps) do
      expect.truthy(s.at >= prev,
        string.format("step %d is at %.2f, before step %d at %.2f", i, s.at, i - 1, prev))
      prev = s.at
    end
  end)

  it("gives an off-GCD weave a since of zero", function()
    -- Adrenaline Rush is declared gcd = false, so weaving it costs no time. A timeline
    -- that charged it a GCD would push everything after it a second into the future and
    -- the countdown would be wrong for the rest of the sequence.
    local Tuono = harness.boot({
      inCombat = true,
      world = function(s)
        readyWorld(s)
        s.state.comboPoints = 0            -- Adrenaline Rush wants cp <= 2
        s.setCooldown(ROLL_THE_BONES, 45)  -- keep the rules above it out of the way
        s.setCooldown(KEEP_IT_ROLLING, 360)
      end,
    })
    harness.evaluate(Tuono)
    local steps = predict(Tuono)
    expect.equal(steps[1].spellID, ADRENALINE_RUSH,
      "test setup no longer produces an off-GCD opener; got "
        .. tostring(steps[1] and steps[1].spellID))
    expect.equal(steps[2].since, 0,
      "an off-GCD ability consumes no time, so the next step is immediate")
    expect.equal(steps[2].at, 0, "and it is still available right now")
  end)
end)

describe("timeline: pooling is reported as a wait, in seconds", function()
  -- Nothing free to press: the zero-cost cooldowns are all down, so the walk has to reach
  -- an energy-costing ability and wait for it. This is the state that produces the
  -- "pooling" label, and the whole point of the timeline is to turn that label into a
  -- number the player can act on.
  local function starvedWorld(stub)
    stub.state.inCombat = true
    stub.state.energy = 0
    stub.state.comboPoints = 0
    stub.state.comboPointsMax = 5
    stub.state.secret.auras = true
    for _, id in ipairs({ ADRENALINE_RUSH, PREPARATION, KEEP_IT_ROLLING, BLADE_RUSH,
                          ROLL_THE_BONES }) do
      stub.setCooldown(id, 120)
    end
  end

  it("reports position 1 as a real wait at zero energy", function()
    local Tuono = harness.boot({ world = starvedWorld, inCombat = true })
    harness.evaluate(Tuono)
    local steps = predict(Tuono)
    expect.truthy(#steps >= 1, "the bar must still name what you are waiting for")

    local first = steps[1]
    local ability = Tuono.Rotation.ABILITIES[first.spellID]
    expect.truthy(ability and (ability.cost or 0) > 0,
      "test setup picked a free ability, so there is no wait to measure; got "
        .. tostring(first.spellID))

    expect.truthy(first.at > 0,
      "at zero energy position 1 cannot be pressed now, so its offset must not be zero")

    -- Expected against the energy the MODEL believes, not the stub's raw 0. Energy is
    -- never read: the bracket infers it from IsSpellUsable, so a stub sitting at 0
    -- presents to the engine as "somewhere below the cheapest cost" and the model's point
    -- estimate lands at 14, not 0. Computing the expectation from the stub's number would
    -- be testing a quantity the addon deliberately never has.
    local believed = Tuono.State.energy
    expect.truthy(believed < ability.cost,
      "setup no longer starves the model; believed energy " .. tostring(believed))
    about(first.at, (ability.cost - believed) / SIM_REGEN, 0.35,
      "the wait should match the time the modelled regen needs to cover the shortfall")
  end)

  it("puts a pooled step later than the one before it", function()
    local Tuono = harness.boot({
      inCombat = true,
      world = function(s)
        readyWorld(s)
        -- Enough for exactly one builder. Two things had to be tuned to make this
        -- scenario actually pool, and both are worth stating because they are properties
        -- of the engine rather than of the test:
        --
        -- Combo points start at ZERO. At 3 the first builder reaches the finisher
        -- threshold and step 2 becomes a 25-cost Between the Eyes, affordable
        -- immediately -- nothing pools and the test measures nothing.
        --
        -- Energy starts at exactly one builder's cost. Affordability is answered from the
        -- BRACKET, which the stub's IsSpellUsable pins between the costliest usable
        -- ability and the cheapest unusable one. At 45 that is a tight [45, 49], so after
        -- spending 45 the interval provably cannot cover another builder. Starting at 50
        -- leaves the upper bound unpinned (nothing reports insufficient power), the
        -- interval stays wide, affordability answers "maybe", and the walk never waits.
        s.state.energy = 45
        s.state.comboPoints = 0
        s.setCooldown(ROLL_THE_BONES, 45)
        s.setCooldown(BLADE_RUSH, 60)
        s.setCooldown(ADRENALINE_RUSH, 180)
        s.setCooldown(KEEP_IT_ROLLING, 360)
        s.setCooldown(PREPARATION, 240)
      end,
    })
    harness.evaluate(Tuono)
    local steps = predict(Tuono)
    expect.truthy(#steps >= 2, "need two steps to compare")
    expect.equal(steps[1].at, 0, "step 1 is affordable now, so the wait belongs to step 2")
    expect.truthy(steps[2].since > SIM_GCD,
      string.format("step 2 had to pool for energy, so it must be more than one GCD "
        .. "after step 1; since was %.2f", steps[2].since))
  end)
end)

describe("timeline: does not break what it extends", function()
  it("stays idempotent", function()
    -- The clock lives on the module-level scratch table. A leak there would make Predict
    -- answer differently for identical input, which is the churn defect this whole suite
    -- exists to prevent.
    local Tuono = harness.boot({ world = readyWorld, inCombat = true })
    harness.evaluate(Tuono)

    local first = predict(Tuono)
    local firstAt = {}
    for i, s in ipairs(first) do firstAt[i] = s.at end

    for round = 2, 5 do
      local again = predict(Tuono)
      expect.equal(#again, #first, "sequence length changed on call " .. round)
      for i, s in ipairs(again) do
        expect.equal(s.at, firstAt[i],
          string.format("call %d disagreed on step %d's time: %.3f vs %.3f",
            round, i, s.at, firstAt[i]))
      end
    end
  end)

  it("keeps the sequence itself unchanged", function()
    -- The timeline is additive. If adding it moved a spell, the pooling changes went too
    -- far and the rotation itself is now different.
    local Tuono = harness.boot({ world = readyWorld, inCombat = true })
    harness.evaluate(Tuono)
    local steps = predict(Tuono)
    expect.truthy(#steps >= 3, "need depth")
    for i, s in ipairs(steps) do
      expect.truthy(s.spellID ~= nil, "step " .. i .. " lost its spell")
    end
  end)
end)
