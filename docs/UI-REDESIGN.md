# OutlawAssist UI Redesign Spec — The One Bar

Status: DRAFT for implementation. Read-only inputs used: `OutlawAssist/Display.lua` (current
impl), `README.md`, `docs/CONTRACT.md` (module contract), `docs/research/hekilight-analysis.md`
(competitor), and the v1 UX audit (ship-blocker findings, cited throughout as **[AUDIT §n]**).

Non-negotiable product constraints this spec designs within (do not relitigate):
- **One bar.** No second frame, no side panel, no floating RtB/cooldown/trinket rows. Everything
  in one strip.
- **Position 1 = Blizzard's live pick**, from `C_AssistedCombat.GetNextCastSpell()`. Authoritative,
  changes every GCD. We do not own its content.
- **Positions 2–8 = ours.** Ready major cooldowns, ready on-use trinket windows, Roll the Bones
  advisory, stealth opener. Per `docs/CONTRACT.md` "Unified Queue Engine," this is explicitly
  "what else is worth pressing right now," never a multi-step lookahead — Blizzard's queue is
  static, we cannot fake foresight, and the UI must not imply otherwise.
- **Persists out of combat.** Default OOC-visible (this spec changes the current default; see
  STATES §2).

---

## 1. LAYOUT

### 1.1 Dimensions (scale = 1)

| Element | Value |
|---|---|
| Position-1 icon (art) | 46×46 px |
| Position-1 bounding box (art + authority ring) | 50×50 px |
| Position 2–8 icon (art) | 38×38 px |
| Position 2–8 bounding box (art + kind ring) | 42×42 px |
| Gap between every icon (1→2 and 2→3…7→8) | 6 px, uniform |
| Outer strip padding (top/left/right) | 6 px |
| Reserved status-line height (bottom, always present, empty when idle) | 14 px |
| Anchor height | 6(top) + 50(tallest box) + 6(mid pad) + 14(status) = **76 px** |

**Fix over current impl:** today the gap between icon 1 and icon 2 is 0 px (they touch) while
every subsequent gap is 4 px (`Display.lua:176,211-217` — `x = 48 + (i-2)*44` against a 48 px
icon 1). That inconsistency reads as a layout bug on close inspection. This spec uses one uniform
6 px gap everywhere.

**Fix over current impl:** the anchor/background is sized from `OA.db.display.iconCount`
(a *setting*) at `Init()` time, not from how many entries actually render each tick
(`Display.lua:176-177`, sized once). If the user configures `iconCount=4` but the engine only
ever fills 1 slot, they get one icon adrift in a dark box sized for four. **New behavior:** the
strip resizes to wrap exactly the entries actually shown this render, clamped to
`min(iconCount, #result.queue, 8)`. Resize is instant (no tween — see MOTION §5), and only
executed when the rendered count actually changed since last tick (cache `anchor.lastCount`,
skip `SetSize` otherwise — allocation-light per the existing code's own discipline,
`Display.lua:238-239`).

### 1.2 Width formula

`width = 6 + 50 + Σ(6 + 42) for each additional visible icon + 6`

| Visible icons | Width |
|---|---|
| 1 | 62 px |
| 4 | 206 px |
| 8 | 398 px |

