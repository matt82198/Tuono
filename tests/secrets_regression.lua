-- Regression harness for the Midnight secret-value failure modes.
--
-- These tests encode the two stacking root causes of the "first icon is frozen and
-- pressing it does nothing" report:
--   R1  AssistReader crashed on a SECRET boolean from C_AssistedCombat.IsAvailable(),
--       aborting Assist.Update before nextSpellID was reassigned -> Blizzard's pick
--       froze at whatever it held when combat started.
--   R2  StateTracker collapsed a SECRET energy read to 0 -> every canAfford() gate
--       failed -> Rotation.Predict returned an EMPTY sequence -> the bar fell through
--       to that frozen pick, showing one static icon instead of a 4-step wheel.
--   R3  Cooldowns whose startTime/duration are secret were reported ready=false,
--       which deleted every cooldown ability from the queue in instanced content.
--
-- Each test FAILS against the pre-fix code, which is the only way it proves anything.

local results = { passed = 0, failed = 0 }
local function check(name, cond, detail)
  if cond then
    results.passed = results.passed + 1
    print("PASS: " .. name)
  else
    results.failed = results.failed + 1
    print("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- Secret-value emulation.
-- Real secrets report their true type() but error on arithmetic/comparison. Lua
-- cannot fake type(), so we use a sentinel table and drive detection through
-- issecretvalue(), which is exactly the gate the addon is required to use.
-- Arithmetic/comparison metamethods error so that any code touching a secret
-- WITHOUT checking first blows up loudly instead of silently coercing.
-- ---------------------------------------------------------------------------
local SECRETS = setmetatable({}, { __mode = "k" })
local function boom() error("attempt to operate on a secret value", 2) end
local SecretMT = {
  __add = boom, __sub = boom, __mul = boom, __div = boom, __mod = boom,
  __pow = boom, __unm = boom, __lt = boom, __le = boom, __len = boom,
  __concat = boom, __tostring = function() return "<secret>" end,
}
local function secret()
  local t = setmetatable({}, SecretMT)
  SECRETS[t] = true
  return t
end

_G.issecretvalue = function(v) return SECRETS[v] == true end

-- ---------------------------------------------------------------------------
-- Minimal WoW surface. Only what the loaded modules actually touch.
-- ---------------------------------------------------------------------------
local clock = 1000
_G.GetTime = function() return clock end

local scenario = {
  energySecret     = false,
  energy           = 100,
  comboPoints      = 0,
  comboPointsMax   = 6,
  stealthed        = false,
  inCombat         = true,
  cooldownSecret   = false,
  cdActive         = {},          -- spellID -> true when on cooldown
  assistSecretAvail = false,
  assistNext       = 1,
}

_G.Enum = { PowerType = { Energy = 3, ComboPoints = 4 } }

_G.UnitPower = function(unit, kind)
  if kind == 3 then
    if scenario.energySecret then return secret() end
    return scenario.energy
  end
  return scenario.comboPoints
end
_G.UnitPowerMax = function(unit, kind)
  if kind == 3 then return 100 end
  return scenario.comboPointsMax
end
_G.UnitClass = function() return "Rogue", "ROGUE" end
_G.GetSpecialization = function() return 2 end
_G.IsStealthed = function() return scenario.stealthed end
_G.GetHaste = function() return 0 end
_G.GetInventoryItemID = function() return nil end
_G.GetInventoryItemTexture = function() return nil end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

_G.C_Spell = {
  GetSpellCooldown = function(spellID)
    local onCD = scenario.cdActive[spellID] and true or false
    if scenario.cooldownSecret then
      -- Timer hidden, but the never-secret booleans still answer "ready?".
      return { startTime = secret(), duration = secret(), isEnabled = true, isActive = onCD }
    end
    if onCD then
      return { startTime = clock, duration = 60, isEnabled = true, isActive = true }
    end
    return { startTime = 0, duration = 0, isEnabled = true, isActive = false }
  end,
  GetSpellTexture = function(spellID)
    -- The "Waiting for Energy" sentinel is identified by this icon.
    if spellID == 1249752 then return 134377 end
    return 1
  end,
  -- Bracketing surface. Both are flagged never-secret, which is the whole reason they
  -- are usable in combat when UnitPower is not.
  GetSpellPowerCost = function(spellID)
    local cost = scenario.costOf and scenario.costOf(spellID) or nil
    if not cost or cost == 0 then return {} end
    return { { type = 3, cost = cost } }
  end,
  IsSpellUsable = function(spellID)
    local cost = scenario.costOf and scenario.costOf(spellID) or nil
    if not cost or cost == 0 then return true, false end
    if scenario.energy >= cost then return true, false end
    return false, true            -- unusable, specifically for want of power
  end,
}
_G.C_SpellBook = { IsSpellKnown = function() return true end }
_G.C_UnitAuras = {
  GetPlayerAuraBySpellID = function() return nil end,
  GetAuraDataByIndex = function() return nil end,
}
_G.C_NamePlate = { GetNamePlates = function() return {} end }
_G.C_AssistedCombat = {
  IsAvailable = function()
    if scenario.assistSecretAvail then return secret(), "restricted" end
    return true, ""
  end,
  GetNextCastSpell = function() return scenario.assistNext end,
  GetRotationSpells = function() return {} end,
}

-- Frames: record handlers so we can drive events, ignore all cosmetic calls.
local eventSinks = {}
local frameMT = {}
frameMT.__index = function(t, k)
  return rawget(t, k) or function(...) return nil end
end
local function newFrame()
  local f = setmetatable({}, frameMT)
  f.RegisterEvent = function(self, e) eventSinks[e] = eventSinks[e] or true end
  f.SetScript = function(self, which, fn)
    if which == "OnEvent" then self._onEvent = fn end
    if which == "OnUpdate" then self._onUpdate = fn end
  end
  f.CreateTexture = function() return newFrame() end
  f.CreateFontString = function() return newFrame() end
  f.GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end
  f.GetName = function() return "stubframe" end
  return f
end
_G.CreateFrame = function() return newFrame() end
_G.UIParent = newFrame()
_G.SlashCmdList = {}
_G.STANDARD_TEXT_FONT = "font"

-- ---------------------------------------------------------------------------
-- Load the addon in real TOC order.
-- ---------------------------------------------------------------------------
local Tuono = {}
local TOC = {
  "Tuono/Core.lua",
  "Tuono/Profiles.lua",
  "Tuono/UserRules.lua",
  "Tuono/profiles/OutlawRogue.lua",
  "Tuono/data/rules.lua",
  "Tuono/StateTracker.lua",
  "Tuono/AssistReader.lua",
  "Tuono/Rotation.lua",
  "Tuono/EnergyModel.lua",
  "Tuono/IntelligenceLayer.lua",
  "Tuono/Config.lua",   -- owns Tuono.defaults; without it Tuono.db is nil
}
for _, file in ipairs(TOC) do
  local fn, err = loadfile(file)
  if not fn then print("FATAL: cannot load " .. file .. ": " .. tostring(err)) os.exit(1) end
  local ok, lerr = pcall(fn, "Tuono", Tuono)
  if not ok then print("FATAL: error in " .. file .. ": " .. tostring(lerr)) os.exit(1) end
end

Tuono.db = Tuono.defaults or {}
Tuono.State.inCombat = true

-- Late-bound so the C_Spell stubs above can read the profile's real cost table, which
-- only exists once the profile has registered.
scenario.costOf = function(spellID)
  local ab = Tuono.Rotation and Tuono.Rotation.ABILITIES and Tuono.Rotation.ABILITIES[spellID]
  return ab and ab.cost or nil
end

-- Core.lua drives each stage through Tuono.safe (a pcall), so a throw inside one stage is
-- swallowed and merely leaves that stage's state stale. Mirror that exactly: a test
-- that let the error propagate would report a crash where production reports a FREEZE,
-- and the freeze is the behaviour under test.
local function tick(dt)
  clock = clock + (dt or 0.1)
  pcall(Tuono.State.RefreshFast)
  pcall(Tuono.Assist.Update)
end

-- ===========================================================================
-- R2: secret energy must not empty the predicted sequence
-- ===========================================================================
-- Every zero-cost cooldown is put ON cooldown so nothing but energy-costing builders
-- can satisfy the priority list. Without this the sequence fills with free abilities
-- (Adrenaline Rush, Blade Rush) and the test passes even when energy handling is
-- broken -- which is exactly how the first draft of this assertion fooled itself.
local function starveCooldowns()
  scenario.cdActive = {}
  for _, id in pairs(Tuono.SpellIDs) do scenario.cdActive[id] = true end
  scenario.cdActive[Tuono.SpellIDs.sinisterStrike] = false
  scenario.cdActive[Tuono.SpellIDs.dispatch] = false
end

scenario.energySecret = false
scenario.energy = 100
scenario.comboPoints = 0
starveCooldowns()
tick(0.1)                        -- seed the shadow model with a real measurement
scenario.energySecret = true     -- Midnight hides energy from here on
tick(0.1)

-- Pre-fix this was a confident 0 ("you have no energy"). The shadow model must instead
-- carry a real positive estimate seeded from the last measurement.
check("R2: secret energy yields a positive ESTIMATE, not a confident zero",
  Tuono.State.energy > 0 and Tuono.State.energyKnown == true,
  "energy=" .. tostring(Tuono.State.energy)
    .. " known=" .. tostring(Tuono.State.energyKnown)
    .. " source=" .. tostring(Tuono.State.energySource))

-- The point of this assertion is that a derived value is never passed off as a direct
-- read. "bracketed" satisfies that just as well as "estimated" -- and is strictly
-- better, being bounded by IsSpellUsable rather than extrapolated. What must NEVER
-- appear here is "measured", which would claim we read the secret.
check("R2: energy is labelled as derived, never as a direct measurement",
  Tuono.State.energySource == "estimated"
    or Tuono.State.energySource == "stale"
    or Tuono.State.energySource == "bracketed",
  "energySource=" .. tostring(Tuono.State.energySource))

local preds = Tuono.Rotation.Predict(Tuono.State, 4)
check("R2: secret energy still yields a 4-step sequence",
  preds and #preds >= 4,
  "got " .. tostring(preds and #preds or "nil") .. " steps")

-- ===========================================================================
-- R2b: a repeated ability must be shown repeatedly, not collapsed to one icon
-- ===========================================================================
scenario.comboPoints = 0
scenario.cdActive = {}
for _, id in pairs(Tuono.SpellIDs) do scenario.cdActive[id] = true end
scenario.cdActive[Tuono.SpellIDs.sinisterStrike] = false
tick(0.1)
local seq = Tuono.Rotation.Predict(Tuono.State, 4)
local ssCount = 0
for _, p in ipairs(seq or {}) do
  if p.spellID == Tuono.SpellIDs.sinisterStrike then ssCount = ssCount + 1 end
end
check("R2b: repeated builder appears once per step (wheel shows repeats)",
  ssCount >= 2,
  "Sinister Strike appeared " .. ssCount .. " time(s) in a 4-step sequence")

-- ===========================================================================
-- R3: secret cooldown timer must still resolve readiness
-- ===========================================================================
scenario.cooldownSecret = true
scenario.cdActive = {}
scenario.cdActive[Tuono.SpellIDs.adrenalineRush] = false   -- AR is READY
scenario.cdActive[Tuono.SpellIDs.bladeRush] = true         -- Blade Rush is ON COOLDOWN
tick(0.1)

check("R3: ready cooldown is known-and-ready despite secret timer",
  Tuono.State.cooldowns.adrenalineRush.known == true
    and Tuono.State.cooldowns.adrenalineRush.ready == true,
  "known=" .. tostring(Tuono.State.cooldowns.adrenalineRush.known)
    .. " ready=" .. tostring(Tuono.State.cooldowns.adrenalineRush.ready))

check("R3: running cooldown is known-and-not-ready despite secret timer",
  Tuono.State.cooldowns.bladeRush.known == true
    and Tuono.State.cooldowns.bladeRush.ready == false,
  "known=" .. tostring(Tuono.State.cooldowns.bladeRush.known)
    .. " ready=" .. tostring(Tuono.State.cooldowns.bladeRush.ready))

check("R3: remaining is flagged unreadable so the UI will not draw a fake number",
  Tuono.State.cooldowns.adrenalineRush.remainingKnown == false,
  "remainingKnown=" .. tostring(Tuono.State.cooldowns.adrenalineRush.remainingKnown))

-- ===========================================================================
-- R1: secret IsAvailable() must not freeze Blizzard's pick
-- ===========================================================================
scenario.cooldownSecret = false
scenario.assistSecretAvail = true
scenario.assistNext = 111
tick(0.1)
local first = Tuono.Assist.nextSpellID
scenario.assistNext = 222
tick(0.1)
local second = Tuono.Assist.nextSpellID

check("R1: assist pick still updates when IsAvailable() is secret",
  first == 111 and second == 222,
  "first=" .. tostring(first) .. " second=" .. tostring(second))

check("R1: secret availability is recorded as unknown, not as 'off'",
  Tuono.Assist.available == true and Tuono.Assist.availabilityKnown == false,
  "available=" .. tostring(Tuono.Assist.available)
    .. " known=" .. tostring(Tuono.Assist.availabilityKnown))

-- ===========================================================================
-- Engine end-to-end: the queue the display actually renders
-- ===========================================================================
scenario.energySecret = true
scenario.cooldownSecret = true
scenario.comboPoints = 0
scenario.cdActive = {}
tick(0.1)
local result = Tuono.Engine.Evaluate()
check("E2E: engine emits a multi-entry queue under full secrecy",
  result and result.queue and #result.queue >= 2,
  "queue length " .. tostring(result and result.queue and #result.queue))

-- ===========================================================================
-- AOE: two rotations, one bar, switched on enemy count with hysteresis
-- ===========================================================================
scenario.energySecret = false
scenario.cooldownSecret = false
scenario.cdActive = {}
scenario.comboPoints = 0
Tuono.db.aoeMode = "auto"
Tuono.db.aoeThreshold = 2

Tuono.State.enemyCount = 1
tick(0.1)
check("AoE: single target below threshold",
  Tuono.Rotation.ResolveMode(Tuono.State) == "single",
  "mode=" .. tostring(Tuono.Rotation.mode) .. " reason=" .. tostring(Tuono.Rotation.modeReason))

Tuono.State.enemyCount = 3
check("AoE: switches to AoE immediately at threshold",
  Tuono.Rotation.ResolveMode(Tuono.State) == "aoe",
  "mode=" .. tostring(Tuono.Rotation.mode))

-- Drop below threshold: must HOLD AoE through the dwell window, not strobe back.
Tuono.State.enemyCount = 1
clock = clock + 0.5
check("AoE: holds AoE during dwell window (no strobing)",
  Tuono.Rotation.ResolveMode(Tuono.State) == "aoe",
  "mode=" .. tostring(Tuono.Rotation.mode) .. " reason=" .. tostring(Tuono.Rotation.modeReason))

clock = clock + 3.0
check("AoE: falls back to single target after dwell expires",
  Tuono.Rotation.ResolveMode(Tuono.State) == "single",
  "mode=" .. tostring(Tuono.Rotation.mode))

-- Unreadable count must HOLD, never snap to single mid-pack.
Tuono.State.enemyCount = 4
Tuono.Rotation.ResolveMode(Tuono.State)
Tuono.State.enemyCount = nil
check("AoE: unreadable enemy count holds the current rotation",
  Tuono.Rotation.ResolveMode(Tuono.State) == "aoe",
  "mode=" .. tostring(Tuono.Rotation.mode) .. " reason=" .. tostring(Tuono.Rotation.modeReason))

-- The two lists must actually differ, or the switch is cosmetic.
Tuono.db.aoeMode = "off"
Tuono.State.enemyCount = 5
scenario.comboPoints = 0
tick(0.1)
local stSeq = Tuono.Rotation.Predict(Tuono.State, 4)
Tuono.db.aoeMode = "on"
tick(0.1)
local aoeSeq = Tuono.Rotation.Predict(Tuono.State, 4)
local function firstOf(seq) return seq and seq[1] and seq[1].spellID end
check("AoE: AoE list produces a different opener than single target",
  firstOf(stSeq) ~= nil and firstOf(aoeSeq) ~= nil and firstOf(stSeq) ~= firstOf(aoeSeq),
  "single=" .. tostring(firstOf(stSeq)) .. " aoe=" .. tostring(firstOf(aoeSeq)))

-- ===========================================================================
-- User-editable rules compile and take effect
-- ===========================================================================
Tuono.db.aoeMode = "auto"
local prof = Tuono.Profiles.Active()
check("Profiles: Outlaw registered and active",
  prof ~= nil and prof.id == "outlaw-rogue",
  "active=" .. tostring(prof and prof.id))

local rows = Tuono.UserRules.GetRows(prof, "single")
check("UserRules: built-in list seeds editable rows",
  rows and #rows > 0,
  "rows=" .. tostring(rows and #rows))

-- Pin Dispatch to the very top with an always-true condition and confirm the engine
-- honours the user's ordering over the profile default.
-- The previous block left the engine in AoE mode with an unreadable count, so pin
-- single-target explicitly: editing the "single" list proves nothing while the engine
-- is reading the "aoe" one.
Tuono.db.aoeMode = "off"
Tuono.State.enemyCount = 1
table.insert(rows, 1, { spellKey = "dispatch", enabled = true, conditions = { { type = "always" } } })
scenario.cdActive = {}
scenario.comboPoints = 0
tick(0.1)
local custom = Tuono.Rotation.Predict(Tuono.State, 4)
check("UserRules: user-ordered rule wins position 1",
  custom and custom[1] and custom[1].spellID == Tuono.SpellIDs.dispatch,
  "got " .. tostring(custom and custom[1] and custom[1].spellID))

Tuono.UserRules.ResetToDefault(prof.id, "single")
tick(0.1)
local restored = Tuono.Rotation.Predict(Tuono.State, 4)
check("UserRules: reset restores the profile default",
  restored and restored[1] and restored[1].spellID ~= Tuono.SpellIDs.dispatch,
  "got " .. tostring(restored and restored[1] and restored[1].spellID))

-- ===========================================================================
-- ONE ROTATION ON THE BAR: Blizzard's pick is a sensor, never an icon
-- ===========================================================================
Tuono.db.aoeMode = "off"
Tuono.State.enemyCount = 1
scenario.energySecret = false
scenario.cooldownSecret = false
scenario.comboPoints = 0
scenario.cdActive = {}
scenario.assistSecretAvail = false
scenario.assistNext = 999999          -- a spellID that is in NO profile list
scenario.energy = 100
tick(0.1)

local r = Tuono.Engine.Evaluate()
local sawAssist = false
for _, e in ipairs(r.queue or {}) do
  if e.spellID == 999999 or e.source == "blizzard_static_fallback" then sawAssist = true end
end
check("Blizzard's pick never appears in the rendered queue",
  not sawAssist, "assist spellID leaked into the queue")

-- Starve everything: no energy, every cooldown down. Pre-change this produced an EMPTY
-- sequence, which is precisely what handed the bar to Blizzard's fallback.
scenario.energy = 0
scenario.energySecret = false
for _, id in pairs(Tuono.SpellIDs) do scenario.cdActive[id] = true end
Tuono.Energy.confidence = "unknown"
Tuono.Energy.lastSyncAt = 0
tick(0.1)
Tuono.Energy.TrySync()
tick(0.1)

local starved = Tuono.Rotation.Predict(Tuono.State, 4)
check("energy starvation yields a POOLING entry, not an empty bar",
  starved and #starved >= 1 and starved[1].confidence == "pooling",
  "len=" .. tostring(starved and #starved)
    .. " conf=" .. tostring(starved and starved[1] and starved[1].confidence))

local rs = Tuono.Engine.Evaluate()
check("pooling entry survives the castability filter",
  rs and rs.queue and #rs.queue >= 1,
  "queue length " .. tostring(rs and rs.queue and #rs.queue))

-- The sensor still runs, it just does not render.
scenario.energy = 100
tick(0.1)
Tuono.Engine.Evaluate()
check("drift sensor records agreement state without queueing it",
  Tuono.Engine.disagreeStreak ~= nil,
  "disagreeStreak=" .. tostring(Tuono.Engine.disagreeStreak))

-- ===========================================================================
-- "Waiting for Energy" sentinel must never be treated as a recommendation
-- ===========================================================================
scenario.assistSecretAvail = false
scenario.assistNext = 1249752          -- Blizzard's pooling placeholder
tick(0.1)
check("sentinel is not stored as an assist pick",
  Tuono.Assist.nextSpellID == nil,
  "nextSpellID=" .. tostring(Tuono.Assist.nextSpellID))
check("sentinel sets the waiting-for-resource flag",
  Tuono.Assist.waitingForResource == true,
  "waiting=" .. tostring(Tuono.Assist.waitingForResource))

-- Detection must also work by icon, so a sibling sentinel Blizzard adds later is
-- caught without an addon update.
check("sentinel is detected by icon as well as by ID",
  Tuono.Assist.IsWaitSentinel(1249752) == true, "icon path failed")

scenario.assistNext = Tuono.SpellIDs.sinisterStrike
tick(0.1)
check("a real pick clears the waiting flag",
  Tuono.Assist.waitingForResource == false
    and Tuono.Assist.nextSpellID == Tuono.SpellIDs.sinisterStrike,
  "waiting=" .. tostring(Tuono.Assist.waitingForResource))

-- ===========================================================================
-- Energy bracketing via IsSpellUsable  (the measurement, not the estimate)
-- ===========================================================================
-- Outlaw ladder: Blade Flurry 15, RtB/BtE 25, Dispatch 35, Pistol Shot 40, SS/KS 45.
scenario.energySecret = true           -- UnitPower hidden, as in real Midnight combat
scenario.energy = 42                   -- affords 40, cannot afford 45

local lower, upper = Tuono.Energy.Bracket()
check("bracket derives a lower bound from the costliest usable ability",
  lower == 40, "lower=" .. tostring(lower))
check("bracket derives an upper bound from the cheapest unaffordable ability",
  upper == 45, "upper=" .. tostring(upper))

-- Cold start: no direct read has EVER succeeded, so dead reckoning has no seed.
-- Bracketing alone must be able to establish a usable value.
Tuono.Energy.confidence = "unknown"
Tuono.Energy.lastSyncAt = 0
Tuono.Energy.value = 0
Tuono.Energy.lastAdvanceAt = 0
Tuono.Energy.Advance()
check("bracketing cold-starts the model with no prior direct read",
  Tuono.Energy.confidence == "bracketed" and Tuono.Energy.value >= 40,
  "conf=" .. tostring(Tuono.Energy.confidence)
    .. " value=" .. tostring(Tuono.Energy.value))

-- Drift correction: force the estimate far above what the bracket permits.
Tuono.Energy.value = 95
Tuono.Energy.ApplyBracket()
check("bracket clamps an over-estimate down below the upper bound",
  Tuono.Energy.value < 45, "value=" .. tostring(Tuono.Energy.value))

Tuono.Energy.value = 5
Tuono.Energy.ApplyBracket()
check("bracket clamps an under-estimate up to the lower bound",
  Tuono.Energy.value >= 40, "value=" .. tostring(Tuono.Energy.value))

check("a bracketed value is not reported as stale",
  select(3, Tuono.Energy.Get()) == "bracketed",
  "conf=" .. tostring(select(3, Tuono.Energy.Get())))

-- Full energy: nothing is unaffordable, so there is no upper bound to infer.
scenario.energy = 100
local lo2, up2 = Tuono.Energy.Bracket()
-- Costliest energy ability is Ambush at 50 (was asserted as 45 back when Ambush was
-- wrongly modelled as free and Sinister Strike topped the ladder).
check("no upper bound when everything is affordable",
  lo2 == 50 and up2 == nil,
  "lower=" .. tostring(lo2) .. " upper=" .. tostring(up2))

-- ===========================================================================
-- Sentinel anchoring: the falling edge is an EXACT energy reading
-- ===========================================================================
local SS = Tuono.SpellIDs.sinisterStrike       -- 45 energy
scenario.energySecret = true
scenario.energy = 100                          -- keep the bracket from fighting us

-- Enter the wait, then clear it. Energy must land exactly on the cost of the ability
-- the engine was waiting to afford.
scenario.assistNext = 1249752
tick(0.1); tick(0.1)
Tuono.Energy.value = 3                          -- deliberately wrong going in
scenario.assistNext = SS
tick(0.1); tick(0.1)

check("sentinel clear anchors energy to the cost of the revealed ability",
  Tuono.Energy.value == 45 and Tuono.Energy.confidence == "anchored",
  "value=" .. tostring(Tuono.Energy.value)
    .. " conf=" .. tostring(Tuono.Energy.confidence))

-- A second anchor with a known spend between the two lets us SOLVE for regen:
--   regen = (C2 - C1 + spent) / dt = (45 - 45 + 45) / 4 = 11.25
Tuono.Energy.OnCast(SS)                         -- spends 45, books it against the anchor
scenario.assistNext = 1249752
tick(0.1)
clock = clock + 4.0
scenario.assistNext = SS
tick(0.1); tick(0.1)

check("two anchors plus the spend ledger measure the real regen rate",
  Tuono.Energy.measuredRegen ~= nil
    and Tuono.Energy.measuredRegen > 5 and Tuono.Energy.measuredRegen < 60,
  "measuredRegen=" .. tostring(Tuono.Energy.measuredRegen))

check("measured regen replaces the hardcoded Combat Potency guess",
  Tuono.Energy.EffectiveRegen() == Tuono.Energy.measuredRegen,
  "effective=" .. tostring(Tuono.Energy.EffectiveRegen()))

-- Implausible samples must be rejected rather than smeared into the average.
-- NOTE ON TICK COUNTS: ObserveAssist runs inside RefreshFast, which the update loop
-- calls BEFORE Assist.Update, so it always sees the PREVIOUS tick's assist state and
-- the falling edge lands one tick late. An earlier version of this test used a single
-- tick after revealing the spell, so the edge was never processed at all and the
-- assertion passed no matter what the code did -- it survived deleting BOTH rejection
-- guards. Two ticks after each transition, or it proves nothing.
local goodRate = Tuono.Energy.measuredRegen
scenario.assistNext = 1249752
tick(0.01); tick(0.01)
Tuono.Energy.anchor = { value = 45, at = GetTime(), spentSince = 0 }
scenario.assistNext = SS
tick(0.01); tick(0.01)                          -- dt far below MIN_OBS_DT
check("implausibly short observation windows are rejected",
  Tuono.Energy.measuredRegen == goodRate,
  "regen moved to " .. tostring(Tuono.Energy.measuredRegen))

-- A free ability revealing on the clear tells us nothing about energy.
Tuono.Energy.value = 20
Tuono.Energy.confidence = "estimated"
scenario.assistNext = 1249752
tick(0.1)
scenario.assistNext = Tuono.SpellIDs.adrenalineRush     -- 0 cost
tick(0.1); tick(0.1)
check("a zero-cost reveal does not anchor",
  Tuono.Energy.confidence ~= "anchored",
  "conf=" .. tostring(Tuono.Energy.confidence))

-- ===========================================================================
-- UNIT_AURA payload is secret in combat  (reported from a live 12.1.0 client)
-- ===========================================================================
-- `if updateInfo.isFullUpdate then` is a BOOLEAN TEST ON A SECRET, which raises.
-- OnUnitAura runs inside Tuono.safe, so the throw was swallowed and the whole Tier-1
-- delta path died silently on every aura event in combat -- the same failure shape as
-- the IsAvailable() freeze. Nothing looked broken; buffs simply stopped updating.
--
-- HARNESS LIMIT, STATED PLAINLY: Lua has no metamethod for a truthiness test, so this
-- stub CANNOT make `if secretValue then` raise the way the real client does. Mutation
-- testing confirms it: reinstating the raw boolean test leaves three of the four
-- assertions below green. Only the fully-secret-payload case is genuinely sensitive
-- (indexing a secret table DOES raise, and that we can emulate).
--
-- So treat these as verifying that the guards exist and that absent is distinguished
-- from secret -- not as proof the client's throw is handled. That proof only comes
-- from the live client, which is where this bug was found in the first place.
local auraHandlers = Tuono.eventHandlers and Tuono.eventHandlers["UNIT_AURA"]
check("UNIT_AURA has a registered handler to exercise",
  auraHandlers and #auraHandlers > 0, "no UNIT_AURA handler")

if auraHandlers and #auraHandlers > 0 then
  local fire = function(payload)
    for _, h in ipairs(auraHandlers) do pcall(h, "UNIT_AURA", "player", payload) end
  end

  -- A secret isFullUpdate must degrade cleanly, not throw and not corrupt state.
  Tuono.State.buffs.degraded = false
  fire({ isFullUpdate = secret() })
  check("secret isFullUpdate degrades instead of throwing",
    Tuono.State.buffs.degraded == true,
    "degraded=" .. tostring(Tuono.State.buffs.degraded))

  -- A wholly secret payload: even INDEXING it throws, so the guard must come first.
  Tuono.State.buffs.degraded = false
  fire(secret())
  check("a fully secret payload degrades instead of throwing",
    Tuono.State.buffs.degraded == true,
    "degraded=" .. tostring(Tuono.State.buffs.degraded))

  -- Secret ARRAYS: ipairs and # both throw on one.
  Tuono.State.buffs.degraded = false
  fire({ addedAuras = secret(), removedAuraInstanceIDs = secret() })
  check("secret delta arrays degrade instead of throwing",
    Tuono.State.buffs.degraded == true,
    "degraded=" .. tostring(Tuono.State.buffs.degraded))

  -- REGRESSION GUARD: absent is NOT secret. An ordinary delta omits isFullUpdate, and
  -- treating that omission as unreadable killed every normal aura update -- which is
  -- exactly what the first version of this fix did.
  Tuono.State.buffs.degraded = false
  Tuono.State.buffs.adrenalineRush.up = false
  fire({ addedAuras = { {
    auraInstanceID = 4242,
    spellId = Tuono.SpellIDs.adrenalineRush,
    expirationTime = GetTime() + 20,
  } } })
  check("an ordinary delta (no isFullUpdate) still applies",
    Tuono.State.buffs.adrenalineRush.up == true,
    "adrenalineRush.up=" .. tostring(Tuono.State.buffs.adrenalineRush.up))
end

print("")
print(string.format("SECRETS REGRESSION: %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
