local ADDON_NAME, Tuono = ...

Tuono.Assist = {
	available = false,
	nextSpellID = nil,
	queue = {},
	rotationSet = {},
	aoeDetected = false,
	deviated = false,
	lastChangeAt = 0
}

local warned = false

function Tuono.Assist.Update()
	-- Clear deviation flag at start of update; it will be re-set by event handler if player casts ~= recommendation
	Tuono.Assist.deviated = false

	if not C_AssistedCombat then
		if not warned then
			Tuono.safe(function()
				Tuono.print("C_AssistedCombat API not available")
			end)
			warned = true
		end
		Tuono.Assist.available = false
		Tuono.Assist.nextSpellID = nil
		wipe(Tuono.Assist.queue)
		wipe(Tuono.Assist.rotationSet)
		return
	end

	-- ROOT CAUSE OF THE FROZEN FIRST ICON.
	-- IsAvailable() returns (isAvailable, failureReason). In instanced combat the boolean
	-- can come back SECRET, and `if not isAvailable then` on a secret boolean THROWS.
	-- The throw propagated out of Assist.Update (Core wraps the whole call in Tuono.safe), so
	-- every in-combat tick aborted RIGHT HERE -- before nextSpellID was ever reassigned.
	-- Tuono.Assist.nextSpellID therefore stayed pinned to whatever it held at combat entry.
	-- That is the "Blizzard's GetNextCastSpell is STATIC in combat, 52 samples" note in
	-- IntelligenceLayer: not the API being static, this addon crashing before it read it.
	--
	-- An unreadable availability flag must mean "keep polling", never "switch off": the
	-- content where it goes secret is exactly the content where the fallback matters.
	local available = true
	if C_AssistedCombat.IsAvailable then
		local ok, res = pcall(C_AssistedCombat.IsAvailable)
		if ok then
			local b, known = Tuono.readBool(res)
			Tuono.Assist.availabilityKnown = known
			if known then available = b end
		else
			Tuono.Assist.availabilityKnown = false
		end
	else
		Tuono.Assist.availabilityKnown = false
	end

	if not available then
		Tuono.Assist.available = false
		Tuono.Assist.nextSpellID = nil
		wipe(Tuono.Assist.queue)
		wipe(Tuono.Assist.rotationSet)
		return
	end

	Tuono.Assist.available = true

	-- GetNextCastSpell is documented NOT to return a secret (no SecretReturns flag in
	-- AssistedCombatDocumentation.lua), but a nil/secret here must degrade to "no pick"
	-- rather than poison every downstream comparison.
	local prevNextSpellID = Tuono.Assist.nextSpellID
	local okNext, rawNext = pcall(C_AssistedCombat.GetNextCastSpell, false)
	if okNext then
		local id, known = Tuono.readNum(rawNext)
		Tuono.Assist.nextSpellID = (known and id and id > 0) and id or nil
		Tuono.Assist.pickSecret = (rawNext ~= nil) and not known or false
	else
		Tuono.Assist.nextSpellID = nil
		Tuono.Assist.pickSecret = false
	end

	-- Track when position 1 changes (diagnostic: lastChangeAt timestamp)
	if Tuono.Assist.nextSpellID ~= prevNextSpellID then
		Tuono.Assist.lastChangeAt = GetTime()
	end

	-- Get rotation spells and build CAPABILITY SET (not a sequence)
	local rotationSpells = Tuono.safe(function()
		return C_AssistedCombat.GetRotationSpells()
	end) or {}

	-- Clear rotation set and rebuild it for membership tests only
	wipe(Tuono.Assist.rotationSet)
	for _, entry in ipairs(rotationSpells) do
		local spellID = nil

		if type(entry) == "number" then
			spellID = entry
		elseif type(entry) == "table" and entry.spellID then
			spellID = entry.spellID
		end

		if spellID then
			Tuono.Assist.rotationSet[spellID] = true
		end
	end

	-- POSITION 1: always live GetNextCastSpell, no padding with static rotation
	-- Queue is built dynamically by IntelligenceLayer from rules only
	wipe(Tuono.Assist.queue)
	if Tuono.Assist.nextSpellID then
		table.insert(Tuono.Assist.queue, Tuono.Assist.nextSpellID)
	end

	-- Detect AoE: check if Blade Flurry appears in the capability set (rotationSet)
	Tuono.Assist.aoeDetected = false
	if Tuono.SpellIDs and Tuono.SpellIDs.bladeFlurry then
		Tuono.Assist.aoeDetected = Tuono.Assist.rotationSet[Tuono.SpellIDs.bladeFlurry] or false
	end
end

-- Deviation detection: flag when player casts a spell that doesn't match recommendation
-- This handler runs immediately on spell cast (forced by event), then Update() clears the flag on next tick
Tuono.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(event, unit, castGUID, spellID, ...)
	if unit == "player" and spellID ~= Tuono.Assist.nextSpellID then
		Tuono.Assist.deviated = true
		-- Request immediate update to refresh recommendation after deviation
		Tuono.RequestImmediateUpdate()
	end
end)
