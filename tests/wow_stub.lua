-- WoW API stub for pure-Lua testing
--
-- MERGED HARNESS. This is the original 746-line stub (broad client surface: nameplates,
-- threat, action slots, spell overrides, full frame/texture/fontstring API) extended with
-- the capabilities the newer harness added -- chiefly C_Spell.IsSpellUsable and
-- GetSpellPowerCost, without which EnergyModel's interval bracket never runs at all and
-- the whole inversion model goes untested.
--
-- WHAT THIS STILL CANNOT MODEL, and it matters:
--   * `if secretValue then` RAISES in the live client. Lua has no __tobool metamethod, so
--     a stub secret is a table and tests truthy. Any code that boolean-tests a raw secret
--     PASSES here and THROWS in game. That gap is why tests/lint_secrets.lua exists, and
--     it is a static check precisely because no stub can catch it.
--   * `secret == number` returns false rather than raising, for the same reason: __eq
--     only fires table-to-table.
--   * Geometry. SetPoint/SetAllPoints record nothing, so tests assert on structure and
--     recorded values, never on pixels.
-- Arithmetic and ordered comparison DO raise, which covers most of the real surface.
local stub = {}

-- CAPTURE THE PRISTINE type/print EXACTLY ONCE, ACROSS REPEATED LOADS.
-- harness.load() re-executes this file for every test to get a clean world, but the
-- overrides below install wrappers into _G -- so a plain `local real_type = type` on the
-- second load captures the FIRST load's wrapper. Each load then adds a frame to every
-- type() call, and type() runs thousands of times per boot. At ~60 tests that is
-- quadratic and the suite stops finishing, which is exactly the "every suite passes alone
-- but the full run hangs" symptom this stub produced once already.
_G.__wow_stub_pristine_type = _G.__wow_stub_pristine_type or type
_G.__wow_stub_pristine_print = _G.__wow_stub_pristine_print or print

stub.state = {
  -- THE CLOCK MUST NOT START AT ZERO. NormalizeCooldown reads startTime == 0 as
  -- 'no cooldown running', which is correct WoW semantics -- so a stub clock at 0
  -- made stub.setCooldown() write startTime=0 and EVERY cooldown read as ready,
  -- however long a test had just put it down. Cooldown assertions were vacuous.
  time = 1000,
  energy = 50,
  energyMax = 100,
  comboPoints = 2,
  -- Default to a LEVELLING rogue (5), not a geared one. Hardcoding 6 meant the whole
  -- suite only ever exercised max-level play while the user levelled.
  comboPointsMax = 5,
  inCombat = false,
  combatSecrets = false, -- Mode: when true, UnitPower/cooldown APIs return secret values
  buffs = {
    adrenalineRush = false,
    adrenalineRushExpires = 0,
    opportunity = false,
    opportunityExpires = 0,
    rollTheBones = false,
    rollTheBonesStage = 0,
    rollTheBonesExpires = 0
  },
  cooldowns = {
    [13750] = { startTime = 0, duration = 0 }, -- adrenalineRush
    [271877] = { startTime = 0, duration = 0 }, -- bladeRush
    [14185] = { startTime = 0, duration = 0 }  -- preparation
  },
  trinkets = {
    [13] = { itemID = 123456, startTime = 0, duration = 0 },
    [14] = { itemID = 123457, startTime = 0, duration = 0 }
  },
  spec = 2, -- Outlaw
  class = "ROGUE",

  -- --- added by the harness merge ------------------------------------------------
  -- Per-channel secrecy. `combatSecrets` above is the original coarse switch and still
  -- works; this table lets a test hide ONE channel, which is what Midnight actually does
  -- (energy is secret unconditionally while combo points stay readable).
  secret = { energy = false, comboPoints = false, haste = false, auras = false },

  -- Energy cost per spellID. Drives IsSpellUsable/GetSpellPowerCost, which is what makes
  -- EnergyModel's interval bracket run at all -- the original stub had neither, so the
  -- entire inversion model was untested by 183 behavioural tests.
  costs = {
    [193315] = 45,  -- Sinister Strike
    [8676]   = 50,  -- Ambush
    [1214909] = 25, -- Roll the Bones
    [315341] = 25,  -- Between the Eyes
    [51690]  = 45,  -- Killing Spree
    [2098]   = 35,  -- Dispatch
    [185763] = 40,  -- Pistol Shot
    [13877]  = 15,  -- Blade Flurry
  },

  auras = {},        -- array form, appended to the flat `buffs` flags above
  knownSpells = {},  -- spellID -> true/false; nil means "never asked"
  bindings = {},     -- binding name -> key string
  haste = 18.3,
  powerRegen = 13.72,
  assist = { available = true, nextSpell = nil, rotationSpells = {} },
  errors = {},
}


stub.eventHandlers = {}
stub.frameScripts = {}
stub.frames = {}
stub.slashCommands = {}
stub.nameplates = {}
stub.threatLevels = {}

