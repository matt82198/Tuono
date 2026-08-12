local ADDON_NAME, Tuono = ...

-- ============================================================================
-- SHADOW ENERGY MODEL
-- ============================================================================
-- Energy is the one resource Outlaw needs that Midnight hides UNCONDITIONALLY:
-- UnitPower("player", Energy) carries the SecretWhenUnitPowerRestricted predicate with
-- no restriction gate, unlike every sibling predicate which names combat/encounter/
-- keystone/PvP explicitly. Combo points are a SECONDARY resource and stay readable, and
-- UnitPowerMax is readable, so energy is the only hole -- but it is the hole that gates
-- every affordability decision in the priority list.
--
-- THE APPROACH (player's design): stop trying to READ energy and instead SHADOW it.
-- We never touch a secret. We integrate our own model forward from inputs that are all
-- plainly readable:
--
--   * what we cast, and when   -- UNIT_SPELLCAST_SUCCEEDED carries a readable spellID
--   * what each cast costs     -- our own ABILITIES table
--   * elapsed time             -- GetTime() is never secret
--   * haste                    -- a character stat, not combat state
--   * the energy ceiling       -- UnitPowerMax is never secret
--
-- NOTE ON THE KEYBIND VARIANT: hooking keypresses is strictly worse than this. A
-- keypress is not a cast (it can be out of range, on cooldown, interrupted, or eaten by
-- the GCD), hardware-event hooking is restricted, and it would miss casts made by
-- clicking or by macro. UNIT_SPELLCAST_SUCCEEDED is the same signal with none of those
-- failure modes: it fires only for casts that ACTUALLY happened, and its spellID is
-- readable. Same idea, better sensor.
--
-- LEGALITY: this reads no protected value and automates no input. It is a client-side
-- estimate built from the player's own actions -- the same thing a human does in their
-- head. Blizzard's stated position is that rotation helpers are not inherently harmful;
-- what is disallowed is reading the hidden state, which this deliberately does not do.
--
-- HONESTY: the estimate DRIFTS (Combat Potency is stochastic, and Adrenaline Rush is
-- itself inferred from our own cast rather than read from the aura). The model reports
-- its own confidence and the UI must degrade that into the display rather than present
-- an estimate as a measurement.
-- ============================================================================

Tuono.Energy = {
	value = 0,
	max = 100,
	-- "measured"  = read directly from the API this tick (out of combat, or if Blizzard
	--               ever unhides it). Trustworthy.
	-- "estimated" = integrated forward from casts + time since the last measurement.
	-- "unknown"   = never had a measurement to seed from; do not gate anything on this.
	confidence = "unknown",
	lastSyncAt = 0,
	lastAdvanceAt = 0,
	arUntil = 0,
	driftSeconds = 0
}

local E = Tuono.Energy

-- Outlaw energy constants. Base regen is 10/sec scaled by haste; Adrenaline Rush adds
-- +60%; Combat Potency contributes off-hand-proc energy that is stochastic, so it is
-- modelled as a flat average and is the single largest source of drift.
local BASE_REGEN = 10
local AR_REGEN_MULTIPLIER = 1.6
local COMBAT_POTENCY_AVG = 2.5
local AR_DURATION = 20
local MAX_DRIFT_BEFORE_LOW_CONFIDENCE = 8

-- ============================================================================
-- HASTE IS CONDITIONALLY SECRET AS OF 12.0.5
-- ============================================================================
-- GetHaste carries SecretWhenUnitStatsRestricted -- it was readable at Midnight launch
-- and was locked down in 12.0.5, so anything written against early-Midnight behaviour
-- is now silently degraded.
--
-- The old code fell back to a multiplier of 1, i.e. "this character has 0% haste".
-- That is the same fail-silent mistake as reading unreadable energy as zero: it is not
-- a neutral default, it is a specific and wrong claim, and it made the regen model
-- systematically underestimate for every geared character.
--
-- Haste is a GEAR stat, not combat state. It does not meaningfully change mid-pull
-- (procs aside), so the last value read OUT of combat is a far better estimate than
-- zero. We cache it and keep using it, and report which source we are on.
E.lastKnownHaste = 0
E.hasteSource = "unread"

-- Runtime authority beats a hardcoded assumption -- Blizzard has already moved this
-- once mid-expansion, so ask rather than assume.
function Tuono.Energy.StatsAreSecret()
	if _G.C_Secrets and _G.C_Secrets.ShouldUnitStatsBeSecret then
		local ok, res = pcall(_G.C_Secrets.ShouldUnitStatsBeSecret)
		if ok then
			local b, known = Tuono.readBool(res)
			if known then return b end
		end
	end
	return nil   -- cannot tell
end

local function readHasteMultiplier()
	if _G.GetHaste then
		local ok, haste = pcall(_G.GetHaste)
		if ok then
			local h, known = Tuono.readNum(haste)
			if known and h and h >= 0 then
				E.lastKnownHaste = h
				E.hasteSource = "measured"
				return 1 + (h / 100)
			end
		end
	end

	-- Unreadable. Carry the last real reading rather than asserting zero.
	E.hasteSource = (E.lastKnownHaste > 0) and "cached" or "unknown"
	return 1 + (E.lastKnownHaste / 100)
end

-- Out of combat is when stats are readable, so refresh the cache at every boundary.
Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", function() readHasteMultiplier() end)
Tuono.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() readHasteMultiplier() end)
Tuono.RegisterEvent("PLAYER_ENTERING_WORLD", function() readHasteMultiplier() end)

