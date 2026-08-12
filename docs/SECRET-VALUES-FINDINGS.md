# What Midnight's Secret Values Actually Do

A public, MIT-licensed proof of concept. Everything here was found with documented,
sanctioned APIs and verified against a live 12.1.0 client. Nothing in this repo reads a
protected value, circumvents a check, or automates input.

It is published for two reasons: players who relied on rotation helpers for
accessibility lost them overnight, and the practical shape of the new constraints is
not written down anywhere. This is that writeup.

## Why publish it

Because the alternative to a public writeup is not "nobody knows this". It is "only the
people willing to spend a month on it know this, and they are not sharing".

Everything in this document was reachable with sanctioned APIs and a lot of ordinary
engineering — interval arithmetic, threshold detection, event correlation. That is not a
high wall, it is a *tall* one: it does not stop anybody determined, it just filters out
the volunteer who maintained a free addon for their guild. The observable result is that
the open, auditable tools died and the closed ones did not.

So the choice this document is making is between a capability that exists privately and
the same capability existing in the open, where it can be read, checked, argued with, and
corrected when it is wrong. Hiding a value from an API mostly relocates a capability
rather than removing it, and this is an attempt to relocate it somewhere accountable.

None of that is an argument against Blizzard wanting to rein in addons, and none of it
excuses reading protected state — this repo does not. It is an argument that the cost of
the change landed mostly on people who were never the problem.

---

## The honest summary

Midnight's secret-values system **worked**. It is not theatre and it did not fail.

- The combat log is **gone** for addons — `COMBAT_LOG_EVENT_UNFILTERED` carries
  `HasRestrictions` and registering it fires `ADDON_ACTION_FORBIDDEN`.
- Enemy state is **gone**: health, power, buffs, casts, GUIDs in instances.
- Aura payloads are **secret in combat**, and the by-index path *raises* rather than
  returning nil.
- Primary resources are **secret unconditionally** — energy is not readable even
  standing in the open world out of combat, which we confirmed directly.
- Attempts to launder secrets back into readable form have been **patched** (string
  formatting in 12.0.1; status-bar and cooldown-frame read-back are closed by
  `SecretReturnsForAspect`).

What did **not** happen is the thing people assumed: that a rotation helper became
impossible. It didn't. It became *lower fidelity and much more work*.

## Why a helper still works

Blizzard left a coherent set of things readable, and the stated intent lines up with
it — rotation helpers that let you play "at a competent level" are fine; ones that show
"the truly optimal action" are not. The readable set is close to exactly that line.

| Readable | Not readable |
|---|---|
| Combo points and other secondary resources | Energy and other primary resources |
| Cooldown **readiness** (`isEnabled`/`isActive`/`isOnGCD`, all NeverSecret) | Cooldown **remaining** (`startTime`/`duration`) |
| `IsSpellUsable` → `isUsable`, `insufficientPower` | Aura payloads in combat |
| Spell activation overlay (proc glows) — query *and* events, no flags at all | Enemy anything |
| Your own casts, with spellIDs, exactly | The combat log |
| Nameplates and player-vs-nameplate threat | Enemy identity in instances |
| `GetSpellPowerCost`, `UnitPowerMax` | `GetHaste` (secret since 12.0.5) |

The useful reframing: **you never need to read a secret. You need any never-secret
function of it, then invert.** Almost everything below is an application of that.

## The four techniques

**1. Bound it, don't estimate it.** A point estimate of a hidden number is a lie with a
decimal point on it. Carry an interval instead: time widens it, observations tighten it.
It can be wide, but it cannot be wrong — and "wide" is a state a UI can render honestly.

**2. Every threshold is a sensor.** `insufficientPower` flips exactly when energy
crosses an ability's cost. A cost ladder — Outlaw's is 15/25/35/40/45/50 — is six
tripwires. A flip from unaffordable to affordable is an *exact* reading at a known
instant, and two of them solve the regen rate outright.

**3. Reconstruct time from your own actions.** Cooldown remaining is secret, but it is
`(castAt + duration − CDR) − now`, and every term is readable: casts carry spellIDs,
durations are static data, and cooldown reduction is driven by combo points. The
never-secret readiness boolean corrects the model, so it can be wrong but never
*silently* wrong.

**4. Ask what the client is willing to say.** `C_Secrets` exposes runtime predicates for
every secrecy question — including `GetSpellAuraSecrecy`, which enumerates auras that
stay readable in combat. Hardcoding assumptions about what is secret is a mistake;
Blizzard has already moved `GetHaste` and the secondary-resource set mid-expansion.

## What remains genuinely impossible

Stated plainly, because a writeup that only lists wins is marketing:

- **Enemy state.** No health, no debuffs, no cast bars. No interrupt planning, no
  execute-range logic, no fight-mechanic awareness.
- **Exact energy.** Bounded, never known. The bracket is tight when you are near a cost
  threshold and loose when you are not — which is fortunate, since that is when it
  matters, but it is a bound either way.
- **Roll the Bones stage 4 vs 3.** The tiers differ only by +10% crit. There is no
  deterministic observable. Stages 1, 2 and "3-or-4" collapse to certainty within about
  two globals via combo-point and cooldown-reduction side effects; the last bit is
  statistical inference or nothing.
- **Aura stack counts** for procs detected via overlay glow. The glow proves a proc
  exists; it never says how many.

## Why this exists

Not as a demonstration that restrictions can be beaten. They largely cannot, and the
section above says so plainly.

It exists because **the replacement is not good enough yet, and something had to fill
the gap.** Blizzard removed the old generation of helpers and shipped Assisted Combat in
their place. That system:

- covers **damage abilities only** — no defensives, no interrupts, no utility, which is
  most of what actually kills you in a keystone
- is reported to **stall**, repeating an AoE suggestion against a single target and
  refusing to advance until you obey it — the most trust-destroying behaviour a
  recommender can have
- costs some specs a great deal of throughput, Outlaw among the worst, because a flat
  priority ignores Roll the Bones entirely
- and is rendered on the action bar, which is exactly where players said they did not
  want to be looking

Meanwhile the players hit hardest were not parse-chasers. They were people using these
tools for accessibility, who went from playing to not playing.

That is the gap. When a company's own answer falls short, someone builds the missing
piece — and the healthy version of that is built **inside the rules**, published in the
open, honest about what it cannot do. That is the whole intent here. The techniques in
this document are not clever evasions; they are what is left when you take the
restrictions seriously and still try to make something useful.

Two consequences worth stating. Every channel used here is documented, unflagged, and
could be flagged tomorrow — if that happens this degrades rather than breaks, which is
deliberate. And none of it would be needed if the built-in assistant handled defensives,
stopped stalling, and stopped being a flat list. That is a product problem, and product
problems get solved by whoever is willing to solve them.

## Compliance

The WoW UI Add-On Development Policy has eight clauses and none address combat
advantage, automation, or inferring restricted information. Nothing here violates any
of them. This addon reads no protected value and presses no button — you press the
button, always.

One risk worth naming rather than hiding: bounding a secret scalar with a non-secret
boolean is a *declassification channel*, and Blizzard has patched that class of thing
before. The plausible failure mode is `insufficientPower` being flagged secret in a
future patch — a durability risk, not a compliance violation. If that happens, this
degrades gracefully, and that will have been the right call rather than a workaround to
route around.
