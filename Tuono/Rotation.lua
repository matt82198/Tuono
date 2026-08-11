local ADDON_NAME, Tuono = ...

-- ============================================================================
-- ROTATION ENGINE (spec-agnostic)
-- ============================================================================
-- Knows nothing about Outlaw, or about any spec. It reads the ACTIVE PROFILE for the
-- ability table and the ordered priority list, then forward-simulates N steps.
-- Everything spec-specific lives in profiles/*.lua.
--
-- The simulation exists because a single "next spell" is not enough: the player asked
-- for a rolling wheel of the next four presses, INCLUDING repeats. If the honest answer
-- at 0 combo points is "Sinister Strike four times", the wheel must show four icons.
-- ============================================================================

Tuono.Rotation = Tuono.Rotation or {}

-- Derived from the active profile on every activation. Published because
-- IntelligenceLayer, Display and EnergyModel all need to map a spellID to its cost or
-- its cooldown key.
Tuono.Rotation.ABILITIES = {}
Tuono.Rotation.SPELL_TO_CDKEY = {}

local ABILITIES = Tuono.Rotation.ABILITIES
local SPELL_TO_CDKEY = Tuono.Rotation.SPELL_TO_CDKEY

local function rebuildFromProfile(profile)
	for k in pairs(ABILITIES) do ABILITIES[k] = nil end
	for k in pairs(SPELL_TO_CDKEY) do SPELL_TO_CDKEY[k] = nil end
	if not profile then return end

	for spellID, data in pairs(profile.abilities or {}) do
		ABILITIES[spellID] = data
	end
	-- The cooldown-key map is keyed by spellID and valued by the profile's spell KEY,
	-- which is also the key StateTracker files cooldown state under.
	for key, spellID in pairs(profile.spells or {}) do
		if type(spellID) == "number" then SPELL_TO_CDKEY[spellID] = key end
	end
end

Tuono.Profiles.OnActivate(rebuildFromProfile)
-- A profile may already be active (registration activates the first one, and profiles
-- load before this file), so build once immediately rather than waiting for the next
-- activation that may never come.
rebuildFromProfile(Tuono.Profiles.Active())

-- ---------------------------------------------------------------------------
-- Rule helpers, published for profiles to use. Profiles load BEFORE this file, so they
-- must reference these lazily (Tuono.RuleHelpers.x inside a closure), never capture them.
-- ---------------------------------------------------------------------------

-- Read-only fallback for a cooldown key the profile does not track. NEVER hand this out
-- as writable: it is module-level, so one `cdOf(...).remaining = x` on a missing key
-- would corrupt every later untracked lookup for the rest of the session.
local UNTRACKED_CD_RO = { known = false, ready = true, remaining = 0 }
local function cdOf(S, key)
	if not (S and S.cooldowns and key) then return UNTRACKED_CD_RO end
	local t = S.cooldowns[key]
	if t == nil then
		-- Create in the VIRTUAL state (deepCopyState isolates it from Tuono.State) so
		-- simulated writes land somewhere real instead of on the shared sentinel.
		t = { known = false, ready = true, remaining = 0 }
		S.cooldowns[key] = t
	end
	return t
end

-- Guides say "6+ CP" because 6 is max for a geared character. A levelling one has
-- comboPointsMax = 5, making a literal >= 6 unreachable: the builder gates below max,
-- every finisher needs 6, and the sequence goes EMPTY. Spend at 6, or at max when lower.
local function finisherThreshold(S)
	local mx = S and S.comboPointsMax
	if type(mx) ~= "number" or mx < 1 then mx = 6 end
	return math.min(6, mx)
end

-- Effective CP cap. comboPointsMax reads 0 when UnitPowerMax was never readable, and
-- `S.comboPoints < 0` is false for every value -- which silently kills the builder rule
-- and empties the sequence. Never return 0.
local function cpCap(S)
	local mx = S and S.comboPointsMax
	if type(mx) ~= "number" or mx < 1 then return 6 end
	return mx
end

-- Absent flag means "assume readable", keeping older state tables and tests working.
local function energyKnown(S) return S and S.energyKnown ~= false end
local function cpIsKnown(S) return S and S.comboPointsKnown ~= false end

-- Asymmetric predicates for unreadable combo points.
-- "AT LEAST n" is a claim we cannot make when CP is hidden, so it fails -- we will not
-- tell the player to spend a finisher we cannot verify. "AT MOST n" gates cooldowns
-- that are near-always correct on cooldown, so an unprovable answer passes rather than
-- suppressing the entire cooldown layer.
local function cpAtLeast(S, n)
	if not cpIsKnown(S) then return false end
	return S.comboPoints >= n
end

local function cpAtMost(S, n)
	if not cpIsKnown(S) then return true end
	return S.comboPoints <= n
end

local function cpBelowCap(S)
	if not cpIsKnown(S) then return true end
	return S.comboPoints < cpCap(S)
end

-- Is an ALTERNATIVE ability genuinely usable? An unlearned spell sits at zero cooldown,
-- so a cooldown-only check reports it "ready" and blocks the fallback that should fire.
local function isUsableAlternative(S, spellID, cdKey)
	if not spellID then return false end
	local known = S.knownSpells and S.knownSpells[spellID]
	if known == false then return false end
	if known == nil and not S.knownUnavailable then return false end
	return cdOf(S, cdKey).ready
end

-- UNREADABLE ENERGY MUST NOT READ AS "BROKE". S.energy is 0 both when genuinely out of
-- energy and when the read failed. Blocking on the second case failed every gate at
-- once and emptied the sequence. When energy is unknown we cannot prove
-- unaffordability, so the ability passes and confidence carries the uncertainty.
-- When set, affordability checks pass unconditionally. Used for ONE narrow purpose:
-- answering "what is the player waiting to afford?" after normal evaluation has found
-- nothing castable. See the pooling fallback in Predict. Never leave this true.
local ignoreEnergy = false

local function canAfford(S, spellID)
	if not spellID then return true end
	local ability = ABILITIES[spellID]
	if not ability then return false end
	if (ability.cost or 0) == 0 then return true end
	if ignoreEnergy then return true end
	if not energyKnown(S) then return true end
	return S.energy >= ability.cost
end

Tuono.RuleHelpers = {
	cdOf = cdOf,
	finisherThreshold = finisherThreshold,
	cpCap = cpCap,
	energyKnown = energyKnown,
	cpIsKnown = cpIsKnown,
	cpAtLeast = cpAtLeast,
	cpAtMost = cpAtMost,
	cpBelowCap = cpBelowCap,
	isUsableAlternative = isUsableAlternative,
	canAfford = canAfford,
}

-- ---------------------------------------------------------------------------
-- Simulation internals
-- ---------------------------------------------------------------------------

local function deepCopyState(state)
	local copy = {}
	for k, v in pairs(state) do
		if type(v) == "table" then
			copy[k] = {}
			for k2, v2 in pairs(v) do
				if type(v2) == "table" then
					copy[k][k2] = {}
					for k3, v3 in pairs(v2) do copy[k][k2][k3] = v3 end
				else
					copy[k][k2] = v2
				end
			end
		else
			copy[k] = v
		end
	end
	return copy
end

-- Restless-Blades-style CDR: 1.0s per CP, 1.3s during RtB stage 3.
local function applyCDR(cpSpent, rtbStage)
	return cpSpent * ((rtbStage == 3) and 1.3 or 1.0)
end

local function calcGCD(hasteBuffUp)
	return hasteBuffUp and 0.8 or 1.0
end

local function calcEnergyRegen(hasteBuffUp)
	local base = 10
	if hasteBuffUp then base = base * 1.6 end
	return base + 2.5   -- Combat Potency average
end

-- Exclude a rule ONLY when we explicitly probed and learned the player lacks the spell.
-- nil means "never probed" -> fail OPEN, because hiding a player's whole rotation on a
-- missing probe is far worse than one stray icon.
local function buildActivePriorityList(priorityList, knownSpells, spells)
	local active = {}
	for _, rule in ipairs(priorityList) do
		local reqID = rule.requiresSpell
		if type(reqID) == "string" then reqID = spells[reqID] end
		if not reqID or knownSpells[reqID] ~= false then
			table.insert(active, rule)
		end
	end
	return active
end

local function ruleSpellID(rule, spells)
	if rule.spellID then return rule.spellID end
	if rule.spellKey then return spells[rule.spellKey] end
	return nil
end

-- ---------------------------------------------------------------------------
-- AOE / SINGLE-TARGET MODE
-- ---------------------------------------------------------------------------
-- A profile carries TWO priority lists. They are genuinely different rotations, not one
-- list with a Blade Flurry bolted on, so the engine selects between them rather than
-- overlaying. Both render to the SAME bar; only the source list changes.
--
-- HYSTERESIS IS THE POINT. Enemy count oscillates constantly in real pulls (adds die,
-- mobs walk out of melee, a nameplate blinks). Switching lists on every crossing makes
-- the wheel strobe between two rotations and is unreadable. So: enter AoE the instant
-- the threshold is met, but only fall back to single-target after the count has stayed
-- below it continuously for a dwell period.
local AOE_DWELL_SECONDS = 2.0

Tuono.Rotation.mode = "single"
Tuono.Rotation.modeReason = "init"
local belowThresholdSince = nil

function Tuono.Rotation.ResolveMode(S)
	local db = Tuono.db or {}
	local threshold = db.aoeThreshold or 2

	-- aoeMode is a tri-state: "auto" | "on" | "off". A manual pin wins outright and is
	-- not subject to dwell. (It was a plain boolean, which cannot express "auto" -- the
	-- state that should be the default.)
	local pin = db.aoeMode
	if pin == true then pin = "on" elseif pin == false then pin = "auto" end
	if pin == "on" then
		belowThresholdSince = nil
		Tuono.Rotation.mode, Tuono.Rotation.modeReason = "aoe", "pinned AoE"
		return "aoe"
	end
	if pin == "off" then
		belowThresholdSince = nil
		Tuono.Rotation.mode, Tuono.Rotation.modeReason = "single", "pinned single"
		return "single"
	end

	local count = S and S.enemyCount
	if count == nil then
		-- Count unreadable: HOLD the current mode rather than snapping to single-target.
		-- Treating "cannot tell" as "one enemy" would drop AoE mid-pack.
		Tuono.Rotation.modeReason = "count unreadable (holding)"
		return Tuono.Rotation.mode
	end

	local now = GetTime()
	if count >= threshold then
		belowThresholdSince = nil
		Tuono.Rotation.mode, Tuono.Rotation.modeReason = "aoe", count .. " enemies"
		return "aoe"
	end

	if Tuono.Rotation.mode == "aoe" then
		belowThresholdSince = belowThresholdSince or now
		if (now - belowThresholdSince) < AOE_DWELL_SECONDS then
			Tuono.Rotation.modeReason = "dwell (" .. count .. " enemies)"
			return "aoe"
		end
	end

	belowThresholdSince = nil
	Tuono.Rotation.mode, Tuono.Rotation.modeReason = "single", count .. " enemies"
	return "single"
end

-- ---------------------------------------------------------------------------
-- Predict: returns an array of { spellID, confidence, reason }, possibly empty.
-- ---------------------------------------------------------------------------
function Tuono.Rotation.Predict(state, steps)
	if not state then return nil end

	local profile = Tuono.Profiles.Active()
	if not profile then return {} end
	local spells = profile.spells or {}

	-- DEGRADED AURA DATA MUST NOT DISABLE THE ROTATION. In real combat Midnight hides
	-- aura payloads, so buffs.degraded is often TRUE. Bailing out here meant the
	-- simulation never ran in combat and the bar fell back to Blizzard's pick. Combo
	-- points and cooldown READINESS are still readable and drive most of the list, so
	-- predict anyway and only lower confidence.
	local degraded = state.buffs and state.buffs.degraded

	steps = steps or 4
	if steps > 8 then steps = 8 end
	if steps < 1 then steps = 1 end

	local S = deepCopyState(state)

	-- Pick which of the profile's two rotations feeds the bar this tick.
	local mode = Tuono.Rotation.ResolveMode(state)
	local sourceList
	if mode == "aoe" then
		-- A profile without a dedicated AoE list falls back to single-target rather than
		-- rendering nothing; not every spec needs two.
		sourceList = Tuono.UserRules.EffectivePriority(profile, "aoe")
		if not sourceList or #sourceList == 0 then
			sourceList = Tuono.UserRules.EffectivePriority(profile, "single")
		end
	else
		sourceList = Tuono.UserRules.EffectivePriority(profile, "single")
	end

	local priorityList = buildActivePriorityList(sourceList or {}, state.knownSpells or {}, spells)
	Tuono.Rotation.activeRuleCount = #priorityList

	local result = {}
	local maxEnergy = 100
	if S.buffs and S.buffs.adrenalineRush and S.buffs.adrenalineRush.up then
		maxEnergy = 150
	end
	local hasteBuff = S.buffs and S.buffs.adrenalineRush and S.buffs.adrenalineRush.up

	for step = 1, steps do
		local spellID, reason = nil, nil
		local poolAttempts, maxPoolAttempts = 0, 3
		local pooledStepOne = false

		repeat
			for _, rule in ipairs(priorityList) do
				local ok, matched = pcall(rule.when, S, state)
				if ok and matched then
					spellID = ruleSpellID(rule, spells)
					reason = rule.name
					if spellID then break end
				end
			end

			-- STEP 1 MUST NEVER *ASSERT* CASTABILITY. Pooling advances virtual time to let
			-- energy regenerate, which is right for future steps but wrong to present as
			-- "press this now": at 40 energy with a 45-cost builder the bar would be
			-- telling you to press something you cannot afford this instant.
			--
			-- It used to hard-break here, which produced an EMPTY sequence -- and the
			-- empty sequence is what handed the whole bar to Blizzard's fallback pick.
			-- Now that the fallback is gone, breaking would leave a blank bar during
			-- energy starvation, which reads as "the addon is broken" when the honest
			-- answer is "wait, this is next". So we still pool, and mark the result
			-- POOLING so the display can dim it and show it as a wait rather than a
			-- command. The invariant is preserved: we never claim it is castable now.
			if not spellID and step == 1 then
				pooledStepOne = true
			end

			if not spellID and poolAttempts < maxPoolAttempts then
				local gcd = calcGCD(hasteBuff)
				S.energy = math.min(maxEnergy, S.energy + calcEnergyRegen(hasteBuff) * gcd)
				for _, cdData in pairs(S.cooldowns) do
					if cdData.remaining and cdData.remaining > 0 then
						cdData.remaining = math.max(0, cdData.remaining - gcd)
						if cdData.remaining <= 0 then cdData.ready = true end
					end
				end
				poolAttempts = poolAttempts + 1
			else
				break
			end
		until false

		-- POOLING FALLBACK. Nothing is castable and pooling ran out of runway (3 GCDs of
		-- regen is ~37 energy, short of a 45-cost builder from empty). Rather than
		-- return an empty sequence -- which is what used to hand the whole bar to
		-- Blizzard's pick, and would now just blank it -- answer the question the player
		-- actually has: what am I waiting for? Re-run the list with affordability
		-- suspended so cooldown and resource gates still apply but energy does not.
		if not spellID and step == 1 then
			ignoreEnergy = true
			local ok = pcall(function()
				for _, rule in ipairs(priorityList) do
					local matched = rule.when(S, state)
					if matched then
						local id = ruleSpellID(rule, spells)
						if id then spellID, reason = id, rule.name break end
					end
				end
			end)
			-- Reset unconditionally: a throw inside the loop must not leave affordability
			-- permanently disabled for every later evaluation in the session.
			ignoreEnergy = false
			if ok and spellID then pooledStepOne = true end
		end

		if not spellID then break end

		local confidence = "high"
		if step >= 4 then confidence = "low" end
		-- Pooling outranks every other confidence label: "you cannot press this yet" is
		-- more important for the player to see than how sure we are about the choice.
		if pooledStepOne and step == 1 then confidence = "pooling" end
		-- Buff-dependent decisions are guesses while aura data is hidden; so is any
		-- energy-gated decision while energy is only an estimate.
		if (degraded or state.energyKnown == false or state.energySource == "estimated")
			and confidence == "high" then
			confidence = "medium"
		end

		table.insert(result, { spellID = spellID, confidence = confidence, reason = reason })

		-- Apply effects to the virtual state so the NEXT step differs from this one.
		local ability = ABILITIES[spellID]
		if ability then
			S.energy = math.max(0, S.energy - (ability.cost or 0))

			if (ability.cpGen or 0) > 0 then
				S.comboPoints = math.min(cpCap(S), S.comboPoints + ability.cpGen)
			elseif (ability.cpSpend or 0) > 0 then
				local cpSpent = math.min(S.comboPoints, ability.cpSpend)
				S.comboPoints = 0
				local cdr = applyCDR(cpSpent, S.buffs.rtb and S.buffs.rtb.stage or 0)
				for _, key in pairs(SPELL_TO_CDKEY) do
					local slot = S.cooldowns[key]
					if slot and slot.remaining and slot.remaining > 0 then
						slot.remaining = math.max(0, slot.remaining - cdr)
						if slot.remaining <= 0 then slot.ready = true end
					end
				end
			end

			-- Consumed procs must not re-fire in the simulation, or the wheel recommends
			-- consecutive Pistol Shots as if Opportunity reset instantly.
			if spellID == spells.pistolShot and S.buffs.opportunity then
				S.buffs.opportunity.up = false
				S.buffs.opportunity.stacks = 0
			end
			-- Ambush breaks stealth, so later steps must not predict it again.
			if spellID == spells.ambush then S.stealthed = false end

			if (ability.cd or 0) > 0 then
				local cdKey = SPELL_TO_CDKEY[spellID]
				if cdKey then
					local slot = cdOf(S, cdKey)
					slot.remaining = ability.cd
					slot.ready = false
				end
			end

			if ability.gcd then
				local gcd = calcGCD(hasteBuff)
				S.energy = math.min(maxEnergy, S.energy + calcEnergyRegen(hasteBuff) * gcd)
				for _, cdData in pairs(S.cooldowns) do
					if cdData.remaining and cdData.remaining > 0 then
						cdData.remaining = math.max(0, cdData.remaining - gcd)
						if cdData.remaining <= 0 then cdData.ready = true end
					end
				end
			end
		end
	end

	return result
end
