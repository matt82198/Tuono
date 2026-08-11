local ADDON_NAME, Tuono = ...

-- ============================================================================
-- IN-GAME CONFIGURATION UI  --  /tuono config
-- ============================================================================
-- Two jobs:
--   1. Pick which PROFILE (rotation) feeds the wheel.
--   2. Edit that profile's priority list -- ordered rows, first match wins.
--
-- Deliberately built from plain Buttons and FontStrings rather than
-- UIDropDownMenu/Blizzard templates: those have churned across expansions and a
-- template rename would take the whole options panel down with it. Cyclers
-- ("< value >") are uglier than dropdowns and cannot break the same way.
--
-- Row frames are POOLED and reused. Rebuilding frames on every refresh leaks them
-- (frames cannot be destroyed in WoW) and would bloat memory every time the list
-- redraws.
-- ============================================================================

Tuono.Options = Tuono.Options or {}
local O = Tuono.Options

local ROW_HEIGHT = 24
local VISIBLE_ROWS = 12
local PANEL_W, PANEL_H = 660, 520

local currentKind = "single"     -- which of the profile's two lists is being edited
local selectedIndex = nil        -- row open in the detail editor
local rowPool = {}

local function spellName(spellID)
	if not spellID then return "?" end
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, spellID)
		if ok and type(n) == "string" then return n end
	end
	if _G.GetSpellInfo then
		local ok, n = pcall(_G.GetSpellInfo, spellID)
		if ok and type(n) == "string" then return n end
	end
	return "spell " .. tostring(spellID)
end

local function spellTexture(spellID)
	if not spellID then return nil end
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, t = pcall(C_Spell.GetSpellTexture, spellID)
		if ok then return t end
	end
	return nil
end

-- Ordered list of spell keys in the active profile, for the ability cycler.
local function profileSpellKeys(profile)
	local keys = {}
	for k in pairs(profile.spells or {}) do table.insert(keys, k) end
	table.sort(keys)
	return keys
end

local function cycle(list, current, delta)
	if #list == 0 then return current end
	local idx = 1
	for i, v in ipairs(list) do if v == current then idx = i break end end
	idx = idx + delta
	if idx < 1 then idx = #list end
	if idx > #list then idx = 1 end
	return list[idx]
end

