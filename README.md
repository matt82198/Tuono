# Outlaw Assist

A World of Warcraft Midnight (12.0+) addon that provides Hekili-grade rotation guidance for Outlaw Rogue DPS using Blizzard's C_AssistedCombat API as a legal substrate. Instead of simulating combat state (blocked by Midnight's "secret values" system), the addon layers Outlaw-specific intelligence on top of Blizzard's built-in rotation recommendations: Roll the Bones state tracking, cooldown coordination, trinket usage timing, and proc management.

**Status:** Planning phase (PLAN.md available for review).

## Quick Links

- **Master Plan:** [PLAN.md](PLAN.md) — Full design, architecture, milestones M0–M5, risks, and open questions
- **Research Docs:** [docs/research/](docs/research/) — Verified facts about Midnight APIs, Outlaw rotation mechanics, and gear modeling
- **Gearing Guide:** [docs/mplus-gearing-guide.md](docs/mplus-gearing-guide.md) — Mythic+ optimization for reference

## Why This?

Hekili ended January 20, 2026 because Midnight blocked all combat state introspection. But Blizzard provides C_AssistedCombat, a legal rotation recommendation API. Outlaw players report that Blizzard's suggestions don't optimize for Roll the Bones synergy, cooldown windows, trinket timing, or proc management. This addon fills that gap with legally-bounded overrides and advisory layers.

See [PLAN.md](PLAN.md) for the full technical vision.

## Installation

1. Copy the `OutlawAssist/` folder into `World of Warcraft\_retail_\Interface\AddOns\`
2. Launch WoW and log in to a character
3. Type `/reload` to reload the UI
4. Run `/oa apitest` FIRST and verify all checks pass
5. If any checks FAIL, copy the full output and report it as a GitHub issue

## Slash Commands

- `/oa` — List all available commands and settings
- `/oa apitest` — Probe WoW API compatibility; run this first after installation
- `/oa debug` — Print current state dump (energy, CP, RtB stage, cooldowns, trinkets)
- `/oa lock` — Lock the display frame in place
- `/oa unlock` — Unlock the display frame for repositioning
- `/oa scale <0.5-2>` — Adjust display scale (default 1)
- `/oa toggle <queue|cds|trinkets|rtb|procs|ooc>` — Toggle display rows on/off
- `/oa aoe` — Toggle Blade Flurry preference for AoE situations
- `/oa status` — Print current display toggles and settings
- `/oa reset` — Reset all settings to defaults and reposition display
