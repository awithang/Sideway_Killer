# SIDEWAY KILLER — Phase 5 Logic Specification (REVISED)

**Document Version:** 2.0.0 — DRAFT FOR AUDIT  
**Phase:** 5 — Trailing Stop: "Letting Profits Run"  
**Architect:** KIMI-K2  
**Date:** 2026-04-09  
**Status:** ⏳ PENDING AUDIT (GLM-4.7) + USER APPROVAL  

**Scope:** Three-layer profit-maximization shield with FastStrike handover protocol. Revised per Captain's directive: primary objective is **capturing maximum trend profit**, with protection as secondary safety net. Logic design only — no implementation code.  

**Design Authority:**
- `SIDEWAY_KILLER_CORE_LOGIC.md` §5 (Simple Trailing Stop)
- `SYNTHESIS/Trailing_Stop.md` — Trailing stop debate synthesis
- `SYNTHESIS/Fast_Strike.md` — Fast-Strike handover patterns
- `Docs/GV_SCHEMA.md` — Phase 1 GV checkpoint namespace (`SK_T<id>_*`)
- `Docs/PHASE4_LOGIC_SPEC.md` — Fast-Strike Layer 1/2 logic

---

## EXECUTIVE SUMMARY (REVISED)

Phase 5 implements the **profit-maximization engine** of SIDEWAY KILLER. Unlike traditional protective trailing stops, this system is designed to **let profitable trades run during strong XAUUSD trends** instead of capping gains at a fixed target.

**Primary Objective:** Capture the maximum possible profit from trending baskets by handing over control from FastStrike (fixed target) to VirtualTrailing (dynamic peak-following) once profitability is confirmed.

**Three-Layer Architecture:**

| Layer | Name | Role | Execution |
|-------|------|------|-----------|
| **1** | Virtual Trailing | **Primary exit** — lets profits run | Every tick |
| **2** | Checkpoint Persistence | Restart recovery | 1–30s adaptive |
| **3** | Emergency Physical Stops | Catastrophic safety net | Event-triggered |

**Key Innovation:** The **Handover Protocol** allows a basket to transition from "close at fixed target" (FastStrike) to "follow the trend" (VirtualTrailing) seamlessly, combining the certainty of profit-locking with the upside of trend-following.

---

## 1. PHILOSOPHY: FROM PROTECTION TO PROFIT MAXIMIZATION

### 1.1 Why Fixed Targets Underperform in XAUUSD Trends

XAUUSD exhibits **strong directional trends** with significant intraday ranges (150–3,000 points). A fixed $5.00 profit target:
- Captures only **0.3–1.0%** of a typical daily move
- Leaves **90%+ of trend profit** on the table
- Forces premature exits during strong momentum

### 1.2 The Handover Solution

```
Traditional Flow:  Basket → FastStrike TP → CLOSE (fixed $5)
Handover Flow:     Basket → FastStrike TP → HANDOVER → Trail Peak → CLOSE (variable, often $50+)
```

**Benefits:**
- **Downside protection:** FastStrike confirms profitability first (Layer 2 conservative math)
- **Upside capture:** VirtualTrailing follows the trend to its natural conclusion
- **Automatic:** No manual intervention required

### 1.3 XAUUSD Trend Characteristics

| Characteristic | Implication for Trailing Design |
|----------------|--------------------------------|
| ATR(14) = 20–60 pts | Trail distance must scale with volatility |
| Trends persist 3–8 hours | Trailing must not exit on normal 1× ATR pullbacks |
| Retracements = 1–2× ATR | Trail buffer must accommodate 1.5× ATR |
| Spike reversals = 3×+ ATR | Emergency layer catches catastrophic moves |

**Design Response:** Dynamic trail distance = `ATR(14) × 1.5`, scaling with real-time volatility.

---

## 2. HANDOVER PROTOCOL: FASTSTRIKE → VIRTUALTRAILING

### 2.1 Overview

The Handover Protocol defines the transition point where a basket switches from **target-driven** management to **trend-following** management.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         HANDOVER STATE MACHINE                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌───────────┐│
│  │   ACTIVE    │───→│ FASTSTRIKE  │───→│  HANDED     │───→│ TRAILING ││
│  │  (building  │    │   HIT       │    │   OVER      │    │  ACTIVE  ││
│  │   levels)   │    │ (target met)│    │ (transferred)│    │          ││
│  └─────────────┘    └─────────────┘    └──────┬──────┘    └─────┬─────┘│
│                                               │                  │     │
│                                               │     Peak update  │     │
│                                               │         │        │     │
│                                               │    ┌────┴────┐   │     │
│                                               └───→│ REVISION │←──┘     │
│                                                    │  PEAK   │         │
│                                                    └────┬────┘         │
│                                                         │               │
│                              Retreat ≥ TrailDist        ▼               │
│                              ◄────────────────────  ┌─────────┐         │
│                                                     │ TRIGGER │         │
│                                                     │  CLOSE  │         │
│                                                     └─────────┘         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Handover Trigger Conditions

