local ADDON_NAME, OA = ...

OA.Assist = {
	available = false,
	nextSpellID = nil,
	queue = {},
	aoeDetected = false,
	deviated = false
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
		return
	end

	OA.Assist.available = true

	local nextSpell = OA.safe(function()
		return C_AssistedCombat.GetNextCastSpell(false)
	end)
	OA.Assist.nextSpellID = nextSpell or nil

	local rotationSpells = OA.safe(function()
		return C_AssistedCombat.GetRotationSpells()
	end) or {}

	wipe(OA.Assist.queue)

	if OA.Assist.nextSpellID then
		table.insert(OA.Assist.queue, OA.Assist.nextSpellID)
	end

	local seen = {}
	if OA.Assist.nextSpellID then
		seen[OA.Assist.nextSpellID] = true
	end

	for _, entry in ipairs(rotationSpells) do
		local spellID = nil

		if type(entry) == "number" then
			spellID = entry
		elseif type(entry) == "table" and entry.spellID then
			spellID = entry.spellID
		end

		if spellID and not seen[spellID] then
			table.insert(OA.Assist.queue, spellID)
			seen[spellID] = true
		end
	end

	-- Detect AoE: check if Blade Flurry appears in the normalized queue
	-- Blizzard's engine recommends AoE when 2+ targets are present
	OA.Assist.aoeDetected = false
	if OA.SpellIDs and OA.SpellIDs.bladeFlurry then
		for _, spellID in ipairs(OA.Assist.queue) do
			if spellID == OA.SpellIDs.bladeFlurry then
				OA.Assist.aoeDetected = true
				break
			end
		end
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
