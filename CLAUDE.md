# OutlawAssist — Project CLAUDE.md

**What:** WoW Midnight addon providing Hekili-grade rotation guidance for Outlaw Rogue DPS via Blizzard's C_AssistedCombat API (legal substrate under Midnight's secret-values system).

## Domain Map

- **OutlawAssist/** — Addon modules: Core (event dispatch + frame loop), StateTracker (combat state cache: buffs, energy, CPs, cooldowns, trinkets), AssistReader (C_AssistedCombat poller), IntelligenceLayer (PIN/PREFER rule engine), Display (UI renderer), Config (settings/slash routing), ApiTest (verification probes)
- **data/rules.lua** — Decision rules table (20 Outlaw-specific rules: APL priorities, cooldown sequencing, proc management, source-cited from SimulationCraft + guide consensus)
- **tests/** — Lua 5.4 harness (wow_stub.lua, run_tests.lua); 20/20 tests green; behavioral proof (PIN/PREFER/ADVISE evaluation)
- **tools/refresh_sim_data.py** — Sim-data refresh pipeline (post-patch: clone SimC, extract MID1_Rogue_Outlaw.simc, refresh rules.lua)
- **docs/** — PLAN.md (M0–M5 roadmap, 6 milestones, risks/open questions), CONTRACT.md (cross-module interfaces, TOC load order, per-lane API contracts), research/ (5 docs: verification, midnight-api-changes, outlaw-rotation, gear-trinket-modeling, hekili-analysis)

## Gates

**REAL gate:** `"C:\Users\matt8\AppData\Local\Programs\Lua\bin\lua.exe" tests\run_tests.lua` (exit 0, 20/20 passing).
**Parse gate:** Lua 5.1-compatible (WoW runtime) + must parse under Lua 5.4 (build gate).
**Secret-scan gate:** `python C:\Users\matt8\scripts\secret_scan.py --staged` (abort on fail before push).

**Branch discipline:** Feature branches only; PR + MERGED-state verification; worktrees only (never checkout primary tree).

**Release channel:** GitHub release with ZIP asset (user's WoW PC pulls latest release; sanctioned delivery, no CurseForge auto-publish).

**Lua constraints:** 5.1-compatible, no new globals except `OutlawAssistDB` (Core), no io/os/require/setfenv/goto, ASCII only, OA.num/OA.bool coercion for ALL WoW API returns (secret-value guards), rules table distilled from docs only (no invented mechanics).

**Truth hierarchy:** In-game test (/dump calls) > stub tests > code inspection. In-game live behavior beats PLAN assumptions; stub must fail-against-broken-code when proving guards.
