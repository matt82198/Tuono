# OutlawAssist — Module Contract (build coordination doc)

Single source of truth for cross-module interfaces. Every build lane follows this EXACTLY —
drift here breaks integration. Orchestrator-owned; lanes read, never edit.

## Global rules (every file)
- First line: `local ADDON_NAME, OA = ...` (WoW passes addon name + shared private table).
- Lua 5.1 compatible (WoW runtime), must also PARSE under Lua 5.4 (syntax gate). No `io`, `os`,
  `require`, `setfenv`, `goto`. ASCII only. No file may create globals except `OutlawAssistDB`
  (Core only) and the two slash-command globals (Core only).
- Every WoW API call that could not exist goes through existence guards or `OA.safe`.
- Spell/item IDs live ONLY in `OA.SpellIDs` / rules data, each tagged `-- TODO(M0): verify in-game`.
- Comments sparse; only for non-obvious constraints.

## File layout + TOC load order (Lane A owns TOC)
```
OutlawAssist/OutlawAssist.toc
OutlawAssist/Core.lua
OutlawAssist/data/rules.lua
OutlawAssist/StateTracker.lua
OutlawAssist/AssistReader.lua
OutlawAssist/IntelligenceLayer.lua
OutlawAssist/Display.lua
OutlawAssist/Config.lua
OutlawAssist/ApiTest.lua
```

## Core.lua (Lane A)
Provides on OA:
- `OA.frame` — hidden event-dispatcher Frame.
- `OA.RegisterEvent(event, fn)` — multiple handlers per event; handlers get (event, ...).
- `OA.RegisterUpdate(fn, interval)` — throttled OnUpdate callback registry.
- `OA.db` — saved variables (global `OutlawAssistDB`), created on ADDON_LOADED by deep-merging
  `OA.defaults` (defined by Config.lua; Core must tolerate it loading later — merge at
  PLAYER_LOGIN too).
- `OA.print(msg)` — chat print prefixed `|cff00ccffOutlawAssist|r: `.
- `OA.safe(fn, ...)` — pcall wrapper; on error returns nil, increments `OA.errorCount`, prints
  each unique error message once.
- `OA.RegisterSlash(subcmd, fn, helptext)` — router for `/oa <subcmd>`; `/oa` alone lists help.
  Registers slash globals SLASH_OUTLAWASSIST1 = "/oa", SLASH_OUTLAWASSIST2 = "/outlawassist".
- MAIN LOOP: Core registers ONE update at interval `OA.db.updateInterval or 0.1` that runs, in
  order and only if the module tables exist: `OA.State.RefreshFast()`, `OA.Assist.Update()`,
  `local r = OA.Engine.Evaluate()`, `OA.Display.Render(r)`. Wrapped in OA.safe.

## StateTracker.lua (Lane B)
- `OA.SpellIDs = { adrenalineRush = 13750, bladeRush = 271877, preparation = 14185, betweenTheEyes = 315341, rollTheBones = 315508, sinisterStrike = 193315, bladeFlurry = 13877 }`
  — every value `-- TODO(M0): verify in-game`.
- `OA.RTB_BUFF_NAMES` — list of Roll the Bones buff names from research (Broadside, True Bearing,
  Ruthless Precision, Buried Treasure, Grand Melee, Skull and Crossbones) PLUS the literal
  "Roll the Bones" (Midnight reworked RtB to progressive stages; we detect stage = stack count of
  the RtB aura if present, else count of matched classic buff names). `-- TODO(M0)` on the list.
- `OA.State` fields (read by Engine/Display every tick):
  - `energy, energyMax, comboPoints, comboPointsMax` (numbers, default 0)
  - `buffs = { rtb = {stage=0, expires=0, names={}}, opportunity={up=false, expires=0}, adrenalineRush={up=false, expires=0} }`
  - `cooldowns = { adrenalineRush={known,ready,remaining}, bladeRush=..., preparation=... }`
  - `trinkets = { [13]={itemID, ready, remaining, onUse}, [14]=... }`
  - `tier = {twoPc=false, fourPc=false}` (best effort, out of combat only)
  - `inCombat` (bool)
