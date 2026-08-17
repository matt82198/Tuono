# RESEARCH — Midnight API surface and the competitive landscape

**Client:** 12.1.0 build 69273. **Researched:** 2026-08-17.
Confidence markers as in `docs/LEGALITY.md`: **VERIFIED** (own probe or Blizzard docs),
**CORROBORATED** (two independent secondary sources), **UNVERIFIED** (single weak source
or inference).

---

## 1. The landscape

### 1.1 Hekili is dead

Hekili does not work under Midnight. **CORROBORATED** (multiple addon roundups; the
CurseForge listing is still titled "Hekili [The War Within]", i.e. it was never updated
for 12.x). The reason is structural, not a bug: Hekili's entire design is a snapshot-based
forward simulation fed by combat-log events and full resource reads, and 12.0 removed
`COMBAT_LOG_EVENT_UNFILTERED` from the addon API and made resources secret. There is no
patch that recovers it.

**This is the single most important fact about the market.** The category leader is gone,
its users are stranded, and everything that replaced it is a thin wrapper.

### 1.2 What replaced it

| Addon | What it does | Own rotation logic? | Display | Evidence |
|---|---|---|---|---|
| **HekiLight** | Re-displays Blizzard's assist as a movable icon strip | **No** — "Blizzard controls the rotation logic. HekiLight only reads and displays it" | up to 5 icons, default 3 | 29.7K downloads, updated 2026-08-12. VERIFIED (CurseForge) |
| **Knickili** | Single icon + keybind from `GetNextCastSpell` | **No** | 1 icon | 12.7K downloads, updated 2026-06-17. VERIFIED (CurseForge) |
| **TrueShot** | Presentation overlay on the assist, plus per-spec "presentation rules" and hero-talent detection | **Partially** — labels and "stabilises" AC output, degrades to passthrough | overlay | VERIFIED (GitHub, itsDNNS/TrueShot) |
| **MaxDps** | Pre-existing rotation helper | **Yes**, historically | button highlight | status under 12.x **UNVERIFIED** — see §1.4 |

Every one of these except MaxDps takes Blizzard's recommendation as ground truth. None of
them models resources. None of them expresses uncertainty. TrueShot is the closest
competitor in ambition and it explicitly positions itself as "complementary, not
corrective" and "degrades to pure AC passthrough when signals are unavailable".

**Tuono is doing something nobody else in this list is doing:** running an independent
priority list against a reconstructed resource model, and disagreeing with Blizzard on
purpose. That is the product.

### 1.3 The competitive claim, stated accurately

Blizzard's assist is **deliberately** worse than optimal play. Game director Ion
Hazzikostas said the system is intentionally sub-optimal and aimed at "people who maybe
aren't interested in the gameplay of mastering their spec". **CORROBORATED.**

Reported gaps:

- **One-button mode:** ~15–20% DPS loss vs optimised manual play, driven by an explicit
  built-in penalty of roughly 25% of a GCD per press. **CORROBORATED** (Wowhead;
  community testing). Per-spec spread is wide: Augmentation Evoker ~8%, Destruction
  Warlock ~10%.
- **Highlight assist** (the mode Tuono actually competes with) is a *different and
  smaller* penalty — it has no GCD tax, since the player still presses the button. I could
  **not** retrieve the per-spec highlight-assist numbers: the Wowhead article that
  contains them did not render its body through WebFetch. **UNVERIFIED — do not quote a
  highlight-assist percentage until someone reads that article directly.**
- Spec-by-spec quality varies a lot: Retribution Paladin reportedly matches Hekili ~90% of
  the time; Windwalker Monk and Frost Mage / Beast Mastery are reported much worse
  (~20% drop for the latter two). **UNVERIFIED** — forum anecdote, single thread.
- A concrete failure mode reported: the assist suggested Kill Command on Survival Hunter
  while the player was already at maximum resource stacks. **UNVERIFIED** (single forum
  post) but consistent in kind with what we measured (§1.5).
