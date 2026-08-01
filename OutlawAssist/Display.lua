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

	-- Cache hit: return already-abbreviated string or sentinel (not nil, which would re-lookup)
	local cached = spellIDtoKeytext[spellID]
	if cached ~= nil then
		return (cached == trinketCacheSentinel) and nil or cached
	end

	local foundKey = nil

	-- Try C_ActionBar.FindSpellActionButtons (modern, preferred)
	if C_ActionBar and C_ActionBar.FindSpellActionButtons then
		local ok, buttons = OA.safe(function() return C_ActionBar.FindSpellActionButtons(spellID) end)
		if ok and buttons and #buttons > 0 then
			local slot = buttons[1]
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
					foundKey = AbbreviateKey(key)
				end
			end
		end
	end

	-- Fallback: iterate action buttons 1-120
	if not foundKey and GetActionInfo then
		for slot = 1, 120 do
			local actionType, actionID, _ = GetActionInfo(slot)
			-- Check both spell and potentially talent/override variants
			if actionID == spellID and (actionType == "spell" or actionType == "talent" or actionType == "action") then
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
						foundKey = AbbreviateKey(key)
						break
					end
				end
			end
		end
	end

	-- Cache result (use sentinel for nil so we retry later, not poison the cache)
	spellIDtoKeytext[spellID] = foundKey or trinketCacheSentinel
	return foundKey
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

	-- Cooldown timer text (center-top)
	local cooldownText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	cooldownText:SetPoint("CENTER", btn, "TOP", 0, -5)
	cooldownText:SetTextColor(1, 1, 1, 1)
	cooldownText:Hide()
	btn.cooldownText = cooldownText

	-- Blizzard cooldown widget (visual sweep). Guarded: a client without the template
	-- must not take the whole display down -- the numeric text is the fallback.
	local okCD, cooldownWidget = pcall(CreateFrame, "Cooldown", nil, btn, "CooldownFrameTemplate")
	if okCD and cooldownWidget and cooldownWidget.SetAllPoints then
		pcall(cooldownWidget.SetAllPoints, cooldownWidget, btn)
		btn.cooldownWidget = cooldownWidget
	end

	-- Keybind text in bottom-right (larger, more legible)
	local keyText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	keyText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -3, 2)
	keyText:SetTextColor(1, 1, 1, 0.9)
	keyText:SetShadowColor(0, 0, 0, 0.8)
	keyText:SetShadowOffset(1, -1)
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

	-- Status text for empty-queue reason (centered in the strip area)
	local statusText = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	statusText:SetPoint("CENTER", strip, "CENTER", 0, 0)
	statusText:SetTextColor(0.7, 0.7, 1, 0.8)
	statusText:Hide()
	anchor.statusText = statusText

	-- Register for UPDATE_BINDINGS and ACTIONBAR_SLOT_CHANGED events via OA dispatcher
	OA.RegisterEvent("UPDATE_BINDINGS", function()
		InvalidateKeybindCache()
	end)
	OA.RegisterEvent("ACTIONBAR_SLOT_CHANGED", function()
		InvalidateKeybindCache()
	end)

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

	-- PERSISTENT: Always show the bar (user controls with show.queue toggle, not combat status)
	local classToken = select(2, UnitClass("player"))
	local spec = GetSpecialization and GetSpecialization() or nil
	if classToken ~= "ROGUE" or (spec and spec ~= 2) then
		anchor:Hide()
		return
	end

	anchor:Show()

	-- Track degraded state for desaturation effect
	local isDegraded = OA.State and OA.State.buffs and OA.State.buffs.degraded or false
	local assistAvailable = OA.Assist and OA.Assist.available ~= false or true

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
					-- Apply desaturation tint if degraded (reduce saturation, increase grey)
					if isDegraded then
						r = r * 0.6 + 0.2
						g = g * 0.6 + 0.2
						b = b * 0.6 + 0.2
						a = a * 0.8  -- slightly more transparent when degraded
					end
					icon.border:SetColorTexture(r, g, b, a)
					icon.border:Show()

					-- Display keybind text (bottom-right)
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

					-- Display cooldown timer (center-top)
					local remaining = 0
					if entry.kind == "cooldown" and entry.spellID then
						local cdKey = entry.spellID == OA.SpellIDs.adrenalineRush and "adrenalineRush" or
						              entry.spellID == OA.SpellIDs.bladeRush and "bladeRush" or
						              entry.spellID == OA.SpellIDs.preparation and "preparation" or nil
						if cdKey and OA.State.cooldowns[cdKey] then
							remaining = OA.State.cooldowns[cdKey].remaining
						end
					elseif entry.kind == "trinket" and entry.itemSlot then
						if OA.State.trinkets[entry.itemSlot] then
							remaining = OA.State.trinkets[entry.itemSlot].remaining
						end
					end

					-- Display cooldown timer text if remaining > 0
					if remaining > 0 then
						local timerText = string.format("%.1f", remaining)
						icon.cooldownText:SetText(timerText)
						icon.cooldownText:Show()
					else
						icon.cooldownText:Hide()
					end

					-- Update cooldown widget for visual representation
					if icon.cooldownWidget then
						if remaining > 0 then
							-- Set cooldown: (startTime, duration) where startTime+duration=now+remaining
							local now = GetTime()
							icon.cooldownWidget:SetCooldown(now - (GetTime() - (GetTime() - remaining)), remaining)
						else
							icon.cooldownWidget:Hide()
						end
					end

					icon:Show()
				else
					icon:Hide()
				end
			else
				icon:Hide()
			end
		end
		anchor.statusText:Hide()
	else
		-- Queue is empty or show.queue is false: show reason or status
		for _, icon in ipairs(anchor.icons) do
			icon:Hide()
		end

		-- Show status text if assist is unavailable
		if not assistAvailable then
			anchor.statusText:SetText("Rotation assist unavailable")
			anchor.statusText:Show()
		else
			anchor.statusText:Hide()
		end
	end

	-- Show degraded indicator hint (subtle visual cue on first icon's border alpha)
	if isDegraded and (#(result and result.queue or {}) > 0) then
		-- Degradation already applied via desaturation above; no additional indicator needed
		-- The desaturated borders act as the visual cue
	end
end
