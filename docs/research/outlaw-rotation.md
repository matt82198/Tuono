# Outlaw Rogue Rotation Research: WoW Midnight 12.0
**Research Date:** August 1, 2026  
**Expansion:** World of Warcraft: Midnight (Patch 12.0.7)  

---

## DATA CURRENCY STATEMENT

**Verified Midnight (12.0) Facts:**
- Rotation priority and core mechanics (Roll the Bones rework, Blade Rush emphasis)
- Tier set bonuses for Midnight Season 1
- Top trinket recommendations (Gaze of the Alnseer, Plume trinkets)
- Theorycraft guide sources (Method, Icy Veins, Wowhead, Murlok.io, Maxroll.gg)
- SimulationCraft Midnight branch existence and directory structure

**UNVERIFIED (Guides thin or partially accessible):**
- Exact APL code examples and conditional syntax from SimulationCraft Midnight profiles (file paths confirmed; content inaccessible via web fetch)
- Precise on-use trinket handling in APL conditions
- Hero talent cooldown interactions specific to Midnight (Trickster mentioned but not fully specified)

**TWW-Era Fallback (labeled as such):**
- None used; all rotation guidance sourced from Midnight 12.0+ guides

---

## 1. OUTLAW PRIORITY & CORE MECHANICS

### Single-Target Rotation Priority
*Source: [Method Outlaw Rogue Guide - Playstyle and Rotation (Midnight 12.0.7)](https://www.method.gg/guides/outlaw-rogue/playstyle-and-rotation) | [Icy Veins Outlaw DPS Rotation (12.0.7)](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities)*

**Spec Philosophy:** "Always Be Casting (ABC)" with one of the highest APM counts in the game.

**Priority Order:**
1. **Roll the Bones** – Use on cooldown unless already at Stage 2+. Reworked in Midnight to grant progressive stages (1–4) with cumulative buffs. Most common outcomes: Stage 1 (55% odds), Stage 2 (30% odds).
2. **Adrenaline Rush** – Main cooldown; increases Energy Regen, maximum Energy (+100 to baseline 100), Attack Speed, and reduces global cooldown. Use on cooldown with 2 or fewer Combo Points.
3. **Between the Eyes** – Primary finisher at 6+ Combo Points. Highest damage finisher; grants stun immunity on crit and applies crit-damage debuff to boss. Critical to maintain uptime; missing a Between the Eyes window is the #1 Outlaw damage loss.
4. **Blade Rush** – Use on cooldown as a regular combo-point builder. Tier set bonus (below) pushes this further.
5. **Sinister Strike** – Bread-and-butter combo-point generator at 5 or fewer Combo Points. Baseline double-strike chance; doubled during Skull and Crossbones buff (rolled from Roll the Bones Stage 4).
6. **Pistol Shot** – Secondary generator with lower priority than Sinister Strike.

### Roll the Bones Mechanics
*Source: [Method Outlaw Rogue Guide - Playstyle and Rotation](https://www.method.gg/guides/outlaw-rogue/playstyle-and-rotation)*

Roll the Bones was reworked in Midnight for consistency. It provides **four cumulative stages** (1–4):
- **Stage 1:** Base buff (20% extra damage)
- **Stage 2:** Sinister Strike gains 20% increased chance to strike twice and grant Opportunity
- **Stage 3:** Additional bonuses stack
- **Stage 4:** Increased critical strike chance

**Reroll Mechanics:**
- Use **Keep It Rolling** at Stage 2 or higher to continue rolling and progress toward Stage 4
- Stage resets if the buff expires or you intentionally reroll

### Opportunity & Audacity Procs
*Source: [Method Playstyle Guide](https://www.method.gg/guides/outlaw-rogue/playstyle-and-rotation) | [Murlok.io Mythic+ Guide - Midnight Season 1](https://murlok.io/rogue/outlaw/m+)*

- **Opportunity:** Granted by Sinister Strike double-strikes (Stage 2+ of Roll the Bones); enables free Pistol Shot without Energy cost or Global Cooldown
- **Audacity:** Talent-based proc (confirmed in Mythic+ top builds); enhances rotational uptime
- Both procs maintain high action-per-minute gameplay during Adrenaline Rush windows

### Blade Flurry & AoE Rotation
*Source: [Icy Veins Outlaw DPS Rotation](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities) | [Maxroll.gg Mythic+ Guide (12.0.7)](https://maxroll.gg/wow/class-guides/outlaw-rogue-mythic-plus-guide)*

- **Blade Flurry:** Cleave ability originating from caster position. Maintain on 2+ targets (damage scales with number of nearby enemies)
- On 3+ targets, AoE becomes primary damage output mode
- Synergizes with Blade Rush tier set bonus for additional AoE efficiency

### Energy & Combo Point Management
*Source: [Icy Veins Rotation Guide](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities)*

- **Baseline Energy Pool:** 100 (200 with Vigor talent, 250 during Adrenaline Rush)
- **Regen:** 10 per second baseline
- **Finisher (Between the Eyes) Cooldown Reduction:** Refunds cooldowns via **Restless Blades** payoff system when finishers land

---

## 2. MAJOR DPS COOLDOWNS & USAGE CONDITIONS

*Source: [Method Outlaw Rogue Guide - Playstyle](https://www.method.gg/guides/outlaw-rogue/playstyle-and-rotation) | [Icy Veins Rotation & Cooldowns](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities)*

### Primary Cooldowns

**Adrenaline Rush** (Main)
- Increases Energy Regen, maximum Energy, and Attack Speed dramatically
- Reduces GCD based on Haste value
- Use on cooldown (with 2 or fewer Combo Points ideally)
- Window for on-use trinkets (Plume trinkets best aligned here)

**Blade Rush**
- Regular cooldown ability (especially emphasized in Midnight tier set)
- Combo-point builder; use on cooldown
- Tier set bonus extends its value (see Gear section)

**Preparation**
- Resets offensive ability cooldowns (Between the Eyes, Adrenaline Rush, Blade Rush) when those are unavailable
- Can be held strategically for damage phases (cooldown refund timing matters)

**Killing Spree / Blade Rush Equivalent**
- UNVERIFIED: No specific Killing Spree replacement found in Midnight guides; Blade Rush appears to be the primary mobility/cooldown builder

### Hero Talents
*Source: [Murlok.io Mythic+ Guide - Midnight Season 1](https://murlok.io/rogue/outlaw/m+)*

- **Trickster** hero talent dominates top Mythic+ builds (confirmed in 50/50 adoption across ranked players)
- Talent synergies: Opportunity, Adrenaline Rush, Improved Adrenaline Rush show 50/50 adoption rates for sustained damage

---

## 3. SIMULATIONCRAFT: APL SOURCE & FILES

*Source: [SimulationCraft GitHub - Midnight Branch](https://github.com/simulationcraft/simc/tree/midnight) | [GitHub Rogue APL Header](https://github.com/simulationcraft/simc/blob/midnight/engine/class_modules/apl/apl_rogue.hpp)*

### APL Location & Architecture

**Engine File:** `engine/class_modules/apl/apl_rogue.hpp` (header interface on Midnight branch)

**Implementation:** The APL is modular; the header declares spec-specific functions:
```
Namespace rogue_apl {
  void assassination( player_t* );
  void outlaw( player_t* );
  void subtlety( player_t* );
  ...
}
```

Each function applies specialization-specific action priorities based on character data.

### Midnight Profile Files
*Source: [SimulationCraft Profiles Directory - Midnight Branch](https://github.com/simulationcraft/simc/tree/midnight/profiles)*

**Midnight Raid Profiles:**
- **Directory:** `profiles/MID1/` and `profiles/MID2/` (for Midnight tiers 1 & 2)
- **Outlaw Rogue Files:**
  - `MID1_Rogue_Outlaw.simc`
  - `MID1_Rogue_Outlaw_Trickster.simc` (hero talent variant)

**Status:** UNVERIFIED – Files confirmed to exist in GitHub directory but full APL code content not accessible via web fetch. Requires direct GitHub repository clone or web-based file viewer.

### APL Syntax Example
*Source: [Method Outlaw Guide](https://www.method.gg/guides/outlaw-rogue/playstyle-and-rotation) | [GitHub APL Issues #5693](https://github.com/simulationcraft/simc/issues/5693)*

SimulationCraft APLs use conditional priority expressions. Example pattern (from related Outlaw issue discussions):
```
action_priority_list=default
  /adrenaline_rush,if=combo_points<=2
  /between_the_eyes,if=combo_points>=6
  /sinister_strike,if=combo_points<=5
```

**Note:** Exact Midnight Outlaw APL code is not directly accessible. Historical patterns show:
- Conditions based on combo points, buff uptime (Roll the Bones stage), energy
- Trinket usage aligned with Adrenaline Rush windows

---

## 4. GEAR: TIER SET BONUSES & TRINKETS

### Midnight Season 1 Tier Set Bonuses
*Source: [Method Outlaw Rogue Guide - Gearing (Midnight 12.0.7)](https://www.method.gg/guides/outlaw-rogue/gearing) | [Wowhead Tier Set Bonuses](https://www.wowhead.com/guide/classes/rogue/outlaw/tier-set-bonuses)*

**2-Piece Bonus:**
- Blade Rush damage increased by 30%
- Blade Rush damage to primary target increased by additional 15%

**4-Piece Bonus:**
- Blade Rush cooldown reduced by 6 seconds
- Grants 5% damage buff for 8 seconds on Blade Rush cast

**Rotational Impact:** No change to priority order; simply pushes Blade Rush further as an on-cooldown ability. Tier set centered on single ability but provides solid damage increases.

### Top Trinkets: Raid & Mythic+
*Source: [Method Gearing Guide](https://www.method.gg/guides/outlaw-rogue/gearing) | [Murlok.io Top Builds - Midnight](https://murlok.io/rogue/outlaw/m+) | [Maxroll.gg Mythic+ Guide](https://maxroll.gg/wow/class-guides/outlaw-rogue-mythic-plus-guide)*

**Raid Trinkets (Recommended):**

1. **Gaze of the Alnseer** – Passive critical strike trinket
   - Used by 100% of top-ranked (rank 50) Mythic+ Outlaw Rogues
   - Essential for performance
   - No APL action required; passive stat

2. **Umbral Plume** (On-Use) – Large on-use cooldown
   - Should be used on cooldown OR during Adrenaline Rush
   - Requires APL condition (UNVERIFIED): `umbral_plume,if=buff.adrenaline_rush.up`

3. **Radiant Plume** (On-Use) – Alternative on-use trinket
   - Same usage strategy as Umbral Plume
   - Choose one Plume trinket based on stat preferences

**Mythic+ Trinkets (Until Raid Available):**
- Solarflare Prism (passive)
- Heart of Wind (passive)

### On-Use Trinket Strategy
*Source: [Method Gearing Guide](https://www.method.gg/guides/outlaw-rogue/gearing)*

**General Philosophy:** Outlaw lacks traditional burst cooldowns; passive stat-based trinkets are generally stronger than on-use options. However:
- Plume trinkets are large enough to warrant on-cooldown usage
- Optimal timing: during Adrenaline Rush windows (to avoid losing casts in dungeons/encounters)
- APL integration: UNVERIFIED – likely includes conditional checks on buff uptime

### Stat Priority (Mythic+ Top Performers)
*Source: [Murlok.io Midnight Season 1](https://murlok.io/rogue/outlaw/m+)*

1. Critical Strike: 37%
2. Haste: 25%
3. Mastery: 16%
4. Versatility: 3%

---

## 5. THEORYCRAFT COMMUNITY: CURRENT RESOURCES

*Source: Search results aggregated from multiple providers*

### Primary Guides & Sims

| Resource | URL | Coverage |
|----------|-----|----------|
| **Wowhead** | [Outlaw Rogue Guides](https://www.wowhead.com/guide/classes/rogue/outlaw/rotation-cooldowns-pve-dps) | Rotation, Cooldowns, BiS Gear (Midnight 12.0) |
| **Icy Veins** | [Outlaw Rogue PvE DPS Guide (12.0.7)](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-guide) | Comprehensive spec, builds, talents, rotation, gear |
| **Method** | [Outlaw Rogue Playstyle & Rotation](https://www.method.gg/guides/outlaw-rogue/playstyle-and-rotation) | In-depth rotation, cooldown stacking, mechanics (Midnight 12.0.7) |
| **Maxroll.gg** | [Outlaw Raid & Mythic+ Guides (12.0.7)](https://maxroll.gg/wow/class-guides/outlaw-rogue-raid-guide) | Raid & dungeon-specific strategies |
| **Murlok.io** | [Outlaw Mythic+ Guide (Midnight S1)](https://murlok.io/rogue/outlaw/m+) | Top-performer builds, gear, stat priority (real data from ranked players) |
| **SimulationCraft** | [GitHub Midnight Branch Profiles](https://github.com/simulationcraft/simc/blob/midnight/profiles/) | DPS sims (Midnight-specific profiles: MID1, MID2) |
| **MythicSim** | [Stat Priority (12.0.5)](https://mythicsim.com/stat-priority/outlaw-rogue) | SimulationCraft-derived stat weights |

### Community Discord & Updates
- **Rogue Community:** Primary theorycraft conducted via Method, Murlok.io, and Wowhead community comments
- **Update Cadence:** SimulationCraft profiles re-run weekly after simc updates (MythicSim data regenerated June 11, 2026)

---

## SUMMARY OF KEY CHANGES vs. THE WAR WITHIN

*(For reference—not substituted fallback data)*

1. **Roll the Bones Rework:** Now 4-stage progressive system instead of random buffs; much more consistent
2. **Tier Set Focus:** Blade Rush emphasis (6-sec CD reduction) deepens cooldown-driven playstyle
3. **Hero Talent Expansion:** Trickster solidifies as dominant choice with Opportunity/Audacity synergies

---

## RESEARCH LIMITATIONS & NEXT STEPS

### Confirmed but Inaccessible:
- Full SimulationCraft Midnight APL code (files exist; web fetch unsuccessful)
- Exact on-use trinket conditional logic in APL
- Killing Spree equivalent ability (if any) in Midnight

### Recommended Next Steps:
1. Clone SimulationCraft Midnight branch locally; inspect `profiles/MID1_Rogue_Outlaw.simc` directly
2. Cross-reference Method guide against SimulationCraft APL to validate any discrepancies
3. Monitor Murlok.io & MythicSim for weekly updates (sims regenerated post-patch)

---

## SOURCES

- [Wowhead - Outlaw Rogue Rotation Guide](https://www.wowhead.com/guide/classes/rogue/outlaw/rotation-cooldowns-pve-dps)
- [Icy Veins - Outlaw Rogue DPS Guide (12.0.7)](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-guide)
- [Icy Veins - Outlaw Rotation & Cooldowns (12.0.7)](https://www.icy-veins.com/wow/outlaw-rogue-pve-dps-rotation-cooldowns-abilities)
- [Method - Outlaw Playstyle & Rotation (Midnight 12.0.7)](https://www.method.gg/guides/outlaw-rogue/playstyle-and-rotation)
- [Method - Outlaw Gearing (Midnight 12.0.7)](https://www.method.gg/guides/outlaw-rogue/gearing)
- [Maxroll.gg - Outlaw Raid Guide (12.0.7)](https://maxroll.gg/wow/class-guides/outlaw-rogue-raid-guide)
- [Maxroll.gg - Outlaw Mythic+ Guide (12.0.7)](https://maxroll.gg/wow/class-guides/outlaw-rogue-mythic-plus-guide)
- [Murlok.io - Outlaw Mythic+ Guide (Midnight S1)](https://murlok.io/rogue/outlaw/m+)
- [SimulationCraft GitHub - Midnight Branch](https://github.com/simulationcraft/simc/tree/midnight)
- [SimulationCraft GitHub - Rogue APL Header](https://github.com/simulationcraft/simc/blob/midnight/engine/class_modules/apl/apl_rogue.hpp)
- [SimulationCraft GitHub - Midnight Profiles](https://github.com/simulationcraft/simc/tree/midnight/profiles)
- [MythicSim - Outlaw Stat Priority (12.0.5)](https://mythicsim.com/stat-priority/outlaw-rogue)
- [SimulationCraft Issue #5693 - Outlaw APL Optimization](https://github.com/simulationcraft/simc/issues/5693)
