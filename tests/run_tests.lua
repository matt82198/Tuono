-- ============================================================================
-- TEST RUNNER
-- ============================================================================
--   lua tests/run_tests.lua            run everything
--   lua tests/run_tests.lua rotation   run only suites whose name matches
--
-- Exit code is non-zero on any failure, so this is usable as a gate.
-- ============================================================================

-- `lua tests/run_tests.lua` yields a source with no separator before "tests", so a
-- pattern anchored on one silently leaves root as the whole path and every suite file
-- then fails to open. A gate that skips silently is worse than no gate, so this
-- normalizes both forms and the runner asserts below that suites were actually found.
local function scriptRoot()
  local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
  local dir = src:match("^(.*)/tests/run_tests%.lua$")
  if dir and dir ~= "" then return dir end
  return "."
end

local root = scriptRoot()
package.path = root .. "/tests/?.lua;" .. package.path

local T = {}
T.suites = {}

local currentSuite = nil

function describe(name, fn)
  currentSuite = { name = name, tests = {} }
  table.insert(T.suites, currentSuite)
  fn()
  currentSuite = nil
end

function it(name, fn)
  assert(currentSuite, "it() outside describe()")
  table.insert(currentSuite.tests, { name = name, fn = fn })
end

-- --- assertions -------------------------------------------------------------

local function fail(msg, level)
  error({ __testfail = true, msg = msg }, (level or 2) + 1)
end

local function render(v)
  if type(v) == "table" then
    local parts = {}
    for _, x in ipairs(v) do table.insert(parts, tostring(x)) end
    if #parts > 0 then return "[" .. table.concat(parts, ", ") .. "]" end
    local keys = {}
    for k, x in pairs(v) do table.insert(keys, tostring(k) .. "=" .. tostring(x)) end
    table.sort(keys)
    return "{" .. table.concat(keys, ", ") .. "}"
  end
  return tostring(v)
end

expect = {}

function expect.equal(actual, want, why)
  if actual ~= want then
    fail(string.format("expected %s, got %s%s", render(want), render(actual),
      why and ("  -- " .. why) or ""))
  end
end

function expect.truthy(v, why)
  if not v then fail("expected truthy, got " .. render(v) .. (why and ("  -- " .. why) or "")) end
end

function expect.falsy(v, why)
  if v then fail("expected falsy, got " .. render(v) .. (why and ("  -- " .. why) or "")) end
end

function expect.listEqual(actual, want, why)
  local same = #actual == #want
  if same then
    for i = 1, #want do
      if actual[i] ~= want[i] then same = false break end
    end
  end
  if not same then
    fail(string.format("expected %s, got %s%s", render(want), render(actual),
      why and ("  -- " .. why) or ""))
  end
end

function expect.contains(list, value, why)
  for _, v in ipairs(list) do
    if v == value then return end
  end
  fail("expected " .. render(list) .. " to contain " .. render(value)
    .. (why and ("  -- " .. why) or ""))
end

function expect.notContains(list, value, why)
  for _, v in ipairs(list) do
    if v == value then
      fail("expected " .. render(list) .. " NOT to contain " .. render(value)
        .. (why and ("  -- " .. why) or ""))
    end
  end
end

function expect.noThrow(fn, why)
  local ok, err = pcall(fn)
  if not ok then
    fail("expected no error, got: " .. tostring(err) .. (why and ("  -- " .. why) or ""))
  end
end

-- --- discovery --------------------------------------------------------------

local SUITE_FILES = {
  "toc_check.lua",
  "lint_lua51.lua",
  "lint_secrets.lua",
  "lint_codegen.lua",
  "test_load.lua",
  "test_energy.lua",
  "test_rotation.lua",
  "test_mode.lua",
  "test_profile.lua",
  "test_cooldown.lua",
  "test_statetracker.lua",
  "test_recorder.lua",
  "test_observers.lua",
  "test_userrules.lua",
  "test_display.lua",
  "test_highlight.lua",
  "test_fallback.lua",
  "test_confidence.lua",
  "test_triggers.lua",
  "test_timeline.lua",
  "test_apl.lua",
  "test_churn.lua",
}

local filter = ...

local found = 0
for _, f in ipairs(SUITE_FILES) do
  local path = root .. "/tests/" .. f
  local fh = io.open(path, "r")
  if fh then
    fh:close()
    dofile(path)
    found = found + 1
  end
end

-- Fail closed. Zero suites means a broken path or a renamed file, not a green run.
if found == 0 then
  io.write("no suite files found under " .. root .. "/tests/ -- refusing to report green\n")
  os.exit(2)