function stub.FireEvent(event, ...)
  local handlers = stub.eventHandlers[event] or {}
  for _, handler in ipairs(handlers) do
    handler(event, ...)
  end

  -- Also fire through any registered frames' OnEvent handlers
  -- This ensures Tuono.frame receives events properly
  for _, frame in ipairs(stub.frames) do
    if frame.scripts.OnEvent then
      frame.scripts.OnEvent(frame, event, ...)
    end
  end
end

function stub.Tick(dt)
  stub.state.time = stub.state.time + dt
  local frames = stub.frames
  for _, frame in ipairs(frames) do
    if frame.scripts.OnUpdate then
      frame.scripts.OnUpdate(frame, dt)
    end
  end
end

-- Global WoW API mocks

function CreateFrame(frameType, name, parent)
  local frame = {
    name = name,
    parent = parent,
    scripts = {},
    events = {},
    visible = true
  }
  table.insert(stub.frames, frame)

  -- Frame geometry/cooldown methods the real API exposes on frames (a stub that
  -- omits them makes real code look broken and hides real breakage).
  function frame:SetAllPoints(f) self.allPoints = f or true end
  function frame:GetSize() return self.w or 0, self.h or 0 end
  function frame:GetWidth() return self.w or 0 end
  function frame:GetHeight() return self.h or 0 end
  function frame:SetAlpha(a) self.alpha = a end
  function frame:GetAlpha() return self.alpha or 1 end
  function frame:SetDesaturated(d) self.desaturated = d end
  function frame:IsShown() return self.visible == true end
  function frame:IsVisible() return self.visible == true end
  function frame:SetCooldown(start, duration)
    self.cdStart, self.cdDuration = start, duration
    -- Counted: display tests assert a sweep is armed ONCE per cooldown rather than
    -- re-armed every tick, which is a real strobe bug this makes visible.
    self.setCooldownCalls = (self.setCooldownCalls or 0) + 1
  end
  function frame:SetSwipeColor() end
  function frame:SetDrawEdge() end
  function frame:SetReverse() end
  function frame:SetHideCountdownNumbers() end

  -- Added by the harness merge. Core.lua prefers RegisterUnitEvent and falls back to
  -- RegisterEvent when it is absent, so the original stub worked -- but it silently
  -- exercised the fallback path instead of the one the addon actually uses in game.
  function frame:RegisterUnitEvent(event, unit)
    self.events[event] = unit or true
    if stub.eventHandlers then
      stub.eventHandlers[event] = stub.eventHandlers[event] or {}
    end
  end
  function frame:UnregisterEvent(event) self.events[event] = nil end
  function frame:GetName() return self.name end
  function frame:GetScript(which) return self.scripts and self.scripts[which] end
  function frame:ClearAllPoints() end
  function frame:SetFrameStrata(v) self.strata = v end
  function frame:SetFrameLevel(v) self.frameLevel = v end
  function frame:SetParent(p) self.parent = p end
  function frame:SetMinMaxValues() end
  function frame:SetValue(v) self.value = v end
  function frame:GetValue() return self.value end
  function frame:GetCooldownTimes()
    return (self.cdStart or 0) * 1000, (self.cdDuration or 0) * 1000
  end
  function frame:GetCooldownDuration() return (self.cdDuration or 0) * 1000 end

  function frame:RegisterEvent(event)
    self.events[event] = true
  end

  function frame:SetScript(event, handler)
    self.scripts[event] = handler
  end

  function frame:SetSize(w, h)
    self.w, self.h = w, h
    self.width = w
    self.height = h
  end

  function frame:SetPoint(point, relFrame, relPoint, x, y)
    self.point = point or "CENTER"
    self.x = x or 0
    self.y = y or -180
  end

  function frame:SetScale(s)
    self.scale = s
  end

  function frame:SetMovable(m)
    self.movable = m
  end

  function frame:EnableMouse(e)
    self.mouseEnabled = e
  end

  function frame:RegisterForDrag(button)
    self.dragButton = button
  end

  function frame:GetPoint()
    return self.point, nil, nil, self.x, self.y
  end

  function frame:StartMoving()
    self.moving = true
  end

  function frame:StopMovingOrSizing()
    self.moving = false
  end

  function frame:Show()
    self.visible = true
  end

  function frame:Hide()
    self.visible = false
  end

  function frame:IsVisible()
    return self.visible
  end

  function frame:GetWidth()
    return self.width or 200
  end

  function frame:GetHeight()
    return self.height or 250
  end

  function frame:CreateTexture(name, layer)
    self.regions = self.regions or {}
    local tex = {
      name = name,
      layer = layer,
      -- NO DEFAULT COLOUR. A stub records what the addon DID, not what a real
      -- texture happens to start as. Seeding {1,1,1,1} made every texture the addon
      -- never coloured look like a deliberate opaque fill, which is exactly the bug
      -- the overlay tests are looking for -- so the stub manufactured a false
      -- positive. color stays nil until SetColorTexture is called.
      color = nil
    }
    function tex:SetAllPoints(f)
      self.parent = f
    end
    -- Textures support the same geometry/appearance calls as frames in the real API.
    -- Omitting them makes correct addon code look broken (and hid real breakage).
    function tex:SetSize(w, h) self.w, self.h = w, h end
    function tex:SetPoint(...) self.points = self.points or {}; table.insert(self.points, {...}) end
    function tex:SetVertexColor(r, g, b, a) self.vertexColor = {r, g, b, a} end
    function tex:SetAlpha(a) self.alpha = a end
    function tex:GetAlpha() return self.alpha or 1 end
    function tex:SetDesaturated(d) self.desaturated = d end
    function tex:SetTexCoord(...) self.texCoord = {...} end
    function tex:SetDrawLayer(...) end
    function tex:SetBlendMode(...) end
    function tex:IsShown() return self.visible ~= false end
    function tex:SetColorTexture(r, g, b, a)
      self.color = {r, g, b, a}
    end
    function tex:SetTexture(texID)
      self.texID = texID
    end
    function tex:Hide()
      self.visible = false
    end
    function tex:Show()
      self.visible = true
    end
    -- Recorded so tests can inspect exactly what a module built (e.g. that the
    -- highlight overlay is a four-edge ring and every colour carries an alpha).
    table.insert(self.regions, tex)
    return tex
  end

  function frame:CreateFontString(name, layer, template)
    self.regions = self.regions or {}
    local fs = {
      name = name,
      layer = layer,
      template = template,
      text = "",
      visible = true
    }
    function fs:SetPoint(point, relFrame, relPoint, x, y)
      self.point = point
      self.x = x or 0
      self.y = y or 0
    end
    function fs:SetAlpha(a) self.alpha = a end
  function fs:GetAlpha() return self.alpha or 1 end
  function fs:SetSize(w, h) self.w, self.h = w, h end
  function fs:SetShadowColor(r, g, b, a) self.shadowColor = {r, g, b, a} end
  function fs:SetShadowOffset(x, y) self.shadowOffset = {x, y} end
  function fs:SetFont() end
  function fs:SetJustifyH() end
  function fs:SetTextColor(r, g, b, a)
      self.color = {r, g, b, a}
    end
    function fs:SetText(text)
      self.text = text
    end
    function fs:SetFormattedText(fmt, ...)
      self.text = string.format(fmt, ...)
    end
    function fs:Show()
      self.visible = true
    end
    function fs:Hide()
      self.visible = false
    end
    table.insert(self.regions, fs)
    return fs
  end

  return frame
