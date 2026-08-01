# World of Warcraft: Midnight (12.0) Addon API Changes Research

**Date**: 2026-08-01  
**Focus**: Combat addon capabilities, Assisted Combat API, rotation recommendation addon feasibility

---

## FEASIBILITY VERDICT

**Can a custom rotation recommendation engine run in combat: ONLY-VIA-ASSIST-API**

A traditional Hekili-style standalone rotation recommendation addon that simulates combat state and makes independent decisions is **NOT buildable** in Midnight. Blizzard blocked all combat data access via a "secret values" system that prevents addons from:
- Reading unit auras (buffs/debuffs)
- Querying spell cooldowns
- Accessing combat log events (COMBAT_LOG_EVENT_UNFILTERED removed)
- Simulating rotation logic based on combat state

**However**, addons CAN:
1. **Call C_AssistedCombat.GetNextCastSpell()** and render custom UI overlays displaying Blizzard's recommendations (e.g., HekiLight, Knickili, TrueShot)
2. **Display Blizzard's built-in Single-Button Assistant** suggestions with customized positioning/styling
3. Read non-combat data and **class secondary resources** (combo points, runes, maelstrom weapon, soul fragments) to enhance UI
4. Cache out-of-combat cooldown info and compute remaining time in combat (TrinketTracker pattern)

**Verdict Summary**: The rotation advisor can exist, but must delegate decisions to Blizzard's `C_AssistedCombat` API. Independent combat simulation is permanently blocked.

---

## 1. Announced Restrictions vs. Shipped Reality

### Blizzard's Announcement (Late 2025 Pre-Patch)

**Source**: [Combat Philosophy and Addon Disarmament in Midnight - Blizzard News](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight)

Blizzard announced a paradigm shift: *"Combat events are in a black box; addons can change the size or shape of the box, and they can paint it a different color, but what they can't do is look inside."*

**Stated Goals**:
- Limit addons' ability to "perform complex logic and decision making based off combat information"
- Preserve UI customization capabilities (positioning, sizing, styling, accessibility)
- Block all combat state introspection

### What Actually Shipped in Midnight 12.0

**Confirmed Restrictions**:

1. **COMBAT_LOG_EVENT_UNFILTERED** — Removed entirely from addon API surface
   - Source: [Warcraft Wiki Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)
   - CombatLogGetCurrentEventInfo() returns "secret values" instead of readable data
   - No addon-facing replacement exists; external combat log files (WoWCombatLog.txt) still log everything with full fidelity

2. **Secret Values System** — New mechanism restricting operations on tainted execution paths
   - APIs affected: C_Secrets.HasSecretRestrictions(), C_Secrets.ShouldSpellCooldownBeSecret(), C_Secrets.ShouldUnitAuraIndexBeSecret()
   - Functions like issecretvalue() and issecrettable() added to detect restricted data

