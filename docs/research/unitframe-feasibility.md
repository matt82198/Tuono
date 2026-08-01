# WoW Midnight 12.x Unit Frame Addon Feasibility Research

**Date:** 2026-08-01  
**Target:** Midnight (patch 12.x post-cutoff)  
**Scope:** Can an addon replace/restyle PLAYER, TARGET, and PARTY frames? What are hard constraints?

---

## 1. SECURE/PROTECTED FRAMES

**Current Architecture:**
- `SecureUnitButtonTemplate` and `SecureGroupHeaderTemplate` (also `SecureGroupPetHeaderTemplate`) remain the standard for party/raid frames.
- `RegisterUnitWatch`, `SecureHandler` attributes, and attribute-driven combat behavior unchanged from live.

**What CANNOT be done in combat:**
- Creating new secure frames
- Showing/hiding secure frames
- Reanchoring secure frames
- Changing secure handler attributes

**Standard pattern:**
Set all frame configuration (sizing, anchoring, attribute handlers, templates) **out of combat** during login or zone-in. Let Blizzard's secure handler system manage visibility/behavior changes during combat. Taint protection is automatic via the template system.

**Status:** UNCHANGED FROM LIVE

---

## 2. HIDING BLIZZARD FRAMES

**Current best practice:**
Use Blizzard's **secure visibility drivers** (no taint, no combat issues). The addon "Hide Unit Frames" demonstrates the correct pattern: visibility updates via secure drivers work cleanly.

**Does NOT work anymore:**
- The old `UnregisterAllEvents` + `Hide()` pattern is obsolete and risks taint in Midnight.

**Edit Mode integration:**
- Edit Mode is fully compatible with hidden frames.
- Hidden frames fade slightly while in Edit Mode so you can still move/align them.
- Visibility reapplies correctly after reloads, zoning, Edit Mode toggle.

**Verified addons:**
- BetterBlizzFrames (confirmed Midnight-ready, hides/replaces PlayerFrame/TargetFrame/PartyFrame)
- Hide Unit Frames (lightweight, uses secure drivers, verified Midnight)

**Status:** BUILDABLE — use secure visibility drivers, not direct frame hiding

---

## 3. MIDNIGHT SECRET VALUES — THE CRITICAL GATE

**UnitHealth / UnitHealthMax / UnitHealthPercent behavior:**

These APIs **return SECRET VALUES** during:
- Active raid encounters
- M+ dungeon runs

Secret values are opaque Lua objects — addons **cannot**:
- Compare them with other values (causes Lua error)
- Perform arithmetic on them
- Use in conditional logic
- Display as numbers on UI

**What addons CAN do with secrets:**
- Store in variables/table fields
- Pass to Blizzard UI functions designed to accept them
- Use `C_CurveUtil` to map secrets to visual properties (e.g., health percentage → bar width) without exposing the raw value

**For non-combat content (world, dungeons without M+):**
`UnitHealth` returns normal integers and party member health is readable.

**Comparison with live:**
- Pre-Midnight: full read access to health/power in all content
- Midnight: secret values only during instanced combat

**Evidence:**
GitHub PR #457 in Cell addon (popular raid frame addon) documents Midnight compatibility: "WoW 12.0.0 (Midnight) Compatibility — Secret Values, CLEU Removal"; Cell had to refactor to work within this constraint.

**Workaround via Curves:**
Addon can request Blizzard to compute health bar width/color by passing the secret directly to `C_CurveUtil` functions, but addon never sees the numeric value.

**Status:** BUILDABLE-WITH-LIMITS — custom health bars cannot display live numeric health in raids/M+; must use Blizzard's curve system for bar rendering

---

## 4. AURAS ON OTHER UNITS (DISPEL HIGHLIGHTING)

**Reading party/raid auras in combat:**

Aura data fields (`dispelName`, `isHarmful`, etc.) are protected and return secret values.

**How dispel highlighting still works:**
- Use `C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, colorCurve)` — returns the dispel color directly without exposing the dispel type as readable data.
- Iterate auras by index using `C_UnitAuras.GetDebuffDataByIndex()`, access only `auraInstanceID` (the secret).
- Pass the secret to Blizzard's color-mapping function.

**Verified addon:**
- BigDebuffs — demonstrates this pattern for crowd-control and dispel highlighting in Midnight.
- ElvUI_DebuffHighlight — uses `C_CurveUtil.CreateColorCurve()` to map secrets to colors.

**Status:** BUILDABLE — dispel highlighting via C_UnitAuras API without exposing secret aura fields

