local ADDON_NAME, Tuono = ...

-- ============================================================================
-- COOLDOWN RECONSTRUCTION
-- ============================================================================
-- SpellCooldownInfo.startTime and .duration are secret in combat, so the addon has
-- been reporting remainingKnown=false and refusing to draw a countdown. That was the
-- honest thing to do given what it knew -- but it was giving up too early.
--
-- The countdown is not actually hidden. It is DERIVABLE, exactly, from things that are
-- all plainly readable:
--
--   when the ability was cast   -- UNIT_SPELLCAST_SUCCEEDED, readable spellID + GetTime()
--   its base cooldown           -- static profile data, not state at all
--   cooldown reduction          -- Restless Blades is combo points spent x a rate, and
--                                 COMBO POINTS ARE NEVER SECRET
--   whether it is ready NOW     -- .isEnabled / .isActive are flagged NeverSecret
--
--   remaining = (castAt + duration - accumulatedCDR) - now
--
-- Nothing in that expression touches a protected value. This is the same inversion as
-- the energy bracket, applied to time instead of resource: we cannot read the clock, so
-- we run our own and correct it against the one boolean Blizzard still answers.
--
-- THE READINESS BOOLEAN IS THE CORRECTOR, and it is what keeps the model from drifting
-- into fiction:
--   * model says "still on cooldown" but the client says READY  -> we over-estimated
--     (an unobserved reset -- Preparation, a talent proc, a fight-start reset). Collapse
--     to zero immediately.
--   * model says "ready" but the client says ON COOLDOWN        -> we under-estimated
--     (a cast we never saw, a duration that is wrong for this talent build). Hold a
--     small positive remainder and report it as a floor, not a measurement.
--
-- So the model can be WRONG but never SILENTLY wrong: every tick it is checked against
-- ground truth, and disagreement is itself information.
-- ============================================================================

Tuono.CooldownModel = Tuono.CooldownModel or {}
local CM = Tuono.CooldownModel

-- key -> { at = when the cooldown started, duration = effective duration }
local started = {}

-- Combo points as of the last tick. UNIT_SPELLCAST_SUCCEEDED fires AFTER the finisher
-- has already consumed them, so the live value reads 0 at exactly the moment we need
-- to know what was spent. The previous tick's value is the one that matters.
local prevCP = 0

-- Restless Blades: seconds of cooldown reduction per combo point spent. 1.3 while Roll
-- the Bones is at stage 3+ (Triple Threat), otherwise 1.0.
local CDR_PER_CP = 1.0
local CDR_PER_CP_TRIPLE = 1.3

-- ============================================================================
-- GLOBAL COOLDOWN
-- ============================================================================
-- Found in a live trace: Sinister Strike failed 31 times against 14 successes, with
-- exactly 31 "Ability is not ready yet." errors. Sinister Strike has NO cooldown, so
-- "not ready" could only mean the GCD -- and the addon did not model the GCD at all.
-- Worse, cooldownKeys() skips any ability with cd == 0, so SS was never even polled.
--
-- The recommendation was RIGHT. It just was not pressable yet. That distinction is the
-- whole fix: suppressing it would blank the bar for most of every GCD, which is worse.
-- It renders as waiting instead.
--
-- The GCD is derivable without reading anything secret: it starts on a cast we observe,
-- and its length is 1.0s scaled by haste with a 0.75s floor. Haste read live in the
-- trace at 17.8%, and EnergyModel already caches it across the combat boundary where it
-- goes secret.
local GCD_BASE = 1.0
local GCD_FLOOR = 0.75
local gcdUntil = 0

local function currentGCD()
	local haste = 0
	if Tuono.Energy and Tuono.Energy.lastKnownHaste then
		haste = Tuono.Energy.lastKnownHaste or 0
	end
	local d = GCD_BASE / (1 + (haste / 100))
	if d < GCD_FLOOR then d = GCD_FLOOR end
	return d
end

-- Seconds until the GCD ends; 0 when free.
function CM.GCDRemaining()
	local r = gcdUntil - GetTime()
	if r <= 0 then return 0 end
	return r
end

function CM.GCDActive()
	return CM.GCDRemaining() > 0
end

-- Nominal GCD length and the absolute time the current one STARTED.
--
-- Display needs the start, not the remainder. Re-arming a sweep from "0.4s left" on every
-- tick restarts the animation ten times a second, which reads as the icon strobing; an
-- absolute start is idempotent, so the same GCD sets the sweep exactly once.
--
-- These live here rather than in Display because Display was recomputing the haste
-- formula itself, and two GCD models that disagree by a few milliseconds would make the
-- reconstructed start jitter -- defeating the idempotence they exist to provide.
function CM.GCDLength()
	return currentGCD()
end

function CM.GCDStart()
	if gcdUntil <= 0 then return nil end
	return gcdUntil - currentGCD()
end

function CM.NoteGCDFromCast(spellID)
	local abilities = Tuono.Rotation and Tuono.Rotation.ABILITIES
	local ability = abilities and abilities[spellID]
	-- Off-GCD abilities (Adrenaline Rush, Preparation) must not start one.
	if not ability or ability.gcd == false then return end
	gcdUntil = GetTime() + currentGCD()
end

-- Ground truth beats the model: isOnGCD is flagged NeverSecret, so when the client
-- says a spell is merely GCD-blocked we can trust it directly.
function CM.NoteGCDFromCooldownInfo(isActive, isOnGCD)
	local active = Tuono.readBool(isActive)
	local onGCD = Tuono.readBool(isOnGCD)
	if active == true and onGCD == true then
		if gcdUntil <= GetTime() then
			gcdUntil = GetTime() + currentGCD()
		end
	elseif onGCD == false and active == false then
		gcdUntil = 0
	end