### 1.3 ASCII wireframe — full 8-slot, in combat

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│  ╔══════════╗  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐          │
│  ║ ◈icon    ║  │● icon  │  │  icon  │  │  icon  │  │★ icon  │  │◆ icon  │  ...      │
│  ║ [sweep]  ║  │[sweep] │  │        │  │        │  │        │  │[sweep] │           │
│  ║      S-2 ║  │     2  │  │   C-3  │  │     4  │  │     5  │  │  A-M1  │           │
│  ╚══════════╝  └────────┘  └────────┘  └────────┘  └────────┘  └────────┘           │
│   silver ring    amber●     teal▲       no badge     gold★      purple◆             │
│   BLIZZARD PICK  cooldown   opener      rotation     rtb        trinket             │
│                                                                                        │
│                                                          (status line — hidden here) │
└────────────────────────────────────────────────────────────────────────────────────┘
```

Key: `╔═╗` = position-1's distinct **authority ring** (silver/white, never a kind color — see
§3.5). `● ▲ ★ ◆` = kind badges, top-left corner of each 2–8 icon (see §3.3). Bottom-right of every
icon = keybind text, large. Bottom-right of the icon itself carries the cooldown sweep as a
radial darken, not a separate widget footprint.

### 1.4 ASCII wireframe — single entry (assist available, nothing else qualifies)

```
┌──────────────────┐
│ ╔══════════╗     │
│ ║ ◈ icon   ║     │
│ ║ [sweep]  ║     │
│ ║      S-2 ║     │
│ ╚══════════╝     │
│                   │
└──────────────────┘
```

Strip shrinks to wrap exactly this one box (62×76 at scale 1) — no dead space, no phantom slots.
This is the most common OOC state and the state right after a pull before any of our rules have
fired.

### 1.5 Position-1 emphasis, summarized

Position 1 is emphasized three independent ways simultaneously, deliberately redundant so the eye
catches it under any glance condition: (a) **larger** — 50 px box vs 42 px, (b) **distinct ring
treatment** — silver/white authority ring vs. colored kind rings, (c) **fixed leftmost position**
— it never moves, never reorders, is always the first thing the reading direction (left-to-right)
hits.

---

## 2. INFORMATION HIERARCHY

**What the eye must catch in <200 ms mid-combat (pre-attentive tier):**

1. **Position-1 icon art + its keybind.** This is the literal answer to "what do I press right
   now." Hekili refugees already have this exact scan pattern trained (icon shape → keybind →
   press) — [Hekili-analysis §2] confirms even the minimal competitor (HekiLight) preserves
   "primary slot always displays the currently highlighted suggestion" as the anchor of the UI.
   Size and fixed position are pre-attentive (processed before color); that's why §1.5 leans on
   them, not color, for the single most time-critical read.
2. **Whether anything in 2–8 just changed** (a new icon appeared where there wasn't one, i.e. a
   cooldown/trinket/RtB window just opened). This is carried by the one-shot pop-in motion
   (§5), which is a pre-attentive motion cue — peripheral vision catches "something moved" far
   faster than it can read "what."

**What is secondary — parsed only on a deliberate look (200–500 ms), not the first glance:**

- Kind badges (shape+color) on positions 2–8 — answers "why is this here," not "what do I press."
- Exact cooldown numeric text — the sweep already answers "roughly how long" pre-attentively; the
  number is for players who choose to look closer, not something that needs to resolve in 200 ms.
- The degraded/unavailable status chip — important, but it is a *should I trust this* signal, one
  level removed from the *what do I press* signal position 1 answers. It must never compete with
  position 1 for the first 200 ms of attention (see §3.4 for why it's placed where it is).

**What must be actively suppressed:**

- **Continuous glow/pulse on multiple icons at once.** [AUDIT §3] notes Hekili trained users to
  expect "glow/pulse for cast now," but a busy multi-glow UI on an 8-icon strip is the opposite of
  glanceable — it forces the eye to triage between competing animated elements. This spec grants
  exactly one animated element at a time (the change-pulse, §5) and nothing else moves.
- **Full-frame color-wash borders as they exist today** (`GetKindBorderColor`,
  `Display.lua:120-134`). [AUDIT §3] found cooldown-orange and rtb-gold differ only by 0.2 in the
  green channel at 60% alpha — genuinely hard to tell apart mid-combat — and the default/most
  common "rotation" case renders at the *lowest* contrast (grey, 0.6 alpha) when the routine case
  should be the calmest but still legible as "yes, this has a kind." §3.3 replaces this scheme
  entirely.
- **Precise cooldown numerics for anything the player isn't actively deciding about.** Rendering a
  countdown on every icon at full attention-grabbing weight (bright white, top-corner, as today)
  competes with the keybind for the same visual budget. This spec keeps the numeric but folds it
  into the low-attention center of the icon via the native sweep widget instead of a bright corner
  label (§3.2).

---

## 3. PER-ICON ANATOMY

### 3.1 Icon art

- `BACKGROUND` layer texture, `SetAllPoints` on the icon button, same as today
  (`Display.lua:141-143`).
- Spell entries: `C_Spell.GetSpellTexture(spellID)` guarded fallback to legacy `GetSpellTexture`
  (existing pattern, keep).
- Trinket entries (`itemSlot` 13/14): `GetInventoryItemTexture("player", slot)` (existing pattern,
  keep).
- Missing texture fallback: `134400` (question mark) — unchanged.

### 3.2 Cooldown timer — sweep **and** numeric, via the native widget

Replace the hand-rolled `cooldownText` FontString (`Display.lua:145-149`) with a real
`CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")` per icon, created once at `Init()`.
`CooldownFrameTemplate` gives you both for free, matching Blizzard's own action-bar convention
(exactly what players already read on their action bars):
- The radial darken/swipe (pre-attentive "how full/empty" cue).
- Centered numeric countdown text (Blizzard's own formatting: decimals under a few seconds,
  rounds to whole seconds above that) — no custom font/positioning work needed.

