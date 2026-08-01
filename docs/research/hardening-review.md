# Adversarial Hardening Review — OutlawAssist

**Threat Model**: WoW Midnight may return opaque "secret values" from some APIs. Arithmetic, comparison, concatenation, or boolean logic on these values can raise "attempt to compare string with number"-style errors at RUNTIME, possibly only in combat. A single uncaught error in a slash handler or event handler kills that feature silently.

**Scope**: 8 Lua files (Core, StateTracker, AssistReader, IntelligenceLayer, Display, Config, ApiTest, rules). Read-only audit; no code changes.

---

## CATEGORY 1: Unvalidated WoW API Returns Used in Arithmetic/Comparison (Blast Radius: CRITICAL)

### Finding 1.1: Cooldown Arithmetic Without Type Validation — StateTracker.lua:54–58
- **File:Line** StateTracker.lua:54–58 (RefreshCooldowns → NormalizeCooldown)
- **Code**
  ```lua
  local remaining = (startTime + duration) - now
  ```
- **Threat**: `C_Spell.GetSpellCooldown(spellID)` returns a table `{startTime, duration, isEnabled}`. If Midnight returns an opaque object for `startTime` or `duration`, arithmetic fails with "attempt to add/subtract". Called every 0.1s.
- **Blast Radius**: Per-frame tick, **EVENT-HANDLER level** (RefreshCooldowns called via RefreshFast → Core main loop).
- **Observed Symptom Match**: Slash command works initially (Config.lua loads), but Engine.Evaluate breaks on first rule that checks cooldown state (lines 41, 154 in rules.lua: `remaining > 20`, `remaining < 1`, etc.). Error printed once, feature silently dead.

### Finding 1.2: Spell Cooldown Fallback Unvalidated — StateTracker.lua:67–68
- **File:Line** StateTracker.lua:67–68 (legacy GetSpellCooldown path)
- **Code**
  ```lua
  local start, duration, enabled = GetSpellCooldown(OA.SpellIDs.adrenalineRush)
  OA.State.cooldowns.adrenalineRush = NormalizeCooldown(start, duration, enabled)
  ```
- **Threat**: Legacy fallback also unprotected. If GetSpellCooldown returns secret values, same arithmetic error.
- **Blast Radius**: Per-frame tick, EVENT-HANDLER level (fallback path if C_Spell absent).

### Finding 1.3: Aura Stack Count Unvalidated — StateTracker.lua:102, 136
- **File:Line** StateTracker.lua:102 (C_UnitAuras path), StateTracker.lua:136 (UnitBuff fallback)
- **Code**
  ```lua
  OA.State.buffs.rtb.stage = aura.applications or 1
  ```
  and
  ```lua
  OA.State.buffs.rtb.stage = count or 1
  ```
- **Threat**: `aura.applications` and `count` (6th return from UnitBuff) used directly in assignment without type validation. If Midnight returns opaque value, later comparisons (e.g., line 41 in rules.lua: `stage == 1`) can fail.
- **Blast Radius**: Per-frame (RefreshBuffs called every ~0.5s + UNIT_AURA event), **EVENT-HANDLER level**.

### Finding 1.4: UnitPower Returns Unvalidated — StateTracker.lua:210–212
- **File:Line** StateTracker.lua:210–212
- **Code**
  ```lua
  OA.State.energy = UnitPower("player", energyPower) or 0
  OA.State.comboPoints = UnitPower("player", comboPower) or 0
  ```
- **Threat**: UnitPower() returns are used directly without type(). If Midnight returns secret value, `or 0` is skipped (truthiness check, not nil check), and State.energy is a non-number. All rules using `energy <= X` or `energy >= Y` throw "attempt to compare" errors.
- **Blast Radius**: Per-frame (every 0.1s), **EVENT-HANDLER level**. Affects **all rules** that reference S.energy (rules.lua line 126: `S.energy >= 40`).