- Structural complaint that matters for our UI: the assist "only highlights one ability at
  a time rather than showing a queue, forcing players to scan action bars instead of
  focusing on enemy mechanics." **UNVERIFIED** (forum), but it is exactly the lead-time
  argument in `IntelligenceLayer.lua:368-384`.

**Do not repeat "27% better than Blizzard" anywhere public until it is reproducible.**
Nothing in this repo supports that figure, and the one number I could verify is a
one-button figure that does not apply to the mode we compete with.

### 1.4 MaxDps

I could not establish MaxDps's current Midnight status from the web. **UNVERIFIED.**
`EnergyModel.lua:152-154` states that MaxDps calls `GetPowerRegenForPowerType`, and that
this is where Tuono learned about the function. That provenance claim is plausible and
unverified here; more importantly, **the function is secret in combat on this client**
(see `docs/LEGALITY.md` §2.1), so whatever MaxDps does with it, it cannot be getting a
live in-combat regen rate from it either.

Worth a direct look at the MaxDps source rather than more searching.

### 1.5 What our own trace says about the assist

From the 69-second flight recording (**VERIFIED**, own probe):

`C_AssistedCombat.GetNextCastSpell()` returned **315584 on every sample**, in combat and
out. Spell 315584 is **Instant Poison** — a one-hour weapon buff with a 1.5s cast that
grants +4% energy regen and does not break stealth (**VERIFIED**, Wowhead).

So for the entire fight, Blizzard's engine was saying "apply your poison", because the
player had let it lapse. That is *correct advice* and it is also completely useless as a
combat rotation signal.

Three consequences, all actionable:

1. **The 0/127 disagreement figure is explained and is not evidence of anything.** The
   drift sensor in `IntelligenceLayer.lua:135-149` was comparing a rotation spell against
   a buff-maintenance suggestion. Any conclusion drawn from `disagreeStreak` in that trace
   is void.
2. **The drift sensor needs to exclude non-rotation picks.** Compare against
   `Tuono.Rotation.ABILITIES` membership before counting a disagreement, or the sensor
   reports drift whenever the player is missing a consumable.
3. **Tuono has a real gap: it models no buff maintenance at all.** Instant Poison, and
   Slice and Dice (315496, which the aura capture shows was active), are part of playing
   the spec correctly and are entirely absent from `profiles/OutlawRogue.lua`. Blizzard
   caught it and we did not. That is worth fixing on the merits, independent of the
   sensor.

---

## 2. The Assisted Combat API surface

Four functions and one event exist. **VERIFIED** (Warcraft Wiki category listing).

| Symbol | Signature | Added | Used by Tuono |
|---|---|---|---|
| `C_AssistedCombat.GetNextCastSpell` | `spellID = GetNextCastSpell([checkForVisibleButton])` | 11.1.7 | yes |
| `C_AssistedCombat.GetRotationSpells` | `spellIDs = GetRotationSpells()` → `number[]` | 11.1.7 | yes |
| `C_AssistedCombat.IsAvailable` | `isAvailable [, failureReason]` | 11.1.7 | yes |
| `C_AssistedCombat.GetActionSpell` | — | 11.1.7 | only in `ApiTest.lua` |
| `ASSISTED_COMBAT_ACTION_SPELL_CAST` (event) | — | — | **no** |

Notes:

- `GetNextCastSpell` takes an optional `checkForVisibleButton` boolean, default `false`.
  Custom action buttons participate if registered via `SetActionUIButton`. **VERIFIED.**
  Tuono passes `false` (`AssistReader.lua:126`).
- **No return of any C_AssistedCombat function is flagged secret in the documentation.**
  VERIFIED. But our probe shows `IsAvailable` returning a readable `true` in combat while
  `AssistReader.lua:87-97` documents it coming back *secret* in instanced combat. Both can
  be true — the probe was taken outdoors. Keep the tri-state read; do not simplify it.

### 2.1 GetRotationSpells: ordered queue or capability set?

