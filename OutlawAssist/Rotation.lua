local ADDON_NAME, OA = ...

OA.Rotation = OA.Rotation or {}

-- ABILITIES TABLE: verified against live Wowhead data (patch 12.1.0)
-- Format: { cost, cpGen, cpSpend (0 if not spender, else CP cost), cd (base cooldown), gcd }
-- Each value sourced from Wowhead spell page and verified 2026-08-01.
local ABILITIES = {
	-- Sinister Strike: https://www.wowhead.com/spell=193315/sinister-strike (verified 45 energy, current-patch ID not legacy)
	[OA.SpellIDs.sinisterStrike] = { cost=45, cpGen=1, cpSpend=0, cd=0, gcd=true },
	-- Ambush: https://www.wowhead.com/spell=8676/ambush (0 cost, stealth-only, 2 CP gen, GCD=true per live)
	[OA.SpellIDs.ambush] = { cost=0, cpGen=2, cpSpend=0, cd=0, gcd=true },
	-- Blade Rush: https://www.wowhead.com/spell=271877/blade-rush (0 cost, 60s CD, not 10s)
	[OA.SpellIDs.bladeRush] = { cost=0, cpGen=1, cpSpend=0, cd=60, gcd=true },
	-- Roll the Bones: https://www.wowhead.com/spell=315508/roll-the-bones (verified 25 energy, 45s CD)
	[OA.SpellIDs.rollTheBones] = { cost=25, cpGen=0, cpSpend=0, cd=45, gcd=true },
	-- Between the Eyes: https://www.wowhead.com/spell=315341/between-the-eyes (25 energy, 45s CD, not 30s)
	[OA.SpellIDs.betweenTheEyes] = { cost=25, cpGen=0, cpSpend=6, cd=45, gcd=true },
	-- Killing Spree: https://www.wowhead.com/spell=51690/killing-spree (45 energy, 180s CD, NOT a CP spender — independent cooldown burst)
	[OA.SpellIDs.killingSpree] = { cost=45, cpGen=0, cpSpend=0, cd=180, gcd=true },
	-- Dispatch: https://www.wowhead.com/spell=2098/dispatch (35 energy, not 25; verified critical for leveling)
	[OA.SpellIDs.dispatch] = { cost=35, cpGen=0, cpSpend=5, cd=0, gcd=true },
	-- Pistol Shot: https://www.wowhead.com/spell=185763/pistol-shot (verified 40 energy)
	[OA.SpellIDs.pistolShot] = { cost=40, cpGen=1, cpSpend=0, cd=0, gcd=true },
	-- Adrenaline Rush: https://www.wowhead.com/spell=13750/adrenaline-rush (verified 180s CD)
	[OA.SpellIDs.adrenalineRush] = { cost=0, cpGen=0, cpSpend=0, cd=180, gcd=false },
	-- Blade Flurry: https://www.wowhead.com/spell=13877/blade-flurry (15 energy, 30s CD)
	[OA.SpellIDs.bladeFlurry] = { cost=15, cpGen=0, cpSpend=0, cd=30, gcd=false },
	-- Preparation: https://www.wowhead.com/spell=14185/preparation (0 cost, 30s CD, resets cooldowns)
	[OA.SpellIDs.preparation] = { cost=0, cpGen=0, cpSpend=0, cd=30, gcd=false },
	-- Keep It Rolling: https://www.wowhead.com/spell=333549/keep-it-rolling (0 cost, 360s CD, not 15s)
	[OA.SpellIDs.keepItRolling] = { cost=0, cpGen=0, cpSpend=0, cd=360, gcd=false },
}

-- Define LOW_CP as our interpretation of the guide's wording. This is tunable and should be
-- considered a strategic parameter, not a hardcoded constant from WoW mechanics.
local LOW_CP = 2

