# Tuono — Module Contract (build coordination doc)

Single source of truth for cross-module interfaces. Every build lane follows this EXACTLY —
drift here breaks integration. Orchestrator-owned; lanes read, never edit.

## Global rules (every file)
- First line: `local ADDON_NAME, Tuono = ...` (WoW passes addon name + shared private table).
- Lua 5.1 compatible (WoW runtime), must also PARSE under Lua 5.4 (syntax gate). No `io`, `os`,
  `require`, `setfenv`, `goto`. ASCII only. No file may create globals except `TuonoDB`
  (Core only) and the two slash-command globals (Core only).
- Every WoW API call that could not exist goes through existence guards or `Tuono.safe`.
- Spell/item IDs live ONLY in `Tuono.SpellIDs` / rules data, each tagged `-- TODO(M0): verify in-game`.
- Comments sparse; only for non-obvious constraints.

## File layout + TOC load order (Lane A owns TOC)
```
Tuono/Tuono.toc
Tuono/Core.lua
Tuono/data/rules.lua
Tuono/StateTracker.lua
Tuono/AssistReader.lua
Tuono/IntelligenceLayer.lua
Tuono/Display.lua
Tuono/Config.lua
Tuono/ApiTest.lua
```

## Core.lua (Lane A)
Provides on Tuono:
- `Tuono.frame` — hidden event-dispatcher Frame.
- `Tuono.RegisterEvent(event, fn)` — multiple handlers per event; handlers get (event, ...).
- `Tuono.RegisterUpdate(fn, interval)` — throttled OnUpdate callback registry.
- `Tuono.db` — saved variables (global `TuonoDB`), created on ADDON_LOADED by deep-merging
  `Tuono.defaults` (defined by Config.lua; Core must tolerate it loading later — merge at
  PLAYER_LOGIN too).
- `Tuono.print(msg)` — chat print prefixed `|cff00ccffOutlawAssist|r: `.
- `Tuono.safe(fn, ...)` — pcall wrapper; on error returns nil, increments `Tuono.errorCount`, prints
  each unique error message once.
- `Tuono.RegisterSlash(subcmd, fn, helptext)` — router for `/tuono <subcmd>`; `/oa` alone lists help.
  Registers slash globals SLASH_OUTLAWASSIST1 = "/tuono", SLASH_OUTLAWASSIST2 = "/outlawassist".
- MAIN LOOP: Core registers ONE update at interval `Tuono.db.updateInterval or 0.1` that runs, in
  order and only if the module tables exist: `Tuono.State.RefreshFast()`, `Tuono.Assist.Update()`,
  `local r = Tuono.Engine.Evaluate()`, `Tuono.Display.Render(r)`. Wrapped in Tuono.safe.

## StateTracker.lua (Lane B)
- `Tuono.SpellIDs = { adrenalineRush = 13750, bladeRush = 271877, preparation = 14185, betweenTheEyes = 315341, rollTheBones = 315508, sinisterStrike = 193315, bladeFlurry = 13877 }`
  — every value `-- TODO(M0): verify in-game`.
- `Tuono.RTB_BUFF_NAMES` — list of Roll the Bones buff names from research (Broadside, True Bearing,
  Ruthless Precision, Buried Treasure, Grand Melee, Skull and Crossbones) PLUS the literal
  "Roll the Bones" (Midnight reworked RtB to progressive stages; we detect stage = stack count of
  the RtB aura if present, else count of matched classic buff names). `-- TODO(M0)` on the list.
- `Tuono.State` fields (read by Engine/Display every tick):
  - `energy, energyMax, comboPoints, comboPointsMax` (numbers, default 0)
  - `buffs = { rtb = {stage=0, expires=0, names={}}, opportunity={up=false, expires=0}, adrenalineRush={up=false, expires=0} }`
  - `cooldowns = { adrenalineRush={known,ready,remaining}, bladeRush=..., preparation=... }`
  - `trinkets = { [13]={itemID, ready, remaining, onUse}, [14]=... }`
  - `tier = {twoPc=false, fourPc=false}` (best effort, out of combat only)
  - `inCombat` (bool)
- `Tuono.State.RefreshFast()` — energy/CP via UnitPower/UnitPowerMax (Enum.PowerType.Energy=3,
  ComboPoints=4, guard Enum existence); spell CDs via `C_Spell.GetSpellCooldown` (guard: fall back
  to legacy `GetSpellCooldown` signature); trinket remaining via `C_Item.GetItemCooldown` (guard
  legacy `GetItemCooldown`).
