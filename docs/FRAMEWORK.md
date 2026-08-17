# Tuono as a distributable framework

**Date:** 2026-08-17
**Against:** v2.2.1, commit `be2569d`
**Status:** architecture critique + roadmap. Nothing here is implemented.

Every claim about the current code cites a file and line. Claims about the WoW ecosystem
that could not be confirmed against a primary source are marked UNVERIFIED. This project
inherited a planning document that asserted a spell ID which 404'd and a cooldown that was
wrong by a factor of eight; the cost of that is why this one is written the way it is.

---

## 0. The one-line summary

Tuono has a genuinely novel engine and a single-spec body wrapped around it. The engine is
worth generalising. The body is not spec-agnostic, and the claim that it is — `Profiles.lua:6-9`,
"The engine (Rotation.lua) knows none of it" — is false in at least four modules.

The good news is that the leaks are concentrated and nameable rather than diffuse.

---

## 1. Profile/spec API

### 1.1 What the profile contract claims

`Profiles.lua:41-47` documents the contract as `spells`, `abilities`, `priority`,
`resources`. `profiles/OutlawRogue.lua` supplies nine further undocumented fields:
`priorityAoE`, `meleeRangeSpell`, `overlayAuras`, `rtbStageBuffs`, `rtbDuration`,
`rtbExtendCap`, `auraProbeList`, `spellAliases`, `trackedAuras`.

Three of those are Outlaw nouns in what is meant to be a generic contract
(`rtbStageBuffs`, `rtbDuration`, `rtbExtendCap`). Two are dead:

- **`profile.resources` is never read.** Declared at `profiles/OutlawRogue.lua:433-436`,
  and `grep -n '\.resources|resources\.'` across every `.lua` in the repo returns nothing.
  The field that exists specifically to make the resource model pluggable is inert.
- **`profile.rtbExtendCap` is never read.** Declared at `profiles/OutlawRogue.lua:476`,
  no consumer.

And one is half-honoured: **`profile.trackedAuras`** (`profiles/OutlawRogue.lua:497`) is
read only by `Observers.lua:116`, for the aura-secrecy probe. `StateTracker.lua:246-251`
ignores it and hardcodes its own list — including a bare literal `195627` at line 249,
the Opportunity spell ID, in the module whose header comment (`StateTracker.lua:3-7`)
says "The tracker is spec-agnostic and follows whatever keys the profile declares".

That header comment is the single most misleading line in the codebase. A contributor
reads it and believes the seam exists.

### 1.2 Where Outlaw leaked into the engine

**`Rotation.lua`** — the file that most explicitly claims spec-agnosticism (`Rotation.lua:5-8`):

| Line | Leak |
|---|---|
| `329-333` | `applyCDR(cpSpent, rtbStage)` hardcodes Restless Blades: 1.0s per combo point, 1.3s at Roll the Bones stage 3+. This is one talent of one spec, in the simulator's core. |
| `335-337` | `calcGCD(hasteBuffUp)` returns a flat `0.8` or `1.0`. Not haste-derived, not profile-supplied, and wrong for any spec with a 1.5s GCD. Note `CooldownModel.lua:74-82` computes the GCD *properly* from cached haste — two GCD models that disagree. |
| `355-358` | `calcEnergyRegen` hardcodes base 10/sec, a 1.6x haste-buff multiplier, and `+2.5` for Combat Potency. Energy, Adrenaline Rush and an Outlaw talent, in the generic simulator. |
| `456` | `inputConfidence` has an `rtbStage` branch — an Outlaw condition type in the generic confidence rater. |
| `638-642` | `maxEnergy = 100`, or `150` when `S.buffs.adrenalineRush.up`. Both the resource and the buff are named literally. |
| `755` | Reads `S.buffs.rtb.stage` to compute CDR. |
| `773-789` | Effect application keys off *profile spell keys by name*: `spells.pistolShot` consumes `S.buffs.opportunity`, `spells.ambush` breaks stealth, `spells.stealth` applies it. A Fury Warrior profile would have to name an ability `pistolShot` to get proc-consumption modelling. |
| `295-325` | `deepCopyState` copies a **fixed** buff set: `rtb`, `opportunity`, `adrenalineRush`. A new spec's buffs never reach the simulation at all. |