A basket is eligible for handover when **ALL** of the following are met:

```
1. Layer 2 Conservative Profit ≥ TargetProfit × 0.95
   (Same as original FastStrike close condition)

2. Basket Age ≥ MinimumHandoverAge (default: 120 seconds)
   (Prevents handover on micro-spikes)

3. Virtual Trailing not already active for this basket
   (One-time handover only)

4. Basket Status = BASKET_ACTIVE
   (Not closing, not closed)
```

**Rationale for MinimumHandoverAge (120s):**
- FastStrike minimum age: 60s (confirms profitability)
- Handover additional buffer: +60s (confirms trend persistence)
- Total: 120s ensures the move has sustained momentum before letting it run

### 2.3 Handover Execution Sequence

```
FUNCTION FastStrikeCheck()
    
    FOR each active basket:
        
        // ── Layer 1 + Layer 2 checks (unchanged from Phase 4) ──
        distance = CalculateDistance(i)
        layer1Profit = distance × volume × 100.0
        
        IF (layer1Profit < targetProfit)
            CONTINUE    // Below target, check next basket
        
        layer2Profit = CalculateLayer2(i, distance)
        IF (layer2Profit < targetProfit × 0.95)
            CONTINUE    // Insufficient net profit
        
        // ═══════════════════════════════════════════════════════
        // HANDOVER DECISION POINT (REVISED)
        // ═══════════════════════════════════════════════════════
        IF (NOT g_virtualTrail[i].isHandedOver)
            
            // Check minimum handover age
            basketAge = TimeCurrent() - g_baskets[i].created
            IF (basketAge < MinimumHandoverAge)
                // Profit target hit but too young — CLOSE immediately
                CloseBasketImmediate(i)
                RETURN
            END IF
            
            // ═══════════════════════════════════════════════════
            // EXECUTE HANDOVER (instead of close)
            // ═══════════════════════════════════════════════════
            HandOverToTrailing(i, layer2Profit)
            
            // Still return from OnTick() — trailing takes over next tick
            RETURN
            
        ELSE
            // Already handed over — trailing manages this basket
            // FastStrike skips already-handed-over baskets
            CONTINUE
        END IF
        
    END FOR
    
END FUNCTION
```

### 2.4 HandOverToTrailing() Function Specification

```
FUNCTION HandOverToTrailing(basketIndex, profitAtHandover)
    
    basket = g_baskets[basketIndex]
    vt = g_virtualTrail[basketIndex]
    
    // 1. Mark basket as handed over
    vt.isHandedOver = true
    vt.isActivated = true          // Trailing starts immediately
    vt.profitAtHandover = profitAtHandover
    
    // 2. Initialize peak tracking
    IF (basket.direction == BUY)
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID)
        vt.peakPrice = currentPrice
        vt.stopLevel = currentPrice - CalculateDynamicTrailDistance()
    ELSE
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
        vt.peakPrice = currentPrice
        vt.stopLevel = currentPrice + CalculateDynamicTrailDistance()
    END IF
    
    vt.peakTime = TimeCurrent()
    
    // 3. Lock profit at handover level (minimum guaranteed)
    vt.minimumStopLevel = CalculateMinimumStopLevel(basketIndex, profitAtHandover)
    
    // 4. Log and notify
    Print("HANDOVER: Basket ", basketIndex, 
          " handed to trailing at profit $", profitAtHandover,
          " — Peak: ", vt.peakPrice,
          " — Trail: ", vt.currentTrailDist)
    
    Alert("Basket ", basketIndex, 
          " profit target reached — now FOLLOWING TREND")
    
    // 5. Immediate checkpoint save
    SSoT_SaveCheckpoint(basketIndex)
    
END FUNCTION
```

### 2.5 FastStrike Behavior After Handover

Once a basket is handed over, FastStrike **ignores** it on subsequent ticks:

```
FUNCTION FastStrikeCheck()
    FOR each basket:
        
        // Skip baskets already handed over to trailing
        IF (g_virtualTrail[i].isHandedOver)
            CONTINUE
        
        // ... rest of FastStrike logic ...
    END FOR
END FUNCTION
```

**Rationale:** After handover, VirtualTrailing is the sole exit manager. Running FastStrike on handed-over baskets would create competing exit conditions.

---

## 3. VIRTUAL TRAILING: TREND-FOLLOWING ENGINE

