local ADDON_NAME, OA = ...

OA.Rotation = OA.Rotation or {}

-- ABILITIES TABLE: verified against live Wowhead data (patch 12.1.0)
-- Format: { cost, cpGen, cpSpend (0 if not spender, else CP cost), cd (base cooldown), gcd }
-- Each value sourced from Wowhead spell page and verified 2026-08-01.
local ABILITIES = {
	-- Sinister Strike: https://www.wowhead.com/spell=1752/sinister-strike (verified 45 energy)
	[OA.SpellIDs.sinisterStrike] = { cost=45, cpGen=1, cpSpend=0, cd=0, gcd=true },
	-- Ambush: https://www.wowhead.com/spell=8676/ambush (0 cost, stealth-only, 2 CP gen)
	[OA.SpellIDs.ambush] = { cost=0, cpGen=2, cpSpend=0, cd=0, gcd=false },
	-- Blade Rush: https://www.wowhead.com/spell=271896/blade-rush (0 cost, 60s CD, not 10s)
	[OA.SpellIDs.bladeRush] = { cost=0, cpGen=1, cpSpend=0, cd=60, gcd=true },
	-- Roll the Bones: https://www.wowhead.com/spell=315508/roll-the-bones (verified 25 energy, 45s CD)
	[OA.SpellIDs.rollTheBones] = { cost=25, cpGen=0, cpSpend=0, cd=45, gcd=true },
	-- Between the Eyes: https://www.wowhead.com/spell=315341/between-the-eyes (25 energy, 45s CD, not 30s)
	[OA.SpellIDs.betweenTheEyes] = { cost=25, cpGen=0, cpSpend=6, cd=45, gcd=true },
	-- Killing Spree: https://www.wowhead.com/spell=5374/killing-spree (45 energy, 180s CD, not 30s)
	[OA.SpellIDs.killingSpree] = { cost=45, cpGen=0, cpSpend=6, cd=180, gcd=true },
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

local SPELL_TO_CDKEY = {}
for k, v in pairs(OA.SpellIDs or {}) do
	if type(v) == "number" then SPELL_TO_CDKEY[v] = k end
end

-- PRIORITY LIST: SINGLE-TARGET (research/rotation-model.md §1b)
-- Each rule: { name, spellID, requiresSpell (or nil for basic builder), when(S, A) -> bool }
-- Ordered; first condition match wins. Talent-gating via requiresSpell.
-- Rules filter dynamically based on OA.State.knownSpells; unlearned abilities are skipped.
local PRIORITY_SINGLE = {
	{
		name = "Ambush_stealth_opener",
		spellID = OA.SpellIDs.ambush,
		requiresSpell = OA.SpellIDs.ambush,
		when = function(S, A)
			-- Ambush only available when stealthed (per research/rotation-model.md §1a)
			return S.stealthed and S.energy >= 0
		end
	},
	{
		name = "RtB_reroll_low_stage",
		spellID = OA.SpellIDs.rollTheBones,
		requiresSpell = OA.SpellIDs.rollTheBones,
		when = function(S, A)
			return S.buffs.rtb.stage < 2 and cdOf(S, "rollTheBones").ready and S.energy >= 25
		end
	},
	{
		name = "KIR_maintain_buff",
		spellID = OA.SpellIDs.keepItRolling,
		requiresSpell = OA.SpellIDs.keepItRolling,
		when = function(S, A)
			return S.buffs.rtb.stage >= 3 and cdOf(S, "keepItRolling").ready and S.energy >= 0
		end
	},
	{
		name = "AR_on_cooldown",
		spellID = OA.SpellIDs.adrenalineRush,
		requiresSpell = OA.SpellIDs.adrenalineRush,
		when = function(S, A)
			return cdOf(S, "adrenalineRush").ready
		end
	},
	{
		name = "BR_on_cooldown",
		spellID = OA.SpellIDs.bladeRush,
		requiresSpell = OA.SpellIDs.bladeRush,
		when = function(S, A)
			return cdOf(S, "bladeRush").ready and S.energy >= 25
		end
	},
	{
		name = "BtE_finisher_6cp",
		spellID = OA.SpellIDs.betweenTheEyes,
		requiresSpell = OA.SpellIDs.betweenTheEyes,
		when = function(S, A)
			return S.comboPoints >= 6 and cdOf(S, "betweenTheEyes").ready and S.energy >= 25
		end
	},
	{
		name = "KS_finisher_6cp",
		spellID = OA.SpellIDs.killingSpree,
		requiresSpell = OA.SpellIDs.killingSpree,
		when = function(S, A)
			return S.comboPoints >= 6 and cdOf(S, "killingSpree").ready and S.energy >= 25
		end
	},
	{
		name = "Dispatch_finisher",
		spellID = OA.SpellIDs.dispatch,
		requiresSpell = OA.SpellIDs.dispatch,
		when = function(S, A)
			return S.comboPoints >= 5 and S.energy >= 25
		end
	},
	{
		name = "PS_opportunity",
		spellID = OA.SpellIDs.pistolShot,
		requiresSpell = OA.SpellIDs.pistolShot,
		when = function(S, A)
			return S.buffs.opportunity.up and S.energy >= 40
		end
	},
	{
		name = "SS_default_builder",
		spellID = OA.SpellIDs.sinisterStrike,
		requiresSpell = nil,
		when = function(S, A)
			-- Only cast if we have energy AND we can generate CP (not at cap).
			-- Without this, an unavailable finisher would cause SS to spam past 6 CP indefinitely.
			return S.energy >= 45 and S.comboPoints < S.comboPointsMax
		end
	},
}

-- PRIORITY LIST: MULTI-TARGET (AoE when 2+ enemies or aoeMode=true)
-- Insert Blade Flurry after Adrenaline Rush
local PRIORITY_AOE = {
	PRIORITY_SINGLE[1], -- RtB_reroll_low_stage
	PRIORITY_SINGLE[2], -- KIR_maintain_buff
	PRIORITY_SINGLE[3], -- AR_on_cooldown
	{
		name = "BF_aoe_low_cp",
		spellID = OA.SpellIDs.bladeFlurry,
		requiresSpell = nil,
		when = function(S, A)
			-- Check energy cost (15), CD, and CP threshold. Off-GCD toggle but still costs energy.
			return cdOf(S, "bladeFlurry").ready and S.comboPoints < 5 and S.energy >= 15
		end
	},
	PRIORITY_SINGLE[4], -- BR_on_cooldown
	PRIORITY_SINGLE[5], -- BtE_finisher_6cp
	PRIORITY_SINGLE[6], -- KS_finisher_6cp
	PRIORITY_SINGLE[7], -- Dispatch_finisher
	PRIORITY_SINGLE[8], -- PS_opportunity
	PRIORITY_SINGLE[9], -- SS_default_builder
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
	if not state or state.buffs.degraded then
		return nil  -- Fall back to Blizzard
	end

	steps = steps or 4
	if steps > 8 then steps = 8 end
	if steps < 1 then steps = 1 end

	-- Deep copy state into virtual state (no side effects on real state)
	local S = deepCopyState(state)

	-- Determine priority list based on enemy count
	local basePriorityList = PRIORITY_SINGLE
	if S.enemyCount and S.enemyCount >= 2 then
		basePriorityList = PRIORITY_AOE
	end

	-- Build active priority list (filter by known talents)
	local priorityList = buildActivePriorityList(basePriorityList, state.knownSpells or {})
	OA.Rotation.activeRuleCount = #priorityList

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

		for _, rule in ipairs(priorityList) do
			if rule.when(S, OA.Assist) then
				spellID = rule.spellID
				reason = rule.name
				break
			end
		end

		if not spellID then
			-- No castable ability; early exit
			break
		end

		-- Determine confidence
		local confidence = "high"
		if step >= 4 then
			confidence = "low"
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
