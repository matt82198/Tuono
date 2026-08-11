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

Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, castGUID, spellID)
  if unit ~= "player" then return end
  local id = Tuono.readNum(spellID)
  if not id then return end
  local recommended = Tuono.Engine.lastPos1
  if recommended and id ~= recommended then
    Tuono.Engine.stallCount = (Tuono.Engine.stallCount or 0) + 1
  else
    Tuono.Engine.stallCount = 0
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
  local predictions = Tuono.safe(Tuono.Rotation.Predict, S, 4)
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

        -- Handle rule action
        if rule.action == "PIN" then
          if not pinApplied and ruleSpellID then
            -- First PIN wins: move or insert at position 1
            -- MOVE the existing entry, never rebuild it. Rebuilding dropped every field
            -- the rule does not know about -- `isSequence`, so Step 3 dedup then
            -- collapsed a legitimate "Sinister Strike x4" back into one icon, and
            -- `confidence`, so Display defaulted it to "high" and a pooling pick
            -- rendered at full alpha as though it were castable now. Three separately
            -- documented fixes were being silently undone here.
            local existingPos = queueSet[ruleSpellID]
            local pinEntry
            if existingPos then
              pinEntry = table.remove(resultQueue, existingPos)
              pinEntry.source = rule.name
              if rule.kind then pinEntry.kind = rule.kind end
              if rule.itemSlot then pinEntry.itemSlot = rule.itemSlot end
            else
              pinEntry = { spellID = ruleSpellID, source = rule.name,
                           kind = rule.kind or "rotation", itemSlot = rule.itemSlot }
            end
            table.insert(resultQueue, 1, pinEntry)
            rebuildQueueSet()
            pinApplied = true
          end

        elseif rule.action == "PREFER" then
          if ruleSpellID then
            local pos = queueSet[ruleSpellID]
            if pos and pos > 1 then
              -- Move the existing entry forward; see the PIN branch above for why
              -- rebuilding it here silently destroyed isSequence and confidence.
              local moved = table.remove(resultQueue, pos)
              moved.source = rule.name
              if rule.kind then moved.kind = rule.kind end
              if rule.itemSlot then moved.itemSlot = rule.itemSlot end
              table.insert(resultQueue, pos - 1, moved)
              rebuildQueueSet()
            elseif not pos then
              -- Not in queue: insert at position 2 (if room)
              if #resultQueue >= 1 then
                table.insert(resultQueue, 2, { spellID = ruleSpellID, source = rule.name, kind = rule.kind or "rotation", itemSlot = rule.itemSlot })
              else
                table.insert(resultQueue, { spellID = ruleSpellID, source = rule.name, kind = rule.kind or "rotation", itemSlot = rule.itemSlot })
              end
              rebuildQueueSet()
            end
          end

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
            -- RtB entry
            if S.buffs.rtb.stage == 0 then
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

  -- Remember what we are about to recommend, so the stall detector can compare the
  -- player's next cast against it. Reset the counter when the recommendation CHANGES:
  -- a stall is "same advice, repeatedly ignored", not "advice that happens to differ
  -- from what you pressed once".
  local newPos1 = resultQueue[1] and resultQueue[1].spellID or nil
  if newPos1 ~= Tuono.Engine.lastPos1 then
    Tuono.Engine.stallCount = 0
    Tuono.Engine.lastPos1 = newPos1
  end

  -- Step 5: Truncate queue to 8
  while #resultQueue > 8 do
    table.remove(resultQueue)
  end

  return { queue = resultQueue, advisories = resultAdvisories }
end
