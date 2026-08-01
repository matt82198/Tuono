local ADDON_NAME, OA = ...

OA.defaults = {
	updateInterval = 0.1,
	aoeMode = false,
	show = {
		queue = true,
		cds = true,
		trinkets = true,
		rtb = true,
		procs = true,
		ooc = false
	},
	display = {
		locked = true,
		scale = 1,
		point = "CENTER",
		x = 0,
		y = -180
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
		OA.print("Usage: /oa toggle <queue|cds|trinkets|rtb|procs|ooc>")
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
	OutlawAssistDB = nil
	OA.db = nil
	OA.print("Config reset to defaults.")
	if OA.Display and OA.Display.anchor then
		OA.Display.anchor:SetPoint(OA.defaults.display.point or "CENTER", OA.defaults.display.x or 0, OA.defaults.display.y or -180)
	end
end

local function HandleStatus()
	OA.print("=== OutlawAssist Status ===")
	OA.print("Queue: " .. (OA.db.show.queue and "ON" or "OFF"))
	OA.print("Cooldowns: " .. (OA.db.show.cds and "ON" or "OFF"))
	OA.print("Trinkets: " .. (OA.db.show.trinkets and "ON" or "OFF"))
	OA.print("RtB: " .. (OA.db.show.rtb and "ON" or "OFF"))
	OA.print("Procs: " .. (OA.db.show.procs and "ON" or "OFF"))
	OA.print("Out-of-combat: " .. (OA.db.show.ooc and "ON" or "OFF"))
	OA.print("Scale: " .. (OA.db.display.scale or 1))
	OA.print("AoE mode: " .. (OA.db.aoeMode and "ON" or "OFF"))
end

OA.RegisterSlash("lock", HandleLock, "Lock the display (disable dragging).")
OA.RegisterSlash("unlock", HandleUnlock, "Unlock the display (enable dragging).")
OA.RegisterSlash("scale", HandleScale, "Set display scale (0.5-2).")
OA.RegisterSlash("toggle", HandleToggle, "Toggle a feature: queue|cds|trinkets|rtb|procs|ooc.")
OA.RegisterSlash("aoe", HandleAoe, "Toggle AoE mode.")
OA.RegisterSlash("reset", HandleReset, "Reset config to defaults.")
OA.RegisterSlash("status", HandleStatus, "Print current status.")
