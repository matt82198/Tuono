# Tests

Run from the repository root:

```bash
lua tests/run_tests.lua           # 180 behavioural tests; also runs the TOC and Lua 5.1 lints
lua tests/secrets_regression.lua  #  77 assertions against emulated secret values
lua tests/migration_test.lua      #   8 tests for the OutlawAssist -> Tuono import path
lua tests/toc_check.lua           #   TOC / CHANGELOG / file-manifest drift gate
lua tests/lua51_check.lua         #   Lua 5.1 syntax gate (the WoW runtime is 5.1)
```

`tests/wow_stub.lua` provides the client surface: events, spell/cooldown/aura APIs, a
controllable clock, nameplates, and an `issecretvalue` that reports whichever values the
scenario has marked secret.

## The rule

**A test that only passes proves nothing.** Every fix in this repo is confirmed to turn its
covering test red against the broken code before being called done. If you add a test, break
the thing it covers and watch it fail first.

This is not ceremony. Several tests in this suite were passing for the wrong reason and hid
real bugs for weeks:

- The aura stub encoded `GetPlayerAuraBySpellID("player", id)` — the wrong arity — so the
  suite certified a dead aura layer. Fixing the stub exposed two more call sites.
- Seven tests were passing only because a legacy `PIN` rule forced position 1 regardless of
  state. They were not testing the rotation at all, and they masked both cross-test state
  pollution and a profile rule that never fired.
- One test survived deleting *both* of the guards it existed to protect.

## Known harness limitation

Lua has no truthiness metamethod, so the stub cannot make `if secret then` raise the way the
live client does. Tests that cover secret-value *boolean* handling therefore verify the
guard is present and the surrounding behaviour is correct, but cannot reproduce the raise
itself. Where that matters it is noted at the test.
