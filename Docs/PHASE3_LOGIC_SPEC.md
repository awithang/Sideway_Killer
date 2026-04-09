# SIDEWAY KILLER — Phase 3 Logic Specification

**Document Version:** 1.0.0 — DRAFT FOR AUDIT  
**Phase:** 3 — Grid System  
**Architect:** KIMI-K2  
**Date:** 2026-04-09  
**Status:** ⏳ PENDING AUDIT (GLM-4.7) + USER APPROVAL  

**Scope:** This document specifies the pure mathematical logic for Grid Spacing (DVASS) and Lot Multiplier systems. It does NOT contain implementation code — only logic design, formulas, constraints, and integration patterns.  

**Reference Documents:**
- `SIDEWAY_KILLER_CORE_LOGIC.md` §1.2 (DVASS), §1.3 (RAKIM), §6.1 (Heat)
- `SYNTHESIS/Grid.md` — Grid spacing debate synthesis
- `SYNTHESIS/Lot_Multiplier.md` — Lot multiplier debate synthesis
- `Docs/GV_SCHEMA.md` — Phase 1 SSoT data mapping

---

## EXECUTIVE SUMMARY

Phase 3 defines the **recovery mechanics** of the SIDEWAY KILLER system:

| Component | Purpose | Execution Path | Latency Budget |
|-----------|---------|----------------|----------------|
| **DVASS Spacing** | Determine optimal distance between grid levels | `OnTick()` conditional branch | < 0.5ms per basket |
| **Lot Multiplier** | Calculate position size for each recovery level | Called during grid addition | < 0.5ms per calculation |
| **Heat Constraint** | Override multiplier based on account exposure | Applied to ALL lot calculations | < 0.1ms |

**Critical Design Principle:** All volatility-dependent calculations (ATR, spread stats) are **pre-computed in the cold path** (`OnTimer()`) and cached. The `OnTick()` path performs only deterministic arithmetic on cached values.

---

## 1. ARCHITECTURE POSITIONING

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         PHASE 3 IN SYSTEM CONTEXT                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  OnTick() Hot Path                                                       │
│  ─────────────────                                                       │
│  1. FastStrikeCheck()        ← Phase 4 (highest priority)              │
│  2. UpdateVirtualTrailing()  ← Phase 5                                  │
│  3. CheckGridLevels()        ← PHASE 3 ENTRY POINT                      │
│     ├─→ GetGridDistance()    ← DVASS spacing calc (cached ATR)         │
│     ├─→ GetLotMultiplier()   ← Lot calc (cached heat + stats)          │
│     └─→ AddGridLevel()       ← Execute order (if conditions met)       │
│                                                                          │
│  OnTimer() Cold Path (1-second interval)                                 │
│  ────────────────────────                                                │
│  • UpdateMarketState()       ← ATR(14), ATR(100), volatility ratio     │
│  • UpdateSpreadStats()       ← EMA spread, standard deviation          │
│  • UpdateHeatCache()         ← Pre-calculate heat for all baskets      │
│  • UpdateBayesianStats()     ← Kelly fraction (if mode = BAYESIAN)     │
│                                                                          │
│  Cache Pre-computation (stored in g_market, g_spreadStats)             │
│  ─────────────────────────                                               │
│  • g_market.volatilityRatio  = ATR(14) / ATR(100)                      │
│  • g_spreadStats.average     = EMA of spread                           │
│  • g_heatCache[]             = Per-basket pre-calculated heat          │
│  • g_kellyCache              = Pre-calculated Kelly multiplier         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. DVASS GRID SPACING LOGIC

### 2.1 Design Authority

**Primary Source:** `SIDEWAY_KILLER_CORE_LOGIC.md` §1.2  
**Supporting Source:** `SYNTHESIS/Grid.md`  

The DVASS (Dynamic Volatility-Adjusted Step Spacing) model computes the price distance required before adding a new recovery level. The spacing adapts to current market volatility using ATR and expands exponentially per level.

### 2.2 Formula Specification

