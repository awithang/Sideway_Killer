# SIDEWAY KILLER - Architecture Debate Final Synthesis

**Topic:** Single Source of Truth (SSoT) vs Traditional State Management for MQL5
**Date:** 2026-04-09
**Participants:** Claude/Opus, Sonnet, Gemini, Codex
**Status:** ✅ CONSENSUS REACHED

---

## 🎯 EXECUTIVE SUMMARY

**Decision:** Hybrid Architecture Approved
- **SSoT:** Terminal Global Variables for persistence
- **Cache:** In-memory working copy for hot path optimization
- **Split:** Dual-path execution (hot/cold) as specified in core logic

**Rationale:** Satisfies both performance requirements (< 1ms hot path) and persistence requirements (survives restarts).

---

## 📊 DEBATE OUTCOMES

### Starting Positions

| Participant | Initial Position | Key Concern |
|-------------|------------------|-------------|
| Claude | Nuanced Hybrid | Balance performance with correctness |
| Sonnet | Performance-First | Pure SSoT adds unacceptable latency |
| Gemini | Architecture-First | SSoT is business requirement |
| Codex | Pragmatic Implementation | Cache synchronization complexity |

### Final Positions

| Participant | Final Position | Confidence | Key Shift |
|-------------|----------------|------------|-----------|
| Claude | Support Hybrid | 9.2/10 | Consistency maintained |
| Sonnet | Support (Conditional) | 8.5/10 | Accepted cache with strict performance gate |
| Gemini | Fully Support | 9.8/10 | Validated that cache ≠ alternative source |
| Codex | Support (Safeguards) | 9.0/10 | Provided implementation roadmap |

### Consensus Points

✅ **Global Variables are the Single Source of Truth**
- Authoritative data store
- Survives EA restarts
- Accessible to UI dashboard

✅ **Cache is an Access Optimization, Not Alternative Source**
- Read-only on hot path
- Refreshed periodically from GVs
- No independent authority

✅ **Dual-Path Architecture is Required**
- Hot Path: Fast profit checks using cache
- Cold Path: Full sync with GVs for validation

✅ **Performance Must Be Validated**
- Hot path target: < 1ms execution
- Cold path target: < 50ms sync time
- Profit First directive is non-negotiable

---

## 🏗️ APPROVED ARCHITECTURE

```
┌─────────────────────────────────────────────────────────────┐
│              SIDEWAY KILLER - DATA ARCHITECTURE             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  PERSISTENCE LAYER (SSoT)                            │   │
│  │  Terminal Global Variables                           │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │ Namespace: "SK_<BasketID>_<Field>"           │   │   │
│  │  │ Fields: WA, VOL, TARGET, STATUS, LEVELS     │   │   │
│  │  │ Purpose: Survive restarts, UI access        │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                      │
│                       │ Write-through (state changes)       │
│                       │ Periodic sync (1 sec)               │
│                       │                                      │
│  ┌────────────────────▼────────────────────────────────┐   │
│  │  WORKING LAYER (Cache)                               │   │
│  │  In-Memory Basket Array                              │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │ struct BasketCache {                        │   │   │
│  │  │   double weightedAvg;                       │   │   │
│  │  │   double totalVolume;                       │   │   │
│  │  │   double targetProfit;                      │   │   │
│  │  │   datetime lastSync;                        │   │   │
│  │  │   bool isValid;                             │   │   │
│  │  │ }                                            │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │  Access: Read-only on hot path                     │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                      │
│       ┌───────────────┴───────────────┐                     │
│       │                               │                     │
│  ┌────▼─────────┐              ┌──────▼─────┐              │
│  │ HOT PATH     │              │ COLD PATH   │              │
│  │ Every Tick   │              │ Every 1s    │              │
│  │              │              │             │              │
│  │ - Read Cache │              │ - Sync GVs  │              │
│  │ - Live Price │              │ - Refresh   │              │
│  │ - Calc Profit│              │ - Validate  │              │
│  │ - Close      │              │ - Log diffs │              │
│  │              │              │             │              │
│  │ Target: <1ms │              │ Target: <50ms│              │
│  └──────────────┘              └─────────────┘              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 IMPLEMENTATION GUIDE

### Step 1: Define Global Variable Schema

```mql5
// ============================================================
// GLOBAL VARIABLE NAMESPACE (SSoT)
// ============================================================
// Pattern: "SK_<BasketID>_<Field>"
// Example: "SK_001_WA" = Basket #1 Weighted Average

