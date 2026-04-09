# SIDEWAY KILLER — Position Adoption Protocol Design

**Document Version:** 1.0.0  
**Phase:** 2 — Position Adoption System  
**Architect:** KIMI-K2  
**Date:** 2026-04-09  
**Reference:** `SYNTHESIS/Adoption.md`, `SIDEWAY_KILLER_CORE_LOGIC.md §3`

---

## 1. EXECUTIVE SUMMARY

The Position Adoption System automatically identifies open manual trades that meet recovery criteria and converts them into managed **Baskets** (Level 0 positions). The system operates with **configurable modes**, **adaptive market filtering**, and **comment-based user overrides**.

**Design Goals:**
- 27× faster than manual adoption (< 2s vs 55+s)
- Flash-crash protection via adaptive filters
- Zero UI development overhead (comment-based controls)
- Seamless SSoT integration with Phase 1 architecture

---

## 2. SYSTEM ARCHITECTURE

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ADOPTION SYSTEM — HIGH LEVEL                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  USER CONTROL LAYER                                              │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │   │
│  │  │  NOADOPT    │  │    FORCE    │  │         CLEAR           │ │   │
│  │  │  (exclude)  │  │  (override) │  │  (reset overrides)      │ │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────────────┘ │   │
│  └────────────────────────┬────────────────────────────────────────┘   │
│                           │                                              │
│  ┌────────────────────────▼────────────────────────────────────────┐   │
│  │  ADOPTION MODE SELECTOR                                          │   │
│  │  ┌──────────┬──────────┬──────────────┬────────────────────────┐ │   │
│  │  │ AGGRESSIVE│   SMART  │ CONSERVATIVE │       MANUAL          │ │   │
│  │  │  (fast)   │(default) │   (safe)     │    (force-only)       │ │   │
│  │  └──────────┴──────────┴──────────────┴────────────────────────┘ │   │
│  └────────────────────────┬────────────────────────────────────────┘   │
│                           │                                              │
│  ┌────────────────────────▼────────────────────────────────────────┐   │
│  │  SCAN → FILTER → EVALUATE → ADOPT PIPELINE                       │   │
│  │  ┌────────┐  ┌──────────┐  ┌────────────┐  ┌──────────────────┐ │   │
│  │  │  Scan  │→│  Base    │→│ Mode-Specific│→│  SSoT_Create     │ │   │
│  │  │All Pos │  │ Criteria │  │   Filters    │  │   Basket()       │ │   │
│  │  └────────┘  └──────────┘  └────────────┘  └──────────────────┘ │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. TRIGGER SCHEDULE

| Event | Frequency | Handler | Latency Target |
|-------|-----------|---------|----------------|
| User command scan | Every 1 second | `OnTimer()` | < 50ms |
| Adoption candidate scan | Every 1 second | `OnTimer()` | < 1ms/position |
| Market state update | Every 1 second | `OnTimer()` | < 5ms |
| Tracking maintenance | Every 1 second | `OnTimer()` | < 5ms |

**Execution Order in OnTimer():**
1. `Adoption_ProcessUserCommands()` — Parse comments
2. `Adoption_UpdateMarketState()` — Cache volatility/spread
3. `Adoption_ExecuteScan()` — Main adoption pipeline

---

## 4. BASE CRITERIA (All Modes)

Every position must pass ALL base criteria before mode-specific evaluation.

### Criterion 1: Magic Number Match
```
IF (position_magic == g_targetMagic) OR (position_magic == 0)
    → PASS
ELSE
    → FAIL (reason: "Magic mismatch")
```

### Criterion 2: Symbol Match
```
IF (position_symbol == _Symbol)
    → PASS
ELSE
    → FAIL (reason: "Symbol mismatch")
```

### Criterion 3: Must Be In Loss
```
IF (position_profit < 0)
    → PASS
ELSE
    → FAIL (reason: "Position in profit")
```

### Criterion 4: Drawdown Within Range
```
BUY:  drawdown% = ((openPrice - currentBid) / openPrice) × 100
SELL: drawdown% = ((currentAsk - openPrice) / openPrice) × 100

IF (0% < drawdown% < 2.0%)
    → PASS
ELSE IF (drawdown% <= 0%)
    → FAIL (reason: "No drawdown")
ELSE IF (drawdown% >= 2.0%)
    → FAIL (reason: "Drawdown too deep")
```

