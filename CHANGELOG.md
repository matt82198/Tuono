# Changelog

All notable changes to OutlawAssist are documented here.

## [1.4.0] - 2026-08-01

### Added
- **Rotation decision rules** — Implemented missing strategic decisions to reduce DPS loss:
  - Preparation reset: `Prep_reset_cooldowns` rule casts Preparation when AR/BtE/Blade Rush are down (P1-7, docs/research/rotation-model.md §1b rule 6)
  - CP pooling before finishers: `SS_at_5cp_if_6cp_finisher_coming` pools 1 CP when a 6-CP finisher will be ready within ~1 GCD (P1-1, docs/research/rotation-model.md § finisher priority)
  - Improved finisher fallback chain: Dispatch only casts at 5-6 CP when both BtE and KS are unavailable, preventing low-CP finishers from blocking better high-CP options
  - Opportunity buff simulation fix: `buffs.opportunity.up` is now cleared after virtual Pistol Shot to prevent multi-step predictions from double-casting on a single proc (P1-3)
- **Energy pooling** — Prediction now advances virtual time (1 GCD per attempt, up to 3 GCDs) when no ability is castable due to energy starvation, instead of terminating early. Fixes "only 2 icons showing" issue where sequences terminated after running out of energy.
- **Central affordability checker** — Added `canAfford(S, spellID)` helper that derives energy costs from ABILITIES table, eliminating hardcoded thresholds that could drift. All 13 priority rules now use it, guaranteeing consistency when costs change (prevents repeat of Dispatch 25→35 energy desync bug).

### Fixed
- **Stuck Dispatch icon** — Dispatch rule checked `S.energy >= 25` but real cost is 35; rules now use `canAfford()` helper, fixing the energy desync that left icons stuck recommending uncastable spells.
- **KS energy check corrected** — Killing Spree rule checked `S.energy >= 25` but costs 45; now uses `canAfford()` which reads from ABILITIES table.
- **BR energy check corrected** — Blade Rush rule checked `S.energy >= 25` but costs 0; now uses `canAfford()`.
- **Empty predictions at low energy** — Sequences now pool energy instead of breaking early; 4-step predictions return 4 steps (was returning 2).

### Tests Added
- `decisions: CP pooling — SS at 5 CP if BtE will be ready within ~1 GCD` — Verifies pooling triggers when a finisher is coming up soon
- `decisions: Dispatch fallback — cast at 5 CP when both 6-CP finishers unavailable` — Confirms finisher fallback chain works
- `decisions: Preparation reset — fires when AR/BtE/BR down` — Tests Preparation reset condition
- `decisions: Opportunity buff cleared after PS — no double-cast in simulation` — Ensures Opportunity doesn't reproc for free in predictions
- `decisions: leveling build — SS + Dispatch loop at low level` — Validates minimal-spell builds (2-3 abilities) still work
- `decisions: Dispatch at 6 CP — only when both BtE/KS unavailable` — Confirms high-CP finisher preference

## [1.3.1] - 2026-08-01

### Fixed
- First icon never changed in combat: the simulation bailed out whenever aura data was
  degraded, and Midnight hides aura data in combat, so it never ran and the bar fell back
  to Blizzard's static pick. It now predicts from energy/combo points/cooldowns (all still
  readable) and only lowers confidence.
- Keybinds appeared on only some icons: the action-slot to binding-name map covered slots
  1-12 and 61-72 and mislabelled 73+, so spells on most action bars resolved no keybind.
  Replaced with the full canonical mapping.

## [1.3.0] - 2026-08-01

### Fixed
- **CRITICAL: Six ability cooldowns/costs were wrong** — Blade Rush cd 10→60s (6x), Killing Spree cd 30→180s (6x), Killing Spree cost 25→45, Between the Eyes cd 30→45s, Dispatch cost 25→35 (core leveling bug), Blade Flurry cost 0→15, Keep It Rolling cd 15→360s (24x). All values verified against live Wowhead 2026-08-01; forward simulation was silently corrupted by these errors.
- **Ambush stealth-opener rule missing** — Ambush was in the ABILITIES table but never appeared in any priority rule, so the free 2-CP stealth opener was never recommended. Added `Ambush_stealth_opener` rule at highest priority for all stealth scenarios.
- **Sinister Strike has no combo-point cap check** — SS would spam past 6 CP forever if a finisher reads as unavailable, instead of going quiet. Added `comboPoints < comboPointsMax` guard.
- **Blade Flurry rule didn't check energy cost** — The AoE toggle rule checked cooldown and CP only, not the 15 energy cost. Added energy check.
- **SpellID TODO comments cleared** — All 14 SpellIDs now verified against Wowhead and marked VERIFIED; removed stale TODOs.