local function abilityCost(spellID)
	local abilities = Tuono.Rotation and Tuono.Rotation.ABILITIES
	if not abilities then return nil end
	local ab = abilities[spellID]
	if not ab then return nil end
	return ab.cost or 0
end

-- Is Adrenaline Rush believed active? Prefer the real aura when the aura layer actually
-- read it; otherwise fall back to our own shadow window opened when we saw AR cast.
local function arActive()
	local buffs = Tuono.State and Tuono.State.buffs
	if buffs and buffs.adrenalineRush and buffs.adrenalineRush.up then
		return true
	end
	return GetTime() < (E.arUntil or 0)
end

function Tuono.Energy.RegenPerSecond()
	local rate = BASE_REGEN * readHasteMultiplier()
	if arActive() then
		rate = rate * AR_REGEN_MULTIPLIER
	end
	return rate + COMBAT_POTENCY_AVG
end

-- ============================================================================
-- ENERGY BRACKETING VIA IsSpellUsable
-- ============================================================================
-- The dead-reckoning above drifts, because Combat Potency is stochastic. This is the
-- correction, and it is a MEASUREMENT rather than an estimate.
--
-- C_Spell.IsSpellUsable(spellID) -> isUsable, insufficientPower. It is flagged
-- never-secret, so unlike UnitPower it still answers in combat. Costs come from
-- C_Spell.GetSpellPowerCost, which is static data and also never secret.
--
-- Together they bracket the hidden value from both sides:
--   costliest ability still usable        -> energy >= that cost   (lower bound)
--   cheapest ability short on power       -> energy <  that cost   (upper bound)
--
-- Outlaw's cost ladder is 15 / 25 / 35 / 40 / 45, so this pins energy into a band
-- every frame without ever reading the secret. The wider the ability set, the tighter
-- the band.
--
-- ASYMMETRY IN WHAT WE TRUST:
-- `isUsable == false` is NOT evidence of low energy -- a spell is also unusable when
-- unlearned, out of range, or lacking a target. Only `insufficientPower == true` is
-- specifically about resources, so only that sets the upper bound. Conversely
-- `isUsable == true` does prove affordability, so it safely sets the lower bound.
-- Cooldowns do not affect isUsable, so a spell on cooldown still reports honestly.
-- ============================================================================

local bracketCostCache = {}

-- Energy cost for a spell, preferring the live API over our profile table so a talent
-- that changes a cost does not silently invalidate the bracket.
local function energyCostOf(spellID)
	local cached = bracketCostCache[spellID]
	if cached ~= nil then return cached end

	local cost = nil
	local energyType = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3
	if C_Spell and C_Spell.GetSpellPowerCost then
		local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
		if ok and type(costs) == "table" then
			for _, entry in ipairs(costs) do
				if type(entry) == "table" and entry.type == energyType then
					local c, known = Tuono.readNum(entry.cost)
					if known and c and c > 0 then cost = c end
				end
			end
		end
	end
	if cost == nil then
		cost = abilityCost(spellID)
		if cost == 0 then cost = nil end
	end

	bracketCostCache[spellID] = cost or false
	return cost