end

Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", function() gcdUntil = 0 end)

function CM.NoteTick()
	local cp = Tuono.State and Tuono.State.comboPoints
	if type(cp) == "number" and (Tuono.State.comboPointsKnown ~= false) then
		prevCP = cp
	end
end

-- Apply Restless Blades to every running cooldown.
local function applyCDR(cpSpent)
	if cpSpent <= 0 then return end
	local rtb = Tuono.State and Tuono.State.buffs and Tuono.State.buffs.rtb
	-- Only claim the boosted rate when the stage is actually KNOWN. Assuming the better
	-- rate on an unreadable stage would make every cooldown look shorter than it is.
	local rate = CDR_PER_CP
	if rtb and rtb.stageKnown and (rtb.stage or 0) >= 3 then
		rate = CDR_PER_CP_TRIPLE
	end
	local cdr = cpSpent * rate
	for _, s in pairs(started) do
		-- Only shift entries that hold a real countdown. An inferred entry has no
		-- duration, so reducing its start time expresses nothing -- and would silently
		-- back-date the anchor if a later observation ever gave it one.
		if s.duration ~= nil then
			s.at = s.at - cdr
		end
	end
end

function CM.OnCast(spellID)
	if not spellID then return end
	local abilities = Tuono.Rotation and Tuono.Rotation.ABILITIES
	local map = Tuono.Rotation and Tuono.Rotation.SPELL_TO_CDKEY
	if not (abilities and map) then return end

	local ability = abilities[spellID]
	if not ability then return end

	-- Spending combo points reduces OTHER cooldowns; do this before starting this
	-- ability's own cooldown so it does not reduce itself on the cast that began it.
	local spend = ability.cpSpend or 0
	if spend ~= 0 then
		local want = (spend < 0) and prevCP or spend
		applyCDR(math.min(prevCP, want))
	end

	if (ability.cd or 0) > 0 then
		local key = map[spellID]
		if key then
			started[key] = { at = GetTime(), duration = ability.cd }
		end
	end

	CM.NoteGCDFromCast(spellID)
end

-- Predicted remaining for a key. Returns (remaining, known).
--
-- AN INFERRED ENTRY HAS NO REMAINDER TO PREDICT, and saying so is the whole point.
-- It used to carry a one-second placeholder duration and report it as KNOWN, which made
-- an invented number indistinguishable from a derived one at the only boundary that
-- could still tell them apart. StateTracker trusts `remaining` exactly when this returns
-- known, and Rotation.Predict then decrements that remainder one GCD per simulated step
-- -- so a 180s Adrenaline Rush we never observed reported "ready" two steps into the
-- lookahead, rated `certain`, because `known` was true.
--
-- Returning unknown makes StateTracker fall through to its own not-ready row, whose
-- `remaining` is 0. The simulator only decrements entries above zero, so the ability
-- correctly stays unavailable for the whole lookahead instead of resurrecting itself.
function CM.Predict(key)
	local s = key and started[key]
	if not s then return nil, false end
	if s.duration == nil then return nil, false end
	local remaining = (s.at + s.duration) - GetTime()
	if remaining <= 0 then
		started[key] = nil
		return 0, true
	end
	return remaining, true
end

-- Reconcile the model against the never-secret readiness boolean. `ready` may be nil
-- when even that is unavailable, in which case the model is left alone.
function CM.Reconcile(key, ready)
	if key == nil or ready == nil then return end

	if ready == true then
		-- Ground truth says usable. Whatever we believed, it is off cooldown now --
		-- an unobserved reset (Preparation, a proc, a fight-start wipe of cooldowns).
		started[key] = nil
		return
	end

	-- Ground truth says NOT ready. If the model disagrees, we missed a cast or hold a
	-- wrong duration for this build. Record that a cooldown is running WITHOUT a
	-- duration: we know it is not ready -- the client just said so -- and we genuinely
	-- do not know when it will be.
	--
	-- The old form invented `duration = 1`. Two failures came out of that. The remainder
	-- sawtoothed between 1 and 0 forever, because this branch re-fired the moment the
	-- fake second elapsed and reset `at`; and the fake second was small enough that one
	-- simulated GCD wiped it out, turning any unobserved cooldown into a ready one at
	-- step 2 of the lookahead.
	--
	-- An entry that is ALREADY inferred is left strictly alone. There is nothing to
	-- refresh -- it holds no time -- and rewriting `at` every tick is what produced the
	-- sawtooth.
	local s = started[key]
	if s == nil then
		started[key] = { at = GetTime(), inferred = true }
	elseif s.duration ~= nil and (s.at + s.duration) - GetTime() <= 0 then
		-- We held a real duration and it has run out, yet the client still says the
		-- ability is not ready. Our duration was wrong for this build, or we missed a
		-- later cast. Demote to inferred rather than keep asserting a finished countdown.
		started[key] = { at = GetTime(), inferred = true }
	end
end

function CM.IsInferred(key)
	local s = key and started[key]
	return s ~= nil and s.inferred == true
end

function CM.Reset()
	for k in pairs(started) do started[k] = nil end
end

-- A fresh world means cooldowns we cannot vouch for.
Tuono.RegisterEvent("PLAYER_ENTERING_WORLD", function() CM.Reset() end)

Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, castGUID, spellID)
	local id = Tuono.readNum(spellID)
	if id then CM.OnCast(id) end
end)
