local ADDON_NAME, OA = ...

OA.Assist = {
	available = false,
	nextSpellID = nil,
	queue = {}
}

local warned = false

function OA.Assist.Update()
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
end
