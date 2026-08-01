# STATE.md — OutlawAssist Project State

**Date:** 2026-08-01  
**Current Version:** v0.2.0 (commit cc26932)  
**Single-Writer:** Orchestrator

## Current State

**Shipping Status:**
- v0.1.0 — M0+M1+M2+M3 complete: API verified, display UI, state tracking, cooldown+trinket advisor shipped
- v0.1.3 — Incident fix: TOC parse-check, deterministic lint gate added
- v0.2.0 — M4 partial: Secret-value hardening (OA.num/OA.bool guards on all API calls) + assist-driven AoE detection (Blade Flurry in queue signals 2+ targets) + TOC lint (fail-closed if comma in Interface line)

**What Works:**
- Core APIs verified in-game (M0 acceptance criteria 7/7 passing)
- Icon queue rendering (5-icon strip, HekiLight parity, GCD greyed, cooldown spirals)
- StateTracker: RtB stage, Opportunity procs, energy/CP, spell/trinket CDs, tier-set detection
- Cooldown + trinket display rows (AR/Blade Rush/Prep + slots 13/14)
- RtB stage + reroll advisory
- 20 decision rules (SOURCE-CITED: SimC + guide consensus; PIN/PREFER/ADVISE engine)
- Secret-value compliance: all UnitPower/GetSpellCooldown/GetItemCooldown/aura returns guarded
- Tests: 20/20 passing; behavioral proof (rule evaluation, state cache, display render)

## NEXT STEPS (Standing Backlog)

1. **User in-game verdict (Party-HP cadence AoE detection):** User runs `/oa apitest` on latest patch + combat-tests party-HP readability. If legal, upgrade AoE detector to HP-cadence (higher fidelity than Blade Flurry queue inference). Blocks M4 completion.

2. **Converge pass (Zero verified defects):** Adversarial review + regression sweep to ZERO known defects before M5 ship.

3. **M4 Completion (HP-cadence AoE if legal):** Party-HP cadence detector as optional high-fidelity AoE advisor (legal-by-construction: UnitHealth("party1..4") readable in combat per research; requires user verdict from step 1).

4. **M5 (CurseForge packaging):** `.pkgmeta` file, full options panel polish, enhanced README (setup, features, limitations), CHANGELOG (all milestones, per-patch notes), user-gated CurseForge upload via GitHub release.

5. **Sim-data refresh cadence (Patch N+1):** Post-patch: run `tools/refresh_sim_data.py` to clone SimC, extract MID1_Rogue_Outlaw.simc, refresh rules.lua (semi-automated; hand-completion + verification required). See docs/SIM-DATA.md for procedure.

## Known Constraints

- Cannot read enemy buffs/cooldowns/health (secret values system)
- No enemy count legal surface (assisted by Blade Flurry queue presence; manual `/oa aoe` toggle for declarative override)
- Outlaw Rogue only (v1 scope; other specs possible in v2+)
- No input automation (recommendation-only; player always chooses)
- Lua 5.1 target (WoW runtime constraint)

## Incidents Logged

- **v0.1.3 (2026-08-01):** TOC Interface line comma-list detection regression. Fix: added `tests/toc_check.lua` fail-closed lint gate. Now part of standard test suite.

## Release Track

- v0.1.0 → v0.1.3 → v0.2.0 (current)
- Next formal release: v0.2.x (converge pass) or v0.3.0 (M5 complete + CurseForge)
