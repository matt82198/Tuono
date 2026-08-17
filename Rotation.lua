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
-- SimC finishes at cp_max_spend - 1, not at a flat 6:
--   variable,name=finish_condition,value=combo_points>=cp_max_spend-1-(...)
-- The old min(6, cpMax) happened to be right at a 7-point cap (Deeper + Devious
-- Stratagem) but demanded 6 at the far more common 6-point cap, delaying every
-- finisher by a GCD and overcapping whenever Sinister Strike double-struck.
local function finisherThreshold(S)
	local mx = S and S.comboPointsMax
	if type(mx) ~= "number" or mx < 1 then mx = 6 end
	return math.max(1, mx - 1)
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

-- ---------------------------------------------------------------------------
-- ROLL THE BONES STAGE, TRI-STATE
-- ---------------------------------------------------------------------------
-- `stage` reads 0 both when there is genuinely no Roll the Bones buff AND when we
-- simply cannot see one, so no caller may read it without also asking whether it is
-- known. Returns (stage, known); stage is nil whenever known is false.
local function rtbStage(S)
	local rtb = S and S.buffs and S.buffs.rtb
	if not rtb then return nil, false end
	if rtb.stageKnown == false then return nil, false end
	local stage = rtb.stage
	if type(stage) ~= "number" then return nil, false end
	return stage, true
end

-- BOTH RtB RULES SPEND A COOLDOWN, so both are positive claims and both must fail
-- closed on an unreadable stage. Rerolling a stage we cannot see is how the addon came
-- to tell players to reroll a Jackpot every 45 seconds.
--
-- These exist as HELPERS rather than as an inline guard in each rule specifically
-- because the inline version diverged: the single-target list carried the guard, the
-- AoE list was written later without it, and the AoE list is the one that ran. A shared
-- helper cannot be half-applied.
local function rtbStageBelow(S, n)
	local stage, known = rtbStage(S)
	if not known then return false end
	return stage < n
end

local function rtbStageAtLeast(S, n)
	local stage, known = rtbStage(S)
	if not known then return false end
	return stage >= n
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

-- Affordability is a THREE-VALUED question, and the rotation only ever needed the
-- answer -- never the underlying number.
--
--   "yes"   provably affordable
--   "no"    provably not
--   "maybe" the interval straddles the cost
--
-- Live state defers to the interval model, whose bounds come from the never-secret
-- IsSpellUsable oracle. Simulated steps carry their own interval forward
-- arithmetically. Nothing here reads a hidden value, and nothing branches on WHICH
-- values are hidden: starve it of observations and the interval widens to [0, max],
-- every answer becomes "maybe", and the priority list degrades to cooldown-driven
-- logic on its own.
function Tuono.Rotation.AffordState(S, spellID)
	if not spellID then return "yes" end
	local ability = ABILITIES[spellID]
	if not ability then return "no" end
	if (ability.cost or 0) == 0 then return "yes" end
	if ignoreEnergy then return "yes" end

	if S and S.energyLo and S.energyHi then
		if S.energyLo >= ability.cost then return "yes" end
		if S.energyHi < ability.cost then return "no" end
		return "maybe"
	end

	if Tuono.Energy and Tuono.Energy.AffordState then
		return Tuono.Energy.AffordState(ability.cost)
	end
	return "maybe"
end

-- Boolean face for rule closures. "maybe" PASSES: an unprovable answer must not
-- suppress a recommendation -- that is exactly what emptied the bar when secret energy
-- read as zero. The uncertainty is not discarded, it is carried into the confidence
-- rating, so a maybe-affordable step renders as "bounded" rather than solid.
local function canAfford(S, spellID)
	return Tuono.Rotation.AffordState(S, spellID) ~= "no"
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
	rtbStage = rtbStage,
	rtbStageBelow = rtbStageBelow,
	rtbStageAtLeast = rtbStageAtLeast,
}

-- ---------------------------------------------------------------------------
-- Simulation internals
-- ---------------------------------------------------------------------------