#### Step 1: ATR Normalization

```
ATR_Normalized = ATR(14) / ATR_NormalizationBase
```

| Parameter | Symbol | Default | Range | Description |
|-----------|--------|---------|-------|-------------|
| ATR Period | `ATR(14)` | — | — | 14-period Average True Range |
| Normalization Base | `N_base` | 20.0 | 10.0–50.0 | Divisor to normalize ATR to baseline volatility |

**Rationale:** XAUUSD ATR typically ranges 15–80 points. Dividing by 20.0 produces a normalized value near 1.0 during typical conditions, scaling proportionally during volatile periods.

**Example:**
- ATR(14) = 30 points → Normalized = 30 / 20 = **1.5**
- ATR(14) = 15 points → Normalized = 15 / 20 = **0.75**
- ATR(14) = 60 points → Normalized = 60 / 20 = **3.0**

#### Step 2: Spike Detection Multiplier

```
IF (UseSpikeDetection AND ATR(5) > 1.5 × ATR(14))
    SpikeMultiplier = 1.5
ELSE
    SpikeMultiplier = 1.0
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Fast ATR Period | `ATR(5)` | — | 5-period ATR for spike detection |
| Spike Threshold | `S_thresh` | 1.5 | Ratio triggering spike mode |
| Spike Multiplier | `S_mult` | 1.5 | Additional spacing during spikes |

**Rationale:** When fast ATR exceeds 1.5× standard ATR, the market is experiencing a volatility spike. Increasing spacing by 50% prevents over-trading during chaotic price action.

#### Step 3: Base Step Calculation

```
AdjustedBaseStep = BaseStep × ATR_Normalized × SpikeMultiplier
```

| Parameter | Symbol | Default | Range | Description |
|-----------|--------|---------|-------|-------------|
| Base Step | `B_step` | 250.0 | 50–1000 | Base spacing in points |

**Example:**
- BaseStep = 250, ATR_Normalized = 1.5, Spike = false
- AdjustedBaseStep = 250 × 1.5 × 1.0 = **375 points**

#### Step 4: Level Expansion

```
LevelMultiplier = (1.0 + ExpansionFactor) ^ LevelIndex
FinalStep = AdjustedBaseStep × LevelMultiplier
```

| Parameter | Symbol | Default | Range | Description |
|-----------|--------|---------|-------|-------------|
| Expansion Factor | `E_fac` | 0.3 | 0.1–1.0 | Per-level exponential growth |
| Level Index | `L_idx` | 0–6 | 0–14 | Current level being calculated |

**Mathematical Effect:**

| Level | Multiplier | Final Step (Base=250, ATR=1.0) |
|-------|-----------|--------------------------------|
| 0 (Original) | 1.00 | 250 points |
| 1 | 1.30 | 325 points |
| 2 | 1.69 | 423 points |
| 3 | 2.20 | 549 points |
| 4 | 2.86 | 714 points |
| 5 | 3.71 | 928 points |
| 6 | 4.83 | 1,207 points |
| 7 | 6.27 | 1,569 points |

#### Step 5: Safety Bounds

```
FinalStep = MAX(FinalStep, MinStep)
FinalStep = MIN(FinalStep, MaxStep)
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Minimum Step | `MinStep` | 150.0 | Prevents over-trading in low volatility |
| Maximum Step | `MaxStep` | 1,200.0 | Prevents never-triggering in high volatility |

**Rationale:** Bounds prevent pathological outcomes:
- **MinStep = 150:** Even with ATR = 0 (or very low), grid levels add at reasonable intervals
- **MaxStep = 1,200:** Even with extreme ATR, levels still trigger within observable timeframes

### 2.3 Full Formula (Consolidated)

```
DVASS_Spacing(Level) = 
    CLAMP(
        BaseStep × (ATR(14) / 20.0) × SpikeMult × (1.3 ^ Level),
        MinStep,
        MaxStep
    )
```

### 2.4 Alternative Modes

