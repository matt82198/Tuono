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
    if entry.spellID then
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

  -- Step 1: Build base queue from Assist (nextSpellID first, with dedup)
  if not A.available then
    -- Assist unavailable - single advisory
    resultAdvisories[1] = {
      kind = "rtb",
      icon = nil,
      itemSlot = nil,
      text = "Blizzard rotation assist unavailable",
      active = true
    }
    return { queue = resultQueue, advisories = resultAdvisories }
  end

  -- Populate base queue: nextSpellID first, then queue
  local queueIndex = 1
  if A.nextSpellID then
    resultQueue[queueIndex] = { spellID = A.nextSpellID, source = "blizzard", kind = "rotation" }
    tempDedup[A.nextSpellID] = true
    queueSet[A.nextSpellID] = queueIndex
    queueIndex = queueIndex + 1
  end

  -- Add remaining queue entries (avoid duplicates)
  if A.queue then
    for _, spellID in ipairs(A.queue) do
      if spellID and not tempDedup[spellID] then
        resultQueue[queueIndex] = { spellID = spellID, source = "blizzard", kind = "rotation" }
        tempDedup[spellID] = true
        queueSet[spellID] = queueIndex
        queueIndex = queueIndex + 1
      end
    end
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
  local seenSpells = {}
  for i, entry in ipairs(resultQueue) do
    if entry.spellID then
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

  -- Step 4: Truncate queue to 8
  while #resultQueue > 8 do
    table.remove(resultQueue)
  end

  return { queue = resultQueue, advisories = resultAdvisories }
end
