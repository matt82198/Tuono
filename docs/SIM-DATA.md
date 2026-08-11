# Simulation Data Refresh Procedure

**Version:** 1.0  
**Purpose:** Maintain rule accuracy by regularly syncing APL actions from SimulationCraft Midnight profiles  
**Scope:** Outlaw Rogue combat rotation rules only

---

## Overview

The `Tuono/data/rules.lua` file contains the decision logic that powers rotation recommendations. These rules are distilled from SimulationCraft APL (Action Priority List) profiles, which encode the optimal rotation strategy for each patch.

This document describes how to refresh the rules when patches update SimulationCraft profiles.

---

## Refresh Procedure

### Step 1: Run the Diff Tool

The `tools/refresh_sim_data.py` script fetches the latest Outlaw Rogue APL from SimulationCraft and generates a diff report:

```bash
python tools/refresh_sim_data.py --out sim-data-report.md
```

**Flags:**
- `--out <file>` — Write report to markdown file (default: stdout only)
- `--branch <name>` — SimulationCraft branch to fetch (default: `midnight`; falls back to `master` on 404)
- `--timeout <sec>` — Network timeout (default: 10s)
- `--selftest` — Validate parser with embedded sample (exit 0 on success)

**Exit codes:**
- `0` — Report generated successfully
- `2` — Network unavailable (fatal; check GitHub access)
- `1` — Other errors (check stderr)

**Output:** Markdown report with three sections:
1. **APL Actions Without Rules** — Actions in SimC profile but not yet defined in `rules.lua`
2. **Rules Without APL Actions** — Rules in `rules.lua` that cite actions no longer in current APL
3. **Summary** — Coverage metrics

### Step 2: Review the Report

Example output:

```markdown
# Sim-Data Diff Report

## APL Actions Without Rules
**Count:** 2

- `new_cooldown_ability` (if=cooldown.ready)
- `hero_talent_finisher` (if=combo_points>=6)

## Rules Without APL Actions
**Count:** 0

✓ All rules cite APL actions.

## Summary
- APL actions: 15
- Defined rules: 13
- Coverage: 13/15
```

**Interpretation:**
- Missing rules (section 1) = new mechanics you may want to add
- Orphaned rules (section 2) = rules for removed or renamed actions; consider deprecating them
- Coverage % = how well your rules match the current APL

### Step 3: Hand-Update `Tuono/data/rules.lua`

**DO NOT auto-edit** — all changes must be human-reviewed and cited.

For each **new action** from the report:
1. Read the condition (`if=...`) from the SimC profile
2. Create a new rule entry in `rules.lua` following the existing format:

```lua
  {
    name = "new_action_name",
    desc = "Short description of the action",
    action = "PIN|ADVISE|PREFER",  -- PIN for high-priority, ADVISE for conditional, PREFER for soft hints
    kind = "cooldown|finisher|proc|aoe|builder|trinket|rtb",
    spellID = <number> or nil,
    itemSlot = <number> or nil,
    when = function(S, A)
      return S.<state_condition>  -- Map SimC condition to Lua
    end,
    source = "outlaw-rotation.md (section); SimC APL line reference"
  },
```

**Key mapping (SimC → Lua):**
- `combo_points<=2` → `S.comboPoints <= 2`
- `buff.ar.up` → `S.buffs.adrenalineRush.up`
- `cooldown.ready` → `S.cooldowns.bladeRush.ready`
- `target.health.pct<20` → NOT READABLE (secret values system blocks enemy unit state)

**For orphaned rules:** Mark as deprecated or remove if the action no longer exists:

```lua
  -- [DEPRECATED: v1.0.2] Removed in Midnight patch 12.1 (action renamed)
  -- {
  --   name = "old_action_name",
  --   ...
  -- },
```

### Step 4: Update Version Comment

At the top of `Tuono/data/rules.lua`, update the rules version and refresh date:

```lua
-- Rules version: 1.0.2
-- Last refresh: 2026-08-01
-- SimC Midnight branch (commit TBD)
```

### Step 5: Verify Coverage

Run a quick check to ensure no typos introduced:

```bash
python tools/refresh_sim_data.py --out sim-data-report-final.md
```

Confirm the **Coverage %** remained the same or improved. If it dropped, review your edits.

### Step 6: Test in-Game (Optional)

1. Load the addon in WoW
2. Enter a training dummy scenario
3. Verify that new rules fire at expected times (e.g., "Adrenaline Rush when CP <= 2")
4. No automated testing possible (rules are Lua functions that require combat state)

---

## Cadence

Per PLAN.md §5, follow this schedule:

| Trigger | Action | Effort |
|---------|--------|--------|
| **Weekly** | Check WarcraftLogs top-10 parses for meta shifts (optional, informational) | ~10 min |
| **Patch Day** | Clone SimC, run refresh_sim_data.py, hand-update rules.lua, commit | ~2 hours |
| **Quarterly** | Full audit of all rules against latest guides (Method, Icy Veins, Murlok.io) | ~4 hours |

---

## Troubleshooting

### "Network unavailable" (exit 2)

Check GitHub access:
```bash
curl -I https://raw.githubusercontent.com/simulationcraft/simc/midnight/profiles/MID1/MID1_Rogue_Outlaw.simc
```

If blocked, try switching branches manually (`--branch master`) or check your firewall/proxy.

### Profile not found

The script tries multiple paths and branches. If all fail:
1. Verify SimulationCraft repo is up-to-date: https://github.com/simulationcraft/simc
2. Check if profile directory structure changed (common in major patches)
3. Manually clone and locate the profile:
   ```bash
   git clone --branch midnight https://github.com/simulationcraft/simc.git
   find simc -name "*Rogue_Outlaw*.simc" -type f
   ```

### Parser errors

The embedded `--selftest` validates the APL parser:
```bash
python tools/refresh_sim_data.py --selftest
```

Exit 0 = parser works. If it fails, the APL format may have changed; update the regex in `parse_apl_actions()`.

---

## Implementation Notes

- **No runtime web fetch** — All data is checked in as Lua files; the addon never calls external APIs at runtime
- **Human-in-the-loop** — The script REPORTS mismatches; humans DECIDE which rules to add/remove
- **Incremental:** You don't need to rewrite the entire `rules.lua` per patch; just address the diff
- **Source citations mandatory** — Every rule must link to its origin (SimC line, guide section, theorycraft reasoning)

---

## References

- **SimulationCraft Midnight profiles:** https://github.com/simulationcraft/simc/tree/midnight/profiles/MID1
- **Research basis:** `docs/research/outlaw-rotation.md` (WoW Midnight rotation priority)
- **Addon architecture:** `PLAN.md §3` (IntelligenceLayer rule engine)
- **Refresh tool:** `tools/refresh_sim_data.py`
