local ADDON_NAME, Tuono = ...

Tuono.Display = Tuono.Display or {}

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
-- Sentinel for "looked up, found nothing". Storing plain nil means the cache never
-- populates, so every icon re-scanned up to 120 action slots EVERY TICK at 10Hz. This
-- name was used below but never defined in this file -- it was nil the whole time.
local KEYBIND_MISS = {}
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

-- Bonus-bar-aware main-bar slot math. STEALTH SWAPS THE ACTION BAR PAGE: entering
-- stealth changes bonusBarOffset, which remaps what ActionButton1-12 show WITHOUT
-- necessarily changing GetActionBarPage() -- that API explicitly does NOT reflect
-- bonus-bar overrides (VERIFIED, warcraft.wiki.gg API_GetActionBarPage: "might not
-- actually be available if overridden by a vehicle, mind control, temporary
-- shapeshift or other similar mechanics"). GetBonusBarOffset() is authoritative and
-- takes priority when > 0 (Rogue Stealth = bonus offset 1, VERIFIED). Formula for
-- main-bar button N's CURRENT absolute slot (VERIFIED, warcraft.wiki.gg
-- API_GetBonusBarOffset): bonus active -> N + (NUM_ACTIONBAR_PAGES + offset - 1) *
-- NUM_ACTIONBAR_BUTTONS; otherwise -> N + (page - 1) * NUM_ACTIONBAR_BUTTONS. All
-- reads pcall-guarded; the two NUM_ACTIONBAR_* globals fall back to the standard 6/12
-- if this client build doesn't define them.
local function CurrentMainBarSlot(buttonIndex)
	local numPages = tonumber(_G.NUM_ACTIONBAR_PAGES) or 6
	local numButtons = tonumber(_G.NUM_ACTIONBAR_BUTTONS) or 12

	local bonusOffset = 0
	if _G.GetBonusBarOffset then
		local ok, off = pcall(_G.GetBonusBarOffset)
		if ok and type(off) == "number" and off > 0 then bonusOffset = off end
	end
	if bonusOffset > 0 then
		return buttonIndex + (numPages + bonusOffset - 1) * numButtons
	end

	local page = 1
	if _G.GetActionBarPage then
		local ok, p = pcall(_G.GetActionBarPage)
		if ok and type(p) == "number" and p > 0 then page = p end
	end
	return buttonIndex + (page - 1) * numButtons
end

-- Action-slot -> binding-name map. The previous inline version covered only slots
-- 1-12 and 61-72 and mislabelled 73+, so a spell on any other bar silently produced
-- no keybind -- which is why keybinds appeared on only some icons in live play.
-- Canonical layout: 1-12 main, 13-24 main page 2 (shares ACTIONBUTTON bindings),
-- 25-36 MultiBarRight(3), 37-48 MultiBarLeft(4), 49-60 MultiBarBottomRight(2),
-- 61-72 MultiBarBottomLeft(1), 73-120 bars 5-7.
local function bindingNameForSlot(slot)
	if type(slot) ~= "number" then return nil end

	-- Whichever absolute slot is CURRENTLY showing on the main 12 buttons (accounting
	-- for stealth/bonus-bar swaps) wins over the static page table below: that table
	-- assumes page 1 == buttons 1-12, which is false while a bonus bar is active.
	for i = 1, 12 do
		if CurrentMainBarSlot(i) == slot then
			return "ACTIONBUTTON" .. i
		end
	end

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

-- GetActionInfo, secret-safe.
--
-- Every tier below compares actionID against a spellID. Under Midnight an unreadable
-- actionID makes that comparison RAISE, and GetKeybindText is called from inside the
-- render loop with nothing between it and the icon strip -- so one secret action slot
-- takes out the rest of the frame's rendering, including the keybinds on every icon after
-- it. Which is exactly the reported symptom: bindings "not showing appropriately at all".
--
-- Read it through the tri-state primitives and treat unreadable as "no match here", not as
-- an error and not as a match. Skipping one slot costs at most one keybind; raising costs
-- the whole display.
local function safeActionInfo(slot)
	if not GetActionInfo then return nil, nil end
	local ok, actionType, actionID = pcall(GetActionInfo, slot)
	if not ok then return nil, nil end
	if Tuono.isSecret(actionType) then actionType = nil end
	local id = Tuono.readNum(actionID)
	if type(actionType) ~= "string" then actionType = nil end
	return actionType, id
