# Tuono — Accessibility

**Status:** design and position paper. Written 2026-08-17 against Tuono 2.2.1.
**Audience:** whoever decides what this addon is *for*, and whoever builds the UI next.

Confidence markers as elsewhere in `docs/`: **VERIFIED** (own probe, code, or primary
source), **CORROBORATED** (two independent secondary sources), **UNVERIFIED**.

---

## 0. Two corrections to the brief, before anything else

The brief was: *"make this really helpful for accessibility and kinda saying f u to
blizzard honestly because hekili allowed so many people to enjoy wow, and it was 20% dps
loss."*

The instinct is right. Two parts of the framing are wrong, and both would get the argument
dismissed by exactly the people it needs to persuade.

### 0.1 "F u to Blizzard" is the weak version of the argument

Blizzard did not ignore accessibility. They pre-empted the complaint in writing, in the
Midnight addon announcement (**VERIFIED**, primary source):

> "tools that make the game accessible to players with a range of disabilities" [will be
> affected]

and committed to replacing them:

> "a range of native accessibility improvements, such as a built-in **Combat Audio
> Alerts** system that allows players to use **Text to Speech** and other audio cues"

They also shipped Assisted Highlight and One-Button Rotation and described them explicitly
as being there "to help players learn new specializations and **improve overall
accessibility**." An argument premised on Blizzard not caring collides with a blog post
where they say they do, and loses.

**The strong version uses their own stated principle against the outcome.** Blizzard's
guiding rule for Midnight is a split between *processing* and *display*:

> "a surgical approach that limits addons' ability to process information, with the least
> possible impact on their ability to display it"

> "addons can change the size or shape of the box, and they can paint it a different
> colour, but what they can't do is look inside the box."

Tuono does not look inside the box. `docs/INVERSION.md` §1a establishes what a secret
actually is — taint, not absence — and Tuono never reads one. It models resources from
never-secret predicates that Blizzard deliberately left readable, and displays the result.
That is not a loophole; it is the stated design working as described.

So the position is: **we are doing the thing your philosophy permits, to restore the
accessibility outcome your philosophy cost.** That is defensible in public, in a ticket,
and to a CurseForge reviewer. "F u to Blizzard" is not.

There is a real grievance underneath, and it survives the reframing: Blizzard replaced a
*queue* with a *single highlight*, and §3.1 shows that specific substitution is the one
that hurts slow-reaction players most. Make that argument. It is narrow, concrete, and
true.

### 0.2 The evidence base for rotation-helper accessibility is thinner than advocacy assumes

This needs saying because building a public case on it and being caught out would be worse
than not making the case.

I searched for first-person accounts of disabled players describing what Hekili
specifically did for them. What actually exists:

- The dedicated Blizzard forum thread *"API Restrictions on Rotation Helpers (Hekili) &
  Accessibility"* argues the accessibility case in general terms — *"whether due to
  visual processing issues, anxiety, or just getting older—these addons bridged the gap
  that allowed us to play at a competent level"* — but **contains no specific personally
  described disability**. **VERIFIED** by reading it.
- The strongest, most concrete first-person account in this space is about a **blind
  player's sound addon**, not a rotation helper: *"He has spent years developing an addon
  that translates game information into sound... without them, he will no longer be able
  to play."* Real, serious, and **not a use case Tuono addresses**. Do not borrow its
  weight.

**Conclusion:** the accessibility case for rotation helpers is strong on *mechanism* and
weak on *published testimony*. Argue the mechanism — reaction time, working memory, visual
search cost — because that is what can be defended with numbers. Do not claim a documented
population you cannot cite. If someone wants the testimony, it has to be collected, and
collecting it is a real task, not a citation.

---

## 1. Who this is actually for

Only groups where something concrete can be said. Everything else was cut.

### Slow motor initiation — Parkinson's, post-stroke, cerebral palsy, essential tremor

**The measurable barrier.** Simple reaction time for target movement measures ~346 ms in
age-matched controls versus **798 ms in Parkinson's patients** — more than double
(**CORROBORATED**, *Neurology* 39(12); ScienceDirect). Movement initiation *and*
termination are both delayed.