end

_G.UIParent = CreateFrame("Frame", "UIParent", nil)

function GetTime()
  return stub.state.time
end

function UnitPower(unit, powerType)
  if unit == "player" then
    if powerType == 3 then -- Energy
      if stub.state.combatSecrets then
        return stub.makeSecret(stub.state.energy)
      end
      return stub.state.energy
    elseif powerType == 4 then -- ComboPoints
      if stub.state.combatSecrets then
        return stub.makeSecret(stub.state.comboPoints)
      end
      return stub.state.comboPoints
    end
  end
  return 0
end

function UnitPowerMax(unit, powerType)
  if unit == "player" then
    if powerType == 3 then -- Energy
      return stub.state.energyMax
    elseif powerType == 4 then -- ComboPoints
      return stub.state.comboPointsMax
    end
  end
  return 0
end

_G.Enum = {
  PowerType = {
    Energy = 3,
    ComboPoints = 4
  }
}

function C_Spell_GetSpellCooldown(spellID)
  if not _G.C_Spell then return nil end
  local cd = stub.state.cooldowns[spellID]
  if not cd then
    -- THE REAL CLIENT ANSWERS FOR ANY KNOWN SPELL. Returning nil for a spell with no
    -- explicit entry made every ability the test had not named read as UNKNOWN COOLDOWN,
    -- so rules gated on cdReady failed and their steps rated 'unknown' -- which then
    -- truncated the sequence. Observed: at 5/5 combo points with everything ready, the
    -- bar showed one Sinister Strike instead of a finisher, purely because Between the
    -- Eyes had no row in this table. An absent entry means 'off cooldown', not 'unknown'.
    return { startTime = 0, duration = 0, isEnabled = true, isActive = false, isOnGCD = false }
  end

  -- isActive IS THE READINESS BOOLEAN, and it is never secret in the live client.
  -- The original stub returned only isEnabled, so StateTracker had nothing to read a
  -- running cooldown from and every ability came back READY however long a test had
  -- just put it on cooldown. Whole categories of cooldown assertion were therefore
  -- vacuous: the setup said 'Roll the Bones is down for 45s' and the engine saw it up.
  local remaining = (cd.startTime + cd.duration) - stub.state.time
  local running = (cd.duration or 0) > 0 and remaining > 0

  if stub.channelSecret and stub.channelSecret('cooldowns') or stub.state.combatSecrets then
    -- Timers hidden, readiness still answerable -- exactly the Midnight contract.
    return {
      startTime = stub.makeSecret(cd.startTime),
      duration = stub.makeSecret(cd.duration),
      isEnabled = true,
      isActive = running,
      isOnGCD = false,
    }
  end

  return {
    startTime = cd.startTime,
    duration = cd.duration,
    isEnabled = true,
    isActive = running,
    isOnGCD = false,
  }