#### FIXED Mode
```
Spacing(Level) = BaseStep × (FixedExpansion ^ Level)
```
- No ATR dependency
- Predictable, constant logic
- Suitable for novice users

#### HYBRID Mode
```
Regime = DetectRegime(ATR(14))
BaseStep = GetRegimeBaseStep(Regime)      // 180/300/500/800
Expansion = GetRegimeExpansion(Regime)    // 1.2/1.3/1.4/1.5
Spacing(Level) = BaseStep × (Expansion ^ Level)
```

### 2.5 Trigger Condition

A new grid level is added when:

```
FOR BUY Baskets:
    (LastLevelPrice - CurrentBid) ≥ DVASS_Spacing(CurrentLevelCount)

FOR SELL Baskets:
    (CurrentAsk - LastLevelPrice) ≥ DVASS_Spacing(CurrentLevelCount)
```

**Cooldown Protection:** Minimum 30 seconds between grid executions to prevent over-trading during volatile spikes.

### 2.6 Cold-Path Cache Design

To ensure `GetGridDistance()` executes in < 0.5ms during `OnTick()`:

```
┌─────────────────────────────────────────────────────────────┐
│  COLD PATH (OnTimer, every 1s)                              │
│  ─────────────────────────────                              │
│  1. Read ATR(14) from indicator handle                      │
│  2. Read ATR(5) from indicator handle                       │
│  3. Compute g_cachedATR14, g_cachedATR5                     │
│  4. Compute g_cachedSpikeMult                               │
│  5. Compute g_cachedAdjustedBaseStep                        │
│                                                             │
│  HOT PATH (OnTick, conditional)                             │
│  ──────────────────────────────                             │
│  1. Read g_cachedAdjustedBaseStep (O(1))                   │
│  2. Compute (1.3 ^ Level) via MathPow()                     │
│  3. Apply bounds                                            │
│  4. Return result                                           │
└─────────────────────────────────────────────────────────────┘
```

**Cache Invalidation:** ATR values are inherently smooth. The cache is refreshed every second, which is sufficient for grid spacing decisions (grid levels add on price movements of hundreds of points, not tick-by-tick).

---

## 3. LOT MULTIPLIER LOGIC

### 3.1 Design Authority

**Primary Source:** `SIDEWAY_KILLER_CORE_LOGIC.md` §1.3  
**Supporting Source:** `SYNTHESIS/Lot_Multiplier.md`  

The lot multiplier determines the position size for each recovery level. The system supports three modes with a **mandatory heat constraint** applied universally.

### 3.2 Mode Overview

| Mode | Default | Formula | Complexity |
|------|---------|---------|------------|
| FIXED | ✅ Yes | `Base × Decay^Level` | Simple |
| BAYESIAN KELLY | No | `Kelly-derived × Decay^Level` | Advanced |
| HYBRID | No | `Blend(FIXED, Kelly)` | Intermediate |

### 3.3 FIXED Mode

```
Multiplier(Level) = BaseMultiplier × (DecayFactor ^ Level)
```

| Parameter | Symbol | Default | Range | Description |
|-----------|--------|---------|-------|-------------|
| Base Multiplier | `M_base` | 1.5 | 1.1–5.0 | Starting multiplier |
| Decay Factor | `D_fac` | 0.98 | 0.80–1.0 | Per-level reduction |

**Example:**

| Level | Calculation | Multiplier |
|-------|-------------|------------|
| 0 | 1.5 × (0.98^0) | 1.500 |
| 1 | 1.5 × (0.98^1) | 1.470 |
| 2 | 1.5 × (0.98^2) | 1.441 |
| 3 | 1.5 × (0.98^3) | 1.412 |
| 5 | 1.5 × (0.98^5) | 1.356 |
| 7 | 1.5 × (0.98^7) | 1.302 |

**Rationale for Decay:** As the basket goes deeper, risk exposure increases. The decay factor slightly reduces the acceleration, preventing runaway position sizes at deep levels.

### 3.4 BAYESIAN KELLY MODE

