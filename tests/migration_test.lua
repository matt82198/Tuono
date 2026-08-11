-- Migration from OutlawAssist saved variables.
--
-- The rename keys saved variables to a new addon folder, so without this every
-- existing user silently loses their bar position, scale, glow settings and edited
-- priority rows. These tests pin the four behaviours that matter:
--   1. a fresh install with legacy data present carries it over
--   2. an already-configured Tuono is NEVER overwritten by stale legacy data
--   3. it runs exactly once (idempotent across relogs)
--   4. aoeMode's boolean -> tri-state shape change is translated, not copied raw

local results = { passed = 0, failed = 0 }
local function check(name, cond, detail)
  if cond then
    results.passed = results.passed + 1
    print("PASS: " .. name)
  else
    results.failed = results.failed + 1
    print("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end

_G.GetTime = function() return 1000 end
_G.issecretvalue = function() return false end

-- Minimal harness: we only need Core (event dispatch, deepMerge, safe) plus
-- Migration. Loading the full TOC would drag in frames we do not exercise here.
local function freshEnv()
  local Tuono = {}
  local handlers = {}
  local frame = {
    RegisterEvent = function() end,
    SetScript = function() end,
  }
  _G.CreateFrame = function() return frame end
  _G.SlashCmdList = {}

  -- Core.lua's own registration path, reproduced just enough to fire PLAYER_LOGIN.
  Tuono.eventHandlers = handlers
  Tuono.RegisterEvent = function(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
  end
  Tuono.print = function() end
  Tuono.safe = function(fn, ...)
    local ok, r = pcall(fn, ...)
    if not ok then return nil end
    return r
  end

  local fn = assert(loadfile("Tuono/Migration.lua"))
  fn("Tuono", Tuono)

  Tuono.fire = function(event, ...)
    for _, h in ipairs(handlers[event] or {}) do h(event, ...) end
  end
  return Tuono
end

local function defaults()
  return {
    aoeMode = "auto",
    aoeThreshold = 2,
    show = { queue = true, ooc = true },
    display = { locked = true, scale = 1, point = "CENTER", x = 0, y = -180, iconCount = 4 },
    highlight = { enabled = true, combatOnly = false },
  }
end

-- ---------------------------------------------------------------------------
-- 1. Fresh install + legacy data present -> carried over
-- ---------------------------------------------------------------------------
local T = freshEnv()
T.db = defaults()
T.dbWasFresh = true
_G.OutlawAssistDB = {
  aoeMode = true,                       -- old boolean shape
  show = { queue = false, ooc = true },
  display = { locked = false, scale = 1.4, point = "TOPLEFT", x = 120, y = -300, iconCount = 6 },
  highlight = { enabled = false, combatOnly = true },
  showedWelcome = true,
}
T.fire("PLAYER_LOGIN")

check("carries display position and scale",
  T.db.display.scale == 1.4 and T.db.display.x == 120 and T.db.display.iconCount == 6,
  "scale=" .. tostring(T.db.display.scale) .. " x=" .. tostring(T.db.display.x)
    .. " icons=" .. tostring(T.db.display.iconCount))

check("carries nested booleans that differ from defaults",
  T.db.display.locked == false and T.db.highlight.enabled == false
    and T.db.highlight.combatOnly == true and T.db.show.queue == false,
  "locked=" .. tostring(T.db.display.locked)
    .. " glow=" .. tostring(T.db.highlight.enabled))

check("translates aoeMode boolean true -> \"on\"",
  T.db.aoeMode == "on", "aoeMode=" .. tostring(T.db.aoeMode))

check("stamps migratedFrom so it cannot repeat",
  T.db.migratedFrom == "OutlawAssist", "migratedFrom=" .. tostring(T.db.migratedFrom))

-- ---------------------------------------------------------------------------
-- 2. Idempotence: a second login must not re-import
-- ---------------------------------------------------------------------------
T.db.display.scale = 0.8            -- user changes it AFTER migrating
T.fire("PLAYER_LOGIN")
check("second login does not re-import over user changes",
  T.db.display.scale == 0.8, "scale=" .. tostring(T.db.display.scale))

-- ---------------------------------------------------------------------------
-- 3. Existing Tuono config must never be clobbered
-- ---------------------------------------------------------------------------
local T2 = freshEnv()
T2.db = defaults()
T2.db.display.scale = 2.0
T2.dbWasFresh = false               -- user already had a Tuono DB on disk
_G.OutlawAssistDB = { display = { scale = 0.5 } }
T2.fire("PLAYER_LOGIN")
check("configured Tuono is not overwritten by stale legacy data",
  T2.db.display.scale == 2.0 and T2.db.migratedFrom == nil,
  "scale=" .. tostring(T2.db.display.scale)
    .. " migratedFrom=" .. tostring(T2.db.migratedFrom))

-- ---------------------------------------------------------------------------
-- 4. Fresh install, no legacy addon installed -> clean no-op
-- ---------------------------------------------------------------------------
local T3 = freshEnv()
T3.db = defaults()
T3.dbWasFresh = true
_G.OutlawAssistDB = nil
T3.fire("PLAYER_LOGIN")
check("fresh install with no legacy data is a clean no-op",
  T3.db.migratedFrom == nil and T3.db.aoeMode == "auto",
  "migratedFrom=" .. tostring(T3.db.migratedFrom))

-- ---------------------------------------------------------------------------
-- 5. aoeMode false meant "not currently AoE", which maps to auto, not off
-- ---------------------------------------------------------------------------
local T4 = freshEnv()
T4.db = defaults()
T4.dbWasFresh = true
_G.OutlawAssistDB = { aoeMode = false, display = { scale = 1.1 } }
T4.fire("PLAYER_LOGIN")
check("aoeMode boolean false -> \"auto\" (not \"off\")",
  T4.db.aoeMode == "auto", "aoeMode=" .. tostring(T4.db.aoeMode))

print("")
print(string.format("MIGRATION: %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
