local ADDON_NAME, Tuono = ...

Tuono.Engine = Tuono.Engine or {}

-- ==========================================================================
-- STALL DETECTION
-- ==========================================================================
-- The documented trust-killer for assisted-combat addons: the recommender gets stuck on
-- a suggestion the player is deliberately ignoring (Blizzard's own engine is reported to
-- stall on AoE abilities against a single target and refuse to advance until you obey).
-- A helper that keeps insisting is worse than one that admits doubt.
--
-- Both halves are exactly knowable: what we recommended, and what the player actually
-- cast. If they keep diverging, the panel should visibly lose confidence in itself
-- rather than keep shouting. It does not warn and pops nothing -- it fades, which is
-- the one honest signal that costs no attention.
Tuono.Engine.stallCount = 0
local STALL_THRESHOLD = 3

-- How long a plan may survive without the player following it. This is a BACKSTOP, not
-- the primary invalidation path -- deviation and persistent disagreement both re-plan
-- immediately. It exists so a player who stops pressing things (target died, ran out of
-- range, walked away) still sees the bar catch up rather than holding a stale plan.
local MAX_PLAN_AGE = 3.0

-- Ticks of disagreement before the plan is abandoned. The tick loop runs at 10Hz in
-- combat, so 3 is ~0.3s -- long enough that a single blinking sensor reading cannot
-- unseat a plan, short enough to be imperceptible when the world genuinely changed.
-- One tick would make this identical to having no plan at all, which is where the churn
-- came from in the first place.
local DISAGREE_TICKS_BEFORE_REPLAN = 3

-- How far the simulation runs. Deliberately deeper than the icon count: Display collapses
-- consecutive repeats into a single icon with a multiplier, so depth buys sequence SHAPE
-- rather than screen space. Rotation.Predict caps at 8.
local PREDICT_DEPTH = 8

-- How many predicted steps may reach the queue. Separate from PREDICT_DEPTH so the
-- simulation can run deeper than the bar shows, and separate from the advisories, which
-- are facts about now and are never trimmed to make room for a prediction.
local MAX_SEQUENCE_ENTRIES = 8

-- ==========================================================================
-- RECALCULATION TRIGGERS
-- ==========================================================================
-- What is allowed to throw away a plan, named in one place.
--
-- These existed before, scattered across an event handler, a disagreement counter and an
-- age check, with nothing that said what the complete set was. Scattered triggers are
-- how a set becomes accidentally incomplete AND accidentally over-eager at the same
-- time: nobody can see the whole of it to judge either.
--
-- THE GOVERNING CONSTRAINT: every trigger is a chance for the bar to churn again, which
-- is the defect this layer exists to fix. So a trigger must fire on a REAL state change,
-- never on a sensor blinking. Where an input can blink, it is either derived from a
-- modelled value or required to persist -- see worldChangedSince, which compares KNOWN
-- to KNOWN and treats a transition into "unknown" as an absence of evidence rather than
-- as evidence of change. That distinction is the whole reason the stage was readable on
-- 27% of ticks and the bar flapped anyway.
local TRIGGER = {
  DEVIATED  = "deviated",         -- cast something other than the planned step
  PROC      = "proc",             -- an activation overlay lit or cleared
  COOLDOWN  = "cooldown-ready",   -- a cooldown we knew was down came up
  RTB_STAGE = "rtb-stage",        -- Roll the Bones landed on a different stage
  TARGET    = "target-changed",   -- range, facing and target existence all changed
  MODE      = "mode-flipped",     -- AoE <-> single: a genuinely different priority list
  TALENTS   = "talents-changed",  -- the ability set itself changed
  COMBAT    = "combat-boundary",  -- a plan from the last pull is not a plan for this one
  DISAGREE  = "disagreement",     -- fresh prediction persistently differs from the cursor
  EXHAUSTED = "plan-exhausted",   -- the player followed it to the end
  AGED      = "plan-aged-out",    -- nobody is following it; catch up rather than freeze
  RESOURCE  = "resource-changed", -- combo points moved without us casting anything
  WORLD     = "world-changed",    -- fallback label when no more specific reason was set
}
Tuono.Engine.TRIGGER = TRIGGER

-- Throw the plan away, recording WHY.
--
-- The reason is remembered rather than counted here: Evaluate does the counting when it
-- actually re-plans, so an invalidation and the re-plan it causes are one event in the
-- tally instead of two. `lastTrigger` is published for /tuono debug and the flight
-- recorder -- a trace that shows a re-plan without saying what caused it is not
-- diagnosable, which is how the original churn went unexplained for so long.
function Tuono.Engine.InvalidatePlan(reason)
  local E = Tuono.Engine
  E.plan = nil
  E.cursor = nil
  E.planContext = nil
  E.disagreeTicks = 0
  E.verifyOnAdvance = false
  E.pendingTrigger = reason
end

-- PROC EDGES. The spell activation overlay carries no secrecy flags, fires on BOTH the
-- show and hide edges, and carries a plainly readable spellID -- so this is an OBSERVED
-- transition, not a polled value. That is precisely why it needs no persistence filter
-- while an aura read would: an event cannot blink, it can only happen.
--
-- Filtered to the procs the active profile actually gates rules on. Every spell in the
-- game lights up somebody's button, and re-planning on a Paladin's Art of War would be
-- churn with no information in it.
local function onOverlayEdge(event, spellID)
  local id = Tuono.readNum(spellID)
  if not id then return end
  local profile = Tuono.Profiles and Tuono.Profiles.Active()
  local map = profile and profile.overlayAuras
  if not (map and map[id]) then return end
  Tuono.Engine.InvalidatePlan(TRIGGER.PROC)
