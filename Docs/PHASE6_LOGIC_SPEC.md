# SIDEWAY KILLER — Phase 6 Logic Specification

**Document Version:** 1.0.0 — DRAFT FOR AUDIT  
**Phase:** 6 — Heat & Safety System (Portfolio Thermostat)  
**Architect:** KIMI-K2  
**Date:** 2026-04-09  
**Status:** ⏳ PENDING AUDIT (GLM-4.7) + USER APPROVAL  

**Scope:** Portfolio-level risk management system. Logic design only — no implementation code.  

**Design Authority:**
- `SIDEWAY_KILLER_CORE_LOGIC.md` §6.1–6.2 (Heat Calculation, Safety Halts)
- `Docs/PHASE3_LOGIC_SPEC.md` §3.6–3.7 (Heat Constraint in Lot Multiplier)
- `Docs/PHASE5_LOGIC_SPEC.md` §4.3 (Protection Level based on Heat)
- `SYNTHESIS/SSoT.md` (State persistence requirements)

---

## EXECUTIVE SUMMARY

Phase 6 implements the **portfolio thermostat** — an automated risk management system that monitors account health across four dimensions (Recovery Heat, Total Heat, Spread, Margin) and enforces graduated trading restrictions to prevent catastrophic drawdown.

**Core Principle:** The system uses **graduated responses** — each guard restricts a specific scope of operations without disabling the entire system. Profit-taking mechanisms (FastStrike, VirtualTrailing) always remain active.

| Guard | Threshold | Scope of Restriction | Profit-Taking |
|-------|-----------|---------------------|---------------|
| Recovery Heat | > 5% | Per-basket grid additions | ✅ Active |
| Total Heat | > 10% | All new adoptions | ✅ Active |
| Spread Guard | > 100 pts | All new operations | ✅ Active |
| Margin Guard | < 200% | All new operations | ✅ Active |

**Key Design Decision:** Heat calculations use **drawdown-based** metrics (unrealized loss) rather than exposure-based metrics. This directly measures the risk that matters — how much the portfolio is currently losing.

---

## 1. ARCHITECTURE POSITIONING

