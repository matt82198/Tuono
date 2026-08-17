# INVERSION

The design thesis of this addon. `EnergyModel.lua` cites this document by section; it had
never been written down. This is the reconstruction, taken from the code that already
implements it.

---

## 1. The inversion

Every other rotation addon asks the client **"what is my energy?"**. Midnight answers with
a secret, and the addon is dead.

Tuono never asks. It **runs its own model of energy** and corrects it against signals the
client will always answer. The hidden value is never read, so whether it is hidden stops
mattering.

That is the inversion:

> **Do not read state. Model it, and correct the model against never-secret observations.**

The consequence worth internalising: **secrecy is not a problem to be defended against.**
It is a property of a channel we deliberately do not use. `EnergyModel.lua:301` says it
outright —

> Nothing here asks WHICH values are secret. Feed it whatever observations exist and it
> tightens; starve it and it widens to [0, max] and the rotation falls back to
> cooldown-driven logic on its own.

There is no branch anywhere in the energy model that says "if energy is hidden then". If
Blizzard hides more, the interval widens. If Blizzard unhides something, it tightens. The
model does not change either way. **A design that has to be told what is secret is not
inverted.**

## 1a. What a "secret" actually is — taint, not absence

VERIFIED from a live 12.1.0 error report, 2026-08-17. Blizzard's own
`Blizzard_CooldownViewer` threw:

```
CooldownViewer.lua:987: attempt to perform arithmetic on field 'startTime'
(a secret number value, while execution tainted by 'CooldownManagerCentered')

spellCooldownInfo = {
  modRate   = <secret number>
  isEnabled = true
  startTime = <secret number>
  isActive  = false
  duration  = <secret number>
}
```

Read that carefully, because it corrects the obvious mental model. Blizzard's own code
performs arithmetic on `startTime` every frame without incident. It threw **only because
execution was tainted by an addon**. The value is not absent and it is not encrypted — it
is *operable by untainted code and inoperable by tainted code*.

Three consequences that matter:

1. **Addon code is tainted by definition.** There is no cleverness that recovers the
   value directly, ever. The inversion is not a workaround for a temporary limitation; it
   is the only approach available to an addon, permanently.
2. **Blizzard deliberately left decision-grade predicates non-secret.** `isEnabled` and
   `isActive` came back as plain booleans in the same table whose numbers were secret.
   `C_Spell.IsSpellUsable` likewise returns a plain boolean. These are choices, not
   oversights — the raw quantity is withheld while the *answer an addon actually needs*
   is handed over. Building on them is using the surface as designed. (Whether recovering
   a precise value from MANY such predicates is equally intended is a separate and less
   settled question; see STATE.md.)
3. **Taint is contagious and it breaks Blizzard's code, not just yours.** The error above
   is an addon causing a denial of service in a Blizzard UI component, 52 times. This is
   why `Highlight.lua` anchors its own frame to an action button and never writes to one,
   and why `tests/lint_codegen.lua` gates `hooksecurefunc` and friends.

Also confirmed incidentally: the timer fields were secret while `isActive` was **false**,
so cooldown secrecy is not gated on the cooldown running. And Blizzard's own
`MIN_GLOBAL_RECOVERY_TIME` appeared in the locals as `0.750000`, independently confirming
the `GCD_FLOOR = 0.75` constant in `CooldownModel.lua`.

## 2. Why reading loses, structurally

A read is a single point in time that either succeeds or fails, and failure carries no
information. Worse, the failure mode is *intermittent*: an aura query that works out of
combat and fails in it produces a value that blinks.

A blinking input produces a blinking output. That is not a bug in the consumer — a rule
gated on a value correctly enters and leaves the priority walk as that value appears and
disappears. Measured on a live 69-second trace: the Roll the Bones stage was readable on
**27%** of ticks, and each transition legitimately reordered the recommendation. The
addon looked broken because it was faithfully reporting a broken sensor.

A model does not blink. It is a function of accumulated observations and elapsed time,
both of which are monotone. **Inverting a quantity converts an intermittent sensor into a
continuous estimate**, and that is usually a bigger win than the accuracy itself.

## 3. The three inversions already built

**Energy** (`EnergyModel.lua`). Never read. Bounded from both sides by
`C_Spell.IsSpellUsable`, which is never-secret: an ability that is usable proves
`energy >= cost` (lower bound); one reporting `insufficientPower` proves `energy < cost`
(upper bound). Outlaw's cost ladder 15/25/35/40/45/50 gives six tripwires across the
range. A *crossing* — unaffordable last sample, affordable now — collapses the interval to
a single exact value. Two crossings with a known spend ledger solve for the regen rate
itself:

```
regen = (cost2 - cost1 + spent) / dt
```

