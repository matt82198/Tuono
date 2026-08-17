-- ============================================================================
-- NO RUNTIME CODE GENERATION
-- ============================================================================
-- The worst security incidents in the WoW addon ecosystem have all been the same
-- shape: an addon accepts a shareable string, and somewhere in the import path that
-- string reaches an evaluator. WeakAuras has shipped this class of bug more than once,
-- and the blast radius is total -- a player pastes a string from a Discord and the
-- author of that string runs code inside their client.
--
-- Tuono is currently immune BY ARCHITECTURE, not by intent: UserRules rows are
-- declarative data compiled by our own interpreter, so there has never been a reason to
-- evaluate a string. That is a property worth making load-bearing before profile
-- import/export lands (docs/FRAMEWORK.md puts base64 import strings on the roadmap),
-- because the tempting shortcut when implementing import is exactly `loadstring(cond)`.
--
-- This gate fails the build if any shipping file gains the ability to execute a string.
-- It is deliberately absolute: there is no legitimate use for these in this addon, and
-- an allowlist here would be the first step of the incident.
-- ============================================================================

local harness = require("harness")

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local s = fh:read("*a")
  fh:close()
  return s
end

-- Blank comments and string literals so a mention in prose is not a finding. Offsets are
-- preserved so reported line numbers stay true.
local function stripNonCode(src)
  local out = src
  out = out:gsub("%-%-%[(=*)%[.-%]%1%]", function(s) return (" "):rep(#s) end)
  out = out:gsub("%-%-[^\n]*", function(s) return (" "):rep(#s) end)
  out = out:gsub('"[^"\n]*"', function(s) return (" "):rep(#s) end)
  out = out:gsub("'[^'\n]*'", function(s) return (" "):rep(#s) end)
  return out
end

local function lines(s)
  local t = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = line end
  return t
end

-- Every one of these turns data into code, or reaches outside the addon sandbox.
local FORBIDDEN = {
  { pattern = "%f[%w_]loadstring%s*%(", why = "loadstring executes a string as code" },
  { pattern = "%f[%w_]load%s*%(",       why = "load() executes a string or chunk as code" },
  { pattern = "%f[%w_]dofile%s*%(",     why = "dofile executes a file" },
  { pattern = "%f[%w_]loadfile%s*%(",   why = "loadfile compiles a file into a chunk" },
  { pattern = "%f[%w_]RunScript%s*%(",  why = "RunScript executes a string as code" },
  { pattern = "%f[%w_]setfenv%s*%(",    why = "setfenv re-parents an environment" },
  { pattern = "%f[%w_]getfenv%s*%(",    why = "getfenv reaches the global environment" },
  { pattern = "ChatFrame%d*EditBox",    why = "driving the edit box can execute /run" },
}

local function scan()
  local findings = {}
  for _, rel in ipairs(harness.tocFiles()) do
    if rel:match("%.lua$") then
      local src = readFile(harness.root .. "/" .. rel)
      if src then
        local code = lines(stripNonCode(src))
        for i, line in ipairs(code) do
          for _, rule in ipairs(FORBIDDEN) do
            if line:find(rule.pattern) then
              findings[#findings + 1] = string.format("%s:%d  %s", rel, i, rule.why)
            end
          end
        end
      end
    end
  end
  table.sort(findings)
  return findings
end

describe("no runtime code generation", function()
  it("no shipping file can execute a string", function()
    local found = scan()
    expect.listEqual(found, {},
      "an addon that can evaluate a string can be made to evaluate a SHARED string; "
        .. "see the header of this file")
  end)

  it("actually scanned the addon (a lint over zero files is not a pass)", function()
    -- The gate above passes trivially if tocFiles() ever returns nothing, which is
    -- exactly how a security check quietly stops being one.
    expect.truthy(#harness.tocFiles() >= 15, "expected the full .toc")
  end)

  it("detects the pattern it exists to prevent", function()
    -- Self-test. A gate nobody has watched fail is a gate nobody knows works: this pins
    -- that the matcher fires on real code and not on the word appearing in a comment.
    local code = lines(stripNonCode('local f = loadstring(userSuppliedString)'))
    expect.truthy(code[1]:find("%f[%w_]loadstring%s*%("), "matcher failed on live code")

    local prose = lines(stripNonCode('-- we must never call loadstring(x) here'))
    expect.falsy(prose[1]:find("%f[%w_]loadstring%s*%("), "matcher fired inside a comment")

    local str = lines(stripNonCode('local msg = "do not use loadstring(x)"'))
    expect.falsy(str[1]:find("%f[%w_]loadstring%s*%("), "matcher fired inside a string")
  end)
end)
