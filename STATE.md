# STATE — Tuono

**Date:** 2026-08-17
**Version:** 2.2.1 (imported from live AddOns at `b882b54`; no prior VCS)
**Single-writer:** Orchestrator

---

## Intent

Ship a rotation helper that is **more accurate than Blizzard's Assisted Combat and more
readable than Hekili**, on a client that hides the state both of those were designed
around. Position 1 is already right. The product is not yet *enjoyable*, and that is the
whole remaining problem.

## The thesis (locked)

Midnight hides combat state behind secret values. Tuono never reads the hidden value. It
**bounds** it from never-secret signals and carries the width of that bound into the UI.
Certainty is an output, not an assumption.

This is a genuine edge and it is already built:

- `EnergyModel.lua` brackets hidden energy from both sides via `C_Spell.IsSpellUsable`
  (`isUsable` ⇒ lower bound, `insufficientPower` ⇒ upper bound), collapses the interval to
  an **exact value** on a threshold crossing, and *solves for regen* between two crossings
  — retiring the secret haste read and the stochastic Combat Potency guess.
- `Rotation.lua` rates each predicted step by **provenance** (what the firing rule actually
  depended on), not by how far down the list it sits.
- The player's own actions are an observation channel: a successful cast proves
  affordability; a failed cast plus a localized out-of-power error proves the opposite.

## Locked decisions

1. **The bar is ours.** Blizzard's `GetNextCastSpell` is a *drift sensor* and an AoE
   signal, never an icon. (`IntelligenceLayer.lua:84`)
2. **The sequence is a causal chain, not a list.** Nothing may reorder or splice it — the
   legacy `PIN`/`PREFER` rules are deliberately inert for exactly this reason.
   (`IntelligenceLayer.lua:198`)
3. **Recommendation only.** No input automation, ever. No reading of protected values.
4. **Unknown is never "no".** Fail open, lower confidence, surface it.
5. **Interval over point estimate.** A single number for a hidden value is a lie with a
   decimal point on it.

---

## The live complaint

> "The first button is optimal. It switches the entire list a lot and it's not smooth."

**Diagnosis (inferred from reading; NOT yet proven by test).** Position 1 is stable
because it is re-derived from ground truth every tick. Positions 2–N are not smoothed at
all: `Engine.Evaluate` → `Rotation.Predict` re-simulates from scratch on every tick, at up
to ~30Hz, with **zero state carried between ticks**. Three independent oscillators feed it:

1. **Queue length flaps.** `IntelligenceLayer.lua:389` truncates the sequence at the first
   step rated `unknown`. `inputConfidence` returns `unknown` for a `buffUp` condition
   whenever `buffs.degraded` is set and `fromOverlay` is not — and `degraded` toggles with
   per-tick aura read success. So the visible list length jumps between 1 and 4.
2. **The energy interval breathes.** `widen()` grows the interval continuously with time;
   `Observe()` tightens it only every `BRACKET_MIN_INTERVAL` (0.25s). That is a ~4Hz
   sawtooth on interval width, which flips `AffordState` between `yes` and `maybe` for the
   marginal step and re-rates its confidence.
3. **RtB stage readability flaps**, flipping `rtbStage`-gated rules between rated and cut.

**This is a smoothing / commitment problem, not a modeling problem.** The model is the
asset. The presentation layer has no hysteresis, no commitment, and no notion that the
player is a human with a reaction time.

## Open defects (found by reading; unverified in game)

| # | Severity | Where | Defect |
|---|---|---|---|
| D1 | **HIGH** | `profiles/OutlawRogue.lua:327` | The **AoE** Roll-the-Bones rule is missing the `stageKnown == false` guard that the single-target copy has at :135. In AoE this reproduces the "reroll a Jackpot every 45s" bug the comment at :116 says was the most damaging thing the profile ever did — and it will *throw* outright if `stage` is nil. |
| D2 | MED | `Display.lua:651` | The cooldown cache-guard re-fires on `sinceLast > 0.1`, so `SetCooldown` restarts the sweep animation ~10×/sec on any cooldown entry. This is the same strobe the GCD path at :699 was explicitly fixed for; the fix was never applied here. |
| D3 | MED | `Display.lua:668` | `cooldownWidget:Show()` is called unconditionally inside the `if icon.cooldownText` branch, including when `remaining == 0` and `SetCooldown` was never called — leaving a stale sweep on screen. The `else` branch that hides it is structurally unreachable (`cooldownText` is always created in `CreateIcon`). |
| D4 | LOW | `Rotation.lua:613` | If a rule matches but resolves to a nil spellID, `reason` is assigned while `spellID` stays nil; the loop continues and a later rule's spell can be paired with an earlier rule's reason. |

**Zero of these are provable today**, which is the real finding — see below.

## The blocking structural gap

**There are no tests.** 21 files, ~378KB of Lua, an engine claimed at 3% error, and the
only verification surface is `ApiTest.lua`, which requires being logged into the game.
The *ancestor* project (`outlaw-assist`, archived in Downloads) had `tests/wow_stub.lua`,
`tests/run_tests.lua` and a fail-closed `toc_check.lua`. Tuono dropped all three.

"No accepted bugs" is unreachable without this. It is prerequisite to everything else.

---

## NEXT STEPS (ranked)

1. **Test harness.** Port the ancestor's `wow_stub.lua` forward; add `toc_check.lua`
   (fail-closed: every `.lua` listed, every listed file exists, single-number Interface
   line). Gate: `lua tests/run_tests.lua` green.
2. **Prove the defects.** Write a failing test for D1–D4 *before* fixing them.
3. **Replay rig.** `Recorder.lua` already snapshots ticks. Turn recorded traces into
   deterministic fixtures, then define **queue churn as a measured number** (edit distance
   between consecutive ticks' queues, per second). The complaint becomes a metric.
4. **Smoothing layer.** Commitment + hysteresis on positions 2–N, tuned against that
   metric. Position 1 keeps its current re-derive-every-tick behaviour.
5. **UX pass.** Decide the primary surface (queue strip vs. action-bar highlight vs. both)
   — see the open decision below.
6. **Multi-spec.** The engine is already spec-agnostic; only `profiles/` is Outlaw. This
   is the growth path, and it is gated on 1–4 being solid.

## Open decisions (need the human)

- **D-A: Primary UI surface.** The user's instinct is to highlight icons on existing
  action/WeakAura bars. `Highlight.lua` already does this for position 1 only. It is more
  glanceable but structurally cannot show lead time — and lead time is what a rotation
  helper is *for*. Candidate resolution: keep both, make the highlight the default and the
  strip an opt-in "lookahead" panel, and put a numbered order badge on highlighted buttons
  so the bar itself carries 2–3 steps of prediction.
- **D-B: Where does the 3% error figure come from?** Not reproducible from anything in
  this repo. Needs to be either located and checked in as a fixture, or re-measured. It is
  the central marketing claim and currently rests on nothing versioned.

## Known constraints

- Enemy auras, enemy cooldowns, other units' health: unreadable (secret values).
- No combat log for addons in Midnight.
- Energy is unconditionally secret; combo points and `UnitPowerMax` are not.
- Haste went secret in 12.0.5 (`SecretWhenUnitStatsRestricted`).
- Lua 5.1; no input automation; recommendation only.