end

_G.C_Spell = {
  GetSpellCooldown = C_Spell_GetSpellCooldown,
  GetSpellTexture = function(spellID)
    return "Interface\\Icons\\Ability_Rogue_Adrenaline"
  end
}

function GetSpellCooldown(spellID)
  local cd = stub.state.cooldowns[spellID]
  if cd then
    if stub.state.combatSecrets then
      return stub.makeSecret(cd.startTime), stub.makeSecret(cd.duration), true
    end
    return cd.startTime, cd.duration, true
  end
  return 0, 0, true
end

function C_UnitAuras_GetAuraDataByIndex(unit, index, filter)
  if unit ~= "player" or filter ~= "HELPFUL" then return nil end

  local auras = {}
  if stub.state.buffs.adrenalineRush then
    table.insert(auras, {
      spellId = 13750,
      name = "Adrenaline Rush",
      expirationTime = stub.state.buffs.adrenalineRushExpires,
      applications = 1
    })
  end
  if stub.state.buffs.opportunity then
    table.insert(auras, {
      spellId = 195627,
      name = "Opportunity",
      expirationTime = stub.state.buffs.opportunityExpires,
      applications = 1
    })
  end
  if stub.state.buffs.rollTheBones then
    table.insert(auras, {
      spellId = 315508,
      name = "Roll the Bones",
      expirationTime = stub.state.buffs.rollTheBonesExpires,
      applications = stub.state.buffs.rollTheBonesStage
    })
  end

  -- BRIDGE: the original stub describes buffs as flat boolean flags; the newer
  -- suites add them as an array via stub.addAura. Both must answer the same
  -- query, or a test that adds an aura sees the client report nothing and
  -- silently asserts against an empty world.
  for _, a in ipairs(stub.state.auras or {}) do
    table.insert(auras, a)
  end

  if stub.channelSecret and stub.channelSecret('auras') then
    local a = auras[index]
    if not a then return nil end
    return {
      spellId = a.spellId, name = a.name,
      applications = stub.makeSecret(a.applications or 0),
      expirationTime = stub.makeSecret(a.expirationTime or 0),
      duration = stub.makeSecret(a.duration or 0),
    }
  end

  return auras[index]
end

function C_UnitAuras_GetAuraDataBySpellID(unit, spellID)
  -- BRIDGE: array-form auras added by stub.addAura are answered here too, so a
  -- test that adds one is visible through every query path rather than only the
  -- index walk.
  for _, a in ipairs(stub.state.auras or {}) do
    if a.spellId == spellID then
      if stub.channelSecret and stub.channelSecret('auras') then
        return { spellId = a.spellId, name = a.name,
                 applications = stub.makeSecret(a.applications or 0),
                 expirationTime = stub.makeSecret(a.expirationTime or 0) }
      end
      return a
    end
  end
  if unit ~= "player" then return nil end

  local auras = {}
  if stub.state.buffs.adrenalineRush then
    table.insert(auras, {
      spellId = 13750,
      auraInstanceID = 1001,
      name = "Adrenaline Rush",
      expirationTime = stub.state.buffs.adrenalineRushExpires,
      applications = 1
    })
  end
  if stub.state.buffs.opportunity then
    table.insert(auras, {
      spellId = 195627,
      auraInstanceID = 1002,
      name = "Opportunity",
      expirationTime = stub.state.buffs.opportunityExpires,
      applications = 1
    })
  end
  if stub.state.buffs.rollTheBones then
    table.insert(auras, {
      spellId = 315508,
      auraInstanceID = 1003,
      name = "Roll the Bones",
      expirationTime = stub.state.buffs.rollTheBonesExpires,
      applications = stub.state.buffs.rollTheBonesStage
    })
  end

  for _, aura in ipairs(auras) do
    if aura.spellId == spellID then
      return aura
    end
  end
  return nil
end