Plus the combo-point family — `cpCap`, `finisherThreshold`, `cpAtLeast`, `cpAtMost`,
`cpBelowCap`, and now `rtbStage`/`rtbStageBelow`/`rtbStageAtLeast` — all published on
`Tuono.RuleHelpers` as though they were generic vocabulary.

**`StateTracker.lua`** is the worst offender and the real blocker:

- `9-17` — `Tuono.RTB_BUFF_NAMES`, seven Outlaw buff names, each still carrying a
  `TODO(M0): verify names` marker from the ancestor project.
- `19-63` — `Tuono.State` is a **fixed schema**: literal `energy`, `comboPoints`,
  `buffs.rtb`, `buffs.opportunity`, `buffs.adrenalineRush`, and `cooldowns` pre-seeded
  with nine hardcoded Outlaw keys.
- `264-277`, `365-376`, `397-436` — three separate `if/elseif` chains dispatching on
  Outlaw buff key strings.
- `838-840` — `RefreshFast` hardcodes `Enum.PowerType.Energy` and
  `Enum.PowerType.ComboPoints`, while `profile.resources` sits unread.

**`EnergyModel.lua`** — the *mechanism* is fully general and is the best thing in the
repo. Interval bracketing from `IsSpellUsable`, exact collapse on a threshold crossing,
and regen solved from two crossings (`EnergyModel.lua:416-439`) would work for Focus,
Rage, Runic Power, Astral Power or Mana without modification. The *parameterisation* is
not: `BASE_REGEN = 10`, `AR_REGEN_MULTIPLIER = 1.75`, `COMBAT_POTENCY_AVG = 2.5`,
`AR_DURATION = 15` (lines 60-69), `arActive()` reading `buffs.adrenalineRush` (137-142),
and `OnCast` special-casing Pistol Shot as free under Opportunity (842-845).

The generalisation here is cheap because the hard part is already right. Rename the module
to a resource model, take the constants and the "this buff modifies regen" rule from the
profile, and it serves every spec. This is the highest value-to-effort item in the repo.

**`CooldownModel.lua`** — `CDR_PER_CP = 1.0` / `CDR_PER_CP_TRIPLE = 1.3` (51-52) and
`applyCDR` reading `State.buffs.rtb.stage` (147-153). Same Restless Blades leak as
`Rotation.lua:329`, implemented twice, independently, in two files. When Blizzard changes
the rate, one of them will be missed.

**`UserRules.lua:23-33`** — the user-facing condition vocabulary contains `rtbStage`.
Every spec's rule editor would offer "Roll the Bones stage" as a condition.

### 1.3 What the simulator cannot model at all

These are not leaks; they are absent capabilities. Each one blocks a class of spec, and
one of them is wrong for Outlaw today.

1. **Buffs never expire in the simulation.** `deepCopyState` copies `expires`
   (`Rotation.lua:304`, `312`, `318`) but `Predict` advances virtual time
   (`Rotation.lua:800-808`) without ever re-evaluating a buff against it. A four-step
   lookahead can therefore recommend Pistol Shot at step 4 on an Opportunity proc that
   expires at step 2. **This is a live correctness bug in the shipping spec**, not just a
   framework gap.
2. **No charges.** `ability.cd` is a scalar. Nothing models `charges` / `maxCharges` /
   recharge time. This alone blocks most of Demon Hunter, Monk, Druid and Warrior.
