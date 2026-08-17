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

describe("depth: the lookahead does not end when the simulation runs dry", function()
  -- Measured in a live trace: published depth was 1 icon on 64 of 198 ticks and 0 on 51
  -- more -- 58% of the fight showing one button or none. The cause was that the
  -- ignoreEnergy rescue which keeps step 1 from vanishing was `step == 1` only, so a
  -- later step that could not be afforded within the pooling runway simply ended the
  -- sequence. A lookahead is allowed to span several seconds of pooling; that is what
  -- makes it a lookahead.
  local function depth(Tuono)
    return #(Tuono.Rotation.Predict(Tuono.State, 4) or {})
  end

  it("returns full depth at low energy", function()
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        s.state.inCombat = true
        s.state.energy = 5
        s.state.comboPoints = 2
        s.state.secret.auras = true
      end,
    })
    harness.evaluate(Tuono)
    expect.equal(depth(Tuono), 4,
      "the sequence ended early because the simulated player ran out of energy")
  end)

  it("returns full depth with every cooldown running", function()
    -- The live condition my first offline probe missed: a fresh boot has every cooldown
    -- ready, which is not what a real fight looks like after the opener.
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        s.state.inCombat = true
        s.state.energy = 20
        s.state.comboPoints = 1
        s.state.secret.auras = true
        for _, id in ipairs({ 13750, 271877, 1277933, 315341, 1214909, 51690, 13877, 381989 }) do
          s.setCooldown(id, 90)
        end
      end,
    })
    harness.evaluate(Tuono)
    expect.equal(depth(Tuono), 4, "cooldowns running collapsed the lookahead")
  end)

  it("labels only position 1 as pooling, never a later step", function()
    -- "Pooling" means "you cannot press this yet", which is a statement about NOW. Of
    -- course you cannot press step 3 yet; saying so on every step would make the label
    -- meaningless and dim the whole bar.
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        s.state.inCombat = true
        s.state.energy = 0
        s.state.comboPoints = 0
        s.state.secret.auras = true
      end,
    })
    harness.evaluate(Tuono)
    local steps = Tuono.Rotation.Predict(Tuono.State, 4) or {}
    for i, step in ipairs(steps) do
      if i > 1 then
        expect.truthy(step.confidence ~= "pooling",
          "step " .. i .. " was labelled pooling; that label belongs to position 1 only")
      end
    end
  end)
end)

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

describe("fallback: one bad rule cannot empty the bar", function()
  it("survives a rule that throws, and counts it", function()
    -- The rescue that guarantees an answer used to wrap the whole priority walk in a
    -- SINGLE pcall, so one throwing rule aborted it and the sequence came back empty --
    -- silently, because a bare pcall never reaches Tuono.safe. A live trace showed the
    -- sequence empty on 41% of in-combat ticks with no error recorded anywhere.
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    local profile = Tuono.Profiles.Active()

    -- Poison one rule near the top of the walk.
    local poisoned = profile.priority[3]
    local original = poisoned.when
    poisoned.when = function() error("deliberate: a rule that throws") end
    Tuono.Rotation.ruleErrors = 0

    local ok = pcall(function()
      local ids = harness.queueIDs(harness.evaluate(Tuono))
      expect.truthy(#ids >= 1, "one throwing rule emptied the entire bar")
      expect.truthy((Tuono.Rotation.ruleErrors or 0) > 0,
        "the throw was swallowed without being counted, so a trace cannot tell a rule "
          .. "that throws every tick from one that simply never matches")
    end)

    poisoned.when = original
    if not ok then error("assertions failed", 0) end
  end)
end)

describe("fallback: the fallback is the APL, not a constant", function()
  -- "we aren't falling back to the optimal rotation, we fall back to nothing except
  -- sinister strike, when it should be the APL list based on the current modeled state"
  --
  -- This matters more than it looks because the model is fed by what the player casts. A
  -- bar that answers with a hardcoded filler gets that filler cast at it, which teaches
  -- the energy model nothing it did not already assume. At a training dummy -- sustained
  -- single target, nothing to interrupt the loop -- it degenerates into one builder
  -- forever, which is exactly what it did.
  it("produces a full sequence when nothing is affordable, not one icon", function()
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    local ids = harness.queueIDs(harness.evaluate(Tuono))
    expect.truthy(#ids >= 3,
      "energy-starved must still answer with the priority list, not a filler; got "
        .. #ids .. " entries")
  end)

  it("still respects cooldowns while relaxing affordability", function()
    -- Only affordability is suspended. Recommending something on cooldown would be a
    -- different and worse lie than recommending something unaffordable, because the
    -- player can wait out energy but cannot wait out a 3-minute cooldown in one GCD.
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        starved(s)
        for _, id in ipairs({ 13750, 271877, 1277933, 1214909, 51690, 381989, 315341, 13877 }) do
          s.setCooldown(id, 120)
        end
      end,
    })
    local result = harness.evaluate(Tuono)
    local onCooldown = { [13750] = true, [271877] = true, [1214909] = true,
                         [51690] = true, [315341] = true, [13877] = true }
    for i, e in ipairs(result.queue) do
      if e.isSequence and i == 1 then
        expect.falsy(onCooldown[e.spellID],
          "position 1 recommended an ability that is on cooldown")
      end
    end
  end)

  it("marks the relaxed head as a wait, never as a command", function()
    local Tuono, stub = harness.boot({ world = starved, inCombat = true })
    local first = harness.evaluate(Tuono).queue[1]
    expect.truthy(first, "queue empty")
    expect.truthy(first.confidence == "pooling" or first.confidence == "fallback",
      "an unaffordable position 1 must render as a wait; got " .. tostring(first.confidence))
  end)
end)
