local ADDON_NAME, OA = ...

OA.Display = OA.Display or {}

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
local COOLDOWN_SPELLS = { adrenalineRush = 13750, bladeRush = 271877, preparation = 14185 }
local TRINKET_SLOTS = { 13, 14 }

local function CreateIcon(parent, name, size, x, y)
	local btn = CreateFrame("Button", name, parent)
	btn:SetSize(size, size)
	btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

	local tex = btn:CreateTexture(nil, "BACKGROUND")
	tex:SetAllPoints(btn)
	btn.texture = tex

	local cooldownText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	cooldownText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
	cooldownText:SetTextColor(1, 1, 1, 1)
	cooldownText:Hide()
	btn.cooldownText = cooldownText

	local border = btn:CreateTexture(nil, "BORDER")
	border:SetAllPoints(btn)
	border:Hide()
	btn.border = border

	return btn
end

function OA.Display.Init()
	if OA.Display.anchor then
		return
	end

	local scale = OA.db.display.scale or 1

	local anchor = CreateFrame("Frame", nil, UIParent)
	anchor:SetSize(200, 250)
	anchor:SetPoint(OA.db.display.point or "CENTER", OA.db.display.x or 0, OA.db.display.y or -180)
	anchor:SetScale(scale)
	anchor:SetMovable(not OA.db.display.locked)
	anchor:EnableMouse(true)

	anchor:RegisterForDrag("LeftButton")
	anchor:SetScript("OnDragStart", function(self)
		if not OA.db.display.locked then
			self:StartMoving()
		end
	end)
	anchor:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, relTo, relPoint, x, y = self:GetPoint()
		OA.db.display.point = point or "CENTER"
		OA.db.display.x = x or 0
		OA.db.display.y = y or -180
	end)

	local bg = anchor:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(anchor)
	bg:SetColorTexture(0.1, 0.1, 0.1, 0.3)

	local rotationRow = CreateFrame("Frame", nil, anchor)
	rotationRow:SetSize(200, 48)
	rotationRow:SetPoint("TOPLEFT", anchor, "TOPLEFT", 5, -5)
	anchor.rotationRow = rotationRow

	anchor.rotationIcons = {}
	for i = 1, 5 do
		local size = (i == 1) and 48 or 32
		local x = (i == 1) and 0 or (48 + (i - 2) * 38)
		local y = (i == 1) and 0 or 8
		local icon = CreateIcon(rotationRow, nil, size, x, y)
		table.insert(anchor.rotationIcons, icon)
		icon.index = i
		icon.isSizeLarge = (i == 1)
	end

	local cdRow = CreateFrame("Frame", nil, anchor)
	cdRow:SetSize(200, 40)
	cdRow:SetPoint("TOPLEFT", anchor, "TOPLEFT", 5, -60)
	anchor.cdRow = cdRow

	anchor.cdIcons = {}
	local cdNames = {"adrenalineRush", "bladeRush", "preparation"}
	for i, name in ipairs(cdNames) do
		local icon = CreateIcon(cdRow, nil, 32, (i - 1) * 38, 0)
		icon.spellName = name
		icon.spellID = COOLDOWN_SPELLS[name]
		table.insert(anchor.cdIcons, icon)
	end

	local trinketRow = CreateFrame("Frame", nil, anchor)
	trinketRow:SetSize(100, 40)
	trinketRow:SetPoint("TOPLEFT", anchor, "TOPLEFT", 5, -105)
	anchor.trinketRow = trinketRow

	anchor.trinketIcons = {}
	for i, slot in ipairs(TRINKET_SLOTS) do
		local icon = CreateIcon(trinketRow, nil, 32, (i - 1) * 38, 0)
		icon.slot = slot
		table.insert(anchor.trinketIcons, icon)
	end

	local rtbPanel = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	rtbPanel:SetPoint("TOPLEFT", anchor, "TOPLEFT", 5, -150)
	rtbPanel:SetTextColor(1, 1, 1, 1)
	rtbPanel:SetText("RtB stage 0  00:00s")
	anchor.rtbPanel = rtbPanel

	local advisory = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	advisory:SetPoint("TOPLEFT", anchor, "TOPLEFT", 5, -175)
	advisory:SetTextColor(1, 1, 0.5, 1)
	advisory:SetText("")
	anchor.advisory = advisory

	local aoeIndicator = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	aoeIndicator:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -5, -5)
	aoeIndicator:SetTextColor(1, 0.8, 0, 1)
	aoeIndicator:SetText("")
	anchor.aoeIndicator = aoeIndicator

	OA.Display.anchor = anchor
