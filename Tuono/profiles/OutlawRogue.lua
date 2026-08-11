local ADDON_NAME, Tuono = ...

-- ============================================================================
-- PROFILE: Outlaw Rogue
-- ============================================================================
-- The reference profile, and the worked example for anyone writing their own. Nothing
-- in here is privileged -- the engine treats this exactly like a user-authored profile.
--
-- Rules are an ORDERED PRIORITY LIST: the engine walks it top to bottom and the FIRST
-- rule whose `when` returns true supplies the next button. That is the same shape
-- rotation guides are written in, and the same shape the in-game editor edits.
--
-- Rule helpers are resolved LAZILY inside each closure (Tuono.RuleHelpers.x, not a local
-- captured at load) because this file loads BEFORE Rotation.lua publishes them. Writing
-- `local H = Tuono.RuleHelpers` at the top of this file would capture nil forever.
-- ============================================================================

local SPELLS = {
	adrenalineRush = 13750,
	bladeRush      = 271877,
	-- 14185 is the CLASSIC Preparation and 404s on retail Wowhead. The retail 12.x
	-- Outlaw Preparation is 1277933. With the wrong ID every knownSpells probe failed
	-- and SPELL_TO_CDKEY mapped a spell the client does not have.
	preparation    = 1277933,
	betweenTheEyes = 315341,
	rollTheBones   = 315508,
	sinisterStrike = 193315,
	bladeFlurry    = 13877,
	stealth        = 1784,
	pistolShot     = 185763,
	opportunity    = 195627,
	ambush         = 8676,
	killingSpree   = 51690,
	dispatch       = 2098,
	keepItRolling  = 381989,
}

-- A previous version of this comment claimed the whole table was "verified against
-- Wowhead for 12.1.0". It was not: Preparation's spell ID did not exist on retail and
-- its cooldown was off by 8x, Ambush's cost was off by 50, Blade Rush's combo-point
-- generation was invented, and Killing Spree -- a finishing move -- was modelled as
-- spending zero combo points. Corrections below are individually sourced; anything
-- still unverified says so rather than implying a check that did not happen.
--
-- cpSpend = -1 means "spends ALL combo points up to the cap". Finishers scale with the
-- points consumed, so a hardcoded number under-credits Restless Blades CDR at a 6- or
-- 7-point cap. The engine resolves -1 against the live cap.
local SPEND_ALL = -1

local ABILITIES = {
	[SPELLS.sinisterStrike] = { cost = 45, cpGen = 1, cpSpend = 0, cd = 0,   gcd = true },
	-- Ambush is 50 energy (45 with Hidden Opportunity). At cost 0 canAfford always
	-- passed, so the opener could be recommended at 10 energy.
	[SPELLS.ambush]         = { cost = 50, cpGen = 2, cpSpend = 0, cd = 0,   gcd = true },
	-- Blade Rush generates 25 ENERGY over 5s, not a combo point. cpGen was fabricated.
	[SPELLS.bladeRush]      = { cost = 0,  cpGen = 0, cpSpend = 0, cd = 60,  gcd = true },
	[SPELLS.rollTheBones]   = { cost = 25, cpGen = 0, cpSpend = 0, cd = 45,  gcd = true },
	[SPELLS.betweenTheEyes] = { cost = 25, cpGen = 0, cpSpend = SPEND_ALL, cd = 45, gcd = true },
	-- Killing Spree IS a finishing move: "45 Energy / 1 to 7 Combo Points". Modelling
	-- it as cpSpend=0 meant the simulation never zeroed CP or applied its CDR, so every
	-- predicted step after a Killing Spree was wrong.
	[SPELLS.killingSpree]   = { cost = 45, cpGen = 0, cpSpend = SPEND_ALL, cd = 180, gcd = true },
	[SPELLS.dispatch]       = { cost = 35, cpGen = 0, cpSpend = SPEND_ALL, cd = 0,  gcd = true },
	[SPELLS.pistolShot]     = { cost = 40, cpGen = 1, cpSpend = 0, cd = 0,   gcd = true },
	[SPELLS.adrenalineRush] = { cost = 0,  cpGen = 0, cpSpend = 0, cd = 180, gcd = false },
	-- Wowhead lists a 1s GCD for Blade Flurry; it was marked off-GCD, so the simulation
	-- treated pressing it as free and drifted from step 2 onward.
	[SPELLS.bladeFlurry]    = { cost = 15, cpGen = 0, cpSpend = 0, cd = 30,  gcd = true },
	-- Preparation is a 4-MINUTE cooldown, not 30s. At cd=30 the simulation believed it
	-- was available roughly 8x more often than it is.
	[SPELLS.preparation]    = { cost = 0,  cpGen = 0, cpSpend = 0, cd = 240, gcd = false },
	[SPELLS.keepItRolling]  = { cost = 0,  cpGen = 0, cpSpend = 0, cd = 360, gcd = false },
}