3. **No cast times or channels.** `ability.gcd` is a boolean. Every ability is treated as
   instant. Any caster spec is unrepresentable — the whole point of a Frost Mage lookahead
   is knowing that a hardcast occupies the next 2 seconds.
4. **No DoT/debuff tracking.** SimC APLs are full of `dot.x.remains<gcd`. Midnight makes
   enemy auras secret, so this may be permanently impossible — but that is a *finding to
   state*, not a gap to leave silent. Several specs are simply out of scope until it is
   resolved, and the framework should say which.
5. **Fixed resource generation.** `cpGen` is a constant. Sinister Strike's double-strike
   proc, Rage from damage taken, and Runic Power from Rune spend are all stochastic or
   event-driven.
6. **No rune model.** Death Knight runes are six independently recharging resources. Not
   expressible in the current shape at all.

### 1.4 The profile contract I would actually want

Three seams, in dependency order.

**Seam A — resource schema.** The profile declares its resources; `StateTracker` builds
`State.resources[name]` dynamically instead of hardcoding two fields.

```lua
resources = {
  {
    key      = "energy",
    powerType = Enum.PowerType.Energy,
    max      = 100,
    -- The interval model needs only these two things to work for any resource.
    regen    = { base = 10, hastedBase = true, flat = 2.5 },
    modifiers = { { buff = "adrenalineRush", regenMult = 1.75, maxBonus = 50 } },
  },
  { key = "comboPoints", powerType = Enum.PowerType.ComboPoints, max = 6, discrete = true },
}
```

Rule helpers become `H.resource(S, "energy")` and `H.atLeast(S, "comboPoints", n)`. The
existing `cpAtLeast` family survives as thin aliases so profiles do not all break at once.

**Seam B — aura schema.** Replaces the `if/elseif` chains and `RTB_BUFF_NAMES`.

```lua
auras = {
  opportunity = { spellID = 195627, overlaySpell = "pistolShot", tracksStacks = true },
  adrenalineRush = { spellID = 13750, duration = 15 },
  -- The Roll the Bones stage machinery generalises to "one of these auras is up, and
  -- which one it is IS the value". Several specs have this shape.
  rtb = {
    kind     = "exclusive",
    members  = { [1214933] = 1, [1214934] = 2, [1214935] = 3, [1214937] = 4 },
    appliedBy = { "rollTheBones", "keepItRolling" },
    duration = 30, extendCap = 60,
  },
}
```

`rtbStage` in the condition vocabulary becomes the generic `auraValue` condition against
an `exclusive` aura. `Observers.lua`'s RtB learner (`Observers.lua:295-335`) becomes the
generic learner for any `exclusive` aura — it is already written generically enough that
this is mostly renaming.

**Seam C — effects.** The `spells.pistolShot` / `spells.ambush` special cases move onto
the ability, where they are data:

```lua
[SPELLS.pistolShot] = {
  cost = { energy = 40 }, generates = { comboPoints = 1 },
  consumes = { "opportunity" },
  freeWhen = { buff = "opportunity" },
},
[SPELLS.betweenTheEyes] = {
  cost = { energy = 25 }, spends = { comboPoints = "all" }, cd = 45,
  -- Restless Blades, declared rather than hardcoded in two engine files.
  onSpend = { { resource = "comboPoints", reduceCooldowns = 1.0,
                scaleWhen = { aura = "rtb", atLeast = 3, factor = 1.3 } } },
},
```

`applyCDR` in `Rotation.lua` and `CooldownModel.lua` both collapse into one interpreter
over `onSpend`.

### 1.5 What a third party would have to write today

For Fury Warrior, a contributor would have to: edit `StateTracker.lua` to add rage to the
fixed state schema and to the three aura dispatch chains; edit `Rotation.lua` to stop
applying Restless Blades CDR and to stop assuming energy regen; edit `EnergyModel.lua` or
bypass it; edit `CooldownModel.lua`; and edit `UserRules.lua` to add rage conditions.

