local ADDON_NAME, Tuono = ...

Tuono.defaults = {
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
	Tuono.db.display.locked = true
	Tuono.print("Display locked.")
	if Tuono.Display and Tuono.Display.anchor then
		Tuono.Display.anchor:SetMovable(false)
	end
end

local function HandleUnlock()
	Tuono.db.display.locked = false
	Tuono.print("Display unlocked. Drag to move.")
	if Tuono.Display and Tuono.Display.anchor then
		Tuono.Display.anchor:SetMovable(true)
	end
end

local function HandleScale(arg)
	if not arg or arg == "" then
		Tuono.print("Usage: /tuono scale <0.5-2>")
		return
	end
	local scale = tonumber(arg)
	if not scale then
		Tuono.print("Invalid scale. Use a number between 0.5 and 2.")
		return
	end
	scale = math.max(0.5, math.min(2, scale))
	Tuono.db.display.scale = scale
	if Tuono.Display and Tuono.Display.anchor then
		Tuono.Display.anchor:SetScale(scale)
	end
	Tuono.print("Scale set to " .. tostring(scale))
end

local function HandleToggle(arg)
	if not arg or arg == "" then
		Tuono.print("Usage: /tuono toggle <queue|ooc>")
		return
	end
	local toggle = string.lower(arg)
	if Tuono.db.show[toggle] == nil then
		Tuono.print("Unknown toggle: " .. toggle)
		return
	end
	Tuono.db.show[toggle] = not Tuono.db.show[toggle]
	local state = Tuono.db.show[toggle] and "ON" or "OFF"
	Tuono.print(toggle .. " toggled " .. state)
end

local function HandleAoe()
	-- Cycle the tri-state rather than negating it. `not "auto"` is false, which
	-- ResolveMode maps back to "auto" -- so the old toggle flipped between auto and on
	-- and could never reach off.
	local order = { auto = "on", on = "off", off = "auto" }
	local mode = Tuono.db.aoeMode
	if mode == true then mode = "on" elseif mode == false then mode = "auto" end
	Tuono.db.aoeMode = order[mode] or "auto"
	local state = Tuono.db.aoeMode
	Tuono.print("AoE mode " .. state)
end

local function HandleReset()
	TuonoDB = {}
	for k, v in pairs(Tuono.defaults) do
		if type(v) == "table" then
			TuonoDB[k] = {}
			for k2, v2 in pairs(v) do
				TuonoDB[k][k2] = v2
			end
		else
			TuonoDB[k] = v
		end
	end
	Tuono.db = TuonoDB
	Tuono.print("Config reset to defaults.")
	if Tuono.Display and Tuono.Display.anchor then
		Tuono.Display.anchor:SetPoint(Tuono.defaults.display.point or "CENTER", Tuono.defaults.display.x or 0, Tuono.defaults.display.y or -180)
		Tuono.Display.anchor:SetScale(Tuono.defaults.display.scale or 1)
	end
end

local function HandleStatus()
	Tuono.print("=== Tuono Status ===")
	Tuono.print("Queue: " .. (Tuono.db.show.queue and "ON" or "OFF"))
	Tuono.print("Out-of-combat: " .. (Tuono.db.show.ooc and "ON" or "OFF"))
	Tuono.print("Scale: " .. (Tuono.db.display.scale or 1))
	Tuono.print("Icon count: " .. (Tuono.db.display.iconCount or 4))
	-- Print the mode, not a truthiness test: "off" is a truthy string and reported "ON".
	Tuono.print("AoE mode: " .. tostring(Tuono.db.aoeMode))
	Tuono.print("Highlight: " .. (Tuono.db.highlight.enabled and "ON" or "OFF"))
	if Tuono.db.highlight.enabled then
		Tuono.print("  Combat-only: " .. (Tuono.db.highlight.combatOnly and "ON" or "OFF"))
	end
end

local function HandleHelp()
	Tuono.print("=== Tuono Commands ===")
	Tuono.print("Display & Layout:")
	Tuono.print("  /tuono lock — Lock display (disable dragging)")
	Tuono.print("  /tuono unlock — Unlock display (enable dragging)")
	Tuono.print("  /tuono scale <0.5-2> — Adjust scale")
	Tuono.print("  /tuono icons <1-8> — Set icon count")
	Tuono.print("  /tuono toggle <queue|ooc> — Toggle display visibility")
	Tuono.print("  /tuono reset — Reset to defaults and reposition display")
	Tuono.print("Features:")
	Tuono.print("  /tuono aoe — Toggle AoE mode")
	Tuono.print("  /tuono glow — Toggle action bar highlight")
	Tuono.print("  /tuono glow combat — Toggle combat-only mode")
	Tuono.print("Diagnostics:")
	Tuono.print("  /tuono status — Print current settings")
	Tuono.print("  /tuono apitest — Verify API compatibility")
	Tuono.print("  /tuono debug — Print state dump")
end

local function HandleIcons(arg)
	if not arg or arg == "" then
		Tuono.print("Usage: /tuono icons <1-8>")
		return
	end
	local count = tonumber(arg)
	if not count then
		Tuono.print("Invalid icon count. Use a number between 1 and 8.")
		return
	end
	count = math.max(1, math.min(8, count))
	Tuono.db.display.iconCount = count
	if Tuono.Display and Tuono.Display.anchor then
		-- Re-layout: update anchor size and re-render
		local stripWidth = 48 + math.max(0, (count - 1)) * 44
		Tuono.Display.anchor:SetSize(stripWidth + 10, 60)
		-- Trigger a re-render on next tick
		if Tuono.Engine and Tuono.Engine.Evaluate then
			local result = Tuono.Engine.Evaluate()
			if Tuono.Display and Tuono.Display.Render then
				Tuono.Display.Render(result)
			end
		end
	end
	Tuono.print("Icon count set to " .. count)
end

-- Module debug aggregator (called after ApiTest debug)
local function HandleDebugModules()
	if Tuono.Highlight and Tuono.Highlight.AppendDebugOutput then
		Tuono.Highlight.AppendDebugOutput()
	end
end

-- Register module debug hook; will be called from ApiTest or independently
Tuono.HandleDebugModules = HandleDebugModules

Tuono.RegisterSlash("lock", HandleLock, "Lock the display (disable dragging).")
Tuono.RegisterSlash("unlock", HandleUnlock, "Unlock the display (enable dragging).")
Tuono.RegisterSlash("scale", HandleScale, "Set display scale (0.5-2).")
Tuono.RegisterSlash("icons", HandleIcons, "Set icon count (1-8).")
Tuono.RegisterSlash("toggle", HandleToggle, "Toggle a feature: queue|ooc.")
Tuono.RegisterSlash("aoe", HandleAoe, "Toggle AoE mode.")
Tuono.RegisterSlash("reset", HandleReset, "Reset config to defaults.")
Tuono.RegisterSlash("status", HandleStatus, "Print current status.")
Tuono.RegisterSlash("help", HandleHelp, "List all commands.")