end

local function actionMatches(actionType, actionID, spellID)
	if not actionType or not actionID then return false end
	if actionType ~= "spell" and actionType ~= "talent" and actionType ~= "action" then
		return false
	end
	if actionID == spellID then return true end
	local ok, matched = pcall(Tuono.SpellMatchesAction, spellID, actionID)
	return ok and matched or false
end

local function GetKeybindText(spellID)
	if not spellID then return nil end

	-- Cache hit: return already-abbreviated string or sentinel (not nil, which would re-lookup)
	local cached = spellIDtoKeytext[spellID]
	if cached ~= nil then
		-- NOT `(cached == MISS) and nil or cached`: in Lua `true and nil` is nil, so that
		-- idiom falls through to `or cached` and returns the SENTINEL TABLE, which then
		-- reached SetText ("bad argument #1 to SetText") and killed the render.
		if cached == KEYBIND_MISS then return nil end
		return cached
	end

	local foundKey = nil

	-- TIER 1: C_ActionBar.FindSpellActionButtons (modern, preferred). Expects a BASE
	-- spell ID and resolves overrides internally (VERIFIED, warcraft.wiki.gg: "Expects
	-- a base spell, so if a spell is overridden the base ID should be provided") --
	-- exactly what Tuono.SpellIDs / the queue's spellID always is.
	-- BUGFIX: Tuono.safe returns a SINGLE value (`return result`, see Core.lua), not an
	-- (ok, result) pair. `local ok, buttons = Tuono.safe(...)` put the buttons array in
	-- `ok` and left `buttons` always nil, so `if ok and buttons` never passed and this
	-- whole modern path was permanently dead -- every lookup fell through to the
	-- 120-slot scan below. pcall directly instead.
	if C_ActionBar and C_ActionBar.FindSpellActionButtons then
		local ok, buttons = pcall(C_ActionBar.FindSpellActionButtons, spellID)
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

	-- TIER 2: the CURRENTLY VISIBLE main-bar slots (bonus-bar aware), so a
	-- stealth-only spell (e.g. Ambush) resolves to whatever button is ACTUALLY
	-- showing it right now, not a static page-1 guess. Override-aware match: the slot
	-- may hold spellID's active override rather than spellID itself.
	if not foundKey and GetActionInfo then
		for i = 1, 12 do
			local slot = CurrentMainBarSlot(i)
			local actionType, actionID = safeActionInfo(slot)
			if actionMatches(actionType, actionID, spellID) then
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

	-- TIER 3: fallback full sweep of all 120 action slots (fixed multibars unaffected
	-- by the main-bar page/bonus swap, plus a catch-all for anything TIER 1/2 missed).
	-- Override-aware for the same reason as TIER 2.
	if not foundKey and GetActionInfo then
		for slot = 1, 120 do
			local actionType, actionID = safeActionInfo(slot)
			if actionMatches(actionType, actionID, spellID) then
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
	spellIDtoKeytext[spellID] = foundKey or KEYBIND_MISS
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

function Tuono.Display.Init()
	if Tuono.Display.anchor then
		return
	end

	local scale = Tuono.db.display.scale or 1
	local iconCount = Tuono.db.display.iconCount or 4

	local anchor = CreateFrame("Frame", nil, UIParent)
	-- Size based on iconCount: first icon is 48px, rest are 40px, with 4px spacing
	local stripWidth = 48 + math.max(0, (iconCount - 1)) * 44
	anchor:SetSize(stripWidth + 10, 60)
	anchor:SetPoint(Tuono.db.display.point or "CENTER", Tuono.db.display.x or 0, Tuono.db.display.y or -180)
	anchor:SetScale(scale)
	anchor:SetMovable(not Tuono.db.display.locked)
	anchor:EnableMouse(true)

	anchor:RegisterForDrag("LeftButton")
	anchor:SetScript("OnDragStart", function(self)
		if not Tuono.db.display.locked then
			self:StartMoving()
		end
	end)
	anchor:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, relTo, relPoint, x, y = self:GetPoint()
		Tuono.db.display.point = point or "CENTER"
		Tuono.db.display.x = x or 0
		Tuono.db.display.y = y or -180
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

	-- ========================================================================
	-- READY RAIL -- facts only, no prediction
	-- ========================================================================
	-- The wheel answers "what next". The rail answers "what is available", which the
	-- wheel structurally cannot: it only ever shows abilities the priority list chose,
	-- so a ready cooldown that lost the priority walk is invisible. Both rows are built
	-- purely from exactly-readable state -- combo points, and cooldown readiness via the
	-- never-secret booleans -- so nothing here can be wrong about the future.
	--
	-- Deliberately pips, never numbers: we know ready/not-ready, and in instanced combat
	-- we do NOT know the remaining duration. A digit would claim a measurement we do not
	-- have. There is also deliberately no energy bar -- energy is an estimate here and
	-- Blizzard's real one is already on screen two inches away.
	local rail = CreateFrame("Frame", nil, anchor)
	rail:SetSize(stripWidth, 14)
	rail:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 2, -2)
	anchor.rail = rail

	anchor.cpPips = {}
	for i = 1, 7 do
		local pip = rail:CreateTexture(nil, "ARTWORK")
		pip:SetSize(7, 7)
		pip:SetPoint("LEFT", rail, "LEFT", (i - 1) * 10, 0)
		pip:Hide()
		anchor.cpPips[i] = pip
	end

	anchor.cdPips = {}
	for i = 1, 8 do
		local pip = rail:CreateTexture(nil, "ARTWORK")
		pip:SetSize(9, 9)
		pip:SetPoint("LEFT", rail, "LEFT", 84 + (i - 1) * 12, 0)
		pip:Hide()
		anchor.cdPips[i] = pip
	end

	-- Track last rendered count for dynamic resize
	anchor.lastCount = 0

	-- Status text for empty-queue reason (centered in the strip area)
	local statusText = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	statusText:SetPoint("CENTER", strip, "CENTER", 0, 0)
	statusText:SetTextColor(0.7, 0.7, 1, 0.8)
	statusText:Hide()
	anchor.statusText = statusText

	-- Register for UPDATE_BINDINGS and ACTIONBAR_SLOT_CHANGED events via Tuono dispatcher
	Tuono.RegisterEvent("UPDATE_BINDINGS", function()
		InvalidateKeybindCache()
	end)
	Tuono.RegisterEvent("ACTIONBAR_SLOT_CHANGED", function()
		InvalidateKeybindCache()
	end)

	-- STEALTH SWAPS THE ACTION BAR PAGE: the keybind cache must be recomputed for the
	-- newly visible bar even when no individual slot changed. VERIFIED events
	-- (warcraft.wiki.gg, 2026-08-01): UPDATE_STEALTH, ACTIONBAR_PAGE_CHANGED,
	-- UPDATE_BONUS_ACTIONBAR all fire with no payload. SPELLS_CHANGED covers overrides
	-- granted/revoked by talents. PLAYER_REGEN_DISABLED/ENABLED are included per the
	-- same "invalidate on any plausible transition" policy the reported bug needs.
	Tuono.RegisterEvent("UPDATE_STEALTH", function()
		InvalidateKeybindCache()
	end)
	Tuono.RegisterEvent("ACTIONBAR_PAGE_CHANGED", function()
		InvalidateKeybindCache()
	end)
	Tuono.RegisterEvent("UPDATE_BONUS_ACTIONBAR", function()
		InvalidateKeybindCache()
	end)
	Tuono.RegisterEvent("SPELLS_CHANGED", function()
		InvalidateKeybindCache()
	end)
	Tuono.RegisterEvent("PLAYER_REGEN_DISABLED", function()
		InvalidateKeybindCache()
	end)
	Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", function()
		InvalidateKeybindCache()
	end)

	Tuono.Display.anchor = anchor