end

Tuono.RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", onOverlayEdge)
Tuono.RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", onOverlayEdge)

-- A NEW TARGET IS A NEW FIGHT for every purpose the plan cares about: range, facing,
-- whether anything is there to hit at all. The recorded trace carried
-- ERR_SPELL_OUT_OF_RANGE and ERR_NO_ATTACK_TARGET against live recommendations.
Tuono.RegisterEvent("PLAYER_TARGET_CHANGED", function()
  Tuono.Engine.InvalidatePlan(TRIGGER.TARGET)
end)

-- The ability set itself changed, so the plan may name spells the character no longer
-- has. Rare and never noisy, which is why it needs no damping.
for _, evt in ipairs({ "TRAIT_CONFIG_UPDATED", "PLAYER_SPECIALIZATION_CHANGED" }) do
  Tuono.RegisterEvent(evt, function()
    Tuono.Engine.InvalidatePlan(TRIGGER.TALENTS)
  end)
end

Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, castGUID, spellID)
  if unit ~= "player" then return end
  local id = Tuono.readNum(spellID)
  if not id then return end
  local E = Tuono.Engine

  local recommended = E.lastPos1
  if recommended and id ~= recommended then
    E.stallCount = (E.stallCount or 0) + 1
  else
    E.stallCount = 0
  end

  -- ADVANCE THE PLAN, OR ABANDON IT.
  --
  -- This is the whole point of planning: following the plan must be CHEAP. The
  -- simulation already computed the state this cast produces, so the remaining steps are
  -- still correct and the bar should simply slide left.
  --
  -- Deviating is different in kind. Every later step was conditioned on this press
  -- happening; once it did not, they describe a world that does not exist. A plan built
  -- on a press that never happened is worse than no plan, so it goes immediately -- no
  -- disagreement counter, no grace.
  --
  -- Off-GCD abilities are deliberately NOT treated as deviation. Adrenaline Rush and
  -- Preparation do not consume the GCD, so weaving one does not invalidate the plan for
  -- the ability the player is still about to press.
  if E.plan and E.cursor then
    local planned = E.plan[E.cursor]
    if planned and planned.spellID == id then
      E.cursor = E.cursor + 1
      E.disagreeTicks = 0
      -- Followed correctly -- but possibly LATE. Re-validate on the very next tick
      -- instead of trusting the rest of the plan; see the note in Evaluate.
      E.verifyOnAdvance = true
    else
      local ability = Tuono.Rotation and Tuono.Rotation.ABILITIES
        and Tuono.Rotation.ABILITIES[id]
      local offGCD = ability and ability.gcd == false
      if not offGCD then
        Tuono.Engine.InvalidatePlan(TRIGGER.DEVIATED)
      end
    end
  end
end)

Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", function()
  Tuono.Engine.stallCount = 0
end)

function Tuono.Engine.IsStalled()
  return (Tuono.Engine.stallCount or 0) >= STALL_THRESHOLD
end

-- Reusable result tables (allocation-light per contract)
local resultQueue = {}
local resultAdvisories = {}
local tempDedup = {}
local queueSet = {}
local dedupQueue = {}

-- Helper: wipe table via for-loop nil-ing (Lua 5.1 compatible)
local function wipeTable(tbl)
  for i = 1, #tbl do
    tbl[i] = nil
  end
end

-- Helper: remove all entries from a set-style table
local function wipeSet(tbl)
  for k in pairs(tbl) do
    tbl[k] = nil
  end
end

-- ==========================================================================
-- PLAN CONTEXT: the world as it stood when the plan was made
-- ==========================================================================
-- A trigger is a CHANGE, and a change needs a baseline. This captures the small set of
-- facts a plan's validity actually rests on, so the per-tick check compares against what
-- was true at plan time rather than against nothing.
--
-- Deliberately small. Every field here is a thing that can re-plan the bar, so anything
-- added must earn it by changing what the priority walk chooses.
local function snapshotPlanContext(S)
  local ctx = { notReady = {} }

  -- Cooldowns we KNEW were down. Storing the not-ready set rather than the ready set is
  -- what makes the later comparison a provable transition: known-not-ready -> known-ready
  -- involves no unknown at either end, so a `known` flag flickering cannot manufacture a
  -- trigger out of nothing.
  for key, cd in pairs(S.cooldowns or {}) do
    if cd.known and not cd.ready then ctx.notReady[key] = true end
  end

  ctx.mode = Tuono.Rotation and Tuono.Rotation.mode

  -- Combo points as of the plan. Never secret, so this is a real observation; see the
  -- RESOURCE trigger in worldChangedSince for why it is skipped on a post-cast tick.
  if S.comboPointsKnown ~= false and type(S.comboPoints) == "number" then
    ctx.cp = S.comboPoints
  end

  -- Deliberately NOT written as `local stage, known = A and A.rtbStage and A.rtbStage(S)`.
  -- An `and` chain truncates a multiple-return call to its first value, so `known` would
  -- silently be nil, the stage would never be captured, and the trigger below would be
  -- permanently dead -- along with the test asserting it does not misfire, which would
  -- have passed vacuously forever.
  if Tuono.RuleHelpers and Tuono.RuleHelpers.rtbStage then
    local stage, known = Tuono.RuleHelpers.rtbStage(S)
    if known then ctx.rtbStage = stage end
  end

  return ctx
