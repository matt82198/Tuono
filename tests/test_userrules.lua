-- ============================================================================
-- USER-EDITABLE RULES
-- ============================================================================
-- Two defects live here, and both are worse than they look because compiled user rows
-- REPLACE the profile's hand-written closures rather than sitting alongside them:
--
--   C2  the compiled rtbStage condition dropped the stageKnown guard, so opening the
--       editor reinstated the "reroll a Jackpot every 45 seconds" bug in full.
--   C3  GetRows materialised on READ, so merely looking at the rules forked a user off
--       the built-in profile forever and silently cut them off from every future fix.
-- ============================================================================

local harness = require("harness")

local PROFILE_ID = "outlaw-rogue"

local function bootProfile()
  -- SavedVariables are a GLOBAL. harness.load() re-runs the addon but nothing clears
  -- _G.TuonoDB, so Tuono.db is literally the same table across boots and stored rules
  -- leak from one test into the next -- which showed up here as IsCustomised already
  -- true before a single test had read anything. Cleared locally; the leak itself is in
  -- the harness and is reported rather than fixed from this file.
  _G.TuonoDB = nil
  local Tuono = harness.boot()
  return Tuono, Tuono.Profiles.Active()
end

-- The stored row for a named built-in rule, materialising the list first.
local function storedRow(Tuono, profile, kind, name)
  for _, row in ipairs(Tuono.UserRules.GetRows(profile, kind)) do
    if row.name == name then return row end
  end
  return nil
end

-- Compile one stored row and return its predicate, as the engine would.
local function compiledWhen(Tuono, profile, row)
  local rule = Tuono.UserRules.Compile(row, profile)
  return rule and rule.when or nil
end

-- ============================================================================
-- C2 -- the compiled conditions must carry the same guards as the built-ins
-- ============================================================================

describe("userrules: rtbStage fails closed on an unreadable stage", function()
  it("does not reroll when the stage cannot be read", function()
    local Tuono, profile = bootProfile()
    local row = storedRow(Tuono, profile, "single", "Roll the Bones below stage 2")
    expect.truthy(row, "built-in reroll rule did not seed into editable rows")

    local when = compiledWhen(Tuono, profile, row)
    expect.truthy(when, "row failed to compile")

    local S = harness.fakeState()
    S.buffs.rtb.stage = 0
    S.buffs.rtb.stageKnown = false

    expect.falsy(when(S, nil),
      "stage reads 0 both when there is no buff and when we cannot see one. The "
      .. "built-in closure guards this; the compiled copy must too, or opening the "
      .. "editor reinstates the reroll-a-Jackpot bug.")
  end)

  it("agrees with the built-in closure on the same state", function()
    local Tuono, profile = bootProfile()
    for _, kind in ipairs({ "single", "aoe" }) do
      local listName = (kind == "aoe") and "priorityAoE" or "priority"
      local builtin = harness.rule(Tuono, listName, "Roll the Bones below stage 2")
      local row = storedRow(Tuono, profile, kind, "Roll the Bones below stage 2")
      local when = compiledWhen(Tuono, profile, row)
      expect.truthy(builtin and when, kind .. ": missing rule or row")

      for _, case in ipairs({
        { stage = 0, known = false, why = "unreadable" },
        { stage = 1, known = true, why = "readable stage 1" },
        { stage = 4, known = true, why = "readable Jackpot" },
      }) do
        local S = harness.fakeState()
        S.buffs.rtb.stage = case.stage
        S.buffs.rtb.stageKnown = case.known
        local a = builtin.when(S, nil) and true or false
        local b = when(S, nil) and true or false
        expect.equal(b, a,
          kind .. ", " .. case.why .. ": compiled row disagreed with the built-in "
          .. "closure it was seeded from")
      end
    end
  end)

  it("does not throw when the stage is nil", function()
    local Tuono, profile = bootProfile()
    local row = storedRow(Tuono, profile, "single", "Roll the Bones below stage 2")
    local when = compiledWhen(Tuono, profile, row)
    local S = harness.fakeState()
    S.buffs.rtb.stage = nil
    S.buffs.rtb.stageKnown = false
    expect.noThrow(function() when(S, nil) end, "compared a nil stage with <")
  end)

  it("still fires on a genuinely bad, readable roll", function()
    local Tuono, profile = bootProfile()
    local row = storedRow(Tuono, profile, "single", "Roll the Bones below stage 2")
    local when = compiledWhen(Tuono, profile, row)
    local S = harness.fakeState()
    S.buffs.rtb.stage = 1
    S.buffs.rtb.stageKnown = true
    expect.truthy(when(S, nil), "refused to reroll a known stage 1")
  end)

  it("fails closed for an at-least claim too, not just a reroll", function()
    -- Keep It Rolling is gated on stage >= 3 and also spends a cooldown, so an
    -- unreadable stage must not authorise it either.
    local Tuono, profile = bootProfile()
    local row = {
      spellKey = "keepItRolling",
      enabled = true,
      conditions = { { type = "rtbStage", op = ">=", value = 3 } },
    }
    local when = compiledWhen(Tuono, profile, row)
    local S = harness.fakeState()
    S.buffs.rtb.stage = 0
    S.buffs.rtb.stageKnown = false
    expect.falsy(when(S, nil), "authorised a six-minute cooldown on a stage we cannot see")
  end)
end)

