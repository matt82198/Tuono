# WoW Rotation Addon Gear & Trinket Modeling — Research Summary

**Date:** August 1, 2026  
**Scope:** Equipment detection APIs, SimulationCraft APL gear conditions, Hekili's approach (concluded), proc/buff modeling, on-use trinket recommendations  
**Status:** Hekili concluded development Jan 20, 2026 (patch 12.0); modern rotation helpers blocked in Midnight

---

## 1. Equipment Detection APIs

### Inventory Slot Queries

**Legacy API: GetInventoryItemID**
- **Signature:** `itemId, unknown = GetInventoryItemID(unit, invSlotId)`
- **Purpose:** Returns the item ID of an equipped item in a specific inventory slot
- **Source:** [Vanilla WoW Wiki – GetInventoryItemID](https://vanilla-wow-archive.fandom.com/wiki/API_GetInventoryItemID), [Warcraft Wiki – GetInventoryItemID](https://warcraft.wiki.gg/wiki/API_GetInventoryItemID)
- **Status:** Legacy; works but superceded by C_Item namespace

**Modern API: C_Item Namespace**
- **Key Functions:**
  - `C_Item.GetItemInfo(itemID)` – Returns comprehensive item data including name, quality, item level
  - `C_Item.GetDetailedItemLevelInfo(itemID)` – Retrieves detailed item level information
  - `C_Item.IsItemBindToAccount`, `C_Item.CanItemTransmogAppearance` – Equipment capability checks
- **Source:** [Warcraft Wiki – C_Item.GetItemInfo](https://warcraft.wiki.gg/wiki/API_C_Item.GetItemInfo), [GitHub – InspectEquip addon](https://github.com/Nukme/InspectEquip) (uses C_Item.GetDetailedItemLevelInfo)

### Trinket Slot Detection

- **Trinket Slots:** Inventory slots 13 (trinket 1) and 14 (trinket 2)
- **Detection Method:** Addons query slots 13 and 14 directly via GetInventoryItemID or C_Item API
- **Example Addon:** TrinketTracker (Midnight) detects equipped trinkets in slots 13 and 14
- **Source:** [CurseForge – TrinketTracker (Midnight)](https://www.curseforge.com/wow/addons/trinkettracker-midnight)

### Tier Set Detection

**C_Item.GetItemSetInfo (expected modern equivalent)**
- **Purpose:** Retrieve tier set information for equipped items
- **Usage in Addons:** Details! Item Level Display and O Item Level (OiLvL) both reference tier set detection for 2P/4P bonuses
- **Midnight Support:** SeasonN tier sets configured with hero tree variants (e.g., Felscarred 2pc, 4pc)
- **Source:** [CurseForge – Details! Item Level Plugin](https://www.curseforge.com/wow/addons/details-item-level-plugin), [CurseForge – O Item Level](https://www.curseforge.com/wow/addons/o-item-level)
- **Status:** UNVERIFIED – Exact function name not directly confirmed in API docs; inferred from addon usage patterns

### Equipment Change Event

**PLAYER_EQUIPMENT_CHANGED Event**
- **Purpose:** Fires when a player's equipped items change
- **Addon Implementation:** Trinket tracking addons register this event to detect equipment swaps
- **Detection Method:** Slots monitored via GetInventoryItemID queries on event trigger
- **Source:** [MMO-Champion – Auto equip change addon discussion](https://www.mmo-champion.com/threads/1472979-Auto-equip-change-addon), [WoWInterface – Equipment change detection](https://www.wowinterface.com/forums/showthread.php?t=3216)

---

## 2. SimulationCraft APL Gear Condition Expressions

### Set Bonus Syntax

**Legacy Format (Pre-Tier 17):**
```
tier11_2pc_caster=1
tier11_4pc_caster=1
```

**Modern Format (Tier 17+):**
```
set_bonus=tier17_2pc=1
set_bonus=tier17_4pc=1
```

**Hero Talent Tier Set (The War Within S3):**
```
set_bonus=name=thewarwithin_season_3,pc=2,hero_tree=felscarred,enable=1
```
- **Source:** [GitHub – SimulationCraft Equipment Wiki](https://github.com/simulationcraft/simc/wiki/Equipment), [GitHub – SimulationCraft Rogue Profile](https://github.com/simulationcraft/simc/blob/dragonflight/profiles/Tier31/T31_Rogue_Subtlety.simc)

### Trinket Slot Configuration

**Trinket Definition (Profile Section):**
```
trinket1=unsolvable_riddle,stats=321mastery,use=1605str_120cd_20dur
trinket2=darkmoon_card_hurricane,stats=321str,equip=procby/attack_5000nature_10%
```

**Breakdown:**
- `trinket1/trinket2` – Equipment slots
- `stats=XXX` – Primary stat allocation
- `use=<effect>` – On-use effect (stat value, cooldown, duration)
- `equip=procby/...` – Passive proc effect (trigger type, damage value, proc chance)

- **Source:** [GitHub – SimulationCraft Equipment Wiki](https://github.com/simulationcraft/simc/wiki/Equipment)

### APL Trinket Usage Examples

**From Rogue Subtlety Profile (Real Excerpt):**

```lua
actions.cds+=/use_item,name=irideus_fragment,if=(buff.cold_blood.up|(!talent.danse_macabre...))
actions.cds+=/use_item,name=witherbarks_branch,if=buff.flagellation_buff.up&talent.invigorating_shadowdust
actions.cds+=/use_items,if=!stealthed.all&(!trinket.mirror_of_fractured_tomorrows.cooldown.ready...))
```

**Set Bonus Condition in APL:**
```lua
actions.cds+=/symbols_of_death,if=variable.snd_condition&(!buff.the_rotten.up|!set_bonus.tier30_2pc)
```

**Explanation:**
- `use_item,name=...` – Triggers on-use trinket by name
- `use_items,slots=trinket1` – Generic trinket slot usage with conditions
- `if=...` – Conditions (buff presence, talent checks, cooldown state)
- `trinket.XXX.cooldown.ready` – Queries trinket cooldown state
- `set_bonus.tier30_2pc` – References 2-piece tier set bonus state
- `buff.XXX.up` – Checks if player has a buff active

- **Source:** [GitHub – T31_Rogue_Subtlety.simc](https://github.com/simulationcraft/simc/blob/dragonflight/profiles/Tier31/T31_Rogue_Subtlety.simc)

---

## 3. Hekili Spec Module Gear Registration (Concluded 12.0)

### Project Status

**Hekili has concluded development** as of **January 20, 2026 (WoW patch 12.0 – Midnight).**

**Reason:** "The new direction with Blizzard's API makes it impossible to continue the addon in a way that would meet our design goals and quality standards."

- **Source:** [GitHub – Hekili/hekili repository](https://github.com/Hekili/hekili) (project status page)

### Why It Matters

Hekili's cessation marks the end of third-party complex rotation logic modeling based on gear state. The addon used SimulationCraft APL logic to recommend actions based on:
- Equipped trinkets and their passive procs
- Active tier set bonuses
- Buff states from equipped gear effects
- On-use trinket cooldown coordination

### registerGear Pattern (Historical Context)

While direct API documentation is not available post-shutdown, Hekili's architecture included:
- Spec modules registering trinkets and set bonuses at initialization
- Runtime queries of equipped items via GetInventoryItemID
- Event handlers for PLAYER_EQUIPMENT_CHANGED to refresh state
- Buff/aura scanning to detect active proc effects

**Source:** [GitHub – Hekili (archived)](https://github.com/Hekili/hekili) – historical reference only; specific registerGear function definitions not extracted as repository is inactive

### Modern Alternatives (Midnight-Compliant)

**HekiLight** – Successor addon that reads Blizzard's built-in Rotation Assistant (C_AssistedCombat API) and re-displays suggestions. No custom gear modeling.

**Knickili** – Shows spell recommendations from Blizzard's Single Button Assistant, which automatically incorporates gear state but does not expose gear modeling to third-party code.

- **Source:** [CurseForge – HekiLight](https://www.curseforge.com/wow/addons/hekilight), [CurseForge – Knickili](https://www.curseforge.com/wow/addons/knickili)

---

## 4. Proc & Buff Modeling

### Aura Scanning by Spell ID

**Detection Method:**
- Addons monitor Combat Log events: `SPELL_AURA_APPLIED` and `SPELL_AURA_REMOVED`
- Each trinket proc is registered by its **Spell ID** (not item ID)
- Example: Trinket proc effect → Spell ID 163727 (Item - Trinket Proc Summon Guardian)

**Why Combat Log, Not Cooldown API:**
- Passive procs (no inventory cooldown) require buff detection
- Buff duration is auto-detected via `UnitAura()` queries
- Cooldown state is derived from buff duration + proc application timestamp

- **Source:** [WoWInterface – Trinket Proc Detection Discussion](https://www.wowinterface.com/forums/showthread.php?t=48173), [Wowhead – Trinket Proc Examples](https://www.wowhead.com/spell=163727/item-trinket-proc-summon-guardian)

### Trinket Proc Data Sources

**SimulationCraft Item Database:**
- Maintains a separate trinket database with proc mechanics
- Proc data is generated via DBC (Blizzard game database) extraction
- Includes: on-use stat buffs, passive proc triggers, cooldowns, durations
- Accessible programmatically via simc_support Python package (see Trinket.py)

- **Source:** [GitHub – simc_support/Trinket.py](https://github.com/Bloodmallet/simc_support/blob/master/simc_support/game_data/Trinket.py/), [PyPI – simc_support](https://pypi.org/project/simc-support/10.0.2.13)

**Wowhead Item Database:**
- Public API endpoint: `get_item` returns: id, name, icon, link, class, subclass, level, quality, json, jsonEquip
- Spell data via `get_spell` endpoint resolves proc spell IDs to names
- Spell ID lookup: item trinket effects link to spell pages (e.g., /spell=163727/)

- **Source:** [Parse.bot – Wowhead API Documentation](https://parse.bot/marketplace/dcf24c30-539c-47c6-ad80-e754dfb7e99e/wowhead-com-api), [Wowhead – Spell Database](https://www.wowhead.com/spell=163727/item-trinket-proc-summon-guardian)

### Trinket Data Structure (simc_support)

SimulationCraft's Trinket.py dataclass tracks:
- **Core:** Item ID, name, quality, item level
- **Stats:** stat_type_1 through stat_type_10 (primary stats like Agility, Strength)
- **Context:** Encounter ID, instance type, raid tier, expansion, season
- **Property:** `on_use` boolean flag

**Important Limitation:** Proc-specific data (spell IDs, proc rates, cooldown mechanics, duration) is **NOT explicitly exposed** in the visible Trinket structure. Advanced proc mechanics appear to be handled through separate spell/effect databases.

- **Source:** [GitHub – simc_support/Trinket.py](https://github.com/Bloodmallet/simc_support/blob/master/simc_support/game_data/Trinket.py/)

---

## 5. On-Use Trinket Recommendations: Status in Midnight

### Historical Approach

Rotation addons like Hekili queued on-use trinkets into action priority lists. The APL evaluated:
1. Current cooldown state (trinket available?)
2. Buff conditions (player has haste buff, etc.)
3. Remaining fight time
4. Cooldown alignment with burst windows

Example Hekili-era behavior: "Press trinket now if buff is up and cooldown is ready"

### Midnight Restrictions (NEEDS-MIDNIGHT-VERIFICATION)

**Combat Log Access Blocked:**
- `COMBAT_LOG_EVENT` and `COMBAT_LOG_EVENT_UNFILTERED` now cause addon errors
- Proc aura scanning is compromised if proc buffs were historically tracked via combat log

- **Source:** [Warcraft Wiki – Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)

**Secret Values System:**
- "API changes introduced with aim to limit addons from complex logic based off combat information"
- Functions like `C_Secrets.HasSecretRestrictions` and `C_RestrictedActions.IsAddOnRestrictionActive` control data visibility
- In-combat cooldown queries return "secret values" (hidden from addons)

- **Source:** [Warcraft Wiki – Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)

**Trinket Cooldown PvP Exploit Fix:**
- Blizzard fixed an exploit allowing addons to access PvP trinket cooldowns for other players
- `GetActionCooldown` now tracks PvP trinket loss-of-control (LoC) cooldown
- Addons must cache cooldown durations **out of combat** and compute remaining time via elapsed timestamp

- **Source:** [Warcraft Wiki – Patch 12.0.5/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.5/API_changes)

**Rotation Helper Automation Blocked:**
- Third-party rotation helpers (like Hekili) are completely blocked in Midnight
- Blizzard replaced them with built-in Assisted Highlights and Single Button Rotation Assistant
- Modern addons like HekiLight and Knickili are **display-only** wrappers around Blizzard's C_AssistedCombat API

- **Source:** [CurseForge – HekiLight](https://www.curseforge.com/wow/addons/hekilight), [WoW Forums – Rotation Assist in Midnight](https://us.forums.blizzard.com/en/wow/t/in-midnight-is-blizzard%E2%80%99s-rotation-assist-meant-to-replace-addons-like-hekili/2212381)

### Surviving Trinket Features (Midnight-Compatible)

**Trinket Swap Addons (Still Functional):**
- TrinketMenu, TrinketSwap, GearMenu still work but are **user-initiated**, not automated
- Players manually queue trinket swaps via dropdown menu; swap occurs on combat exit
- No automation of on-use trinket presses; no real-time buff-based recommendations

- **Source:** [CurseForge – TrinketMenu](https://www.curseforge.com/wow/addons/trinket-menu), [CurseForge – TrinketSwap](https://www.curseforge.com/wow/addons/trinketswap), [GitHub – wow-gearmenu](https://github.com/RagedUnicorn/wow-gearmenu)

**Trinket Proc Trackers (Still Functional):**
- WeakAuras can display trinket proc buffs by spell name or ID (manually configured)
- Filger addon provides aura tracking for trinket procs
- Both work via standard buff/debuff queries (not combat log), so Midnight-safe

- **Source:** [Wago.io – Trinket Proc WeakAura Templates](https://wago.io/m8TRqFzZ5), [GitHub – Filger](https://github.com/lua-wow/Filger)

### Conclusion on On-Use Recommendations

- **Pre-Midnight:** Rotation addons like Hekili recommended trinket usage via APL + buff/cooldown state → **Blocked**
- **Midnight:** Only display-only wrappers (HekiLight, Knickili) around Blizzard's built-in assistant → **No gear-aware automation**
- **Implication:** Complex trinket recommendation logic based on gear state, buff state, and cooldowns is no longer implementable via third-party addons

---

## Summary Table: Gear Detection Lineage

| Layer | Pre-Midnight | Midnight Status | Notes |
|-------|---|---|---|
| **Equipment Detection** | GetInventoryItemID, C_Item namespace | Still works | C_Item API is modern preferred method |
| **Trinket Slot Queries** | Slots 13, 14 via GetInventoryItemID | Still works | TrinketTracker confirms functionality |
| **Tier Set Detection** | C_Item.GetItemSetInfo (inferred) | NEEDS-VERIFICATION | Addons use it but exact API not exposed |
| **Equipment Change Event** | PLAYER_EQUIPMENT_CHANGED | Still works | Trinket addons register this event |
| **Set Bonus APL Logic** | SimulationCraft set_bonus.tier_2pc | Offline only | APL is used in theory; no addon executes it |
| **Proc Aura Scanning** | Combat log (SPELL_AURA_APPLIED/REMOVED) | **Broken** | COMBAT_LOG_EVENT now errors |
| **Buff Duration Queries** | UnitAura() for trinket proc buffs | Still works (outside combat) | Secret values apply in combat |
| **Cooldown State Queries** | GetActionCooldown | **Restricted** | Returns secrets in combat; cache required |
| **Rotation Helper Automation** | Hekili (ended 12.0) | **Blocked** | Replaced by Blizzard's Assisted Highlights |
| **Trinket On-Use Recommendation** | Hekili APL execution | **Impossible** | No third-party automation allowed |
| **Trinket Swapping** | TrinketMenu automation | User-initiated only | Works but requires manual queue |

---

## Unverified & Flagged Items

1. **C_Item.GetItemSetInfo exact function name** – Inferred from addon usage (Details!, O Item Level) but not directly confirmed in API docs (UNVERIFIED)
2. **PLAYER_EQUIPMENT_CHANGED event firing semantics** – Assumed to fire on gear change but exact trigger timing not verified (UNVERIFIED)
3. **Proc data in simc_support.Trinket** – Visible structure lacks dedicated proc spell ID fields; may be stored elsewhere (UNVERIFIED)
4. **Midnight combat log alternatives** – Whether addons can use PLAYER_EQUIPMENT_CHANGED + buff queries as a workaround for proc detection (NEEDS-MIDNIGHT-VERIFICATION)
5. **Secret values impact on buff queries** – Whether UnitAura returns secrets for trinket procs in-combat (NEEDS-MIDNIGHT-VERIFICATION)

---

## Sources

- [Vanilla WoW Wiki – GetInventoryItemID](https://vanilla-wow-archive.fandom.com/wiki/API_GetInventoryItemID)
- [Warcraft Wiki – GetInventoryItemID](https://warcraft.wiki.gg/wiki/API_GetInventoryItemID)
- [Warcraft Wiki – C_Item.GetItemInfo](https://warcraft.wiki.gg/wiki/API_C_Item.GetItemInfo)
- [GitHub – InspectEquip addon](https://github.com/Nukme/InspectEquip)
- [CurseForge – TrinketTracker (Midnight)](https://www.curseforge.com/wow/addons/trinkettracker-midnight)
- [CurseForge – Details! Item Level Plugin](https://www.curseforge.com/wow/addons/details-item-level-plugin)
- [CurseForge – O Item Level](https://www.curseforge.com/wow/addons/o-item-level)
- [GitHub – SimulationCraft Equipment Wiki](https://github.com/simulationcraft/simc/wiki/Equipment)
- [GitHub – SimulationCraft Rogue Profile](https://github.com/simulationcraft/simc/blob/dragonflight/profiles/Tier31/T31_Rogue_Subtlety.simc)
- [GitHub – Hekili/hekili](https://github.com/Hekili/hekili)
- [WoWInterface – Trinket Proc Detection Discussion](https://www.wowinterface.com/forums/showthread.php?t=48173)
- [Wowhead – Trinket Proc Examples](https://www.wowhead.com/spell=163727/item-trinket-proc-summon-guardian)
- [GitHub – simc_support/Trinket.py](https://github.com/Bloodmallet/simc_support/blob/master/simc_support/game_data/Trinket.py/)
- [PyPI – simc_support](https://pypi.org/project/simc-support/10.0.2.13)
- [Parse.bot – Wowhead API Documentation](https://parse.bot/marketplace/dcf24c30-539c-47c6-ad80-e754dfb7e99e/wowhead-com-api)
- [Warcraft Wiki – Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)
- [Warcraft Wiki – Patch 12.0.5/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.5/API_changes)
- [CurseForge – HekiLight](https://www.curseforge.com/wow/addons/hekilight)
- [CurseForge – Knickili](https://www.curseforge.com/wow/addons/knickili)
- [WoW Forums – Rotation Assist in Midnight](https://us.forums.blizzard.com/en/wow/t/in-midnight-is-blizzard%E2%80%99s-rotation-assist-meant-to-replace-addons-like-hekili/2212381)
- [CurseForge – TrinketMenu](https://www.curseforge.com/wow/addons/trinket-menu)
- [CurseForge – TrinketSwap](https://www.curseforge.com/wow/addons/trinketswap)
- [GitHub – wow-gearmenu](https://github.com/RagedUnicorn/wow-gearmenu)
- [Wago.io – Trinket Proc WeakAura Templates](https://wago.io/m8RqFzZ5)
- [GitHub – Filger](https://github.com/lua-wow/Filger)