---

## 5. NAMEPLATES

**C_NamePlate and NamePlateDriverFrame:**
- Customization still works in Midnight.
- Midnight included a major nameplate UI overhaul (cleaner, more modern aesthetic, template-based styling).
- Not exempt from API restrictions, but addons can still visually alter nameplates.

**Verified addons:**
- Platynator (first released Midnight-compatible nameplate addon)
- MidnightNameplates
- Nameplate customization is available via options menu (size, buffs, cast bars, style templates).

**Status:** BUILDABLE — nameplates customizable; constraint level moderate (must work within secret-values regime for unit data)

---

## 6. EDIT MODE INTEGRATION

**Current state:**
- Edit Mode is fully integrated with Blizzard's frame system.
- Custom frames **are not automatically registered** with Edit Mode; you must opt-in.
- Hidden frames show a faded preview during Edit Mode for positioning.

**Can custom frames be registered?**
- Edit Mode registration for third-party frames is possible but Midnight docs do not expose the standard pattern yet.
- Safest approach: hide Blizzard frames, position custom frames manually or via anchor-save addons (not Edit Mode).

**Status:** BUILDABLE-WITH-LIMITS — Edit Mode integration for custom frames not officially documented; manual positioning is reliable

---

## VERDICT TABLE

| Component | Status | Evidence |
|-----------|--------|----------|
| **Player Frame (replacement)** | BUILDABLE-WITH-LIMITS | Can replace visually; health display limited to secrets (bars via C_CurveUtil only) |
| **Target Frame (replacement)** | BUILDABLE-WITH-LIMITS | Same as player frame; health bars work, numeric values do not in raids/M+ |
| **Party Frames (custom)** | BUILDABLE-WITH-LIMITS | SecureGroupHeaderTemplate works; health secret in combat; BigDebuffs pattern for dispels confirmed |
| **Health Bars with Live Values** | BLOCKED-IN-COMBAT | UnitHealth returns secrets during raids/M+; numeric display impossible; bar width via curves only |
| **Dispel Highlighting** | BUILDABLE | C_UnitAuras.GetAuraDispelTypeColor() workaround verified; BigDebuffs addon proves feasibility |

---

## SINGLE BIGGEST BLOCKER

**UnitHealth/UnitHealthMax return SECRET VALUES during raids and M+ runs.**

This prevents custom party/raid frames from displaying accurate **numeric health values** on party members and targets in the content where raid frames matter most. You can:
- Render health bars (using Blizzard's curve system to map the secret to bar width)
- Display dispels (via dedicated `GetAuraDispelTypeColor` API)

You **cannot**:
- Show "1234 / 5678 HP" on a party frame during a raid
- Compare health values for triage logic
- Create dynamic healing rotation addons that read target HP

**Implication:** A **cosmetic-only UI replacement** (bars, colors, positions) is fully buildable. A **data-rich** raid UI (absorbs, threat, dispellable status) is constrained to out-of-combat content and weakly-typed patterns.

---

## Sources

- [Wowhead: Unit Frame Addons in Midnight - Massive Changes](https://www.wowhead.com/news/unit-frame-addons-in-midnight-massive-changes-project-reworked-for-midnight-379941)
- [Blizzard Forums: Development Clarification - Secret Value Obfuscation](https://us.forums.blizzard.com/en/wow/t/development-clarification-maintaining-ui-accuracy-vs-secret-value-obfuscation-in-midnight/2243547)
- [Warcraft Wiki: Patch 12.0.0 Planned API Changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes)
- [Warcraft Wiki: Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values)
- [GitHub: Cell Addon PR #457 - Midnight Compatibility](https://github.com/enderneko/Cell/pull/457)
- [CurseForge: Hide Unit Frames addon](https://www.curseforge.com/wow/addons/hide-unit-frames)
- [CurseForge: BetterBlizzFrames addon](https://www.curseforge.com/wow/addons/betterblizzframes)
- [CurseForge: BigDebuffs addon](https://www.curseforge.com/wow/addons/elvui-debuffhighlight)
- [Wowhead: Best Raid Tools for WoW Midnight 2026](https://wowcoach.gg/blog/best-raid-tools-wow-midnight-2026)
- [Xepheris: Nameplates in Midnight](https://gerritalex.de/blog/nameplates-in-midnight)
- [Wowhead: Nameplates in Midnight - What's Changing and What Add-Ons Can I Use](https://www.wowhead.com/news/nameplates-in-midnight-whats-changing-and-what-add-ons-can-i-use-379924)
