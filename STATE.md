# STATE — Tuono

**Phase:** substrate complete, UI rework begun, live-validated in a 12.1.0 client.
**Repo:** https://github.com/matt82198/Tuono (public, MIT)
**Single-writer:** orchestrator.

## Intent

A configurable rotation-helper FRAMEWORK for WoW Midnight. Outlaw Rogue is the reference
profile, not the point. Legal by construction: reads no protected value, automates no
input, degrades honestly when data is unavailable.

It exists because Blizzard's replacement for the old helpers is DPS-only, is reported to
stall, and ignores Roll the Bones entirely — and because players who used those tools for
accessibility lost them with no substitute. See `docs/SECRET-VALUES-FINDINGS.md`.

## Locked decisions

1. **Unknown is never zero.** Every read reports KNOWN vs UNKNOWN (`Tuono.readNum` /
   `readBool`). Collapsing unreadable into a default value is the single failure mode
   that caused most of this project's bugs, in at least five separate places.
2. **Bound, don't estimate.** Hidden scalars are carried as intervals. Time widens,
   observation tightens. Wide is renderable; wrong is not.
3. **Never read the secret — invert a never-secret function of it.** `IsSpellUsable`
   bounds energy, the cast stream reconstructs cooldowns, overlay glows expose procs.
4. **Secret-agnostic by construction.** No branch asks "is X hidden". Starve the model
   and intervals widen to `[0,max]`, every answer becomes "maybe", and the rotation
   degrades to cooldown+combo-point logic on its own.
5. **Provenance, not index, sets confidence.** A step derived from exact inputs is solid
   in slot 4; one gated on hidden aura state is uncertain in slot 1. Provenance is
   per-input, never a global "degraded" flag — and it must survive into the simulator's
   scratch state, or every predicted step inherits the worst case.
8. **The length of the queue is a signal.** The lookahead stops at the first step whose
   provenance is `unknown`. One icon is too little to react to; four icons where the
   fourth is a guess is worse than none.
6. **One rotation on the bar.** Blizzard's pick is a sensor, never an icon.
7. **The gate is not overridden.** `secret_scan.py --staged` before every push; a false
   positive is fixed in the code, not waived.

## Live-validated (12.1.0 client, via flight recorder)

- Position 1 reads as **optimal** in play. The substrate works.
- Energy interval holds to **~0.5** width: `[50.89, 51.39]` on a value the client refuses
  to return. Saturates correctly at 100.
- Energy is **SECRET even out of combat in the open world** — the predicate has no
  restriction gate.
- `UNIT_AURA` guards fire constantly: `full=SECRET` ×21, `full=INDEX_THREW` ×13 in one
  session. Each would have been a silent crash of the aura layer.
- RtB stage 1 aura `1214933` "One of a Kind" captured live, independently matching SimC.
- GCD fix confirmed: "Ability is not ready yet" dropped out of the top errors.

## NEXT STEPS (ranked)

1. **Verify the range/target gate.** Just landed, unverified. Last trace had 8 "Out of
   range" and 9 "There is nothing to attack". Re-run `/tuono record` → `/reload`.
2. **Residual energy errors.** 10× "Not enough energy", mostly Between the Eyes. The
   interval is good but the affordability gate still lets some through.
3. **Stage discriminators without auras.** Stage ≥2 → SS grants +1 CP (CP is readable);
   stage ≥3 → Restless Blades 1.3s/CP vs 1.0 (cooldowns are reconstructed). Collapses
   the stage within ~2 globals. 4-vs-3 differs only by crit and is unresolvable.
4. **Learn the other three RtB stage auras.** IDs are in the profile from SimC; the
   learner confirms them from play and writes candidates to SavedVariables.
5. **UI rework.** Default is 4 icons, self-truncating at the first `unknown` step, plus
   the ready rail. The rail needs real design work; the escalation slot for
   defensives/interrupts is unbuilt.
6. **SimC APL importer.** The rule schema is already APL-shaped. Blocked on nothing but
   effort; value depends on how much of an imported APL is evaluable under secrets.
7. **`C_RestrictedActions.IsAddOnRestrictionActive` returns CALL_FAILED** for all six
   contexts. Undiagnosed.
8. **Tag a release.** Deliberately held until the above settles.

## Known limitations

- Enemy state is gone permanently: no health, debuffs, casts. No interrupt planning.
- Energy is bounded, never known.
- RtB stage 4 vs 3 has no deterministic observable.
- Proc detection via overlay gives presence only, never stack count.
- `Tuono.Rules` (data/rules.lua) and profile priority lists are two engines, the former
  post-processing the latter. This caused several bugs and should be folded in. Two more
  found since: `preparation_ready` still carried the dead Classic spell ID 14185 after the
  profile was corrected, and `rtb_reroll_stage2` advised a six-minute cooldown at a stage
  the profile explicitly gates against. Both fixed; the underlying duplication is not.
- Overlay-glow provenance only exists for procs Blizzard glows, and only while the spell
  is on an action bar. Un-barred, no event fires, `fromOverlay` is never set, and the
  affected steps rate `unknown` — the lookahead shortens rather than going stale.
- Nothing has been validated in a mythic keystone; all live data so far is open world.