function C_UnitAuras_GetAuraDataByAuraInstanceID(unit, instanceID)
  if unit ~= "player" then return nil end

  -- Map instanceID to buff state for update refresh
  local auras = {
    [1001] = {
      spellId = 13750,
      auraInstanceID = 1001,
      name = "Adrenaline Rush",
      expirationTime = stub.state.buffs.adrenalineRushExpires,
      applications = 1
    },
    [1002] = {
      spellId = 195627,
      auraInstanceID = 1002,
      name = "Opportunity",
      expirationTime = stub.state.buffs.opportunityExpires,
      applications = 1
    },
    [1003] = {
      spellId = 315508,
      auraInstanceID = 1003,
      name = "Roll the Bones",
      expirationTime = stub.state.buffs.rollTheBonesExpires,
      applications = stub.state.buffs.rollTheBonesStage
    }
  }

  return auras[instanceID]
end

_G.C_UnitAuras = {
  GetAuraDataByIndex = C_UnitAuras_GetAuraDataByIndex,
  GetAuraDataBySpellID = C_UnitAuras_GetAuraDataBySpellID,
  -- ARITY MATTERS. The real GetPlayerAuraBySpellID takes ONE argument (spellID);
  -- GetAuraDataBySpellID takes two (unit, spellID). This stub used to alias the
  -- one-arg name straight to the two-arg function, so the suite happily certified a
  -- call site that passed ("player", spellID) to the one-arg form -- putting the
  -- string "player" in the spellID slot and returning nil for every aura in the real
  -- client. A stub that is more permissive than the client tests nothing.
  GetPlayerAuraBySpellID = function(spellID)
    if type(spellID) ~= "number" then
      error("GetPlayerAuraBySpellID takes a spellID, got " .. tostring(spellID))
    end
    return C_UnitAuras_GetAuraDataBySpellID("player", spellID)
  end,
  GetAuraDataByAuraInstanceID = C_UnitAuras_GetAuraDataByAuraInstanceID
}

function UnitBuff(unit, index)
  if unit ~= "player" then return nil end
  local bufs = {}
  if stub.state.buffs.adrenalineRush then
    table.insert(bufs, "Adrenaline Rush")
  end
  if stub.state.buffs.opportunity then
    table.insert(bufs, "Opportunity")
  end
  if stub.state.buffs.rollTheBones then
    table.insert(bufs, "Roll the Bones")
  end

  if bufs[index] then
    return bufs[index], nil, 1, nil, 0, stub.state.time + 100
  end
  return nil
end

function GetInventoryItemID(unit, slot)
  if unit == "player" and stub.state.trinkets[slot] then
    return stub.state.trinkets[slot].itemID
  end
  return nil
end

function C_Item_GetItemCooldown(itemID)
  for slot = 13, 14 do
    if stub.state.trinkets[slot] and stub.state.trinkets[slot].itemID == itemID then
      return stub.state.trinkets[slot].startTime, stub.state.trinkets[slot].duration
    end
  end
  return 0, 0
end

_G.C_Item = {
  GetItemCooldown = C_Item_GetItemCooldown,
  GetItemSpell = function(itemID)
    return "Potion Name", 123 -- return (spellName, spellID) matching real API
  end
}

function GetItemCooldown(itemID)
  for slot = 13, 14 do
    if stub.state.trinkets[slot] and stub.state.trinkets[slot].itemID == itemID then
      return stub.state.trinkets[slot].startTime, stub.state.trinkets[slot].duration
    end
  end
  return 0, 0
end

function GetInventoryItemTexture(unit, slot)
  if unit == "player" and stub.state.trinkets[slot] and stub.state.trinkets[slot].itemID then
    return "Interface\\Icons\\Ability_Rogue_Adrenaline"
  end
  return nil
end

function GetItemSpell(itemID)
  return "Potion Name", 123 -- return (spellName, spellID) matching real API
end

function GetSpellTexture(spellID)
  return "Interface\\Icons\\Ability_Rogue_Adrenaline"
end

function wipe(t)
  for k in pairs(t) do
    t[k] = nil
  end
end

function print(msg)
  -- Captured AND echoed. Legacy suites read stdout; the newer ones assert on what
  -- the addon actually said -- e.g. '/tuono record must tell the player it is
  -- recording', which pins a silent-failure bug seen in the field.
  stub.printed = stub.printed or {}
  table.insert(stub.printed, tostring(msg))
  io.write(tostring(msg) .. string.char(10))
end

function UnitClass(unit)
  if unit == "player" then
    return "Rogue", stub.state.class
  end
  return nil
end

function GetSpecialization()
  return stub.state.spec
end

_G.C_AssistedCombat = {
  IsAvailable = function()
    return true
  end,
  GetNextCastSpell = function(checkForVisibleButton)
    return 193315 -- Sinister Strike
  end,
  GetRotationSpells = function()
    -- Include both number and table entry forms, and blade flurry for aoeDetected testing
    return {193315, 271877, 315341, 13877}
  end,
  GetActionSpell = function(actionID)
    return 193315
  end
}

function IsStealthed()
  return stub.state.stealthed == true
end

_G.SlashCmdList = {}