end

-- Returns a TRIGGER when the world has moved in a way that invalidates the plan, or nil.
--
-- Each check is written to be blind to blinking. That is the entire difficulty: the
-- naive version of any of these fires on a sensor losing its signal, which is not a
-- change in the world and must never move the bar.
local function worldChangedSince(S, ctx)
  if not ctx then return nil end

  -- MODE FLIP. AoE and single-target are genuinely different priority lists, so a plan
  -- built from one is not a plan for the other. Safe to act on instantly because
  -- Rotation.ResolveMode already carries a 2s dwell -- this fires on the DEBOUNCED
  -- output, never on a nameplate count crossing the threshold back and forth.
  local mode = Tuono.Rotation and Tuono.Rotation.mode
  if mode ~= ctx.mode then return TRIGGER.MODE end

  -- ROLL THE BONES STAGE. Gates the reroll rule and Keep It Rolling, both near the top
  -- of the list. Compared KNOWN to KNOWN only: a transition into unknown is an absence
  -- of evidence, not evidence of a change, and treating it as one is exactly the defect
  -- that made the bar flap when the stage was still a per-tick aura read.
  if ctx.rtbStage and Tuono.RuleHelpers and Tuono.RuleHelpers.rtbStage then
    local stage, known = Tuono.RuleHelpers.rtbStage(S)
    if known and stage ~= ctx.rtbStage then return TRIGGER.RTB_STAGE end
  end

  -- A COOLDOWN CAME UP. Readiness is the never-secret boolean corrected every tick
  -- against ground truth, so this is an observed transition rather than a guess, and a
  -- major cooldown becoming available makes a higher-priority rule true.
  --
  -- Only down -> up counts. Going ON cooldown is something the plan itself caused and
  -- already predicted, so treating it as news would re-plan after every single cast.
  for key, cd in pairs(S.cooldowns or {}) do
    if cd.known and cd.ready and ctx.notReady[key] then return TRIGGER.COOLDOWN end
  end

  -- COMBO POINTS MOVED AND WE DID NOT MOVE THEM.
  --
  -- Combo points gate every finisher and the builder, so a plan built at 2 points is not
  -- a plan at 5. They are never secret, so this is an observed transition.
  --
  -- The subtlety is that CP changes constantly BECAUSE the player follows the plan, and
  -- triggering on that would re-plan after every cast and defeat the whole layer. So the
  -- comparison is skipped on the tick right after a cast -- `verifyOnAdvance` already
  -- marks exactly that tick -- and the baseline is re-taken instead. What survives is the
  -- case this is for: points that changed with no cast of ours behind them, which means
  -- the plan was built on a world that no longer exists.
  --
  -- Without this, Engine.Evaluate is not a function of Tuono.State: a caller that changes
  -- the state and evaluates once gets the PREVIOUS plan, because the disagreement check
  -- needs three consecutive ticks and a single call never accumulates them.
  if ctx.cp ~= nil and S.comboPointsKnown ~= false and type(S.comboPoints) == "number" then
    if S.comboPoints ~= ctx.cp then return TRIGGER.RESOURCE end
  end

  return nil
end

-- Helper: rebuild queueSet from current queue (minimize calls)
local function rebuildQueueSet()
  wipeSet(queueSet)
  for i, entry in ipairs(resultQueue) do
    -- FIRST occurrence wins. The predicted sequence may repeat an ability, and
    -- last-wins made PIN/PREFER move the LAST copy instead of the one at the front --
    -- reordering the wrong entry and corrupting the sequence the user reads first.
    if entry.spellID and not queueSet[entry.spellID] then
      queueSet[entry.spellID] = i
    end
  end
end

