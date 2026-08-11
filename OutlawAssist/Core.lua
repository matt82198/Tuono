local ADDON_NAME, OA = ...

OA.frame = CreateFrame("Frame")
OA.eventHandlers = {}
OA.updateHandlers = {}
OA.errorsSeen = {}
OA.errorCount = 0

-- Module-local flag for forced immediate update (set by event handlers)
local forceNext = false

local function deepMerge(target, source)
  if type(source) ~= "table" then
    return source
  end
  if type(target) ~= "table" then
    target = {}
  end
  for k, v in pairs(source) do
    if type(v) == "table" and type(target[k]) == "table" then
      target[k] = deepMerge(target[k], v)
    else
      if target[k] == nil then
        target[k] = v
      end
    end
  end
  return target
end

function OA.RegisterEvent(event, fn)
  if not OA.eventHandlers[event] then
    OA.eventHandlers[event] = {}
    OA.frame:RegisterEvent(event)
  end
  table.insert(OA.eventHandlers[event], fn)
end

function OA.RegisterUpdate(fn, interval)
  table.insert(OA.updateHandlers, { fn = fn, interval = interval, elapsed = 0 })
end

function OA.RequestImmediateUpdate()
  forceNext = true
end

function OA.print(msg)
  print("|cff00ccffOutlawAssist|r: " .. tostring(msg))
end

