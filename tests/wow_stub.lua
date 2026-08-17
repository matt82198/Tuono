-- ============================================================================
-- WOW API STUB
-- ============================================================================
-- Enough of the WoW client to load and drive Tuono outside the game. Every function
-- here answers from `stub.state`, so a test sets up a world, ticks it, and asserts on
-- what the addon decided.
--
-- WHAT THIS DELIBERATELY DOES NOT MODEL, and why it matters:
--
--   * `if secretValue then` raises in the real client. Lua has no __tobool metamethod,
--     so a stub secret is a table and tests truthy. Any code that boolean-tests a raw
--     secret will PASS here and THROW in game. This is why the addon must read through
--     Tuono.readBool -- and why `tests/lint_secrets.lua` exists to check that it does.
--   * `secret == number` returns false in Lua rather than raising, for the same reason
--     (__eq only fires table-to-table).
--
-- Arithmetic and ordered comparison DO raise, which covers the majority of the real
-- failure surface.
-- ============================================================================

local stub = {}

local SECRET = setmetatable({}, { __tostring = function() return "SECRET_MARKER" end })

-- CAPTURE THE PRISTINE type/print EXACTLY ONCE, ACROSS REPEATED LOADS.
--
-- harness.load() re-executes this file for every test, to get a clean world. But the
-- overrides below install wrappers into _G, so a plain `local real_type = type` on the
-- second load captures the FIRST load's wrapper rather than Lua's own. Each load then
-- adds a frame to every type() call, and type() is called thousands of times per boot.
-- At ~60 tests that is quadratic and the suite stops finishing -- which is exactly the
-- "full run hangs but every suite passes alone" symptom this stub produced.
--
-- Stashing the originals in _G makes re-execution idempotent.
_G.__wow_stub_pristine_type = _G.__wow_stub_pristine_type or type
_G.__wow_stub_pristine_print = _G.__wow_stub_pristine_print or print
local real_type = _G.__wow_stub_pristine_type

-- --- secret values ----------------------------------------------------------

local function secretError()
  error("attempted to use a secret value", 2)
end

function stub.makeSecret(value)
  return setmetatable({}, {
    __index = function() secretError() end,
    __lt = secretError, __le = secretError,
    __add = secretError, __sub = secretError,
    __mul = secretError, __div = secretError, __mod = secretError,
    __unm = secretError, __len = secretError,
    __concat = secretError,
    __tostring = function() return "<secret>" end,
    [SECRET] = true,
    __secret_real_type = real_type(value),
    __secret_value = value,
  })
end

local function isSecretTable(v)
  if real_type(v) ~= "table" then return false end
  local mt = getmetatable(v)
  return (mt and mt[SECRET]) and true or false
end

-- --- world state ------------------------------------------------------------

function stub.reset()
  stub.state = {
    time = 1000,
    -- `secret` names which reads come back hidden. Midnight hides energy
    -- unconditionally, so that is the default.
    secret = { energy = true, comboPoints = false, haste = false, auras = false },
    energy = 100,
    energyMax = 100,
    comboPoints = 0,
    comboPointsMax = 6,
    inCombat = false,
    stealthed = false,
    haste = 18.3,
    powerRegen = 13.72,
    spec = 2,
    class = "ROGUE",
    -- spellID -> { startTime, duration }
    cooldowns = {},
    -- spellID -> energy cost, used by IsSpellUsable/GetSpellPowerCost
    costs = {
      [193315] = 45, [8676] = 50, [1214909] = 25, [315341] = 25,
      [51690] = 45, [2098] = 35, [185763] = 40, [13877] = 15,
    },
    knownSpells = {},         -- spellID -> true/false; nil means "not asked about"
    auras = {},               -- array of { spellId, name, applications, expirationTime, duration }
    trinkets = {},            -- slot -> { itemID, startTime, duration }
    actionSlots = {},         -- slot -> { type = "spell", id = spellID }
    bindings = {},            -- binding name -> key string
    assist = { available = true, nextSpell = nil, rotationSpells = {} },
    bonusBarOffset = 0,
    actionBarPage = 1,
    errors = {},              -- UI error messages raised this run
  }
  stub.frames = {}
  stub.eventHandlers = {}     -- event -> { {fn = , unit = } }
  stub.slashCommands = {}
  stub.printed = {}
