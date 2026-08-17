# Tuono — Project CLAUDE.md

**What**: A rotation-helper addon for World of Warcraft (Midnight 12.x). It runs its own
forward-simulating APL engine and renders the next N presses. Outlaw Rogue is the
reference profile; the engine itself is spec-agnostic. MIT, Lua 5.1.

**The thesis, in one line**: don't read state — **model it**, and correct the model against
never-secret observations. Certainty is a first-class output, not a hidden assumption.

**Read `docs/INVERSION.md` before changing anything in the engine or the sensing layer.**
It is the design doctrine and it is load-bearing. The short version: secrecy is not a
problem to be defended against, it is a property of a channel we deliberately do not use.
`EnergyModel` contains no branch anywhere asking whether energy is hidden — it models
energy and tightens on observation. A design that has to be *told* what is secret is not
inverted. When a value blinks, the fix is to invert it, not to guard every reader of it.

## Key commands

| Task | Command |
|---|---|
| Deploy to the live client | `pwsh tools/deploy.ps1` |
| Run offline tests | `lua tests/run_tests.lua` |
| In-game API probe | `/tuono apitest` (must be logged in) |
| In-game diagnostics | `/tuono debug`, `/tuono record` |

## Gotchas (verified, they change how you work)

- **The deployed copy is not this repo.** The game loads
  `<WoW>/_retail_/Interface/AddOns/Tuono`. Editing here changes nothing until you deploy.
- **Every `.lua` must be listed in `Tuono.toc`, in load order.** A file not listed loads
  silently as nothing; a file listed in the wrong order captures `nil` upvalues.
  `profiles/` and `data/` load *before* `Rotation.lua`, which is why profiles resolve
  `Tuono.RuleHelpers` lazily inside closures instead of capturing it at the top.
- **Never test a secret value directly.** Arithmetic, comparison, `if`, `#`, and table-key
  use all *throw* on a secret. Read through `Tuono.readNum` / `Tuono.readBool`, which
  return `(value, known)`. `Tuono.num`/`Tuono.bool` collapse unknown to a default and are
  fail-*silent* — only use them where "zero" and "unreadable" genuinely mean the same thing.
- **Unknown is never "no".** Treating an unreadable value as a negative is the single
  defect class this codebase has shipped most often (it emptied the bar, suppressed the
  rotation, and told players to reroll a Jackpot). Fail open, lower confidence, say so.
  But note the ordering: this is the *fallback*. A modelled value is rarely unknown in the
  first place, so inverting the quantity beats guarding every reader of it. See
  `docs/INVERSION.md` §6.4.
- **Never write to a Blizzard secure frame.** Anchoring our own frame *to* a button reads
  it and is safe; `CreateTexture` on an `ActionButton` taints it and produces "Interface
  action failed because of an AddOn".
- **Lua 5.1 only.** No goto, no integer division, no `table.unpack`.

## Domain map

The addon is flat by necessity (`.toc` load order), so domains are file groups, not
directories. Read exactly one.

- **Engine** — `Rotation.lua`, `IntelligenceLayer.lua`, `CooldownModel.lua`.
  Forward simulation, confidence rating, queue assembly. See `docs/ENGINE.md`.
- **Sensing** — `StateTracker.lua`, `EnergyModel.lua`, `Observers.lua`, `AssistReader.lua`,
  `Secrets.lua`. Everything that turns the client into state. See `docs/SENSING.md`.
- **UI** — `Display.lua`, `Highlight.lua`, `Options.lua`, `Config.lua`. See `docs/UI.md`.
- **Profiles** — `Profiles.lua`, `UserRules.lua`, `profiles/*.lua`, `data/rules.lua`.
  The APL itself. Read `profiles/CLAUDE.md`.
- **Tests** — `tests/`. Offline WoW stub + engine replay. Read `tests/CLAUDE.md`.
- **Core** — `Core.lua`, `Migration.lua`, `Recorder.lua`. Event dispatch, tick loop,
  saved-variable migration, flight recorder.

## Dispatch rule

Workers read exactly ONE domain doc; this file is navigation only.

## See also

- `STATE.md` — intent, locked decisions, open defects, next steps. Source of truth.
- `docs/LEGALITY.md` — what is readable, what is not, and where the ToS line sits.