### Criterion 5: Not Already Adopted
```
FOR EACH active basket:
    FOR EACH level in basket:
        IF (level.ticket == position_ticket)
            → FAIL (reason: "Already in basket")
→ PASS
```

### Criterion 6: Not User-Excluded
```
IF (g_userOverrides.excluded[ticket] == true)
    → FAIL (reason: "User excluded")
→ PASS
```

### Criterion 7: Capacity Available
```
IF (g_basketCount < inpMaxBaskets) AND (g_basketCount < SK_MAX_BASKETS)
    → PASS
ELSE
    → FAIL (reason: "Max baskets reached")
```

---

## 5. MODE-SPECIFIC LOGIC

### 5.1 AGGRESSIVE Mode (`ADOPT_AUTO_ALL`)

**Philosophy:** Speed over safety. Minimal filters.

**Additional Checks:**
```
// Minimum age only
datetime openTime = PositionGetInteger(POSITION_TIME);
int ageSeconds = (int)(TimeCurrent() - openTime);

IF (ageSeconds >= 30)
    → ADOPT
ELSE
    → REJECT (reason: "Too young")
```

**Characteristics:**
- Fastest adoption
- May adopt during flash crashes
- Suitable for users who prioritize recovery speed

---

### 5.2 SMART Mode (`ADOPT_AUTO_SMART`) — DEFAULT

**Philosophy:** Adaptive balance. Market-aware filtering.

**Additional Checks:**

#### Step 1: Adaptive Minimum Age
```
baseAge = inpSmartMinAge (default: 60s)

IF (g_market.isHighVolatility)
    baseAge = baseAge × 2.0     // 120s

IF (g_market.isWideSpread)
    baseAge = baseAge × 1.5     // 90s

IF (both conditions)
    baseAge = baseAge × 3.0     // 180s (capped)

IF (ageSeconds < baseAge)
    → REJECT (reason: "Below adaptive age")
```

#### Step 2: Adaptive Spread Check
```
avgSpread = Adoption_GetAverageSpread(100)
currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)

maxSpread = avgSpread × (inpSmartSpreadMult + g_market.volatilityRatio)

IF (currentSpread > maxSpread)
    → REJECT (reason: "Spread too wide")
```

#### Step 3: Volatility Sanity Check (Conditional)
```
IF (g_market.isHighVolatility)
    IF (!Adoption_IsPriceStable(ticket, 15))
        → REJECT (reason: "Price unstable")
```

**Price Stability Algorithm:**
```
// Check if price moved > 0.5% in last N seconds
barsToCheck = ceil(15 / 60) + 1 = 2 bars (M1)
CopyRates(_Symbol, PERIOD_M1, 0, 2, rates)

priceNow = currentPrice
priceThen = rates[1].close
movePct = |priceNow - priceThen| / priceThen × 100

IF (movePct < 0.5%)
    → STABLE
ELSE
    → UNSTABLE
```

**Characteristics:**
- Recommended for most users
- Adapts to market conditions automatically
- Balances speed and safety

---

### 5.3 CONSERVATIVE Mode (`ADOPT_AUTO_CONSERVATIVE`)

**Philosophy:** Maximum safety. Fixed strict thresholds.

**Additional Checks:**

```
// Stricter minimum age
IF (ageSeconds < 90)
    → REJECT (reason: "Below conservative age")

// Stricter spread check
avgSpread = Adoption_GetAverageSpread(100)
currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)

IF (currentSpread > avgSpread × 2.0)
    → REJECT (reason: "Spread exceeds conservative threshold")

// Stricter volatility check
atr14 = iATR(14)
atr100 = iATR(100)
volRatio = atr14 / atr100

IF (volRatio > 1.5)
    → REJECT (reason: "Volatility too high")
```

**Characteristics:**
- Slowest adoption
- Best protection against edge cases
- May miss some recovery opportunities

---

### 5.4 MANUAL Mode (`ADOPT_MANUAL_ONLY`)

**Philosophy:** User has full control.

