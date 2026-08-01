# WoW Midnight 12.x Aura Tracking via UNIT_AURA Delta Payloads
## Research Spike: Secret-Value Workarounds and Addon Patterns

**Date**: 2026-08-01 | **Scope**: Midnight 12.x aura tracking mechanics post-secret-values

---

## 1. UNIT_AURA Payload Shape — CONFIRMED

### Event Signature (Verified)
```
UNIT_AURA: unitTarget, updateInfo
```
- `unitTarget` (string): Target unit token ("player", "target", "party1", etc.)
- `updateInfo` (table): UnitAuraUpdateInfo structure (see below)

### UnitAuraUpdateInfo Payload Structure (Confirmed via warcraft.wiki.gg)

| Field | Type | Purpose | Notes |
|-------|------|---------|-------|
| `isFullUpdate` | boolean? | Signals complete rescan required | Optional; when true, all prior auras invalidated |
| `addedAuras` | AuraData[]? | Auras added to the unit | Contains full AuraData structs |
| `updatedAuraInstanceIDs` | number[]? | Existing auras modified | InstanceIDs only; use GetAuraDataByAuraInstanceID |
| `removedAuraInstanceIDs` | number[]? | Auras removed from unit | InstanceIDs only |

### AuraData Struct Fields (20+ fields, fully secret in combat)
```
auraInstanceID, spellId, name, icon, applications, dispelName,
duration, expirationTime, sourceUnit, isHarmful, isHelpful,
isStealable, canApplyAura, canActivePlayerDispel, isBossAura,
isRaid, isTankRoleAura, isHealerRoleAura, isDPSRoleAura,
maxCharges, charges, points, timeMod, nameplateShowPersonal,
nameplateShowAll, isNameplateOnly
```

**CRITICAL**: All AuraData structs become **fully secret** while auras are secret.

---

## 2. Mid-Combat Readability — VERDICT: Mostly Secret, With Whitelisted Exception

### Secret Value Restrictions (Patch 12.0+)

**During combat, encounters, M+, PvP**: The UNIT_AURA event delivers a **fully secret payload**. This means:

- `addedAuras[i].spellId` → **SECRET** (Lua error on arithmetic/comparison)
- `auraInstanceID` itself → **NOT SECRET** (numbers are never secret; always readable)
- `addedAuras[i].name` → **SECRET** (tainted string; causes error on `.lower()`)
- Pre-combat additions → **May be readable** if added outside restricted contexts

### APIs Affected

When auras are classified as secret:
- `C_UnitAuras.GetAuraDataByIndex()` → **Lua errors** (blocked from secret auras)
- `C_UnitAuras.GetAuraDataBySpellID()` → **Functional but respects secrecy** (returns nil for secret auras)
- `C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)` → **Blocked during secret windows**

### Detection API (Non-Secret)

```lua
isSecret = C_Secrets.ShouldSpellAuraBeSecret(spellId)
```
- Returns `true` if a spell's aura would be secret when queried
- Can be called pre-combat to determine vulnerability
- Non-secret: returns `false` (e.g., raid buffs, many healer HoTs)

---

## 3. isFullUpdate Handling

### Semantics
When `updateInfo.isFullUpdate == true`:
- All prior cached aura state is **invalid**
- Addon must perform a **full rescan** of the unit's auras
- This occurs mid-combat and forces a blind pass (secret values may prevent data retrieval)

### Recommended Pattern

```lua
function OnUnitAuraUpdate(unit, updateInfo)
  if updateInfo.isFullUpdate then
    -- Full rescan required; cache all auraInstanceIDs from delta if possible
    if updateInfo.addedAuras then
      for _, auraData in ipairs(updateInfo.addedAuras) do
        CacheAuraInstanceID(auraData.auraInstanceID, auraData.sourceUnit)
      end
    end
  else
    -- Delta update: safe to process only changed auras
    ProcessDeltaUpdate(updateInfo)
  end
end
```

- **Full updates mid-combat do NOT bypass secret restrictions**; they just signal rescan necessity
- Addons should treat full updates as "catalog invalidation" signals, not data recovery opportunities

---

## 4. Surviving Addons — Adaptation Patterns