local LOW_CP = 2

-- Declarative condition set, mirroring what the in-game editor can build. Every rule
-- below could equally be expressed as editor rows; keeping the same vocabulary means a
-- user-edited copy of this profile stays round-trippable.
local PRIORITY = {
	{
		name = "Ambush from stealth",
		spellKey = "ambush",
		requiresSpell = "ambush",
		conditions = { { type = "stealthed" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return S.stealthed and H.canAfford(S, SPELLS.ambush)
		end
	},
	{
		-- REROLLING MUST FAIL CLOSED WHEN THE STAGE IS UNREADABLE.
		--
		-- `stage` reads 0 both when no Roll the Bones buff is up AND when we simply
		-- cannot see it -- and in 12.x we usually cannot: RtB does not apply an aura
		-- with spellID 315508 (that is the castable ability). It applies one of four
		-- separately-named buffs -- One of a Kind / Double Trouble / Triple Threat /
		-- Jackpot -- whose IDs are NOT YET CONFIRMED for this build, so the tracker
		-- finds nothing and reports stage 0 forever.
		--
		-- The old condition was a bare `stage < 2`, which is true for stage 0, so this
		-- rule fired every time RtB came off cooldown. That means it was telling the
		-- player to reroll a JACKPOT down to a fresh single buff, every 45 seconds --
		-- the most damaging thing in this profile.
		--
		-- Until the stage buffs are resolvable, only recommend RtB when we positively
		-- know there is nothing to lose: stage known AND below 2. `rtbStageKnown` is
		-- false whenever the aura layer could not read it.
		name = "Roll the Bones below stage 2",
		spellKey = "rollTheBones",
		requiresSpell = "rollTheBones",
		conditions = { { type = "rtbStage", op = "<", value = 2 }, { type = "cdReady", spell = "rollTheBones" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			if S.buffs.rtb.stageKnown == false then return false end
			return S.buffs.rtb.stage < 2 and H.cdOf(S, "rollTheBones").ready
				and H.canAfford(S, SPELLS.rollTheBones)
		end
	},
	{
		-- SimC gates this at rtb_buffs>=3, as does Maxroll ("Stage 3 or higher"). The
		-- old >=2 locked a SIX MINUTE cooldown into Double Trouble when Triple Threat
		-- or Jackpot was one reroll away.
		name = "Keep It Rolling at stage 3+",
		spellKey = "keepItRolling",
		requiresSpell = "keepItRolling",
		conditions = { { type = "rtbStage", op = ">=", value = 3 }, { type = "cdReady", spell = "keepItRolling" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			if S.buffs.rtb.stageKnown == false then return false end
			return S.buffs.rtb.stage >= 3 and H.cdOf(S, "keepItRolling").ready
				and H.canAfford(S, SPELLS.keepItRolling)
		end
	},
	{
		name = "Adrenaline Rush at low CP",
		spellKey = "adrenalineRush",
		requiresSpell = "adrenalineRush",
		conditions = { { type = "cp", op = "<=", value = LOW_CP }, { type = "cdReady", spell = "adrenalineRush" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cpAtMost(S, LOW_CP) and H.cdOf(S, "adrenalineRush").ready
				and H.canAfford(S, SPELLS.adrenalineRush)
		end
	},
	{
		name = "Blade Rush on cooldown",
		spellKey = "bladeRush",
		requiresSpell = "bladeRush",
		conditions = { { type = "cdReady", spell = "bladeRush" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cdOf(S, "bladeRush").ready and H.canAfford(S, SPELLS.bladeRush)
		end
	},
	{
		name = "Between the Eyes at max CP",
		spellKey = "betweenTheEyes",
		requiresSpell = "betweenTheEyes",
		conditions = { { type = "cp", op = ">=", value = 6 }, { type = "cdReady", spell = "betweenTheEyes" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cpAtLeast(S, H.finisherThreshold(S)) and H.cdOf(S, "betweenTheEyes").ready
				and H.canAfford(S, SPELLS.betweenTheEyes)
		end
	},
	{
		name = "Preparation to reset cooldowns",
		spellKey = "preparation",
		requiresSpell = "preparation",
		conditions = { { type = "cdReady", spell = "preparation" } },
		when = function(S, A)
			-- Every source uses AND, not OR. Between the Eyes is on a 45s cooldown and is
			-- therefore down almost always, so an OR fired Preparation about two seconds
			-- into every pull, resetting nothing worth resetting -- on a FOUR MINUTE
			-- cooldown. SimC gates on Killing Spree, not Blade Rush; Killing Spree is the
			-- higher-value reset and Preparation resets both anyway.
			--   preparation,if=cooldown.adrenaline_rush.remains>30
			--                 &!cooldown.between_the_eyes.ready
			--                 &!cooldown.killing_spree.ready
			local H = Tuono.RuleHelpers
			if not H.cdOf(S, "preparation").ready then return false end
			if not H.canAfford(S, SPELLS.preparation) then return false end
			return not H.cdOf(S, "adrenalineRush").ready
				and not H.cdOf(S, "betweenTheEyes").ready
				and not H.cdOf(S, "killingSpree").ready
		end
	},
	{
		name = "Killing Spree at max CP",
		spellKey = "killingSpree",
		requiresSpell = "killingSpree",
		conditions = { { type = "cp", op = ">=", value = 6 }, { type = "cdReady", spell = "killingSpree" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cpAtLeast(S, H.finisherThreshold(S)) and H.cdOf(S, "killingSpree").ready
				and H.canAfford(S, SPELLS.killingSpree)
		end
	},
	{
		name = "Dispatch as fallback finisher",
		spellKey = "dispatch",
		requiresSpell = "dispatch",
		conditions = { { type = "cp", op = ">=", value = 6 } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			if not H.cpAtLeast(S, H.finisherThreshold(S)) then return false end
			if not H.canAfford(S, SPELLS.dispatch) then return false end
			local bteUsable = H.isUsableAlternative(S, SPELLS.betweenTheEyes, "betweenTheEyes")
			local ksUsable = H.isUsableAlternative(S, SPELLS.killingSpree, "killingSpree")
			return not bteUsable and not ksUsable
		end
	},
	{
		name = "Pistol Shot on Opportunity",
		spellKey = "pistolShot",
		requiresSpell = "pistolShot",
		conditions = { { type = "buffUp", spell = "opportunity" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			if not S.buffs.opportunity.up or not H.canAfford(S, SPELLS.pistolShot) then
				return false
			end
			local stacks = S.buffs.opportunity.stacks or 0
			if stacks >= 6 then return true end
			if stacks >= 3 then
				return H.cpIsKnown(S) and S.comboPoints >= 1 and S.comboPoints <= 3
			end
			return false
		end
	},
	{
		name = "Sinister Strike to build",
		spellKey = "sinisterStrike",
		requiresSpell = nil,
		conditions = { { type = "cp", op = "<", value = 6 } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.canAfford(S, SPELLS.sinisterStrike) and H.cpBelowCap(S)
		end
	},
	{
		-- LAST RESORT. An empty bar reads as "the addon is broken" and is strictly worse
		-- than one slightly suboptimal suggestion.
		name = "Sinister Strike (last resort)",
		spellKey = "sinisterStrike",
		requiresSpell = nil,
		conditions = { { type = "always" } },
		when = function(S, A)
			return Tuono.RuleHelpers.canAfford(S, SPELLS.sinisterStrike)
		end
	},
}

-- ---------------------------------------------------------------------------
-- AOE ROTATION (a genuinely separate priority list, not an overlay)
-- ---------------------------------------------------------------------------
-- The engine selects between this and PRIORITY by enemy count, with hysteresis, and
-- renders whichever wins to the same bar. The real differences from single target:
--   * Blade Flurry is maintained FIRST and at low CP (Deft Maneuvers wants the cleave
--     window open before you start generating)
--   * Between the Eyes stays the finisher, but Dispatch is preferred less strongly
--     because cleaved builder damage outweighs a second finisher
--   * Killing Spree is worth more here, so it is not gated behind BtE being down
local PRIORITY_AOE = {
	{
		name = "Ambush from stealth",
		spellKey = "ambush",
		requiresSpell = "ambush",
		conditions = { { type = "stealthed" } },
		when = function(S, A)
			return S.stealthed and Tuono.RuleHelpers.canAfford(S, SPELLS.ambush)
		end
	},
	{
		name = "Blade Flurry (maintain cleave)",
		spellKey = "bladeFlurry",
		requiresSpell = "bladeFlurry",
		conditions = { { type = "cdReady" }, { type = "cp", op = "<=", value = LOW_CP } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cdOf(S, "bladeFlurry").ready and H.cpAtMost(S, LOW_CP)
				and H.canAfford(S, SPELLS.bladeFlurry)
		end
	},
	{
		name = "Roll the Bones below stage 2",
		spellKey = "rollTheBones",
		requiresSpell = "rollTheBones",
		conditions = { { type = "rtbStage", op = "<", value = 2 }, { type = "cdReady" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return S.buffs.rtb.stage < 2 and H.cdOf(S, "rollTheBones").ready
				and H.canAfford(S, SPELLS.rollTheBones)
		end
	},
	{
		name = "Adrenaline Rush at low CP",
		spellKey = "adrenalineRush",
		requiresSpell = "adrenalineRush",
		conditions = { { type = "cp", op = "<=", value = LOW_CP }, { type = "cdReady" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cpAtMost(S, LOW_CP) and H.cdOf(S, "adrenalineRush").ready
				and H.canAfford(S, SPELLS.adrenalineRush)
		end
	},
	{
		name = "Killing Spree (cleaves hard)",
		spellKey = "killingSpree",
		requiresSpell = "killingSpree",
		conditions = { { type = "cp", op = ">=", value = 6 }, { type = "cdReady" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cpAtLeast(S, H.finisherThreshold(S)) and H.cdOf(S, "killingSpree").ready
				and H.canAfford(S, SPELLS.killingSpree)
		end
	},
	{
		name = "Blade Rush on cooldown",
		spellKey = "bladeRush",
		requiresSpell = "bladeRush",
		conditions = { { type = "cdReady" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cdOf(S, "bladeRush").ready and H.canAfford(S, SPELLS.bladeRush)
		end
	},
	{
		name = "Between the Eyes at max CP",
		spellKey = "betweenTheEyes",
		requiresSpell = "betweenTheEyes",
		conditions = { { type = "cp", op = ">=", value = 6 }, { type = "cdReady" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cpAtLeast(S, H.finisherThreshold(S)) and H.cdOf(S, "betweenTheEyes").ready
				and H.canAfford(S, SPELLS.betweenTheEyes)
		end
	},
	{
		name = "Dispatch as fallback finisher",
		spellKey = "dispatch",
		requiresSpell = "dispatch",
		conditions = { { type = "cp", op = ">=", value = 6 } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.cpAtLeast(S, H.finisherThreshold(S)) and H.canAfford(S, SPELLS.dispatch)
		end
	},
	{
		name = "Pistol Shot on Opportunity",
		spellKey = "pistolShot",
		requiresSpell = "pistolShot",
		conditions = { { type = "buffUp", spell = "opportunity" } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return S.buffs.opportunity.up and H.canAfford(S, SPELLS.pistolShot)
		end
	},
	{
		name = "Sinister Strike to build",
		spellKey = "sinisterStrike",
		requiresSpell = nil,
		conditions = { { type = "cp", op = "<", value = 6 } },
		when = function(S, A)
			local H = Tuono.RuleHelpers
			return H.canAfford(S, SPELLS.sinisterStrike) and H.cpBelowCap(S)
		end
	},
	{
		name = "Sinister Strike (last resort)",
		spellKey = "sinisterStrike",
		requiresSpell = nil,
		conditions = { { type = "always" } },
		when = function(S, A)
			return Tuono.RuleHelpers.canAfford(S, SPELLS.sinisterStrike)
		end
	},
}

Tuono.Profiles.Register({
	id = "outlaw-rogue",
	name = "Outlaw Rogue",
	class = "ROGUE",
	specIndex = 2,
	builtin = true,
	spells = SPELLS,
	abilities = ABILITIES,
	priority = PRIORITY,          -- single target
	priorityAoE = PRIORITY_AOE,   -- 2+ enemies; engine switches with hysteresis
	-- Used by the enemy counter to reject nameplates outside melee range, so an 8yd
	-- cleave decision is not made off a 40yd nameplate count.
	meleeRangeSpell = "sinisterStrike",
	resources = {
		primary = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3,
		secondary = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4,
	},
	-- Buff spellIDs the state tracker should follow for this spec.
	trackedAuras = {
		{ key = "adrenalineRush", spellID = SPELLS.adrenalineRush },
		{ key = "rtb",            spellID = SPELLS.rollTheBones },
		{ key = "opportunity",    spellID = SPELLS.opportunity },
		{ key = "stealthed",      spellID = SPELLS.stealth },
	},
})