-- Marker for secret values
local SECRET_MARKER = "__is_secret_value"

-- Secret value factory for testing WoW Midnight behavior
-- Secrets report their REAL type via type() (e.g., secret number has type=="number")
-- This models actual Midnight client behavior where secrets pass through type() checks
function stub.makeSecret(value)
  local realType = type(value)
  local secretMeta = {
    __lt = function() error("attempt to compare secret") end,
    __le = function() error("attempt to compare secret") end,
    __eq = function() error("attempt to compare secret") end,
    __add = function() error("attempt to arith secret") end,
    __sub = function() error("attempt to arith secret") end,
    __mul = function() error("attempt to arith secret") end,
    __div = function() error("attempt to arith secret") end,
    __len = function() error("attempt to get length of secret") end,
    __concat = function(a, b) return tostring(a) .. tostring(b) end,
    __tostring = function(a) return tostring(value) end,
    [SECRET_MARKER] = true,
    __secret_real_type = realType  -- Store the real type for shadowed type() function
  }
  local secret = {}
  setmetatable(secret, secretMeta)
  return secret
end

-- Shadow the global type() function to return the real type for secrets
-- This models Midnight behavior where secrets report their real type
local real_type = _G.__wow_stub_pristine_type
function _G.type(x)
  if x and real_type(x) == "table" then
    local mt = getmetatable(x)
    if mt and mt[SECRET_MARKER] then
      return mt.__secret_real_type or "table"
    end
  end
  return real_type(x)
end

-- Global issecretvalue for Midnight API compliance testing
function _G.issecretvalue(v)
  if v and real_type(v) == "table" then
    local mt = getmetatable(v)
    if mt and mt[SECRET_MARKER] then
      return true
    end
  end
  return false
end

-- C_ActionBar stub for keybind lookups
_G.C_ActionBar = {
  FindSpellActionButtons = function(spellID)
    -- Return slot 1 for spell 193315 (Sinister Strike), nil for others
    if spellID == 193315 then
      return {1}  -- Action button 1
    end
    return nil
  end
}

-- GetBindingKey stub for keybind text
function _G.GetBindingKey(bindingName)
  -- Stub: return a binding for ACTIONBUTTON1
  if bindingName == "ACTIONBUTTON1" then
    return "1"
  end
  return nil
end

-- GetActionInfo stub
function _G.GetActionInfo(slot)
  if slot == 1 then
    return "spell", 193315  -- Spell in slot 1
  end
  return nil
end

-- C_NamePlate stub for threat detection
_G.C_NamePlate = {
  GetNamePlates = function()
    return stub.nameplates
  end
}

-- Helper to add a nameplate with threat level
function stub.AddNamePlate(unitToken, threatLevel)
  threatLevel = threatLevel or 3  -- Default to high threat
  local plate = {
    namePlateUnitToken = unitToken,
    UnitFrame = {
      unit = unitToken
    }
  }
  table.insert(stub.nameplates, plate)
  -- Store threat level in stub for UnitThreatSituation
  if not stub.threatLevels then
    stub.threatLevels = {}
  end
  stub.threatLevels[unitToken] = threatLevel
end

-- Helper to clear nameplates
function stub.ClearNamePlates()
  wipe(stub.nameplates)
  stub.threatLevels = {}
end

-- UnitThreatSituation stub
function _G.UnitThreatSituation(player, unitToken)
  if not stub.threatLevels then
    return nil
  end
  return stub.threatLevels[unitToken]
end

-- === state-transition stub additions (additive; nothing above this line is edited) ===
-- Bonus-bar / action-bar-page stub state and spell-override stub state, added to
-- exercise stealth-triggered slot/button transitions and override resolution.

stub.state.bonusBarOffset = 0  -- 0 = no bonus bar; Rogue Stealth = 1 (VERIFIED contract)
stub.state.actionBarPage = 1

-- slot -> {actionType, actionID} map, keyed by ABSOLUTE action slot. Slot 1 keeps the
-- original stub default (spell/193315) so every pre-existing test still passes.
stub.state.actionSlots = {
  [1] = { "spell", 193315 }
}

function stub.SetActionSlot(slot, actionType, actionID)
  stub.state.actionSlots[slot] = { actionType, actionID }
end

function stub.ClearActionSlot(slot)
  stub.state.actionSlots[slot] = nil
end

-- Supersedes the single-slot GetActionInfo defined above (last definition wins in
-- Lua); slot 1 keeps returning spell/193315 by default via stub.state.actionSlots.
function _G.GetActionInfo(slot)
  local entry = stub.state.actionSlots and stub.state.actionSlots[slot]
  if not entry then return nil end
  -- Two shapes exist: the original positional {actionType, actionID} and the
  -- newer named {type=, id=}. Accept both, or a test using one silently sees an
  -- empty action bar and asserts against a world that was never set up.
  if entry.type or entry.id then return entry.type or "spell", entry.id end
  return entry[1], entry[2]