Call `:SetCooldown(start, duration)` from the entry's cached cooldown data. **Cache-guard the
call**: store `icon.lastCDStart`/`icon.lastCDDuration`, skip `SetCooldown` when both are unchanged
since last render — this avoids resetting/restarting the swipe animation on every 0.1 s tick and
keeps `Render()` allocation-light, consistent with the file's existing stated discipline
(`Display.lua:238-239`).

This resolves the "numeric vs sweep vs where" question directly: **both, centered, native
widget** — not a corner label. It also frees the top-left and bottom-right corners for the kind
badge and keybind respectively.

### 3.3 Kind indicator — thin ring + shape badge, not a full-frame color wash

[AUDIT §3] is right that the current scheme (full-square `SetColorTexture` wash at 60% alpha,
`GetKindBorderColor`) is the wrong encoding: it washes over the spell art, two of five colors are
nearly indistinguishable, and it's color-only (fails colorblind users outright). Replace with:

- **Thin 2 px ring** (`BORDER` layer, doughnut-shaped texture, alpha-punched center, tinted via
  `SetVertexColor` — one texture asset serves every color) instead of a full-square wash. Keeps
  spell art legible underneath.
- **Small shape badge, top-left corner** (~12 px at scale 1, `ARTWORK` layer, dark 1px outline
  halo so it reads over bright or dark art) — redundant, non-color encoding so kind is legible
  without relying on hue at all:

| Kind | Ring color | Badge shape | Meaning |
|---|---|---|---|
| `rotation` (2–8 only; never position 1) | grey, higher alpha than today's 0.6 default | thin outline circle, no fill | Blizzard's own queue entry, still just informational at this position |
| `cooldown` | amber | filled circle | Ready major cooldown (AR, Blade Rush, Prep) |
| `trinket` | purple | filled diamond | Ready on-use trinket window |
| `rtb` | gold | filled 6-pointed star (hints "6 stages") | Roll the Bones cast/reroll advisory |
| `opener` | teal | filled triangle | Stealth opener |

Shape carries the meaning; color is reinforcement, not the sole channel — this satisfies
colorblind-safe encoding (§6) without needing a special "colorblind mode."

**Why ring+badge over the current wash:** the wash's core problem was legibility of the *icon
art itself* plus hue confusion between two kinds. A thin ring preserves the art; a shape badge
resolves the hue-confusion problem categorically (orange vs. gold no longer matters — circle vs.
star does) rather than just nudging the two colors further apart, which was the audit's
lower-effort fallback suggestion (§8 item 8) — this spec takes the more durable fix since it's
roughly the same implementation cost (one texture, tinted, instead of a full square).

### 3.4 Degraded / unknown state — per-icon overlay, never silent

Per [AUDIT §4], this is the single worst failure mode identified: `OA.State.buffs.degraded` is
tracked but **never read by `Display.lua`** today, so a stale RtB/proc value keeps rendering with
full visual confidence after Midnight's secret-value system has already made it unreliable — "a
gold RtB border showing Stage 4 that is actually stale, with zero indicator." This spec makes
degraded state impossible to render silently:

- **Contract addition required** (flag for the Lua implementer, not just a Display-only change):
  `OA.Engine.Evaluate()`'s queue entries need a `degraded` boolean, set true when the entry's
  `kind` depends on aura tracking that `OA.State.buffs.degraded` currently taints (`rtb`,
  `opener`, and any `cooldown`/`trinket` entry gated on a buff-derived condition like
  `adrenalineRush.up`). This is a small addition to the existing queue-entry shape documented in
  `docs/CONTRACT.md`'s "v0.3 Unified Queue Engine" addendum.