// Field Definitions:
// _WA      = Weighted Average Price (double)
// _VOL     = Total Volume in lots (double)
// _TARGET  = Profit Target USD (double)
// _STATUS  = 0=Active, 1=Closed (double)
// _LEVELS  = Number of grid levels (double)
// _DIR     = Direction 0=BUY, 1=SELL (double)
// _CREATED = Creation timestamp (double)

#define GV_PREFIX "SK_"
#define GV_WA "_WA"
#define GV_VOL "_VOL"
#define GV_TARGET "_TARGET"
#define GV_STATUS "_STATUS"
#define GV_LEVELS "_LEVELS"
#define GV_DIR "_DIR"
#define GV_CREATED "_CREATED"

// Helper Functions
string GVName(ulong basketId, string field) {
    return GV_PREFIX + IntegerToString(basketId, 3, '0') + field;
}
```

### Step 2: Define Cache Structure

```mql5
// ============================================================
// IN-MEMORY CACHE (Working Copy)
// ============================================================
struct BasketCache {
    ulong id;                  // Basket ID
    double weightedAvg;        // Weighted average price
    double totalVolume;        // Total lots
    double targetProfit;       // Profit target USD
    int levelCount;            // Number of levels
    int direction;             // 0=BUY, 1=SELL
    datetime created;          // Creation time
    datetime lastSync;         // Last GV sync
    bool isValid;              // Cache validity flag
};

BasketCache g_baskets[MAX_BASKETS];
int g_basketCount = 0;
bool g_cacheValid = false;
```

### Step 3: Implement Hot Path (OnTick)

```mql5
// ============================================================
// HOT PATH: Fast Profit Check
// CRITICAL: This function MUST complete in < 1ms
// ============================================================
void OnTick() {
    // Early exit if cache not ready
    if (!g_cacheValid) return;

    // Get live price (NEVER cache price data!)
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    // Fast-Strike: Check all baskets
    for (int i = 0; i < g_basketCount; i++) {
        if (!g_baskets[i].isValid) continue;

        // Calculate approximate profit using CACHE data
        double priceDist = 0;
        if (g_baskets[i].direction == 0) {  // BUY
            priceDist = bid - g_baskets[i].weightedAvg;
        } else {  // SELL
            priceDist = g_baskets[i].weightedAvg - ask;
        }

        // Fast profit calculation (Section 2.3)
        double profit = priceDist * g_baskets[i].totalVolume * 100.0;

        // CRITICAL: Close immediately if target hit
        if (profit >= g_baskets[i].targetProfit) {
            CloseBasketImmediate(i);
            return;  // Exit early - Profit First!
        }
    }

    // Grid logic: Check for new level additions
    // (Separate from profit check for clarity)
    CheckGridLevels(bid, ask);
}

void CloseBasketImmediate(int basketIndex) {
    // Close all positions in basket
    // This is the most critical function - must execute ASAP

    for (int i = g_baskets[basketIndex].levelCount - 1; i >= 0; i--) {
        // Close each position
        // Use PositionClose() not OrderClose() for speed
    }

    // Update SSoT
    string statusGV = GVName(g_baskets[basketIndex].id, GV_STATUS);
    GlobalVariableSet(statusGV, 1);  // Mark as closed

    // Invalidate cache entry
    g_baskets[basketIndex].isValid = false;
}
```

### Step 4: Implement Cold Path (OnTimer)

```mql5
// ============================================================
// COLD PATH: Sync with SSoT
// Runs every 1 second - Not time-critical
// ============================================================
int OnInit() {
    // Set up timer for sync
    EventSetTimer(1);  // 1 second interval
    LoadFromGlobals();  // Initial load
    return INIT_SUCCEEDED;
}

