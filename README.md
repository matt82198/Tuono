<p align="center">
  <img src="assets/logo.svg" width="140" alt="Tuono">
</p>

<h1 align="center">Tuono</h1>

<p align="center">
  <strong>A configurable rotation-helper framework for World of Warcraft: Midnight (12.0+)</strong><br>
  Legal by construction. Reads no hidden state. Never presses a button for you.
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#what-midnight-broke">What Midnight broke</a> ·
  <a href="#how-this-stays-legal">How this stays legal</a> ·
  <a href="docs/PROFILES.md">Write a profile</a>
</p>

---

## What this is

Midnight's **secret values** system hid the combat state that rotation addons were built
on. Hekili is unmaintained. The usual answer is "use Blizzard's Single-Button Assistant
or nothing" — and the assistant is a flat priority that ignores your buffs and costs
some specs 25–30% of their damage.

This is the third option: **a framework for building rotation helpers out of the data
that is still legally readable**, with your own priority logic layered on top.

- **A rolling wheel of your next four presses**, including repeats. If the honest answer
  is "builder four times", you see four icons — and if the fourth step depends on
  something Midnight hides, the wheel ends before it. The length of the strip is itself
  the confidence signal.
- **Two rotations, one bar.** Single-target and AoE lists switch automatically on live
  enemy count, with hysteresis so the bar cannot strobe.
- **An in-game rule editor.** Ordered priority rows, first match wins, no Lua required.
- **Profiles.** Outlaw Rogue ships as the worked example. Any spec can be added as data.
- **Honesty about uncertainty.** Values Midnight hides are shown as estimates, never as
  measurements.

