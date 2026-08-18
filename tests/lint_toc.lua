-- ============================================================================
-- TOC LINT  --  fail-closed, runs first
-- ============================================================================
-- The .toc is the manifest. A file missing from it loads as nothing; a file listed but
-- absent silently truncates the load. Neither produces an error the player will ever
-- see -- the addon just quietly does less. The ancestor project shipped a broken TOC
-- once and it cost a release, so this gate exists.
-- ============================================================================

local harness = require("harness")

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local s = fh:read("*a")
  fh:close()
  return s
end

local function fileExists(path)
  local fh = io.open(path, "r")
  if fh then fh:close() return true end
  return false
end

-- Portable directory listing without LFS: shell out once and cache.
local function luaFilesOnDisk()
  local out = {}
  local cmd
  if package.config:sub(1, 1) == "\\" then
    cmd = 'dir /b /s "' .. harness.addonDir:gsub("/", "\\") .. '\\*.lua" 2>nul'
  else
    cmd = 'find "' .. harness.addonDir .. '" -name "*.lua" -type f 2>/dev/null'
  end
  local pipe = io.popen(cmd)
  if not pipe then return out end
  for line in pipe:lines() do
    local norm = line:gsub("\\", "/")
    local rel = norm:sub(#harness.addonDir + 2)
    -- tests/ and tools/ are repo-only; the client never loads them.
    if rel ~= "" and not rel:match("^tests/") and not rel:match("^tools/") then
      table.insert(out, rel)
    end
  end
  pipe:close()
  return out
end

describe("toc (structural)", function()
  local tocPath = harness.addonDir .. "/Tuono.toc"
  local raw = readFile(tocPath)

  it("Tuono.toc exists", function()
    expect.truthy(raw, "no .toc at " .. tocPath)
  end)

  it("has exactly one Interface line", function()
    local n = 0
    for _ in raw:gmatch("##%s*Interface:") do n = n + 1 end
    expect.equal(n, 1, "multiple ## Interface: lines confuse the client")
  end)

  it("declares Title, Version and SavedVariables", function()
    for _, field in ipairs({ "Title", "Version", "SavedVariables" }) do
      expect.truthy(raw:match("##%s*" .. field .. ":"), "missing ## " .. field .. ":")
    end
  end)

  it("every listed file exists on disk", function()
    local missing = {}
    for _, rel in ipairs(harness.tocFiles()) do
      if not fileExists(harness.addonDir .. "/" .. rel) then
        table.insert(missing, rel)
      end
    end
    expect.listEqual(missing, {}, "listed in .toc but not on disk")
  end)

  it("every shipping .lua on disk is listed", function()
    local listed = {}
    for _, rel in ipairs(harness.tocFiles()) do listed[rel] = true end
    local orphans = {}
    for _, rel in ipairs(luaFilesOnDisk()) do
      if not listed[rel] then table.insert(orphans, rel) end
    end
    table.sort(orphans)
    expect.listEqual(orphans, {}, "on disk but not loaded by the client")
  end)

  it("loads profiles and data before the engine that reads them", function()
    local order = {}
    for i, rel in ipairs(harness.tocFiles()) do order[rel] = i end
    expect.truthy(order["profiles/OutlawRogue.lua"], "profile not in .toc")
    expect.truthy(order["Rotation.lua"], "Rotation.lua not in .toc")
    expect.truthy(order["profiles/OutlawRogue.lua"] < order["Rotation.lua"],
      "profiles must load before Rotation.lua rebuilds from them")
    expect.truthy(order["Profiles.lua"] < order["profiles/OutlawRogue.lua"],
      "Profiles.lua must define Register() before a profile calls it")
  end)
end)
