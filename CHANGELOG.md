# Changelog

All notable changes to OutlawAssist are documented here.

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