end

-- GetBonusBarOffset: 0 = no bonus bar, matching the real Rogue contract (Stealth = 1).
function _G.GetBonusBarOffset()
  return stub.state.bonusBarOffset or 0
end

-- GetActionBarPage: the player-selected page. Per Blizzard's own docs this does NOT
-- reflect bonus-bar overrides, so the stub mirrors that: it stays whatever it was set
-- to regardless of stub.state.bonusBarOffset.
function _G.GetActionBarPage()
  return stub.state.actionBarPage or 1
end

_G.NUM_ACTIONBAR_PAGES = 6
_G.NUM_ACTIONBAR_BUTTONS = 12

-- Spell override stub: baseSpellID -> overrideSpellID currently active.
stub.state.spellOverrides = {}

function stub.SetSpellOverride(baseSpellID, overrideSpellID)
  stub.state.spellOverrides[baseSpellID] = overrideSpellID
end

function stub.ClearSpellOverrides()
  wipe(stub.state.spellOverrides)
end

function _G.FindSpellOverrideByID(spellID)
  return (stub.state.spellOverrides and stub.state.spellOverrides[spellID]) or spellID
end

function _G.FindBaseSpellByID(spellID)
  if stub.state.spellOverrides then
    for base, override in pairs(stub.state.spellOverrides) do
      if override == spellID then return base end
    end
  end
  return spellID
end

-- _G.C_Spell already exists above (GetSpellCooldown/GetSpellTexture); extend it
-- additively rather than replacing the table.
_G.C_Spell.GetOverrideSpell = function(spellID)
  return _G.FindSpellOverrideByID(spellID)
end

-- ============================================================================
-- ADDED BY THE HARNESS MERGE
-- ============================================================================
-- Everything below was absent from the original stub. The most important entries are
-- C_Spell.IsSpellUsable and GetSpellPowerCost: EnergyModel brackets hidden energy by
-- probing them across the ability cost ladder, and without them Observe() returns false
-- immediately and the interval model is never exercised at all.

-- Honour BOTH secrecy switches: the original coarse `combatSecrets` and the per-channel
-- `secret` table, so legacy suites and new ones can each say what they mean.
local function channelSecret(kind)
  if stub.state.combatSecrets then return true end
  local sec = stub.state.secret
  return (sec and sec[kind]) and true or false
end
stub.channelSecret = channelSecret

local function maybeSecret(kind, value)
  if channelSecret(kind) then return stub.makeSecret(value) end
  return value
end
stub.maybeSecret = maybeSecret

-- --- the never-secret oracles the interval model is built on ----------------
-- IsSpellUsable answers from REAL energy, so the bracket genuinely converges rather than
-- being fed a constant. insufficientPower at cost c proves energy < c; that one boolean
-- is the whole inversion.
_G.C_Spell.IsSpellUsable = function(spellID)
  local cost = stub.state.costs and stub.state.costs[spellID]
  if not cost then return true, false end
  if (stub.state.energy or 0) < cost then return false, true end
  return true, false
end

_G.C_Spell.GetSpellPowerCost = function(spellID)
  local cost = stub.state.costs and stub.state.costs[spellID]
  if not cost then return {} end
  return { { type = 3, cost = cost } }   -- 3 = Enum.PowerType.Energy
end

_G.C_Spell.GetSpellInfo = _G.C_Spell.GetSpellInfo or function(spellID)
  return { name = "Spell" .. tostring(spellID), spellID = spellID }
end
_G.C_Spell.GetSpellName = _G.C_Spell.GetSpellName or function(spellID)
  return "Spell" .. tostring(spellID)
end
_G.C_Spell.GetBaseSpell = _G.C_Spell.GetBaseSpell or function(spellID)
  return _G.FindBaseSpellByID and _G.FindBaseSpellByID(spellID) or spellID
end

