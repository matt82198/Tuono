# HEKILI

What Hekili actually does, read from source, and what Tuono should take from it.

Tuono is named after Hekili (*tuono* = thunder in Italian, *hekili* = thunder in Hawaiian).
Hekili was an addon on top of an API Midnight removed. Tuono replaces that API with a
model. This document exists because the model is now good and the **presentation of it is
still reactive**, and Hekili solved presentation a decade ago.

All line references are to the source cloned at `/tmp/hekili` (`Core.lua` 2317 lines,
`State.lua` 8099, `UI.lua` 3201). Verified by reading, not recalled.

---

## 0. Licence — read this first

**There is no licence file in the Hekili repository.** No `LICENSE`, `COPYING`, or legal
file at root; no licence line in `Hekili.toc` (which carries `## Interface`, `## Version`,
`## Title`, `## Author`, `## Notes`, `## SavedVariables`, `## OptionalDeps` and three
distribution IDs, and nothing else); no copyright notice in `README.md`.

Absent an explicit grant, the default is **all rights reserved**. The practical rule:

- **Permitted:** reading it, and reimplementing the *ideas* — a timeline model, an event
  queue, abilities-as-data. Architecture and algorithms are not copyrightable.
- **Not permitted:** copying code, or transcribing a function and renaming the locals. A
  distinctive comment or an unusual expression carried across is evidence of copying.

Everything below is described so it can be **reimplemented from the description**. Nothing
in this document should be pasted into Tuono.

---

## 1. The timeline model

This is the single biggest architectural gap in Tuono, and the direct answer to "too
reactive rather than predictive".

### The clock

`State.lua:2174` defines the whole thing in one line:

```
query_time = now + offset + delay
```

- **`now`** — real `GetTime()` at the start of the pass. Fixed for the whole computation.
- **`offset`** — how far the *simulation* has advanced past `now`. Moved only by
  `state.advance()`.
- **`delay`** — how far past `offset` the currently-considered action is being evaluated.
  Set per candidate, and reset constantly.

Every state query in the engine — cooldown remains, buff remains, resource amount —
resolves against `query_time`, not against `now`. `State.lua:605` is representative:
`return max( 0, t.expires - state.query_time )`. So the *same* state table answers "is
this buff up?" differently depending on where the clock is, and the APL is evaluated in
the simulated future without any code in the APL knowing that.

Tuono's equivalent is `S.simNow`, added recently for buff expiry, but it is only consumed
by expiry checks. Cooldown readiness, affordability and buff presence are still answered
for *now*. That is the difference between a simulation and a recomputation.

### `state.advance( time )` — State.lua:7174

Order of operations inside a single advance:

1. Zero `state.delay` (the delay has been consumed by moving the clock).
2. Fire any queued events whose `time` falls inside the window `[query_time, query_time +
   time]`, each handled with `offset` temporarily set to that event's moment so handlers
   see the correct clock (7196–7217). Capped at 10 events per advance.
3. Regenerate every resource by `regen * time` (7226–7243).
4. `state.offset = state.offset + time`.

Two details worth stealing. Events fire **during** the advance at their own timestamps,
not at the end — so a cooldown that comes up mid-window is up for the rest of the window.
And the event loop has a hard iteration cap, because a mis-modelled ability can otherwise
queue events forever.

### `TimeToReady` — State.lua:7831

The mechanism that makes prediction possible. For a candidate ability it returns **when it
will be usable**, as the maximum of every constraint:

- its own cooldown remaining
- the global cooldown remaining, unless the ability is off-GCD or flagged
  interrupt/defensive
- remaining cast/channel time, if not dual-castable
- **`resource.time_to_X`** — the forecast time until the resource reaches the cost

The last one is the important one. Hekili does not ask "can I afford this?"; it asks
"**when** can I afford this?" and gets a number.

### The APL walk uses it — Core.lua:895–897

```
wait_time = state:TimeToReady()
clash     = state.ClashOffset()
state.delay = wait_time
```

