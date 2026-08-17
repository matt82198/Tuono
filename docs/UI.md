# Tuono — UI/UX Plan

**Status:** design, not yet implemented. Written 2026-08-17 against Tuono 2.2.1.
**Audience:** whoever builds `Display.lua` and `Highlight.lua` next.

---

## 0. Where Tuono actually sits

Read this first. Every design decision below falls out of it.

**Hekili is dead.** It stopped working when the Midnight pre-patch removed the APIs its
APL simulation depended on. The field that replaced it — HekiLight, Knickili, NextGCD,
Blizzkili — is, without exception, **presentation layers over Blizzard's Assisted
Combat**. NextGCD says so in its own marketing: *"NextGCD is not a custom rotation solver.
Instead, it acts as a polished presentation layer for Blizzard Assisted Combat."*

**Blizzard already highlights the next button.** "Assisted Highlight", shipped in 11.1.7,
puts a **blue** highlight on the next recommended damage ability, on every spec, in the
base UI, for free. It covers damage abilities only — no buffs, defensives, or utility.

Three consequences, and they are not negotiable:

1. **A Tuono that only glows position 1 on the action bar is a worse version of a
   built-in feature.** It is strictly redundant. Occupying the action bar is only
   defensible if Tuono puts something there that Blizzard's highlighter structurally
   cannot: **lead time** and **uncertainty**.
2. **Tuono's moat is that it actually simulates.** It is the only thing in this space
   with a real forward model, an energy interval, and per-step provenance
   (`Rotation.lua:377` `inputConfidence`). Everything the UI does should make that
   visible, because it is the only thing a competitor cannot copy in a weekend.
3. **Two highlighters will disagree on screen.** The recorded 69s trace showed Tuono
   agreeing with Blizzard's pick on **0 of 127 ticks**. If the player leaves Assisted
   Highlight on, they will see a blue Blizzard highlight and a Tuono highlight on
   different buttons, constantly. This must be handled explicitly (§6.4), not ignored.

> UNVERIFIED: whether Assisted Highlight can be toggled off programmatically, or only
> through the Options panel. If it can only be toggled by the player, Tuono must detect
> it and say so rather than silently competing with it.

---

## 1. The core tension, resolved

> Action-bar highlighting is glanceable but carries no lead time. A queue strip carries
> lead time but is a second place to look.

**Resolution: the two surfaces are not alternatives, they are different time horizons,
and they should be split on that axis rather than duplicated.**

- **The action bar answers "now".** One button, unmistakable, zero interpretation. The
  eye finds it in peripheral vision without leaving the boss.
- **The strip answers "what shape is the next few seconds".** It is a *parked* display —
  the player looks at it between pulls, during a lull, while learning. It is not, and
  should never be, something you read at 200ms under pressure.

The mistake in the current build is that the strip is asked to do both jobs. Its position
1 is drawn at 50px with an authority ring (`Display.lua:314-320, 367-372`) — it is
competing with the action bar for the "now" job, and losing, because the player's hands
are already on the action bar.

### 1.1 Against my brief's own proposal

The working proposal was numbered order badges (1/2/3) on highlighted buttons. **Half
right. The half that is wrong will actively hurt.**

**Numerals do not survive a raid.** A 12px glyph (`Display.lua:301` sizes the existing
badge at 12×12) rendered over arbitrary spell art, at 40% UI scale, in a room with
particle effects, while the player is tracking a boss cast bar — that is not a legible
target. Reading a numeral requires foveal attention. The entire point of putting
information on the action bar is that it works *peripherally*. A design that puts
foveal-only information in the periphery has cancelled its own benefit.

**Use ordinal pips, not numerals.** One dot, two dots, three dots, on the button edge.
Pips are preattentive — subitizing handles 1–3 without counting and without fixation.
They are colorblind-safe by construction. They need no font. They degrade gracefully at
small scale into "more marks = later".

**Three is the ceiling, and even three is generous.** Position 4+ on the action bar is
noise; by the time the player gets there the world has changed. The strip can show more.

### 1.2 The repeat problem

