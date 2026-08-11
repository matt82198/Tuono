local ADDON_NAME, OA = ...

OA.defaults = {
	updateInterval = 0.1,
	-- Tri-state: "auto" switches rotations on the live enemy count (with hysteresis),
	-- "on"/"off" pin one rotation. Auto is the default now that enemy counting is
	-- verified legal and range-filtered.
	aoeMode = "auto",
	aoeThreshold = 2,
	activeProfile = nil,
	show = {
		queue = true,
		ooc = true
	},
	display = {
		locked = true,
		scale = 1,
		point = "CENTER",
		x = 0,
		y = -180,
		iconCount = 4
	},
	highlight = {
		enabled = true,
		combatOnly = false
	}
}

local function HandleLock()
	OA.db.display.locked = true
	OA.print("Display locked.")
	if OA.Display and OA.Display.anchor then
		OA.Display.anchor:SetMovable(false)
	end
end

local function HandleUnlock()
	OA.db.display.locked = false
	OA.print("Display unlocked. Drag to move.")
	if OA.Display and OA.Display.anchor then
		OA.Display.anchor:SetMovable(true)
	end
end

local function HandleScale(arg)
	if not arg or arg == "" then
		OA.print("Usage: /oa scale <0.5-2>")
		return
	end
	local scale = tonumber(arg)
	if not scale then
		OA.print("Invalid scale. Use a number between 0.5 and 2.")
		return
	end
	scale = math.max(0.5, math.min(2, scale))
	OA.db.display.scale = scale
	if OA.Display and OA.Display.anchor then
		OA.Display.anchor:SetScale(scale)
	end
	OA.print("Scale set to " .. tostring(scale))
end

local function HandleToggle(arg)
	if not arg or arg == "" then
		OA.print("Usage: /oa toggle <queue|ooc>")
		return
	end
	local toggle = string.lower(arg)
	if OA.db.show[toggle] == nil then
		OA.print("Unknown toggle: " .. toggle)
		return
	end
	OA.db.show[toggle] = not OA.db.show[toggle]
	local state = OA.db.show[toggle] and "ON" or "OFF"
	OA.print(toggle .. " toggled " .. state)
end

local function HandleAoe()
	OA.db.aoeMode = not OA.db.aoeMode
	local state = OA.db.aoeMode and "ON" or "OFF"
	OA.print("AoE mode " .. state)
end

local function HandleReset()
	OutlawAssistDB = {}
	for k, v in pairs(OA.defaults) do
		if type(v) == "table" then
			OutlawAssistDB[k] = {}
			for k2, v2 in pairs(v) do
				OutlawAssistDB[k][k2] = v2
			end
		else
			OutlawAssistDB[k] = v
		end
	end
	OA.db = OutlawAssistDB
	OA.print("Config reset to defaults.")
	if OA.Display and OA.Display.anchor then
		OA.Display.anchor:SetPoint(OA.defaults.display.point or "CENTER", OA.defaults.display.x or 0, OA.defaults.display.y or -180)
		OA.Display.anchor:SetScale(OA.defaults.display.scale or 1)
	end
end

local function HandleStatus()
	OA.print("=== OutlawAssist Status ===")
	OA.print("Queue: " .. (OA.db.show.queue and "ON" or "OFF"))
	OA.print("Out-of-combat: " .. (OA.db.show.ooc and "ON" or "OFF"))
	OA.print("Scale: " .. (OA.db.display.scale or 1))
	OA.print("Icon count: " .. (OA.db.display.iconCount or 4))
	OA.print("AoE mode: " .. (OA.db.aoeMode and "ON" or "OFF"))
	OA.print("Highlight: " .. (OA.db.highlight.enabled and "ON" or "OFF"))
	if OA.db.highlight.enabled then
		OA.print("  Combat-only: " .. (OA.db.highlight.combatOnly and "ON" or "OFF"))
	end
end

local function HandleHelp()
	OA.print("=== OutlawAssist Commands ===")
	OA.print("Display & Layout:")
	OA.print("  /oa lock — Lock display (disable dragging)")
	OA.print("  /oa unlock — Unlock display (enable dragging)")
	OA.print("  /oa scale <0.5-2> — Adjust scale")
	OA.print("  /oa icons <1-8> — Set icon count")
	OA.print("  /oa toggle <queue|ooc> — Toggle display visibility")
	OA.print("  /oa reset — Reset to defaults and reposition display")
	OA.print("Features:")
	OA.print("  /oa aoe — Toggle AoE mode")
	OA.print("  /oa glow — Toggle action bar highlight")
	OA.print("  /oa glow combat — Toggle combat-only mode")
	OA.print("Diagnostics:")
	OA.print("  /oa status — Print current settings")
	OA.print("  /oa apitest — Verify API compatibility")
	OA.print("  /oa debug — Print state dump")
end

local function HandleIcons(arg)
	if not arg or arg == "" then
		OA.print("Usage: /oa icons <1-8>")
		return
	end
	local count = tonumber(arg)
	if not count then
		OA.print("Invalid icon count. Use a number between 1 and 8.")
		return
	end
	count = math.max(1, math.min(8, count))
	OA.db.display.iconCount = count
	if OA.Display and OA.Display.anchor then
		-- Re-layout: update anchor size and re-render
		local stripWidth = 48 + math.max(0, (count - 1)) * 44
		OA.Display.anchor:SetSize(stripWidth + 10, 60)
		-- Trigger a re-render on next tick
		if OA.Engine and OA.Engine.Evaluate then
			local result = OA.Engine.Evaluate()
			if OA.Display and OA.Display.Render then
				OA.Display.Render(result)
			end
		end
	end
	OA.print("Icon count set to " .. count)
end

-- Module debug aggregator (called after ApiTest debug)
local function HandleDebugModules()
	if OA.Highlight and OA.Highlight.AppendDebugOutput then
		OA.Highlight.AppendDebugOutput()
	end
end

-- Register module debug hook; will be called from ApiTest or independently
OA.HandleDebugModules = HandleDebugModules

OA.RegisterSlash("lock", HandleLock, "Lock the display (disable dragging).")
OA.RegisterSlash("unlock", HandleUnlock, "Unlock the display (enable dragging).")
OA.RegisterSlash("scale", HandleScale, "Set display scale (0.5-2).")
OA.RegisterSlash("icons", HandleIcons, "Set icon count (1-8).")
OA.RegisterSlash("toggle", HandleToggle, "Toggle a feature: queue|ooc.")
OA.RegisterSlash("aoe", HandleAoe, "Toggle AoE mode.")
OA.RegisterSlash("reset", HandleReset, "Reset config to defaults.")
OA.RegisterSlash("status", HandleStatus, "Print current status.")
OA.RegisterSlash("help", HandleHelp, "List all commands.")
