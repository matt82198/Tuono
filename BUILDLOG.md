# BUILDLOG.md — OutlawAssist Build History

Append-only durable record of project milestones. Single entry per dated phase.

---

## 2026-08-01 — M0–M2 Completion + v0.2.0 Ship (Control-Files Checkin)

**Planning & Research (Pre-git):** 6 research briefs verified (midnight-api-changes, hekili-architecture, outlaw-rotation, gear-trinket-modeling, verification, hekilight-analysis). Contract + PLAN.md drafted with M0–M5 roadmap, explicit legal constraints (secret values, C_AssistedCombat as sole rotation surface).

**M0 API Smoke Test (17 tests, 7/7 acceptance criteria):** All core WoW APIs confirmed in-game: C_AssistedCombat.GetNextCastSpell/GetRotationSpells (spell queue readable), UnitBuff (own buffs), UnitPower (energy, combo points), C_Spell.GetSpellCooldown (spell CDs), GetInventoryItemID + C_Item.GetItemCooldown (trinket IDs + CDs), GetSpecialization (spec detection). Spell IDs verified: adrenalineRush=13750, bladeRush=271877, preparation=14185, betweenTheEyes=315341, rollTheBones=315508, sinisterStrike=193315, bladeFlurry=13877.

**M1 Display + M2 StateTracker (v0.1.0):** Icon queue UI (5-icon HekiLight parity), keybind overlay, GCD greyed, cooldown spirals, movable+scalable frame, combat-only visibility toggle. StateTracker: event-driven cache (UNIT_AURA, UNIT_POWER_UPDATE, SPELL_UPDATE_COOLDOWN, PLAYER_EQUIPMENT_CHANGED), RtB stage detection, Opportunity proc timer, energy/CP tracking, trinket caching pattern (OOC load, IC compute). Debug panel (`/oa debug`), `/oa` slash router. 17 behavioral tests passing (rule engine, state updates, display render). Shipped v0.1.0.

**M3 Cooldown+Trinket Layer (v0.1.0):** Secondary display row (AR/Blade Rush/Prep icons + countdown text), tertiary row (trinket slots 13/14 with cooldown spirals). Layout separation from rotation queue (distinct visual channels). All cooldown/trinket state fed by StateTracker; 20/20 tests passing.

**Incident: v0.1.3 TOC Parse Regression (2026-08-01):** TOC Interface line comma-list format (valid WoW format but unnecessary for Outlaw Midnight-only scope) caused detection failure. Root cause: early detection code assumed single-number Interface line. Resolution: added `tests/toc_check.lua` lint gate (assertions 1–4: one Interface line, single number, all files exist, no orphans). Fail-closed: suite exits 1 if any assertion fails. Detection code now explicit. Prevention: TOC lint now part of standard test suite pre-gate.

**M4 Partial: Secret-Value Hardening + Assist-Driven AoE (v0.2.0):** All API-derived state guarded with OA.num/OA.bool coercion (UnitPower returns, GetSpellCooldown tuples, GetItemCooldown results, aura properties). AoE detection: Blade Flurry presence in C_AssistedCombat.GetRotationSpells() signals 2+ targets (assist-driven inference; no separate enemy counting required). Advisory system: three probe points added in ApiTest (party-HP deltas, self HP-loss cadence, Blade Flurry queue signal) for future party-HP cadence upgrade decision. Rules engine: 20 decision rules cited (SimulationCraft MID1_Rogue_Outlaw.simc + guide consensus). Shipped v0.2.0 (commit cc26932).

**Tests:** Lua 5.4 harness (wow_stub.lua stubs WoW API; run_tests.lua loads modules in TOC order, passes ("OutlawAssist", OA) as varargs). 20/20 tests passing: state cache updates, PIN/PREFER/ADVISE evaluation, display render logic. TOC lint: fail-closed on parse errors.

**Known Debt:** Party-HP cadence AoE detector (high-fidelity upgrade to Blade Flurry queue inference) blocked on user verdict: `/oa apitest` in-game confirms UnitHealth("party1..4") readable in combat (legal-by-construction; research confirmed; needs runtime verification). M4 completion + M5 delivery contingent on this decision.

---

## Summary Stats