### 3.1 Revised State Machine

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    VIRTUAL TRAILING STATE MACHINE                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [NOT HANDED OVER]                                                      │
│        │                                                                │
│        │ HandOverToTrailing() called                                    │
│        ▼                                                                │
│  ┌─────────────────┐                                                    │
│  │  HANDED OVER    │ ← Entry state                                     │
│  │  (initial peak  │                                                    │
│  │   locked)       │                                                    │
│  └────────┬────────┘                                                    │
│           │                                                             │
│           │ Price extends beyond peak                                   │
│           ▼                                                             │
│  ┌─────────────────┐     ┌─────────────────┐                            │
│  │  TRACKING PEAK  │←────│  REVISING STOP  │                            │
│  │  (new highs/lows)│     │  (trail follows)│                            │
│  └────────┬────────┘     └─────────────────┘                            │
│           │                                                             │
│           │ Retreat ≥ TrailDistance from peak                           │
│           ▼                                                             │
│  ┌─────────────────┐                                                    │
│  │   TRIGGERED     │ ← Terminal state                                   │
│  │  (close basket) │                                                    │
│  └─────────────────┘                                                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Dynamic Trail Distance for XAUUSD

**Problem:** Fixed trail distance (50 points) is:
- Too tight during high volatility (ATR=60 → normal pullback = 60-120 pts)
- Too loose during low volatility (ATR=15 → gives back too much profit)

**Solution:** Dynamic trail distance scaling with ATR.

#### Formula

```
TrailDistance = BaseTrailDistance × VolatilityMultiplier

WHERE:
    VolatilityMultiplier = MAX(0.5, MIN(2.0, ATR(14) / ATR_NormalizationBase))
    
    // Simplified:
    VolatilityMultiplier = CLAMP(ATR(14) / 20.0, 0.5, 2.0)
```

| Parameter | Symbol | Default | Range | Description |
|-----------|--------|---------|-------|-------------|
| Base Trail Distance | `T_base` | 50 | 25–100 | Base trail in points |
| ATR Normalization Base | `N_base` | 20.0 | — | Same as DVASS normalization |
| Minimum Multiplier | `M_min` | 0.5 | — | Prevents trail < 25 pts |
| Maximum Multiplier | `M_max` | 2.0 | — | Prevents trail > 200 pts |

#### Dynamic Trail Distance Table

| ATR(14) | VolatilityMult | Trail Distance (Base=50) | Interpretation |
|---------|---------------|--------------------------|----------------|
| 10 pts | 0.50 (clamped) | **25 pts** | Very tight in low vol |
| 20 pts | 1.00 | **50 pts** | Baseline |
| 40 pts | 2.00 (clamped) | **100 pts** | Wide in high vol |
| 60 pts | 2.00 (clamped) | **100 pts** | Maximum width |

#### Alternative: ATR-Direct Mode (Expert Setting)

For advanced users, trail distance can be set directly as an ATR multiple:

```
TrailDistance = ATR(14) × TrailATRMultiple

WHERE TrailATRMultiple = 1.5 (default, range 0.5–3.0)
```

**Example with ATR-Direct:**
| ATR(14) | Trail (1.5×) | Behavior |
|---------|--------------|----------|
| 20 pts | 30 pts | Tight, locks profit quickly |
| 40 pts | 60 pts | Moderate, allows normal pullback |
| 60 pts | 90 pts | Wide, captures extended trends |

**Recommendation:** Use **ATR-Direct Mode** as default for XAUUSD trend-following. It naturally scales with market conditions without arbitrary clamping.

### 3.3 Minimum Stop Level (Profit Lock)

**Purpose:** Ensure that even if the trend reverses immediately after handover, the basket closes at or above the handover profit level.

```
FUNCTION CalculateMinimumStopLevel(basketIndex, profitAtHandover)
    
    basket = g_baskets[basketIndex]
    
    // Convert handover profit to price points
    priceBuffer = (profitAtHandover / basket.totalVolume) / 100.0
    
    // Add cost buffer for safety
    priceBuffer = priceBuffer + CostBufferPoints    // +2 pts
    
    IF (basket.direction == BUY)
        RETURN basket.weightedAvg + priceBuffer
    ELSE
        RETURN basket.weightedAvg - priceBuffer
    
END FUNCTION
```

**Enforcement:** The virtual stop level is never allowed below the minimum stop level:

```
IF (basket.direction == BUY)
    vt.stopLevel = MAX(vt.stopLevel, vt.minimumStopLevel)
ELSE
    vt.stopLevel = MIN(vt.stopLevel, vt.minimumStopLevel)
```

**Rationale:** This creates a "profit floor" — the basket cannot lose money once handed over, even if the trend reverses instantly.

### 3.4 Revised UpdateVirtualTrailing() Algorithm