At 0 combo points the honest answer is "Sinister Strike ×4". On the bar that is **one
button**, and sequential badges are meaningless — you cannot put a 1, a 2, a 3 and a 4
on the same square.

**Show distinct buttons with their earliest position, plus a repeat count.** Sinister
Strike gets the position-1 treatment and a small `×4`. This is strictly more honest than
the strip's four identical icons, which imply four *decisions* when there is really one
decision repeated. It is also less visual noise for the same information.

This is a genuine advantage of the bar surface over the strip, and it is worth saying
out loud: **the bar can express "repeat" more truthfully than the strip can.**

### 1.3 When the spell is not on any bar

`Highlight.lua:149-164` resolves spellID → slot through a cached index and returns nil on
a real miss. Today that miss is silent: no glow, no explanation, and the player has no
idea the addon wanted to tell them something.

Three responses, in order of when they apply:

1. **The strip is the fallback surface.** This is the argument for never removing it. If
   a recommendation has no button, the strip is the only place it can appear.
2. **Say so, once, out of combat.** On first detection, a one-time chat line: *"Tuono
   recommends Roll the Bones but it is not on any action bar."* Not a repeating warning
   — alarm fatigue is how addons get uninstalled.
3. **An options-panel readout** listing every ability in the active profile that has no
   binding. This is a setup-time problem and belongs in a setup-time surface.

---

## 2. Trust and abandonment

A rotation helper is uninstalled for one of five reasons. Tuono has machinery aimed at
four of them. The machinery is largely right; **the visual language attached to it is
not.**

| Failure | What it looks like | Tuono's machinery | Verdict |
|---|---|---|---|
| Strobing | Icon flickers, list reshuffles | none yet | **Open.** The lookahead is recomputed from scratch every tick with no commitment. §4. |
| Stalling | Keeps insisting on advice you are deliberately ignoring | `Engine.IsStalled()`, `IntelligenceLayer.lua:17-38` | Logic right, **encoding broken**. §2.2 |
| False certainty | Claims to know what it is guessing | provenance confidence, `Rotation.lua:370-451` | Logic excellent, **encoding overloaded**. §2.1 |
| GCD lag | Tells you to press something you cannot press yet | GCD sweep, `Display.lua:697-721` | **Correct.** Best-implemented thing in the display. |
| Fighting muscle memory | Contradicts what the player knows is right | drift sensor, `disagreeStreak` | Instrumented, not surfaced. §6.4 |

### 2.1 Alpha is the wrong channel, and it is currently carrying three meanings

`Display.lua:534-547` sets `baseAlpha` from confidence. Then `:586-594` overrides for
pooling. Then `:680-686` overrides for stalled. Three semantically unrelated statements
are being multiplexed onto one perceptual channel:

- `unknown` → 0.4 — *"we do not know if this is right"* (an epistemic claim)
- `pooling` → 0.35 — *"you cannot afford this yet"* (a **timing** claim)
- stalled → ≤0.45 — *"you keep ignoring us"* (a **social** claim)

The player sees one thing: dimmer. They cannot decode which of three unrelated messages
it is. **Alpha means "less" and nothing more specific.**

Two concrete defects follow directly:

**(a) The stall signal is silently swallowed.** `Display.lua:682` does
`baseAlpha = math.min(baseAlpha, 0.45)`. When confidence is already `unknown`, alpha is
0.4, and `min(0.4, 0.45) = 0.4`. **A stalled recommendation on uncertain data is visually
identical to a merely-uncertain one.** The stall detector's entire output is discarded in
exactly the case where the player is most likely to be ignoring the addon *because* it is
uncertain.

**(b) Pooling is inverted.** Pooling renders dimmer (0.35) than unknown (0.4). But
pooling is a **high-confidence** statement — "I am certain you cannot press this yet" —
and unknown is a low-confidence one. The more certain state is drawn as the less certain
one.

**(c) Alpha does not port to the action bar.** We cannot dim a Blizzard action button; we
would have to write to a secure frame, which is the taint the whole overlay architecture
exists to avoid (`Highlight.lua:227-246`). So every meaning encoded in alpha is
**unavailable on the surface that matters most.** That alone disqualifies it as the
primary channel.

