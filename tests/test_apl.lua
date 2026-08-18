-- ============================================================================
-- APL PARITY  --  pinned to MIDNIGHT 12.1 sources, deliberately
-- ============================================================================
-- This suite exists because of a near-miss. Auditing the profile against Hekili's source
-- and SimulationCraft's Outlaw APL, both of which are the obvious authorities, would have
-- REGRESSED five separate rules -- because both are synced to The War Within (11.x) and
-- Tuono targets Midnight (12.x).
--
--   Hekili/hekili README:                  "The Hekili Project on Retail WoW has ended
--                                           with the launch of the Midnight prepatch"
--   Hekili.toc:                            ## Interface: 110205   (patch 11.2.5)
--   Priorities/RogueOutlaw.simc header:    thewarwithin, commit bafa87f, 2025-09-03
--
-- The clearest example: Hekili declares Blade Rush at a 45s cooldown. Tuono says 60.
-- Tuono is right -- patch 12.0.0 increased it from 45 to 60. "Correcting" our value
-- against the more authoritative-looking source would have been a silent 25% error in
-- every cooldown prediction involving it, which is exactly the class of defect this
-- profile's comments already document three of.
--
-- So every assertion below cites a MIDNIGHT-ERA source, and says where an
-- earlier-expansion source disagrees. A future contributor reading Hekili or a
-- thewarwithin .simc will find a red test rather than a plausible-looking edit.
--
-- WHAT IS NOT PINNED HERE: anything I could not establish for 12.x. Those are recorded
-- as comments naming the uncertainty, never as assertions. A test that guesses is worse
-- than no test, because it converts a guess into an enforced invariant.
-- ============================================================================

local harness = require("harness")

local function profile(Tuono) return Tuono.Profiles.Active() end
local function ability(Tuono, key)
  local p = profile(Tuono)
  return p.abilities[p.spells[key]]
end

-- Build the benign state and let the caller break exactly one thing.
--
-- harness.fakeState omits `tier`, which StateTracker's schema ALWAYS provides
-- (tier = { twoPc = false, fourPc = false }). Two advisory rules read S.tier directly and
-- throw without it -- but they throw against the fixture, not against anything the addon
-- can actually produce, so the fixture is what gets corrected here. Bending the rules to
-- satisfy an unrealistic state would be the mistake, not the fix.
local function stateWith(over)
  local S = harness.fakeState()
  S.tier = S.tier or { twoPc = false, fourPc = false }
  for k, v in pairs(over or {}) do S[k] = v end
  return S
end

