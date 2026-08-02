# Outlaw Rogue Fresh Level 80 Kit — WoW Midnight 12.0.7

**Research Date:** August 2026 | **Patch:** 12.0.7 | **Expansion:** Midnight

## Level Cap & Levelling Range

**Level cap: 90.** A fresh-80 character is at the **end of The War Within expansion** and begins Midnight's levelling arc: **80 → 90** (10 levels).

Sources:
- Wowhead Leveling Guide: https://www.wowhead.com/guide/classes/rogue/outlaw/dps-leveling-tips
- Blizzard official: level-cap confirmation in official patch notes (12.0.7)

---

## Baseline vs. Talented Abilities

| Ability | Status | Notes |
|---|---|---|
| **Sinister Strike** | BASELINE | Core combo-point generator |
| **Dispatch** | BASELINE | Execute finisher |
| **Roll the Bones** | BASELINE | Reworked in Midnight: 4-stage escalating buff (no longer random) |
| **Ambush** | BASELINE | Opener from Stealth |
| **Pistol Shot** | BASELINE | Auto-generates Opportunity procs |
| **Between the Eyes** | BASELINE | Combo-point finisher |
| **Slice and Dice** | BASELINE | Duration buff (still exists post-Midnight) |
| **Vanish** | BASELINE | Stealth exit ability |
| **Stealth** | BASELINE | Opener stance |
| **Blade Flurry** | BASELINE | AoE toggle (available to fresh 80) |
| **Adrenaline Rush** | TALENTED | Spec tree, Row 2 (mandatory single node) |
| **Blade Rush** | TALENTED | Spec tree, Row 6 |
| **Killing Spree** | TALENTED | Spec tree, Row 10 (capstone, choice option) |
| **Keep It Rolling** | TALENTED | Spec tree, Row 10 (capstone, alternative to Killing Spree) |
| **Preparation** | TALENTED | Spec tree, Row 10 (capstone, choice option) |