- `OA.State.RefreshFast()` — energy/CP via UnitPower/UnitPowerMax (Enum.PowerType.Energy=3,
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
- `OA.Assist = { available=false, nextSpellID=nil, queue={} }`
- `OA.Assist.Update()` — guards `C_AssistedCombat` exists AND (`.IsAvailable` missing or returns
  true). nextSpellID = `C_AssistedCombat.GetNextCastSpell(false)` (checkForVisibleButton=false);
  queue = `C_AssistedCombat.GetRotationSpells()` result normalized to a flat array of spellIDs
  (entries may be numbers or tables — handle both, keep unknown shapes out via type checks).
  Sets available=false (once-printed warning via OA.safe semantics) when API absent.

## IntelligenceLayer.lua (Lane C)
- `OA.Engine.Evaluate()` returns:
  `{ queue = { {spellID=n, source="blizzard"|<ruleName>}, ... max 5 }, advisories = { {kind="cooldown"|"trinket"|"rtb"|"proc", icon=<spellID|nil>, itemSlot=<13|14|nil>, text="...", active=bool}, ... } }`
- Base queue: OA.Assist.queue ordered with nextSpellID first (dedup). If assist unavailable,
  queue = {} and one advisory {kind="rtb", text="Blizzard rotation assist unavailable", active=true}.
- Rule pass over `OA.Rules` in array order, each rule's `when(S, A)` called via OA.safe with
  S=OA.State, A=OA.Assist:
  - PIN: first matching PIN inserts its spellID at position 1 (dedup afterwards), later PINs ignored.
  - PREFER: move its spellID (if present in queue) one slot toward front; if absent, insert at
    position 2.
  - ADVISE: append advisory {kind=rule.kind, icon=rule.spellID, itemSlot=rule.itemSlot,
    text=rule.desc, active=true}.
- Queue truncated to 5. Deterministic, allocation-light (reuse tables).

## data/rules.lua (Lane C)
- `OA.Rules` = array of `{ name, desc, action="PIN"|"PREFER"|"ADVISE", kind=..., spellID=..., itemSlot=..., when=function(S,A) ... end, source="<citation>" }`.
- 10–20 rules distilled ONLY from `docs/research/outlaw-rotation.md`, `docs/research/verification.md`
  (§D2 weaknesses), and PLAN.md §3 examples. Each rule cites its source doc+section. Must include:
  AR PIN at comboPoints<=2 & CD ready; BtE PIN at comboPoints>=6 (only if BtE in assist queue OR
  always per source); RtB stage-1 reroll ADVISE when AR CD remaining>20; trinket ADVISE (per slot)
  when adrenalineRush.up & trinket ready & onUse; Opportunity proc ADVISE while up; Blade Flurry
  PREFER when `OA.db.aoeMode` (manual AoE toggle — enemy counting is not legally readable, PLAN §9).
  NO invented mechanics: if a condition isn't supported by the research docs, leave it out.

## Display.lua (Lane D)
- `OA.Display.Init()` builds frames once at PLAYER_LOGIN; `OA.Display.Render(result)` cheap per tick.
- Anchor frame: movable when unlocked (`OA.db.display.locked`), drag saves point/x/y to
  `OA.db.display`; scale from `OA.db.display.scale` (default 1).
- Rows (each toggleable via OA.db.show.*): rotation (5 icons, pos-1 larger + highlight border and
  colored border when source ~= "blizzard"), cooldowns (AR/BladeRush/Prep icons + remaining text),
  trinkets (slots 13/14 icons via `GetInventoryItemTexture("player", slot)` guarded), rtbPanel
  (text: "RtB stage N  MM:SS"), advisory line (topmost active advisory text).
- Icons: `C_Spell.GetSpellTexture or GetSpellTexture` guarded; missing texture => 134400 (question mark).
- Cooldown numbers as text (no OmniCC dependency). Visibility: hidden OOC unless
  `OA.db.show.ooc`; always hidden when player class isn't ROGUE or spec isn't Outlaw
  (`GetSpecialization`==2 guarded — best effort, show anyway if API unsure).

## Config.lua (Lane D)
- `OA.defaults = { updateInterval=0.1, aoeMode=false, show={queue=true, cds=true, trinkets=true, rtb=true, procs=true, ooc=false}, display={locked=true, scale=1, point="CENTER", x=0, y=-180} }`
- Slash subcommands via OA.RegisterSlash: `lock`/`unlock`, `scale <0.5-2>`, `toggle <queue|cds|trinkets|rtb|procs|ooc>`, `aoe`, `reset` (wipe db to defaults + reposition), `status` (print current toggles).

## ApiTest.lua (Lane A)
- `/oa apitest`: pcall-probe each dependency, print one PASS/FAIL line each with returned type:
  C_AssistedCombat (.IsAvailable, .GetNextCastSpell, .GetRotationSpells, .GetActionSpell),
  UnitPower energy+CP, C_UnitAuras.GetAuraDataByIndex, UnitBuff fallback, C_Spell.GetSpellCooldown
  (AR id), GetInventoryItemID 13/14, C_Item.GetItemCooldown (equipped trinket), GetSpecialization.
  Ends with summary "N/M PASS — paste this output into a GitHub issue if anything FAILs".
- `/oa debug`: print a one-shot state dump (energy, CP, RtB stage, CD remainings, trinket state,
  assist nextSpellID + queue length).

## tests/ (Lane E, later)
- Pure-Lua harness run by `lua tests/run_tests.lua` (Lua 5.4 on the build box): `tests/wow_stub.lua`
  fakes the WoW API surface above; loader loads files in TOC order passing ("OutlawAssist", OA)
  as varargs; asserts on Engine PIN/PREFER/ADVISE behavior + State cache updates from stubbed events.
