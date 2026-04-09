# QWEN-Coder — Implementation Task Assignment

**Role:** Senior MQL5 Lead Programmer  
**Mission:** Transform KIMI-K2's architectural blueprints into high-efficiency MQL5 source code  
**Priority Directive:** "Profit First" — Close All must execute immediately when target hit  
**Anti-Lag Commitment:** Eliminate any code causing >1ms hot-path delays

---

## 📋 TABLE OF CONTENTS

1. [Global Coding Mandates](#1-global-coding-mandates)
2. [Task Dependency Map](#2-task-dependency-map)
3. [Phase 1 Tasks: Foundation Layer](#3-phase-1-tasks-foundation-layer)
4. [Phase 2 Tasks: Position Adoption](#4-phase-2-tasks-position-adoption)
5. [Phase 3 Tasks: Grid System](#5-phase-3-tasks-grid-system)
6. [Phase 4 Tasks: Profit Detection](#6-phase-4-tasks-profit-detection)
7. [Phase 5 Tasks: Trailing Stop](#7-phase-5-tasks-trailing-stop)
8. [Phase 6 Tasks: Heat Management](#8-phase-6-tasks-heat-management)
9. [Phase 7 Tasks: Integration](#9-phase-7-tasks-integration)
10. [Performance Validation Checklist](#10-performance-validation-checklist)

---

## 1. GLOBAL CODING MANDATES

### 1.1 Performance Rules (NON-NEGOTIABLE)

| Rule | Violation Consequence |
|------|----------------------|
| **NO** `GlobalVariable*` calls in `OnTick()` | Instant rejection |
| **NO** `PositionGetDouble(POSITION_PROFIT)` in `OnTick()` | Instant rejection |
| **NO** `OrderSend()` in `OnTick()` except emergency | Instant rejection |
| **NO** loops > 20 iterations in `OnTick()` without early exit | Must justify |
| **NO** indicator recalculation in `OnTick()` | Use cached handles |
| **NO** string concatenation in `OnTick()` | Pre-compute |
| **NO** dynamic memory allocation in `OnTick()` | Static arrays only |

### 1.2 Code Style Requirements

```cpp
// Function naming: PascalCase, descriptive
void FastStrikeCheck()           // GOOD
void fs()                        // BAD

// Variable naming: g_ prefix for globals, camelCase
BasketCache g_baskets[];         // GOOD
BasketCache baskets;             // BAD (not global)

// Constants: UPPER_CASE with module prefix
#define SK_MAX_BASKETS 20        // GOOD
#define MAX 20                   // BAD (not namespaced)

// Comments: Every non-trivial block
// Hot path functions MUST have latency estimate comment

// Error handling: Always check return values
if (!PositionSelectByTicket(ticket)) {
    Print("ERROR: Failed to select position ", ticket);
    return false;
}
```

### 1.3 Architecture Compliance

- **All state changes → write-through to GVs** (via `SK_SSoT.mqh` interface)
- **All hot-path reads → from cache only** (`g_baskets[]`)
- **All GV sync → in `OnTimer()` or event handlers** (cold path)
- **All basket operations → atomic** (complete cache + GV update)

---

## 2. TASK DEPENDENCY MAP

```
Phase 1 (Foundation)
    │
    ├──→ Phase 2 (Adoption) ──→ Phase 3 (Grid)
    │                              │
    │                              ├──→ Phase 4 (Profit Detection)
    │                              │
    │                              └──→ Phase 5 (Trailing Stop)
    │
    └──→ Phase 6 (Heat Management)
             │
             └──→ Phase 7 (Integration + Testing)

Parallel Work Opportunities:
- Phase 3 Grid Spacing & Phase 3 Lot Multiplier can be developed in parallel
- Phase 4 & Phase 5 can be developed in parallel after Phase 3
- Phase 6 can be developed in parallel with Phase 7
```

---

## 3. PHASE 1 TASKS: FOUNDATION LAYER

### Task 1.1: Implement SSoT Core Functions

**File:** `Modules/SK_SSoT.mqh`  
**Status:** Architecture complete — needs implementation  
**Priority:** CRITICAL (blocks all other tasks)

**Functions to Implement:**

```cpp
//--- Initialization & Lifecycle
bool   SSoT_Init();
void   SSoT_Deinit(const int reason);

//--- Hot Path: Cache-only read operations
bool   SSoT_IsCacheValid();
int    SSoT_GetBasketCount();
bool   SSoT_GetBasket(const int index, BasketCache &outBasket);
double SSoT_GetWeightedAvg(const int index);
double SSoT_GetTotalVolume(const int index);
double SSoT_GetTargetProfit(const int index);
int    SSoT_GetLevelCount(const int index);
int    SSoT_GetDirection(const int index);

//--- Cold Path: GV Synchronization
void   SSoT_RefreshCacheFromGlobals();
void   SSoT_ValidateCacheConsistency();
void   SSoT_SyncDashboardToGlobals();

//--- State Change: Write-through to SSoT
int    SSoT_CreateBasket(const ulong ticket, const double openPrice, 
                          const double lots, const int dir, const ulong magic);
void   SSoT_AddGridLevel(const int basketIndex, const ulong ticket,
                          const double lots, const double price);
void   SSoT_UpdateBasketStatus(const int basketIndex, 
                                const ENUM_BASKET_STATUS status);
void   SSoT_CloseBasket(const int basketIndex);
void   SSoT_SaveCheckpoint(const int basketIndex);
void   SSoT_LoadCheckpoint(const int basketIndex);

//--- Bulk Operations
void   SSoT_SaveAllBaskets();
void   SSoT_LoadAllBaskets();
void   SSoT_SaveTradeStats();
void   SSoT_LoadTradeStats();
void   SSoT_SaveGlobalState();
void   SSoT_LoadGlobalState();

//--- Cleanup & Maintenance
void   SSoT_PurgeOrphanedRecords();
void   SSoT_ClearAllGlobals();
int    SSoT_CountOrphanedRecords();

//--- GV Wrapper Functions
bool   SSoT_GV_Set(const string name, const double value);
double SSoT_GV_Get(const string name);
bool   SSoT_GV_Exists(const string name);
bool   SSoT_GV_Delete(const string name);

//--- Internal Helpers
void   SSoT_RecalcWeightedAvg(const int basketIndex);
void   SSoT_WriteBasketToGlobals(const int basketIndex);
bool   SSoT_ReadBasketFromGlobals(const ulong basketId, BasketCache &outBasket);
void   SSoT_ClearBasketGlobals(const ulong basketId);
ulong  SSoT_GetNextBasketId();
bool   SSoT_IsBasketIdAvailable(const ulong id);
```

**Acceptance Criteria:**
- [ ] `SSoT_Init()` loads all baskets from GVs on startup
- [ ] `SSoT_CreateBasket()` writes 13 GVs (9 core + 4 level 0) + updates state
- [ ] `SSoT_RefreshCacheFromGlobals()` completes in < 50ms with 20 baskets
- [ ] `SSoT_ValidateCacheConsistency()` detects and logs mismatches
- [ ] Restart test: stop EA, modify GV, restart → cache reflects changes
- [ ] NO `GlobalVariableCheck()` calls outside cold path functions

**Reference Documents:**
- `SYNTHESIS/SSoT.md` — Architecture specification
- `Docs/GV_SCHEMA.md` — Complete GV mapping
- `Modules/SK_GVSchema.mqh` — Naming convention helpers

---

### Task 1.2: Implement Utility Functions

**File:** `Modules/SK_Utils.mqh` (NEW FILE)  
**Priority:** CRITICAL

**Functions to Implement:**

```cpp
//--- ATR Calculations
 double CalcATR(const int period);
 double CalcATRFast();
 double GetNormalizedATR();

//--- Spread Calculations
 double GetCurrentSpread();
 double GetAverageSpread(const int periods);
 void   UpdateSpreadStats();

//--- Weighted Average
 double CalcWeightedAverage(const double prices[], const double volumes[], 
                             const int count);
 double UpdateWeightedAverage(const double oldWA, const double oldVol,
                               const double newPrice, const double newVol);

//--- Heat Calculations
 double CalcBasketHeat(const int basketIndex);
 double CalcTotalHeat();
 double CalcCurrentHeat();
 bool   IsHeatCritical();
 bool   IsHeatWarning();

//--- Drawdown
 double CalcDrawdownPct(const double openPrice, const double currentPrice, 
                         const int direction);

//--- Price Helpers
 double GetPriceForDirection(const int direction, const bool isOpen = false);
 double GetBid();
 double GetAsk();

//--- Lot Normalization
 double NormalizeLot(const double lot);
```

**Acceptance Criteria:**
- [ ] `CalcATR(14)` returns valid ATR value (not 0 after warm-up)
- [ ] `UpdateWeightedAverage()` produces mathematically correct results
- [ ] `CalcBasketHeat()` matches formula: `(WA - Price) × Volume × 100 / Balance`
- [ ] All functions have error handling (no division by zero)

---

## 4. PHASE 2 TASKS: POSITION ADOPTION

### Task 2.1: Implement Adoption Core Logic

**File:** `Modules/SK_Adoption.mqh`  
**Status:** Architecture complete — needs implementation  
**Priority:** HIGH (depends on Task 1.1)

**Functions to Implement:**

```cpp
//--- Public API
bool   Adoption_Init();
void   Adoption_Deinit();
void   Adoption_ExecuteScan();
void   Adoption_ProcessUserCommands();
bool   Adoption_ShouldAdopt(const ulong ticket, AdoptionResult &result);
int    Adoption_AdoptPosition(const ulong ticket);

//--- Base Criteria
bool   Adoption_MeetsBaseCriteria(const ulong ticket, AdoptionResult &result);
double Adoption_CalcDrawdownPct(const ulong ticket);
bool   Adoption_IsPositionInBasket(const ulong ticket);
double Adoption_GetCurrentPrice(const int direction);

//--- Mode-Specific Logic
bool   Adoption_Mode_Aggressive(const ulong ticket, const AdoptionResult &baseResult);
bool   Adoption_Mode_Smart(const ulong ticket, const AdoptionResult &baseResult);
bool   Adoption_Mode_Conservative(const ulong ticket, const AdoptionResult &baseResult);
bool   Adoption_Mode_Manual(const ulong ticket);

//--- Smart Filters
int    Adoption_CalcAdaptiveMinAge();
double Adoption_CalcAdaptiveMaxSpread();
bool   Adoption_IsPriceStable(const ulong ticket, const int secondsWindow = 15);
void   Adoption_UpdateMarketState();
double Adoption_GetAverageSpread(const int periods);

//--- User Commands
void   Adoption_ScanUserCommands();
bool   Adoption_IsExcluded(const ulong ticket);
bool   Adoption_IsForced(const ulong ticket);
void   Adoption_AddExclusion(const ulong ticket);
void   Adoption_AddForce(const ulong ticket);
void   Adoption_ClearOverrides(const ulong ticket);

//--- Tracking & Logging
void   Adoption_MaintainTracking();
int    Adoption_GetTrackingIndex(const ulong ticket);
void   Adoption_LogDecision(const ulong ticket, const AdoptionResult &result);
void   Adoption_NotifyAdopted(const int basketIndex, const ulong ticket);
```

**Acceptance Criteria:**
- [ ] Aggressive mode adopts qualifying positions within 30s
- [ ] Smart mode applies adaptive age correctly (volatility ×2, spread ×1.5)
- [ ] `NOADOPT` comment prevents adoption
- [ ] `FORCE` comment bypasses ALL criteria
- [ ] `CLEAR` comment resets overrides
- [ ] Positions already in baskets are never double-adopted
- [ ] Full scan of 20 positions completes in < 15ms

**Test Scenarios:**
1. Place manual BUY position on XAUUSD, wait 60s → should be adopted (Smart mode)
2. Comment "NOADOPT" on position → should NOT be adopted
3. Comment "FORCE" on position with 50% drawdown → SHOULD be adopted
4. Position already in basket → should NOT be re-adopted
5. 5 active baskets, max = 3 → should NOT adopt new positions

**Reference Documents:**
- `Docs/ADOPTION_PROTOCOL.md` — Complete specification
- `SYNTHESIS/Adoption.md` — Debate synthesis

---

## 5. PHASE 3 TASKS: GRID SYSTEM

### Task 3.1: Implement Grid Spacing Engine (DVASS)

**File:** `Modules/SK_Grid.mqh` (NEW FILE)  
**Priority:** HIGH (depends on Task 1.1, 1.2)

**Functions to Implement:**

```cpp
//--- Grid Spacing Interface
double GetGridDistance(const int basketIndex, const int level);

//--- FIXED Mode
double CalculateFixedSpacing(const int level);

//--- DVASS Mode
double CalculateDVASS(const int level);
double GetSafeATR();
double GetSafeATR_Fast();

//--- HYBRID Mode
double CalculateHybridSpacing(const int level);
ENUM_VOL_REGIME DetectRegime(const double atr);

//--- Grid Level Management
void   CheckGridLevels(const double bid, const double ask);
bool   ShouldAddLevel(const int basketIndex, const double bid, const double ask);
int    AddGridLevel(const int basketIndex);

//--- Price Level Calculation
double GetNextLevelPrice(const int basketIndex, const int newLevel);
```

**Acceptance Criteria:**
- [ ] FIXED mode: spacing = BaseStep × (Expansion^level)
- [ ] DVASS mode: spacing = BaseStep × (ATR/20) × (1.3^level)
- [ ] DVASS fallback to FIXED when ATR = 0 or > 200
- [ ] Min/Max bounds enforced (150 / 1200 points)
- [ ] Spike detection triggers when FastATR > 1.5 × NormalATR
- [ ] Grid levels add at correct distances for both BUY and SELL

**Reference Documents:**
- `SYNTHESIS/Grid.md` — Grid spacing debate synthesis
- `SIDEWAY_KILLER_CORE_LOGIC.md §1.2` — DVASS mathematics

---

### Task 3.2: Implement Lot Multiplier System

**File:** `Modules/SK_LotMultiplier.mqh` (NEW FILE)  
**Priority:** HIGH (parallel with Task 3.1)

**Functions to Implement:**

```cpp
//--- Main Interface
double GetLotMultiplier(const int basketIndex, const int level);

//--- FIXED Mode
double CalculateFixedMultiplier(const int level);

//--- BAYESIAN KELLY Mode
double CalculateBayesianKelly(const int level);

//--- HYBRID Mode
double CalculateHybridMultiplier(const int level);

//--- Heat Constraint (applies to ALL modes)
double ApplyHeatConstraint(const double multiplier);
double CalculateCurrentHeat();

//--- Trade Statistics
double GetCurrentWinRate();
void   OnBasketClosed(const double profit, const int levelsUsed);
void   SaveTradeStats();
void   LoadTradeStats();
void   InitializeBayesianPriors();
```

**Acceptance Criteria:**
- [ ] FIXED: multiplier = Base × (Decay^level)
- [ ] BAYESIAN: Kelly formula with prior strength of 20
- [ ] Heat > 90% → multiplier forced to 1.1
- [ ] Heat > 70% → multiplier × 0.8
- [ ] Trade stats persist to GVs and survive restart
- [ ] Result always within broker lot constraints

**Reference Documents:**
- `SYNTHESIS/Lot_Multiplier.md` — Lot multiplier debate synthesis
- `SIDEWAY_KILLER_CORE_LOGIC.md §1.3` — RAKIM mathematics

---

## 6. PHASE 4 TASKS: PROFIT DETECTION

### Task 4.1: Implement Fast-Strike System

**File:** `Modules/SK_FastStrike.mqh` (NEW FILE)  
**Priority:** CRITICAL — "Profit First" directive

**Functions to Implement:**

```cpp
//--- Main Entry Point (CALLED FROM OnTick — HOT PATH)
void   FastStrikeCheck();

//--- Layer 1: Aggressive Math
double CalculateLayer1(const int basketIndex);

//--- Layer 2: Conservative Math
double CalculateLayer2(const int basketIndex);
double GetConservativeValuePerPoint();
double GetSpreadBuffer();

//--- Layer 3: API Verification (optional)
double CalculateLayer3(const int basketIndex);

//--- Execution
void   CloseBasketImmediate(const int basketIndex);
bool   ClosePosition(const ulong ticket);

//--- Cold Path Validation
void   UpdateSpreadStatistics();
void   ValidateMathAccuracy();
void   UpdateAPIVerificationCache();
```

**Performance Requirements (NON-NEGOTIABLE):**
| Function | Max Latency | Notes |
|----------|-------------|-------|
| `FastStrikeCheck()` | < 0.10ms | Entire function |
| `CalculateLayer1()` | < 0.05ms | Pure math, no API |
| `CalculateLayer2()` | < 0.05ms | Pure math, no API |
| `CloseBasketImmediate()` | ASAP | Priority 1 execution |

**Acceptance Criteria:**
- [ ] Layer 1: `profit = distance × volume × 100.0`
- [ ] Layer 2: `netProfit = gross - spreadCost - commission`
- [ ] Closes basket when Layer 2 ≥ target × 0.95
- [ ] Early exit after first close (don't check remaining baskets)
- [ ] NO `PositionGetDouble(POSITION_PROFIT)` in `FastStrikeCheck()`
- [ ] `OnTick()` total latency < 1ms with 10 active baskets

**CRITICAL WARNINGS:**
- Hot path purity: Only cache reads and `SymbolInfoDouble()` allowed
- Early exit: `return` immediately after `CloseBasketImmediate()`
- Basket closure: Must close ALL positions before updating status

**Reference Documents:**
- `SYNTHESIS/Fast_Strike.md` — Fast-Strike debate synthesis
- `SIDEWAY_KILLER_CORE_LOGIC.md §2.3-2.4` — Profit calculation formulas

---

## 7. PHASE 5 TASKS: TRAILING STOP

### Task 5.1: Implement Three-Layer Protection

**File:** `Modules/SK_TrailingStop.mqh` (NEW FILE)  
**Priority:** HIGH (depends on Task 1.1, 1.2)

**Functions to Implement:**

```cpp
//--- Layer 1: Virtual Trailing (Hot Path)
void   UpdateVirtualTrailing(const int basketIndex);
void   UpdateAllVirtualTrailings();
double GetCurrentPrice(const int direction);

//--- Layer 2: Checkpoint Persistence (Cold Path)
void   UpdateCheckpointSystem();
ENUM_PROTECTION_LEVEL DetermineProtectionLevel();
void   SaveAllCheckpoints();
void   SaveBasketCheckpoint(const int basketIndex);
void   LoadAllCheckpoints();
void   LoadBasketCheckpoint(const int basketIndex);

//--- Layer 3: Emergency Physical Stops (Cold Path)
void   ManageEmergencyStops();
bool   ShouldActivateEmergencyStops();
bool   AutoEmergencyCondition();
void   SetEmergencyStop(const int basketIndex);
void   RemoveEmergencyStop(const int basketIndex);
bool   SetPhysicalStop(const ulong ticket, const double stopPrice);
bool   RemovePhysicalStop(const ulong ticket);
```

**Acceptance Criteria:**
- [ ] Virtual trailing activates at 100 points profit
- [ ] Stop level updates correctly with peak price
- [ ] Trigger closes entire basket (not individual positions)
- [ ] Checkpoints save every 1-30s based on protection level
- [ ] Checkpoints restore correctly after restart
- [ ] Emergency stops activate at heat > 90%
- [ ] All positions in basket get SAME stop price
- [ ] Emergency stops set on `OnDeinit()`

**CRITICAL WARNINGS:**
- Basket integrity: Same stop price for ALL positions
- Emergency buffer: Must include spread + commission
- Do NOT set virtual stop below weighted average before activation

**Reference Documents:**
- `SYNTHESIS/Trailing_Stop.md` — Trailing stop debate synthesis
- `SIDEWAY_KILLER_CORE_LOGIC.md §5` — Virtual trailing mathematics

---

## 8. PHASE 6 TASKS: HEAT MANAGEMENT

### Task 6.1: Implement Heat & Safety System

**File:** `Modules/SK_Safety.mqh` (NEW FILE)  
**Priority:** MEDIUM (depends on Task 1.2)

**Functions to Implement:**

```cpp
//--- Heat Calculation
double CalcBasketHeat(const int basketIndex);
double CalcTotalHeat();
double CalcRecoveryHeat();

//--- Safety Checks
bool   CheckHeatLimits();
bool   IsSpreadAcceptable();
bool   IsMarginSafe();
bool   IsConnectionStable();

//--- Safety Actions
void   HaltTrading();
void   ResumeTrading();
bool   IsTradingHalted();

//--- Limits
bool   IsMaxBasketsReached();
bool   IsMaxLotsReached();
bool   IsMaxDrawdownReached();
```

**Acceptance Criteria:**
- [ ] Heat > 5% recovery → halt new recovery levels
- [ ] Heat > 10% total → halt ALL new baskets
- [ ] Spread > 100 points → halt trading
- [ ] Margin < 200% → halt trading
- [ ] Auto-resume when conditions normalize
- [ ] Heat alert logged when warning threshold crossed

**Reference Documents:**
- `SIDEWAY_KILLER_CORE_LOGIC.md §6` — Safety system integration

---

## 9. PHASE 7 TASKS: INTEGRATION

### Task 7.1: Wire All Modules into Main EA

**File:** `SideWayKiller.mq5`  
**Priority:** CRITICAL (final deliverable)

**Integration Points:**

```cpp
// OnTick() — Hot Path Priority Order:
1. FastStrikeCheck()           // Priority 1: Profit First
2. UpdateAllVirtualTrailings() // Priority 2: Protection
3. CheckGridLevels(bid, ask)   // Priority 3: Recovery

// OnTimer() — Cold Path (every 1 second):
1. SSoT_RefreshCacheFromGlobals()
2. SSoT_ValidateCacheConsistency()  // every 10s
3. Adoption_ProcessUserCommands()
4. Adoption_UpdateMarketState()
5. Adoption_ExecuteScan()
6. UpdateCheckpointSystem()
7. ManageEmergencyStops()
8. SSoT_SyncDashboardToGlobals()
9. CheckHeatLimits()

// OnInit():
1. EventSetTimer(1)
2. SSoT_Init()
3. LoadAllCheckpoints()
4. LoadTradeStats()
5. InitializeBayesianPriors()

// OnDeinit():
1. SetEmergencyStop() for all active baskets
2. SSoT_SaveAllBaskets()
3. SSoT_SaveTradeStats()
4. SSoT_SaveGlobalState()
5. EventKillTimer()

// OnTrade():
1. SSoT_RefreshCacheFromGlobals()
```

### Task 7.2: Implement Dashboard

**File:** `Modules/SK_Dashboard.mqh` (NEW FILE)  
**Priority:** MEDIUM

**Functions:**
```cpp
void UpdateDashboard();
void DrawDashboard();
void ClearDashboard();
```

**Requirements:**
- Top-right corner display
- Real-time: Bid/Ask, Active Baskets, Heat %, Floating P&L
- Updated via `SSoT_SyncDashboardToGlobals()` (cold path)
- Zero impact on hot path

### Task 7.3: Create Configuration Presets

**File:** `SideWayKiller.mq5` (input parameters)  
**Priority:** LOW

**Presets to Implement:**
```cpp
// Preset: Aggressive
// Preset: Balanced (default)
// Preset: Conservative
```

Use `#property parameter_set_name` or comment-based preset blocks.

---

## 10. PERFORMANCE VALIDATION CHECKLIST

Before declaring ANY task complete, verify:

### Hot Path Profiling
- [ ] Run EA with `GetMicrosecondCount()` wrapper around `OnTick()`
- [ ] Log max/average latency every 60 seconds
- [ ] Target: < 1ms average, < 5ms worst case

### Function-Level Profiling
- [ ] `FastStrikeCheck()` < 0.10ms
- [ ] `UpdateVirtualTrailing()` per basket < 0.1ms
- [ ] `CheckGridLevels()` per basket < 0.5ms

### SSoT Validation
- [ ] Terminal restart → baskets restored correctly
- [ ] Cache consistency check → 0 mismatches after 1 hour
- [ ] GV write-through → verified by external GV read

### Safety Validation
- [ ] Heat limit → trading halts correctly
- [ ] Emergency stop → activates on `OnDeinit()`
- [ ] Checkpoint restore → trailing state recovered

---

## 📊 TASK ASSIGNMENT SUMMARY

| Task | File | Priority | Estimated Hours | Dependencies |
|------|------|----------|-----------------|--------------|
| 1.1 SSoT Core | `SK_SSoT.mqh` | CRITICAL | 8-12 | None |
| 1.2 Utilities | `SK_Utils.mqh` | CRITICAL | 4-6 | None |
| 2.1 Adoption | `SK_Adoption.mqh` | HIGH | 6-10 | 1.1, 1.2 |
| 3.1 Grid Spacing | `SK_Grid.mqh` | HIGH | 6-8 | 1.1, 1.2 |
| 3.2 Lot Multiplier | `SK_LotMultiplier.mqh` | HIGH | 4-6 | 1.1, 1.2 |
| 4.1 Fast-Strike | `SK_FastStrike.mqh` | CRITICAL | 6-8 | 1.1, 1.2 |
| 5.1 Trailing Stop | `SK_TrailingStop.mqh` | HIGH | 6-8 | 1.1, 1.2 |
| 6.1 Heat/Safety | `SK_Safety.mqh` | MEDIUM | 3-4 | 1.2 |
| 7.1 Integration | `SideWayKiller.mq5` | CRITICAL | 4-6 | ALL |
| 7.2 Dashboard | `SK_Dashboard.mqh` | MEDIUM | 2-3 | 1.1 |
| 7.3 Presets | `SideWayKiller.mq5` | LOW | 1-2 | 7.1 |
| **TOTAL** | | | **50-73 hours** | |

---

## 🚀 RECOMMENDED IMPLEMENTATION ORDER

**Sprint 1 (Foundation):**
1. Task 1.1 — SSoT Core
2. Task 1.2 — Utilities

**Sprint 2 (Core Logic):**
3. Task 2.1 — Adoption
4. Task 3.1 — Grid Spacing
5. Task 3.2 — Lot Multiplier

**Sprint 3 (Execution & Protection):**
6. Task 4.1 — Fast-Strike
7. Task 5.1 — Trailing Stop

**Sprint 4 (Safety & Integration):**
8. Task 6.1 — Heat/Safety
9. Task 7.1 — Integration
10. Task 7.2 — Dashboard
11. Task 7.3 — Presets

---

**QWEN-Coder: Begin with Task 1.1. Report back when SSoT Core is ready for KIMI-K2 review.**
