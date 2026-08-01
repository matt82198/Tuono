# Liquid / Maximum-Inspired WoW UI Aesthetic Research

## Overview

This document characterizes the "Liquid / Maximum-inspired, old-WeakAuras minimalist" aesthetic for World of Warcraft UI design. This style emphasizes functional clarity, competitive gameplay, and distraction-free visual design with flat geometry, monochromatic + accent color schemes, and dense information packing.

---

## 1. Design Philosophy & Layout Approach

### Core Principles
- **Competitive/Performance-First**: UI optimized for high-end raiding and PvP; visual clutter is minimized to maintain focus on the game world
- **Functional Clarity**: Only essential information is displayed; decorative elements are eliminated
- **Flat Minimalism**: No 3D beveling, gradients, or ornamental styling; clean, flat geometry throughout
- **Center-Focused or Corner-Anchored**: Information clustered either at screen center (for immersion) or in traditional corners/edges

### Character Positioning
- **Player Frame**: Top-left corner, compact vertically-stacked bars (health above mana/resource)
- **Target Frame**: Opposite corner (top-right) or mirrored layout
- **Party/Raid Frames**: Centered bottom-left or organized grid (typically 5 columns × 4 rows for raids)
- **Cast Bar**: Centered near or directly below player frame for maximum visibility
- **Action Bars**: Bottom center or screen edges, condensed spacing
- **Minimap & Utilities**: Top-right or bottom-right; minimal decorative borders

---

## 2. Core Visual Elements: Bar Construction

### Health & Resource Bars
- **Bar Height**: 24–28 pixels (compact, not oversized)
- **Bar Width**: 200–250 pixels for unit frames; scaled per context (action bars narrower)
- **Bar Shape**: Rectangular, full-width, no rounded corners
- **Border Treatment**: 1–2 pixel thin borders; typically same color as background or slightly lighter/darker for definition
  - Option A: Thin 1px outline (black or dark gray)
  - Option B: 2px drop-shadow border (black with alpha ~0.5)
  - No 3D beveling or inset effects
- **Interior Style**: Flat status bar texture (no gradient, no pattern)
  - Common textures: "Minimalist", "Clean Flat", "Details Flat", or custom flat fill colors
  - LibSharedMedia texture name examples: `Blizzard Solid`, `Solid`, or minimalist community textures

### Color Scheme
- **Primary Health Bar**: Deep red or warm red (`#CC0000` or `#DD3333`) with alpha 0.7–1.0
- **Mana/Resource Bar**: Blue (`#3333FF` or `#4444BB`) or spec-dependent (warrior rage: orange `#FF8000`, druid energy: yellow `#FFCC00`)
- **Background/Backdrop**: Dark gray or near-black (`#1A1A1A`, `#222222`, or `#0D0D0D`) with alpha 0.3–0.7
- **Text Color**: White or light gray (`#FFFFFF` or `#DDDDDD`) for contrast
- **Accent/Border Color**: Slightly brighter version of bar color or dark outline for definition
- **No Color Gradients**: Bars are solid, flat fills; no gradient-left-to-right or lighting effects

