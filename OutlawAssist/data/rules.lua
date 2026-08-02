local ADDON_NAME, OA = ...

OA.Rules = {
  -- Mandatory Rule 1: Adrenaline Rush PIN when combo points low and CD ready
  {
    name = "adrenaline_rush_low_cp",
    desc = "Use Adrenaline Rush on cooldown at low combo points",
    action = "PIN",
    kind = "cooldown",
    spellID = 13750,
    itemSlot = nil,
    when = function(S, A)
      return S.inCombat and S.comboPoints <= 2 and S.cooldowns.adrenalineRush.ready
    end,
    source = "outlaw-rotation.md §1 (Priority Order: 'Use on cooldown with 2 or fewer Combo Points'); §2 (APL syntax: adrenaline_rush,if=combo_points<=2); FIX: gated on S.inCombat to prevent pre-pull override of stealth opener"
  },

  -- Mandatory Rule 2: Between the Eyes PIN at high combo points
  {
    name = "between_the_eyes_finisher",
    desc = "Use Between the Eyes at 6+ combo points",
    action = "PIN",
    kind = "finisher",
    spellID = 315341,
    itemSlot = nil,
    when = function(S, A)
      return S.comboPoints >= 6
    end,
    source = "outlaw-rotation.md §1 (Priority Order: 'Between the Eyes – Primary finisher at 6+ Combo Points. Highest damage finisher')"
  },

  -- Mandatory Rule 3: Roll the Bones Stage 1 reroll ADVISE when AR CD > 20s
  {
    name = "rtb_stage1_reroll",
    desc = "Consider rerolling RtB at stage 1 when AR CD remaining > 20s",
    action = "ADVISE",
    kind = "rtb",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.buffs.rtb.stage == 1 and S.cooldowns.adrenalineRush.remaining > 20
    end,
    source = "PLAN.md §3 (Sim-Data Pipeline: 'ADVISE rule when RtB stage=1 and AR CD remaining > 20'); outlaw-rotation.md §1 (Reroll Mechanics)"
  },

  -- Mandatory Rule 4: On-use trinket ADVISE during Adrenaline Rush (slot 13)
  {
    name = "trinket_slot13_during_ar",
    desc = "Use on-use trinket (slot 13) during Adrenaline Rush",
    action = "ADVISE",
    kind = "trinket",
    spellID = nil,
    itemSlot = 13,
    when = function(S, A)
      return S.buffs.adrenalineRush.up and S.trinkets[13].ready and S.trinkets[13].onUse
    end,
    source = "outlaw-rotation.md §4 (On-Use Trinket Strategy: 'Optimal timing: during Adrenaline Rush windows'); verification.md §D2 (On-use trinkets not prioritized)"
  },

  -- Mandatory Rule 5: On-use trinket ADVISE during Adrenaline Rush (slot 14)
  {
    name = "trinket_slot14_during_ar",
    desc = "Use on-use trinket (slot 14) during Adrenaline Rush",
    action = "ADVISE",
    kind = "trinket",
    spellID = nil,
    itemSlot = 14,
    when = function(S, A)
      return S.buffs.adrenalineRush.up and S.trinkets[14].ready and S.trinkets[14].onUse
    end,
    source = "outlaw-rotation.md §4 (On-Use Trinket Strategy: 'Optimal timing: during Adrenaline Rush windows')"
  },

  -- Mandatory Rule 6: Opportunity proc ADVISE
  {
    name = "opportunity_proc",
    desc = "Opportunity proc active - free Pistol Shot available",
    action = "ADVISE",
    kind = "proc",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.buffs.opportunity.up
    end,
    source = "outlaw-rotation.md §1 (Opportunity & Audacity Procs: 'Opportunity: Granted by Sinister Strike double-strikes; enables free Pistol Shot')"
  },

  -- Mandatory Rule 7: Blade Flurry PREFER when AOE mode enabled or enemy count >= 2
  {
    name = "blade_flurry_aoe",
    desc = "Prefer Blade Flurry when AOE mode active, AoE detected in queue, or 2+ enemies engaging",
    action = "PREFER",
    kind = "aoe",
    spellID = 13877,
    itemSlot = nil,
    when = function(S, A)
      local db = OA.db or {}
      local aoeMode = db.aoeMode
      local aoeDetected = (A and A.aoeDetected) or false
      local enemyCountSignal = (S.enemyCount ~= nil and S.enemyCount >= 2) or false
      return aoeMode or aoeDetected or enemyCountSignal
    end,
    source = "CONTRACT.md (Mandatory rules: 'Blade Flurry PREFER when OA.db.aoeMode (manual AoE toggle — enemy counting is not legally readable)'); threat-table detector v0.3 (composite: manual aoeMode OR A.aoeDetected OR (S.enemyCount ~= nil and S.enemyCount >= 2), threshold 2); outlaw-rotation.md §1 (Blade Flurry & AoE Rotation: 'Maintain on 2+ targets')"
  },

  -- Additional Rule 8: Blade Rush on cooldown
  {
    name = "blade_rush_on_cooldown",
    desc = "Use Blade Rush on cooldown as combo-point builder",
    action = "PREFER",
    kind = "cooldown",
    spellID = 271877,
    itemSlot = nil,
    when = function(S, A)
      return S.cooldowns.bladeRush.ready
    end,
    source = "outlaw-rotation.md §1 (Priority Order: 'Blade Rush – Use on cooldown as a regular combo-point builder')"
  },

  -- Additional Rule 9: Sinister Strike at low combo points (P0-3: gate to <= 4 CP, not 5, to avoid demoting finisher at 5 CP)
  {
    name = "sinister_strike_builder",
    desc = "Use Sinister Strike as primary combo-point generator",
    action = "PREFER",
    kind = "builder",
    spellID = 193315,
    itemSlot = nil,
    when = function(S, A)
      -- FIX P0-3: gate to <= 4 CP so Dispatch is not demoted when at 5 CP. Rotation.lua Dispatch_finisher
      -- (priority 10) correctly puts Dispatch first; this PREFER should not override it.
      -- Cost comes from the ability table, never a hardcoded threshold: this said 40
      -- while Sinister Strike actually costs 45, so it recommended an unaffordable cast.
      local ab = OA.Rotation and OA.Rotation.ABILITIES
        and OA.Rotation.ABILITIES[OA.SpellIDs.sinisterStrike]
      local cost = (ab and ab.cost) or 45
      return S.comboPoints <= 4 and S.energy >= cost
    end,
    source = "outlaw-rotation.md §1 (Priority Order: 'Sinister Strike – Bread-and-butter combo-point generator at 5 or fewer Combo Points'); FIX: gated to <= 4 CP to prevent demoting Dispatch finisher (P0-3)"
  },

  -- Additional Rule 10: RtB maintenance during stage progression
  {
    name = "rtb_reroll_stage2",
    desc = "Consider Keep It Rolling at stage 2+ to progress toward stage 4",
    action = "ADVISE",
    kind = "rtb",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.buffs.rtb.stage >= 2 and S.buffs.rtb.stage < 4
    end,
    source = "outlaw-rotation.md §1 (Reroll Mechanics: 'Use Keep It Rolling at Stage 2 or higher to continue rolling and progress toward Stage 4')"
  },

  -- Additional Rule 11: Preparation cooldown tracking
  {
    name = "preparation_ready",
    desc = "Preparation cooldown available to reset major abilities",
    action = "ADVISE",
    kind = "cooldown",
    spellID = 14185,
    itemSlot = nil,
    when = function(S, A)
      return S.cooldowns.preparation.ready and S.cooldowns.adrenalineRush.remaining > 5
    end,
    source = "outlaw-rotation.md §2 (Major DPS Cooldowns: 'Preparation - Resets offensive ability cooldowns when those are unavailable')"
  },

  -- Additional Rule 12: Energy pooling before major cooldowns
  {
    name = "energy_pool_for_ar",
    desc = "Build energy before Adrenaline Rush window",
    action = "ADVISE",
    kind = "resource",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.cooldowns.adrenalineRush.remaining < 3 and S.cooldowns.adrenalineRush.remaining > 0 and S.energy >= 80
    end,
    source = "PLAN.md §3 (Architecture: 'Cooldown Pooling - Query Adrenaline Rush cooldown via C_Spell.GetSpellCooldown()')"
  },

  -- Additional Rule 13: RtB buff tracking for optimal action window
  {
    name = "rtb_stage4_maintenance",
    desc = "Maintain RtB buff, especially at high stages",
    action = "ADVISE",
    kind = "rtb",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.buffs.rtb.expires < 10 and S.buffs.rtb.stage > 0
    end,
    source = "outlaw-rotation.md §1 (Roll the Bones Mechanics: 'Stage resets if the buff expires')"
  },

  -- Additional Rule 14: Opportunity tooltip tracking for high APM gameplay
  {
    name = "opportunity_duration",
    desc = "Monitor Opportunity buff duration for free Pistol Shot timing",
    action = "ADVISE",
    kind = "proc",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.buffs.opportunity.up and S.buffs.opportunity.expires < 3
    end,
    source = "outlaw-rotation.md §1 (Opportunity & Audacity Procs: 'Both procs maintain high action-per-minute gameplay during Adrenaline Rush windows')"
  },

  -- Additional Rule 15: Energy management during high-activity phases
  {
    name = "energy_cap_warning",
    desc = "Monitor energy to avoid overcapping during high-regen phases",
    action = "ADVISE",
    kind = "resource",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.energyMax > 0 and S.energy >= S.energyMax - 10
    end,
    source = "outlaw-rotation.md §1 (Energy & Combo Point Management: 'Baseline Energy Pool: 100 (200 with Vigor talent, 250 during Adrenaline Rush)')"
  },

  -- Additional Rule 16: Blade Rush tier set emphasis
  {
    name = "blade_rush_tier_priority",
    desc = "Prioritize Blade Rush due to tier set bonus",
    action = "PREFER",
    kind = "cooldown",
    spellID = 271877,
    itemSlot = nil,
    when = function(S, A)
      return S.tier.fourPc and S.cooldowns.bladeRush.ready
    end,
    source = "outlaw-rotation.md §4 (Tier Set Bonuses: '4-Piece Bonus: Blade Rush cooldown reduced by 6 seconds')"
  },

  -- Additional Rule 20: Tier set 2-piece Blade Rush damage boost
  {
    name = "blade_rush_tier2pc",
    desc = "Blade Rush damage increased by tier set 2-piece",
    action = "PREFER",
    kind = "cooldown",
    spellID = 271877,
    itemSlot = nil,
    when = function(S, A)
      return S.tier.twoPc and S.cooldowns.bladeRush.ready
    end,
    source = "outlaw-rotation.md §4 (Tier Set Bonuses: '2-Piece Bonus: Blade Rush damage increased by 30%')"
  },

  -- Additional Rule 21: Roll the Bones initial cast
  {
    name = "roll_the_bones_open",
    desc = "Roll the Bones - no buff active, cast it",
    action = "ADVISE",
    kind = "rtb",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.buffs.rtb.stage == 0 and not (S.buffs.rtb.expires > 0)
    end,
    source = "outlaw-rotation.md §1 (Roll the Bones Mechanics: 'Use on cooldown unless already at Stage 2+')"
  },

  -- Additional Rule 22: Pistol Shot fallback at low energy
  {
    name = "pistol_shot_low_energy",
    desc = "Use Pistol Shot as fallback builder when energy low",
    action = "PREFER",
    kind = "builder",
    spellID = nil,
    itemSlot = nil,
    when = function(S, A)
      return S.energy < 40 and S.buffs.opportunity.up
    end,
    resolveSpellID = function()
      return OA.SpellIDs and OA.SpellIDs.pistolShot or nil
    end,
    source = "outlaw-rotation.md §1 (Opportunity & Audacity Procs: 'enables free Pistol Shot without Energy cost') and (Priority Order: 'Pistol Shot – Secondary generator with lower priority than Sinister Strike')"
  },

  -- Additional Rule 23: Stealth before opening
  {
    name = "opener_stealth",
    desc = "Stealth before opening",
    action = "PIN",
    kind = "opener",
    spellID = OA.SpellIDs and OA.SpellIDs.stealth or 1784,
    itemSlot = nil,
    when = function(S, A)
      return not S.inCombat and not S.stealthed
    end,
    source = "v0.3 unified queue engine - stealthing before opening"
  },

  -- Additional Rule 24: Ambush when stealthed (primary stealth opener)
  {
    name = "opener_ambush",
    desc = "Ambush from stealth - primary damage opener",
    action = "PIN",
    kind = "opener",
    spellID = OA.SpellIDs and OA.SpellIDs.ambush or 8676,
    itemSlot = nil,
    when = function(S, A)
      return S.stealthed
    end,
    source = "outlaw-rotation.md §1 (Opener: 'Ambush when available to cast from stealth - primary stealth-locked damage button'); VERIFIED against current guides (Method.gg, Icy Veins)"
  },
}