describe("apl: ability data is pinned to Midnight, not to an earlier expansion", function()
  it("Blade Rush is a 60s cooldown", function()
    -- Patch 12.0.0 (2026-01-20) increased Blade Rush from 45s to 60s.
    -- Hekili TheWarWithin/RogueOutlaw.lua declares `cooldown = 45`, which was correct for
    -- 11.x and is wrong here. This assertion exists specifically to reject that edit.
    local Tuono = harness.boot()
    expect.equal(ability(Tuono, "bladeRush").cd, 60,
      "45 is the War Within value; Midnight raised it to 60")
  end)

  it("Blade Rush generates energy, not combo points", function()
    -- The profile's own history: "Blade Rush's combo-point generation was invented."
    -- Hekili declares no cp_gain for it either, so both sources agree.
    local Tuono = harness.boot()
    expect.equal(ability(Tuono, "bladeRush").cpGen, 0)
    expect.equal(ability(Tuono, "bladeRush").cost, 0)
  end)

  it("costs match the values both expansions agree on", function()
    -- These are unchanged between 11.x and 12.x, so Hekili corroborates Wowhead and the
    -- risk of drift is low. Sourced: Hekili TheWarWithin/RogueOutlaw.lua ability
    -- declarations (id / spend), cross-checked against the profile's existing citations.
    local Tuono = harness.boot()
    local expected = {
      sinisterStrike = 45,   -- Hekili spend = 45
      ambush         = 50,   -- Hekili spend = 50 (45 with Hidden Opportunity)
      dispatch       = 35,   -- Hekili spend = 35 * tight_spender
      betweenTheEyes = 25,   -- Hekili spend = 25 * tight_spender
      killingSpree   = 45,   -- Hekili spend = 45 * tight_spender
      pistolShot     = 40,   -- Hekili spend = 40 - opportunity discount
      bladeFlurry    = 15,   -- Hekili spend = 15
      rollTheBones   = 25,   -- Hekili spend = 25
    }
    for key, cost in pairs(expected) do
      expect.equal(ability(Tuono, key).cost, cost, key .. " energy cost")
    end
  end)

  it("cooldowns match where the expansions agree", function()
    local Tuono = harness.boot()
    local expected = {
      adrenalineRush = 180,  -- Hekili cooldown = 180
      killingSpree   = 180,  -- Hekili cooldown = 180
      betweenTheEyes = 45,   -- Hekili cooldown = 45 (0 with Crackshot while stealthed)
      rollTheBones   = 45,   -- Hekili cooldown = 45
      bladeFlurry    = 30,   -- Hekili cooldown = 30
      keepItRolling  = 360,  -- Hekili cooldown = 360
    }
    for key, cd in pairs(expected) do
      expect.equal(ability(Tuono, key).cd, cd, key .. " cooldown")
    end
  end)

  it("every finisher spends all combo points", function()
    -- cpSpend = -1 means "spend up to the live cap". A hardcoded number under-credits
    -- Restless Blades cooldown reduction at a 6- or 7-point cap.
    local Tuono = harness.boot()
    for _, key in ipairs({ "betweenTheEyes", "killingSpree", "dispatch" }) do
      expect.equal(ability(Tuono, key).cpSpend, -1, key .. " must spend all combo points")
    end
  end)

  it("off-GCD abilities are marked off-GCD", function()
    -- Hekili declares gcd = "off" for adrenaline_rush and keep_it_rolling. Getting this
    -- wrong makes the simulation charge a GCD for a free action and drift from step 2 on.
    local Tuono = harness.boot()
    expect.falsy(ability(Tuono, "adrenalineRush").gcd, "Adrenaline Rush is off-GCD")
    expect.falsy(ability(Tuono, "keepItRolling").gcd, "Keep It Rolling is off-GCD")
    -- Blade Flurry is ON the GCD (Hekili: gcd = "totem", i.e. a real GCD).
    expect.truthy(ability(Tuono, "bladeFlurry").gcd, "Blade Flurry is on the GCD")
  end)
end)

