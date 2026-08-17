-- ============================================================================
-- FORWARD SIMULATION: TIME ACTUALLY PASSES
-- ============================================================================
-- Predict advances a VIRTUAL clock -- each simulated press costs a GCD, and pooling
-- costs more -- but for a long time nothing in the simulation was judged against that
-- clock. Buffs never lapsed, and a cooldown remainder we had only GUESSED was counted
-- down like a measured one.
--
-- Both produce the same failure: a step that is confidently wrong. That is the worst
-- output this addon can produce, and it got worse when the per-GCD commitment layer
-- landed, because the bar now HOLDS such a step instead of churning past it.
-- ============================================================================

local harness = require("harness")

-- Suppress every cooldown ability so the priority walk falls through to the builder
-- chain, which is where multi-step behaviour is observable. Combo points start at 0, so
-- no finisher fires either.
local function builderChainState()
  local S = harness.fakeState()
  S.comboPoints = 0
  for _, key in ipairs({ "keepItRolling", "adrenalineRush", "bladeRush", "preparation" }) do
    S.cooldowns[key].ready = false
    S.cooldowns[key].remaining = 300
    S.cooldowns[key].remainingKnown = true
  end
  return S
end

local function predictIDs(Tuono, S, n)
  local out = {}
  for _, step in ipairs(Tuono.Rotation.Predict(S, n or 4) or {}) do
    table.insert(out, step.spellID)
  end
  return out
end

describe("rotation: buffs expire as the simulation advances", function()
  it("stops recommending a proc after its readable expiry passes", function()
    local Tuono = harness.boot({ inCombat = true })
    local pistolShot = Tuono.Profiles.Active().spells.pistolShot

    local S = builderChainState()
    S.buffs.opportunity.up = true
    S.buffs.opportunity.stacks = 3
    -- Three stacks only qualifies at 1-3 combo points, so step 1 builds and step 2 would
    -- fire Pistol Shot. Expire the proc before step 2's virtual instant.
    S.buffs.opportunity.expires = GetTime() + 0.5

    expect.notContains(predictIDs(Tuono, S), pistolShot,
      "Opportunity lapsed half a second in, but the simulation still recommended "
        .. "Pistol Shot a full GCD later -- `expires` was copied into the scratch state "
        .. "and then never compared against the advancing clock")
  end)

  it("still recommends the proc while it is genuinely up", function()
    local Tuono = harness.boot({ inCombat = true })
    local pistolShot = Tuono.Profiles.Active().spells.pistolShot

    local S = builderChainState()
    S.buffs.opportunity.up = true
    S.buffs.opportunity.stacks = 3
    S.buffs.opportunity.expires = GetTime() + 30

    -- The control for the test above. Without this, expiring everything unconditionally
    -- would also pass, and the suite would be enforcing the opposite bug.
    expect.contains(predictIDs(Tuono, S), pistolShot,
      "a proc with 30 seconds left was dropped from the lookahead")
  end)

  it("fails OPEN when the expiry timestamp is unreadable", function()
    local Tuono = harness.boot({ inCombat = true })
    local pistolShot = Tuono.Profiles.Active().spells.pistolShot

    -- Midnight hides aura payloads, so `expires` is frequently 0 or nil. That is
    -- indistinguishable from "expired long ago" under a naive comparison, and treating
    -- it as expired would silently delete every proc-gated step in real combat -- the
    -- unknown-as-no defect this codebase has now shipped six times.
    for _, unreadable in ipairs({ 0, -1 }) do
      local S = builderChainState()
      S.buffs.opportunity.up = true
      S.buffs.opportunity.stacks = 3
      S.buffs.opportunity.expires = unreadable
      expect.contains(predictIDs(Tuono, S), pistolShot,
        "an unreadable expiry (" .. tostring(unreadable) .. ") was treated as expired")
    end

    local S = builderChainState()
    S.buffs.opportunity.up = true
    S.buffs.opportunity.stacks = 3
    S.buffs.opportunity.expires = nil
    expect.contains(predictIDs(Tuono, S), pistolShot,
      "a nil expiry was treated as expired")
  end)

  it("does not throw when a buff table carries no expiry at all", function()
    local Tuono = harness.boot({ inCombat = true })
    local S = builderChainState()
    S.buffs.opportunity = { up = true, stacks = 6 }
    expect.noThrow(function() Tuono.Rotation.Predict(S, 4) end)
  end)
end)

