# Architecture Review — Tuono

**Date:** 2026-08-17
**Reviewed at:** working tree on top of `be2569d`
**Method:** full read of the addon, plus offline reproduction against `tests/harness.lua`.
Every CONFIRMED finding below was executed, not inferred. Scratch reproductions were run
from the system temp scratchpad and are not checked in.

The engine is good. The sensing layer is genuinely novel. The defects below are almost
all one bug wearing different hats, and the codebase has already named it in its own
`CLAUDE.md`: **unknown is never "no"** — plus its mirror, **a guard applied to one copy of
duplicated logic and not the other**. The Roll the Bones stage guard now exists in five
places in this repo. Two of them have it.

---

## Severity summary

| # | Sev | Where | One line |
|---|---|---|---|
| A1 | **CRITICAL** | `CooldownModel.lua:216` | An unobserved cooldown is pinned at "1 second remaining" forever, and the forward simulation then advertises a 180s cooldown as the next button, at `certain` confidence. |
| A2 | **HIGH** | `UserRules.lua:109` | The compiled `rtbStage` condition has no `stageKnown` guard. The reroll-a-Jackpot bug returns in full the moment a user opens the rotation editor. |
| A3 | **HIGH** | `UserRules.lua:206` | `GetRows` writes on read. Merely *opening* the editor permanently forks the user off the built-in profile, so they silently stop receiving rotation fixes. |
| A4 | **HIGH** | `data/rules.lua:290`, `IntelligenceLayer.lua:228` | A fifth and sixth copy of the unguarded `rtb.stage == 0` test, both reachable, both able to append a Roll the Bones icon while a real buff is up. |
| B1 | MED | `StateTracker.lua:693` | An unreadable `UnitCanAttack` silently drops the unit from the enemy count while the count is still published as *known*. |
| B2 | MED | `StateTracker.lua:706` | The threat "engagement" filter does not filter. `engaged` is only ever false on a read failure; a `nil` threat passes. The comment claims the opposite. |
| B3 | MED | `UserRules.lua:105` | `enemyCount` applies no known/unknown asymmetry, so an unprovable *upper* bound fails closed. `cp` next to it gets this right. |
| B4 | MED | `StateTracker.lua:519,570` | The legacy Roll the Bones name scan writes `stage` without writing `stageKnown`, so an unverified `TODO` name list can promote a guess to a known stage. |
| B5 | MED | `EnergyModel.lua:790` | A long gap (loading screen, alt-tab, `/reload`) marks confidence unknown but leaves the energy *interval* untouched and seeded. Stale bounds survive a zone change. |
| B6 | MED | `EnergyModel.lua:844` | A missed Opportunity proc makes a free Pistol Shot debit 40 and assert `energy >= 40`. A lower bound above truth is the one unsound direction. Self-heals, but only via the contradiction path. |
| C1 | LOW | `StateTracker.lua:1082,1089` | `RefreshKnownSpells` — ~13 spells x ~5 pcalls — is wired to `SPELLS_CHANGED` and `UPDATE_STEALTH`, both of which fire constantly for a Rogue. |
| C2 | LOW | `IntelligenceLayer.lua:155` | ~10 permanently inert `PIN`/`PREFER` rules are still `pcall`-evaluated every tick. |
| C3 | LOW | `Display.lua` / `Highlight.lua` | `CurrentMainBarSlot` and the slot→binding mapping are copy-pasted. This is the exact shape that produced A2/A4. |

---

## A1 — CRITICAL: an unobserved cooldown reads as "1 second away", forever

**`CooldownModel.lua:201-218`**

```lua
local s = started[key]
if not s or (s.at + s.duration) - GetTime() <= 0 then
    started[key] = { at = GetTime(), duration = 1, inferred = true }
end
```

`Reconcile` is called from `NormalizeCooldown` on **every** `RefreshCooldowns`, i.e. every
tick, whenever the never-secret booleans say "not ready". When the model has no record of
the cast, it re-arms with `at = GetTime()` and `duration = 1` — *every tick*. The remainder
is therefore pinned at ~1.0s and never counts down. It is not a decaying estimate; it is a
permanent claim that a cooldown is about to come up.

