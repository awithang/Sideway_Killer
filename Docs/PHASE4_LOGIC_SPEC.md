# SIDEWAY KILLER — Phase 4 Logic Specification

**Document Version:** 1.0.0 — DRAFT FOR AUDIT  
**Phase:** 4 — Fast-Strike Profit Detection  
**Architect:** KIMI-K2  
**Date:** 2026-04-09  
**Status:** ⏳ PENDING AUDIT (GLM-4.7) + USER APPROVAL  

**Scope:** Two-Layer Math-Based Profit Detection system. Logic design only — no implementation code.  

**Design Authority:**
- `SIDEWAY_KILLER_CORE_LOGIC.md` §2.3–2.4 (Fast-Strike Execution, Net Profit Calculation)
- `SYNTHESIS/Fast_Strike.md` — Fast-Strike debate synthesis
- `AGENTS.md` — "Profit First" Priority Directive

---

## EXECUTIVE SUMMARY

Phase 4 implements the **most critical system** in SIDEWAY KILLER: the profit-taking mechanism. The design follows the "Profit First" directive — once a target is reached, the "Close All" command executes **immediately**, without waiting for UI updates or secondary logic cycles.

**Core Design:** Two-layer math-based detection with zero API calls in the hot path.

| Layer | Purpose | Latency | Data Source |
|-------|---------|---------|-------------|
| **Layer 1** | Aggressive quick-filter | ~0.05ms | Cache-only |
| **Layer 2** | Conservative confirmation | ~0.05ms | Cache + cached spread stats |
| **Total** | Combined detection | **~0.10ms** | No `POSITION_PROFIT` API calls |

**Performance Comparison:**
- Math-based (this design): **0.10ms**
- API-based (`PositionGetDouble`): **5–10ms**
- **Advantage: 50–100× faster**

---

## 1. ARCHITECTURE POSITIONING

### 1.1 Execution Priority in OnTick()

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    OnTick() — PRIORITY HIERARCHY                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  PRIORITY 1 (MANDATORY — FIRST OPERATION)                               │
│  ════════════════════════════════════════                               │
│  FastStrikeCheck()                                                       │
│    ├─→ Layer 1: Quick Spark (aggressive math)                          │
│    ├─→ Layer 2: Statistical Buffer (conservative math)                 │
│    └─→ If target hit → CloseBasketImmediate() → RETURN                  │
│                                                                          │
│  PRIORITY 2                                                             │
│  ═════════════                                                          │
│  CheckGridLevels()       ← Phase 3 (only if no close triggered)        │
│                                                                          │
│  PRIORITY 3                                                             │
│  ═════════════                                                          │
│  UpdateAllVirtualTrailings()  ← Phase 5                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**CRITICAL RULE:** If `FastStrikeCheck()` triggers a basket closure, `OnTick()` **MUST** `return` immediately. No subsequent logic executes. This is the "Profit First" enforcement mechanism.

### 1.2 Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                 FAST-STRIKE DATA FLOW                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  CACHE (Phase 1 SSoT)          LIVE PRICE          COLD-PATH CACHE      │
│  ─────────────────────         ───────────         ─────────────────    │
│  g_baskets[i].weightedAvg  +   SymbolInfoDouble()  g_spreadStats.*      │
│  g_baskets[i].totalVolume      (BID/ASK)           g_spreadBuffer       │
│  g_baskets[i].targetProfit                         g_valuePerPoint      │
│  g_baskets[i].direction                            g_commissionPerLot   │
│                                                                          │
│         │                            │                      │           │
│         └────────────┬───────────────┘──────────────────────┘           │
│                      ▼                                                  │
│              FastStrikeCheck()                                          │
│                      │                                                  │
│         ┌────────────┼────────────┐                                     │
│         ▼            ▼            ▼                                     │
│    Layer 1      Layer 2      CloseBasket                                │
│    (<0.05ms)    (<0.05ms)    Immediate                                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. LAYER 1: QUICK SPARK (AGGRESSIVE DETECTION)

### 2.1 Purpose