-- ============================================================================
-- SIMULATION SCRATCH STATE
-- ============================================================================
-- This was a full recursive deep copy of Tuono.State on EVERY Predict, i.e. every tick:
-- ~18 tables and ~150 field copies, including knownSpells (40+ entries) and rtb.names,
-- neither of which the simulation ever mutates. At 10Hz that is thousands of table
-- allocations a second, all of it garbage.
--
-- Predict only ever WRITES a small, fixed set of fields. Everything else it merely
-- reads, and can read straight off the live state. So keep one persistent scratch
-- table and reset the mutable fields in place -- zero allocation in steady state.
--
-- The read-only fields are assigned by reference deliberately: the simulation must not
-- write to them, and if a future rule does, that is a bug worth surfacing rather than
-- hiding behind a defensive copy.
local scratch = {
	cooldowns = {},
	buffs = { rtb = {}, opportunity = {}, adrenalineRush = {} },
}

local function deepCopyState(state)
	local S = scratch

	-- THE VIRTUAL CLOCK. Every simulated press costs a GCD, so a 4-step lookahead reaches
	-- several seconds into the future. Buff expiry timestamps are absolute, so the
	-- simulation needs its own "now" to compare them against. Reset per call: it is
	-- mutable per-run state living on a scratch table that is deliberately reused, and a
	-- leak here would make Predict answer differently for identical input.
	S.simNow = GetTime()

	-- Scalars the simulation mutates.
	S.energy = state.energy
	S.energyMax = state.energyMax

	-- Seed the simulation's energy INTERVAL from the live model. Steps then carry it
	-- forward with interval arithmetic rather than pretending to a point value, so a
	-- later step whose affordability genuinely straddles the bound is reported as
	-- uncertain instead of guessed.
	if Tuono.Energy and Tuono.Energy.Interval then
		S.energyLo, S.energyHi = Tuono.Energy.Interval()
	else
		S.energyLo, S.energyHi = nil, nil
	end
	S.energyKnown = state.energyKnown
	S.energySource = state.energySource
	S.comboPoints = state.comboPoints
	S.comboPointsMax = state.comboPointsMax
	S.comboPointsKnown = state.comboPointsKnown
	S.stealthed = state.stealthed
	S.enemyCount = state.enemyCount
	S.enemyCountKnown = state.enemyCountKnown
	S.inCombat = state.inCombat

	-- Read-only passthrough: never written by the simulation.
	S.knownSpells = state.knownSpells
	S.knownUnavailable = state.knownUnavailable
	S.tier = state.tier
	S.trinkets = state.trinkets

	-- Cooldowns ARE mutated (pooling decrements them, finishers apply CDR), so each
	-- entry needs its own scratch row -- but the rows are reused, not reallocated.
	local srcCD = state.cooldowns or {}
	for key, cd in pairs(srcCD) do
		local row = S.cooldowns[key]
		if not row then row = {} S.cooldowns[key] = row end
		row.known = cd.known
		row.ready = cd.ready
		row.remaining = cd.remaining
		row.remainingKnown = cd.remainingKnown
	end
	-- Drop scratch rows for cooldowns the live state no longer tracks (profile swap),
	-- otherwise a stale row would answer for an ability this spec does not have.
	for key in pairs(S.cooldowns) do
		if srcCD[key] == nil then S.cooldowns[key] = nil end
	end

	local srcBuffs = state.buffs or {}
	S.buffs.degraded = srcBuffs.degraded

	local rtb = srcBuffs.rtb or {}
	S.buffs.rtb.stage = rtb.stage
	S.buffs.rtb.stageKnown = rtb.stageKnown
	S.buffs.rtb.expires = rtb.expires
	S.buffs.rtb.names = rtb.names          -- read-only; not copied

	-- fromOverlay and stacksKnown are PROVENANCE, and rateRule runs against this scratch
	-- copy, not against the live state. Omitting them meant every simulated step rated its
	-- buff dependency off the global `degraded` flag -- which is nearly always true in
	-- combat -- so the whole lookahead came back "unknown" no matter how well the overlay
	-- channel was actually tracking the proc.
	local opp = srcBuffs.opportunity or {}
	S.buffs.opportunity.up = opp.up
	S.buffs.opportunity.stacks = opp.stacks
	S.buffs.opportunity.expires = opp.expires
	S.buffs.opportunity.fromOverlay = opp.fromOverlay
	S.buffs.opportunity.stacksKnown = opp.stacksKnown

	local ar = srcBuffs.adrenalineRush or {}
	S.buffs.adrenalineRush.up = ar.up
	S.buffs.adrenalineRush.expires = ar.expires
	S.buffs.adrenalineRush.fromOverlay = ar.fromOverlay
	S.buffs.adrenalineRush.stacksKnown = ar.stacksKnown

	return S
