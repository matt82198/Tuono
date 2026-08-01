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

-- Action-slot -> binding-name map. The previous inline version covered only slots
-- 1-12 and 61-72 and mislabelled 73+, so a spell on any other bar silently produced
-- no keybind -- which is why keybinds appeared on only some icons in live play.
-- Canonical layout: 1-12 main, 13-24 main page 2 (shares ACTIONBUTTON bindings),
-- 25-36 MultiBarRight(3), 37-48 MultiBarLeft(4), 49-60 MultiBarBottomRight(2),
-- 61-72 MultiBarBottomLeft(1), 73-120 bars 5-7.
local function bindingNameForSlot(slot)
	if type(slot) ~= "number" then return nil end
	if slot >= 1 and slot <= 12 then return "ACTIONBUTTON" .. slot end
	if slot >= 13 and slot <= 24 then return "ACTIONBUTTON" .. (slot - 12) end
	if slot >= 25 and slot <= 36 then return "MULTIACTIONBAR3BUTTON" .. (slot - 24) end
	if slot >= 37 and slot <= 48 then return "MULTIACTIONBAR4BUTTON" .. (slot - 36) end
	if slot >= 49 and slot <= 60 then return "MULTIACTIONBAR2BUTTON" .. (slot - 48) end
	if slot >= 61 and slot <= 72 then return "MULTIACTIONBAR1BUTTON" .. (slot - 60) end
	if slot >= 73 and slot <= 84 then return "MULTIACTIONBAR5BUTTON" .. (slot - 72) end
	if slot >= 85 and slot <= 96 then return "MULTIACTIONBAR6BUTTON" .. (slot - 84) end
	if slot >= 97 and slot <= 108 then return "MULTIACTIONBAR7BUTTON" .. (slot - 96) end
	return nil
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
			local bindingName = bindingNameForSlot(slot)

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
			local bindingName = bindingNameForSlot(slot)

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

