local ADDON_NAME, OA = ...

OA.Rotation = OA.Rotation or {}

-- ABILITIES TABLE: transcribed from research/rotation-model.md
-- Format: { energyCost, cpGenerated, cpSpender (bool), cooldown, triggersGCD, talentGated }
local ABILITIES = {
	[OA.SpellIDs.sinisterStrike] = { cost=45, cpGen=1, cpSpend=false, cd=0, gcd=true, talent=false },
	[OA.SpellIDs.ambush] = { cost=0, cpGen=2, cpSpend=false, cd=0, gcd=false, talent=false },
	[OA.SpellIDs.bladeRush] = { cost=25, cpGen=1, cpSpend=false, cd=0, gcd=true, talent=false },
	[OA.SpellIDs.rollTheBones] = { cost=25, cpGen=0, cpSpend=false, cd=0, gcd=true, talent=false },
	[OA.SpellIDs.betweenTheEyes] = { cost=25, cpGen=0, cpSpend=6, cd=0, gcd=true, talent=false },
	[OA.SpellIDs.killingSpree] = { cost=25, cpGen=0, cpSpend=6, cd=0, gcd=true, talent=false },
	[OA.SpellIDs.dispatch] = { cost=25, cpGen=0, cpSpend=5, cd=0, gcd=true, talent=false },
	[OA.SpellIDs.pistolShot] = { cost=40, cpGen=1, cpSpend=false, cd=0, gcd=true, talent=false },
	[OA.SpellIDs.adrenalineRush] = { cost=0, cpGen=0, cpSpend=false, cd=0, gcd=false, talent=false },
	[OA.SpellIDs.bladeFlurry] = { cost=0, cpGen=0, cpSpend=false, cd=0, gcd=false, talent=false },
	[OA.SpellIDs.preparation] = { cost=0, cpGen=0, cpSpend=false, cd=0, gcd=false, talent=true },
	keepItRolling = { cost=0, cpGen=0, cpSpend=false, cd=0, gcd=false, talent=true },
}

-- Killing Spree spell ID; using reference to avoid direct constant
local KILLING_SPREE_ID = 51690 -- TODO(M0): verify in-game

-- PRIORITY LIST: SINGLE-TARGET (research/rotation-model.md §1b)
-- Ordered rules; first condition match wins
local PRIORITY_SINGLE = {
	-- Rule 1: Roll the Bones at stage < 2 (reroll to progress)
	function(S, A)
		if S.buffs.rtb.stage < 2 and S.cooldowns.rollTheBones.ready and S.energy >= 25 then
			return OA.SpellIDs.rollTheBones, "RtB_reroll_low_stage"
		end
		return nil
	end,
	-- Rule 2: Keep It Rolling at stage >= 3 (maintain buff)
	function(S, A)
		if S.buffs.rtb.stage >= 3 and S.energy >= 0 then
			-- Note: KIR ID is not in SpellIDs; skip if unavailable
			return nil
		end
		return nil
	end,
	-- Rule 3: Adrenaline Rush on cooldown
	function(S, A)
		if S.cooldowns.adrenalineRush.ready then
			return OA.SpellIDs.adrenalineRush, "AR_on_cooldown"
		end
		return nil
	end,
	-- Rule 4: Blade Rush on cooldown (builder/mobility)
	function(S, A)
		if S.cooldowns.bladeRush.ready and S.energy >= 25 then
			return OA.SpellIDs.bladeRush, "BR_on_cooldown"
		end
		return nil
	end,
	-- Rule 5: Between the Eyes at 6 CP
	function(S, A)
		if S.comboPoints >= 6 and S.cooldowns.betweenTheEyes.ready and S.energy >= 25 then
			return OA.SpellIDs.betweenTheEyes, "BtE_finisher_6cp"
		end
		return nil
	end,
	-- Rule 6: Killing Spree at 6 CP (when BtE on CD)
	function(S, A)
		if S.comboPoints >= 6 and S.cooldowns.killingSpree.ready and S.energy >= 25 then
			return KILLING_SPREE_ID, "KS_finisher_6cp"
		end
		return nil
	end,
	-- Rule 7: Dispatch at 5-6 CP (fallback finisher)
	function(S, A)
		if S.comboPoints >= 5 and S.energy >= 25 then
			return OA.SpellIDs.dispatch, "Dispatch_finisher"
		end
		return nil
	end,
	-- Rule 8: Pistol Shot with Opportunity (only recommend at 6 stacks + high energy)
	function(S, A)
		if S.buffs.opportunity.up and S.energy >= 40 then
			return OA.SpellIDs.pistolShot, "PS_opportunity"
		end
		return nil
	end,
	-- Rule 9: Sinister Strike as default builder
	function(S, A)
		if S.energy >= 45 then
			return OA.SpellIDs.sinisterStrike, "SS_default_builder"
		end
		return nil
	end,
}

