#!/usr/bin/env lua
-- Lua 5.1 Syntax Gate: Scan files for 5.2+ constructs
-- Banned: goto/labels, bitwise ops, integer division, unicode escapes, setfenv/require/io/os

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- Strip string literals and trailing comments so patterns only see CODE.
-- (WoW color codes like "|cff00ccff" inside strings false-positive the bitwise scan.)
local function stripStringsAndComments(line)
  local s = line:gsub("\\\\", ""):gsub('\\"', ""):gsub("\\'", "")
  s = s:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
  s = s:gsub("%[%[.-%]%]", "")
  s = s:gsub("%-%-.*$", "")
  return s
end

local function scanForBannedConstruct(content, filename)
  local violations = {}

  local lineNum = 0
  for rawLine in content:gmatch("[^\n]+") do
    lineNum = lineNum + 1
    local line = stripStringsAndComments(rawLine)

    -- Skip lines that are comments
    if not line:match("^%s*%-%-") and #line > 0 then
      -- Check for goto statement (not ::label::)
      if line:match("goto%s+%w") then
        table.insert(violations, {line = lineNum, construct = "goto", line_text = line})
      end

      -- Check for labels ::label::
      if line:match("::%w+::") then
        table.insert(violations, {line = lineNum, construct = "label", line_text = line})
      end

      -- Check for bitwise operators (&, |, ~ but not ~= which is not-equal)
      -- Need to avoid ~= (not equal)
      if line:match("[^=]~[^=]") or line:match("^~[^=]") then
        table.insert(violations, {line = lineNum, construct = "bitwise ~", line_text = line})
      end
      if line:match("[&|][^=]") or line:match("^[&|][^=]") then
        table.insert(violations, {line = lineNum, construct = "bitwise & or |", line_text = line})
      end

      -- Check for integer division //
      if line:match("//") then
        table.insert(violations, {line = lineNum, construct = "integer division //", line_text = line})
      end

      -- Check for unicode escapes \u{ or \z
      if line:match("\\u{") then
        table.insert(violations, {line = lineNum, construct = "unicode escape \\u{", line_text = line})
      end
      if line:match("\\z") then
        table.insert(violations, {line = lineNum, construct = "whitespace escape \\z", line_text = line})
      end

      -- Check for setfenv, require, io., os. (outside strings/comments)
      -- Pragmatic: just line-scan; full parse is fragile
      if line:match("setfenv%s*%(") then
        table.insert(violations, {line = lineNum, construct = "setfenv", line_text = line})
      end
      if line:match("require%s*%(") or line:match("require%s*%{") or line:match("require%s*\"") or line:match("require%s*'") then
        table.insert(violations, {line = lineNum, construct = "require", line_text = line})
      end
      if line:match("io%.") then
        table.insert(violations, {line = lineNum, construct = "io.", line_text = line})
      end
      if line:match("os%.") then
        table.insert(violations, {line = lineNum, construct = "os.", line_text = line})
      end
    end
  end

  return violations
end

local function runLua51Check()
  local testCount = 0
  local passCount = 0
  local allViolations = {}

  local function test(name, fn)
    testCount = testCount + 1
    local ok, err = pcall(fn)
    if ok then
      print("PASS: " .. name)
      passCount = passCount + 1
    else
      print("FAIL: " .. name .. " - " .. tostring(err))
    end
  end

  -- Read TOC to get file list (reuse toc_check logic)
  local tocPath = "Tuono/Tuono.toc"
  local tocContent = readFile(tocPath)

  test("toc file exists for scanning", function()
    if not tocContent then
      error("Could not read " .. tocPath)
    end
  end)

  if not tocContent then
    return testCount, passCount, allViolations
  end

  -- Extract file list from TOC
  local tocFiles = {}
  test("toc file list can be parsed for lua51 scan", function()
    for line in tocContent:gmatch("[^\n]+") do
      -- Skip comments and empty lines
      if not line:match("^##") and not line:match("^%s*$") and not line:match("^%s*#") then
        local file = line:match("^%s*(.+)%s*$")
        if file and #file > 0 then
          table.insert(tocFiles, file)
        end
      end
    end

    if #tocFiles == 0 then
      error("No Lua files found in TOC")
    end
  end)

  -- Scan each TOC file for banned constructs
  test("all toc-listed files pass lua51 syntax check", function()
    for _, file in ipairs(tocFiles) do
      local fullPath = "Tuono/" .. file
      local content = readFile(fullPath)

      if not content then
        error("Could not read file: " .. fullPath)
      end

      local violations = scanForBannedConstruct(content, fullPath)
      if #violations > 0 then
        for _, v in ipairs(violations) do
          table.insert(allViolations, {file = fullPath, line = v.line, construct = v.construct, text = v.line_text})
        end
        error("File " .. fullPath .. " contains " .. #violations .. " Lua 5.2+ constructs")
      end
    end
  end)

  -- NOTE: tests/ is deliberately NOT scanned — the harness runs under desktop Lua
  -- (5.4), never inside the WoW client; only TOC-listed files ship to the 5.1 runtime.

  return testCount, passCount, allViolations
end

-- Run the Lua 5.1 check
local testCount, passCount, allViolations = runLua51Check()
print("")
print("LUA51 CHECK: " .. passCount .. "/" .. testCount .. " checks passed")

-- Print detailed violations for debugging
if #allViolations > 0 then
  print("")
  print("Violations found:")
  for _, v in ipairs(allViolations) do
    print("  " .. v.file .. ":" .. v.line .. " - " .. v.construct)
    print("    " .. v.text)
  end
end

-- Return status (don't exit; let caller decide)
return (passCount == testCount)
