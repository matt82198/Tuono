# Inverting for Accuracy

*The mathematics behind reading a value you are not allowed to read.*

This is the theory under techniques 1 and 2 in
[SECRET-VALUES-FINDINGS.md](SECRET-VALUES-FINDINGS.md), and under every line of
`Tuono/EnergyModel.lua`. It is written to be portable: nothing here is specific to World of
Warcraft, or to energy, or to this addon. It is what you do whenever a system hides a
number but keeps answering questions about it.

The one-sentence version:

> **You never need to read the secret. You need any never-secret *function* of it, and then
> you invert.**

---

## 1. The setup

You cannot read hidden state `x`. You *can* read `y = f(x)` for various never-secret `f`.
Reading `y` tells you

```
        x ∈ f⁻¹(y)
```

the **preimage** of what you observed. You never invert to a point. You invert to a *set*,
and your accuracy is the size of the intersection over every channel you have:

```
        X̂  =  ⋂ fᵢ⁻¹(yᵢ)              accuracy = |X̂|
              i
```

That reframing is the whole thing. Stop asking for the value; start collecting constraints
and intersect them. Each channel on its own may be almost worthless — a single boolean
carries one bit — and the intersection of enough of them can still be tight.

Two properties matter and they pull in opposite directions:

- **Soundness:** the true `x` is always in `X̂`. Never violated, or everything downstream is
  garbage. See §6.
- **Precision:** `|X̂|` is small. Nice to have. Sacrificed freely to protect soundness.

---

## 2. Why intervals

The observation functions available here are **monotone thresholds**, so their preimages
are half-lines, and half-lines are closed under intersection. That makes intervals the
natural representation: cheap, closed under the operations we need, and sound by
construction. An interval can be uselessly wide, but it cannot be *wrong*.

`C_Spell.IsSpellUsable`'s `insufficientPower` flag at cost `c` is literally the indicator
function `1[x < c]`:

```
        insufficientPower = false   →   x ∈ [c, ∞)      (you could afford it)
        insufficientPower = true    →   x ∈ [0, c)      (you could not)
```

One boolean, one bit, one half-line. Outlaw's cost ladder is `{15, 25, 35, 40, 45, 50}`, so
there are six of these — a six-level **quantizer** strapped to a continuous quantity the
client refuses to return.

`Tuono/EnergyModel.lua`:

```lua
E.lo = 0
E.hi = 0
E.intervalSeeded = false
```

---

## 3. The key move: transitions, not levels

Read *statically*, six booleans are mediocre. They localize energy to a bin: past 45, not
yet 50, width 5. That is the quantization floor and no amount of re-reading improves it.

The information is not in the levels. It is in the **crossings**.

At the instant `insufficientPower` flips false at cost `c`, energy is not "somewhere above
`c`". It is `c`:

```
        lo = hi = c            width 0
```

An exact measurement of an unreadable number. You did not read `x`; you observed the moment
`x` equalled something you already knew.

This is **level-crossing sampling**, and it is old. It is how a dual-slope ADC measures
voltage with a comparator and a clock, how a Vernier scale beats the resolution of its own
graduations, how you time a pendulum by when it passes a mark rather than by measuring
where it is. The quantizer's *output* is coarse; the quantizer's *transition times* are not.

```lua
-- Record an exact crossing and, if we have a previous one, solve for regen.
local function recordEdge(cost, now) ... end
```

The residual error is no longer the bin width. It is `r · δt`, where `δt` is the sampling
interval — how long the flip can sit unnoticed. At a 0.1s poll and ~12/sec regen that is
about 1.2, against a bin width of 5–10. Poll faster, measure better.

Measured on a live 12.1.0 client: **mean interval width 2.76** out of a 0-100 range across
113 in-combat ticks, and exactly 0 at each crossing. Under 3% of the range, on a value the
client refuses to return, using only things it was willing to say. It arrived in three
steps -- 7.13, then 3.44, then 2.76 -- as the crossing solve, an out-of-combat regen seed
and per-buff provenance each came online.

---

## 4. Predict and update

Between observations the estimate propagates under bounded dynamics. The rate is itself
only known within bounds, so time makes things *worse*, which is the honest outcome:

```
        predict   [lo, hi]  ←  [ min(cap, lo + r_lo·dt),  min(cap, hi + r_hi·dt) ]
        update    [lo, hi]  ←  [ max(lo, a),              min(hi, b)             ]
        spend     [lo, hi]  ←  [ max(0,  lo − c),         max(0,  hi − c)        ]
```

Width grows linearly at `(r_hi − r_lo)·dt` and collapses on each observation. This is the
predict/update cycle of a Kalman filter with **set-membership** semantics rather than
probabilistic ones — a bounded-error estimator in the Schweppe/Witsenhausen sense. You get
*guaranteed containment* instead of a confidence interval, which is the right trade whenever
a confidently wrong answer costs more than an admittedly vague one. In a rotation helper it
does: a wrong recommendation gets pressed.

Note that `min(cap, …)` is not mere clamping. **Saturation is free information.** Once both
endpoints reach the cap, the width is zero — standing at full energy is self-measuring, with
no observation required at all. Nonlinearity that contracts the state is a gift.

```lua
local function widen(dt)
	local cap = E.max > 0 and E.max or 100
	E.lo = math.min(cap, E.lo + E.regenLo * dt)
	E.hi = math.min(cap, E.hi + E.regenHi * dt)
end
```

### The player is an observation channel

Two exact bounds fall out of things the player did, not from anything hidden:

- **A successful cast proves affordability.** `UNIT_SPELLCAST_SUCCEEDED` carries a readable
  spellID, so at that instant `x ≥ cost`. Debiting the cost without recording that lower
  bound throws away the tightest observation in the system, on every single cast.
- **A failure for want of power proves the opposite:** `x < cost`, hence an inclusive upper
  bound of `cost − 1`. (Inclusive/exclusive matters here and has been got wrong once
  already: `insufficientPower` at cost `c` proves `x < c`, so the inclusive bound is `c − 1`,
  not `c`.)

---

## 5. Second order: differencing out the unknown

Two consecutive crossings, with a known spend ledger `S` accumulated between them:

```
        r = (c₂ − c₁ + S) / Δt
```

The unknown initial condition **cancels**. You never needed to know where energy was — only
that it touched `c₁`, then later touched `c₂`. One equation retires both the `GetHaste` read
(secret since 12.0.5) and the Combat Potency average that was previously a guess.

Error propagates as

```
        δr/r  ≈  δc/Δc  +  δt/Δt
```

Crossing *values* are exact, so `δc = 0` and timing jitter dominates. Longer baselines give
better rate estimates — but only while the ledger stays complete. That tension is exactly
why the code gates the window:

```lua
if dt >= 0.3 and dt <= 20 then
    local rate = (cost - lastEdge.cost + (lastEdge.spentSince or 0)) / dt
    if rate >= 3 and rate <= 60 then
```

Below 0.3s, poll jitter swamps the measurement. Above 20s, an unobserved proc has almost
certainly corrupted `spentSince`. The `3 ≤ rate ≤ 60` guard is a plausibility filter: a
result outside physical bounds means an assumption broke, and a broken assumption must not
be allowed to poison the estimator.

---

## 6. Why it deliberately refuses to converge

This is the part that looks like sloppiness and is the most important code in the file.

```lua
-- Converge the regen interval on the measurement rather than replacing it outright:
-- one sample can be distorted by an unobserved proc.
E.regenLo = E.regenLo + (rate - E.regenLo) * 0.35
E.regenHi = E.regenHi + (rate - E.regenHi) * 0.35
-- Keep a floor of uncertainty; a perfectly known rate is another lie.
local mid = (E.regenLo + E.regenHi) / 2
E.regenLo = math.min(E.regenLo, mid - 0.5)
E.regenHi = math.max(E.regenHi, mid + 0.5)
```

The soundness guarantee in §1 holds **only while the model is complete**, and ours is not:
Combat Potency procs add energy we never observe. So any single crossing may be distorted.

If the filter ever becomes confident enough to *exclude the true value*, soundness is lost
permanently. Every subsequent intersection then narrows around a wrong answer, and because
intersection only ever removes possibilities, the estimator can never recover on its own.
This is covariance collapse — the classic divergence failure of an over-tuned Kalman filter,
and the reason real ones inject process noise they do not strictly believe in.

Two defences:

1. **A floor on width.** Never claim to know the rate exactly. Cheap insurance against a
   single corrupted sample locking in a lie.