#### Step 1: Bayesian Win Rate

```
WinRate = Alpha / (Alpha + Beta)
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Alpha | `α` | 13.0 | Prior wins (0.65 × 20) + actual wins |
| Beta | `β` | 7.0 | Prior losses (0.35 × 20) + actual losses |
| Prior Strength | `P_str` | 20 | Equivalent sample size of prior belief |
| Prior Win Rate | `P_wr` | 0.65 | Expected win rate |

**Initialization:**
```
Alpha_initial = PriorWinRate × PriorStrength = 0.65 × 20 = 13.0
Beta_initial = (1.0 - PriorWinRate) × PriorStrength = 0.35 × 20 = 7.0
```

**Update Rule (on basket close):**
```
IF (profit > 0):
    Wins++, Alpha++
    TotalWinAmount += profit
ELSE:
    Losses++, Beta++
    TotalLossAmount += ABS(profit)
```

#### Step 2: Reward-to-Risk Ratio

```
AvgWin = TotalWinAmount / MAX(Wins, 1)
AvgLoss = TotalLossAmount / MAX(Losses, 1)
b = AvgWin / AvgLoss
```

**Edge Case:** If `Losses = 0` and `TotalLossAmount = 0`, use a default `b = 1.0` to prevent division by zero.

#### Step 3: Kelly Fraction

```
q = 1.0 - WinRate
KellyFraction = (WinRate × b - q) / b
```

**Interpretation:**
- KellyFraction > 0: Positive edge, increase position size
- KellyFraction = 0: Break-even, no edge
- KellyFraction < 0: Negative edge, theoretically don't bet

#### Step 4: Safety Factor (Quarter Kelly)

```
AppliedKelly = KellyFraction × SafetyFactor
KellyMultiplier = 1.0 + AppliedKelly
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Safety Factor | `S_fac` | 0.25 | Quarter Kelly for conservative sizing |

**Rationale:** Full Kelly is too aggressive for trading. Quarter Kelly provides ~50% of the growth rate with dramatically reduced drawdown risk.

#### Step 5: Level Decay

```
LevelDecay = BayesianDecay ^ Level
RawMultiplier = KellyMultiplier × LevelDecay
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Bayesian Decay | `B_decay` | 0.95 | Per-level decay (less aggressive than FIXED) |

#### Step 6: Safety Bounds

```
RawMultiplier = MAX(RawMultiplier, MinMultiplier)
RawMultiplier = MIN(RawMultiplier, MaxMultiplier)
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Minimum | `M_min` | 1.1 | Floor to prevent no-recovery |
| Maximum | `M_max` | 2.5 | Ceiling to prevent catastrophic sizing |

#### Full BAYESIAN Formula

```
BayesianMultiplier(Level) = 
    CLAMP(
        (1.0 + (((α/(α+β)) × b - (1-α/(α+β))) / b) × 0.25) × (0.95 ^ Level),
        1.1,
        2.5
    )
```

### 3.5 HYBRID Mode

The HYBRID mode provides a gradual transition from FIXED to BAYESIAN as trade statistics accumulate.

```
IF (TotalTrades < MinTradesForKelly):
    // Not enough data — use FIXED
    Multiplier = CalculateFixedMultiplier(Level)
ELSE:
    // Blend based on confidence
    TradeRatio = TotalTrades / MinTradesForKelly
    KellyWeight = MIN(TradeRatio, 1.0) × HybridKellyWeight
    FixedWeight = 1.0 - KellyWeight
    
    FixedPart = CalculateFixedMultiplier(Level)
    KellyPart = CalculateBayesianKelly(Level)
    
    Multiplier = FixedWeight × FixedPart + KellyWeight × KellyPart
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Min Trades | `T_min` | 50 | Minimum trades before Kelly influence |
| Kelly Weight | `K_wt` | 0.5 | Maximum Kelly influence (0.0–1.0) |

**Transition Curve:**

| Total Trades | KellyWeight | FixedWeight | Behavior |
|--------------|-------------|-------------|----------|
| 0 | 0.0 | 1.0 | Pure FIXED |
| 25 | 0.25 | 0.75 | Mostly FIXED |
| 50 | 0.50 | 0.50 | Balanced blend |
| 100 | 0.50 | 0.50 | Full Kelly influence |
| 200+ | 0.50 | 0.50 | Full Kelly influence (capped) |

### 3.6 HEAT CONSTRAINT SYSTEM

**Design Authority:** `SIDEWAY_KILLER_CORE_LOGIC.md` §1.3 (Heat Constraint), §6.1 (Heat Calculation)

The Heat Constraint is **NON-NEGOTIABLE** and applies to **ALL** lot multiplier modes (FIXED, BAYESIAN, HYBRID).

#### Heat Calculation

```
BasketDrawdown$ = (WeightedAverage - CurrentPrice) × TotalVolume × ValuePerPoint

