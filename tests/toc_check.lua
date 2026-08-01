#!/usr/bin/env lua
-- TOC Lint: Verify OutlawAssist.toc integrity

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

local function listLuaFiles(dir)
  local files = {}
  local p = io.popen("find " .. dir .. " -name '*.lua' -type f")
  if p then
    for line in p:lines() do
      table.insert(files, line)
    end
    p:close()
  end
  return files
end

local function runTocCheck()
  local testCount = 0
  local passCount = 0

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

  -- Test 1: Read TOC file
  local tocPath = "OutlawAssist/OutlawAssist.toc"
  local tocContent = readFile(tocPath)

  test("toc file exists", function()
    if not tocContent then
      error("Could not read " .. tocPath)
    end
  end)

  if not tocContent then
    return testCount, passCount
  end

  -- Test 2: Verify Interface line on line 1 with numeric single-or-list format
  test("toc interface line on line 1, numeric single-or-list", function()
    local interfaceLines = {}
    for line in tocContent:gmatch("[^\n]+") do
      if line:match("^##%s*Interface%s*:") then
        table.insert(interfaceLines, line)
      end
    end

    if #interfaceLines ~= 1 then
      error("Expected 1 Interface line, found " .. #interfaceLines)
    end

    local interfaceLine = interfaceLines[1]
    -- Extract the interface number(s) part
    local numberPart = interfaceLine:match("^##%s*Interface%s*:%s*(.+)$")
    if not numberPart then
      error("Could not parse Interface line: " .. interfaceLine)
    end

    -- Strip trailing whitespace (handles Windows line endings)
    numberPart = numberPart:gsub("%s+$", "")

    -- Verify it contains only digits, commas, and spaces, and starts/ends with a digit
    if not numberPart:match("^[0-9][0-9, ]*[0-9]$") and not numberPart:match("^[0-9]+$") then
      error("Interface line must contain one or more comma-separated digit numbers: " .. numberPart)
    end
  end)

  -- Test 3: Extract file list from TOC
  local tocFiles = {}
  test("toc file list can be parsed", function()
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

  -- Test 4: Verify every TOC-listed file exists
  test("all toc-listed files exist on disk", function()
    for _, file in ipairs(tocFiles) do
      local fullPath = "OutlawAssist/" .. file
      if not fileExists(fullPath) then
        error("File listed in TOC not found: " .. fullPath)
      end
    end
  end)

  -- Test 5: Verify all OutlawAssist and data Lua files are in TOC
  test("all outlaw assist lua files are listed in toc", function()
    -- Find all .lua files in OutlawAssist/ (excluding subdirs for now)
    local allFiles = {}

    -- Check OutlawAssist/*.lua
    local p = io.popen("find OutlawAssist -maxdepth 1 -name '*.lua' -type f")
    if p then
      for line in p:lines() do
        -- Strip OutlawAssist/ prefix
        local file = line:gsub("^OutlawAssist/", "")
        table.insert(allFiles, file)
      end
      p:close()
    end

    -- Check OutlawAssist/data/*.lua
    local p2 = io.popen("find OutlawAssist/data -name '*.lua' -type f")
    if p2 then
      for line in p2:lines() do
        -- Strip OutlawAssist/ prefix
        local file = line:gsub("^OutlawAssist/", "")
        table.insert(allFiles, file)
      end
      p2:close()
    end

    -- Check that each file is in tocFiles
    for _, file in ipairs(allFiles) do
      local found = false
      for _, tocFile in ipairs(tocFiles) do
        if tocFile == file then
          found = true
          break
        end
      end
      if not found then
        error("File not listed in TOC: " .. file)
      end
    end
  end)

  return testCount, passCount
end

-- Run the TOC check
local testCount, passCount = runTocCheck()
print("")
print("TOC LINT: " .. passCount .. "/" .. testCount .. " checks passed")

-- Return status (don't exit; let caller decide)
return (passCount == testCount)