-- Defensive cooldown accessor: StateTracker now tracks all ability cooldowns, so a rule
-- referencing any rotation ability gets valid cooldown data. This accessor is a safety
-- belt for any future abilities; if a cooldown is not tracked, it returns ready=true.
-- Read-only fallback for malformed state. NEVER hand this out as a writable table:
-- it is module-level, so a single `cdOf(...).remaining = x` on a missing key would
-- corrupt every later untracked lookup for the rest of the session.
local UNTRACKED_CD_RO = { known = false, ready = true, remaining = 0 }
local function cdOf(S, key)
	if not (S and S.cooldowns and key) then return UNTRACKED_CD_RO end
	local t = S.cooldowns[key]
	if t == nil then
		-- Create in the VIRTUAL state (deepCopyState isolates it from OA.State), so
		-- writes land somewhere real instead of on a shared sentinel.
		t = { known = false, ready = true, remaining = 0 }
		S.cooldowns[key] = t
	end
	return t
end

-- spellID -> cooldown key. Starting a cooldown used to write to `reason`, which is the
-- RULE name ("BR_on_cooldown"), so no ability cooldown ever actually started in the
-- simulation and the same ability could repeat forever in a predicted sequence.
-- Exposed for introspection (/oa debug) and so tests can assert the DATA, not just
-- behaviour -- the ability numbers are the thing most likely to be silently wrong.
OA.Rotation.ABILITIES = ABILITIES

-- BUGFIX: this export used to run BEFORE `local SPELL_TO_CDKEY = {}` below, so it
-- captured the (undeclared, always-nil) GLOBAL SPELL_TO_CDKEY instead of the local
-- table -- OA.Rotation.SPELL_TO_CDKEY was permanently nil, silently disabling
-- IntelligenceLayer's position-1 castability filter (it does
-- `OA.Rotation.SPELL_TO_CDKEY and ...`). The local must exist before it is exported.
local SPELL_TO_CDKEY = {}
for k, v in pairs(OA.SpellIDs or {}) do
	if type(v) == "number" then SPELL_TO_CDKEY[v] = k end
end
-- Exposed so the engine can map a queued spell back to its cooldown key.
OA.Rotation.SPELL_TO_CDKEY = SPELL_TO_CDKEY

-- FINISHER THRESHOLD. The guide says "6+ CP" because 6 is max for a geared rogue. A
-- LEVELLING rogue has comboPointsMax = 5, so a literal >= 6 is UNREACHABLE: the builder
-- is gated below max, every finisher needs 6, and at 5 CP the sequence went EMPTY --
-- which is why the bar froze on Blizzard's static pick with no glow. Spend at 6, or at
-- max when max is lower.
local function finisherThreshold(S)
	local mx = S and S.comboPointsMax
	if type(mx) ~= "number" or mx < 1 then mx = 6 end
	return math.min(6, mx)
end

-- Central affordability checker: prevents hardcoded energy/CP thresholds from drifting vs ABILITIES table
-- Usage: rules call canAfford(S, spellID) instead of S.energy >= X; guarantees consistency
-- NOTE: CP is a strategic decision (managed per-rule), not affordability; we only check energy here
local function canAfford(S, spellID)
	if not spellID then return true end  -- No spell = no cost
	local ability = ABILITIES[spellID]
	if not ability then return false end  -- Unknown spell = unaffordable
	-- Check energy cost only; CP is per-rule strategy
	return S.energy >= ability.cost
end