**The documentation does not say.** It specifies the return type as `number[]` and gives
no description of ordering or semantics. **VERIFIED that the docs are silent.**

Evidence that it is a **capability set**, not a live ordered queue:

- `AssistReader.lua:165` builds it into a set "for membership tests only" and calls it a
  CAPABILITY SET in its own comment.
- Our trace: `aoeDetected` (derived from Blade Flurry's *membership*) was true on all 127
  ticks of a single continuous fight, with no variation, while the actual recommendation
  and the player's actions changed throughout. A live ordered queue would not be constant.
  **VERIFIED** from trace.
- HekiLight, which renders "up to 5 icons from the rotation queue", states that it
  "automatically hides abilities on cooldown" in the secondary slots — i.e. it filters the
  list itself rather than trusting it as a live sequence. **CORROBORATED** (CurseForge
  description) — weak, but it is the behaviour you would build if the list were static.

**Conclusion: treat it as an unordered capability set.** The recent `AssistReader` fix
that stopped deriving AoE from membership was correct. Confidence: **CORROBORATED**, not
VERIFIED — the docs do not settle it, so if this assumption ever becomes load-bearing
again, probe it directly by logging the array across a fight with changing target counts.

### 2.2 Update cadence

Undocumented. **UNVERIFIED.** `IntelligenceLayer.lua:93-96` asserts Blizzard's own
`AssistedCombatManager` polls `GetNextCastSpell` every 0.1s and that an earlier claim of
the value being static in combat was an artefact of a crash in our own reader. That
correction is consistent with the code but I found no external confirmation of the 0.1s
figure. Treat the number as unverified; the *behaviour* (it changes in combat) is sound.

---

## 3. The "Waiting for Energy" sentinel — claim PARTIALLY REFUTED

`AssistReader.lua:15-38` claims spell **1249752** is a Feral-Druid-specific pooling
placeholder, scoped via `AssistedCombatStep` rows 13079/13126 → `AssistedCombatID` 115 →
`ChrSpecializationID` 103 (Feral), and that a sweep of all 331 `AssistedCombatStep`
spellIDs found no other such sentinel.

**What I could verify:** the spell exists and is named **"Waiting for Energy"**. It is a
**passive** spell with a **hidden aura**, applying a **Dummy** aura via a **server-side
script**. **VERIFIED** (Wowhead).

**What I could NOT verify:** the Feral-only scoping, the DB2 row numbers, the
`AssistedCombatID` 115 → spec 103 join, or the claim that no other sentinel exists.
Wowhead's page carries no class or specialization restriction. **UNVERIFIED.**

Also unverified: the comment's claim that the spell is flagged `DO_NOT_DISPLAY |
DO_NOT_LOG`. Wowhead shows "Passive spell" and "Aura is hidden" — compatible in spirit,
but not the same flags.

**Assessment.** The *filter* is right either way: a hidden passive placeholder must never
reach the queue or the drift comparison, and `AssistReader` filters it unconditionally
regardless of spec. That behaviour needs no change.

The *scoping* claim is doing real damage though. On the strength of it, the energy
anchoring machinery in `EnergyModel.lua:640-739` — which extracts an **exact** energy
value on the sentinel's falling edge, and lets two consecutive anchors *solve* the regen
rate — was made opt-in per profile (`profile.waitSentinels`) and is switched **off for
Outlaw**. If the Feral-only claim is wrong, Outlaw is leaving the single tightest
observation in the whole model on the table.

**Recommended next step:** this is cheap to settle empirically and expensive to keep
guessing about. Log every distinct `GetNextCastSpell` return over a few Outlaw sessions
and check whether 1249752 (or any spell with icon 134377) ever appears. The recorder
already captures `assist` per tick; one pass over accumulated traces answers it. Do not
re-derive it from DB2 claims nobody in this repo can check.

---

## 4. API surface Tuono is not using but should consider

| API | Why it matters | Confidence |
|---|---|---|
| `C_Secrets.GetPowerTypeSecrecy(powerType)` | Returns a secrecy **level** (2 for Energy, 0 for Combo Points, in and out of combat). Direct answer to "is this resource hidden on this client", instead of inferring it from a failed read. Would let a future non-Outlaw profile discover its own resource situation. | VERIFIED (probe) |
| `canaccessvalue(v)` | "Would an operation on this value error." Expresses exactly what `Tuono.readNum`/`readBool` approximate. | VERIFIED (wiki) |
| `issecrettable(t)` / `canaccesstable(t)` | `Recorder.lua` already hand-rolls this for `UNIT_AURA` payloads with nested pcalls. These replace that. | VERIFIED (wiki) |
| `ASSISTED_COMBAT_ACTION_SPELL_CAST` | An event, versus the current per-tick poll of `GetNextCastSpell`. Could cut polling and give an exact edge for the sentinel/anchor logic. Semantics undocumented — probe before adopting. | VERIFIED it exists; semantics UNVERIFIED |
| `C_Secrets.ShouldCooldownsBeSecret` / `GetSpellCooldownSecrecy` | Probe returned `ShouldCooldownsBeSecret = true` in combat, `CALL_FAILED` out. `StateTracker` currently infers cooldown-timer secrecy per read. | VERIFIED (probe) |
| `C_Spell.GetSpellCharges` (if present) | Nothing in Outlaw uses charges, but no other spec's profile can be written without it. Not yet probed. | UNVERIFIED |
| `SetActionUIButton` + `GetNextCastSpell(true)` | Makes Blizzard's own visibility check aware of custom buttons. Relevant if the highlight path ever needs to cooperate with a custom bar addon. | VERIFIED (wiki) |

### 4.1 One thing to stop doing

`Recorder.lua:88-155` (`tryReadBack`) re-tests widget laundering on every probe. That
question is settled — closed by design, corroborated by both our in-combat probe and the
wiki's Secret Aspects table (`docs/LEGALITY.md` §2.2). Keep one cheap assertion if you
want a canary for a Blizzard regression, but the three-channel probe is spending combat
budget to re-learn a known answer.

---

## Sources

- [Secret Values — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Secret_Values)
- [Patch 12.0.5 API changes — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.0.5/API_changes)
- [C_AssistedCombat.GetNextCastSpell — Warcraft Wiki](https://warcraft.wiki.gg/wiki/API_C_AssistedCombat.GetNextCastSpell)
- [C_AssistedCombat.GetRotationSpells — Warcraft Wiki](https://warcraft.wiki.gg/wiki/API_C_AssistedCombat.GetRotationSpells)
- [AssistedCombat API category — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Category:API_systems/AssistedCombat)
- [Spell 315584 Instant Poison — Wowhead](https://www.wowhead.com/spell=315584)
- [Spell 1249752 Waiting for Energy — Wowhead](https://www.wowhead.com/spell=1249752)
- [HekiLight — CurseForge](https://www.curseforge.com/wow/addons/hekilight)
- [Knickili — CurseForge](https://www.curseforge.com/wow/addons/knickili)
- [Hekili \[The War Within\] — CurseForge](https://www.curseforge.com/wow/addons/hekili)
- [TrueShot — GitHub](https://github.com/itsDNNS/TrueShot)
- [Is Blizzard's Rotation Assist meant to replace Hekili? — Blizzard Forums](https://us.forums.blizzard.com/en/wow/t/in-midnight-is-blizzard%E2%80%99s-rotation-assist-meant-to-replace-addons-like-hekili/2212381)
- [Estimated DPS loss with Highlight Assist and One-Button — Wowhead](https://www.wowhead.com/news/estimated-dps-loss-with-highlight-assist-and-one-button-rotation-in-patch-11-1-7-377287)
- [WoW previews rotational assistance UI, nixes automating addons — Massively OP](https://massivelyop.com/2025/05/01/world-of-warcraft-previews-new-rotational-assistance-ui-tool-nixes-some-automating-addons/)
- Primary: `TuonoDiagDB` flight recording, client 12.1.0.69273, captured 2026-08-12.