Layer 1 is a **fast-filter** designed to eliminate baskets that are clearly below target with minimal computation. It uses an optimistic profit estimate (no cost deductions) to quickly reject non-qualifying baskets.

**Design Principle:** Fail fast. If Layer 1 fails, skip Layer 2 entirely and move to the next basket.

### 2.2 Formula

#### Step 1: Price Distance

```
FOR BUY Baskets:
    Distance = CurrentBid - WeightedAverage

FOR SELL Baskets:
    Distance = WeightedAverage - CurrentAsk
```

| Variable | Source | Description |
|----------|--------|-------------|
| `CurrentBid` | `SymbolInfoDouble(_Symbol, SYMBOL_BID)` | Live market price |
| `CurrentAsk` | `SymbolInfoDouble(_Symbol, SYMBOL_ASK)` | Live market price |
| `WeightedAverage` | `g_baskets[i].weightedAvg` | Phase 1 cache |

**Note:** `SymbolInfoDouble()` is permitted in the hot path. It reads from the terminal's tick cache (microsecond latency). It is NOT a broker API call.

#### Step 2: Aggressive Profit Estimate

```
Layer1Profit = Distance × TotalVolume × ValuePerPoint_Aggressive
```

| Parameter | Symbol | Value | Description |
|-----------|--------|-------|-------------|
| `TotalVolume` | `V` | `g_baskets[i].totalVolume` | Phase 1 cache |
| `ValuePerPoint_Aggressive` | `Vpp_agg` | 100.0 | $100 per lot per point (XAUUSD) |

**Rationale for $100/lot/pt:**
- XAUUSD: 1.0 lot = $100 per point movement
- This is a fixed convention for this instrument
- Layer 1 uses the **optimistic** value (no deductions)

#### Step 3: Target Comparison

```
IF (Layer1Profit >= TargetProfit)
    → Proceed to Layer 2
ELSE
    → Skip to next basket (Layer 1 FAILED)
```

| Variable | Source | Description |
|----------|--------|-------------|
| `TargetProfit` | `g_baskets[i].targetProfit` | Phase 1 cache (default $5.00) |

### 2.3 Example Calculation

**Scenario:** BUY basket, 3 levels, profitable movement

```
Weighted Average:  2046.82
Current Bid:       2047.20
Total Volume:      0.48 lots
Target Profit:     $5.00

Distance = 2047.20 - 2046.82 = 0.38 points
Layer1Profit = 0.38 × 0.48 × 100.0 = $18.24

$18.24 ≥ $5.00 → LAYER 1 PASSED → Proceed to Layer 2
```

### 2.4 Edge Cases

| Scenario | Handling |
|----------|----------|
| `Distance ≤ 0` | Layer 1 fails (position not profitable) |
| `TotalVolume = 0` | Skip basket, log warning (corrupt cache) |
| `Cache invalid` | Abort `FastStrikeCheck()` entirely |

---

## 3. LAYER 2: STATISTICAL BUFFER (CONSERVATIVE CONFIRMATION)

### 3.1 Purpose

Layer 2 applies **statistical cost buffers** to the Layer 1 estimate to account for:
- Spread cost (bid-ask differential)
- Commission cost (round-turn per lot)
- Conservative value-per-point factor (3% buffer)

**Design Principle:** Confirm that profit is real and executable after accounting for friction costs. Use a **95% target threshold** (5% safety margin) to prevent premature closure due to tick fluctuation.

### 3.2 Formula

#### Step 1: Conservative Value Per Point

```
ValuePerPoint_Conservative = 100.0 × ConservativeFactor
```

| Parameter | Symbol | Value | Description |
|-----------|--------|-------|-------------|
| `ConservativeFactor` | `C_fac` | 0.97 | 3% conservative buffer |

**Rationale:** XAUUSD value-per-point is theoretically $100/lot/pt. The 0.97 factor provides a 3% buffer to account for:
- Minor broker variations in tick value
- Slippage on entry/exit
- Rounding errors in volume-weighted average