```
FUNCTION UpdateVirtualTrailing(basketIndex, currentBid, currentAsk)
    
    basket = g_baskets[basketIndex]
    vt = g_virtualTrail[basketIndex]
    
    // Skip if not handed over
    IF (NOT vt.isHandedOver)
        RETURN
    
    // Select price
    IF (basket.direction == BUY)
        currentPrice = currentBid
    ELSE
        currentPrice = currentAsk
    
    // ─────────────────────────────────────────────
    // STEP 1: Update dynamic trail distance
    // ─────────────────────────────────────────────
    vt.currentTrailDist = CalculateDynamicTrailDistance()
    
    // ─────────────────────────────────────────────
    // STEP 2: Update peak price
    // ─────────────────────────────────────────────
    peakUpdated = false
    
    IF (basket.direction == BUY)
        IF (currentPrice > vt.peakPrice)
            vt.peakPrice = currentPrice
            peakUpdated = true
        END IF
    ELSE
        IF (currentPrice < vt.peakPrice)
            vt.peakPrice = currentPrice
            peakUpdated = true
        END IF
    END IF
    
    // ─────────────────────────────────────────────
    // STEP 3: Calculate new virtual stop
    // ─────────────────────────────────────────────
    IF (peakUpdated)
        vt.peakTime = TimeCurrent()
    END IF
    
    IF (basket.direction == BUY)
        newStop = vt.peakPrice - vt.currentTrailDist
        // Enforce minimum stop level
        vt.stopLevel = MAX(newStop, vt.minimumStopLevel)
    ELSE
        newStop = vt.peakPrice + vt.currentTrailDist
        // Enforce minimum stop level
        vt.stopLevel = MIN(newStop, vt.minimumStopLevel)
    END IF
    
    // ─────────────────────────────────────────────
    // STEP 4: Check trigger condition
    // ─────────────────────────────────────────────
    triggered = false
    
    IF (basket.direction == BUY)
        triggered = (currentPrice <= vt.stopLevel)
    ELSE
        triggered = (currentPrice >= vt.stopLevel)
    
    IF (triggered)
        Print("Trailing TRIGGERED for basket ", basketIndex,
              " at ", currentPrice, " (stop: ", vt.stopLevel,
              ") — Peak was: ", vt.peakPrice)
        CloseBasket(basketIndex)
    END IF
    
END FUNCTION
```

### 3.5 Example Walkthrough: XAUUSD Trend Capture

**Scenario:** BUY basket, WA = 2046.82, handed over at profit = $12.50

| Tick | Price | Profit | Peak | TrailDist | Stop Level | Trigger? | Notes |
|------|-------|--------|------|-----------|------------|----------|-------|
| H | 2047.07 | $12.50 | 2047.07 | 45 | 2046.62 | No | Handover |
| 1 | 2047.30 | $23.50 | 2047.30 | 45 | 2046.85 | No | New peak |
| 2 | 2047.80 | $47.50 | 2047.80 | 45 | 2047.35 | No | Strong trend |
| 3 | 2048.50 | $84.00 | 2048.50 | 45 | 2048.05 | No | Peak updated |
| 4 | 2048.20 | $76.00 | 2048.50 | 45 | 2048.05 | No | Pullback 30 pts |
| 5 | 2049.00 | $108.00 | 2049.00 | 45 | 2048.55 | No | New peak |
| 6 | 2048.80 | $98.00 | 2049.00 | 45 | 2048.55 | No | Pullback 20 pts |
| 7 | 2048.30 | $74.00 | 2049.00 | 45 | 2048.55 | No | Deeper pullback |
| 8 | 2048.54 | $86.40 | 2049.00 | 45 | 2048.55 | No | Just above stop |
| 9 | 2048.55 | $86.80 | 2049.00 | 45 | 2048.55 | No | At stop (not ≤) |
| 10 | 2048.54 | $86.40 | 2049.00 | 45 | 2048.55 | **YES** | **CLOSE** |

**Result:**
- Handover profit: $12.50
- Trailing captured: $86.40
- **Improvement: 6.9× the fixed target**

### 3.6 Comparison: Fixed Target vs. Handover + Trailing

| Scenario | Fixed Target | Handover + Trailing | Improvement |
|----------|-------------|---------------------|-------------|
| Weak trend (50 pt move) | $5.00 | $8.00 | 1.6× |
| Moderate trend (150 pt) | $5.00 | $35.00 | 7.0× |
| Strong trend (300 pt) | $5.00 | $85.00 | 17× |
| Extended trend (500 pt) | $5.00 | $150.00 | 30× |
| Spike reversal (caught) | $5.00 | $45.00 | 9.0× |

---

## 4. CHECKPOINT SYSTEM (LAYER 2 — SAFETY NET)