end

-- --- run --------------------------------------------------------------------

local passed, failed, skipped = 0, 0, 0
local failures = {}

local GREEN, RED, DIM, RESET = "", "", "", ""
if os.getenv("NO_COLOR") == nil then
  GREEN, RED, DIM, RESET = "\27[32m", "\27[31m", "\27[90m", "\27[0m"
end

for _, suite in ipairs(T.suites) do
  if filter and not suite.name:lower():find(filter:lower(), 1, true) then
    skipped = skipped + #suite.tests
  else
    io.write(suite.name, "\n")
    for _, test in ipairs(suite.tests) do
      local ok, err = pcall(test.fn)
      if ok then
        passed = passed + 1
        io.write(DIM, "  ok   ", RESET, test.name, "\n")
      else
        failed = failed + 1
        local msg
        if type(err) == "table" and err.__testfail then
          msg = err.msg
        else
          msg = tostring(err)
        end
        io.write(RED, "  FAIL ", RESET, test.name, "\n")
        io.write("         ", msg, "\n")
        table.insert(failures, suite.name .. " :: " .. test.name .. "\n         " .. msg)
      end
    end
  end
end

io.write("\n")
-- ============================================================================
-- LEGACY SUITES
-- ============================================================================
-- These predate the describe/it driver and share ONE addon instance across every
-- assertion, mutating Tuono.State directly. That is why they run as SUBPROCESSES rather
-- than being loaded here: their global mutation would leak into the isolated suites
-- above, and they call os.exit() on completion, which would kill this runner.
--
-- Running them out-of-process preserves their semantics exactly and folds their counts
-- into one total, so `lua tests/run_tests.lua` really does run everything. Before this
-- merge the 77 secret-value regressions and both scenarios were never reached by the
-- entry point at all -- you had to know to invoke them by hand.
local NL = string.char(10)
local LEGACY = {
  { file = "tests/legacy_behaviour.lua",   name = "legacy: behaviour" },
  { file = "tests/secrets_regression.lua", name = "legacy: secret-value regressions" },
  { file = "tests/migration_test.lua",     name = "legacy: OutlawAssist migration" },
  { file = "tests/scenario_bar.lua",       name = "legacy: scenario (levelling rogue)" },
  { file = "tests/scenario_fresh80.lua",   name = "legacy: scenario (fresh 80)" },
}

local legacyPassed, legacyFailed = 0, 0

local function runLegacy(entry)
  local fh = io.open(entry.file, "r")
  if not fh then return end
  fh:close()

  local pipe = io.popen('lua "' .. entry.file .. '" 2>&1')
  if not pipe then return end
  local out = pipe:read("*a") or ""
  local ok = pipe:close()

  -- Parse whichever tally the suite prints. Both legacy formats are covered; if neither
  -- matches, fall back to the exit status so a suite can never pass silently.
  local p, total = out:match("(%d+)%s*/%s*(%d+) tests passed")
  local f
  if p then
    p, total = tonumber(p), tonumber(total)
    f = total - p
  else
    local a, b = out:match("(%d+) passed,%s*(%d+) failed")
    p, f = tonumber(a), tonumber(b)
  end
  if not p then
    p, f = (ok and 1 or 0), (ok and 0 or 1)
  end

  legacyPassed = legacyPassed + p
  legacyFailed = legacyFailed + f

  io.write(entry.name, NL)
  if f == 0 then
    io.write(DIM, "  ok   ", RESET, tostring(p), " assertions", NL)
  else
    io.write(RED, "  FAIL ", RESET, tostring(f), " of ", tostring(p + f), " failing", NL)
    local shown = 0
    for line in out:gmatch("[^" .. string.char(13, 10) .. "]+") do
      if line:match("^FAIL") and shown < 8 then
        io.write("         ", line:sub(1, 140), NL)
        shown = shown + 1
      end
    end
  end
end

if not filter or ("legacy"):find(filter:lower(), 1, true) then
  for _, entry in ipairs(LEGACY) do runLegacy(entry) end
end

passed = passed + legacyPassed
failed = failed + legacyFailed

if failed == 0 then
  io.write(GREEN, string.format("%d passed", passed), RESET)
else
  io.write(RED, string.format("%d failed, %d passed", failed, passed), RESET)
end
if skipped > 0 then io.write(string.format(", %d skipped", skipped)) end
io.write("\n")

os.exit(failed == 0 and 0 or 1)