end

-- Restless-Blades-style CDR: 1.0s per CP, 1.3s during RtB stage 3.
local function applyCDR(cpSpent, rtbStage)
	-- Stages are CUMULATIVE: Stage 4 (Jackpot) includes Stage 3 (Triple Threat), so an
	-- equality test silently dropped the bonus at the best stage.
	return cpSpent * (((rtbStage or 0) >= 3) and 1.3 or 1.0)
end

local function calcGCD(hasteBuffUp)
	return hasteBuffUp and 0.8 or 1.0
end

-- Interval regen for the simulation. Regen is itself only known within bounds (haste is
-- secret since 12.0.5, Combat Potency is stochastic), so elapsed time makes the interval
-- WIDER, not merely higher. That widening IS the honest representation of a forward
-- prediction losing certainty the further out it reaches -- and it is why a step-4
-- affordability question can legitimately answer "maybe" while step 1 answers "yes".
local function widenSim(S, maxEnergy, dt)
	if not (S and S.energyLo and S.energyHi) then return end
	local lo, hi = 8, 40
	if Tuono.Energy then
		lo = Tuono.Energy.regenLo or lo
		hi = Tuono.Energy.regenHi or hi
	end
	S.energyLo = math.min(maxEnergy, S.energyLo + lo * dt)
	S.energyHi = math.min(maxEnergy, S.energyHi + hi * dt)
end

local function calcEnergyRegen(hasteBuffUp)
	local base = 10
	if hasteBuffUp then base = base * 1.6 end
	return base + 2.5   -- Combat Potency average
end

-- Adrenaline Rush raises the ceiling and hastes the GCD. Both were sampled ONCE before
-- the step loop, which was fine while nothing could change them mid-simulation. Now that
-- buffs lapse against the virtual clock, they have to be asked per step or a simulation
-- that outlives the buff keeps spending its bonus.
local function maxEnergyFor(S)
	local ar = S and S.buffs and S.buffs.adrenalineRush
	return (ar and ar.up) and 150 or 100
end

local function hasteBuffUp(S)
	local ar = S and S.buffs and S.buffs.adrenalineRush
	return (ar and ar.up) and true or false
end

-- ============================================================================
-- BUFF EXPIRY INSIDE THE SIMULATION
-- ============================================================================
-- `expires` is an ABSOLUTE GetTime() timestamp. The simulation advances a virtual clock
-- past it -- four predicted presses are four GCDs into the future -- so every step must
-- be judged against that advanced instant, not against the moment Predict was called.
-- deepCopyState has always COPIED expires; nothing ever compared it. The result was a
-- wheel that recommended Pistol Shot on an Opportunity which had lapsed two steps
-- earlier, and the per-GCD commitment layer now HOLDS such a step rather than churning
-- past it.
--
-- FAILS OPEN ON AN UNREADABLE EXPIRY. Midnight hides aura payloads, so expires is
-- frequently 0 or nil -- which under a naive comparison is indistinguishable from
-- "expired long ago". Treating that as expired would silently delete every proc-gated
-- step in real combat: the unknown-as-no defect, which this codebase has shipped
-- repeatedly. Only a POSITIVE, readable timestamp is allowed to end a buff.
local function expireBuffs(S, now)
	local buffs = S and S.buffs
	if not buffs then return end
	for _, b in pairs(buffs) do
		-- `degraded` is a boolean living alongside the buff tables; skip anything that is
		-- not a buff record.
		if type(b) == "table" then
			local exp = b.expires
			if type(exp) == "number" and exp > 0 and exp <= now then
				if b.up then b.up = false end
				if b.stacks then b.stacks = 0 end
				-- Roll the Bones carries a stage rather than an up flag. Its expiry is a
				-- genuine drop to no-buff, and stageKnown stays true because we PROVED it
				-- from a readable timestamp rather than failing to read one.
				if b.stage then b.stage = 0 end
			end
		end
	end
