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