Heat% = (BasketDrawdown$ / AccountBalance) × 100

TotalHeat% = SUM(AllBasketHeat%) 
```

| Parameter | Symbol | Default | Description |
|-----------|--------|---------|-------------|
| Value Per Point | `V_pt` | 100.0 | $100 per lot per point (XAUUSD) |
| Max Recovery Heat | `H_max_rec` | 5.0% | Per-basket heat limit |
| Max Total Heat | `H_max_tot` | 10.0% | Account-wide heat limit |

#### Heat Ratio

```
HeatRatio = CurrentHeat / MaximumHeat
```

#### Constraint Application

```
FUNCTION ApplyHeatConstraint(Multiplier):
    HeatRatio = CalculateCurrentHeat() / inpMaxRecoveryHeat
    
    IF (HeatRatio > 0.90):
        // CRITICAL: Force minimum multiplier
        RETURN Heat_MinimumMultiplier        // 1.1
        
    ELSE IF (HeatRatio > 0.70):
        // WARNING: Reduce multiplier by 20%
        RETURN Multiplier × Heat_ReductionFactor    // 0.80
        
    ELSE:
        // NORMAL: Use calculated multiplier
        RETURN Multiplier
```

| Zone | Heat Ratio | Action | Result |
|------|-----------|--------|--------|
| Normal | ≤ 0.70 | None | Multiplier unchanged |
| Warning | 0.70–0.90 | Reduce 20% | Multiplier × 0.80 |
| Critical | > 0.90 | Force minimum | Multiplier = 1.1 |

### 3.7 Heat Constraint × Bayesian Kelly Interaction

This is the **critical integration point** between two advanced systems.

#### Scenario Analysis

**Scenario A: Low Heat, Mature Bayesian Stats**
```
HeatRatio = 0.30 (Normal zone)
BayesianMultiplier = 1.8 (from Kelly formula)

ApplyHeatConstraint(1.8):
    HeatRatio 0.30 ≤ 0.70 → RETURN 1.8

FinalMultiplier = 1.8
```

**Scenario B: Warning Heat, Mature Bayesian Stats**
```
HeatRatio = 0.75 (Warning zone)
BayesianMultiplier = 1.8

ApplyHeatConstraint(1.8):
    HeatRatio 0.75 > 0.70 → RETURN 1.8 × 0.80 = 1.44

FinalMultiplier = 1.44
```

**Scenario C: Critical Heat, Any Mode**
```
HeatRatio = 0.95 (Critical zone)
BayesianMultiplier = 1.8   // or FIXED = 1.5

ApplyHeatConstraint(1.8):
    HeatRatio 0.95 > 0.90 → RETURN 1.1

FinalMultiplier = 1.1
```

**Scenario D: Kelly Suggests High, Heat Constrains**
```
HeatRatio = 0.85 (Warning zone)
BayesianMultiplier = 2.4 (near maximum)

ApplyHeatConstraint(2.4):
    HeatRatio 0.85 > 0.70 → RETURN 2.4 × 0.80 = 1.92