end

-- ============================================================================
-- ADVANCE THE VIRTUAL CLOCK BY dt
-- ============================================================================
-- This body used to exist twice, byte for byte -- once in the pooling loop and once
-- after a cast. That is the exact duplication shape that produced the Roll the Bones
-- divergence (one copy got the guard, the other did not), so it is one function now.
local function advanceTime(S, dt)
	local cap = maxEnergyFor(S)
	S.energy = math.min(cap, S.energy + calcEnergyRegen(hasteBuffUp(S)) * dt)
	widenSim(S, cap, dt)

	for _, cdData in pairs(S.cooldowns) do
		-- A REMAINDER WE NEVER MEASURED MUST NOT BE COUNTED DOWN.
		--
		-- When the client hides a cooldown's timer, CooldownModel parks the ability at a
		-- placeholder remainder and StateTracker flags it remainingKnown = false
		-- (StateTracker.lua:147). Decrementing that placeholder exactly like a
		-- measurement is how a 180-second Adrenaline Rush came to read "ready" at step 2
		-- -- rendered `certain`, because readiness normally IS exactly knowable. A
		-- confidently wrong step is the worst output this addon can produce.
		--
		-- This deliberately does NOT suppress the ability: readiness itself is never
		-- secret, so step 1 still answers from ground truth and a cooldown the client
		-- reports as ready is still recommended. Only the invented FUTURE turnover is
		-- refused. We decline to name a moment we cannot know rather than guessing one.
		if cdData.remaining and cdData.remaining > 0 and cdData.remainingKnown ~= false then
			cdData.remaining = math.max(0, cdData.remaining - dt)
			if cdData.remaining <= 0 then cdData.ready = true end
		end
	end

	S.simNow = (S.simNow or GetTime()) + dt
	expireBuffs(S, S.simNow)

	-- Adrenaline Rush lapsing drops the ceiling from 150 back to 100, so an energy value
	-- that was legal an instant ago is now above the cap. Clamp rather than carry an
	-- impossible number into the next step's affordability arithmetic.
	local newCap = maxEnergyFor(S)
	if newCap < cap then
		S.energy = math.min(S.energy, newCap)
		if S.energyLo then
			S.energyLo = math.min(S.energyLo, newCap)
			S.energyHi = math.min(S.energyHi, newCap)
		end
	end
end

-- Exclude a rule ONLY when we explicitly probed and learned the player lacks the spell.
-- nil means "never probed" -> fail OPEN, because hiding a player's whole rotation on a
-- missing probe is far worse than one stray icon.
-- FAIL OPEN WHEN THE KNOWN-SPELL API ITSELF IS UNAVAILABLE.
--
-- knownSpells[id] == false means "the client told us the character does not have this".
-- But when the probe could not run at all, StateTracker sets knownUnavailable and every
-- entry is stale -- at which point a `false` is not the client's answer, it is our own
-- failed read looking exactly like one. Suppressing the whole rotation on that is the
-- unknown-as-no bug in its purest form, and Evaluate's own castability filter already
-- has this exemption. The simulator did not, so with the legacy PREFER rules gone -- they
-- had been re-inserting the suppressed spells from outside -- the gap became reachable.
local function buildActivePriorityList(priorityList, knownSpells, spells, knownUnavailable)
	local active = {}
	for _, rule in ipairs(priorityList) do
		local reqID = rule.requiresSpell
		if type(reqID) == "string" then reqID = spells[reqID] end
		if not reqID or knownUnavailable or knownSpells[reqID] ~= false then
			table.insert(active, rule)
		end
	end
	return active