That is five engine files for one spec. Nobody does that for someone else's addon. **This
is the whole reason a second spec has not appeared, and it will not change until Seams A
and B land.**

---

## 2. Packaging and distribution

Current state: no `LICENSE`, no `README.md`, no `CHANGELOG.md`, no `.pkgmeta`, no
`.github/`. `Tuono.toc:7` declares `## X-License: MIT` — **a licence claim with no licence
file behind it.** That is not a nitpick: without the text, the grant is not made, and no
distributor or contributor can rely on it. Fix it first; it costs one file.

### 2.1 Files to add

**`LICENSE`** — the MIT text, matching the TOC's existing claim.

**`.pkgmeta`** — consumed by the BigWigs packager, which is the de-facto standard build
for WoW addons and uploads to CurseForge, WoWInterface, Wago and GitHub Releases from one
run. YAML: spaces only, tabs break the parser.

```yaml
package-as: Tuono

enable-nolib-creation: no

ignore:
  - tests
  - tools
  - docs
  - CLAUDE.md
  - STATE.md
  - .gitattributes

manual-changelog:
  filename: CHANGELOG.md
  markup-type: markdown

# Empty until libraries are actually adopted (see §3). Listed here so the decision is
# recorded rather than rediscovered.
# externals:
#   Libs/LibStub: https://repos.wowace.com/wow/libstub/trunk
```

Directives verified against the packager wiki: `package-as`, `externals`, `move-folders`,
`ignore`, `required-dependencies`, `optional-dependencies`, `embedded-libraries`,
`tools-used`, `manual-changelog`, `enable-nolib-creation`.

**`.github/workflows/release.yml`** — tag-triggered packaging.

```yaml
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: write        # default token is read-only since Feb 2023; without this the
                         # packager cannot publish a GitHub release
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }     # packager derives the changelog from history
      - uses: BigWigsMods/packager@master
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}
          GITHUB_OAUTH: ${{ secrets.GITHUB_TOKEN }}
```

**`.github/workflows/test.yml`** — run `lua tests/run_tests.lua` on push and PR. The test
suite is the project's main asset; an untested PR must not be mergeable. This is the
cheapest possible contributor-quality gate and it already works headless.

### 2.2 TOC changes

Replace the hardcoded `## Version: 2.2.1` with `@project-version@`, which the packager
substitutes from the git tag. A hand-maintained version drifts from the tag, and then bug
reports carry a version string that does not identify a commit.

Add the distribution IDs once the projects exist: `## X-Curse-Project-ID`, `## X-Wago-ID`,
`## X-WoWI-ID`. The packager uses these to route uploads.

Add `## Category: Combat` and `## X-Website`. `## X-Website` is already present
(`Tuono.toc:8`).

The current `## Interface: 120005, 120007, 120100` is **valid** — comma-delimited
interface lists are supported by the client, and let one TOC serve several builds. Note
this contradicts the ancestor project's `tests/toc_check.lua`, which asserted "single
number, no commas" as a hard lint. That assertion was a project-scope preference, not a
format rule, and it should not be carried forward. The current `tests/toc_check.lua`
correctly checks only that there is exactly one `## Interface:` line.

For multi-flavour support later, the client picks the most specific TOC available:
`Tuono_Mainline.toc` beats `Tuono.toc` on retail. Not needed while the addon targets
Midnight only.

### 2.3 Where to publish

CurseForge is the incumbent and carries the overwhelming majority of the catalogue; Wago
is the modern alternative and is where the WeakAuras-adjacent audience already is. Publish
to both — the packager does it in one step, so there is no ongoing cost to covering both.
GitHub Releases as well, since several managers (WowUp, CurseBreaker) can install from it
and it is the only channel you control outright.

UNVERIFIED: WoWInterface's current health. Searching turned up no shutdown announcement
and the site responds, but it is clearly the least active of the three. Include it in the
packager config because it is free to do so; do not spend effort on it.

