# SIDEWAY KILLER - Lot Multiplier Debate Final Synthesis

**Topic:** RAKIM Kelly Criterion vs Fixed Multiplier for Lot Sizing
**Date:** 2026-04-09
**Participants:** Claude/Opus, Sonnet, Gemini, Codex
**Status:** ✅ CONSENSUS REACHED

---

## 🎯 EXECUTIVE SUMMARY

**Decision:** Configurable Multi-Mode Architecture with FIXED as Default
- **Mode 1:** FIXED - Constant multiplier for simplicity (DEFAULT)
- **Mode 2:** BAYESIAN KELLY - Adaptive, prior-based for advanced users
- **Mode 3:** HYBRID - Blended approach for intermediate users

**Rationale:** Fixed multiplier is simple and predictable (aligns with "lightweight" philosophy). Bayesian Kelly provides mathematically optimal adaptation for advanced users. Heat constraint always overrides all modes for safety.

---

## 📊 DEBATE OUTCOMES

### Starting Positions

| Participant | Initial Position | Key Concern |
|-------------|------------------|-------------|
| Sonnet | Pro Fixed | Complexity, assumptions, warm-up problems |
| Gemini | Pro Kelly | Mathematical optimality, adaptation |
| Codex | Neutral | Implementation challenges, trade tracking |
| Claude | Context-dependent | User expertise level |

### Final Positions

| Participant | Final Position | Confidence | Key Shift |
|-------------|----------------|------------|-----------|
| Sonnet | Fixed default, Bayesian optional | 8.5/10 | Accepted Bayesian for warm-up fix |
| Gemini | Bayesian Kelly with safeguards | 9.5/10 | Acknowledged fixed for novices |
| Codex | Multi-mode configurable | 9.5/10 | Provided implementation roadmap |
| Claude | Fixed default, Kelly available | 9.0/10 | Balance simplicity with power |

### Consensus Points

✅ **No Single Best Solution**
- Novice users need simplicity (FIXED)
- Expert users need optimization (BAYESIAN)
- Intermediate users need transition (HYBRID)

✅ **Bayesian Kelly Solves Warm-Up Problem**
- Using prior beliefs prevents early-trade death spiral
- Equivalent of 20 prior trades at 65% win rate
- Smooth updates instead of sharp changes

✅ **Heat Constraint is Non-Negotiable**
- All modes must respect heat limits
- High heat (>90%) forces minimum multiplier (1.1×)
- Medium heat (>70%) reduces multiplier by 20%

✅ **Trade Statistics Must Persist**
- Win/loss tracking saved to Global Variables
- Survives EA restarts
- Required for all adaptive modes

---

## 🏗️ APPROVED ARCHITECTURE

