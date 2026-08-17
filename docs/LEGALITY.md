# LEGALITY — what is readable, what is not, and where the line sits

**Client:** 12.1.0 build 69273 (from the flight recording's own `GetBuildInfo`).
**Last verified:** 2026-08-17.

Every claim below carries a confidence marker:

- **VERIFIED** — measured by our own probe on a live client, or stated in Blizzard's own
  API documentation.
- **CORROBORATED** — two independent secondary sources agree.
- **UNVERIFIED** — single weak source, or inference. Do not build on these.

The primary evidence is a machine-readable secrecy probe captured in combat and out of
it, stored in `TuonoDiagDB` and parsed by `tools/trace_analyze.py`. **Where the probe
disagrees with a web source, the probe wins**, and the disagreement is called out.

---

## 1. The secret-values system

Secret values are Lua values that tainted (addon) code may hold and pass around but may
not inspect. They are "black boxes" — the value is really in there, the addon just cannot
see it. Introduced 12.0.0.

### 1.1 What a secret does under each operation

| Operation | Result | Confidence |
|---|---|---|
| Store in variable / upvalue / table value | allowed | VERIFIED (wiki) |
| Pass to a Lua function | allowed | VERIFIED (wiki) |
| `type(secret)` | returns the **real** type ("number", "boolean", …) | VERIFIED (wiki + probe) |
| Concatenate, when string or number | allowed; also `string.format`, `string.join`, `string.concat` | VERIFIED (wiki) |
| Boolean test on a **non-boolean** secret | **allowed** | VERIFIED (wiki) |
| Boolean test on a **boolean** secret | **error** | VERIFIED (wiki) |
| Comparison (`==`, `<`, `<=`, …) | **error** | VERIFIED (wiki) |
| Arithmetic (`+ - * / % ^`) | **error** | VERIFIED (wiki) |
| Length (`#`) | **error** | VERIFIED (wiki) |
| Use as a table **key** | **error** | VERIFIED (wiki) |
| Indexed access/assign on a secret (`secret["foo"]`) | **error** | VERIFIED (wiki) |
| Call as a function | **error** | VERIFIED (wiki) |

**CORRECTION TO EXISTING PROJECT DOCS.** `tests/wow_stub.lua` and the ancestor's
`secret-values-spike.md` both state that `if secret then` errors in general. It does not.
The wiki is explicit that boolean tests are permitted on non-boolean secrets and error
only on boolean-typed ones. That narrows the real hazard: `if UnitPower(...) then` is
safe, `if C_AssistedCombat.IsAvailable() then` is not. `AssistReader.lua:87-97` already
documents exactly that boolean case as the root cause of the frozen first icon, which
corroborates the narrower rule.

### 1.2 Detection helpers

| Function | Purpose | Used by Tuono? | Confidence |
|---|---|---|---|
| `issecretvalue(v)` | is this value secret | yes (`Core.lua:101`) | VERIFIED |
| `canaccessvalue(v)` | would an operation on `v` error | **no** | VERIFIED (wiki) |
| `issecrettable(t)` | is this table secret | **no** | VERIFIED (wiki) |
| `canaccesstable(t)` | would accessing `t` error | **no** | VERIFIED (wiki) |

The three unused helpers are worth adopting: `canaccessvalue` expresses "may I touch
this" directly, which is what `Tuono.readNum`/`readBool` currently approximate by
combining `issecretvalue` with a `type` check.

### 1.3 C_Secrets — the runtime predicate namespace

Enumerated **from the live client** by the probe (`Recorder.R.Probe` walks `_G.C_Secrets`).
27 functions exist:

```
CanCompareUnitTokens              ShouldSpellCooldownBeSecret
GetPowerTypeSecrecy               ShouldTotemSlotBeSecret
GetSpellAuraSecrecy               ShouldTotemSpellBeSecret
GetSpellCastSecrecy               ShouldUnitAuraIndexBeSecret
GetSpellCooldownSecrecy           ShouldUnitAuraInstanceBeSecret
HasSecretRestrictions             ShouldUnitAuraSlotBeSecret
ShouldActionCooldownBeSecret      ShouldUnitComparisonBeSecret
ShouldAurasBeSecret               ShouldUnitHealthMaxBeSecret
ShouldCooldownsBeSecret           ShouldUnitIdentityBeSecret
ShouldSpellAuraBeSecret           ShouldUnitPowerBeSecret
ShouldSpellBookItemCooldownBeSecret  ShouldUnitPowerMaxBeSecret
                                  ShouldUnitSpellCastBeSecret
                                  ShouldUnitSpellCastingBeSecret
                                  ShouldUnitStatsBeSecret
                                  ShouldUnitThreatStateBeSecret
                                  ShouldUnitThreatValuesBeSecret
```

**VERIFIED.** Tuono currently calls only four: `GetSpellAuraSecrecy`,
`ShouldUnitStatsBeSecret`, `ShouldUnitPowerBeSecret`, `GetSpellCooldownSecrecy`.

`GetPowerTypeSecrecy` returns a **level, not a boolean** — the probe returned `2` for
Energy and `0` for Combo Points, in combat and out. VERIFIED. Nothing in the codebase
reads it, and it is the cleanest available answer to "is this resource hidden on this
client", which would let `EnergyModel` stop inferring secrecy from failed reads.

### 1.4 Restriction contexts

The wiki documents 24 named secret *predicates*. The ones that bear on Tuono:

| Predicate | Turns on when | Added | Confidence |
|---|---|---|---|
| `SecretWhenInCombat` | combat addon restrictions | 12.0.0 | VERIFIED |
| `SecretWhenUnitPowerRestricted` | see discrepancy below | 12.0.0 | VERIFIED |
| `SecretWhenCooldownsRestricted` | combat, encounter, challenge mode, PvP | 12.0.5 | VERIFIED |
| `SecretWhenAurasRestricted` | combat, encounter, challenge mode, PvP | 12.1.0 | VERIFIED |
| `SecretWhenUnitStatsRestricted` | unit stats generally restricted | **12.0.5** | VERIFIED |
| `SecretOnRestrictedMaps` | dungeon or raid | 12.0.5 | VERIFIED |

`C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.X)` reports which
are live. **The wiki documents no `Enum.AddOnRestrictionType`**, but the probe proves it
exists: in combat, `Combat` returned `true` while `Encounter`, `ChallengeMode`,
`PvPMatch`, `Map` and `Chat` all returned `CALL_FAILED`. Out of combat, **all six**
returned `CALL_FAILED`.

**UNVERIFIED:** why the non-Combat members fail. Either those enum members do not exist
on this build, or the API errors when the named restriction is inactive. The probe was
taken outdoors in Khaz Algar, so no instance restriction was live either way. Resolve
this before relying on the enum — probe inside a dungeon.

### 1.5 DISCREPANCY: unit power secrecy

The wiki says `SecretWhenUnitPowerRestricted` applies when "the unit isn't
player-controlled". **The probe contradicts this for the player's own energy.**

- `UnitPower("player", Energy)` → `SECRET`, **both in combat and out of combat**. VERIFIED.
- `UnitPower("player", ComboPoints)` → `3` (readable), in combat. VERIFIED.
- `C_Secrets.ShouldUnitPowerBeSecret("player", Energy)` → `true`, in combat and out. VERIFIED.
- `GetPowerTypeSecrecy(Energy)` → `2`; `GetPowerTypeSecrecy(ComboPoints)` → `0`. VERIFIED.

**The probe wins.** Energy secrecy is a property of the *power type*, not of the unit, and
it is unconditional — it does not lift out of combat. Combo points are a secondary
resource and stay readable. This is exactly the premise `EnergyModel.lua:6-11` is built
on, and it is now measured rather than assumed.

---

## 2. What is readable in combat

All rows VERIFIED by the in-combat probe (`probeAtStart`, `inCombat = true`) unless noted.

### Readable

| Value | API | Evidence |
|---|---|---|
| Combo points | `UnitPower("player", ComboPoints)` | returned `3` |
| Combo point max | `UnitPowerMax("player", ComboPoints)` | returned `5` |
| Energy **max** | `UnitPowerMax("player", Energy)` | returned `100` |
| **Spell affordability** | `C_Spell.IsSpellUsable(id)` | returned `(true, false)` |
| **Spell energy cost** | `C_Spell.GetSpellPowerCost(id)` | returned `45` |
| Cooldown **readiness** | `C_Spell.GetSpellCooldown(id).isEnabled` / `.isActive` | `true` / `false` |
| Action bar contents | `GetActionInfo(slot)` | 63 readable, **0 secret, 0 raised** across 120 slots |
| Action button lookup | `C_ActionBar.FindSpellActionButtons(id)` | returned slot numbers |
| Blizzard's rotation pick | `C_AssistedCombat.GetNextCastSpell()` | returned `315584` |
| Assist availability | `C_AssistedCombat.IsAvailable()` | returned `true` (non-secret **here**; see §2.1) |
| `UnitPowerDisplayMod` | — | returned `1` |
| Build info | `GetBuildInfo()` | never secret — CORROBORATED |

The first two of these are the entire foundation of the interval model:
`IsSpellUsable` + `GetSpellPowerCost` are never-secret and answer in combat, so energy can
be bracketed from both sides without ever touching the hidden value.

### Not readable

| Value | API | In-combat result |
|---|---|---|
| **Energy** | `UnitPower("player", Energy)` | `SECRET` (also secret out of combat) |
| Haste | `GetHaste`, `UnitSpellHaste`, `GetMeleeHaste` | `SECRET` |
| Attack speed | `UnitAttackSpeed` | `SECRET` |
| **Energy regen rate** | `GetPowerRegenForPowerType`, `GetPowerRegen` | `SECRET` |
| Cooldown **timers** | `C_Spell.GetSpellCooldown(id).startTime` / `.duration` | `SECRET` |
| Auras by index | `C_UnitAuras.GetAuraDataByIndex("player", 1, "HELPFUL")` | **THREW** |

Out of combat, every one of these returned a plain value (haste `18.315`, regen `13.726`,
cooldown `startTime 0 / duration 0`, aura-by-index `OK`) — **except energy, which stays
secret**.

### 2.1 The finding that matters most

**`GetPowerRegenForPowerType` is SECRET in combat.** VERIFIED.

`EnergyModel.lua:145-161` is headed "THE CLIENT WILL JUST TELL YOU THE REGEN RATE" and
cites a live measurement of 13.7257. That measurement was taken **out of combat**. The
same block already hedges correctly — it routes through `readNum` and falls back — and
`refreshRegenBounds` therefore just never fires in a fight. So the code is safe, but the
comment overstates its reach, and anyone reading it would conclude the regen problem is
solved when in combat it is still solved entirely by `recordEdge`'s two-crossing solve.

The 12.0.5 patch notes confirm the cause: `SecretWhenUnitStatsRestricted` was added in
12.0.5 and applied to `GetHaste`, `UnitSpellHaste`, `UnitAttackSpeed`,
`GetPowerRegenForPowerType` and `GetPowerRegen` together. VERIFIED.

### 2.2 Widget laundering is closed

The recurring idea — feed a secret to a widget the client will happily render, read it
back out — does not work. Measured **in combat**:

| Channel | Setter | Getter |
|---|---|---|
| `Cooldown:SetCooldown` → `GetCooldownTimes` | **RAISED** | — |
| `StatusBar:SetValue` → `GetValue` | ACCEPTED | `SECRET` |
| `FontString:SetFormattedText` → `GetText` | ACCEPTED | `SECRET` |

**VERIFIED**, and independently **CORROBORATED** by the wiki's Secret Aspects table, which
documents this as designed behaviour: an aspect is applied to the widget when it accepts a
secret, and every getter tagged with that aspect then returns secrets. `BarValue` (0x4000)
covers `StatusBar:SetValue`/`GetValue`; `Text` (0x8) covers `FontString:SetText`/`GetText`;
`Cooldown` (0x8000) covers `Cooldown:SetCooldown`/`GetCooldownTimes`.

Stop re-testing this. The taint rides along with the value by design.

**Consequence for Tuono:** `Alpha` is also an aspect (0x80, `Region:SetAlpha` →
`GetAlpha`). `Display.lua` sets icon alpha from confidence. That is safe *only* because
confidence is derived from non-secret inputs. If a secret ever reaches `SetAlpha`, that
region's `GetAlpha` starts returning secrets. Keep secrets out of the render path.

---

## 3. The ToS line

### Unambiguously permitted

Displaying information the client already gives you, and suggesting an action. Blizzard
ships this capability itself: `C_AssistedCombat.GetNextCastSpell` is a public, documented
API added in 11.1.7 whose entire purpose is telling an addon which spell to recommend
next. An addon reading a public API and drawing an icon is doing what the API is for.
**VERIFIED** (API is documented on Warcraft Wiki, added 11.1.7).

Overlays, keybind hints, cooldown displays, and highlighting a button are all long-settled
practice and remain so.

### Unambiguously forbidden

Automating input. The addon may not press the button, simulate a hardware event, or
execute the action on the player's behalf. This is the line the entire secret-values
system exists to enforce, and Blizzard's public framing is explicit: Ion Hazzikostas
described automation addons as having become "mandatory", requiring raid tuning to assume
them, and the 12.0 restrictions as a deliberate correction. **CORROBORATED.**

Blizzard's own one-button assistant carries a built-in penalty (~25% of a GCD per press,
reported as a 15–20% DPS loss) precisely so that automation cannot beat manual play.
**CORROBORATED** (Wowhead, Massively OP, community testing). That penalty is the clearest
possible statement of intent: automation is permitted only in the form Blizzard ships,
and only at a cost.