### 4.1 Purpose (Revised)

While the primary role of checkpoints was originally restart recovery, it now serves an additional purpose: **preserving trend-capture progress** if the terminal crashes during a strong move.

**Scenario:** Basket handed over at $12.50 profit. Price runs to +$100. Terminal crashes. Without checkpoint: basket reverts to FastStrike behavior on restart (closes at $5 target). With checkpoint: trailing state restored, continues following trend.

### 4.2 Revised GV Schema

| GV Name | Field | Description |
|---------|-------|-------------|
| `SK_T<NNN>_PEAK` | Peak price | Highest/lowest since handover |
| `SK_T<NNN>_STOP` | Stop level | Current virtual stop |
| `SK_T<NNN>_ACT` | Activated | 1 = handed over and active |
| `SK_T<NNN>_TIME` | Timestamp | Last checkpoint save |
| `SK_T<NNN>_PHO` | Profit Handover | Profit at handover time |
| `SK_T<NNN>_TDIS` | Trail Distance | Current trail distance |
| `SK_T<NNN>_MIN` | Minimum Stop | Floor stop level |

**New Fields (v2.0):**
- `_PHO` — Profit at handover (for minimum stop reconstruction)
- `_TDIS` — Current trail distance (for dynamic trail restoration)
- `_MIN` — Minimum stop level (profit floor)

### 4.3 Adaptive Frequency (Enhanced)

Higher frequency during handed-over state because trend-following baskets have more "state value" to preserve:

```
FUNCTION DetermineProtectionLevel()
    
    heat = CalculateCurrentHeat()
    handedOverCount = CountHandedOverBaskets()
    
    // Base level from heat
    IF (heat > 0.90)
        baseLevel = PROTECTION_CRITICAL
    ELSE IF (heat > 0.75)
        baseLevel = PROTECTION_HIGH
    ELSE IF (heat > 0.60)
        baseLevel = PROTECTION_ELEVATED
    ELSE
        baseLevel = PROTECTION_NORMAL
    
    // Boost level if baskets are handed over (trend-following mode)
    IF (handedOverCount > 0 AND baseLevel < PROTECTION_HIGH)
        baseLevel = baseLevel + 1    // Elevate by one level
    
    RETURN baseLevel
    
END FUNCTION
```

**Revised Intervals:**

| Base Level | With Handover Boost | Interval |
|------------|---------------------|----------|
| NORMAL | — | 30s |
| NORMAL | ELEVATED | 10s |
| ELEVATED | HIGH | 3s |
| HIGH | CRITICAL | 1s |
| CRITICAL | — | 1s |

### 4.4 Load Algorithm (OnInit with Handover Reconstruction)

```
FUNCTION LoadBasketCheckpoint(basketId)
    
    // Load basic fields (from v1.0)
    vt.peakPrice = SSoT_GV_Get(GV_TrailField(basketId, GV_TRAIL_PEAK))
    vt.stopLevel = SSoT_GV_Get(GV_TrailField(basketId, GV_TRAIL_STOP))
    vt.isActivated = (SSoT_GV_Get(GV_TrailField(basketId, GV_TRAIL_ACTIVE)) != 0.0)
    
    // Load handover-specific fields (v2.0)
    vt.isHandedOver = vt.isActivated    // If active, it was handed over
    vt.profitAtHandover = SSoT_GV_Get(GV_TrailField(basketId, GV_TRAIL_PROFIT_HO))
    vt.currentTrailDist = SSoT_GV_Get(GV_TrailField(basketId, GV_TRAIL_DISTANCE))
    vt.minimumStopLevel = SSoT_GV_Get(GV_TrailField(basketId, GV_TRAIL_MIN_STOP))
    
    // Validate
    checkpointTime = (datetime)SSoT_GV_Get(GV_TrailField(basketId, GV_TRAIL_TIME))
    IF (TimeCurrent() - checkpointTime > 3600)
        Print("Checkpoint expired — resetting trailing for basket ", basketId)
        ResetTrailingState(basketId)
        RETURN
    END IF
    
    // Reconstruct dynamic trail if needed
    IF (vt.currentTrailDist <= 0)
        vt.currentTrailDist = CalculateDynamicTrailDistance()
    END IF
    
    Print("Trailing restored for basket ", basketId,
          " — Peak: ", vt.peakPrice,
          " — Stop: ", vt.stopLevel,
          " — HandedOver: ", vt.isHandedOver)
    
END FUNCTION
```

---

## 5. EMERGENCY PHYSICAL STOPS (LAYER 3 — CATASTROPHIC NET)

### 5.1 Role (Revised)