_G.C_SpellBook = _G.C_SpellBook or {
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
_G.IsSpellKnown = _G.IsSpellKnown or function(spellID)
  local k = stub.state.knownSpells[spellID]
  if k == nil then return true end
  return k
end

-- --- the stat family, all SecretWhenUnitStatsRestricted in the live client ---
function _G.GetHaste() return maybeSecret("haste", stub.state.haste) end
function _G.UnitSpellHaste() return maybeSecret("haste", stub.state.haste) end
function _G.GetMeleeHaste() return maybeSecret("haste", stub.state.haste) end
function _G.UnitAttackSpeed() return maybeSecret("haste", 1.23) end
function _G.GetPowerRegenForPowerType() return maybeSecret("haste", stub.state.powerRegen) end
function _G.GetPowerRegen() return maybeSecret("haste", stub.state.powerRegen) end
function _G.UnitPowerDisplayMod() return 1 end

function _G.GetBuildInfo() return "12.1.0", "69273", "2026-08-01", 120100 end
function _G.GetInstanceInfo() return "Test", "none", 0, "Normal" end
function _G.IsInInstance() return false, "none" end
function _G.UnitAffectingCombat(unit)
  return unit == "player" and stub.state.inCombat or false
end
function _G.GetSpecializationInfo() return 260, "Outlaw" end
_G.date = _G.date or function() return "2026-01-01 00:00:00" end
_G.STANDARD_TEXT_FONT = _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
_G.SPELL_FAILED_NO_POWER = _G.SPELL_FAILED_NO_POWER or "Not enough energy"
_G.ERR_OUT_OF_ENERGY = _G.ERR_OUT_OF_ENERGY or "Not enough energy"

-- Runtime secrecy predicates. Answering these lets the addon ASK rather than assume,
-- which is the behaviour docs/INVERSION.md asks for.
_G.C_Secrets = _G.C_Secrets or {
  ShouldUnitPowerBeSecret = function() return channelSecret("energy") end,
  ShouldUnitStatsBeSecret = function() return channelSecret("haste") end,
  ShouldAurasBeSecret = function() return channelSecret("auras") end,
  GetPowerTypeSecrecy = function(pt) return pt == 3 and 2 or 0 end,
  HasSecretRestrictions = function() return true end,
  GetSpellAuraSecrecy = function() return nil end,
}
_G.C_RestrictedActions = _G.C_RestrictedActions or {
  IsAddOnRestrictionActive = function() return stub.state.inCombat end,
}
_G.C_Timer = _G.C_Timer or { After = function() end }
_G.Enum.AddOnRestrictionType = _G.Enum.AddOnRestrictionType or {
  Combat = 1, Encounter = 2, ChallengeMode = 3, PvPMatch = 4, Map = 5, Chat = 6,
}
_G.Enum.SecrecyLevel = _G.Enum.SecrecyLevel or { NeverSecret = 0, AlwaysSecret = 1, ContextuallySecret = 2 }

-- NOTE: GetBindingKey is NOT redefined here. The original stub already provides one that
-- resolves through the action-slot map, and five keybind tests depend on it. An additive
-- merge must never clobber a working implementation with a simpler one; stub.state.bindings
-- exists only as an optional override for tests that want to force a specific key.

-- --- test-facing helpers ----------------------------------------------------
function stub.setCooldown(spellID, duration)
  stub.state.cooldowns[spellID] = { startTime = stub.state.time, duration = duration }
end

function stub.clearCooldown(spellID)
  stub.state.cooldowns[spellID] = nil
end

function stub.addAura(spellId, name, applications, remaining)
  table.insert(stub.state.auras, {
    spellId = spellId, name = name,
    applications = applications or 0,
    duration = remaining or 30,
    expirationTime = stub.state.time + (remaining or 30),
  })
end

function stub.clearAuras()
  stub.state.auras = {}
end

-- Put a spell on a specific slot, and make it resolve THERE.
--
-- The default bar already holds Sinister Strike in slot 1 (legacy suites depend on it),
-- and the slot index takes the FIRST match -- so placing that same spell on slot 108 and
-- then asking which button it lives on answered 'slot 1'. The helper's whole purpose is
-- 'this spell is on this button', so it now clears any earlier slot holding the same
-- spell rather than silently losing to it.
function stub.placeOnBar(slot, spellID)
  for s, entry in pairs(stub.state.actionSlots or {}) do
    local id = entry and (entry.id or entry[2])
    if id == spellID and s ~= slot then stub.state.actionSlots[s] = nil end
  end
  if stub.SetActionSlot then stub.SetActionSlot(slot, "spell", spellID) end
end

-- ============================================================================
-- FRESH WORLD
-- ============================================================================
-- Snapshotted HERE, at the very end, because everything above contributes to
-- stub.state -- actionSlots, spellOverrides, bonusBarOffset, stealthed are all added
-- further down than the initial table. An earlier version of this merge took the
-- snapshot next to the table literal and reset() then silently DELETED every field
-- added afterwards, emptying the action bar for any test that called it.
local function deepcopy(t)
  if type(t) ~= 'table' then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopy(v) end
  return out
end
local PRISTINE_STATE = deepcopy(stub.state)

-- The newer suites boot a fresh addon per test and rely on this. The legacy suites load
-- once and never call it, so it is purely additive.
function stub.reset()
  stub.state = deepcopy(PRISTINE_STATE)
  for k in pairs(stub.frames or {}) do stub.frames[k] = nil end
  for k in pairs(stub.eventHandlers or {}) do stub.eventHandlers[k] = nil end
  for k in pairs(stub.nameplates or {}) do stub.nameplates[k] = nil end
  for k in pairs(stub.threatLevels or {}) do stub.threatLevels[k] = nil end
  stub.printed = {}
end
stub.printed = stub.printed or {}

return stub