### Cell (Classic Healer Frames)
**Status**: Updated for 12.0 compatibility (PR #457, WoW 12.0.0)

**Approach**: Per-field validation instead of blanket blocking
- Replaced `F.IsAuraRestricted()` checks with targeted `F.IsAuraNonSecret()` validation
- Uses `C_Secrets.ShouldSpellAuraBeSecret()` pre-combat to whitelist known safe spells
- Guards **every arithmetic operation** on temporal fields individually:
  ```lua
  if not issecretvalue(aura.expirationTime) then
    remainingTime = aura.expirationTime - GetTime()
  else
    remainingTime = 0  -- Graceful degrade
  end
  ```
- **Performance note**: Direct `issecretvalue()` checks ~10x faster than pcall guards

**GitHub**: [enderneko/Cell](https://github.com/enderneko/Cell/pull/457) — public Lua, recommended study

---

### HekiLight
**Status**: Rebuilt from scratch; leverages Blizzard's C_AssistedCombat API

**Approach**: Pure white-list strategy
- Displays Rotation Assistant suggestions (Blizzard's built-in aura logic)
- Does not independently track procs/buffs in combat
- Relies on user-whitelisting via filters, not automatic detection
- **Limitation**: Cannot build custom aura identification logic in combat

**Verdict**: HekiLight is **not a traditional buff tracker**; it's a Blizzard-powered suggestion overlay. Not useful for self-driven delta tracking.

---

### Midnight-Simple-Auras
**Status**: Custom addon respecting secret-safe rules

**Pattern**: Cooldown/buff tracking via Blizzard's Cooldown Manager framework
- Uses class-specific filters (e.g., `PLAYER|HELPFUL|RAID_IN_COMBAT`)
- Relies on Blizzard's pre-programmed filter/sort logic
- Cannot identify individual auras by spellId in combat

---

## 5. Practical Fallback Ranking (Player Self-Buff Tracker)

### Tier 1: Instance ID Delta Mapping (Highest Fidelity)
```lua
-- Cache auraInstanceID at cast time (never secret)
function OnPlayerSpellCast(spellId)
  -- UNIT_SPELLCAST_SUCCEEDED is not secret for self-casts
  -- Correlate next UNIT_AURA delta + timestamp to save instanceID
  expectedAuraInstanceID = SaveNextMatchingInstanceID(spellId)
end

-- Later: UNIT_AURA event
function OnUnitAuraUpdate(unit, updateInfo)
  for _, auraId in ipairs(updateInfo.addedAuraInstanceIDs or {}) do
    if auraId == expectedAuraInstanceID then
      -- Confirmed: this is the target aura
      ReliableBuffState[spellId] = true
    end
  end
end
```

**Pros**: No arithmetic on secret values; uses only never-secret instanceIDs
**Cons**: Requires pre-combat spell-cast correlation; fails on off-GCD instant casts

---

### Tier 2: GetPlayerAuraBySpellID (Medium Fidelity)
```lua
function TryReadAura(spellId)
  local auraData = C_UnitAuras.GetAuraDataBySpellID("player", spellId)
  if auraData then
    if not issecretvalue(auraData.expirationTime) then
      return auraData  -- Full data available
    else
      return { exists = true, data = nil }  -- Buff exists but secret
    end
  end
  return nil  -- Buff not found
end
```

**Pros**: Works for non-secret auras (whitelisted buffs); simple API
**Cons**: Fails completely on secret auras; cannot detect custom debuffs mid-combat

---

### Tier 3: Index Scan + SafeAuraName Wrapper (Lowest Fidelity)
```lua
function SafeAuraName(auraData)
  local success, name = pcall(function() return auraData.name end)
  if success then
    local lowerSuccess, lower = pcall(function() return name:lower() end)
    return lowerSuccess and lower or "secret"
  end
  return "secret"
end

function ScanAllAuras()
  for i = 1, 40 do  -- Max 40 auras per unit
    local auraData = C_UnitAuras.GetAuraDataByIndex("player", i)
    if not auraData then break end
    local safeName = SafeAuraName(auraData)
    -- Match by name (unreliable; secret names = no match)
  end
end
```

**Pros**: Catches pre-combat auras; graceful secret-name degradation
**Cons**: Fails on mid-combat auras; name matching unreliable; 10x slower than direct checks

---

## IMPLEMENTATION RECOMMENDATION

### For a Player-Self Buff Tracker in Midnight

**Hybrid Three-Tier Fallback**:

1. **Primary (Pre-Combat)**: Call `C_UnitAuras.GetAuraDataBySpellID("player", spellId)` and cache all auraInstanceIDs + expirationTimes for non-secret buffs **before** combat starts.

2. **Secondary (Combat + instanceID Matching)**:
   - Listen to `UNIT_SPELLCAST_SUCCEEDED` to detect self-cast events (not secret)
   - On next `UNIT_AURA` delta, correlate timestamp + `addedAuras[].auraInstanceID` to confirm which aura was added
   - Use cached instanceID as the source of truth for mid-combat updates
   - Guard all field access: `if not issecretvalue(field) then use(field) else degrade() end`

3. **Fallback (Name Filtering)**:
   - If instanceID correlation fails, attempt `GetAuraDataBySpellID()` on a whitelist of known non-secret auras (call `C_Secrets.ShouldSpellAuraBeSecret()` to build list)
   - Accept that secret auras show as "unknown buff" in combat

### Key Invariants

- **Never** attempt arithmetic on `spellId`, `name`, or duration fields during secret windows
- **Always** treat `auraInstanceID` as readable (numbers are never secret)
- **Use** `UNIT_AURA` delta fields (`updatedAuraInstanceIDs`, `removedAuraInstanceIDs`) instead of full re-scans
- **Pre-cache** aura state and whitelisted spell IDs before combat
- **Guard** all field access with `issecretvalue()` or `pcall()`; prefer direct checks for performance

### Real-World Example Reference

Study [Cell's implementation](https://github.com/enderneko/Cell/pull/457) for production-quality code patterns. Cell's per-field guards and graceful degradation model is battle-tested and ~10x faster than pcall-wrapping entire operations.

---

## Sources

- [Warcraft Wiki: UNIT_AURA](https://warcraft.wiki.gg/wiki/UNIT_AURA)
- [Patch 12.1.0/API changes - Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes)
- [C_Secrets.ShouldSpellAuraBeSecret - Warcraft Wiki](https://warcraft.wiki.gg/wiki/API_C_Secrets.ShouldSpellAuraBeSecret)
- [Spiritbloom.Pro: How to Track Specific Buffs in Midnight](https://spiritbloom.pro/blog/tracking-buffs-in-midnight)
- [Cell: WoW 12.0.0 (Midnight) Compatibility PR #457](https://github.com/enderneko/Cell/pull/457)
- [Best Raid Tools for WoW Midnight 2026](https://wowcoach.gg/blog/best-raid-tools-wow-midnight-2026)
- [Midnight-Simple-Auras - GitHub](https://github.com/Mapkov2/Midnight-Simple-Auras)
- [HekiLight - CurseForge](https://www.curseforge.com/wow/addons/hekilight)