**Source:** Wowhead (https://www.wowhead.com/guide/classes/rogue/outlaw/abilities-talents-pve-dps) + Icy Veins (https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-spell-summary) — cross-verified, zero conflicts.

**Summary:** A fresh 80 has **9 core baseline abilities** (Sinister Strike, Dispatch, Roll the Bones, Ambush, Pistol Shot, Between the Eyes, Slice and Dice, Vanish, Stealth, Blade Flurry). The remaining 5 (Adrenaline Rush, Blade Rush, Killing Spree, Keep It Rolling, Preparation) are talent-gated, with Adrenaline Rush being the first mandatory pick at Row 2.

---

## Combo Point Maximum at Fresh 80

**Baseline (zero talents): 5 combo points.**

**Talent increases (available within fresh-80 talent budget):**
- **Devious Stratagem** — Spec tree, Row 5: `+1 max CP`
- **Deeper Stratagem** — Class tree, Row 10 (choice node): `+1 max CP`
- **Theoretical maximum with both:** 7 combo points

**Practical fresh-80 reality:** With ~30 Spec tree and ~31 Class tree points available, a fresh 80 has budget to pick Devious Stratagem (Row 5) early, yielding **6 combo points**. Deeper Stratagem is deep in the Class tree (Row 10), so a true fresh 80 may not have both.

Source: https://www.wowhead.com/talent-calc/rogue/outlaw + Icy Veins glossary

---

## Talent Point Budget at Level 80

**At level 80 (fresh):**
- Class tree: ~31 points (34 max at 90, minus 3 earned 80→90)
- Spec tree: ~30 points (34 max at 90, minus 4 earned 80→90)
- Hero tree: ~10 points (13 max at 90, minus 3 earned 80→90)
- **Total: ~71 talent points**

**Hero tree availability:** Hero talents unlock at **level 71**, so a fresh 80 already has Hero tree access and some points allocated.

Source: https://www.wowhead.com/talent-calc/rogue/outlaw (live calculator, Req Level columns)

---

## Fresh-80 Outlaw Rotation Priority

**Single-target (dungeons, solo mobs):**
1. **Adrenaline Rush** — on cooldown at ≤2 combo points (the big cooldown)
2. **Blade Rush** — on cooldown (fast cooldown, priority)
3. **Roll the Bones** — if currently at Stage 1 (keep buff up)
4. **Between the Eyes** — at 5+ combo points, on cooldown
5. **Dispatch** — at 5+ combo points (execute)
6. **Sinister Strike** — combo-point builder
7. **Pistol Shot** — when Opportunity proc available (free combo points)

**AoE (2+ targets):** Add **Blade Flurry** as top priority when 2+ mobs present (toggle on, spend combo points as usual).

**Flat-out source:** Wowhead Leveling Guide's "TALENT ORDER & ROTATION FOR LEVEL 80+" section (https://www.wowhead.com/guide/classes/rogue/outlaw/dps-leveling-tips).

**How it differs from endgame:** Endgame (level 90 with full build) opens from Stealth with Ambush → Adrenaline Rush → Roll the Bones → Slice and Dice → Blade Flurry, then builds into Between the Eyes at 6 CP with Deeper Stratagem talent, and rotates Killing Spree. Fresh 80 skips Slice and Dice (no talent for the refresh), has no Deeper Stratagem, and uses Dispatch (not optimal) until Row 10 capstone talents are unlocked. **The rotation fundamentally shortens** — fresh 80 is build → finisher → repeat, whereas endgame has opener branching and cooldown juggling.

---

## Hero Talents

**Unlock level: 71.**

A fresh-80 Outlaw already qualifies for Hero talents and has points to spend. The two available hero talent trees for Rogue are **Trickster** and **Fatebound**.

- **Trickster path** (Outlaw-synergistic): Delivered Doom, Controlled Chaos, etc.
- **Fatebound path** (generic): available to any Rogue, includes defensive/utility picks.

With ~10 hero points at fresh 80, you can invest in one or both paths but won't have a full hero tree.

**Does it change the rotation materially?** No — the fresh-80 rotation above remains the priority loop. Hero talents are enhancements/utility (buffs, resets, defensive procs), not rotation-structure changes. You'll weave them in as they trigger, but the core 6-step priority stays stable.

Source: https://www.wowhead.com/talent-calc/rogue/outlaw (Hero column, Req Level: 71)

---

## Summary for Addon Implementation

**What a fresh-80 Outlaw actually has:**
- All 9 core baseline abilities (Strike, Dispatch, Bones, Ambush, Pistol Shot, BtE, Slice & Dice, Vanish, Stealth, Blade Flurry)
- Adrenaline Rush forced at Row 2 (first talent point spent)
- Baseline 5 CP (6 if they grab Devious Stratagem early)
- ~71 talent points to allocate across 3 trees
- Hero tree access (71+ unlocked at fresh 80)
- Rotation is short/simple: Cooldowns → Finishers → Combo generators, no opener complexity

**Addon gotchas:**
- Do NOT assume Killing Spree, Keep It Rolling, or Preparation (Row 10 capstone picks — too deep for day one)
- Adrenaline Rush is mandatory, not optional
- Roll the Bones is baseline (reworked to deterministic 4-stage buff in Midnight)
- Slice and Dice is still baseline (not removed)
- Hero talents do not alter priority order — they're enhancements

---

## Sources

- Wowhead Abilities & Talents: https://www.wowhead.com/guide/classes/rogue/outlaw/abilities-talents-pve-dps
- Wowhead Talent Calculator: https://www.wowhead.com/talent-calc/rogue/outlaw
- Wowhead Leveling Tips: https://www.wowhead.com/guide/classes/rogue/outlaw/dps-leveling-tips
- Icy Veins Spell Summary: https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-spell-summary
- Icy Veins Rotation: https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities
- Icy Veins Talent Builds: https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-spec-builds-talents
