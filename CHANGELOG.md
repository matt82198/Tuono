# Changelog

All notable changes to OutlawAssist are documented here.

## [1.8.1] - 2026-08-02

### Fixed
- Fresh/levelling character with a partial kit got an EMPTY bar at max combo points:
  Dispatch is gated on "no other finisher available", but availability was tested by
  COOLDOWN only - an untalented Between the Eyes or Killing Spree sits at zero cooldown,
  so it read as available and blocked the one finisher the character actually had.
  Availability now requires the ability to be known, not merely off cooldown.
- Added a last-resort builder so the bar is never blank, even for a character with no
  finisher at all.

## [1.8.0] - 2026-08-01

### Fixed
- ROOT CAUSE of frozen/empty bar for levelling characters: a levelling rogue has 5 max
  combo points, but finishers hardcoded >= 6 (unreachable) while the builder was gated
  below max - at 5 CP the sequence went EMPTY and fell back to Blizzard's static pick.
  Finishers now spend at 6 OR at max when max is lower. Test stub defaults to 5.
- Stealth/bonus-bar: entering stealth remaps action slots, so keybinds and the glow
  pointed at the wrong button; slot resolution is now bonus-bar aware and caches
  invalidate on stealth/page/bar events.
- Spell overrides resolve in both directions, so an overridden ability is no longer
  treated as unknown.
- Failed casts (out of range, line of sight) force an immediate re-evaluate.
- OA.safe single-return misuse disabled the modern action-button lookup entirely.
- SPELL_TO_CDKEY was exported before its declaration and was permanently nil.

## [1.7.0] - 2026-08-01

### Fixed — Stealth/Bonus-Bar State Transitions
- **Keybind text and glow pointed at the wrong button while stealthed** — STEALTH SWAPS THE ACTION BAR PAGE (`GetBonusBarOffset() > 0` for Rogue Stealth, VERIFIED), which remaps what ActionButton1-12 show. `GetActionBarPage()` does NOT reflect this swap (VERIFIED: "might not actually be available if overridden by ... temporary shapeshift or other similar mechanics"), so the old static slot→frame table mapped stealth-bar slots (e.g. 73-84) to a fixed multibar name regardless of whether that bar was actually visible. Fixed: `Display.lua`/`Highlight.lua` now compute the CURRENT main-bar slot for buttons 1-12 from `GetBonusBarOffset()`/`GetActionBarPage()` (VERIFIED formula: `N + (NUM_ACTIONBAR_PAGES + bonusOffset - 1) * NUM_ACTIONBAR_BUTTONS`) and prefer that over the static table.
- **Highlight glow got stuck on the pre-stealth button** — `OA.Highlight.Update` short-circuited whenever the recommended spellID was unchanged, even if the actual bar layout (and therefore the correct button) had moved. Added a `barDirty` flag, set by the new bonus-bar/page-change event handlers, so the cache hit only applies when BOTH the spellID and the layout are unchanged.
- **Spell overrides broke lookups both directions** — talents/procs/stealth can swap the spell actually sitting on a slot for a different (override) ID than the base ID this addon reasons about. `Display.lua`/`Highlight.lua` now match a base spellID against an action slot holding its live override (and vice versa) via new `OA.ResolveOverrideSpell`/`OA.ResolveBaseSpell`/`OA.SpellMatchesAction` helpers (`StateTracker.lua`), backed by `C_Spell.GetOverrideSpell`/`FindSpellOverrideByID`/`FindBaseSpellByID` (VERIFIED APIs, all guarded).
- **Known-spell gating didn't account for overrides** — `RefreshKnownSpells` now probes a spellID's live override/base alongside itself and marks all of them known when any one checks true, so a talented-and-overridden ability is never read as "unknown".
- **Caches never invalidated on the actual transition** — registered `UPDATE_STEALTH`, `ACTIONBAR_PAGE_CHANGED`, `UPDATE_BONUS_ACTIONBAR` (all VERIFIED, no-payload events) alongside the pre-existing `ACTIONBAR_SLOT_CHANGED`/`UPDATE_BINDINGS`/`SPELLS_CHANGED`/`PLAYER_REGEN_DISABLED`/`PLAYER_REGEN_ENABLED` to invalidate both the Display keybind cache and the Highlight bar-dirty flag.
- **Dead talent-change event registrations** — `StateTracker.lua` guarded `PLAYER_TALENT_UPDATE`/`ACTIVE_TALENT_GROUP_CHANGED`/`TRAIT_CONFIG_UPDATED`/`SPELLS_CHANGED` registration behind `if _G.EVENT_NAME then`, which tests for a global VARIABLE sharing the event's name (never defined) rather than the event's validity — none of these handlers were ever actually registered. All four are VERIFIED real events and are now registered unconditionally, plus `UPDATE_STEALTH` (overrides can change on a stealth transition, not only on talent change).