---

## 3. Libraries

### 3.1 Recommendation

**Do not adopt AceAddon-3.0 or AceEvent-3.0.** `Core.lua:34-61` already implements event
dispatch with two properties AceEvent does not offer: per-handler `pcall` isolation
(`Core.lua:177-183`), and **`RegisterUnitEvent`** (`Core.lua:51-61`), which filters unit
events in the C engine rather than in Lua. The comment there is right about why it matters
— `UNIT_AURA` fires for every group member and every nameplate, and engine-side filtering
is the difference between a handful of dispatches and thousands per second in a raid pull.
Migrating to AceEvent would lose that and buy nothing.

**Do adopt AceDB-3.0.** This is the one clear win, and it is the enabler for §4.

`Core.lua:15-32`'s `deepMerge` has a defect that will bite on the first release that
changes a default: it only fills keys that are `nil` (`Core.lua:27`). Once a key exists in
SavedVariables, a changed default *never* reaches an existing user. It also never removes
stale keys, and there is no schema version. `Migration.lua` handles migration from the
predecessor addon, not default drift.

AceDB stores defaults behind a metatable rather than copying them into the saved table.
Changing a default therefore just works, and the saved file holds only what the user
actually changed. It also brings the profile system — per-character, per-spec,
account-wide, copy-from, reset — which is precisely the multi-spec lifecycle in §4, and
which is fiddly enough that hand-rolling it is a poor use of time.

**Do not adopt AceConfig-3.0.** The priority-list editor is a reorderable rule list with
per-row condition builders (`Options.lua:117-180`, `UserRules.lua:238-264`). AceConfig
models that badly, and a rewrite is a lot of motion for a worse editor. Instead, spend ten
lines registering the existing canvas panel with Blizzard's Settings API:

```lua
local category = Settings.RegisterCanvasLayoutCategory(panel, "Tuono")
Settings.RegisterAddOnCategory(category)
```

Verified: `Settings.RegisterCanvasLayoutCategory(frame, name)` and
`Settings.RegisterAddOnCategory(category)` are the 10.0+ replacements for
`InterfaceOptions_AddCategory`. Today **Tuono does not register anywhere** — grep for
`Settings.Register|InterfaceOptions_AddCategory|RegisterAddOnCategory` across the repo
returns nothing, and `Options.lua:253` creates a bare `TuonoOptionsFrame` parented to
`UIParent`. The addon is therefore invisible in Game Menu → Options → AddOns, which is the
first place every user looks. That is a bad first impression for zero technical reason.

**Do adopt LibCustomGlow.** `Highlight.lua:226-324` hand-rolls a pooled overlay frame
specifically to avoid tainting Blizzard's secure action buttons — the reasoning at
`Highlight.lua:227-246` is correct and hard-won. LibCustomGlow solves exactly this problem,
is what WeakAuras uses, and offers pixel-glow, autocast-shine and button-glow variants that
users already recognise from other addons. Keeping the bespoke version means owning taint
correctness forever against a moving client.

**Do adopt Masque** (optional dependency). Tuono's icons are plain `Button` frames with a
texture (`Display.lua:258-323`). Masque skinning is a near-universal expectation for
icon-based addons and the integration is small. Users will ask; it is cheaper to plan for.

**Do adopt LibSharedMedia-3.0** when fonts and textures become configurable.
`Display.lua:289` hardcodes `STANDARD_TEXT_FONT`.

**Skip LibDataBroker/LibDBIcon** for now. A minimap button is a config surface, and the
slash commands plus a Settings entry cover it. Revisit if users ask.

**LibStub** comes along with any Ace library; it is not a decision in itself.

### 3.2 The cost to be honest about

Adopting libraries means either `externals` in `.pkgmeta` (packager fetches at build time)
or committing them under `Libs/`. Use `externals` — committed libraries go stale silently
and turn every library update into a manual merge. It also means the offline test harness
must stub or vendor them, which is real work: `tests/harness.lua` currently loads exactly
what the TOC lists and nothing else.