end

-- Only spells that actually COST energy can constrain the bracket. Iterating the whole
-- profile meant calling IsSpellUsable on Stealth and the Opportunity buff every tick --
-- 14 calls where 8 would do, and the extras can never contribute a bound. Computed once
-- per profile activation.
local costingSpells = nil

local function costingSpellList()
	if costingSpells then return costingSpells end
	costingSpells = {}
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	if not profile then return costingSpells end
	for _, spellID in pairs(profile.spells or {}) do
		if energyCostOf(spellID) then table.insert(costingSpells, spellID) end
	end
	table.sort(costingSpells)
	return costingSpells
end

if Tuono.Profiles then
	Tuono.Profiles.OnActivate(function()
		costingSpells = nil
		-- Talents change spell costs, and this cache is keyed by spellID with no
		-- lifecycle of its own, so it has to go too.
		for k in pairs(bracketCostCache) do bracketCostCache[k] = nil end
	end)
end

-- Same invalidation on anything that can retalent or restat the character.
for _, evt in ipairs({ "TRAIT_CONFIG_UPDATED", "SPELLS_CHANGED", "PLAYER_SPECIALIZATION_CHANGED" }) do
	Tuono.RegisterEvent(evt, function()
		costingSpells = nil
		for k in pairs(bracketCostCache) do bracketCostCache[k] = nil end
	end)
end

-- ============================================================================
-- INTERVAL STATE  --  the secret-agnostic core
-- ============================================================================
-- The point estimate above is retained for compatibility, but this is the real model.
--
-- A single number for a hidden value is a lie with a decimal point on it. Carry an
-- INTERVAL instead: energy is somewhere in [lo, hi). Time WIDENS it (regen is itself
-- only known within bounds); observations TIGHTEN it. The interval can never be wrong,
-- only wide -- and "wide" is a state the UI can render honestly.
--
-- Nothing here asks WHICH values are secret. Feed it whatever observations exist and
-- it tightens; starve it and it widens to [0, max] and the rotation falls back to
-- cooldown-driven logic on its own. That is what makes it secret-agnostic: no branch
-- anywhere says "if energy is hidden then". Blizzard can hide or unhide anything and
-- the only consequence is interval width.
--
-- THRESHOLD EDGES ARE EXACT MEASUREMENTS.
-- IsSpellUsable's insufficientPower flag flips at the moment energy crosses that
-- ability's cost. Outlaw's ladder is 15/25/35/40/45/50, so there are six tripwires
-- across the range. A flip from unaffordable to affordable means energy passed exactly
-- that cost, at that instant -- lo == hi == cost. This is the same idea as the Feral
-- "Waiting for Energy" sentinel, except it exists for every spec and needs no
-- cooperation from Blizzard's rotation table.
--
-- AND TWO EDGES SOLVE REGEN.
-- Between two upward crossings with a known spend ledger, everything but the rate is
-- observed: regen = (cost2 - cost1 + spent) / dt. That retires the haste read (secret
-- since 12.0.5) and the Combat Potency guess in one move.
-- ============================================================================

E.lo = 0
E.hi = 0
E.intervalSeeded = false

-- Regen carried as an interval too, because it is inferred rather than read. Seeded
-- wide enough to cover unhasted-no-procs through Adrenaline-Rush-with-haste, then
-- narrowed by measurement.
E.regenLo = 8
E.regenHi = 40

local lastUsable = {}          -- spellID -> insufficientPower on the previous sample
local lastEdge = nil           -- { cost, at, spentSince }

function Tuono.Energy.Interval()
	if not E.intervalSeeded then return nil, nil end
	return E.lo, E.hi
end

-- Three-valued affordability. This, not a number, is what the rotation actually needs.
--   "yes"   -- provably affordable
--   "no"    -- provably not
--   "maybe" -- the interval straddles the cost; say so rather than guessing
-- Bounds are INCLUSIVE: energy is in [lo, hi].
function Tuono.Energy.AffordState(cost)
	if not cost or cost <= 0 then return "yes" end
	if not E.intervalSeeded then return "maybe" end
	if E.lo >= cost then return "yes" end
	if E.hi < cost then return "no" end
	return "maybe"
