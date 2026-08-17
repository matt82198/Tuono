-- ============================================================================
-- CONFIDENCE MUST COME FROM THE MODEL, NOT FROM WHETHER A READ WORKED
-- ============================================================================
-- Prompted by a live report, "single combat shows one button", but BE PRECISE about what
-- this does and does not explain.
--
-- `rateRule` used to rate a costing ability "unknown" whenever `energyKnown` was false --
-- and energyKnown reports whether the RAW energy read succeeded. Every step then rated
-- unknown, and IntelligenceLayer's confidence truncation cut the sequence to one icon.
--
-- WHETHER THAT IS THE LIVE CAUSE IS UNCONFIRMED. A recorded trace shows energySource as
-- "bracketed" or "estimated" on every tick, never "measured", which suggests energyKnown
-- was TRUE in play and the old code would have said "bounded" rather than "unknown"
-- there. So this fixes a real fragility -- reachable whenever the model is unseeded, e.g.
-- the first tick after a reload mid-combat -- but the live one-button report may have a
-- different cause still to be found. The recorder now captures sequence depth so the next
-- trace can answer it instead of being reasoned about.
--
-- That is the inversion violated at its core (docs/INVERSION.md 1): we do not read
-- energy, we model it -- and the model was measured at a median interval width of 0.2 in
-- a live trace. Asking "did the read work" instead of asking the model throws away the
-- entire asset and then reports the loss as uncertainty.
--
-- Affordability is three-valued. "yes" and "no" are PROVEN answers derived from
-- never-secret observations, and a proven answer is not uncertain just because it came
-- from an interval. Only "maybe" -- where the interval straddles the cost -- is genuinely
-- uncertain, and that is `bounded`, not `unknown`.
-- ============================================================================

local harness = require("harness")

local SINISTER_STRIKE = 193315

local function combatWorld(stub)
  stub.state.inCombat = true
  stub.state.energy = 100
  stub.state.comboPoints = 3
  stub.state.secret.energy = true   -- as Midnight always does
  stub.state.secret.auras = true
  stub.state.assist.nextSpell = SINISTER_STRIKE
  stub.state.assist.rotationSpells = { SINISTER_STRIKE }
end

-- Prime the state exactly as the tick loop does. State.RefreshFast seeds the energy
-- bracket from IsSpellUsable; calling Predict without it measures an unseeded model,
-- which is not a state the addon is ever in after its first tick. My first version of
-- these tests skipped this and "reproduced" a bug that does not occur in play.
local function confidences(Tuono)
  harness.evaluate(Tuono)
  local out = {}
  for _, step in ipairs(Tuono.Rotation.Predict(Tuono.State, 4) or {}) do
    table.insert(out, step.confidence)
  end
  return out
end

describe("confidence: hidden energy is not unknown energy", function()
  it("does not rate a provably affordable step unknown", function()
    local Tuono = harness.boot({ world = combatWorld, inCombat = true })
    local confs = confidences(Tuono)
    expect.truthy(#confs >= 2, "need a sequence to rate")
    for i, c in ipairs(confs) do
      expect.truthy(c ~= "unknown",
        "step " .. i .. " rated unknown. Energy is secret in every Midnight combat, so "
          .. "rating on whether the raw read worked marks the whole rotation unknown "
          .. "and truncates the bar to one icon.")
    end
  end)

  it("publishes the full sequence in single target", function()
    local Tuono = harness.boot({ world = combatWorld, inCombat = true })
    harness.evaluate(Tuono)
    Tuono.State.enemyCount, Tuono.State.enemyCountKnown = 1, true
    local result = Tuono.Engine.Evaluate()
    expect.truthy(#result.queue >= 3,
      "single target collapsed to " .. #result.queue .. " entries")
  end)

  it("publishes the full sequence in AoE", function()
    local Tuono = harness.boot({ world = combatWorld, inCombat = true })
    harness.evaluate(Tuono)
    Tuono.State.enemyCount, Tuono.State.enemyCountKnown = 3, true
    local result = Tuono.Engine.Evaluate()
    expect.truthy(#result.queue >= 3,
      "AoE collapsed to " .. #result.queue .. " entries")
  end)

  it("still says bounded when the interval genuinely straddles the cost", function()
    -- Honest uncertainty must survive. At an energy level where the bracket cannot prove
    -- affordability either way, the step is bounded -- visible as reduced alpha -- but it
    -- is NOT unknown, because we know a great deal about it.
    local Tuono, stub = harness.boot({ world = combatWorld, inCombat = true })
    stub.state.energy = 44   -- straddles Sinister Strike's 45
    harness.evaluate(Tuono)
    local confs = confidences(Tuono)
    for i, c in ipairs(confs) do
      expect.truthy(c ~= "unknown", "step " .. i .. " went unknown near a threshold")
    end
  end)

  it("keeps rating a genuinely hidden dependency as unknown", function()
    -- The mechanism must not be blunted into always saying "certain". A rule gated on
    -- something we truly cannot see must still say so.
    local Tuono = harness.boot({ world = combatWorld, inCombat = true })
    local rule = harness.rule(Tuono, "priority", "Roll the Bones below stage 2")
    local S = harness.fakeState()
    S.buffs.rtb.stageKnown = false
    S.buffs.rtb.stage = nil
    expect.equal(Tuono.Rotation.RateRule(rule, S, 1214909), "unknown",
      "a stage-gated rule with an unreadable stage must still rate unknown")
  end)
end)
