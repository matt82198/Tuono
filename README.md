# Tuono

A rotation-assistance engine for World of Warcraft: Midnight (12.x).

*Tuono* is thunder in Italian. [Hekili](https://github.com/Hekili/hekili) is thunder in
Hawaiian. The name is a debt, not a coincidence.

---

## What this is, and what it is not

**Tuono is not an install-and-play rotation helper.** It is the architecture that makes a
rotation assistant possible again, and right now it has a steep configuration curve.

That distinction is the whole project. Midnight's secret-values system removed the state
that every third-party rotation addon was built on, and Hekili — the one most people
used — ended with the Midnight prepatch. What replaced it are presentation layers over
Blizzard's own Assisted Combat: they read Blizzard's recommendation and draw it. None of
them model your resources, and none of them can tell you anything Blizzard's engine has
not already decided.

Tuono models the state instead of reading it. That is the part that took the work, and it
is what the repository is for. A polished, one-click experience is downstream of it and is
not finished.

If you want something that works the moment you install it, use one of the Assisted
Combat wrappers. If you want an engine that can be pointed at a spec, argued with, and
extended, that is this.

## Current state, honestly

- **One spec is implemented**: Outlaw Rogue. The engine is spec-agnostic by design, but
  adding a second spec today means touching engine files, not just writing a profile.
  See `docs/FRAMEWORK.md` for exactly which seams are missing.
- **Configuration is slash commands and SavedVariables.** There is an options panel, but
  several settings — including the text-size control that matters most for
  accessibility — are reachable only by command.
- **The rotation is hand-distilled** from Midnight-era sources and pinned by tests, but it
  is one person's reading of the guides, not a sim.
- **It is under active development and will change under you.**

## What is actually good here

The engine never reads hidden state. It **models** it and corrects the model against
signals the client will always answer:

- **Energy** is bracketed from both sides by `C_Spell.IsSpellUsable`, collapsed to an exact
  value whenever it crosses an ability's cost, and the regeneration rate is *solved* from
  two crossings. Measured live: median interval width **0.1 energy**.
- **Cooldowns** are reconstructed from the cast we observed plus static durations, and
  corrected every tick against the one boolean Blizzard still answers.
- **Procs** come from the spell-activation overlay, which is never secret and fires on
  both edges.
- **Certainty is a first-class output.** Every recommendation is rated by what it actually
  depended on, and the display says so rather than presenting an estimate as a fact.

The design doctrine is `docs/INVERSION.md`. Read it before changing the engine.

## Documentation

| File | What it is |
|---|---|
| `docs/INVERSION.md` | The design thesis. Do not read state; model it. |
| `docs/HEKILI.md` | What Hekili did, what to take, and what to refuse. |
| `docs/ACCESSIBILITY.md` | Who this is for and what it owes them. |
| `docs/LEGALITY.md` | What is readable, and where the ToS line sits. |
| `docs/FRAMEWORK.md` | What must change to support a second spec. |
| `docs/ARCHITECTURE-REVIEW.md` | An adversarial review of the engine. |
| `STATE.md` | Current state, open defects, next steps. |

## Development

```sh
lua tests/run_tests.lua        # 233 tests, no game required
pwsh tools/deploy.ps1          # copy into Interface/AddOns
```

The test suite runs the real addon against a WoW API stub, including secret values that
throw the way the live client does. There are also fail-closed lints for Lua 5.1
compatibility, unguarded secret reads, runtime code generation, and taint.

In game, `/tuono record` writes a flight trace to SavedVariables;
`python3 tools/trace_analyze.py <path>` turns it into numbers. Most of the defects fixed
so far were found that way rather than by reasoning.

## Legality

Tuono reads no protected value and automates no input. It displays a suggestion; the
player presses the button. See `docs/LEGALITY.md`, which also states plainly where the
argument is settled and where it is not.

## Licence

MIT. See `LICENSE`.

Hekili is a design reference only — it carries no licence file, so its ideas are
reimplemented here and none of its code is copied.
