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
    -- A readable number coming back out only means something if the value going IN was
    -- secret. The first version of this check flagged any readable getter, and duly cried
    -- leak on a cooldown probe taken out of combat where startTime/duration were a
    -- perfectly readable 0/0 -- nothing was laundered because nothing was hidden.
    local pairsToCheck = {
      { src = "sourceDuration", got = "cooldownGetDuration", what = "Cooldown" },
      { src = "sourceStart",    got = "cooldownGetTimes",    what = "Cooldown" },
      { src = "sourceEnergy",   got = "statusBarGetValue",   what = "StatusBar" },
      { src = "sourceEnergy",   got = "fontStringGetText",   what = "FontString" },
    }
    local leaked, tested, untested = {}, 0, {}
    for _, c in ipairs(pairsToCheck) do
      local src, got = p.readBack[c.src], p.readBack[c.got]
      if got ~= nil then
        if src ~= "SECRET" then
          untested[#untested + 1] = c.what .. " (source was readable: " .. fmt(src) .. ")"
        else
          tested = tested + 1
          local leakedHere = type(got) == "number" or type(got) == "string" and got ~= "SECRET"
            and got ~= "RAISED" and got ~= "NO_WIDGET"
          if type(got) == "table" then
            leakedHere = false
            for _, v in pairs(got) do if v ~= "SECRET" then leakedHere = true end end
          end
          if leakedHere then leaked[#leaked + 1] = c.what .. "." .. c.got end
        end
      end
    end
    if #leaked > 0 then
      print("    !! LEAK: " .. table.concat(leaked, ", "))
      print("       A SECRET went in and a readable value came out. Open channel.")
    elseif tested > 0 then
      print(string.format("    -> %d of %d widget path(s) tested with a genuinely SECRET input;",
        tested, #pairsToCheck))
      print("       every one returned SECRET. The taint rides through. Channel closed.")
    end
    for _, u in ipairs(untested) do
      print("    -- inconclusive: " .. u .. "; re-probe in combat")
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

  if type(p.keybinds) == "table" then
    print("\n  keybind resolution (why the icons show no binding):")
    local s = p.keybinds.slots
    if s then
      print(string.format("    action slots 1-120: %s readable, %s SECRET, %s empty, %s raised",
        tostring(s.readable), tostring(s.secret), tostring(s.empty), tostring(s.raised)))
      if tonumber(s.secret) and tonumber(s.secret) > 0 then
        print("    !! secret action slots exist -- an unguarded actionID comparison RAISES here")
      end
      if tonumber(s.readable) == 0 then
        print("    !! NO action slot was readable. Every keybind lookup must fail.")
      end
    end
    for k, row in pairs(p.keybinds) do
      if k ~= "slots" and k ~= "error" and type(row) == "table" then
        print(string.format("    spell %-9s find=%-6s slot=%-6s binding=%-18s key=%s",
          k, tostring(row.find), tostring(row.slot),
          tostring(row.bindingName), tostring(row.key)))
      end
    end
    if p.keybinds.error then print("    error: " .. tostring(p.keybinds.error)) end
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

-- The in-combat re-probe. This is the one that settles whether the stat family survives
-- restriction; the start/stop probes are both taken with combat off.
for _, s in pairs(diag.trace or {}) do
  if type(s) == "table" and s.k == "probe" then
    showProbe("PROBE IN COMBAT (t=" .. tostring(s.t) .. ")", {
      inCombat = true,
      readBack = s.readBack,
      unusedReads = s.unusedReads,
      secrecyPredicates = s.secrecyPredicates,
    })
    break
  end
end

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
  -- SUMMARISE THE WHOLE RUN BEFORE SHOWING THE TAIL.
  -- The tail is misleading on its own: a trace almost always ends out of combat, where
  -- energy is legitimately [100,100] and the source legitimately goes stale. Reading the
  -- last thirteen ticks as representative produced a confident and wrong diagnosis once
  -- already -- "the update step is disconnected" -- when the real story was that the
  -- earlier fight had simply been quiet. Distribution first, tail second.
  local srcCount, inCombatTicks, widthSum, widthN, widthMax = {}, 0, 0, 0, 0
  for _, s in ipairs(ticks) do
    local k = tostring(s.eSrc)
    srcCount[k] = (srcCount[k] or 0) + 1
    if s.inCombat then inCombatTicks = inCombatTicks + 1 end
    local lo, hi = tonumber(s.eLo), tonumber(s.eHi)
    if lo and hi then
      local w = hi - lo
      widthSum = widthSum + w; widthN = widthN + 1
      if w > widthMax then widthMax = w end
    end
  end
  local srcKeys = {}
  for k in pairs(srcCount) do srcKeys[#srcKeys + 1] = k end
  table.sort(srcKeys, function(a, b) return srcCount[a] > srcCount[b] end)
  local parts = {}
  for _, k in ipairs(srcKeys) do parts[#parts + 1] = k .. "x" .. srcCount[k] end
  print("\n  energy source across ALL " .. #ticks .. " ticks: " .. table.concat(parts, "  "))
  if widthN > 0 then
    print(string.format("  interval width: mean %.2f, max %.2f  (0 = an exact threshold pin)",
      widthSum / widthN, widthMax))
  end
  if (srcCount["bracketed"] or 0) + (srcCount["measured"] or 0) + (srcCount["anchored"] or 0) == 0 then
    print("    !! No tick was ever bracketed, measured or anchored. The observation channel")
    print("       produced nothing all run -- either no threshold was crossed (too little")
    print("       spending) or recordEdge is not being reached at all.")
  end

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