Adopt AceDB and LibCustomGlow. Defer the rest until a user asks.

---

## 4. Multi-spec lifecycle

`Profiles.lua:214-229` currently handles login and `PLAYER_SPECIALIZATION_CHANGED` by
picking the first registered profile whose class and spec match, with a saved manual
override. That is a reasonable skeleton with four gaps:

**Talent changes are not handled.** `TRAIT_CONFIG_UPDATED` is registered by
`Observers.lua:345` and `Highlight.lua:453`, but not by `Profiles.lua`. A talent swap can
change spell IDs, costs, cooldowns and which abilities exist, and the profile does not
re-resolve. `resolveAliases` (`Profiles.lua:94-138`) runs only on activation.

**No per-spec settings.** `Tuono.db.profiles[profileId]` (`UserRules.lua:153-158`) keys
custom priority lists by profile, which is right. But display position, scale, icon count
and highlight settings (`Config.lua:11-33`) are global. A player who wants a four-icon bar
on Outlaw and a two-icon bar on Assassination cannot have it. AceDB's profile system gives
this for free, including the per-spec profile mode.

**No import/export.** The convention users expect — from WeakAuras and Hekili — is a
deflated, base64-encoded blob pasted into a text box. `UserRules.lua:11-14` already made
the critical design choice that makes this safe: rows are **plain data, not functions**,
compiled to predicates at load. So an imported string can never execute a stranger's Lua.
That is the hard part, and it is done. What remains is serialise → `LibDeflate` →
`LibSerialize` → base64, a version tag, and a validating importer that rejects unknown
condition types rather than compiling them to `false` silently.

Do this. It is the single largest driver of adoption for a rotation addon: it turns every
good player into a distributor of your addon.

**User lists do not survive an addon update.** `UserRules.lua:206-213` materialises an
editable copy on first open, seeded from the built-in list. From that moment the user's
copy is frozen — a later release that fixes a rule (as `be2569d` just did for Roll the
Bones) will not reach anyone who opened the editor once. `IsCustomised` is all-or-nothing
per list.

That is a serious maintenance trap: the more successful the addon, the more users are
running a stale fork of a rotation that got fixed. Fix it with per-row provenance —
record which built-in row a user row derived from and whether it was actually modified,
then on upgrade merge unmodified rows forward and report the conflicts rather than
silently keeping either side. Store a `schemaVersion` alongside so this stays tractable.

---

## 5. Sim data pipeline

The ancestor's `tools/refresh_sim_data.py` and `docs/SIM-DATA.md` have the right shape:
fetch the `.simc` profile from the SimulationCraft repo, diff APL actions against the
addon's rules, produce a report, and require a human to apply it. `docs/SIM-DATA.md:74`
gets the key rule right — **"DO NOT auto-edit"**.

Two things make the ported version meaningfully better than the original.

**The diff can be semantic, not name-based.** The ancestor diffed action *names*. Tuono's
priority rules already carry machine-readable conditions: every rule declares
`conditions = { { type = "cp", op = ">=", value = 6 }, ... }`
(`profiles/OutlawRogue.lua:180`), and that vocabulary is the same one the in-game editor
uses (`UserRules.lua:23-33`). So the tool can parse `combo_points>=cp_max_spend-1` from
SimC into the same IR and report *"rule fires at >= 6, SimC says >= cp_max_spend - 1"* —
which is the class of drift that name-diffing misses entirely, and exactly the class that
produced the `>=2` versus `>=3` Keep It Rolling bug noted at
`profiles/OutlawRogue.lua:141-143`.

