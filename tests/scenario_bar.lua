-- End-to-end scenario: what does the BAR actually show for a levelling rogue in combat?
-- Unit tests keep passing while live play is broken, so drive the real pipeline instead.
local stub = require("tests.wow_stub")
_G.ADDON_NAME = "Tuono"
local Tuono = {}
for k, v in pairs(stub) do if k ~= "state" then _G[k] = v end end
-- LOAD ORDER COMES FROM THE .toc, NOT FROM A HAND-KEPT LIST.
-- This file used to hardcode its own subset and omitted Profiles.lua, so Rotation.lua
-- indexed a nil Tuono.Profiles and the whole scenario crashed before asserting anything.
-- It had been dead on main for some time. The .toc IS the contract; read it.
local function tocFiles()
  local fh = assert(io.open("Tuono/Tuono.toc", "r"))
  local out = {}
  for line in fh:lines() do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" and t:sub(1, 1) ~= "#" then out[#out + 1] = "Tuono/" .. t end
  end
  fh:close()
  return out
end
for _, f in ipairs(tocFiles()) do assert(loadfile(f))("Tuono", Tuono) end
stub.FireEvent("ADDON_LOADED", "Tuono")
stub.FireEvent("PLAYER_LOGIN")
stub.FireEvent("PLAYER_ENTERING_WORLD")

local out = {}
local function log(s) table.insert(out, s) end

local function showBar(label)
  local r = Tuono.Engine.Evaluate()
  local parts = {}
  for i, e in ipairs(r.queue or {}) do
    parts[#parts + 1] = string.format("%d:%s(%s/%s)", i, tostring(e.spellID),
      tostring(e.source), tostring(e.confidence))
  end
  log(label .. " -> " .. (#parts > 0 and table.concat(parts, "  ") or "EMPTY"))
end

-- SCENARIO A: levelling rogue, knows only Sinister Strike + Dispatch, mid-combat.
Tuono.State.inCombat = true
Tuono.State.stealthed = false
Tuono.State.buffs.degraded = true          -- combat: auras hidden, as in the real client
Tuono.State.energy, Tuono.State.energyMax = 100, 100
Tuono.State.comboPoints, Tuono.State.comboPointsMax = 0, 6
Tuono.State.knownSpells = {}
Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
Tuono.State.knownSpells[Tuono.SpellIDs.dispatch] = true
for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                    "killingSpree","rollTheBones","keepItRolling","bladeFlurry","ambush"}) do
  Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
  Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
end
Tuono.State.cooldowns.dispatch = { known = true, ready = true, remaining = 0 }
Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
log("== A: levelling (SS + Dispatch only), 0 CP, full energy, degraded ==")
showBar("  0 CP")
Tuono.State.comboPoints = 5
showBar("  5 CP")
Tuono.State.comboPoints = 0
Tuono.State.energy = 30
showBar("  0 CP / 30 energy")

-- SCENARIO B: same, but the known-spell probe reports FALSE for everything
-- (what happens if the API answers differently than we assume?)
log("== B: known-spell probe says false for EVERYTHING ==")
for id in pairs(Tuono.State.knownSpells) do Tuono.State.knownSpells[id] = false end
Tuono.State.energy, Tuono.State.comboPoints = 100, 0
showBar("  0 CP")

-- SCENARIO C: probe unavailable entirely (all nil)
log("== C: known-spell table empty (probe unavailable) ==")
Tuono.State.knownSpells = {}
showBar("  0 CP")

-- === p0fix tests ===

-- P0-1 TEST: Stealth opener yields Ambush ONCE, then different ability
log("")
log("== P0-1: Stealth opener (Ambush clears stealthed) ==")
Tuono.State.inCombat = false
Tuono.State.stealthed = true
Tuono.State.buffs.degraded = false
Tuono.State.energy = 100
Tuono.State.comboPoints = 0
Tuono.State.knownSpells = {}
Tuono.State.knownSpells[Tuono.SpellIDs.ambush] = true
Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
Tuono.State.knownSpells[Tuono.SpellIDs.dispatch] = true
Tuono.State.cooldowns.ambush = { known = true, ready = true, remaining = 0 }
Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
Tuono.State.cooldowns.dispatch = { known = true, ready = true, remaining = 0 }
for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                    "killingSpree","rollTheBones","keepItRolling","bladeFlurry"}) do
  Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
  Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
