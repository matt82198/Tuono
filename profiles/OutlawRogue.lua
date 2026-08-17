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
	-- 1214909, not 315508. SimC resolves Roll the Bones by NAME because the ID moved in
	-- Midnight: SpecializationSpells has zero rows for 315508, while 1214909 is row 7256
	-- under spec 260 (Outlaw). The alias list below still resolves against the client at
	-- load and 315508 remains a candidate there -- but the DEFAULT must be the live ID,
	-- because the alias path returns early when C_SpellBook.IsSpellKnown is unavailable,
	-- and the default was then rendering an icon for a spell that does not exist.
	rollTheBones   = 1214909,
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
	-- Stealth is not part of the damage rotation, but it IS the correct action when you
	-- are stood out of combat about to pull, and the bar is shown out of combat. It has to
	-- be in ABILITIES or the simulator cannot cost it or start its cooldown.
	[SPELLS.stealth]        = { cost = 0,  cpGen = 0, cpSpend = 0, cd = 20,  gcd = false },
}

local LOW_CP = 2

-- Declarative condition set, mirroring what the in-game editor can build. Every rule
-- below could equally be expressed as editor rows; keeping the same vocabulary means a
-- user-edited copy of this profile stays round-trippable.
local PRIORITY = {
	{
		-- STEALTH BEFORE THE PULL. This used to live in data/rules.lua as a PIN, which
		-- forced it to position 1 from OUTSIDE the simulation -- so it also fired in the
		-- middle of combat and shoved itself in front of the real rotation. As a priority
		-- rule it is simulated like everything else: it wins out of combat because nothing
		-- above it applies, and it simply never matches once the fight starts.
		name = "Stealth before the pull",
		spellKey = "stealth",
		requiresSpell = "stealth",
		conditions = { { type = "stealthed" } },
		when = function(S, A)
			return not S.inCombat and not S.stealthed
		end
	},
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
		-- cannot see it. The old condition was a bare `stage < 2`, true for stage 0, so
		-- this rule fired every time RtB came off cooldown -- telling the player to
		-- reroll a JACKPOT down to a single buff, every 45 seconds. The most damaging
		-- thing this profile did.
		--
		-- The four stage auras are now known (see rtbStageBuffs) and resolved through
		-- Observers.ResolveRtbStage, so the common case is genuinely readable. The guard
		-- stays because readability is still conditional: an unidentified roll, or a
		-- stage aura that is neither whitelisted nor readable out of combat, must not be
		-- silently treated as "no buff".
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
		-- STEALTH BEFORE THE PULL. This used to live in data/rules.lua as a PIN, which
		-- forced it to position 1 from OUTSIDE the simulation -- so it also fired in the
		-- middle of combat and shoved itself in front of the real rotation. As a priority
		-- rule it is simulated like everything else: it wins out of combat because nothing
		-- above it applies, and it simply never matches once the fight starts.
		name = "Stealth before the pull",
		spellKey = "stealth",
		requiresSpell = "stealth",
		conditions = { { type = "stealthed" } },
		when = function(S, A)
			return not S.inCombat and not S.stealthed
		end
	},
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
	-- PROC GLOW -> TRACKED BUFF. The spell activation overlay carries no secrecy flags
	-- at all, so when Blizzard lights up a button we get an exact, per-spellID proc
	-- signal that survives combat -- which is the only reliable way to see Opportunity
	-- and Audacity now that aura payloads are secret.
	--
	-- Keyed by the spellID whose BUTTON glows, valued by the buff key it implies.
	-- Opportunity glows Pistol Shot; Audacity glows Ambush.
	overlayAuras = {
		[SPELLS.pistolShot] = "opportunity",
		[SPELLS.ambush]     = "audacity",   -- aura 386270; 381845 is the TALENT, not an aura
	},

	-- ROLL THE BONES STAGE BUFFS.
	-- 315508 is the castable ability and applies NO aura of its own -- reading it was
	-- why stage sat at 0 forever and the addon told you to reroll a Jackpot every 45s.
	-- In 12.x RtB applies ONE named summary aura whose identity IS the stage.
	--
	-- 1214933 "One of a Kind" = stage 1, captured from a live 12.1.0 client
	-- (/tuono record auras after a roll). The other three -- Double Trouble, Triple
	-- Threat, Jackpot -- are still unknown because a roll only produces one at a time.
	-- They are NOT guessed here; RtBLearner discovers them from play and writes them to
	-- SavedVariables, and until then an unrecognised post-roll aura is treated as
	-- "a stage buff of unknown stage", which is safe (see the reroll rule).
	-- All four confirmed from SimC's midnight branch (sc_rogue.cpp:10270-10273), and
	-- stage 1 independently confirmed from a live 12.1.0 client capture -- the two
	-- agreeing on 1214933 is what makes the other three trustworthy.
	-- Note Jackpot is 1214937; 1214936 is NOT in the sequence.
	--
	-- Stages are strictly CUMULATIVE: Jackpot carries all four effects. A recast expires
	-- all four and applies exactly one fresh, so exactly one is ever up.
	rtbStageBuffs = {
		[1214933] = 1,   -- One of a Kind    +20% SS double-strike / Opportunity chance
		[1214934] = 2,   -- Double Trouble   +1 CP on SS & Ambush, +15% their damage
		[1214935] = 3,   -- Triple Threat    +30% Restless Blades CDR
		[1214937] = 4,   -- Jackpot          +10% crit
	},
	rtbDuration = 30,
	-- Keep It Rolling adds 30s but cannot push total remaining past 60s (server bug,
	-- modelled in SimC since 2022-12-12).
	rtbExtendCap = 60,

	-- Run these through C_Secrets.GetSpellAuraSecrecy at load. If a stage buff comes
	-- back NeverSecret it can be read in full IN COMBAT -- stacks, expiry and all --
	-- which would close the Roll the Bones hole outright rather than approximating it.
	auraProbeList = { 1214933, 1214934, 1214935, 1214937 },

	-- SPELL IDS THAT MAY HAVE BEEN RENUMBERED. SimC resolves Roll the Bones by NAME
	-- because the ID moved in Midnight: SpecializationSpells has zero rows for 315508,
	-- while 1214909 is row 7256 under spec 260 (Outlaw). Six spells still share the
	-- name "Roll the Bones", so a name lookup alone is ambiguous.
	--
	-- Rather than swap blindly on secondary evidence, list the candidates and let the
	-- client decide at load: whichever the character actually KNOWS wins. That is
	-- correct whichever ID this build really uses, and it self-heals if Blizzard moves
	-- it again.
	spellAliases = {
		rollTheBones = { 1214909, 315508 },
	},

	-- Buff spellIDs the state tracker should follow for this spec.
	trackedAuras = {
		{ key = "adrenalineRush", spellID = SPELLS.adrenalineRush },
		{ key = "rtb",            spellID = SPELLS.rollTheBones },
		{ key = "opportunity",    spellID = SPELLS.opportunity },
		{ key = "stealthed",      spellID = SPELLS.stealth },
	},
})