end

local function widen(dt)
	if not E.intervalSeeded then return end
	local cap = E.max > 0 and E.max or 100
	E.lo = math.min(cap, E.lo + E.regenLo * dt)
	E.hi = math.min(cap, E.hi + E.regenHi * dt)
end

local function debit(cost)
	if not E.intervalSeeded then return end
	E.lo = math.max(0, E.lo - cost)
	E.hi = math.max(0, E.hi - cost)
	if lastEdge then lastEdge.spentSince = (lastEdge.spentSince or 0) + cost end
end

-- Intersect the interval with an observed bound. This is the only thing that ever
-- makes the estimate tighter.
local function intersect(lo, hi)
	local cap = E.max > 0 and E.max or 100
	if not E.intervalSeeded then
		E.lo, E.hi = lo or 0, hi or cap
		E.intervalSeeded = true
		return
	end
	if lo and lo > E.lo then E.lo = lo end
	if hi and hi < E.hi then E.hi = hi end
	-- A contradiction means an assumption broke (a cost changed under us, a proc made
	-- something free). Trust the fresh observation and reset the width around it
	-- rather than carrying an impossible interval forward.
	if E.lo > E.hi then
		E.lo = lo or 0
		E.hi = math.max(E.lo, hi or cap)
	end
end

-- Record an exact crossing and, if we have a previous one, solve for regen.
local function recordEdge(cost, now)
	if lastEdge and lastEdge.cost then
		local dt = now - lastEdge.at
		if dt >= 0.3 and dt <= 20 then
			local rate = (cost - lastEdge.cost + (lastEdge.spentSince or 0)) / dt
			if rate >= 3 and rate <= 60 then
				-- Converge the regen interval on the measurement rather than replacing
				-- it outright: one sample can be distorted by an unobserved proc.
				E.regenLo = E.regenLo + (rate - E.regenLo) * 0.35
				E.regenHi = E.regenHi + (rate - E.regenHi) * 0.35
				if E.regenLo > E.regenHi then E.regenLo, E.regenHi = E.regenHi, E.regenLo end
				-- Keep a floor of uncertainty; a perfectly known rate is another lie.
				local mid = (E.regenLo + E.regenHi) / 2
				E.regenLo = math.min(E.regenLo, mid - 0.5)
				E.regenHi = math.max(E.regenHi, mid + 0.5)
				E.regenSamples = (E.regenSamples or 0) + 1
				E.measuredRegen = mid
			end
		end
	end
	lastEdge = { cost = cost, at = now, spentSince = 0 }
	E.anchors = (E.anchors or 0) + 1
end

-- ============================================================================
-- THE PLAYER'S OWN ACTIONS ARE AN OBSERVATION CHANNEL
-- ============================================================================
-- Two exact bounds we were discarding, both free, both derived from things the player
-- did rather than from anything hidden:
--
--   A SUCCESSFUL CAST proves you could afford it. UNIT_SPELLCAST_SUCCEEDED carries a
--   readable spellID, so at that instant energy >= cost. We were debiting the cost but
--   never recording the lower bound it implies -- throwing away the tightest
--   observation in the whole system, on every single cast.
--
--   A FAILED CAST FOR WANT OF POWER proves the opposite: energy < cost. The client
--   emits UI_ERROR_MESSAGE with the localized out-of-energy string, and
--   UNIT_SPELLCAST_FAILED carries the spellID. Correlated within a frame or two, that
--   is an exact upper bound handed to us by the player's own misclick.
--
-- Neither reads a protected value. Both are the same trick as the IsSpellUsable
-- bracket: a never-secret signal that happens to be a function of a secret one.
-- ============================================================================

local noPowerAt = 0
local NO_POWER_WINDOW = 0.35

-- Compare against the client's own localized constant rather than an English literal,
-- so this works on every locale without a translation table.
local function isOutOfPowerMessage(msg)
	if type(msg) ~= "string" then return false end
	local outOfEnergy = _G.SPELL_FAILED_NO_POWER or _G.ERR_OUT_OF_ENERGY
	if outOfEnergy and msg == outOfEnergy then return true end
	-- Some builds format the generic "not enough <resource>" string; fall back to the
	-- energy-specific one if it exists.
	local generic = _G.ERR_NOT_ENOUGH_ENERGY
	return generic ~= nil and msg == generic
