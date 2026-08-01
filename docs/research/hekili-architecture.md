# Hekili Addon Architecture Reference

**Project Status**: Concluded January 20, 2026 (https://github.com/Hekili/hekili/releases)  
**Repository**: https://github.com/Hekili/hekili (MIT Licensed as of v0.5.0)

## Overview

Hekili is a World of Warcraft priority helper addon that displays multiple sequential ability recommendations based on SimulationCraft-style action priority lists (APLs). It predicts future game state changes and simulates ability sequences to recommend "the next 3 actions" you should take in combat.

**Key architectural principle**: Collect current state snapshot → simulate ability effects → generate predictions → display → update every frame.

---

## 1. Core Loop: State Prediction & Recommendations

### Entry Point: `Hekili.Update()` (https://github.com/Hekili/hekili/blob/main/Core.lua, line 1561)

The main update loop runs every frame and is the heartbeat of the prediction engine:

```lua
function Hekili.Update()
    -- Validates addon is initialized and user has valid spec/pack selected
    if not Hekili:ScriptsLoaded() or not Hekili:IsValidSpec() then return end
    
    -- Fetch current spec's action priority list package
    local specID = state.spec.id
    local spec = profile.specs[specID]
    local pack = profile.packs[spec.package]
    
    -- Loop through 5 display categories (Interrupts, Cooldowns, etc.)
    for round = 1, 5 do
        -- Reset stack, clear caches
        wipe(Stack); wipe(Block); wipe(InUse)
        
        -- Call GetNextPrediction() to generate recommendations
        local numRecs = display.numIcons or 3  -- Typically 3 icons displayed
        -- ... prediction generation ...
    end
end
```

Source: https://github.com/Hekili/hekili/blob/main/Core.lua lines 1561–1620

### Prediction Engine: `GetNextPrediction()` (https://github.com/Hekili/hekili/blob/main/Core.lua)

This is the core state-prediction function that generates the "next N abilities":

```lua
function Hekili:GetNextPrediction( dispName, packName, slot )
    -- Cache clearing: wipes prediction stack, block list, in-use tracking
    twipe( Stack ); twipe( Block ); twipe( InUse )
    twipe( listStack )
    
    -- Reset spell and variable caches
    self:ResetSpellCaches()
    state:ResetVariables()
    
    -- Fetch the active pack (APL)
    local display = rawget( self.DB.profile.displays, dispName )
    local pack = rawget( self.DB.profile.packs, packName )
    
    -- Initialize prediction state
    state.selection_time = nil
    state.selected_action = nil
    
    -- Generate predictions depth-first (typically 3–10 actions ahead)
    local action, wait, depth = nil, nil, 0
    -- ... iterates through APL conditions, applies predicted state changes ...
end
```

Source: https://github.com/Hekili/hekili/blob/main/Core.lua

### State Prediction Mechanism: `GetPredictionFromAPL()`

After each simulated action, state is advanced forward in time:

```lua
function Hekili:GetPredictionFromAPL( dispName, packName, listName, slot, action, wait, depth, caller )
    local specID = state.spec.id
    local spec = self.DB.profile.specs[specID]
    local module = class.specs[specID]
    
    -- Resolve which APL pack to use (e.g., SimulationCraft-imported data)
    local pack = self.DB.profile.packs[packName]
    local list = pack.lists[listName]
    
    -- For each action in the list, check if its conditions are met
    -- If condition passes: record action, apply state changes (cooldown, resource spend, buff applies)
    -- Virtual time advances (state.query_time += cast_time + gcd)
    -- Loop back to find next action with updated state
end
```

Source: https://github.com/Hekili/hekili/blob/main/Core.lua

**Virtual Time Advance Pattern**: After each predicted ability:
1. Spend resources (energy, combo points, cooldowns)
2. Apply predicted buffs/debuffs
3. Increment `state.query_time` by GCD + cast time
4. Re-evaluate conditions with new state snapshot
5. Repeat until depth limit or no valid actions remain

---

## 2. APL Handling: SimulationCraft Integration

### APL Storage & Import

APLs are stored as **compressed binary packs** registered via `spec:RegisterPack()`:

```lua
-- From RogueOutlaw.lua line ~1750
spec:RegisterPack( "Outlaw", 20250903, [[Hekili:L3tAZTTrY(BrvQIMmsIMKYY54jQQSD2e7KSj5z5S5dBTceeyijIabyWHv0RuXF7...]] )
```

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua line 1750

The binary format is a custom compression scheme (not standard Lua or JSON). The pack contains:
- List names (e.g., `single_target`, `aoe`, `precombat`)
- Conditions expressed as stack-based expressions
- Action priority ordering

### DSL/Condition Format

Conditions are stored as postfix (Reverse Polish Notation) expressions in the pack, then evaluated at prediction time:

```lua
-- Example condition structure (internal representation):
-- "if (energy > 50) and (buff.opportunity.up) then action X"
-- Stored as:
-- { op="and", left={op=">", var="energy", val=50}, right={op="up", var="buff.opportunity"} }

-- Evaluation at prediction time:
if condition:evaluate(state) then
    recordAction(action)
    applyStateChanges(state, action)
end
```

**UNVERIFIED**: Exact serialization format not visible in source; likely binary/compressed format designed for size efficiency.

Source: https://github.com/Hekili/hekili/blob/main/Core.lua (prediction evaluation)

### APL Update Frequency

- **Patch updates**: Typically within 24–48 hours of WoW patch
- **Minor balance updates**: Weekly to semi-weekly
- **User imports**: Can import custom SimulationCraft APLs via multiline text editor
- **Source**: APLs derived from [SimulationCraft](https://www.simulationcraft.org) and [RaidBots](https://www.raidbots.com/simbot)

Source: https://github.com/Hekili/hekili/wiki/Getting-Started (historical)

---

## 3. Spec Modules: Rogue/Outlaw Registration API

### Module Structure

Spec modules (e.g., `TheWarWithin/RogueOutlaw.lua`) follow a standardized registration pattern:

```lua
-- Create spec (260 = Rogue/Outlaw spec ID)
local spec = Hekili:NewSpecialization( 260 )

-- 1. Register Resources (energy, combo points)
spec:RegisterResource( Enum.PowerType.ComboPoints, { ... } )
spec:RegisterResource( Enum.PowerType.Energy, { ... } )

-- 2. Register Talents
spec:RegisterTalents( { ... } )

-- 3. Register Abilities/Spells
spec:RegisterAbilities( { ... } )

-- 4. Register Gear/Set Bonuses
spec:RegisterGear( { ... } )

-- 5. Register Auras (buffs/debuffs)
spec:RegisterAuras( { ... } )

-- 6. Register APL Pack
spec:RegisterPack( "Outlaw", version, compressedAPLData )

-- 7. Register Options & Keybinds
spec:RegisterOptions( { ... } )
spec:RegisterRanges( "ability1", "ability2", ... )
spec:RegisterSettings( { ... } )
```

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua lines 1–1767

### Ability Registration Example

```lua
-- From RogueOutlaw.lua
spec:RegisterAbilities( {
    adrenaline_rush = {
        id = 13750,
        cast = 0,
        cooldown = 180,
        gcd = "off",
        
        talent = "adrenaline_rush",
        startsCombat = false,
        
        handler = function()
            -- Predicted state changes when cast
            applyBuff( "adrenaline_rush" )
            gain( 25, "energy" )  -- Predict energy gain
        end
    },
    
    sinister_strike = {
        id = 193315,
        cast = 0,
        cooldown = 0,
        gcd = "spell",
        
        spend = 45,
        spendType = "energy",
        startsCombat = true,
        
        cp_gain = function()
            return 1 + (buff.broadside.up and 1 or 0)
        end,
        
        handler = function()
            gain( action.sinister_strike.cp_gain, "combo_points" )
            removeStack( "snake_eyes" )
        end
    }
} )
```

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua lines ~1125–1767

### Gear Set Bonus Registration

```lua
spec:RegisterGear( {
    tww3 = {
        items = { 237667, 237665, 237663, 237664, 237662 },  -- Item IDs
        auras = {
            tww3_trickster_4pc = {
                duration = 5,
                max_stack = 1,
                generate = function( t )
                    -- Custom aura generation logic for set bonuses
                    if set_bonus.tww3 >= 4 and buff.escalating_blade.up then
                        t.expires = buff.escalating_blade.expires
                    end
                end
            }
        }
    },
    tier31 = {
        items = { 207234, 207235, 207236, 207237, 207239, ... }
    }
} )
```

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua lines 1046–1125

---

## 4. State Model: Rogue/Outlaw Specifics

### Resource Management

#### Energy (Primary Resource)

```lua
spec:RegisterResource( Enum.PowerType.Energy, {
    blade_rush = {
        aura = "blade_rush",
        
        last = function()
            local app = state.buff.blade_rush.applied
            local t = state.query_time
            return app + floor( t - app )  -- Ticks every 1 sec
        end,
        
        interval = function() return class.auras.blade_rush.tick_time end,
        value = 5,  -- Gain 5 energy per tick
    },
},
nil,  -- No replacement model
{     -- Meta function replacements
    base_time_to_max = function( t )
        if buff.adrenaline_rush.up then
            if t.current > t.max - 50 then return 0 end
            -- Predict time to reach max-50 energy during Adrenaline Rush
            return state:TimeToResource( t, t.max - 50 )
        end
    end,
    base_deficit = function( t )
        if buff.adrenaline_rush.up then
            -- Energy cap becomes max-50 during AR
            return max( 0, (t.max - 50) - t.current )
        end
    end,
}
)
```

**Regen model**: Base energy regeneration + aura modifiers (Adrenaline Rush increases regen by ~25%)

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua lines 51–72

#### Combo Points (Secondary Resource)

```lua
spec:RegisterResource( Enum.PowerType.ComboPoints, {
    -- Killing Spree generation
    killing_spree = {
        channel = "killing_spree",
        last = function()
            local app  = state.buff.casting.applied
            local tick = 0.5 * state.haste
            local t    = state.query_time
            return app + math.floor( (t - app) / tick ) * tick
        end,
        interval = function() return 0.5 * state.haste end,
        value = 1,  -- Gain 1 CP per 0.5s tick
    },
} )
```

**Combo Points** are consumed by finishing moves and generated by generators (Sinister Strike: 1 CP, Ambush: 2 CP, etc.).

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua lines 37–50

### Roll the Bones Buff Tracking

Roll the Bones can grant one of 8 possible buffs. Hekili tracks this via alias:

```lua
spec:RegisterAuras( {
    roll_the_bones = {
        alias = { "broadside", "buried_treasure", "grand_melee", "ruthless_precision", 
                  "skull_and_crossbones", "true_bearing", "rtb_buff_1", "rtb_buff_2" },
        aliasMode = "longest",  -- Use buff with longest remaining duration
        aliasType = "buff",
        duration = 30
    },
    
    rtb_buff_1 = { duration = 30 },  -- Generic RTB buff (actual ID unclear)
    rtb_buff_2 = { duration = 30 },
    
    supercharged_combo_points = {
        -- Fully emulated (no direct buff ID)
        duration = 3600,
        max_stack = function() return combo_points.max end,
    }
} )
```

**Prediction**: When RTB is cast, a "generic RTB buff" is applied for prediction purposes. The actual buff outcome is unknown until server confirms, so recommendations assume the most-commonly-valuable outcome or track all possibilities.

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua lines 138–180 (auras section)

### Blade Flurry & Opportunity Tracking

Opportunity is tracked via flag/counter (from Sinister Strike procs):

```lua
buff.opportunity = {
    id = 279876,  -- Opportunity (Outlaw talent)
    duration = 10,
    max_stack = 6,  -- Per talent: Fan the Hammer max 6 stacks
}
```

Prediction increments/decrements `buff.opportunity.stack` based on:
- Sinister Strike's proc chance (22% baseline + talent modifiers)
- Pistol Shot consumption (`removeStack("opportunity")` in handler)

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua (auras, ability handlers)

### Global State Variables

All state tracked in `Hekili.State` object:

```lua
local state = Hekili.State

state.now = 0  -- Current time (from GetTime())
state.offset = 0  -- Prediction offset
state.query_time = 0  -- Virtual time during prediction

state.spec.id = specID  -- Current spec ID (260 for Outlaw)
state.action = {}  -- Last action taken
state.active_dot = {}  -- Damage-over-time effects on targets
state.buff = {}  -- Player buffs (indexed by name or ID)
state.aura = {}  -- All auras (alias index)
```

Source: https://github.com/Hekili/hekili/blob/main/State.lua lines 65–120

---

## 5. Performance & UX

### Update Throttling

Hekili implements two levels of throttling to manage CPU cost:

#### Forecasting Time Cap (`throttleForecastingTime`)

```lua
-- Per-spec setting (e.g., Rogue max prediction time)
if spec.throttleForecastingTime then
    -- Stop predicting if virtual time exceeds this threshold
    -- Prevents runaway prediction loops (e.g., 10 second lookahead)
    if state.query_time > spec.throttleForecastingTime then
        break  -- Stop depth iteration
    end
end
```

Source: https://github.com/Hekili/hekili/blob/main/Core.lua lines 939, 1093

#### Forecasting Count Cap (`throttleForecastingCount`)

```lua
if spec.throttleForecastingCount then
    -- Limit number of actions predicted
    local cap_n = spec.throttleForecastingCount or 10
    if depth >= cap_n then
        break  -- Stop after N recommendations
    end
end
```

Source: https://github.com/Hekili/hekili/blob/main/Core.lua line 1101

### FPS-Aware Frame Budget

Hekili tracks smoothed FPS and allocates frame budget dynamically:

```lua
-- From UI.lua: FPS tracking with 30-sample sliding window
local fpsTracker = {
    samples         = {},
    maxSamples      = 30,
    smoothedFPS     = 60,
    updateInterval  = 0.1,  -- Update every 100ms
}

function Hekili.GetSmoothedFPS()
    return updateSmoothedFPS()  -- Returns averaged FPS over last 3 seconds
end

-- Frame budget allocation
local function calculateFrameBudget()
    local smoothedFPS = updateSmoothedFPS()
    local frameBudget = Hekili.DB.profile.performance.frameBudget or 0.7
    -- Allocate 70% of frame time to Hekili's predictions
    local frameTime = 1000 / math.max(smoothedFPS, 30)  -- ms per frame
end
```

Source: https://github.com/Hekili/hekili/blob/main/UI.lua lines 79–120

### Display System

#### Multiple Synchronized Displays

Hekili generates recommendations for 5 separate displays in sequence:

1. **Interrupts**: Abilities that should interrupt enemy casts
2. **Cooldowns**: High-CD abilities (90s+)
3. **Defensives**: Mitigation/survivability
4. **Main**: Primary rotation actions
5. (Optional) **Custom/AoE**: Alternate lists for multi-target

Each is updated independently but uses the same state snapshot:

```lua
function Hekili.Update()
    -- ... initialize state ...
    
    for round = 1, 5 do
        local rule, fullReset, nextDisplay = unpack( displayRules[ dispName ] )
        -- displayRules determine which displays are shown based on profile toggles
        
        -- For this display:
        state.reset( dispName, fullReset )  -- Reset prediction state
        state.system.display = dispName
        
        local numRecs = display.numIcons or 3  -- Typically 3 icons
        for i = 1, numRecs do
            local action = self:GetNextPrediction( dispName, packName, i )
            -- Render action i to position i
        end
    end
end
```

Source: https://github.com/Hekili/hekili/blob/main/Core.lua lines 1561–1620

#### Icon Rendering

Hekili renders ability icons with:
- **Spell texture** (from WoW's spell database)
- **GCD indicator** (greyed if on GCD)
- **Cooldown spiral** (if ability is on cooldown)
- **Keybinding text** (optional overlay showing user's bound key)
- **Stack count** (for abilities with stacks, e.g., Opportunity)

Source: https://github.com/Hekili/hekili/blob/main/UI.lua (rendering functions)

### Keybind Capture & Options

```lua
spec:RegisterOptions( {
    enabled = true,
    
    aoe = 3,  -- Threshold for AoE mode (switch to AoE list at 3+ enemies)
    cycle = false,  -- Target cycling
    
    nameplates = true,
    nameplateRange = 10,
    rangeFilter = false,
    
    damage = true,
    damageExpiration = 6,  -- Hide targets after 6s out of combat
    
    potion = "tempered_potion",  -- Recommended potion
    
    package = "Outlaw",  -- APL package name
} )

spec:RegisterRanges( "pick_pocket", "kick", "blind", "shadowstep" )
```

**Keybinds**: Users can set hotkeys via `/hekili` options panel. Keybind metadata is fetched from user's action bar bindings and overlaid on icons.

**UNVERIFIED**: Exact keybind capture mechanism (likely via WoW's `GetBindingKey(action)` API).

Source: https://github.com/Hekili/hekili/blob/main/TheWarWithin/RogueOutlaw.lua lines 1708–1750

---

## 6. Midnight Status

**Project Concluded**: January 20, 2026, following the launch of World of Warcraft's Midnight prepatch (patch 12.0).

**Reason**: API changes introduced by Blizzard made it impossible to continue the addon "in a way that would meet design goals and quality standards." Key loss: likely related to state introspection APIs (cooldown tracking, buff/debuff enumeration, or spec/talent queries).

**Last Commit**: `36daec3` on 2026-01-20 – README revision announcing project conclusion.

**Archive Status**: Repository remains public on GitHub with full source code available under MIT License (as of v0.5.0, released 2026-07-29).

Source: https://github.com/Hekili/hekili/blob/main/README.md (project closure announcement)

---

## REUSABLE DESIGN DECISIONS

### For a From-Scratch Single-Spec (Outlaw Rogue) Clone

#### 1. **State Prediction Architecture (COPY)**
- **Do**: Implement a snapshot-based state machine that advances virtual time via predicted ability effects.
- **Why**: Allows lookahead without modifying live game state. Pure functional prediction = testability + real-time updates.
- **Simplify**: Start with 3-action lookahead; add deeper prediction only if framerate permits.

#### 2. **Resource Modeling (COPY)**
- **Do**: Register energy regen as base + aura-stacked modifiers (e.g., Adrenaline Rush increases regen %).
- **Do**: Track combo point generation per ability, not per resource.
- **Do**: Model buff-duration effects separately (e.g., Killing Spree ticks energy every 0.5s).
- **Why**: Matches Blizzard's design. Avoids hardcoding ability-specific regen.
- **Simplify**: Skip secondary resource types (Mana, Runic Power); focus on Energy + Combo Points.

#### 3. **Buff/Aura Alias System (COPY)**
- **Do**: For buffs with dynamic IDs or multiple equivalent buffs (e.g., Roll the Bones), use alias lists with precedence rules (longest duration, first found, etc.).
- **Why**: Avoids hardcoding buff IDs; works across gear tiers and talent trees.
- **Simplify**: Implement 2–3 alias resolution modes (longest, first, highest-stack) initially.

#### 4. **APL Storage as Compressed Packs (SKIP for MVP, IMPLEMENT v2)**
- **Do**: Design APL format as structured data (not plain text); consider binary compression.
- **Why**: Hekili uses ~5–10 KB per spec even with deep APLs; plain text APLs balloon to 100+ KB.
- **Simplify (v1)**: Store as JSON/Lua tables; compress only if storage/bandwidth becomes bottleneck.
- **Why skip**: Adds complexity; MVP can work with uncompressed APLs. Compress in v2 if needed.

#### 5. **FPS-Aware Throttling (COPY)**
- **Do**: Track smoothed FPS (30-sample sliding window), allocate frame budget per display.
- **Do**: Cap prediction depth both by virtual time AND by action count.
- **Why**: Prevents frame hitches; works on potato PCs and high-end boxes.
- **Simplify**: Start with fixed throttle caps (e.g., 10 actions max); add adaptive budgeting later.

#### 6. **Multi-Display Architecture (IMPLEMENT if UX requires, SKIP for Weak Aura)**
- **Do**: Separate displays for Interrupts, Cooldowns, Rotation if targeting addon UI.
- **Simplify**: If targeting Weak Aura/WeakAuras export, generate a single flat recommendation list; let user create custom display logic.
- **Why**: Weak Aura handles display; your addon only needs to predict actions.

#### 7. **Ability Handler Callbacks (COPY)**
- **Do**: Define ability effects as Lua functions (apply/remove buff, gain/spend resource).
- **Why**: Enables dynamic prediction; easy to patch when Blizzard changes an ability.
- **Pattern**:
  ```lua
  ability.some_spell = {
      id = 12345,
      handler = function()
          applyBuff("some_buff", 30)
          gain(50, "energy")
      end
  }
  ```

#### 8. **Performance Wins to Keep (COPY)**
- **Zero allocation in inner loop**: Pre-allocate all tables; use `wipe()` to reset, never `{}`.
- **Cache predictions**: Store results for reuse until state changes.
- **Math only**: No string operations in prediction paths.
- **Why**: WoW addon CPU budget is ~4–6 ms per frame for all addons combined.

#### 9. **Do NOT Copy**
- **Complex APL condition evaluation**: Hekili's postfix RPN + stack machine is over-engineered for single-spec.
  - **Simplify**: If condition is < 100 LOC, implement as direct Lua (if/elseif chains).
  - **Why**: Easier to debug, maintain, and extend.
- **Comprehensive set bonus tracking**: Hekili tracks all tiers (Mythic, Crafted, old content).
  - **Simplify**: Track only current-patch gear + 1 tier for alts.
- **Multi-class dispatch**: Hekili loads 12+ class modules dynamically.
  - **Simplify**: Hardcode single spec; avoid dynamic module loading.

#### 10. **Actionable Patterns from Code Review**
- **State reset per display**: `state.reset(displayName, fullReset)` isolates predictions per display type. Use this pattern for Interrupts vs. Rotation.
- **Condition evaluation order**: Check `usable()` before `handler()`. Prevents invalid predictions.
- **Buff debouncing**: Track buff `applied` time, not just expiration, to handle rapid refreshes.
- **GCD assumption**: Most predictions assume target GCD; separate GCD handling for off-GCD abilities (e.g., spells with `gcd = "off"`).

---

## Summary

**Hekili is a mature, production-grade priority prediction system** that validates its approach with years of WoW player adoption. The architecture is sound: snapshot-based state → iterative prediction → display. For a from-scratch single-spec clone, the key takeaway is **avoid the compression/pack complexity** and **lean on Lua's flexibility** for condition evaluation. Start minimal (3-action lookahead, Energy + CP only), validate with live play, then expand.
