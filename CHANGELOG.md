# Changelog

All notable changes to OutlawAssist are documented here.

## [1.2.0] - 2026-08-01

### Added
- **Forward-simulating rotation engine** — New `OA.Rotation.Predict()` function computes the next 1-4 ability casts deterministically based on current state (energy, combo points, cooldowns, RtB stage). Predicts energy regeneration, cooldown reduction (Restless Blades: 1.0 sec/CP, +30% in RtB Stage 3), and GCD advancement across the simulation horizon.
- Rotation priorities transcribed from research/rotation-model.md with single-target and AoE variants (Blade Flurry priority insertion).
- Confidence tracking (high for steps 1-3, low for 4+) reflecting determinism ceiling beyond ~3 GCDs.
- Fallback to Blizzard assist when prediction yields no castable ability (degraded state or out-of-resources).

### Changed
- IntelligenceLayer now wires OUR predicted sequence into the queue as source=<ruleName> entries, tagged with confidence. Blizzard's live value (OA.Assist.nextSpellID) still merges as a safety net and is compared for UI agreement display (OA.Engine.blizzAgrees).

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