-- AUTHORITATIVE PRIORITY LIST (10 RULES, verbatim from guide)
-- Ordered; first condition match wins. Talent-gating via requiresSpell.
-- Rules filter dynamically based on OA.State.knownSpells; unlearned abilities are skipped.
local PRIORITY_SINGLE = {
	-- Rule 1: Use Roll the Bones on cooldown unless you are already in Stage 2 or higher.
	{
		name = "RtB_reroll_low_stage",
		spellID = OA.SpellIDs.rollTheBones,
		requiresSpell = OA.SpellIDs.rollTheBones,
		when = function(S, A)
			return S.buffs.rtb.stage < 2 and cdOf(S, "rollTheBones").ready and canAfford(S, OA.SpellIDs.rollTheBones)
		end
	},

	-- Rule 2: Use Keep It Rolling when you are in Stage 3. If your next Roll the Bones is
	-- unlikely to be used alongside Loaded Dice, you can KIR at Stage 2 as well.
	-- NOTE: We default to Stage 2+ (the consistency choice the note recommends) and explain why.
	-- Stage 3 is authoritative, but Stage 2 allowance enables more consistent uptime.
	{
		name = "KIR_maintain_buff",
		spellID = OA.SpellIDs.keepItRolling,
		requiresSpell = OA.SpellIDs.keepItRolling,
		when = function(S, A)
			-- Default to Stage 2+ for consistency (note recommendation); Stage 3 is the hard trigger.
			return S.buffs.rtb.stage >= 2 and cdOf(S, "keepItRolling").ready and canAfford(S, OA.SpellIDs.keepItRolling)
		end
	},

	-- Rule 3: Use Adrenaline Rush on cooldown, at low Combo Points.
	{
		name = "AR_on_cooldown",
		spellID = OA.SpellIDs.adrenalineRush,
		requiresSpell = OA.SpellIDs.adrenalineRush,
		when = function(S, A)
			return S.comboPoints <= LOW_CP and cdOf(S, "adrenalineRush").ready and canAfford(S, OA.SpellIDs.adrenalineRush)
		end
	},

	-- Rule 4: Use Blade Rush on cooldown as if it were a regular builder.
	{
		name = "BR_on_cooldown",
		spellID = OA.SpellIDs.bladeRush,
		requiresSpell = OA.SpellIDs.bladeRush,
		when = function(S, A)
			return cdOf(S, "bladeRush").ready and canAfford(S, OA.SpellIDs.bladeRush)
		end
	},

	-- Rule 5: Cast Between the Eyes on cooldown with 6+ CP.
	{
		name = "BtE_finisher_6cp",
		spellID = OA.SpellIDs.betweenTheEyes,
		requiresSpell = OA.SpellIDs.betweenTheEyes,
		when = function(S, A)
			return S.comboPoints >= finisherThreshold(S) and cdOf(S, "betweenTheEyes").ready and canAfford(S, OA.SpellIDs.betweenTheEyes)
		end
	},

	-- Rule 6: Use Preparation to reset the cooldown of your AR, BtE, and Blade Rush.
	{
		name = "Prep_reset_cooldowns",
		spellID = OA.SpellIDs.preparation,
		requiresSpell = OA.SpellIDs.preparation,
		when = function(S, A)
			-- Use Preparation when any of its cooldown-reset targets are down
			local arDown = not cdOf(S, "adrenalineRush").ready and cdOf(S, "adrenalineRush").remaining > 0
			local bteDown = not cdOf(S, "betweenTheEyes").ready and cdOf(S, "betweenTheEyes").remaining > 0
			local brDown = not cdOf(S, "bladeRush").ready and cdOf(S, "bladeRush").remaining > 0
			return cdOf(S, "preparation").ready and (arDown or bteDown or brDown) and canAfford(S, OA.SpellIDs.preparation)
		end
	},

	-- Rule 7: Use Killing Spree on cooldown, at 6+ Combo Points. Try to avoid using it while
	-- Supercharger is active (Energy overcap risk).
	-- TODO: Supercharger buff ID not yet verified from live source. Implement rule without the
	-- Supercharger condition until buff ID is confirmed via Wowhead.
	{
		name = "KS_burst_cooldown",
		spellID = OA.SpellIDs.killingSpree,
		requiresSpell = OA.SpellIDs.killingSpree,
		when = function(S, A)
			return S.comboPoints >= finisherThreshold(S) and cdOf(S, "killingSpree").ready and canAfford(S, OA.SpellIDs.killingSpree)
		end
	},

	-- Rule 8: Cast Dispatch as your main finisher with 6+ CP if no other finishers are available to be used.
	{
		name = "Dispatch_finisher",
		spellID = OA.SpellIDs.dispatch,
		requiresSpell = OA.SpellIDs.dispatch,
		when = function(S, A)
			if S.comboPoints < finisherThreshold(S) then return false end
			if not canAfford(S, OA.SpellIDs.dispatch) then return false end
			-- Only use Dispatch if both BtE and KS are on cooldown
			local bteReady = cdOf(S, "betweenTheEyes").ready
			local ksReady = cdOf(S, "killingSpree").ready
			return not bteReady and not ksReady
		end
	},

	-- Rule 9: Cast Pistol Shot if you have 6 stacks of Opportunity. If you have 3 stacks,
	-- use it at 1-3 CPs only.
	{
		name = "PS_opportunity",
		spellID = OA.SpellIDs.pistolShot,
		requiresSpell = OA.SpellIDs.pistolShot,
		when = function(S, A)
			if not S.buffs.opportunity.up or not canAfford(S, OA.SpellIDs.pistolShot) then
				return false
			end
			local stacks = S.buffs.opportunity.stacks or 0
			-- 6+ stacks: cast at any CP
			if stacks >= 6 then
				return true
			end
			-- 3-5 stacks: only at 1-3 CP
			if stacks >= 3 then
				return S.comboPoints >= 1 and S.comboPoints <= 3
			end
			-- Less than 3 stacks: don't cast
			return false
		end
	},

	-- Rule 10: Cast Sinister Strike to generate Combo Points.
	{
		name = "SS_default_builder",
		spellID = OA.SpellIDs.sinisterStrike,
		requiresSpell = nil,
		when = function(S, A)
			-- Only cast if we have energy AND we can generate CP (not at cap).
			-- Without this, an unavailable finisher would cause SS to spam past 6 CP indefinitely.
			return canAfford(S, OA.SpellIDs.sinisterStrike) and S.comboPoints < S.comboPointsMax
		end
	},

	-- Stealth opener (not in the numbered rules but necessary for rotation start)
	{
		name = "Ambush_stealth_opener",
		spellID = OA.SpellIDs.ambush,
		requiresSpell = OA.SpellIDs.ambush,
		when = function(S, A)
			-- Ambush only available when stealthed
			return S.stealthed and canAfford(S, OA.SpellIDs.ambush)
		end
	},
}