### Genuinely grey

- **Suppressing or overriding Blizzard's pick.** Tuono renders its own rotation and never
  displays Blizzard's (`IntelligenceLayer.lua:84`). No API forbids this and no rule
  addresses it. **UNVERIFIED** as to Blizzard's opinion. It is very likely fine — the
  addon is a display, and the player still chooses — but nobody has ruled on it.
- **Being *better* than the assist.** The assist is "intentionally sub-optimal" (Ion
  Hazzikostas, **CORROBORATED**). An addon that closes that gap works against a stated
  design intent without breaking any stated rule. Blizzard's lever here is API access, not
  enforcement: the realistic risk is a future patch narrowing what is readable, not a
  suspension. Design for that risk (see §4).
- **Prediction depth.** Showing four steps ahead is more than Blizzard shows. No rule
  addresses lookahead. **UNVERIFIED.**

### Not applicable

Nothing in Tuono reads a protected value, hooks a hardware event, or executes an action.
There is no `/click`, no `SetAttribute` on a secure frame, no `RunMacro`. The one place it
touches a secure frame at all is anchoring an overlay to it, which is a read
(`Highlight.lua:227-246`).

---

## 4. Is shadowing a hidden resource legal?

This is the load-bearing premise of the product, so it deserves a real argument rather
than an assumption.

