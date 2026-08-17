-- ============================================================================
-- ROLL THE BONES STAGE: MODELLED, NOT READ
-- ============================================================================
-- docs/INVERSION.md §7 lists this as the largest un-inverted quantity in the addon, and
-- §2 explains why reading it loses structurally: the aura query fails in combat, so the
-- stage blinks, and every blink legitimately reorders the recommendation. Measured on a
-- live 69-second trace: readable on 27% of ticks.
--
-- The stage is fixed at the instant of the roll, the duration is a profile constant, and
-- the roll itself is observed exactly (UNIT_SPELLCAST_SUCCEEDED carries a readable
-- spellID). So it is modellable, and these tests pin the model.
-- ============================================================================

local harness = require("harness")

local ROLL_THE_BONES = 1214909
local KEEP_IT_ROLLING = 381989
local ONE_OF_A_KIND = 1214933   -- stage 1
local JACKPOT = 1214937         -- stage 4
local RTB_DURATION = 30

-- In combat the ordinary aura query stops answering. The stub always answers, so a test
-- that wants the in-combat failure mode has to impose it. This is the whole condition
-- the model exists to survive.
local function blindAuras()
  _G.C_UnitAuras.GetPlayerAuraBySpellID = function() return nil end
  _G.C_UnitAuras.GetAuraDataByIndex = function() return nil end
end

-- Roll, let the dice land on `stageSpellID`, and let the addon identify it once.
local function rollAndIdentify(Tuono, stub, stageSpellID, name)
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-roll", ROLL_THE_BONES)
  stub.addAura(stageSpellID, name, 1, RTB_DURATION)
  stub.state.time = stub.state.time + 0.5
  Tuono.Observers.PollRtbLearner()
  return Tuono.Observers.ResolveRtbStage()
end

describe("observers: the stage is identified in combat, not only out of it", function()
  it("identifies a stage buff while in combat", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    stub.addAura(JACKPOT, "Jackpot", 1, RTB_DURATION)
    local stage, known = Tuono.Observers.ResolveRtbStage()
    expect.equal(stage, 4,
      "the ordinary aura query was gated on `not inCombat`, but PollRtbLearner runs the "
        .. "identical query ungated -- so in combat the stage went unidentified while the "
        .. "learner cleared rtbUnknownPresent, and ResolveRtbStage fell through to "
        .. "'stage 0, KNOWN' with a Jackpot up. That is the reroll bug by another route.")
    expect.truthy(known)
  end)

  it("never reports stage 0 as known while a stage aura is present", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    for _, id in ipairs({ ONE_OF_A_KIND, JACKPOT }) do
      stub.clearAuras()
      stub.addAura(id, "Stage", 1, RTB_DURATION)
      local stage, known = Tuono.Observers.ResolveRtbStage()
      expect.falsy(stage == 0 and known == true,
        "claimed 'no buff, certain' while aura " .. id .. " was up")
    end
  end)
end)

describe("observers: the stage model holds when the sensor goes dark", function()
  it("holds the stage through 10 seconds of unreadable auras", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    local stage, known = rollAndIdentify(Tuono, stub, JACKPOT, "Jackpot")
    expect.equal(stage, 4, "setup failed: the stage was never identified")
    expect.truthy(known)

    -- The sensor dies, as it does on entering real combat. The model must carry.
    blindAuras()
    for i = 1, 20 do
      stub.state.time = stub.state.time + 0.5
      local s, k = Tuono.Observers.ResolveRtbStage()
      expect.equal(s, 4, string.format("stage moved to %s at t+%.1fs", tostring(s), i * 0.5))
      expect.truthy(k, string.format("stage went unknown at t+%.1fs", i * 0.5))
    end
  end)

  it("does not reroll a Jackpot it can no longer see", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    rollAndIdentify(Tuono, stub, JACKPOT, "Jackpot")
    blindAuras()
    stub.state.time = stub.state.time + 5

    local S = harness.fakeState()
    local stage, known = Tuono.Observers.ResolveRtbStage()
    S.buffs.rtb.stage, S.buffs.rtb.stageKnown = stage, known
    local rule = harness.rule(Tuono, "priorityAoE", "Roll the Bones below stage 2")
    expect.falsy(rule.when(S, nil),
      "the single most damaging thing this addon has ever done: rerolling a Jackpot "
        .. "because the aura went unreadable")
  end)
end)