### Added
- **Regression guards** — Tests to prevent future placeholder cooldown/cost errors, specifically the critical Dispatch 35-energy leveling case.

## [1.2.2] - 2026-08-01

### Fixed
- Simulated cooldowns never started: the cooldown was keyed by the RULE name instead of
  the ability, so a predicted sequence could repeat the same ability instead of advancing.
- A missing cooldown key returned a shared module-level table, so writing to it corrupted
  every later untracked lookup for the rest of the session.

## [1.2.1] - 2026-08-01

### Fixed
- **Ability data** — Transcribed real cooldown values, energy costs, and combo-point generation/consumption from rotation-model.md research doc. All abilities now have accurate cd, cpGen, and cpSpend values (previously all set to 0).
- **Cooldown tracking** — StateTracker now tracks cooldowns for all rotation abilities (Adrenaline Rush, Blade Rush, Between the Eyes, Blade Flurry, Roll the Bones, Killing Spree, Dispatch, Keep It Rolling, Preparation), not just AR/Blade Rush/Prep. Eliminated fallback UNTRACKED_CD behavior.
- **Talent-driven rotation** — Rotation priorities now filter dynamically based on player's known talents/spells via `OA.State.knownSpells`. Talent-gated abilities (Preparation, Keep It Rolling, Killing Spree if not talented) are excluded from the active priority list. Respec or talent change (via SPELLS_CHANGED / PLAYER_TALENT_UPDATE / etc.) rebuilds the active list without requiring `/reload`.

### Added
- **Missing spell IDs** — StateTracker.lua now defines `OA.SpellIDs.killingSpree`, `dispatch`, `keepItRolling` (previously only local constants in Rotation.lua, causing nil-table-key load failures).
- `OA.Rotation.activeRuleCount` — Exposes the count of active (talent-filtered) rules in the priority list; shown in `/oa debug` output for observability.
- Tests validating that rotation recommendations change when talents change without reload, and that disabled talent rules are never evaluated.

## [1.2.0] - 2026-08-01

### Added
- **Forward-simulating rotation engine** — New `OA.Rotation.Predict()` function computes the next 1-4 ability casts deterministically based on current state (energy, combo points, cooldowns, RtB stage). Predicts energy regeneration, cooldown reduction (Restless Blades: 1.0 sec/CP, +30% in RtB Stage 3), and GCD advancement across the simulation horizon.
- Rotation priorities transcribed from research/rotation-model.md with single-target and AoE variants (Blade Flurry priority insertion).
- Confidence tracking (high for steps 1-3, low for 4+) reflecting determinism ceiling beyond ~3 GCDs.
- Fallback to Blizzard assist when prediction yields no castable ability (degraded state or out-of-resources).
- `/oa probe` — Proc observability probe and accessor liveness sampler (15s). Records aura observability (query-by-ID and delta-event tracking for Opportunity, Adrenaline Rush, Roll the Bones, Stealth). Samples all assist-combat accessors side-by-side: GetNextCastSpell(false/true), GetActionSpell(...), and enumerates available C_AssistedCombat/C_ActionBar functions. Reports verdict (DIRECT, DELTA-ONLY, or NONE) for proc visibility and identifies best live accessor.

### Changed
- IntelligenceLayer now wires OUR predicted sequence into the queue as source=<ruleName> entries, tagged with confidence. Blizzard's live value (OA.Assist.nextSpellID) still merges as a safety net and is compared for UI agreement display (OA.Engine.blizzAgrees).

## [1.1.1] - 2026-08-01

### Added
- `/oa probe` — Proc observability probe and accessor liveness sampler (15s).
  Records aura observability (query-by-ID and delta-event tracking for Opportunity, Adrenaline Rush, Roll the Bones, Stealth).
  Samples all assist-combat accessors side-by-side: GetNextCastSpell(false/true), GetActionSpell(...), and enumerates available C_AssistedCombat/C_ActionBar functions.
  Reports verdict (DIRECT, DELTA-ONLY, or NONE) for proc visibility and identifies best live accessor.
  Run during active combat with proc-triggering actions for accurate results.

## [1.1.0] - 2026-08-01