### 1.1 System Context

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   PHASE 6 IN SYSTEM CONTEXT                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    PHASE 6: HEAT & SAFETY                        │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │   │
│  │  │   HEAT      │  │   SPREAD    │  │   MARGIN    │             │   │
│  │  │  MONITOR    │  │   GUARD     │  │   GUARD     │             │   │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘             │   │
│  │         │                │                │                     │   │
│  │         └────────────────┴────────────────┘                     │   │
│  │                      │                                          │   │
│  │         ┌────────────┴────────────┐                            │   │
│  │         ▼                         ▼                            │   │
│  │  ┌─────────────┐          ┌─────────────┐                      │   │
│  │  │   HALT      │          │  AUTO-RESUME│                      │   │
│  │  │  CONTROLLER │          │   PROTOCOL  │                      │   │
│  │  └─────────────┘          └─────────────┘                      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  Interactions with other phases:                                        │
│  • Phase 3 (Grid): Heat > 5% → blocks CheckGridLevels()                │
│  • Phase 3 (Lot): Heat > 70% → reduces multiplier (already spec'd)     │
│  • Phase 3 (Lot): Heat > 90% → forces minimum multiplier               │
│  • Phase 2 (Adoption): Total Heat > 10% → blocks Adoption_ExecuteScan()│
│  • Phase 5 (Trailing): Heat drives checkpoint frequency                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Execution Placement

```cpp
void OnTimer()    // Cold path — every 1 second
{
    // ... other timer operations ...
    
    // ═══════════════════════════════════════════════════════
    // PHASE 6: HEAT & SAFETY (executed every 1 second)
    // ═══════════════════════════════════════════════════════
    CheckHeatLimits();           // Update heat, enforce hierarchy
    CheckSpreadGuard();          // Monitor spread
    CheckMarginGuard();          // Monitor margin
    UpdateHaltController();      // Manage halt states
    CheckAutoResumeConditions(); // Evaluate normalization
    
    // ... rest of timer operations ...
}
```

**Rationale:** Heat, spread, and margin are slowly-changing conditions. Monitoring every 1 second is sufficient and avoids hot-path overhead.

---

## 2. HEAT CALCULATION

### 2.1 Formula Specification

#### Per-Basket Recovery Heat

```
RecoveryHeat%(Basket) = (BasketDrawdown$ / AccountBalance) × 100

WHERE:
    BasketDrawdown$ = ABS(WeightedAverage - CurrentPrice) × TotalVolume × ValuePerPoint

FOR BUY Baskets:
    IF (CurrentPrice ≥ WeightedAverage)
        BasketDrawdown$ = 0    // In profit, no drawdown heat
    ELSE
        BasketDrawdown$ = (WeightedAverage - CurrentPrice) × TotalVolume × 100.0

FOR SELL Baskets:
    IF (CurrentPrice ≤ WeightedAverage)
        BasketDrawdown$ = 0    // In profit, no drawdown heat
    ELSE
        BasketDrawdown$ = (CurrentPrice - WeightedAverage) × TotalVolume × 100.0
```

**Key Insight:** Heat is **zero** when a basket is in profit. Heat only measures the "bad" side — how much unrealized loss exists.

#### Total Portfolio Heat

```
TotalHeat% = SUM(RecoveryHeat% of ALL baskets)
           = SUM(BasketDrawdown$ of ALL baskets) / AccountBalance × 100
```

**Simplified:**
```
TotalDrawdown$ = Σ BasketDrawdown$(i)  for i = 0 to g_basketCount-1
TotalHeat% = (TotalDrawdown$ / AccountBalance) × 100
```

#### Example Calculation

**Account:** Balance = $10,000

| Basket | Direction | WA | Current | Volume | Drawdown $ | Recovery Heat |
|--------|-----------|-----|---------|--------|-----------|---------------|
| 1 | BUY | 2050.00 | 2048.50 | 0.30 | (1.50 × 0.30 × 100) = $45.00 | 0.45% |
| 2 | SELL | 2045.00 | 2046.20 | 0.20 | (1.20 × 0.20 × 100) = $24.00 | 0.24% |
| 3 | BUY | 2048.00 | 2049.50 | 0.25 | In profit → $0.00 | 0.00% |
| **TOTAL** | | | | | **$69.00** | **0.69%** |

### 2.2 Performance Optimization

**Cold-Path Pre-computation:**
```
FUNCTION UpdateHeatCache()
    
    totalDrawdown = 0.0
    
    FOR i = 0 TO g_basketCount - 1:
        IF (NOT g_baskets[i].isValid)
            g_heatCache[i] = 0.0
            CONTINUE
        
        // Get appropriate price
        IF (g_baskets[i].direction == BUY)
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID)
        ELSE
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
        
        // Calculate drawdown (0 if in profit)
        IF (g_baskets[i].direction == BUY)
            IF (currentPrice >= g_baskets[i].weightedAvg)
                drawdown = 0.0
            ELSE
                drawdown = (g_baskets[i].weightedAvg - currentPrice) × g_baskets[i].totalVolume × 100.0
        ELSE
            IF (currentPrice <= g_baskets[i].weightedAvg)
                drawdown = 0.0
            ELSE
                drawdown = (currentPrice - g_baskets[i].weightedAvg) × g_baskets[i].totalVolume × 100.0
        
        g_heatCache[i] = drawdown
        totalDrawdown += drawdown
    END FOR
    
    balance = AccountInfoDouble(ACCOUNT_BALANCE)
    
    IF (balance > 0)
        g_totalHeat = (totalDrawdown / balance) × 100.0
    ELSE
        g_totalHeat = 0.0    // Prevent division by zero
    
END FUNCTION
```

**Cache Usage:**
- `g_heatCache[i]` — Per-basket drawdown in $ (used by Lot Multiplier Heat Constraint)
- `g_totalHeat` — Total portfolio heat % (used by Safety System)

---

## 3. HEAT HIERARCHY & TRIGGER ACTIONS

### 3.1 Hierarchy Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      HEAT HIERARCHY PYRAMID                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│                         ┌─────────────┐                                  │
│                         │  TOTAL HEAT │ > 10%                            │
│                         │   > 10%     │ → HALT ALL ADOPTIONS             │
│                         └──────┬──────┘                                  │
│                                │                                         │
│                    ┌───────────┴───────────┐                             │
│                    ▼                       ▼                             │
│           ┌─────────────┐          ┌─────────────┐                       │
│           │ RECOVERY    │          │   WARNING   │                       │
│           │   HEAT      │ > 5%     │    ZONE     │ 7–10%                 │
│           │   > 5%      │ → HALT   │             │ → Alert only          │
│           │             │   GRID   │             │                       │
│           └─────────────┘          └─────────────┘                       │
│                                                                          │
│  Scope of Impact:                                                        │
│  • Recovery Heat > 5%: Single basket cannot add levels                   │
│  • Total Heat 7–10%: Warning logged, no action                          │
│  • Total Heat > 10%: No new baskets can be adopted                       │
│                                                                          │
│  What ALWAYS works:                                                      │
│  ✓ FastStrike profit detection                                          │
│  ✓ VirtualTrailing trend following                                      │
│  ✓ Emergency physical stops                                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Recovery Heat > 5% — Per-Basket Grid Halt

**Trigger Condition:**
```
RecoveryHeat%(Basket) > MaxRecoveryHeat    // 5.0%
```

**Action:**
```
FUNCTION EnforceRecoveryHeatLimit(basketIndex)
    
    heat = (g_heatCache[basketIndex] / AccountBalance) × 100
    
    IF (heat > inpMaxRecoveryHeat)    // 5.0
        
        IF (NOT g_recoveryHalted[basketIndex])
            // First time crossing threshold
            g_recoveryHalted[basketIndex] = true
            g_recoveryHaltTime[basketIndex] = TimeCurrent()
            
            Print("RECOVERY HALT: Basket ", basketIndex,
                  " heat = ", DoubleToString(heat, 2), "%",
                  " — Grid additions suspended")
        END IF
        
        RETURN false    // Do not allow grid addition
    ELSE
        
        IF (g_recoveryHalted[basketIndex])
            // Heat has dropped below threshold
            g_recoveryHalted[basketIndex] = false
            
            Print("RECOVERY RESUME: Basket ", basketIndex,
                  " heat = ", DoubleToString(heat, 2), "%",
                  " — Grid additions resumed")
        END IF
        
        RETURN true     // Allow grid addition
    END IF
    
END FUNCTION
```

**Integration Point (Phase 3):**
```cpp
// In CheckGridLevels() — before adding a new level:
IF (NOT EnforceRecoveryHeatLimit(basketIndex))
    CONTINUE    // Skip this basket — recovery halted
```

**Visual Indicator:**
- Dashboard shows "🔒 HEAT" next to affected basket
- Breakeven line changes color (gold → orange)

### 3.3 Total Heat > 10% — Global Adoption Halt

**Trigger Condition:**
```
TotalHeat% > MaxTotalHeat    // 10.0%
```

**Action:**
```
FUNCTION EnforceTotalHeatLimit()
    
    IF (g_totalHeat > inpMaxTotalHeat)    // 10.0
        
        IF (NOT g_adoptionHalted)
            // First time crossing threshold
            g_adoptionHalted = true
            g_adoptionHaltTime = TimeCurrent()
            
            Alert("TOTAL HEAT HALT: Portfolio heat = ",
                  DoubleToString(g_totalHeat, 2), "%",
                  " — New basket adoption suspended")
            
            Print("Total Heat = ", g_totalHeat, "%",
                  " — Max = ", inpMaxTotalHeat, "%")
        END IF
        
        RETURN false    // Do not allow new adoptions
    ELSE
        
        IF (g_adoptionHalted)
            // Heat has dropped — auto-resume handles this
            // (see Section 6 for Auto-Resume Protocol)
        END IF
        
        RETURN true     // Allow new adoptions
    END IF
    
END FUNCTION
```

**Integration Point (Phase 2):**
```cpp
// In Adoption_ExecuteScan() — before evaluating candidates:
IF (NOT EnforceTotalHeatLimit())
    RETURN    // Skip entire adoption scan
```

### 3.4 Warning Zone (Total Heat 7–10%)

**Purpose:** Early warning before hard halt. Allows traders to manually intervene.

```
FUNCTION CheckHeatWarning()
    
    warningThreshold = inpMaxTotalHeat × 0.70    // 10.0 × 0.70 = 7.0%
    
    IF (g_totalHeat > warningThreshold AND NOT g_heatWarningActive)
        g_heatWarningActive = true
        g_heatWarningTime = TimeCurrent()
        
        Alert("HEAT WARNING: Portfolio heat = ",
              DoubleToString(g_totalHeat, 2), "%",
              " — Approaching limit of ", inpMaxTotalHeat, "%")
    
    ELSE IF (g_totalHeat < warningThreshold × 0.80 AND g_heatWarningActive)
        g_heatWarningActive = false
        
        Print("Heat warning cleared — Portfolio heat = ",
              DoubleToString(g_totalHeat, 2), "%")
    END IF
    
END FUNCTION
```

**Dashboard Display:**
- Heat < 7%: Green
- Heat 7–10%: Orange (warning)
- Heat > 10%: Red (halted)

### 3.5 Summary of Heat Actions

| Heat Condition | Threshold | Action | Scope |
|----------------|-----------|--------|-------|
| Recovery Heat Normal | ≤ 5% | Allow grid additions | Per-basket |
| Recovery Heat High | > 5% | **Halt grid additions** | Per-basket |
| Total Heat Normal | ≤ 7% | No action | — |
| Total Heat Warning | 7–10% | Alert only | Global |
| Total Heat Critical | > 10% | **Halt all adoptions** | Global |

---

## 4. SPREAD GUARD

### 4.1 Purpose

XAUUSD spreads can widen dramatically during:
- News events (NFP, FOMC, CPI)
- Market open/close transitions
- Low liquidity periods (Asian session start)
- Broker maintenance windows

Trading during extreme spread conditions is dangerous because:
- Entry prices are unfavorable
- Virtual trailing calculations become inaccurate
- Slippage on close can exceed profit margin

### 4.2 Trigger Logic

```
FUNCTION CheckSpreadGuard()
    
    currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
    
    IF (currentSpread > inpMaxSpreadPoints)    // 100 points
        
        IF (NOT g_spreadHalted)
            g_spreadHalted = true
            g_spreadHaltTime = TimeCurrent()
            g_spreadAtHalt = currentSpread
            
            Alert("SPREAD HALT: Current spread = ", currentSpread,
                  " points — Max = ", inpMaxSpreadPoints,
                  " — Trading suspended")
        END IF
        
    ELSE IF (g_spreadHalted)
        // Spread improved — auto-resume evaluates (see Section 6)
    END IF
    
END FUNCTION
```

**Configuration:**
```cpp
input int inpMaxSpreadPoints = 100;    // Halt if spread > 100 points
```

**Impact Scope:**
- Grid additions: ❌ Halted
- New adoptions: ❌ Halted
- FastStrike: ✅ Still active (uses conservative math)
- VirtualTrailing: ✅ Still active (but may trigger more conservatively)

### 4.3 Spread-Based Adaptive Behavior

Even when spread is below the halt threshold, elevated spread can affect other systems:

```
// In adoption logic (Phase 2):
IF (currentSpread > g_spreadStats.average × 2.0)
    // Smart mode: Increase minimum age by 50%
    minAge = minAge × 1.5
```

This is specified in `Docs/ADOPTION_PROTOCOL.md` and reinforced here.

---

## 5. MARGIN GUARD

### 5.1 Purpose

Margin level indicates how much free capital remains. A margin level below 200% means:
- Less than 2:1 cushion against adverse movement
- Approaching potential margin call territory
- High risk of forced position closure by broker

### 5.2 Trigger Logic

```
FUNCTION CheckMarginGuard()
    
    marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)
    
    // Handle case where margin = 0 (no open positions)
    IF (marginLevel == 0)
        g_marginHalted = false
        RETURN
    
    IF (marginLevel < inpMinMarginPercent)    // 200%
        
        IF (NOT g_marginHalted)
            g_marginHalted = true
            g_marginHaltTime = TimeCurrent()
            g_marginAtHalt = marginLevel
            
            Alert("MARGIN HALT: Margin level = ",
                  DoubleToString(marginLevel, 1), "%",
                  " — Min = ", inpMinMarginPercent, "%",
                  " — Trading suspended")
        END IF
        
    ELSE IF (g_marginHalted)
        // Margin improved — auto-resume evaluates (see Section 6)
    END IF
    
END FUNCTION
```

**Configuration:**
```cpp
input double inpMinMarginPercent = 200.0;    // Halt if margin < 200%
```

**Impact Scope:** Same as Spread Guard — all new operations halted, profit-taking remains active.

### 5.3 Margin Calculation Reference

```
Margin Level = (Equity / Margin) × 100

WHERE:
    Equity = Balance + Floating P&L
    Margin = Total margin used by all positions
```

**Example:**
- Balance: $10,000
- Floating P&L: −$500
- Equity: $9,500
- Margin Used: $4,000
- Margin Level: (9,500 / 4,000) × 100 = **237.5%** ✅

If equity drops to $7,500 with same margin:
- Margin Level: (7,500 / 4,000) × 100 = **187.5%** ❌ HALT

---

## 6. AUTO-RESUME PROTOCOL

### 6.1 Design Principle

Simple threshold-crossing can cause **oscillation** (halt → resume → halt → resume) when conditions hover near the boundary. The Auto-Resume Protocol prevents this using:

1. **Hysteresis:** Resume threshold is lower (or higher) than halt threshold
2. **Time Delay:** Condition must persist for a minimum duration
3. **Combined Validation:** Both conditions must be met

### 6.2 Resume Thresholds (Hysteresis)

| Guard | Halt Threshold | Resume Threshold | Hysteresis |
|-------|---------------|------------------|------------|
| Recovery Heat | > 5.0% | < 4.0% | 20% buffer |
| Total Heat | > 10.0% | < 8.0% | 20% buffer |
| Spread | > 100 pts | < 80 pts | 20% buffer |
| Margin | < 200% | > 240% | 20% buffer |

**Formula:**
```
ResumeThreshold = HaltThreshold × (1.0 - HysteresisPercent)    // For upper-bound guards
ResumeThreshold = HaltThreshold × (1.0 + HysteresisPercent)    // For lower-bound guards

WHERE HysteresisPercent = 0.20 (20%)
```

### 6.3 Time Delay

```
ResumeTimeDelay = 60 seconds    // Condition must persist for 1 minute
```

**Rationale:** 
- 60 seconds filters out transient spikes
- Long enough to confirm genuine normalization
- Short enough to resume quickly when conditions truly improve

### 6.4 Auto-Resume Algorithm

```
FUNCTION CheckAutoResumeConditions()
    
    currentTime = TimeCurrent()
    
    // ═══════════════════════════════════════════════════════
    // RECOVERY HEAT AUTO-RESUME (Per-basket)
    // ═══════════════════════════════════════════════════════
    FOR i = 0 TO g_basketCount - 1:
        IF (g_recoveryHalted[i])
            
            heat = (g_heatCache[i] / AccountBalance) × 100
            resumeThreshold = inpMaxRecoveryHeat × 0.80    // 5.0 × 0.80 = 4.0%
            
            IF (heat < resumeThreshold)
                
                // Check if condition has persisted long enough
                IF (currentTime - g_recoveryHaltTime[i] > ResumeTimeDelay)
                    
                    g_recoveryHalted[i] = false
                    
                    Print("AUTO-RESUME: Basket ", i,
                          " recovery heat normalized to ",
                          DoubleToString(heat, 2), "%",
                          " — Grid additions resumed")
                END IF
            ELSE
                // Reset timer — condition not yet met
                g_recoveryHaltTime[i] = currentTime
            END IF
        END IF
    END FOR
    
    // ═══════════════════════════════════════════════════════
    // TOTAL HEAT AUTO-RESUME (Global)
    // ═══════════════════════════════════════════════════════
    IF (g_adoptionHalted)
        
        resumeThreshold = inpMaxTotalHeat × 0.80    // 10.0 × 0.80 = 8.0%
        
        IF (g_totalHeat < resumeThreshold)
            
            IF (currentTime - g_adoptionHaltTime > ResumeTimeDelay)
                
                g_adoptionHalted = false
                
                Alert("AUTO-RESUME: Portfolio heat normalized to ",
                      DoubleToString(g_totalHeat, 2), "%",
                      " — Basket adoption resumed")
            END IF
        ELSE
            g_adoptionHaltTime = currentTime
        END IF
    END IF
    
    // ═══════════════════════════════════════════════════════
    // SPREAD AUTO-RESUME (Global)
    // ═══════════════════════════════════════════════════════
    IF (g_spreadHalted)
        
        currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
        resumeThreshold = inpMaxSpreadPoints × 0.80    // 100 × 0.80 = 80 pts
        
        IF (currentSpread < resumeThreshold)
            
            IF (currentTime - g_spreadHaltTime > ResumeTimeDelay)
                
                g_spreadHalted = false
                
                Alert("AUTO-RESUME: Spread normalized to ",
                      currentSpread, " points",
                      " — Trading resumed")
            END IF
        ELSE
            g_spreadHaltTime = currentTime
        END IF
    END IF
    
    // ═══════════════════════════════════════════════════════
    // MARGIN AUTO-RESUME (Global)
    // ═══════════════════════════════════════════════════════
    IF (g_marginHalted)
        
        marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)
        resumeThreshold = inpMinMarginPercent × 1.20    // 200 × 1.20 = 240%
        
        IF (marginLevel > resumeThreshold)
            
            IF (currentTime - g_marginHaltTime > ResumeTimeDelay)
                
                g_marginHalted = false
                
                Alert("AUTO-RESUME: Margin level normalized to ",
                      DoubleToString(marginLevel, 1), "%",
                      " — Trading resumed")
            END IF
        ELSE
            g_marginHaltTime = currentTime
        END IF
    END IF
    
END FUNCTION
```

### 6.5 Resume State Machine

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    AUTO-RESUME STATE MACHINE                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [TRADING_NORMAL]                                                       │
│       │                                                                 │
│       │ Guard condition triggered                                       │
│       ▼                                                                 │
│  ┌─────────────┐                                                        │
│  │   HALTED    │                                                        │
│  │  (blocked)  │                                                        │
│  └──────┬──────┘                                                        │
│         │                                                               │
│         │ Condition drops below resume threshold                        │
│         ▼                                                               │
│  ┌─────────────┐                                                        │
│  │  MONITORING │ ← Start 60s timer                                     │
│  │  (checking) │    Reset if condition worsens                         │
│  └──────┬──────┘                                                        │
│         │                                                               │
│         │ 60 seconds elapsed                                            │
│         ▼                                                               │
│  ┌─────────────┐                                                        │
│  │   RESUME    │ ← Alert user, log event                               │
│  │  (normal)   │                                                        │
│  └─────────────┘                                                        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.6 Manual Override

Users can manually force resume regardless of conditions:

```cpp
// User command (via comment or input)
input bool inpForceResume = false;

IF (inpForceResume)
{
    g_recoveryHalted[] = false
    g_adoptionHalted = false
    g_spreadHalted = false
    g_marginHalted = false
    
    Alert("MANUAL OVERRIDE: All trading resumed by user")
    
    inpForceResume = false    // Reset flag
}
```

---

## 7. HALT CONTROLLER

### 7.1 Unified Halt State

The Halt Controller aggregates all individual guard states into a unified trading permission model:

```
FUNCTION IsTradingAllowed(operationType, basketIndex = -1)
    
    // Global halts affect ALL operations
    IF (g_spreadHalted OR g_marginHalted)
        RETURN false
    
    // Per-basket halt affects grid operations
    IF (operationType == OPERATION_GRID_ADDITION)
        IF (g_recoveryHalted[basketIndex])
            RETURN false
    
    // Total heat halt affects adoption
    IF (operationType == OPERATION_ADOPTION)
        IF (g_adoptionHalted)
            RETURN false
    
    // All checks passed
    RETURN true
    
END FUNCTION
```

### 7.2 Operation Type Enum

```cpp
enum ENUM_OPERATION_TYPE
{
    OPERATION_GRID_ADDITION,     // Phase 3
    OPERATION_ADOPTION,          // Phase 2
    OPERATION_FASTSTRIKE,        // Phase 4 — ALWAYS ALLOWED
    OPERATION_TRAILING_UPDATE    // Phase 5 — ALWAYS ALLOWED
};
```

### 7.3 Dashboard Halt Status Display

```
┌────────────────────────────────────────────────────────┐
│  HALT STATUS                                           │
├────────────────────────────────────────────────────────┤
│  🔥 Heat:     3.2%  [GREEN]  ✓ Trading active          │
│  📊 Spread:   28    [GREEN]  ✓ Trading active          │
│  💰 Margin:   287%  [GREEN]  ✓ Trading active          │
│                                                        │
│  Or:                                                   │
│                                                        │
│  🔥 Heat:     11.5% [RED]    ✗ Adoption halted         │
│  📊 Spread:   125   [RED]    ✗ All trading halted      │
│  💰 Margin:   287%  [GREEN]  ✓ Trading active          │
└────────────────────────────────────────────────────────┘
```

---

## 8. INTEGRATION WITH PHASES 1–5

### 8.1 Phase 1 (SSoT)

**GV Persistence:**
- Halt states are NOT persisted to GVs (session-only)
- Rationale: Halt conditions are transient. A restart should evaluate fresh conditions.
- Exception: Heat cache values can be recalculated on restart.

### 8.2 Phase 2 (Adoption)

```cpp
void Adoption_ExecuteScan()
{
    // Phase 6 guard
    IF (NOT IsTradingAllowed(OPERATION_ADOPTION))
        RETURN
    
    // ... rest of adoption logic ...
}
```

### 8.3 Phase 3 (Grid System)

```cpp
void CheckGridLevels(double bid, double ask)
{
    FOR each basket:
        
        // Phase 6 guard
        IF (NOT IsTradingAllowed(OPERATION_GRID_ADDITION, i))
            CONTINUE
        
        // Phase 3 heat constraint (lot multiplier)
        // (already applied in GetLotMultiplier())
        
        // ... grid logic ...
    END FOR
}
```

### 8.4 Phase 4 (FastStrike)

**NO INTEGRATION NEEDED.** FastStrike operates regardless of halt status. Profit-taking is never blocked.

### 8.5 Phase 5 (Virtual Trailing)

**NO INTEGRATION NEEDED.** Trailing stops operate regardless of halt status. Protection is never blocked.

**Checkpoint Frequency Link:** Heat level drives checkpoint frequency (specified in Phase 5).

---

## 9. STATE MANAGEMENT

### 9.1 Halt State Variables

```cpp
// Per-basket recovery halt
bool     g_recoveryHalted[SK_MAX_BASKETS];      // Grid additions halted?
datetime g_recoveryHaltTime[SK_MAX_BASKETS];    // When halted

// Global adoption halt
bool     g_adoptionHalted;                      // New adoptions halted?
datetime g_adoptionHaltTime;                    // When halted

// Global spread halt
bool     g_spreadHalted;                        // Spread too wide?
datetime g_spreadHaltTime;                      // When halted
int      g_spreadAtHalt;                        // Spread value at halt

// Global margin halt
bool     g_marginHalted;                        // Margin too low?
datetime g_marginHaltTime;                      // When halted
double   g_marginAtHalt;                        // Margin level at halt

// Warning state
bool     g_heatWarningActive;                   // Heat warning displayed?
datetime g_heatWarningTime;                     // When warning started
```

### 9.2 Heat Cache Variables

```cpp
double   g_heatCache[SK_MAX_BASKETS];           // Per-basket drawdown $
double   g_totalHeat;                           // Total portfolio heat %
```

---

## 10. PERFORMANCE BUDGET

### 10.1 Heat Calculation

| Operation | Cost | Notes |
|-----------|------|-------|
| Per-basket drawdown | ~10 cycles | Simple arithmetic |
| 20 baskets total | ~200 cycles | < 0.1μs |
| Account balance query | ~50 cycles | `AccountInfoDouble()` |
| **Total UpdateHeatCache()** | **~250 cycles** | **< 0.1μs** |

### 10.2 Guard Checks

| Guard | Cost | Notes |
|-------|------|-------|
| Spread check | ~30 cycles | `SymbolInfoInteger()` |
| Margin check | ~50 cycles | `AccountInfoDouble()` |
| Heat limit enforcement | ~20 cycles | Simple comparisons |
| Auto-resume | ~50 cycles | Timer comparisons |
| **Total per OnTimer()** | **~150 cycles** | **< 0.1μs** |

### 10.3 Overall Budget

| Component | Target |
|-----------|--------|
| `UpdateHeatCache()` | < 0.1ms |
| `CheckSpreadGuard()` | < 0.1ms |
| `CheckMarginGuard()` | < 0.1ms |
| `CheckAutoResumeConditions()` | < 0.1ms |
| **Total Phase 6 per OnTimer()** | **< 0.5ms** |

---

## 11. EDGE CASES & ERROR HANDLING

### 11.1 Heat Calculation Edge Cases

| Scenario | Handling |
|----------|----------|
| `AccountBalance = 0` | Return heat = 0, log critical error |
| `AccountBalance < 0` | Return heat = 100%, halt all trading |
| Basket in profit (drawdown = 0) | Heat = 0% for that basket |
| Cache invalid | Skip heat calculation, assume normal |
| Division by zero protection | Always check balance > 0 |

### 11.2 Guard Edge Cases

| Scenario | Handling |
|----------|----------|
| Spread data unavailable | Assume normal (permissive) |
| Margin = 0 (no positions) | Not halted |
| Margin = INF (no margin used) | Not halted |
| Multiple guards trigger simultaneously | All restrictions apply independently |
| All four guards active | Only profit-taking works |

### 11.3 Auto-Resume Edge Cases

| Scenario | Handling |
|----------|----------|
| Timer overflow (TimeCurrent() wrap) | Use `datetime` arithmetic (MT5 handles) |
| Condition oscillates near threshold | Hysteresis + time delay prevents flapping |
| User manually halts | Manual flag takes precedence over auto-resume |
| Restart while halted | Re-evaluate fresh — may resume immediately if conditions normalized |

---

## 12. DECISION LOG

| Decision | Rationale | Source |
|----------|-----------|--------|
| Drawdown-based heat (not exposure) | Measures actual risk, not potential | `CORE_LOGIC.md` §6.1 |
| Heat = 0 when in profit | No risk when winning | §2.1 |
| Recovery Heat > 5% → halt grid | Prevents deepening losing baskets | §3.2 |
| Total Heat > 10% → halt adoption | Prevents portfolio overextension | §3.3 |
| Spread > 100 pts → halt all | XAUUSD normal ~20-40, 100 = extreme | §4.2 |
| Margin < 200% → halt all | Standard safety threshold | §5.2 |
| 20% hysteresis on resume | Prevents oscillation | §6.2 |
| 60s time delay on resume | Confirms genuine normalization | §6.3 |
| Profit-taking always active | "Profit First" directive | `AGENTS.md` |
| Halt states NOT persisted | Transient conditions, fresh start | §8.1 |
| Manual override available | User discretion | §6.6 |

---

## 13. AUDIT CHECKLIST (FOR GLM-4.7)

- [ ] Heat formula matches `CORE_LOGIC.md` §6.1
- [ ] Recovery Heat scope = per-basket grid additions only
- [ ] Total Heat scope = global adoption halt only
- [ ] Profit-taking (FastStrike/Trailing) never blocked
- [ ] Spread threshold 100 pts appropriate for XAUUSD
- [ ] Margin threshold 200% is standard safe practice
- [ ] 20% hysteresis prevents halt/resume oscillation
- [ ] 60s time delay confirms normalization
- [ ] Manual override specified
- [ ] Edge cases for zero/negative balance handled
- [ ] Performance budget < 0.5ms achievable

---

## 14. APPROVAL SIGNATURES

| Role | Name | Status | Date |
|------|------|--------|------|
| Architect | KIMI-K2 | ✅ Delivered | 2026-04-09 |
| QA Auditor | GLM-4.7 | ⏳ Pending Audit | — |
| Project Lead | User | ⏳ Pending Approval | — |

---

**END OF PHASE 6 LOGIC SPECIFICATION**

*This document is READ-ONLY until approved. No files shall be modified pending audit and sign-off.*