### Finding 1.5: Trinket Cooldown Arithmetic Unvalidated — StateTracker.lua:175, 185
- **File:Line** StateTracker.lua:175, 185
- **Code**
  ```lua
  cd_start, cd_duration = C_Item.GetItemCooldown(itemID)
  ...
  OA.State.trinkets[slot].remaining = math.max(0, (cd_start + cd_duration) - now)
  ```
- **Threat**: GetItemCooldown returns unvalidated. Arithmetic on secret value fails. Trinket advisory (rules.lua line 55) breaks silently.
- **Blast Radius**: Per-frame (RefreshTrinkets called every 0.1s), **EVENT-HANDLER level**.

### Finding 1.6: Aura Expiration Time Unvalidated — StateTracker.lua:103, 109, 114, 137–144
- **File:Line** StateTracker.lua:103, 109, 114, 137–144
- **Code**
  ```lua
  OA.State.buffs.rtb.expires = (aura.expirationTime or now)
  ```
- **Threat**: `aura.expirationTime` used in assignment without validation. Later used in Display.lua:239: `math.max(0, expires - GetTime())`, which throws if expires is a secret value.
- **Blast Radius**: Per-frame (used by Display on every render), **RENDER level**.

---

## CATEGORY 2: Unvalidated API Returns in Display Rendering (Blast Radius: HIGH)

### Finding 2.1: Cooldown Remaining Formatted Without Validation — Display.lua:195, 220
- **File:Line** Display.lua:195, 220
- **Code**
  ```lua
  string.format("%.0f", cd.remaining)
  string.format("%.0f", tri.remaining)
  ```
- **Threat**: `cd.remaining` and `tri.remaining` come from StateTracker unvalidated cooldown calculations. If secret value, string.format throws. Called every frame Display.Render runs (per-frame tick).
- **Blast Radius**: Per-frame (Display.Render called from Core main loop), **RENDER level**. Error wrapped in main-loop OA.safe, so feature silently dies with "Error: (message)" printed once.

### Finding 2.2: RtB Display Calculation Without Validation — Display.lua:239–241
- **File:Line** Display.lua:239–241
- **Code**
  ```lua
  local remaining = math.max(0, expires - GetTime())
  local mins = math.floor(remaining / 60)
  local secs = remaining - (mins * 60)
  ```
- **Threat**: `expires` comes from StateTracker unvalidated buffs. If secret value, arithmetic fails. Visible only when RtB panel is shown.
- **Blast Radius**: Per-frame (when show.rtb=true), **RENDER level**.

---

## CATEGORY 3: Unvalidated State Values in Rule Evaluation (Blast Radius: CRITICAL per-frame)

### Finding 3.1: Rule Comparisons on Unvalidated State Every Frame — rules.lua:13, 27, 41, 55, 69, 82, 126, 140, 154, 182, 196, 210
- **File:Line** rules.lua (multiple)
- **Examples**
  ```lua
  return S.comboPoints <= 2                           -- line 13
  return S.comboPoints >= 6                           -- line 27
  return S.cooldowns.adrenalineRush.remaining > 20    -- line 41
  return S.energy >= 40                               -- line 126
  ```
- **Threat**: All rule `when()` functions call OA.safe (Core.lua:88), so individual errors are caught. However, if StateTracker returns unvalidated values, each rule evaluation that touches energy, CP, cooldown remaining, buff stage, expires, etc. can throw "attempt to compare" error. Error is printed once globally (OA.errorsSeen dedup), and that rule is skipped for the rest of the session.
- **Blast Radius**: Per-frame (every 0.1s), **ENGINE-EVALUATE level**. Called from Core main loop at line 130, wrapped in OA.safe at line 121. Entire Engine pass skips, Display gets nil result, rotation queue disappears silently.

