# Writing a Profile

A **profile** is everything spec-specific: which spells exist, what they cost, and the
ordered priority lists that decide what to press. The engine knows none of it. Outlaw
Rogue is just the first registered profile, not a special case.

If you can write a rotation guide, you can write a profile.

---

## The shape

```lua
local ADDON_NAME, Tuono = ...

local SPELLS = {
    myBuilder  = 12345,
    myFinisher = 67890,
}

local ABILITIES = {
    [SPELLS.myBuilder]  = { cost = 30, cpGen = 1, cpSpend = 0, cd = 0,  gcd = true },
    [SPELLS.myFinisher] = { cost = 35, cpGen = 0, cpSpend = 5, cd = 0,  gcd = true },
}

local PRIORITY = {
    {
        name = "Finisher at max CP",
        spellKey = "myFinisher",
        requiresSpell = "myFinisher",          -- omit for baseline abilities
        conditions = { { type = "cp", op = ">=", value = 5 } },   -- editor metadata
        when = function(S, A)                                     -- what the engine runs
            return Tuono.RuleHelpers.cpAtLeast(S, 5)
        end
    },
    {
        name = "Builder",
        spellKey = "myBuilder",
        conditions = { { type = "always" } },
        when = function(S, A)
            return Tuono.RuleHelpers.canAfford(S, SPELLS.myBuilder)
        end
    },
}

Tuono.Profiles.Register({
    id = "my-spec",
    name = "My Spec",
    class = "MAGE",
    specIndex = 1,
    spells = SPELLS,
    abilities = ABILITIES,
    priority = PRIORITY,        -- single target
    priorityAoE = PRIORITY_AOE, -- optional; falls back to `priority` if absent
    meleeRangeSpell = "myBuilder",
})
```

Add the file to the TOC **after** `Profiles.lua` and **before** `StateTracker.lua`.

---

## First match wins

The engine walks the list top to bottom and takes the first rule whose `when` returns
true. Then it applies that ability's effects to a *virtual copy* of your state — spends
the energy, adds the combo point, starts the cooldown — and walks the list again for
the next slot. That is why the wheel can legitimately show the same ability four times:
if the honest answer is "builder, builder, builder, builder", that is what you get.

Put the most specific rules at the top and a cheap always-true fallback at the bottom.
**Always include a fallback.** An empty bar reads as "the addon is broken" and is
strictly worse than one slightly suboptimal suggestion.

---

## `conditions` vs `when` — why both

- `when` is the **executable** predicate. It is what the engine actually calls.
- `conditions` is **metadata** describing the same logic declaratively.

The in-game editor (`/tuono config`) reads `conditions` to seed editable rows, and compiles
*those* back into predicates when the user customises. Keeping them in sync means a user
can open your profile, tweak one threshold, and keep everything else you wrote. If you
omit `conditions`, your rule still runs — it just shows up as "always" in the editor and
loses fidelity the moment someone edits it.

---

## Rule helpers

Available as `Tuono.RuleHelpers`. **Reference them lazily inside the closure** —
`Tuono.RuleHelpers.cpAtLeast(...)`, never `local H = Tuono.RuleHelpers` at file scope. Profiles
load *before* `Rotation.lua` publishes them, so a top-level capture gets `nil` forever.

| Helper | Meaning |
|---|---|
| `canAfford(S, spellID)` | Energy check. Passes when energy is unreadable. |
| `cdOf(S, key).ready` | Cooldown readiness for a spell key. |
| `cpAtLeast(S, n)` | **Fails** when combo points are unreadable. |
| `cpAtMost(S, n)` | **Passes** when combo points are unreadable. |
| `cpBelowCap(S)` | Below the combo-point maximum. |
| `finisherThreshold(S)` | 6, or the character's max if lower (levelling). |
| `isUsableAlternative(S, id, key)` | Known *and* off cooldown — for "if nothing better exists". |

### The asymmetry is deliberate

`cpAtLeast` fails on unknown, `cpAtMost` passes on unknown. That is not an inconsistency.
"Do I have at least 6 combo points?" is a claim we cannot make when the value is hidden,
and telling someone to spend a finisher they cannot afford is a real error. "Am I at most
2?" gates cooldowns that are nearly always correct on cooldown, so an unprovable answer
should not suppress the entire cooldown layer.

Copy this instinct in your own rules: **ask what happens when the value is unreadable,
and pick the failure direction that hurts least.**

---

## What you can condition on

| `type` | Readable under Midnight? | Notes |
|---|---|---|
| `always` | yes | fallback rows |
| `cp` | **yes** | secondary resources are never-secret |
| `cdReady` / `cdReadyOf` | **yes** | readiness survives; the *countdown* does not |
| `stealthed` | yes | `IsStealthed()` is never-secret |
| `enemyCount` | **yes** | nameplates + threat are never-secret |
| `energy` | **no** | shadow-modelled estimate, see below |
| `buffUp` | **no** | aura payloads go secret in combat |
| `rtbStage` | **no** | same |

The editor marks the unreadable ones in orange so nobody builds a rule that can never
fire in a keystone.

---

## Energy is special

`UnitPower("player", Energy)` is secret **unconditionally** in Midnight — primary
resources carry a predicate with no restriction gate. There is no sanctioned way to read
it back.

So the addon does not read it. `EnergyModel.lua` **bounds** it. It carries an interval
`[lo, hi]`, integrating forward from your own casts (`UNIT_SPELLCAST_SUCCEEDED` carries a
readable spellID), elapsed time, and a haste value cached from the last out-of-combat read
— `GetHaste` went secret in 12.0.5 too.

Integration alone would only drift, so the interval is *tightened* by never-secret
observations. The load-bearing one is `C_Spell.IsSpellUsable`: its `insufficientPower`
boolean turns every ability's cost into a threshold, and watching the true value cross a
threshold is an exact measurement of something you cannot read. Affordability therefore
answers **yes / no / maybe**, and rules are written to handle all three.

It reports `measured` / `bracketed` / `anchored` / `estimated` / `stale`, and never presents
an estimate as a measurement.

This touches no secret and automates no input. It is a client-side model of your own
actions — the same thing a human does in their head.

Practical consequence for profile authors: **do not build tight energy thresholds.** The
estimate drifts (Combat Potency is stochastic). Gate on combo points and cooldowns, which
are real, and let energy be a soft signal.

---

## Two rotations, one bar

Provide `priorityAoE` and the engine switches to it when the live enemy count reaches
`aoeThreshold` (default 2), with a **2-second dwell** before falling back. The dwell is
not optional polish: enemy counts oscillate constantly in real pulls, and switching on
every crossing makes the wheel strobe between two rotations unreadably.

If the count becomes unreadable, the engine **holds** the current mode rather than
snapping to single target.

Set `meleeRangeSpell` to a melee ability so the counter can reject nameplates outside
melee range — an 8-yard cleave decision made off a 40-yard nameplate count is noise.

---

## Testing

```bash
lua tests/secrets_regression.lua
```

The suite emulates secret values and asserts the addon degrades honestly. If you add a
profile, add a case that runs your priority list with energy secret and combo points
readable — that is the real Midnight condition, and it is where naive rules fall over.

A test that only passes proves nothing. Break your rule deliberately and confirm the test
goes red before you trust it.