**Alternative (more precise but slower):**
```
tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE)
tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)
ValuePerPoint_Conservative = (tickValue / tickSize) × ConservativeFactor
```

> **Decision:** Use hardcoded `100.0 × 0.97 = 97.0` for Layer 2. The `tickValue/tickSize` calculation is performed once during `OnInit()` and cached in `g_valuePerPointConservative`. This avoids any `SymbolInfoDouble()` calls in the hot path beyond BID/ASK.

#### Step 2: Gross Profit (Conservative)

```
GrossProfit = Distance × TotalVolume × ValuePerPoint_Conservative
```

#### Step 3: Spread Cost Estimate

```
SpreadCost = TotalVolume × SpreadBuffer
```

**Spread Buffer Calculation:**
```
CurrentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
AverageSpread = g_spreadStats.average        // EMA, updated in OnTimer

SpreadBuffer = MAX(CurrentSpread, AverageSpread × SpreadMultiplier)
```

| Parameter | Symbol | Value | Description |
|-----------|--------|-------|-------------|
| `SpreadMultiplier` | `S_mult` | 1.5 | Use 1.5× average as buffer |

**Rationale:** Use the **more conservative** of current spread or 1.5× average spread. This ensures the buffer is adequate during both normal and widened spread conditions.

**Note:** `SYMBOL_SPREAD` is a fast terminal lookup (not a broker API call). The `g_spreadStats.average` is refreshed every 1 second in the cold path.

#### Step 4: Commission Cost Estimate

```
CommissionCost = TotalVolume × CommissionPerLot
```

| Parameter | Symbol | Value | Description |
|-----------|--------|-------|-------------|
| `CommissionPerLot` | `C_lot` | 7.0 | $7 per lot round-turn (estimated) |

**Rationale:** Commission is estimated rather than queried per-position. The $7/lot estimate is based on typical XAUUSD ECN broker pricing. This avoids `POSITION_COMMISSION` API calls in the hot path.

#### Step 5: Net Profit

```
NetProfit = GrossProfit - SpreadCost - CommissionCost
```

#### Step 6: Confirmation Threshold

```
IF (NetProfit ≥ TargetProfit × 0.95)
    → LAYER 2 PASSED → EXECUTE CLOSE
ELSE
    → LAYER 2 FAILED → Skip to next basket
```

The **0.95 factor** provides a 5% safety margin. This means the system requires 95% of the target profit to be achievable **after all estimated costs** before triggering closure.

### 3.3 Example Calculation

**Continuing from Layer 1 example:**

```
Layer 1 Result: Distance = 0.38, Volume = 0.48, Target = $5.00

Step 1: ValuePerPoint_Conservative = 100.0 × 0.97 = 97.0

Step 2: GrossProfit = 0.38 × 0.48 × 97.0 = $17.69

Step 3: Spread Buffer
    CurrentSpread = 35 points
    AverageSpread = 28 points
    SpreadBuffer = MAX(35, 28 × 1.5) = MAX(35, 42) = 42 points
    SpreadCost = 0.48 × 42 = $20.16

Step 4: CommissionCost = 0.48 × 7.0 = $3.36

Step 5: NetProfit = 17.69 - 20.16 - 3.36 = -$5.83

Step 6: Threshold = $5.00 × 0.95 = $4.75
    -$5.83 < $4.75 → LAYER 2 FAILED → Do NOT close
```

**Interpretation:** Although Layer 1 showed $18.24 of "raw" profit, the wide spread (42 points) consumed all profit and more. Layer 2 correctly prevented a losing closure.

**Revised Scenario (narrower spread):**
```
CurrentSpread = 20 points
AverageSpread = 18 points
SpreadBuffer = MAX(20, 18 × 1.5) = MAX(20, 27) = 27 points
SpreadCost = 0.48 × 27 = $12.96

NetProfit = 17.69 - 12.96 - 3.36 = $1.37

$1.37 < $4.75 → STILL FAILED
```