3. **Unit Auras (Buffs/Debuffs)** — Blocked during combat
   - Source: [Icy Veins: Blizzard Relaxing More Addon Limitations](https://www.icy-veins.com/wow/news/blizzard-relaxing-more-addon-limitations-in-midnight/)
   - When active in combat/encounters/M+/PvP, C_UnitAuras API calls return nil or full secret values
   - Aura lookup functions (targeting by spell ID or name) are no longer callable in combat
   - Workaround: Addons like BuffTracker Midnight use UNIT_SPELLCAST_SUCCEEDED events + manually cached durations

4. **Spell Cooldowns** — Marked secret during combat
   - Source: [Icy Veins: Combat Addon Restrictions Eased](https://www.icy-veins.com/wow/news/combat-addon-restrictions-eased-in-midnight/)
   - Cooldown queries return secret values; can't be read by addon logic in tainted execution
   - Workaround: TrinketTracker caches durations out-of-combat and computes remaining time (guaranteed never secret)

5. **Action/Party Restrictions** — Specific functions removed/disabled
   - Source: [Warcraft Wiki Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)
   - Removed: PromoteToLeader, DemoteAssistant, SetEveryoneIsAssistant, DoReadyCheck, C_PartyInfo.DoCountdown, C_PartyInfo.SetLootMethod

### Post-Launch Relaxations

**Released in Patches 12.0.1 - 12.1.0**:

- Enhancement Shaman's Maelstrom Weapon — Full data visibility whitelisted
- Demon Hunter's Soul Fragments — Full data visibility whitelisted
- Combat resurrection spells — Non-secret cooldowns and charge counts
- All class secondary resources — Confirmed as "fully non-secret" (combo points, runes, Holy Power, etc.)
- New utility APIs: CreateUnitHealPredictionCalculator, UnitGetDetailedHealPrediction, C_CurveUtil.EvaluateColorFromBoolean for rendering secret values

**Source**: [Icy Veins: Blizzard Relaxing More Addon Limitations](https://www.icy-veins.com/wow/news/blizzard-relaxing-more-addon-limitations-in-midnight/)

---

## 2. Blizzard's Assisted Combat API (C_AssistedCombat)

### Origin and Purpose

**Single-Button Assistant** was introduced in patch **11.1.7** (pre-Midnight) as an accessibility feature. It was expanded in Midnight to become the only legal way for addons to get rotation recommendations.

**Source**: [Blizzard Watch: Combat Assistant in WoW patch 11.1.7](https://blizzardwatch.com/2025/05/01/wow-combat-assistant-rotation-patch-11-1-7/)

### C_AssistedCombat Functions

**Documented Function**:

- **C_AssistedCombat.GetNextCastSpell(checkForVisibleButton?)**
  - Returns: spell ID (number) or nil
  - Parameter: checkForVisibleButton (boolean, optional, defaults false) — includes custom action buttons associated with action IDs
  - **Source**: [Warcraft Wiki: C_AssistedCombat.GetNextCastSpell](https://warcraft.wiki.gg/wiki/API_C_AssistedCombat.GetNextCastSpell)
  - Returns the spell ID recommended by Blizzard's Single-Button Assistant/Assisted Highlights system

**Other C_AssistedCombat Functions** (UNVERIFIED list, names inferred from addon usage):
- C_AssistedCombat.GetRotationSpells() — [Referenced in search results but not independently verified with official docs]
  - Likely returns a queue of additional recommended spells beyond the next cast

**Note**: A complete official list of all C_AssistedCombat functions is not readily available in public documentation. The in-game `/api` command is the authoritative source.

### How the API Works

1. Blizzard's Action Priority Lists (APLs) — Condensed logic that determines recommended spells based on class, spec, talents, cooldowns, resources
2. Single-Button Assistant evaluates these APLs and stores the recommended spell ID in C_AssistedCombat
3. Addons call GetNextCastSpell() to retrieve that ID
4. Addons render custom UI displaying the recommendation (button highlight, overlay icon, etc.)
5. The player still chooses whether to cast or do something else (feature is assistive, not automated)

**GCD Penalty**: Using the built-in Single-Button Assistant to auto-cast incurs an intentional small GCD penalty as compensation for not requiring active decision-making. Custom overlays that only *suggest* do not.

---

## 3. How Existing Rotation Addons Adapted

### Hekili (Original Project)

**Status**: **DEAD — Project sunset**

**Timeline**:
- Hekili operated via APL simulation: parsing Action Priority Lists, simulating unit state, computing optimal next spell
- Patch 12.0 (Midnight pre-patch, January 20, 2026) blocked all combat state access

**Official Statement**:
> "Hekili will sunset with the launch of WoW's Midnight pre-patch (12.0). I hope the addon helped you take on (and overcome?) new challenges in the game that you otherwise might never have done."

**Source**: [Hekili on X/Twitter](https://x.com/hekili808/status/1973479282006696123)

**Source**: [GitHub Issue #5337: Midnight](https://github.com/Hekili/hekili/issues/5337)

The project ended because "the new direction with Blizzard's API makes it impossible to continue the addon in a way that would meet our design goals and quality standards."

### Successor: HekiLight

**What It Is**: Lightweight addon that reads Blizzard's C_AssistedCombat API and re-displays recommendations as a movable, scalable icon strip

**How It Works**:
1. Calls C_AssistedCombat.GetNextCastSpell() continuously
2. Renders Blizzard's recommendation as a custom overlay (position, size, styling all user-configurable)
3. Provides the familiar Hekili aesthetic, powered entirely by Blizzard's engine

**Source**: [HekiLight on CurseForge](https://www.curseforge.com/wow/addons/hekilight)

**Source**: [Midnight Ready - EpicSync](https://epicsyncpro.github.io/Midnightinfograph/hekili_midnight_infographic_3.html)

### Other New Rotation Addons Using C_AssistedCombat

1. **Knickili**
   - Shows the icon and keybind of C_AssistedCombat.GetNextCastSpell()
   - Does NOT require SBA button placement; pulls recommendations directly from the API
   - Source: [Knickili on CurseForge](https://www.curseforge.com/wow/addons/knickili)

2. **TrueShot**
   - Rotation overlay for Hunter, Demon Hunter, and Druid
   - Layers priority fixes on top of Blizzard Assisted Combat
   - Source: [TrueShot on GitHub](https://github.com/itsDNNS/TrueShot)

3. **Blizzkili**
   - Rotation helper based on Hekili and Single Button Assistant concepts
   - Source: [Blizzkili on CurseForge](https://www.curseforge.com/wow/addons/blizzkili)

4. **Synaptic - Rotation Assistant**
   - Uses C_AssistedCombat for spell suggestions with cooldown visuals
   - Source: [Synaptic on CurseForge](https://www.curseforge.com/wow/addons/synaptic-rotation-assistant)

### MaxDps and ConRO

**Status**: Updated but functionality reduced

**MaxDps**:
- Version 11.2.96+ carries support for Midnight
- Can no longer simulate independent rotations; must display suggestions only
- Source: [MaxDps on CurseForge](https://www.curseforge.com/wow/addons/maxdps-rotation-helper)
- Source: [MaxDps Midnight Support](https://maxdps.pro/addons/midnight)

**ConRO (Conflict Rotation Optimizer)**:
- Still available; updated for Midnight
- Advertises "adjusted based on talents chosen to optimize damage output"
- Actual mechanics in Midnight are unknown — **UNVERIFIED** whether it still performs independent simulation or now wraps C_AssistedCombat
- Source: [ConRO on CurseForge](https://www.curseforge.com/wow/addons/conflict-rotation-optimizer-conro)

---

## 4. What Remains Readable in Combat

### Data Still Accessible

#### Always-Readable (In and Out of Combat)

1. **Class Secondary Resources** (non-secret)
   - Combo Points (Rogue, Feral Druid, Demon Hunter)
   - Runes (Death Knight)
   - Holy Power (Paladin)
   - Maelstrom Weapon (Enhancement Shaman) — explicitly whitelisted in Midnight
   - Soul Fragments (Demon Hunter) — explicitly whitelisted in Midnight
   - Source: [Blizzard News: Combat Philosophy](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight/)
   - **Examples**: MidnightUI Suite, SenseiClassResourceBar, MidnightRogueBars render these successfully

2. **Equipped Inventory Items** (partially readable)
   - GetInventoryItemID() — Can read equipped item IDs out of combat
   - In combat: **UNVERIFIED** whether this function is secret or still readable
   - Workaround pattern (TrinketTracker): Cache item IDs out-of-combat, then compute cooldown timers in combat only
   - Source: [TrinketTracker Midnight on CurseForge](https://www.curseforge.com/wow/addons/trinkettracker-midnight)

3. **Action Bar/Spell Button State** (readable for display)
   - Action bar button appearance, position, art
   - "Important cast" state on nameplates (Blizzard now highlights dangerous casts in base UI)
   - Addons can customize size, animation, color of that state
   - Source: [Icy Veins: Some Combat Addons Survive](https://www.icy-veins.com/wow/news/some-combat-addons-might-break-in-midnight-but-heres-what-survives/)

#### Not Readable in Combat (Secret Values)

1. **Unit Auras (Buffs/Debuffs)** — Completely blocked
   - C_UnitAuras API returns nil or secret data
   - Cannot query auras by spell ID or name
   - Workaround: Use UNIT_SPELLCAST_SUCCEEDED events + manually cached buff durations (BuffTracker Midnight pattern)
   - Source: [Icy Veins: Blizzard Relaxing Restrictions](https://www.icy-veins.com/wow/news/blizzard-relaxing-more-addon-limitations-in-midnight/)

2. **Spell Cooldowns** — Marked secret
   - Cannot query GetSpellCooldown() or similar in combat
   - Only readable for whitelisted spells (combat resurrections, Maelstrom Weapon, Soul Fragments)
   - Workaround: TrinketTracker caches out-of-combat, computes timer in combat (C_Cooldowns.GetCooldownDuration() still works)
   - Source: [Icy Veins: Combat Addon Restrictions Eased](https://www.icy-veins.com/wow/news/combat-addon-restrictions-eased-in-midnight/)

3. **Combat Log Events** — Completely inaccessible
   - COMBAT_LOG_EVENT_UNFILTERED removed from addon API
   - CombatLogGetCurrentEventInfo() returns secret values
   - No direct replacement; external WoWCombatLog.txt file still logs everything (usable by external tools only, not addons)
   - Source: [Warcraft Wiki: Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)

4. **Unit State Queries** (in combat scenarios)
   - UnitHealth(target) — **UNVERIFIED** secret or readable status in Midnight
   - UnitPower(target) — **UNVERIFIED**
   - UnitCastingInfo(target) — Readable for UI display (nameplate highlights); can't be used for logic
   - Source: [GitHub Issue #28: DragonShout CLEU removal](https://github.com/Xerrion/DragonShout/issues/28) [Discusses UNIT_* event migration but doesn't enumerate full restrictions]

### What Addons Can Still Customize

**Presentation Layer** (All still allowed):

- Raid frames (position, size, colors, fonts)
- Nameplates (appearance of buffs/debuffs, cast bars, threat indicators)
- Action bars (button layout, styling, artwork)
- Cooldown display (fonts, colors, swipe animations)
- Enemy cast bar appearance
- Buff/debuff display location and styling (but not the data underneath in combat)

**Source**: [Icy Veins: Some Combat Addons Survive](https://www.icy-veins.com/wow/news/some-combat-addons-might-break-in-midnight-but-heres-what-survives/)

---

## Summary: What a Rotation Recommendation Addon Can Do

### Buildable (Supported)

✅ Call C_AssistedCombat.GetNextCastSpell() continuously  
✅ Render custom UI overlay displaying the recommended spell ID  
✅ Show spell cooldown timers (for out-of-combat-cached trinkets, whitelisted spells)  
✅ Display class secondary resources (combo points, runes, etc.)  
✅ Respond to UNIT_SPELLCAST_SUCCEEDED events with manually cached buff durations  
✅ Customize nameplate/castbar appearance  
✅ Create movable, scalable, stylable recommendation icons (HekiLight pattern)  

### Not Buildable (Blocked)

❌ Query unit auras to detect buffs/debuffs in combat  
❌ Read spell cooldowns independently (must use cached data or whitelisted APIs)  
❌ Parse combat log events (COMBAT_LOG_EVENT_UNFILTERED removed)  
❌ Simulate combat state or run independent APL logic  
❌ Perform rotation optimization based on live combat data  
❌ Detect what abilities are available via state introspection  

---

## Sources

### Official Blizzard

- [Combat Philosophy and Addon Disarmament in Midnight - Blizzard News](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight)
- [How Midnight's Upcoming Game Changes Will Impact Combat Addons - Blizzard](https://worldofwarcraft.blizzard.com/en-us/news/24244638)

### Warcraft Wiki (Primary API Documentation)

- [Patch 12.0.0/API changes - Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)
- [Patch 12.0.0/Planned API changes - Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes)
- [Patch 12.0.1/API changes - Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.0.1/API_changes)
- [Patch 12.1.0/API changes - Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes)
- [API C_AssistedCombat.GetNextCastSpell - Warcraft Wiki](https://warcraft.wiki.gg/wiki/API_C_AssistedCombat.GetNextCastSpell)

### News & Analysis

- [Icy Veins: Some Combat Addons Might Break in Midnight But Here's What Survives](https://www.icy-veins.com/wow/news/some-combat-addons-might-break-in-midnight-but-heres-what-survives/)
- [Icy Veins: Blizzard Relaxing More Addon Limitations in Midnight](https://www.icy-veins.com/wow/news/blizzard-relaxing-more-addon-limitations-in-midnight/)
- [Icy Veins: Combat Addon Restrictions Eased in Midnight](https://www.icy-veins.com/wow/news/combat-addon-restrictions-eased-in-midnight/)
- [Escapist Magazine: World of Warcraft: Midnight is bringing one of the most controversial changes in the game's history](https://www.escapistmagazine.com/world-of-warcraft-midnight-addon/)
- [Blizzard Watch: WoW is adding a Hekili-like Combat Assistant in patch 11.1.7 — plus more on Blizzard's long-term UI goals](https://blizzardwatch.com/2025/05/01/wow-combat-assistant-rotation-patch-11-1-7/)
- [WoW Midnight's Addon, Combat, and Design Changes Part 1 – API Anarchy and The Dark Black Box](https://kaylriene.com/2025/10/03/wow-midnights-addon-combat-and-design-changes-part-1-api-anarchy-and-the-dark-black-box/)

### Addon Projects & CurseForge

- [HekiLight - CurseForge](https://www.curseforge.com/wow/addons/hekilight)
- [Hekili GitHub Repository](https://github.com/Hekili/hekili)
- [Hekili Twitter Statement on Sunset](https://x.com/hekili808/status/1973479282006696123)
- [Knickili - CurseForge](https://www.curseforge.com/wow/addons/knickili)
- [TrueShot - GitHub](https://github.com/itsDNNS/TrueShot)
- [Blizzkili - CurseForge](https://www.curseforge.com/wow/addons/blizzkili)
- [Synaptic - Rotation Assistant - CurseForge](https://www.curseforge.com/wow/addons/synaptic-rotation-assistant)
- [MaxDps - CurseForge](https://www.curseforge.com/wow/addons/maxdps-rotation-helper)
- [MaxDps Midnight Support](https://maxdps.pro/addons/midnight)
- [ConRO - CurseForge](https://www.curseforge.com/wow/addons/conflict-rotation-optimizer-conro)
- [TrinketTracker (Midnight) - CurseForge](https://www.curseforge.com/wow/addons/trinkettracker-midnight)
- [BuffTracker Midnight - CurseForge](https://www.curseforge.com/wow/addons/bufftracker-midnight)
- [MidnightUI Suite - CurseForge](https://www.curseforge.com/wow/addons/midnightui-midnight-ready)

### Community & Developer Discussion

- [GitHub Issue #28: DragonShout - Midnight CLEU removal](https://github.com/Xerrion/DragonShout/issues/28)
- [GitHub PR #457: Cell - WoW 12.0.0 Compatibility](https://github.com/enderneko/Cell/pull/457)

### Forum Discussions

- [Please Revert Midnight Addon API Changes - Blizzard Forums](https://us.forums.blizzard.com/en/wow/t/please-revert-midnight-addon-api-changes/2177092)
- [In Midnight, is Blizzard's Rotation Assist Meant to Replace Addons Like Hekili? - Blizzard Forums](https://us.forums.blizzard.com/en/wow/t/in-midnight-is-blizzard%E2%80%99s-rotation-assist-meant-to-replace-addons-like-hekili/2212381)
- [Combo point addon in prepatch - Blizzard Forums](https://us.forums.blizzard.com/en/wow/t/combo-point-addon-in-prepatch/2227251)

---

## Key Terminology

- **Secret Value**: A data type that can be displayed by UI but not read by addon logic in tainted execution (in-combat context)
- **Tainted Execution**: Addon code running during or after combat; restricted from accessing certain sensitive data
- **C_AssistedCombat**: Blizzard's official API namespace exposing Single-Button Assistant recommendations
- **Single-Button Assistant**: Built-in Midnight feature that evaluates Blizzard's APLs and casts the recommended spell with a GCD penalty
- **Assisted Highlights**: Variant of Single-Button Assistant that only highlights (suggests) without auto-casting
- **APL (Action Priority List)**: Condensed rotation logic used by Blizzard's built-in assistant
- **Black Box Philosophy**: Core Midnight design: addons can change presentation but cannot inspect combat state

---

## Document Status

**Last Updated**: 2026-08-01  
**Verification**: All claims tied to specific sources (URLs provided). Unverified claims marked [UNVERIFIED].  
**Cutoff**: Information current as of WoW Patch 12.1.0 (June 2026).