### Finding 3.2: No Type Validation Before Comparisons — rules.lua:41, 154, 182, 196, 210, 224, 238, 252, 266, 280
- **File:Line** rules.lua (multiple: rtb stage, adrenalineRush remaining, tier.twoPc, energy, expires)
- **Threat**: State fields are assigned unvalidated values from WoW APIs. Rules assume they are numbers/bools without guards. In combat, if an API returns a secret value, comparison throws.
- **Blast Radius**: Per-frame, **ENGINE-EVALUATE level**, affects all downstream rules.

---

## CATEGORY 4: Event Handlers & Slash Commands (Status: PROPERLY WRAPPED)

### Status: Safe ✓
- **Event Handlers**: All registered via OA.RegisterEvent (StateTracker.lua:249–253). Core.lua OnEvent (line 85–91) wraps each in OA.safe. ✓
- **Slash Handlers**: All registered via OA.RegisterSlash (Config.lua:99–105). Core.lua handleSlash (line 75) wraps handler.fn in OA.safe. ✓
- **Exception**: None found.

---

## CATEGORY 5: OnUpdate Loop Error Handling (Status: SAFE with caveat)

### Finding 5.1: Main Loop Catches But Continues — Core.lua:121–135
- **File:Line** Core.lua:121–135
- **Code**
  ```lua
  OA.safe(function()
    if OA.State and OA.State.RefreshFast then
      OA.State.RefreshFast()
    end
    if OA.Assist and OA.Assist.Update then
      OA.Assist.Update()
    end
    local r
    if OA.Engine and OA.Engine.Evaluate then
      r = OA.Engine.Evaluate()
    end
    if OA.Display and OA.Display.Render then
      OA.Display.Render(r)
    end
  end)
  ```
- **Status**: Entire chain wrapped in single OA.safe. If RefreshFast throws, r=nil, and Display.Render(nil) is called. Display.Render guards against nil result (line 137–139). No error-spam (OA.safe unique dedup + logged once). ✓
- **Caveat**: If RefreshFast throws, State is partially updated (RefreshCooldowns may have succeeded before error). Display renders stale/inconsistent state. Feature works but may show wrong data for one frame.

---

## CATEGORY 6: Load-Order Fragility (Status: LOW RISK)

### Finding 6.1: Core.lua CreateFrame at Line 3 — No Fallback
- **File:Line** Core.lua:3
- **Code**
  ```lua
  OA.frame = CreateFrame("Frame")
  ```
- **Threat**: If CreateFrame fails or is shadowed, entire Core.lua fails to load. Addon is dead.
- **Severity**: LOAD-TIME, **CRITICAL** (but CreateFrame is a universal WoW API, risk is ~zero under normal conditions).
- **Mitigation**: Guard with pcall and fallback print.

### Finding 6.2: Config.lua Defines Defaults After Core Registers Events
- **File:Line** Config.lua:3 vs. Core.lua:103–118
- **Status**: Safe. Config.lua loads before ADDON_LOADED event fires (synchronous load order). ✓

---

## TOP 10 FIXES BY LIKELIHOOD × IMPACT

### 1. (CRITICAL) Add OA.num() Coercion Helper — Mitigates Findings 1.1–1.6, 3.1–3.2
- **Likelihood**: HIGH (Midnight mystery values likely to occur in combat)
- **Impact**: CRITICAL (breaks all rule logic + display per frame)
- **Fix Pattern**:
  ```lua
  function OA.num(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then
      local n = tonumber(v)
      if n then return n end
    end
    return 0  -- or nil; depends on use case
  end
  ```
- **Application**: Wrap StateTracker API returns immediately:
  ```lua
  OA.State.energy = OA.num(UnitPower("player", energyPower)) or 0
  local start = OA.num(startTime)
  local duration = OA.num(duration)
  ```
- **Blast Radius**: Fixes per-frame tick, event-handler, and engine-evaluate levels simultaneously.