**Logic:**
```
IF (g_userOverrides.forced[ticket] == true)
    → ADOPT
ELSE
    → REJECT (reason: "Manual mode — force required")
```

**Characteristics:**
- Only FORCE-commented positions adopted
- Full user discretion
- Recovery delays possible

---

## 6. USER COMMAND SYSTEM

### 6.1 Command Interface

Users control adoption behavior by setting position comments via MT5 terminal.

| Command | Action | Effect | Persistence |
|---------|--------|--------|-------------|
| `NOADOPT` | Exclude position | Never adopt this ticket | Session-only |
| `FORCE` | Force adoption | Bypass ALL criteria | Session-only |
| `CLEAR` | Reset overrides | Remove from exclude/force lists | Session-only |

### 6.2 Command Processing Flow

```
FOR each open position:
    comment = PositionGetString(POSITION_COMMENT)

    IF (comment == "NOADOPT"):
        g_userOverrides.excluded[ticket] = true
        PositionSetString(POSITION_COMMENT, "NOADOPT [PROCESSED]")
        Print("Ticket ", ticket, " excluded from adoption")

    ELSE IF (comment == "FORCE"):
        g_userOverrides.forced[ticket] = true
        PositionSetString(POSITION_COMMENT, "FORCE [PROCESSED]")
        Print("Ticket ", ticket, " marked for forced adoption")

    ELSE IF (comment == "CLEAR"):
        g_userOverrides.excluded[ticket] = false
        g_userOverrides.forced[ticket] = false
        PositionSetString(POSITION_COMMENT, "CLEAR [PROCESSED]")
        Print("Ticket ", ticket, " override status cleared")
```

### 6.3 Anti-Reprocessing Protection

**Problem:** Without protection, same command would be processed every scan.

**Solution:** Append `" [PROCESSED]"` to comment after first processing.

**Fallback:** If `PositionSetString()` fails (insufficient permissions), track processed tickets in-memory using a `processedCommands[]` array with timestamp expiration (5 minutes).

### 6.4 FORCE Override Behavior

When a position is FORCE-marked:
- **ALL criteria are bypassed** — magic, symbol, drawdown, age, spread
- User assumes full responsibility
- FORCE evaluation takes priority over NOADOPT
- Position is adopted immediately on next scan

---

## 7. SSoT INTEGRATION SPECIFICATION

### 7.1 Adoption Success Flow

```
Adoption_AdoptPosition(ticket)
    │
    ├─→ Select position by ticket
    ├─→ Extract: openPrice, lots, direction, magic
    │
    ├─→ CALL: SSoT_CreateBasket(ticket, openPrice, lots, direction, magic)
    │     │
    │     ├─→ Assign basketId from g_nextBasketId
    │     ├─→ Initialize BasketCache entry
    │     ├─→ Write basket core to GVs (9 fields)
    │     ├─→ Write Level 0 to GVs (4 fields)
    │     ├─→ Update global state GVs (SK_STATE_*)
    │     └─→ Increment g_basketCount, g_nextBasketId
    │
    ├─→ Adoption_NotifyAdopted(basketIndex, ticket)
    │     └─→ Alert("Basket X created with position Y")
    │
    └─→ Adoption_LogDecision(ticket, result)
          └─→ Print detailed adoption log
```

### 7.2 Pre-Adoption SSoT Checks

Before evaluating a position for adoption:

```
IF (!g_cacheValid)
    → SKIP (SSoT not ready)

IF (g_basketCount >= SK_MAX_BASKETS)
    → SKIP (capacity limit)
```

### 7.3 Post-Adoption Cache Update

After successful `SSoT_CreateBasket()`:

```
// Cache is already updated by SSoT layer
// No additional cache manipulation needed

// Dashboard should reflect new basket on next sync
// Trade statistics unchanged (only updated on basket CLOSE)
```

---

## 8. ADOPTION TRACKING SYSTEM

### 8.1 Purpose

Track evaluation history per position for:
- Debugging and audit trail
- Preventing excessive re-evaluation logging
- Analytics on rejection patterns

### 8.2 Tracking Data