FinalMultiplier = 1.92
```

#### Key Design Decision: Application Order

The Heat Constraint is applied **AFTER** the mode-specific multiplier is calculated, but **BEFORE** broker lot normalization.

```
CORRECT ORDER:
    1. Calculate mode-specific multiplier
    2. ApplyHeatConstraint() ← ALWAYS
    3. NormalizeLot() ← Broker constraints

WRONG ORDER (DO NOT DO):
    1. Calculate mode-specific multiplier
    2. NormalizeLot()
    3. ApplyHeatConstraint() ← Too late!
```

**Rationale:** Applying heat constraint after broker normalization could produce lot sizes that don't reflect the true risk reduction intent. The constraint modifies the *intended* multiplier, which is then normalized.

### 3.8 Final Lot Size Calculation

```
BaseLot = OriginalPositionLotSize
ProposedLot = BaseLot × FinalMultiplier
NormalizedLot = NormalizeLot(ProposedLot)    // Broker min/max/step
```

### 3.9 Cold-Path Cache Design

To ensure `GetLotMultiplier()` executes in < 0.5ms during grid addition:

```
┌─────────────────────────────────────────────────────────────┐
│  COLD PATH (OnTimer, every 1s)                              │
│  ─────────────────────────────                              │
│  1. Update trade statistics (if basket closed)              │
│  2. Recalculate Bayesian Alpha/Beta                         │
│  3. Pre-compute KellyMultiplier (if mode = BAYESIAN)        │
│  4. Pre-compute per-basket heat values                      │
│  5. Store in g_kellyCache, g_heatCache[]                    │
│                                                             │
│  HOT PATH (OnTick, during grid addition)                    │
│  ────────────────────────────────────────                   │
│  1. Read cached heat value (O(1))                          │
│  2. Read cached Kelly multiplier (O(1))                    │
│  3. Compute level decay via MathPow()                       │
│  4. ApplyHeatConstraint() (single comparison)               │
│  5. Return result                                           │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. INTEGRATION WITH PHASE 1 UTILITIES

### 4.1 Utility Function Mapping

| Phase 3 Need | Phase 1 Utility | File | Path |
|--------------|-----------------|------|------|
| ATR(14) | `CalcATR(14)` | `SK_Utils.mqh` | Cold (cached) |
| ATR(5) | `CalcATRFast()` | `SK_Utils.mqh` | Cold (cached) |
| Spread average | `GetAverageSpread(100)` | `SK_Utils.mqh` | Cold (cached) |
| Current spread | `GetCurrentSpread()` | `SK_Utils.mqh` | Cold (cached) |
| Heat calculation | `CalcBasketHeat()` | `SK_Utils.mqh` | Cold (cached) |
| Weighted average update | `UpdateWeightedAverage()` | `SK_Utils.mqh` | Cold (grid addition) |
| Drawdown % | `CalcDrawdownPct()` | `SK_Utils.mqh` | Cold (adoption) |
| Lot normalization | `NormalizeLot()` | `SK_Utils.mqh` | Cold (order prep) |
| GV read/write | `SSoT_GV_*()` | `SK_SSoT.mqh` | Cold only |

### 4.2 Cache Refresh Schedule

| Cached Value | Refresh Rate | Refresh Trigger | Consumer |
|--------------|-------------|-----------------|----------|
| `g_cachedATR14` | 1 second | `OnTimer()` | DVASS spacing |
| `g_cachedATR5` | 1 second | `OnTimer()` | Spike detection |
| `g_cachedSpikeMult` | 1 second | `OnTimer()` | DVASS spacing |
| `g_cachedAdjustedBaseStep` | 1 second | `OnTimer()` | DVASS spacing |
| `g_spreadStats.average` | 1 second | `OnTimer()` | Adaptive filters |
| `g_heatCache[basket]` | 1 second | `OnTimer()` | Heat constraint |
| `g_tradeStats.alpha/beta` | On event | Basket close | Bayesian Kelly |
| `g_kellyCache` | 1 second | `OnTimer()` | Bayesian multiplier |

### 4.3 Hot Path Guarantee