end

function Tuono.Display.Render(result)
	-- Allocation-light per-tick rendering: all frames created at Init, reused here
	if not Tuono.Display.anchor then
		return
	end

	local anchor = Tuono.Display.anchor
	local show = Tuono.db.show or {}
	local inCombat = Tuono.State and Tuono.State.inCombat
	local iconCount = Tuono.db.display.iconCount or 4

	-- PERSISTENT: Always show the bar (user controls with show.queue toggle, not combat status)
	local classToken = select(2, UnitClass("player"))
	local spec = GetSpecialization and GetSpecialization() or nil
	if classToken ~= "ROGUE" or (spec and spec ~= 2) then
		anchor:Hide()
		return
	end

	anchor:Show()

	-- Track degraded state for visual indication
	local isDegraded = Tuono.State and Tuono.State.buffs and Tuono.State.buffs.degraded or false
	-- `A and B or true` parses as `(A and B) or true`, which is unconditionally true --
	-- so the "assist unavailable" status text below was unreachable.
	local assistAvailable = not (Tuono.Assist and Tuono.Assist.available == false)

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
		-- The ready rail sits under the strip and is ~190px wide no matter how many icons
		-- are shown. The queue now truncates itself at the first uncertain step, so a
		-- single-icon strip (~62px) is a normal state, not an edge case -- without a floor
		-- the rail would draw outside its own frame every time the lookahead collapses.
		local RAIL_MIN_WIDTH = 196
		if width < RAIL_MIN_WIDTH then width = RAIL_MIN_WIDTH end
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

					-- PROVENANCE-DRIVEN ALPHA. Confidence now describes what the decision
					-- was DERIVED FROM, not how far down the queue it sits, so a step
					-- built entirely from combo points and cooldown readiness renders
					-- solid even in slot 4 -- and a step gated on a hidden aura reads as
					-- unknown even in slot 1. The sequence visibly dissolves at exactly
					-- the step where we stopped knowing things, which is the honest
					-- picture rather than an arbitrary fade.
					local confidence = entry.confidence or "bounded"
					local baseAlpha = 1.0
					if confidence == "bounded" then
						baseAlpha = 0.72         -- real bounds, but a threshold could straddle them
					elseif confidence == "unknown" then
						baseAlpha = 0.4          -- depends on something Midnight hides
					elseif confidence == "pooling" then
						baseAlpha = 0.35
					-- Legacy tiers, still accepted so older profiles/tests keep rendering.
					elseif confidence == "medium" then
						baseAlpha = 0.7
					elseif confidence == "low" then
						baseAlpha = 0.45
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

					-- UNKNOWN provenance gets an amber hazard wash, the same language the
					-- degraded-data state already uses. Dimness alone is ambiguous -- it
					-- reads as "less preferred" rather than "we could not check this".
					if confidence == "unknown" and icon.hazard then
						icon.hazard:SetColorTexture(1, 0.6, 0, 0.22)
						icon.hazard:Show()
					end

					-- POOLING: this is "wait for it", not "press it". Dim alpha alone reads as
					-- low confidence, which is a different message, so position 1 also gets
					-- a blue marker and its authority ring is muted -- the ring is what says
					-- "press this now" and it must not say that here.
					if confidence == "pooling" then
						if icon.badge then
							icon.badge:SetColorTexture(0.3, 0.6, 1, 0.9)
							icon.badge:Show()
						end
						if i == 1 and icon.authRing then
							icon.authRing:SetVertexColor(0.3, 0.6, 1, 0.25)
						end
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
						-- Default TRUE so trinkets and the no-cooldown case behave as before;
						-- only a spell cooldown whose timer went secret sets this false.
						local remainingIsKnown = true
						if entry.kind == "cooldown" and entry.spellID then
							-- Resolve via the shared spellID->key map rather than a hand-written
							-- chain: the old inline version knew only AR/Blade Rush/Preparation,
							-- so every other cooldown silently rendered no sweep at all.
							local cdKey = Tuono.Rotation and Tuono.Rotation.SPELL_TO_CDKEY
								and Tuono.Rotation.SPELL_TO_CDKEY[entry.spellID]
							local cd = cdKey and Tuono.State.cooldowns[cdKey]
							if cd then
								remaining = cd.remaining or 0
								remainingIsKnown = cd.remainingKnown ~= false
							end
						elseif entry.kind == "trinket" and entry.itemSlot then
							if Tuono.State.trinkets[entry.itemSlot] then
								remaining = Tuono.State.trinkets[entry.itemSlot].remaining
							end
						end

						-- Cache-guard. `(GetTime() - icon.lastCDStart or 0)` parsed as
						-- `(GetTime() - lastCDStart) or 0`, so it performed arithmetic on nil
						-- whenever the first branch did not short-circuit -- a latent throw that
						-- would abort the whole render. Compare against an explicit default.
						local sinceLast = GetTime() - (icon.lastCDStart or 0)
						if remaining ~= icon.lastCDDuration or sinceLast > 0.1 then
							if remaining > 0 then
								icon.cooldownWidget:SetCooldown(GetTime(), remaining)
							end
							if icon.cooldownText then
								-- Only draw a countdown we actually measured. Under Midnight the
								-- timer goes secret while readiness stays readable, so `remaining`
								-- is legitimately 0-with-unknown-duration; printing "0" there would
								-- assert a precision we do not have.
								if remaining and remaining > 0 and remainingIsKnown then
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

					-- STALLED: the same advice, ignored repeatedly. Fade position 1 rather
					-- than keep asserting it. Silent by design -- a warning here would be
					-- alarm fatigue for something the player is doing on purpose.
					if i == 1 and Tuono.Engine and Tuono.Engine.IsStalled
						and Tuono.Engine.IsStalled() then
						baseAlpha = math.min(baseAlpha, 0.45)
						if icon.authRing then
							icon.authRing:SetVertexColor(0.6, 0.6, 0.6, 0.15)
						end
					end

					-- GLOBAL COOLDOWN on position 1. A live trace showed Sinister Strike
					-- failing 31 times against 14 successes, every failure paired with
					-- "Ability is not ready yet" -- i.e. the player pressing a correct
					-- recommendation during the GCD and getting nothing. The advice was
					-- right; the timing was not, and the bar said nothing about it.
					--
					-- Deliberately a sweep rather than a fade: fading reads as "we are
					-- unsure", and we are not unsure at all. It is the correct next
					-- button, it just is not pressable for another fraction of a second.
					if i == 1 and Tuono.CooldownModel and Tuono.CooldownModel.GCDActive
						and Tuono.CooldownModel.GCDActive() then
						-- SET THE SWEEP ONCE PER GCD, NOT ONCE PER TICK.
						-- Calling SetCooldown every tick restarts the animation from full
						-- ten times a second, which reads as the icon strobing. The model
						-- knows when the GCD started, and an absolute start is idempotent,
						-- so the same GCD arms the sweep exactly once.
						local start = Tuono.CooldownModel.GCDStart and Tuono.CooldownModel.GCDStart()
						if icon.cooldownWidget and start then
							if icon.gcdStart ~= start then
								icon.gcdStart = start
								icon.cooldownWidget:SetCooldown(start, Tuono.CooldownModel.GCDLength())
								icon.cooldownWidget:Show()
							end
						end
					elseif i == 1 then
						-- GCD over: clear the sweep so a stale one cannot linger on an icon
						-- that has since been replaced. Guarded, or this would fire 10x/sec.
						if icon.gcdStart then
							icon.gcdStart = nil
							if icon.cooldownWidget then
								icon.cooldownWidget:SetCooldown(0, 0)
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

		-- ====================================================================
		-- READY RAIL
		-- ====================================================================
		if anchor.cpPips then
			local S = Tuono.State
			local cpKnown = S.comboPointsKnown ~= false
			local cpMax = (S.comboPointsMax and S.comboPointsMax > 0) and S.comboPointsMax or 5
			for i, pip in ipairs(anchor.cpPips) do
				if i <= cpMax then
					if not cpKnown then
						-- Unreadable: show the slots exist, refuse to claim a count.
						pip:SetColorTexture(0.35, 0.35, 0.4, 0.5)
					elseif i <= (S.comboPoints or 0) then
						pip:SetColorTexture(1, 0.85, 0.3, 1)
					else
						pip:SetColorTexture(0.3, 0.3, 0.35, 0.8)
					end
					pip:Show()
				else
					pip:Hide()
				end
			end

			local profile = Tuono.Profiles and Tuono.Profiles.Active()
			local keys = {}
			if profile then
				for key, spellID in pairs(profile.spells or {}) do
					local ab = (profile.abilities or {})[spellID]
					if ab and (ab.cd or 0) > 0 then table.insert(keys, key) end
				end
				table.sort(keys)
			end
			for i, pip in ipairs(anchor.cdPips) do
				local key = keys[i]
				local cd = key and Tuono.State.cooldowns[key]
				if cd then
					if not cd.known then
						pip:SetColorTexture(0.4, 0.3, 0.15, 0.7)   -- unreadable
					elseif cd.ready then
						pip:SetColorTexture(0.3, 0.9, 0.5, 1)      -- usable NOW
					else
						pip:SetColorTexture(0.25, 0.25, 0.3, 0.8)  -- on cooldown
					end
					pip:Show()
				else
					pip:Hide()
				end
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