Verified — the model does not converge:

```
t=1000.0  Reconcile#1 -> remaining=1 known=true inferred=true
t=1010.0  Reconcile#2 -> remaining=1 known=true inferred=true
t=1040.0  Reconcile#5 -> remaining=1 known=true inferred=true
```

Verified through the real path, with secret timers and `isActive = true` (the Midnight
in-combat shape) — three ticks, five seconds apart:

```
tick 1 -> known=true ready=false remaining=1.00 remainingKnown=false
tick 3 -> known=true ready=false remaining=1.00 remainingKnown=false
```

`remainingKnown=false` correctly stops **Display** drawing the number. It does not stop the
**simulator**, which reads `remaining` directly. `Rotation.Predict` decrements cooldowns by
one GCD per simulated step (`Rotation.lua`, the `ability.gcd` block), so a 1-second
remainder becomes *ready* at step 2:

```
step 1 -> spell 193315  (Sinister Strike to build)   conf=certain
step 2 -> spell 13750   (Adrenaline Rush at low CP)  conf=certain
```

**Failure scenario.** Player `/reload`s mid-fight, or logs in during combat, having cast
Adrenaline Rush 5 seconds earlier. `CooldownModel` has no record. The client says
not-ready. From the next tick onward the bar's second icon is Adrenaline Rush — a
175-second wait — rendered **solid**, because `inputConfidence` rates `cdReady` as
`certain` whenever `cd.known` is true, and the placeholder sets `known = true`.

This is the worst available failure mode: confidently wrong. The engine-level castability
filter in `IntelligenceLayer.lua:318` only applies to position 1, and its own comment
explains why later steps are deliberately exempt.

**Fix.** `inferred` must mean "unknown remainder", not "1 second". Either return
`(nil, false)` from `Predict` for an inferred entry so `NormalizeCooldown` falls through to
`remaining = 0, remainingKnown = false`, or seed the placeholder from the profile's static
`ability.cd` — the honest floor for a cooldown we know is running but never saw start. Also
stop re-arming: `Reconcile` should arm once and leave `at` alone while the client keeps
saying not-ready, or the remainder can never decay. The simulator additionally should not
treat an `inferred` cooldown as becoming ready inside the lookahead window at all.

---

## A2 — HIGH: the editor reintroduces the reroll-a-Jackpot bug

**`UserRules.lua:109-113`**

```lua
elseif ctype == "rtbStage" then
    return function(S)
        local stage = (S.buffs and S.buffs.rtb and S.buffs.rtb.stage) or 0
        return compare(cond.op, stage, cond.value or 0)
    end
```

No `stageKnown` check. `stage` reads 0 both when there is no Roll the Bones buff and when
the aura layer cannot see one — the precise conflation the profile was just fixed for.

This is not a dormant path. `U.RowsFromProfile` seeds editable rows *from the built-in
profile*, including its `conditions` metadata. Once rows exist, `U.EffectivePriority`
returns **compiled** rules built from that data, and the profile's hand-written `when`
closure — the one carrying the fix — is never called again.

Verified side by side, with `stage = 0, stageKnown = false`:

```
COMPILED rule fires on unknown stage: true
BUILT-IN rule fires on unknown stage: false
```

**Failure scenario.** Player opens the rotation editor once, ever. In a keystone, where
`stageKnown` is false for the great majority of ticks (a live trace measured 27% readable),
Roll the Bones is recommended on cooldown regardless of the buff actually up — rerolling a
Jackpot every 45 seconds, which the profile comments call the most damaging thing this
addon has ever done.

**Fix.** The fix belongs in `compileCondition`, not in a third hand-written guard. Route it
through the helpers that already exist: `Tuono.RuleHelpers.rtbStageBelow` /
`rtbStageAtLeast`, selecting by operator, and fail closed for every operator when the stage
is unknown — both directions spend a cooldown, so both are positive claims.

---

## A3 — HIGH: opening the editor silently and permanently forks the profile

**`UserRules.lua:206-213`**