end

function OA.Display.Render(result)
	if not OA.Display.anchor then
		return
	end

	local anchor = OA.Display.anchor
	local show = OA.db.show or {}
	local inCombat = OA.State and OA.State.inCombat

	local showUI = inCombat or show.ooc
	if not showUI then
		anchor:Hide()
		return
	end

	local classToken = select(2, UnitClass("player"))
	local spec = GetSpecialization and GetSpecialization() or nil
	if classToken ~= "ROGUE" or (spec and spec ~= 2) then
		anchor:Hide()
		return
	end

	anchor:Show()

	if show.queue and result and result.queue then
		for i, rotIcon in ipairs(anchor.rotationIcons) do
			local entry = result.queue[i]
			if entry then
				local tex = GetSpellTexture(entry.spellID) or FALLBACK_TEXTURE
				rotIcon.texture:SetTexture(tex)
				rotIcon:Show()

				if i == 1 then
					if entry.source ~= "blizzard" then
						rotIcon.border:Show()
						rotIcon.border:SetColorTexture(1, 0.5, 0, 0.4)
					else
						rotIcon.border:Hide()
					end
				end
			else
				rotIcon:Hide()
			end
		end
	else
		for _, rotIcon in ipairs(anchor.rotationIcons) do
			rotIcon:Hide()
		end
	end

	if show.cds and OA.State and OA.State.cooldowns then
		for _, cdIcon in ipairs(anchor.cdIcons) do
			local cd = OA.State.cooldowns[cdIcon.spellName]
			if cd then
				local tex = GetSpellTexture(cdIcon.spellID) or FALLBACK_TEXTURE
				cdIcon.texture:SetTexture(tex)
				cdIcon:Show()

				local remaining = OA.num(cd.remaining, 0)
				if remaining and remaining > 0 then
					cdIcon.cooldownText:SetText(string.format("%.0f", remaining))
					cdIcon.cooldownText:Show()
				else
					cdIcon.cooldownText:Hide()
				end
			else
				cdIcon:Hide()
			end
		end
	else
		for _, cdIcon in ipairs(anchor.cdIcons) do
			cdIcon:Hide()
		end
	end

	if show.trinkets and OA.State and OA.State.trinkets then
		for _, trinIcon in ipairs(anchor.trinketIcons) do
			local slot = trinIcon.slot
			local tri = OA.State.trinkets[slot]
			if tri and tri.itemID then
				local tex = GetInventoryItemTexture("player", slot) or FALLBACK_TEXTURE
				trinIcon.texture:SetTexture(tex)
				trinIcon:Show()

				local remaining = OA.num(tri.remaining, 0)
				if remaining and remaining > 0 then
					trinIcon.cooldownText:SetText(string.format("%.0f", remaining))
					trinIcon.cooldownText:Show()
				else
					trinIcon.cooldownText:Hide()
				end
			else
				trinIcon:Hide()
			end
		end
	else
		for _, trinIcon in ipairs(anchor.trinketIcons) do
			trinIcon:Hide()
		end
	end

	if show.rtb and OA.State and OA.State.buffs and OA.State.buffs.rtb then
		local rtb = OA.State.buffs.rtb
		local stage = OA.num(rtb.stage, 0)
		local expires = OA.num(rtb.expires, 0)
		local remaining = math.max(0, expires - GetTime())
		local mins = math.floor(remaining / 60)
		local secs = remaining - (mins * 60)
		anchor.rtbPanel:SetFormattedText("RtB stage %d  %d:%02d s", stage, mins, secs)
		anchor.rtbPanel:Show()
	else
		anchor.rtbPanel:Hide()
	end

	if show.procs and result and result.advisories then
		local advisoryText = ""
		for _, adv in ipairs(result.advisories) do
			if adv.active then
				advisoryText = adv.text
				break
			end
		end
		anchor.advisory:SetText(advisoryText)
	else
		anchor.advisory:SetText("")
	end

	-- Render AoE indicator
	if OA.Assist and OA.Assist.aoeDetected then
		anchor.aoeIndicator:SetText("AoE")
	else
		anchor.aoeIndicator:SetText("")
	end
end