**DVASS Spacing in OnTick():**
```cpp
// Maximum operations per basket:
// 1. Array read: g_cachedAdjustedBaseStep        → O(1)
// 2. MathPow(1.3, level)                         → O(1)
// 3. Multiplication                              → O(1)
// 4. Two comparisons (MIN/MAX)                   → O(1)
// Total: ~4 operations → < 0.1μs per call
```

**Lot Multiplier in Grid Addition:**
```cpp
// Maximum operations:
// 1. Switch on mode                              → O(1)
// 2. Array read (cached Kelly or base mult)      → O(1)
// 3. MathPow(decay, level)                       → O(1)
// 4. Heat comparison (cached)                    → O(1)
// 5. Possible multiplication                     → O(1)
// Total: ~5 operations → < 0.1μs per call
```

**Conclusion:** Both calculations are computationally trivial. The only latency risk is ATR indicator copying, which is entirely isolated to the cold path.

---

## 5. PERFORMANCE BUDGET

### 5.1 Phase 3 Operations Latency

| Operation | Target | Worst Case | Notes |
|-----------|--------|------------|-------|
| `GetGridDistance()` | < 0.1ms | < 0.5ms | With cached ATR |
| `GetLotMultiplier()` | < 0.1ms | < 0.5ms | With cached stats |
| `ApplyHeatConstraint()` | < 0.05ms | < 0.1ms | Single comparison |
| `CheckGridLevels()` (all baskets) | < 1.0ms | < 2.0ms | 20 baskets max |
| Full grid addition (order prep) | < 5.0ms | < 10.0ms | Includes lot calc + order send prep |

### 5.2 Cold Path Pre-computation Budget

| Operation | Target | Notes |
|-----------|--------|-------|
| ATR copy (2 handles) | < 2ms | `CopyBuffer()` calls |
| Heat calculation (all baskets) | < 3ms | Per-basket O(1) |
| Bayesian stats update | < 1ms | Only when trades close |
| Spread EMA update | < 1ms | Single EMA step |
| **Total cold path** | < 10ms | Within 50ms budget |

---

## 6. EDGE CASES & ERROR HANDLING

### 6.1 DVASS Edge Cases

| Scenario | Handling |
|----------|----------|
| ATR(14) = 0 | Fallback to FIXED mode spacing |
| ATR(14) > 200 | Cap at MaxStep, log warning |
| ATR indicator not ready | Skip grid check, retry next tick |
| `MathPow()` overflow (Level > 15) | Hard limit at SK_MAX_LEVELS = 7 |
| Negative spacing | Absolute value + log error |

### 6.2 Lot Multiplier Edge Cases

| Scenario | Handling |
|----------|----------|
| `AvgLoss = 0` (no losses yet) | Set `b = 1.0` to prevent div/0 |
| KellyFraction < 0 | Floor at MinMultiplier (1.1) |
| Heat data unavailable | Assume Normal zone (no constraint) |
| AccountBalance = 0 | Return MinMultiplier, log critical |
| Broker lot step violation | `NormalizeLot()` handles |

### 6.3 Heat Constraint Edge Cases

| Scenario | Handling |
|----------|----------|
| Heat calculation fails | Assume Normal zone (permissive default) |
| Negative heat | Clamp to 0, log warning |
| Heat > 100% | Clamp to 100%, force critical action |
| Multiple baskets at warning | Each individually constrained |

---

## 7. TEST SCENARIOS

### 7.1 DVASS Test Cases

| # | Condition | Expected Spacing (Base=250) |
|---|-----------|----------------------------|
| 1 | ATR=20, Level=0, No spike | 250 points |
| 2 | ATR=30, Level=0, No spike | 375 points |
| 3 | ATR=30, Level=3, No spike | 549 × 1.5 = 824 points |
| 4 | ATR=10, Level=0, No spike | 125 → CLAMPED to 150 |
| 5 | ATR=100, Level=7, No spike | 1569 × 5 = 7845 → CLAMPED to 1200 |
| 6 | ATR=20, Level=0, Spike detected | 250 × 1.5 = 375 points |

