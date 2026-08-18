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

-- FALLBACK_TEXTURE deliberately removed. It was a hardcoded FileDataID (134400), and
-- Blizzard no longer names new icons, so that number is not a stable reference to the
-- question-mark art it was chosen for -- it renders whatever now occupies the ID. An icon
-- the player cannot identify is not a degraded recommendation, it is a wrong one. Entries
-- with no identity at all are dropped; entries whose art merely failed to load draw a
-- neutral block and are identified by their keybind.
local TRINKET_SLOTS = { 13, 14 }

-- How far the reconstructed end instant of a cooldown may move before we treat it as a
-- DIFFERENT cooldown and restart the sweep. `remaining` is recomputed every refresh, so
-- the derived end wobbles by fractions of a frame; the smallest real change is Restless
-- Blades at 1.0s per combo point. This sits comfortably between the two.
local CD_REARM_EPSILON = 0.25

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

-- Exposed so tests can clear it: the cache short-circuits the entire lookup, which makes
-- any test of the lookup itself silently vacuous once an earlier test has populated it.
Tuono.Display.InvalidateKeybindCache = InvalidateKeybindCache

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

-- GetBindingKey returns a STRING, and AbbreviateKey runs gsub on it. A secret string
-- would raise inside gsub, so it is read before use like everything else.
local function readBindingKey(bindingName)
	if not bindingName or not GetBindingKey then return nil end
	local ok, key = pcall(GetBindingKey, bindingName)
	if not ok or key == nil then return nil end
	if Tuono.isSecret(key) or type(key) ~= "string" or key == "" then return nil end
	return AbbreviateKey(key)
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
		-- The call is pcall'd but its RESULT was not guarded, which is the same hole that
		-- was just closed in tiers 2 and 3 -- and the more damaging one, because tier 1
		-- runs for every icon. An unreadable slot flows straight into bindingNameForSlot,
		-- where `CurrentMainBarSlot(i) == slot` and `slot >= 1` raise on a secret. The
		-- render loop then dies partway through the strip, leaving whatever icon 1 drew
		-- last frozen on screen while nothing behind it updates: "Q is just overlaying on
		-- the first icon constantly".
		--
		-- #buttons on a secret-bearing table can raise too, so length is taken inside the
		-- guard rather than in the condition.
		if ok and type(buttons) == "table" then
			local okLen, count = pcall(function() return #buttons end)
			if okLen and (count or 0) > 0 then
				local slot = Tuono.readNum(buttons[1])
				local bindingName = slot and bindingNameForSlot(slot) or nil
				if bindingName then
					foundKey = readBindingKey(bindingName)
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
				foundKey = bindingName and readBindingKey(bindingName) or nil
				if foundKey then break end
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
				foundKey = bindingName and readBindingKey(bindingName) or nil
				if foundKey then break end
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

-- ============================================================================
-- FONT SCALE, INDEPENDENT OF ICON SCALE
-- ============================================================================
-- There was exactly one control, `display.scale`, and it scaled the whole anchor. At a
-- common 1440p UI scale of ~0.64 an 11px glyph renders around 7px of actual screen, and
-- the only way a low-vision player could enlarge the keybind was to enlarge the icons
-- too. The coupling is backwards for precisely the population that needs the text bigger.
--
-- Pure function so the arithmetic is testable without a font engine: the stub's SetFont
-- is a no-op and records nothing.
local MIN_FONT_PX = 8

function Tuono.Display.FontSize(base)
	local db = Tuono.db and Tuono.db.display
	local mult = db and db.fontScale or 1
	if type(mult) ~= "number" or mult <= 0 then mult = 1 end
	local px = math.floor((base or 11) * mult + 0.5)
	if px < MIN_FONT_PX then px = MIN_FONT_PX end
	return px
end

-- SetFont can fail (a missing font path, a locale without the glyph). The old code
-- wrapped it in a bare pcall and moved on, which leaves the string at whatever default it
-- had -- a silent degradation on exactly the accessibility path that matters. Fall back to
-- a Blizzard font OBJECT, which always exists, so text is never left unreadable.
local function applyFont(fs, base)
	if not fs then return end
	local ok = pcall(function()
		fs:SetFont(STANDARD_TEXT_FONT, Tuono.Display.FontSize(base), "THICKOUTLINE")
	end)
	if not ok and fs.SetFontObject then
		pcall(fs.SetFontObject, fs, _G.GameFontNormalSmall)
	end
	return ok
end
Tuono.Display.ApplyFont = applyFont

-- ============================================================================
-- CERTAINTY LIVES ON THE RING, NOT ON ALPHA
-- ============================================================================
-- Alpha was multiplexing three unrelated statements onto one channel that can only say
-- "less", and the player cannot decode which of the three they are seeing:
--
--   unknown -> 0.40   "we do not know if this is right"   (epistemic)
--   pooling -> 0.35   "you cannot afford this yet"        (timing)
--   stalled -> <=0.45 "you keep ignoring us"              (social)
--
-- Two defects followed. The stall clamp was `math.min(baseAlpha, 0.45)` against an
-- `unknown` alpha of 0.40, so min(0.40, 0.45) = 0.40 -- a STALLED recommendation was
-- pixel-identical to a merely uncertain one, discarding the stall detector's output
-- exactly when the player is most likely ignoring the addon BECAUSE it is uncertain. And
-- pooling drew dimmer than unknown despite being a HIGH-confidence claim ("I am certain
-- you cannot press this yet"), so the more certain state read as the less certain one.
--
-- Alpha now carries ONE meaning: how sure we are. Everything else moved to the ring,
-- which also ports to the action bar -- we cannot dim a Blizzard button without writing
-- to a secure frame, so alpha was structurally unavailable on the surface that matters.
--
-- Ring PATTERN carries certainty; ring COLOUR stays free for kind. No collision, and the
-- pattern survives greyscale, which matters because deuteranopia is ~6% of men.
local CERTAINTY = {
	certain  = { alpha = 1.00, pattern = "solid"  },
	bounded  = { alpha = 0.75, pattern = "dashed" },
	unknown  = { alpha = 0.45, pattern = "dashed" },
	pooling  = { alpha = 0.90, pattern = "solid"  },
	fallback = { alpha = 0.50, pattern = "dashed" },
	-- Legacy tiers, still accepted so older profiles and tests keep rendering.
	-- `high` was MISSING here while medium and low were kept, so anything still passing
	-- the old name fell through to the `bounded` default and rendered at 0.75 instead of
	-- full opacity -- a silent downgrade of a confident recommendation, which is the
	-- unknown-as-default defect class this codebase keeps re-shipping. An incomplete
	-- compatibility map is worse than none, because it fails quietly for a subset.
	high     = { alpha = 1.00, pattern = "solid"  },
	medium   = { alpha = 0.75, pattern = "dashed" },
	low      = { alpha = 0.50, pattern = "dashed" },
}

-- AUTHORITY IS THICKNESS AS WELL AS LUMINANCE.
--
-- docs/UI.md 5.2 specifies a 2px ring on position 1 and 1px on the lookahead. Only the
-- colour half was implemented, so position 1 differed from position 2 by HUE ALONE --
-- near-white against the kind colour. Measured in greyscale that is a 1.82x luminance
-- contrast, and against the pooling blue only 1.63x: perceptible, but thin to be the sole
-- carrier of "this is the one to press", and it violates the rule that no meaning may
-- rest on colour alone. Thickness is a second, independent channel that survives every
-- form of colour vision and any icon art underneath.
local RING_THICKNESS_AUTHORITY = 3
local RING_THICKNESS_LEAD = 1
local RING_INSET = 7   -- how far a dashed edge pulls back from each corner

-- Paint the four-edge ring. "solid" is a closed outline; "dashed" pulls each edge back
-- from the corners so the outline is literally incomplete -- the suppressed resolution IS
-- the encoding, which reads instantly and needs no legend. "none" hides it entirely.
local function setRing(icon, pattern, r, g, b, a, thickness)
	local ring = icon.ring
	if not ring then return end
	icon.ringPattern = pattern
	thickness = thickness or RING_THICKNESS_LEAD
	icon.ringThickness = (pattern ~= "none") and thickness or 0

	if pattern == "none" then
		for _, t in pairs(ring) do t:Hide() end
		return
	end

	local inset = (pattern == "dashed") and RING_INSET or 0
	for edge, t in pairs(ring) do
		pcall(function()
			t:ClearAllPoints()
			if edge == "top" then
				t:SetPoint("TOPLEFT", icon, "TOPLEFT", inset, 0)
				t:SetPoint("TOPRIGHT", icon, "TOPRIGHT", -inset, 0)
				t:SetHeight(thickness)
			elseif edge == "bottom" then
				t:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", inset, 0)
				t:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -inset, 0)
				t:SetHeight(thickness)
			elseif edge == "left" then
				t:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, -inset)
				t:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", 0, inset)
				t:SetWidth(thickness)
			else
				t:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 0, -inset)
				t:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, inset)
				t:SetWidth(thickness)
			end
		end)
		t:SetColorTexture(r, g, b, a)
		t:Show()
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
		-- Born hidden, like every other overlay below. Render only ever SHOWS this when
		-- there is a sweep to draw, so a widget that starts shown is a sweep asserted
		-- before anything has been measured.
		if cooldownWidget.Hide then pcall(cooldownWidget.Hide, cooldownWidget) end
		btn.cooldownWidget = cooldownWidget
	end

	-- Keybind text in bottom-right, large, THICKOUTLINE for mid-combat legibility
	-- Numeric cooldown text. Blizzard's Cooldown widget draws a sweep, but its countdown
	-- NUMBERS are a user setting that is often off -- and the user explicitly asked for
	-- cooldowns visible on the icons, so we draw our own and never rely on that setting.
	local cooldownText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	cooldownText:SetPoint("CENTER", btn, "CENTER", 0, 0)
	cooldownText:SetTextColor(1, 0.9, 0.4, 1)
	-- Scaled like the others: a countdown a low-vision player cannot read is not a
	-- countdown. The template supplies a fallback if SetFont fails.
	btn.cdBaseFont = isPosition1 and 14 or 12
	applyFont(cooldownText, btn.cdBaseFont)
	cooldownText:Hide()
	btn.cooldownText = cooldownText

	-- Run multiplier, top-left. "x4" on one Sinister Strike says the same thing as four
	-- identical icons, in a quarter of the space, and without implying four decisions.
	-- Top-LEFT because bottom-right is the keybind and centre is the cooldown countdown;
	-- three numbers on one icon need three unambiguous homes.
	local countText = btn:CreateFontString(nil, "OVERLAY")
	countText:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
	countText:SetTextColor(1, 1, 1, 1)
	btn.countBaseFont = isPosition1 and 13 or 11
	applyFont(countText, btn.countBaseFont)
	countText:Hide()
	btn.countText = countText

	-- WHEN, not just what. Hekili stores an absolute time per button and recomputes the
	-- delay every frame (Hekili UI.lua:1493), which is what lets "wait 1.4s then press
	-- this" look different from "press this now". Tuono rendered both identically.
	-- Top-RIGHT: top-left is the repeat count, bottom-right the keybind, centre the
	-- cooldown countdown. Four numbers need four unambiguous homes.
	local delayText = btn:CreateFontString(nil, "OVERLAY")
	delayText:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -2, -2)
	delayText:SetTextColor(0.4, 0.7, 1, 1)   -- blue: the pooling/timing channel
	btn.delayBaseFont = isPosition1 and 13 or 11
	applyFont(delayText, btn.delayBaseFont)
	delayText:Hide()
	btn.delayText = delayText

	local keyText = btn:CreateFontString(nil, "OVERLAY")
	keyText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 1)
	keyText:SetTextColor(1, 1, 1, 1)
	-- THICKOUTLINE for contrast against arbitrary spell art
	btn.keyBaseFont = isPosition1 and 13 or 11
	applyFont(keyText, btn.keyBaseFont)
	keyText:Hide()
	btn.keyText = keyText

	-- Certainty ring: four edges, so "incomplete outline" is expressible without a font,
	-- a colour, or a texture file. See the CERTAINTY block above for why this is not alpha.
	local ring = {}
	for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
		local seg = btn:CreateTexture(nil, "OVERLAY")
		seg:Hide()
		ring[edge] = seg
	end
	btn.ring = ring
	btn.ringPattern = "none"

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
		-- Absolute instant this icon's current cooldown ends. Identity for the sweep, so
		-- the same cooldown arms it exactly once. See CD_REARM_EPSILON.
		icon.cdEndsAt = nil
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

	-- ========================================================================
	-- COLLAPSE RUNS: FOUR SINISTER STRIKES IS ONE DECISION, NOT FOUR
	-- ========================================================================
	-- The engine simulates 8 steps but the bar shows 4, and an Outlaw at a 5-point cap
	-- needs up to 5 builders before a finisher -- so the finisher fell off the end and the
	-- player saw a wall of one icon with cooldowns popping into slot 1. The sequence was
	-- correct the whole time; it was being truncated at exactly the point where it became
	-- interesting.
	--
	-- Repeats carry no extra information as separate icons. "Sinister Strike x4 then
	-- Between the Eyes" is the same fact in a quarter of the space, and it is MORE honest:
	-- four identical icons imply four decisions when there is one decision repeated. The
	-- count then ticks down as the player presses, and the finisher visibly approaches,
	-- which is the predictive behaviour the wheel exists for.
	--
	-- Only consecutive identical SEQUENCE steps merge. The cooldown and trinket reminders
	-- appended after the sequence are independent facts and are never folded together.
	-- AN UNIDENTIFIABLE ICON IS WORSE THAN NO ICON.
	--
	-- Reported from live play as "some dude's face with a blue icon". Entries whose art
	-- cannot be resolved were rendering FALLBACK_TEXTURE, a hardcoded FileDataID -- and
	-- since Blizzard stopped naming new icons, that ID now points at whatever art happens
	-- to live there. The whole product is "press THIS button", so an icon the player
	-- cannot identify is not a degraded recommendation, it is a wrong one.
	--
	-- This surfaced because advisories stopped being trimmed off past the queue cap, which
	-- was itself a fix: they were being silently deleted. A trinket advisory carries no
	-- spellID and depends on GetInventoryItemTexture, which answers nil when there is
	-- nothing to draw -- so the entries that had been invisible became visible AND broken
	-- in the same change.
	-- IDENTIFIABLE, OR NOT SHOWN. But "identifiable" is not the same as "has art".
	--
	-- The first version of this dropped every entry whose texture would not resolve. That
	-- over-corrects: C_Spell.GetSpellTexture can answer nil transiently before the client
	-- has cached a spell's data, and silently deleting a REAL recommendation is worse than
	-- the placeholder it was meant to prevent -- the player is left with no answer at all
	-- and no way to know one was withheld.
	--
	-- The two cases are genuinely different:
	--   * has a spellID, art missing -- still identifiable. The keybind names the button
	--     and the position carries the order, so keep it and draw a neutral block.
	--   * no spellID and no item art -- a trinket advisory with nothing equipped. Nothing
	--     on screen could tell the player what it is. Drop it.
	local function resolveTexture(entry)
		if entry.itemSlot and (entry.itemSlot == 13 or entry.itemSlot == 14) then
			return GetInventoryItemTexture("player", entry.itemSlot)
		end
		if not entry.spellID then return nil end
		return GetSpellTexture(entry.spellID)
	end

	-- Can the player tell WHAT this is, by any channel we have?
	local function isIdentifiable(entry)
		return (entry.__tex ~= nil) or (entry.spellID ~= nil)
	end

	local collapsed = {}
	if show.queue and result and result.queue then
		for _, entry in ipairs(result.queue) do
			entry.__tex = resolveTexture(entry)
		end
		local drawable = {}
		for _, entry in ipairs(result.queue) do
			if isIdentifiable(entry) then table.insert(drawable, entry) end
		end
		result = { queue = drawable, advisories = result.advisories }
		for _, entry in ipairs(result.queue) do
			local prev = collapsed[#collapsed]
			if prev and prev.entry.isSequence and entry.isSequence
				and prev.entry.spellID == entry.spellID and entry.spellID ~= nil then
				prev.count = prev.count + 1
				-- Keep the WEAKEST confidence across the run: the bar must not claim more
				-- certainty about the fourth press than it has about the fourth press.
				if entry.confidence == "unknown" or prev.entry.confidence == "pooling" then
					prev.worst = entry.confidence
				end
			else
				table.insert(collapsed, { entry = entry, count = 1 })
			end
		end
	end

	-- COLLAPSING MUST EARN ITS PLACE.
	--
	-- Reported from live play: "it literally just drops to 1 icon when there is one target
	-- and 4 when there are multi". Collapsing a run is only a win when it FREES SPACE FOR
	-- SOMETHING ELSE. When the whole sequence is one ability -- a builder chain with no
	-- reachable finisher -- collapsing turns the entire bar into a single box, which reads
	-- as broken and destroys the lead time the wheel exists to give.
	--
	-- So: if collapsing does not reveal a second distinct ability, do not collapse. The
	-- player gets their icons back and the run is shown as the row of presses it is.
	if #collapsed < 2 and result and result.queue and #result.queue >= 2 then
		collapsed = {}
		for _, entry in ipairs(result.queue) do
			table.insert(collapsed, { entry = entry, count = 1 })
		end
	end

	-- Calculate visible entry count for dynamic strip resize
	local visibleCount = math.min(iconCount, 8, #collapsed)

	-- What the player actually SEES, published for the flight recorder. Every trace so far
	-- has recorded engine-side depth, which is not the same number: a sequence of 8 can
	-- render as 1 icon after collapsing, and three separate live reports turned on exactly
	-- that gap.
	Tuono.Display.shownCount = visibleCount

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
				local slot = collapsed[i]
				local entry = slot and slot.entry
				local repeatCount = slot and slot.count or 1
				if entry then
					-- Determine texture based on entry type
					-- NO HARDCODED FileDataID. The old FALLBACK_TEXTURE was 134400 -- the
					-- classic question-mark ID -- and since Blizzard stopped naming new
					-- icons that number now points at unrelated art, which is how the bar
					-- came to show a stranger's face. There is no stable numeric icon to
					-- fall back to, so we stop pretending there is: draw a flat neutral
					-- block and let the keybind identify the button.
					if entry.__tex then
						icon.texture:SetTexture(entry.__tex)
					else
						icon.texture:SetColorTexture(0.16, 0.16, 0.18, 1)
					end

					-- The multiplier. Shown only when it means something: "x1" is noise.
					if icon.countText then
						if repeatCount > 1 then
							icon.countText:SetText("x" .. repeatCount)
							icon.countText:Show()
						else
							icon.countText:Hide()
						end
					end

					-- PROVENANCE-DRIVEN ALPHA. Confidence now describes what the decision
					-- was DERIVED FROM, not how far down the queue it sits, so a step
					-- built entirely from combo points and cooldown readiness renders
					-- solid even in slot 4 -- and a step gated on a hidden aura reads as
					-- unknown even in slot 1. The sequence visibly dissolves at exactly
					-- the step where we stopped knowing things, which is the honest
					-- picture rather than an arbitrary fade.
					-- The run keeps the WEAKEST confidence across its members: the bar must
					-- not claim more certainty about the fourth press than it has.
					local confidence = (slot and slot.worst) or entry.confidence or "bounded"
					local tier = CERTAINTY[confidence] or CERTAINTY.bounded
					local baseAlpha = tier.alpha

					-- Alpha now says ONE thing: how sure we are. Timing lives on the delay
					-- text and the blue ring; the social "you are ignoring us" signal recedes
					-- the icon rather than dimming it (further down).
					local stalled = (i == 1) and Tuono.Engine and Tuono.Engine.IsStalled
						and Tuono.Engine.IsStalled() or false

					local kind = entry.kind or "rotation"
					local rr, rg, rb = GetKindBorderColor(kind)
					if i == 1 then
						-- Authority is carried by LUMINANCE, not hue: near-white reads against
						-- arbitrary spell art for every form of colour vision, and deliberately
						-- avoids blue, which is Blizzard's own Assisted Highlight.
						rr, rg, rb = 0.95, 0.95, 0.95
					end
					if confidence == "pooling" then
						-- Timing channel. Solid ring, because we are SURE you cannot press it
						-- yet -- that is a high-confidence claim, not a doubtful one.
						rr, rg, rb = 0.30, 0.60, 1.00
					end

					if stalled then
						-- RECEDE, DO NOT DIM. A faded icon reads as "less important"; dropping
						-- the ring reads as the addon stepping back while staying available.
						-- The old encoding clamped alpha to 0.45 against an unknown alpha of
						-- 0.40, so the stall signal was silently swallowed.
						setRing(icon, "none")
					else
						setRing(icon, tier.pattern, rr, rg, rb, 0.95,
							(i == 1) and RING_THICKNESS_AUTHORITY or RING_THICKNESS_LEAD)
					end
					icon.stalled = stalled

					-- Legacy regions retired: the ring now carries both kind and certainty.
					if icon.kindRing then icon.kindRing:Hide() end
					if icon.authRing then icon.authRing:SetVertexColor(0, 0, 0, 0) end
					if icon.badge then icon.badge:Hide() end

					-- HAZARD, DECIDED ONCE. An amber wash ON TOP of the dashed ring: two
					-- independent cues, and the hatch is borrowed from hazard signage so it
					-- needs no learning. Dimness alone is ambiguous -- it reads as "less
					-- preferred" rather than "we could not check this".
					--
					-- This used to be two blocks: one showing it for `unknown`, and a later
					-- one that showed it for `entry.degraded` and HID it otherwise -- which
					-- unconditionally undid the first. One decision, one place.
					--
					-- Per-step, never global. `Tuono.State.buffs.degraded` was true on 100%
					-- of ticks in a recorded trace, so a display-wide treatment marks
					-- everything suspect permanently, which is the same as marking nothing.
					if icon.hazard then
						if confidence == "unknown" or entry.degraded then
							icon.hazard:SetColorTexture(1, 0.6, 0, entry.degraded and 0.35 or 0.22)
							icon.hazard:Show()
						else
							icon.hazard:Hide()
						end
					end

					-- ============================================================
					-- WHEN TO PRESS IT
					-- ============================================================
					-- Inspired by Hekili UI.lua:1487-1566. The critical detail there is the
					-- EARLIEST-TIME SUBTRACTION: it only shows a delay when the recommendation
					-- is later than the soonest it could physically happen. Waiting out the
					-- GCD is not news -- the player can see the sweep. Waiting BEYOND it, to
					-- pool energy, is news, and it is the one thing our simulation knows that
					-- Blizzard's highlighter structurally cannot.
					--
					-- Defensive: `at` is supplied by Rotation.Predict and may be absent, in
					-- which case we simply say nothing rather than invent a number.
					if icon.delayText then
						local at = entry.at
						local shown = false
						if type(at) == "number" and at > 0 then
							local earliest = 0
							if i == 1 and Tuono.CooldownModel and Tuono.CooldownModel.GCDRemaining then
								local okG, g = pcall(Tuono.CooldownModel.GCDRemaining)
								if okG and type(g) == "number" then earliest = g end
							end
							if at > earliest + 0.05 then
								icon.delayText:SetText(string.format("%.1f", at))
								icon.delayText:SetAlpha(baseAlpha)
								icon.delayText:Show()
								shown = true
							end
						end
						if not shown then icon.delayText:Hide() end
					end

					-- (Hazard is decided in one place above. This block used to re-decide it
					-- and hid whatever the confidence branch had just shown.)

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

					-- How much cooldown this entry has left. The NUMBER and the SWEEP are
					-- driven separately below, because position 1's sweep belongs to the GCD.
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
							remaining = Tuono.State.trinkets[entry.itemSlot].remaining or 0
						end
					end

					-- Only draw a countdown we actually measured. Under Midnight the timer
					-- goes secret while readiness stays readable, so `remaining` is
					-- legitimately 0-with-unknown-duration; printing "0" there would assert a
					-- precision we do not have. CooldownModel.Reconcile also parks an
					-- unobserved cooldown at a 1s placeholder and flags it inferred -- neither
					-- a number nor a sweep may be drawn from that.
					local drawable = remaining > 0 and remainingIsKnown

					if icon.cooldownText then
						if drawable then
							icon.cooldownText:SetText(string.format("%.0f", remaining))
							icon.cooldownText:Show()
						else
							icon.cooldownText:Hide()
						end
					end

					-- ARM THE SWEEP ONCE PER COOLDOWN, NOT ONCE PER TICK.
					--
					-- The old guard also fired on `sinceLast > 0.1`, so SetCooldown restarted
					-- the animation from full ten times a second and the icon strobed. That is
					-- the same defect the GCD block below was already fixed for, and it takes
					-- the same fix: identify the cooldown by something that does NOT move while
					-- it runs.
					--
					-- `remaining` counts down every tick, so it can never be that identity. The
					-- absolute instant the cooldown ENDS can: it holds still for the whole
					-- sweep and shifts only on a genuine change -- a recast, or Restless Blades
					-- cutting it short.
					--
					-- POSITION 1 IS EXCLUDED. The GCD block below owns that widget, and two
					-- writers on one Cooldown frame re-arm over each other every tick. Nothing
					-- is lost: Engine's castability filter already drops a position-1 entry
					-- whose cooldown is known and not ready, so there is no sweep to draw there.
					if icon.cooldownWidget and i > 1 then
						if drawable then
							local endsAt = GetTime() + remaining
							if icon.cdEndsAt == nil
								or math.abs(icon.cdEndsAt - endsAt) > CD_REARM_EPSILON then
								icon.cdEndsAt = endsAt
								icon.cooldownWidget:SetCooldown(GetTime(), remaining)
							end
							icon.cooldownWidget:Show()
						else
							-- Show() used to be called here unconditionally: it sat inside
							-- `if icon.cooldownText then`, whose else branch is unreachable
							-- because CreateIcon always creates cooldownText. A finished sweep
							-- therefore stayed on screen over a ready ability.
							if icon.cdEndsAt ~= nil then
								icon.cdEndsAt = nil
								icon.cooldownWidget:SetCooldown(0, 0)
							end
							icon.cooldownWidget:Hide()
						end
					end

					-- (Stalling is handled above by dropping the ring rather than clamping
					-- alpha. The old clamp was `math.min(baseAlpha, 0.45)` against an
					-- `unknown` alpha of 0.40, so min(0.40, 0.45) = 0.40 and a stalled
					-- recommendation was pixel-identical to a merely uncertain one --
					-- discarding the stall detector's output in precisely the case where the
					-- player is most likely ignoring the addon BECAUSE it is uncertain.)

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
						-- Hidden as well as zeroed: SetCooldown(0, 0) stops the animation but
						-- leaves the frame shown, which is the same lingering-overlay defect
						-- the cooldown block above was just fixed for.
						if icon.gcdStart then
							icon.gcdStart = nil
							if icon.cooldownWidget then
								icon.cooldownWidget:SetCooldown(0, 0)
								icon.cooldownWidget:Hide()
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