```
┌─────────────────────────────────────────────────────────────┐
│           SIDEWAY KILLER - LOT MULTIPLIER SYSTEM            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  USER SELECTABLE MODE (Input Parameter)             │   │
│  │  ┌────────────┬────────────┬────────────┐           │   │
│  │  │   FIXED    │  BAYESIAN  │   HYBRID   │           │   │
│  │  │   Mode     │   Kelly    │   Mode     │           │   │
│  │  └────────────┴────────────┴────────────┘           │   │
│  │         Default: FIXED (simple & safe)               │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                      │
│  ┌────────────────────▼────────────────────────────────┐   │
│  │  LOT MULTIPLIER CALCULATOR                          │   │
│  │  ┌──────────────────────────────────────────────┐  │   │
│  │  │ double GetLotMultiplier(int basket, int level) │ │   │
│  │  │ {                                              │ │   │
│  │  │   double mult;                                 │ │   │
│  │  │   switch (LotMode) {                           │ │   │
│  │  │     case FIXED:    mult = CalcFixed(level);   │ │   │
│  │  │     case BAYESIAN: mult = CalcBayesian(level); │ │   │
│  │  │     case HYBRID:   mult = CalcHybrid(level);  │ │   │
│  │  │   }                                            │ │   │
│  │  │   mult = ApplyHeatConstraint(mult);            │ │   │
│  │  │   return mult;                                 │ │   │
│  │  │ }                                              │ │   │
│  │  └──────────────────────────────────────────────┘  │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                      │
│       ┌───────────────┴───────────────┐                     │
│       │                               │                     │
│  ┌────▼─────┐                  ┌──────▼─────┐              │
│  │  MODE 1  │                  │   MODE 2   │              │
│  │  FIXED   │                  │ BAYESIAN   │              │
│  │          │                  │            │              │
│  │ Constant │                  │  Prior-    │              │
│  │ spacing  │                  │  based     │              │
│  │          │                  │  adaptive  │              │
│  │ 1.5× base│                  │  Updates   │              │
│  │ 0.98 exp │                  │  Smooth    │              │
│  └──────────┘                  └─────────────┘              │
│                                                              │
│              ┌─────────────────┐                            │
│              │    MODE 3       │                            │
│              │    HYBRID       │                            │
│              │                 │                            │
│              │  Blend of both  │                            │
│              │  Gradual        │                            │
│              │  transition     │                            │
│              └─────────────────┘                            │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  HEAT CONSTRAINT (Always Applies)                   │   │
│  │  ┌───────────────────────────────────────────────┐  │   │
│  │  │ if (heat > 0.90) return 1.1;  (minimum)       │  │   │
│  │  │ if (heat > 0.70) return mult * 0.8; (reduce)  │  │   │
│  │  └───────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 IMPLEMENTATION GUIDE

### Step 1: Define Configuration Structure

```mql5
// ============================================================
// LOT MULTIPLIER CONFIGURATION
// ============================================================

enum ELotMultiplierMode {
    LOT_FIXED,         // Constant multiplier (simple, safe)
    LOT_BAYESIAN_KELLY, // Adaptive Bayesian Kelly (advanced)
    LOT_HYBRID         // Blended approach (intermediate)
};

// User-selectable mode
input ELotMultiplierMode LotMode = LOT_FIXED;  // DEFAULT

// FIXED MODE PARAMETERS
input double Fixed_BaseMultiplier = 1.5;      // Base multiplier
input double Fixed_Decay = 0.98;              // Decay per level

// BAYESIAN KELLY MODE PARAMETERS
input double Bayesian_PriorWinRate = 0.65;     // Expected win rate
input double Bayesian_PriorStrength = 20;      // Prior sample size
input double Bayesian_SafetyFactor = 0.25;     // Quarter Kelly
input double Bayesian_Decay = 0.95;            // Level decay
input double Bayesian_MinMultiplier = 1.1;     // Safety floor
input double Bayesian_MaxMultiplier = 2.5;     // Safety ceiling

// HYBRID MODE PARAMETERS
input double Hybrid_KellyWeight = 0.5;         // Kelly influence (0-1)
input int Hybrid_MinTrades = 50;               // Minimum trades before Kelly

// HEAT CONSTRAINT PARAMETERS
input double Heat_WarningLevel = 0.70;         // 70% heat
input double Heat_CriticalLevel = 0.90;        // 90% heat
input double Heat_ReductionFactor = 0.80;      // 20% reduction at warning
input double Heat_MinimumMultiplier = 1.1;     // Minimum at critical
```

### Step 2: Define Trade Statistics Structure

```mql5
// ============================================================
// TRADE STATISTICS TRACKING
// ============================================================

struct TradeStatistics {
    // Basic tracking
    int totalTrades;
    int wins;
    int losses;

    // Amount tracking
    double totalWinAmount;
    double totalLossAmount;

    // Bayesian parameters
    double alpha;  // Prior wins + actual wins
    double beta;   // Prior losses + actual losses

    // Last update time
    datetime lastUpdate;
};

TradeStatistics g_stats;