local function CreateIcon(parent, name, size, x, y, isPosition1)
	local btn = CreateFrame("Button", name, parent)
	btn:SetSize(size, size)
	btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

	local tex = btn:CreateTexture(nil, "BACKGROUND")
	tex:SetAllPoints(btn)
	btn.texture = tex

	-- Cooldown widget via CooldownFrameTemplate (sweep + numeric)
	local okCD, cooldownWidget = pcall(CreateFrame, "Cooldown", nil, btn, "CooldownFrameTemplate")
	if okCD and cooldownWidget and cooldownWidget.SetAllPoints then
		pcall(cooldownWidget.SetAllPoints, cooldownWidget, btn)
		btn.cooldownWidget = cooldownWidget
	end

	-- Keybind text in bottom-right, large, THICKOUTLINE for mid-combat legibility
	-- Numeric cooldown text. Blizzard's Cooldown widget draws a sweep, but its countdown
	-- NUMBERS are a user setting that is often off -- and the user explicitly asked for
	-- cooldowns visible on the icons, so we draw our own and never rely on that setting.
	local cooldownText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	cooldownText:SetPoint("CENTER", btn, "CENTER", 0, 0)
	cooldownText:SetTextColor(1, 0.9, 0.4, 1)
	cooldownText:Hide()
	btn.cooldownText = cooldownText

	local keyText = btn:CreateFontString(nil, "OVERLAY")
	keyText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 1)
	keyText:SetTextColor(1, 1, 1, 1)
	-- Use THICKOUTLINE for contrast against arbitrary spell art
	local fontSize = isPosition1 and 13 or 11
	pcall(function() keyText:SetFont(STANDARD_TEXT_FONT, fontSize, "THICKOUTLINE") end)
	keyText:Hide()
	btn.keyText = keyText

	-- Kind ring (BORDER layer, thin 2px effect via alpha)
	local kindRing = btn:CreateTexture(nil, "BORDER")
	kindRing:SetAllPoints(btn)
	kindRing:Hide()
	btn.kindRing = kindRing

	-- Kind badge (top-left, shape indicator)
	local badge = btn:CreateTexture(nil, "ARTWORK")
	badge:SetSize(12, 12)
	badge:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
	badge:Hide()
	btn.badge = badge

	-- Degraded hazard overlay (amber diagonal stripes)
	local hazard = btn:CreateTexture(nil, "ARTWORK")
	hazard:SetAllPoints(btn)
	hazard:SetColorTexture(1, 0.6, 0, 0.35)
	hazard:Hide()
	btn.hazard = hazard

	-- Authority ring for position 1 (silver/white, non-kind encoding)
	if isPosition1 then
		local authRing = btn:CreateTexture(nil, "BORDER")
		authRing:SetAllPoints(btn)
		authRing:SetColorTexture(0.9, 0.9, 0.9, 0.3)
		authRing:Show()
		btn.authRing = authRing
	end

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
		local size = (i == 1) and 50 or 42
		local x = (i == 1) and 6 or (6 + 50 + (i - 2) * (6 + 42))
		local isPos1 = (i == 1)
		local icon = CreateIcon(strip, nil, size, x, 6, isPos1)
		table.insert(anchor.icons, icon)
		icon.queueIndex = i
		icon.isSizeLarge = isPos1
		icon.lastCDStart = nil
		icon.lastCDDuration = nil
	end

	-- Track last rendered count for dynamic resize
	anchor.lastCount = 0

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
	-- Allocation-light per-tick rendering: all frames created at Init, reused here
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

	-- Track degraded state for visual indication
	local isDegraded = OA.State and OA.State.buffs and OA.State.buffs.degraded or false
	local assistAvailable = OA.Assist and OA.Assist.available ~= false or true

	-- Calculate visible entry count for dynamic strip resize
	local visibleCount = 0
	if show.queue and result and result.queue then
		visibleCount = math.min(iconCount, 8, #result.queue)
	end

	-- Dynamic strip resize: only call SetSize if count actually changed
	if visibleCount ~= anchor.lastCount then
		anchor.lastCount = visibleCount
		-- Width formula: 6 + 50 + sum(6 + 42) for each additional icon + 6
		local width = 6 + 50 + math.max(0, visibleCount - 1) * (6 + 42) + 6
		local height = 6 + 50 + 6 + 14
		anchor:SetSize(width, height)
	end

	-- Render unified strip from result.queue
	if show.queue and result and result.queue then
		for i = 1, 8 do
			local icon = anchor.icons[i]
			if i <= visibleCount then
				local entry = result.queue[i]
				if entry then
					-- Determine texture based on entry type
					local tex = nil
					if entry.itemSlot and (entry.itemSlot == 13 or entry.itemSlot == 14) then
						tex = GetInventoryItemTexture("player", entry.itemSlot) or FALLBACK_TEXTURE
					else
						tex = GetSpellTexture(entry.spellID) or FALLBACK_TEXTURE
					end
					icon.texture:SetTexture(tex)

					-- Confidence-aware rendering: opacity based on confidence level
					-- high (1.0), medium (0.7), low (0.45), static-fallback (0.3 + special mark)
					local confidence = entry.confidence or "high"
					local baseAlpha = 1.0
					if confidence == "medium" then
						baseAlpha = 0.7
					elseif confidence == "low" then
						baseAlpha = 0.45
					elseif confidence == "static-fallback" then
						baseAlpha = 0.3
					end

					-- Position 1 gets authority ring (silver, always opaque)
					if i == 1 then
						if icon.authRing then
							icon.authRing:SetVertexColor(0.9, 0.9, 0.9, 0.4)
						end
						if icon.kindRing then
							icon.kindRing:Hide()
						end
						if icon.badge then
							icon.badge:Hide()
						end
					else
						-- Positions 2-8: kind ring + badge
						local kind = entry.kind or "rotation"
						local r, g, b = GetKindBorderColor(kind)
						if icon.kindRing then
							icon.kindRing:SetColorTexture(r, g, b, baseAlpha * 0.6)
							icon.kindRing:Show()
						end
						if icon.badge then
							-- Badge would be a shape texture here; for now hide
							icon.badge:Hide()
						end
					end

					-- Static-fallback gets special mark (will be visible even with low alpha)
					if confidence == "static-fallback" and icon.badge then
						-- Show a special marker indicating frozen/static value
						icon.badge:SetColorTexture(0.5, 0.5, 0.5, 0.6)
						icon.badge:Show()
					end

					-- Degraded overlay: amber hazard stripes
					if entry.degraded then
						if icon.hazard then
							icon.hazard:SetColorTexture(1, 0.6, 0, 0.35)
							icon.hazard:Show()
						end
					else
						if icon.hazard then
							icon.hazard:Hide()
						end
					end

					-- Display keybind text (bottom-right, large, THICKOUTLINE)
					if entry.spellID then
						local keytext = GetKeybindText(entry.spellID)
						if keytext then
							icon.keyText:SetText(keytext)
							-- Apply alpha to keybind as well
							icon.keyText:SetAlpha(baseAlpha)
							icon.keyText:Show()
						else
							icon.keyText:Hide()
						end
					else
						icon.keyText:Hide()
					end

					-- Cooldown widget: cache-guard to avoid resetting animation every tick
					if icon.cooldownWidget then
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

						-- Only call SetCooldown if values changed (cache-guard)
						if remaining ~= icon.lastCDDuration or (GetTime() - icon.lastCDStart or 0) > 0.1 then
							if remaining > 0 then
								icon.cooldownWidget:SetCooldown(GetTime(), remaining)
							end
							if icon.cooldownText then
								if remaining and remaining > 0 then
									icon.cooldownText:SetText(string.format("%.0f", remaining))
									icon.cooldownText:Show()
								else
									icon.cooldownText:Hide()
								end
								icon.lastCDStart = GetTime()
								icon.lastCDDuration = remaining
								icon.cooldownWidget:Show()
							else
								icon.cooldownWidget:Hide()
								icon.lastCDStart = nil
								icon.lastCDDuration = nil
							end
						end
					end

					-- Icon transparency follows confidence
					icon:SetAlpha(baseAlpha)
					icon:Show()
				else
					icon:Hide()
				end
			else
				icon:Hide()
			end
		end

		-- Status text for degraded data
		if isDegraded then
			anchor.statusText:SetText("~ degraded data")
			anchor.statusText:Show()
		else
			anchor.statusText:Hide()
		end
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
end
