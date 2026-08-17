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

  -- SAVED VARIABLES ARE GLOBALS, AND GLOBALS OUTLIVE A LOAD.
  -- The client hands an addon its SavedVariables as real _G entries, so Core's
  -- `TuonoDB = deepMerge(TuonoDB or {}, defaults)` happily adopts the PREVIOUS test's
  -- table -- verified with rawequal: Tuono.db was literally the same table across two
  -- boots. Every assertion about db state was therefore order-dependent, and one suite
  -- saw a user profile already marked customised before it had read anything.
  -- A fresh load must mean a fresh character.
  _G.TuonoDB = nil
  _G.TuonoDiagDB = nil

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
  if opts and opts.inCombat then harness.enterCombat(stub) end
  return Tuono, stub
end

-- COMBAT IS AN EVENT, NOT A FLAG. StateTracker learns it only from
-- PLAYER_REGEN_DISABLED (StateTracker.lua:1002); setting stub.state.inCombat alone
-- leaves the addon believing it is standing around before a pull, which silently turns
-- any combat test into a test of the opener. That produced a queue of
-- Stealth -> Ambush and a trivially stable bar.
function harness.enterCombat(stub)
  stub.state.inCombat = true
  stub.FireEvent("PLAYER_REGEN_DISABLED")
end

function harness.leaveCombat(stub)
  stub.state.inCombat = false
  stub.FireEvent("PLAYER_REGEN_ENABLED")
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
    -- A PLAIN TABLE, pre-populated. It must not auto-vivify, because deepCopyState
    -- clears stale scratch rows with `if srcCD[key] == nil` -- an __index metamethod
    -- makes that test never fire, the simulator's own writes survive into the next
    -- call, and Predict stops being a pure function of its input. That produced a
    -- harness which reported the engine as non-idempotent when the engine was fine.
    cooldowns = (function()
      local t = {}
      for _, key in ipairs({
        "adrenalineRush", "bladeRush", "preparation", "betweenTheEyes", "rollTheBones",
        "sinisterStrike", "bladeFlurry", "stealth", "pistolShot", "ambush",
        "killingSpree", "dispatch", "keepItRolling",
      }) do
        t[key] = { known = true, ready = true, remaining = 0, remainingKnown = true }
      end
      return t
    end)(),
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

-- CAST A SPELL AND MOVE THE WORLD THE WAY THE CLIENT WOULD.
--
-- Firing UNIT_SPELLCAST_SUCCEEDED alone is not a cast: the stub does not simulate the
-- game, so energy, combo points and cooldowns all stay exactly where they were. Any test
-- of "the player followed the plan" that only fires the event is really testing what
-- happens when a cast produces NO effect -- which the engine correctly treats as the
-- world failing to move as predicted, and re-plans.
--
-- That is a genuine and useful behaviour (it is what catches a clipped GCD), so it gets
-- its own test. This helper is for the ordinary case: apply the ability's declared cost,
-- generation and cooldown, then fire the event.
function harness.cast(Tuono, stub, spellID)
  local ab = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[spellID]
  if ab then
    stub.state.energy = math.max(0, stub.state.energy - (ab.cost or 0))
    local spend = ab.cpSpend or 0
    if spend ~= 0 then
      stub.state.comboPoints = 0
    end
    if (ab.cpGen or 0) > 0 then
      stub.state.comboPoints = math.min(stub.state.comboPointsMax,
        stub.state.comboPoints + ab.cpGen)
    end
    if (ab.cd or 0) > 0 then stub.setCooldown(spellID, ab.cd) end
  end
  stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", spellID)
end