end

-- --- event + tick driving ---------------------------------------------------

function stub.FireEvent(event, ...)
  for _, frame in ipairs(stub.frames) do
    if frame.events[event] and frame.scripts.OnEvent then
      frame.scripts.OnEvent(frame, event, ...)
    end
  end
end

-- Advance time and run every OnUpdate. `dt` is a real elapsed interval, so a test that
-- wants N engine ticks must advance at least N * the addon's throttle.
function stub.Tick(dt)
  stub.state.time = stub.state.time + dt
  for _, frame in ipairs(stub.frames) do
    if frame.scripts.OnUpdate then
      frame.scripts.OnUpdate(frame, dt)
    end
  end
end

-- --- frames -----------------------------------------------------------------

local function makeRegion()
  local r = {}
  r.visible = false
  function r:SetAllPoints() end
  function r:SetPoint() end
  function r:ClearAllPoints() end
  function r:SetSize() end
  function r:SetColorTexture(a, b, c, d) self.color = { a, b, c, d } end
  function r:SetVertexColor(a, b, c, d) self.vertex = { a, b, c, d } end
  function r:SetTexture(t) self.texture = t end
  function r:SetText(t) self.text = t end
  function r:SetFormattedText(fmt, ...) self.text = string.format(fmt, ...) end
  function r:GetText() return self.text end
  function r:SetTextColor() end
  function r:SetFont() end
  function r:SetAlpha(a) self.alpha = a end
  function r:GetAlpha() return self.alpha or 1 end
  function r:Show() self.visible = true end
  function r:Hide() self.visible = false end
  function r:IsVisible() return self.visible end
  function r:IsShown() return self.visible end
  return r
end

function CreateFrame(frameType, name, parent, template)
  local frame = makeRegion()
  frame.frameType = frameType
  frame.name = name
  frame.parent = parent
  frame.template = template
  frame.scripts = {}
  frame.events = {}
  frame.visible = true
  frame.regions = {}

  function frame:GetName() return self.name end
  function frame:RegisterEvent(event) self.events[event] = true end
  function frame:RegisterUnitEvent(event, unit) self.events[event] = unit or true end
  function frame:UnregisterEvent(event) self.events[event] = nil end
  function frame:SetScript(which, handler) self.scripts[which] = handler end
  function frame:GetScript(which) return self.scripts[which] end
  function frame:SetScale(s) self.scale = s end
  function frame:SetMovable(m) self.movable = m end
  function frame:EnableMouse(e) self.mouse = e end
  function frame:RegisterForDrag(b) self.dragButton = b end
  function frame:GetPoint() return self.point or "CENTER", nil, nil, self.x or 0, self.y or 0 end
  function frame:StartMoving() end
  function frame:StopMovingOrSizing() end
  function frame:SetFrameStrata(s) self.strata = s end
  function frame:SetCooldown(start, duration)
    self.cdStart, self.cdDuration = start, duration
    self.setCooldownCalls = (self.setCooldownCalls or 0) + 1
  end
  function frame:GetCooldownTimes() return (self.cdStart or 0) * 1000, (self.cdDuration or 0) * 1000 end
  function frame:GetCooldownDuration() return (self.cdDuration or 0) * 1000 end
  function frame:SetValue(v) self.value = v end
  function frame:GetValue() return self.value end
  function frame:SetMinMaxValues() end

  function frame:CreateTexture(texName, layer)
    local t = makeRegion()
    t.name, t.layer = texName, layer
    table.insert(self.regions, t)
    return t
  end
  function frame:CreateFontString(fsName, layer, template2)
    local fs = makeRegion()
    fs.name, fs.layer, fs.template = fsName, layer, template2
    fs.text = ""
    table.insert(self.regions, fs)
    return fs
  end

  table.insert(stub.frames, frame)
  return frame
end

-- --- core APIs --------------------------------------------------------------

function GetTime() return stub.state.time end

local function maybeSecret(kind, value)
  if stub.state.secret[kind] then return stub.makeSecret(value) end
  return value
end

_G.Enum = {
  PowerType = { Energy = 3, ComboPoints = 4, Mana = 0 },
  AddOnRestrictionType = { Combat = 1, Encounter = 2, ChallengeMode = 3, PvPMatch = 4, Map = 5, Chat = 6 },
}