```lua
function U.GetRows(profile, kind)
  local s = store(profile.id)
  local key = storeKey(kind)
  if not s[key] then
    s[key] = U.RowsFromProfile(profile, kind)   -- write, on a read
  end
  return s[key]
end
```

`IsCustomised` is defined as "a stored list exists", and `GetRows` creates one. Verified:

```
IsCustomised before GetRows: false
IsCustomised after  GetRows: true
```

**Failure scenario.** A user opens the rotation editor to look at it, changes nothing, and
closes it. They are now permanently pinned to a frozen snapshot of the 2.2.1 priority list.
Every future rotation fix, spell-ID correction and patch-day APL update ships to everyone
except them, with no indication anything happened. For a product whose whole maintenance
story is "we keep the APL current", this quietly breaks the value proposition for exactly
the users engaged enough to open the editor.

It also makes A2 reachable by inspection rather than by intent.

**Fix.** Separate *materialise for display* from *adopt as custom*. `GetRows` should return
a copy without storing; only an actual edit (`AddRow`/`MoveRow`/`DeleteRow`/a condition
change) should call `store`. Additionally, stored rows need a `schemaVersion` and the
originating profile version, so an update can offer a diff-and-merge instead of silently
diverging forever.

---

## A4 — HIGH: two more unguarded `rtb.stage == 0` tests, both live

**`data/rules.lua:283-293`**

```lua
name = "roll_the_bones_open",
action = "ADVISE", kind = "rtb",
when = function(S, A)
  return S.buffs.rtb.stage == 0 and not (S.buffs.rtb.expires > 0)
end,
```

**`IntelligenceLayer.lua:226-238`**

```lua
elseif rule.kind == "rtb" then
  if S.buffs.rtb.stage == 0 then
    local rtbEntry = { spellID = Tuono.SpellIDs.rollTheBones, ... }
```

`ADVISE` rules are *not* inert — only `PIN`/`PREFER` are. This pair appends a Roll the Bones
icon to the queue whenever `stage == 0`, with no `stageKnown` test in either the rule or the
handler.

**Failure scenario.** A roll lands that the learner cannot identify, so
`Observers.rtbUnknownPresent` is set and `ResolveRtbStage` returns `(0, false)`.
`StateTracker` correctly leaves `stageKnown = false`. `stage` is still 0. The profile rule
now correctly declines — and this advisory path appends a Roll the Bones icon anyway. The
player is told to reroll a buff the addon has explicitly concluded it cannot see.

Note that `rtb_reroll_stage3` immediately below it (`data/rules.lua:164`) *does* carry the
guard, with a comment explaining why. Same file, same concern, one guarded and one not.

**Fix.** Guard both. Better: this is the strongest argument in the review for collapsing
`Tuono.Rules` into the profile schema (see *Architectural debt*). Six copies of one
predicate is not a guard, it is a lottery.

---

## B1 — Enemy count drops unreadable units but still reports itself known

**`StateTracker.lua:689-694`**

```lua
local attackable = true
if _G.UnitCanAttack then
    local okA, res = pcall(_G.UnitCanAttack, "player", token)
    local b, known = Tuono.readBool(okA and res)
    attackable = known and b or false
end
```

`known == false` yields `attackable = false`, so the unit is excluded. That is
unknown-as-no. The damage is compounded downstream: only *threat*-unreadable units
increment `poisoned`, so the `poisoned == considered` check at line 724 never fires for
this case, and the addon publishes `enemyCount = N, enemyCountKnown = true` for a count it
knows is incomplete.

**Failure scenario.** Three of five nameplates return a secret from `UnitCanAttack`.
`enemyCount` is published as 2 with `enemyCountKnown = true`. With `aoeThreshold = 2` this
is a coin flip on the correct rotation; at a threshold of 3 it silently runs single-target
in a pack. Worse, `ResolveMode` (`Rotation.lua`) treats a non-nil count as authoritative
and will not fall back to Blizzard's cleave signal, because that fallback only runs when
`count == nil`.

**Fix.** Count unreadable-attackability units into `poisoned` too, and treat any poisoned
fraction as making the count a *lower bound* rather than a measurement — publish
`enemyCountAtLeast` alongside, or set `enemyCountKnown = false` once poisoned exceeds a
small threshold.

