# C_AssistedCombat Polling & Refresh Strategy
**WoW Midnight 12.x Rotation Recommendation Engine**

Research compiled: 2026-08-01  
**Subject:** Optimal polling interval, event-driven triggers, and desync recovery for OutlawAssist addon  
**Scope:** GetNextCastSpell() API call patterns, performance characteristics, and edge-case handling

---

## 1. Existing Wrapper Implementations

### TrueShot (itsDNNS/TrueShot — GitHub)
**Polling Strategy:** Tiered update rates
- **10Hz (100ms interval)** during active combat
- **2Hz (500ms interval)** when idle (out of combat)
- **0Hz** when overlay is hidden (no polling)

**Method:** Frame-based OnUpdate handler with throttling based on game state.

**Source:** [TrueShot GitHub](https://github.com/itsDNNS/TrueShot) — README documents "Tiered update rates (10Hz combat, 2Hz idle, 0Hz hidden)" in Display Features section.

---

### HekiLight (Hekili/hekili — CurseForge/GitHub)
**Polling Strategy:** Not explicitly documented in public README.

**Known behavior:** Lightweight wrapper around C_AssistedCombat.GetNextCastSpell() for Midnight 12.0+; re-displays Blizzard's single-button assistant recommendations as a movable icon strip.

**Source:** [HekiLight CurseForge](https://www.curseforge.com/wow/addons/hekilight) | [Hekili GitHub](https://github.com/Hekili/hekili)

**Note:** Hekili's main rotation engine uses event-driven re-evaluation ("immediately re-evaluates when you cast something else"), but polling interval for GetNextCastSpell not exposed in docs. **UNVERIFIED** whether it mirrors TrueShot's 10Hz or uses event-only approach.

---

### JustAC (wealdly/JustAC — GitHub)
**Polling Strategy:** Event-driven with minimal polling.

**Event-based triggers:**
- `SPELL_UPDATE_COOLDOWN` — fires when spell cooldown changes
- `ACTION_RANGE_CHECK_UPDATE` — fires when spell range eligibility changes
- `RegisterUnitEvent` — filters unit events at engine level to reduce noise

**Mechanism:** "Marks queues dirty" on event fire, triggering selective updates only when game state changes, rather than frame-by-frame polling.

**Performance claim:** Keeps "idle CPU low in crowded cities" by avoiding continuous polling.

**Source:** [JustAC GitHub](https://github.com/wealdly/JustAC) | [JustAC CurseForge](https://www.curseforge.com/wow/addons/just-assisted-combat)

---

### Knickili (KnickLighter — CurseForge)
**Polling Strategy:** Source code unavailable ("All Rights Reserved" license).

**Known behavior:** Keybind indicator for Blizzard's Single Button Assistant; shows which keybind corresponds to the recommended spell.

**Source:** [Knickili CurseForge](https://www.curseforge.com/wow/addons/knickili)

---

## 2. GetNextCastSpell() Computation & Performance

### Function Signature
```lua
spellID = C_AssistedCombat.GetNextCastSpell([checkForVisibleButton])
```

**Parameters:**
- `checkForVisibleButton` (boolean, optional, defaults to false) — filters for visible action bar buttons

**Return:** spellID (number, optional)

**Source:** [Warcraft Wiki — C_AssistedCombat.GetNextCastSpell](https://warcraft.wiki.gg/wiki/API_C_AssistedCombat.GetNextCastSpell)

---

### Live-Compute vs. Cached Behavior
**Official documentation:** Silent on implementation (wiki marked "under extended maintenance" since July 2026).

**Inferred from addon patterns:**
- JustAC uses event-driven "mark dirty" strategy, suggesting GetNextCastSpell **recomputes on state change** rather than returning a stale cached value.
- TrueShot's aggressive 10Hz polling (100ms) in combat implies per-frame freshness matters — if heavily cached, lower polling would suffice.

**UNVERIFIED:** GetNextCastSpell appears to be **live-computed on each call** based on current player state (cooldowns, resources, buffs, enemies), but no Blizzard dev documentation confirms this.

**Performance:** No official rate-limit or per-frame cost warnings found. TrueShot's 10Hz suggests per-call overhead is acceptable for frame-budget purposes.

---

## 3. Latency Budget & Optimal Poll Interval

### GCD & Queue Window Mechanics
- **Base GCD:** 1500ms (1.5 seconds)
- **Minimum GCD (at 100% Haste):** 0.75 seconds (750ms)
- **Spell Queue Window:** Exists but compressed by haste scaling  
  - Default queue window: **~400ms** (UNVERIFIED; inferred from player feedback on WoW forums)
  - At high haste, queue window shrinks or vanishes

**Source:** [Wowpedia — Haste](https://wowpedia.fandom.com/wiki/Haste) | [WoW Forums — GCD with a lot of haste](https://eu.forums.blizzard.com/en/wow/t/gcd-with-a-lot-of-haste/526604)

---

### Poll Interval Derivation

**Constraint:** Recommendation must refresh within the spell-queue window to catch player's intended cast.

**Candidates:**
1. **50ms (20Hz)** — Ultra-high refresh, probably wasteful
2. **100ms (10Hz)** — TrueShot's combat polling; covers most queue windows; good compromise
3. **250ms (4Hz)** — Hybrid compromise; risks missing narrow haste-compressed queue windows at peak haste
4. **500ms (2Hz)** — TrueShot's idle polling; acceptable when out of GCD pressure

**Recommendation:**
- **Poll interval: 100ms (10Hz)** during active combat (in GCD window)
- **Poll interval: 250–500ms (2–4Hz)** when idle or between pulls
- **0ms** when addon overlay hidden (pause polling entirely to save CPU)

This mirrors TrueShot's proven tiered strategy and keeps recommendations fresh within the ~400ms queue window.

---

## 4. Desync & Edge Case Recovery

### Desync Scenarios
1. **Player casts wrong spell** — addon recommends A, player casts B
2. **Target dies mid-GCD** — recommendation becomes invalid mid-cast
3. **Movement interrupts cast** — cast fails, old recommendation stale
4. **Buff/debuff expires** — changes cooldown eligibility of recommended spell
5. **Resource pool changes** — reduces ability to cast recommended spell

---

### Event Triggers for Immediate Re-Poll

When these events fire, **force an immediate call to GetNextCastSpell()** (bypass throttle timer) and re-render:

#### Combat Completion Events
- **`UNIT_SPELLCAST_SUCCEEDED`** (on "player") — fire on spell completion
  - Event parameters: unitTarget, castGUID, spellID, castBarID
  - **Use case:** Detect if player cast what was recommended or deviated
  - **Source:** [Warcraft Wiki — UNIT_SPELLCAST_SUCCEEDED](https://warcraft.wiki.gg/wiki/UNIT_SPELLCAST_SUCCEEDED)

- **`UNIT_SPELLCAST_INTERRUPTED`** (on "player") — fire when cast is interrupted
  - Event parameters: unitTarget, castGUID, spellID
  - **Use case:** Clear in-flight recommendation, force re-poll for next viable spell
  - **Source:** [Warcraft Wiki — UNIT_SPELLCAST_INTERRUPTED](https://warcraft.wiki.gg/wiki/UNIT_SPELLCAST_INTERRUPTED)

- **`UNIT_SPELLCAST_FAILED`** (on "player") — fire when cast fails (e.g., out of range)
  - **Use case:** Recommendation was invalid; re-poll immediately

#### Environmental Changes
- **`PLAYER_TARGET_CHANGED`** — target switch invalidates range/threat checks
  - **Use case:** New target → recommendation may differ
  - **Source:** [Warcraft Wiki — Events](https://warcraft.wiki.gg/wiki/Events)

- **`COMBAT_LOG_EVENT_UNFILTERED`** (filtered for "player" unit) — alternative to above events
  - **Use case:** Consolidated event stream for spell events

#### Resource & Cooldown Changes
- **`SPELL_UPDATE_COOLDOWN`** — spell cooldown starts/ends
  - **Use case:** Recommended spell came off cooldown or went on cooldown
  - **Source:** [Warcraft Wiki — SPELL_UPDATE_COOLDOWN](https://warcraft.wiki.gg/wiki/SPELL_UPDATE_COOLDOWN)

- **`UNIT_POWER_UPDATE`** (on "player") — resource changes (energy, combo points, rage, etc.)
  - **Note:** Fires once per 2 seconds by default; use `UNIT_POWER_FREQUENT` for per-tick updates
  - **Use case:** Detect resource-gated ability availability
  - **Source:** [Warcraft Wiki — UNIT_POWER_UPDATE](https://warcraft.wiki.gg/wiki/UNIT_POWER_UPDATE)

- **`ACTIONBAR_UPDATE_COOLDOWN`** — action bar cooldown updates
  - **Use case:** Keybind or ability became available
  - **Source:** [Wowpedia — ACTIONBAR_UPDATE_COOLDOWN](https://wowpedia.fandom.com/wiki/ACTIONBAR_UPDATE_COOLDOWN)

---

### How Existing Wrappers Handle Desync

**TrueShot:** Doesn't explicitly address desync; relies on aggressive 10Hz polling to self-correct within ~100ms of mis-cast.

**JustAC:** Event-driven "mark dirty" approach catches cooldown and range changes immediately, but may miss player-initiated deviation until next 100ms poll window or event.

**HekiLight:** No documented desync recovery beyond GetNextCastSpell's own re-computation.

**Gap:** No addon fully implements explicit "detect player cast B when A was recommended" logic with immediate fallback. OutlawAssist can improve on this.

---

## 5. OutlawAssist Rule Engine: Recalculation Triggers

### Immediate Triggers (Force Evaluate + Render, bypass throttle)
These should **always** force a fresh GetNextCastSpell() call and rule evaluation:

1. `UNIT_SPELLCAST_SUCCEEDED` → player cast something; check if it matches recommendation
2. `UNIT_SPELLCAST_INTERRUPTED` → mid-cast interruption; re-evaluate next option
3. `PLAYER_TARGET_CHANGED` → new target invalidates prior recommendation
4. `SPELL_UPDATE_COOLDOWN` → spell availability changed
5. `UNIT_POWER_UPDATE` (or `UNIT_POWER_FREQUENT` for rogue combo points) → resource pool changed

### Throttled Triggers (Stay on 100ms timer, don't force immediate re-poll)
These queue updates for the next timer tick if not already pending:

1. `UNIT_AURA` (buffs/debuffs) → usually debounced; let timer pick up changes
2. `UNIT_HEALTH` / `UNIT_MAXHEALTH` → on-demand only if threat/survival check needed
3. Combat state changes (entering/leaving combat) → state flags used for tiered polling rates

### Polling Fallback (Always active)
- **100ms timer** (10Hz) during combat
- **250–500ms timer** (2–4Hz) out of combat
- Acts as catch-all for missed events or state drift

---

## Recommendation

### Polling Interval
- **Combat:** 100ms (10Hz) — covers spell-queue window; aligns with TrueShot
- **Idle:** 500ms (2Hz) — sufficient for non-critical updates; reduces CPU
- **Hidden:** 0ms (pause polling) — overlay off-screen, no need to compute

**Rationale:** 100ms interval fits comfortably within ~400ms queue window, allowing 3–4 GetNextCastSpell() calls per queue cycle. TrueShot's proven success with this rate validates the choice.

### Event Trigger List
**Immediate re-poll (force Evaluate + Render):**
- UNIT_SPELLCAST_SUCCEEDED (detect deviated cast)
- UNIT_SPELLCAST_INTERRUPTED (recover from interrupt)
- PLAYER_TARGET_CHANGED (invalidates threat/range checks)
- SPELL_UPDATE_COOLDOWN (spell availability changed)
- UNIT_POWER_UPDATE or UNIT_POWER_FREQUENT (resource-gated ability changed)

**Throttled (queue for next timer tick):**
- UNIT_AURA (buff/debuff state)
- Combat enter/exit (affects tiered polling rates)

### Desync Recovery Rule
When player casts spell B and recommendation was spell A:
1. **Detect:** UNIT_SPELLCAST_SUCCEEDED fires with spellID = B
2. **Compare:** If spellID ≠ last GetNextCastSpell() result, flag as **deviation**
3. **Recover:** Immediately call GetNextCastSpell() and re-render for next GCD
4. **Log:** Track deviation count; emit warning if pattern emerges (suggests recommendation is consistently wrong)

**Fallback:** If event stream breaks, 100ms timer will re-poll within ~200ms and self-correct by next queue window.

---

## Conclusion

**Optimal strategy for OutlawAssist:**
- Use **event-driven immediate re-poll** (UNIT_SPELLCAST_SUCCEEDED, INTERRUPTED, TARGET_CHANGED, COOLDOWN, POWER)
- Maintain **100ms (10Hz) throttle timer** as fallback / drift correction
- Implement **tiered rates** (100ms combat, 500ms idle, 0ms hidden)
- **Monitor deviation** (player cast ≠ recommendation) to surface recommendation errors

**Uncertainty:** GetNextCastSpell() caching behavior remains UNVERIFIED; test live-compute assumption by calling it 10× per frame and measuring lag impact. If per-call cost is high, consider JustAC's "mark dirty" event-caching hybrid.

---

## References

- [TrueShot GitHub](https://github.com/itsDNNS/TrueShot)
- [Hekili GitHub](https://github.com/Hekili/hekili)
- [JustAC GitHub](https://github.com/wealdly/JustAC)
- [Warcraft Wiki — C_AssistedCombat.GetNextCastSpell](https://warcraft.wiki.gg/wiki/API_C_AssistedCombat.GetNextCastSpell)
- [Warcraft Wiki — UNIT_SPELLCAST_SUCCEEDED](https://warcraft.wiki.gg/wiki/UNIT_SPELLCAST_SUCCEEDED)
- [Warcraft Wiki — UNIT_SPELLCAST_INTERRUPTED](https://warcraft.wiki.gg/wiki/UNIT_SPELLCAST_INTERRUPTED)
- [Warcraft Wiki — SPELL_UPDATE_COOLDOWN](https://warcraft.wiki.gg/wiki/SPELL_UPDATE_COOLDOWN)
- [Warcraft Wiki — UNIT_POWER_UPDATE](https://warcraft.wiki.gg/wiki/UNIT_POWER_UPDATE)
- [Wowpedia — Haste](https://wowpedia.fandom.com/wiki/Haste)
- [WoW Forums — GCD with high haste](https://eu.forums.blizzard.com/en/wow/t/gcd-with-a-lot-of-haste/526604)
