# Outlaw Rogue WoW Midnight 12.x Rotation Model

**Last Updated:** 2026-08-01  
**Patch:** World of Warcraft Midnight 12.0.7  
**Sources:**
- [Icy Veins Outlaw Rogue Rotation, Cooldowns, and Abilities](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities)
- [Icy Veins Outlaw Rogue DPS Guide](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-guide)
- [Wowhead Outlaw Rogue Rotation Guide](https://www.wowhead.com/guide/classes/rogue/outlaw/rotation-cooldowns-pve-dps)
- [SimulationCraft Rogue Profiles](https://github.com/simulationcraft/simc)

---

## 1. PRIORITY LIST — SINGLE-TARGET

Ordered decision list for single-target rotation. Each rule is checked top-to-bottom; first matching condition executes.

### 1a. Pre-Combat (Stealth Opener)

1. Apply poisons (before entering combat)
2. **Ambush** (from stealth; generates 2 CP, 0 energy cost from stealth)
3. **Roll the Bones** (cast after Ambush to get RtB buff rolling)
4. **Adrenaline Rush** (on cooldown, boost damage; affects energy regen and GCD)
5. **Sinister Strike** as needed to generate CP while in stealth pre-combat

### 1b. Main Rotation (All-In Priority Order)

1. **Roll the Bones** - Cast on cooldown **UNLESS** already at Stage 2 or higher RtB buff active. This is critical for stage progression.
   - Condition: `rtb_stage < 2 AND roll_the_bones.cooldown == 0`
   - Cost: 25 Energy, 0 CP
   - Cooldown: Reduced by Restless Blades

2. **Keep It Rolling** - Extend Roll the Bones duration by 30 seconds when at Stage 3+ RtB. Use to prevent buff expiry.
   - Condition: `rtb_stage >= 3 AND keep_it_rolling.cooldown == 0`
   - Cost: 0 Energy
   - Cooldown: Talent-gated (requires talent)

3. **Adrenaline Rush** - Use on cooldown at any point, especially low CP. Priority over most builders.
   - Condition: `adrenaline_rush.cooldown == 0`
   - Cost: 0 Energy
   - Cooldown: 180 seconds base; reduced by Restless Blades
   - Effect: Energy capacity +50 (to 250), energy regen +60%, GCD reduced by Haste value (min 0.8s)

4. **Blade Rush** - Use on cooldown as a builder/mobility tool. Benefits from Restless Blades.
   - Condition: `blade_rush.cooldown == 0`
   - Cost: 25 Energy
   - CP Generated: 1
   - Cooldown: Reduced by Restless Blades
   - Notes: Dual-role as builder and gap closer

5. **Between the Eyes** - Use on cooldown **with 6+ CP**. Primary finisher for cooldown reduction (Restless Blades benefit: 1.3 sec per CP during Stage 3 RtB).
   - Condition: `combo_points >= 6 AND between_the_eyes.cooldown == 0`
   - Cost: 25 Energy
   - CP Spent: 6 CP (consumes all)
   - Cooldown: Base varies; reduced by Restless Blades (1.0 sec per CP spent, +30% during RtB Stage 3 → 1.3 sec per CP)
   - Effect: Debuffs target; reduces cooldowns of AR, Blade Flurry, Blade Rush, Grappling Hook, Keep It Rolling, Killing Spree, Roll the Bones, Sprint

6. **Preparation** - Reset cooldowns of Adrenaline Rush, Between the Eyes, and Blade Rush.
   - Condition: `(adrenaline_rush.cooldown > 0 OR between_the_eyes.cooldown > 0 OR blade_rush.cooldown > 0) AND preparation.cooldown == 0`
   - Cost: 0 Energy
   - Cooldown: Talent-gated

7. **Killing Spree** - Use on cooldown **with 6+ CP**. Finisher that applies damage buff. Avoid during Supercharger active.
   - Condition: `combo_points >= 6 AND killing_spree.cooldown == 0 AND NOT supercharger_active`
   - Cost: 25 Energy
   - CP Spent: 6 CP
   - Cooldown: Reduced by Restless Blades
   - Effect: Dashes to nearby enemies, applies multiple strikes

8. **Dispatch** - Use as main finisher **with 5-6+ CP** when Between the Eyes and Killing Spree are unavailable.
   - Condition: `combo_points >= 5 AND between_the_eyes.cooldown > 0 AND killing_spree.cooldown > 0`
   - Cost: 25 Energy
   - CP Spent: 5-6 CP
   - Cooldown: 0 (no cooldown)
   - Effect: Direct damage based on CP spent; benefits from Trickster talent (Coup de Grace enhancer)

9. **Pistol Shot** (with Opportunity proc) - Use when you have Opportunity proc **with 6 stacks**. If only 3 stacks and low on energy, use at 1-3 CP.
   - Condition: `opportunity_stacks == 6 AND energy >= 40`
   - Cost: 40 Energy
   - CP Generated: 4 (with Fan the Hammer talent; 1 without)
   - Cooldown: 0
   - Effect: Free cast when Opportunity active; generates multiple CP

10. **Sinister Strike** - Default builder when no other conditions met. Main resource generator.
    - Condition: `energy >= 45`
    - Cost: 45 Energy
    - CP Generated: 1
    - Cooldown: 0
    - Special: Grants Opportunity proc (triggers Pistol Shot availability)

---

## 2. PRIORITY LIST — MULTI-TARGET / BLADE FLURRY VARIANT

**Key difference from single-target:** Blade Flurry is prioritized; otherwise priorities are identical.

1. All entries from **1b Main Rotation** (priority 1-10 unchanged)
   
2. **Blade Flurry** - Insert after Adrenaline Rush (priority 3.5). Use on cooldown **whenever 2+ targets in range**; try to use at low CP to preserve finisher CP for single-target.
   - Condition: `enemy_count >= 2 AND blade_flurry.cooldown == 0 AND combo_points < 5`
   - Cost: 0 Energy
   - Cooldown: Reduced by Restless Blades
   - Duration: 1 minute
   - Damage spread: 28% of Outlaw's damage to additional targets (reduced from 30% in April 2026 balance change)
   - Notes: Fatebound talent increases spread by 5% (to 33%); timing at low CP prevents wasting CP during high-damage finisher windows

---

## 3. ABILITY TABLE

Comprehensive reference for all abilities in the rotation. **GCD** = triggers Global Cooldown; **Talent-Gated** = requires talent selection.

| Ability | Energy Cost | CP Cost | CP Gen | Cooldown (Base) | GCD? | Talent-Gated? | Notes |
|---------|-------------|---------|--------|-----------------|------|---------------|-------|
| Ambush | 0 (stealth) | — | +2 | — | No | No | Stealth-only opener; no energy cost from stealth |
| Adrenaline Rush | 0 | — | — | 180s | No | No | Boosts energy capacity +50, regen +60%, GCD faster |
| Between the Eyes | 25 | 6 | — | Varies | Yes | No | Finisher; applies debuff; reduced by Restless Blades (1.0s/CP, +30% in RtB Stage 3) |
| Blade Flurry | 0 | — | — | Varies | No | No | AoE toggle; 28% damage spread; cooldown reduced by Restless Blades |
| Blade Rush | 25 | — | +1 | Varies | Yes | No | Builder/gap closer; cooldown reduced by Restless Blades |
| Dispatch | 25 | 5-6 | — | None | Yes | No | Finisher; no cooldown; damage scales with CP spent |
| Keep It Rolling | 0 | — | — | Varies | No | Yes | Extends Roll the Bones +30s duration; cooldown reduced by Restless Blades |
| Killing Spree | 25 | 6 | — | Varies | Yes | No | Finisher; dashes to targets; cooldown reduced by Restless Blades |
| Pistol Shot | 40 | — | +1 (or +4 with Fan the Hammer) | None | Yes | Proc-based | Requires Opportunity proc; no cooldown; multiple CP gen |
| Preparation | 0 | — | — | Varies | No | Yes | Resets AR, BtE, Blade Rush cooldowns |
| Roll the Bones | 25 | — | — | Varies | Yes | No | Grants progressive stages 1-4; cooldown reduced by Restless Blades |
| Sinister Strike | 45 | — | +1 | None | Yes | No | Main builder; grants Opportunity on hit |

---

## 4. RESOURCE MODEL

### Energy System

- **Base Maximum:** 100 Energy
- **Base Regeneration:** 10 Energy/sec (not haste-scaled in Midnight 12.x)
- **With Vigor Talent:** Energy max +100 (total 200)
- **During Adrenaline Rush:** Energy max +50 (total 250 base, 350 with Vigor)
- **AR Effect on Regen:** +60% (from 10 to 16 Energy/sec base)
- **Combat Potency Passive:** +25% additional regen (adds 2.5 Energy/sec, stacks with AR for 3.75 Energy/sec during AR)
- **Haste Scaling:** Energy regen is NOT directly haste-scaled; haste affects GCD and Adrenaline Rush's GCD reduction instead

### Combo Points

- **Maximum Combo Points:** 6 points
- **Ruthlessness Passive:** 20% chance per CP consumed by finisher to refund 1 CP (probabilistic; cannot predict)
- **Generation:** Builders (Sinister Strike +1, Blade Rush +1, Ambush +2 from stealth, Pistol Shot +1-4)
- **Consumption:** Finishers (Between the Eyes -6, Killing Spree -6, Dispatch -5-6)
- **Strategic:** Higher CP before finisher = higher Restless Blades cooldown reduction

### Global Cooldown

- **Base GCD:** 1.0 second
- **During Adrenaline Rush:** Reduced by Haste percentage (minimum 0.8 seconds)
  - Example: 15% Haste → GCD = 1.0 - 0.15 = 0.85 seconds
- **GCD-Free Abilities:** Adrenaline Rush, Blade Flurry, Keep It Rolling, Preparation, Ambush (stealth)
- **GCD Application:** All builders (Sinister Strike, Blade Rush, Pistol Shot) and finishers (Between the Eyes, Dispatch, Killing Spree, Roll the Bones)

---

## 5. FINISHER RULES & COMBO POINT THRESHOLDS

### Between the Eyes (Primary Finisher)

- **Trigger Threshold:** 6 CP (exact, all CP consumed)
- **When to Use:** On cooldown when available (prioritized above Dispatch)
- **Why:** Applies debuff; triggers Restless Blades for maximum cooldown reduction (6 sec per cast normally, 7.8 sec during RtB Stage 3)
- **Effect:** Reduces AR, Blade Flurry, Blade Rush, Grappling Hook, Keep It Rolling, Killing Spree, Roll the Bones, Sprint by 1s per CP (base), or 1.3s per CP during RtB Stage 3

### Killing Spree (Secondary Finisher)

- **Trigger Threshold:** 6 CP
- **When to Use:** On cooldown when Between the Eyes is on cooldown AND Supercharger not active
- **Why:** High damage burst finisher; triggers Restless Blades
- **Avoid Condition:** Never use during Supercharger active (wastes potential)

### Dispatch (Fallback Finisher)

- **Trigger Threshold:** 5-6 CP (flexible; use at 5+ when higher priority finishers unavailable)
- **When to Use:** When Between the Eyes and Killing Spree both have active cooldowns
- **Why:** No cooldown; always available; scales damage with CP
- **Advantage:** Can be used at lower CP (5) compared to primary finishers (6), allowing faster cycle when needed

### Roll the Bones Reroll Policy

**CRITICAL MECHANIC:** Roll the Bones was reworked in Midnight; stages are cumulative.

- **Stage Progression:**
  - Stage 1 (55% initial): Sinister Strike +20% double-strike chance, grants Opportunity
  - Stage 2 (30% upgrade): SS/Ambush +1 CP, +15% damage (includes Stage 1)
  - Stage 3 (10% upgrade): Restless Blades +30% CDR (includes prior stages; **HIGHEST PRIORITY STAGE**)
  - Stage 4 (5% upgrade): +10% crit chance (includes all prior buffs)

- **Reroll Decision Rule:**
  - **At Stage 1 or 2:** Reroll immediately (cast Roll the Bones on cooldown) to progress to Stage 3
  - **At Stage 3 or 4:** Do NOT reroll; maintain buff; use Keep It Rolling to extend duration before it expires
  - **Duration:** Each stage lasts a base duration; Keep It Rolling extends by 30 seconds
  - **CDR Benefit of Stage 3:** +30% to Restless Blades means finishers apply 1.3s cooldown reduction per CP instead of 1.0s

- **Deterministic Reroll:** The stage progression is deterministic (no RNG on stage advancement once applied); the proc chance to upgrade is given, so the simulation can treat it as guaranteed progression on each RtB cast

---

## 6. OPENER: EXACT STEALTH SEQUENCE

### Pre-Combat Setup (Outside Combat)

1. Apply poisons to weapon(s)
2. Enter Stealth (automatic; rogue ability)
3. Position within melee range of target

### Combat Opener (At Pull / First GCD)

1. **Ambush** (from stealth, 0 energy cost)
   - Generates: +2 CP (now at 2/6 CP)
   - No cooldown; breaks stealth and begins combat

2. **Roll the Bones** (immediately after Ambush)
   - Cost: 25 Energy (8/100 energy remaining)
   - Effect: Grants Stage 1 buff (55% of RtB casts land on Stage 1; deterministic for this cast)
   - **Reroll Logic Applies:** If Stage is <2, will reroll on cooldown

3. **Adrenaline Rush** (third ability, on cooldown at pull)
   - Cost: 0 Energy (cooldown-based)
   - Effect: +50 energy capacity (now 100+50=150 max), +60% regen boost
   - GCD affected: Future casts reduced by Haste percentage (min 0.8s)

4. **Continue Main Rotation** (priority list 1b) once opener completes

### Alternative: No-Stealth Opener (Forced Pull Without Stealth)

- Skip Ambush; start with Sinister Strike instead
- Proceed to Roll the Bones and Adrenaline Rush as above
- Loss: 2 CP and stealth benefit

---

## 7. SIMULATION NOTES: DETERMINISTIC VS PROBABILISTIC

### SAFE TO SIMULATE (Deterministic)

These mechanics can be predicted forward in a rotation simulator; they are guaranteed outcomes:

1. **Energy Regeneration:** Constant 10 Energy/sec base, +6 during AR, affected by Combat Potency passive (never random)
2. **Cooldown Reduction (Restless Blades):** Exact formula: 1.0 sec per CP spent (or 1.3 sec during RtB Stage 3). Deterministic given CP count.
3. **Global Cooldown:** Exact timing: 1.0s base or reduced by Haste during AR. Fully predictable.
4. **Roll the Bones Stage Progression:** Once a stage is applied, the next progression is guaranteed (no RNG per stage); can be simulated forward.
5. **Ability Costs:** All energy and CP costs are fixed; no variance.
6. **Cooldown Duration:** Ability cooldowns are fixed base values, reduced by Restless Blades deterministically.

### UNSAFE TO SIMULATE (Probabilistic)

These mechanics involve RNG and CANNOT be predicted; simulation must treat them as "unknown" and re-evaluate when observed:

1. **Opportunity Proc:** Sinister Strike has a proc chance to grant Opportunity stacks (for Pistol Shot use). Cannot predict *when* it procs.
   - **Simulation Decision:** Either assume 100% uptime (best-case) or ignore it (worst-case); real rotation varies per pull.

2. **Ruthlessness Refund:** 20% chance per CP consumed to refund 1 CP. Probabilistic; cannot predict which finisher triggers refund.
   - **Simulation Decision:** Assume no refund (conservative) or average 20% refund per finisher (optimistic).

3. **Roll the Bones Initial Stage:** While stage progression is deterministic, the INITIAL stage on first RtB cast has probabilities:
   - 55% → Stage 1
   - 30% → Stage 2
   - 10% → Stage 3
   - 5% → Stage 4
   - **Simulation Decision:** Model the lucky 3+ stage case for DPS ceiling, or average stages for realistic prediction.

4. **Critical Strikes (RtB Stage 4):** +10% crit passive from Stage 4. Crit % is probabilistic on each ability hit.
   - **Simulation Decision:** Include static crit % in damage model; do not model individual crit RNG.

5. **Fan the Hammer Proc:** Generates extra Opportunity stacks or CP. Talent-gated and proc-based.
   - **Simulation Decision:** Model as proc chance or ignore for conservative prediction.

### SIMULATION HORIZON RECOMMENDATION

Given the probabilistic elements above, a **rotation simulator can honestly predict 1-3 GCDs forward** with high confidence (energy, cooldowns, CP next 3 GCDs are deterministic). Beyond that, assumptions about proc uptime become load-bearing; track them as "likely" vs "guaranteed."

**UNVERIFIED UNCERTAINTIES** (gaps where sources disagree or unclear):

1. **Opportunity Proc Rate:** Icy Veins does not state the exact proc % of Sinister Strike granting Opportunity. SimulationCraft code would have exact value.
   - Source Gap: [Icy Veins Rotation](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities) states "use Pistol Shot when you have an Opportunity proc" but not the proc rate itself.

2. **Restless Blades Scaling in RtB Stage 3:** Icy Veins states "+30% increased CDR," interpreted as 1.3s per CP (base 1.0 × 1.30 = 1.3). Confirmation needed in-game.
   - Source: [Icy Veins](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities) — exact mechanic clear, math implied but not explicit.

3. **Fan the Hammer CP Generation:** States "Pistol Shot grants 4 CP with Fan the Hammer" but does not clarify if this stacks with Ruthlessness refund logic.
   - Source: [Icy Veins](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities) — CP generation stated, interaction with refund unclear.

4. **Blade Flurry Cooldown Base Duration:** Icy Veins implies cooldown is controlled by Restless Blades but does not state a base cooldown.
   - Source Gap: No explicit base cooldown stated; behavior inferred as "cooldown reduced by Restless Blades."

5. **Stealth Opener Exact Sequence:** Icy Veins mentions "open from Stealth" and "cast Ambush" but does not provide the exact command sequence or timing after Ambush.
   - Source: [Icy Veins DPS Guide](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-guide) — high level, not granular.

---

## 8. IMPLEMENTATION CHECKLIST FOR LUA ADDON

Use this section to validate a Lua rotation predictor against the model:

- [ ] **Resource Tracking:** Energy pool (0-250 base, +50 with Vigor, +50 during AR), combo points (0-6)
- [ ] **Cooldown State:** Track cooldowns for Adrenaline Rush, Between the Eyes, Blade Rush, Blade Flurry, Roll the Bones, Keep It Rolling, Killing Spree, Preparation
- [ ] **Buff State:** Active Roll the Bones stage (0-4), Adrenaline Rush active, Opportunity stacks
- [ ] **Priority Logic:** Implement decision tree from §1 (single-target) and §2 (multi-target/AoE)
- [ ] **Restless Blades CDR:** Apply 1.0s per CP spent to cooldowns (or 1.3s during RtB Stage 3)
- [ ] **GCD Calculation:** 1.0s base, reduced by Haste % during AR (min 0.8s)
- [ ] **Energy Regen:** +10/sec base, +6/sec during AR, +2.5/sec from Combat Potency (stacks)
- [ ] **Output Format:** Predicted next 3-5 casts as: `[Ability, Energy After, CP After, Cooldown Remaining]`
- [ ] **Prediction Caveat:** Flag Opportunity and Ruthlessness as "uncertain" in output; mark confidence as "high" only for first 3 GCDs

---

## 9. SOURCES & CITATION REFERENCE

| Source | Patch | Last Updated | Primary Use |
|--------|-------|--------------|------------|
| [Icy Veins Rotation](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities) | 12.0.7 | June 2026 | Priority list, ability costs, cooldowns, resource values, finisher rules, RtB mechanics |
| [Icy Veins DPS Guide](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-guide) | 12.0.7 | June 2026 | Opener sequence, high-level strategy |
| [Wowhead Rotation Guide](https://www.wowhead.com/guide/classes/rogue/outlaw/rotation-cooldowns-pve-dps) | 12.0.7 | April 2026 | Corroboration (content not fully fetched) |
| [SimulationCraft Rogue Module](https://github.com/simulationcraft/simc) | Varies (T31 last confirmed) | Dynamic | APL structure, ability definitions, conditional logic |

---

**Document Purpose:** Machine-implementable reference for Outlaw Rogue rotation prediction in WoW Midnight 12.x. Not a strategy guide; intended for addon/simulator development.