---

## B2 — The threat filter does not filter

**`StateTracker.lua:706-714`**

```lua
local engaged = true
local okT, threat = pcall(UnitThreatSituation, "player", token)
if not okT then
    poisoned = poisoned + 1
    engaged = false
elseif isSecret(threat) then
    poisoned = poisoned + 1
    engaged = false
end
```

The *value* of `threat` is never examined. `UnitThreatSituation` returns `nil` for a unit
you have no threat relationship with — the common case for a mob you have not hit — and
`nil` is neither a pcall failure nor secret, so `engaged` stays `true`. `engaged` is false
only when the read *fails*.

The comment two lines above states the intended semantics: "a unit we have no threat
relationship with is usually not one we are fighting". The code does not implement it.

This is a comment/code divergence rather than a crash, and the current fail-open behaviour
is arguably the safer of the two. But it is load-bearing for the count and reads as
implemented. Either implement it (`engaged = threat ~= nil`, accepting that it will drop
freshly-pulled adds) or delete the claim.

---

## B3 — `enemyCount` conditions fail closed in both directions

**`UserRules.lua:102-107`**

The file's own header states the convention: "an unprovable 'at least' fails, an unprovable
'at most' passes". `cp` implements it (line 66-68). `enemyCount` does not — it returns
`false` for every operator when the count is nil.

Verified, same unreadable-count state, two conditions:

```
'enemies <= 1' with an unreadable count fires: false     <- should pass
'combo points <= 1' with unreadable CP fires:  true      <- correct
```

**Failure scenario.** A user writes the natural single-target guard `enemies <= 1` on their
opener. Nameplates go unreadable for a moment. The rule stops firing, and their opener
silently drops out of the priority list until the count comes back.

**Fix.** Mirror the `cp` branch: `return (cond.op == "<" or cond.op == "<=")` when
`S.enemyCount == nil`.

---

## B4 — The legacy name scan promotes a guess to a known stage

**`StateTracker.lua:513-523` and `565-574`**

```lua
if auraName == buffName and auraSpellId ~= Tuono.SpellIDs.rollTheBones then
    table.insert(Tuono.State.buffs.rtb.names, buffName)
    Tuono.State.buffs.rtb.stage = 1
    Tuono.State.buffs.degraded = true
end
```

`stage` is written; `stageKnown` is not. The scan therefore inherits whatever `stageKnown`
some earlier code path left behind — and `RefreshFast`'s absence proof (line 935-942) sets
`stageKnown = true` with `stage = 0` on the tick before. Net effect: `stage = 1,
stageKnown = true`, asserted from a name match.

Verified — one aura named `Broadside` on the player, nothing else:

```
stage=1 stageKnown=true degraded=true names=1
```

The matched names come from `Tuono.RTB_BUFF_NAMES` (`StateTracker.lua:9-17`), all seven of
which still carry `-- TODO(M0): verify names` and are the *pre-Midnight* Roll the Bones
sub-buffs. `profiles/OutlawRogue.lua` documents that 12.x applies one summary aura instead,
whose identity is the stage. If any of those legacy names still exists on the player for
any reason, the addon claims a known stage 1 and the reroll rule fires.

**Fix.** The legacy scan must set `stageKnown = false` (presence without identity), or be
deleted outright now that `Observers.ResolveRtbStage` and the learner exist. Deleting is
better: it is an unverified name list guessing at a mechanic that changed expansion.

---

## B5 — The energy interval survives a loading screen unchanged

**`EnergyModel.lua:786-819`**

```lua
if hadSeed and last > 0 then
    local dt = now - last
    if dt > 5 then
        E.confidence = "unknown"        -- point estimate only
    elseif dt > 0 then ... end
end
...
if last > 0 then
    local dt = now - last
    if dt > 0 and dt <= 5 then widen(dt) end     -- interval NOT touched when dt > 5
end
```

A gap longer than 5 seconds degrades the legacy *point* estimate but leaves `E.lo`, `E.hi`
and `intervalSeeded` exactly as they were. `Rotation.AffordState` reads the interval, not
the point estimate, so the stale bounds are what the rotation actually uses.