describe("apl: rotation rules are pinned to Midnight guidance", function()
  local function fires(Tuono, list, name, S)
    local rule = harness.rule(Tuono, list, name)
    expect.truthy(rule, name .. " missing from " .. list)
    return rule.when(S, nil) and true or false
  end

  it("rerolls Roll the Bones below stage 2", function()
    -- Icy Veins 12.1: "Use Roll the Bones on cooldown unless you are already in Stage 2
    -- or higher."
    -- CONFLICTING EARLIER SOURCE: the thewarwithin SimC APL's unconditional rule is
    -- `roll_the_bones,if=rtb_buffs=0`, rerolling only with NO buffs; its <=1 and <=2
    -- rules are gated behind talents and set bonuses. That is 11.x guidance and must not
    -- be applied here.
    local Tuono = harness.boot()
    local S = stateWith()
    S.buffs.rtb.stage, S.buffs.rtb.stageKnown = 1, true
    expect.truthy(fires(Tuono, "priority", "Roll the Bones below stage 2", S),
      "must reroll a known stage 1")
    S.buffs.rtb.stage = 2
    expect.falsy(fires(Tuono, "priority", "Roll the Bones below stage 2", S),
      "must not reroll at stage 2")
  end)

  it("uses Keep It Rolling at stage 3, not stage 4", function()
    -- Icy Veins 12.1: "Use Keep It Rolling when you are in Stage 3."
    -- CONFLICTING EARLIER SOURCE: thewarwithin SimC uses `rtb_buffs>=4`. 11.x.
    local Tuono = harness.boot()
    local S = stateWith()
    S.buffs.rtb.stage, S.buffs.rtb.stageKnown = 3, true
    expect.truthy(fires(Tuono, "priority", "Keep It Rolling at stage 3+", S),
      "must fire at stage 3")
    S.buffs.rtb.stage = 2
    expect.falsy(fires(Tuono, "priority", "Keep It Rolling at stage 3+", S),
      "must not fire at stage 2")
  end)

  it("uses Adrenaline Rush at low combo points", function()
    -- Icy Veins 12.1: "Use Adrenaline Rush on cooldown, at low Combo Points."
    -- CONFLICTING EARLIER SOURCE: thewarwithin SimC gates primarily on
    -- `!buff.adrenaline_rush.up` with the combo-point clause attached to Improved
    -- Adrenaline Rush only.
    local Tuono = harness.boot()
    local S = stateWith({ comboPoints = 1 })
    expect.truthy(fires(Tuono, "priority", "Adrenaline Rush at low CP", S))
    S.comboPoints = 5
    expect.falsy(fires(Tuono, "priority", "Adrenaline Rush at low CP", S),
      "must not fire at high combo points")
  end)

  it("uses Blade Rush on cooldown, with no energy gate", function()
    -- Icy Veins 12.1: "Use Blade Rush on cooldown as if it were a regular builder."
    -- CONFLICTING EARLIER SOURCE: thewarwithin SimC gates it on
    -- `energy.base_time_to_max>4&!stealthed.all`. Applying that here would suppress it
    -- at high energy, which 12.1 guidance does not ask for.
    local Tuono = harness.boot()
    local S = stateWith({ energy = 100, energyLo = 100, energyHi = 100 })
    expect.truthy(fires(Tuono, "priority", "Blade Rush on cooldown", S),
      "Blade Rush must fire on cooldown regardless of energy")
  end)

  it("puts Between the Eyes ahead of Killing Spree in single target", function()
    -- Icy Veins 12.1: "Cast Between the Eyes at 6+ CP first; only then Use Killing Spree
    -- on cooldown, at 6+ Combo Points."
    --
    -- CONFLICTING SOURCE, UNRESOLVED: thewarwithin SimC's finish list orders
    -- killing_spree BEFORE between_the_eyes, and it shares that list between single
    -- target and AoE. Tuono's AoE list follows SimC's order and its single-target list
    -- follows Icy Veins. That asymmetry is DELIBERATE and documented in the profile, but
    -- it rests on two sources that disagree and has not been settled for 12.x. Recorded
    -- rather than resolved; see the report accompanying this suite.
    local Tuono = harness.boot()
    local p = profile(Tuono)
    local order = {}
    for i, rule in ipairs(p.priority) do order[rule.name] = i end
    expect.truthy(order["Between the Eyes at max CP"] < order["Killing Spree at max CP"],
      "single-target order follows Icy Veins 12.1")
  end)

  it("holds Preparation until every reset target is actually down", function()
    -- Icy Veins 12.1: "Use Preparation to reset the cooldown of your AR, BtE, and Blade
    -- Rush" when Between the Eyes is unavailable. The profile requires ALL of Adrenaline
    -- Rush, Between the Eyes and Killing Spree to be on cooldown -- stricter than the
    -- guide, and deliberately so: an OR fired it two seconds into every pull on a
    -- four-minute cooldown, resetting nothing worth resetting.
    local Tuono = harness.boot()
    local S = stateWith()
    S.cooldowns.adrenalineRush.ready = false
    S.cooldowns.betweenTheEyes.ready = false
    S.cooldowns.killingSpree.ready = false
    expect.truthy(fires(Tuono, "priority", "Preparation to reset cooldowns", S),
      "must fire when all three reset targets are down")
    S.cooldowns.betweenTheEyes.ready = true
    expect.falsy(fires(Tuono, "priority", "Preparation to reset cooldowns", S),
      "must not burn a 4-minute cooldown while Between the Eyes is already up")
  end)
end)