function UnitPower(unit, powerType)
  if unit ~= "player" then return 0 end
  if powerType == 3 then return maybeSecret("energy", stub.state.energy) end
  if powerType == 4 then return maybeSecret("comboPoints", stub.state.comboPoints) end
  return 0
end

function UnitPowerMax(unit, powerType)
  if unit ~= "player" then return 0 end
  if powerType == 3 then return stub.state.energyMax end
  if powerType == 4 then return stub.state.comboPointsMax end
  return 0
end

function UnitClass(unit)
  if unit == "player" then return "Rogue", stub.state.class end
  return nil
end

function UnitAffectingCombat(unit)
  return unit == "player" and stub.state.inCombat or false
end

function GetSpecialization() return stub.state.spec end
function GetSpecializationInfo(i) return 260, "Outlaw" end

function GetHaste() return maybeSecret("haste", stub.state.haste) end
function UnitSpellHaste() return maybeSecret("haste", stub.state.haste) end
function GetMeleeHaste() return maybeSecret("haste", stub.state.haste) end
function UnitAttackSpeed() return maybeSecret("haste", 1.23) end
function GetPowerRegenForPowerType(pt) return stub.state.powerRegen end
function GetPowerRegen() return stub.state.powerRegen end
function UnitPowerDisplayMod() return 1 end

function GetBuildInfo() return "12.1.0", "69273", "2026-08-01", 120100 end
function GetInstanceInfo() return "Test", "none", 0, "Normal" end
function IsInInstance() return false, "none" end

function GetBonusBarOffset() return stub.state.bonusBarOffset end
function GetActionBarPage() return stub.state.actionBarPage end
_G.NUM_ACTIONBAR_PAGES = 6
_G.NUM_ACTIONBAR_BUTTONS = 12
_G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
_G.SPELL_FAILED_NO_POWER = "Not enough energy"
_G.ERR_OUT_OF_ENERGY = "Not enough energy"

function GetActionInfo(slot)
  local a = stub.state.actionSlots[slot]
  if not a then return nil end
  return a.type or "spell", a.id
end

function GetBindingKey(name) return stub.state.bindings[name] end

function GetInventoryItemID(unit, slot)
  local t = stub.state.trinkets[slot]
  return t and t.itemID or nil
end

function GetInventoryItemTexture(unit, slot)
  return stub.state.trinkets[slot] and 12345 or nil
end

-- --- namespaced APIs --------------------------------------------------------

local function cooldownFor(spellID)
  local cd = stub.state.cooldowns[spellID]
  if not cd then return { startTime = 0, duration = 0, isEnabled = true } end
  return { startTime = cd.startTime, duration = cd.duration, isEnabled = true }
end

_G.C_Spell = {
  GetSpellCooldown = function(spellID) return cooldownFor(spellID) end,
  GetSpellTexture = function(spellID) return 100000 + (spellID or 0) end,
  GetSpellInfo = function(spellID) return { name = "Spell" .. tostring(spellID), spellID = spellID } end,
  GetSpellName = function(spellID) return "Spell" .. tostring(spellID) end,
  -- Never-secret, per the model's load-bearing assumption. Answers from real energy.
  IsSpellUsable = function(spellID)
    local cost = stub.state.costs[spellID]
    if not cost then return true, false end
    if stub.state.energy < cost then return false, true end
    return true, false
  end,
  GetSpellPowerCost = function(spellID)
    local cost = stub.state.costs[spellID]
    if not cost then return {} end
    return { { type = 3, cost = cost } }
  end,
  GetOverrideSpell = function(spellID) return spellID end,
  GetBaseSpell = function(spellID) return spellID end,
}

_G.C_SpellBook = {
  IsSpellKnown = function(spellID)
    local k = stub.state.knownSpells[spellID]
    if k == nil then return true end
    return k
  end,
  IsSpellInSpellBook = function(spellID)
    local k = stub.state.knownSpells[spellID]
    if k == nil then return true end
    return k
  end,
}

function IsSpellKnown(spellID)
  local k = stub.state.knownSpells[spellID]
  if k == nil then return true end
  return k
end

