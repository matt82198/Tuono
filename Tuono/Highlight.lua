local ADDON_NAME, Tuono = ...

Tuono.Highlight = Tuono.Highlight or {}

-- Retained only for /tuono debug output; there is one mechanism now (see below).
local glowMechanism = "own-frame overlay"

-- Cache: last highlighted button to avoid redundant work
local lastHighlightedButton = nil
local lastHighlightedSpellID = nil

-- Set true whenever the action-bar LAYOUT might have changed (stealth/bonus-bar
-- swap, page change, slot edit, binding edit, talent/spell change, combat
-- enter/exit). The spellID-equality cache below is only valid when the layout is
-- ALSO unchanged: a stealth transition can leave the recommended spellID identical
-- while moving it to a different button, and without this flag the glow would stay
-- pinned to the button it left -- the "stuck highlight" class of the reported bug.
-- Starts true so the very first Update() always resolves.
local barDirty = true
local function MarkBarDirty()
	barDirty = true
end

-- Forward declaration. The pool itself is defined further down, next to the glow
-- implementation; declaring the function here without the locals in scope would have
-- silently resolved GLOW_POOL_SIZE/glowPool/makeGlow to nil GLOBALS.
local PrewarmGlowPool

-- Bonus-bar-aware main-bar slot math (see Display.lua's copy for the full derivation
-- and citations; duplicated locally rather than shared to keep Display/Highlight
-- decoupled). STEALTH SWAPS THE ACTION BAR PAGE: GetBonusBarOffset() > 0 takes
-- priority over GetActionBarPage() (VERIFIED, warcraft.wiki.gg: GetActionBarPage
-- "might not actually be available if overridden by ... temporary shapeshift or
-- other similar mechanics"; Rogue Stealth = bonus offset 1, VERIFIED).
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

-- ============================================================================
-- ACTION SLOT -> BUTTON FRAME
-- ============================================================================
-- ONE TABLE IS THE SOURCE OF TRUTH FOR BOTH DIRECTIONS. The slot sweep used to run
-- 1..120 while this mapping rejected anything above 108, so a spell on bar 8 was indexed
-- and then resolved to no frame -- the glow simply never appeared, with no error and no
-- diagnostic. Two hardcoded bounds in two functions is exactly the divergence shape that
-- has bitten this codebase repeatedly, so the sweep now iterates precisely the range this
-- table covers and the two cannot drift apart.
--
-- Canonical layout: 1-12 main, 13-24 main page 2 (shares ActionButton frames), 25-36
-- MultiBarRight, 37-48 MultiBarLeft, 49-60 MultiBarBottomRight, 61-72 MultiBarBottomLeft,
-- 73-108 MultiBar5/6/7. 109-120 exist as action slots but have no named button frame.
local BAR_RANGES = {
	{ first = 1,   last = 12,  prefix = "ActionButton",              base = 0 },
	{ first = 13,  last = 24,  prefix = "ActionButton",              base = 12 },
	{ first = 25,  last = 36,  prefix = "MultiBarRightButton",       base = 24 },
	{ first = 37,  last = 48,  prefix = "MultiBarLeftButton",        base = 36 },
	{ first = 49,  last = 60,  prefix = "MultiBarBottomRightButton", base = 48 },
	{ first = 61,  last = 72,  prefix = "MultiBarBottomLeftButton",  base = 60 },
	{ first = 73,  last = 84,  prefix = "MultiBar5Button",           base = 72 },
	{ first = 85,  last = 96,  prefix = "MultiBar6Button",           base = 84 },
	{ first = 97,  last = 108, prefix = "MultiBar7Button",           base = 96 },
}

local MAX_ACTION_SLOT = BAR_RANGES[#BAR_RANGES].last
Tuono.Highlight.MAX_ACTION_SLOT = MAX_ACTION_SLOT

local function GetActionButtonFrameName(slot)
	if type(slot) ~= "number" or slot < 1 or slot > MAX_ACTION_SLOT then
		return nil
	end

	-- Whichever absolute slot is CURRENTLY showing on the main 12 buttons (accounting
	-- for stealth/bonus-bar swaps) wins over the static page table below.
	for i = 1, 12 do
		if CurrentMainBarSlot(i) == slot then
			return "ActionButton" .. i
		end
	end

	for _, range in ipairs(BAR_RANGES) do
		if slot >= range.first and slot <= range.last then
			return range.prefix .. (slot - range.base)
		end
	end
	return nil
end

-- Published so the invariant "every slot we index resolves to a frame" is testable, and
-- so Display can eventually share this instead of keeping its own copy.
Tuono.Highlight.FrameNameForSlot = GetActionButtonFrameName

-- GetActionInfo, secret-safe. Display.lua learned this the expensive way: an unreadable
-- actionID makes the `actionID == spellID` comparison RAISE, and one secret slot mid-loop
-- took out the entire icon strip. The same hazard is worse here, because a raise inside
-- rebuildSlotIndex leaves the whole index empty and no spell resolves to any button.
-- Skipping one slot costs at most one glow; raising costs all of them.
local function safeActionInfo(slot)
	if not _G.GetActionInfo then return nil, nil end
	local ok, actionType, actionID = pcall(_G.GetActionInfo, slot)
	if not ok then return nil, nil end
	if Tuono.isSecret(actionType) then actionType = nil end
	if type(actionType) ~= "string" then actionType = nil end
	local id = Tuono.readNum(actionID)
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

-- ============================================================================
-- SPELL -> ACTION SLOT INDEX
-- ============================================================================
-- This used to scan for the slot on every lookup: 12 GetActionInfo calls, then a
-- fallback sweep of all 120 slots, with each slot running SpellMatchesAction ->
-- two pcall'd C_Spell override calls. ~390 C calls per resolution.
--
-- And it ran EVERY TICK, because the caller only cached on success: a recommendation
-- that is not on any action bar -- a levelling rogue, an unbarred cooldown -- never
-- populated the cache, so the guard never short-circuited and the full sweep repeated
-- at 10Hz forever. (Display's keybind cache already solved this with a MISS sentinel;
-- Highlight never got the same treatment.)
--
-- Now the bar is indexed ONCE per layout change. Lookup is a table read, and a missing
-- key is a definitive miss rather than a reason to rescan -- the index is complete by
-- construction, so absence is information.
local slotIndex = {}
local slotIndexDirty = true

local function MarkSlotIndexDirty()
	slotIndexDirty = true
end

local function rebuildSlotIndex()
	wipe(slotIndex)
	slotIndexDirty = false
	if not _G.GetActionInfo then return end

	-- Iterate exactly the slots BAR_RANGES can resolve to a frame. Sweeping further
	-- indexed spells that could never be glowed.
	for slot = 1, MAX_ACTION_SLOT do
		local actionType, actionID = safeActionInfo(slot)
		if actionID and
			(actionType == "spell" or actionType == "talent" or actionType == "action") then
			-- First slot wins, so a duplicated ability resolves to its earliest button.
			if slotIndex[actionID] == nil then slotIndex[actionID] = slot end

			-- Index BOTH directions of an override pair, so a lookup succeeds whether we
			-- hold the base ID (which is what the profile stores) or the override the
			-- bar actually reports. Done here, once per layout change, instead of two
			-- pcall'd resolutions per slot per tick.
			if Tuono.ResolveBaseSpell then
				local base = Tuono.ResolveBaseSpell(actionID)
				if base and base ~= actionID and slotIndex[base] == nil then
					slotIndex[base] = slot
				end
			end
			if Tuono.ResolveOverrideSpell then
				local override = Tuono.ResolveOverrideSpell(actionID)
				if override and override ~= actionID and slotIndex[override] == nil then
					slotIndex[override] = slot
				end
			end
		end
	end
end

-- Resolve spellID to action slot using available APIs
local function GetActionSlotForSpell(spellID)
	if not spellID then return nil end

	if slotIndexDirty then rebuildSlotIndex() end
	local indexed = slotIndex[spellID]
	if indexed then return indexed end

	-- Not in the index. The index covers all 120 slots, so this is a real miss and
	-- there is nothing to gain from sweeping again -- except for the override case,
	-- which is one cheap resolution rather than 120.
	if Tuono.ResolveOverrideSpell then
		local override = Tuono.ResolveOverrideSpell(spellID)
		if override and override ~= spellID then return slotIndex[override] end
	end
	return nil
end

-- Retained for the /tuono debug path and as a correctness reference; not on any hot
-- path any more.
local function GetActionSlotForSpell_Scan(spellID)
	if not spellID then return nil end

	-- TIER 1: C_ActionBar.FindSpellActionButtons (modern). Expects a BASE spell ID and
	-- resolves overrides internally (VERIFIED, warcraft.wiki.gg).
	-- BUGFIX: Tuono.safe returns a SINGLE value (see Core.lua: `return result`), not an
	-- (ok, result) pair. `local ok, buttons = Tuono.safe(...)` put the buttons array in
	-- `ok` and left `buttons` always nil, so `if ok and buttons` never passed and this
	-- modern path was permanently dead -- every lookup fell through to the uncached
	-- 120-slot scan below, on the 0.1s combat tick. pcall directly instead.
	if _G.C_ActionBar and _G.C_ActionBar.FindSpellActionButtons then
		local ok, buttons = pcall(_G.C_ActionBar.FindSpellActionButtons, spellID)
		if ok and buttons and #buttons > 0 then
			return buttons[1]
		end
	end

	-- TIER 2: the CURRENTLY VISIBLE main-bar slots (bonus-bar aware), so the glow
	-- follows a stealth-only spell (e.g. Ambush) to whatever button is ACTUALLY
	-- showing it right now instead of a static page-1 guess. Override-aware match.
	-- Read through safeActionInfo, not raw. A secret actionID makes the comparison below
	-- RAISE, and this whole function is called from a slash command with nothing between
	-- it and the user -- so an unreadable slot would turn a diagnostic into an error.
	if _G.GetActionInfo then
		for i = 1, 12 do
			local slot = CurrentMainBarSlot(i)
			local actionType, actionID = safeActionInfo(slot)
			if actionMatches(actionType, actionID, spellID) then
				return slot
			end
		end
	end

	-- TIER 3: fallback sweep of every slot that has a button frame (fixed multibars are
	-- unaffected by the main-bar page/bonus swap, plus a catch-all for anything TIER 1/2
	-- missed).
	if _G.GetActionInfo then
		for slot = 1, MAX_ACTION_SLOT do
			local actionType, actionID = safeActionInfo(slot)
			if actionMatches(actionType, actionID, spellID) then
				return slot
			end
		end
	end

	return nil
end

-- Get the button frame from global table
local function GetButtonFrame(frameName)
	if not frameName then return nil end
	local frame = _G[frameName]
	if frame and type(frame) == "table" and frame.GetName then
		return frame
	end
	return nil
end

-- ============================================================================
-- GLOW OVERLAYS  --  WE NEVER TOUCH THE SECURE BUTTON
-- ============================================================================
-- The previous implementation called buttonFrame:CreateTexture() on Blizzard's
-- ActionButtons -- SecureActionButtonTemplate derivatives -- lazily, from the 0.1s
-- combat tick. Creating a region on a secure frame from addon-tainted execution taints
-- that frame's region list, and the taint surfaces later when Blizzard's own code
-- handles a click on it. That is the "Interface action failed because of an AddOn"
-- report. It was also LAZY, so the first creation landed mid-fight, exactly when a
-- stealth bar swap moved the glow onto an undecorated button.
--
-- Now: the overlay is OUR frame, parented to UIParent, merely ANCHORED to the button.
-- SetPoint against a secure frame reads its position; it writes nothing to it. Frames
-- are pooled and pre-created at login so no allocation happens in combat.
--
-- The Blizzard-helper and "discovered API" paths are gone too. ActionButton_ShowOverlayGlow
-- was removed in the 10.1 spell-alert refactor, so it was dead; and if it did exist it
-- would attach a Blizzard alert frame to the secure button -- the same taint class via
-- someone else's code. The C_ActionBar name-sniffing loop was worse than useless: it
-- would happily bind show/hide to two unrelated functions with mismatched signatures
-- and then call them with a frame.
local GLOW_POOL_SIZE = 4
local glowPool = {}
local glowByButton = {}

-- How many buttons may carry a mark at once: the immediate recommendation plus two steps
-- of lead. Subitizing is reliable to about four, and three leaves margin.
local MAX_MARKS = 3
local MAX_PIPS = MAX_MARKS - 1

-- ============================================================================
-- COLOUR TOKENS
-- ============================================================================
-- DELIBERATELY NO GREEN AND NO RED. Green/red is the single most common colourblind
-- failure (deuteranopia, roughly 6% of men), and the previous glow was pure green.
-- Authority is carried by LUMINANCE instead, which works for every form of colour vision
-- and reads against arbitrary spell art.
--
-- Blue is deliberately absent too: Blizzard's own Assisted Highlight is blue, and a blue
-- Tuono mark would be indistinguishable from it.
local COLOR_AUTHORITY = { 0.95, 0.95, 0.95, 0.95 }   -- position 1
local COLOR_LEAD      = { 0.60, 0.60, 0.65, 0.75 }   -- positions 2-3

local RING_THICKNESS_PRIMARY = 2
local RING_THICKNESS_LEAD = 1

-- Frame and texture API surface varies across builds and across the test harness. None
-- of these calls is worth taking the whole highlight module down for.
local function try(obj, method, ...)
	if obj and obj[method] then pcall(obj[method], obj, ...) end
end

local function makeGlow()
	local f = CreateFrame("Frame", nil, UIParent)
	if f.SetFrameStrata then pcall(f.SetFrameStrata, f, "HIGH") end
	if f.Hide then f:Hide() end
	if not f.CreateTexture then return f end

	-- FOUR EDGES, NOT A FILL.
	--
	-- This used to be a single texture with SetAllPoints on a frame covering the entire
	-- button, at HIGH strata, coloured with a three-argument SetColorTexture -- which
	-- defaults alpha to 1.0. The result was a solid rectangle over the spell art: the
	-- player was told "press the green square" and could not see which spell it was.
	--
	-- Edge pieces mark the button and leave the icon completely readable, which is the
	-- entire point of putting the mark on the bar rather than on our own strip.
	f.ring = {}
	for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local tex = f:CreateTexture(nil, "OVERLAY")
		tex.edge = edge
		f.ring[#f.ring + 1] = tex
	end

	-- ORDINAL PIPS carry lead time onto the action bar, which is the only thing that
	-- justifies occupying it: Blizzard already ships a native position-1 highlight, so a
	-- helper that marks only position 1 is a worse copy of a built-in feature. Numerals
	-- would need foveal attention and cancel the benefit of being peripheral; one to
	-- three dots are preattentive.
	f.pips = {}
	for i = 1, MAX_PIPS do
		local tex = f:CreateTexture(nil, "OVERLAY")
		try(tex, "SetSize", 3, 3)
		try(tex, "Hide")
		f.pips[i] = tex
	end

	-- The one place a numeral earns its slot. A repeat count is read at leisure and its
	-- absence is the common case -- and "Sinister Strike x4" on one button is more honest
	-- than four identical marks, which would imply four decisions where there is one
	-- decision repeated.
	if f.CreateFontString then
		f.countText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		try(f.countText, "Hide")
	end

	return f
end

local function layoutRing(f, thickness, color)
	for _, tex in ipairs(f.ring or {}) do
		try(tex, "ClearAllPoints")
		try(tex, "SetColorTexture", color[1], color[2], color[3], color[4])
		local edge = tex.edge
		if edge == "TOP" then
			try(tex, "SetPoint", "TOPLEFT", f, "TOPLEFT", 0, 0)
			try(tex, "SetPoint", "TOPRIGHT", f, "TOPRIGHT", 0, 0)
			try(tex, "SetHeight", thickness)
		elseif edge == "BOTTOM" then
			try(tex, "SetPoint", "BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
			try(tex, "SetPoint", "BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
			try(tex, "SetHeight", thickness)
		elseif edge == "LEFT" then
			try(tex, "SetPoint", "TOPLEFT", f, "TOPLEFT", 0, 0)
			try(tex, "SetPoint", "BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
			try(tex, "SetWidth", thickness)
		else
			try(tex, "SetPoint", "TOPRIGHT", f, "TOPRIGHT", 0, 0)
			try(tex, "SetPoint", "BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
			try(tex, "SetWidth", thickness)
		end
		try(tex, "Show")
	end
end

local function configureGlow(f, mark)
	local primary = (mark.ordinal or 1) <= 1
	layoutRing(f,
		primary and RING_THICKNESS_PRIMARY or RING_THICKNESS_LEAD,
		primary and COLOR_AUTHORITY or COLOR_LEAD)

	-- Pips count PRESSES AWAY, so the immediate recommendation carries none: its thicker,
	-- brighter ring already says "now".
	local pipCount = math.max(0, math.min(MAX_PIPS, (mark.ordinal or 1) - 1))
	for i, tex in ipairs(f.pips or {}) do
		if i <= pipCount then
			try(tex, "ClearAllPoints")
			try(tex, "SetPoint", "TOPRIGHT", f, "TOPRIGHT", -3 - (i - 1) * 5, -3)
			try(tex, "SetColorTexture", COLOR_LEAD[1], COLOR_LEAD[2], COLOR_LEAD[3], 0.9)
			try(tex, "Show")
		else
			try(tex, "Hide")
		end
	end

	if f.countText then
		local n = mark.repeatCount or 1
		if n >= 2 then
			try(f.countText, "ClearAllPoints")
			try(f.countText, "SetPoint", "BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
			try(f.countText, "SetText", "x" .. n)
			try(f.countText, "Show")
		else
			try(f.countText, "Hide")
		end
	end
end

local function acquireGlow()
	return table.remove(glowPool) or makeGlow()
end

-- Pre-create the overlay pool at login so nothing allocates during a fight. (Allocating
-- our OWN frames in combat is safe -- the taint risk was only ever writing to Blizzard's
-- secure buttons -- but pooling keeps the combat tick clean.)
function PrewarmGlowPool()
	for _ = 1, GLOW_POOL_SIZE do
		table.insert(glowPool, makeGlow())
	end
end

local function ShowGlow(buttonFrame, mark)
	if not buttonFrame then return false end
	if glowByButton[buttonFrame] then return true end

	local f = acquireGlow()
	-- Anchoring to the secure frame is a READ of it. Nothing is written to the button.
	local ok = pcall(function()
		f:ClearAllPoints()
		f:SetAllPoints(buttonFrame)
	end)
	if not ok then
		table.insert(glowPool, f)
		return false
	end

	-- Parented to UIParent, so the overlay does NOT inherit the button's visibility.
	-- Without this a hidden bar (vehicle UI, bar fade, page swap) would leave a glow
	-- floating over nothing.
	--
	-- Only an EXPLICIT false counts as hidden. `not buttonFrame:IsVisible()` also
	-- catches nil, which means "this build/harness does not answer", and refusing to
	-- glow on an unanswered question is the same unknown-as-negative mistake this
	-- codebase keeps making.
	if buttonFrame.IsVisible then
		local okVis, vis = pcall(buttonFrame.IsVisible, buttonFrame)
		if okVis and vis == false then
			table.insert(glowPool, f)
			return false
		end
	end

	configureGlow(f, mark or { ordinal = 1, repeatCount = 1 })
	f:Show()
	glowByButton[buttonFrame] = f
	return true
end

local function HideGlow(buttonFrame)
	if not buttonFrame then return false end
	local f = glowByButton[buttonFrame]
	if not f then return false end
	f:Hide()
	f:ClearAllPoints()
	-- Reset the decorations too. A pooled frame reused for position 1 must not still be
	-- wearing the pips and repeat count of the position-3 mark it last served.
	for _, tex in ipairs(f.pips or {}) do try(tex, "Hide") end
	if f.countText then try(f.countText, "Hide") end
	glowByButton[buttonFrame] = nil
	table.insert(glowPool, f)
	return true
end

-- Buttons currently wearing a mark, in sequence order.
local activeMarks = {}
local lastSignature = nil

local function clearMarks()
	for _, mark in ipairs(activeMarks) do
		HideGlow(mark.button)
	end
	for i = #activeMarks, 1, -1 do activeMarks[i] = nil end
	lastHighlightedButton = nil
	lastHighlightedSpellID = nil
end

-- Turn the engine's queue into at most MAX_MARKS button marks.
local function buildMarks(result)
	local marks = {}
	local bySpell = {}
	local ordinal = 0

	for _, entry in ipairs((result and result.queue) or {}) do
		-- Only the SEQUENCE is a prediction. The cooldown and trinket reminders appended
		-- after it report something ready now; giving them an ordinal would claim they
		-- are the third press, which they are not.
		if entry.isSequence and entry.spellID then
			ordinal = ordinal + 1

			local existing = bySpell[entry.spellID]
			if existing then
				-- The honest answer at 0 combo points is "Sinister Strike x4", and that is
				-- ONE button. Marking it three times would need three ordinals on one
				-- frame, which is unreadable and untrue.
				existing.repeatCount = existing.repeatCount + 1
			else
				-- An uncertain LOOKAHEAD step gets no mark: if we cannot stand behind
				-- step 3 we do not point at it, and the number of marks stays a signal.
				-- Position 1 is exempt -- refusing to answer "what do I press now" is
				-- strictly worse than answering it with a visible uncertainty cue.
				if ordinal > 1 and entry.confidence == "unknown" then break end
				if #marks >= MAX_MARKS then break end

				local mark = {
					spellID = entry.spellID,
					ordinal = ordinal,
					repeatCount = 1,
					confidence = entry.confidence,
				}
				marks[#marks + 1] = mark
				bySpell[entry.spellID] = mark
			end
		end
	end

	return marks
end

local function signatureOf(marks)
	local parts = {}
	for i, m in ipairs(marks) do
		parts[i] = tostring(m.spellID) .. ":" .. m.ordinal .. ":" .. m.repeatCount
	end
	return table.concat(parts, "|")
end

-- Main highlight update: called after Display.Render
function Tuono.Highlight.Update(result)
	if not Tuono.db or not Tuono.db.highlight or not Tuono.db.highlight.enabled then
		clearMarks()
		lastSignature = nil
		return
	end

	local marks = buildMarks(result)
	local signature = signatureOf(marks)

	-- Cache hit only holds when BOTH the marked set AND the action-bar layout are
	-- unchanged (see barDirty declaration for why: a stealth/bonus-bar swap can leave
	-- every spellID identical while moving them to different buttons).
	--
	-- The signature covers a resolved MISS as well, because it is derived from the queue
	-- rather than from what we managed to glow. Keying on success is what made an
	-- unbarred recommendation re-resolve every tick forever.
	if not barDirty and signature == lastSignature then
		return
	end
	barDirty = false
	lastSignature = signature

	clearMarks()

	local usedButton = {}
	for _, mark in ipairs(marks) do
		local slot = GetActionSlotForSpell(mark.spellID)
		local frameName = slot and GetActionButtonFrameName(slot) or nil
		local buttonFrame = frameName and GetButtonFrame(frameName) or nil
		-- Two spellIDs can resolve to the SAME button (an override pair), and one button
		-- can only carry one mark. The earlier ordinal wins, because that is the press
		-- the player makes first.
		if buttonFrame and not usedButton[buttonFrame] then
			if ShowGlow(buttonFrame, mark) then
				usedButton[buttonFrame] = true
				mark.button = buttonFrame
				activeMarks[#activeMarks + 1] = mark
			end
		end
	end

	local first = activeMarks[1]
	lastHighlightedButton = first and first.button or nil
	lastHighlightedSpellID = first and first.spellID or nil
end

-- Read-only view of what is currently marked. Copies out, so a caller cannot reach in
-- and mutate the module's own bookkeeping.
function Tuono.Highlight.ActiveMarks()
	local out = {}
	for i, m in ipairs(activeMarks) do
		local name = nil
		if m.button and m.button.GetName then
			local ok, n = pcall(m.button.GetName, m.button)
			name = ok and n or nil
		end
		out[i] = {
			spellID = m.spellID,
			ordinal = m.ordinal,
			repeatCount = m.repeatCount,
			confidence = m.confidence,
			buttonName = name,
		}
	end
	return out
end

function Tuono.Highlight.LastButtonName()
	if not (lastHighlightedButton and lastHighlightedButton.GetName) then return nil end
	local ok, name = pcall(lastHighlightedButton.GetName, lastHighlightedButton)
	return ok and name or nil
end

-- Clear glow on combat exit if combatOnly is true
local function ClearGlowOutOfCombat()
	if Tuono.db and Tuono.db.highlight and Tuono.db.highlight.combatOnly then
		clearMarks()
		lastSignature = nil
	end
end

-- Slash command handlers
local function HandleGlow(arg)
	if not arg or arg == "" then
		Tuono.db.highlight.enabled = not Tuono.db.highlight.enabled
		local state = Tuono.db.highlight.enabled and "ON" or "OFF"
		Tuono.print("Action bar highlight " .. state)
		return
	end

	local cmd = string.lower(arg)
	if cmd == "combat" then
		Tuono.db.highlight.combatOnly = not Tuono.db.highlight.combatOnly
		local state = Tuono.db.highlight.combatOnly and "ON" or "OFF"
		Tuono.print("Highlight in combat only: " .. state)
	else
		Tuono.print("Unknown glow option: " .. arg)
	end
end

-- Register events for lifecycle management
local function RegisterHighlightEvents()
	-- Clear glow on combat exit
	Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", ClearGlowOutOfCombat)

	-- Clear on logout/reload
	Tuono.RegisterEvent("PLAYER_LOGOUT", function()
		clearMarks()
		lastSignature = nil
	end)

	-- STEALTH SWAPS THE ACTION BAR PAGE: the glow target must be re-resolved even when
	-- the recommended spellID hasn't changed, because the underlying bar layout might
	-- have. VERIFIED events (warcraft.wiki.gg, 2026-08-01): UPDATE_STEALTH,
	-- ACTIONBAR_PAGE_CHANGED, UPDATE_BONUS_ACTIONBAR fire with no payload.
	-- ACTIONBAR_SLOT_CHANGED/UPDATE_BINDINGS/SPELLS_CHANGED/PLAYER_REGEN_DISABLED are
	-- pre-existing, verified WoW events used elsewhere in this addon.
	-- Both the glow-target cache AND the slot index invalidate on the same signals:
	-- anything that can move a spell to a different button, or change which override
	-- is active. Rebuilding is event-driven, never per tick.
	local function dirty()
		MarkBarDirty()
		MarkSlotIndexDirty()
	end

	Tuono.RegisterEvent("UPDATE_STEALTH", dirty)
	Tuono.RegisterEvent("ACTIONBAR_PAGE_CHANGED", dirty)
	Tuono.RegisterEvent("UPDATE_BONUS_ACTIONBAR", dirty)
	Tuono.RegisterEvent("ACTIONBAR_SLOT_CHANGED", dirty)
	Tuono.RegisterEvent("SPELLS_CHANGED", dirty)
	Tuono.RegisterEvent("UPDATE_BINDINGS", MarkBarDirty)
	Tuono.RegisterEvent("PLAYER_REGEN_DISABLED", MarkBarDirty)
	Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", MarkBarDirty)
	Tuono.RegisterEvent("PLAYER_ENTERING_WORLD", dirty)
	Tuono.RegisterEvent("TRAIT_CONFIG_UPDATED", dirty)
end

-- Initialization: probe glow mechanisms and register events
function Tuono.Highlight.Init()
	-- Init is called once from Core, but guard anyway: it used to have no guard while
	-- Core's comment claimed it was idempotent, so a second call double-registered
	-- eight event handlers and the slash command.
	if Tuono.Highlight._inited then return end
	Tuono.Highlight._inited = true

	PrewarmGlowPool()
	RegisterHighlightEvents()
	Tuono.RegisterSlash("glow", HandleGlow, "Toggle action bar glow highlighting (or 'combat' for combat-only mode).")
end

-- Extend debug output
local originalUpdateDebugOutput = nil

function Tuono.Highlight.AppendDebugOutput()
	if not Tuono.Display or not Tuono.Display.anchor then
		return
	end

	-- Append highlight-specific debug info
	local debugInfo = {}
	table.insert(debugInfo, "=== Highlight Debug ===")
	table.insert(debugInfo, "Enabled: " .. (Tuono.db and Tuono.db.highlight and Tuono.db.highlight.enabled and "ON" or "OFF"))
	table.insert(debugInfo, "Combat-only: " .. (Tuono.db and Tuono.db.highlight and Tuono.db.highlight.combatOnly and "ON" or "OFF"))
	table.insert(debugInfo, "Glow mechanism: " .. (glowMechanism or "none"))
	table.insert(debugInfo, "Max action slot: " .. tostring(MAX_ACTION_SLOT))
	-- The PRIMARY marked button, as one line. Multi-step marking replaced this with a
	-- per-mark list, which answers "what is marked" but no longer answers "what am I
	-- supposed to press", and that is the question a player -- or a diagnostic -- asks
	-- first. It is also the only single-valued handle anything outside this file has on
	-- the glow, so removing it silently broke every consumer of the debug output.
	table.insert(debugInfo, "Button frame: " ..
		(Tuono.Highlight.LastButtonName() or "none"))
	for _, m in ipairs(Tuono.Highlight.ActiveMarks()) do
		table.insert(debugInfo, string.format("  #%d spell %s x%d on %s (%s)",
			m.ordinal, tostring(m.spellID), m.repeatCount,
			tostring(m.buttonName), tostring(m.confidence)))
	end
	if #activeMarks == 0 then
		table.insert(debugInfo, "  no buttons marked")
	end

	for _, line in ipairs(debugInfo) do
		Tuono.print(line)
	end
end
