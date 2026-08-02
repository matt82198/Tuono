-- WoW API stub for pure-Lua testing
local stub = {}

stub.state = {
  time = 0,
  energy = 50,
  energyMax = 100,
  comboPoints = 2,
  comboPointsMax = 6,
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
  class = "ROGUE"
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
  -- This ensures OA.frame receives events properly
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
  end
  function frame:SetSwipeColor() end
  function frame:SetDrawEdge() end
  function frame:SetReverse() end
  function frame:SetHideCountdownNumbers() end

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
    local tex = {
      name = name,
      layer = layer,
      color = {1, 1, 1, 1}
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
    return tex
  end

  function frame:CreateFontString(name, layer, template)
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
  if cd then
    if stub.state.combatSecrets then
      return {
        startTime = stub.makeSecret(cd.startTime),
        duration = stub.makeSecret(cd.duration),
        isEnabled = true
      }
    end
    return {
      startTime = cd.startTime,
      duration = cd.duration,
      isEnabled = true
    }
  end
  return nil
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

  return auras[index]
end

function C_UnitAuras_GetAuraDataBySpellID(unit, spellID)
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
  -- Real client exposes GetPlayerAuraBySpellID; alias it so tests exercise the
  -- name the addon prefers (a stub that models only our assumption proves nothing).
  GetPlayerAuraBySpellID = C_UnitAuras_GetAuraDataBySpellID,
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
  io.write(tostring(msg) .. "\n")
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
local real_type = type
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

return stub