### Fixed
- **CRITICAL: Fail-open cooldown bug** — Secret/unknown cooldowns (in combat) were treated as READY, causing on-cooldown abilities to be recommended. Now unknown cooldowns fail CLOSED: only known-ready cooldowns are queued.
- Keybind display was not rendering in-game; improved resolution logic with better fallback paths and cache-retry behavior.
- Keybind positioning (now bottom-right, larger font with shadow for legibility).

### Changed
- Persistent bar: now visible out-of-combat by default (`show.ooc = true`).
- Cooldown timers now display on icons (top-center, numeric format).
- Added Blizzard's native Cooldown widget for visual cooldown swipe overlay.
- Engine adds belt-and-braces castability filter: drops any non-position-1 entry whose cooldown is not known-ready.

### Added
- Enhanced `/oa debug` diagnostic output: shows keybind resolution per queue entry with slot/binding/key details.
- Trinket cooldowns now respect fail-closed logic (unknown = not ready).

## [1.0.2] - 2026-08-01

### Fixed
- Idle throttle stuck at combat rate; dynamic 0.1s combat / 0.5s idle now works
- Removed dead per-kind display toggles left over from the multi-row design
- `/oa debug` reported trinkets as always ready
- Display's own event frame bypassed the addon's error guard
- `/oa debug` now surfaces the accumulated error count

## [1.0.1] - 2026-08-01

### Fixed
- Frozen bar: icons 2+ were padded from the static rotation list and could never
  change. Position 1 is now the live recommendation, re-polled every tick; later
  slots hold only state-derived entries and the bar shrinks when there is nothing real.
- Combat error "attempt to compare local auraName (secret)": aura NAMES are secret in
  combat, not just spell IDs. All aura strings pass a secret guard before comparison.
- Closed an un-gated legacy aura-scan path that could run in combat.

### Added
- `/oa watch` — 15s combat sampler reporting whether the recommendation changes and
  whether the rotation list is static or live.

## [1.0.0] — 2026-08-01

### Added
- LICENSE file (MIT) for CurseForge/WagoApp publishing
- First-run welcome message and recovery help documentation
- `/oa help` alias for command listing
- `/oa reset` recovery hint for off-screen display recovery
- Degraded buff tracking indicator when aura introspection fails
- Empty-queue reason display when Blizzard's rotation assist is unavailable
- Enhanced UX for non-Outlaw specs with explanatory message

### Changed
- Version unified across TOC, README, and git tags (1.0.0)
- README version references now link to releases page instead of hardcoding versions

## [0.2.7] — 2026-07-20

### Fixed
- Display table initializer (in-game load)
- Honest bare-OA test loader
- Self-shadow texture wrappers
- String-stripping lint gate

## [0.2.6] — 2026-07-19

### Fixed
- Removed goto statement (Lua 5.1 compatibility)
- Added 5.1-syntax lint gate
- Engine module loading in-game

## [0.2.5] — 2026-07-18

### Fixed
- Interface versions (120005, 120007, 120100) for Midnight client compatibility

## [0.2.4] — 2026-07-17

### Fixed
- TOC structure (Interface directive must be first)

## [0.2.3] — 2026-07-16

### Added
- Converge hardening pass
- Secret-mode stub with P0 bite-proofs

### Fixed
- Test order-fragility
- De-tautologized tests

## [0.2.2] — 2026-07-15

### Fixed
- Display.Init wiring at login
- Config rebuild on /oa reset
- Blade Flurry probe normalization
- Live update interval

## [0.2.1] — 2026-07-14

### Fixed
- Secret value guard order (issecretvalue check must precede type check in OA.num/OA.bool)

## [0.2.0] — 2026-07-13

### Added
- Secret-value hardening for Midnight API guards
- Assist-driven AoE detection (threat-table, multi-combat signals)
- Reactive polling with event-forced re-evaluation
- Unified rolling queue UI with per-icon keybinds
- Configurable icon count (1-8)
- TOC lint gate

### Changed
- Allocation-light Render path (expert review pass)

## [0.1.3] — 2026-07-10

### Added
- Module load canary (login message)
- State control files (CLAUDE.md, STATE.md, BUILDLOG.md)

## [0.1.2] — 2026-07-09

### Added
- Rules content v1 (SimulationCraft-sourced, converged lens)

## [0.1.1] — 2026-07-08

### Fixed
- Initial API integration and testing

## [0.1.0] — 2026-07-01

### Added
- Initial release
- Core event dispatcher and frame management
- StateTracker combat state caching
- AssistReader polling of C_AssistedCombat API
- IntelligenceLayer decision rules (20 Outlaw-specific rules)
- Display renderer with kind-colored borders
- Config slash-command interface
- ApiTest verification probes