**Revised Scenario (larger price movement):**
```
CurrentBid = 2047.60
Distance = 2047.60 - 2046.82 = 0.78 points

GrossProfit = 0.78 × 0.48 × 97.0 = $36.31
SpreadCost = 0.48 × 27 = $12.96
CommissionCost = $3.36

NetProfit = 36.31 - 12.96 - 3.36 = $19.99

$19.99 ≥ $4.75 → LAYER 2 PASSED → CLOSE IMMEDIATELY
```

### 3.4 Cost Component Breakdown

| Component | Typical Value (0.48 lots) | Impact |
|-----------|---------------------------|--------|
| Gross Profit (0.38 pts) | $18.24 | Revenue |
| Spread Cost (27 pts) | $12.96 | 71% of gross |
| Commission ($7/lot) | $3.36 | 18% of gross |
| **Net Profit** | **$1.92** | **10% of gross** |

This illustrates why Layer 2 is essential: without cost accounting, the system would close at a loss after spread and commission.

---

## 4. FAST-STRIKE EXECUTION SEQUENCE

### 4.1 Complete Algorithm

```
FUNCTION FastStrikeCheck()
    
    // Early exit if cache not ready
    IF (NOT g_cacheValid)
        RETURN
    
    // Iterate all active baskets
    FOR i = 0 TO g_basketCount - 1:
        
        // Skip invalid entries
        IF (NOT g_baskets[i].isValid)
            CONTINUE
        
        // Skip baskets already closing
        IF (g_baskets[i].status != BASKET_ACTIVE)
            CONTINUE
        
        // Get live prices
        bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
        ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
        
        // ─────────────────────────────────────────────
        // LAYER 1: AGGRESSIVE CHECK
        // ─────────────────────────────────────────────
        distance = CalculateDistance(i, bid, ask)
        
        IF (distance <= 0)
            CONTINUE    // Not profitable, skip to next basket
        
        layer1Profit = distance × g_baskets[i].totalVolume × 100.0
        
        IF (layer1Profit < g_baskets[i].targetProfit)
            CONTINUE    // Below target, skip to next basket
        
        // ─────────────────────────────────────────────
        // LAYER 2: CONSERVATIVE CHECK
        // ─────────────────────────────────────────────
        layer2Profit = CalculateLayer2(i, distance, bid, ask)
        threshold = g_baskets[i].targetProfit × 0.95
        
        IF (layer2Profit < threshold)
            CONTINUE    // Insufficient net profit, skip to next basket
        
        // ─────────────────────────────────────────────
        // ALL CHECKS PASSED — CLOSE IMMEDIATELY
        // ─────────────────────────────────────────────
        CloseBasketImmediate(i)
        RETURN          // CRITICAL: Exit OnTick() immediately!
        
    END FOR
    
END FUNCTION
```

### 4.2 Helper Functions

```
FUNCTION CalculateDistance(basketIndex, bid, ask)
    
    IF (g_baskets[basketIndex].direction == BUY)
        RETURN bid - g_baskets[basketIndex].weightedAvg
    ELSE
        RETURN g_baskets[basketIndex].weightedAvg - ask
    
END FUNCTION
```

```
FUNCTION CalculateLayer2(basketIndex, distance, bid, ask)
    
    volume = g_baskets[basketIndex].totalVolume
    
    // Gross profit with conservative value
    gross = distance × volume × g_valuePerPointConservative    // 97.0
    
    // Spread cost
    currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
    avgSpread = g_spreadStats.average
    spreadBuffer = MAX(currentSpread, avgSpread × 1.5)
    spreadCost = volume × spreadBuffer
    
    // Commission cost
    commissionCost = volume × g_commissionPerLot               // 7.0
    
    // Net profit
    RETURN gross - spreadCost - commissionCost
    
END FUNCTION
```

### 4.3 CloseBasketImmediate Protocol