**Why that ends a rotation.** Outlaw's GCD is 1.0 s, floored at 0.75 s
(`CooldownModel.lua` `GCD_FLOOR`, independently confirmed against Blizzard's own
`MIN_GLOBAL_RECOVERY_TIME = 0.750000` — `docs/INVERSION.md` §1a). A player needing ~800 ms
to *initiate* a press has ~200 ms of margin in a 1.0 s window — and that is before they
have identified *which* button. With Blizzard's Assisted Highlight, identification is a
visual search across the action bar that begins only when the previous GCD ends. The
budget is negative. They do not play slightly worse; the loop does not close.

**What a helper must do:** show the next action **one full GCD early**, so identification
happens during the previous GCD and only execution happens inside the current one. This is
the single most important accessibility requirement in this document, and it is precisely
what Blizzard's built-in structurally cannot provide.

### Limited keybind reach — one-handed play, chronic pain, arthritis, RSI

**The barrier.** Not decision-making — *travel*. Fewer reachable keys means more modifier
chords and more repositioning, each adding time and, for chronic pain, cost. Every
avoidable press has a price.

**What a helper must do:** never require a press it did not have to. Two consequences that
are already partly built: the repeat count (`Highlight.lua` `countText`, rendering `×N`)
tells the player "this button four times" instead of making them re-read the bar four
times; and the plan/cursor model in `IntelligenceLayer` means following the plan does not
re-derive it, so the display stops demanding re-reads it does not need.

### Working-memory load — ADHD, cognitive fatigue, long COVID, post-concussion

**The barrier.** Modern rotations are conditional priority lists held in working memory
*while* tracking mechanics, positioning, and cooldowns. The rotation is not hard to
*know*; it is hard to *hold* while doing something else. This is the largest population by
headcount and the least visible.

**What a helper must do:** be an *external* store, not a second thing to track. That means
stable output above all — a display that changes when nothing changed is a memory tax, not
a memory aid. It also argues against adding channels: an audio cue plus a highlight plus a
strip is three things to monitor.

### Returning and older players

**The barrier.** Not impairment — *currency*. Six years away, or a spec reworked twice
since they last played it. They know how to play; they do not know this rotation.

**What a helper must do:** be *learnable*, not just followable. The provenance system
(`Rotation.lua` `inputConfidence`) is unusual here: it can show *why* a step is uncertain,
which teaches. Nothing else in this space does that. It is also the group most likely to
stop needing the addon, which is a feature.

### Colour vision deficiency

**The barrier.** Deuteranopia affects roughly 1 in 12 men. WoW's playerbase is heavily
male, so the practical incidence is high.

**Status: already handled, deliberately.** `Highlight.lua:302` carries the reasoning in
code — no green, no red, authority carried by luminance (`COLOR_AUTHORITY` is near-white
`0.95, 0.95, 0.95`). Blue is reserved and avoided for "press this" because Blizzard's own
Assisted Highlight is blue. This is genuinely done and should not be re-litigated.

### Low vision

**The barrier.** Small text and thin marks at high resolution and low UI scale.

**Status: not handled, and there is a structural flaw.** See §3.4 — the addon has exactly
one scale control and it scales everything together.

### Deliberately not addressed

**Blind and severely visually impaired players.** Tuono is a visual overlay. The
accessibility work that matters for that population is sonification of game state, which
is a different addon with a different architecture. Saying otherwise would be dishonest
and would trade on someone else's harder problem.

---

## 2. The DPS-loss claim, corrected

The number in the brief is wrong for the mode Tuono competes with, and being wrong here is
expensive: a bad figure invites dismissal of the whole argument.