end

-- ============================================================================
-- PROVENANCE-BASED CONFIDENCE
-- ============================================================================
-- Confidence used to be assigned by INDEX -- `step >= 4 -> low` -- which is arbitrary
-- and has no relationship to whether we actually knew anything. A step derived entirely
-- from combo points and cooldown readiness (both exactly readable) is not less true
-- because it sits in slot 4; a step gated on Roll the Bones stage is a guess even in
-- slot 1.
--
-- So rate each step by WHAT THE FIRING RULE DEPENDED ON, and take the weakest input.
-- This is the VSUP principle applied properly: bind visual resolution to uncertainty,
-- not to horizon. The two only coincide for addons whose sole input is Blizzard's
-- next-cast scalar; ours has real state behind it, of varying quality.
--
--   certain  -- every input exactly readable (combo points, cooldown ready, stealth,
--               enemy count). Render solid, whatever the slot.
--   bounded  -- depends on energy, which we bracket rather than read. Real bounds, but
--               a threshold near the bracket edge is a coin flip.
--   unknown  -- depends on an aura or RtB stage that is hidden in combat. Say so.
--
-- Depth is deliberately NOT folded in here. Later steps do assume you follow the
-- sequence, but that is a conditional, not missing knowledge, and the display already
-- encodes it by drawing slot 1 larger.
local CONF_RANK = { certain = 3, bounded = 2, unknown = 1 }

local function weakest(a, b)
	if (CONF_RANK[b] or 1) < (CONF_RANK[a] or 1) then return b end
	return a
end

local function inputConfidence(cond, S, ownKey)
	local t = cond and cond.type
	if t == nil or t == "always" or t == "stealthed" then return "certain" end

	if t == "cp" then
		return cpIsKnown(S) and "certain" or "unknown"
	elseif t == "cdReady" or t == "cdReadyOf" then
		-- cdReady is self-referential to the rule's own spell; cdReadyOf names another.
		local key = (t == "cdReadyOf") and cond.spell or ownKey
		local cd = key and S.cooldowns and S.cooldowns[key]
		-- Readiness survives secret timers via the never-secret booleans, so a known
		-- cooldown is a CERTAIN input even when its countdown is hidden.
		if cd and cd.known then return "certain" end
		return "unknown"
	elseif t == "enemyCount" then
		return (S.enemyCountKnown ~= false) and "certain" or "unknown"
	elseif t == "energy" then
		return energyKnown(S) and "bounded" or "unknown"
	elseif t == "buffUp" then
		-- PER-BUFF PROVENANCE, not the global degraded flag.
		--
		-- `degraded` means "some aura read failed", which in combat is nearly always true
		-- -- payloads are secret. Rating every buff-gated step "unknown" off that flag made
		-- the entire Outlaw rotation unknown in live play, which matters much more now that
		-- the queue TRUNCATES at the first unknown step: the lookahead would have collapsed
		-- to one icon in every real fight, silently reproducing the complaint it was built
		-- to answer.
		--
		-- The overlay channel is the reason it does not have to. A proc glow is a
		-- never-secret event that fires on BOTH edges, so once it has fired for a buff, that
		-- buff's presence is tracked by a live channel regardless of what the aura payload
		-- is doing. Observers already records this as `fromOverlay` and its comment already
		-- claims it "lifts the degraded flag for that specific buff" -- nothing was reading
		-- it. Now something does.
		--
		-- Residual risk: glow events only fire for spells on an action bar. If the spell is
		-- un-barred, no event ever fires and `fromOverlay` is never set, so this degrades to
		-- the flag below rather than going stale -- which is the safe direction.
		local b = S.buffs and cond.spell and S.buffs[cond.spell]
		if type(b) == "table" and b.fromOverlay then return "certain" end
		return (S.buffs and S.buffs.degraded) and "unknown" or "certain"
	elseif t == "rtbStage" then
		local rtb = S.buffs and S.buffs.rtb
		return (rtb and rtb.stageKnown) and "certain" or "unknown"
	end
	return "unknown"
