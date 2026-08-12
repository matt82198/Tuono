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

- Position 1 reads as **optimal** in play. The substrate works.
- Energy interval: **mean width 7.13, max 103** across 94 in-combat ticks, with exact
  0-width pins at every threshold crossing (`bracketed` on 71 of 94). The `~0.5` figure
  quoted earlier was one cherry-picked sample, not the distribution.
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
2. **Is the stat family readable IN COMBAT?** `GetPowerRegenForPowerType` (13.7257),
   `GetHaste`, `UnitSpellHaste`, `UnitAttackSpeed` and `UnitPowerDisplayMod` all returned
   plain numbers — but only in probes taken out of combat, and that whole family carries
   `SecretWhenUnitStatsRestricted`. The recorder now re-probes on `PLAYER_REGEN_DISABLED`.
   If regen survives restriction it replaces the two-crossing solve outright; if it does
   not, it is still a far better out-of-combat seed than the `[8,40]` prior.
3. **Widget read-back is CLOSED, measured.** A secret energy value fed to a `StatusBar` and
   a `FontString` came back `SECRET` from both getters. The `Cooldown` path is still
   inconclusive — out of combat the source cooldown is itself readable, so nothing was
   laundered — hence the in-combat re-probe above.
4. **Verify the range/target gate.** Still unverified. The 23:12 trace shows 3× "Target
   needs to be in front of you", 1× "You are facing the wrong way!".
5. **Stage discriminators without auras.** Stage ≥2 → SS grants +1 CP (CP is readable);
   stage ≥3 → Restless Blades 1.3s/CP vs 1.0 (cooldowns are reconstructed). Collapses
   the stage within ~2 globals. 4-vs-3 differs only by crit and is unresolvable.
6. **Learn the other three RtB stage auras.** IDs are in the profile from SimC; the
   learner confirms them from play and writes candidates to SavedVariables.
7. **UI rework.** Default is 4 icons, self-truncating at the first `unknown` step, plus
   the ready rail. The rail needs real design work; the escalation slot for
   defensives/interrupts is unbuilt.
8. **SimC APL importer.** The rule schema is already APL-shaped. Blocked on nothing but
   effort; value depends on how much of an imported APL is evaluable under secrets.
9. **`C_RestrictedActions.IsAddOnRestrictionActive` returns CALL_FAILED** for all six
   contexts. Undiagnosed.
10. **Tag a release.** Deliberately held until the above settles.

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
