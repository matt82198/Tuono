local ADDON_NAME, Tuono = ...

-- ============================================================================
-- OBSERVATION CHANNELS FOR STATE WE CANNOT READ DIRECTLY
-- ============================================================================
-- Auras are secret in combat, so the addon has been flying blind on procs -- which for
-- Outlaw means Opportunity and Audacity, i.e. most of what makes the rotation move.
-- Three channels recover it without touching a protected value.
--
-- 1. SPELL ACTIVATION OVERLAY -- the "your button is glowing" system.
--    SpellActivationOverlayDocumentation.lua carries ZERO Secret* flags: not on
--    IsSpellOverlayed, not on SPELL_ACTIVATION_OVERLAY_GLOW_SHOW, not on _HIDE. Both
--    the edge events and the pollable predicate are open, and both carry a plain
--    readable spellID. For any proc that lights up a button this is an EXACT presence
--    signal -- strictly better than an aura read, because it survives combat.
--
-- 2. NEVER-SECRET AURA WHITELIST.
--    SecretWhenUnitAuraRestricted says "individual spells may be flagged as never or
--    always secret, WHICH TAKES PRIORITY OVER RESTRICTIONS". So some auras stay fully
--    readable in combat -- and C_Secrets.GetSpellAuraSecrecy(spellID) tells us which,
--    at runtime. Probe once, then read those auras normally forever. Coverage is
--    unknown until measured on a live client, which is exactly why this probes rather
--    than assumes.
--
-- 3. AURA CARDINALITY.
--    GetUnitAuraInstanceIDs / GetAuraSlots carry no secrecy flag on the RETURNED TABLE
--    (only GetUnitAuras marks its CONTENTS conditional). So the COUNT of buffs and
--    their stable instance IDs are readable even when their meaning is not. That is
--    enough to detect "a buff appeared" / "a buff fell off" and correlate it with a
--    cast we just saw -- identity without semantics.
--
-- None of this reads a secret. Each is a never-secret function of hidden state.
-- ============================================================================

Tuono.Observers = Tuono.Observers or {}
local O = Tuono.Observers

-- spellID -> true while its activation overlay (proc glow) is showing.
O.overlayed = {}
O.overlayEverFired = false

-- ---------------------------------------------------------------------------
-- 1. Activation overlay: exact proc presence
-- ---------------------------------------------------------------------------
local function setOverlay(spellID, on)
	local id = Tuono.readNum(spellID)
	if not id then return end
	O.overlayed[id] = on or nil
	O.overlayEverFired = true

	-- Map the proc onto tracked buff state. The profile declares which spell's overlay
	-- corresponds to which tracked aura, so this stays spec-agnostic.
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	local map = profile and profile.overlayAuras
	local key = map and map[id]
	if not key then return end

	local b = Tuono.State and Tuono.State.buffs and Tuono.State.buffs[key]
	if type(b) == "table" then
		b.up = on and true or false
		b.fromOverlay = true
		if not on then b.stacks = 0 end
		-- An overlay-derived proc is a REAL observation, so it lifts the degraded flag
		-- for that specific buff -- but it says nothing about stacks or expiry, and the
		-- rules that need those must keep treating them as unknown.
		b.stacksKnown = false
	end
end

Tuono.RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", function(event, spellID)
	setOverlay(spellID, true)
end)
Tuono.RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", function(event, spellID)
	setOverlay(spellID, false)
end)

-- Pollable form, for state that was already active before we loaded.
function O.RefreshOverlays()
	local api = _G.C_SpellActivationOverlay
	local fn = (api and api.IsSpellOverlayed) or _G.IsSpellOverlayed
	if not fn then return false end
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	if not (profile and profile.overlayAuras) then return false end

	for spellID in pairs(profile.overlayAuras) do
		local ok, on = pcall(fn, spellID)
		if ok then
			local b, known = Tuono.readBool(on)
			if known then setOverlay(spellID, b) end
		end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- 2. Never-secret aura whitelist
-- ---------------------------------------------------------------------------
-- spellID -> true when C_Secrets says this aura is NeverSecret, so it can be read in
-- full (stacks, expiry) even in combat.
O.readableAuras = {}
O.auraProbeDone = false