**Failure scenario.** Player is at 15 energy, zones into a dungeon (40-second loading
screen), and arrives at full. `E.lo/E.hi` still describe 15. `PLAYER_ENTERING_WORLD` calls
`TrySync`, which cannot collapse the interval because energy is unconditionally secret. For
up to `BRACKET_MIN_INTERVAL` plus however long it takes an ability to constrain a bound, the
engine believes the player is broke and the priority list degrades to whatever is free.

**Fix.** On `dt > 5`, reset the interval to full uncertainty (`E.lo, E.hi = 0, E.max`)
rather than leaving it seeded. Widest-possible is always sound; stale is not. Same treatment
on `PLAYER_ENTERING_WORLD` and on spec change, and clear `lastUsable` so a stale
insufficient-power sample cannot manufacture a false crossing edge.

---

## B6 — A missed Opportunity proc puts the lower bound above the truth

**`EnergyModel.lua:842-853`**

```lua
if spellID == pistolShot then
    local opp = Tuono.State and ... .opportunity
    if opp and opp.up then cost = 0 end
end
intersect(cost, nil)     -- asserts energy >= cost
debit(cost)
```

The lower bound is asserted from *our belief* about Opportunity, not from an observation.
`opportunity.up` is driven by the spell-activation overlay (`Observers.lua:45`), and the
overlay only fires for spells **on an action bar** — a residual risk the codebase notes
elsewhere. A player who casts Pistol Shot via macro or click, with the spell unbarred, gets
`opp.up == false` while the proc is genuinely active.

**Failure scenario.** True energy 10. Opportunity is up but unobserved. Player casts the
free Pistol Shot. `OnCast` asserts `energy >= 40` and raises `E.lo` to 40. The interval's
lower bound is now above the truth — which `EnergyModel.lua:363` itself identifies as "the
one error that breaks soundness permanently".

In practice it is *not* permanent: the next `Observe` finds `insufficientPower` on a cheap
ability, `intersect` detects `E.lo > E.hi`, and the contradiction branch (line 410-413)
resets around the fresh observation. So the real exposure is a bounded window of up to
`BRACKET_MIN_INTERVAL` (0.25s) plus one tick, during which `AffordState` returns `yes` for
abilities the player cannot cast.

Worth stating plainly because the module's own documentation claims the interval "can never
be wrong, only wide". That is true of every bound derived from an observation, and false of
this one, which is derived from an inference. **Fix:** when the proc state is not
`fromOverlay`-backed, treat the cost as *unknown* — skip the `intersect` entirely and debit
the pessimistic (full) cost only from the upper bound. Never assert a lower bound from a
belief.

---

## C1 — `RefreshKnownSpells` is wired to two of the spammiest events in the game

**`StateTracker.lua:1077-1090`**

`OnTalentChange` → `RefreshKnownSpells`, which walks `Tuono.SpellIDs` (13 entries) and per
entry runs up to three `pcall`'d known-spell probes plus two override resolutions (each
1-2 more `pcall`s) — order 60-100 protected calls, plus a `wipe` of `knownSpells`.

It is registered on `SPELLS_CHANGED` (line 1082) and `UPDATE_STEALTH` (line 1089).
`SPELLS_CHANGED` is well known to fire in bursts for unrelated reasons, and `UPDATE_STEALTH`
fires on every stealth transition — for a Rogue, every Ambush opener, every Vanish, every
Shadowmeld. During the wipe-then-repopulate window, `knownSpells` is empty, and
`buildActivePriorityList` (`Rotation.lua`) reads `knownSpells[reqID] ~= false`, which is
true for `nil`, so it fails open. No correctness bug — but it is real work at a bad moment.

**Fix.** Coalesce: set a dirty flag and rebuild at most once per 0.5s from the existing tick
loop, rather than synchronously inside the event handler.

## C2 — Ten inert rules evaluated every tick

`IntelligenceLayer.lua:155-198` iterates all of `Tuono.Rules` and `Tuono.safe`s each `when`.
Ten of the twenty-odd rules in `data/rules.lua` are `PIN`/`PREFER`, which the handler
deliberately ignores. That is ten closure calls inside ten `pcall`s per tick, at 10-30Hz,
to produce a value that is discarded by design.

