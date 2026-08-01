local ADDON_NAME, OA = ...

OA.Display = OA.Display or {}

local function GetSpellTexture(spellID)
	if C_Spell and C_Spell.GetSpellTexture then
		return C_Spell.GetSpellTexture(spellID)
	end
	local g = _G.GetSpellTexture
	if g then
		return g(spellID)
	end
	return nil
end

local function GetInventoryItemTexture(unit, slot)
	local g = _G.GetInventoryItemTexture
	if g then
		return g(unit, slot)
	end
	return nil
end

local FALLBACK_TEXTURE = 134400
local TRINKET_SLOTS = { 13, 14 }

-- Keybind cache: spellID -> "S-1" (already abbreviated, ready to display)
-- Module-local to avoid per-tick allocations; invalidated only on binding changes
local spellIDtoKeytext = {}
local function InvalidateKeybindCache()
	-- Wipe cache in-place; reuse same table to avoid allocating new table
	for k in pairs(spellIDtoKeytext) do
		spellIDtoKeytext[k] = nil
	end
end

local function AbbreviateKey(keyStr)
	if not keyStr or keyStr == "" then return nil end
	-- Single pass string operations to create abbreviated form once
	keyStr = string.gsub(keyStr, "SHIFT%-", "S-")
	keyStr = string.gsub(keyStr, "CTRL%-", "C-")
	keyStr = string.gsub(keyStr, "ALT%-", "A-")
	keyStr = string.gsub(keyStr, "BUTTON", "M")
	return keyStr
end

local function GetKeybindText(spellID)
	if not spellID then return nil end

	-- Cache hit: return already-abbreviated string without recomputing
	if spellIDtoKeytext[spellID] then
		return spellIDtoKeytext[spellID]
	end

	-- Try C_ActionBar.FindSpellActionButtons (guard existence)
	if C_ActionBar and C_ActionBar.FindSpellActionButtons then
		local buttons = C_ActionBar.FindSpellActionButtons(spellID)
		if buttons and #buttons > 0 then
			local slot = buttons[1]
			-- Map slot to binding name (bars 1-6)
			local bindingName = nil
			if slot >= 1 and slot <= 12 then
				bindingName = "ACTIONBUTTON" .. slot
			elseif slot >= 61 and slot <= 72 then
				bindingName = "MULTIACTIONBAR1BUTTON" .. (slot - 60)
			elseif slot >= 73 and slot <= 84 then
				bindingName = "MULTIACTIONBAR2BUTTON" .. (slot - 72)
			elseif slot >= 85 and slot <= 96 then
				bindingName = "MULTIACTIONBAR3BUTTON" .. (slot - 84)
			elseif slot >= 97 and slot <= 108 then
				bindingName = "MULTIACTIONBAR4BUTTON" .. (slot - 96)
			end
			-- TODO: stance bars for other specs

			if bindingName and GetBindingKey then
				local key = GetBindingKey(bindingName)
				if key then
					local abbrev = AbbreviateKey(key)
					spellIDtoKeytext[spellID] = abbrev
					return abbrev
				end
			end
		end
	end

	-- Fallback: iterate action buttons 1-120
	if GetActionInfo then
		for slot = 1, 120 do
			local actionType, actionID = GetActionInfo(slot)
			if actionType == "spell" and actionID == spellID then
				local bindingName = nil
				if slot >= 1 and slot <= 12 then
					bindingName = "ACTIONBUTTON" .. slot
				elseif slot >= 61 and slot <= 72 then
					bindingName = "MULTIACTIONBAR1BUTTON" .. (slot - 60)
				elseif slot >= 73 and slot <= 84 then
					bindingName = "MULTIACTIONBAR2BUTTON" .. (slot - 72)
				elseif slot >= 85 and slot <= 96 then
					bindingName = "MULTIACTIONBAR3BUTTON" .. (slot - 84)
				elseif slot >= 97 and slot <= 108 then
					bindingName = "MULTIACTIONBAR4BUTTON" .. (slot - 96)
				end

				if bindingName and GetBindingKey then
					local key = GetBindingKey(bindingName)
					if key then
						local abbrev = AbbreviateKey(key)
						spellIDtoKeytext[spellID] = abbrev
						return abbrev
					end
				end
				break
			end
		end
	end

	return nil
end

local function GetKindBorderColor(kind)
	-- kind can be: "rotation" (default), "cooldown" (orange), "trinket" (purple), "rtb" (gold), "opener" (teal)
	if kind == "cooldown" then
		return 1, 0.6, 0, 0.6  -- orange
	elseif kind == "trinket" then
		return 0.8, 0.2, 0.8, 0.6  -- purple
	elseif kind == "rtb" then
		return 1, 0.8, 0, 0.6  -- gold
	elseif kind == "opener" then
		return 0, 0.8, 0.8, 0.6  -- teal
	else
		-- default (rotation)
		return 0.5, 0.5, 0.5, 0.6
	end
end