-- BLADE FLURRY RULE for AoE (single rule, fires when enemyCount >= 2 or aoeMode, at low CP)
-- This is the ONLY single-target/AoE difference per the guide.
local BLADE_FLURRY_RULE = {
	name = "BF_aoe_low_cp",
	spellID = OA.SpellIDs.bladeFlurry,
	requiresSpell = nil,
	when = function(S, A)
		-- Check: 2+ enemies OR manual aoeMode override
		if not S.enemyCount or S.enemyCount < 2 then
			-- Fall back to aoeMode if available (from the config)
			if not A or not A.aoeMode then
				return false
			end
		end
		-- Blade Flurry at LOW CP only (to gain full benefit of Deft Maneuvers)
		return S.comboPoints <= LOW_CP and cdOf(S, "bladeFlurry").ready and canAfford(S, OA.SpellIDs.bladeFlurry)
	end
}

-- Deep copy a state table for simulation (no side effects on real state)
local function deepCopyState(state)
	local copy = {}
	for k, v in pairs(state) do
		if type(v) == "table" then
			copy[k] = {}
			for k2, v2 in pairs(v) do
				if type(v2) == "table" then
					copy[k][k2] = {}
					for k3, v3 in pairs(v2) do
						copy[k][k2][k3] = v3
					end
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

-- Apply Restless Blades CDR to a cooldown value
-- Formula from research/rotation-model.md: 1.0s per CP (or 1.3s during RtB Stage 3)
local function applyCDR(cpSpent, rtbStage)
	local cdrPerCP = 1.0
	if rtbStage == 3 then
		cdrPerCP = 1.3
	end
	return cpSpent * cdrPerCP
end

-- Calculate GCD duration (base 1.0s, min 0.8s during AR)
local function calcGCD(arUp)
	if arUp then
		return 0.8  -- Min during AR; real calculation would be 1.0 - haste%
	end
	return 1.0
end

-- Calculate energy regen per second
local function calcEnergyRegen(arUp, hasVigor)
	local base = 10
	if arUp then
		base = base * 1.6  -- +60%
	end
	-- Combat Potency passive adds 2.5/sec (assumed always active in-combat)
	base = base + 2.5
	return base