end

Tuono.RegisterEvent("UI_ERROR_MESSAGE", function(event, errorType, message)
	if isOutOfPowerMessage(message) then
		noPowerAt = GetTime()
	end
end)

-- A cast that FAILED while an out-of-power error was fresh bounds energy from above.
Tuono.RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", function(event, unit, castGUID, spellID)
	local id = Tuono.readNum(spellID)
	if not id then return end
	if (GetTime() - noPowerAt) > NO_POWER_WINDOW then return end
	-- CONSUME the flag: one error message corresponds to ONE failed cast. Leaving it
	-- armed let a single out-of-power error taint every unrelated failure in the next
	-- third of a second -- out of range, line of sight, facing -- each of which would
	-- have been recorded as false evidence that energy was low.
	noPowerAt = 0

	local cost = energyCostOf(id)
	if not cost or cost <= 0 then return end
	-- Could not afford it => energy < cost => inclusive upper bound is cost-1.
	intersect(nil, cost - 1)
	E.observations = (E.observations or 0) + 1
end)

-- Sample every costing ability and fold the result into the interval.
function Tuono.Energy.Observe()
	if not (C_Spell and C_Spell.IsSpellUsable) then return false end
	local now = GetTime()
	local lo, hi = nil, nil
	local sawAny = false

	for _, spellID in ipairs(costingSpellList()) do
		local cost = energyCostOf(spellID)
		if cost then
			local ok, usable, insufficient = pcall(C_Spell.IsSpellUsable, spellID)
			if ok then
				local isUsable = Tuono.readBool(usable)
				local noPower = Tuono.readBool(insufficient)

				-- BOTH BOUNDS ARE INCLUSIVE: energy is in [lo, hi].
				-- insufficientPower at cost c proves energy < c, so the inclusive upper
				-- bound is c-1, NOT c. Storing c made AffordState(c) answer "maybe" when
				-- it could prove "no" -- off by exactly one, in the direction that
				-- discards information. Energy is integral, so c-1 is exact.
				if noPower == true then
					sawAny = true
					local bound = cost - 1
					if hi == nil or bound < hi then hi = bound end
				elseif isUsable == true then
					sawAny = true
					if lo == nil or cost > lo then lo = cost end
				end

				-- EDGE: unaffordable last sample, affordable now => energy just crossed
				-- this exact cost. The tightest observation available anywhere, and it
				-- collapses the interval to a single value.
				local was = lastUsable[spellID]
				if was == true and noPower == false then
					intersect(cost, cost)
					recordEdge(cost, now)
				end
				if noPower ~= nil then lastUsable[spellID] = noPower end
			end
		end
	end

	if not sawAny then return false end
	intersect(lo, hi)
	E.driftSeconds = 0
	E.lastSyncAt = now
	return true
end

-- Returns lower, upper (either may be nil when no ability constrains that side).
function Tuono.Energy.Bracket()
	if not (C_Spell and C_Spell.IsSpellUsable) then return nil, nil end
	local profile = Tuono.Profiles and Tuono.Profiles.Active()
	if not profile then return nil, nil end

	local lower, upper = nil, nil

	for _, spellID in ipairs(costingSpellList()) do
		local cost = energyCostOf(spellID)
		if cost then
			local ok, usable, insufficient = pcall(C_Spell.IsSpellUsable, spellID)
			if ok then
				local isUsable = Tuono.readBool(usable)
				local noPower = Tuono.readBool(insufficient)

				if noPower == true then
					if upper == nil or cost < upper then upper = cost end
				elseif isUsable == true then
					if lower == nil or cost > lower then lower = cost end
				end
			end
		end
	end

	return lower, upper
end

