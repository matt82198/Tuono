# OutlawAssist

A World of Warcraft Midnight (12.0+) addon that provides Hekili-grade rotation guidance for Outlaw Rogue DPS using Blizzard's `C_AssistedCombat` API as a legal substrate.

**What it does:** Midnight blocks third-party combat state introspection (the "secret values" system), so traditional rotation simulators like Hekili cannot exist. Instead, OutlawAssist reads Blizzard's built-in rotation recommendations via `C_AssistedCombat.GetNextCastSpell()` and layers Outlaw-specific intelligence on top: Roll the Bones stage tracking, cooldown coordination, trinket usage timing, and proc management. The addon displays a unified rolling bar with kind-colored borders (cooldown orange, trinket purple, RtB gold, opener teal), per-icon keybind labels, reactive polling (fast in combat, event-forced on miscast/target-swap), and threat-table AoE detection (2+ enemies, composite signal with manual `/oa aoe` override). Aura tracking is hardened for Midnight secret values. Player always chooses—addon recommends.

**Status:** Core APIs verified in-game. Feature-complete for M4 (AoE detection shipped beyond spec; threat-count primary). See [Releases](https://github.com/matt82198/outlaw-assist/releases) for current version and changelog.

## Installation

1. Download the latest release from [Releases](https://github.com/matt82198/outlaw-assist/releases)
2. Extract the ZIP file to `World of Warcraft\_retail_\Interface\AddOns\`
3. **IMPORTANT TRAP #1: Windows Extract-All creates a nested folder.** After extraction, verify your directory structure is:
   ```
   Interface\AddOns\OutlawAssist\OutlawAssist.toc
   Interface\AddOns\OutlawAssist\Core.lua
   Interface\AddOns\OutlawAssist\StateTracker.lua
   ...
   ```
   NOT `Interface\AddOns\OutlawAssist\OutlawAssist\OutlawAssist.toc`. If you see nested folders, move the inner `OutlawAssist` folder one level up to the correct path.

4. Launch WoW and log in to an Outlaw Rogue character
5. **IMPORTANT TRAP #2: Addon may be flagged "out of date."** Before logging in, open the Addons pane and tick **"Load out of date AddOns"**
6. Type `/oa apitest` to verify all APIs are available (see TROUBLESHOOTING below if anything fails)
7. Type `/oa` to list available commands

## Troubleshooting

### Addon not appearing in WoW
- **Check path nesting:** Verify `Interface\AddOns\OutlawAssist\OutlawAssist.toc` exists (NOT nested double-OutlawAssist)
- **Enable "Load out of date AddOns":** In the Addons pane, tick the checkbox before logging into the world
- **Reload UI:** Type `/reload` to reload the UI if you're already in-game

### Addon shows but display is empty or no suggestions appear
- **Run API test:** Type `/oa apitest` and check for any FAIL lines. Copy the output and report to GitHub if you see failures.
- **Check you're in combat:** The addon only displays during combat by default. Type `/oa toggle ooc` to show out-of-combat display, or test on a training dummy.
- **Verify character is Outlaw Rogue:** The addon only functions on Outlaw Rogue characters. Check your talent tree.
- **View debug output:** Type `/oa debug` to print a live state dump (energy, combo points, cooldowns, trinket status)

### Login errors or missing modules
- **Check for errors:** Type `/console scriptErrors 1` then `/reload` to enable detailed Lua error messages in the game console (Escape → System → Lua Errors)
- **Check canary message:** v0.1.3+ prints a login message showing which modules loaded. Check chat or type `/oa status`
- **Report errors:** Paste any red Lua errors into a [GitHub Issue](https://github.com/matt82198/outlaw-assist/issues)

## Slash Commands

**Display & Layout:**
- `/oa` — List all available commands and settings
- `/oa lock` — Lock the display in place (disable dragging)
- `/oa unlock` — Unlock the display for repositioning
- `/oa scale <0.5-2>` — Adjust display scale (default: 1)
- `/oa icons <1-8>` — Set icon count in unified rolling bar (default: 4)
- `/oa toggle <queue|cds|trinkets|rtb|procs|ooc>` — Toggle a display row on/off
  - `queue` — Rotation queue (Blizzard's suggestions + our priority hints)
  - `cds` — Cooldown layer (Adrenaline Rush, Blade Rush, Preparation)
  - `trinkets` — Equipped trinket cooldowns (slots 13, 14)
  - `rtb` — Roll the Bones stage and reroll advisory
  - `procs` — Opportunity proc timer overlay
  - `ooc` — Show display out-of-combat (default: hidden OOC)

**Features:**
- `/oa aoe` — Toggle AoE mode (manual override for Blade Flurry; threat-table detection is primary, composite 2+ enemies)
- `/oa reset` — Reset all settings to defaults and reposition display

**Diagnostics:**
- `/oa apitest` — Probe API compatibility. Run this first after installation. Report FAIL lines as GitHub issues.
- `/oa debug` — Print a one-shot state dump (energy, combo points, cooldowns, trinket state, etc.)
- `/oa status` — Print current display toggles and feature settings

## Architecture

OutlawAssist is modular: Core provides event dispatcher and frame management; StateTracker polls readable combat state (own buffs, energy, combo points, cooldowns, trinket IDs) every frame via events; AssistReader queries Blizzard's `C_AssistedCombat` rotation queue each frame; IntelligenceLayer applies Outlaw-specific decision rules (distilled from SimulationCraft and community guides) to PIN/PREFER spells in Blizzard's queue or emit advisories; Display renders the result as distinct visual channels (rotation row, cooldown row, trinket row, RtB state panel, proc overlay) so you always know each suggestion's source. Config manages saved settings and slash routing. For full technical design, diagrams, and open questions, see [PLAN.md](PLAN.md). For module interfaces and build contract, see [docs/CONTRACT.md](docs/CONTRACT.md).

## Development

### Run Tests
```bash
lua tests/run_tests.lua
```
Tests use a Lua 5.4 harness that stubs the WoW API surface and exercises rule evaluation, state caching, and display rendering logic.

### Verify a Code Change
```bash
# In-game
/oa apitest      # Verify APIs are available
/oa debug        # Check state updates
```
Then test in combat on a training dummy and watch the display for correct suggestions.

### Refresh Sim Data (Post-Patch)
When WoW patches, SimulationCraft's Midnight profiles may update. To refresh the rule set:
1. Clone SimulationCraft: `git clone --branch midnight https://github.com/simulationcraft/simc.git`
2. Locate Outlaw profiles: `simc/profiles/MID1/MID1_Rogue_Outlaw.simc`
3. Extract priority APL rules and cross-reference against [docs/research/outlaw-rotation.md](docs/research/outlaw-rotation.md)
4. Update [OutlawAssist/data/rules.lua](OutlawAssist/data/rules.lua) with new conditions, citing SimulationCraft section numbers
5. Run `lua tests/run_tests.lua` to verify rule syntax
6. Test in-game on a training dummy

## Known Limitations

- **Midnight secret values:** Cannot read enemy buffs, debuffs, or cooldowns. No interrupt planning, no targeted defensives, no fight-mechanic awareness.
- **Enemy counting:** Cannot count nearby enemies legally. Blade Flurry advisory requires manual AoE toggle (`/oa aoe`); presence is inferred from whether Blade Flurry appears in Blizzard's queue.
- **Multi-spec:** Outlaw Rogue only for v1. Assassination and Subtlety not supported.
- **No input automation:** Addon displays suggestions only. You press the button—it never does (ToS-compliant by design).

## License

MIT. See LICENSE file.

## Contributing

Bug reports and feature requests: [GitHub Issues](https://github.com/matt82198/outlaw-assist/issues)

Community maintainers wanted. See PLAN.md §7 for bus-factor mitigation and the documented sim-data refresh process for rotating maintainer handoff.