- **Per-icon render:** when `entry.degraded == true`, replace the icon's normal kind badge with a
  diagonal amber hazard-stripe overlay (`ARTWORK`, ~35% alpha, above the icon art, below the
  cooldown sweep) plus a small `?` glyph in the badge slot instead of the shape — this is a
  distinct visual state, not a desaturated version of the normal one (desaturation was tried
  and correctly flagged as too subtle — [AUDIT §3] on the existing degraded-tint code path,
  `Display.lua:290-296`, which the audit calls "silent wrongness... present" because it's the
  *only* signal and it's weak).
- **Strip-level chip** (see §3.6 below) additionally states the aggregate condition in text.

### 3.5 "Blizzard's pick" vs. "ours" — position, not decoration

Position 1 never renders a kind ring or badge — it structurally cannot be one of the five kinds
above, because it is always Blizzard's own `GetNextCastSpell()` result. Instead it gets the
**authority ring**: a fixed silver/white 2 px ring, same treatment regardless of what spell is in
it, never colored like the kind rings. This is the cleanest way to answer "is this Blizzard's or
ours": position + a completely different, non-overlapping visual language, rather than asking the
user to remember "grey = Blizzard, colored = ours" as one more entry in the same color legend
they're already parsing for kind. If Blizzard's queue naturally contains a spell that also appears
in slots 2–8 (a `kind="rotation"` entry sourced from the same base queue per
`docs/CONTRACT.md`), that entry still gets the plain outline-circle rotation badge in slot 2+ —
the distinction is purely "is this in slot 1" not "what does this spell happen to be."

### 3.6 Strip-level status chip (reused frame, not a new panel)

Repurpose the existing `anchor.statusText` FontString (`Display.lua:220-224`, currently only used
for "empty queue" reason) as the one place aggregate/global messages live, inside the reserved
14 px bottom strip (§1.1) — no second frame, satisfies the one-bar constraint. Shown when:
- Assist unavailable (state 4).
- Any currently-visible entry has `degraded == true` (state 3) — text: `"~ degraded data"` with a
  tooltip on hover explaining which channel (RtB/proc tracking) is unreliable right now.
- Non-Outlaw/wrong-spec is **not** rendered here — the whole bar hides in that case (§4.5); this
  chip only fires while the bar itself is otherwise visible.

### 3.7 Keybind — bottom-right, large, outlined

Per the hard constraint: bottom-right corner, sized to actually read mid-combat.

- `FontString`, `OVERLAY` layer, anchored `BOTTOMRIGHT` with a 2 px inset (matches current anchor
  point, `Display.lua:152-153`, but repositioned per this spec's per-icon anatomy — cooldown
  numeric now owns the icon center via the native widget, so bottom-right is fully free for this).
- Font: outline style `THICKOUTLINE` (`SetFont(path, size, "THICKOUTLINE")`) instead of relying on
  `GameFontNormalSmall`'s default (no guaranteed outline) — this is exactly the technique
  Blizzard's own action bars use for hotkey text, so it's both cheap (no extra backdrop texture)
  and instantly familiar to every WoW player, addressing [AUDIT §3]'s "no contrast guarantee
  against bright spell-icon art" finding directly.
- Size: ~13 px at scale 1 on position 1 (50 px box), ~11 px on positions 2–8 (42 px box) — larger
  than today's `GameFontNormalSmall` on a 40 px icon, which the audit flagged as "tight, especially
  for 2-3 char abbreviations like S-5 or C-M4."
- Full opacity white (`1,1,1,1`), not the current 0.8 alpha (`Display.lua:154`) — legibility over
  subtlety, per the hard constraint that this specific label must be "readable mid-combat."

---

## 4. STATES

### 4.1 In-combat, active

Full strip as in §1.3, sized to actual entry count. Position 1 = Blizzard's live pick with
authority ring; 2–8 = our derived entries with kind rings/badges, cooldown sweeps running, keybind
labels visible. If the engine momentarily returns a genuinely empty queue mid-fight (assist
available but nothing castable this instant — rare, per `docs/CONTRACT.md` normally at least
`nextSpellID` is present during combat), show a single dim placeholder tile in position 1
(desaturated icon, no ring, no keybind) rather than letting the strip vanish and reappear — a
strip that blinks in and out is more disorienting mid-fight than one calm empty-looking tile
(ties to MOTION §5 — no fade in/out on the whole strip).

### 4.2 Out-of-combat, idle

**Default changes to visible OOC** (this spec overrides today's `show.ooc = false` default,
per [AUDIT §1]: "a brand-new user who just installed the addon and reloads sees literally
nothing... silence reads as did it even install"). OOC rendering:
- Same layout, reduced to ~60% overall alpha (strip, icons, rings, badges together) so it reads as
  "resting," not "alert" — a calm ambient presence, matching the "persists out of combat, not just
  in combat" requirement without being visually loud outside a fight.
- Position 1 shows the stealth-opener entry when unstealthed (`kind="opener"`, per
  `docs/CONTRACT.md`'s `opener_stealth` rule) if one exists; otherwise a neutral "ready" class-icon
  placeholder with no authority ring (nothing to be authoritative *about* yet) and a tooltip:
  "Enter combat or target an enemy for live suggestions."
- Positions 2+ may still show ready major cooldowns (useful pre-pull check — "is Vendetta up") —
  these are legitimately known OOC without needing Blizzard's live assist at all.
- No cooldown-sweep numeric urgency styling; sweeps still run (a CD is still a CD) but nothing
  pulses (§5).

### 4.3 Degraded data

Per-icon hazard overlay + `?` badge on affected entries (§3.4), plus the strip-level status chip
text "~ degraded data" (§3.6). Everything else renders normally — degraded is a data-trust signal
layered onto specific entries, not a whole-bar state.

### 4.4 Assist-API unavailable (`OA.Assist.available == false`)

Position 1 does **not** disappear or show a stale/frozen spell — it becomes a distinct
placeholder tile: dashed grey outline (not the silver authority ring — there is no authority to
show), a lock or "?" glyph in place of spell art, no keybind text (nothing to bind to). Positions
2–8 **keep working** — per `docs/CONTRACT.md`, our derived entries (cooldown/trinket/rtb/opener)
read `OA.State`/`StateTracker`, not `C_AssistedCombat`, so they don't actually depend on assist
availability and should keep showing what they can. The strip-level chip (§3.6) states
"Blizzard rotation assist unavailable" (already the exact advisory text `docs/CONTRACT.md`
specifies IntelligenceLayer should emit — `{kind="rtb", text="Blizzard rotation assist
unavailable", active=true}` — this spec just makes sure Display actually renders it, which per
[AUDIT §1] it currently does not: `OA.Assist.available` is tracked but never read by
`Display.lua`).

### 4.5 Non-Outlaw spec (wrong class or wrong spec)

The bar hides entirely — correct behavior, don't clutter other specs/classes. This spec's scope is
the bar itself, so it does not render anything here by design; the audit's related finding (no
one-time chat message explaining the silent hide, [AUDIT §1] item 3) is a Core.lua/first-run
concern, not a Display.lua strip concern, and is out of scope for this document — flagged here
only so it isn't lost, not designed.

---

## 5. MOTION / FEEDBACK

**Animates:**

1. **Position-1 change-pulse.** When `GetNextCastSpell()` returns a *different* spellID than last
   render, position 1 does a single ~180 ms scale pulse (100% → 108% → 100%) so the user perceives
   "the recommendation just changed" without needing to read the icon art to notice. Fires once
   per change, never loops.
2. **New-entry pop-in.** When an entry appears in slots 2–8 that wasn't present last render (e.g.
   a trinket just came off cooldown), that icon scales in from 90%→100% over ~120 ms. This is the
   peripheral "something just became available" cue called out in §2 as the second pre-attentive
   read.
3. **Cooldown sweep** — continuous by nature of the native `CooldownFrameTemplate` widget, exactly
   as expected from every other WoW cooldown display; this is "motion" but it's the
   universally-understood kind, not extra noise.
4. **Degraded-onset flash.** When an entry's `degraded` flag flips false→true, one brief flash of
   the hazard overlay (fade 0→60%→35% over ~250 ms) then hold static at 35% — an acknowledgment,
   not a strobe.

**Must NOT animate:**

- **Reordering among slots 2–8.** No slide/reflow when entries change position in the array
  between ticks. Per [AUDIT §4]'s own note, `OA.Assist.deviated` reordering was flagged as a
  "missed opportunity... to reduce perceived flicker" — this spec resolves that by making
  reordering *silent* (snap, no tween) rather than adding motion to it; only content changes (new
  entry present/absent) animate, not position changes among entries that were already visible.
- **Strip resize** (§1.1) — instant `SetSize`, no tween. An animated width change while the user
  is trying to read icon contents is worse than a snap, especially at 10 Hz render cadence.
- **Any continuous/looping glow** beyond the sweep — no permanent "ready" glow on cooldown/trinket
  icons sitting available for a while. Hekili-style multi-glow (§2, suppressed) stays suppressed
  even here; the one-shot pop-in already told the user it became available, it doesn't need to
  keep telling them.
- **Whole-strip fade in/out** on OOC↔combat transition or on empty↔non-empty queue — show/hide is
  instant (`:Show()`/`:Hide()`), consistent with §4.1's "no blink in/out" rule.

---

## 6. ACCESSIBILITY / LEGIBILITY

- **Contrast over arbitrary backgrounds:** every text element (keybind §3.7) uses `THICKOUTLINE`
  font rendering rather than relying on a flat color against unknown spell-art/world backgrounds
  behind the (semi-transparent) strip background. Kind badges (§3.3) get a 1 px dark halo for the
  same reason — both are cheap (`SetFont`/pre-baked halo in the badge texture asset), no runtime
  backdrop-blur needed.
- **Colorblind-safe kind encoding:** shape (§3.3 table) is the primary discriminator, color is
  reinforcement only — this covers protanopia/deuteranopia/tritanopia without a separate
  "colorblind mode" toggle, since the encoding is redundant by construction, not color-alone with
  a fallback.
- **Optional accessibility toggle (flag for backlog, not required for v1 of this redesign):**
  `/oa toggle labels` — replaces shape badges with 3-letter text tags (`CD`, `TRI`, `RTB`, `OPN`)
  for users who want maximum unambiguous clarity at the cost of a slightly busier icon corner.
- **Scaling:** respect existing `/oa scale <0.5-2>` uniformly — icon, ring, badge, and keybind
  font all live under the single scaled `anchor` frame (already true today,
  `anchor:SetScale(scale)`, `Display.lua:179`), so nothing in this spec needs independent
  per-element scale handling. Practical note for the implementer: below ~0.6 scale the keybind
  text (§3.7, ~11–13 px baseline) becomes hard to read — not worth hard-blocking, but worth a
  one-line mention in `/oa scale`'s help text.
- **No screen-reader path exists for WoW addon frames** — not solvable at the UI layer. The
  closest available accessibility win in-scope for a future pass is populating `OnEnter`/`OnLeave`
  tooltips with the human-readable reason text (see Build Order §8 item 8, and [AUDIT §3]'s
  "why is this suggested — not conveyed at all" finding) so at minimum sighted users who need to
  slow down and inspect can do so via a standard, familiar interaction (hover a button, get a
  tooltip) rather than nothing at all.

---

## 7. IMPLEMENTATION NOTES (WoW-specific)

- **Icon buttons:** keep `CreateFrame("Button", nil, parent)` per icon (unchanged pattern,
  `Display.lua:137`) — needed as the anchor for future `OnEnter`/`OnLeave` tooltip wiring (§6, §8
  item 8) even though this pass doesn't require tooltips to ship.
- **Cooldown widget:** `CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")`, created once
  per icon at `Init()`, reused every render (§3.2). This replaces the manual `cooldownText`
  FontString entirely — one fewer hand-maintained widget, one more use of a battle-tested Blizzard
  template.
- **Kind ring + badge textures:** author as small bundled texture assets (a doughnut-shape ring,
  and one shape-badge atlas: circle/diamond/star/triangle/outline-circle), tinted per-kind at
  runtime via `:SetVertexColor(r,g,b)` — one asset per shape serves every color variant, avoiding
  five separate hand-authored colored textures. `BORDER` layer for the ring, `ARTWORK` for the
  badge (draws above icon art, below the cooldown sweep's `OVERLAY`/native layer).
- **Degraded hazard overlay:** a single diagonal-stripe texture asset, `ARTWORK` layer, tinted
  amber, alpha-driven show/hide — no per-tick allocation, just `:Show()`/`:Hide()` and one
  `SetVertexColor` call when the degraded flag flips.
- **Fonts:** `SetFont(path, size, "THICKOUTLINE")` for keybind text (§3.7) — no extra backdrop
  texture needed, matches Blizzard's own action-bar hotkey rendering convention.
- **Strip/anchor resize:** cache `anchor.lastCount`; only call `anchor:SetSize`/`bg:SetWidth` when
  the rendered entry count actually changed since the previous tick (§1.1) — keeps `Render()`
  allocation-light and avoids redundant layout work at the 10 Hz (`updateInterval = 0.1`, per
  `docs/CONTRACT.md`) tick rate.
- **`CooldownFrameTemplate` cache-guard:** store `icon.lastCDStart` / `icon.lastCDDuration` per
  icon; skip `:SetCooldown()` when unchanged (§3.2) — calling it redundantly every tick restarts
  the swipe visually in some Blizzard client versions and is wasted work regardless.
- **Taint / secure-frame risk — the one hard rule:** this addon is display-only by design
  (README: "You press the button—it never does"). Do **not** parent any icon under a Blizzard
  secure template (e.g. `SecureActionButtonTemplate`, `ActionBarButtonTemplate`) and do not attach
  click-cast attributes to these buttons, ever — that would cross from "display" into
  "click-to-cast," which is both a ToS-risk regression and a taint risk (secure frames touched
  from insecure code during combat can taint the execution path and break unrelated Blizzard UI).
  Keep using plain `CreateFrame("Button", nil, parent)` with only cosmetic textures/fontstrings,
  exactly as today's implementation already correctly does — this spec adds visual richness, not
  interactivity, and that boundary should stay explicit for whoever implements it.
- **Per-frame cost:** all new elements (ring, badge, hazard overlay, native cooldown widget,
  status chip) are created once at `Init()` and only `Show()/Hide()/SetVertexColor()/SetSize()`
  per render — no `CreateFrame` or table allocation inside `Render()`, matching the file's
  existing stated discipline ("Allocation-light per-tick rendering," `Display.lua:238-239`).
- **Contract change required, not Display-only:** `entry.degraded` on queue entries (§3.4) needs
  to be added by `IntelligenceLayer.lua`/the Engine, documented in `docs/CONTRACT.md`'s queue-entry
  shape — flag this to whoever owns that lane before Display work lands, since Display alone
  cannot know an entry is degraded without it being passed through.

---

## 8. PRIORITIZED BUILD ORDER

Ranked by biggest perceived improvement per unit of implementation risk. Items 1–3 and 6 are
Display-only and directly satisfy this task's hard constraints; item 4 requires the small
Engine-side contract addition noted in §7; item 8 is the largest lift and comes last.

1. **Keybind to bottom-right, large, `THICKOUTLINE` font (§3.7).** Directly satisfies the hard
   requirement, purely cosmetic/positional change, zero new widgets, immediate mid-combat
   readability win.
2. **Native `CooldownFrameTemplate` per icon (§3.2).** Replaces the hand-rolled cooldown text with
   a standard Blizzard widget that gives sweep + numeric together for free; frees up the
   bottom-right corner for item 1 and removes one custom-maintained code path.
3. **Position-1 authority ring, visually distinct from kind rings (§3.5).** Pure visual addition,
   no logic change, directly satisfies "Blizzard's pick vs. ours" requirement and anchors the
   information hierarchy in §2.
4. **Wire degraded/unavailable state into `Display.lua` (§3.4, §4.3, §4.4).** Closes the [AUDIT §4]
   P0 "silent wrongness" ship-blocker — the data already exists (`OA.State.buffs.degraded`,
   `OA.Assist.available`), this item is almost entirely about finally rendering it. Needs the
   `entry.degraded` contract addition (§7) as a small prerequisite.
5. **Replace full-square kind-color wash with thin ring + shape badge (§3.3).** Fixes the
   orange/gold hue-confusion and low-contrast-default findings from [AUDIT §3] categorically
   (shape, not just better-separated hues) at comparable implementation cost to the audit's
   original lower-effort suggestion.
6. **Content-driven dynamic strip resize (§1.1).** Fixes the "oversized empty background around
   one icon" glitch; small, self-contained, purely `Render()`-side.
7. **Change-pulse (position 1) and pop-in (new 2–8 entries) motion (§5).** Adds the "I can feel it
   recalculating" cue the audit implicitly asked for (its note on `OA.Assist.deviated` as "a
   missed opportunity... to reduce perceived flicker"); depends on items 1–3 being in place so
   there's a stable visual target to animate.
8. **`OnEnter`/`OnLeave` tooltip surfacing the rule's reason text (§6, referenced from [AUDIT §3]
   "why is this suggested — not conveyed at all... the differentiator is invisible in the UI").**
   Highest-value item for making the addon's actual value proposition (reasoning on top of
   Blizzard's queue) visible, but the largest lift — needs `IntelligenceLayer.lua` to pass a
   reason string through the contract, not just Display-side work. Do this once 1–7 are stable.
