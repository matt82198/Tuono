-- ============================================================================
-- THE BAR MUST NEVER BE EMPTY
-- ============================================================================
-- From a live trace, 2026-08-17: ten UI errors fired while Tuono was recommending
-- nothing at all ("while recommending None"), across four different error types. The
-- player was pressing buttons into a blank bar.
--
-- An empty bar reads as "the addon is broken". It is strictly worse than one slightly
-- suboptimal suggestion, and it is worse than an honest "wait for this" -- both of which
-- are information. This is the same conclusion every mature rotation helper reaches: the
-- priority list ends in an unconditional filler, so the walk can always terminate in an
-- answer.
--
-- The engine already had two mechanisms that were SUPPOSED to prevent this -- a
-- last-resort rule and a pooling fallback that re-runs the list with affordability
-- suspended -- and the trace proves they still leave gaps. So the guarantee is enforced
-- at the engine level rather than trusted to the profile.
-- ============================================================================

local harness = require("harness")

local SINISTER_STRIKE = 193315

-- Genuinely nothing to press: no energy AND no free cooldown.
--
-- Zero energy alone is NOT this state, which the first version of these tests got wrong.
-- Adrenaline Rush costs nothing, so at zero energy with AR ready the correct and
-- confident answer is "press Adrenaline Rush" -- the engine was right and the test was
-- wrong. The cooldowns have to be down too before the bar has no real answer left.
local ZERO_COST_COOLDOWNS = { 13750, 1277933, 381989, 271877 }

local function starved(stub)
  stub.state.inCombat = true
  stub.state.energy = 0
  stub.state.comboPoints = 0
  stub.state.assist.nextSpell = nil
  stub.state.assist.rotationSpells = {}
  for _, id in ipairs(ZERO_COST_COOLDOWNS) do stub.setCooldown(id, 120) end
end

describe("fallback: the queue always has an answer", function()
  it("is not empty at zero energy", function()
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    local ids = harness.queueIDs(harness.evaluate(Tuono))
    expect.truthy(#ids >= 1,
      "energy-starved is the single most common way to reach an empty bar, and 'wait "
        .. "for this one' is a real answer that an empty bar refuses to give")
  end)

  it("is not empty when every cooldown is running", function()
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        starved(s)
        s.state.energy = 100
        for _, id in ipairs({ 13750, 271877, 1277933, 315341, 1214909, 51690, 13877, 381989 }) do
          s.setCooldown(id, 120)
        end
      end,
    })
    local ids = harness.queueIDs(harness.evaluate(Tuono))
    expect.truthy(#ids >= 1, "everything on cooldown must still leave the filler")
  end)

  it("marks a fallback we cannot yet afford as a wait, not a command", function()
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    local result = harness.evaluate(Tuono)
    local first = result.queue[1]
    expect.truthy(first, "queue empty")
    -- The invariant from Rotation.lua: step 1 must never ASSERT castability. Telling a
    -- player at 0 energy to press a 45-cost builder right now is a lie; telling them
    -- that is what they are waiting for is true and useful.
    expect.truthy(first.confidence == "pooling" or first.confidence == "fallback",
      "an unaffordable position 1 must render as a wait, not as a command; got "
        .. tostring(first.confidence))
  end)

  it("stays non-empty across a stretch of starvation", function()
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    local frames = harness.runTicks(Tuono, stub, 30, 0.1)
    for i, f in ipairs(frames) do
      expect.truthy(f.len >= 1, "bar went empty on frame " .. i)
    end
  end)

  it("does not go empty when the player deviates repeatedly", function()
    -- Deviation drops the plan, and a fight where the player is moving, out of range or
    -- on the wrong target produces a lot of it. Re-planning must always land somewhere.
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    for i = 1, 10 do
      stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "c" .. i, 1856)  -- never planned
      stub.state.time = stub.state.time + 0.1
      local ids = harness.queueIDs(harness.evaluate(Tuono))
      expect.truthy(#ids >= 1, "bar went empty after deviation " .. i)
    end
  end)

  it("reports the displayed head, not a head the player never saw", function()
    -- lastPos1 feeds the stall detector and the flight recorder's `rec` field. If it is
    -- computed before the plan is applied, both describe a recommendation that was never
    -- on screen -- which is how a trace comes to blame the wrong spell.
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    local ids = harness.queueIDs(harness.evaluate(Tuono))
    expect.equal(Tuono.Engine.lastPos1, ids[1],
      "lastPos1 disagrees with what was actually published")
  end)
end)