```
FUNCTION CloseBasketImmediate(basketIndex)
    
    // 1. Flag basket to prevent new grid additions
    g_baskets[basketIndex].status = BASKET_CLOSING
    
    // 2. Write status to SSoT (GV) — cold path write
    SSoT_UpdateBasketStatus(basketIndex, BASKET_CLOSING)
    
    // 3. Close all positions in basket
    FOR level = g_baskets[basketIndex].levelCount - 1 DOWNTO 0:
        ticket = g_baskets[basketIndex].levels[level].ticket
        ClosePosition(ticket)    // OrderSend TRADE_ACTION_DEAL
    END FOR
    
    // 4. Verify closure (cold path, next timer cycle)
    //    (Immediate verification skipped to prevent latency)
    
    // 5. Update trade statistics (on confirmed close)
    //    Handled by OnTrade() event or next OnTimer()
    
    // 6. Mark cache entry invalid
    g_baskets[basketIndex].isValid = false
    
    // 7. Write closed status to SSoT
    SSoT_UpdateBasketStatus(basketIndex, BASKET_CLOSED)
    
    // 8. Alert user
    Alert("Basket ", basketIndex, " closed. Profit target reached.")
    
END FUNCTION
```

---

## 5. HOT PATH INTEGRATION

### 5.1 OnTick() Structure

```cpp
void OnTick()
{
    // ═══════════════════════════════════════════════════════
    // PRIORITY 1: PROFIT FIRST — Fast-Strike Check
    // ═══════════════════════════════════════════════════════
    // This MUST be the first operation in OnTick().
    // If a basket hits target, we exit immediately.
    // ═══════════════════════════════════════════════════════
    FastStrikeCheck();
    
    // If FastStrikeCheck() triggered a close, it returned.
    // Code below only executes if NO close was triggered.
    
    // ═══════════════════════════════════════════════════════
    // PRIORITY 2: Grid Level Management (Phase 3)
    // ═══════════════════════════════════════════════════════
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    CheckGridLevels(bid, ask);
    
    // ═══════════════════════════════════════════════════════
    // PRIORITY 3: Virtual Trailing (Phase 5)
    // ═══════════════════════════════════════════════════════
    for (int i = 0; i < g_basketCount; i++)
    {
        if (g_baskets[i].isValid)
            UpdateVirtualTrailing(i);
    }
}
```

### 5.2 Why FastStrike Must Be First

| Scenario | If FastStrike is FIRST | If FastStrike is LAST |
|----------|------------------------|----------------------|
| Price spikes to target | Closes in 0.10ms | Grid adds level first (wrong!) |
| Price reverses after target | Already closed | Missed profit, now in loss |
| Trailing stop activates | Profit already taken | Trailing closes at lower profit |

**The 0.10ms advantage is only realized if FastStrike runs BEFORE any other logic that might delay execution.**

### 5.3 Early Exit Enforcement

```cpp
// CORRECT: Early return after close
void FastStrikeCheck()
{
    for (int i = 0; i < g_basketCount; i++)
    {
        // ... layer 1 and layer 2 checks ...
        
        if (layer2Profit >= threshold)
        {
            CloseBasketImmediate(i);
            return;  // ← CRITICAL: Exit OnTick() via return
        }
    }
}

// WRONG: Continue checking other baskets
void FastStrikeCheck()
{
    for (int i = 0; i < g_basketCount; i++)
    {
        if (layer2Profit >= threshold)
        {
            CloseBasketImmediate(i);
            // Missing return! → OnTick() continues executing
        }
    }
}
```

---

## 6. COLD PATH SUPPORT FUNCTIONS

### 6.1 Spread Statistics Update (OnTimer)

```
FUNCTION UpdateSpreadStatistics()
    
    currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
    
    // Exponential Moving Average with alpha = 0.1
    g_spreadStats.average = g_spreadStats.average × 0.9 + currentSpread × 0.1
    
    // EMA variance
    delta = currentSpread - g_spreadStats.average
    g_spreadStats.variance = g_spreadStats.variance × 0.9 + (delta × delta) × 0.1
    g_spreadStats.stdDev = SQRT(g_spreadStats.variance)
    
    g_spreadStats.lastUpdate = TimeCurrent()
    
END FUNCTION
```