**Move uncertainty to the border.** A ring works on both surfaces (we own our overlay
frame), survives arbitrary icon art underneath, and has three independent sub-channels —
colour, thickness, and pattern — that can carry independent meanings without collision.

### 2.2 Fading is the wrong verb for stalling

`IntelligenceLayer.lua:8-16` argues that a helper which keeps shouting is worse than one
that admits doubt, and it fades. The instinct is right and the execution undercuts it: a
faded icon reads as *"this is less important"*, not *"we notice you disagree"*.

**Stalling should recede, not dim.** Shrink the recommendation and drop its ring, so it
stops claiming authority while remaining available. Physical retreat reads as deference.
Transparency reads as unimportance. The player who is deliberately deviating should feel
the addon *step back*, and should be able to bring it forward again by following it once.

---

## 3. Uncertainty, without cognitive load

This is the differentiator. Nothing else in this space tells you how much to trust the
recommendation. The recorded trace makes the stakes concrete: **aura data degraded on
100% of ticks; Roll the Bones stage readable only 27% of the time.** An addon that
rendered all of that with equal authority would be lying most of the time.

### 3.1 Verdict on VSUP

Value-Suppressing Uncertainty Palettes (Correll, Moritz & Heer, CHI 2018) collapse the
colour range as uncertainty rises, so an uncertain value literally cannot be read as
precisely as a certain one. The idea is exactly right for Tuono's problem.

**The technique does not survive contact with a raid.** VSUP is built for maps and
charts: a static image, a legend in frame, and a viewer who can take as long as they
like. In combat there is no legend, the background is arbitrary spell art plus particle
effects, and the read budget is under 200ms. A 2D colour lattice is unreadable under
those conditions.

**Take the principle, drop the palette.** The principle worth keeping is *bind visual
resolution to certainty* — an uncertain thing should be rendered so it cannot be read
precisely. Tuono already states this at `Rotation.lua:356-359`. Implement it structurally
rather than chromatically:

| Certainty | Encoding | Why |
|---|---|---|
| `certain` | Solid ring, crisp edge | Nothing suppressed; read it exactly. |
| `bounded` | Dashed ring | The dash *is* the suppressed resolution — the outline is literally incomplete. Reads instantly, needs no legend. |
| `unknown` | Dashed ring + amber hatch wash | Two independent cues. The hatch is borrowed from hazard signage and needs no learning. |
| `pooling` | Solid ring + blue fill sweep | High confidence, timing statement. Solid ring because we *are* sure. |

Ring **pattern** is the certainty channel. Ring **colour** stays free for kind
(rotation/cooldown/trinket), which is what `GetKindBorderColor` (`Display.lua:242-256`)
already uses it for. No collision.

### 3.2 The zero-cognitive-load version

Most players will never learn a legend. So the encoding must also work when read as pure
noise:

- Solid, bright, crisp → **trust it**
- Broken, hatched, muted → **think for yourself**

That is the whole mental model. A player who learns nothing still gets the right
behaviour. A player who reads the docs gets three graded levels. Nothing is lost by not
learning.

### 3.3 Length is already a certainty signal — keep it, but stop it flickering

`IntelligenceLayer.lua:389-402` truncates the sequence at the first `unknown` step, and
the reasoning is good: *"the player learns to trust the length, because the length means
something."* This is genuinely elegant and no competitor has it.

But length is only a usable signal if it is **stable**. Under the measured conditions —
degraded auras on 100% of ticks — the truncation point moves constantly, and a bar that
grows and shrinks ten times a second teaches nothing except that the addon is broken. The
signal is correct; it needs the commitment discipline in §4 before a player can read it.

---

## 4. Smoothness

> "It switches the entire list a lot and it's not smooth."

### 4.1 The GCD is the frame rate of the decision loop

The engine recomputes at up to ~30Hz (`Core.lua:202-204`). The player makes one decision
per GCD, which for Outlaw is 1.0s, or 0.8s under Adrenaline Rush (`Rotation.lua`
`calcGCD`). **Any lookahead change faster than one per GCD is, by construction,
information the player cannot act on.** It is noise with a refresh rate.