describe("userrules: enemyCount follows the same asymmetry as combo points", function()
  -- cpAtLeast fails and cpAtMost passes when the value is hidden, for a documented
  -- reason: an unprovable lower bound must not authorise a spend, but an unprovable
  -- upper bound must not suppress the whole cooldown layer. An unreadable enemy count
  -- had been failing BOTH directions, so every single-target-gated user rule went dead.
  local function whenFor(Tuono, profile, op, value)
    return compiledWhen(Tuono, profile, {
      spellKey = "sinisterStrike",
      enabled = true,
      conditions = { { type = "enemyCount", op = op, value = value } },
    })
  end

  it("passes an at-most claim when the count is unreadable", function()
    local Tuono, profile = bootProfile()
    local S = harness.fakeState({ enemyCount = nil, enemyCountKnown = false })
    expect.truthy(whenFor(Tuono, profile, "<=", 1)(S, nil),
      "an unprovable upper bound must not suppress a single-target rule")
  end)

  it("fails an at-least claim when the count is unreadable", function()
    local Tuono, profile = bootProfile()
    local S = harness.fakeState({ enemyCount = nil, enemyCountKnown = false })
    expect.falsy(whenFor(Tuono, profile, ">=", 3)(S, nil),
      "we cannot claim three enemies we cannot see")
  end)

  it("compares normally when the count is readable", function()
    local Tuono, profile = bootProfile()
    local S = harness.fakeState({ enemyCount = 3 })
    expect.truthy(whenFor(Tuono, profile, ">=", 3)(S, nil))
    expect.falsy(whenFor(Tuono, profile, "<=", 1)(S, nil))
  end)
end)

describe("userrules: energy conditions use the interval, not a point estimate", function()
  local function whenFor(Tuono, profile, op, value)
    return compiledWhen(Tuono, profile, {
      spellKey = "sinisterStrike",
      enabled = true,
      conditions = { { type = "energy", op = op, value = value } },
    })
  end

  it("does not block a lower-bound claim the interval cannot disprove", function()
    local Tuono, profile = bootProfile()
    -- Energy is somewhere in [40, 90]. "energy >= 60" is unprovable either way, and the
    -- house rule for energy is that an unprovable claim PASSES and carries its
    -- uncertainty into confidence -- blocking on an estimate is what emptied the bar.
    local S = harness.fakeState({ energy = 40, energyLo = 40, energyHi = 90 })
    expect.truthy(whenFor(Tuono, profile, ">=", 60)(S, nil),
      "a point estimate of 40 suppressed a rule the interval says may well be true")
  end)

  it("still blocks a lower-bound claim the interval disproves", function()
    local Tuono, profile = bootProfile()
    local S = harness.fakeState({ energy = 20, energyLo = 10, energyHi = 30 })
    expect.falsy(whenFor(Tuono, profile, ">=", 60)(S, nil),
      "energy is provably below 60 and the rule should not fire")
  end)

  it("passes everything when energy is entirely unreadable", function()
    local Tuono, profile = bootProfile()
    local S = harness.fakeState({ energyKnown = false, energyLo = nil, energyHi = nil })
    expect.truthy(whenFor(Tuono, profile, ">=", 90)(S, nil))
  end)
end)

-- ============================================================================
-- C3 -- reading the rules must not fork the user off the built-in profile
-- ============================================================================