end

-- Rate one firing rule against the live state.
local function rateRule(rule, S, spellID)
	local conf = "certain"

	for _, cond in ipairs(rule.conditions or {}) do
		conf = weakest(conf, inputConfidence(cond, S, rule.spellKey))
	end

	-- Every rule passes through canAfford, so an ability that COSTS something inherits
	-- the energy signal even when its declared conditions never mention energy.
	local ability = spellID and ABILITIES[spellID]
	if ability and (ability.cost or 0) > 0 then
		if not energyKnown(S) then
			conf = weakest(conf, "unknown")
		elseif S.energySource ~= "measured" then
			conf = weakest(conf, "bounded")
		end
	end

	-- A rule with no declared conditions tells us nothing about its own provenance.
	-- Do not award it "certain" by default just because the list is empty.
	if not rule.conditions or #rule.conditions == 0 then
		conf = weakest(conf, "bounded")
	end

	return conf
end

Tuono.Rotation.RateRule = rateRule

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

-- The dwell exists to stop the bar strobing WITHIN a pull. Carrying it ACROSS pulls is
-- a different thing and is wrong: finish an AoE pack, walk to a single-target boss, and
-- the first two seconds of the new fight would still be running the AoE list. Combat
-- end is an unambiguous boundary, so reset there.
function Tuono.Rotation.ResetMode()
	Tuono.Rotation.mode = "single"
	Tuono.Rotation.modeReason = "combat reset"
	belowThresholdSince = nil