function OA.safe(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    local errMsg = tostring(result)
    if not OA.errorsSeen[errMsg] then
      OA.errorsSeen[errMsg] = true
      OA.print("Error: " .. errMsg)
    end
    OA.errorCount = OA.errorCount + 1
    return nil
  end
  return result
end

-- ===== SECRET-VALUE PRIMITIVES =====
-- Midnight (12.0+) hands back "secret" values: they report their real type() but ERROR
-- on arithmetic, comparison, boolean test, length, and table-key use.
--
-- THE BUG THIS REPLACES: OA.num/OA.bool collapsed a secret to a DEFAULT (0 / false).
-- That is fail-SILENT, not fail-closed. Unreadable energy became "0 energy", every
-- affordability check then failed, Rotation.Predict returned an EMPTY sequence, and the
-- bar fell through to a stale Blizzard pick -- the frozen first icon.
--
-- A read must report KNOWN vs UNKNOWN so callers can degrade HONESTLY (drop the gate,
-- lower confidence, say so in the UI) instead of silently pretending the value is zero.

local hasIsSecret = type(_G.issecretvalue) == "function"

function OA.isSecret(v)
  if not hasIsSecret then return false end
  local ok, res = pcall(_G.issecretvalue, v)
  return ok and res == true
end

-- Returns (number, true) when readable; (nil, false) when absent, secret, or wrong type.
function OA.readNum(v)
  if v == nil then return nil, false end
  if OA.isSecret(v) then return nil, false end
  if type(v) == "number" then return v, true end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n, true end
  end
  return nil, false
end

-- Returns (boolean, true) when readable; (nil, false) when absent or secret.
-- NEVER test a secret boolean directly: `if secretBool then` THROWS.
function OA.readBool(v)
  if v == nil then return nil, false end
  if OA.isSecret(v) then return nil, false end
  if type(v) == "boolean" then return v, true end
  return nil, false
end

-- Back-compat coercions, now implemented on top of the tri-state readers. These are
-- still fail-silent by construction, so prefer OA.readNum/OA.readBool anywhere the
-- DIFFERENCE between "zero" and "unreadable" changes a decision.
function OA.num(v, default)
  if default == nil then default = 0 end
  local n, known = OA.readNum(v)
  if known then return n end
  return default
end

function OA.bool(v, default)
  if default == nil then default = false end
  local b, known = OA.readBool(v)
  if known then return b end
  return default
end

function OA.RegisterSlash(subcmd, fn, helptext)
  if not OA.slashCommands then
    OA.slashCommands = {}
  end
  OA.slashCommands[subcmd] = { fn = fn, help = helptext }
end

local function handleSlash(msg)
  local cmd = string.match(msg, "^(%S*)")
  if cmd == "" then
    OA.print("Slash commands:")
    for k, v in pairs(OA.slashCommands or {}) do
      OA.print("  /oa " .. k .. ": " .. (v.help or ""))
    end
    return
  end
  local handler = OA.slashCommands and OA.slashCommands[cmd]
  if handler then
    local args = string.sub(msg, #cmd + 2)
    OA.safe(handler.fn, args)
  else
    OA.print("Unknown command: /oa " .. cmd)
  end
end

SLASH_OUTLAWASSIST1 = "/oa"
SLASH_OUTLAWASSIST2 = "/outlawassist"
SlashCmdList["OUTLAWASSIST"] = handleSlash

OA.frame:SetScript("OnEvent", function(self, event, ...)
  if OA.eventHandlers[event] then
    for _, fn in ipairs(OA.eventHandlers[event]) do
      OA.safe(fn, event, ...)
    end
  end
end)

OA.frame:SetScript("OnUpdate", function(self, elapsed)
  for _, handler in ipairs(OA.updateHandlers) do
    -- Compute dynamic interval: 0.1s in combat (fast), 0.5s idle (slow)
    local dynamicInterval = handler.interval  -- base interval (0.5s idle)
    if OA.State and OA.State.inCombat then
      dynamicInterval = 0.1  -- override to fast in combat
    end

    handler.elapsed = handler.elapsed + elapsed
    -- Run immediately if forceNext, or on throttle timer
    if forceNext or handler.elapsed >= dynamicInterval then
      OA.safe(handler.fn)
      handler.elapsed = 0
    end
  end

  -- Clear forceNext after processing all handlers
  if forceNext then
    forceNext = false
  end
end)

OA.RegisterEvent("ADDON_LOADED", function(event, addonName)
  if addonName ~= ADDON_NAME then return end
  if not OA.defaults then
    OA.defaults = {}
  end
  OutlawAssistDB = deepMerge(OutlawAssistDB or {}, OA.defaults)
  OA.db = OutlawAssistDB
end)

OA.RegisterEvent("PLAYER_LOGIN", function()
  if not OA.defaults then
    OA.defaults = {}
  end
  OutlawAssistDB = deepMerge(OutlawAssistDB or {}, OA.defaults)
  OA.db = OutlawAssistDB

  -- Initialize Display (idempotent; guards against double-init)
  if OA.Display and OA.Display.Init then
    OA.safe(OA.Display.Init)
  end

  -- Initialize Highlight (idempotent; guards against double-init)
  if OA.Highlight and OA.Highlight.Init then
    OA.safe(OA.Highlight.Init)
  end

  -- Register update handler with base idle interval 0.5s; dynamic override to 0.1s in combat
  OA.RegisterUpdate(function()
    -- Each stage is protected INDIVIDUALLY. They used to share one pcall, so a single
    -- error in Display.Render aborted the closure and silently disabled everything
    -- after it -- that is how a bad SetText call turned into "the glow never works".
    if OA.State and OA.State.RefreshFast then
      OA.safe(OA.State.RefreshFast)
    end
    if OA.Assist and OA.Assist.Update then
      OA.safe(OA.Assist.Update)
    end
    local r
    if OA.Engine and OA.Engine.Evaluate then
      r = OA.safe(OA.Engine.Evaluate)
    end
    if OA.Display and OA.Display.Render then
      OA.safe(OA.Display.Render, r)
    end
    if OA.Highlight and OA.Highlight.Update then
      OA.safe(OA.Highlight.Update, r)
    end
  end, 0.5)

  -- Register event-forced re-evaluate triggers
  -- UNIT_SPELLCAST_SUCCEEDED: detect if player cast what was recommended or deviated
  OA.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(event, unit, ...)
    if unit == "player" then
      OA.RequestImmediateUpdate()
    end
  end)

  -- UNIT_SPELLCAST_INTERRUPTED: recover from interrupt, force re-poll for next viable spell
  -- A cast that FAILS (out of range, line of sight, moving, not facing) must force a
  -- re-evaluate. Without this the bar keeps glowing the same unusable button forever --
  -- and a levelling rogue is out of melee range constantly while questing and kiting.
  OA.RegisterEvent("UNIT_SPELLCAST_FAILED", function(event, unit, ...)
    if unit == "player" then
      OA.RequestImmediateUpdate()
    end
  end)

  OA.RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET", function(event, unit, ...)
    if unit == "player" then
      OA.RequestImmediateUpdate()
    end
  end)

  OA.RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", function(event, unit, ...)
    if unit == "player" then
      OA.RequestImmediateUpdate()
    end
  end)

  -- PLAYER_TARGET_CHANGED: target switch invalidates range/threat checks
  OA.RegisterEvent("PLAYER_TARGET_CHANGED", function(event, ...)
    OA.RequestImmediateUpdate()
  end)

  -- SPELL_UPDATE_COOLDOWN: spell availability changed
  OA.RegisterEvent("SPELL_UPDATE_COOLDOWN", function(event, ...)
    OA.RequestImmediateUpdate()
  end)

  -- Load canary: verify all expected module tables are present
  local expectedModules = {"State", "Assist", "Engine", "Rules", "Display", "defaults"}
  local missing = {}
  for _, mod in ipairs(expectedModules) do
    if not OA[mod] then
      table.insert(missing, mod)
    end
  end
  if #missing > 0 then
    OA.print("module(s) failed to load: " .. table.concat(missing, ", ") .. " - run /console scriptErrors 1 and /reload to see the error")
  end

  -- First-run welcome message (print if no saved vars were loaded before login)
  local isFirstRun = (OutlawAssistDB == nil or (not OutlawAssistDB.showedWelcome))
  if isFirstRun then
    OA.print("OutlawAssist v1.0 loaded. Type /oa help for commands or /oa unlock to move the display.")
    if OutlawAssistDB then
      OutlawAssistDB.showedWelcome = true
    end
  end

  -- Spec-gate message if not Outlaw Rogue
  local classToken = select(2, UnitClass("player"))
  local spec = GetSpecialization and GetSpecialization() or nil
  if classToken ~= "ROGUE" or (spec and spec ~= 2) then
    OA.print("This addon only functions on Outlaw Rogue characters. The display will remain hidden on other specs.")
  end
end)