end
showBar("  Stealth: Ambush ONCE, then different")

-- P0-2 TEST: At max CP with finisher ready, finisher appears at position 1
log("")
log("== P0-2: At 5 CP, finisher priority (Dispatch first, not buried) ==")
Tuono.State.inCombat = true
Tuono.State.stealthed = false
Tuono.State.buffs.degraded = true
Tuono.State.energy = 100
Tuono.State.comboPoints = 5
Tuono.State.knownSpells = {}
Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
Tuono.State.knownSpells[Tuono.SpellIDs.dispatch] = true
Tuono.State.cooldowns.dispatch = { known = true, ready = true, remaining = 0 }
Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                    "killingSpree","rollTheBones","keepItRolling","bladeFlurry","ambush"}) do
  Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
  Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
end
showBar("  5 CP: Dispatch first (not buried)")

-- P0-3 TEST: Levelling fixture (SS + Dispatch, 5 CP) puts Dispatch at position 1
log("")
log("== P0-3: Levelling (SS + Dispatch, 5 CP), Dispatch at position 1 ==")
-- (same state as P0-2, already set above)
-- The test is: position 1 should be Dispatch, not SS
showBar("  Levelling 5 CP: Dispatch at position 1")

-- P0-4 TEST: Killing Spree not treated as CP spender at 6 CP
log("")
log("== P0-4: Killing Spree independent of CP, not gated to 6 CP ==")
Tuono.State.inCombat = true
Tuono.State.stealthed = false
Tuono.State.buffs.degraded = true
Tuono.State.energy = 100
Tuono.State.comboPoints = 2  -- Low CP, not 6 CP
Tuono.State.knownSpells = {}
Tuono.State.knownSpells[Tuono.SpellIDs.killingSpree] = true
Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
Tuono.State.cooldowns.killingSpree = { known = true, ready = true, remaining = 0 }
Tuono.State.cooldowns.sinisterStrike = { known = true, ready = true, remaining = 0 }
for _, k in ipairs({"adrenalineRush","bladeRush","preparation","betweenTheEyes",
                    "rollTheBones","keepItRolling","bladeFlurry","ambush","dispatch"}) do
  Tuono.State.knownSpells[Tuono.SpellIDs[k]] = false
  Tuono.State.cooldowns[k] = { known = true, ready = false, remaining = 60 }
end
showBar("  2 CP: Killing Spree available (not gated to 6 CP)")

io.write(table.concat(out, "\n") .. "\n")

-- Direct Predict probe: how many steps does it actually return?
Tuono.State.knownSpells = {}
Tuono.State.knownSpells[Tuono.SpellIDs.sinisterStrike] = true
Tuono.State.knownSpells[Tuono.SpellIDs.dispatch] = true
Tuono.State.energy, Tuono.State.energyMax = 100, 100
Tuono.State.comboPoints = 0
local p = Tuono.Rotation.Predict(Tuono.State, 4)
local n = p and #p or -1
local d = {}
for i, e in ipairs(p or {}) do d[#d+1] = i .. ":" .. tostring(e.spellID) .. "/" .. tostring(e.confidence) end
io.write("PREDICT steps=" .. n .. "  " .. table.concat(d, " ") .. "\n")
io.write("activeRuleCount=" .. tostring(Tuono.Rotation.activeRuleCount) .. "\n")

-- Instrument: how many entries survive each stage?
local realPredict = Tuono.Rotation.Predict
Tuono.Rotation.Predict = function(st, n)
  local r = realPredict(st, n)
  io.write("  [hook] Predict returned " .. tostring(r and #r or -1) .. " steps\n")
  return r
end
Tuono.State.comboPoints = 0
Tuono.State.energy = 100
_G.__OA_TRACE = true
local r2 = Tuono.Engine.Evaluate()
io.write("  [hook] Evaluate queue length = " .. tostring(#r2.queue) .. "\n")
for i, e in ipairs(r2.queue) do
  io.write("    " .. i .. ": " .. tostring(e.spellID) .. " kind=" .. tostring(e.kind) .. " src=" .. tostring(e.source) .. "\n")
end