void OnTimer() {
    RefreshCacheFromGlobals();
    ValidateCacheConsistency();
}

void RefreshCacheFromGlobals() {
    int loaded = 0;

    // Scan for basket GVs
    for (int i = 0; i < MAX_BASKETS; i++) {
        string waName = GVName(i, GV_WA);
        double wa = GlobalVariableCheck(waName);

        if (wa == 0) continue;  // No basket at this ID

        // Load all fields
        g_baskets[loaded].id = i;
        g_baskets[loaded].weightedAvg = GlobalVariableCheck(GVName(i, GV_WA));
        g_baskets[loaded].totalVolume = GlobalVariableCheck(GVName(i, GV_VOL));
        g_baskets[loaded].targetProfit = GlobalVariableCheck(GVName(i, GV_TARGET));
        g_baskets[loaded].levelCount = (int)GlobalVariableCheck(GVName(i, GV_LEVELS));
        g_baskets[loaded].direction = (int)GlobalVariableCheck(GVName(i, GV_DIR));
        g_baskets[loaded].created = (datetime)GlobalVariableCheck(GVName(i, GV_CREATED));
        g_baskets[loaded].lastSync = TimeCurrent();
        g_baskets[loaded].isValid = true;

        loaded++;
    }

    g_basketCount = loaded;
    g_cacheValid = true;
}

void ValidateCacheConsistency() {
    // Run every 10 seconds (add counter)
    static int counter = 0;
    if (++counter < 10) return;
    counter = 0;

    // Spot-check: Compare cache with GVs
    for (int i = 0; i < g_basketCount; i++) {
        double cacheWA = g_baskets[i].weightedAvg;
        double gvWA = GlobalVariableCheck(GVName(g_baskets[i].id, GV_WA));

        if (MathAbs(cacheWA - gvWA) > 0.01) {
            Alert("Cache mismatch detected! Basket: ", g_baskets[i].id);
            Print("Cache: ", cacheWA, " GV: ", gvWA);
            RefreshCacheFromGlobals();  // Force resync
            break;
        }
    }
}
```

### Step 5: State Change Management

```mql5
// ============================================================
// STATE CHANGES: Write-through to SSoT
// ============================================================
void CreateNewBasket(ulong ticket, double openPrice, double lots, int dir) {
    ulong basketId = GetNextBasketId();

    // Write to SSoT
    GlobalVariableSet(GVName(basketId, GV_WA), openPrice);
    GlobalVariableSet(GVName(basketId, GV_VOL), lots);
    GlobalVariableSet(GVName(basketId, GV_TARGET), g_inputTargetProfit);
    GlobalVariableSet(GVName(basketId, GV_STATUS), 0);  // Active
    GlobalVariableSet(GVName(basketId, GV_LEVELS), 1);
    GlobalVariableSet(GVName(basketId, GV_DIR), dir);
    GlobalVariableSet(GVName(basketId, GV_CREATED), TimeCurrent());

    // Update cache immediately (sync write)
    g_baskets[g_basketCount].id = basketId;
    g_baskets[g_basketCount].weightedAvg = openPrice;
    g_baskets[g_basketCount].totalVolume = lots;
    g_baskets[g_basketCount].targetProfit = g_inputTargetProfit;
    g_baskets[g_basketCount].levelCount = 1;
    g_baskets[g_basketCount].direction = dir;
    g_baskets[g_basketCount].created = TimeCurrent();
    g_baskets[g_basketCount].lastSync = TimeCurrent();
    g_baskets[g_basketCount].isValid = true;
    g_basketCount++;
}