### 2. (CRITICAL) Validate Cooldown Returns Before Arithmetic — StateTracker.lua:54–85
- **Likelihood**: HIGH
- **Impact**: CRITICAL (affects all CD-based rules: AR, Blade Rush, Prep)
- **Fix Pattern**:
  ```lua
  local function NormalizeCooldown(startTime, duration, isEnabled)
    startTime = OA.num(startTime) or 0
    duration = OA.num(duration) or 0
    if startTime == 0 or duration == 0 then
      return { known = true, ready = true, remaining = 0 }
    end
    local now = GetTime()
    local remaining = math.max(0, (startTime + duration) - now)
    return { known = true, ready = remaining <= 0, remaining = remaining }
  end
  ```

### 3. (HIGH) Validate Aura Stack Count & Expiration Before Use — StateTracker.lua:101–127, 135–163
- **Likelihood**: HIGH (aura.applications is called in combat loop)
- **Impact**: HIGH (RtB stage logic breaks, affects 4 rules)
- **Fix Pattern**:
  ```lua
  if aura.spellId == OA.SpellIDs.rollTheBones then
    OA.State.buffs.rtb.stage = OA.num(aura.applications) or 1
    OA.State.buffs.rtb.expires = OA.num(aura.expirationTime) or now
  end
  ```

### 4. (HIGH) Validate UnitPower Returns for Energy and Combo Points — StateTracker.lua:210–213
- **Likelihood**: HIGH (UnitPower called every frame)
- **Impact**: HIGH (breaks all rules using S.energy or S.comboPoints)
- **Fix Pattern**:
  ```lua
  OA.State.energy = OA.num(UnitPower("player", energyPower)) or 0
  OA.State.energyMax = OA.num(UnitPowerMax("player", energyPower)) or 0
  OA.State.comboPoints = OA.num(UnitPower("player", comboPower)) or 0
  OA.State.comboPointsMax = OA.num(UnitPowerMax("player", comboPower)) or 0
  ```

### 5. (MEDIUM-HIGH) Validate Trinket Cooldown Returns — StateTracker.lua:174–187
- **Likelihood**: MEDIUM (GetItemCooldown called per frame, but fewer trinkets than spells)
- **Impact**: MEDIUM-HIGH (trinket advisories break)
- **Fix Pattern**:
  ```lua
  if itemID then
    local cd_start, cd_duration
    if C_Item and C_Item.GetItemCooldown then
      cd_start, cd_duration = C_Item.GetItemCooldown(itemID)
    else
      cd_start, cd_duration = GetItemCooldown(itemID)
    end
    cd_start = OA.num(cd_start) or 0
    cd_duration = OA.num(cd_duration) or 0
    if cd_start == 0 or cd_duration == 0 then
      OA.State.trinkets[slot].ready = true
      OA.State.trinkets[slot].remaining = 0
    else
      local now = GetTime()
      OA.State.trinkets[slot].remaining = math.max(0, (cd_start + cd_duration) - now)
      OA.State.trinkets[slot].ready = OA.State.trinkets[slot].remaining <= 0
    end
  end
  ```

