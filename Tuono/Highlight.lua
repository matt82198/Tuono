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

-- Map action slot (1-108) to the action button frame name
-- Canonical layout: 1-12 ActionButton, 13-24 ActionButton (page 2), 25-36 MultiBarRightButton, etc.
local function GetActionButtonFrameName(slot)
	if type(slot) ~= "number" or slot < 1 or slot > 108 then
		return nil
	end

	-- Whichever absolute slot is CURRENTLY showing on the main 12 buttons (accounting
	-- for stealth/bonus-bar swaps) wins over the static page table below.
	for i = 1, 12 do
		if CurrentMainBarSlot(i) == slot then
			return "ActionButton" .. i
		end
	end

	if slot >= 1 and slot <= 12 then
		return "ActionButton" .. slot
	elseif slot >= 13 and slot <= 24 then
		return "ActionButton" .. (slot - 12)
	elseif slot >= 25 and slot <= 36 then
		return "MultiBarRightButton" .. (slot - 24)
	elseif slot >= 37 and slot <= 48 then
		return "MultiBarLeftButton" .. (slot - 36)
	elseif slot >= 49 and slot <= 60 then
		return "MultiBarBottomRightButton" .. (slot - 48)
	elseif slot >= 61 and slot <= 72 then
		return "MultiBarBottomLeftButton" .. (slot - 60)
	elseif slot >= 73 and slot <= 84 then
		return "MultiBar5Button" .. (slot - 72)
	elseif slot >= 85 and slot <= 96 then
		return "MultiBar6Button" .. (slot - 84)
	elseif slot >= 97 and slot <= 108 then
		return "MultiBar7Button" .. (slot - 96)
	end
	return nil
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

	for slot = 1, 120 do
		local ok, actionType, actionID = pcall(_G.GetActionInfo, slot)
		if ok and actionID and
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
	if _G.GetActionInfo then
		for i = 1, 12 do
			local slot = CurrentMainBarSlot(i)
			local actionType, actionID = _G.GetActionInfo(slot)
			local matches = (actionType == "spell" or actionType == "talent" or actionType == "action")
				and ((Tuono.SpellMatchesAction and Tuono.SpellMatchesAction(spellID, actionID)) or actionID == spellID)
			if matches then
				return slot
			end
		end
	end

	-- TIER 3: fallback full sweep of all 120 action slots (fixed multibars unaffected
	-- by the main-bar page/bonus swap, plus a catch-all for anything TIER 1/2 missed).
	if _G.GetActionInfo then
		for slot = 1, 120 do
			local actionType, actionID = _G.GetActionInfo(slot)
			local matches = (actionType == "spell" or actionType == "talent" or actionType == "action")
				and ((Tuono.SpellMatchesAction and Tuono.SpellMatchesAction(spellID, actionID)) or actionID == spellID)
			if matches then
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

local function makeGlow()
	local f = CreateFrame("Frame", nil, UIParent)
	-- Frame API surface varies across builds and harnesses; none of these are worth
	-- taking the whole highlight module down for.
	if f.SetFrameStrata then pcall(f.SetFrameStrata, f, "HIGH") end
	if f.Hide then f:Hide() end
	if f.CreateTexture then
		local tex = f:CreateTexture(nil, "OVERLAY")
		if tex and tex.SetAllPoints then pcall(tex.SetAllPoints, tex, f) end
		if tex and tex.SetColorTexture then pcall(tex.SetColorTexture, tex, 0, 1, 0.35) end
		f.tex = tex
	end
	return f
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

local function ShowGlow(buttonFrame)
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
	glowByButton[buttonFrame] = nil
	table.insert(glowPool, f)
	return true
end

-- Main highlight update: called after Display.Render
function Tuono.Highlight.Update(result)
	if not Tuono.db or not Tuono.db.highlight or not Tuono.db.highlight.enabled then
		-- Ensure no glow is active
		if lastHighlightedButton then
			HideGlow(lastHighlightedButton)
			lastHighlightedButton = nil
			lastHighlightedSpellID = nil
		end
		return
	end

	-- Clear previous highlight if recommendation changed
	local currentSpellID = nil
	if result and result.queue and #result.queue > 0 then
		currentSpellID = result.queue[1].spellID
	end

	-- Cache hit only holds when BOTH the recommendation AND the action-bar layout are
	-- unchanged (see barDirty declaration for why: a stealth/bonus-bar swap can leave
	-- the recommended spellID identical while moving it to a different button).
	--
	-- The `lastHighlightedButton` term is gone from this guard. It was only ever
	-- assigned on a SUCCESSFUL resolution, so a spell that is not on any bar left it
	-- nil, the guard never short-circuited, and the resolution re-ran every tick
	-- forever. A resolved miss is now cached like any other result.
	if not barDirty and currentSpellID == lastHighlightedSpellID then
		return
	end
	barDirty = false

	-- Clear previous glow
	if lastHighlightedButton then
		HideGlow(lastHighlightedButton)
		lastHighlightedButton = nil
		lastHighlightedSpellID = nil
	end

	-- Apply glow to new recommendation.
	-- lastHighlightedSpellID is recorded UNCONDITIONALLY, including when the spell is
	-- not on any bar. Recording it only on success is what made an unbarred
	-- recommendation re-resolve every tick forever; "we looked and there is no button"
	-- is a result worth remembering, and barDirty already invalidates it.
	lastHighlightedSpellID = currentSpellID

	if currentSpellID then
		local slot = GetActionSlotForSpell(currentSpellID)
		if slot then
			local frameName = GetActionButtonFrameName(slot)
			if frameName then
				local buttonFrame = GetButtonFrame(frameName)
				if buttonFrame then
					ShowGlow(buttonFrame)
					lastHighlightedButton = buttonFrame
				end
			end
		end
	end
end

-- Clear glow on combat exit if combatOnly is true
local function ClearGlowOutOfCombat()
	if Tuono.db and Tuono.db.highlight and Tuono.db.highlight.combatOnly then
		if lastHighlightedButton then
			HideGlow(lastHighlightedButton)
			lastHighlightedButton = nil
			lastHighlightedSpellID = nil
		end
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
		if lastHighlightedButton then
			HideGlow(lastHighlightedButton)
			lastHighlightedButton = nil
			lastHighlightedSpellID = nil
		end
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
	table.insert(debugInfo, "Last spell ID: " .. (lastHighlightedSpellID or "none"))
	table.insert(debugInfo, "Button frame: " .. (lastHighlightedButton and lastHighlightedButton:GetName() or "none"))

	for _, line in ipairs(debugInfo) do
		Tuono.print(line)
	end
end