function O.ProbeAuraSecrecy()
	local cs = _G.C_Secrets
	if not (cs and cs.GetSpellAuraSecrecy) then return false end
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	if not profile then return false end

	-- SecrecyLevel: 0 NeverSecret, 1 AlwaysSecret, 2 ContextuallySecret.
	local NEVER = (Enum and Enum.SecrecyLevel and Enum.SecrecyLevel.NeverSecret) or 0

	for k in pairs(O.readableAuras) do O.readableAuras[k] = nil end

	local candidates = {}
	for _, id in pairs(profile.spells or {}) do candidates[id] = true end
	for _, entry in ipairs(profile.trackedAuras or {}) do
		if entry.spellID then candidates[entry.spellID] = true end
	end
	-- Whatever else the profile wants probed (RtB stage buffs, once their IDs exist).
	for _, id in ipairs(profile.auraProbeList or {}) do candidates[id] = true end

	for id in pairs(candidates) do
		local ok, level = pcall(cs.GetSpellAuraSecrecy, id)
		if ok then
			local lv = Tuono.readNum(level)
			if lv == NEVER then O.readableAuras[id] = true end
		end
	end
	O.auraProbeDone = true
	return true
end

-- Read an aura in full, but ONLY if it is on the never-secret whitelist. Returns nil
-- otherwise rather than attempting a read that would come back secret or raise.
function O.ReadAura(spellID)
	if not spellID or not O.readableAuras[spellID] then return nil end
	local api = C_UnitAuras
	if not api then return nil end
	local ok, aura
	if api.GetPlayerAuraBySpellID then
		ok, aura = pcall(api.GetPlayerAuraBySpellID, spellID)
	elseif api.GetAuraDataBySpellID then
		ok, aura = pcall(api.GetAuraDataBySpellID, "player", spellID)
	end
	if not ok or type(aura) ~= "table" then return nil end
	return aura
end

-- ---------------------------------------------------------------------------
-- 3. Aura cardinality: identity without semantics
-- ---------------------------------------------------------------------------
O.auraCount = nil
O.auraInstanceIDs = nil

function O.RefreshAuraCardinality()
	local api = C_UnitAuras
	if not (api and api.GetUnitAuraInstanceIDs) then return false end
	local ok, ids = pcall(api.GetUnitAuraInstanceIDs, "player", "HELPFUL")
	if not ok or type(ids) ~= "table" or Tuono.isSecret(ids) then
		O.auraCount = nil
		return false
	end
	local okLen, n = pcall(function() return #ids end)
	O.auraCount = okLen and n or nil
	O.auraInstanceIDs = okLen and ids or nil
	return okLen == true
end

-- ---------------------------------------------------------------------------
-- 4. Patch-correct UI error names
-- ---------------------------------------------------------------------------
-- UI_ERROR_MESSAGE's errorType is a luaIndex whose numeric values SHIFT BETWEEN
-- PATCHES -- the wiki's table is stale to 9.2.5 and warns as much. Comparing localized
-- message strings works but is fragile in the other direction. GetGameMessageInfo maps
-- index -> stable errorName ("ERR_OUT_OF_ENERGY"), and is not secret, so building the
-- map at load makes the channel both patch-correct and locale-independent.
O.errorNames = {}

function O.BuildErrorMap()
	local fn = _G.GetGameMessageInfo
	if not fn then return false end
	for i = 1, 2000 do
		local ok, name = pcall(fn, i)
		if ok and type(name) == "string" and name ~= "" then
			O.errorNames[i] = name
		end
	end
	return true
end

function O.ErrorName(errorType)
	local n = Tuono.readNum(errorType)
	return n and O.errorNames[n] or nil
end

-- ---------------------------------------------------------------------------
Tuono.RegisterEvent("PLAYER_LOGIN", function()
	Tuono.safe(O.BuildErrorMap)
	Tuono.safe(O.ProbeAuraSecrecy)
	Tuono.safe(O.RefreshOverlays)
end)

-- Talent changes can alter which auras exist and which are flagged; re-probe.
for _, evt in ipairs({ "TRAIT_CONFIG_UPDATED", "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_ENTERING_WORLD" }) do
	Tuono.RegisterEvent(evt, function()
		Tuono.safe(O.ProbeAuraSecrecy)
		Tuono.safe(O.RefreshOverlays)
	end)
end