- Buff scan on UNIT_AURA (unit=="player") AND on RefreshFast every ~0.5s as belt-and-braces:
  prefer `C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")` loop; fallback `UnitBuff`.
- Equipment: cache trinket itemIDs via `GetInventoryItemID("player", 13|14)` on
  PLAYER_ENTERING_WORLD + PLAYER_EQUIPMENT_CHANGED. `onUse` = item has a use effect — best effort
  via `C_Item.GetItemSpell or GetItemSpell` (guarded); if unknown, true when GetItemCooldown
  reports a nonzero duration ever seen.
- PLAYER_REGEN_DISABLED/ENABLED maintain `inCombat`.

## AssistReader.lua (Lane B)
- `Tuono.Assist = { available=false, nextSpellID=nil, queue={} }`
- `Tuono.Assist.Update()` — guards `C_AssistedCombat` exists AND (`.IsAvailable` missing or returns
  true). nextSpellID = `C_AssistedCombat.GetNextCastSpell(false)` (checkForVisibleButton=false);
  queue = `C_AssistedCombat.GetRotationSpells()` result normalized to a flat array of spellIDs
  (entries may be numbers or tables — handle both, keep unknown shapes out via type checks).
  Sets available=false (once-printed warning via Tuono.safe semantics) when API absent.

## IntelligenceLayer.lua (Lane C)
- `Tuono.Engine.Evaluate()` returns:
  `{ queue = { {spellID=n, source="blizzard"|<ruleName>}, ... max 5 }, advisories = { {kind="cooldown"|"trinket"|"rtb"|"proc", icon=<spellID|nil>, itemSlot=<13|14|nil>, text="...", active=bool}, ... } }`
- Base queue: Tuono.Assist.queue ordered with nextSpellID first (dedup). If assist unavailable,
  queue = {} and one advisory {kind="rtb", text="Blizzard rotation assist unavailable", active=true}.
- Rule pass over `Tuono.Rules` in array order, each rule's `when(S, A)` called via Tuono.safe with
  S=Tuono.State, A=Tuono.Assist:
  - PIN: first matching PIN inserts its spellID at position 1 (dedup afterwards), later PINs ignored.
  - PREFER: move its spellID (if present in queue) one slot toward front; if absent, insert at
    position 2.
  - ADVISE: append advisory {kind=rule.kind, icon=rule.spellID, itemSlot=rule.itemSlot,
    text=rule.desc, active=true}.
- Queue truncated to 5. Deterministic, allocation-light (reuse tables).

## data/rules.lua (Lane C)
- `Tuono.Rules` = array of `{ name, desc, action="PIN"|"PREFER"|"ADVISE", kind=..., spellID=..., itemSlot=..., when=function(S,A) ... end, source="<citation>" }`.
- 10–20 rules distilled ONLY from `docs/research/outlaw-rotation.md`, `docs/research/verification.md`
  (§D2 weaknesses), and PLAN.md §3 examples. Each rule cites its source doc+section. Must include:
  AR PIN at comboPoints<=2 & CD ready; BtE PIN at comboPoints>=6 (only if BtE in assist queue OR
  always per source); RtB stage-1 reroll ADVISE when AR CD remaining>20; trinket ADVISE (per slot)
  when adrenalineRush.up & trinket ready & onUse; Opportunity proc ADVISE while up; Blade Flurry
  PREFER when `Tuono.db.aoeMode` (manual AoE toggle — enemy counting is not legally readable, PLAN §9).
  NO invented mechanics: if a condition isn't supported by the research docs, leave it out.

## Display.lua (Lane D)
- `Tuono.Display.Init()` builds frames once at PLAYER_LOGIN; `Tuono.Display.Render(result)` cheap per tick.
- Anchor frame: movable when unlocked (`Tuono.db.display.locked`), drag saves point/x/y to
  `Tuono.db.display`; scale from `Tuono.db.display.scale` (default 1).
- Rows (each toggleable via Tuono.db.show.*): rotation (5 icons, pos-1 larger + highlight border and
  colored border when source ~= "blizzard"), cooldowns (AR/BladeRush/Prep icons + remaining text),
  trinkets (slots 13/14 icons via `GetInventoryItemTexture("player", slot)` guarded), rtbPanel
  (text: "RtB stage N  MM:SS"), advisory line (topmost active advisory text).
