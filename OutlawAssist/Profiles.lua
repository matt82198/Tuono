local ADDON_NAME, OA = ...

-- ============================================================================
-- PROFILE REGISTRY
-- ============================================================================
-- A PROFILE is everything spec-specific: which spells exist, what they cost, and the
-- ordered priority list that decides what to press. The engine (Rotation.lua) knows
-- none of it. Outlaw Rogue is just the first registered profile, not a special case --
-- that separation is the whole point of the framework.
--
-- LOAD-ORDER CONTRACT (this is load-bearing, do not reorder the TOC casually):
--   Profiles.lua        creates the SHARED OA.SpellIDs table
--   profiles/*.lua      register profiles; the first one registered activates
--                       immediately so that load-time readers see populated data
--   StateTracker.lua    reads OA.SpellIDs
--   Rotation.lua        publishes OA.RuleHelpers and consumes the active profile
--
-- OA.SpellIDs is MUTATED IN PLACE on activation, never reassigned. Half this addon
-- captured a reference to it at load; swapping the table would silently strand every
-- one of those references pointing at the old spec's data.
-- ============================================================================

OA.Profiles = OA.Profiles or {}
local P = OA.Profiles

P.registry = P.registry or {}
P.order = P.order or {}
P.active = nil

-- Shared, mutated in place. See the contract note above.
OA.SpellIDs = OA.SpellIDs or {}

-- Callbacks fired after a profile becomes active, so modules can rebuild anything they
-- derived from the old profile (Rotation's spellID->cooldown-key map, for one).
P.activationHooks = P.activationHooks or {}

function P.OnActivate(fn)
	table.insert(P.activationHooks, fn)
end

-- profile = {
--   id, name, class, specIndex,
--   spells    = { key = spellID },
--   abilities = { [spellID] = { cost, cpGen, cpSpend, cd, gcd } },
--   priority  = { { name, spellKey, requiresSpell, when(S, A) }, ... },  -- first match wins
--   resources = { primary = Enum.PowerType.X, secondary = ... },
-- }
function P.Register(profile)
	if type(profile) ~= "table" or not profile.id then
		return false, "profile needs an id"
	end
	if not P.registry[profile.id] then
		table.insert(P.order, profile.id)
	end
	profile.priority = profile.priority or {}
	profile.spells = profile.spells or {}
	profile.abilities = profile.abilities or {}
	P.registry[profile.id] = profile

	-- First profile in wins the default slot so load-time consumers (data/rules.lua
	-- reads OA.SpellIDs while loading) never see an empty table.
	if not P.active then
		P.Activate(profile.id)
	end
	return true
end

function P.Get(id)
	return P.registry[id]
end

function P.Active()
	return P.active and P.registry[P.active] or nil
end

function P.List()
	local out = {}
	for _, id in ipairs(P.order) do
		local prof = P.registry[id]
		if prof then
			table.insert(out, { id = id, name = prof.name or id, class = prof.class })
		end
	end
	return out
end

function P.Activate(id)
	local profile = P.registry[id]
	if not profile then return false end

	P.active = id

	-- Mutate the shared table in place.
	for k in pairs(OA.SpellIDs) do OA.SpellIDs[k] = nil end
	for k, v in pairs(profile.spells) do OA.SpellIDs[k] = v end

	for _, fn in ipairs(P.activationHooks) do
		pcall(fn, profile)
	end
	return true
end

-- Pick the profile matching the player's class and spec. Falls back to whatever is
-- already active rather than blanking the display on an unsupported spec.
function P.ResolveForPlayer()
	local ok, _, classToken = pcall(UnitClass, "player")
	if not ok then return end
	local specIndex = _G.GetSpecialization and _G.GetSpecialization() or nil

	for _, id in ipairs(P.order) do
		local prof = P.registry[id]
		if prof and prof.class == classToken then
			if prof.specIndex == nil or prof.specIndex == specIndex then
				P.Activate(id)
				return id
			end
		end
	end
	return nil
end

-- Does the active profile match who the player actually is? Display uses this instead
-- of its own hardcoded ROGUE/spec-2 check, so a second profile does not need the UI
-- edited to become visible.
function P.MatchesPlayer()
	local prof = P.Active()
	if not prof then return false end
	local ok, _, classToken = pcall(UnitClass, "player")
	if not ok then return false end
	if prof.class and prof.class ~= classToken then return false end
	if prof.specIndex then
		local specIndex = _G.GetSpecialization and _G.GetSpecialization() or nil
		if specIndex and specIndex ~= prof.specIndex then return false end
	end
	return true
end

OA.RegisterEvent("PLAYER_LOGIN", function()
	-- A saved manual choice beats auto-detection; the player may be theorycrafting a
	-- spec they are not currently in.
	local saved = OA.db and OA.db.activeProfile
	if saved and P.registry[saved] then
		P.Activate(saved)
	else
		P.ResolveForPlayer()
	end
end)

OA.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function(event, unit)
	if unit and unit ~= "player" then return end
	if OA.db and OA.db.activeProfile then return end
	P.ResolveForPlayer()
end)