-- Usability only changes when a resource crosses a cost threshold or a cooldown turns
-- over, and WoW fires events for exactly that. Polling every ability every tick was
-- pure waste: ~14 API calls at 10Hz to re-derive a value that mostly did not move.
--
-- Event-driven, with a slow safety poll so a missed event degrades accuracy rather
-- than correctness. The floor is well below the timescale energy moves on (~12/sec,
-- so 0.25s is ~3 energy of staleness -- inside the bracket's own resolution anyway).
local BRACKET_MIN_INTERVAL = 0.25
local bracketDueAt = 0

local function markBracketDue()
	bracketDueAt = 0
end

for _, evt in ipairs({ "SPELL_UPDATE_USABLE", "ACTIONBAR_UPDATE_USABLE", "SPELL_UPDATE_COOLDOWN" }) do
	Tuono.RegisterEvent(evt, markBracketDue)
end
Tuono.RegisterUnitEvent("UNIT_POWER_UPDATE", "player", markBracketDue)

-- Fold the bracket into the running estimate. Only ever CLAMPS -- it never invents a
-- value, so a spec whose abilities do not span the range degrades to plain dead
-- reckoning rather than to nonsense.
-- Scheduling lives at the CALL SITE, not in here. ApplyBracket is also the "correct me
-- now" entry point (diagnostics, tests, a forced resync), and a function that silently
-- does nothing depending on a hidden clock is a trap for every caller that is not the
-- tick loop.
function Tuono.Energy.BracketIsDue()
	return GetTime() >= bracketDueAt
end

function Tuono.Energy.ApplyBracket()
	bracketDueAt = GetTime() + BRACKET_MIN_INTERVAL

	local lower, upper = Tuono.Energy.Bracket()
	if lower == nil and upper == nil then return false end

	-- A contradictory bracket (lower >= upper) means something upstream is lying --
	-- a stale cost, a talent-swapped ability, an unlearned spell reporting usable.
	-- Trust neither side rather than clamping to a value we know is wrong.
	if lower and upper and lower >= upper then return false end

	local before = E.value
	if lower and E.value < lower then E.value = lower end
	if upper and E.value >= upper then E.value = math.max(0, upper - 1) end

	E.lastBracket = { lower = lower, upper = upper }

	if E.value ~= before then
		E.corrections = (E.corrections or 0) + 1
	end
	-- A bracketed value is measured evidence, not extrapolation, so the drift clock
	-- resets: this is as good as a direct read for decision-making purposes.
	E.driftSeconds = 0
	E.lastSyncAt = GetTime()
	if E.confidence == "unknown" then
		-- Bracketing can COLD-START the model. Without a real read we would otherwise
		-- never have a seed, and dead reckoning would stay disabled forever.
		E.value = lower or math.max(0, (upper or 1) - 1)
	end
	E.confidence = "bracketed"
	return true
end

-- ============================================================================
-- SENTINEL ANCHORING  +  MEASURED REGEN
-- ============================================================================
-- The bracket bounds energy every frame but only to a band, and the band is widest
-- (45..max) exactly when everything is affordable. Blizzard's "Waiting for Energy"
-- sentinel gives something the bracket cannot: an EXACT value, occasionally.
--
-- While the sentinel is showing, energy is BY DEFINITION the blocker -- that is what
-- the placeholder means. The instant it clears, GetNextCastSpell returns the ability
-- it was waiting for. If energy had already been at or above that ability's cost the
-- sentinel would not have been showing, so at the moment of the transition:
--
--     energy == cost(newly returned spell)
--
-- We do not know the cost during the wait; we learn it retroactively on the clear.
--
-- WHY THIS IS WORTH MORE THAN THE ANCHOR ITSELF:
-- Two consecutive exact anchors let us MEASURE the regen rate rather than assume it.
-- Between anchors every other term is known -- the casts we saw and their costs, and
-- elapsed time -- so:
--
--     regen = (C2 - C1 + sum(costs spent between)) / dt
--
-- That retires COMBAT_POTENCY_AVG, a hardcoded 2.5 guess which is the single largest
-- source of drift in this model. It also absorbs haste, Adrenaline Rush and trinket
-- procs for free, since it measures the effective rate rather than deriving it.
--
-- STALENESS CAVEAT: the assist pick can lag a completed cast by up to ~1 GCD, so the
-- clear edge may arrive slightly late and bias the anchor low relative to true energy.
-- Observations are therefore sanity-bounded rather than trusted outright, and the
-- measured rate is smoothed instead of replaced outright by any single sample.
-- ============================================================================

local MIN_OBS_DT = 0.5           -- shorter than this and timing noise dominates
local MAX_OBS_DT = 15            -- longer and an unobserved cast has probably crept in
local MIN_PLAUSIBLE_REGEN = 5    -- below base regen: something is wrong with the sample
local MAX_PLAUSIBLE_REGEN = 60   -- well above AR+haste ceiling: reject
local REGEN_SMOOTHING = 0.25     -- weight of each new observation

E.measuredRegen = nil            -- nil until we have a plausible observation
E.regenSamples = 0
E.anchor = nil                   -- { value, at, spentSince }
E.wasWaiting = false

-- Record a cast against the OPEN anchor window, so the regen solve knows what left the
-- pool between the two exact points.
local function accrueSpend(cost)
	if E.anchor then
		E.anchor.spentSince = (E.anchor.spentSince or 0) + cost
	end
end

local function observeRegen(newValue, now)
	local a = E.anchor
	if not a then return end

	local dt = now - a.at
	if dt < MIN_OBS_DT or dt > MAX_OBS_DT then return end

	-- Everything but the rate is known between two exact points.
	local rate = (newValue - a.value + (a.spentSince or 0)) / dt
	if rate < MIN_PLAUSIBLE_REGEN or rate > MAX_PLAUSIBLE_REGEN then return end

	if E.measuredRegen == nil then
		E.measuredRegen = rate
	else
		E.measuredRegen = E.measuredRegen * (1 - REGEN_SMOOTHING) + rate * REGEN_SMOOTHING
	end
	E.regenSamples = (E.regenSamples or 0) + 1
end

-- Called once per tick with the current assist state.
function Tuono.Energy.ObserveAssist()
	local A = Tuono.Assist
	if not A then return end

	local waiting = A.waitingForResource == true
	local wasWaiting = E.wasWaiting
	E.wasWaiting = waiting

	-- Only the FALLING edge carries information: sentinel -> real recommendation.
	if not (wasWaiting and not waiting) then return end

	local spellID = A.nextSpellID
	if not spellID then return end

	local cost = energyCostOf(spellID)
	if not cost or cost <= 0 then return end   -- a free ability anchors nothing

	local now = GetTime()

	observeRegen(cost, now)

	E.value = cost
	E.confidence = "anchored"
	E.lastSyncAt = now
	E.driftSeconds = 0
	E.anchor = { value = cost, at = now, spentSince = 0 }
	E.anchors = (E.anchors or 0) + 1
end

-- Effective regen: the measured rate when we have one, otherwise the modelled guess.
function Tuono.Energy.EffectiveRegen()
	if E.measuredRegen then return E.measuredRegen end
	return Tuono.Energy.RegenPerSecond()
end

-- Attempt a real read. Returns true when a hard measurement landed.
function Tuono.Energy.TrySync()
	local powerType = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3

	local maxVal, maxKnown = Tuono.readNum(UnitPowerMax("player", powerType))
	if maxKnown and maxVal and maxVal > 0 then
		E.max = maxVal
	end

	local cur, curKnown = Tuono.readNum(UnitPower("player", powerType))
	if curKnown and cur then
		E.value = cur
		E.confidence = "measured"
		E.lastSyncAt = GetTime()
		E.driftSeconds = 0
		-- A DIRECT READ IS THE TIGHTEST POSSIBLE OBSERVATION: collapse the interval onto
		-- it. Without this the interval ignored the one case where we actually know the
		-- answer exactly, and every affordability question stayed "maybe" out of combat.
		E.lo, E.hi = cur, cur
		E.intervalSeeded = true
		return true
	end
	return false
end

-- Integrate the model forward to now. Safe to call every tick.
function Tuono.Energy.Advance()
	local now = GetTime()
	local last = E.lastAdvanceAt
	E.lastAdvanceAt = now

	-- A direct read always wins over the model.
	if Tuono.Energy.TrySync() then
		return
	end

	-- Integrate forward FIRST, then correct. Order matters: bracketing clamps whatever
	-- the model currently believes, so applying it before regen would immediately be
	-- undone by this tick's regen and the correction would never stick.
	local hadSeed = not (E.confidence == "unknown" and E.lastSyncAt == 0)

	if hadSeed and last > 0 then
		local dt = now - last
		if dt > 5 then
			-- A long gap (loading screen, /reload, afk) makes the estimate meaningless.
			E.confidence = "unknown"
		elseif dt > 0 then
			-- Measured rate when we have one; the modelled guess only until then.
			E.value = math.min(E.max, E.value + Tuono.Energy.EffectiveRegen() * dt)
			E.confidence = "estimated"
			E.driftSeconds = now - E.lastSyncAt
		end
	end

	-- Ordering is deliberate, weakest evidence first so the strongest wins:
	--   integrate -> bracket (a band) -> sentinel anchor (an exact value)
	--
	-- The anchor runs last because it is the only signal that pins a number rather
	-- than bounding one. Running it before the bracket would let a band clamp away an
	-- exact measurement, which is backwards.

	-- IsSpellUsable-derived bounds. This both corrects accumulated drift and can COLD
	-- START the model when energy has never once been directly readable -- which is the
	-- normal case in Midnight, where UnitPower is secret unconditionally. Without it,
	-- a player who logs in mid-combat would have no seed and stay "unknown" forever.
	-- Throttled here rather than inside ApplyBracket: this is the only caller that wants
	-- rate limiting. Usability is event-driven (SPELL_UPDATE_USABLE et al reset the
	-- timer), so this is a safety poll, not the primary trigger.
	-- Interval model: widen by elapsed time, then tighten on observation.
	if last > 0 then
		local dt = now - last
		if dt > 0 and dt <= 5 then widen(dt) end
	end
	if Tuono.Energy.BracketIsDue() then
		pcall(Tuono.Energy.Observe)
		pcall(Tuono.Energy.ApplyBracket)
	end

	pcall(Tuono.Energy.ObserveAssist)
end

-- Debit a cast from the model. Called from UNIT_SPELLCAST_SUCCEEDED.
function Tuono.Energy.OnCast(spellID)
	if not spellID then return end

	if spellID == (Tuono.SpellIDs and Tuono.SpellIDs.adrenalineRush) then
		E.arUntil = GetTime() + AR_DURATION
	end

	local cost = abilityCost(spellID)
	if not cost or cost <= 0 then return end

	-- Opportunity makes Pistol Shot free; the proc flag is readable often enough to be
	-- worth honouring, and over-debiting is the more damaging error (it suppresses
	-- suggestions the player can actually afford).
	if spellID == (Tuono.SpellIDs and Tuono.SpellIDs.pistolShot) then
		local opp = Tuono.State and Tuono.State.buffs and Tuono.State.buffs.opportunity
		if opp and opp.up then cost = 0 end
	end

	-- ORDER MATTERS: the cast SUCCEEDED, so immediately before it energy was at least
	-- the cost. Record that lower bound BEFORE debiting, or the evidence is destroyed
	-- by the very subtraction it should have informed.
	intersect(cost, nil)
	E.observations = (E.observations or 0) + 1

	debit(cost)

	if E.confidence ~= "unknown" then
		E.value = math.max(0, E.value - cost)
		E.confidence = "estimated"
	end

	-- Book the spend against the open anchor window regardless of confidence: the regen
	-- solve needs the full ledger of what left the pool between two exact points, and
	-- dropping spends here would make the measured rate read systematically low.
	accrueSpend(cost)
end

-- Public accessor. Returns (value, isUsable, confidence).
-- isUsable is false while confidence is "unknown", so callers can distinguish
-- "0 energy" from "no idea" -- the distinction the old Tuono.num(x, 0) destroyed.
function Tuono.Energy.Get()
	if E.confidence == "unknown" then
		return 0, false, "unknown"
	end
	local stale = E.driftSeconds > MAX_DRIFT_BEFORE_LOW_CONFIDENCE
	return E.value, true, (stale and "stale" or E.confidence)
end

Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, castGUID, spellID)
	if unit ~= "player" then return end
	local id, known = Tuono.readNum(spellID)
	if known and id then
		Tuono.Energy.OnCast(id)
	end
end)

-- Combat boundaries are the best resync opportunities: out of combat the value is
-- readable on most builds, and a fresh combat should not inherit stale drift.
Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", function()
	Tuono.Energy.TrySync()
end)

Tuono.RegisterEvent("PLAYER_REGEN_DISABLED", function()
	Tuono.Energy.TrySync()
end)

Tuono.RegisterEvent("PLAYER_ENTERING_WORLD", function()
	E.arUntil = 0
	Tuono.Energy.TrySync()
end)
