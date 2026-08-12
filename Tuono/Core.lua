local ADDON_NAME, Tuono = ...

Tuono.frame = CreateFrame("Frame")
Tuono.eventHandlers = {}
Tuono.updateHandlers = {}
Tuono.errorsSeen = {}
Tuono.errorCount = 0

-- Module-local flag for forced immediate update (set by event handlers)
local forceNext = false

-- Floor on how far a forced update may jump the throttle. ~33Hz ceiling.
local MIN_FORCED_GAP = 0.03

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

function Tuono.RegisterEvent(event, fn)
  if not Tuono.eventHandlers[event] then
    Tuono.eventHandlers[event] = {}
  end
  -- Register on the FRAME every time rather than only when the handler table is new.
  -- RegisterEvent is idempotent on the frame, and the old guard meant anything that
  -- inserted into eventHandlers directly (ApiTest did) permanently prevented the event
  -- from ever being registered for the rest of the session.
  Tuono.frame:RegisterEvent(event)
  table.insert(Tuono.eventHandlers[event], fn)
end

-- UNIT events fire for EVERY unit in your group and every nameplate. Registering them
-- broadly means UNIT_AURA alone dispatches thousands of times a second in a raid pull,
-- each one allocating a vararg and running a pcall per handler, only to be discarded by
-- a `unit == "player"` check inside the handler. RegisterUnitEvent filters in the
-- engine, before any of that.
function Tuono.RegisterUnitEvent(event, unit, fn)
  if not Tuono.eventHandlers[event] then
    Tuono.eventHandlers[event] = {}
  end
  if Tuono.frame.RegisterUnitEvent then
    Tuono.frame:RegisterUnitEvent(event, unit or "player")
  else
    Tuono.frame:RegisterEvent(event)
  end
  table.insert(Tuono.eventHandlers[event], fn)
end

function Tuono.RegisterUpdate(fn, interval)
  table.insert(Tuono.updateHandlers, { fn = fn, interval = interval, elapsed = 0 })
end

function Tuono.RequestImmediateUpdate()
  forceNext = true
end

function Tuono.print(msg)
  print("|cff00ccffTuono|r: " .. tostring(msg))
end