// ============================================================
// GLOBAL VARIABLE NAMESPACE FOR PERSISTENCE
// ============================================================
#define GV_STATS_TOTAL_TRADES "SK_STATS_TOTAL"
#define GV_STATS_WINS "SK_STATS_WINS"
#define GV_STATS_LOSSES "SK_STATS_LOSSES"
#define GV_STATS_WIN_AMT "SK_STATS_WIN_AMT"
#define GV_STATS_LOSS_AMT "SK_STATS_LOSS_AMT"
#define GV_STATS_ALPHA "SK_STATS_ALPHA"
#define GV_STATS_BETA "SK_STATS_BETA"
```

### Step 3: Implement Unified Interface

```mql5
// ============================================================
// UNIFIED LOT MULTIPLIER INTERFACE
// ============================================================

/**
 * Get lot multiplier for a grid level
 * @param basketIndex Basket index (for logging)
 * @param level Grid level (0 = original position)
 * @return Lot multiplier
 */
double GetLotMultiplier(int basketIndex, int level) {
    double multiplier;
    string modeName;

    // Calculate based on mode
    switch (LotMode) {
        case LOT_FIXED:
            multiplier = CalculateFixedMultiplier(level);
            modeName = "FIXED";
            break;

        case LOT_BAYESIAN_KELLY:
            multiplier = CalculateBayesianKelly(level);
            modeName = "BAYESIAN";
            break;

        case LOT_HYBRID:
            multiplier = CalculateHybridMultiplier(level);
            modeName = "HYBRID";
            break;

        default:
            multiplier = CalculateFixedMultiplier(level);  // Safe fallback
            modeName = "FALLBACK";
            break;
    }

    // Apply heat constraint (ALWAYS)
    multiplier = ApplyHeatConstraint(multiplier);

    // Log for monitoring
    LogMultiplier(basketIndex, level, multiplier, modeName);

    return multiplier;
}

/**
 * Apply heat constraint to multiplier
 */
double ApplyHeatConstraint(double multiplier) {
    double heat = CalculateCurrentHeat();

    if (heat > Heat_CriticalLevel) {
        // Critical: Use minimum multiplier
        Print("CRITICAL: Heat at ", DoubleToString(heat * 100, 1), "%, using min multiplier");
        return Heat_MinimumMultiplier;
    } else if (heat > Heat_WarningLevel) {
        // Warning: Reduce multiplier
        Print("WARNING: Heat at ", DoubleToString(heat * 100, 1), "%, reducing multiplier by 20%");
        return multiplier * Heat_ReductionFactor;
    }

    return multiplier;
}

/**
 * Calculate current account heat
 */
double CalculateCurrentHeat() {
    double totalExposure = 0;

    for (int i = 0; i < g_basketCount; i++) {
        if (!g_baskets[i].isValid) continue;

        // Calculate exposure in USD
        double exposure = g_baskets[i].totalVolume * 100000;  // Approximate
        totalExposure += exposure;
    }

    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double maxHeat = accountBalance * 0.05;  // 5% max

    return totalExposure / maxHeat;
}
```

### Step 4: Implement FIXED Mode

```mql5
// ============================================================
// FIXED MODE: Constant multiplier
// ============================================================

double CalculateFixedMultiplier(int level) {
    double base = Fixed_BaseMultiplier;
    double decay = Fixed_Decay;
    double levelDecay = MathPow(decay, level);
    return base * levelDecay;
}
```

### Step 5: Implement BAYESIAN KELLY Mode

```mql5
// ============================================================
// BAYESIAN KELLY MODE: Adaptive with priors
// ============================================================

double CalculateBayesianKelly(int level) {
    // Get Bayesian win rate
    double winRate = g_stats.alpha / (g_stats.alpha + g_stats.beta);

    // Get reward ratio
    double avgWin = g_stats.totalWinAmount / MathMax(g_stats.wins, 1);
    double avgLoss = g_stats.totalLossAmount / MathMax(g_stats.losses, 1);
    double b = avgWin / avgLoss;  // Reward-to-risk ratio

    // Kelly formula: f = (p*b - q) / b
    double q = 1.0 - winRate;
    double kellyFraction = (winRate * b - q) / b;

    // Apply safety factor (Quarter Kelly)
    double appliedKelly = kellyFraction * Bayesian_SafetyFactor;
    double kellyMultiplier = 1.0 + appliedKelly;

    // Apply level decay
    double levelDecay = MathPow(Bayesian_Decay, level);
    double result = kellyMultiplier * levelDecay;

    // Apply safety bounds
    result = MathMax(result, Bayesian_MinMultiplier);
    result = MathMin(result, Bayesian_MaxMultiplier);

    // Warn if at bounds
    if (result <= Bayesian_MinMultiplier) {
        Print("Note: Kelly multiplier at minimum (", Bayesian_MinMultiplier, ")");
    } else if (result >= Bayesian_MaxMultiplier) {
        Print("Warning: Kelly multiplier at maximum (", Bayesian_MaxMultiplier, ")");
    }

    return result;
}
```

### Step 6: Implement HYBRID Mode

```mql5
// ============================================================
// HYBRID MODE: Blended approach
// ============================================================