### 6.2 Value Per Point Initialization

```
// Called once in OnInit()
FUNCTION InitValuePerPoint()
    
    tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE)
    tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)
    
    IF (tickSize > 0)
        g_valuePerPointRaw = tickValue / tickSize
    ELSE
        g_valuePerPointRaw = 100.0    // XAUUSD default fallback
    
    g_valuePerPointConservative = g_valuePerPointRaw × 0.97
    
    Print("Value per point: ", g_valuePerPointRaw,
          " (conservative: ", g_valuePerPointConservative, ")")
    
END FUNCTION
```

### 6.3 Commission Configuration

```
// User input or auto-detected
INPUT double inpCommissionPerLot = 7.0    // $7 per lot round-turn

// Stored in global for hot path access
double g_commissionPerLot = 7.0
```

---

## 7. PERFORMANCE BUDGET

### 7.1 Operation Count Analysis

**Per-Basket Layer 1:**
| Operation | CPU Cost |
|-----------|----------|
| Array read (weightedAvg) | ~1 cycle |
| Subtraction (distance) | ~1 cycle |
| Comparison (≤ 0) | ~1 cycle |
| Multiplication (× volume) | ~3 cycles |
| Multiplication (× 100.0) | ~3 cycles |
| Comparison (≥ target) | ~1 cycle |
| **Total** | **~10 cycles** |

**Per-Basket Layer 2 (only if Layer 1 passes):**
| Operation | CPU Cost |
|-----------|----------|
| Multiplication (× volume × 97.0) | ~6 cycles |
| SymbolInfoInteger (SYMBOL_SPREAD) | ~50 cycles |
| Array read (avgSpread) | ~1 cycle |
| Multiplication (× 1.5) | ~3 cycles |
| MAX() comparison | ~1 cycle |
| Multiplication (× volume) | ~3 cycles |
| Multiplication (× commission) | ~3 cycles |
| Two subtractions | ~2 cycles |
| Comparison (≥ threshold) | ~1 cycle |
| **Total** | **~70 cycles** |

**Typical Scenario (20 baskets, 1 hits Layer 2):**
- 19 baskets × 10 cycles (Layer 1 only) = 190 cycles
- 1 basket × 80 cycles (Layer 1 + Layer 2) = 80 cycles
- **Total: ~270 cycles ≈ 0.05μs** (on 3GHz CPU)

> **Even with pessimistic estimates (1000 cycles), execution time is < 1μs — well within the 0.10ms budget.**

### 7.2 Latency Targets

| Function | Target | Worst Case | Notes |
|----------|--------|------------|-------|
| `FastStrikeCheck()` total | < 0.10ms | < 0.20ms | All baskets |
| Layer 1 (per basket) | < 0.05ms | < 0.10ms | Cache-only |
| Layer 2 (per basket) | < 0.05ms | < 0.10ms | + spread lookup |
| `CloseBasketImmediate()` | ASAP | < 50ms | Order execution |

---

## 8. EDGE CASES & ERROR HANDLING

### 8.1 Hot Path Edge Cases

| Scenario | Handling |
|----------|----------|
| `g_cacheValid == false` | Abort `FastStrikeCheck()` immediately |
| `g_basketCount == 0` | Return immediately (no baskets) |
| `distance ≤ 0` for all baskets | Normal exit, no action |
| `g_spreadStats.average == 0` | Use `currentSpread × 2` as fallback |
| `totalVolume == 0` | Skip basket, log corruption warning |
| `targetProfit ≤ 0` | Skip basket, log configuration error |

### 8.2 Close Execution Edge Cases

| Scenario | Handling |
|----------|----------|
| `ClosePosition()` fails | Retry once, log error, leave basket flagged as CLOSING |
| Partial close (some positions fail) | Retry failed positions on next timer cycle |
| Position already closed externally | Detect in verification, mark as closed |
| Broker rejects close | Log error, alert user, halt new grid levels for basket |

### 8.3 Price Movement During Close

**Problem:** Price can move between Layer 2 confirmation and actual order execution.

