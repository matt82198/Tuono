-- ============================================================================
-- PROFILE RULE CORRECTNESS
-- ============================================================================
-- The single-target list learned these lessons; the AoE list was written later and did
-- not inherit them. Since the mode selector pinned every fight to AoE (see
-- test_mode.lua), the AoE list is the one that actually ran.
-- ============================================================================

local harness = require("harness")

describe("profile: Roll the Bones must fail closed on an unreadable stage", function()
  it("single-target list does not reroll when the stage is unknown", function()
    local Tuono = harness.boot()
    local rule = harness.rule(Tuono, "priority", "Roll the Bones below stage 2")
    expect.truthy(rule, "rule missing from the single-target list")
    local S = harness.fakeState()
    S.buffs.rtb.stage = 0
    S.buffs.rtb.stageKnown = false
    expect.falsy(rule.when(S, nil),
      "stage 0 means 'no buff' AND 'cannot see it'; rerolling on the second is what " ..
      "told players to reroll a Jackpot every 45 seconds")
  end)

  it("AoE list does not reroll when the stage is unknown", function()
    local Tuono = harness.boot()
    local rule = harness.rule(Tuono, "priorityAoE", "Roll the Bones below stage 2")
    expect.truthy(rule, "rule missing from the AoE list")
    local S = harness.fakeState()
    S.buffs.rtb.stage = 0
    S.buffs.rtb.stageKnown = false
    expect.falsy(rule.when(S, nil),
      "the AoE copy is missing the stageKnown guard its single-target twin has. " ..
      "The live trace had RtB stage readable only 27% of the time, in AoE mode 100% " ..
      "of the time -- so this fired constantly.")
  end)

  it("neither list throws when the stage is nil", function()
    local Tuono = harness.boot()
    for _, list in ipairs({ "priority", "priorityAoE" }) do
      local rule = harness.rule(Tuono, list, "Roll the Bones below stage 2")
      local S = harness.fakeState()
      S.buffs.rtb.stage = nil
      S.buffs.rtb.stageKnown = false
      expect.noThrow(function() rule.when(S, nil) end,
        list .. " compared a nil stage with <")
    end
  end)

  it("both lists still reroll a genuinely bad, readable roll", function()
    local Tuono = harness.boot()
    for _, list in ipairs({ "priority", "priorityAoE" }) do
      local rule = harness.rule(Tuono, list, "Roll the Bones below stage 2")
      local S = harness.fakeState()
      S.buffs.rtb.stage = 1
      S.buffs.rtb.stageKnown = true
      expect.truthy(rule.when(S, nil), list .. " refused to reroll a known stage 1")
    end
  end)

  it("neither list rerolls a good, readable roll", function()
    local Tuono = harness.boot()
    for _, list in ipairs({ "priority", "priorityAoE" }) do
      local rule = harness.rule(Tuono, list, "Roll the Bones below stage 2")
      local S = harness.fakeState()
      S.buffs.rtb.stage = 4
      S.buffs.rtb.stageKnown = true
      expect.falsy(rule.when(S, nil), list .. " rerolled a Jackpot")
    end
  end)
end)

describe("profile: ability data", function()
  it("every priority rule resolves to a spell the profile declares", function()
    local Tuono = harness.boot()
    local profile = Tuono.Profiles.Active()
    for _, list in ipairs({ "priority", "priorityAoE" }) do
      for _, rule in ipairs(profile[list] or {}) do
        local id = rule.spellID or (rule.spellKey and profile.spells[rule.spellKey])
        expect.truthy(id, list .. " rule '" .. rule.name .. "' resolves to no spellID")
        expect.truthy(profile.abilities[id],
          list .. " rule '" .. rule.name .. "' names a spell with no ability entry")
      end
    end
  end)

  it("every ability that costs energy is priced above zero", function()
    local Tuono = harness.boot()
    local profile = Tuono.Profiles.Active()
    -- A zero cost makes canAfford unconditionally true, which is how Ambush came to be
    -- recommended at 10 energy.
    for _, key in ipairs({ "sinisterStrike", "ambush", "dispatch", "pistolShot", "bladeFlurry" }) do
      local id = profile.spells[key]
      local ab = profile.abilities[id]
      expect.truthy(ab and (ab.cost or 0) > 0, key .. " has no energy cost")
    end
  end)

  it("finishers spend combo points", function()
    local Tuono = harness.boot()
    local profile = Tuono.Profiles.Active()
    for _, key in ipairs({ "betweenTheEyes", "dispatch", "killingSpree" }) do
      local ab = profile.abilities[profile.spells[key]]
      expect.truthy(ab and (ab.cpSpend or 0) ~= 0,
        key .. " is a finisher but spends no combo points, so the simulation never " ..
        "zeroes CP and every step after it is wrong")
    end
  end)
end)