## C3 — The duplication that produces this whole class of bug

`Display.lua` and `Highlight.lua` each carry their own `CurrentMainBarSlot` and their own
slot→binding/frame mapping, with a comment in `Highlight.lua:29` explaining that the
duplication is deliberate "to keep Display/Highlight decoupled". The two mappings already
differ: `Display` maps slots 1-108 to binding *names* and `Highlight` maps 1-108 to frame
names, but `Display.bindingNameForSlot` handles 97-108 while `GetActionButtonFrameName`
rejects `slot > 108` — and neither covers 109-120, which `GetActionSlotForSpell` will
happily return from its 1..120 index sweep. A spell on bar 8 resolves to a slot and then to
no frame, silently.

That is the same failure shape as A2 and A4: two copies, one updated. Decoupling is not
worth this; extract a shared `Tuono.ActionBars` module.

---

## Soundness of the energy model — verdict

The interval construction is correct and the two-crossing regen solve is a genuinely good
idea. The claim "can never be wrong, only wide" holds for every bound that comes from an
*observation* (`IsSpellUsable`, a successful cast, an out-of-power error). It does not hold
for the two places a bound is derived from an *inference*:

1. **B6** — the Opportunity free-cast assumption raises `E.lo` from a belief.
2. **B5** — a long gap leaves the interval asserting bounds for a world that no longer
   exists.

Both are recoverable, neither is permanent, and both are fixable by refusing to assert
rather than by adding cleverness. The correct invariant to enforce and test is: *no code
path may raise `E.lo` except from a never-secret observation.* That is one grep and one
test away from being a guarantee rather than a convention.

Two smaller notes:

- `refreshRegenBounds` (`EnergyModel.lua:363-379`) only ever tightens. A haste proc raises
  true regen, `E.regenHi` cannot follow, and `widen` then under-grows the upper bound
  producing false `no` answers. `recordEdge` can raise it again, so it is self-correcting
  only while crossings keep happening. Give the bounds a slow decay back toward the prior.
- `E.max` is refreshed inside `TrySync`, which is only called from `Advance` and combat
  boundaries. Adrenaline Rush raises max energy; the interval cap follows on the next tick.
  Acceptable, but worth an explicit test.

---

## Architectural debt

**Two rule schemas, one half-dead.** `Tuono.Rules` (`data/rules.lua`) and the profile
priority lists express overlapping intent in incompatible shapes. `PIN`/`PREFER` are inert
by decision; `ADVISE` is not, and A4 shows that the surviving half still carries defects the
profile half has already fixed. The cost is not the wasted `pcall`s — it is that a reader
cannot tell which file governs behaviour, and a fix applied to one does not reach the other.
**Recommendation:** move the three genuinely distinct advisory kinds (`cooldown`, `trinket`,
`rtb`) into the profile as a declared `advisories` list with the same condition vocabulary
`UserRules` already compiles, and delete `Tuono.Rules` entirely. One vocabulary, one
compiler, one place to guard.

**`Engine.Evaluate` does five jobs.** Predict, merge advisories, dedup, castability-filter,
confidence-truncate — 340 lines, one function, five reusable-table caches at module scope
(`resultQueue`, `resultAdvisories`, `tempDedup`, `queueSet`, `dedupQueue`) that must be
wiped in the right order at the top. `rebuildQueueSet` is called from inside the merge loop
and rescans the whole queue each time. Splitting this into `predict → decorate → filter →
truncate`, each taking and returning a list, would make the truncation policy testable in
isolation — which matters now, because that policy is the thing about to be changed for the
smoothing work.

**The returned tables are shared mutable state.** `Evaluate` returns `resultQueue` itself,
not a copy, and the next call wipes it in place. Any consumer that holds the result across
a tick — a smoothing layer that wants to compare this tick to the last one, precisely what
is being built — sees its "previous" value mutate underneath it. This will bite the
commitment work directly. `harness.runTicks` already has to snapshot `queueIDs` per frame
for this reason.

