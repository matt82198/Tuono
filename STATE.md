# STATE — Tuono

**Phase:** substrate complete, UI rework begun, live-validated in a 12.1.0 client.
**Repo:** https://github.com/matt82198/Tuono (public, MIT)
**Single-writer:** orchestrator.

## Intent

A configurable rotation-helper FRAMEWORK for WoW Midnight. Outlaw Rogue is the reference
profile, not the point. Legal by construction: reads no protected value, automates no
input, degrades honestly when data is unavailable.

**The thesis, which the docs are now written around:** secret values did not remove these
tools, they privatized them. This repo reads nothing protected and reconstructs most of the
hidden state anyway, purely through engineering effort — so the barrier was never a wall,
it was cost. Cost does not remove a capability, it selects who keeps it. The free, open,
audited addons died; private ones did not. Players who used helpers for accessibility are
the ones who actually lost something. Hence: MIT, public, every technique documented, every
uncertainty rendered honestly rather than papered over.

This is not an argument for cheating and not a complaint about wanting fair play. See
README and `docs/SECRET-VALUES-FINDINGS.md`.

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
6. **The length of the queue is a signal.** The lookahead stops at the first step whose
   provenance is `unknown`. One icon is too little to react to; four icons where the
   fourth is a guess is worse than none.
7. **One rotation on the bar.** Blizzard's pick is a sensor, never an icon.
8. **The gate is not overridden.** `secret_scan.py --staged` before every push; a false
   positive is fixed in the code, not waived.

## Live-validated (12.1.0 client, via flight recorder)

- Position 1 reads as **optimal** in play, and the bar is fluid and readable. Step 2 is
  right about **half** the time -- see NEXT STEPS 4, which is where to resume.
- Energy interval: **mean width 2.76** across 113 in-combat ticks (`bracketed` on 75),
  with exact 0-width pins at threshold crossings. Improved 7.13 -> 3.44 -> 2.76 as the
  client regen seed and the crossing solve came together. The `~0.5` once quoted was one
  cherry-picked sample, not the distribution.
- Energy is **SECRET even out of combat in the open world** — the predicate has no
  restriction gate.
- `UNIT_AURA` guards fire constantly: `full=SECRET` ×21, `full=INDEX_THREW` ×13 in one
  session. Each would have been a silent crash of the aura layer.
- RtB stage 1 aura `1214933` "One of a Kind" captured live, independently matching SimC.
- GCD fix confirmed: "Ability is not ready yet" dropped out of the top errors.

## NEXT STEPS (ranked)

1. **RETRACTED — the energy model was never disconnected.** The previous entry here said
   `recordEdge` never fires, "provably", from the 23:12 trace. That was wrong, and wrong in
   an instructive way: it was read off the **last 13 ticks**, which land after the fight
   ends, where `[100,100] stale` is the *correct* answer for a rested player. The next
   trace showed `bracketed` on 71 of 94 ticks with exact 0-width pins at each crossing. The
   real story was low excitation (4 casts in the whole run) — precisely the observability
   caveat in `docs/INVERSION.md` §9. The reader now prints a source histogram and interval
   width over ALL ticks before showing the tail, so this misreading is not repeatable.
2. **ANSWERED — the stat family does NOT survive combat.** In-combat probe:
   `GetPowerRegenForPowerType`, `GetPowerRegen`, `GetHaste`, `UnitSpellHaste`,
   `GetMeleeHaste`, `UnitAttackSpeed` all return `SECRET`; out of combat all return plain
   numbers. The whole family is `SecretWhenUnitStatsRestricted`. `UnitPowerDisplayMod`
   survives. So the readable regen rate is an out-of-combat SEED, not a replacement for the
   two-crossing solve — which is what `readClientRegen` already does, reading through
   `readNum` so the modelled path carries on when it returns nil. It still paid: interval
   mean width went 7.13 → 3.44 → **2.76**, bracketed on 75 of 113 ticks.
3. **ANSWERED — widget read-back is CLOSED.** A secret energy value fed to a `StatusBar`
   and a `FontString` came back `SECRET` from both getters; the taint rides through, as
   designed. The `Cooldown` path stays inconclusive out of combat (the source cooldown is
   itself readable there, so nothing is laundered). The recurring "middle layer of
   invisible icons" idea does not work on this build, and `/tuono record` re-measures it
   whenever Blizzard changes something.