-- ---------------------------------------------------------------------------
-- Small widget helpers
-- ---------------------------------------------------------------------------
local function mkButton(parent, text, w, h, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	if not b.SetText then return nil end
	b:SetSize(w, h)
	b:SetText(text)
	b:SetScript("OnClick", function() Tuono.safe(onClick) end)
	return b
end

-- Fallback when UIPanelButtonTemplate is unavailable on a given build.
local function mkPlainButton(parent, text, w, h, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(b)
	bg:SetColorTexture(0.2, 0.2, 0.25, 0.9)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("CENTER")
	fs:SetText(text)
	b.text = fs
	b:SetScript("OnEnter", function() bg:SetColorTexture(0.32, 0.32, 0.4, 0.95) end)
	b:SetScript("OnLeave", function() bg:SetColorTexture(0.2, 0.2, 0.25, 0.9) end)
	b:SetScript("OnClick", function() Tuono.safe(onClick) end)
	return b
end

local function button(parent, text, w, h, onClick)
	local ok, b = pcall(mkButton, parent, text, w, h, onClick)
	if ok and b then return b end
	return mkPlainButton(parent, text, w, h, onClick)
end

local function label(parent, text, size, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetText(text or "")
	if r then fs:SetTextColor(r, g, b) end
	return fs
end

-- ---------------------------------------------------------------------------
-- Detail editor: conditions for one row
-- ---------------------------------------------------------------------------
local function BuildDetail(panel)
	local d = CreateFrame("Frame", nil, panel)
	d:SetSize(PANEL_W - 24, 150)
	d:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 44)
	local bg = d:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(d)
	bg:SetColorTexture(0.08, 0.08, 0.1, 0.85)

	d.title = label(d, "No rule selected", 12, 1, 0.82, 0)
	d.title:SetPoint("TOPLEFT", d, "TOPLEFT", 8, -6)

	d.abilityLabel = label(d, "Ability:")
	d.abilityLabel:SetPoint("TOPLEFT", d, "TOPLEFT", 8, -26)

	d.abilityPrev = button(d, "<", 20, 18, function()
		local row = O.SelectedRow(); if not row then return end
		local keys = profileSpellKeys(Tuono.Profiles.Active())
		row.spellKey = cycle(keys, row.spellKey, -1)
		O.Refresh()
	end)
	d.abilityPrev:SetPoint("LEFT", d.abilityLabel, "RIGHT", 6, 0)

	d.abilityText = label(d, "-", 12, 1, 1, 1)
	d.abilityText:SetPoint("LEFT", d.abilityPrev, "RIGHT", 6, 0)
	d.abilityText:SetWidth(170)
	d.abilityText:SetJustifyH("LEFT")

	d.abilityNext = button(d, ">", 20, 18, function()
		local row = O.SelectedRow(); if not row then return end
		local keys = profileSpellKeys(Tuono.Profiles.Active())
		row.spellKey = cycle(keys, row.spellKey, 1)
		O.Refresh()
	end)
	d.abilityNext:SetPoint("LEFT", d.abilityText, "RIGHT", 6, 0)

	d.condHeader = label(d, "Conditions (ALL must be true):", 11, 0.7, 0.85, 1)
	d.condHeader:SetPoint("TOPLEFT", d, "TOPLEFT", 8, -50)

	-- Three condition slots is enough for every rule in the built-in profiles and keeps
	-- the panel readable; more than that belongs in a separate rule.
	d.condRows = {}
	for i = 1, 3 do
		local c = CreateFrame("Frame", nil, d)
		c:SetSize(PANEL_W - 48, 20)
		c:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -66 - (i - 1) * 22)

		c.typePrev = button(c, "<", 18, 16, function() O.CycleCondition(i, "type", -1) end)
		c.typePrev:SetPoint("LEFT", c, "LEFT", 0, 0)
		c.typeText = label(c, "-", 11, 1, 1, 1)
		c.typeText:SetPoint("LEFT", c.typePrev, "RIGHT", 4, 0)
		c.typeText:SetWidth(150); c.typeText:SetJustifyH("LEFT")
		c.typeNext = button(c, ">", 18, 16, function() O.CycleCondition(i, "type", 1) end)
		c.typeNext:SetPoint("LEFT", c.typeText, "RIGHT", 4, 0)

		c.opPrev = button(c, "<", 18, 16, function() O.CycleCondition(i, "op", -1) end)
		c.opPrev:SetPoint("LEFT", c.typeNext, "RIGHT", 10, 0)
		c.opText = label(c, "-", 11, 1, 1, 1)
		c.opText:SetPoint("LEFT", c.opPrev, "RIGHT", 4, 0)
		c.opText:SetWidth(28); c.opText:SetJustifyH("CENTER")
		c.opNext = button(c, ">", 18, 16, function() O.CycleCondition(i, "op", 1) end)
		c.opNext:SetPoint("LEFT", c.opText, "RIGHT", 4, 0)

		c.valMinus = button(c, "-", 18, 16, function() O.AdjustValue(i, -1) end)
		c.valMinus:SetPoint("LEFT", c.opNext, "RIGHT", 10, 0)
		c.valText = label(c, "-", 11, 1, 1, 1)
		c.valText:SetPoint("LEFT", c.valMinus, "RIGHT", 4, 0)
		c.valText:SetWidth(28); c.valText:SetJustifyH("CENTER")
		c.valPlus = button(c, "+", 18, 16, function() O.AdjustValue(i, 1) end)
		c.valPlus:SetPoint("LEFT", c.valText, "RIGHT", 4, 0)

		-- Warns when a condition depends on a value Midnight hides, so nobody builds a
		-- rule that silently never fires in a keystone.
		c.warn = label(c, "", 11, 1, 0.5, 0.3)
		c.warn:SetPoint("LEFT", c.valPlus, "RIGHT", 10, 0)

		d.condRows[i] = c
	end

	panel.detail = d
	return d
end

-- ---------------------------------------------------------------------------
-- Public helpers used by the widget callbacks
-- ---------------------------------------------------------------------------
function O.Rows()
	local profile = Tuono.Profiles.Active()
	if not profile then return {} end
	return Tuono.UserRules.GetRows(profile, currentKind)
end

function O.SelectedRow()
	if not selectedIndex then return nil end
	return O.Rows()[selectedIndex]
end

function O.CycleCondition(slot, field, delta)
	local row = O.SelectedRow(); if not row then return end
	row.conditions = row.conditions or {}
	local cond = row.conditions[slot]
	if not cond then
		if field ~= "type" then return end
		cond = { type = "always" }
		row.conditions[slot] = cond
	end

	if field == "type" then
		local ids = {}
		for _, t in ipairs(Tuono.UserRules.CONDITION_TYPES) do table.insert(ids, t.id) end
		cond.type = cycle(ids, cond.type, delta)
		local t = Tuono.UserRules.GetConditionType(cond.type)
		if t and t.needsOp and not cond.op then cond.op = ">=" end
		if t and t.needsValue and not cond.value then cond.value = 1 end
	elseif field == "op" then
		cond.op = cycle(Tuono.UserRules.OPERATORS, cond.op or ">=", delta)
	end
	O.Refresh()
end

function O.AdjustValue(slot, delta)
	local row = O.SelectedRow(); if not row then return end
	local cond = row.conditions and row.conditions[slot]
	if not cond then return end
	cond.value = math.max(0, (cond.value or 0) + delta)
	O.Refresh()
end

-- ---------------------------------------------------------------------------
-- Panel construction
-- ---------------------------------------------------------------------------
function O.Build()
	if O.panel then return O.panel end

	local p = CreateFrame("Frame", "OutlawAssistOptions", UIParent)
	p:SetSize(PANEL_W, PANEL_H)
	p:SetPoint("CENTER")
	p:SetMovable(true)
	p:EnableMouse(true)
	p:RegisterForDrag("LeftButton")
	p:SetScript("OnDragStart", function(self) self:StartMoving() end)
	p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	p:Hide()

	local bg = p:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(p)
	bg:SetColorTexture(0.05, 0.05, 0.07, 0.96)

	local title = label(p, "Tuono - Rotation Configuration", 14, 1, 0.82, 0)
	title:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -10)

	local close = button(p, "X", 24, 20, function() p:Hide() end)
	close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)

	-- Profile cycler: this is "select which rotation you want to see on the wheel".
	local profLabel = label(p, "Profile:", 12, 0.7, 0.85, 1)
	profLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -38)

	p.profPrev = button(p, "<", 22, 18, function() O.CycleProfile(-1) end)
	p.profPrev:SetPoint("LEFT", profLabel, "RIGHT", 6, 0)
	p.profText = label(p, "-", 12, 1, 1, 1)
	p.profText:SetPoint("LEFT", p.profPrev, "RIGHT", 8, 0)
	p.profText:SetWidth(220); p.profText:SetJustifyH("LEFT")
	p.profNext = button(p, ">", 22, 18, function() O.CycleProfile(1) end)
	p.profNext:SetPoint("LEFT", p.profText, "RIGHT", 8, 0)

	-- AoE behaviour lives here too, since it decides which list the wheel shows.
	p.aoeBtn = button(p, "AoE: auto", 110, 18, function()
		local order = { "auto", "on", "off" }
		Tuono.db.aoeMode = cycle(order, Tuono.db.aoeMode or "auto", 1)
		O.Refresh()
	end)
	p.aoeBtn:SetPoint("LEFT", p.profNext, "RIGHT", 20, 0)

	-- Which of the two rotations is being edited.
	p.tabSingle = button(p, "Single Target", 110, 20, function()
		currentKind = "single"; selectedIndex = nil; O.Refresh()
	end)
	p.tabSingle:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -66)
	p.tabAoE = button(p, "AoE", 110, 20, function()
		currentKind = "aoe"; selectedIndex = nil; O.Refresh()
	end)
	p.tabAoE:SetPoint("LEFT", p.tabSingle, "RIGHT", 6, 0)

	p.hint = label(p, "First rule whose conditions all pass wins. Drag order = priority.",
		11, 0.6, 0.6, 0.65)
	p.hint:SetPoint("LEFT", p.tabAoE, "RIGHT", 16, 0)

	-- Row list
	p.list = CreateFrame("Frame", nil, p)
	p.list:SetSize(PANEL_W - 24, VISIBLE_ROWS * ROW_HEIGHT)
	p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -94)

	for i = 1, VISIBLE_ROWS do
		local r = CreateFrame("Button", nil, p.list)
		r:SetSize(PANEL_W - 24, ROW_HEIGHT - 2)
		r:SetPoint("TOPLEFT", p.list, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

		r.bg = r:CreateTexture(nil, "BACKGROUND")
		r.bg:SetAllPoints(r)
		r.bg:SetColorTexture(0.12, 0.12, 0.15, 0.7)

		r.toggle = button(r, "on", 30, 16, function()
			local row = O.Rows()[r.dataIndex]
			if row then row.enabled = not (row.enabled ~= false); O.Refresh() end
		end)
		r.toggle:SetPoint("LEFT", r, "LEFT", 2, 0)

		r.num = label(r, "", 11, 0.6, 0.6, 0.7)
		r.num:SetPoint("LEFT", r.toggle, "RIGHT", 6, 0)
		r.num:SetWidth(20)

		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(16, 16)
		r.icon:SetPoint("LEFT", r.num, "RIGHT", 2, 0)

		r.text = label(r, "", 11, 1, 1, 1)
		r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
		r.text:SetWidth(380); r.text:SetJustifyH("LEFT")

		r.up = button(r, "^", 20, 16, function()
			Tuono.UserRules.MoveRow(Tuono.Profiles.Active().id, currentKind, r.dataIndex, -1)
			if selectedIndex == r.dataIndex then selectedIndex = r.dataIndex - 1 end
			O.Refresh()
		end)
		r.up:SetPoint("RIGHT", r, "RIGHT", -70, 0)

		r.down = button(r, "v", 20, 16, function()
			Tuono.UserRules.MoveRow(Tuono.Profiles.Active().id, currentKind, r.dataIndex, 1)
			if selectedIndex == r.dataIndex then selectedIndex = r.dataIndex + 1 end
			O.Refresh()
		end)
		r.down:SetPoint("RIGHT", r, "RIGHT", -46, 0)

		r.del = button(r, "X", 20, 16, function()
			Tuono.UserRules.DeleteRow(Tuono.Profiles.Active().id, currentKind, r.dataIndex)
			selectedIndex = nil
			O.Refresh()
		end)
		r.del:SetPoint("RIGHT", r, "RIGHT", -22, 0)

		r:SetScript("OnClick", function()
			selectedIndex = r.dataIndex
			O.Refresh()
		end)

		rowPool[i] = r
	end

	p.scrollNote = label(p, "", 11, 0.6, 0.6, 0.65)
	p.scrollNote:SetPoint("TOPLEFT", p.list, "BOTTOMLEFT", 2, -4)

	BuildDetail(p)

	p.addBtn = button(p, "Add Rule", 90, 22, function()
		local profile = Tuono.Profiles.Active()
		local keys = profileSpellKeys(profile)
		Tuono.UserRules.AddRow(profile.id, currentKind, keys[1])
		selectedIndex = #O.Rows()
		O.Refresh()
	end)
	p.addBtn:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 12, 12)

	p.resetBtn = button(p, "Reset to Default", 130, 22, function()
		Tuono.UserRules.ResetToDefault(Tuono.Profiles.Active().id, currentKind)
		selectedIndex = nil
		O.Refresh()
	end)
	p.resetBtn:SetPoint("LEFT", p.addBtn, "RIGHT", 8, 0)

	p.closeBtn = button(p, "Close", 80, 22, function() p:Hide() end)
	p.closeBtn:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -12, 12)

	O.panel = p
	return p
