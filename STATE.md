# STATE — Tuono

**Date:** 2026-08-17
**Version:** 2.2.1 (imported from live AddOns; no prior VCS)
**HEAD:** `326f882` · **Tests:** 63 passing, full suite green
**Single-writer:** Orchestrator

---

## Intent

Ship a rotation helper that is more accurate than Blizzard's Assisted Combat and more
readable than anything else on a client that hides the state they were designed around.
Position 1 is already right. The remaining problem is that it is not yet *enjoyable*.

## The thesis (locked)

Midnight hides combat state behind secret values. Tuono never reads the hidden value. It
**bounds** it from never-secret signals and carries the width of that bound into the UI.
Certainty is an output, not an assumption.

**This is now the only differentiator in the market, and the market is emptier than we
thought.** Hekili is dead under Midnight (CLEU removal plus secret resources — structural,
not fixable). Everything that replaced it is a presentation layer over Blizzard's Assisted
Combat: HekiLight states outright that "Blizzard controls the rotation logic, HekiLight
only reads and displays it". Blizzard ships **Assisted Highlight** natively since 11.1.7.
Nobody else models resources or expresses uncertainty. See `docs/RESEARCH-MIDNIGHT.md`.

Corollary that should govern UI work: a Tuono that only glows position 1 is a worse copy
of a built-in feature. Occupying the action bar is defensible **only** if it carries what
Blizzard's cannot — lead time and uncertainty.

## Locked decisions

1. **The bar is ours.** Blizzard's pick is a sensor and an AoE signal, never an icon.
2. **The sequence is a causal chain, not a list.** Nothing may reorder or splice it.
3. **Recommendation only.** No input automation. No reading of protected values.
4. **Unknown is never "no".** Fail open, lower confidence, surface it.
5. **Interval over point estimate.**
6. **Truth at the moment you can act on it.** The sequence is frozen while the GCD is
   running (nothing is pressable, and the bar is being *read*) and live when it is free.

---

## Done this session

- **Version control, `/power` layer, `.toc`-driven deploy** (`tools/deploy.ps1`, fails
  closed on a manifest that lists a missing file).
- **Offline test harness.** Loads the addon in real `.toc` order against a WoW API stub.
  63 tests. Includes fail-closed TOC lint, a Lua 5.1 lint (the harness runs 5.4, which
  would otherwise accept code the game rejects), and a secret-read lint.
- **Churn diagnosed and fixed.** `Rotation.Predict` is pure and idempotent; the churn came
  from a *flapping input* — RtB stage readable on only 27% of live ticks, and every flip
  legitimately reorders the sequence. `IntelligenceLayer` now commits the sequence per
  GCD. Position 1 is frozen too: measurement showed it was the largest source of change
  (39 of 40 frames), so exempting it defeated the layer.
- **Five correctness fixes**, each with a failing test written first: the `aoeDetected`
  capability-set bug, and three more copies of the unknown-as-no defect on the RtB stage.
- **Display strobe fixed** (D2/D3): sweeps re-armed ~10×/sec; now keyed on the absolute
  instant a cooldown ends, and position 1's sweep belongs solely to the GCD.
- **Full-suite hang fixed.** `wow_stub.lua` captured `type` *after* overwriting `_G.type`,
  so each `harness.load()` added a stack frame to every `type()` call — quadratic. Every
  suite passed alone, which is what made it confusing.

---

## OPEN DEFECTS, ranked

### CRITICAL

**C1 — `CooldownModel.lua:216`: the inferred-cooldown placeholder is treated as real.**
`Reconcile` re-arms an unobserved cooldown with `duration = 1` on *every* tick, so
`remaining` is pinned near 1.0s and never decays. `remainingKnown = false` correctly stops
Display drawing a number, but the **simulator reads `remaining` directly** and decrements
one GCD per step — so a 180s Adrenaline Rush becomes "ready" at step 2. Worse, it renders
*solid*, because `inputConfidence` rates `cdReady` as `certain` whenever `cd.known` is set.
Confidently wrong is the worst failure this addon can produce. Triggered by any `/reload`
or login mid-fight. Verified end-to-end by execution.

**C2 — `UserRules.lua:109`: compiled user rules drop the RtB stage guard, and they
*replace* the profile's closures.** The moment a user opens the rule editor, the
reroll-a-Jackpot bug returns in full. Verified side by side on identical state: compiled
fires `true`, built-in fires `false`.

**C3 — `UserRules.lua:206`: `GetRows` writes on read.** Opening the editor and changing
nothing permanently forks that user off the built-in profile (`IsCustomised` flips
`false → true` on a pure display call). They silently stop receiving every future APL fix
— including the ones committed today. This quietly breaks the maintenance story for the
most engaged users, and gets worse with every release.

### HIGH

**H1 — Buffs never expire inside the simulation.** `deepCopyState` copies `expires` but
`Predict` advances virtual time without re-checking it. A 4-step lookahead can recommend
Pistol Shot at step 4 on an Opportunity that expired at step 2. The commitment layer will
faithfully preserve steps that are simply wrong.