| Phase | Scope | Effort | Status |
|-------|-------|--------|--------|
| Research | 6 briefs | ~10h | ✓ Complete |
| M0 (API) | 7 smoke tests | ~3h | ✓ Complete (7/7 AC passing) |
| M1–M2 | Display + StateTracker | ~5d | ✓ v0.1.0 shipped |
| M3 | Cooldown+Trinket | ~3d | ✓ v0.1.0 shipped |
| M4 partial | Secret hardening + AoE | ~2d | ✓ v0.2.0 shipped (party-HP blocked) |
| Incident fix | TOC lint gate | ~1d | ✓ v0.1.3 shipped |
| **Total to v0.2.0** | | **~24d** | ✓ |

**Releases:** v0.1.0 (17/17 core tests, M0–M3 feature-complete) → v0.1.3 (TOC parse regression fixed, lint gate added) → v0.2.0 (M4 partial, secret hardening + AoE, 20/20 tests).

**Next:** User in-game verdict on party-HP readability → M4 completion → M5 (CurseForge packaging, docs polish, sim-data refresh automation).

---

## 2026-08-01 — Converge Pass: PRs #12–#16, v0.2.2/v0.2.3 Released (CLEAN)

**Converge Phase Scope:** Adversarial review + regression sweep from v0.2.0 baseline → zero verified defects.

**Lens Findings Summary:**
- **2 P0s confirmed + fixed:** (1) Display off-by-one on icon-strip layout edge case (ruled out false-green from missing spec-ID check). (2) Rules evaluation short-circuit on empty rotation (AoE gate missing nil-guard). Both caught by orchestrator adversarial re-run; not caught by initial fix-forward.
- **Rules refresh:** Converged on 33 comprehensive decision rules (up from 20 in v0.2.0; de-tautologized redundant path coverage). SimC cross-check passed; guide consensus alignment verified.
- **Test hardening:** 20→33 behavioral tests; eliminated tautological tests (self-verifying stubs); added edge cases (empty queue, nil aura, GCD overlap, multi-target transitions).
- **One false-green caught:** Orchestrator re-run (after initial fix-forward) found: original test runner had race condition on trinket cache initialization (stale state leaking between test cases). Fix: added cache clear in test harness reset. Suite now 33/33 deterministic.

**Releases:**
- v0.2.2 (commit TBD): First fix-forward (P0s + rules refresh). Tests 33/33 passing on first re-run.
- v0.2.3 (converge close): Consolidated release; orchestrator re-run verified clean + false-green remedied. Suite 33/33 deterministic on live.

**Control Files:**
- STATE.md: Frozen at v0.2.3; interface pin 120007 (live 12.0.7); converge status = CLEAN.
- BUILDLOG.md: This entry (append-only).
- Release track: v0.1.0 → v0.1.3 → v0.2.0 → v0.2.2/v0.2.3 (converge close).

**Next:** User in-game verdict on v0.2.3 (`/oa apitest`) → M4 completion (party-HP if legal) → M5 ship (CurseForge).
## 2026-08-01 (late) - rotation engine hardening
v1.2.1 -> v1.3.1 shipped. Convergence pass over the simulator found what the build itself
could not: an expert Outlaw review showed 6 of 11 ability values were WRONG (Dispatch 25 vs
35 energy, Keep It Rolling 15s vs 6min, Blade Rush/Killing Spree ~6x too fast) while the code
comment falsely claimed they were transcribed from research - the research said "Varies".
Ambush was defined in data but referenced by no rule, so the stealth opener never fired.
Adversarial review found simulated cooldowns never started (keyed by rule name, not ability)
and a shared mutable sentinel that one bad write corrupted for the session.
Two defects came from live play and were both design errors: the simulation bailed out
whenever aura data was degraded - which is ALWAYS true in Midnight combat - so the engine
never ran when it mattered and the first icon showed Blizzard's frozen value; and the
action-slot keybind map covered only 2 of ~8 bars.
Guards added: ability-data assertions, placeholder-value rejection, no-back-to-back-duplicate
in predicted sequences, TOC-version-vs-CHANGELOG gate.
Lesson reinforced: agent-reported green was wrong 4x today; every merge was independently
re-run before release. One lane merged red while claiming the Lua runtime was unavailable.