function Tuono.Engine.Evaluate()
  wipeTable(resultQueue)
  wipeTable(resultAdvisories)
  wipeSet(tempDedup)
  wipeSet(queueSet)
  wipeTable(dedupQueue)

  local S = Tuono.State
  local A = Tuono.Assist

  -- ONE ROTATION ON THE BAR. THE BAR IS OURS.
  --
  -- This used to fall back to Blizzard's GetNextCastSpell pick whenever our own
  -- prediction came back empty. Two reasons that is gone:
  --
  -- 1. It was firing constantly, but only because of a bug. Secret energy was being
  --    read as a confident 0, so every affordability gate failed and Predict returned
  --    an empty sequence on every tick -- and the "fallback" became the entire bar.
  --    (The old note here claimed GetNextCastSpell is STATIC in combat, "52 samples".
  --    It is not. Blizzard's own AssistedCombatManager polls it every 0.1s and acts on
  --    the change. What those samples measured was AssistReader crashing on a secret
  --    boolean from IsAvailable() before it ever reassigned nextSpellID.)
  --
  -- 2. Even working correctly it is the WRONG THING TO RENDER. Blizzard's assist is a
  --    different rotation, not a degraded copy of ours -- it ignores Roll the Bones and
  --    combo-point overflow. Silently swapping one list for the other mid-fight, with
  --    only an alpha difference to signal it, is incoherent for the player reading it.
  --
  -- We still READ the assist pick every tick (see AssistReader): it is the only thing
  -- in this addon with access to true combat state, which makes it useful as a SENSOR
  -- for drift in our own estimates. It just never becomes an icon.
  --
  -- Step 0: Get our rotation predictions -- the only source for the queue.
  -- SIMULATE DEEPER THAN WE DISPLAY.
  --
  -- This was 4, exactly the number of icons shown, which quietly capped what the bar
  -- could ever reveal. Outlaw needs up to 5 builders before a finisher at a 5-point cap,
  -- so the finisher sat at position 5 and was invisible until the player was already at
  -- 3 combo points -- producing a wall of Sinister Strike with occasional cooldowns
  -- popping into slot 1. Reported as "the whole bar is sinister strike while random
  -- things pop into the first slot".
  --
  -- The sequence was never wrong. Simulated 6 deep it reads
  --   cp=0  SS > SS > SS > SS > BtE > SS
  --   cp=2  SS > SS > BtE > SS > SS > SS
  --   cp=4  BtE > SS > SS > SS > SS > Dispatch
  -- -- the finisher marching left as combo points build, which is exactly the shape a
  -- rotation helper exists to show. It was simply off the end of the bar.
  --
  -- Display collapses runs of the same ability into one icon with a count, so the extra
  -- depth costs no screen space and buys the whole shape.
  local predictions = Tuono.safe(Tuono.Rotation.Predict, S, PREDICT_DEPTH)
  local queueIndex = 1

  if predictions and type(predictions) == "table" then
    for _, pred in ipairs(predictions) do
      -- DO NOT dedupe the predicted SEQUENCE. A rotation legitimately repeats an
      -- ability -- at 0 combo points the honest answer is "Sinister Strike x4" -- and
      -- collapsing those to one icon is why the bar showed only one or two entries.
      -- Dedup still applies to the rule-derived extras merged in below, so a cooldown
      -- reminder never doubles up an ability already in the sequence.
      if pred.spellID then
        table.insert(resultQueue, {
          spellID = pred.spellID,
          source = pred.reason or "rotation_predict",
          kind = "rotation",
          confidence = pred.confidence,
          step = queueIndex,
          -- CARRY THE TIMELINE THROUGH. Rotation.Predict stamps every step with `at`
          -- (seconds until it should be cast) and `since` (the gap after the previous
          -- one), and this was dropping both on the floor -- so Display's wait rendering,
          -- written to read entry.at, could never fire and every entry arrived at=nil.
          -- The engine computed the harder quantity and then discarded it.
          at = pred.at,
          since = pred.since,
          isSequence = true
        })
        tempDedup[pred.spellID] = true
        if not queueSet[pred.spellID] then
          queueSet[pred.spellID] = queueIndex
        end
        queueIndex = queueIndex + 1
      end
    end
  end

  -- Step 0b: DRIFT SENSOR (diagnostic only -- never enters the queue).
  -- Blizzard's engine can see the resources Midnight hides from us, so sustained
  -- disagreement between its pick and ours is the best available evidence that our
  -- shadow energy estimate has drifted. A single tick of disagreement means nothing
  -- (the two lists have genuinely different priorities), so only a run of them counts.
  Tuono.Engine = Tuono.Engine or {}
  local ours = predictions and predictions[1] and predictions[1].spellID or nil
  if ours and A.nextSpellID then
    local agrees = (ours == A.nextSpellID)
    Tuono.Engine.blizzAgrees = agrees
    Tuono.Engine.disagreeStreak = agrees and 0 or ((Tuono.Engine.disagreeStreak or 0) + 1)
  else
    Tuono.Engine.blizzAgrees = nil
    Tuono.Engine.disagreeStreak = 0
  end

  -- Step 2: Apply rules in array order
  local pinApplied = false
  local advisoryIndex = #resultAdvisories + 1

  for _, rule in ipairs(Tuono.Rules or {}) do
    -- Evaluate rule condition safely (skip if no when clause or condition not met)
    if rule.when then
      local condMet = Tuono.safe(rule.when, S, A)
      if condMet then
        -- Resolve spell ID lazily if needed
        local ruleSpellID = rule.spellID
        if rule.resolveSpellID and not ruleSpellID then
          ruleSpellID = Tuono.safe(rule.resolveSpellID)
        end

        -- THE SEQUENCE IS NOT A LIST. PIN AND PREFER MAY NOT TOUCH IT.
        --
        -- `Rotation.Predict` returns a CAUSAL CHAIN: step 3 is only correct if steps 1 and
        -- 2 actually happened, because the simulator spent their energy, banked their
        -- combo points and started their cooldowns. Reordering it, or splicing a foreign
        -- entry into the middle of it, produces a list that is not a valid sequence of
        -- anything -- while still being read by the player as "press these in order".
        --
        -- That is what was actually wrong with the wheel. Reproduced offline against the
        -- state from a live trace, at 3 combo points the bar read:
        --
        --     Sinister Strike | Blade Flurry | Dispatch | Adrenaline Rush | Sinister Strike
        --
        -- Blade Flurry wedged into a SINGLE-TARGET rotation against one enemy, Adrenaline
        -- Rush pinned into the middle as a fourth icon duplicating one already shown, and
        -- Dispatch promoted above the builder that was supposed to feed it. Only position
        -- 1 survived intact -- which is exactly what the display looked like in play.
        --
        -- Every PIN/PREFER spell here (Adrenaline Rush, Between the Eyes, Blade Flurry,
        -- Blade Rush, Sinister Strike, Pistol Shot, Stealth, Ambush) already has a rule in
        -- the profile's priority list, individually sourced against SimC. These are the
        -- pre-framework duplicates of those, and they were overriding the sourced version
        -- from outside the simulation. Nothing user-facing depends on them: the in-game
        -- editor compiles into the profile priority list, not into Tuono.Rules.
        --
        -- So the rotation is the profile's, and this layer is advisory only. ADVISE still
        -- appends cooldown, trinket and Roll the Bones reminders AFTER the sequence, where
        -- Display already renders them as a visibly different kind of thing.
        --
        -- The remaining duplication -- two rule schemas, one of which is now half inert --
        -- is tracked in STATE.md. The fix is to fold this file into the profiles; this is
        -- the part of it that was actively corrupting the bar.
        if rule.action == "PIN" or rule.action == "PREFER" then
          -- deliberately inert; see above

        elseif rule.action == "ADVISE" then
          -- Fold certain advisories into queue entries based on kind
          if rule.kind == "cooldown" and ruleSpellID then
            -- Only add if not already in queue
            if not queueSet[ruleSpellID] then
              local cooldownEntry = {
                spellID = ruleSpellID,
                source = rule.name,
                kind = "cooldown",
                itemSlot = rule.itemSlot
              }
              table.insert(resultQueue, cooldownEntry)
              rebuildQueueSet()
            end
          elseif rule.kind == "trinket" then
            -- Trinket entry with itemSlot
            if rule.itemSlot and not queueSet[rule.itemSlot] then
              local trinketEntry = {
                spellID = nil,
                source = rule.name,
                kind = "trinket",
                itemSlot = rule.itemSlot
              }
              table.insert(resultQueue, trinketEntry)
            end
          elseif rule.kind == "rtb" then
            -- FAIL CLOSED ON AN UNREADABLE STAGE. This was a bare `stage == 0`, which is
            -- the same unknown-as-no defect the profile rules already carry a shared
            -- helper for -- and it is reachable, because the ADVISE path is live even
            -- though PIN/PREFER are inert. Unguarded it flips with the sensor and
            -- re-orders the bar behind position 1.
            local _, rtbKnown = Tuono.RuleHelpers.rtbStage(S)
            if rtbKnown and S.buffs.rtb.stage == 0 then
              local rtbEntry = {
                spellID = Tuono.SpellIDs.rollTheBones,
                source = rule.name,
                kind = "rtb",
                itemSlot = nil
              }
              if not queueSet[Tuono.SpellIDs.rollTheBones] then
                table.insert(resultQueue, rtbEntry)
                rebuildQueueSet()
              end
            else
              -- Non-stage-0 RtB advice goes to advisory
              resultAdvisories[advisoryIndex] = {
                kind = rule.kind or "generic",
                icon = ruleSpellID,
                itemSlot = rule.itemSlot,
                text = rule.desc or "",
                active = true
              }
              advisoryIndex = advisoryIndex + 1
            end
          else
            -- Other ADVISE actions become advisories
            resultAdvisories[advisoryIndex] = {
              kind = rule.kind or "generic",
              icon = ruleSpellID,
              itemSlot = rule.itemSlot,
              text = rule.desc or "",
              active = true
            }
            advisoryIndex = advisoryIndex + 1
          end
        end
      end
    end
  end

  -- Step 3: Dedup by spellID (keep highest-priority = earliest in array)
  -- Sequence steps are EXEMPT: deduping them collapsed "SS, SS, SS, SS" into one icon,
  -- which is why the bar showed one or two entries instead of the four predicted steps.
  local seenSpells = {}
  for i, entry in ipairs(resultQueue) do
    if entry.isSequence then
      table.insert(dedupQueue, entry)
    elseif entry.spellID then
      if not seenSpells[entry.spellID] then
        table.insert(dedupQueue, entry)
        seenSpells[entry.spellID] = true
      end
    else
      -- Trinket entries (no spellID) - keep by itemSlot dedup
      local key = "trinket_" .. (entry.itemSlot or "nil")
      if not seenSpells[key] then
        table.insert(dedupQueue, entry)
        seenSpells[key] = true
      end
    end
  end
  wipeTable(resultQueue)
  for i, entry in ipairs(dedupQueue) do
    resultQueue[i] = entry
  end

  -- Step 4: ENGINE-LEVEL CASTABILITY FILTER (belt-and-braces)
  -- Drop any entry whose cooldown is not known-ready OR spell is not known, EXCEPT position 1 from Blizzard
  local filteredQueue = {}
  for i, entry in ipairs(resultQueue) do
    local skip = false

    -- The "position 1 from Blizzard is authoritative, never filter" exemption that used
    -- to sit here is gone with the fallback itself. It never matched anyway: the entry
    -- it was written for carried source "blizzard_static_fallback", not "blizzard".
    do
      -- Check if spell is known (when API available)
      if entry.spellID and not S.knownUnavailable then
        if S.knownSpells[entry.spellID] == false then
          skip = true
        end
      end

      -- POSITION 1 ONLY: the immediate action must be castable RIGHT NOW. Later
      -- sequence steps are legitimately on cooldown at this instant -- that is the
      -- point of a forward simulation -- so filtering them against live cooldowns
      -- would delete correct future steps.
      -- ALL position-1 entries, not just simulated ones. PIN entries from the legacy
      -- rules were skipping this check, so a Between the Eyes on a 38s cooldown could be
      -- pinned to position 1 while the actually-ready finisher sat at position 2.
      -- A pooling entry is ALREADY flagged as not-yet-castable; filtering it here would
      -- delete the very thing we are trying to tell the player to wait for.
      if not skip and i == 1 and entry.spellID and entry.confidence ~= "pooling" then
        -- Only meaningful for abilities that HAVE a cooldown. A zero-cooldown ability
        -- (Ambush, Sinister Strike, Dispatch) can never be "not ready", so a stale
        -- not-ready entry for one must not suppress a correct recommendation.
        local ab = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[entry.spellID]
        local hasCooldown = ab and (ab.cd or 0) > 0
        if hasCooldown then
          local key = Tuono.Rotation.SPELL_TO_CDKEY and Tuono.Rotation.SPELL_TO_CDKEY[entry.spellID]
          local cd = key and S.cooldowns[key]
          if cd and cd.known and not cd.ready then
            skip = true
          end
        end
      end

      -- For cooldown/trinket entries: verify the cooldown is known and ready
      if not skip and entry.kind == "cooldown" and entry.spellID then
        local cd = S.cooldowns[entry.spellID == Tuono.SpellIDs.adrenalineRush and "adrenalineRush" or
                              entry.spellID == Tuono.SpellIDs.bladeRush and "bladeRush" or
                              entry.spellID == Tuono.SpellIDs.preparation and "preparation" or nil]
        if cd and (not cd.known or not cd.ready) then
          skip = true
        end
      elseif not skip and entry.kind == "trinket" and entry.itemSlot then
        local trinket = S.trinkets[entry.itemSlot]
        if trinket and not trinket.ready then
          skip = true
        end
      end
    end

    if not skip then
      table.insert(filteredQueue, entry)
    end
  end
  wipeTable(resultQueue)
  for i, entry in ipairs(filteredQueue) do
    resultQueue[i] = entry
  end

  -- (lastPos1 is assigned AFTER the plan and fallback layers, further down: it must
  -- describe what was published, not what was derived. See the note there.)

  -- CONFIDENCE TRUNCATION: show lookahead only as far as we can stand behind it.
  --
  -- Removing the wheel entirely was an over-correction. "Position 1 is optimal but it is
  -- too hard to react to with zero prediction" is the correct complaint: lead time is
  -- the thing a rotation helper is FOR, and one icon gives none.
  --
  -- But the reason the wheel was useless was never its length -- it was that step 4 was
  -- rendered with the same authority as step 1 while resting on an energy interval and
  -- unreadable aura state. Now that every step carries its provenance, the sequence can
  -- simply STOP at the first step we cannot justify.
  --
  -- The result is self-adjusting: a clean combo-point-and-cooldown sequence shows its
  -- full depth, and one that hits a hidden dependency ends there. The player learns to
  -- trust the length, because the length means something.
  -- Position 1 is exempt: it is the answer to "what do I press now", and refusing to
  -- answer that is strictly worse than answering it with a visible uncertainty tint.
  -- Only the LOOKAHEAD has to earn its place.
  --
  -- Only sequence steps are cut. The cooldown and trinket reminders appended after them
  -- are independently sourced -- they are not predicting the future, they are reporting a
  -- cooldown that is ready now -- so an uncertain step 2 must not silently delete them.
  local cut = nil
  for i, entry in ipairs(resultQueue) do
    if i > 1 and entry.isSequence and entry.confidence == "unknown" then
      cut = i
      break
    end
  end
  if cut then
    for i = #resultQueue, cut, -1 do
      if resultQueue[i].isSequence then
        table.remove(resultQueue, i)
      end
    end
  end

  -- ==========================================================================
  -- LOOKAHEAD COMMITMENT
  -- ==========================================================================
  -- Position 1 is re-derived from ground truth every tick and is supposed to move. The
  -- LOOKAHEAD is different, and it was being recomputed just as often -- which is the
  -- reported complaint: "the first button is optimal, it switches the entire list a lot
  -- and it's not smooth".
  --
  -- The engine is not at fault. Rotation.Predict is a pure, idempotent function of its
  -- input (proven in tests/test_churn.lua). The problem is that its INPUT flaps: a
  -- recorded trace had the Roll the Bones stage readable on only 27% of ticks, and every
  -- flip legitimately reorders the sequence, because a stage-gated rule correctly enters
  -- and leaves the priority walk with it. Correct engine, blinking sensor, no damping.
  --
  -- THE GCD IS THE FRAME RATE OF THE DECISION LOOP. The player cannot act on a change
  -- faster than one press per global cooldown, so a lookahead that changes faster than
  -- that is showing information nobody can use, at the cost of being unreadable. So the
  -- lookahead is committed for the duration of a GCD and only re-derived when something
  -- material happens:
  --
  --   * a new GCD started        -- a press landed; this is the natural decision boundary
  --   * position 1 changed       -- the world moved enough to change the immediate answer
  --   * the hold aged out        -- nothing is happening (out of combat, or idle), so
  --                                 refresh anyway rather than freeze indefinitely
  --
  -- ONLY THE SEQUENCE IS HELD. The cooldown and trinket entries appended after it are
  -- not predictions -- they report something that is ready NOW -- so freezing them would
  -- make the bar lie about live facts.
  local seqHead, seqTail, extras = nil, {}, {}
  for i, entry in ipairs(resultQueue) do
    if entry.isSequence then
      if seqHead == nil then seqHead = entry else table.insert(seqTail, entry) end
    else
      table.insert(extras, entry)
    end
  end

  -- ==========================================================================
  -- THE SEQUENCE IS A PLAN, AND FOLLOWING IT ADVANCES A CURSOR
  -- ==========================================================================
  -- The requirement, in the player's words: "if I press the optimal button I should be
  -- in the optimal sequence -- but it should still check."
  --
  -- That is exactly right, and it falls out of what the sequence already IS. Predict
  -- returns a CAUSAL CHAIN: step 3 is only correct because the simulator spent step 1's
  -- energy, banked its combo points and started its cooldowns. So once the player
  -- actually casts step 1, steps 2..N are still valid BY CONSTRUCTION -- the world moved
  -- to the state we predicted. Re-deriving them from scratch throws away work we already
  -- did and correctly own, and it is why pressing the right button produced a whole new
  -- list instead of the old one sliding left.
  --
  -- So: publish a plan, advance a cursor when the player follows it, and re-plan only
  -- when reality disagrees.
  --
  --   FOLLOWED     cast == plan[cursor]  -> cursor advances. The bar slides left. This
  --                is the common case and it costs nothing.
  --   DEVIATED     cast ~= plan[cursor]  -> the premise of every later step is void.
  --                Re-plan immediately; a plan conditioned on a press that did not
  --                happen is worse than no plan.
  --   SURPRISED    a fresh prediction persistently disagrees with the cursor -> the
  --                world changed under us (a proc landed, a cooldown reset, the target
  --                died). Re-plan. This is the "it should still check" half.
  --   EXHAUSTED    cursor ran off the end -> re-plan.
  --
  -- The disagreement test is deliberately NOT instantaneous. Predict is idempotent, but
  -- its INPUTS blink -- Roll the Bones stage was readable on 27% of ticks before it was
  -- modelled -- and a single tick of disagreement is far more likely to be sensor noise
  -- than a changed world. Requiring the disagreement to persist is what separates
  -- "checking" from "thrashing".
  local now = GetTime()
  local E = Tuono.Engine

  local fresh = {}
  if seqHead then table.insert(fresh, seqHead) end
  for _, entry in ipairs(seqTail) do table.insert(fresh, entry) end

  local plan = E.plan
  local replan, reason = false, nil

  if plan == nil or E.cursor == nil then
    -- Already invalidated, by an event that named its own reason.
    replan, reason = true, E.pendingTrigger or TRIGGER.WORLD
  elseif E.cursor > #plan then
    replan, reason = true, TRIGGER.EXHAUSTED
  end

  -- The world may have moved even though the plan is still nominally valid. Checked
  -- before the disagreement counter because a NAMED cause is strictly better diagnostics
  -- than "the prediction differs" -- both re-plan, but only one tells you why.
  if not replan then
    -- FOLLOWING THE PLAN IS NOT THE WORLD CHANGING. On the tick right after a cast the
    -- player's own press moved combo points and energy, so the resource comparison is
    -- re-baselined rather than evaluated -- otherwise every correct press would re-plan
    -- and the cursor could never advance. Every other trigger still applies here.
    if E.verifyOnAdvance and E.planContext
      and S.comboPointsKnown ~= false and type(S.comboPoints) == "number" then
      E.planContext.cp = S.comboPoints
    end
    local trigger = worldChangedSince(S, E.planContext)
    if trigger then replan, reason = true, trigger end
  end

  if not replan then
    local planned = plan[E.cursor]
    local freshHead = fresh[1] and fresh[1].spellID or nil
    -- A CAST IS THE MOMENT OF MAXIMUM INFORMATION, SO CHECK HARDEST THERE.
    --
    -- The plan assumes the player casts each step PROMPTLY -- the simulator advanced one
    -- GCD per step. Press the right button late (clipped GCD, a moment's hesitation) and
    -- the world has moved further than the plan modelled: energy regenerated, a cooldown
    -- came up, a proc landed. The remaining steps may no longer be optimal even though
    -- the player did exactly the right thing.
    --
    -- So advancing the cursor does not grant the plan immunity. It schedules an immediate
    -- re-check: one tick of disagreement is enough to re-plan right after a cast, where
    -- between casts it takes three. Noise rejection is for quiet periods; a cast boundary
    -- is a real event and disagreement there is real news.
    local needed = E.verifyOnAdvance and 1 or DISAGREE_TICKS_BEFORE_REPLAN
    E.verifyOnAdvance = false

    if planned and freshHead and planned.spellID ~= freshHead then
      E.disagreeTicks = (E.disagreeTicks or 0) + 1
      if E.disagreeTicks >= needed then replan, reason = true, TRIGGER.DISAGREE end
    else
      E.disagreeTicks = 0
      -- The plan and the world agree, so refresh the head's provenance from the fresh
      -- rating rather than showing a rating computed several GCDs ago. The CHOICE is
      -- held; how sure we are about it stays current.
      if planned and fresh[1] then
        planned.confidence = fresh[1].confidence
      end
    end
    -- A plan is a short-lived object. This is a backstop against holding one across
    -- something we failed to notice, not the primary invalidation path.
    if (now - (E.planAt or 0)) > MAX_PLAN_AGE then replan, reason = true, TRIGGER.AGED end
  end

  local seq
  if replan then
    E.plan = fresh
    E.cursor = 1
    E.planAt = now
    E.planContext = snapshotPlanContext(S)
    E.disagreeTicks = 0
    E.verifyOnAdvance = false

    -- One counting site, so an invalidation and the re-plan it caused are one event in
    -- the tally rather than two. Published for /tuono debug and the flight recorder.
    local fired = reason or E.pendingTrigger or TRIGGER.WORLD
    E.pendingTrigger = nil
    E.lastTrigger = fired
    E.lastTriggerAt = now
    E.triggerCounts = E.triggerCounts or {}
    E.triggerCounts[fired] = (E.triggerCounts[fired] or 0) + 1

    seq = fresh
  else
    -- Publish from the cursor onward: the tail the player has not reached yet.
    seq = {}
    for i = E.cursor, #plan do table.insert(seq, plan[i]) end
  end
  -- ==========================================================================
  -- THERE IS ALWAYS AN ANSWER
  -- ==========================================================================
  -- A live trace recorded ten UI errors fired while the queue held NOTHING -- the player
  -- was pressing buttons into a blank bar. An empty bar reads as "the addon is broken",
  -- which is strictly worse than one slightly suboptimal suggestion and worse than an
  -- honest "wait for this", both of which are information.
  --
  -- Two mechanisms already existed to prevent this: the profile's unconditional
  -- last-resort rule, and Predict's pooling fallback which re-runs the list with
  -- affordability suspended. The trace proves they still leave gaps -- the last-resort
  -- rule is itself gated on canAfford, so provable unaffordability empties it, and a
  -- deviation can drop a plan at a moment when Predict returns nothing.
  --
  -- So the guarantee moves here, where it can be enforced rather than hoped for. The
  -- profile names its filler; the engine promises the bar is never blank. Marked
  -- "fallback" so the display renders it as a wait rather than a command -- we are not
  -- claiming it is castable this instant, only that it is what you are waiting for.
  if #seq == 0 then
    local profile = Tuono.Profiles and Tuono.Profiles.Active()
    local key = profile and (profile.fallback or "sinisterStrike")
    local fallbackID = profile and profile.spells and profile.spells[key]
    local known = fallbackID and S.knownSpells and S.knownSpells[fallbackID]
    -- Fail OPEN on an unprobed spell: nil means "never asked", and refusing to show
    -- anything because we did not probe is the unknown-as-no defect in its purest form.
    if fallbackID and (known ~= false or S.knownUnavailable) then
      seq = { {
        spellID = fallbackID,
        source = "fallback",
        kind = "rotation",
        confidence = "fallback",
        step = 1,
        isSequence = true,
      } }
      E.usedFallback = true
    end
  else
    E.usedFallback = false
  end

  E.committedHead = seq[1] and seq[1].spellID or nil

  wipeTable(resultQueue)
  for _, entry in ipairs(seq) do table.insert(resultQueue, entry) end
  for _, entry in ipairs(extras) do table.insert(resultQueue, entry) end

  -- WHAT WE ACTUALLY PUBLISHED, not what we derived before planning.
  --
  -- This assignment used to sit above the plan block, so lastPos1 described the raw
  -- prediction rather than the sequence on screen. Both consumers care about the screen:
  -- the stall detector compares the player's cast against what they were SHOWN, and the
  -- flight recorder files it as `rec`, which is how a trace attributes an error to a
  -- recommendation. Reading the wrong one makes a trace blame the wrong spell.
  local publishedPos1 = resultQueue[1] and resultQueue[1].spellID or nil
  if publishedPos1 ~= Tuono.Engine.lastPos1 then
    Tuono.Engine.stallCount = 0
    Tuono.Engine.lastPos1 = publishedPos1
  end

  -- Step 5: CAP THE SEQUENCE, NEVER THE FACTS BEHIND IT.
  --
  -- This trimmed the tail to 8 entries. The cooldown and trinket advisories are appended
  -- AFTER the sequence, so raising the simulation depth from 4 to 8 filled the cap with
  -- predicted steps and silently deleted every advisory -- the trinket reminder, the
  -- ready-cooldown reminder, all of it. Five legacy behaviour tests caught it.
  --
  -- The two kinds are not interchangeable and must not compete for the same budget. The
  -- sequence is a prediction and can be trimmed without losing a fact; an advisory is a
  -- fact about right now, and dropping it is a lie by omission. So the cap applies to the
  -- sequence alone, and the advisories always survive.
  local trimmed, seqSeen = {}, 0
  for _, entry in ipairs(resultQueue) do
    if entry.isSequence then
      seqSeen = seqSeen + 1
      if seqSeen <= MAX_SEQUENCE_ENTRIES then table.insert(trimmed, entry) end
    else
      table.insert(trimmed, entry)
    end
  end
  wipeTable(resultQueue)
  for i, entry in ipairs(trimmed) do resultQueue[i] = entry end

  return { queue = resultQueue, advisories = resultAdvisories }
end

-- Drop the held lookahead. Combat boundaries are a hard reset: carrying a sequence
-- committed against the last pull into the next one is exactly the staleness this layer
-- must not introduce.
function Tuono.Engine.ResetCommitment()
  Tuono.Engine.InvalidatePlan(Tuono.Engine.TRIGGER.COMBAT)
  Tuono.Engine.planAt = nil
  Tuono.Engine.committedHead = nil
end

Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", Tuono.Engine.ResetCommitment)
Tuono.RegisterEvent("PLAYER_REGEN_DISABLED", Tuono.Engine.ResetCommitment)
Tuono.RegisterEvent("PLAYER_ENTERING_WORLD", Tuono.Engine.ResetCommitment)