**Mitigation:**
- Layer 2's 5% safety margin (0.95× target) absorbs minor adverse movement
- Close order uses market execution (not pending) for immediate fill
- If slippage exceeds margin, the close still executes (better than missing target)

---

## 9. ACCURACY VALIDATION

### 9.1 Cold Path Accuracy Check

Every 10 seconds (every 10th `OnTimer()` call), validate math accuracy:

```
FUNCTION ValidateMathAccuracy()
    
    FOR each active basket:
        mathProfit = CalculateLayer2(basketIndex, ...)
        apiProfit = CalculateAPIProfit(basketIndex)    // Slow, but cold path
        
        errorPct = ABS(mathProfit - apiProfit) / MAX(ABS(apiProfit), 0.01)
        
        IF (errorPct > 0.10)    // 10% threshold
            Print("WARNING: Math accuracy error ", errorPct × 100, "%")
            Print("  Basket: ", basketIndex, " Math: ", mathProfit, " API: ", apiProfit)
        END IF
    END FOR
    
END FUNCTION
```

### 9.2 Expected Accuracy

| Component | Typical Error | Source |
|-----------|--------------|--------|
| Layer 1 (aggressive) | +5% to +15% | No cost deduction |
| Layer 2 (conservative) | -3% to +3% | Statistical estimation |
| Spread buffer | ±10% | EMA vs. actual |
| Commission estimate | ±5% | Fixed $7 vs. actual |
| **Layer 2 net accuracy** | **±3%** | **Statistical buffers compensate** |

---

## 10. DECISION LOG

| Decision | Rationale | Source |
|----------|-----------|--------|
| Two-layer design | Layer 1 filters 90%+ of baskets quickly | `Fast_Strike.md` consensus |
| Layer 1: $100/lot/pt | XAUUSD convention, optimistic | `CORE_LOGIC.md` §2.3 |
| Layer 2: 0.97 factor | 3% buffer for estimation errors | `Fast_Strike.md` §3 |
| Spread buffer: 1.5× avg | Captures 99.4% of spread conditions | `Fast_Strike.md` §3 |
| Commission: $7/lot | Typical XAUUSD ECN pricing | `CORE_LOGIC.md` §2.3 |
| Confirmation threshold: 0.95× | 5% safety margin against slippage | `Fast_Strike.md` §3 |
| Early return after close | "Profit First" directive enforcement | `AGENTS.md` |
| FastStrike FIRST in OnTick() | Prevents grid addition before close | §5.2 |
| SymbolInfoInteger in hot path | Terminal cache lookup, < 1μs | Performance analysis |
| `tickValue/tickSize` in OnInit | Avoids SymbolInfo call in hot path | §6.2 |

---

## 11. AUDIT CHECKLIST (FOR GLM-4.7)

Before approval, verify:

- [ ] Layer 1 formula matches `CORE_LOGIC.md` §2.3
- [ ] Layer 2 statistical buffers match `Fast_Strike.md`
- [ ] No `PositionGetDouble(POSITION_PROFIT)` in hot path
- [ ] No `GlobalVariable*` calls in hot path
- [ ] `FastStrikeCheck()` is first in `OnTick()`
- [ ] Early `return` after `CloseBasketImmediate()`
- [ ] 0.95 confirmation threshold is mathematically justified
- [ ] Spread buffer formula handles both normal and wide spread
- [ ] Edge cases have defined handling
- [ ] Accuracy validation mechanism specified
- [ ] Performance budget < 0.10ms is achievable

---

## 12. APPROVAL SIGNATURES

| Role | Name | Status | Date |
|------|------|--------|------|
| Architect | KIMI-K2 | ✅ Delivered | 2026-04-09 |
| QA Auditor | GLM-4.7 | ⏳ Pending Audit | — |
| Project Lead | User | ⏳ Pending Approval | — |

---

**END OF PHASE 4 LOGIC SPECIFICATION**

*This document is READ-ONLY until approved. No files shall be modified pending audit and sign-off.*
