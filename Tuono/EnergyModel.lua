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

local function readHasteMultiplier()
	if _G.GetHaste then
		local ok, haste = pcall(_G.GetHaste)
		if ok then
			local h, known = Tuono.readNum(haste)
			if known and h then return 1 + (h / 100) end
		end
	end
	return 1
end

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

	-- Never measured at all: we have nothing to integrate from.
	if E.confidence == "unknown" and E.lastSyncAt == 0 then
		return
	end

	if last <= 0 then return end
	local dt = now - last
	if dt <= 0 then return end
	-- A long gap (loading screen, /reload, afk) makes the estimate meaningless.
	if dt > 5 then
		E.confidence = "unknown"
		return
	end

	E.value = math.min(E.max, E.value + Tuono.Energy.RegenPerSecond() * dt)
	E.confidence = "estimated"
	E.driftSeconds = now - E.lastSyncAt
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

	if E.confidence ~= "unknown" then
		E.value = math.max(0, E.value - cost)
		E.confidence = "estimated"
	end
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

Tuono.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(event, unit, castGUID, spellID)
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