| Mode | DPS loss vs optimal APL | Confidence |
|---|---|---|
| **Highlight Assist** (Tuono's actual competitor) | **3–15%** | CORROBORATED |
| **One-Button Rotation** | **15–20%** | CORROBORATED |

Source: Wowhead's 11.1.7 analysis, via two independent search retrievals; the article body
would not render through WebFetch on either attempt, so this is CORROBORATED rather than
VERIFIED. Someone should read it directly and record per-spec figures here.

**Why the modes differ.** One-Button carries an explicit built-in penalty of roughly **25%
of a GCD per press** (**CORROBORATED**). Highlight Assist has no such tax — the player
still presses the button — so its loss is pure decision quality.

**So "20% DPS loss" is:**

- **Right** for One-Button.
- **Wrong** for Highlight Assist, by a wide margin at the bottom of the range. Quoting 20%
  against highlight assist overstates the deficit by up to 6×.

### 2.1 The reading that actually matters

The brief may mean something different: *Hekili users were themselves ~20% off optimal* —
i.e. the addon was never a cheat. **UNVERIFIED**, and structurally hard to verify: Hekili
follows a SimC APL, so a *perfectly* followed Hekili is near-optimal by construction, and
the real loss is human execution — reaction time, GCD clipping, mechanics. That loss is
per-player, not per-addon, and nobody has published it.

**But the argument does not need the number.** The point is qualitative and holds without
it: *a rotation helper tells you what to press; it does not press it, and it does not
recover the time you lose pressing it late.* Blizzard's own figures make this for us — even
their fully-automated One-Button mode is 15–20% off optimal. If **automation** is 15–20%
short, **advice** cannot be a competitive advantage. That is a stronger argument than any
Hekili-specific number, and it is sourced to Blizzard's own tool.

**Use that.** Do not publish a Hekili percentage.

---

## 3. What accessibility actually requires here

Ranked by how much it matters and how badly it is currently served.

### 3.1 Lead time — the requirement everything else is subordinate to

From §1: a slow-initiation player needs identification to happen *before* the GCD in which
they act. One step of lookahead converts a ~200 ms budget into a ~1.2 s budget. That is
the difference between playable and not.

**Implications, concretely:**

- **Depth of 3 is right; 4+ is decoration.** Beyond three the world has changed. The
  current default `iconCount = 4` (`Config.lua`) is one past useful, and `MAX_PIPS` in
  `Highlight.lua` already caps bar marks at 3, which is correct.
- **The plan/cursor model in `IntelligenceLayer` is an accessibility feature, not just a
  smoothness feature.** A player who cannot re-read the bar every GCD depends on the
  sequence being the *same sequence*, advanced — not a fresh derivation that happens to
  look similar. Following the plan advancing a cursor is exactly the right semantics for
  this population, and it should be described that way in user-facing docs.
- **Position 1 must never be empty.** Covered in §4.
- **Corollary that cuts the other way:** lead time is only usable if the lookahead is
  *stable*. An unstable 3-step lookahead is worse than a stable 1-step one, because the
  player spends their scarce budget re-reading. Stability is a precondition, not a polish
  item.

### 3.2 Cognitive load — where the line is

The temptation is "show less". That is wrong for this population. The correct rule:

> **Minimise things that must be MONITORED. Do not minimise things that can be CONSULTED.**

A monitored thing costs attention continuously. A consulted thing costs attention once,
when the player chooses. The action-bar marks are monitored — they must be few, quiet, and
preattentive (pips, not numerals: subitizing handles 1–3 without fixation; this is settled
in `docs/UI.md` §1.1 and implemented). The strip is consulted, between pulls and during
lulls — it can carry more.

This is also the argument against a fourth icon *and* against removing the strip. They are
different surfaces with different attention costs, and the split in `docs/UI.md` §1 is
correct on accessibility grounds independently of the aesthetic ones.

### 3.3 Alpha is an accessibility defect, not just an encoding one

`docs/UI.md` §2.1 establishes that alpha carries three unrelated meanings. The
accessibility case is more damning than the design case.

**Confirmed live in the code** (`Display.lua`):

```
unknown  -> baseAlpha = 0.4
pooling  -> baseAlpha = 0.35
stalled  -> baseAlpha = math.min(baseAlpha, 0.45)
```

`math.min(0.4, 0.45) = 0.4`. **A stalled recommendation on uncertain data is pixel-identical
to a merely-uncertain one.** The stall signal is discarded exactly when it fires most.

Why this is specifically an accessibility problem:

- **Low contrast is the failure mode of low vision.** Encoding *meaning* in reduced
  contrast means the players who most need to read the state are the ones who cannot.
  A 0.35-alpha icon over arbitrary spell art is at or below the point of legibility for a
  low-vision player at any UI scale.
- **It is unlearnable.** Three meanings, one channel, no legend. A player with working-
  memory load cannot decode which of three messages "dimmer" is, and will not try twice.
- **It does not port to the action bar** — dimming a Blizzard button means writing to a
  secure frame, which is the taint the entire overlay architecture exists to avoid
  (`docs/INVERSION.md` §1a, consequence 3). So the meanings are unavailable on the surface
  slow-reaction players depend on most.

**Requirement: no meaning may be carried by opacity alone.** Move certainty to ring
pattern per `docs/UI.md` §3.1 — which is already implemented on the bar
(`Highlight.lua` rings and pips) and still outstanding in `Display.lua`.

### 3.4 Text size — an unfixable coupling, currently

`Display.lua`:

| Element | Size |
|---|---|
| keybind text, position 1 | 13 px |
| keybind text, positions 2+ | 11 px |
| cooldown countdown | `GameFontNormalSmall` |
| status text | `GameFontNormalSmall` |
| ordinal pips | 7×7 px |
| cooldown pips | 9×9 px |

At a common 1440p UI scale of ~0.64, an 11 px glyph renders around 7 px of actual screen
height. That is below legibility for a substantial fraction of players, and the pips are
worse.

**The structural problem: there is exactly one control, `display.scale`
(`Config.lua`, `/tuono scale 0.5-2`), and it scales the entire anchor.** A low-vision
player who wants readable text must inflate the icons too, consuming screen real estate
they may also need. The coupling is backwards for the population that needs it: they want
*large text on modest icons*.

**Requirement: independent font scale.** Not a variant of the existing scale — a separate
multiplier applied to the font strings only.

Also worth noting: `Display.lua` wraps the `SetFont` call in a bare `pcall`. If it fails,
the font string silently keeps whatever default it had. That is a silent degradation on
exactly the element a low-vision player depends on, and it should at minimum be detectable.

### 3.5 Audio — opinionated: not yet, and possibly not ever here

**Current state: Tuono contains no audio at all.** Verified — no `PlaySound`,
`PlaySoundFile`, or text-to-speech anywhere in the shipping files.

**Position: do not add rotation audio cues.** Three reasons.

1. **A rotation fires ~1 cue/second for the entire fight.** That is not an alert, it is a
   metronome, and it will be muted within one raid night. Alert fatigue is how addons get
   uninstalled.
2. **The population that would benefit most is already served better elsewhere.** Blizzard
   is shipping Combat Audio Alerts with TTS natively in Midnight (**VERIFIED**, primary
   source). Competing with it is a poor use of effort.
3. **Audio adds a monitored channel** (§3.2) to players whose barrier is usually that they
   already have too many.

**The narrow exception worth building:** a single, rare, *state-change* cue — for example,
one soft tone when the addon loses confidence and stops being able to advise. That is an
event, not a metronome, and it tells a player who cannot easily glance down that the thing
they are relying on has stopped being reliable. Off by default.

### 3.6 One-button mode — the honest position

**Tuono must not implement it, and the reason is not squeamishness.**

The line in `STATE.md` is "Recommendation only. No input automation, ever." Beyond ToS,
there is a practical argument: **Blizzard already ships it, and it is better positioned to.**
Their One-Button mode operates inside the secure execution environment where it can
legitimately press buttons; a third-party version would require the exact
hardware-event-simulation that gets addons banned and users actioned. A player who needs
full automation should use Blizzard's, and Tuono's documentation should say so plainly
rather than pretending it is a competitor.

**Where Tuono is genuinely better for that same player:** they may not need *automation*,
they may need *lead time*. §3.1 is the whole argument — many players who reach for
One-Button do so because identification-within-a-GCD is impossible, not because pressing is
impossible. Solve identification and a meaningful fraction of them can play the highlight
mode at 3–15% loss instead of 15–20%.

**That is the actual accessibility pitch, and it is quantified:** Tuono can move a player
from the One-Button tier to the Highlight tier, which by Blizzard's own numbers is worth
roughly 5–17 percentage points of their damage — while giving them back the agency of
pressing their own buttons.

### 3.7 Motion — accessibility strengthens the existing position

`docs/UI.md` §4.2 argues against animating the advance. **Accessibility makes that
stronger, not weaker.**

Vestibular sensitivity and motion-triggered migraine are real and common, and peripheral
motion is the strongest involuntary attention cue there is. An animation firing once per
GCD for an entire fight is hundreds of involuntary saccades per pull. For an ADHD or
cognitive-fatigue player that is a continuous tax on the exact resource the addon exists to
conserve.

**Requirement: icons swap in place. The GCD sweep is the only permitted motion**, and it is
permitted because a sweep is a clock — continuous, predictable, and therefore ignorable —
rather than an alert.

---

## 4. What makes a disabled player trust it

The asymmetry that governs this whole section: **for an able-bodied player chasing parses,
a broken helper is an annoyance. For a player who depends on it, a broken helper ends the
session.** They cannot fall back on knowing the rotation; not knowing it is why the addon
is installed.

That raises the cost of every failure mode, and it reframes several already-fixed defects
as accessibility bugs:

| Defect | Ordinary reading | Accessibility reading |
|---|---|---|
| **The bar went empty** (10 UI errors fired with nothing recommended) | annoying gap | the player has *no* information and no fallback. The session stops. |
| **Sweep re-armed ~10×/sec** | flickery | strobing. Migraine and photosensitivity trigger; also unreadable to anyone tracking it peripherally. |
| **Glow was an opaque green rectangle** | ugly | *"press the green square"* with the ability art fully hidden — unusable for anyone who navigates by icon recognition rather than position, and green is the worst possible hue for deuteranopia. |
| **Lookahead churned every tick** | noisy | destroys lead time (§3.1), which is the entire accessibility mechanism. |

All four are fixed. The point of tabulating them is that **the reliability work already
done is the accessibility work** — this addon does not need a separate accessibility
feature list so much as it needs the guarantees it has just acquired to hold.

Two properties are worth stating as commitments, because they are what "depend on it"
actually means:

1. **Never empty.** Now enforced in the engine rather than hoped for from the profile.
2. **Never confidently wrong.** The provenance system exists for this. A helper that says
   "I am not sure" keeps a player's trust; one that is silently wrong loses it permanently,
   and a player who cannot check the answer themselves has no way to recover.

---

## 5. Honest limits

### 5.1 Accessibility conflicts with the no-automation line, and cannot fully resolve it

The most accessible interface is one button. The most contested interface is one button.
That tension does not dissolve; §3.6 routes around it by pointing at Blizzard's
implementation, but it does not answer the underlying question, and Tuono should not
pretend it has.

### 5.2 The legality premise is unsettled, and it is a bigger risk to disabled users

`STATE.md` records that the interval model is, in security terms, an oracle attack on a
deliberately-secreted value. `docs/INVERSION.md` §1a softens this — Blizzard left those
predicates readable on purpose — but it is not settled.

**The accessibility consequence is worse than the product consequence.** If Blizzard closes
the predicate, an able-bodied user loses a nice-to-have. A dependent user loses access
again, for the second time, having been told it was safe. That obligation argues for two
things:

- **Say so in the user-facing documentation.** Anyone building a dependency on this
  deserves to know the foundation is contested.
- **Keep the graceful degradation deliberate.** `EnergyModel` widening to cooldown-driven
  logic when starved of observations is currently framed as elegance. For this population
  it is a continuity guarantee, and it should be tested as one.

### 5.3 Optimal play and accessible play are not the same target

A player who cannot read a display in 200 ms should be given the *stable* answer, not the
*best* answer. Those diverge: the best answer changes with every proc; the stable answer
does not. The plan/cursor model already chooses stability within a GCD, and that is
correct — but it is a real trade, it costs a little damage, and it should be an
acknowledged design position rather than an accident of the smoothing work.

**It should not, however, become a setting.** A toggle between "accurate" and "stable"
asks the player to diagnose their own cognitive budget mid-fight. Pick the stable default.

### 5.4 Nothing here has been tested with a disabled player

Every claim in this document is derived from mechanism, published reaction-time data, and
code reading. **No user testing has been done.** The reaction-time argument in §3.1 is the
most defensible thing here and it is still an inference from clinical data to a game
interface. Treat the build list as hypotheses.

---

## 6. Build list, ranked

Each item names the population and the barrier. Items already done are listed for
completeness because the framing matters for how the addon is described.

| # | Item | Population | Barrier removed |
|---|---|---|---|
| — | *Done:* never-empty queue; ring not fill; no green/red; no strobe | all dependent users | the addon stops being something you can rely on |
| **1** | **Independent font scale** (§3.4) | low vision | text is ~7 px at 1440p and cannot be enlarged without enlarging icons |
| **2** | **Certainty off alpha, onto ring pattern in `Display.lua`** (§3.3) | low vision, working memory | meaning encoded in contrast is invisible to the people who need it; the stall signal is currently swallowed entirely |
| **3** | **Reduce default `iconCount` 4 → 3** (§3.1) | working memory, ADHD | the fourth icon is decoration and costs monitoring budget |
| **4** | **Document the plan/cursor model as a lead-time guarantee** | slow motor initiation | the mechanism exists; nobody knows it is there or why it matters |
| **5** | **Per-step hazard instead of the global degraded flag** | working memory | a permanently-on warning marks everything, therefore nothing |
| **6** | **Confidence-lost audio cue, off by default** (§3.5) | low vision, slow initiation | a dependent player cannot tell when the thing they depend on stopped working |
| **7** | **State the legality risk in user documentation** (§5.2) | all dependent users | informed dependency, not a second unannounced removal |
| **8** | **Collect actual testimony** (§0.2, §5.4) | — | the case is currently mechanism-only; validate the hypotheses |

**Item 1 first** because it is the only barrier in this list that makes the addon
completely unusable for an affected player, and it is a small change. Item 2 next because
it is already specified in `docs/UI.md` §3.1 and half-built on the bar surface.

---

## Sources

- [Combat Philosophy and Addon Disarmament in Midnight — Blizzard](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight) — primary; processing-vs-display principle, accessibility acknowledgement, native replacements
- [API Restrictions on Rotation Helpers (Hekili) & Accessibility — Blizzard Forums](https://us.forums.blizzard.com/en/wow/t/api-restrictions-on-rotation-helpers-hekili-accessibility/2252485)
- [Accessibility Impact of API Restrictions in Midnight Prepatch — Blizzard Forums](https://us.forums.blizzard.com/en/wow/t/accessibility-impact-of-api-restrictions-in-midnight-prepatch/2176481)
- [Estimated DPS Loss With Highlight Assist and One-Button Rotation in 11.1.7 — Wowhead](https://www.wowhead.com/news/estimated-dps-loss-with-highlight-assist-and-one-button-rotation-in-patch-11-1-7-377287) — body would not render; figures via search retrieval, CORROBORATED
- [Estimated DPS Loss ... in Patch 11.2 — Wowhead](https://www.wowhead.com/news/estimated-dps-loss-with-highlight-assist-and-one-button-rotation-in-patch-11-2-378081)
- [Simple and choice reaction time in Parkinson's disease — ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0006899398010609)
- [Reaction times of movement preparation in Parkinson's disease — *Neurology* 39(12)](https://www.neurology.org/doi/10.1212/WNL.39.12.1615) — 346 ms controls vs 798 ms patients
- [WoW Midnight Accessibility: New Features & Improvements](https://boostroom.com/blog/wow-midnight-accessibility-features-whats-new-and-whats-improved)
- Internal: `docs/UI.md`, `docs/INVERSION.md`, `docs/RESEARCH-MIDNIGHT.md`, `STATE.md`