_G.C_UnitAuras = {
  GetAuraDataByIndex = function(unit, index, filter)
    if unit ~= "player" then return nil end
    local a = stub.state.auras[index]
    if not a then return nil end
    if stub.state.secret.auras then
      return {
        spellId = a.spellId,
        name = a.name,
        applications = stub.makeSecret(a.applications or 0),
        expirationTime = stub.makeSecret(a.expirationTime or 0),
        duration = stub.makeSecret(a.duration or 0),
      }
    end
    return a
  end,
  GetPlayerAuraBySpellID = function(spellID)
    for _, a in ipairs(stub.state.auras) do
      if a.spellId == spellID then
        if stub.state.secret.auras then
          return {
            spellId = a.spellId, name = a.name,
            applications = stub.makeSecret(a.applications or 0),
            expirationTime = stub.makeSecret(a.expirationTime or 0),
          }
        end
        return a
      end
    end
    return nil
  end,
}

_G.C_Item = {
  GetItemCooldown = function(itemID)
    for _, t in pairs(stub.state.trinkets) do
      if t.itemID == itemID then return t.startTime, t.duration, true end
    end
    return 0, 0, true
  end,
  GetItemInfo = function(itemID) return "Trinket" .. tostring(itemID) end,
  GetItemSpell = function(itemID) return "Use", 12345 end,
}

_G.C_AssistedCombat = {
  IsAvailable = function() return stub.state.assist.available end,
  GetNextCastSpell = function() return stub.state.assist.nextSpell end,
  GetRotationSpells = function() return stub.state.assist.rotationSpells end,
  GetActionSpell = function(a) return a end,
}

_G.C_ActionBar = {
  FindSpellActionButtons = function(spellID)
    local out = {}
    for slot, a in pairs(stub.state.actionSlots) do
      if a.id == spellID then table.insert(out, slot) end
    end
    table.sort(out)
    return out
  end,
}

_G.C_Secrets = {
  ShouldUnitPowerBeSecret = function() return stub.state.secret.energy end,
  ShouldUnitStatsBeSecret = function() return stub.state.secret.haste end,
  ShouldAurasBeSecret = function() return stub.state.secret.auras end,
  GetPowerTypeSecrecy = function(pt) return pt == 3 and 2 or 0 end,
  HasSecretRestrictions = function() return true end,
  GetSpellAuraSecrecy = function() return nil end,
}

_G.C_RestrictedActions = {
  IsAddOnRestrictionActive = function(kind) return stub.state.inCombat end,
}

_G.C_NamePlate = {
  GetNamePlates = function() return {} end,
}

_G.C_Timer = {
  After = function(delay, fn) table.insert(stub.pendingTimers or {}, { at = stub.state.time + delay, fn = fn }) end,
}

-- --- misc globals -----------------------------------------------------------

function wipe(t)
  for k in pairs(t) do t[k] = nil end
  return t
end

_G.SlashCmdList = {}

-- Same reasoning as real_type above: take the pristine print, never the last wrapper.
local realPrint = _G.__wow_stub_pristine_print
function _G.print(msg)
  table.insert(stub.printed, tostring(msg))
end
stub.realPrint = realPrint

function _G.issecretvalue(v) return isSecretTable(v) end

function _G.type(x)
  if isSecretTable(x) then
    return getmetatable(x).__secret_real_type or "table"
  end
  return real_type(x)
end

function _G.date(fmt) return "2026-01-01 00:00:00" end

-- --- helpers for tests ------------------------------------------------------

-- Put a spell on cooldown as of now.
function stub.setCooldown(spellID, duration)
  stub.state.cooldowns[spellID] = { startTime = stub.state.time, duration = duration }
end

function stub.clearCooldown(spellID)
  stub.state.cooldowns[spellID] = nil
end

function stub.addAura(spellId, name, applications, remaining)
  table.insert(stub.state.auras, {
    spellId = spellId,
    name = name,
    applications = applications or 0,
    duration = remaining or 30,
    expirationTime = stub.state.time + (remaining or 30),
  })
end

function stub.clearAuras()
  stub.state.auras = {}
end

function stub.placeOnBar(slot, spellID)
  stub.state.actionSlots[slot] = { type = "spell", id = spellID }
end

stub.reset()

return stub