-- ---------------------------------------------------------------------------
-- CHURN MEASUREMENT
-- ---------------------------------------------------------------------------
-- "It switches the entire list a lot and it's not smooth" is a feeling. This turns it
-- into a number, so a fix can be shown to work rather than asserted to.
--
-- Drives the engine for `ticks` iterations at `dt` seconds apart and returns the queue
-- seen at each one. `onTick(i, stub, Tuono)` runs BEFORE each evaluation, which is where
-- a scenario injects casts, cooldowns and resource changes.
--
-- `observe(Tuono, stub)` runs AFTER each evaluation and its return value is stored on
-- the frame as `.obs`. Use it to record what the engine actually saw, so a test can
-- prove its input really varied. Poking Tuono.State from onTick does NOT work:
-- harness.evaluate runs State.RefreshFast first and overwrites it, which quietly turns
-- a flapping-input test into a constant-input one.
--
-- `opts.rawEngine` calls Engine.Evaluate WITHOUT the State.RefreshFast that normally
-- precedes it. Use it when the scenario drives Tuono.State directly: RefreshFast
-- re-derives that state from the client every tick and would silently overwrite the
-- input, leaving the test measuring a constant. That is not hypothetical -- it made two
-- earlier tests here vacuous.
function harness.runTicks(Tuono, stub, ticks, dt, onTick, observe, opts)
  local frames = {}
  local raw = opts and opts.rawEngine
  for i = 1, ticks do
    if onTick then onTick(i, stub, Tuono) end
    stub.state.time = stub.state.time + dt
    local result = raw and Tuono.Engine.Evaluate() or harness.evaluate(Tuono)
    local ids = harness.queueIDs(result)
    table.insert(frames, {
      t = stub.state.time,
      ids = ids,
      len = #ids,
      obs = observe and observe(Tuono, stub) or nil,
    })
  end
  return frames
end

-- Prove a driven input actually varied across the run. Without this, a test that claims
-- "flapping X does not move the queue" passes just as happily when X never flapped.
function harness.assertVaried(frames, why)
  local first, varied = nil, false
  for _, f in ipairs(frames) do
    if first == nil then
      first = f.obs
    elseif f.obs ~= first then
      varied = true
      break
    end
  end
  if not varied then
    error({ __testfail = true, msg =
      "vacuous: the observed input never varied across the run -- " .. tostring(why) }, 2)
  end
end

local function sameList(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- Churn statistics over a run of frames.
--
--   tailChanges  positions 2..N differed from the previous frame. This is the number the
--                complaint is about: position 1 is re-derived from ground truth every
--                tick and is SUPPOSED to move, but the lookahead flipping under a
--                stationary player is noise with no information in it.
--   headChanges  position 1 differed. Expected to be non-zero in real combat.
--   lenChanges   the visible length changed, which reads as the bar growing and
--                shrinking even when the contents are right.
function harness.churn(frames)
  local stats = { frames = #frames, tailChanges = 0, headChanges = 0, lenChanges = 0 }
  for i = 2, #frames do
    local prev, cur = frames[i - 1], frames[i]
    if prev.ids[1] ~= cur.ids[1] then stats.headChanges = stats.headChanges + 1 end
    if prev.len ~= cur.len then stats.lenChanges = stats.lenChanges + 1 end

    local prevTail, curTail = {}, {}
    for j = 2, #prev.ids do table.insert(prevTail, prev.ids[j]) end
    for j = 2, #cur.ids do table.insert(curTail, cur.ids[j]) end
    if not sameList(prevTail, curTail) then stats.tailChanges = stats.tailChanges + 1 end
  end
  local span = (#frames > 1) and (frames[#frames].t - frames[1].t) or 1
  stats.span = span
  stats.tailPerSec = stats.tailChanges / span
  stats.headPerSec = stats.headChanges / span
  return stats
end

-- ANTI-VACUITY GUARD. "The lookahead never changed" is trivially true of a lookahead
-- that was never there, so every stability assertion has to prove there was something
-- to be stable. Call this before asserting on churn.
function harness.assertLookahead(frames, minLen)
  minLen = minLen or 2
  for _, f in ipairs(frames) do
    if f.len < minLen then
      error({ __testfail = true, msg = string.format(
        "vacuous: a frame carried only %d entries (need >= %d), so a stability "
        .. "assertion would pass without testing anything", f.len, minLen) }, 2)
    end
  end
end

function harness.describeChurn(stats)
  return string.format(
    "%d frames over %.1fs: tail changed %d (%.2f/s), head changed %d (%.2f/s), length changed %d",
    stats.frames, stats.span, stats.tailChanges, stats.tailPerSec,
    stats.headChanges, stats.headPerSec, stats.lenChanges)
end

return harness
