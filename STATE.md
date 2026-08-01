# STATE.md — OutlawAssist Project State

**M0 API VERIFICATION: PASSED IN-GAME 2026-08-01** — /oa apitest on the live client reports all
probes PASS except the deliberately-SKIPped legacy UnitBuff fallback. Spell IDs independently
verified by an Outlaw specialist. Remaining live unknown: whether GetRotationSpells is static or
live (run /oa watch on a dummy; decides whether a true multi-step sequence is possible at all).

**VERIFIED IN LIVE COMBAT 2026-08-01 (/oa watch, 52 samples):** C_AssistedCombat.GetNextCastSpell
is STATIC — 1 distinct value, 0 changes across the window; GetRotationSpells never changed. It does
not react to procs and does not switch to a finisher at max combo points. CONSEQUENCE: wrapping
Blizzard's recommendation cannot produce a live sequence. The forward-simulating rotation engine
(docs/research/rotation-model.md) is the sequence source; Blizzard is a static fallback only, and
must be labeled as such wherever shown. OPEN: v1.1.1 probe enumerates alternative accessors
(GetNextCastSpell(true), GetActionSpell, C_ActionBar assisted queries, ASSISTED_* events) to see
whether any accessor IS proc-aware — Blizzard's own UI highlight reportedly reacts to procs.

**Date:** 2026-08-01  
**Current Version:** v0.2.3 (consolidated)  
**Interface Pin:** 120007 (live 12.0.7)  
**Status:** Converge CLEAN 2026-08-01 (zero verified defects)  
**Single-Writer:** Orchestrator

## Current State

**Shipping Status:**
- v0.1.0 — M0+M1+M2+M3 complete: API verified, display UI, state tracking, cooldown+trinket advisor shipped
- v0.1.3 — Incident fix: TOC parse-check, deterministic lint gate added
- v0.2.0 — M4 partial: Secret-value hardening (OA.num/OA.bool guards on all API calls) + assist-driven AoE detection (Blade Flurry in queue signals 2+ targets) + TOC lint (fail-closed if comma in Interface line)
- v0.2.2/v0.2.3 — Converge pass: 2 P0s confirmed+fixed, rules refreshed, tests 20→33 de-tautologized, one false-green caught by orchestrator re-run, suite 33/33 deterministic

**What Works:**
- Core APIs verified in-game (M0 acceptance criteria 7/7 passing)
- Icon queue rendering (5-icon strip, HekiLight parity, GCD greyed, cooldown spirals)
- StateTracker: RtB stage, Opportunity procs, energy/CP, spell/trinket CDs, tier-set detection
- Cooldown + trinket display rows (AR/Blade Rush/Prep + slots 13/14)
- RtB stage + reroll advisory
- 20 decision rules (SOURCE-CITED: SimC + guide consensus; PIN/PREFER/ADVISE engine)
- Secret-value compliance: all UnitPower/GetSpellCooldown/GetItemCooldown/aura returns guarded
- Tests: 33/33 passing deterministic; behavioral proof (rule evaluation, state cache, display render)

## NEXT STEPS (Ordered)

1. **AoE Detection Verification (v0.3.0 prerequisite):** User runs `/oa apitest` to validate threat-table detection (`C_NamePlate.GetNamePlates()` + `UnitThreatSituation()` legality + behavior in live combat). Confirm: does threat-count accurately detect 2+ enemies? Are APIs available on Midnight 12.0.7+?

2. **Aug 11 Interface bump:** When 12.1 launches, bump Interface pin to 120100 in TOC; verify no API surface changes impact threat-detection or existing rules.

3. **v0.3.0 Finalization:** Lock threat-table AoE detection (M4 feature complete); ship with `/oa apitest` results documented; call for user feedback on detection accuracy.

4. **M5 (CurseForge packaging):** `.pkgmeta` file, full options panel polish, enhanced README (setup, features, limitations, AoE detection method), CHANGELOG (all milestones, per-patch notes), user-gated CurseForge upload via GitHub release.

5. **Sim-data refresh cadence:** Post-patch: run `tools/refresh_sim_data.py` to clone SimC, extract MID1_Rogue_Outlaw.simc, refresh rules.lua (semi-automated; hand-completion + verification required). See docs/SIM-DATA.md for procedure.

## Known Constraints

- Cannot read enemy buffs/cooldowns/health (secret values system)
- No enemy count legal surface (assisted by Blade Flurry queue presence; manual `/oa aoe` toggle for declarative override)
- Outlaw Rogue only (v1 scope; other specs possible in v2+)
- No input automation (recommendation-only; player always chooses)
- Lua 5.1 target (WoW runtime constraint)