For each entry in the priority list, the engine sets the clock forward to the moment that
entry becomes ready, and *then* evaluates its condition. An entry that will be ready in
0.4s and whose condition holds at that moment beats an entry that is ready now but whose
condition does not. The winner is the entry with the lowest `wait` that passes.

**This is what "predictive" means and Tuono does not do it.** `Rotation.Predict` walks the
priority list asking `canAfford` and `cdOf(...).ready` — both strictly present-tense — and
only pools (advances a whole GCD at a time, up to three) when *nothing* matched. Hekili
pools with sub-second precision per candidate, as a first-class part of selection.

### What a recommendation carries — Core.lua:2015–2018

```
slot.time       = state.offset + wait
slot.exact_time = state.now + state.offset + wait
slot.delay      = i > 1 and wait or ( state.offset + wait )
slot.since      = i > 1 and slot.time - Queue[ i - 1 ].time or 0
```

Four distinct quantities:

| Field | Meaning |
|---|---|
| `time` | seconds from the start of this pass |
| `exact_time` | absolute `GetTime()` at which to press |
| `delay` | for slot 1, time until you should press; for later slots, wait beyond the previous |
| `since` | gap between this recommendation and the previous one |

Tuono's queue entries carry `spellID`, `confidence`, `source`, `step`, `isSequence`. There
is **no time on any of them.** Position is ordinal only, which is why the bar can only say
"next" and never "in 0.6s".

### Between slots — Core.lua:2048

```
if state.delay > 0 then state.advance( state.delay ) end
```

Then the per-slot effects (§2), then the loop continues to slot `i+1`. The queue is
therefore a genuine forward simulation with a moving clock, and each icon is a snapshot of
a different moment.

---

## 2. Per-slot order of operations — Core.lua:2050–2118

After an action is chosen for slot `i`, and only when `i < display.numIcons`:

1. Record `state.this_action` / `state.this_list`.
2. `state.advance( state.delay )` — move to the moment of the cast.
3. If the ability is on the GCD and the GCD is currently free, start it:
   `state.setCooldown( "global_cooldown", state.gcd.execute )`.
4. Clear the casting buff unless the ability is dual-cast.
5. Branch on cast time:
   - **`cast > 0`, not channelled** — apply a `casting` buff and `QueueEvent(…,
     "CAST_FINISH")`. Note what does **not** happen here: the cooldown is not set and
     resources are not spent. Both are deferred to the event.
   - **`cast > 0`, channelled** — spend charges or set the cooldown *immediately*, queue
     `CHANNEL_FINISH`, queue one `CHANNEL_TICK` per `tick_time`, then `RunHandler` and
     `spendResources` now.
   - **instant** — spend charges or set cooldown, `spendResources`, `RunHandler`.
6. If `isProjectile`, queue `PROJECTILE_IMPACT` at `query_time + cast`.
7. Trinket shared-cooldown bookkeeping.

The distinction in step 5 is the entire reason the event queue exists: **a hardcast's
effects land when the cast finishes, not when it starts.** Tuono models only instants, so
it has no equivalent problem *yet* — Outlaw is entirely instant — but any spec with a cast
time or a channel needs this before it can be supported.

---

## 3. The event queue

`state:QueueEvent( action, start, time, type, target, real )` — State.lua:6259. Two
queues: a **real** one (things that actually happened) and a **virtual** one (things the
simulation predicts). Events are inserted and the queue re-sorted by time.

Default timings when `time` is omitted (6265–6279):

- `CAST_FINISH` / `CHANNEL_FINISH` → `start + ability.cast`
- `PROJECTILE_IMPACT` → `start + 0.05 + flightTime`, or `start + 0.05 + maxRange /
  velocity` when the ability has no explicit flight time
- `CHANNEL_START` → `start`

`state:HandleEvent( e )` — State.lua:6504 — dispatches:

- **`CAST_FINISH`** — set the cooldown (or spend a charge), `ns.spendResources`, handle
  target cycling, `RunHandler`, clear the casting buff.
- **`CHANNEL_TICK`** — call `ability.tick()`.
- **`CHANNEL_FINISH`** — call `ability.finish()`, clear casting.
- **`PROJECTILE_IMPACT`** — call `ability.impact()`, `StartCombat`.