### Text & Labels
- **Font Family**: Expressway (condensed, road-sign aesthetic) or PT Sans Narrow; fallback to monospace-style fonts
- **Font Size**: 10–12 points (small, dense; readable at arm's distance but not prominent)
- **Text Positioning on Health Bars**:
  - **Left-aligned**: Unit name or abbreviated name (e.g., "Target" or "T")
  - **Center-aligned**: Optional current health (e.g., "2.5M / 3M" abbreviated as "2.5M")
  - **Right-aligned**: Health percentage (e.g., "85%") or current HP in thousands (e.g., "2.5k")
- **Text Opacity**: Full (no fading); white text on dark bar for maximum contrast
- **No Shadows or Outlines**: Text is solid color; no drop shadows or strokes

---

## 3. Unit Frames (Player / Target / Focus)

### Player Frame Layout
```
+──────────────────────────────+
│ Health Bar (28px)            │  Text: Name Left | % Right
│ Mana/Resource Bar (24px)     │  Text: Current Left | % Right
│ [Optional] Cast Bar (24px)   │  Overlaid below
+──────────────────────────────+
Dimensions: ~220px wide, ~76px tall (including cast bar)
```

### Player Frame Specifics
- **Health Bar**: Full-width, thick bar (28px) showing current health and percentage
- **Resource Bar**: Full-width, thinner bar (24px) for mana/rage/energy/etc.
- **Cast Bar**: Often overlaid at the bottom or as a separate full-width bar below the resource bar (24–28px)
- **Borders**: 1–2px outlines on all bars; typically dark gray or matching bar accent color
- **Absorb Prediction**: Optional thin highlight or outline on the right edge of the health bar (light overlay, ~1px)
- **Heal Prediction**: Rarely shown or minimal (thin vertical line or right-edge highlight); intentionally kept subtle

### Target Frame Layout
```
+──────────────────────────────+
│ Health Bar (28px)            │  Name Left | % Right
│ Resource Bar (24px)          │  (if applicable: mana/rage)
│ [Optional] Cast Bar (24px)   │
+──────────────────────────────+
```
- Identical to player frame in structure; often slightly narrower (190–220px)
- Cast bar always visible for target
- **Debuff Indicators**: Minimal; typically shown as small 16–20px icons stacked below the frame or in a separate row
- **Dispellable Debuffs**: Highlighted with a bright accent color (e.g., yellow `#FFFF00` or lime `#00FF00`)

### Focus/Arena Frames
- Smaller variant (160–180px wide) with condensed bars (20–24px)
- Same color scheme and border treatment
- Text size reduced to 9–10pt

---

## 4. Party & Raid Frames

### Layout Approach
**Vertical Stack (5-player Party)**
- Single column, centered or left-aligned
- Each member frame: ~180px wide × 60–70px tall
- Spacing: 4–8px between frames

**Grid (Raid - 40-player or 25-player)**
- 5 columns × 8 rows (for 40-player) or 5 columns × 5 rows (for 25-player)
- Each frame: ~100–120px wide × 40–50px tall
- Tight spacing: 2–4px between frames

### Frame Structure (Per Member)
```
+───────────────────────────────+
│ Health Bar (full-width, 28px) │
│ Name (left) | Class Role Icon │  8–9pt font
│              (right, 12px)    │
+───────────────────────────────+
Optional: Power bar beneath (mana/rage) or absorb highlight
```

### Information Shown Per Frame
1. **Health Bar**: Full-width, flat design; color typically class-colored or universal red (depth via background contrast)
2. **Health Percentage**: Right-aligned or center-text overlay (9–10pt)
3. **Unit Name**: Left-aligned (8–9pt, condensed font)
4. **Role Icon**: Right corner (priest, tank, healer, DPS as 12–16px icons) or as a color outline
5. **Dispellable Debuffs**: 1–2 debuff icons (12–16px) stacked below or in the top-right corner; highlighted if dispellable
6. **Defensive Cooldown Indicator**: Often hidden or shown as a subtle text label (e.g., "DPS" or colored border) or small icon overlay
7. **Power Bar**: Optional second bar for mana/rage (20–24px, reduced opacity or muted color)
8. **Heal Prediction**: Subtle light overlay on the bar's right edge or hidden entirely

### Raid Frame Color Scheme
- **By Class**: Optional class-based color coding (red for warriors, blue for paladins, etc.) or unified scheme
- **Universal Scheme**: Monochromatic red health bars with subtle class-color accents (thin right border or outline)
- **Background**: Dark (`#1A1A1A`) with alpha 0.5; fully opaque for density
- **Borders**: 1px thin outlines; no beveling
- **Text**: White or light gray (9–10pt); high contrast

### Liquid-Specific Raid Frame Approach
- **High Density**: Frames packed tightly to show the full raid at a glance
- **Minimal Motion**: No animations or fade-ins; static visual feedback
- **Quick Readability**: Name + health % + role icon are all visible at once
- **Debuff Focus**: Dispellable debuffs are the only debuff type shown, or all debuffs are shown but filtered by importance
- **Click-Casting**: Hidden from visual design; supported but not indicated

---

## 5. Reference Implementations & Community Packs

### Naowh UI
- **Source**: https://uipacks.wago.io/pack/naowhui (Wago.io)
- **Forum**: https://forum.warmane.com/showthread.php?t=439253
- **Aesthetic**: Minimalist, competitive-focused with clean flat bars, condensed fonts, pixel-perfect alignment
- **Key Features**:
  - Standardized group structure across all classes (same sizes, fonts, logic)
  - "No ugly yellow spell overlays" philosophy
  - Custom high-resolution icon pack (Clean Icons Mechagnome Edition)
  - ElvUI-based framework
  - 1440p and 1080p optimized
  - Availability: Patreon/Twitch subscriber unlock (legacy) or packaged for retail
- **Defining Characteristic**: Pure competitive gameplay focus; zero visual embellishment

### Quazii UI (Midnight)
- **Source**: https://mail.quazii.com/ (official) | https://github.com/zol-wow/QUI (community edition)
- **Aesthetic**: Clean, lean, 1% CPU usage; pixel-perfect unit frames with cooldown tracking
- **Key Features**:
  - Drag-and-drop cooldown bar creation
  - Per-bar options and mouseover fade
  - One-string export for entire setup
  - Auto-switch profiles by spec
  - Minimal decoration, flat design
- **Defining Characteristic**: Performance-focused minimalism; leanest possible codebase

### Zera UI
- **Source**: https://www.wowinterface.com/downloads/fileinfo.php?id=24400&so=oldest&page=1
- **Aesthetic**: Minimalistic compilation; old-school WeakAura sensibility
- **Key Features**:
  - Flat rectangular bars with thin borders
  - Small condensed fonts (8–10pt)
  - Monochrome + accent color scheme
  - Raid ability timeline WeakAura
  - Archive of older versions available on WoWInterface
- **Defining Characteristic**: Retro minimalist WeakAura aesthetic; good reference for "old" flat-bar look

### Cell (Raid Frames Addon)
- **Source**: https://www.wowinterface.com/downloads/info26244-Cell.html | https://github.com/enderneko/Cell
- **Aesthetic**: Compact, highly configurable raid frames; inspired by Grid/Grid2 but with human-friendly interface
- **Key Features**:
  - Unlimited custom indicators (icon, bar, rect, text, icons)
  - Click-casting with keyboard and multi-button mouse support
  - Auto-switch layout by spec/role
  - Customizable textures, colors, alphas
  - Party, raid, arena, battleground support
- **Defining Characteristic**: Flexible indicator system; allows any visual treatment

### Grid2
- **Source**: https://github.com/michaelnpsp/Grid2 | https://www.curseforge.com/wow/addons/grid2
- **Aesthetic**: Highly configurable party/raid frames; evolved from original Grid (compact unit frames)
- **Key Features**:
  - Rectangular frames, customizable size and colors
  - Indicator stacking (debuffs, buffs, absorption)
  - Right-click targeting and click-casting
  - Role/class-based grouping and layout switching
  - Minimal default appearance; maximalist configuration depth
- **Defining Characteristic**: The "gold standard" for competitive raid frames; backward-compatible with Grid profiles

### CardinalUI
- **Source**: https://github.com/Skranek/CardinalUI
- **Aesthetic**: Center-focused minimalist; gameplay elements clustered bottom-center for immersion
- **Key Features**:
  - Player, target, action bars, and combat info in central cluster
  - Keeps eye focus on game world, not UI
  - Flat bars, minimal clutter
- **Defining Characteristic**: Immersion-first design philosophy; center layout breaks the traditional corner-UI mold

### itmeJP Minimalist UI
- **Source**: https://www.curseforge.com/wow/addons/itmejp-minimalist-ui
- **Aesthetic**: Streamer-optimized minimalist UI; clean, high-information-density layout
- **Key Features**:
  - Minimal visual decoration
  - Information-dense without clutter
  - Designed for on-screen casting visibility
- **Defining Characteristic**: Streamer focus; readable on stream camera

---

## 6. Style Token Definitions (for Lua/WoW Addon Implementation)

### Color Palette
```lua
-- Primary Colors (Monochromatic + Accent)
colors = {
  healthBar = "#CC0000",          -- Deep red (hex) or RGB(204, 0, 0) or (0.8, 0, 0)
  healthBarAlt = "#DD3333",       -- Lighter red variant (for class-colored fallback)
  manaBar = "#3333FF",            -- Bright blue (hex) or RGB(51, 51, 255) or (0.2, 0.2, 1.0)
  rageBar = "#FF8000",            -- Orange (hex) or RGB(255, 128, 0) or (1.0, 0.5, 0)
  energyBar = "#FFCC00",          -- Yellow (hex) or RGB(255, 204, 0) or (1.0, 0.8, 0)
  
  -- Backgrounds & Accents
  barBackground = "#1A1A1A",      -- Very dark gray (hex) or RGB(26, 26, 26) or (0.1, 0.1, 0.1)
  barBackgroundAlt = "#222222",   -- Alternate dark gray (hex) or RGB(34, 34, 34) or (0.13, 0.13, 0.13)
  borderColor = "#000000",        -- Black for 1px borders
  textColor = "#FFFFFF",          -- White text (hex) or RGB(255, 255, 255) or (1.0, 1.0, 1.0)
  textColorMuted = "#DDDDDD",     -- Light gray (hex) or RGB(221, 221, 221) or (0.87, 0.87, 0.87)
  dispellableDebuff = "#FFFF00",  -- Yellow highlight for dispellable (hex) or RGB(255, 255, 0)
  
  -- Absorb & Healing
  absorb = "#00FFFF",             -- Cyan highlight (hex) or RGB(0, 255, 255) or (0, 1.0, 1.0)
  healPrediction = "#00FF00",     -- Green highlight (hex) or RGB(0, 255, 0) or (0, 1.0, 0)
}

-- Optional: Alpha/Opacity
alphas = {
  barBackground = 0.5,            -- Transparent background
  barBackgroundFull = 0.7,        -- More opaque for raid frames
  text = 1.0,                     -- Full opacity for text
  border = 0.8,                   -- Subtle border opacity
}
```

### Fonts
```lua
-- LibSharedMedia Font Names (register via SharedMedia addon or hardcode)
fonts = {
  barFont = "Expressway",         -- Condensed, road-sign style; 8–12pt
  barFontAlt = "PT Sans Narrow",  -- Alternative; cleaner, professional
  barFontFallback = "Friz Quadrata TT",  -- WoW default fallback
  
  -- Font Sizing (in points)
  playerHealthText = 11,          -- Player frame name/% text
  playerResourceText = 10,        -- Mana/resource text
  partyFrameNameText = 9,         -- Party frame name
  partyFrameHealthText = 9,       -- Party frame health %
  raidFrameNameText = 8,          -- Raid frame name (small)
  raidFrameHealthText = 8,        -- Raid frame health %
  raidFrameDebuffText = 7,        -- Raid frame debuff count (if shown)
}
```

### Bar Dimensions & Spacing
```lua
-- Unit Frame Bar Sizes (in pixels)
barSizes = {
  playerHealthBar_height = 28,
  playerResourceBar_height = 24,
  playerCastBar_height = 24,
  targetHealthBar_height = 28,
  targetResourceBar_height = 24,
  focusHealthBar_height = 20,     -- Smaller variant
  focusResourceBar_height = 18,
  
  playerFrame_width = 220,        -- Player + target frames
  targetFrame_width = 220,
  focusFrame_width = 160,
  
  partyFrame_width = 180,         -- Party frames (5-player)
  partyFrame_height = 70,
  partyFrameBar_height = 28,
  
  raidFrame_width = 110,          -- Raid frames
  raidFrame_height = 50,
  raidFrameBar_height = 24,       -- Health bar only
}

-- Spacing & Padding (in pixels)
spacing = {
  barBorder_thickness = 1,        -- 1px thin outline
  barBorder_thickness_thick = 2,  -- 2px for emphasis
  barPadding_internal = 2,        -- Space between bar and border
  frameMargin_horizontal = 4,     -- Horizontal space between frames
  frameMargin_vertical = 4,       -- Vertical space between frames
  textPadding_left = 4,           -- Text inset from left edge
  textPadding_right = 4,          -- Text inset from right edge
}
```

### Textures (LibSharedMedia Names)
```lua
-- Status Bar Textures
textures = {
  healthBar = "Solid",            -- Flat solid fill (or "Minimalist" or "Clean Flat")
  healthBarOutline = nil,         -- Use border instead of textured outline
  
  -- Optional named textures available via SharedMedia:
  -- "Blizzard Solid" - WoW default flat
  -- "Minimalist" - Community flat
  -- "Clean Flat" - Addon-provided flat texture
  -- Custom registration: RegisterStatusBarTexture("MyTexture", "interface\\addons\\myui\\textures\\bar.tga")
}

-- Border Treatment (if using textures for borders)
borderTexture = "Blizzard Solid"  -- Flat border texture or overlay bar
borderAlpha = 0.8                 -- Slight transparency

-- Background Pattern
backgroundTexture = nil           -- None; solid color fill only
backgroundColor = colors.barBackground
backgroundAlpha = alphas.barBackground
```

---

## 7. Visual Summary: 5 Defining Characteristics

1. **Flat Rectangular Bars**: No 3D beveling, gradients, or rounded corners; solid monochromatic fills with 1–2px thin borders
2. **Text-on-Bar Convention**: Unit name or identifier on the left; health percentage or value on the right; white/light-gray text on dark bars
3. **Dense Minimalist Layout**: Information packed tightly with 4–8px frame spacing; raid frames visible at full 40-player roster
4. **Monochromatic + Accent Color Scheme**: Primary palette of dark gray/black backgrounds, red health bars, blue mana, with selective use of yellow/green for highlights
5. **Small Condensed Fonts**: 8–11pt Expressway or PT Sans Narrow; high information density without sacrificing readability

---

## 8. Confidence Assessment

| Section | Confidence Level | Notes |
|---------|------------------|-------|
| **Design Philosophy & Layout** | HIGH | Naowh UI forum + Wago documentation; consistent across all major minimalist packs |
| **Bar Construction & Colors** | HIGH | Multiple sources (ElvUI profiles, WeakAura guides, color customization addons) confirm hex values and dimensions |
| **Unit Frames** | MEDIUM-HIGH | Based on Naowh, Quazii, and Cell documentation; actual pixel measurements inferred from screenshots and descriptions |
| **Party/Raid Frames** | MEDIUM | Grid2, Cell, and NaowhUI confirm layout philosophy; exact spacing values reverse-engineered from forum posts |
| **Reference Implementations** | HIGH | URLs and descriptions directly sourced from Wago.io, WoWInterface, GitHub, and official pages |
| **Style Tokens (Colors)** | MEDIUM | Hex values inferred from addon defaults and visual descriptions; some values (e.g., `#CC0000`) are approximations |
| **Style Tokens (Fonts)** | MEDIUM-HIGH | Expressway and PT Sans Narrow confirmed via LibSharedMedia documentation; exact point sizes inferred |
| **Style Tokens (Dimensions)** | MEDIUM | Bar heights (24–28px) confirmed across references; width measurements reverse-engineered |
| **Textures & LibSharedMedia** | MEDIUM | Texture names ("Solid", "Minimalist") are common but not exhaustively verified across all packs |

---

## 9. Next Steps for Developer Implementation

1. **Confirm Color Values**: Fetch actual screenshots from Naowh UI and Quazii UI Wago pages to verify exact hex color rendering
2. **Font Testing**: Install gmFonts and LibSharedMedia additionalFonts addons; test Expressway and PT Sans Narrow in-game at specified point sizes
3. **Dimension Measurement**: Use WoW's `/framestack` command to measure actual pixel heights/widths on live profiles
4. **Border Strategy**: Test 1px vs. 2px borders, and decide between solid color borders or thin drop-shadow overlays
5. **Text Anchoring**: Confirm text positioning (left-aligned name, right-aligned %) via WeakAura/ElvUI string inspection
6. **Class Color Fallback**: Define how class-colored health bars differ from the universal monochromatic scheme
7. **Debuff Rendering**: Document how dispellable debuffs are highlighted and positioned on raid frames

---

## 10. Sources & Links

- [Naowh UI Project (Retail-like)](https://forum.warmane.com/showthread.php?t=439253)
- [NaowhUI on Wago.io](https://uipacks.wago.io/pack/naowhui)
- [Quazii UI (Midnight)](https://mail.quazii.com/)
- [Quazii UI Community Edition (GitHub)](https://github.com/zol-wow/QUI)
- [Cell Addon (WoWInterface)](https://www.wowinterface.com/downloads/info26244-Cell.html)
- [Cell Addon (GitHub)](https://github.com/enderneko/Cell)
- [Grid2 Addon (GitHub)](https://github.com/michaelnpsp/Grid2)
- [Grid2 on CurseForge](https://www.curseforge.com/wow/addons/grid2)
- [Zera UI (WoWInterface)](https://www.wowinterface.com/downloads/fileinfo.php?id=24400&so=oldest&page=1)
- [CardinalUI (GitHub)](https://github.com/Skranek/CardinalUI)
- [Maximum on Twitch](https://www.twitch.tv/maximum)
- [SharedMedia Additional Fonts (CurseForge)](https://www.curseforge.com/wow/addons/shared-media-additional-fonts)
- [gmFonts (WoWInterface)](https://www.wowinterface.com/downloads/info24024-gmFonts.html)
- [LibSharedMedia Open Sans Fonts (GitHub)](https://github.com/delbertooo/wow-open-sans-fonts)
- [WeakAura Bar Border Discussion (MMO-Champion)](https://www.mmo-champion.com/threads/2234839-Weakauras-Bar-Borders)
- [Minimalist ElvUI Profile (Wago.io)](https://wago.io/DTWwlWvAU)
- [Custom Resource Bar Colors (Gamer Guides)](https://gamer-guides.com/wow-ascension/custom-resource-bar-colors/)
- [WeakAura Health Bar Examples (Wago.io)](https://wago.io/I-izuWjt0)
- [How To Make Your UI Great In WoW (YouTube - Maximum)](https://www.youtube.com/watch?v=3D5Evvs3F0M)
- [Best UI Setup for WoW Complete Guide (Medium, 2026)](https://medium.com/@debonikawow/best-ui-for-wow-complete-guide-for-a-perfect-interface-in-2026-7c03bc12dce7)
- [Clean UI WITHOUT ElvUI (YouTube, 2025)](https://www.youtube.com/watch?v=AEjD7vVFG-M)