describe("rotation: a guessed cooldown is not counted down", function()
  -- CooldownModel.Reconcile parks a cooldown it never observed being cast at a
  -- placeholder remainder and flags it via remainingKnown = false (StateTracker.lua:147).
  -- The simulator used to decrement that placeholder exactly like a measurement, so a
  -- 180-second Adrenaline Rush read "ready" two steps out -- and rendered `certain`,
  -- because readiness normally IS exactly knowable.
  it("never turns an unmeasured remainder into a ready ability", function()
    local Tuono = harness.boot({ inCombat = true })
    local adrenalineRush = Tuono.Profiles.Active().spells.adrenalineRush

    local S = builderChainState()
    S.cooldowns.adrenalineRush.ready = false
    S.cooldowns.adrenalineRush.remaining = 1      -- the placeholder, not a measurement
    S.cooldowns.adrenalineRush.remainingKnown = false

    expect.notContains(predictIDs(Tuono, S), adrenalineRush,
      "a cooldown whose duration we never measured became ready at an invented moment")
  end)

  it("still turns over a remainder we did measure", function()
    local Tuono = harness.boot({ inCombat = true })
    local adrenalineRush = Tuono.Profiles.Active().spells.adrenalineRush

    local S = builderChainState()
    S.cooldowns.adrenalineRush.ready = false
    S.cooldowns.adrenalineRush.remaining = 1
    S.cooldowns.adrenalineRush.remainingKnown = true

    -- The control. Refusing to count down anything would also pass the test above.
    expect.contains(predictIDs(Tuono, S), adrenalineRush,
      "a measured one-second cooldown never came up across four simulated GCDs")
  end)

  it("leaves position 1 answering from ground truth, not from the model", function()
    local Tuono = harness.boot({ inCombat = true })
    local adrenalineRush = Tuono.Profiles.Active().spells.adrenalineRush

    -- Readiness itself is never secret. An inferred cooldown that the client reports as
    -- READY must still be recommendable right now -- the fix must suppress an invented
    -- FUTURE turnover, not suppress a present fact.
    local S = builderChainState()
    S.comboPoints = 0
    S.cooldowns.adrenalineRush.ready = true
    S.cooldowns.adrenalineRush.remaining = 0
    S.cooldowns.adrenalineRush.remainingKnown = false

    expect.equal(predictIDs(Tuono, S)[1], adrenalineRush,
      "an inferred-but-ready cooldown was suppressed at position 1, which turns a "
        .. "duration we cannot measure into a recommendation we refuse to make")
  end)
end)

describe("rotation: the simulation stays a pure function of its input", function()
  it("is idempotent across repeated calls", function()
    local Tuono = harness.boot({ inCombat = true })
    -- The virtual clock and buff expiry add mutable per-run state to a scratch table
    -- that is deliberately reused between calls. If either leaks, Predict starts
    -- answering differently for identical input, which is churn manufactured by the
    -- engine itself.
    local first = predictIDs(Tuono, builderChainState())
    for i = 2, 5 do
      expect.listEqual(predictIDs(Tuono, builderChainState()), first,
        "call " .. i .. " disagreed with call 1 on identical input")
    end
  end)

  it("does not mutate the caller's state table", function()
    local Tuono = harness.boot({ inCombat = true })
    local S = builderChainState()
    S.buffs.opportunity.up = true
    S.buffs.opportunity.stacks = 6
    S.buffs.opportunity.expires = GetTime() + 0.1

    Tuono.Rotation.Predict(S, 4)

    expect.truthy(S.buffs.opportunity.up,
      "Predict expired a buff on the CALLER's state; the simulation must write only to "
        .. "its own scratch copy or Tuono.State decays a little on every tick")
    expect.equal(S.cooldowns.keepItRolling.remaining, 300,
      "Predict decremented a cooldown on the caller's state")
  end)
end)