4. **PICK UP HERE — position 2 is right about half the time.** Live verdict after the
   above landed: the bar is fluid, readable, and demonstrably an optimal helper again;
   position 1 is trusted; **step 2 is correct roughly 50% of the time.**

   That number is the most useful thing to work from, because it means the confidence
   rating is too GENEROUS, not that prediction is impossible. The queue truncates at the
   first step rated `unknown` — so a step 2 that renders at all was rated `certain` or
   `bounded`, and being wrong half the time says those ratings are not earned. Suspects, in
   order: (a) `rateRule` awards `certain` to a rule whose declared `conditions` list is
   incomplete relative to what its `when` closure actually reads — the two can drift freely
   and nothing checks them; (b) the simulator advances state the player then diverges from,
   which is a conditional, not an error, and may simply need saying on screen; (c) energy
   `bounded` at mean width 2.76 straddles a cost boundary more often than the rating admits.

   The cheap experiment first: log predicted-step-2 against the player's actual next cast
   in the recorder, bucketed by the rating that step carried. If `certain` steps are ~90%
   and `bounded` steps are ~50%, the rating is fine and only the *display* is
   over-promising. If `certain` steps are also ~50%, (a) is the bug.

5. **Verify the range/target gate.** Still unverified. Traces show "Target needs to be in
   front of you", "Out of range", "You are facing the wrong way!".
6. **Stage discriminators without auras.** Stage ≥2 → SS grants +1 CP (CP is readable);
   stage ≥3 → Restless Blades 1.3s/CP vs 1.0 (cooldowns are reconstructed). Collapses
   the stage within ~2 globals. 4-vs-3 differs only by crit and is unresolvable.
7. **Learn the other three RtB stage auras.** IDs are in the profile from SimC; the
   learner confirms them from play and writes candidates to SavedVariables.
8. **UI rework.** Default is 4 icons, self-truncating at the first `unknown` step, plus
   the ready rail. The rail needs real design work; the escalation slot for
   defensives/interrupts is unbuilt.
9. **SimC APL importer.** The rule schema is already APL-shaped. Blocked on nothing but
   effort; value depends on how much of an imported APL is evaluable under secrets.
10. **`C_RestrictedActions.IsAddOnRestrictionActive` returns CALL_FAILED** for all six
   contexts. Undiagnosed.
11. **Tag a release.** Deliberately held until the above settles.

## Known limitations

- Enemy state is gone permanently: no health, debuffs, casts. No interrupt planning.
- Energy is bounded, never known.
- RtB stage 4 vs 3 has no deterministic observable.
- Proc detection via overlay gives presence only, never stack count.
- `Tuono.Rules` (data/rules.lua) is now **advisory only**. Its PIN/PREFER actions were
  reordering and splicing the simulated sequence from outside the simulation, which is
  what made positions 2+ incoherent; they are gone. ADVISE still appends reminders behind
  the sequence. The file still duplicates profile rules and still restates spell IDs it
  should not — folding it into the profiles remains the real fix.
- Four bugs traced to that duplication, all fixed: `preparation_ready` carried the dead
  Classic ID 14185; `rtb_reroll_stage2` advised a six-minute cooldown at a stage the
  profile gates against; `blade_flurry_aoe` injected Blade Flurry into single-target; and
  the PIN rules were masking cross-test state pollution AND a profile rule that never fired.
- Overlay-glow provenance only exists for procs Blizzard glows, and only while the spell
  is on an action bar. Un-barred, no event fires, `fromOverlay` is never set, and the
  affected steps rate `unknown` — the lookahead shortens rather than going stale.
- Nothing has been validated in a mythic keystone; all live data so far is open world.
- The predecessor addon must be DISABLED, not merely migrated from. Both bars default to
  the same anchor, so leaving OutlawAssist enabled stacks two rotation helpers on the same
  screen position and the old one still throws on UNIT_AURA. Tuono now says so on login;
  the local install has it renamed to `OutlawAssist_DISABLED`.
