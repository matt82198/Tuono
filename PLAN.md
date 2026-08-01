# Outlaw Assist: Master Planning Document

**Version:** 1.0  
**Date:** 2026-08-01  
**Target:** WoW Midnight 12.0 Addon for Outlaw Rogue DPS  
**Scope:** Combat rotation guidance only; uses C_AssistedCombat as legal substrate; intelligence layer adds Outlaw-specific context

---

## 1. Executive Summary

**Product Thesis:** Midnight killed third-party rotation simulation (blocked all combat state introspection via "secret values"). The legal technical substrate is Blizzard's `C_AssistedCombat` API, which exposes Blizzard's built-in rotation recommendations. Existing wrappers (HekiLight, Knickili) are display-only and spec-agnostic. Our edge: a **legally-bounded Outlaw-specific intelligence layer** layered atop C_AssistedCombat that:

1. Reads Blizzard's suggested spell queue via `GetNextCastSpell()` and `GetRotationSpells()`
2. Caches Outlaw state readable in combat: own buffs (Roll the Bones stage + duration via `UnitBuff("player")`), energy/combo points via `UnitPower()`, own spell cooldowns via `C_Spell`, trinket cooldowns via `C_Item.GetItemCooldown()`, equipped item IDs
3. Applies Outlaw-specific decision rules (distilled offline from SimulationCraft and guide consensus) to **override or elevate** Blizzard's position-1 suggestion when high-value conditions met (e.g., "reroll bad RtB", "hold finisher for major cooldown window", "use trinket during AR")
4. Renders rich UI: Blizzard queue + cooldown/trinket layer as distinct visual channels, so player always knows which source recommends what

**Target UX:** Hekili-grade guidance (prioritize by situation, not just "button glow"), max sustained DPS for Outlaw, combat-only focus. Player always chooses—addon recommends.

---

## 2. Hard Constraints (Verified)

### What IS Readable in Combat

| Category | API/Method | Verified | Notes |
|----------|-----------|----------|-------|
| **Player's own buffs** | `UnitBuff("player", [spellID or name])` | ✅ verification.md §D3 | Roll the Bones, Adrenaline Rush, Opportunity tracked |
| **Energy resource** | `UnitPower("player", SPELL_POWER_ENERGY)` | ✅ verification.md §D3 | Baseline 100, +100 Vigor talent, +100 AR |
| **Combo points** | `UnitPower("player", SPELL_POWER_COMBO_POINT)` | ✅ verification.md §D3 | Readable throughout combat |
| **Own spell cooldowns** | `C_Spell.GetSpellCooldown(spellID)` returns {duration, startTime, isEnabled} | ✅ verification.md §D3 | Adrenaline Rush, Blade Rush, Preparation cooldowns queryable |
| **Trinket cooldowns (equipped)** | `C_Item.GetItemCooldown(itemID)` | ✅ verification.md §D3 + gear-trinket-modeling.md | Slots 13, 14 cached out-of-combat; timer computed in-combat |
| **Equipped item IDs** | `GetInventoryItemID("player", slotID)` for slots 13, 14 | ✅ gear-trinket-modeling.md | Works out-of-combat; TrinketTracker pattern caches, computes in-combat |
| **Blizzard's rotation queue** | `C_AssistedCombat.GetNextCastSpell()` + `GetRotationSpells()` | ✅ verification.md §D1 | Per-frame polling legal; includes checkForVisibleButton param |
| **Player's own spell icons/data** | `C_Spell.GetSpellInfo(spellID)` | ✅ implicit | Texture, name, cast time |

**Citation:** All verified in research/verification.md §D3 (Legal Augmentation Surface) and midnight-api-changes.md §2–3 (C_AssistedCombat functions).

---

### What Is NOT Readable in Combat