---

## Taint and security — verdict

**`Highlight.lua`'s claim holds.** The overlay frames are created with `CreateFrame("Frame",
nil, UIParent)` and positioned with `f:SetAllPoints(buttonFrame)`. `SetPoint` writes to
*our* frame and only reads the secure one; that is what every unit-frame and button-glow
addon does and it does not taint the target. Parenting to `UIParent` rather than to the
button is correct and deliberate, and the comment at `Highlight.lua:226-246` accurately
describes the bug it replaced.

Two residual notes, neither a taint issue:

- `ShowGlow` treats only an explicit `IsVisible() == false` as hidden, correctly refusing to
  read `nil` as "hidden". Good.
- The pool is 4 frames but only one glow is ever active (`lastHighlightedButton` is a
  scalar). If the numbered-badge lookahead lands, that becomes N-of-4; the pool will need to
  grow with `iconCount`, which can reach 8.

Nothing in the addon calls a protected function, hooks a secure handler, or writes to a
Blizzard frame. `Recorder.lua`'s widget read-back probe creates its own frames and `pcall`s
every setter.

---

## Testability — what the harness still cannot reach

The offline harness is a large step forward. What it cannot see today:

1. **`if secretValue then` does not raise.** `tests/wow_stub.lua` documents this: Lua has no
   `__tobool`, so a boolean test on a stub secret passes offline and throws in game. This is
   the single highest-value gap, because it is exactly the shape of the two worst bugs in the
   addon's history (`IsAvailable()` in `AssistReader`, `isFullUpdate` in `StateTracker`). A
   static lint is the only way to close it. *(A concurrent agent is building
   `tests/lint_secrets.lua` for this.)*
2. **`secret == number` returns false rather than raising**, same root cause.
3. **The stub's `GetSpellCooldown` returns no `isActive`/`isOnGCD`**, so the entire degraded
   cooldown path — which is where A1 lives — is unreachable without monkeypatching, as this
   review had to do. The stub should model the in-combat shape natively and let a test flip
   `stub.state.secret.cooldowns`.
4. **Frame geometry and draw order are unmodelled.** `SetPoint` is a no-op, so nothing can
   catch a rail drawn outside its parent or two sweeps fighting over one widget.
5. **No time-dilation harness for the tick throttle.** `stub.Tick` advances real time, but
   the interaction between `forceNext`, `MIN_FORCED_GAP` and the 0.1s combat interval is
   where the churn complaint actually lives, and no test drives it.
6. **`Observers`' learner is untestable** without an aura-index sequence that changes
   between two snapshots; the stub has `addAura` but no scripted timeline.

---

## Opinions (no failure scenario; judgement calls)

- **`Tuono.RTB_BUFF_NAMES` should be deleted, not fixed.** Seven strings carrying
  `TODO(M0): verify names` since the ancestor project, describing a mechanic that changed
  expansion, feeding a scan that marks its own output degraded. It cannot be right and it
  can be wrong (B4).
- **`Config.HandleReset` destroys custom priority lists with no confirmation.** `TuonoDB = {}`
  wipes `db.profiles`. For a user who has spent an hour in the editor, `/tuono reset` to fix
  a bar position is unrecoverable. Reset display settings and rotation edits separately.
- **`## Interface: 120005, 120007, 120100`** is a three-version comma list. The ancestor
  project's `toc_check.lua` asserted a *single* number and `STATE.md:95` still lists that as
  the intended check; the shipped `tests/toc_check.lua` only asserts one `## Interface:`
  line. Multi-version TOC lists are legal in modern clients (UNVERIFIED for 12.x
  specifically), so the shipped check is probably the right one — but the divergence from the
  stated plan should be resolved deliberately rather than left as drift.
- **`CM.Predict` mutates `started`** (deletes expired entries). A function named `Predict`
  with a side effect will eventually surprise someone; move the eviction to `NoteTick`.
- **`Tuono.db.activeProfile` is read by `Profiles.lua:217` but never written** by
  `P.Activate`. Manual profile selection therefore cannot persist across a reload today.
  Harmless while there is one profile; a bug the moment there are two.