**The claim:** integrating your own estimate of energy forward from readable signals —
what you cast, what it costs, elapsed time, and never-secret affordability oracles — is
legal, even though the result approximates a value Blizzard chose to hide.

**The argument for:**

1. **No protected value is read.** Every input is independently readable:
   `UNIT_SPELLCAST_SUCCEEDED` carries a non-secret spellID; `GetSpellPowerCost` is static
   data; `GetTime` is never secret; `IsSpellUsable` is never secret and is *documented* as
   answering an affordability question. Nothing is decrypted, unwrapped, or laundered.
2. **The secret-values system is a capability boundary, and it is being respected.** The
   mechanism Blizzard built permits exactly this: it lets addons hold and pass secrets,
   and it errors on inspection. Tuono never inspects. It is inside the fence.
3. **Blizzard published the oracle.** `C_Spell.IsSpellUsable` returning
   `insufficientPower` is Blizzard telling an addon "you cannot afford this". That is a
   deliberate, non-secret answer to a resource question. Bracketing from a published
   oracle is using the API as designed.
4. **A human does the same thing.** A player watching their own bar and counting their own
   casts is estimating the same quantity from the same signals. Nothing here exceeds what
   the client presents to the human.

**The argument against, stated honestly:**

The *intent* of hiding energy was plainly to stop addons from making resource-gated
combat decisions. Reconstructing it to make resource-gated combat decisions defeats that
intent, even if it breaks no rule. If Blizzard cared to close it, they could — by making
`IsSpellUsable` secret in combat, which would collapse the interval to `[0, max]` and
degrade Tuono to cooldown-driven logic.