### 7.2 Lot Multiplier Test Cases

| # | Mode | Heat | Level | Bayesian State | Expected Mult |
|---|------|------|-------|----------------|---------------|
| 1 | FIXED | 30% | 0 | N/A | 1.500 |
| 2 | FIXED | 30% | 3 | N/A | 1.412 |
| 3 | FIXED | 80% | 0 | N/A | 1.500 × 0.80 = 1.200 |
| 4 | FIXED | 95% | 0 | N/A | 1.100 (forced minimum) |
| 5 | BAYESIAN | 30% | 0 | α=20, β=10, b=1.5 | ~1.45 |
| 6 | BAYESIAN | 80% | 0 | α=20, β=10, b=1.5 | ~1.45 × 0.80 = 1.16 |
| 7 | BAYESIAN | 95% | 3 | α=20, β=10, b=1.5 | 1.100 (heat overrides all) |
| 8 | HYBRID | 30% | 0 | 25 trades | Blend: ~0.75×FIXED + 0.25×Kelly |

---

## 8. DECISION LOG

| Decision | Rationale | Document Reference |
|----------|-----------|-------------------|
| ATR normalization base = 20.0 | Produces ~1.0 during typical XAUUSD conditions | `CORE_LOGIC.md` §1.2 |
| Expansion factor = 0.3 (30%) | Matches original STORM RIDER V5 behavior | `CORE_LOGIC.md` §1.2 |
| Spike threshold = 1.5× | Balances sensitivity vs. false positives | `SYNTHESIS/Grid.md` |
| Spike multiplier = 1.5× | 50% increase sufficient for most spikes | `SYNTHESIS/Grid.md` |
| FIXED decay = 0.98 | Slight reduction, not aggressive | `SYNTHESIS/Lot_Multiplier.md` |
| Bayesian decay = 0.95 | More conservative than FIXED | `SYNTHESIS/Lot_Multiplier.md` |
| Kelly safety factor = 0.25 | Quarter Kelly = optimal risk/growth balance | `CORE_LOGIC.md` §1.3 |
| Prior strength = 20 | Weak prior, lets data dominate quickly | `SYNTHESIS/Lot_Multiplier.md` |
| Heat warning = 70% | Early enough to prevent escalation | `CORE_LOGIC.md` §1.3 |
| Heat critical = 90% | Near-limit, force minimum sizing | `CORE_LOGIC.md` §1.3 |
| Heat constraint AFTER mode calc | Ensures intended risk reduction | §3.7 of this document |
| All ATR cached in cold path | Guarantees hot path < 0.5ms | §2.6, §3.9 of this document |

---

## 9. AUDIT CHECKLIST (FOR GLM-4.7)

Before this specification is approved for implementation, verify:

- [ ] DVASS formula matches `CORE_LOGIC.md` §1.2 exactly
- [ ] Kelly formula matches `CORE_LOGIC.md` §1.3 exactly
- [ ] Heat constraint interaction logic is mathematically sound
- [ ] All parameters have default values within specified ranges
- [ ] Edge cases have defined handling (no undefined behavior)
- [ ] Hot path remains free of indicator/GV calls
- [ ] Cache refresh schedule is sufficient for grid decisions
- [ ] Test scenarios cover normal, boundary, and error conditions
- [ ] No contradictions with `SYNTHESIS/Grid.md` or `SYNTHESIS/Lot_Multiplier.md`

---

## 10. APPROVAL SIGNATURES

| Role | Name | Status | Date |
|------|------|--------|------|
| Architect | KIMI-K2 | ✅ Delivered | 2026-04-09 |
| QA Auditor | GLM-4.7 | ⏳ Pending Audit | — |
| Project Lead | User | ⏳ Pending Approval | — |

---

**END OF PHASE 3 LOGIC SPECIFICATION**

*This document is READ-ONLY until approved. No files shall be modified pending audit and sign-off.*