function Tuono.safe(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    local errMsg = tostring(result)
    if not Tuono.errorsSeen[errMsg] then
      Tuono.errorsSeen[errMsg] = true
      Tuono.print("Error: " .. errMsg)
    end
    Tuono.errorCount = Tuono.errorCount + 1
    return nil
  end
  return result
end

-- ===== SECRET-VALUE PRIMITIVES =====
-- Midnight (12.0+) hands back "secret" values: they report their real type() but ERROR
-- on arithmetic, comparison, boolean test, length, and table-key use.
--
-- THE BUG THIS REPLACES: Tuono.num/Tuono.bool collapsed a secret to a DEFAULT (0 / false).
-- That is fail-SILENT, not fail-closed. Unreadable energy became "0 energy", every
-- affordability check then failed, Rotation.Predict returned an EMPTY sequence, and the
-- bar fell through to a stale Blizzard pick -- the frozen first icon.
--
-- A read must report KNOWN vs UNKNOWN so callers can degrade HONESTLY (drop the gate,
-- lower confidence, say so in the UI) instead of silently pretending the value is zero.

local hasIsSecret = type(_G.issecretvalue) == "function"

function Tuono.isSecret(v)
  if not hasIsSecret then return false end
  local ok, res = pcall(_G.issecretvalue, v)
  return ok and res == true
end

-- Returns (number, true) when readable; (nil, false) when absent, secret, or wrong type.
function Tuono.readNum(v)
  if v == nil then return nil, false end
  if Tuono.isSecret(v) then return nil, false end
  if type(v) == "number" then return v, true end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n, true end
  end
  return nil, false
end

-- Returns (boolean, true) when readable; (nil, false) when absent or secret.
-- NEVER test a secret boolean directly: `if secretBool then` THROWS.
function Tuono.readBool(v)
  if v == nil then return nil, false end
  if Tuono.isSecret(v) then return nil, false end
  if type(v) == "boolean" then return v, true end
  return nil, false
end

-- Back-compat coercions, now implemented on top of the tri-state readers. These are
-- still fail-silent by construction, so prefer Tuono.readNum/Tuono.readBool anywhere the
-- DIFFERENCE between "zero" and "unreadable" changes a decision.
function Tuono.num(v, default)
  if default == nil then default = 0 end
  local n, known = Tuono.readNum(v)
  if known then return n end
  return default
end

function Tuono.bool(v, default)
  if default == nil then default = false end
  local b, known = Tuono.readBool(v)
  if known then return b end
  return default
end

function Tuono.RegisterSlash(subcmd, fn, helptext)
  if not Tuono.slashCommands then
    Tuono.slashCommands = {}
  end
  Tuono.slashCommands[subcmd] = { fn = fn, help = helptext }
end

local function handleSlash(msg)
  local cmd = string.match(msg, "^(%S*)")
  if cmd == "" then
    Tuono.print("Slash commands:")
    for k, v in pairs(Tuono.slashCommands or {}) do
      Tuono.print("  /tuono " .. k .. ": " .. (v.help or ""))
    end
    return
  end
  local handler = Tuono.slashCommands and Tuono.slashCommands[cmd]
  if handler then
    local args = string.sub(msg, #cmd + 2)
    Tuono.safe(handler.fn, args)
  else
    Tuono.print("Unknown command: /tuono " .. cmd)
  end
end

SLASH_TUONO1 = "/tuono"
SLASH_TUONO2 = "/tu"
SLASH_TUONO3 = "/oa"
SlashCmdList["TUONO"] = handleSlash

Tuono.frame:SetScript("OnEvent", function(self, event, ...)
  if Tuono.eventHandlers[event] then
    for _, fn in ipairs(Tuono.eventHandlers[event]) do
      Tuono.safe(fn, event, ...)
    end
  end
end)

Tuono.frame:SetScript("OnUpdate", function(self, elapsed)
  for _, handler in ipairs(Tuono.updateHandlers) do
    -- Compute dynamic interval: 0.1s in combat (fast), 0.5s idle (slow)
    local dynamicInterval = handler.interval  -- base interval (0.5s idle)
    if Tuono.State and Tuono.State.inCombat then
      dynamicInterval = 0.1  -- override to fast in combat
    end

    handler.elapsed = handler.elapsed + elapsed

    -- forceNext used to BYPASS the throttle entirely. Several events set it -- and
    -- SPELL_UPDATE_COOLDOWN alone fires many times per GCD in real combat -- so in a
    -- busy pull the "0.1s throttle" was really running at frame rate. The advertised
    -- 10Hz was fiction.
    --
    -- Now an event can only pull the next tick FORWARD, never produce an unbounded
    -- one. Worst case is ~30Hz instead of 144Hz on a fast machine.
    if forceNext then
      handler.elapsed = math.max(handler.elapsed, dynamicInterval - MIN_FORCED_GAP)
    end

    if handler.elapsed >= dynamicInterval then
      Tuono.safe(handler.fn)
      -- Carry the overshoot instead of discarding it, so the effective period is the
      -- nominal one rather than nominal-plus-a-frame, drifting with frame time.
      handler.elapsed = handler.elapsed - dynamicInterval
      if handler.elapsed > dynamicInterval then handler.elapsed = 0 end
    end
  end

  -- Clear forceNext after processing all handlers
  if forceNext then
    forceNext = false
  end
end)

Tuono.RegisterEvent("ADDON_LOADED", function(event, addonName)
  if addonName ~= ADDON_NAME then return end
  if not Tuono.defaults then
    Tuono.defaults = {}
  end

  -- MIGRATION SIGNAL. Capture emptiness BEFORE defaults are merged in: one line later
  -- every fresh DB is indistinguishable from a configured one, because deepMerge has
  -- filled it with the default tree. Migration.lua reads this at PLAYER_LOGIN, which is
  -- the earliest point where the OLD addon is guaranteed to have loaded its own saved
  -- variables into the global environment.
  Tuono.dbWasFresh = (TuonoDB == nil) or (next(TuonoDB) == nil)

  TuonoDB = deepMerge(TuonoDB or {}, Tuono.defaults)
  Tuono.db = TuonoDB
end)

Tuono.RegisterEvent("PLAYER_LOGIN", function()
  if not Tuono.defaults then
    Tuono.defaults = {}
  end
  TuonoDB = deepMerge(TuonoDB or {}, Tuono.defaults)
  Tuono.db = TuonoDB

  -- Initialize Display (idempotent; guards against double-init)
  if Tuono.Display and Tuono.Display.Init then
    Tuono.safe(Tuono.Display.Init)
  end

  -- Initialize Highlight (idempotent; guards against double-init)
  if Tuono.Highlight and Tuono.Highlight.Init then
    Tuono.safe(Tuono.Highlight.Init)
  end

  -- Register update handler with base idle interval 0.5s; dynamic override to 0.1s in combat
  Tuono.RegisterUpdate(function()
    -- CLASS/SPEC GATE, FIRST THING. Only Display.Render checked this, and it checked
    -- AFTER RefreshFast, Assist.Update, a full 4-step Predict and Highlight.Update had
    -- already run. Since ResolveForPlayer leaves the first-registered profile active
    -- when nothing matches, a Mage was running an Outlaw simulation every tick -- and
    -- Highlight then failed to find any of those spells on the bar, hitting the
    -- uncached 120-slot sweep forever. Bail before doing any work.
    if Tuono.Profiles and not Tuono.Profiles.MatchesPlayer() then
      if Tuono.Display and Tuono.Display.anchor then Tuono.Display.anchor:Hide() end
      return
    end

    -- Each stage is protected INDIVIDUALLY. They used to share one pcall, so a single
    -- error in Display.Render aborted the closure and silently disabled everything
    -- after it -- that is how a bad SetText call turned into "the glow never works".
    if Tuono.State and Tuono.State.RefreshFast then
      Tuono.safe(Tuono.State.RefreshFast)
    end
    if Tuono.Assist and Tuono.Assist.Update then
      Tuono.safe(Tuono.Assist.Update)
    end
    local r
    if Tuono.Engine and Tuono.Engine.Evaluate then
      r = Tuono.safe(Tuono.Engine.Evaluate)
    end
    if Tuono.Display and Tuono.Display.Render then
      Tuono.safe(Tuono.Display.Render, r)
    end
    if Tuono.Highlight and Tuono.Highlight.Update then
      Tuono.safe(Tuono.Highlight.Update, r)
    end
    -- Flight recorder last: it observes the tick's outcome, and must never be able to
    -- affect it. Self-throttled internally.
    if Tuono.Recorder and Tuono.Recorder.Snapshot then
      Tuono.safe(Tuono.Recorder.Snapshot)
    end
  end, 0.5)

  -- Register event-forced re-evaluate triggers
  -- UNIT_SPELLCAST_SUCCEEDED: detect if player cast what was recommended or deviated
  Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, ...)
    if unit == "player" then
      Tuono.RequestImmediateUpdate()
    end
  end)

  -- UNIT_SPELLCAST_INTERRUPTED: recover from interrupt, force re-poll for next viable spell
  -- A cast that FAILS (out of range, line of sight, moving, not facing) must force a
  -- re-evaluate. Without this the bar keeps glowing the same unusable button forever --
  -- and a levelling rogue is out of melee range constantly while questing and kiting.
  Tuono.RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", function(event, unit, ...)
    if unit == "player" then
      Tuono.RequestImmediateUpdate()
    end
  end)

  Tuono.RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "player", function(event, unit, ...)
    if unit == "player" then
      Tuono.RequestImmediateUpdate()
    end
  end)

  Tuono.RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", function(event, unit, ...)
    if unit == "player" then
      Tuono.RequestImmediateUpdate()
    end
  end)

  -- PLAYER_TARGET_CHANGED: target switch invalidates range/threat checks
  Tuono.RegisterEvent("PLAYER_TARGET_CHANGED", function(event, ...)
    Tuono.RequestImmediateUpdate()
  end)

  -- SPELL_UPDATE_COOLDOWN: spell availability changed
  Tuono.RegisterEvent("SPELL_UPDATE_COOLDOWN", function(event, ...)
    Tuono.RequestImmediateUpdate()
  end)

  -- Load canary: verify all expected module tables are present
  local expectedModules = {"State", "Assist", "Engine", "Rules", "Display", "defaults"}
  local missing = {}
  for _, mod in ipairs(expectedModules) do
    if not Tuono[mod] then
      table.insert(missing, mod)
    end
  end
  if #missing > 0 then
    Tuono.print("module(s) failed to load: " .. table.concat(missing, ", ") .. " - run /console scriptErrors 1 and /reload to see the error")
  end

  -- First-run welcome message (print if no saved vars were loaded before login)
  local isFirstRun = (TuonoDB == nil or (not TuonoDB.showedWelcome))
  if isFirstRun then
    Tuono.print("Tuono v2.0 loaded. Type /tuono help for commands or /tuono unlock to move the display.")
    if TuonoDB then
      TuonoDB.showedWelcome = true
    end
  end

  -- Spec-gate message if not Outlaw Rogue
  local classToken = select(2, UnitClass("player"))
  local spec = GetSpecialization and GetSpecialization() or nil
  if classToken ~= "ROGUE" or (spec and spec ~= 2) then
    Tuono.print("This addon only functions on Outlaw Rogue characters. The display will remain hidden on other specs.")
  end
end)

