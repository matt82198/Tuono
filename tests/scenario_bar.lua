-- End-to-end scenario: what does the BAR actually show for a levelling rogue in combat?
-- Unit tests keep passing while live play is broken, so drive the real pipeline instead.
local stub = require("tests.wow_stub")
_G.ADDON_NAME = "OutlawAssist"
local OA = {}
for k, v in pairs(stub) do if k ~= "state" then _G[k] = v end end
for _, f in ipairs({
  "OutlawAssist/Core.lua", "OutlawAssist/data/rules.lua", "OutlawAssist/StateTracker.lua",
  "OutlawAssist/AssistReader.lua", "OutlawAssist/Rotation.lua",
  "OutlawAssist/IntelligenceLayer.lua", "OutlawAssist/Display.lua",
  "OutlawAssist/Config.lua", "OutlawAssist/ApiTest.lua"
}) do assert(loadfile(f))("OutlawAssist", OA) end
stub.FireEvent("ADDON_LOADED", "OutlawAssist")
stub.FireEvent("PLAYER_LOGIN")
stub.FireEvent("PLAYER_ENTERING_WORLD")

local out = {}
local function log(s) table.insert(out, s) end

local function showBar(label)
  local r = OA.Engine.Evaluate()
  local parts = {}
  for i, e in ipairs(r.queue or {}) do
    parts[#parts + 1] = string.format("%d:%s(%s/%s)", i, tostring(e.spellID),
      tostring(e.source), tostring(e.confidence))
  end
  log(label .. " -> " .. (#parts > 0 and table.concat(parts, "  ") or "EMPTY"))
end

-- SCENARIO A: levelling rogue, knows only Sinister Strike + Dispatch, mid-combat.
OA.State.inCombat = true
OA.State.stealthed = false
OA.State.buffs.degraded = true          -- combat: auras hidden, as in the real client
OA.State.energy, OA.State.energyMax = 100, 100
OA.State.comboPoints, OA.State.comboPointsMax = 0, 6
OA.State.knownSpells = {}
OA.State.knownSpells[OA.SpellIDs.sinisterStrike] = true
OA.State.knownSpells[OA.SpellIDs.dispatch] = true
for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                    "killingSpree","rollTheBones","keepItRolling","bladeFlurry","ambush"}) do
  OA.State.knownSpells[OA.SpellIDs[k]] = false
  OA.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
end
OA.State.cooldowns.dispatch = { known = true, ready = true, remaining = 0 }
OA.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
log("== A: levelling (SS + Dispatch only), 0 CP, full energy, degraded ==")
showBar("  0 CP")
OA.State.comboPoints = 5
showBar("  5 CP")
OA.State.comboPoints = 0
OA.State.energy = 30
showBar("  0 CP / 30 energy")

-- SCENARIO B: same, but the known-spell probe reports FALSE for everything
-- (what happens if the API answers differently than we assume?)
log("== B: known-spell probe says false for EVERYTHING ==")
for id in pairs(OA.State.knownSpells) do OA.State.knownSpells[id] = false end
OA.State.energy, OA.State.comboPoints = 100, 0
showBar("  0 CP")

-- SCENARIO C: probe unavailable entirely (all nil)
log("== C: known-spell table empty (probe unavailable) ==")
OA.State.knownSpells = {}
showBar("  0 CP")

io.write(table.concat(out, "\n") .. "\n")

-- Direct Predict probe: how many steps does it actually return?
OA.State.knownSpells = {}
OA.State.knownSpells[OA.SpellIDs.sinisterStrike] = true
OA.State.knownSpells[OA.SpellIDs.dispatch] = true
OA.State.energy, OA.State.energyMax = 100, 100
OA.State.comboPoints = 0
local p = OA.Rotation.Predict(OA.State, 4)
local n = p and #p or -1
local d = {}
for i, e in ipairs(p or {}) do d[#d+1] = i .. ":" .. tostring(e.spellID) .. "/" .. tostring(e.confidence) end
io.write("PREDICT steps=" .. n .. "  " .. table.concat(d, " ") .. "\n")
io.write("activeRuleCount=" .. tostring(OA.Rotation.activeRuleCount) .. "\n")

-- Instrument: how many entries survive each stage?
local realPredict = OA.Rotation.Predict
OA.Rotation.Predict = function(st, n)
  local r = realPredict(st, n)
  io.write("  [hook] Predict returned " .. tostring(r and #r or -1) .. " steps\n")
  return r
end
OA.State.comboPoints = 0
OA.State.energy = 100
_G.__OA_TRACE = true
local r2 = OA.Engine.Evaluate()
io.write("  [hook] Evaluate queue length = " .. tostring(#r2.queue) .. "\n")
for i, e in ipairs(r2.queue) do
  io.write("    " .. i .. ": " .. tostring(e.spellID) .. " kind=" .. tostring(e.kind) .. " src=" .. tostring(e.source) .. "\n")
end