**Verdict:** legal on every rule that exists, and squarely against the spirit of one that
does not. **This is an inference, not a ruling — UNVERIFIED.** No Blizzard statement
addresses resource reconstruction specifically; I looked and did not find one.

**The engineering consequence is more useful than the legal one.** The model is already
built so that the answer does not matter much: nothing branches on *which* values are
hidden. Starve it of observations and the interval widens to `[0, max]`, every
affordability question answers "maybe", and the rotation degrades to cooldown-driven logic
on its own (`EnergyModel.lua:291-305`). If Blizzard closes `IsSpellUsable` tomorrow, Tuono
gets worse, not broken. That property is the actual insurance policy, and it should be
protected in every future design decision.

**Do not**: attempt to defeat secrecy (widget laundering, taint-washing through another
addon, comparing secrets indirectly). Those cross from "using the API" to "circumventing
the mechanism", and the difference is the whole case above.

---

## Sources

- [Secret Values — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Secret_Values)
- [Patch 12.0.5 API changes — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.0.5/API_changes)
- [C_AssistedCombat.GetNextCastSpell — Warcraft Wiki](https://warcraft.wiki.gg/wiki/API_C_AssistedCombat.GetNextCastSpell)
- [WoW previews rotational assistance UI, nixes automating addons — Massively OP](https://massivelyop.com/2025/05/01/world-of-warcraft-previews-new-rotational-assistance-ui-tool-nixes-some-automating-addons/)
- [Estimated DPS loss with Highlight Assist and One-Button — Wowhead](https://www.wowhead.com/news/estimated-dps-loss-with-highlight-assist-and-one-button-rotation-in-patch-11-1-7-377287)
- Primary: `TuonoDiagDB` flight recording, client 12.1.0.69273, captured 2026-08-12.