- Icons: `C_Spell.GetSpellTexture or GetSpellTexture` guarded; missing texture => 134400 (question mark).
- Cooldown numbers as text (no OmniCC dependency). Visibility: hidden OOC unless
  `Tuono.db.show.ooc`; always hidden when player class isn't ROGUE or spec isn't Outlaw
  (`GetSpecialization`==2 guarded — best effort, show anyway if API unsure).

## Config.lua (Lane D)
- `Tuono.defaults = { updateInterval=0.1, aoeMode=false, show={queue=true, cds=true, trinkets=true, rtb=true, procs=true, ooc=false}, display={locked=true, scale=1, point="CENTER", x=0, y=-180} }`
- Slash subcommands via Tuono.RegisterSlash: `lock`/`unlock`, `scale <0.5-2>`, `toggle <queue|cds|trinkets|rtb|procs|ooc>`, `aoe`, `reset` (wipe db to defaults + reposition), `status` (print current toggles).

## ApiTest.lua (Lane A)
- `/tuono apitest`: pcall-probe each dependency, print one PASS/FAIL line each with returned type:
  C_AssistedCombat (.IsAvailable, .GetNextCastSpell, .GetRotationSpells, .GetActionSpell),
  UnitPower energy+CP, C_UnitAuras.GetAuraDataByIndex, UnitBuff fallback, C_Spell.GetSpellCooldown
  (AR id), GetInventoryItemID 13/14, C_Item.GetItemCooldown (equipped trinket), GetSpecialization.
  Ends with summary "N/M PASS — paste this output into a GitHub issue if anything FAILs".
- `/tuono debug`: print a one-shot state dump (energy, CP, RtB stage, CD remainings, trinket state,
  assist nextSpellID + queue length).

## tests/ (Lane E, later)
- Pure-Lua harness run by `lua tests/run_tests.lua` (Lua 5.4 on the build box): `tests/wow_stub.lua`
  fakes the WoW API surface above; loader loads files in TOC order passing ("Tuono", Tuono)
  as varargs; asserts on Engine PIN/PREFER/ADVISE behavior + State cache updates from stubbed events.

## v0.3 Unified Queue Engine & Stealth/Opener

**Contract Addendum:** `Tuono.Engine.Evaluate()` returns:
```
{
  queue = {
    {
      spellID = <n>,
      source = "blizzard"|<ruleName>,
      kind = "rotation"|"cooldown"|"trinket"|"rtb"|"opener",
      itemSlot = <13|14|nil>
    },
    ...
  },
  advisories = <unchanged existing shape for context text line>
}
```

**Queue semantics:**
- **kind="rotation"** — Blizzard assist base queue spells
- **kind="cooldown"** — Ready major cooldowns (e.g., Adrenaline Rush per AR rule)
- **kind="trinket"** — Ready on-use trinkets during AR windows; itemSlot marks slot 13 or 14
- **kind="rtb"** — Roll the Bones cast/reroll recommendations (spellID = Tuono.SpellIDs.rollTheBones)
- **kind="opener"** — Pre-combat opener spells (e.g., Stealth when OOC+unstealthed)

**Queue ordering & dedup:**
1. Position 1: first PIN rule (by array order) if any conditions met
2. Positions 2+: PREFER/cooldown/trinket/rtb entries in rule priority order
3. Dedup by spellID (keep highest-priority, first occurrence wins)
4. Truncate to 8 entries maximum
5. Advisories table unchanged; kept for non-queue context text

**Stealth/Opener (Lua 5.1):**
- `Tuono.SpellIDs.stealth = 1784` — TODO(M0): verify in-game
- `Tuono.State.stealthed` (bool) — refreshed on UNIT_AURA + RefreshFast via Stealth aura scan (1784 or "Stealth" name fallback)
- **opener_stealth rule:** PIN kind="opener" spellID=stealth when `not S.inCombat and not S.stealthed`
- **Note:** Research doc (outlaw-rotation.md §5 RESEARCH LIMITATIONS) does not name a specific opener ability from Stealth state; opener_from_stealth rule SKIPPED

**Enemy Counting (AoE Signal):**
- `Tuono.State.enemyCount` — number of threat-engaged enemies (nil if detector unavailable)
  - Implemented via `C_NamePlate.GetNamePlates()` threat-level enumeration (Midnight 12.0.7+)
  - Detects hostile nameplates with threat > 0 on player; 2+ triggers AoE rules
  - Blade Flurry PREFER fires when enemyCount >= 2 OR aoeMode=true OR aoeDetected=true (composite signal)
  - Status (2026-08-01): Threat-table detection implemented; pending live-game verification via `/tuono apitest` probes