void AddGridLevel(ulong basketId, double addPrice, double addLots) {
    // Find basket in cache
    int idx = FindBasketIndex(basketId);
    if (idx < 0) return;

    // Calculate new weighted average
    double oldVol = g_baskets[idx].totalVolume;
    double oldWA = g_baskets[idx].weightedAvg;
    double newVol = oldVol + addLots;
    double newWA = ((oldWA * oldVol) + (addPrice * addLots)) / newVol;

    // Update SSoT
    GlobalVariableSet(GVName(basketId, GV_WA), newWA);
    GlobalVariableSet(GVName(basketId, GV_VOL), newVol);
    GlobalVariableSet(GVName(basketId, GV_LEVELS), g_baskets[idx].levelCount + 1);

    // Update cache
    g_baskets[idx].weightedAvg = newWA;
    g_baskets[idx].totalVolume = newVol;
    g_baskets[idx].levelCount++;
    g_baskets[idx].lastSync = TimeCurrent();
}
```

---

## ⚠️ CRITICAL IMPLEMENTATION WARNINGS

### Warning 1: Hot Path Purity

**DO NOT** call GlobalVariableCheck() in OnTick():
```mql5
// WRONG!
void OnTick() {
    double wa = GlobalVariableCheck("SK_001_WA");  // Blocks!
    // ...
}
```

**DO** use cache only:
```mql5
// RIGHT!
void OnTick() {
    double wa = g_baskets[0].weightedAvg;  // Fast!
    // ...
}
```

### Warning 2: Cache Mutability

**DO NOT** modify cache while iterating:
```mql5
// WRONG!
void OnTick() {
    for (int i = 0; i < g_basketCount; i++) {
        if (ShouldRefresh()) {
            RefreshFromGlobals();  // Modifies cache during iteration!
        }
    }
}
```

**DO** use immutable snapshots:
```mql5
// RIGHT!
void OnTick() {
    for (int i = 0; i < g_basketCount; i++) {
        // Read-only access
        double profit = CalculateProfit(g_baskets[i]);
    }
}
```

### Warning 3: Namespace Collision

**DO** use unique prefix to avoid conflicts:
```mql5
// WRONG!
GlobalVariableSet("Basket_1_WA", wa);  // Generic, may collide

// RIGHT!
GlobalVariableSet("SK_001_WA", wa);  // Unique to Sideway Killer
```

---

## 📊 PERFORMANCE VALIDATION CHECKLIST

Before deployment, MUST validate:

- [ ] OnTick execution time < 1ms (use GetMicrosecondCount())
- [ ] OnTimer sync time < 50ms
- [ ] Cache memory overhead < 10MB
- [ ] No GlobalVariableCheck() calls in hot path
- [ ] Restart recovery works (stop EA, start EA, state preserved)
- [ ] UI dashboard can read basket data from GVs
- [ ] No cache drift after 1 hour of operation
- [ ] Fast-Strike closes within 1 tick of target hit

---

## 🎯 CONCLUSION

**Approved Architecture:** Hybrid SSoT with Hot/Cold Path Split

**Key Takeaways:**
1. Global Variables = Single Source of Truth for persistence
2. Cache = Fast access layer for hot path optimization
3. Hot path (OnTick) = Read-only cache + live price
4. Cold path (OnTimer) = Sync with GVs for validation
5. Performance validation is mandatory before deployment

**Next Steps:**
1. Implement core data structures (BasketCache, GV schema)
2. Implement hot path with cache-only access
3. Implement cold path with GV sync
4. Add validation and error handling
5. Benchmark performance
6. Test restart scenarios

---

**Debate Participants:**
- Claude/Opus: Moderator + Technical Balance
- Sonnet: Performance Engineering
- Gemini: Strategic Architecture
- Codex: Implementation Realities

**Final Verdict:** UNANIMOUS APPROVAL with implementation safeguards
