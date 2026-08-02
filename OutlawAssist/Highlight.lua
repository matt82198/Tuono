local ADDON_NAME, OA = ...

OA.Highlight = OA.Highlight or {}

-- Glow mechanisms probed at runtime
local glowMechanism = nil  -- will be set to "blizzard", "api", or "self-drawn"
local glowFunctions = {}   -- cached glow functions

-- Self-drawn glow overlay: map of buttonFrame -> glowTexture for fallback
local selfDrawnGlows = {}

-- Cache: last highlighted button to avoid redundant work
local lastHighlightedButton = nil
local lastHighlightedSpellID = nil

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

-- Map action slot (1-108) to the action button frame name
-- Canonical layout: 1-12 ActionButton, 13-24 ActionButton (page 2), 25-36 MultiBarRightButton, etc.
local function GetActionButtonFrameName(slot)
	if type(slot) ~= "number" or slot < 1 or slot > 108 then
		return nil
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

	-- Try C_ActionBar.FindSpellActionButtons (modern)
	if _G.C_ActionBar and _G.C_ActionBar.FindSpellActionButtons then
		local ok, buttons = OA.safe(function() return _G.C_ActionBar.FindSpellActionButtons(spellID) end)
		if ok and buttons and #buttons > 0 then
			return buttons[1]
		end
	end

	-- Fallback: iterate action buttons 1-120
	if _G.GetActionInfo then
		for slot = 1, 120 do
			local actionType, actionID = _G.GetActionInfo(slot)
			if actionID == spellID and (actionType == "spell" or actionType == "talent" or actionType == "action") then
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
		OA.safe(glowFunctions.show, buttonFrame)
		return true
	end

	-- Try discovered API
	if glowMechanism == "discovered API" and glowFunctions.show then
		OA.safe(glowFunctions.show, buttonFrame)
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
		OA.safe(glowFunctions.hide, buttonFrame)
		return true
	end

	-- Try discovered API
	if glowMechanism == "discovered API" and glowFunctions.hide then
		OA.safe(glowFunctions.hide, buttonFrame)
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
function OA.Highlight.Update(result)
	if not OA.db or not OA.db.highlight or not OA.db.highlight.enabled then
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

	-- If recommendation hasn't changed, do nothing (cache hit)
	if currentSpellID == lastHighlightedSpellID and lastHighlightedButton then
		return
	end

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
	if OA.db and OA.db.highlight and OA.db.highlight.combatOnly then
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
		OA.db.highlight.enabled = not OA.db.highlight.enabled
		local state = OA.db.highlight.enabled and "ON" or "OFF"
		OA.print("Action bar highlight " .. state)
		return
	end

	local cmd = string.lower(arg)
	if cmd == "combat" then
		OA.db.highlight.combatOnly = not OA.db.highlight.combatOnly
		local state = OA.db.highlight.combatOnly and "ON" or "OFF"
		OA.print("Highlight in combat only: " .. state)
	else
		OA.print("Unknown glow option: " .. arg)
	end
end

-- Register events for lifecycle management
local function RegisterHighlightEvents()
	-- Clear glow on combat exit
	OA.RegisterEvent("PLAYER_REGEN_ENABLED", ClearGlowOutOfCombat)

	-- Clear on logout/reload
	OA.RegisterEvent("PLAYER_LOGOUT", function()
		if lastHighlightedButton then
			HideGlow(lastHighlightedButton)
			lastHighlightedButton = nil
			lastHighlightedSpellID = nil
		end
	end)
end

-- Initialization: probe glow mechanisms and register events
function OA.Highlight.Init()
	ProbeGlowMechanisms()
	RegisterHighlightEvents()
	OA.RegisterSlash("glow", HandleGlow, "Toggle action bar glow highlighting (or 'combat' for combat-only mode).")
end

-- Extend debug output
local originalUpdateDebugOutput = nil

function OA.Highlight.AppendDebugOutput()
	if not OA.Display or not OA.Display.anchor then
		return
	end

	-- Append highlight-specific debug info
	local debugInfo = {}
	table.insert(debugInfo, "=== Highlight Debug ===")
	table.insert(debugInfo, "Enabled: " .. (OA.db and OA.db.highlight and OA.db.highlight.enabled and "ON" or "OFF"))
	table.insert(debugInfo, "Combat-only: " .. (OA.db and OA.db.highlight and OA.db.highlight.combatOnly and "ON" or "OFF"))
	table.insert(debugInfo, "Glow mechanism: " .. (glowMechanism or "none"))
	table.insert(debugInfo, "Last spell ID: " .. (lastHighlightedSpellID or "none"))
	table.insert(debugInfo, "Button frame: " .. (lastHighlightedButton and lastHighlightedButton:GetName() or "none"))

	for _, line in ipairs(debugInfo) do
		OA.print(line)
	end
end
