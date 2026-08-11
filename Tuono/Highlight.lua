local ADDON_NAME, Tuono = ...

Tuono.Highlight = Tuono.Highlight or {}

-- Glow mechanisms probed at runtime
local glowMechanism = nil  -- will be set to "blizzard", "api", or "self-drawn"
local glowFunctions = {}   -- cached glow functions

-- Self-drawn glow overlay: map of buttonFrame -> glowTexture for fallback
local selfDrawnGlows = {}

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

-- Probe for available glow mechanisms (run once at startup)
local function ProbeGlowMechanisms()
	-- Try classic Blizzard helpers first
	if _G.ActionButton_ShowOverlayGlow and _G.ActionButton_HideOverlayGlow then
		glowMechanism = "blizzard"
		glowFunctions.show = _G.ActionButton_ShowOverlayGlow
		glowFunctions.hide = _G.ActionButton_HideOverlayGlow
		return
	end

	-- Try C_ActionBar or other discovered APIs at runtime
	if _G.C_ActionBar then
		-- Enumerate C_ActionBar table for glow-related functions
		for k, v in pairs(_G.C_ActionBar) do
			if type(k) == "string" and string.match(k:lower(), "glow") and type(v) == "function" then
				-- Heuristic: if we find a glow function, prefer show/hide pair
				if string.match(k:lower(), "show") then
					glowFunctions.show = v
				elseif string.match(k:lower(), "hide") then
					glowFunctions.hide = v
				end
			end
		end
		if glowFunctions.show and glowFunctions.hide then
			glowMechanism = "discovered API"
			return
		end
	end

	-- Fall back to self-drawn glow
	glowMechanism = "self-drawn"
end

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

-- Resolve spellID to action slot using available APIs
local function GetActionSlotForSpell(spellID)
	if not spellID then return nil end

	-- TIER 1: C_ActionBar.FindSpellActionButtons (modern). Expects a BASE spell ID and
	-- resolves overrides internally (VERIFIED, warcraft.wiki.gg).
	-- BUGFIX: Tuono.safe returns a SINGLE value (see Core.lua: `return result`), not an
	-- (ok, result) pair. `local ok, buttons = Tuono.safe(...)` put the buttons array in
	-- `ok` and left `buttons` always nil, so `if ok and buttons` never passed and this
	-- modern path was permanently dead -- every lookup fell through to the uncached
	-- 120-slot scan below, on the 0.1s combat tick. pcall directly instead.
	if _G.C_ActionBar and _G.C_ActionBar.FindSpellActionButtons then
		local ok, buttons = pcall(function() return _G.C_ActionBar.FindSpellActionButtons(spellID) end)
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

-- Create or retrieve a self-drawn glow overlay for a button frame
local function GetOrCreateSelfDrawnGlow(buttonFrame)
	if not buttonFrame then return nil end

	if selfDrawnGlows[buttonFrame] then
		return selfDrawnGlows[buttonFrame]
	end

	-- Create a new glow overlay: bright border texture parented to the button
	local glowTexture = buttonFrame:CreateTexture(nil, "OVERLAY")
	glowTexture:SetAllPoints(buttonFrame)
	glowTexture:SetColorTexture(0, 1, 1, 0.3)  -- cyan, semi-transparent
	glowTexture:Hide()
	selfDrawnGlows[buttonFrame] = glowTexture

	return glowTexture
end

-- Show glow on a button frame
local function ShowGlow(buttonFrame)
	if not buttonFrame then return false end

	-- Try Blizzard mechanism
	if glowMechanism == "blizzard" and glowFunctions.show then
		Tuono.safe(glowFunctions.show, buttonFrame)
		return true
	end

	-- Try discovered API
	if glowMechanism == "discovered API" and glowFunctions.show then
		Tuono.safe(glowFunctions.show, buttonFrame)
		return true
	end

	-- Self-drawn fallback
	if glowMechanism == "self-drawn" then
		local glowTexture = GetOrCreateSelfDrawnGlow(buttonFrame)
		if glowTexture then
			glowTexture:Show()
			return true
		end
	end

	return false
end

-- Hide glow on a button frame
local function HideGlow(buttonFrame)
	if not buttonFrame then return false end

	-- Try Blizzard mechanism
	if glowMechanism == "blizzard" and glowFunctions.hide then
		Tuono.safe(glowFunctions.hide, buttonFrame)
		return true
	end

	-- Try discovered API
	if glowMechanism == "discovered API" and glowFunctions.hide then
		Tuono.safe(glowFunctions.hide, buttonFrame)
		return true
	end

	-- Self-drawn fallback
	if glowMechanism == "self-drawn" then
		local glowTexture = selfDrawnGlows[buttonFrame]
		if glowTexture then
			glowTexture:Hide()
			return true
		end
	end

	return false
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
	if not barDirty and currentSpellID == lastHighlightedSpellID and lastHighlightedButton then
		return
	end
	barDirty = false

	-- Clear previous glow
	if lastHighlightedButton then
		HideGlow(lastHighlightedButton)
		lastHighlightedButton = nil
		lastHighlightedSpellID = nil
	end

	-- Apply glow to new recommendation
	if currentSpellID then
		local slot = GetActionSlotForSpell(currentSpellID)
		if slot then
			local frameName = GetActionButtonFrameName(slot)
			if frameName then
				local buttonFrame = GetButtonFrame(frameName)
				if buttonFrame then
					ShowGlow(buttonFrame)
					lastHighlightedButton = buttonFrame
					lastHighlightedSpellID = currentSpellID
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
	Tuono.RegisterEvent("UPDATE_STEALTH", MarkBarDirty)
	Tuono.RegisterEvent("ACTIONBAR_PAGE_CHANGED", MarkBarDirty)
	Tuono.RegisterEvent("UPDATE_BONUS_ACTIONBAR", MarkBarDirty)
	Tuono.RegisterEvent("ACTIONBAR_SLOT_CHANGED", MarkBarDirty)
	Tuono.RegisterEvent("SPELLS_CHANGED", MarkBarDirty)
	Tuono.RegisterEvent("UPDATE_BINDINGS", MarkBarDirty)
	Tuono.RegisterEvent("PLAYER_REGEN_DISABLED", MarkBarDirty)
	Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", MarkBarDirty)
end

-- Initialization: probe glow mechanisms and register events
function Tuono.Highlight.Init()
	ProbeGlowMechanisms()
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