end

Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", function() Tuono.Rotation.ResetMode() end)

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

	-- ========================================================================
	-- BLIZZARD'S PICK IS A FALLBACK, NOT AN OVERRIDE
	-- ========================================================================
	-- Its engine can see enemy state Midnight hides from us, which makes it valuable
	-- exactly when our own nameplate count is unreadable -- and redundant when it is not.
	--
	-- This test used to sit ABOVE the count and return unconditionally, so an inferred
	-- signal outranked a direct measurement. Combined with the capability-set bug in
	-- AssistReader (aoeDetected was constant true for any Outlaw with Blade Flurry
	-- talented), that pinned the addon into the AoE priority list permanently -- on every
	-- fight, against any number of targets.
	--
	-- Order is now: explicit pin > direct count > Blizzard's live pick > hold.
	if count == nil then
		if Tuono.Assist and Tuono.Assist.aoeDetected then
			belowThresholdSince = nil
			Tuono.Rotation.mode = "aoe"
			Tuono.Rotation.modeReason = "Blizzard is cleaving (count unreadable)"
			return "aoe"
		end
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

	local priorityList = buildActivePriorityList(sourceList or {}, state.knownSpells or {}, spells, state.knownUnavailable)
	Tuono.Rotation.activeRuleCount = #priorityList

	local result = {}

	for step = 1, steps do
		local spellID, reason = nil, nil
		local poolAttempts, maxPoolAttempts = 0, 3
		local pooledStepOne = false
		local firedRule = nil

		repeat
			for _, rule in ipairs(priorityList) do
				local ok, matched = pcall(rule.when, S, state)
				if ok and matched then
					spellID = ruleSpellID(rule, spells)
					reason = rule.name
					if spellID then firedRule = rule break end
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
				-- Haste is sampled BEFORE the advance, because the length of the interval
				-- being waited through is fixed by the state at its start.
				advanceTime(S, calcGCD(hasteBuffUp(S)))
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
						if id then spellID, reason, firedRule = id, rule.name, rule break end
					end
				end
			end)
			-- Reset unconditionally: a throw inside the loop must not leave affordability
			-- permanently disabled for every later evaluation in the session.
			ignoreEnergy = false
			if ok and spellID then pooledStepOne = true end
		end

		if not spellID then break end

		-- Rate by PROVENANCE, not by slot index. See rateRule above for why.
		local confidence = firedRule and rateRule(firedRule, S, spellID) or "bounded"

		-- Pooling outranks every other label: "you cannot press this yet" matters more
		-- to the player than how sure we are that it is the right choice.
		if pooledStepOne and step == 1 then confidence = "pooling" end

		table.insert(result, {
			spellID = spellID,
			confidence = confidence,
			reason = reason,
			-- Later steps additionally assume you FOLLOW the sequence. That is a
			-- conditional rather than missing knowledge, so it is reported separately
			-- and the display encodes it by size, not by fading.
			assumesPriorSteps = (step > 1),
		})

		-- Apply effects to the virtual state so the NEXT step differs from this one.
		local ability = ABILITIES[spellID]
		if ability then
			S.energy = math.max(0, S.energy - (ability.cost or 0))
			-- Spend moves BOTH bounds; the interval keeps its width.
			if S.energyLo then
				S.energyLo = math.max(0, S.energyLo - (ability.cost or 0))
				S.energyHi = math.max(0, S.energyHi - (ability.cost or 0))
			end

			-- SPEND THEN GENERATE, as two independent steps. This was if/elseif, which
			-- cannot express an ability that does both -- and Killing Spree does: it is a
			-- finishing move that also generates points during the channel.
			local spend = ability.cpSpend or 0
			if spend ~= 0 then
				-- -1 means "spends everything up to the cap". Finishers scale with points
				-- consumed, so a hardcoded 5 or 6 under-credits Restless Blades CDR at a
				-- 6- or 7-point cap.
				local want = (spend < 0) and cpCap(S) or spend
				local cpSpent = math.min(S.comboPoints, want)
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

			-- Generation applies AFTER any spend, so a spend-and-generate ability
			-- (Killing Spree) lands on the right combo-point total.
			if (ability.cpGen or 0) > 0 then
				S.comboPoints = math.min(cpCap(S), S.comboPoints + ability.cpGen)
			end

			-- Consumed procs must not re-fire in the simulation, or the wheel recommends
			-- consecutive Pistol Shots as if Opportunity reset instantly.
			if spellID == spells.pistolShot and S.buffs.opportunity then
				S.buffs.opportunity.up = false
				S.buffs.opportunity.stacks = 0
			end
			-- Ambush breaks stealth, so later steps must not predict it again.
			if spellID == spells.ambush then S.stealthed = false end
				-- ...and Stealth APPLIES it. Without this the opener rule stayed true after its
				-- own step and the simulation emitted "Stealth, Stealth, Stealth" -- the
				-- degenerate case for any rule whose effect the simulator does not model. With
				-- it, the predicted opener is the real one: Stealth, then Ambush.
				if spellID == spells.stealth then S.stealthed = true end
				-- Anything that is not Stealth STARTS THE FIGHT. Stealth is a pre-pull action,
				-- not a rotation step, so without this the sequence cycled Ambush -> Stealth ->
				-- Ambush forever: Ambush broke stealth, the opener rule saw an unstealthed rogue
				-- and re-armed. Marking combat retires the opener after the pull, which is what
				-- actually happens, and leaves the rest of the sequence to the real rotation.
				if spellID ~= spells.stealth then S.inCombat = true end

			if (ability.cd or 0) > 0 then
				local cdKey = SPELL_TO_CDKEY[spellID]
				if cdKey then
					local slot = cdOf(S, cdKey)
					slot.remaining = ability.cd
					slot.ready = false
					-- A cooldown the SIMULATION started has a duration we know exactly --
					-- it is static profile data, not a hidden client timer. Say so, or the
					-- scratch row inherits remainingKnown = false from a live cooldown that
					-- was unmeasured, and advanceTime then refuses to count down a value it
					-- has every right to trust.
					slot.remainingKnown = true
				end
			end

			if ability.gcd then
				advanceTime(S, calcGCD(hasteBuffUp(S)))
			end
		end
	end

	return result
end