describe("apl: the AoE list carries the same guards as single target", function()
  -- The AoE list was written later and has already been caught once missing a guard its
  -- single-target twin had -- the Roll the Bones stageKnown check, which is the single
  -- most damaging defect this profile has shipped. Every shared rule is checked in BOTH
  -- lists from here on.
  local SHARED = {
    "Roll the Bones below stage 2",
    "Adrenaline Rush at low CP",
    "Blade Rush on cooldown",
    "Between the Eyes at max CP",
    "Killing Spree at max CP",
    "Dispatch as fallback finisher",
    "Pistol Shot on Opportunity",
    "Sinister Strike to build",
    "Sinister Strike (last resort)",
  }

  it("has every shared rule in both lists", function()
    local Tuono = harness.boot()
    local missing = {}
    for _, name in ipairs(SHARED) do
      local aoeName = name
      -- The AoE list renames two rules to explain why they rank differently.
      if name == "Killing Spree at max CP" then aoeName = "Killing Spree (cleaves hard)" end
      if not harness.rule(Tuono, "priorityAoE", aoeName) then
        table.insert(missing, aoeName)
      end
    end
    table.sort(missing)
    expect.listEqual(missing, {}, "rules present in single target but absent from AoE")
  end)

  it("fails closed on an unreadable Roll the Bones stage in BOTH lists", function()
    local Tuono = harness.boot()
    for _, list in ipairs({ "priority", "priorityAoE" }) do
      local rule = harness.rule(Tuono, list, "Roll the Bones below stage 2")
      local S = stateWith()
      S.buffs.rtb.stage, S.buffs.rtb.stageKnown = 0, false
      expect.falsy(rule.when(S, nil),
        list .. " rerolled on a stage it could not read -- this guard has been broken "
          .. "five times in this codebase")
    end
  end)

  it("routes every Roll the Bones comparison through the shared helper", function()
    -- Structural, not behavioural: the guard diverged once because it was written inline
    -- in two places. Reading the stage directly is what makes that possible, so it is
    -- banned outright rather than trusted to review.
    local path = harness.addonDir .. "/profiles/OutlawRogue.lua"
    local fh = assert(io.open(path, "r"))
    local src = fh:read("*a")
    fh:close()
    -- Strip comments so the explanatory prose above each rule does not trip this.
    src = src:gsub("%-%-[^\n]*", "")
    expect.falsy(src:find("buffs%.rtb%.stage%s*[<>=]"),
      "a rule compares buffs.rtb.stage directly; use RuleHelpers.rtbStageBelow or "
        .. "rtbStageAtLeast, which cannot be half-applied")
  end)
end)

describe("apl: advisory rules must not throw", function()
  -- The ADVISE layer in data/rules.lua is walked by Engine.Evaluate on every tick. A rule
  -- that throws there is skipped, but skipping was invisible until recently and a throw in
  -- the rescue walk could empty the bar entirely. These rules read cooldown rows and buff
  -- fields directly, so they are exactly the shape that throws on a state the simulator
  -- legitimately produces: a cooldown key the profile does not track, or a remainder that
  -- was inferred rather than measured and is therefore nil.
  local function everyRuleSurvives(Tuono, S)
    local threw = {}
    for _, rule in ipairs(Tuono.Rules or {}) do
      if rule.when then
        local ok = pcall(rule.when, S, Tuono.Assist)
        if not ok then table.insert(threw, rule.name or "?") end
      end
    end
    table.sort(threw)
    return threw
  end

  it("survives a state where a tracked cooldown row is absent", function()
    local Tuono = harness.boot()
    local S = stateWith()
    S.cooldowns = {}   -- nothing tracked yet: the state right after a reload
    expect.listEqual(everyRuleSurvives(Tuono, S), {},
      "an advisory rule indexed a cooldown row that does not exist")
  end)

  it("survives a cooldown whose remainder was never measured", function()
    -- CooldownModel reports remaining = nil for an inferred cooldown, because inventing a
    -- countdown we never observed is the defect that made Adrenaline Rush look ready at
    -- step 2 of the lookahead.
    local Tuono = harness.boot()
    local S = stateWith()
    for _, key in pairs({ "adrenalineRush", "bladeRush", "preparation" }) do
      S.cooldowns[key] = { known = true, ready = false, remaining = nil, remainingKnown = false }
    end
    expect.listEqual(everyRuleSurvives(Tuono, S), {},
      "an advisory rule compared a remainder it never measured")
  end)

  it("survives an unreadable Roll the Bones stage", function()
    local Tuono = harness.boot()
    local S = stateWith()
    S.buffs.rtb.stage, S.buffs.rtb.stageKnown = nil, false
    expect.listEqual(everyRuleSurvives(Tuono, S), {},
      "an advisory rule compared a stage it could not read")
  end)
end)