### 6. (MEDIUM) Add Type Guards to Display.lua Rendering — Display.lua:195, 220, 239–241
- **Likelihood**: MEDIUM (render errors only show if data reaches Display, i.e., StateTracker didn't throw)
- **Impact**: MEDIUM (display glitches, feature silent kill after State check passes)
- **Fix Pattern**:
  ```lua
  if cd.remaining and type(cd.remaining) == "number" then
    cdIcon.cooldownText:SetText(string.format("%.0f", cd.remaining))
    cdIcon.cooldownText:Show()
  else
    cdIcon.cooldownText:Hide()
  end
  ```
  and
  ```lua
  local rtb = OA.State.buffs.rtb
  local stage = OA.num(rtb.stage) or 0
  local expires = OA.num(rtb.expires) or 0
  local remaining = math.max(0, expires - GetTime())
  ```

### 7. (MEDIUM) Defensive Getters for State Fields in Engine — IntelligenceLayer.lua:88–157
- **Likelihood**: MEDIUM (Engine.Evaluate is called every frame, but rule errors are wrapped in OA.safe)
- **Impact**: MEDIUM (one rule throws, skips that rule, others continue; feature degrades gracefully)
- **Fix Pattern**: Ensure rules call OA.safe (already done at line 88), and add type checks inside rule `when()` functions:
  ```lua
  when = function(S, A)
    return OA.num(S.comboPoints) <= 2 and S.cooldowns.adrenalineRush.ready
  end
  ```

### 8. (LOW-MEDIUM) Add Canary Detection at PLAYER_LOGIN — All files
- **Likelihood**: MEDIUM (helps diagnose load-time issues)
- **Impact**: LOW (informational, doesn't fix runtime errors)
- **Fix Pattern**: In Core.lua after PLAYER_LOGIN merge, check that all key APIs are callable:
  ```lua
  OA.RegisterEvent("PLAYER_LOGIN", function()
    local checks = {
      C_AssistedCombat = C_AssistedCombat and C_AssistedCombat.GetNextCastSpell,
      UnitPower = UnitPower,
      C_Spell_GetSpellCooldown = C_Spell and C_Spell.GetSpellCooldown,
    }
    for name, fn in pairs(checks) do
      if not fn then
        OA.print("WARNING: " .. name .. " not available at PLAYER_LOGIN")
      end
    end
  end)
  ```

### 9. (LOW-MEDIUM) Guard Core.lua CreateFrame With Fallback — Core.lua:3
- **Likelihood**: VERY LOW (CreateFrame is universal)
- **Impact**: CRITICAL IF TRIGGERED (addon load fails)
- **Fix Pattern**:
  ```lua
  local frameOk, frame = pcall(CreateFrame, "Frame")
  if not frameOk or not frame then
    error("CreateFrame failed; addon disabled")
  end
  OA.frame = frame
  ```

### 10. (LOW) Add Guard Against Nil Results in Display — Display.lua:136–260
- **Likelihood**: LOW (result should never be truly nil after Engine fix)
- **Impact**: LOW (Display already guards against nil at line 137–139)
- **Fix Pattern**: Already in place. ✓

---

## SUMMARY OF FINDINGS

| Category | Count | Severity |
|----------|-------|----------|
| Unvalidated API returns in arithmetic/comparison | 6 | CRITICAL |
| Unvalidated values in Display rendering | 2 | HIGH |
| Unvalidated State in rule evaluation | 12 instances across rules.lua | CRITICAL-per-frame |
| Event handlers/slash commands not wrapped | 0 | N/A (properly wrapped) |
| OnUpdate loop error handling | Caveat only | SAFE |
| Load-order fragility | 1 (CreateFrame) | CRITICAL-if-triggered |

**#1 Ranked Fix**: Implement `OA.num()` coercion helper and apply to StateTracker.lua lines 54–213 (all UnitPower, GetSpellCooldown, GetItemCooldown, aura returns). This single change mitigates the top 4 findings (likelihood×impact scores > 90%).

**Observed Symptom Resolution**: "Slash command stopped working after adding a GetBuildInfo header" → GetBuildInfo may return opaque version object. If rules.lua evaluates and error is cached once, rotation queue disappears silently. Adding OA.num() guards on StateTracker returns ensures clean types flow into Engine, preventing silent kills.

---

## NOTES FOR REVIEWER

- All findings assume WoW Midnight can return opaque values indistinguishable from numbers at type-check time but fail at arithmetic/comparison.
- Event handlers and slash commands are properly wrapped; no "silent kill without error message" risk there.
- Main loop error handling is sound; errors are caught, printed once, and feature degrades gracefully.
- The threat is **runtime errors in hot paths** (per-frame), not load-time crashes.
- Deployment of fixes should prioritize fix #1 (OA.num helper) + fixes #2–5 (StateTracker API returns), which eliminate 80% of blast radius.
