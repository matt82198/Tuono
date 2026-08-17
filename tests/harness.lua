-- ============================================================================
-- LOAD HARNESS
-- ============================================================================
-- Loads the real addon files, in the real .toc order, against the stub client.
--
-- Reading load order from Tuono.toc rather than a hand-kept list is deliberate: the
-- order IS the contract (profiles must load before Rotation.lua publishes RuleHelpers,
-- and so on), so a test that hardcodes its own order stops testing the thing that
-- actually breaks.
-- ============================================================================

local harness = {}

local function repoRoot()
  -- tests/ sits directly under the repo root. Handle both an absolute source and the
  -- bare relative one you get from `lua tests/run_tests.lua`, where there is no
  -- separator before "tests" for a pattern to anchor on.
  local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
  local dir = src:match("^(.*)/tests/harness%.lua$")
  if dir and dir ~= "" then return dir end
  return "."
end

-- Resolve to an absolute path. Callers strip `root` as a prefix from shell-listed
-- absolute paths, and a relative "." makes that arithmetic silently wrong.
local function absolute(dir)
  if dir:match("^%a:/") or dir:match("^/") then return dir end
  local isWindows = package.config:sub(1, 1) == "\\"
  local pipe = io.popen(isWindows and "cd" or "pwd")
  if not pipe then return dir end
  local cwd = (pipe:read("*l") or ""):gsub("\\", "/"):gsub("/$", "")
  pipe:close()
  if cwd == "" then return dir end
  if dir == "." then return cwd end
  return cwd .. "/" .. dir
end

harness.root = absolute(repoRoot())

function harness.tocFiles()
  local path = harness.root .. "/Tuono.toc"
  local fh = assert(io.open(path, "r"), "cannot open " .. path)
  local files = {}
  for line in fh:lines() do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      table.insert(files, trimmed)
    end
  end
  fh:close()
  return files
end

-- Load the addon fresh. Returns (Tuono, stub).
--
-- Every file is loaded into the SAME private namespace table, exactly as the client
-- does with the addon's shared `...` vararg.
function harness.load(opts)
  opts = opts or {}

  -- Drop any previously loaded stub so state does not leak between tests.
  package.loaded["wow_stub"] = nil
  package.loaded["tests.wow_stub"] = nil

  local stub = dofile(harness.root .. "/tests/wow_stub.lua")
  stub.reset()
  if opts.world then opts.world(stub) end

  local Tuono = {}
  local loaded = {}

  for _, rel in ipairs(harness.tocFiles()) do
    if not (opts.skip and opts.skip[rel]) then
      local path = harness.root .. "/" .. rel
      local chunk, err = loadfile(path)
      if not chunk then
        error("failed to compile " .. rel .. ": " .. tostring(err), 0)
      end
      local ok, loadErr = pcall(chunk, "Tuono", Tuono)
      if not ok then
        error("failed to run " .. rel .. ": " .. tostring(loadErr), 0)
      end
      table.insert(loaded, rel)
    end
  end

  harness.lastLoaded = loaded
  return Tuono, stub
end

-- Bring the addon to a live, logged-in state: saved variables merged, Display and
-- Highlight initialized, the tick handler registered.
function harness.login(Tuono, stub)
  stub.FireEvent("ADDON_LOADED", "Tuono")
  stub.FireEvent("PLAYER_LOGIN")
  stub.FireEvent("PLAYER_ENTERING_WORLD")
  return Tuono, stub
end

-- Load + login in one call, the shape most tests want.
function harness.boot(opts)
  local Tuono, stub = harness.load(opts)
  harness.login(Tuono, stub)
  return Tuono, stub
end

-- Run the engine once and return its result, bypassing the tick throttle. Tests that
-- care about the throttle should drive stub.Tick instead.
function harness.evaluate(Tuono)
  if Tuono.State and Tuono.State.RefreshFast then Tuono.State.RefreshFast() end
  if Tuono.Assist and Tuono.Assist.Update then Tuono.Assist.Update() end
  return Tuono.Engine.Evaluate()
end

-- A hand-built state table in the shape rules and the simulator expect. Defaults are
-- the benign case -- everything readable, nothing on cooldown, in combat -- so a test
-- only has to state the one thing it is actually about.
function harness.fakeState(over)
  local S = {
    energy = 100, energyMax = 100, energyKnown = true, energySource = "measured",
    energyLo = 100, energyHi = 100,
    comboPoints = 0, comboPointsMax = 6, comboPointsKnown = true,
    stealthed = false, inCombat = true,
    enemyCount = 1, enemyCountKnown = true,
    knownSpells = setmetatable({}, { __index = function() return true end }),
    knownUnavailable = false,
    cooldowns = setmetatable({}, {
      __index = function(t, k)
        local row = { known = true, ready = true, remaining = 0, remainingKnown = true }
        rawset(t, k, row)
        return row
      end,
    }),
    trinkets = {},
    buffs = {
      degraded = false,
      rtb = { stage = 4, stageKnown = true, expires = 0, names = {} },
      opportunity = { up = false, stacks = 0, expires = 0 },
      adrenalineRush = { up = false, expires = 0 },
      audacity = { up = false, stacks = 0, expires = 0 },
    },
  }
  for k, v in pairs(over or {}) do S[k] = v end
  return S
end

-- Find a rule by name in one of the active profile's priority lists.
function harness.rule(Tuono, listName, name)
  local profile = Tuono.Profiles.Active()
  for _, r in ipairs(profile[listName] or {}) do
    if r.name == name then return r end
  end
  return nil
end

-- The queue as a plain array of spellIDs, which is what most assertions are about.
function harness.queueIDs(result)
  local out = {}
  for _, entry in ipairs((result and result.queue) or {}) do
    table.insert(out, entry.spellID or ("item:" .. tostring(entry.itemSlot)))
  end
  return out
end

return harness
