# Tuono Test Suite

## How to Run

```bash
cd C:\Users\matt8\outlaw-assist-wt-build
C:\Users\matt8\AppData\Local\Programs\Lua\bin\lua.exe tests/run_tests.lua
```

Runs 12 behavioral tests via a pure-Lua harness without requiring WoW or the game client. Exit code 0 = all pass, 1 = failures.

## What is Stubbed

- **WoW Frame API** (`CreateFrame`, `SetScript`, `RegisterEvent`, `SetPoint`, etc.) — mock frames that record method calls and fire registered event/update handlers
- **WoW Globals** (`GetTime`, `UnitPower`, `C_Spell.GetSpellCooldown`, `C_UnitAuras.GetAuraDataByIndex`, `UnitBuff`, `GetInventoryItemID`, `C_Item.GetItemCooldown`, `C_Spell.GetSpellTexture`, `C_AssistedCombat`, `Enum.PowerType`, `SlashCmdList`)
- **Stub State** (`stub.state`) — controllable energy, combo points, buffs, cooldowns, trinkets; `stub.FireEvent(event, ...)` and `stub.Tick(dt)` to drive addon behavior

## What is NOT Covered

- Real WoW client behavior (lag, event ordering, frame rendering, texture loading)
- Player class/spec detection beyond mocking
- Complex buff stacking or aura filtering beyond basic cases
- Network behavior or addon communication
- Display frame positioning or visual layout (only functional render calls tested)
- In-game equipment detection beyond trinket slot lookup

## Notes

Two module bugs were fixed to enable tests:
1. `StateTracker.lua:47` — initialized `lastBuffScan = -1` to ensure buffs refresh on first RefreshFast() call
2. `Display.lua:213` — fixed trinket lookup from `Tuono.State.trinkets[tostring(slot)]` to `Tuono.State.trinkets[slot]` (numeric keys)