end

-- Filter priority list based on known talents/spells
local function buildActivePriorityList(priorityList, knownSpells)
	local active = {}
	for _, rule in ipairs(priorityList) do
		-- Include rule if no talent requirement OR talent is known
		-- Exclude ONLY when we explicitly probed and learned the player lacks it.
		-- nil means "never probed" (no API, or not tracked) -> fail OPEN, because hiding
		-- a player's whole rotation on a missing probe is far worse than one stray icon.
		if not rule.requiresSpell or knownSpells[rule.requiresSpell] ~= false then
			table.insert(active, rule)
		end
	end
	return active
end

-- Main prediction function
-- state: readable state table from OA.State
-- steps: number of steps to predict (default 4, capped at 8)
-- returns: array of {spellID, confidence, reason} or nil if degraded
function OA.Rotation.Predict(state, steps)
	if not state then return nil end

	-- DEGRADED AURA DATA MUST NOT DISABLE THE ROTATION.
	-- In real combat Midnight hides aura spellIds/names, so buffs.degraded is often TRUE.
	-- Bailing out here meant the simulation never ran in combat and the bar fell back to
	-- Blizzard's static pick -- which is why the first icon never changed in live play.
	-- Energy, combo points and cooldowns are all still readable, and they drive most of
	-- the priority list, so we predict anyway and only lower confidence.
	local degraded = state.buffs and state.buffs.degraded

	steps = steps or 4
	if steps > 8 then steps = 8 end
	if steps < 1 then steps = 1 end

	-- Deep copy state into virtual state (no side effects on real state)
	local S = deepCopyState(state)

	-- Build priority list: Ambush first (stealth opener), then numbered rules, then Blade Flurry if AoE
	local priorityList = buildActivePriorityList(PRIORITY_SINGLE, state.knownSpells or {})

	-- Check if we should use Blade Flurry (only if 2+ enemies or aoeMode)
	local useBladeFlurry = false
	if S.enemyCount and S.enemyCount >= 2 then
		useBladeFlurry = true
	end

	OA.Rotation.activeRuleCount = #priorityList
	if useBladeFlurry then
		OA.Rotation.activeRuleCount = OA.Rotation.activeRuleCount + 1
	end

	local result = {}
	local maxEnergy = 100
	if S.buffs.adrenalineRush.up then
		maxEnergy = 150
	end

	-- Simulate N steps
	for step = 1, steps do
		-- Find first matching rule
		local spellID = nil
		local reason = nil
		local pooledEnergy = false

		-- Try up to 3 GCDs of pooling if energy-starved
		local poolAttempts = 0
		local maxPoolAttempts = 3
		repeat
			-- Check Blade Flurry first if AoE conditions met
			if useBladeFlurry and BLADE_FLURRY_RULE.when(S, state) then
				spellID = BLADE_FLURRY_RULE.spellID
				reason = BLADE_FLURRY_RULE.name
			end

			-- If Blade Flurry not available, check regular priority list
			if not spellID then
				for _, rule in ipairs(priorityList) do
					if rule.when(S, state) then
						spellID = rule.spellID
						reason = rule.name
						break
					end
				end
			end

			if not spellID and poolAttempts < maxPoolAttempts then
				-- No castable ability and we haven't tried pooling yet.
				-- Check if this is energy starvation: advance time 1 GCD and retry.
				local gcd = calcGCD(S.buffs.adrenalineRush.up) or 1.0
				local regenRate = calcEnergyRegen(S.buffs.adrenalineRush.up, false)
				S.energy = math.min(maxEnergy, S.energy + (regenRate * gcd))

				-- Decrement cooldowns by GCD
				for cdName, cdData in pairs(S.cooldowns) do
					if cdData.remaining and cdData.remaining > 0 then
						cdData.remaining = math.max(0, cdData.remaining - gcd)
					end
				end

				poolAttempts = poolAttempts + 1
				pooledEnergy = true
				-- Retry the priority check
			else
				-- Either found a spell or exhausted pooling attempts
				break
			end
		until false

		if not spellID then
			-- No castable ability even after pooling; early exit
			break
		end

		-- Determine confidence
		local confidence = "high"
		if step >= 4 then
			confidence = "low"
		end
		-- Buff-dependent decisions are guesses while aura data is hidden.
		if degraded and confidence == "high" then
			confidence = "medium"
		end

		-- Record prediction
		table.insert(result, {
			spellID = spellID,
			confidence = confidence,
			reason = reason
		})

		-- Apply effects to virtual state
		local ability = ABILITIES[spellID]
		if ability then
			-- Spend energy
			S.energy = math.max(0, S.energy - ability.cost)

			-- Generate/spend CP
			if ability.cpGen > 0 then
				S.comboPoints = math.min(S.comboPointsMax, S.comboPoints + ability.cpGen)
			elseif ability.cpSpend > 0 then
				local cpSpent = math.min(S.comboPoints, ability.cpSpend)
				S.comboPoints = 0
				-- Apply Restless Blades CDR to affected cooldowns
				local cdr = applyCDR(cpSpent, S.buffs.rtb.stage)
				cdOf(S, "adrenalineRush").remaining = math.max(0, cdOf(S, "adrenalineRush").remaining - cdr)
				cdOf(S, "bladeRush").remaining = math.max(0, cdOf(S, "bladeRush").remaining - cdr)
				cdOf(S, "bladeFlurry").remaining = math.max(0, cdOf(S, "bladeFlurry").remaining - cdr)
				cdOf(S, "rollTheBones").remaining = math.max(0, cdOf(S, "rollTheBones").remaining - cdr)
				cdOf(S, "betweenTheEyes").remaining = math.max(0, cdOf(S, "betweenTheEyes").remaining - cdr)
				cdOf(S, "killingSpree").remaining = math.max(0, cdOf(S, "killingSpree").remaining - cdr)
				cdOf(S, "keepItRolling").remaining = math.max(0, cdOf(S, "keepItRolling").remaining - cdr)
			end

			-- Clear Opportunity buff after Pistol Shot (simulation must not assume reproc for free).
			-- Without this, multi-step predictions recommend consecutive Pistol Shots as if Opportunity resets instantly.
			if spellID == OA.SpellIDs.pistolShot then
				S.buffs.opportunity.up = false
				S.buffs.opportunity.stacks = 0
				S.buffs.opportunity.expires = 0
			end

			-- Clear stealth after Ambush (Ambush breaks stealth on cast, so subsequent steps should not predict Ambush again).
			-- Without this, the simulation predicts Ambush 4 times in a row, which is impossible in live play.
			if spellID == OA.SpellIDs.ambush then
				S.stealthed = false
			end

			-- Start cooldown on the ABILITY's key (never the rule name).
			if ability.cd and ability.cd > 0 then
				local cdKey = SPELL_TO_CDKEY[spellID]
				if cdKey then
					local slot = cdOf(S, cdKey)
					slot.remaining = ability.cd
					slot.ready = false
				end
			end

			-- Advance virtual time by GCD (if applicable)
			local gcd = calcGCD(S.buffs.adrenalineRush.up) or 1.0
			if ability.gcd then
				-- Regen energy over GCD
				local regenRate = calcEnergyRegen(S.buffs.adrenalineRush.up, false)
				S.energy = math.min(maxEnergy, S.energy + (regenRate * gcd))

				-- Decrement cooldowns by GCD
				for cdName, cdData in pairs(S.cooldowns) do
					if cdData.remaining and cdData.remaining > 0 then
						cdData.remaining = math.max(0, cdData.remaining - gcd)
					end
				end
			end
		end
	end

	-- Return result array (empty array is valid). Rotation.Predict produces a sequence
	-- from state ALONE, independent of Assist availability. Empty array means no
	-- castable ability (out of energy, all CDs down, degraded state). Caller must handle:
	-- if predictions are empty AND Assist available, use Assist pick as fallback (marked
	-- confidence="static-fallback"); if Assist unavailable, return empty queue.
	return result
end