-- PRIORITY LIST: MULTI-TARGET (AoE when 2+ enemies or aoeMode=true)
-- Insert Blade Flurry after Adrenaline Rush
local PRIORITY_AOE = {
	-- Rules 1-3: same as single-target (RtB, Keep It Rolling, AR)
	PRIORITY_SINGLE[1],
	PRIORITY_SINGLE[2],
	PRIORITY_SINGLE[3],
	-- Rule 3.5: Blade Flurry on cooldown when 2+ targets at low CP
	function(S, A)
		if S.cooldowns.bladeFlurry.ready and S.comboPoints < 5 then
			return OA.SpellIDs.bladeFlurry, "BF_aoe_low_cp"
		end
		return nil
	end,
	-- Rest of the list
	PRIORITY_SINGLE[4],
	PRIORITY_SINGLE[5],
	PRIORITY_SINGLE[6],
	PRIORITY_SINGLE[7],
	PRIORITY_SINGLE[8],
	PRIORITY_SINGLE[9],
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
	local priorityList = PRIORITY_SINGLE
	if S.enemyCount and S.enemyCount >= 2 then
		priorityList = PRIORITY_AOE
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

		for _, rule in ipairs(priorityList) do
			local id, ruleReason = rule(S, OA.Assist)
			if id then
				spellID = id
				reason = ruleReason
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
				S.cooldowns.adrenalineRush.remaining = math.max(0, S.cooldowns.adrenalineRush.remaining - cdr)
				S.cooldowns.bladeRush.remaining = math.max(0, S.cooldowns.bladeRush.remaining - cdr)
				S.cooldowns.bladeFlurry.remaining = math.max(0, S.cooldowns.bladeFlurry.remaining - cdr)
				S.cooldowns.rollTheBones.remaining = math.max(0, S.cooldowns.rollTheBones.remaining - cdr)
			end

			-- Start cooldown (if ability has one)
			if spellID == OA.SpellIDs.adrenalineRush then
				S.cooldowns.adrenalineRush.remaining = 180
			elseif spellID == OA.SpellIDs.bladeRush then
				S.cooldowns.bladeRush.remaining = 30  -- Approximate base CD
			elseif spellID == OA.SpellIDs.betweenTheEyes then
				S.cooldowns.betweenTheEyes = S.cooldowns.betweenTheEyes or {}
				S.cooldowns.betweenTheEyes.remaining = 60  -- Approximate base CD
			elseif spellID == KILLING_SPREE_ID then
				S.cooldowns.killingSpree = S.cooldowns.killingSpree or {}
				S.cooldowns.killingSpree.remaining = 60  -- Approximate base CD
			elseif spellID == OA.SpellIDs.bladeFlurry then
				S.cooldowns.bladeFlurry.remaining = 30  -- Approximate base CD
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

	-- Return result array, or nil if empty (fall back to Blizzard)
	if #result == 0 then
		return nil
	end
	return result
end