double CalculateHybridMultiplier(int level) {
    double fixed = CalculateFixedMultiplier(level);

    // Only use Kelly if we have enough data
    if (g_stats.totalTrades < Hybrid_MinTrades) {
        return fixed;  // Not enough data yet
    }

    double kelly = CalculateBayesianKelly(level);

    // Calculate Kelly weight based on trade count
    // More trades = more confidence in Kelly = higher weight
    double tradeRatio = (double)g_stats.totalTrades / Hybrid_MinTrades;
    double kellyWeight = MathMin(tradeRatio, 1.0) * Hybrid_KellyWeight;
    double fixedWeight = 1.0 - kellyWeight;

    // Blend
    double result = fixedWeight * fixed + kellyWeight * kelly;

    return result;
}
```

### Step 7: Implement Persistence

```mql5
// ============================================================
// PERSISTENCE: Save/Load trade statistics
// ============================================================

void SaveTradeStats() {
    GlobalVariableSet(GV_STATS_TOTAL_TRADES, g_stats.totalTrades);
    GlobalVariableSet(GV_STATS_WINS, g_stats.wins);
    GlobalVariableSet(GV_STATS_LOSSES, g_stats.losses);
    GlobalVariableSet(GV_STATS_WIN_AMT, g_stats.totalWinAmount);
    GlobalVariableSet(GV_STATS_LOSS_AMT, g_stats.totalLossAmount);
    GlobalVariableSet(GV_STATS_ALPHA, g_stats.alpha);
    GlobalVariableSet(GV_STATS_BETA, g_stats.beta);
    GlobalVariableSet(GV_STATS_LAST_UPDATE, TimeCurrent());
}

void LoadTradeStats() {
    g_stats.totalTrades = (int)GlobalVariableCheck(GV_STATS_TOTAL_TRADES);
    g_stats.wins = (int)GlobalVariableCheck(GV_STATS_WINS);
    g_stats.losses = (int)GlobalVariableCheck(GV_STATS_LOSSES);
    g_stats.totalWinAmount = GlobalVariableCheck(GV_STATS_WIN_AMT);
    g_stats.totalLossAmount = GlobalVariableCheck(GV_STATS_LOSS_AMT);
    g_stats.alpha = GlobalVariableCheck(GV_STATS_ALPHA);
    g_stats.beta = GlobalVariableCheck(GV_STATS_BETA);
}

void InitializeBayesianPriors() {
    // Set priors based on expected win rate
    double priorWR = Bayesian_PriorWinRate;
    double priorStrength = Bayesian_PriorStrength;

    g_stats.alpha = priorWR * priorStrength;      // e.g., 0.65 * 20 = 13
    g_stats.beta = (1.0 - priorWR) * priorStrength; // e.g., 0.35 * 20 = 7
}

// Call after each basket closes
void OnBasketClosed(double profit, int levelsUsed) {
    g_stats.totalTrades++;

    bool isWin = (profit > 0);

    if (isWin) {
        g_stats.wins++;
        g_stats.alpha++;
        g_stats.totalWinAmount += profit;
    } else {
        g_stats.losses++;
        g_stats.beta++;
        g_stats.totalLossAmount += MathAbs(profit);
    }

    g_stats.lastUpdate = TimeCurrent();

    SaveTradeStats();

    Print("Basket closed: ", (isWin ? "WIN" : "LOSS"),
          " | Profit: $", DoubleToString(profit, 2),
          " | Win Rate: ", DoubleToString(GetCurrentWinRate() * 100, 1), "%");
}