There is also `QueueAuraEvent` (6303) for `AURA_EXPIRATION` / `AURA_PERIODIC`, which
carries a `func` instead of an ability.

**Relevance to Tuono.** Tuono has nothing equivalent. Its simulation applies an ability's
effects synchronously at the step, which is correct for instants and wrong for everything
else. More immediately useful: an aura-expiration event is the clean way to model buff
expiry inside the simulation, replacing the current explicit timestamp comparison, and it
generalises to DoT ticks and resource-over-time effects that a second spec will need.

---

## 4. Recomputation and throttling — UI.lua:2377

Hekili does **not** recompute on a fixed tick the way Tuono does.

- The engine runs inside a **coroutine**, resumed across frames under a frame-time budget
  (`Hekili.maxFrameTime`, from `calculateFrameBudget()`). A pass that overruns yields and
  continues next frame rather than dropping a frame.
- Base cadence: `refreshRate = 0.25` out of combat, `combatRate = 0.2` in combat. A new
  pass starts only when no thread is active *and* `refreshTimer` exceeds the applicable
  rate.
- `Hekili:ForceUpdate( event, super )` — UI.lua:2466 — sets `criticalUpdate = true`, which
  selects the faster rate. With `super`, it also adds 0.1 to `refreshTimer`, pulling the
  next pass forward rather than starting one immediately.

So the **effective rate in combat is 5Hz, not 10Hz**, and "force an update" means "use the
fast cadence", never "recompute now, synchronously".

`ForceUpdate` callers (Events.lua) include `UNIT_SPELLCAST_SUCCEEDED`, `_START`, `_STOP`,
`_DELAYED`, `_SENT`, `UNIT_SPELLCAST_CHANNEL_START/STOP/UPDATE`,
`CURRENT_SPELL_CAST_CHANGED`, `PLAYER_TOTEM_UPDATE`, `UNIT_POWER_FREQUENT`,
`UNIT_AURA_FULL`, `UNIT_AURA_ITER`, entering combat, and spec change.

### Comparison with Tuono

Tuono's approach is **different and, in one respect, better**. Hekili has no notion of a
committed plan: every pass rebuilds all recommendations from scratch, and stability comes
from the inputs being stable plus a 5Hz cap. Tuono commits a plan, advances a cursor when
the player follows it, and invalidates on a named trigger (`Engine.TRIGGER`,
`InvalidatePlan(reason)` — IntelligenceLayer.lua:55, :69). That records *why* a
recommendation changed, which Hekili cannot tell you.

Two things Tuono should take anyway:

1. **Drop to 5Hz in combat.** Tuono runs at 10Hz with a synchronous evaluate. Hekili
   demonstrates that half that rate is sufficient for a genuinely heavier computation.
2. **A frame budget.** Tuono's evaluate is synchronous and unbounded; deepening the
   simulation (which §8 recommends) makes that a real risk. Hekili's answer — yield and
   continue next frame — is available in Lua 5.1 via coroutines and needs no API support.

---

## 5. The `wait` action and pooling

The APL may resolve to the pseudo-action `"wait"`. Core.lua:1829–1866:

```
repeat
    action, wait, depth = GetNextPrediction(...)
    if action == "wait" then
        state.advance( wait + slot.waitSec )
        ... reset slot, state.delay = 0, SetConstraint( 0, defaultMax )
        action, wait, depth = GetNextPrediction(...)
    end
    waitLoop = waitLoop + 1
    if waitLoop > 2 then ... break end
until action ~= "wait"
```

Advance the clock past the wait, re-predict at the new time, and give up after two
iterations. If it still resolves to `wait`, the action is discarded (`action, wait = nil,
10`).

`state.this_action` also defaults to `"wait"` (State.lua:2191) so state queries during an
empty walk resolve against a sane GCD (State.lua:3566 treats `wait` as `gcd = "spell"`).

**How it displays.** Not as a separate icon. UI.lua:1722:

```
if i == 1 and conf.delays.extend and rec.exact_time > max( now, start + duration ) then
    start    = ...
    duration = rec.exact_time - start
```

When position 1 is in the future, the **cooldown sweep is extended to cover the delay** —
the icon shows a sweep counting down to the moment you should press it. Plus one of two
optional indicators (UI.lua:1518–1560, options at 2749–2775):

- **`TEXT`** — `format( "%.1f", delay )`, anchored `TOPLEFT` by default.
- **`ICON`** — a dot, colour-coded by urgency: green under 0.5s, yellow under 1.5s, red
  beyond. Only shown when `delay > earliest_time + 0.05`.

There is also an option to fade or desaturate slot 1 while it is unusable
(UI.lua:1609–1613).

**Directly relevant to Tuono.** Tuono marks position 1 `"pooling"` and dims it, with no
number. The player is told "wait" but not *how long*, which is the actionable half. Tuono
already computes the information — the interval model can answer "when will energy reach
45" as precisely as it answers "is energy above 45" — it simply never surfaces it. This is
the cheapest large win available.

---

## 6. Abilities as data

`TheWarWithin/RogueOutlaw.lua:1605` — Ambush, in full:

```
ambush = {
    id = 8676, cast = 0, cooldown = 0, gcd = "spell",
    spend = 50, spendType = "energy",
    startsCombat = true,
    usable = function () return stealthed.ambush or buff.audacity.up, "requires stealth..." end,
    cp_gain = function ()
        return 2 + ( buff.broadside.up and 1 or 0 ) + talent.improved_ambush.rank + ...
    end,
    handler = function ()
        gain( action.ambush.cp_gain, "combo_points" )
        if buff.audacity.up then removeBuff( "audacity" ) end
        if talent.unseen_blade.enabled then unseen_blade.trigger() end
    end,
}
```

Note `spend = 50` — independent confirmation of the value in Tuono's profile.

Every effect is declared **on the ability**:

- `spend` / `spendType` — a number *or a function* returning `(cost, resource)`, so a
  talent-modified cost needs no engine change. `ns.spendResources` (State.lua:7266)
  resolves either form, and treats a value between 0 and 1 as a fraction of max.
- `usable` — returns `(boolean, reason)`; the reason string appears in the debug log.
- `handler` — arbitrary state mutation at cast: resource gain, buff removal, procs.
- `cp_gain` — a function, so combo-point generation varies with buffs and talents.

`state:RunHandler( key )` (State.lua:6727) calls `ability.handler()` (or `ability.start()`
plus `channelSpell` for channels), records `prev`/`prev_gcd`/`prev_off_gcd`, pushes onto a
`predictions` history capped at 10, and stamps `history.casts[key] = query_time`.

### What Tuono should do

`Rotation.Predict` currently hardcodes spec knowledge in the engine (Rotation.lua:925–935):

```
if spellID == spells.pistolShot and S.buffs.opportunity then ... end
if spellID == spells.ambush then S.stealthed = false end
if spellID == spells.stealth then S.stealthed = true end
```

Plus `applyCDR` (Rotation.lua:336), which is Restless Blades — an Outlaw talent —
implemented in the spec-agnostic engine. `docs/FRAMEWORK.md` already identifies this as
the main barrier to a second spec; Hekili shows the shape of the fix.

The Tuono version should be a `handler` on the ability in the profile, receiving the
simulated state:

```
[SPELLS.ambush] = {
    cost = 50, cd = 0, gcd = true,
    cpGen = function(S) return 2 + (S.buffs.broadside.up and 1 or 0) end,
    handler = function(S) S.stealthed = false end,
}
```

`cpGen`/`cpSpend` should accept a function as well as a number, for the same reason
Hekili's `spend` does. This is a contained change: the engine keeps applying cost, CP and
cooldown generically and calls `ability.handler(S)` for anything else, and every
`spellID == spells.x` branch moves into the profile where it belongs.

---

## 7. What NOT to copy

Hekili is ~15,000 lines across its core files and carries a decade of compatibility. Most
of it is scope Tuono should refuse.