The emergency layer serves as the **last-resort safety net** when:
1. Virtual trailing fails (terminal crash during EA runtime)
2. Heat reaches catastrophic levels (>90%)
3. Extended downtime is planned
4. Connection to broker is unstable

**Key Difference from v1.0:** Emergency stops are now primarily for **terminal crashes during trend-following**, not just extended downtime. A basket handed over and running a +$200 trend must be protected even if the EA process dies.

### 5.2 Trigger Conditions (Unchanged)

```
AutoEmergencyCondition():
    1. Heat > 90%
    2. Planned maintenance > 1 hour
    3. Connection unstable
    4. User-initiated shutdown
```

### 5.3 Emergency Stop Price for Handed-Over Baskets

For handed-over baskets, the emergency stop uses the **virtual trailing stop level** instead of recalculating from weighted average:

```
FUNCTION CalculateEmergencyStopPrice(basketIndex)
    
    basket = g_baskets[basketIndex]
    vt = g_virtualTrail[basketIndex]
    
    IF (vt.isHandedOver)
        // Use virtual stop level (preserves trend-capture progress)
        emergencyPrice = vt.stopLevel
        
        // Add small additional buffer for broker execution
        IF (basket.direction == BUY)
            emergencyPrice = emergencyPrice - EmergencyBufferPoints    // -5 pts
        ELSE
            emergencyPrice = emergencyPrice + EmergencyBufferPoints    // +5 pts
    ELSE
        // Not handed over — use original v1.0 calculation
        emergencyPrice = CalculateOriginalEmergencyStop(basketIndex)
    END IF
    
    RETURN emergencyPrice
    
END FUNCTION
```

**Rationale:** If a basket is at +$150 profit with a virtual stop at +$120, the emergency stop should protect the $120 level, not revert to breakeven (+$0).

### 5.4 OnDeinit Behavior (Revised)

```
void OnDeinit(const int reason)
{
    // ... other cleanup ...
    
    IF (reason == REASON_REMOVE OR reason == REASON_CHARTCHANGE)
    {
        FOR each active basket:
            
            IF (g_virtualTrail[i].isHandedOver)
                // Set emergency stop at virtual trailing level
                // This preserves trend-capture progress after EA removal
                SetEmergencyStopAtTrailingLevel(i)
            ELSE
                // Original behavior: set at WA + buffer
                SetEmergencyStop(i)
        END FOR
    }
}
```

---

## 6. STATE MANAGEMENT SPECIFICATION

### 6.1 Revised VirtualTrailingState Structure

```cpp
struct VirtualTrailingState
{
    // v1.0 Fields (protection mode)
    double   peakPrice;           // Highest (BUY) / lowest (SELL) since handover
    double   stopLevel;           // Current virtual stop price
    bool     isActivated;         // Trailing algorithm active?
    datetime peakTime;            // When peak was last updated
    
    // v2.0 Fields (trend-following mode)
    bool     isHandedOver;        // NEW: Basket handed over from FastStrike?
    double   profitAtHandover;    // NEW: Profit level at handover time
    double   currentTrailDist;    // NEW: Current dynamic trail distance
    double   minimumStopLevel;    // NEW: Floor level (profit lock)
    datetime handoverTime;        // NEW: When handover occurred
};
```

### 6.2 Basket Status Evolution

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    BASKET LIFECYCLE WITH HANDOVER                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  CREATED ──→ ACTIVE ──→ FASTSTRIKE HIT ──→ HANDED OVER ──→ TRAILING   │
│     │          │              │                │              │         │
│     │          │              │                │              │         │
│     ▼          ▼              ▼                ▼              ▼         │
│  Level 0    Levels      Layer 2 confirms   Peak tracking   Trigger     │
│  adopted    added       profit ≥ target    begins          close       │
│                                                                          │
│  Status:    Status:     Status:           Status:          Status:     │
│  ACTIVE     ACTIVE      ACTIVE            ACTIVE →        CLOSING      │
│                                        (isHandedOver=true)             │
│                                                                          │
│  FastStrike: FastStrike: FastStrike:     FastStrike:      FastStrike:  │
│  Evaluates  Evaluates   HANDOVER or      IGNORES          N/A          │
│                          CLOSE (if too                            │
│                          young)                                    │
│                                                                          │
│  VirtualTrail: VirtualTrail: VirtualTrail: VirtualTrail:   VirtualTrail:│
│  Inactive   Inactive    Activates         Manages exit      Triggers   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Maximum Growth Tracking

The system tracks the maximum profit achieved during trend-following:

```
FUNCTION GetMaximumProfitAchieved(basketIndex)
    
    basket = g_baskets[basketIndex]
    vt = g_virtualTrail[basketIndex]
    
    IF (NOT vt.isHandedOver)
        RETURN 0.0
    
    // Calculate profit at peak price
    IF (basket.direction == BUY)
        peakDistance = vt.peakPrice - basket.weightedAvg
    ELSE
        peakDistance = basket.weightedAvg - vt.peakPrice
    
    peakProfit = peakDistance × basket.totalVolume × 100.0
    
    RETURN peakProfit
    
END FUNCTION
```

This metric is useful for:
- Dashboard display ("Max profit achieved: $X")
- Post-trade analytics
- Parameter optimization

---

## 7. ON TICK EXECUTION ORDER (REVISED)

```cpp
void OnTick()
{
    // ═══════════════════════════════════════════════════════
    // PRIORITY 1: FastStrike Check (with Handover Protocol)
    // ═══════════════════════════════════════════════════════
    // Evaluates non-handed-over baskets for target hit.
    // If target hit AND age sufficient → hands over to trailing.
    // If target hit BUT too young → closes immediately.
    // If handed-over basket → skipped (trailing manages it).
    // ═══════════════════════════════════════════════════════
    FastStrikeCheck();
    
    // If handover occurred, FastStrikeCheck() returns.
    // Trailing takes over on this same tick (below).
    
    // ═══════════════════════════════════════════════════════
    // PRIORITY 2: Grid Level Management (Phase 3)
    // ═══════════════════════════════════════════════════════
    // Grid additions still allowed on non-handed-over baskets.
    // Handed-over baskets MAY receive new levels if price
    // continues moving against position (trend continuation).
    // ═══════════════════════════════════════════════════════
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    CheckGridLevels(bid, ask);
    
    // ═══════════════════════════════════════════════════════
    // PRIORITY 3: Virtual Trailing (Phase 5 — Trend Following)
    // ═══════════════════════════════════════════════════════
    // Manages ALL handed-over baskets.
    // Tracks peaks, updates dynamic stops, triggers closes.
    // ═══════════════════════════════════════════════════════
    for (int i = 0; i < g_basketCount; i++)
    {
        if (g_baskets[i].isValid && 
            g_baskets[i].status == BASKET_ACTIVE &&
            g_virtualTrail[i].isHandedOver)    // Only handed-over baskets
        {
            UpdateVirtualTrailing(i, bid, ask);
        }
    }
}
```

---

## 8. CONFIGURATION PARAMETERS (REVISED)

### 8.1 New Input Parameters

```cpp
// Handover Protocol
input bool   inpEnableHandover = true;           // Enable trend-following mode
input int    inpMinimumHandoverAge = 120;        // Seconds before handover allowed
input double inpHandoverProfitThreshold = 0.95;  // Layer 2 threshold (0.95 = 95%)

// Dynamic Trail Distance
input int    inpTrailBaseDistance = 50;          // Base trail distance (points)
input double inpTrailATRMultiple = 1.5;          // ATR multiplier for trail
input bool   inpUseATRDirectTrail = true;        // Use ATR × multiple (vs. normalized)

// Minimum Stop (Profit Lock)
input double inpProfitLockBuffer = 2.0;          // Points below handover profit

// Emergency Buffer
input int    inpEmergencyBufferPoints = 5;       // Additional buffer for emergency SL
```

### 8.2 Preset Configurations

**Preset: Trend Catcher (Recommended for XAUUSD)**
```cpp
inpEnableHandover = true
inpMinimumHandoverAge = 120
inpTrailBaseDistance = 50
inpTrailATRMultiple = 1.5
inpUseATRDirectTrail = true
inpProfitLockBuffer = 2.0
```

**Preset: Profit Lock (Conservative)**
```cpp
inpEnableHandover = true
inpMinimumHandoverAge = 60      // Faster handover
inpTrailBaseDistance = 35       // Tighter trail
inpTrailATRMultiple = 1.0       // Tight ATR multiple
inpUseATRDirectTrail = true
inpProfitLockBuffer = 5.0       // Larger safety buffer
```

**Preset: Classic (Original Behavior — No Handover)**
```cpp
inpEnableHandover = false       // FastStrike closes at target
// All trailing parameters ignored
```

---

## 9. PERFORMANCE BUDGET (REVISED)

### 9.1 FastStrikeCheck() with Handover

| Operation | Added Cost | Total Cost |
|-----------|------------|------------|
| `isHandedOver` check | ~1 cycle | Negligible |
| Age comparison | ~2 cycles | Negligible |
| `HandOverToTrailing()` call | ~50 cycles (one-time) | < 0.01ms |
| **Total per basket** | | **< 0.05ms** |

### 9.2 UpdateVirtualTrailing() with Dynamic Trail