double GetCurrentWinRate() {
    return (double)g_stats.wins / MathMax(g_stats.totalTrades, 1);
}
```

### Step 8: Integration with Grid Logic

```mql5
// ============================================================
// GRID ADDITION WITH LOT CALCULATION
// ============================================================

void AddGridLevel(int basketIndex) {
    // Get current level
    int newLevel = g_baskets[basketIndex].levelCount;

    // Get multiplier for this level
    double multiplier = GetLotMultiplier(basketIndex, newLevel);

    // Calculate lot size
    double baseLot = g_baseLotSize;  // From original position
    double newLot = NormalizeDouble(baseLot * multiplier, 2);

    // Apply broker constraints
    newLot = NormalizeLot(newLot);

    // ... (execute order with calculated lot size)

    Print("Added grid level: Basket=", basketIndex,
          " Level=", newLevel,
          " Multiplier=", DoubleToString(multiplier, 3),
          " Lot Size=", newLot);
}
```

---

## ⚠️ CRITICAL IMPLEMENTATION WARNINGS

### Warning 1: Bayesian Prior Selection

**DO NOT** use strong priors without justification:
```mql5
// WRONG!
input double Bayesian_PriorStrength = 1000;  // Too strong - ignores data

// RIGHT!
input double Bayesian_PriorStrength = 20;   // Weak - lets data speak
```

### Warning 2: Heat Constraint Priority

**DO NOT** allow Kelly to override heat limits:
```mql5
// WRONG!
double mult = CalculateKelly();  // May return 3.0×
// Use mult directly even if heat is high

// RIGHT!
double mult = CalculateKelly();
mult = ApplyHeatConstraint(mult);  // Always apply
```

### Warning 3: Trade Definition

**DO** clearly define what counts as a win/loss:
```mql5
// RIGHT: Clear definition
bool IsWin(double profit) {
    return profit > 0;  // Any profit = win
}

// ALTERNATIVE: Target-based
bool IsWin(double profit, double target) {
    return profit >= target * 0.9;  // Within 90% of target
}
```

---

## 📊 MODE COMPARISON TABLE

| Feature | FIXED | BAYESIAN | HYBRID |
|---------|-------|----------|--------|
| **Simplicity** | ⭐⭐⭐ | ⭐ | ⭐⭐ |
| **Adaptability** | ⭐ | ⭐⭐⭐ | ⭐⭐ |
| **Warm-Up Safety** | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ |
| **Mathematical Optimality** | ⭐ | ⭐⭐⭐ | ⭐⭐ |
| **Debugging Ease** | ⭐⭐⭐ | ⭐⭐ | ⭐⭐ |
| **Novice Friendly** | ⭐⭐⭐ | ⭐ | ⭐⭐ |
| **Expert Control** | ⭐ | ⭐⭐⭐ | ⭐⭐ |

**Recommendation by User Level:**
- **Novice**: FIXED mode
- **Intermediate**: HYBRID mode
- **Expert**: BAYESIAN mode

---

## 🎯 CONCLUSION

**Approved Architecture:** Configurable Multi-Mode Lot Multiplier

**Key Takeaways:**
1. FIXED is the default (simple, safe, lightweight)
2. BAYESIAN KELLY is available for advanced users
3. HYBRID provides gradual transition
4. Heat constraint ALWAYS applies
5. Trade statistics persist to Global Variables

**Next Steps:**
1. Implement FIXED mode first
2. Add trade tracking infrastructure
3. Implement BAYESIAN KELLY mode
4. Add HYBRID mode
5. Test with historical data

---

**Debate Participants:**
- Claude/Opus: Moderator + Technical Balance
- Sonnet: Performance Engineering
- Gemini: Strategic Architecture
- Codex: Implementation Realities

**Final Verdict:** UNANIMOUS APPROVAL for configurable architecture
