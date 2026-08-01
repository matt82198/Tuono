local ADDON_NAME, OA = ...

OA.Engine = OA.Engine or {}

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

function OA.Engine.Evaluate()
  wipeTable(resultQueue)
  wipeTable(resultAdvisories)
  wipeSet(tempDedup)
  wipeSet(queueSet)
  wipeTable(dedupQueue)

  local S = OA.State
  local A = OA.Assist

  -- COORDINATOR EVIDENCE (live client, 52 samples): Blizzard's GetNextCastSpell is STATIC
  -- in combat — it returns exactly ONE value and never changes, even when combo points max.
  -- ARCHITECTURE: Our Rotation.Predict is THE PRIMARY SOURCE. Blizzard is a fallback.
  --
  -- Step 0: Get our rotation predictions (primary source, independent of Assist)
  local predictions = OA.safe(OA.Rotation.Predict, S, 4)
  local queueIndex = 1
  local hasAssistStatic = false

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

  -- Step 0b: If our predictions are empty AND Assist is available, use Blizzard's pick
  -- as a fallback (marked as unreliable/"static-fallback")
  if #resultQueue == 0 and A.available and A.nextSpellID then
    table.insert(resultQueue, {
      spellID = A.nextSpellID,
      source = "blizzard_static_fallback",
      kind = "rotation",
      confidence = "static-fallback"
    })
    tempDedup[A.nextSpellID] = true
    queueSet[A.nextSpellID] = queueIndex
    queueIndex = queueIndex + 1
    hasAssistStatic = true
  end

  -- Step 0c: If Assist is unavailable, return our predictions as-is (possibly empty)
  -- Empty queue is valid when out of resources; UI shows degraded/empty bar.
  if not A.available and #resultQueue > 0 then
    resultAdvisories[1] = {
      kind = "rtb",
      icon = nil,
      itemSlot = nil,
      text = "Blizzard rotation assist unavailable; using simulator",
      active = true
    }
  end

  -- Diagnostic: store whether Blizzard agrees with our prediction
  -- With static Assist, disagreement is EXPECTED and does NOT indicate our prediction is wrong.
  OA.Engine = OA.Engine or {}
  OA.Engine.assistStatic = hasAssistStatic
  if predictions and #predictions > 0 and A.nextSpellID then
    OA.Engine.blizzAgrees = (predictions[1].spellID == A.nextSpellID)
  end

  -- Step 2: Apply rules in array order
  local pinApplied = false
  local advisoryIndex = #resultAdvisories + 1

  for _, rule in ipairs(OA.Rules or {}) do
    -- Evaluate rule condition safely (skip if no when clause or condition not met)
    if rule.when then
      local condMet = OA.safe(rule.when, S, A)
      if condMet then
        -- Resolve spell ID lazily if needed
        local ruleSpellID = rule.spellID
        if rule.resolveSpellID and not ruleSpellID then
          ruleSpellID = OA.safe(rule.resolveSpellID)
        end

        -- Handle rule action
        if rule.action == "PIN" then
          if not pinApplied and ruleSpellID then
            -- First PIN wins: move or insert at position 1
            local existingPos = queueSet[ruleSpellID]
            if existingPos then
              -- Remove from current position
              table.remove(resultQueue, existingPos)
              rebuildQueueSet()
            end
            -- Insert at position 1
            local pinEntry = { spellID = ruleSpellID, source = rule.name, kind = rule.kind or "rotation", itemSlot = rule.itemSlot }
            table.insert(resultQueue, 1, pinEntry)
            rebuildQueueSet()
            pinApplied = true
          end

        elseif rule.action == "PREFER" then
          if ruleSpellID then
            local pos = queueSet[ruleSpellID]
            if pos and pos > 1 then
              -- Move one slot forward (toward position 1)
              table.remove(resultQueue, pos)
              table.insert(resultQueue, pos - 1, { spellID = ruleSpellID, source = rule.name, kind = rule.kind or "rotation", itemSlot = rule.itemSlot })
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
                spellID = OA.SpellIDs.rollTheBones,
                source = rule.name,
                kind = "rtb",
                itemSlot = nil
              }
              if not queueSet[OA.SpellIDs.rollTheBones] then
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

    -- Position 1 from Blizzard is authoritative, never filter
    if i == 1 and entry.source == "blizzard" then
      skip = false
    else
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
      if not skip and i == 1 and entry.isSequence and entry.spellID then
        local key = OA.Rotation and OA.Rotation.SPELL_TO_CDKEY and OA.Rotation.SPELL_TO_CDKEY[entry.spellID]
        local cd = key and S.cooldowns[key]
        if cd and cd.known and not cd.ready then
          skip = true
        end
      end

      -- For cooldown/trinket entries: verify the cooldown is known and ready
      if not skip and entry.kind == "cooldown" and entry.spellID then
        local cd = S.cooldowns[entry.spellID == OA.SpellIDs.adrenalineRush and "adrenalineRush" or
                              entry.spellID == OA.SpellIDs.bladeRush and "bladeRush" or
                              entry.spellID == OA.SpellIDs.preparation and "preparation" or nil]
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

  -- Step 5: Truncate queue to 8
  while #resultQueue > 8 do
    table.remove(resultQueue)
  end

  return { queue = resultQueue, advisories = resultAdvisories }
end