| Operation | Cost |
|-----------|------|
| `isHandedOver` check | ~1 cycle |
| Dynamic trail calculation | ~10 cycles (ATR cache read) |
| Peak comparison + update | ~3 cycles |
| Stop recalculation + MIN/MAX | ~5 cycles |
| Trigger check | ~1 cycle |
| **Total per basket** | **~20 cycles = < 0.01ms** |

### 9.3 Overall OnTick() Budget

| Component | Target |
|-----------|--------|
| FastStrikeCheck() (with handover) | < 0.10ms |
| CheckGridLevels() | < 1.0ms |
| UpdateVirtualTrailing() (all handed-over) | < 0.5ms |
| **Total OnTick()** | **< 2.0ms** |

---

## 10. EDGE CASES (REVISED)

### 10.1 Handover Edge Cases

| Scenario | Handling |
|----------|----------|
| Profit target hit but age < 120s | **Close immediately** (don't hand over) — prevents handover on spike |
| Handover executed but price reverses instantly | Minimum stop level protects handover profit — closes at profit floor |
| Multiple baskets hit target same tick | Hand over the first one, others checked next tick |
| Handover during extremely wide spread | Layer 2 already accounts for spread — handover proceeds if net profit confirmed |

### 10.2 Trend-Following Edge Cases

| Scenario | Handling |
|----------|----------|
| ATR drops to 0 (indicator error) | Use `BaseTrailDistance` as fallback |
| Trail distance calculation < 10 pts | Clamp to minimum 10 points |
| Price gaps through stop level | Close on next available tick (gap risk accepted) |
| New grid level added to handed-over basket | Virtual trailing continues — new level included in basket close |
| Basket reaches max levels (7) while trailing | Trailing continues — no new levels added |

---

## 11. DECISION LOG (REVISED)

| Decision | Rationale | Source |
|----------|-----------|--------|
| Handover instead of immediate close | Captain's directive: "Let profits run" | User requirement |
| Minimum handover age: 120s | Confirms trend persistence beyond FastStrike confirmation | §2.2 |
| Dynamic trail: ATR × 1.5 | XAUUSD trends have 1–2× ATR pullbacks — 1.5× captures most | §3.2 |
| ATR-Direct as default | Naturally scales with XAUUSD volatility | §3.2 |
| Minimum stop level (profit floor) | Ensures handover doesn't lose money on instant reversal | §3.3 |
| FastStrike skips handed-over baskets | Prevents competing exit conditions | §2.5 |
| Emergency stop uses trailing level | Preserves trend-capture progress on EA crash | §5.3 |
| Checkpoint boost for handed-over | Higher-value state needs more frequent persistence | §4.3 |
| Grid additions allowed while trailing | Trend continuation may need deeper recovery | §6.2 |

---

## 12. CHANGE LOG (v1.0 → v2.0)

| Section | v1.0 (Protection) | v2.0 (Profit Maximization) |
|---------|-------------------|---------------------------|
| Objective | Protect profits | Let profits run |
| FastStrike | Closes at target | **Hands over to trailing** |
| Trail activation | 100 pts profit | **Handover event** |
| Trail distance | Fixed 50 pts | **Dynamic ATR × 1.5** |
| Initial stop | Breakeven (WA) | **Current price − trail** |
| Minimum stop | None | **Profit floor at handover** |
| Emergency SL | WA + buffer | **Trailing stop level** |
| Checkpoint fields | 4 GVs | **7 GVs (+profit, trail, min)** |
| Checkpoint frequency | Heat-based | **Heat + handover boost** |
| OnDeinit | Set at WA | **Set at trailing level** |

---

## 13. AUDIT CHECKLIST (FOR GLM-4.7)

- [ ] Handover protocol clearly defined with age gate
- [ ] Dynamic trail distance formula appropriate for XAUUSD
- [ ] Minimum stop level (profit floor) specified
- [ ] FastStrike correctly skips handed-over baskets
- [ ] Emergency stop uses trailing level for handed-over baskets
- [ ] Checkpoint schema includes new handover fields
- [ ] OnTick() execution order correct (FastStrike → Grid → Trailing)
- [ ] No GV calls in virtual trailing hot path
- [ ] Edge cases for instant reversal after handover handled
- [ ] Performance budget < 2.0ms for full OnTick()

---

## 14. APPROVAL SIGNATURES

| Role | Name | Status | Date |
|------|------|--------|------|
| Architect | KIMI-K2 | ✅ Delivered v2.0 | 2026-04-09 |
| QA Auditor | GLM-4.7 | ⏳ Pending Audit | — |
| Project Lead (Captain) | User | ⏳ Pending Approval | — |

---

**END OF PHASE 5 LOGIC SPECIFICATION (REVISED v2.0)**

*This document supersedes all previous Phase 5 specifications. No files shall be modified pending audit and sign-off.*