which retires the haste read (secret since 12.0.5) and the Combat Potency guess in one
move. Measured live: interval width median **0.2** energy.

**Cooldowns** (`CooldownModel.lua`). Timers are secret in combat. The remainder is not
hidden, it is *derivable*: `remaining = (castAt + duration - accumulatedCDR) - now`, where
the cast is observed, the duration is static profile data, and Restless Blades CDR is
combo points spent — which are never secret. Corrected every tick against the one boolean
Blizzard still answers, `isEnabled`/`isActive`. The file states the generalisation
directly: *"the same inversion as the energy bracket, applied to time instead of resource"*.

**Procs** (`Observers.lua`). Aura payloads are secret; the spell-activation overlay — "your
button is glowing" — carries no secrecy flags at all, fires on both edges, and carries a
plain readable spellID. So proc presence is observed through the glow rather than read from
the aura.

## 4. The recipe

To invert a quantity `X`:

1. **Find the transitions you can observe.** Casts (`UNIT_SPELLCAST_SUCCEEDED` carries a
   readable spellID), errors (`UI_ERROR_MESSAGE`), glows, never-secret booleans, aura
   *cardinality* (identity without semantics). The player's own actions are an observation
   channel — a successful cast proves you could afford it; a failed one plus an
   out-of-power error proves you could not.
2. **Find the constants.** Ability costs, base cooldowns, buff durations, resource caps.
   These are static data, not state, and are never secret.
3. **Integrate forward** from the last transition using elapsed time — `GetTime()` is
   never secret.
4. **Correct on every observation.** Observations only ever *tighten*; time only ever
   *widens*.
5. **Report the width.** See §5.

If a step needs a value you can only get by reading hidden state, you have not inverted it
— you have added a fallback. Fallbacks blink.

## 5. Certainty is an output, not an assumption

A single number for a value you did not measure is a lie with a decimal point on it. Carry
the uncertainty and hand it to the UI.

Affordability is therefore **three-valued**, not boolean: `yes` (provably affordable),
`no` (provably not), `maybe` (the interval straddles the cost). The rotation only ever
needs the answer, never the underlying number — which is what makes the whole model
substitutable.

Prediction steps are rated by **provenance** — what the firing rule actually depended on —
not by how far down the list they sit. A step derived entirely from combo points and
cooldown readiness is not less true because it is in slot 4.

## 6. Soundness rules

These are the invariants. Violating one is a permanent, silent corruption; everything else
is merely inaccurate.

**6.1 — A bound may only be tightened by an observation, never by an inference.**
Specifically: **no path may raise `E.lo` except from a never-secret observation.** A lower
bound above the truth cannot be recovered from — every affordability question below it
answers `yes` forever, and the model will confidently recommend things the player cannot
cast. An upper bound that is too low merely suppresses a suggestion, which is recoverable.
The asymmetry is deliberate and it is why `refreshRegenBounds` centres its band
*asymmetrically*: procs only ever add, so the honest band sits slightly below the reported
rate and up to one Combat Potency average above it.

**6.2 — Time widens, observation tightens. Never the reverse.**
An estimate that gets more confident as it ages is fabricating.

**6.3 — A contradiction means an assumption broke; reset around the fresh observation.**
Do not carry an impossible interval forward, and do not silently discard the new evidence
to preserve the old.

**6.4 — Unknown is never "no".**
A value that could not be read is not a negative. This codebase has shipped that defect
six separate times — it emptied the bar, suppressed the whole rotation, and told players to
reroll a Jackpot every 45 seconds. Fail open, lower the confidence, and say so.
**But note the ordering: inverting a quantity is the better fix, because a modelled value
is rarely unknown in the first place.** Guards are the fallback, not the goal.

**6.5 — Never claim a precision you did not measure.**
If the remainder was inferred rather than observed, do not draw a countdown for it and do
not let the simulator decrement it as though it were real.

## 7. Not yet inverted

Tracked so the gap is visible rather than rediscovered.

- **Roll the Bones stage.** Still *read*: `Observers.ResolveRtbStage` re-queries the aura
  every tick, and that query fails in combat. This is the single largest remaining source
  of instability. It is straightforwardly invertible — the stage is fixed at the moment of
  the roll, the duration is a known constant (`rtbDuration = 30`, `rtbExtendCap = 60`), and
  nothing else changes it. Identify once at the transition, then integrate.
- **Buff expiry inside the simulation.** `Predict` advances virtual time without ageing
  buffs, so a 4-step lookahead can recommend a proc-gated ability on a proc that expired at
  step 2.
- **Buff maintenance.** Not modelled at all. Blizzard's own assist recommended Instant
  Poison for an entire recorded trace because the player's weapon poison had lapsed; Tuono
  had nothing to say about it.