**H2 — `Highlight.lua:260`: the glow is an opaque green rectangle.** `SetColorTexture`
defaults alpha to 1.0 on a texture that `SetAllPoints` the whole button at `HIGH` strata.
The recommended ability's art is completely hidden. The player is told "press the green
square" and cannot see which spell it is. One-line fix; largest single UX win available.

**H3 — Tuono models no buff maintenance at all.** The 0/127 Blizzard disagreement in the
trace is fully explained: `GetNextCastSpell` returned **315584 = Instant Poison** on every
sample — the player's weapon poison had lapsed. Blizzard caught a real mistake we do not
model. Also means the drift sensor must exclude non-rotation picks before counting
disagreement, or it measures nothing.

**H4 — `Engine.Evaluate` returns `resultQueue` itself and wipes it in place next tick.**
Any consumer holding the previous queue sees it mutate underneath.

**H5 — Confidence encoding collides.** `Display.lua:682` clamps a stalled recommendation
to alpha 0.45 while `unknown` is already 0.4 — so *stalled* and *uncertain* are visually
identical, discarding the stall detector's output exactly when it matters. Pooling renders
at 0.35, *dimmer* than unknown, but pooling is a high-confidence claim. The encoding is
inverted. Root cause: alpha carries three unrelated meanings on one channel that only says
"less" — and it cannot port to the action bar, since dimming a Blizzard button means
writing to a secure frame.

### MEDIUM

- **M1** `Display.lua:485` treats `buffs.degraded` as a global flag; the trace has it true
  on 100% of ticks, so it marks everything and therefore marks nothing. Per-step
  provenance already exists at `Rotation.lua:415`.
- **M2** `Highlight.lua:191/204` calls `GetActionInfo` un-`pcall`'d then compares the
  result — the same defect `Display.lua` already fixed with `safeActionInfo`.
- **M3** `StateTracker.lua:488` boolean-tests `aura.spellId` *before* the secrecy check
  meant to protect it.
- **M4** `Highlight.rebuildSlotIndex` sweeps slots 1–120 but `GetActionButtonFrameName`
  rejects >108, so a spell on bar 8 resolves to a slot and then to no frame.
- **M5** Energy-model soundness holds for every bound derived from an *observation* and
  fails only where a bound is derived from an *inference*: the Opportunity free-cast
  assumption (`EnergyModel.lua:844`) and a long gap leaving pre-loading-screen bounds
  (`:790`). Both self-heal via the contradiction branch. Enforceable invariant, one grep
  away: **no path may raise `E.lo` except from a never-secret observation.**
- **M6** Restless Blades is implemented twice, independently (`Rotation.lua:329` and
  `CooldownModel.lua:51`).
- **M7** `Display.lua` and `Highlight.lua` each carry their own copy of
  `CurrentMainBarSlot` and the slot→binding mapping. This duplication shape is the same
  one that produced the RtB divergence.

---

## The framework gap

The spec-agnosticism claim is **false in four modules**. Adding a second spec today means
editing five engine files (`StateTracker`, `Rotation`, `EnergyModel`, `CooldownModel`,
`UserRules`). That is why no second spec exists.

- `profile.resources` (`profiles/OutlawRogue.lua:433`) is **dead code** — zero consumers.
- `StateTracker.lua:3` claims to be spec-agnostic; it has a fixed state schema, nine
  hardcoded Outlaw cooldown keys, a bare literal `195627`, three if/elseif chains on
  Outlaw buff names, and a hardcoded `Enum.PowerType.Energy`.
- `EnergyModel`'s interval-bracketing mechanism, by contrast, is **already fully general**
  — it would serve Focus, Rage, Runic Power or Mana unmodified; only the constants are
  Outlaw. That is the piece worth building the framework around.

Packaging hygiene not yet done: no `LICENSE` file despite `## X-License: MIT` in the TOC
(the grant is not actually made), no `.pkgmeta`, no release automation, and the addon does
not register with Blizzard's Settings API at all — invisible in Game Menu → AddOns, for no
technical reason. See `docs/FRAMEWORK.md`.

---

## HEKILI: DESIGN REFERENCE ONLY, AND THE ONE IDEA THAT MATTERS

**Licence, checked before anything else: Hekili has NO licence file and no licence line in
its TOC.** Default is all-rights-reserved. Reimplementing its *ideas* is fine; copying or
transcribing its code is not. `docs/HEKILI.md` is written so the design can be implemented
from the description alone — nothing in it is to be pasted. Any future work that reads
`/tmp/hekili` inherits this constraint.

**The idea Tuono is missing**, located precisely (`State.lua:2174`):

```
query_time = now + offset + delay
```

Every state query — cooldown remaining, buff remaining, resource amount — resolves against
`query_time`, not `now`. The same state table answers "is this buff up?" differently
depending on where the virtual clock sits, and the APL never knows it is being evaluated
in the future.

And `Core.lua:895`, which is the whole difference:

```
wait_time = state:TimeToReady()
state.delay = wait_time
```

For each priority entry Hekili moves the clock to the moment that entry becomes ready and
*then* evaluates its condition. `TimeToReady` is `max(cooldown remains, GCD remains,
resource.time_to_X)`. **It never asks "can I afford this?" — it asks "WHEN can I afford
this?" and gets a number.**