## Incidents Logged

- **v0.1.3 (2026-08-01):** TOC Interface line comma-list detection regression. Fix: added `tests/toc_check.lua` fail-closed lint gate. Now part of standard test suite.

## Release Track

- v0.1.0 → v0.1.3 → v0.2.0 → v0.2.2/v0.2.3 (current, converge CLEAN)
- Next: M4 completion (party-HP if legal) → v0.3.0 (M5 CurseForge + docs)

## PRODUCT DIRECTION (user, 2026-08-01): UI SUITE

Scope expands from "rotation bar" to a minimalist UI package, Liquid/Maximum-inspired, old-WeakAuras
aesthetic (flat bars, thin borders, condensed fonts, no beveling):
- Rotation bar: CENTER of screen (this is the anchor of the layout, not an off-to-the-side widget).
- Health bar: minimalist.
- Unit frames + party frames: restyled to match the same aesthetic.
- Nameplates: USER HANDLES THESE - do not build nameplate styling.
Research in flight: docs/research/liquid-ui-style.md (aesthetic tokens), docs/research/unitframe-feasibility.md
(can unit/party frames even be built in Midnight: secure frames, taint, whether party health is
readable in combat). Feasibility gates the whole suite - if party health is secret in combat, party
frames cannot show live health and the design must change.

### UI-SUITE FEASIBILITY VERDICT (2026-08-01, docs/research/unitframe-feasibility.md)
- Player/target/party frames: BUILDABLE-WITH-LIMITS. SecureGroupHeaderTemplate works for party;
  set up out of combat, never restructure in combat.
- Health BARS: buildable via Blizzard's C_CurveUtil, which accepts a secret health value and maps
  it to bar width - so visual bars work in combat.
- NUMERIC health / health-% TEXT in combat: BLOCKED. UnitHealth returns secrets in raids/M+ and
  cannot be compared or formatted. Consequence for the Liquid look: bar fill yes, numbers no.
  Any percent text must be hidden in combat rather than shown stale.
- Dispel highlighting: BUILDABLE (C_UnitAuras.GetAuraDispelTypeColor).
DECISION PENDING (user): accept a numbers-free-in-combat aesthetic, or drop party frames.

### UI-SUITE: CANCELLED (user, 2026-08-01)
User cancelled after the feasibility verdict — numeric health/percent text is blocked in combat by
Midnight's secret values, so the Liquid look could not be delivered faithfully. Do NOT resurrect
unit frames / party frames / health bars. Research kept for reference only
(docs/research/liquid-ui-style.md, docs/research/unitframe-feasibility.md).
SOLE FOCUS: the Outlaw rotation helper. Ship a green build the user can play.

### DECISION LOG (afk, 2026-08-01)
- RELEASES ARE NOT GATED FOR THIS REPO. The generic hard-gate list treats `gh release create` as
  user-gated, but precedent overrides it here: the user asked for GitHub releases as the delivery
  channel ("go back to pushing to github"), has installed ~12 of them today, and is actively
  waiting on the next. Zip releases to this private repo continue autonomously.
  REVERSAL: user says stop, or the repo goes public/npm (npm publish stays gated).
- SHIP ORDER (user, explicit): no release until the pre-ship audits clear — Outlaw expert +
  adversarial bug hunt. Findings get adjudicated by the orchestrator before any fix lane.
- ROOT CAUSE SHIPPED UNRELEASED (03bcab9): two dedup passes were collapsing the predicted sequence
  by spellID, so "Sinister Strike x4" rendered as one icon and 5 CP rendered as Dispatch + one
  leftover — the user's "perma dispatch and one more icon". Sequence steps now bypass dedup.
- GAP THAT ALLOWED IT: 145 unit tests were green while live play was broken. tests/scenario_bar.lua
  (end-to-end harness printing what the BAR shows) found it in minutes. Converting that harness into
  asserting tests is queued as the structural fix.

### DECISION (afk, 2026-08-01): cooldown reminders vs sequence slots
The adversarial audit flagged that a full 4-step sequence pushes rule-derived cooldown/trinket
reminders out of the visible bar. ACCEPTED, not fixed: the user's explicit requirement is that the
bar shows the SEQUENCE ("it should always show 4"), and major cooldowns already appear IN the
sequence when they are the correct press (Adrenaline Rush, Blade Rush and Preparation are priority
rules). A separate reminder for something the sequence already handles is duplication.
REVERSAL: if the user asks to see cooldowns that are ready but not yet the right press, reserve a
trailing slot for extras rather than growing the bar.
