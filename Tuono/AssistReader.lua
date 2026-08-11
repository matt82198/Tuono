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

-- ============================================================================
-- ROTATION-STEP SENTINELS  --  READ THE SCOPE NOTE BEFORE RELYING ON THIS
-- ============================================================================
-- 1249752 "Waiting for Energy" is NOT a generic "cannot afford the next action"
-- placeholder. Verified against the live DB2 at build 12.1.0.69273:
--
--   AssistedCombatStep rows 13079/13126 -> AssistedCombatID 115
--   AssistedCombat 115 -> ChrSpecializationID 103 = FERAL DRUID
--   Tooltip: "Waiting for energy to deal maximum Ferocious Bite damage." Requires Druid.
--
-- It is a Feral-specific instruction to POOL for a max-damage Ferocious Bite. It is
-- scoped to that spec's rotation table and will never appear for Outlaw, or for any
-- other spec. A sweep of all 331 spellIDs in AssistedCombatStep against SpellName found
-- exactly one such entry -- there is no family of "Waiting for <resource>" sentinels.
--
-- An earlier version of this file claimed the opposite and built energy anchoring on
-- it. That machinery is retained because it is genuinely correct FOR FERAL, but it is
-- now opt-in per profile (profile.waitSentinels) rather than assumed universal, and
-- nothing in the Outlaw path depends on it.
--
-- The FILTER below stays unconditional regardless of spec: whatever a sentinel means,
-- it is a UI placeholder rather than a castable recommendation, and letting one reach
-- the queue or the drift comparison would be wrong in every case.
-- ============================================================================
local WAIT_SENTINEL_IDS = { [1249752] = true }
local WAIT_SENTINEL_ICON = 134377   -- inv_misc_pocketwatch_02

local sentinelIconCache = {}

function Tuono.Assist.IsWaitSentinel(spellID)
	if not spellID then return false end
	if WAIT_SENTINEL_IDS[spellID] then return true end

	-- A profile may declare additional sentinels for its own spec.
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	if profile and profile.waitSentinels and profile.waitSentinels[spellID] then
		return true
	end

	local cached = sentinelIconCache[spellID]
	if cached ~= nil then return cached end

	local isSentinel = false
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
		if ok then
			local icon, known = Tuono.readNum(tex)
			isSentinel = known and icon == WAIT_SENTINEL_ICON or false
		end
	end
	sentinelIconCache[spellID] = isSentinel
	return isSentinel
end

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
		id = (known and id and id > 0) and id or nil

		-- "WAITING FOR ENERGY" IS NOT A RECOMMENDATION.
		-- When the player cannot afford the next action, Blizzard's engine does not
		-- return nil and does not return the unaffordable ability -- it returns a
		-- SENTINEL pseudo-spell (1249752, "Waiting for Energy", icon 134377, flagged
		-- DO_NOT_DISPLAY | DO_NOT_LOG). It is a UI placeholder, not something castable.
		--
		-- This is load-bearing in two directions:
		--   * treating it as a real pick would compare a placeholder against our own
		--     recommendation and score every pooling moment as a disagreement, which
		--     poisons the drift signal precisely when the player is resource-starved
		--   * its PRESENCE is itself information: the engine, which can see the energy
		--     we cannot, is telling us the player is below the next action's cost
		--
		-- Detected by ID and by icon, because the sentinel set may grow: the icon is
		-- locale-invariant and shared by any future "Waiting for <resource>" placeholder.
		Tuono.Assist.waitingForResource = false
		if id and Tuono.Assist.IsWaitSentinel(id) then
			Tuono.Assist.waitingForResource = true
			id = nil
		end

		Tuono.Assist.nextSpellID = id
		Tuono.Assist.pickSecret = (rawNext ~= nil) and not known or false
	else
		Tuono.Assist.nextSpellID = nil
		Tuono.Assist.pickSecret = false
		Tuono.Assist.waitingForResource = false
	end

	-- Track when position 1 changes (diagnostic: lastChangeAt timestamp)
	if Tuono.Assist.nextSpellID ~= prevNextSpellID then
		Tuono.Assist.lastChangeAt = GetTime()
	end

	-- Get rotation spells and build CAPABILITY SET (not a sequence)
	local okRot, rotationSpells = pcall(C_AssistedCombat.GetRotationSpells)
	if not okRot or type(rotationSpells) ~= "table" then rotationSpells = {} end

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
Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, castGUID, spellID, ...)
	if unit == "player" and spellID ~= Tuono.Assist.nextSpellID then
		Tuono.Assist.deviated = true
		-- Request immediate update to refresh recommendation after deviation
		Tuono.RequestImmediateUpdate()
	end
end)