- **The full SimC script compiler** (`Scripts.lua`, 2197 lines). It parses SimC expression
  syntax into Lua. Tuono's declarative condition rows are compiled at load and are
  deliberately *not* code — which is what makes profile import/export safe by
  construction, and is now enforced by `tests/lint_codegen.lua`. Adopting a general
  expression compiler would reintroduce exactly the attack surface that gate exists to
  prevent. **Do not build this.**
- **Multiple simultaneous displays** (Primary / AOE / Cooldowns / Defensives / Interrupts,
  Core.lua:1546–1556). Five independently-configured display frames with their own
  visibility rules. Tuono has one bar and a mode selector with hysteresis, which is the
  right size.
- **Target cycling** (`SetupCycle`, `GetCycleInfo`, the `"c"` target suffix). It exists to
  recommend multi-dotting a *different* target. Midnight makes enemy auras unreadable, so
  Tuono cannot know which target needs a refresh. Structurally unavailable, not merely
  unbuilt.
- **`Targets.lua`** (53KB of target counting). Tuono's nameplate count plus the assist
  signal is proportionate.
- **The snapshot/debug system.** Valuable, but Tuono already has a better-suited
  equivalent: the flight recorder writes machine-readable traces to SavedVariables that
  `tools/trace_analyze.py` reads offline. Do not build a second one.
- **Support for every expansion back to Classic.** Six directories of legacy class files.
- **Empowerment, `channel_breakable`, dual-cast whitelists.** All cast/channel machinery
  for specs Tuono does not support. Build when a spec needs it, not before.

---

## 8. Implementation plan for Tuono

Ranked by value per unit of risk. Each item names the Hekili mechanism and the Tuono file.

**1. Put a time on every queue entry.** *(Core.lua:2015–2018 → `Rotation.lua`,
`IntelligenceLayer.lua`)*
Track a virtual clock across simulation steps — `S.simNow` already exists — and stamp each
predicted step with `time` (offset from now) and `since` (gap from the previous step).
Purely additive; nothing has to consume it yet. Everything below depends on it.

**2. Show the wait on position 1.** *(UI.lua:1518–1560, 1722 → `Display.lua`)*
When position 1 is not yet castable, show the time until it is, and extend the cooldown
sweep to cover it. Tuono already knows this — the energy interval can answer "when will
energy reach 45" — and currently discards it in favour of an undifferentiated dim icon.
Highest ratio of perceived improvement to work in this document, and it turns "pooling"
from an apology into information.

**3. `TimeToReady` per candidate.** *(State.lua:7831, Core.lua:895 → `Rotation.lua`)*
Compute, for each priority entry, when it becomes ready — `max(cooldown remaining, GCD
remaining, time until affordable)` — and evaluate its condition at that moment. This is
the change that makes the engine genuinely predictive rather than a present-tense walk
with a pooling fallback. It subsumes the current `maxPoolAttempts` loop, which is a
coarse approximation of the same idea.

**4. Ability handlers as profile data.** *(RogueOutlaw.lua:1605, State.lua:6727 →
`Rotation.lua`, `profiles/OutlawRogue.lua`)*
Move `spellID == spells.x` branches and `applyCDR` out of the engine and onto the
abilities. Allow `cpGen`/`cpSpend`/`cost` to be functions of state. Unblocks a second
spec, which `docs/FRAMEWORK.md` identifies as the growth path.

**5. Drop the combat tick to 5Hz and add a frame budget.** *(UI.lua:2377 → `Core.lua`)*
Hekili runs a heavier computation at 0.2s. Tuono runs at 0.1s synchronously. Halving the
rate frees the headroom that items 3 and 6 consume.

**6. An event queue for the simulation.** *(State.lua:6259, 6504 → `Rotation.lua`)*
Start with aura expiry only, replacing the current explicit expiry comparison. Generalises
to DoT ticks, cast finishes and channels when a spec needs them. Do this **after** items
1–4; without a virtual clock it has nothing to schedule against.

**Explicitly not planned:** the SimC script compiler, multiple displays, target cycling.
See §7.