**Spell IDs can be verified automatically.** The costliest defects in this project's
history were bad static data: Preparation `14185` (Classic, 404s on retail), Roll the
Bones `315508` (renumbered in Midnight), a Preparation cooldown wrong by 8x, a fabricated
`cpGen` on Blade Rush, and Killing Spree modelled as spending no combo points — all
documented in `profiles/OutlawRogue.lua:44-49`. Every one of those is checkable offline
against a DBC dump. Adding a `tools/verify_spell_data.py` that cross-checks each
`SPELLS`/`ABILITIES` entry against a spell-data source and fails CI on a mismatch would
have caught all five.

UNVERIFIED: wago.tools exposes a queryable DBC/CSV export that would serve as that source.
Confirm the endpoint and its terms before building against it.

**Structured citations.** Sources are currently prose comments
(`profiles/OutlawRogue.lua:194-199` cites the SimC line for Preparation, well). Make it a
field so it is machine-checkable and so a stale citation is visible:

```lua
source = {
  simc     = "MID1_Rogue_Outlaw.simc:preparation",
  expr     = "cooldown.adrenaline_rush.remains>30&!cooldown.between_the_eyes.ready&!cooldown.killing_spree.ready",
  guide    = "Maxroll Outlaw 12.1",
  verified = "2026-08-17",
},
```

Then a lint can fail any rule whose `verified` date predates the current patch, which
turns "is this rotation current?" from a question into a gate.

**Split of labour.** Automate: fetching, APL parsing, action/condition diffing, spell-ID
and cooldown verification, staleness reporting. Human: mapping SimC expressions onto
readable state (many reference values Midnight hides — `docs/SIM-DATA.md:99` already
flags `target.health.pct` as unreadable), deciding priority order, and deciding what to
drop as unmodellable. Never auto-write a rule.

---

## 6. What would make maintainers contribute

The bus factor is the real risk, and the ancestor's `PLAN.md` already identified it as
HIGH likelihood. Rotation addons die when one person stops caring, because rotations rot
every patch. Hekili survives on a contributor base; a solo project does not survive a
single expansion.

Five things lower the barrier, in order of effect:

1. **A spec author must never touch an engine file.** Everything in §1.4. This is the
   whole game — the current five-file cost is prohibitive and no amount of documentation
   compensates.
2. **The offline test harness is the recruiting tool.** A contributor can already run
   `lua tests/run_tests.lua` and get a verdict in a second, without launching WoW. That is
   rare in this ecosystem and genuinely attractive. It needs to be in the README's first
   screen, wired to CI, and extended with a `tests/test_profile_contract.lua` that any new
   profile is checked against automatically. Then "did I write a valid spec?" is answered
   by a machine rather than by review.
3. **A worked example that is not the reference spec.** `profiles/OutlawRogue.lua` is
   heavily commented but it is also the spec every seam was built around. A second profile
   for a deliberately different spec proves the seams and doubles as the template.
4. **Publish the flight recorder as a contributor tool.** `Recorder.lua` plus
   `tools/trace_analyze.py` let a contributor prove a rotation bug with a file instead of
   a description. Nothing else in this ecosystem has that. Document it as the standard way
   to file a rotation issue.
5. **Say what you will not accept.** The legality boundary — recommendation only, never
   read a protected value, no input automation — needs to be a stated contribution rule,
   not folklore. Otherwise the first popular PR is someone laundering a secret through a
   widget, which `Recorder.lua:66-87` already measured as closed and which would get the
   addon delisted.

---

## 7. Ranked roadmap

Effort is calendar-days for one experienced developer, not ideal-hours.

**1. Legal and packaging hygiene — 1 day.**
`LICENSE` (the TOC already claims MIT with nothing behind it), `README.md`,
`CHANGELOG.md`, `.pkgmeta`, both GitHub workflows, `@project-version@` in the TOC, and the
ten-line Settings API registration. Nothing else can ship until this exists, it is
entirely mechanical, and the missing licence is a real defect rather than a nicety.

