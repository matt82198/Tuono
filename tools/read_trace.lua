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

  -- THE "MIDDLE LAYER OF INVISIBLE ICONS" QUESTION, ANSWERED BY MEASUREMENT.
  -- If a getter returns SECRET, the widget carried the taint through and the channel is
  -- closed. If it returns a NUMBER, that is a declassification path and a genuine finding.
  if type(p.readBack) == "table" then
    print("\n  widget read-back (can a secret be laundered through a UI widget?):")
    for _, k in ipairs({ "sourceStart", "sourceDuration", "cooldownSetCooldown",
                         "cooldownGetTimes", "cooldownGetDuration", "sourceEnergy",
                         "statusBarSetValue", "statusBarGetValue",
                         "fontStringSetFormatted", "fontStringGetText", "error" }) do
      if p.readBack[k] ~= nil then
        print(string.format("    %-24s %s", k, fmt(p.readBack[k])))
      end
    end
    local leaked = {}
    for k, v in pairs(p.readBack) do
      if type(v) == "number" and not k:find("^source") then leaked[#leaked + 1] = k end
    end
    if #leaked > 0 then
      print("    !! " .. table.concat(leaked, ", ") .. " returned a READABLE number.")
      print("       If the source was SECRET, that is an open declassification channel.")
    else
      print("    -> no readable number came back out; the taint rides through the widget.")
    end
  end

  if type(p.unusedReads) == "table" then
    print("\n  readable? functions we do NOT currently consume:")
    local ks = {}
    for k in pairs(p.unusedReads) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
      local v = p.unusedReads[k]
      local note = ""
      if type(v) == "number" then note = "   <- READABLE, worth wiring up" end
      print(string.format("    %-28s %s%s", k, fmt(v), note))
    end
  end

  if type(p.secrecyPredicates) == "table" then
    print("\n  what the client says about its own secrecy:")
    local ks = {}
    for k in pairs(p.secrecyPredicates) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
      print(string.format("    %-30s %s", k, fmt(p.secrecyPredicates[k])))
    end
  end
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

if diag.rtbCandidates and next(diag.rtbCandidates) then
  section("ROLL THE BONES AURAS LEARNED FROM PLAY")
  for id, name in pairs(diag.rtbCandidates) do
    print(string.format("  %-10s %s", tostring(id), tostring(name)))
  end
  print("  -> add these to the profile's rtbStageBuffs with their stage numbers")
end

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

-- Spell IDs alone are unreadable at a glance, and the whole point of this tool is that a
-- human can skim the output. Names come from the shipped profile, so this stays correct
-- when the profile's IDs are corrected.
local SPELL_NAMES = {
  [13750] = "Adrenaline Rush", [271877] = "Blade Rush",   [1277933] = "Preparation",
  [315341] = "Between the Eyes", [315508] = "Roll the Bones (old ID)",
  [1214909] = "Roll the Bones", [193315] = "Sinister Strike", [13877] = "Blade Flurry",
  [1784] = "Stealth", [185763] = "Pistol Shot", [195627] = "Opportunity",
  [8676] = "Ambush", [51690] = "Killing Spree", [2098] = "Dispatch",
  [381989] = "Keep It Rolling", [315496] = "Slice and Dice", [14185] = "Preparation (CLASSIC - wrong ID)",
}
local function spellName(id)
  local n = SPELL_NAMES[tonumber(id) or -1]
  return n and ("  " .. n) or ""
end

-- What the client REFUSED, and why. These are the ground truth on a bad recommendation:
-- a UI error paired with a failed cast is the client telling us our advice was wrong.
local function tally(pred, keyfn)
  local counts, order = {}, {}
  for _, s in pairs(samples) do
    if pred(s) then
      local key = keyfn(s)
      if counts[key] == nil then order[#order + 1] = key counts[key] = 0 end
      counts[key] = counts[key] + 1
    end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return tostring(a) < tostring(b)
  end)
  return counts, order
end

local errs, errOrder = tally(function(s) return s.k == "uierr" end,
  function(s) return tostring(s.msg) end)
if #errOrder > 0 then
  print("\n  UI errors the client raised (what it refused to do):")
  for _, k in ipairs(errOrder) do print(string.format("    %5dx  %s", errs[k], k)) end
end

local fails, failOrder = tally(function(s) return s.k == "castfail" end,
  function(s) return tostring(s.id) end)
if #failOrder > 0 then
  print("\n  failed casts by spell (id -> count):")
  for _, k in ipairs(failOrder) do
    print(string.format("    %5dx  %s%s", fails[k], k, spellName(k)))
  end
end

local casts, castOrder = tally(function(s) return s.k == "cast" end,
  function(s) return tostring(s.id) end)
if #castOrder > 0 then
  print("\n  successful casts by spell (id -> count):")
  for _, k in ipairs(castOrder) do
    print(string.format("    %5dx  %s%s", casts[k], k, spellName(k)))
  end
end

-- Combo points are the spine of the Outlaw rotation: no CP means no finisher, ever, and
-- the bar degrades to "builder forever". Worth stating outright rather than leaving the
-- reader to notice it in the tick dump.
local cpSeen, cpUnknown, cpMax = {}, 0, 0
for _, s in pairs(samples) do
  if s.k == "tick" then
    if s.cpK == false then cpUnknown = cpUnknown + 1 end
    local n = tonumber(s.cp)
    if n then
      cpSeen[n] = (cpSeen[n] or 0) + 1
      if n > cpMax then cpMax = n end
    end
  end
end
if next(cpSeen) then
  local keys = {}
  for n in pairs(cpSeen) do keys[#keys + 1] = n end
  table.sort(keys)
  local parts = {}
  for _, n in ipairs(keys) do parts[#parts + 1] = n .. "x" .. cpSeen[n] end
  print("\n  combo points observed across ticks: " .. table.concat(parts, "  ") ..
    "   (unreadable on " .. cpUnknown .. " ticks)")
  if cpMax == 0 then
    print("    !! CP never rose above 0. No finisher can ever fire; the rotation")
    print("       degrades to the builder on every step. Check UNIT_POWER_UPDATE and")
    print("       whether the trace covers any real combat at all.")
  end
end

print("")