**Commit the lookahead once per GCD and hold it.**

`CooldownModel.GCDStart()` already exists and is already used as an idempotency key for
the sweep (`Display.lua:704-710`). Use the same key for the lookahead: when `GCDStart()`
changes, publish a new lookahead; otherwise keep publishing the committed one.

This is not a dwell timer, an animation smoother, or a debounce. It aligns the update
rate to the *decision* rate, which is the only rate that means anything. It needs no new
machinery and no tuning constant.

**Position 1 is exempt.** It stays re-derived every tick, because it must be able to
correct within a GCD when the target dies, a proc lands, or the player deviates. Position
1 is already stable in practice — the trace measured 0.28 changes/sec, which is roughly
one per three GCDs. The complaint was never about position 1.

### 4.2 Should icons slide?

**No. Never animate the advance.**

Motion is the strongest attentional cue in peripheral vision — that is what peripheral
vision is *for*. A wheel that slides on every advance fires that cue once per GCD, which
is roughly once per second, for the entire fight. It will pull the eye off the boss
several hundred times per pull.

Icons should swap **in place**, instantly. The only motion in the entire display should
be the GCD sweep, and a sweep is a clock rather than an alert — smooth, continuous,
predictable, and therefore ignorable.

There is a real tension here: sliding would make the *causal chain* legible ("this list
is the same list, advanced by one") in a way that in-place swapping does not. That is a
genuine loss. It is not worth the attentional cost. If the sequence advanced as
predicted, the player's own memory supplies the continuity for free — they pressed the
button, they know what happened.

### 4.3 Does the wheel need to move at all?

Mostly, no — and this is the strongest argument for the split in §1.

If the strip is a *parked* display, its job is to show the **shape** of the next few
seconds, not to track the instant. A strip that only changes when the plan changes — not
when the plan advances — is calmer and carries more information per glance, because a
change actually means something.

That is a larger redesign than the commitment fix and should follow it, not precede it.
Ship §4.1 first and measure.

---

## 5. Concrete spec

### 5.1 Tokens

Never encode meaning by colour alone. Every token below is paired with a shape, a
pattern, or a position.

```
--tuono-authority     0.95 0.95 0.95   near-white   position 1 ring
--tuono-lead          0.60 0.60 0.65   grey         positions 2-3 rings
--tuono-pooling       0.30 0.60 1.00   blue         "wait for it"
--tuono-hazard        1.00 0.60 0.00   amber        "we could not check this"
--tuono-kind-cd       1.00 0.60 0.00   orange       cooldown reminder
--tuono-kind-trinket  0.80 0.20 0.80   purple       trinket
--tuono-kind-rtb      1.00 0.80 0.00   gold         Roll the Bones
```

**Deliberately no green and no red.** Green/red is the single most common colourblind
failure (deuteranopia, ~6% of men). The current glow is pure green at full opacity
(`Highlight.lua:260`), which is both the worst hue choice and, as §6.1 covers, the worst
opacity choice. Authority is carried by **luminance** — near-white against arbitrary
spell art works for every form of colour vision.

**Blue is reserved for pooling** and must not be used for "press this". Blizzard's
Assisted Highlight is blue; a blue Tuono highlight would be indistinguishable from it.

### 5.2 Action bar overlay

```
   ┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐
   │╔══════╗│   │        │   │        │   │        │
   │║      ║│   │      • │   │     ••│   │        │
   │║  SS  ║│   │  Disp  │   │  BtE  │   │  RtB   │
   │║   ×4 ║│   │        │   │        │   │        │
   │╚══════╝│   │        │   │        │   │        │
   └────────┘   └────────┘   └────────┘   └────────┘
    NOW          next        after that    (no mark)
    thick ring   1 pip       2 pips
```

- **Position 1**: 2px `--tuono-authority` ring, full button perimeter. Unmistakable.
- **Positions 2–3**: 1px `--tuono-lead` ring plus ordinal pips, top-right corner, 3px
  dots. Deliberately quiet — peripheral, not competing.
- **Repeat count**: `×N` bottom-right, only when N ≥ 2. This is the one place a numeral
  earns its slot, because it is read at leisure and its absence is the common case.
- **Certainty**: ring pattern per §3.1. Dashed rings are drawn as four corner brackets
  rather than a true dash pattern — cheaper, and reads as "incomplete" at any scale.
- **Uncertain steps get no pip.** If we cannot stand behind step 3, we do not mark step
  3. Length remains the signal.

**Taint safety.** All of this is drawn on Tuono's own `UIParent`-parented frames anchored
*to* the button, per the existing architecture at `Highlight.lua:227-246`. `SetPoint`
against a secure frame reads it; nothing is written. The current pool of 4
(`Highlight.lua:247`) is exactly right for 1 + 3 marks, which suggests the original
author already intended this.

### 5.3 The strip

```
  ┌──────────┐  ┌────────┐ ┌────────┐ ┌────────┐
  │          │  │╌╌╌╌╌╌╌╌│ │▨▨▨▨▨▨▨▨│ │        │
  │    SS    │  │  Disp  │ │  BtE  │ │  RtB   │
  │  ██████  │  │╌╌╌╌╌╌╌╌│ │▨▨▨▨▨▨▨▨│ │        │
  └──────────┘  └────────┘ └────────┘ └────────┘
   certain       bounded    unknown    (cut here)
   solid ring    brackets   + hatch

  ●●●●○○   ▪▪▫▪▫▫▫▫
  combo    cooldowns ready
```

Keep the ready rail (`Display.lua:381-415`). It is the best-reasoned thing in the file —
facts only, pips rather than numbers because we know ready/not-ready but genuinely do not
know remaining duration. Do not add an energy bar; the comment at `:391-393` is right
that it would duplicate Blizzard's own, two inches away, with a worse estimate.

**Shrink position 1 in the strip to match positions 2+.** It currently gets 50px vs 42px
and an authority ring, which duplicates the action bar's job. Once the bar carries "now",
the strip's job is purely shape, and an emphasised first icon is a distraction.

### 5.4 States

| State | Bar | Strip |
|---|---|---|
| idle (OOC) | hidden unless a pre-pull action applies | dimmed, shows opener |
| normal | ring + pips | full sequence |
| pooling | ring stays solid, blue fill sweep | blue badge, solid ring |
| GCD active | sweep on position 1 only | sweep on position 1 only |
| stalled | ring drops to 1px, pips hidden | position 1 shrinks to match others |
| degraded | hatch on affected steps only | hatch on affected steps only |
| unknown pos 1 | ring dashed, still shown | still shown, dashed |

**`degraded` must stop being global.** `Display.lua:485` reads
`Tuono.State.buffs.degraded` and `:785-790` paints one status line for the whole display.
The trace shows that flag true on 100% of ticks, so a global treatment marks everything
as suspect permanently, which is the same as marking nothing. Per-step provenance already
exists (`Rotation.lua:415-417` reads `fromOverlay` per buff) — render hazard per step,
never globally.

### 5.5 Configurable vs opinionated

**Opinionated (no setting):** encoding of certainty; no slide animation; GCD-quantised
commitment; pips rather than numerals; the colour tokens. These are correctness, and a
setting that lets a user break the honesty of the display is not a feature.

**Configurable:** which surface is active (bar / strip / both); strip position, scale,
and length cap; combat-only; the AoE threshold. Anchor these in the existing
`Tuono.defaults` (`Config.lua:3-40`), which already has `highlight.enabled`,
`display.iconCount`, and `show.queue`.

**Default: bar on, strip on, strip length 4.** Both surfaces on by default because a new
user does not know the strip exists unless they see it, and the bar alone is
indistinguishable from Blizzard's built-in.

### 5.6 Accessibility

- Every state has a non-colour cue: ring thickness, ring pattern, pip count, hatch.
- Authority is luminance, not hue.
- No green/red pairing anywhere.
- Hatch angle is fixed at 45° so it never resembles a cooldown sweep.
- Pip count is capped at 3 — subitizing is reliable to 4, and 3 leaves margin.

---

## 6. What to build first

Ranked by perceived improvement per unit of work.

### 6.1 Fix the glow. It is currently opaque. (1 line)

`Highlight.lua:260`:

```lua
pcall(tex.SetColorTexture, tex, 0, 1, 0.35)
```

`SetColorTexture` defaults alpha to **1.0**, and the texture is `SetAllPoints` on a frame
that covers the whole button at `HIGH` strata. **The recommended ability's icon art is
completely hidden behind a solid green rectangle.** The player is told "press the green
square" and cannot see which spell it is.

This is the single worst thing in the UI and it is a one-line fix. It should become a
ring rather than a fill (§5.2), but even before that, giving it an alpha is an enormous
improvement for almost no work.

I did not fix it: it is outside my write scope. **Fix it first.**

### 6.2 Commit the lookahead per GCD (§4.1)

Directly answers the complaint. Reuses `CooldownModel.GCDStart()`, which already exists
and is already used as an idempotency key ten lines away. No new tuning constants.

### 6.3 Move certainty from alpha to the ring (§2.1, §3.1)

Fixes the swallowed stall signal and the inverted pooling encoding, and — more
importantly — makes the encoding portable to the action bar, which is a precondition for
6.5.

### 6.4 Handle the Blizzard highlight collision (§0)

Detect whether Assisted Highlight is enabled. If it is, say once, out of combat:

> *Tuono and Blizzard's Assisted Highlight will often disagree — Tuono simulates Roll the
> Bones and combo-point overflow, Blizzard's does not. Consider turning off Assisted
> Highlight in Options > Combat.*

Do not silently fight it. A player seeing two contradictory highlights and no explanation
concludes the addon is broken, and they are not being unreasonable.

### 6.5 Ordinal pips on the action bar (§5.2)

The actual feature. Everything above is prerequisite: pips on a strobing lookahead are
worse than no pips, and pips are pointless while the glow hides the icon.

### 6.6 Per-step hazard instead of the global degraded flag (§5.4)

Currently marks everything permanently, which marks nothing.

---

## Open questions

- **Does Blizzard's Assisted Highlight expose a readable enabled/disabled state?** If
  not, 6.4 has to be a one-time nudge rather than a conditional one. UNVERIFIED.
- **Can pips be read at 0.6 UI scale on a 1080p display?** Needs a real screenshot test,
  not a judgement call. If not, the bar surface drops to position 1 plus a repeat count,
  and lead time lives entirely on the strip.
- **Should the strip auto-hide out of combat?** `show.ooc` exists (`Config.lua:16`), but
  the opener (Stealth → Ambush) is genuinely useful pre-pull, and hiding it wastes the
  one moment the player has spare attention to learn the display.
- **Does the repeat count help or confuse?** "Sinister Strike ×4" is more honest than
  four icons, but it asks the player to hold a count. Worth an A/B against real users.

---

## Sources

- [Assisted Highlight — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Assisted_Highlight)
- [Single-Button Assistant and Assisted Highlight guide — Icy Veins](https://www.icy-veins.com/wow/single-button-assistant-assisted-highlight-guide)
- [Combat Assistant / One-Button Rotation Tool — Wowhead](https://www.wowhead.com/guide/ui/combat-assistant-one-button-rotation-tool-setup)
- [NextGCD — CurseForge](https://www.curseforge.com/wow/addons/nextgcd)
- [HekiLight — CurseForge](https://www.curseforge.com/wow/addons/hekilight)
- [Knickili — CurseForge](https://www.curseforge.com/wow/addons/knickili)
- [Protected Frames — WeakAuras2 Wiki](https://github.com/WeakAuras/WeakAuras2/wiki/Protected-Frames)
- [LibButtonGlow-1.0 — WowAce](https://www.wowace.com/projects/libbuttonglow-1-0)
- [LibCustomGlow — GitHub](https://github.com/Stanzilla/LibCustomGlow)
- Correll, Moritz & Heer, *Value-Suppressing Uncertainty Palettes*, CHI 2018.
