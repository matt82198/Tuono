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
-- 5. ROLL THE BONES STAGE: MODEL IT, correct it against observation
-- ---------------------------------------------------------------------------
-- The stage IS the identity of the single summary aura RtB applies. We know one ID for
-- certain (1214933 "One of a Kind" = stage 1, captured from a live client). The other
-- three only appear when the dice land that way, so rather than guess them, learn them.
--
-- THIS USED TO BE A PURE READ, re-queried every tick, and that is why the bar flapped.
-- The aura query does not answer reliably in combat: measured on a live 69-second trace,
-- the stage was readable on 27% of ticks. A blinking sensor produces a blinking
-- recommendation, because a stage-gated rule correctly enters and leaves the priority
-- walk with it (docs/INVERSION.md §2).
--
-- So it is inverted, per §4. Roll the Bones is a textbook candidate: the stage is FIXED
-- at the instant of the roll, nothing but a new roll or expiry can change it, the roll
-- itself is observed exactly (UNIT_SPELLCAST_SUCCEEDED carries a readable spellID), and
-- the duration is a profile constant. Identify once, then integrate.
--
--   observation  a whitelist read, or a plain presence query that answered. Always wins;
--                the model may never overwrite it (§6.2).
--   model        stage + expiry, carried forward through however long the sensor is dark.
--   expiry       a POSITIVE fact, derived from a cast we watched plus a constant we
--                hold. Past it, the stage is a known 0 and Roll the Bones is recommended.
--   unknown      a roll landed that nothing ever identified. Stays unknown; we do not
--                fabricate a stage to make the model look continuous (§6.5).
--
-- The learner survives unchanged: only one of the four stage IDs is confirmed from a live
-- client, and it is what makes the map self-completing.

local pendingRollAt = 0
local knownBuffIDs = nil     -- everything seen on the player before the roll

-- stage: the identified stage, or nil while a roll is outstanding and unidentified.
-- expiresAt: when the buff ends -- from the aura payload when it is readable, otherwise
-- from the roll we observed plus the profile's declared duration.
local rtbModel = { stage = nil, expiresAt = nil }

local function rtbConstants()
	local p = Tuono.Profiles and Tuono.Profiles.Active()
	local duration = (p and p.rtbDuration) or 30
	-- Keep It Rolling adds a full duration but cannot push total remaining past the cap.
	local cap = (p and p.rtbExtendCap) or (duration * 2)
	return duration, cap
end

-- Alias-aware spell match, because the cast can arrive under a renumbered sibling ID --
-- Roll the Bones moved in Midnight and the profile lists both candidates.
local function isSpell(profile, key, id)
	if Tuono.Profiles and Tuono.Profiles.MatchesSpell then
		local ok, res = pcall(Tuono.Profiles.MatchesSpell, key, id)
		if ok then return res and true or false end
	end
	return profile.spells and profile.spells[key] == id
end

