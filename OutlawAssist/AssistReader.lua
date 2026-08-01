local ADDON_NAME, OA = ...

OA.Assist = {
	available = false,
	nextSpellID = nil,
	queue = {},
	rotationSet = {},
	aoeDetected = false,
	deviated = false,
	lastChangeAt = 0
}

local warned = false

function OA.Assist.Update()
	-- Clear deviation flag at start of update; it will be re-set by event handler if player casts ~= recommendation
	OA.Assist.deviated = false

	if not C_AssistedCombat then
		if not warned then
			OA.safe(function()
				OA.print("C_AssistedCombat API not available")
			end)
			warned = true
		end
		OA.Assist.available = false
		OA.Assist.nextSpellID = nil
		wipe(OA.Assist.queue)
		wipe(OA.Assist.rotationSet)
		return
	end

	local isAvailable = true
	if C_AssistedCombat.IsAvailable then
		isAvailable = C_AssistedCombat.IsAvailable()
	end

	if not isAvailable then
		OA.Assist.available = false
		OA.Assist.nextSpellID = nil
		wipe(OA.Assist.queue)
		wipe(OA.Assist.rotationSet)
		return
	end

	OA.Assist.available = true

	local nextSpell = OA.safe(function()
		return C_AssistedCombat.GetNextCastSpell(false)
	end)
	local prevNextSpellID = OA.Assist.nextSpellID
	OA.Assist.nextSpellID = nextSpell or nil

	-- Track when position 1 changes (diagnostic: lastChangeAt timestamp)
	if OA.Assist.nextSpellID ~= prevNextSpellID then
		OA.Assist.lastChangeAt = GetTime()
	end

	-- Get rotation spells and build CAPABILITY SET (not a sequence)
	local rotationSpells = OA.safe(function()
		return C_AssistedCombat.GetRotationSpells()
	end) or {}

	-- Clear rotation set and rebuild it for membership tests only
	wipe(OA.Assist.rotationSet)
	for _, entry in ipairs(rotationSpells) do
		local spellID = nil

		if type(entry) == "number" then
			spellID = entry
		elseif type(entry) == "table" and entry.spellID then
			spellID = entry.spellID
		end

		if spellID then
			OA.Assist.rotationSet[spellID] = true
		end
	end

	-- POSITION 1: always live GetNextCastSpell, no padding with static rotation
	-- Queue is built dynamically by IntelligenceLayer from rules only
	wipe(OA.Assist.queue)
	if OA.Assist.nextSpellID then
		table.insert(OA.Assist.queue, OA.Assist.nextSpellID)
	end

	-- Detect AoE: check if Blade Flurry appears in the capability set (rotationSet)
	OA.Assist.aoeDetected = false
	if OA.SpellIDs and OA.SpellIDs.bladeFlurry then
		OA.Assist.aoeDetected = OA.Assist.rotationSet[OA.SpellIDs.bladeFlurry] or false
	end
end

-- Deviation detection: flag when player casts a spell that doesn't match recommendation
-- This handler runs immediately on spell cast (forced by event), then Update() clears the flag on next tick
OA.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(event, unit, castGUID, spellID, ...)
	if unit == "player" and spellID ~= OA.Assist.nextSpellID then
		OA.Assist.deviated = true
		-- Request immediate update to refresh recommendation after deviation
		OA.RequestImmediateUpdate()
	end
end)