**2. Fix buff expiry in the simulator — 1 day.**
§1.3 item 1. This is a live correctness bug in the shipping spec, not a framework
concern: the lookahead recommends abilities gated on procs that will have expired. It also
has to be solved before any smoothing work can be trusted, because a step that is wrong
for this reason is noise the smoothing layer will faithfully preserve. Cheap, isolated,
testable offline today.

**3. Seam A — resource schema — 4 days.**
Generalise `EnergyModel` into a resource model parameterised from `profile.resources`
(which already exists and is dead), and make `StateTracker.State.resources` dynamic. The
mechanism is already general; this is mostly moving constants into data and adding a
dispatch layer. Highest value-to-effort ratio in the project.

**4. Seam B — aura schema — 4 days.**
Kill `RTB_BUFF_NAMES`, the hardcoded `195627`, and the three `if/elseif` chains. Generalise
the Roll the Bones exclusive-aura machinery, including the learner. Unblocks any spec with
procs, which is all of them.

**5. Seam C — declarative effects — 3 days.**
Move proc consumption, stealth, and Restless Blades CDR onto ability data. Collapses the
duplicated `applyCDR` in `Rotation.lua:329` and `CooldownModel.lua:145` into one
interpreter. Do this after A and B because it depends on both.

**6. Charges and cast times — 3 days.**
§1.3 items 2 and 3. Without these the framework covers melee resource specs only, and the
first contributor who picks a caster hits a wall on day one.

**7. AceDB migration and per-spec profiles — 2 days.**
Fixes the `deepMerge` default-drift defect, gives per-spec settings, and sets up import/
export. Do it before the user base is large enough that a saved-variable migration hurts.

**8. Second spec, chosen adversarially — 3 days.**
Fury Warrior. Rage instead of energy, charges, no secondary resource, no stealth. If the
seams survive Fury they will survive most things. This is the forcing function that proves
1–7 rather than a feature in itself — expect it to find gaps, and budget for the fixes it
surfaces rather than treating them as failure.

**9. Import/export strings — 2 days.**
The adoption multiplier. Safe to build because rows are already inert data.

**10. Sim data pipeline v2 — 3 days.**
Semantic APL diffing, automated spell-data verification, structured citations, staleness
gate.

**11. Priority-list upgrade merge — 2 days.**
Per-row provenance so a fixed built-in rule reaches users who customised. Urgency scales
with adoption; it is nearly free now and expensive once there are ten thousand users
carrying stale forks.

**12. Masque, LibCustomGlow, LibSharedMedia — 2 days.**
Polish. Real, but nothing depends on it.

Items 1 and 2 are worth doing this week regardless of what else happens. Items 3–5 are the
framework; without them there is no framework, only an Outlaw addon with a good engine
inside it.

---

## Sources

Ecosystem claims verified against:

- [BigWigsMods/packager](https://github.com/BigWigsMods/packager) and [Preparing the PackageMeta File](https://github.com/BigWigsMods/packager/wiki/Preparing-the-PackageMeta-File)
- [Using the BigWigs Packager with GitHub Actions](https://wowpedia.fandom.com/wiki/Using_the_BigWigs_Packager_with_GitHub_Actions)
- [TOC format — Warcraft Wiki](https://warcraft.wiki.gg/wiki/TOC_format) and [The client now supports comma-delimited Interface versions](https://us.forums.blizzard.com/en/wow/t/the-client-now-supports-comma-delimited-interface-versions/1896097)
- [Settings API — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Settings_API) and [Creating a settings menu](https://warcraft.wiki.gg/wiki/Creating_a_settings_menu)
- [Ace3](https://github.com/WoWUIDev/Ace3), [AceDB-3.0 Tutorial](https://www.wowace.com/projects/ace3/pages/ace-db-3-0-tutorial)
- [Masque](https://github.com/SFX-WoW/Masque), [LibCustomGlow](https://www.curseforge.com/wow/addons/libcustomglow)