> **Status:** the engine and its degradation behaviour are covered by an automated suite
> that emulates secret values — 174 behavioural tests plus 77 secret-value regressions,
> all passing. Validated against a live 12.1.0 client in open-world play, where position 1
> reads as optimal. **Not** yet validated inside a mythic keystone — see
> [Help wanted](#help-wanted).

---

## Quick start

1. Download the latest release and extract to `World of Warcraft\_retail_\Interface\AddOns\`
2. **Trap #1 — Windows Extract-All nests a folder.** You need
   `Interface\AddOns\Tuono\Tuono.toc`, *not*
   `Interface\AddOns\Tuono\Tuono\Tuono.toc`. Move the inner folder up if so.
3. **Trap #2 — it may show as "out of date."** Tick **Load out of date AddOns** in the
   Addons pane before entering the world.
4. In game: `/tuono config` to open the editor, `/tuono secrets` to audit what your client is

### Upgrading from OutlawAssist

Tuono is OutlawAssist renamed. WoW keys saved variables to the addon folder, so the
rename would otherwise look like a fresh install and lose your bar position, scale,
glow settings and any edited priority rows.

**Keep the old `OutlawAssist` folder in place for one login.** On first load Tuono reads
its saved variables, imports them, and tells you in chat what it carried. After that you
can delete the old folder. The import runs once and will never overwrite settings you
have already changed in Tuono.
   actually exposing.

---

## What Midnight broke

Blizzard did not hide *everything*, and the difference matters enormously. Measured
against the live client and Blizzard's generated API documentation:

| Value | Readable in combat / M+? |
|---|---|
| **Combo points** and other secondary resources | ✅ yes |
| **Cooldown readiness** (`isEnabled` / `isActive`) | ✅ yes — flagged never-secret |
| **Trinket cooldowns** | ✅ yes |
| **Enemy count** (nameplates + threat) | ✅ yes |
| `IsStealthed`, `GetTime` | ✅ yes |
| `C_AssistedCombat.GetNextCastSpell` | ✅ yes — plain spellID |
| **Energy** and other primary resources | ❌ **secret unconditionally** |
| Cooldown *remaining* (`startTime` / `duration`) | ❌ secret in combat, encounters, keystones, PvP |
| Aura payloads (`UNIT_AURA`, aura-by-index) | ❌ secret; the index path **raises** |
| Enemy health, buffs, casts | ❌ secret |

Run `/tuono secrets` in a city, on a dummy, and mid-pull in a keystone. Blizzard flips these
between builds — documentation is a hypothesis, that command is the measurement.

### Cooldown readiness survives

The single most useful thing here: `SpellCooldownInfo.isEnabled` and `.isActive` are
flagged never-secret even when the *timer* is hidden. You can know **whether** an ability
is ready in a keystone; you just cannot know for how much longer. Most rotation logic only
needs the boolean.

### Energy is shadowed, not read

Energy has no legal read path. So the addon stops trying and **models** it instead —
integrating forward from your own casts (`UNIT_SPELLCAST_SUCCEEDED` carries a readable
spellID), elapsed time and haste, resyncing whenever a real read lands.

It reports `measured` / `estimated` / `stale` and the UI dims accordingly. It touches no
secret and automates no input: it is a client-side model of your own actions, which is
what a human does in their head anyway.

---

## How this stays legal

- **Reads no hidden state.** Every API return passes a readability check before use. There
  is no declassification trick here; where a value is hidden, the addon says so.
- **No input automation.** It displays suggestions. You press the button. There is no
  code path that casts anything.
- **Fails toward honesty.** Unreadable never silently becomes zero. That distinction is
  the whole design: the predecessor bug in this very addon was `Tuono.num(UnitPower(...), 0)`
  turning "I cannot read your energy" into a confident "you have no energy", which
  emptied the rotation and froze the bar.

Blizzard's stated position is that rotation helpers are not inherently harmful; what is
disallowed is reading the hidden state. This does not.

---

## Commands

| Command | What it does |
|---|---|
| `/tuono config` | Open the rotation editor — profile selector, priority rows, AoE mode |
| `/tuono secrets` | Audit which values are readable right now, plus active restriction contexts |
| `/tuono aoe` | Cycle AoE handling: `auto` / `on` / `off` |
| `/tuono icons <1-8>` | How many upcoming presses to show |
| `/tuono unlock` / `/tuono lock` | Move the bar |
| `/tuono scale <0.5-2>` | Resize |
| `/tuono glow` | Toggle the action-bar highlight |
| `/tuono debug` | One-shot state dump |
| `/tuono apitest` | Probe API compatibility |

---

## Architecture

```
Core            event dispatch, secret-value primitives (readNum/readBool)
Profiles        registry; owns Tuono.SpellIDs
profiles/*      per-spec data: spells, costs, priority lists   <-- add yours here
UserRules       editable priority rows -> compiled predicates
StateTracker    readable state only, with knownness flags
EnergyModel     shadow energy from your own casts
AssistReader    C_AssistedCombat, secret-safe
Rotation        spec-agnostic forward simulation, AoE/ST selection
IntelligenceLayer  queue assembly, castability filtering
Display         the wheel      Highlight  action-bar glow
Options         in-game editor  Secrets   readability audit
```

**Adding a spec is a data change, not a code change.** See
**[docs/PROFILES.md](docs/PROFILES.md)** — it covers the rule schema, the helper API, and
the one genuinely subtle part: choosing which way each rule should fail when a value is
unreadable.

---

## Help wanted

This is the part where the project needs other people, honestly:

- **Live-client validation.** Run `/tuono secrets` in a keystone and open an issue with the
  output. The readability table above is built from Blizzard's generated docs plus a
  simulated harness; real measurements from real content beat both.
- **Profiles for other specs.** Outlaw is the example, not the point. If you main
  something else and can write its priority list, that is the highest-value contribution.
**[What Midnight's secret values actually do](docs/SECRET-VALUES-FINDINGS.md)** — the practical
shape of the new constraints, what survives, what does not, and the four techniques
that make a helper still possible. Written to be useful whether or not you use this addon.

- **Anyone who has read the secret-values rules closely.** If something here is legally
  wrong, say so loudly and I will fix it.

Issues and PRs: <https://github.com/matt82198/Tuono/issues>

---

## Development

```bash
lua tests/run_tests.lua           # 174 behavioural tests (also runs the two lints)
lua tests/secrets_regression.lua  #  77 assertions against emulated secret values
lua tests/migration_test.lua      #   8 tests for the OutlawAssist import path
lua tests/toc_check.lua           #   TOC / CHANGELOG / file-manifest drift gate
lua tests/lua51_check.lua         #   Lua 5.1 syntax gate (the WoW runtime)
```

The suite is **mutation-checked**: every fix above was confirmed to go red against the
broken code before being called done. A test that only passes proves nothing — if you add
one, break the thing it covers and confirm it fails first.

---

## License

MIT. Take it, fork it, ship your own.