| Category | Reason | Consequence |
|----------|--------|-----------|
| **Enemy unit auras** | Secret values system (Patch 12.0.0) blocks `C_UnitAuras` during combat | Cannot read enemy buffs/debuffs; no targeting logic possible |
| **Combat log events** | `COMBAT_LOG_EVENT_UNFILTERED` removed from addon API | No proc detection via combat log; must use buff-event fallback |
| **Enemy cooldowns** | Secret values; prevents PvP exploit | Cannot plan around boss ability timings |
| **Unit health (other players)** | Restricted in combat scenarios | No defensive triage logic |
| **Aura durations in combat (auras other than player's own)** | Secret values on non-player units | Buff-tracking limited to caches + event-driven updates |

**Citation:** midnight-api-changes.md §1–4 (Secret Values System) and verification.md §D3 (not readable).

---

### Ethics & ToS: Recommendation vs. Automation

**Hard Line:** The addon RECOMMENDS actions; it NEVER automates input or simulates without player consent. Specifically:

- **Legal:** Display overlay suggesting "press Adrenaline Rush now" with visual highlight
- **Legal:** Show queued spells from C_AssistedCombat with priority hints ("this one first")
- **Legal:** Keybind overlays (show which key to press)
- **Illegal:** Automatically execute keybind presses (one-button automation)
- **Illegal:** Simulate combat log to drive decisions (not accessible anyway)

**Source:** verification.md §D2 (Community Outlaw-Specific Improvement Opportunities) and midnight-api-changes.md §2 (Anti-Automation Design) both emphasize "player chooses whether to follow the recommendation."

---

## 3. Architecture

### Module Breakdown & Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    Outlaw Assist Addon                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐           ┌────────────────────────────┐ │
│  │  AssistReader    │           │   StateTracker             │ │
│  │  ────────────    │  (frame)  │   ──────────────           │ │
│  │ • Poll           │────────►  │ • Cache RtB buff stage     │ │
│  │   GetNextCast()  │           │ • Track Opportunity stack  │ │
│  │ • Queue          │           │ • Current energy/CPs       │ │
│  │   GetRotation()  │           │ • Own spell CDs            │ │
│  │ • Render next    │           │ • Trinket slot IDs + CDs   │ │
│  │   suggest spell  │           │ • Tier-set count (OOC)     │ │
│  └──────────────────┘           └────────────────────────────┘
│            │                              │
│            │ (per-frame snapshot)         │ (event-driven)
│            └──────────────┬───────────────┘
│                           │
│  ┌────────────────────────▼────────────────────────────────┐
│  │        IntelligenceLayer (Rule Engine)                  │
│  │        ──────────────────────────────                   │
│  │  DATA: rules.lua table (Outlaw APL distilled offline)   │
│  │  LOGIC:                                                 │
│  │  • If RtB stage 1 & no AR soon → PREFER reroll         │
│  │  • If BtE ready & 6+ CP → PIN to top                   │
│  │  • If AR up & trinket ready → suggest on-use           │
│  │  • If 2+ targets → suggest Blade Flurry                │
│  │                                                         │
│  │  OUTPUT: { priority (1-3), reason, override }          │
│  └────────────────────────┬─────────────────────────────────┘
│                           │
│  ┌────────────────────────▼────────────────────────────────┐
│  │             Display (UI Renderer)                       │
│  │             ──────────────────                          │
│  │  Channel 1 (PRIMARY): Blizzard's spell + our priority  │
│  │  Channel 2 (COOLDOWN): AR, Blade Rush, Preparation    │
│  │  Channel 3 (TRINKET): Equipped trinkets 13, 14         │
│  │  Channel 4 (RtB): Current stage + reroll advisory      │
│  │                                                         │
│  │  Movable, scalable, combat-only visibility            │
│  └────────────────────────┬─────────────────────────────────┘
│                           │
│  ┌────────────────────────▼────────────────────────────────┐
│  │            Config & Profiles                            │
│  │            ────────────────────                          │
│  │  Per-feature toggles, one-command reset                │
│  └─────────────────────────────────────────────────────────┘
│
└─────────────────────────────────────────────────────────────────┘
```

### Module Details

#### **AssistReader** — Blizzard API Poller
- **Responsibility:** Query `C_AssistedCombat.GetNextCastSpell()` per frame; cache result; fetch full queue via `GetRotationSpells()`
- **Implementation:** PLAYER_ENTERING_COMBAT, per-frame OnUpdate loop (throttled to avoid frame hitches)
- **Output:** {nextSpellID, queue=[spellID, spellID, ...], isReady}
- **Legal surface:** `checkForVisibleButton` parameter supported (includes custom action buttons)
- **Source:** verification.md §D1 (Queue Depth, Function Parameters)

#### **StateTracker** — Event-Driven State Cache
- **Responsibility:** Maintain readable player state durable across frame updates
- **Readable inputs:**
  - Roll the Bones buff: `UnitBuff("player", "Roll the Bones")` → {stage, duration} (stage inferred from stack count)
  - Opportunity procs: `UnitBuff("player", "Opportunity")` → {stack, remaining_duration}
  - Energy: `UnitPower("player", SPELL_POWER_ENERGY)` and UnitPowerMax
  - Combo points: `UnitPower("player", SPELL_POWER_COMBO_POINT)`
  - Spell CDs: `C_Spell.GetSpellCooldown(id)` for the Outlaw cooldown set — Adrenaline Rush, Blade Rush, Preparation (spell IDs are PLACEHOLDERS until the M0 in-game /dump verifies them; do not hardcode before M0)
  - Trinket slots: `GetInventoryItemID("player", 13)`, slot 14; CDs via `C_Item.GetItemCooldown(itemID)` (cached out-of-combat)
  - Tier set count: count 2pc/4pc equipment out-of-combat
- **Event sinks:** UNIT_AURA (unit=="player"), UNIT_POWER_UPDATE, SPELL_UPDATE_COOLDOWN, PLAYER_EQUIPMENT_CHANGED (combat-log aura events are unavailable in Midnight — own-buff changes arrive via UNIT_AURA; see §2)
- **Caching strategy:** TrinketTracker pattern (see gear-trinket-modeling.md) — cache trinket IDs on load; compute cooldown timers via elapsed time in-combat
- **Source:** verification.md §D3; hekilight-analysis.md §7 (Feasible-Verified features)

#### **IntelligenceLayer** — Rule Engine
- **Responsibility:** Apply Outlaw-specific decision rules to Blizzard's queue
- **Rules are DATA, not code:** Single Lua table (`data/rules.lua`) containing if/then conditions, distilled offline from:
  - SimulationCraft Midnight profiles: `profiles/MID1/MID1_Rogue_Outlaw.simc` (see research/outlaw-rotation.md §3)
  - Guide consensus: Method, Icy Veins, Murlok.io top-performer builds
  - Patch-specific tweaks documented per rule
- **Example rules (pseudocode, from outlaw-rotation.md §1–2):**
  ```
  - rule: adrenaline_rush_priority
    condition: combo_points <= 2 AND energy > 50
    action: PIN adrenaline_rush to position 1
    source: Method Playstyle; SimC MID1_Rogue_Outlaw.simc
    
  - rule: roll_the_bones_reroll_advisory
    condition: rtb.stage == 1 AND ar_cooldown > 20
    action: PREFER "keep_it_rolling" in position 2-3 (soft suggestion)
    source: outlaw-rotation.md "Reroll Mechanics"
    
  - rule: between_the_eyes_finisher
    condition: combo_points >= 6
    action: PIN between_the_eyes to position 1
    source: Method "Between the Eyes — Primary finisher at 6+ CP"
    
  - rule: blade_flurry_aoe_advisory
    condition: nearby_enemies >= 2
    action: PREFER "blade_flurry" elevation in queue
    reason: "Cleave damage scales with enemy count"
    source: icy-veins.md "AoE Rotation"
    
  - rule: trinket_during_ar
    condition: ar_buff.up AND trinket.cooldown.ready
    action: SUGGEST "use_trinket" overlay advisory
    source: outlaw-rotation.md "On-Use Trinket Strategy"
  ```
- **Execution:** For each frame: evaluate all rules, accumulate overrides (PIN takes precedence over PREFER), emit merged queue to Display
- **Legal surface:** PIN/PREFER pattern proven by TrueShot (verification.md §D3, hekilight-analysis.md §7.6)
- **Source:** outlaw-rotation.md (priority, mechanics, cooldowns); hekili-architecture.md §6 (reusable patterns: ability handlers, state prediction via effects)

#### **Display** — UI Renderer (Icon Queue + Layers)
- **Layout:**
  - **Primary row (ROTATION):** 5 spell icons from AssistReader queue; position 1 highlighted (Blizzard's suggestion)
  - **Secondary row (COOLDOWNS):** Adrenaline Rush, Blade Rush, Preparation (3 icons) with countdown timers
  - **Tertiary row (TRINKETS):** Slots 13, 14 with cooldown spirals (TrinketTracker pattern)
  - **Quaternary row (RtB STATE):** Current Roll the Bones stage (1–4) + "reroll advisory" glow if PREFER active
  - **Proc indicator:** Opportunity duration overlay on primary icon when procced (hekilight-analysis.md §7.1–4)
- **Visuals:**
  - HekiLight parity (movable icon strip, scalable, customizable spacing)
  - Channel separation: distinct colors/borders so user always knows which source (Blizzard vs. our rules)
  - Keybind overlay on primary spell (fetch via WoW's keybind system)
  - GCD greyed overlay (HekiLight style)
  - Cooldown spiral on CDs (standard addon pattern)
- **Visibility:** Combat-only toggle (hide OOC option); hide-during-dead, hide-during-cinematics
- **Config:** Slash command `/oa` (Outlaw Assist) → options panel
- **Source:** hekilight-analysis.md (HekiLight display system); hekili-architecture.md §5 (icon rendering, display system)

#### **Config** — Settings & Profiles
- **Per-feature toggles:**
  - Show Blizzard queue (yes/no)
  - Show cooldown layer (yes/no)
  - Show trinket tracker (yes/no)
  - Show RtB state + advisory (yes/no)
  - Show Opportunity timer (yes/no)
- **One-command reset:** `/oa reset` restores defaults
- **Persistence:** Saved variables (WoW standard)
- **Advanced:** Profile import/export (future v2, not M5 scope)

---

## 4. Explicit Non-Goals

- **Interrupts/kicks/stuns:** Not in scope (defensive use, not DPS optimization)
- **Defensives (Cloak of Shadows, Evasion):** Out-of-scope for v1; possible future enhancement
- **Non-combat features:** No talent guides, stat priority calculators, gearing advice in-addon (all out of scope)
- **Anything needing secret values:** Cannot read enemy buffs, boss cooldowns, raid mechanics state
- **Input automation:** No one-button press; never execute macros; player always chooses
- **Multi-spec:** Outlaw Rogue only for v1 (single-spec laser focus)
- **PvP optimization:** PvE combat focus only (enemy state is blocked anyway)

---

## 5. Sim-Data Pipeline

**How sim truth enters the addon:**

1. **Offline Distillation** (per patch, ~2 hours manual work post-patch):
   - Clone SimulationCraft Midnight branch: `git clone --branch midnight https://github.com/simulationcraft/simc.git`
   - Locate Outlaw profiles: `profiles/MID1/MID1_Rogue_Outlaw.simc` and `MID1_Rogue_Outlaw_Trickster.simc` (source: outlaw-rotation.md §3)
   - Extract priority rules from `.simc` file (APL syntax)
   - Cross-reference Method, Icy Veins, Murlok.io top builds for real-player consensus
   - Hand-distill into `data/rules.lua` table with per-rule source citations
   - Example rule entry:
     ```lua
     rules.adrenaline_rush_on_cooldown = {
       condition = "combo_points <= 2",
       action = "PIN",
       source = "SimC MID1_Rogue_Outlaw.simc (adrenaline_rush,if=combo_points<=2)",
       verified_by = "Method Playstyle Guide",
       patch = "12.0.7"
     }
     ```

2. **Verification Gate:**
   - Run addon in training-dummy scenario (combat-only)
   - Spot-check: does rule fire when expected? (e.g., "AR when CP <= 2")
   - Manual override: if real-world playtesting shows rule hurts DPS, mark with `TODO` for patch

3. **Patch Refresh Cadence:**
   - **Weekly:** Check WarcraftLogs top-10 parses for any meta shifts
   - **Patch day:** Clone SimC, extract new profiles, refresh `rules.lua`
   - **Quarterly:** Full audit (link to CurseForge release notes)

4. **No Runtime Scraping:** Data is checked in as versioned Lua files; never fetched from web at runtime (addon-safe, no external dependencies)

**Source:** outlaw-rotation.md §3 (SimulationCraft Midnight branch, profiles directory)

---

## 6. Milestones M0–M5

### **M0: Repo Scaffold & API Smoke Test** (Size: S)

**Deliverable:**
- GitHub repo initialized (MIT license)
- TOC file scaffold (addon manifest)
- `/dump` test harness: in-game Lua command that calls each API function we depend on, prints result
- README outline

**Acceptance Criteria:**
- `/dump C_AssistedCombat.GetNextCastSpell()` returns a spell ID in combat ✓
- `/dump C_AssistedCombat.GetRotationSpells()` returns a table of spell IDs ✓
- `/dump UnitBuff("player")` returns at least one buff ✓
- `/dump UnitPower("player", SPELL_POWER_ENERGY)` returns a number 0–200 ✓
- `/dump C_Spell.GetSpellCooldown(13750)` returns {duration, startTime, isEnabled} ✓
- `/dump GetInventoryItemID("player", 13)` returns item ID (out of combat) ✓
- `/dump C_Item.GetItemCooldown(itemID)` works for that item ✓

**Why First:** THE FABRICATION FIREWALL. If any function signature changed post-research, we catch it before building on lies. Every function name and parameter verified in-game.

**Effort:** ~2–3 hours (scaffold, test harness, in-game verification)

---

### **M1: HekiLight Display Parity** (Size: M)

**Deliverable:**
- Icon queue UI rendering (5 icons, customizable)
- Reads `C_AssistedCombat.GetNextCastSpell() + GetRotationSpells()`
- Shows next spell with keybind overlay, cooldown spiral, GCD grey
- Movable, scalable, combat-only visibility
- Basic `/oa` options panel

**Acceptance Criteria:**
- Addon displays 5-icon strip during combat ✓
- Primary (leftmost) icon matches Blizzard's GetNextCastSpell() ✓
- Secondary icons match queue (skips on-cooldown spells) ✓
- Keybind text overlays correctly ✓
- Icons grey during GCD ✓
- Cooldown spiral shows remaining time ✓
- Drag-to-move, scale slider works ✓
- `/oa hide ooc` toggle works ✓
- Matches HekiLight visual style (reference: screenshot from CurseForge)

**Training-Dummy Protocol:** 
- Equip baseline gear (no raid-specific items)
- Stand still, auto-attack dummy for 60s
- Verify icon strip shows suggestions, updates without framerate drops
- No errors in game console

**Effort:** M (~4–5 days, one developer; mostly UI code borrowed/adapted from HekiLight open-source patterns)

---

### **M2: StateTracker Complete + Visible Debug Panel** (Size: M)

**Deliverable:**
- StateTracker caches all readable state (RtB, Opportunity, energy, CP, spell CDs, trinket CDs, tier set)
- Event-driven updates (UNIT_AURA for own buffs, UNIT_POWER_UPDATE, SPELL_UPDATE_COOLDOWN, PLAYER_EQUIPMENT_CHANGED)
- Debug panel (toggle via `/oa debug`) showing live state: "RtB stage: 2, AR CD: 15s, Energy: 67/100"
- Trinket caching pattern (out-of-combat load, in-combat compute)

**Acceptance Criteria:**
- `/oa debug` panel shows current RtB stage (0–4) ✓
- Opportunity stack count updates on UNIT_AURA after Sinister Strike ✓
- Energy display updates per regen tick ✓
- CP count accurate ✓
- AR cooldown timer accurate (vs. `/run print(select(1, C_Spell.GetSpellCooldown(13750)))`) ✓
- Blade Rush CD accurate ✓
- Trinket 1 & 2 slot IDs cached on PLAYER_ENTERING_WORLD ✓
- Trinket cooldown timers tick down correctly ✓
- Tier set count (2pc/4pc) reads correctly out-of-combat ✓

**Training-Dummy Protocol:**
- Cast abilities, watch debug panel update in real-time
- Verify state snaps to actual values (no lag, no phantom buffs)
- Equip/unequip trinkets, verify IDs cache on next load

**Effort:** M (~4–5 days; event plumbing, cache invalidation, debug UI)

---

### **M3: Cooldown + Trinket Advisor Layer** (Size: M)

**Deliverable:**
- Secondary display row: Adrenaline Rush, Blade Rush, Preparation (3 icons) with countdown timers
- Tertiary display row: Trinket slots 13, 14 (equipped item icons) with cooldown spirals
- State from M2 feeds these (spell CDs, trinket CDs)
- Layout: clear separation from rotation queue (different color/border)

**Acceptance Criteria:**
- Cooldown row shows AR, Blade Rush, Prep icons ✓
- AR icon glows green when ready, grey when on CD with countdown ✓
- Blade Rush & Prep CDs track correctly ✓
- Trinket icons display (fetch via `C_Item.GetItemInfo()`) ✓
- Trinket cooldown spirals tick down ✓
- Trinket row hides if no trinkets equipped ✓
- Visual separation from rotation queue is clear ✓

**Training-Dummy Protocol:**
- Verify cooldown timers match in-game cooldown tooltips (use `/run` to compare)
- Equip different trinkets, verify icons update

**Effort:** M (~3–4 days; trinket icon fetching, layout logic)

---

### **M4: RtB/Proc Guidance + AoE Advisory** (Size: L)

**Deliverable:**
- **RtB State Panel:** Displays current Roll the Bones stage (1–4) + remaining duration + "reroll advisory" glow if stage is suboptimal
- **Opportunity Timer:** Overlay on primary rotation icon showing remaining duration (e.g., "5 sec")
- **AoE Advisory:** When 2+ targets detected (OPEN QUESTION: how to count enemies legally—see §8), show Blade Flurry elevation in queue or as separate advisory
- **IntelligenceLayer rules.lua:** Hardcoded Outlaw APL rules (20–50 rules) with source citations

**Acceptance Criteria:**
- RtB stage display shows correct stage (1–4) ✓
- RtB duration counts down correctly ✓
- "Reroll advisory" highlights when stage 1 detected & no AR soon ✓
- Opportunity timer visible when procced, counts down to 0 ✓
- Blade Flurry advisory activates when 2+ enemies nearby (NEEDS-VERIFICATION: detection method) ✓
- At least 20 rules loaded from `data/rules.lua` ✓
- Each rule has source citation (SimC or guide link) ✓
- Rules apply correctly (spot-check 3–5 rules manually during combat)

**Training-Dummy Protocol:**
- With multi-target dummy setup (if available), verify Blade Flurry advisory fires
- Cast Sinister Strike to proc Opportunity, watch timer appear
- Reroll RtB several times, verify advisory fires at stage 1 (and doesn't fire at stage 3+)

**Effort:** L (~5–7 days; rules distillation, testing against varied combat scenarios, target-count verification)

---

### **M5: Sim-Data Refresh Pipeline + Options Polish + CurseForge** (Size: L)

**Deliverable:**
- `tools/refresh_sim_data.sh` script: clone SimC Midnight, extract MID1_Rogue_Outlaw.simc, generate `data/rules.lua` template (semi-automated; hand-completion still required)
- Enhanced `/oa` options panel: per-feature toggles (show queue, show CDs, show RtB, show trinkets), reset button
- `.pkgmeta` & packaging for CurseForge
- README: setup, features, known limitations, how to file issues
- CHANGELOG: all milestones, per-patch update notes

**Acceptance Criteria:**
- `refresh_sim_data.sh` clones SimC, locates profiles ✓
- Script generates Lua table skeleton with APL conditions ✓
- Options panel toggles hide/show each layer ✓
- `/oa reset` restores defaults ✓
- CurseForge upload successful (syntax check passed, tags applied) ✓
- README complete (setup, usage, limitations, open questions) ✓
- No frame hitches at 60 FPS (tested on potato PC @ 800x600) ✓

**Training-Dummy Protocol:**
- Full 5-minute combat session, all features enabled
- Disable each feature one-by-one, verify correct layers vanish
- Verify FPS doesn't drop below 55 on low-end hardware

**Effort:** L (~4–6 days; docs, CurseForge packaging, polish pass)

---

## 7. Risks & Mitigations

| Risk | Likelihood | Impact | Description | Mitigation |
|------|------------|--------|-------------|-----------|
| **API Drift Mid-Expansion** | Medium | HIGH | Blizzard could widen "secret values" scope, blocking energy/combo/trinket reads mid-expansion. We'd lose StateTracker. | M0 smoke test catches breaking changes same-day. Alert users immediately; mark addon "broken" on CurseForge until fix ships. No auto-update; manual patch required. |
| **C_AssistedCombat Internals Change** | Low | MEDIUM | Blizzard could change GetNextCastSpell/GetRotationSpells signature or behavior. | M0 smoke test catches. Fallback: display static "Blizzard's rotation assistant changed; contact addon author" message. Addon degrades gracefully. |
| **Research Residue (Haiku-Sourced Facts)** | Medium | MEDIUM | Some facts in research docs were Haiku-synthesized and not verified in-game (e.g., "Vendetta is an Outlaw CD" — it's not; it's Assassination). Rules table would encode wrong priorities. | M0 smoke test and manual rules verification catch this. Cross-reference outlaw-rotation.md against in-game talent trees before shipping. |
| **Single-Dev Bus Factor** | HIGH | MEDIUM | If only one dev maintains addon, patch delays post-expansion-major-balance-update. | Document sim-data refresh process & rule syntax clearly. Encourage community contributions (GitHub PR model). Ship with "community maintainer wanted" badge. |
| **Sim-Data Patch Cadence Lag** | Low | LOW | Real-world top-DPS builds diverge from SimC recommendations. Rule table becomes stale. | Weekly WarcraftLogs check; mark stale rules with "PATCH X.Y pending" in code. Alert users on load if last-update > 2 weeks. |

---

## 8. Reconciliations: Known Contradictions from Research

### Contradiction A: Vendetta & Marked for Death as Outlaw CDs

**Finding:** hekilight-analysis.md §7.3 lists "Major Cooldown Layer (Vendetta, Adrenaline Rush, Marked for Death)" as Outlaw cooldowns to track.

**Conflict:** outlaw-rotation.md lists Outlaw major DPS cooldowns as: **Adrenaline Rush, Blade Rush, Preparation** (§2). Vendetta is **Assassination** (not Outlaw). Marked for Death is **Subtlety** (not Outlaw).

**Resolution:** hekilight-analysis.md §7.3 is a **generic template** for "any rotation addon" and copied cooldown names without Outlaw-spec verification. The correct Outlaw cooldown tracker (M3) will use **Adrenaline Rush, Blade Rush, Preparation** only, per outlaw-rotation.md §2.

**Authority:** outlaw-rotation.md is the authoritative Outlaw mechanics reference (§DATA CURRENCY STATEMENT); hekilight-analysis.md is an architectural overview. **Outlaw-specific cooldowns = AR + Blade Rush + Prep.**

### Contradiction B: Umbral Plume Trinket Status (On-Use vs. Passive)

**Finding:** outlaw-rotation.md §4 describes Umbral Plume with conflicting wording:
- Line 182–183: "Umbral Plume (On-Use) – Large on-use cooldown"
- Line 200: "Plume trinkets are large enough to warrant on-cooldown usage"

**Interpretation:** Umbral Plume is an **on-use trinket** (requires player to press button); not passive. "Large enough to warrant" = high damage bonus justifies active key press during AR windows.

**Resolution:** Will treat as on-use in M3 (trinket cooldown tracker will show it alongside spell cooldowns). If real-world testing shows otherwise, mark as `TODO` for patch.

**Authority:** outlaw-rotation.md §4 Table (On-Use) is explicit; this is not actually contradictory, just requires active management.

---

## 9. Open Questions

| Question | Impact | Path to Resolution |
|----------|--------|-------------------|
| **How to count nearby enemies legally?** | HIGH (AoE advisory in M4 blocked) | Verify in-game: Can `C_UnitAuras` or `GetNumGroupMembers()` APIs detect enemy count from nameplate/aura filtering? Does Blizzard's Assisted Combat use a method we can match? M0 smoke test or ask on WowInterface forums. If impossible, M4 advisory defaults to "manual switch to AoE APL" (not auto-detected). |
| **Exact GetRotationSpells return shape?** | MEDIUM | M0 smoke test `/dump` call will reveal table structure. Verify keys (name, id, cooldown?, usability?). Document in code. |
| **Addon distribution policy?** | LOW | CurseForge upload (M5) will clarify ToS compliance. Confirm: does "recommendation overlay on Blizzard's queue" violate anti-automation rules? Likely not (HekiLight, Knickili precedent), but CurseForge review may ask for clarification. Be prepared to explain: "We only display suggestions; player always chooses." |
| **Will PLAYER_EQUIPMENT_CHANGED fire on trinket swap mid-combat?** | MEDIUM (affects trinket cache freshness) | Test in M0: Equip, swap trinket OOC, swap back in combat, verify event fires. If event fires in combat, M2 can refresh cache; if not, stale IDs acceptable (trinket slots don't change mid-pull in practice). |
| **Are all rule conditions deterministically verifiable from readable state?** | MEDIUM (M4 correctness) | Verify each of 20+ rules in `data/rules.lua` can be evaluated using only StateTracker outputs. If a rule needs "enemy health %" or "remaining fight time", flag as `FUTURE` (needs different legal surface). |
| **Patch 12.1+ buff API changes impact proc tracking?** | MEDIUM (Opportunity timer in M4) | Research: "Curse of Ula'tek (Patch 12.1) introduced API changes" (hekilight-analysis.md §7.7). Verify whether `UnitBuff("player", "Opportunity")` still works. If blocked, use fallback: cache `UNIT_SPELLCAST_SUCCEEDED` timestamp + 20s hardcoded (less precise but functional). |

---

## 10. Source Index

All claims grounded in these research documents (6 total):

1. **research/midnight-api-changes.md** — Midnight's secret values system, C_AssistedCombat API surface, what is/isn't readable in combat. Authority on legal addon surface.

2. **research/hekili-architecture.md** — Hekili's snapshot-based state prediction, resource modeling, buff aliasing, display system. Reusable design patterns (but underlying APIs now blocked).

3. **research/outlaw-rotation.md** — Outlaw spec mechanics (Roll the Bones stages, Adrenaline Rush, Between the Eyes, Blade Rush, Opportunity procs), cooldowns, gear, SimulationCraft profile locations. Authority on Outlaw priorities.

4. **research/gear-trinket-modeling.md** — Equipment detection APIs (GetInventoryItemID, C_Item), PLAYER_EQUIPMENT_CHANGED event, TrinketTracker caching pattern. Basis for M3 trinket cooldown tracker.

5. **research/verification.md** — Adversarial fact-checking of all research claims. Confirms readable state (own buffs, energy, CPs, spell/trinket CDs), legal augmentation patterns (PIN/PREFER), community-identified Outlaw guidance gaps. Authority on "what's actually legal".

6. **research/hekilight-analysis.md** — HekiLight implementation deep-dive, feature gaps, do-better opportunities ranked by feasibility. Roadmap for M1–M4 feature prioritization.

---

## Closing Notes

This plan lays out a roughly 4–6 week (part-time, single developer) development roadmap — the M0–M5 effort estimates sum to ~20–25 focused dev days to ship a production-quality Outlaw Assist addon that stays within Midnight's legal addon boundaries while delivering Hekili-grade UX. The key insight: **Blizzard's rotation assistant is a usable substrate; our job is to add Outlaw context without breaking ToS.**

Every module in §3 and every acceptance criterion in §6 is verifiable, testable, and grounded in the research. M0 is the fabrication firewall; every function is confirmed in-game before we commit to it.

For contributor/team expansion: see §7 (bus factor mitigation). The addon is designed to be maintainable by a rotating maintainer role; sim-data refresh is documented and semi-automatable.

---

**Document Version:** 1.0  
**Last Updated:** 2026-08-01  
**Next Review:** Post-M0 API smoke test (blockers identified → plan updated)