Tuono asks `canAfford` and `cdOf(...).ready`, both strictly present-tense, and only pools
— a whole GCD at a time, at most three — when nothing matched at all. That is the
reactive-versus-predictive gap, exactly.

**This is squarely an inversion play.** The interval model can already answer "when will
energy reach 45" as precisely as it answers "is energy above 45", because it carries regen
bounds. We compute the harder quantity and then throw it away to answer the easier
question. See `docs/INVERSION.md` §4.

**One place Tuono is already ahead, do not regress it:** Hekili rebuilds every
recommendation from scratch each pass and has no committed plan, so it structurally cannot
tell you *why* a recommendation changed. Tuono's plan-with-cursor plus the named
`Engine.TRIGGER` set can.

**Do not build:** the SimC script compiler (it parses expressions into Lua, reintroducing
exactly the attack surface `tests/lint_codegen.lua` was added to prevent), multiple
simultaneous displays, target cycling (structurally impossible under Midnight — enemy
auras are unreadable), or a second snapshot system.

## EXISTENTIAL RISK: the inversion is a side channel

Stated plainly because the whole product rests on it.

`C_Spell.IsSpellUsable` is declared never-secret, but its return value is **a function of
the secret energy value**. Probing it across Outlaw's cost ladder recovers the hidden
number to a median width of 0.2; a threshold crossing recovers it *exactly*; two crossings
recover the regen rate. `CooldownModel` does the same thing to secret timers via the
never-secret `isEnabled`/`isActive`. In security terms this is an **oracle attack**:
Blizzard hid a value and left a predicate over it readable.

`docs/LEGALITY.md` argues that shadowing a hidden resource from readable signals is
legitimate. **That argument is the load-bearing premise of the product, and it is not
settled.** If Blizzard instead classifies side-channel recovery of a deliberately-secreted
value as circumvention of an anti-cheat measure, the energy model stops being the asset
and becomes the liability.

The mitigation on their side is cheap and total: flag `IsSpellUsable` secret-when-restricted,
or add jitter around the predicate boundary. Either kills the model outright. Design
accordingly — the interval model already degrades gracefully to cooldown-driven logic when
starved of observations (`EnergyModel.lua:301`), and that property is now a *hedge*, not
just an elegance.

**What separates this from an actual vulnerability**: everything Tuono probes is the
player's own spells on the player's own unit — state the human already has on screen.
Secret values exist for competitive integrity (enemy cooldowns, enemy resources, PvP
information). The serious open question is whether **any never-secret predicate is a
function of state the player is not entitled to**. If one is, that is a disclosure to
Blizzard, not a feature. Not yet investigated; worth doing, and it hardens the legality
argument whichever way it lands.

## Claims to stop making

- **"27% better than Blizzard" is not supported by anything.** The only verifiable figure
  is 15–20%, and that is for *one-button* mode, which carries a GCD penalty that does not
  apply to highlight assist — the mode Tuono actually competes with. Do not publish it.
- **"3% error rate"** is not reproducible from anything versioned. What the trace *does*
  support: energy interval width **median 0.2**, min 0.0, over 127 ticks, with regen solved
  at 16.37/s from 112 crossing samples. That is a strong, defensible claim. Use it instead.
- **"`GetPowerRegenForPowerType` gives us regen directly"** — it is SECRET in combat. The
  13.7257 reading was taken out of combat. The code is safe (it routes through `readNum`),
  but the comment at `EnergyModel.lua:145` overstates its reach.
- **"`if secret then` always errors"** — it errors only on *boolean-typed* secrets. This
  narrows the real hazard considerably and makes `wow_stub.lua`'s documented limitation
  less severe than stated.
- **"Waiting for Energy is Feral-only"** is PARTIALLY REFUTED. On the strength of that
  claim the exact-anchor machinery (`EnergyModel.lua:640-739`) is switched **off** for
  Outlaw, potentially discarding the tightest observation in the model. Cheap to settle:
  the recorder already logs `assist` per tick — scan traces for `1249752` or icon `134377`.

---

## NEXT STEPS (ranked)

1. **C1, C2, C3.** All three are live correctness or maintenance failures.
2. **H1** (buff expiry in the simulator) — it silently poisons the lookahead the
   commitment layer now preserves.
3. **H2** (opaque glow) — one line, biggest perceived improvement.
4. **H5 + M1** — move certainty off alpha onto ring pattern; the design is specified in
   `docs/UI.md`.
5. **Packaging hygiene**: LICENSE, `.pkgmeta`, Settings API registration. ~1 day.
6. **H3** — model buff maintenance, and fix the drift sensor to exclude non-rotation picks.
7. **The three framework seams** (resource schema, aura schema, declarative effects,
   ~11 days), with Fury Warrior as the adversarial forcing function.

## Known constraints

Enemy auras, enemy cooldowns and other units' health are unreadable. No combat log for
addons. Energy is secret unconditionally — it does not lift out of combat. Haste went
secret in 12.0.5. Lua 5.1. Recommendation only; no input automation, ever.