2. **Contradiction detection.** If soundness *is* lost, it eventually becomes provable —
   two constraints with an empty intersection:

```lua
-- A contradiction means an assumption broke (a cost changed under us, a proc made
-- something free). Trust the fresh observation and reset the width around it
-- rather than carrying an impossible interval forward.
if E.lo > E.hi then
    E.lo = lo or 0
    E.hi = math.max(E.lo, hi or cap)
end
```

`lo > hi` is not a bug to clamp away. It is the model announcing that one of its premises is
false, and the correct response is to discard history and re-anchor on the newest evidence.

---

## 7. The output is a lattice, not a number

The rotation never asks "how much energy do I have". It asks a *predicate*, and a set-valued
estimate answers predicates on a three-valued lattice:

```lua
function Tuono.Energy.AffordState(cost)
	if E.lo >= cost then return "yes" end
	if E.hi <  cost then return "no"  end
	return "maybe"
end
```

```
        [lo,hi] ⊆ [c,∞)         →  yes        provably affordable
        [lo,hi] ∩ [c,∞) = ∅     →  no         provably not
        otherwise               →  maybe      the interval straddles the threshold
```

This is **abstract interpretation**: an abstract domain answering concrete questions, where
imprecision surfaces as `⊤` (`maybe`) and never as a wrong answer. Every consumer must
handle three cases. That is a real cost, and it is the price of never lying.

It also fixes where uncertainty is allowed to live. A rule that needs an unprovable claim
fails; a rule that only needs a provable one fires. Which way each rule should fail when the
answer is `maybe` is a *design decision per rule*, documented in
[PROFILES.md](PROFILES.md) — see the asymmetry between `cpAtLeast` (fails closed: never
recommend a finisher we cannot verify) and `cpAtMost` (fails open: cooldowns are nearly
always correct on cooldown).

---

## 8. Why this is "secret-agnostic"

No branch anywhere asks *"is this value hidden?"* There is no `if energyIsSecret then`.
Every channel is optional evidence; the estimator consumes whatever arrives.

The consequences follow from the algebra rather than from special-case code:

| Evidence available | Interval | Behaviour |
|---|---|---|
| Crossings + casts + saturation | tight (~0.5) | full rotation, high confidence |
| Casts only | moderate | rotation runs, steps render as `bounded` |
| Nothing | `[0, max]` | every answer `maybe`; falls back to combo points and cooldowns |

Blizzard can hide or unhide anything and the only consequence is interval width. That is
what makes the design durable against a system explicitly built to change — and it is why
the honest caveat in the README matters: bounding a hidden scalar with a never-secret
boolean *is* a declassification channel. If `IsSpellUsable` is ever flagged, this degrades
to the last row of that table. By design, not by patch.

---

## 9. Observability, and when it fails

In control-theory terms the question "can I reconstruct `x` from the outputs?" is
**observability**, and this system is observable only under **persistent excitation** — the
player must keep spending and regenerating so that `x` keeps sweeping across tripwires.

Three regimes:

- **Active combat.** Constant spending, constant crossings. Best case, and the common one.
- **Full energy.** No crossings at all — but saturation pins the interval to `[cap, cap]`.
  Also fine, for free.
- **Hovering between tripwires.** The genuine worst case: no crossing occurs, so width grows
  to the gap between adjacent costs (5–10 for Outlaw) and stops improving.

A spec with a dense cost ladder is more observable than one with a sparse one. That is a
real, quantifiable statement about which specs this technique serves well — and it is
checkable per profile rather than something to assume.

---

## 10. Worked diagnosis: the theory is falsifiable

The value of stating this formally is that it makes wrong behaviour *diagnosable* rather
than merely disappointing. From a live flight-recorder trace:

- the model reported energy `[100, 100]`, source `stale`
- the client raised **"Not enough energy" 13 times**
- **28 of 32** Sinister Strike casts were refused
- **zero** threshold edges were recorded in ~100 seconds of play

Under §2 and §6 that combination is *impossible*. `insufficientPower` at cost `c` must
intersect the interval with `[0, c−1]`, which contradicts `[100, 100]`, which must trip the
`lo > hi` branch and force a re-anchor. It did not.

So this is not a calibration problem — the filter converging on a wrong rate. It is that the
update step is **not connected at all**: pure propagation, saturating at the cap, sitting
there looking confident. Miscalibration and disconnection produce visibly different traces,
and this one is unambiguously the second.

