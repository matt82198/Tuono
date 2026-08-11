-- What does the bar show for a MINIMAL kit? (fresh-80 worst case)
local stub = require("tests.wow_stub")
_G.ADDON_NAME = "Tuono"
local Tuono = {}
for k, v in pairs(stub) do if k ~= "state" then _G[k] = v end end
for _, f in ipairs({"Tuono/Core.lua","Tuono/data/rules.lua","Tuono/StateTracker.lua",
  "Tuono/AssistReader.lua","Tuono/Rotation.lua","Tuono/IntelligenceLayer.lua",
  "Tuono/Display.lua","Tuono/Config.lua","Tuono/Highlight.lua","Tuono/ApiTest.lua"}) do
  assert(loadfile(f))("Tuono", Tuono)
end
stub.FireEvent("ADDON_LOADED", "Tuono"); stub.FireEvent("PLAYER_LOGIN"); stub.FireEvent("PLAYER_ENTERING_WORLD")

local out = {}
local function bar(label)
  local r = Tuono.Engine.Evaluate()
  local p = {}
  for i, e in ipairs(r.queue or {}) do p[#p+1] = i .. ":" .. tostring(e.spellID) .. "(" .. tostring(e.source) .. ")" end
  out[#out+1] = label .. " -> " .. (#p > 0 and table.concat(p, "  ") or "*** EMPTY ***")
end

local function kit(list, cp, maxcp)
  Tuono.State.inCombat = true; stub.state.stealthed = false; Tuono.State.stealthed = false
  Tuono.State.buffs.degraded = true
  Tuono.State.buffs.opportunity.up = false; Tuono.State.buffs.opportunity.stacks = 0
  Tuono.State.buffs.adrenalineRush.up = false; Tuono.State.buffs.rtb.stage = 0
  Tuono.State.energy, Tuono.State.energyMax = 100, 100
  Tuono.State.comboPointsMax = maxcp; Tuono.State.comboPoints = cp
  Tuono.State.knownSpells = {}; Tuono.State.knownUnavailable = false
  for _, id in pairs(Tuono.SpellIDs) do if type(id) == "number" then Tuono.State.knownSpells[id] = false end end
  for _, name in ipairs(list) do Tuono.State.knownSpells[Tuono.SpellIDs[name]] = true end
  for k in pairs(Tuono.State.cooldowns) do Tuono.State.cooldowns[k] = { known = true, ready = true, remaining = 0 } end
end

kit({"sinisterStrike"}, 0, 5); bar("ONLY Sinister Strike, 0 CP")
kit({"sinisterStrike"}, 5, 5); bar("ONLY Sinister Strike, 5 CP (max)")
kit({"sinisterStrike","dispatch"}, 5, 5); bar("SS + Dispatch, 5 CP (max)")
kit({"sinisterStrike","dispatch","rollTheBones"}, 0, 5); bar("SS+Dispatch+RtB, 0 CP, no RtB buff")
kit({"sinisterStrike","dispatch","pistolShot"}, 2, 5); bar("SS+Dispatch+PistolShot, 2 CP")
io.write(table.concat(out, "\n") .. "\n")