describe("observers: the model ages out rather than fabricating", function()
  it("reports stage 0 as known once the buff duration has elapsed", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    local before = select(1, rollAndIdentify(Tuono, stub, JACKPOT, "Jackpot"))
    expect.equal(before, 4, "setup failed")

    blindAuras()
    stub.state.time = stub.state.time + RTB_DURATION + 1
    local stage, known = Tuono.Observers.ResolveRtbStage()
    expect.equal(stage, 0, "a buff past its known duration is gone")
    expect.truthy(known,
      "expiry is a POSITIVE fact derived from a cast we saw and a constant we hold. "
        .. "Reporting it as unknown would stop Roll the Bones being recommended at all, "
        .. "which breaks a core ability outright.")
  end)

  it("holds right up to the expiry and not past it", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    rollAndIdentify(Tuono, stub, JACKPOT, "Jackpot")
    blindAuras()

    -- 0.5s already elapsed inside rollAndIdentify.
    stub.state.time = stub.state.time + (RTB_DURATION - 2)
    expect.equal(select(1, Tuono.Observers.ResolveRtbStage()), 4, "expired early")

    stub.state.time = stub.state.time + 4
    expect.equal(select(1, Tuono.Observers.ResolveRtbStage()), 0, "expired late")
  end)
end)

describe("observers: Keep It Rolling extends, it does not reroll", function()
  it("preserves the identified stage across a Keep It Rolling cast", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    rollAndIdentify(Tuono, stub, JACKPOT, "Jackpot")
    blindAuras()

    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-kir", KEEP_IT_ROLLING)
    local stage, known = Tuono.Observers.ResolveRtbStage()
    expect.equal(stage, 4,
      "Keep It Rolling extends the duration of the current buffs; it does not re-roll "
        .. "them. Treating it as a fresh roll discards a stage we had already identified.")
    expect.truthy(known)
  end)

  it("extends the window past the original expiry", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    rollAndIdentify(Tuono, stub, JACKPOT, "Jackpot")
    blindAuras()

    stub.state.time = stub.state.time + 20
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-kir", KEEP_IT_ROLLING)

    -- Without the extension the buff would have lapsed at t+30.
    stub.state.time = stub.state.time + 15
    expect.equal(select(1, Tuono.Observers.ResolveRtbStage()), 4,
      "Keep It Rolling did not extend the modelled window")
  end)
end)

describe("observers: unknown stays honest", function()
  it("reports unknown when a roll landed and nothing identified it", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    blindAuras()
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-roll", ROLL_THE_BONES)
    stub.state.time = stub.state.time + 0.5
    Tuono.Observers.PollRtbLearner()

    local stage, known = Tuono.Observers.ResolveRtbStage()
    expect.falsy(known,
      "a roll we watched land but could not identify is genuinely unknown; "
        .. "fabricating a stage to keep the model continuous is exactly what "
        .. "docs/INVERSION.md 6.5 forbids")
  end)

  it("a fresh observation replaces a held stage", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    rollAndIdentify(Tuono, stub, ONE_OF_A_KIND, "One of a Kind")
    expect.equal(select(1, Tuono.Observers.ResolveRtbStage()), 1, "setup failed")

    -- A second roll lands on Jackpot and this time we can see it. Observation must win
    -- over the model, never the other way round (docs/INVERSION.md 6.2).
    stub.clearAuras()
    local stage = select(1, rollAndIdentify(Tuono, stub, JACKPOT, "Jackpot"))
    expect.equal(stage, 4, "the model overwrote a live observation")
  end)

  it("reports no buff as known when nothing has ever been rolled", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    blindAuras()
    local stage, known = Tuono.Observers.ResolveRtbStage()
    expect.equal(stage, 0)
    expect.truthy(known,
      "with no roll outstanding and no buff, stage 0 must be KNOWN or Roll the Bones "
        .. "is never recommended")
  end)
end)
