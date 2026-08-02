-- What does the bar show for a MINIMAL kit? (fresh-80 worst case)
local stub = require("tests.wow_stub")
_G.ADDON_NAME = "OutlawAssist"
local OA = {}
for k, v in pairs(stub) do if k ~= "state" then _G[k] = v end end
for _, f in ipairs({"OutlawAssist/Core.lua","OutlawAssist/data/rules.lua","OutlawAssist/StateTracker.lua",
  "OutlawAssist/AssistReader.lua","OutlawAssist/Rotation.lua","OutlawAssist/IntelligenceLayer.lua",
  "OutlawAssist/Display.lua","OutlawAssist/Config.lua","OutlawAssist/Highlight.lua","OutlawAssist/ApiTest.lua"}) do
  assert(loadfile(f))("OutlawAssist", OA)
end
stub.FireEvent("ADDON_LOADED", "OutlawAssist"); stub.FireEvent("PLAYER_LOGIN"); stub.FireEvent("PLAYER_ENTERING_WORLD")

local out = {}
local function bar(label)
  local r = OA.Engine.Evaluate()
  local p = {}
  for i, e in ipairs(r.queue or {}) do p[#p+1] = i .. ":" .. tostring(e.spellID) .. "(" .. tostring(e.source) .. ")" end
  out[#out+1] = label .. " -> " .. (#p > 0 and table.concat(p, "  ") or "*** EMPTY ***")
end

local function kit(list, cp, maxcp)
  OA.State.inCombat = true; stub.state.stealthed = false; OA.State.stealthed = false
  OA.State.buffs.degraded = true
  OA.State.buffs.opportunity.up = false; OA.State.buffs.opportunity.stacks = 0
  OA.State.buffs.adrenalineRush.up = false; OA.State.buffs.rtb.stage = 0
  OA.State.energy, OA.State.energyMax = 100, 100
  OA.State.comboPointsMax = maxcp; OA.State.comboPoints = cp
  OA.State.knownSpells = {}; OA.State.knownUnavailable = false
  for _, id in pairs(OA.SpellIDs) do if type(id) == "number" then OA.State.knownSpells[id] = false end end
  for _, name in ipairs(list) do OA.State.knownSpells[OA.SpellIDs[name]] = true end
  for k in pairs(OA.State.cooldowns) do OA.State.cooldowns[k] = { known = true, ready = true, remaining = 0 } end
end

kit({"sinisterStrike"}, 0, 5); bar("ONLY Sinister Strike, 0 CP")
kit({"sinisterStrike"}, 5, 5); bar("ONLY Sinister Strike, 5 CP (max)")
kit({"sinisterStrike","dispatch"}, 5, 5); bar("SS + Dispatch, 5 CP (max)")
kit({"sinisterStrike","dispatch","rollTheBones"}, 0, 5); bar("SS+Dispatch+RtB, 0 CP, no RtB buff")
kit({"sinisterStrike","dispatch","pistolShot"}, 2, 5); bar("SS+Dispatch+PistolShot, 2 CP")
io.write(table.concat(out, "\n") .. "\n")