### Fixed — Coordinator-Reported (verified independently, same files)
- **`OA.safe` single-return destructuring bug** — `OA.safe` returns one value (`return result`), but `Display.lua`/`Highlight.lua` destructured it as `local ok, buttons = OA.safe(...)`, which put the buttons array in `ok` and left `buttons` always nil — the modern `C_ActionBar.FindSpellActionButtons` path was permanently dead in both files (Highlight's copy ran uncached on the 0.1s combat tick). Fixed to `pcall` directly.
- **`Rotation.lua` export-before-declaration** — `OA.Rotation.SPELL_TO_CDKEY = SPELL_TO_CDKEY` ran two lines before `local SPELL_TO_CDKEY = {}`, so it captured the undeclared (nil) global instead of the table, silently disabling IntelligenceLayer's position-1 castability filter. Moved the export below the local's construction.

### Tests Added
- `state-transition: keybind follows the same spellID across a stealth swap`
- `state-transition: highlight glow follows the same spellID across a stealth swap`
- `state-transition: override spell ID resolves to its base and back`
- `state-transition: Ambush recommended only while stealthed`
- `state-transition: every registered event invalidates the keybind cache`
- `state-transition: no error when spell is on no action bar at all`
- `state-transition: OA.Rotation.SPELL_TO_CDKEY is populated (forward-reference fix)`
- `state-transition: modern C_ActionBar.FindSpellActionButtons path is actually used (OA.safe fix)`

## [1.6.0] - 2026-08-01

### Added
- **Action bar glow highlight** — Highlights the recommended ability on the action bar for visual feedback. Probes for available glow mechanisms at runtime (Blizzard API, discovered APIs, self-drawn fallback) and applies to the current position-1 recommendation. Feature can be toggled with `/oa glow` and configured for combat-only mode with `/oa glow combat`.
- **Highlight configuration** — New config options: `highlight.enabled` (default true) and `highlight.combatOnly` (default false) for customizing glow behavior in and out of combat.
- **Debug output extension** — Glow state added to debug output via new `OA.Highlight.AppendDebugOutput()` function for diagnostics (resolved slot, button frame, glow mechanism in use).

### Tests Added
- `highlight: module initializes without error`
- `highlight: stub action button frames in globals`
- `highlight: resolves spellID to correct action button`
- `highlight: exactly one button glows at a time`
- `highlight: clears on disabled toggle`
- `highlight: handles missing spell on action bar`
- `highlight: config defaults include highlight settings`
- `highlight: debug output function exists`

## [1.5.0] - 2026-08-01

### Fixed — Release Blockers (Expert Audit)
- **P0-1: Stealth opener predicting Ambush 4x in a row** — Ambush was marked `gcd=false` (incorrect; breaks stealth on cast consumes GCD), and the simulation never cleared `S.stealthed` after applying Ambush. Result: the bar showed "Ambush Ambush Ambush Ambush" for the first 4 GCDs after stealth, teaching players to spam an ability that can only be used once per opener. Fixed: (1) `gcd=false` → `gcd=true` in ABILITIES table, (2) added `S.stealthed = false` in effects application block after Ambush is cast in simulation.
- **P0-2: Finisher starvation at 5-6 CP** — At 5-6 combo points with finisher available, the bar buried the finisher behind Roll the Bones / Adrenaline Rush / Blade Rush / Preparation (none of which spend CP), preventing it from appearing in the 4-icon visible window. Affects the exact moment a finisher should be spent. Fixed by gating utilities: (1) RtB to not fire when 5+ CP with finisher available, (2) AR to <= 2 CP (consistent with rules.lua), (3) Prep to not fire when 5+ CP with finisher available, (4) BR to not fire when 5+ CP with finisher available.
- **P0-3: PREFER rule demoting finisher at 5 CP** — `rules.lua:sinister_strike_builder` PREFER unconditionally moved SS forward whenever `S.comboPoints <= 5`, overriding `Rotation.lua:Dispatch_finisher` which correctly prioritized spending a ready finisher. Result: position 1 icon said "build more" instead of "spend 5 CP now". Fixed: gated PREFER to `<= 4 CP` so Dispatch at 5 CP is not demoted.
- **P0-4: Killing Spree modeled as 6-CP finisher** — Killing Spree was coded as `cpSpend=6` and gated behind `>= 6 CP`, competing with Between the Eyes as if the player must choose "which 6-CP finisher". In live, Killing Spree is a combo-point-independent burst cooldown (teleports + attacks, uses no CP resource). Result: the addon withheld a major cooldown until combo points were capped, throwing away DPS and breaking leveling rotation advice. Fixed: (1) `cpSpend=6` → `cpSpend=0` in ABILITIES table, (2) renamed `KS_finisher_6cp` rule to `KS_burst_cooldown` and removed CP gate, (3) corrected spell ID citation from 5374 (legacy) to 51690 (current patch).
- **Citation mismatches** — Three ability entries had inline Wowhead links pointing at different spell IDs than what the code actually casts (undermining the "verified 2026-08-01" claims): Sinister Strike cited 1752 (classic/legacy), actually uses 193315; Blade Rush cited 271896, actually uses 271877; Killing Spree cited 5374, actually uses 51690. Fixed all citations to match the IDs in OA.SpellIDs.

### Tests Added
- `P0-1 scenario: Stealth opener` — Verifies Ambush fires once, then next ability differs (not Ambush again)
- `P0-2 scenario: 5 CP finisher priority` — Confirms Dispatch appears at position 1, not buried behind utilities
- `P0-3 scenario: Leveling fixture` — Verifies SS+Dispatch at 5 CP puts Dispatch at position 1 (not demoted by PREFER)
- `P0-4 scenario: Killing Spree low CP` — Confirms KS is available and recommended at 2 CP (not gated to 6 CP)

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