describe("userrules: looking at the rules is not editing them", function()
  it("is not customised before anything is read", function()
    local Tuono = bootProfile()
    expect.falsy(Tuono.UserRules.IsCustomised(PROFILE_ID, "single"))
  end)

  it("is still not customised after GetRows", function()
    local Tuono, profile = bootProfile()
    Tuono.UserRules.GetRows(profile, "single")
    expect.falsy(Tuono.UserRules.IsCustomised(PROFILE_ID, "single"),
      "opening the editor and changing nothing forked this user off the built-in "
      .. "profile permanently, cutting them off from every future APL fix")
  end)

  it("keeps running the built-in closures after a mere read", function()
    local Tuono, profile = bootProfile()
    Tuono.UserRules.GetRows(profile, "single")

    -- The built-in closures carry guards the compiler does not reproduce row-for-row.
    -- After a read-only visit the engine must still be running them.
    local effective = Tuono.UserRules.EffectivePriority(profile, "single")
    local builtin = profile.priority
    expect.equal(#effective, #builtin, "list length changed after a read-only visit")
    expect.equal(effective[1], builtin[1],
      "EffectivePriority returned compiled rows after a read that changed nothing")
  end)

  it("propagates a built-in fix to a row the user never touched", function()
    local Tuono, profile = bootProfile()
    Tuono.UserRules.GetRows(profile, "single")

    -- Stand in for a shipped APL fix: the author tightens a built-in rule. A user who
    -- only ever LOOKED at the editor must receive it.
    local target = nil
    for _, rule in ipairs(profile.priority) do
      if rule.name == "Roll the Bones below stage 2" then target = rule end
    end
    expect.truthy(target, "rule missing")
    target.when = function() return false end

    local effective = Tuono.UserRules.EffectivePriority(profile, "single")
    local seen = nil
    for _, rule in ipairs(effective) do
      if rule.name == "Roll the Bones below stage 2" then seen = rule end
    end
    expect.truthy(seen, "rule vanished from the effective list")
    -- Identity, not behaviour. A compiled copy could coincidentally agree with the
    -- sentinel on the state under test and make this pass while the user was in fact
    -- pinned to a stale rule.
    expect.equal(seen, target,
      "the user is running a compiled copy rather than the author's own updated rule")
  end)

  it("becomes customised once a row is actually edited", function()
    local Tuono, profile = bootProfile()
    local rows = Tuono.UserRules.GetRows(profile, "single")
    rows[1].conditions = { { type = "always" } }
    rows[1].spellKey = "dispatch"
    expect.truthy(Tuono.UserRules.IsCustomised(PROFILE_ID, "single"),
      "a real edit must register, or Reset-to-default has nothing to reset")
  end)

  it("becomes customised when a row is added, deleted or moved", function()
    for _, op in ipairs({ "add", "delete", "move" }) do
      local Tuono, profile = bootProfile()
      Tuono.UserRules.GetRows(profile, "single")
      if op == "add" then
        Tuono.UserRules.AddRow(PROFILE_ID, "single", "dispatch")
      elseif op == "delete" then
        Tuono.UserRules.DeleteRow(PROFILE_ID, "single", 1)
      else
        Tuono.UserRules.MoveRow(PROFILE_ID, "single", 1, 1)
      end
      expect.truthy(Tuono.UserRules.IsCustomised(PROFILE_ID, "single"),
        op .. " did not register as customisation")
    end
  end)

  it("runs the user's compiled row once they have edited it", function()
    local Tuono, profile = bootProfile()
    local rows = Tuono.UserRules.GetRows(profile, "single")
    rows[1].spellKey = "dispatch"
    rows[1].conditions = { { type = "always" } }

    local effective = Tuono.UserRules.EffectivePriority(profile, "single")
    expect.truthy(#effective > 0, "empty effective list")
    expect.equal(effective[1].spellKey, "dispatch",
      "the user's own edit did not reach the engine")
  end)

  it("edits survive, and untouched neighbours still track the built-ins", function()
    local Tuono, profile = bootProfile()
    local rows = Tuono.UserRules.GetRows(profile, "single")
    -- Edit exactly one row.
    local editedName = rows[2].name
    rows[2].conditions = { { type = "always" } }

    -- Ship a fix to a DIFFERENT, untouched row.
    for _, rule in ipairs(profile.priority) do
      if rule.name == rows[3].name then rule.when = function() return false end end
    end

    local effective = Tuono.UserRules.EffectivePriority(profile, "single")
    local byName = {}
    for _, rule in ipairs(effective) do byName[rule.name] = rule end

    expect.truthy(byName[editedName], "the edited row vanished")
    expect.truthy(byName[rows[3].name], "the untouched row vanished")
    expect.falsy(byName[rows[3].name].when(harness.fakeState(), nil),
      "the untouched neighbour did not pick up the built-in fix")
  end)

  it("Reset restores the built-in list outright", function()
    local Tuono, profile = bootProfile()
    local rows = Tuono.UserRules.GetRows(profile, "single")
    rows[1].spellKey = "dispatch"
    expect.truthy(Tuono.UserRules.IsCustomised(PROFILE_ID, "single"))
    Tuono.UserRules.ResetToDefault(PROFILE_ID, "single")
    expect.falsy(Tuono.UserRules.IsCustomised(PROFILE_ID, "single"))
    expect.equal(Tuono.UserRules.EffectivePriority(profile, "single")[1], profile.priority[1])
  end)

  it("treats a legacy stored list with no baseline as edited only where it differs", function()
    local Tuono, profile = bootProfile()
    -- Simulate a user forked by the OLD write-on-read behaviour: stored rows exist and
    -- carry no baseline metadata at all.
    local legacy = Tuono.UserRules.RowsFromProfile(profile, "single")
    for _, row in ipairs(legacy) do row.__baseline = nil end
    Tuono.UserRules.Store(PROFILE_ID).priority = legacy

    expect.falsy(Tuono.UserRules.IsCustomised(PROFILE_ID, "single"),
      "a legacy copy identical to the built-ins must be recognised as untouched, or "
      .. "these users never receive another fix")

    -- Now one that genuinely differs must be preserved as an edit.
    local Tuono2, profile2 = bootProfile()
    local legacy2 = Tuono2.UserRules.RowsFromProfile(profile2, "single")
    for _, row in ipairs(legacy2) do row.__baseline = nil end
    legacy2[1].spellKey = "dispatch"
    Tuono2.UserRules.Store(PROFILE_ID).priority = legacy2
    expect.truthy(Tuono2.UserRules.IsCustomised(PROFILE_ID, "single"),
      "a real edit made before the migration must never be silently discarded")
  end)
end)
