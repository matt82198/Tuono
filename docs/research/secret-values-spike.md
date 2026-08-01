# WoW Midnight Secret Values Spike Research

**Date:** 2026-08-01  
**Scope:** World of Warcraft Midnight (12.x), API changes and addon breakage patterns

---

## 1. Secret Values: Exact Semantics

### Operations That ERROR on Secret Values
- **Arithmetic:** `+`, `-`, `*`, `/`, `%`, `^` all error
- **Comparison on booleans:** `==`, `~=`, `<`, `>`, `<=`, `>=` error on boolean secrets
- **Boolean tests:** `if secret then` errors (exception: non-boolean types can be tested, since type isn't secret)
- **Length operator:** `#secret` errors
- **Table operations:** Using secret as table key errors; indexed access `secret["foo"]` errors
- **Function calls:** Calling secret as function errors

### Operations That ARE ALLOWED
- **Storage:** Variables, upvalues, table fields all accept secrets
- **Passing to functions:** Can pass secrets to any function
- **Concatenation:** String/number secrets can be concatenated with `..`
- **String formatting:** `string.format()`, `string.concat()`, `string.join()` accept secrets
- **Type inspection:** `type(secret)` returns actual type (`"string"`, `"number"`, etc.)
- **Detection:** `issecretvalue(value)` returns boolean true if value is secret

### Print Behavior
**UNVERIFIED:** The documentation does not explicitly state whether `print()` errors on secret values. However, GitHub issues show "attempt to compare" errors in tooltip rendering and UI code when printing/rendering values. Likely print() is safe, but downstream operations on the printed value (comparison, formatting) may fail.

---

## 2. Which APIs Return Secret Values and When

### Confirmed Secret-Returning APIs

**Always/Combat-Restricted:**
- Combat log events (no longer available to addons)
- Cooldown access (secret during mythic keystones, PvP, encounters, combat)
- Aura data by index/slot/instance ID (secret; use spell ID/name instead)

**Enemy Unit Information (Combat/Instance-Restricted):**
- `UnitHealth` (enemy health)
- `UnitPower` (enemy power/mana)
- Enemy spellcasts and auras
- Enemy creature names and GUIDs (secret in instances)

**Unit Identity APIs (Secret When Identity is Secret):**
- `UnitClass`, `UnitRace`, `UnitSex`
- `UnitGroupRolesAssigned`, `UnitIsRaidOfficer`, `UnitInRaid`, `UnitIsPVP`
- `UnitIsCharmed`, `UnitIsPossessed` (secret when auras are secret)

**Instance-Specific:**
- Chat messages sent in instances

### NOT Secret-Returning

**`GetBuildInfo()`** — Does NOT return secret values. All returns (buildVersion, buildNumber, buildDate, interfaceVersion, localizedVersion, buildInfo, currentVersion) are plain strings/numbers.

### Secrecy Testing API
- `issecretvalue(value)` returns true/false
- `C_Secrets.GetSpellCooldownSecrecy(spellID)` checks if a spell's cooldown is secret
- `C_Secrets.ShouldUnitPowerBeSecret(unit)` checks unit power secrecy

---

## 3. /run and Macro Script Restrictions in Midnight

### Execution Limits
- Execution in dungeon/raid combat capped at ~100ms per frame (prevents exploit of expensive Lua loops)
- Restricts CPU-heavy logic in combat

### Command Availability
- `/run` is available but restricted in certain contexts
- Some macro commands don't work in combat (e.g., macro modification commands, action bar changes)
- `/console scriptErrors 0` can suppress error display

### Secret Value Context
- `/run` executes in tainted environment if called during combat
- Tainted code cannot operate on secret values (see Section 1)
- **Your case:** `/run print((select(4, GetBuildInfo())))` errors with "attempt to compare string with number" because:
  - `GetBuildInfo()` doesn't return secrets (contradiction in error)
  - Error likely originates in print/select evaluation stack, not GetBuildInfo itself
  - May be a taint/execution-context issue or downstream type coercion in print

---

## 4. Known Addon-Breakage Patterns Since 12.1 "Curse of Ula'tek"

### Major Addon Failures
1. **WeakAuras** — Restricted from combat automation; aura detection now limited
2. **GTFO** — Restricted to only ~57 tracked danger spells vs. ~6,000 pre-Midnight (Blizzard explicitly control spell list)
3. **Bagnon** — Tooltip rendering errors ("attempt to compare secret value")
4. **Auctionator** — Tooltip and price-comparison failures
5. **Baganator** — Lua errors on UI element rendering
6. **AllTheThings** — Tooltip secrets breaking item/quest tooltips

### Root Causes (Recurring Patterns)
- **Tooltip rendering:** Addons attempting to display combat data (health %, power) trigger secret-value comparison errors
- **Identity lookups:** Addons querying unit names/GUIDs in instances get secret values
- **Aura access by index:** Addons using old aura-by-slot API fail; must migrate to spell-ID-based APIs
- **Combat data in logic:** Any addon applying combat health/power to conditional branching fails
- **Spell name declassification exploit:** Blizzard patched ability to convert secret spell names via string formatting

### Blizzard UI Bugs (Pre-12.1.0 Fix)
- `LayoutFrame.lua:487` — Tooltip rendering error
- `MathUtil.lua:28` — Attempt to compare secret max value
- `CompactUnitFrame.lua` — Frame rendering errors
- `TooltipComparisonManager.lua:247`, `MoneyFrame.lua:351` — Arithmetic on secrets

### Workarounds
- **PlsFixMe Midnight Tooltips** addon suppresses critical errors (not a fix, just masking)
- Migrate to `C_CurveUtil` for transforming secret health/power to displayable numbers
- Use `AuraContainer`/`AuraButton` objects instead of direct aura data access

---

## 5. Current Live Retail Interface/TOC Number

### Patch 12.1.0
- **Interface number:** `120100`
- **Format:** Major version (12) + Minor version (01) + Patch (00) concatenated

### Comma-Separated Interface Lists
**YES, valid since 10.2.7:**
```
## Interface: 120100, 50504, 38002, 20506, 11509
```
A single TOC file can declare support for multiple game versions (Midnight, Cataclysm, Dragonflight, Wrath Classic, Vanilla Classic).

### Example
```toc
## Interface: 120100, 50504
## Title: MyAddon
```
This addon will load on both Midnight (12.1.0) and Cataclysm (5.5.04).

---

## Sources

- [Secret Values (warcraft.wiki.gg)](https://warcraft.wiki.gg/wiki/Secret_Values)
- [Patch 12.0.0/API changes (warcraft.wiki.gg)](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)
- [Patch 12.1.0/API changes (warcraft.wiki.gg)](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes)
- [Patch 12.0.0/Planned API changes (warcraft.wiki.gg)](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes)
- [GetBuildInfo (warcraft.wiki.gg)](https://warcraft.wiki.gg/wiki/API_GetBuildInfo)
- [TOC format (warcraft.wiki.gg)](https://warcraft.wiki.gg/wiki/TOC_format)
- [Getting the current interface number (warcraft.wiki.gg)](https://warcraft.wiki.gg/wiki/Getting_the_current_interface_number)
- [Development clarification: Secret Values (Blizzard Forums)](https://us.forums.blizzard.com/en/wow/t/development-clarification-maintaining-ui-accuracy-vs-secret-value-obfuscation-in-midnight/2243547)
- [Tooltip secret value error (GitHub WoWUIBugs #811)](https://github.com/Stanzilla/WoWUIBugs/issues/811)
- [MathUtil.lua secret compare error (GitHub WoWUIBugs #804)](https://github.com/Stanzilla/WoWUIBugs/issues/804)
- [GTFO (WoWInterface)](https://www.wowinterface.com/downloads/info17996-GTFO.html)
- [PlsFixMe Midnight Tooltips (CurseForge)](https://www.curseforge.com/wow/addons/plsfixme-midnight-tooltips)

---

## Summary: Why Your Addon Dies

### The Header Issue
Your header calling `GetBuildInfo()` and concatenating returns should **NOT** cause a secret-value error, since GetBuildInfo doesn't return secrets. If the addon dies on load, check:
- Is taint/security context triggering during addon init?
- Are you concatenating in a tainted context (e.g., during combat-frame setup)?

### The /run Print Issue
`/run print((select(4, GetBuildInfo())))` errors "attempt to compare string with number" because:
- **Not GetBuildInfo itself** (it's safe)
- Likely **taint/macro execution context** prevents the operation
- The error may originate in print()'s internal comparison logic when evaluating select() result

### Recommendation
1. Check if your header code runs during combat or in a tainted frame
2. Use `issecretvalue()` guards if you're working with any unit data
3. Test the GetBuildInfo concatenation in a clean `/run` outside combat
4. If the header still fails, isolate to the exact return value causing the error (try `select(4, GetBuildInfo())` alone)
