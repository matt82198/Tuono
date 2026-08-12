-- Read a Tuono flight-recorder trace straight out of WoW's SavedVariables.
--
-- SavedVariables are plain Lua assignments, so the file IS a loadable chunk. No parser
-- needed -- sandbox it, run it, read the globals. That is the whole reason this loop
-- works without anyone transcribing anything out of the game.
--
--   lua tools/read_trace.lua [path-to-Tuono.lua]
--
-- Default path is the standard retail install. Pass one explicitly for another account.

local DEFAULT = [[C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\91730149#1\SavedVariables\Tuono.lua]]
local path = arg and arg[1] or DEFAULT

local f = io.open(path, "r")
if not f then
  print("No trace at:\n  " .. path)
  print("\nWoW writes SavedVariables on /reload or logout. If the file is missing:")
  print("  1. log in with Tuono enabled")
  print("  2. /tuono record")
  print("  3. fight something")
  print("  4. /reload        <- this is what flushes it to disk")
  os.exit(1)
end
local src = f:read("*a")
f:close()

-- Sandbox: the file should only ever contain data assignments.
local env = {}
local chunk, err = load(src, "savedvars", "t", env)
if not chunk then print("Could not load trace: " .. tostring(err)) os.exit(1) end
local ok, lerr = pcall(chunk)
if not ok then print("Error executing trace: " .. tostring(lerr)) os.exit(1) end

local diag = env.TuonoDiagDB
if not diag then
  print("File loaded but TuonoDiagDB is absent -- the recorder never ran.")
  print("Globals present: ")
  for k in pairs(env) do print("  " .. k) end
  os.exit(1)
end

local function fmt(v)
  if v == nil then return "-" end
  if type(v) == "table" then
    local parts = {}
    for k2, v2 in pairs(v) do parts[#parts + 1] = tostring(k2) .. "=" .. tostring(v2) end
    table.sort(parts)
    return "{" .. table.concat(parts, " ") .. "}"
  end
  return tostring(v)
end

local function section(title) print("\n=== " .. title .. " ===") end

-- ---------------------------------------------------------------------------
-- The environment probe answers every secrecy question at once. This is the part
-- that settles claims the offline harness structurally cannot.
-- ---------------------------------------------------------------------------
local function showProbe(label, p)
  if not p then return end
  section(label)
  print("  in combat      : " .. fmt(p.inCombat))
  print("  instance       : " .. fmt(p.instance))
  print("  issecretvalue  : " .. fmt(p.hasIsSecret))
  print("  restrictions   : " .. fmt(p.restrictions))
  print("  power          : " .. fmt(p.power))
  print("  haste          : " .. fmt(p.haste) .. "   <- secret since 12.0.5?")
  print("  IsSpellUsable  : " .. fmt(p.isSpellUsable) .. "   <- LOAD-BEARING: must not be SECRET")
  print("  GetSpellPowerCost: " .. fmt(p.powerCost))
  print("  cooldown fields: " .. fmt(p.cooldownFields) .. "   <- isEnabled/isActive must be readable")
  print("  aura bySpellID : " .. fmt(p.auraBySpellID))
  print("  aura byIndex   : " .. fmt(p.auraByIndex) .. "   <- expected THREW in combat")
  print("  assist avail   : " .. fmt(p.assistAvailable) .. "   <- SECRET here froze the bar")
  print("  assist pick    : " .. fmt(p.assistPick))
  print("  C_Secrets      : " .. fmt(p.cSecrets))
end

showProbe("PROBE AT START", diag.probeAtStart)
showProbe("PROBE AT STOP", diag.probeAtStop)

-- ---------------------------------------------------------------------------
-- Buff capture: this is what resolves the Roll the Bones stage spell IDs.
-- ---------------------------------------------------------------------------
local function showAuras(label, list)
  if not list or #list == 0 then return end
  section(label .. " (" .. #list .. ")")
  for _, a in ipairs(list) do
    if a.error then
      print(string.format("  [%2d] %s", a.i, a.error))
    else
      print(string.format("  [%2d] id=%-10s stacks=%-6s name=%s",
        a.i, tostring(a.spellId), tostring(a.applications), tostring(a.name)))
    end
  end
end
showAuras("BUFFS AT START", diag.aurasAtStart)
showAuras("BUFFS AT STOP", diag.aurasAtStop)
showAuras("BUFFS CAPTURED MANUALLY (/tuono record auras)", diag.aurasManual)

-- ---------------------------------------------------------------------------
-- Event stream
-- ---------------------------------------------------------------------------
local samples = diag.samples or {}
local n = 0
for _ in pairs(samples) do n = n + 1 end

section("TRACE (" .. n .. " samples, wrapped=" .. tostring(diag.wrapped) .. ")")

local kinds, auraShapes = {}, {}
for _, s in pairs(samples) do
  kinds[s.k] = (kinds[s.k] or 0) + 1
  if s.k == "aura" then
    local shape = "full=" .. tostring(s.full)
      .. " added=" .. tostring(s.addedAuras)
      .. " removed=" .. tostring(s.removedAuraInstanceIDs)
      .. " updated=" .. tostring(s.updatedAuraInstanceIDs)
      .. " info=" .. tostring(s.info)
    auraShapes[shape] = (auraShapes[shape] or 0) + 1
  end
end

print("  event counts:")
local ks = {}
for k in pairs(kinds) do ks[#ks + 1] = k end
table.sort(ks)
for _, k in ipairs(ks) do print(string.format("    %-10s %d", k, kinds[k])) end

if next(auraShapes) then
  print("\n  UNIT_AURA payload shapes observed (the bug that froze the aura layer):")
  for shape, count in pairs(auraShapes) do
    print(string.format("    %5dx  %s", count, shape))
  end
end

-- Last handful of ticks, to see what the model actually believed.
local ticks = {}
for _, s in pairs(samples) do if s.k == "tick" then ticks[#ticks + 1] = s end end
table.sort(ticks, function(a, b) return (a.t or 0) < (b.t or 0) end)
if #ticks > 0 then
  print("\n  last ticks (energy interval, combo points, RtB stage):")
  for i = math.max(1, #ticks - 12), #ticks do
    local s = ticks[i]
    print(string.format(
      "    t=%-9s energy=[%s,%s] %-10s cp=%-4s(%s) rtb=%s(%s) enemies=%-4s mode=%-7s assist=%s",
      tostring(s.t), tostring(s.eLo), tostring(s.eHi), tostring(s.eSrc),
      tostring(s.cp), tostring(s.cpK), tostring(s.rtb), tostring(s.rtbK),
      tostring(s.enemies), tostring(s.mode), tostring(s.assist)))
  end
end

print("")