end

function O.CycleProfile(delta)
	local list = Tuono.Profiles.List()
	if #list <= 1 then return end
	local ids = {}
	for _, e in ipairs(list) do table.insert(ids, e.id) end
	local nextID = cycle(ids, Tuono.Profiles.active, delta)
	Tuono.Profiles.Activate(nextID)
	-- An explicit pick must survive spec changes and relogs, so record it.
	Tuono.db.activeProfile = nextID
	selectedIndex = nil
	O.Refresh()
end

function O.Refresh()
	local p = O.panel
	if not p then return end
	local profile = Tuono.Profiles.Active()
	if not profile then return end

	p.profText:SetText(profile.name or profile.id)
	p.aoeBtn.text = p.aoeBtn.text or nil
	local aoeLabel = "AoE: " .. tostring(Tuono.db.aoeMode or "auto")
	if p.aoeBtn.SetText then pcall(p.aoeBtn.SetText, p.aoeBtn, aoeLabel)
	elseif p.aoeBtn.text then p.aoeBtn.text:SetText(aoeLabel) end

	-- Highlight the active tab.
	local function tint(btn, on)
		if btn and btn.text then
			btn.text:SetTextColor(on and 1 or 0.6, on and 0.82 or 0.6, on and 0 or 0.65)
		end
	end
	tint(p.tabSingle, currentKind == "single")
	tint(p.tabAoE, currentKind == "aoe")

	local rows = O.Rows()
	local customised = Tuono.UserRules.IsCustomised(profile.id, currentKind)
	p.hint:SetText(customised and "|cffffcc00customised|r - first match wins"
		or "profile default - first match wins")

	for i, r in ipairs(rowPool) do
		local data = rows[i]
		r.dataIndex = i
		if data then
			local spellID = profile.spells[data.spellKey]
			r.icon:SetTexture(spellTexture(spellID))
			local enabled = data.enabled ~= false
			local nameText = (data.name or spellName(spellID))
			r.text:SetText(nameText .. "  |cff888888" .. Tuono.UserRules.DescribeRow(data) .. "|r")
			r.text:SetTextColor(enabled and 1 or 0.45, enabled and 1 or 0.45, enabled and 1 or 0.45)
			r.num:SetText(tostring(i) .. ".")
			if r.toggle.SetText then pcall(r.toggle.SetText, r.toggle, enabled and "on" or "off")
			elseif r.toggle.text then r.toggle.text:SetText(enabled and "on" or "off") end
			r.bg:SetColorTexture(
				(selectedIndex == i) and 0.25 or 0.12,
				(selectedIndex == i) and 0.22 or 0.12,
				(selectedIndex == i) and 0.10 or 0.15, 0.8)
			r:Show()
		else
			r:Hide()
		end
	end

	if #rows > VISIBLE_ROWS then
		p.scrollNote:SetText("Showing " .. VISIBLE_ROWS .. " of " .. #rows ..
			" rules. Delete or reorder to see the rest.")
	else
		p.scrollNote:SetText("")
	end

	-- Detail editor
	local d = p.detail
	local row = O.SelectedRow()
	if not row then
		d.title:SetText("Click a rule above to edit it")
		d.abilityText:SetText("-")
		for _, c in ipairs(d.condRows) do c:Hide() end
		return
	end

	local spellID = profile.spells[row.spellKey]
	d.title:SetText("Editing rule " .. tostring(selectedIndex) ..
		"  |cff888888(" .. tostring(row.spellKey) .. ")|r")
	d.abilityText:SetText(spellName(spellID))

	for i, c in ipairs(d.condRows) do
		local cond = row.conditions and row.conditions[i]
		c:Show()
		if not cond then
			c.typeText:SetText("|cff666666(add condition)|r")
			c.opText:SetText(""); c.valText:SetText(""); c.warn:SetText("")
		else
			local t = Tuono.UserRules.GetConditionType(cond.type)
			c.typeText:SetText(t and t.label or cond.type)
			c.opText:SetText((t and t.needsOp) and tostring(cond.op or ">=") or "")
			c.valText:SetText((t and t.needsValue) and tostring(cond.value or 0) or "")
			-- The honesty bit: flag conditions built on values Midnight hides.
			c.warn:SetText((t and t.readable == false)
				and "|cffff8844hidden in combat - estimated|r" or "")
		end
	end
end

function O.Toggle()
	local p = O.Build()
	if p:IsShown() then
		p:Hide()
	else
		O.Refresh()
		p:Show()
	end
end

Tuono.RegisterSlash("config", function() Tuono.safe(O.Toggle) end,
	"Open the rotation configuration panel.")
Tuono.RegisterSlash("options", function() Tuono.safe(O.Toggle) end,
	"Open the rotation configuration panel.")