That is the payoff. "The energy model is wrong" is not actionable. "`recordEdge` is never
called, and here is the algebra proving the observation channel cannot be reaching
`intersect`" is a bug with an address.

---

## 11. What a "secret" actually is: taint, not absence

VERIFIED from a live 12.1.0 error report, 2026-08-17 — thrown by Blizzard's *own*
`Blizzard_CooldownViewer`, not by an addon:

```
CooldownViewer.lua:987: attempt to perform arithmetic on field 'startTime'
(a secret number value, while execution tainted by 'CooldownManagerCentered')

spellCooldownInfo = { modRate=<secret>, isEnabled=true,
                      startTime=<secret>, isActive=false, duration=<secret> }
```

Blizzard's own code performs that arithmetic every frame without incident. It threw *only*
because execution was tainted by an addon. So a secret is not an absent value and not an
encrypted one: it is **operable by untainted code and inoperable by tainted code**.

Three consequences for everything above:

1. **Addon code is tainted by definition.** No cleverness recovers `x` directly, ever. The
   inversion is not a workaround for a temporary gap — it is the only approach available to
   an addon, permanently.
2. **Blizzard deliberately left decision-grade predicates non-secret.** `isEnabled` and
   `isActive` came back plain booleans in the same table whose numbers were secret;
   `C_Spell.IsSpellUsable` likewise. The raw quantity is withheld while the *answer an addon
   actually needs* is handed over. Building on those is using the surface as designed. (Whether
   recovering a precise value from *many* such predicates is equally intended is a separate
   and less settled question — see `STATE.md`.)
3. **Taint is contagious and it breaks Blizzard's code, not just yours.** The error above is
   an addon causing a denial of service in a Blizzard UI component, 52 times, in a stack
   trace that names the responsible addon. This is why `Highlight.lua` anchors its own frame
   to an action button and never writes to one, and why `tests/lint_codegen.lua` gates
   `hooksecurefunc` and friends.

Confirmed incidentally: the timer fields were secret while `isActive` was **false**, so
cooldown secrecy is not gated on the cooldown running. And Blizzard's own
`MIN_GLOBAL_RECOVERY_TIME` appeared in the locals as `0.750000`, independently confirming
the `GCD_FLOOR = 0.75` constant in `CooldownModel.lua`.

---

## 12. Not yet inverted

Tracked so the gap stays visible rather than being rediscovered.

- **Roll the Bones stage.** Now modelled (identified once at the roll, integrated forward
  over `rtbDuration`/`rtbExtendCap`, re-reading demoted to a correction channel). Live
  readability went **27% → 92%** of ticks. The prior per-tick *read* was the single largest
  source of bar instability, and §9's observability caveat is exactly why: a blinking sensor
  produces a blinking output, and no amount of downstream damping fixes the sensor.
- **"When", not "whether".** The deepest remaining gap, and it is an inversion one. Every
  affordability question is currently asked in the present tense — `canAfford`,
  `cooldown.ready` — while the interval model can answer *"when will energy reach 45"* as
  precisely as *"is energy above 45"*, because it carries regen bounds. We compute the
  harder quantity and discard it to answer the easier question. Hekili's `TimeToReady`
  (`State.lua:7831`) is the shape: `max(cooldown remains, GCD remains, resource.time_to_X)`.
  See `docs/HEKILI.md`.
- **Buff expiry inside the simulation** is modelled, but only a *positive, readable*
  timestamp may end a buff — `expires` reads 0 or nil whenever the payload is hidden, and
  treating that as expired would delete every proc-gated step in real combat.
- **Buff maintenance** is not modelled at all. Blizzard's own assist recommended Instant
  Poison for an entire recorded trace because the player's weapon poison had lapsed.

---

## Further reading

- **[SECRET-VALUES-FINDINGS.md](SECRET-VALUES-FINDINGS.md)** — what is and is not readable,
  and the four practical techniques this doc formalises.
- **[PROFILES.md](PROFILES.md)** — how rules consume three-valued answers, and how to choose
  which way each rule fails.
- `Tuono/EnergyModel.lua` — the implementation. Every section above maps to a named function.
- `tests/secrets_regression.lua` — 77 assertions that hold the properties above in place,
  including inclusive-bound arithmetic and the contradiction reset.
