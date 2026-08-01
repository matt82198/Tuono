local ADDON_NAME, OA = ...

OA.Engine = OA.Engine or {}

-- Reusable result tables (allocation-light per contract)
local resultQueue = {}
local resultAdvisories = {}
local tempDedup = {}
local queueSet = {}

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

-- Helper: find spell in queue by spellID
local function findInQueue(queue, spellID)
  for i = 1, #queue do
    if queue[i] == spellID then
      return i
    end
  end
  return nil
end

function OA.Engine.Evaluate()
  wipeTable(resultQueue)
  wipeTable(resultAdvisories)
  wipeSet(tempDedup)
  wipeSet(queueSet)

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
    resultQueue[queueIndex] = { spellID = A.nextSpellID, source = "blizzard" }
    tempDedup[A.nextSpellID] = true
    queueSet[A.nextSpellID] = queueIndex
    queueIndex = queueIndex + 1
  end

  -- Add remaining queue entries (avoid duplicates)
  if A.queue then
    for _, spellID in ipairs(A.queue) do
      if spellID and not tempDedup[spellID] then
        resultQueue[queueIndex] = { spellID = spellID, source = "blizzard" }
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
        -- Handle rule action
        if rule.action == "PIN" then
          if not pinApplied and rule.spellID then
            -- First PIN wins: move or insert at position 1
            local existingPos = queueSet[rule.spellID]
            if existingPos then
              -- Remove from current position
              table.remove(resultQueue, existingPos)
              -- Rebuild queueSet
              wipeSet(queueSet)
              for i, entry in ipairs(resultQueue) do
                queueSet[entry.spellID] = i
              end
            end
            -- Insert at position 1
            table.insert(resultQueue, 1, { spellID = rule.spellID, source = rule.name })
            queueSet[rule.spellID] = 1
            -- Rebuild queueSet after insert
            wipeSet(queueSet)
            for i, entry in ipairs(resultQueue) do
              queueSet[entry.spellID] = i
            end
            pinApplied = true
          end

        elseif rule.action == "PREFER" then
          if rule.spellID then
            local pos = queueSet[rule.spellID]
            if pos and pos > 1 then
              -- Move one slot forward (toward position 1)
              table.remove(resultQueue, pos)
              table.insert(resultQueue, pos - 1, { spellID = rule.spellID, source = rule.name })
              -- Rebuild queueSet
              wipeSet(queueSet)
              for i, entry in ipairs(resultQueue) do
                queueSet[entry.spellID] = i
              end
            elseif not pos then
              -- Not in queue: insert at position 2 (if room)
              if #resultQueue >= 1 then
                table.insert(resultQueue, 2, { spellID = rule.spellID, source = rule.name })
              else
                table.insert(resultQueue, { spellID = rule.spellID, source = rule.name })
              end
              -- Rebuild queueSet
              wipeSet(queueSet)
              for i, entry in ipairs(resultQueue) do
                queueSet[entry.spellID] = i
              end
            end
          end

        elseif rule.action == "ADVISE" then
          resultAdvisories[advisoryIndex] = {
            kind = rule.kind or "generic",
            icon = rule.spellID,
            itemSlot = rule.itemSlot,
            text = rule.desc or "",
            active = true
          }
          advisoryIndex = advisoryIndex + 1
        end
      end
    end
  end

  -- Step 3: Truncate queue to 5
  while #resultQueue > 5 do
    table.remove(resultQueue)
  end

  return { queue = resultQueue, advisories = resultAdvisories }
end