local function snapshotBuffIDs()
	local set = {}
	local api = C_UnitAuras
	if not (api and api.GetAuraDataByIndex) then return nil end
	for i = 1, 40 do
		local ok, a = pcall(api.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok then return nil end       -- index path raises while auras are secret
		if not a then break end
		local id = Tuono.readNum(a.spellId)
		if id then set[id] = true end
	end
	return set
end

-- Persist a newly-discovered stage aura so it survives the session and I can read it
-- off disk without anyone transcribing anything.
local function recordCandidate(spellID, name)
	TuonoDiagDB = TuonoDiagDB or {}
	TuonoDiagDB.rtbCandidates = TuonoDiagDB.rtbCandidates or {}
	if TuonoDiagDB.rtbCandidates[tostring(spellID)] then return end
	TuonoDiagDB.rtbCandidates[tostring(spellID)] = name or "?"
	Tuono.print("Learned a new Roll the Bones aura: " .. tostring(spellID) ..
		" (" .. tostring(name) .. "). Saved -- /reload to persist.")
end

-- THE OBSERVATION CHANNEL. Returns (stage, auraTable) or nil.
--
-- The stage IS the identity of the aura, so PRESENCE is enough -- we never need the
-- payload, which is the part Midnight actually hides.
--
-- The ordinary query used to be gated on `not inCombat` here, while PollRtbLearner ran
-- the identical query UNGATED. In combat that pairing was actively harmful: the learner
-- cleared rtbUnknownPresent without this function ever resolving a stage, so it fell
-- through to "stage 0, KNOWN" with a Jackpot up, and the reroll rule fired. That is the
-- reroll-a-Jackpot bug by a second route, and it was live.
--
-- The gate is gone. A query that answers is an observation whatever the combat state; one
-- that does not simply returns nil and the model carries.
local function identifyStage()
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	local map = profile and profile.rtbStageBuffs
	if not map then return nil end

	local api = C_UnitAuras
	for spellID, stage in pairs(map) do
		local aura = O.ReadAura(spellID)              -- whitelist path, full payload
		if aura then return stage, aura end
		if api and api.GetPlayerAuraBySpellID then
			local ok, a = pcall(api.GetPlayerAuraBySpellID, spellID)
			-- A secret container is not an answer. A plain table is presence, and
			-- presence is identity.
			if ok and a ~= nil and not Tuono.isSecret(a) and type(a) == "table" then
				return stage, a
			end
		end
	end
	return nil
end

-- Returns stage, stageKnown.
function O.ResolveRtbStage()
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	local map = profile and profile.rtbStageBuffs
	if not map then return 0, false end

	local now = GetTime()
	local duration = rtbConstants()

	-- 1. OBSERVATION WINS, ALWAYS. Time widens, observation tightens, never the reverse
	--    (§6.2) -- so a live identification replaces the model outright.
	local stage, aura = identifyStage()
	if stage then
		rtbModel.stage = stage
		-- Prefer a real expiry off the payload. Otherwise keep the window the roll
		-- anchored, and only invent one when we hold none -- a buff cannot outlast a
		-- full duration from the moment we saw it, so that is a sound upper bound.
		local expires = aura and Tuono.readNum(aura.expirationTime)
		if expires and expires > now then
			rtbModel.expiresAt = expires
		elseif not rtbModel.expiresAt or rtbModel.expiresAt <= now then
			rtbModel.expiresAt = now + duration
		end
		O.rtbUnknownPresent = false
		return stage, true
	end

	-- 2. NOTHING ANSWERED -- the normal case in combat, and exactly what the model is for.
	if rtbModel.expiresAt and now >= rtbModel.expiresAt then
		-- Aged out. This is a POSITIVE fact, derived from a cast we watched and a
		-- constant we hold, not an absence of information. Reporting it as unknown
		-- would stop Roll the Bones ever being recommended, which breaks the core
		-- ability of the spec outright.
		rtbModel.stage, rtbModel.expiresAt = nil, nil
		O.rtbUnknownPresent = false
		return 0, true
	end

	if rtbModel.stage and rtbModel.expiresAt then
		return rtbModel.stage, true
	end

	-- 3. A roll landed and nothing ever identified it. Presence is real, the stage is
	--    not. Refuse, so the reroll rule cannot fire.
	if O.rtbUnknownPresent then return 0, false end

	-- 4. No buff and nothing outstanding: stage 0, KNOWN, so Roll the Bones can be
	--    recommended when there is genuinely nothing up.
	--
	-- RESIDUAL RISK, stated plainly and now much smaller. If the player carries a stage
	-- buff this session never saw land -- reloading or zoning mid-buff -- there is no
	-- anchor to integrate from, and this answers "stage 0, known". Two things narrow it
	-- that did not before: identification is no longer gated on being out of combat, so
	-- ANY tick whose aura query answers seeds the model; and PLAYER_ENTERING_WORLD
	-- re-seeds immediately, which is the common case for a zone change. It is not closed.
	return 0, true
end

O.rtbUnknownPresent = false

Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, castGUID, spellID)
	local id = Tuono.readNum(spellID)
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	if not (id and profile and profile.spells) then return end

	local duration, cap = rtbConstants()
	local now = GetTime()

	-- KEEP IT ROLLING EXTENDS; IT DOES NOT RE-ROLL. It lengthens the buffs you already
	-- have. Treating it as a fresh roll -- which this handler used to do -- threw away a
	-- stage we had already identified and sent the model back to unknown for nothing.
	if isSpell(profile, "keepItRolling", id) then
		if rtbModel.expiresAt then
			rtbModel.expiresAt = math.min(now + cap, rtbModel.expiresAt + duration)
		end
		return
	end

	if not isSpell(profile, "rollTheBones", id) then return end

	-- A ROLL IS THE TRANSITION. The dice are re-thrown, so whatever stage we believed is
	-- void -- but the WINDOW is now known exactly, from this instant plus a constant.
	rtbModel.stage = nil
	rtbModel.expiresAt = now + duration

	pendingRollAt = now
	-- Out of combat we can diff the buff list; in combat the index scan raises, so the
	-- learner simply does not run and we fall back to "unknown".
	knownBuffIDs = snapshotBuffIDs()
	O.rtbUnknownPresent = true
end)

-- Shortly after a roll, look for an aura that was not there before.
function O.PollRtbLearner()
	if pendingRollAt == 0 then return end
	if (GetTime() - pendingRollAt) < 0.4 then return end
	pendingRollAt = 0

	-- If the roll produced an aura we DO recognise, the stage is resolvable and there is
	-- nothing unidentified outstanding.
	local prof = Tuono.Profiles and Tuono.Profiles.Active()
	if prof and prof.rtbStageBuffs then
		for spellID in pairs(prof.rtbStageBuffs) do
			local api = C_UnitAuras
			if api and api.GetPlayerAuraBySpellID then
				local ok, a = pcall(api.GetPlayerAuraBySpellID, spellID)
				if ok and a then O.rtbUnknownPresent = false end
			end
		end
	end

	if not knownBuffIDs then return end
	local after = snapshotBuffIDs()
	if not after then return end

	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	local map = (profile and profile.rtbStageBuffs) or {}
	local api = C_UnitAuras

	for id in pairs(after) do
		if not knownBuffIDs[id] and not map[id] then
			local name = nil
			if api and api.GetPlayerAuraBySpellID then
				local ok, a = pcall(api.GetPlayerAuraBySpellID, id)
				if ok and a then
					local s = a.name
					if type(s) == "string" and not Tuono.isSecret(s) then name = s end
				end
			end
			recordCandidate(id, name)
		end
	end
	knownBuffIDs = nil
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

-- A RELOAD OR ZONE LEAVES NO ANCHOR. The model describes a buff whose roll we watched;
-- across a world boundary we watched nothing, so carrying the old window forward would
-- describe a fight we are no longer in. Clear it, then re-seed immediately -- a zone
-- change lands out of combat, where the aura query answers, so the common case recovers
-- on the spot instead of waiting for the next roll.
--
-- Registered AFTER the re-probe above so the never-secret whitelist is refreshed before
-- the re-seed consults it; handlers fire in registration order.
Tuono.RegisterEvent("PLAYER_ENTERING_WORLD", function()
	rtbModel.stage, rtbModel.expiresAt = nil, nil
	O.rtbUnknownPresent = false
	Tuono.safe(O.ResolveRtbStage)
end)