local function CreateIcon(parent, name, size, x, y)
	local btn = CreateFrame("Button", name, parent)
	btn:SetSize(size, size)
	btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

	local tex = btn:CreateTexture(nil, "BACKGROUND")
	tex:SetAllPoints(btn)
	btn.texture = tex

	local cooldownText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	cooldownText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
	cooldownText:SetTextColor(1, 1, 1, 1)
	cooldownText:Hide()
	btn.cooldownText = cooldownText

	-- Keybind text in top-right
	local keyText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	keyText:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -2, -2)
	keyText:SetTextColor(1, 1, 1, 0.8)
	keyText:Hide()
	btn.keyText = keyText

	local border = btn:CreateTexture(nil, "BORDER")
	border:SetAllPoints(btn)
	border:Hide()
	btn.border = border

	return btn
end

function OA.Display.Init()
	if OA.Display.anchor then
		return
	end

	local scale = OA.db.display.scale or 1
	local iconCount = OA.db.display.iconCount or 4

	local anchor = CreateFrame("Frame", nil, UIParent)
	-- Size based on iconCount: first icon is 48px, rest are 40px, with 4px spacing
	local stripWidth = 48 + math.max(0, (iconCount - 1)) * 44
	anchor:SetSize(stripWidth + 10, 60)
	anchor:SetPoint(OA.db.display.point or "CENTER", OA.db.display.x or 0, OA.db.display.y or -180)
	anchor:SetScale(scale)
	anchor:SetMovable(not OA.db.display.locked)
	anchor:EnableMouse(true)

	anchor:RegisterForDrag("LeftButton")
	anchor:SetScript("OnDragStart", function(self)
		if not OA.db.display.locked then
			self:StartMoving()
		end
	end)
	anchor:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, relTo, relPoint, x, y = self:GetPoint()
		OA.db.display.point = point or "CENTER"
		OA.db.display.x = x or 0
		OA.db.display.y = y or -180
	end)

	-- Background texture for the strip
	local bg = anchor:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(anchor)
	bg:SetColorTexture(0.1, 0.1, 0.1, 0.3)

	-- Single rolling strip frame
	local strip = CreateFrame("Frame", nil, anchor)
	strip:SetSize(stripWidth, 48)
	strip:SetPoint("TOPLEFT", anchor, "TOPLEFT", 5, -5)
	anchor.strip = strip

	-- Create icons in the strip (max 8, initially show based on iconCount)
	anchor.icons = {}
	for i = 1, 8 do
		local size = (i == 1) and 48 or 40
		local x = (i == 1) and 0 or (48 + (i - 2) * 44)
		local icon = CreateIcon(strip, nil, size, x, 0)
		table.insert(anchor.icons, icon)
		icon.queueIndex = i
		icon.isSizeLarge = (i == 1)
	end

	-- Register for UPDATE_BINDINGS and ACTIONBAR_SLOT_CHANGED events
	local eventFrame = CreateFrame("Frame")
	eventFrame:RegisterEvent("UPDATE_BINDINGS")
	eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
	eventFrame:SetScript("OnEvent", function(self, event)
		if event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED" then
			InvalidateKeybindCache()
		end
	end)
	anchor.eventFrame = eventFrame

	OA.Display.anchor = anchor
end

function OA.Display.Render(result)
	-- Allocation-light per-tick rendering: all frames/fontstrings created at Init,
	-- reused here; keybind strings cached at module scope; no per-tick table creation
	if not OA.Display.anchor then
		return
	end

	local anchor = OA.Display.anchor
	local show = OA.db.show or {}
	local inCombat = OA.State and OA.State.inCombat
	local iconCount = OA.db.display.iconCount or 4

	local showUI = inCombat or show.ooc
	if not showUI then
		anchor:Hide()
		return
	end

	local classToken = select(2, UnitClass("player"))
	local spec = GetSpecialization and GetSpecialization() or nil
	if classToken ~= "ROGUE" or (spec and spec ~= 2) then
		anchor:Hide()
		return
	end

	anchor:Show()

	-- Render unified strip from result.queue
	if show.queue and result and result.queue then
		local maxIcons = math.min(iconCount, 8, #result.queue)
		for i = 1, 8 do
			local icon = anchor.icons[i]
			if i <= maxIcons then
				local entry = result.queue[i]
				if entry then
					-- Determine texture based on entry type
					local tex = nil
					if entry.itemSlot and (entry.itemSlot == 13 or entry.itemSlot == 14) then
						-- Trinket: use inventory texture
						tex = GetInventoryItemTexture("player", entry.itemSlot) or FALLBACK_TEXTURE
					else
						-- Spell: use spell texture
						tex = GetSpellTexture(entry.spellID) or FALLBACK_TEXTURE
					end
					icon.texture:SetTexture(tex)

					-- Set border color by kind (default to "rotation" if kind is missing)
					local kind = entry.kind or "rotation"
					local r, g, b, a = GetKindBorderColor(kind)
					icon.border:SetColorTexture(r, g, b, a)
					icon.border:Show()

					-- Display keybind text
					if entry.spellID then
						local keytext = GetKeybindText(entry.spellID)
						if keytext then
							icon.keyText:SetText(keytext)
							icon.keyText:Show()
						else
							icon.keyText:Hide()
						end
					else
						icon.keyText:Hide()
					end

					icon:Show()
				else
					icon:Hide()
				end
			else
				icon:Hide()
			end
		end
	else
		for _, icon in ipairs(anchor.icons) do
			icon:Hide()
		end
	end
end