```cpp
struct AdoptionTracking {
    ulong    ticket;           // Position ticket
    datetime firstSeen;        // First detection
    datetime lastEvaluated;    // Last evaluation
    int      evalCount;        // Evaluation count
    bool     wasAdopted;       // Final status
    string   rejectionReason;  // Last reason
};
```

### 8.3 Maintenance

Every scan cycle:
1. Add new positions not yet tracked
2. Remove entries for closed positions
3. Update `lastEvaluated` and `evalCount` on each check

---

## 9. ERROR HANDLING & EDGE CASES

| Scenario | Handling |
|----------|----------|
| Position closes during scan | Skip (detected in `Adoption_MaintainTracking()`) |
| `PositionSelectByTicket()` fails | Log warning, skip position |
| `PositionSetString()` fails | Fall back to in-memory tracking |
| Max baskets reached | Reject with "Max baskets" reason |
| Cache invalid during scan | Abort scan, wait for next timer |
| ATR indicator not ready | Skip volatility checks, use base age |
| Symbol has no history | Assume price stable |

---

## 10. PERFORMANCE BUDGET

| Operation | Target Latency | Notes |
|-----------|----------------|-------|
| User command scan | < 10ms | Linear with position count |
| Market state update | < 5ms | One ATR copy per scan |
| Base criteria check | < 0.1ms | Per position |
| Smart filters | < 0.5ms | Per position (with cached state) |
| Full scan (20 positions, Smart) | < 15ms | Total |
| SSoT_CreateBasket() | < 50ms | GV write-through |

---

## 11. MODE PRESET REFERENCE

### Preset: Aggressive (Maximum Speed)
```
AdoptionMode = ADOPT_AUTO_ALL
Min Age: 30s (hardcoded)
Spread Check: None
Volatility Check: None
Use Case: Users prioritizing speed
Risk: Flash crash adoption possible
```

### Preset: Balanced (Recommended — DEFAULT)
```
AdoptionMode = ADOPT_AUTO_SMART
Smart_MinAge = 60s
Smart_SpreadMult = 3.0
Smart_VolThreshold = 2.0
Use Case: Most users
Risk: Minimal — adaptive filters protect
```

### Preset: Conservative (Maximum Safety)
```
AdoptionMode = ADOPT_AUTO_CONSERVATIVE
Cons_MinAge = 90s
Cons_SpreadMult = 2.0
Cons_VolThreshold = 1.5
Use Case: Cautious users, high-volatility periods
Risk: May miss recovery opportunities
```

### Preset: Manual (Full Control)
```
AdoptionMode = ADOPT_MANUAL_ONLY
Use Case: Complete user control
Risk: Recovery delays
```

---

## 12. DECISION FLOWCHART

```
                         ┌─────────────┐
                         │  Open Pos   │
                         └──────┬──────┘
                                │
                    ┌───────────▼───────────┐
                    │  Already in Basket?   │
                    └──────┬────────┬───────┘
                           │YES     │NO
                           ▼        ▼
                      ┌────────┐   ┌───────────────┐
                      │  SKIP  │   │ User Excluded?│
                      └────────┘   └───────┬───────┘
                                           │YES    │NO
                                           ▼       ▼
                                      ┌────────┐  ┌──────────────┐
                                      │  SKIP  │  │ User Forced? │
                                      └────────┘  └──────┬───────┘
                                                         │YES   │NO
                                                         ▼      ▼
                                                    ┌────────┐ ┌─────────────┐
                                                    │  ADOPT │ │ Base Criteria│
                                                    │IMMEDIATE│ │    Check     │
                                                    └────────┘ └──────┬──────┘
                                                                      │PASS │FAIL
                                                                      ▼     ▼
                                                                 ┌────────┐┌─────┐
                                                                 │ Mode   ││SKIP │
                                                                 │Specific│└─────┘
                                                                 │ Filter │
                                                                 └────┬───┘
                                                                      │PASS│FAIL
                                                                      ▼    ▼
                                                                 ┌────────┐┌────┐
                                                                 │  ADOPT ││SKIP│
                                                                 └────────┘└────┘
```

---

**END OF ADOPTION PROTOCOL DESIGN**

*Next: Phase 3 — Grid System (DVASS spacing, lot multipliers)*
