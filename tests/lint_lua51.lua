-- ============================================================================
-- LUA 5.1 COMPATIBILITY LINT
-- ============================================================================
-- The harness runs on whatever `lua` is installed (5.4 here). WoW runs 5.1. 5.4 is
-- largely a superset, so the harness happily ACCEPTS syntax and library calls the game
-- will reject at load. That is a false green, and a false green is worse than no test:
-- it converts "untested" into "verified" without changing anything.
--
-- This scans the files the .toc actually loads and fails on anything newer than 5.1.
-- The check runs against source with comments and string literals blanked out, because
-- a lint that fires on the word "goto" inside a comment gets disabled, and a disabled
-- lint is the same as no lint.
-- ============================================================================

local harness = require("harness")

local function readFile(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local s = fh:read("*a")
  fh:close()
  return s
end

-- Blank out comments and string literals, preserving byte offsets and newlines so
-- reported line numbers still point at the real source. Returns the blanked code plus
-- the string literals that were removed, which get their own escape-sequence check.
local function strip(src)
  local out, strings = {}, {}
  local i, n = 1, #src

  while i <= n do
    local c = src:sub(i, i)

    if c == "-" and src:sub(i + 1, i + 1) == "-" then
      local eq = src:match("^%-%-%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local _, e = src:find(close, i, true)
        local stop = e or n
        for k = i, stop do out[#out + 1] = (src:sub(k, k) == "\n") and "\n" or " " end
        i = stop + 1
      else
        while i <= n and src:sub(i, i) ~= "\n" do out[#out + 1] = " " i = i + 1 end
      end

    elseif c == '"' or c == "'" then
      local quote, start = c, i
      out[#out + 1] = " "
      i = i + 1
      while i <= n do
        local d = src:sub(i, i)
        if d == "\\" then
          out[#out + 1] = " " out[#out + 1] = " "
          i = i + 2
        elseif d == quote then
          out[#out + 1] = " " i = i + 1
          break
        elseif d == "\n" then
          break
        else
          out[#out + 1] = " " i = i + 1
        end
      end
      strings[#strings + 1] = { pos = start, text = src:sub(start, i - 1) }

    else
      local eq = src:match("^%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local _, e = src:find(close, i, true)
        local stop = e or n
        strings[#strings + 1] = { pos = i, text = src:sub(i, stop) }
        for k = i, stop do out[#out + 1] = (src:sub(k, k) == "\n") and "\n" or " " end
        i = stop + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end

  return table.concat(out), strings
end

-- Byte offset -> 1-based line number.
local function lineIndex(src)
  local starts = { 1 }
  for pos in src:gmatch("()\n") do starts[#starts + 1] = pos + 1 end
  return function(offset)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= offset then lo = mid else hi = mid - 1 end
    end
    return lo
  end
end

local function sourceLine(src, lineNo)
  local n = 0
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n == lineNo then return (line:gsub("^%s+", ""):gsub("%s+$", "")) end
  end
  return ""
end

-- --- what 5.1 does not have -------------------------------------------------

-- Syntax. Each entry is matched against BLANKED source, so comments and strings cannot
-- trigger it.
local SYNTAX = {
  { pat = "%f[%w_]goto%f[^%w_]", why = "goto is 5.2+" },
  { pat = "::%s*[%a_][%w_]*%s*::", why = "::label:: is 5.2+" },
  { pat = "//", why = "// integer division is 5.3+" },
  { pat = "<<", why = "<< bitwise shift is 5.3+" },
  { pat = ">>", why = ">> bitwise shift is 5.3+" },
  { pat = "&", why = "& bitwise and is 5.3+" },
  { pat = "|", why = "| bitwise or is 5.3+" },
  { pat = "<%s*const%s*>", why = "<const> attribute is 5.4" },
  { pat = "<%s*close%s*>", why = "<close> attribute is 5.4" },
}

-- Standard library added after 5.1.
local STDLIB = {
  { pat = "%f[%w_]table%.unpack%f[^%w_]", why = "table.unpack is 5.2+; 5.1 has global unpack" },
  { pat = "%f[%w_]table%.move%f[^%w_]", why = "table.move is 5.3+" },
  { pat = "%f[%w_]table%.pack%f[^%w_]", why = "table.pack is 5.2+" },
  { pat = "%f[%w_]math%.type%f[^%w_]", why = "math.type is 5.3+" },
  { pat = "%f[%w_]math%.tointeger%f[^%w_]", why = "math.tointeger is 5.3+" },
  { pat = "%f[%w_]math%.maxinteger%f[^%w_]", why = "math.maxinteger is 5.3+" },
  { pat = "%f[%w_]math%.mininteger%f[^%w_]", why = "math.mininteger is 5.3+" },
  { pat = "%f[%w_]math%.ult%f[^%w_]", why = "math.ult is 5.3+" },
  { pat = "%f[%w_]string%.pack%f[^%w_]", why = "string.pack is 5.3+" },
  { pat = "%f[%w_]string%.unpack%f[^%w_]", why = "string.unpack is 5.3+" },
  { pat = "%f[%w_]string%.packsize%f[^%w_]", why = "string.packsize is 5.3+" },
  { pat = "%f[%w_]coroutine%.isyieldable%f[^%w_]", why = "coroutine.isyieldable is 5.3+" },
  { pat = "%f[%w_]coroutine%.close%f[^%w_]", why = "coroutine.close is 5.4" },
  { pat = "%f[%w_]rawlen%f[^%w_]", why = "rawlen is 5.2+" },
  { pat = "%f[%w_]os%.exit%s*%(%s*true%f[^%w_]", why = "os.exit(boolean) is 5.2+; 5.1 wants a number" },
  { pat = "%f[%w_]os%.exit%s*%(%s*false%f[^%w_]", why = "os.exit(boolean) is 5.2+; 5.1 wants a number" },
}

-- String escapes added after 5.1. These live INSIDE literals, so they survive the
-- blanking pass and are checked separately -- `"\z"` compiles on 5.4 and is a syntax
-- error in 5.1, which is precisely the false green this file exists to stop.
local ESCAPES = {
  { pat = "\\z", why = "\\z whitespace-skip escape is 5.2+" },
  { pat = "\\x%x%x", why = "\\xXX hex escape is 5.2+" },
  { pat = "\\u{", why = "\\u{XXXX} escape is 5.3+" },
}

-- `~` is bitwise-not/xor in 5.3+, but `~=` is 5.1's not-equal and must never be flagged.
local function findBareTilde(code)
  local hits, init = {}, 1
  while true do
    local s = code:find("~", init, true)
    if not s then return hits end
    if code:sub(s + 1, s + 1) ~= "=" then hits[#hits + 1] = s end
    init = s + 1
  end
end

-- `math.pow` and the bare global `unpack` are deliberately NOT checked. They exist in
-- 5.1 and were REMOVED later, so the harness's own 5.4 runtime already rejects them.
-- They fail in the safe direction; this file only guards the unsafe one.

local function scan(collect)
  local violations = {}
  for _, rel in ipairs(harness.tocFiles()) do
    local src = readFile(harness.root .. "/" .. rel)
    if src then
      local code, strings = strip(src)
      local lineOf = lineIndex(src)
      collect(violations, rel, src, code, strings, lineOf)
    end
  end
  table.sort(violations)
  return violations
end

local function report(violations)
  return "\n         " .. table.concat(violations, "\n         ")
end

describe("lua 5.1 compatibility", function()
  it("uses no syntax newer than Lua 5.1", function()
    local v = scan(function(out, rel, src, code, _, lineOf)
      for _, check in ipairs(SYNTAX) do
        local init = 1
        while true do
          local s = code:find(check.pat, init)
          if not s then break end
          local ln = lineOf(s)
          out[#out + 1] = string.format("%s:%d  %s  |  %s", rel, ln, check.why, sourceLine(src, ln))
          init = s + 1
        end
      end
      for _, s in ipairs(findBareTilde(code)) do
        local ln = lineOf(s)
        out[#out + 1] = string.format("%s:%d  %s  |  %s", rel, ln,
          "~ as bitwise operator is 5.3+ (~= is fine)", sourceLine(src, ln))
      end
    end)
    expect.listEqual(v, {}, "constructs the WoW client cannot parse" ..
      (#v > 0 and report(v) or ""))
  end)

  it("uses no standard library newer than Lua 5.1", function()
    local v = scan(function(out, rel, src, code, _, lineOf)
      for _, check in ipairs(STDLIB) do
        local init = 1
        while true do
          local s = code:find(check.pat, init)
          if not s then break end
          local ln = lineOf(s)
          out[#out + 1] = string.format("%s:%d  %s  |  %s", rel, ln, check.why, sourceLine(src, ln))
          init = s + 1
        end
      end
    end)
    expect.listEqual(v, {}, "library calls that are nil in the WoW client" ..
      (#v > 0 and report(v) or ""))
  end)

  it("uses no string escapes newer than Lua 5.1", function()
    local v = scan(function(out, rel, src, _, strings, lineOf)
      for _, lit in ipairs(strings) do
        for _, check in ipairs(ESCAPES) do
          if lit.text:find(check.pat) then
            local ln = lineOf(lit.pos)
            out[#out + 1] = string.format("%s:%d  %s  |  %s", rel, ln, check.why, sourceLine(src, ln))
          end
        end
      end
    end)
    expect.listEqual(v, {}, "escapes that are a syntax error in 5.1" ..
      (#v > 0 and report(v) or ""))
  end)

  it("actually scanned the addon (a lint over zero files is not a pass)", function()
    local files = harness.tocFiles()
    expect.truthy(#files >= 15, "expected the full .toc, got " .. #files .. " files")
  end)
end)
