# SIDEWAY KILLER — Global Variable Data Mapping Schema

**Document Version:** 1.0.0  
**Phase:** 1 — Foundation Layer  
**Architect:** KIMI-K2  
**Date:** 2026-04-09

---

## 1. OVERVIEW

This document defines the complete **Single Source of Truth (SSoT)** mapping between in-memory cache structures and Terminal Global Variables (GVs). All critical state is persisted to GVs to ensure:

- **Survival across EA restarts**
- **Shared state with UI dashboard**
- **Audit trail and recovery capability**

The architecture follows the **Hybrid SSoT** model:
- **GV Layer:** Authoritative persistence (write-through on all state changes)
- **Cache Layer:** In-memory working copy for <1ms hot-path reads

---

## 2. NAMING CONVENTION

All GV names follow strict, collision-proof patterns:

| Category | Pattern | Example |
|----------|---------|---------|
| Basket Fields | `SK_B<NNN>_<FIELD>` | `SK_B001_WA` |
| Level Fields | `SK_B<NNN>_L<LL>_<FIELD>` | `SK_B001_L01_TIX` |
| Trailing Checkpoint | `SK_T<NNN>_<FIELD>` | `SK_T001_PEAK` |
| Trade Statistics | `SK_STATS_<FIELD>` | `SK_STATS_TOT` |
| Global State | `SK_STATE_<FIELD>` | `SK_STATE_NEXT` |
| Dashboard | `SK_DASH_<FIELD>` | `SK_DASH_PNL` |

**Format rules:**
- `<NNN>` = 3-digit zero-padded basket ID (000–019)
- `<LL>` = 2-digit zero-padded level index (00–06)
- `<FIELD>` = 3–5 character uppercase suffix

---

## 3. BASKET DATA FIELDS

Each active basket stores **9 core fields** in GVs.

| GV Suffix | Field Name | Data Type | Description |
|-----------|------------|-----------|-------------|
| `_WA` | Weighted Average | `double` | Volume-weighted average open price |
| `_VOL` | Total Volume | `double` | Sum of all lot sizes in basket |
| `_TGT` | Profit Target | `double` | Target USD profit for closure |
| `_STS` | Status | `double` | 0=Active, 1=Closing, 2=Closed |
| `_LVL` | Level Count | `double` | Number of grid levels (1..7) |
| `_DIR` | Direction | `double` | 0=BUY, 1=SELL |
| `_CRT` | Created | `double` | Creation timestamp (datetime as double) |
| `_MGC` | Magic Number | `double` | Original position magic |
| `_TK0` | Original Ticket | `double` | Level 0 position ticket |

**Example GV names for Basket #1:**
```
SK_B001_WA   → Weighted Average Price
SK_B001_VOL  → Total Volume
SK_B001_TGT  → Profit Target USD
SK_B001_STS  → Status
SK_B001_LVL  → Level Count
SK_B001_DIR  → Direction
SK_B001_CRT  → Creation Time
SK_B001_MGC  → Magic Number
SK_B001_TK0  → Original Ticket
```

---

## 4. PER-LEVEL DATA FIELDS

Each basket can have up to `SK_MAX_LEVELS` (7) positions. Each level stores **4 fields**.

| GV Suffix | Field Name | Data Type | Description |
|-----------|------------|-----------|-------------|
| `_TIX` | Ticket | `double` | Position ticket number |
| `_LOT` | Lot Size | `double` | Volume for this level |
| `_PRC` | Open Price | `double` | Entry price |
| `_TIM` | Open Time | `double` | Entry timestamp |

**Example GV names for Basket #1, Level #2:**
```
SK_B001_L02_TIX  → Ticket
SK_B001_L02_LOT  → Lot Size
SK_B001_L02_PRC  → Open Price
SK_B001_L02_TIM  → Open Time
```

**Total per-level GVs:** 4 fields × 7 levels = **28 GVs per basket**

---

## 5. VIRTUAL TRAILING CHECKPOINT FIELDS

Each basket has a trailing stop checkpoint stored for restart recovery.

| GV Suffix | Field Name | Data Type | Description |
|-----------|------------|-----------|-------------|
| `_PEAK` | Peak Price | `double` | Highest (BUY) / Lowest (SELL) price seen |
| `_STOP` | Stop Level | `double` | Current virtual stop price |
| `_ACT` | Activated | `double` | 0=Inactive, 1=Active |
| `_TIME` | Checkpoint Time | `double` | Last save timestamp |

**Example GV names for Basket #1:**
```
SK_T001_PEAK  → Peak Price
SK_T001_STOP  → Virtual Stop Level
SK_T001_ACT   → Activated Flag
SK_T001_TIME  → Last Checkpoint Time
```

---

## 6. TRADE STATISTICS FIELDS

Global trade statistics for Bayesian Kelly and performance tracking.

| GV Suffix | Field Name | Data Type | Description |
|-----------|------------|-----------|-------------|
| `_VER` | Schema Version | `double` | GV schema version number |
| `_TOT` | Total Trades | `double` | Cumulative closed basket count |
| `_WIN` | Wins | `double` | Winning basket count |
| `_LOS` | Losses | `double` | Losing basket count |
| `_WAMT` | Win Amount | `double` | Cumulative profit from wins |
| `_LAMT` | Loss Amount | `double` | Cumulative loss from losses |
| `_ALPHA` | Bayesian Alpha | `double` | Prior wins + actual wins |
| `_BETA` | Bayesian Beta | `double` | Prior losses + actual losses |
| `_LUP` | Last Update | `double` | Last stats update timestamp |

**Full GV names:**
```
SK_STATS_VER   → Schema Version
SK_STATS_TOT   → Total Trades
SK_STATS_WIN   → Wins
SK_STATS_LOS   → Losses
SK_STATS_WAMT  → Win Amount
SK_STATS_LAMT  → Loss Amount
SK_STATS_ALPHA → Bayesian Alpha
SK_STATS_BETA  → Bayesian Beta
SK_STATS_LUP   → Last Update
```

---

## 7. GLOBAL STATE FIELDS

System-wide state variables.

| GV Suffix | Field Name | Data Type | Description |
|-----------|------------|-----------|-------------|
| `_BCNT` | Basket Count | `double` | Number of active baskets |
| `_NEXT` | Next Basket ID | `double` | Next available basket ID counter |
| `_INIT` | Init Time | `double` | Last EA initialization timestamp |
| `_HEAT` | Current Heat | `double` | Current heat percentage |

**Full GV names:**
```
SK_STATE_BCNT  → Active Basket Count
SK_STATE_NEXT  → Next Basket ID
SK_STATE_INIT  → Init Timestamp
SK_STATE_HEAT  → Current Heat %
```

---

## 8. DASHBOARD FIELDS

Real-time metrics written for external dashboard/UI access.

| GV Suffix | Field Name | Data Type | Description |
|-----------|------------|-----------|-------------|
| `_BID` | Bid Price | `double` | Current symbol bid |
| `_ASK` | Ask Price | `double` | Current symbol ask |
| `_HEAT` | Heat % | `double` | Current account heat |
| `_PNL` | Floating P&L | `double` | Total unrealized P&L |
| `_CNT` | Basket Count | `double` | Active baskets |
| `_CID` | Closest Basket ID | `double` | ID of basket nearest to target |
| `_CPRG` | Closest Progress | `double` | Progress % of closest basket |
| `_UPD` | Last Update | `double` | Dashboard update timestamp |

**Full GV names:**
```
SK_DASH_BID   → Current Bid
SK_DASH_ASK   → Current Ask
SK_DASH_HEAT  → Heat %
SK_DASH_PNL   → Floating P&L
SK_DASH_CNT   → Active Basket Count
SK_DASH_CID   → Closest Basket ID
SK_DASH_CPRG  → Closest Basket Progress
SK_DASH_UPD   → Last Dashboard Update
```

---

## 9. GV COUNT SUMMARY

| Category | Fields per Unit | Max Units | Total GVs |
|----------|-----------------|-----------|-----------|
| Basket Core | 9 | 20 | 180 |
| Basket Levels | 28 | 20 | 560 |
| Trailing Checkpoints | 4 | 20 | 80 |
| Trade Statistics | 9 | 1 | 9 |
| Global State | 4 | 1 | 4 |
| Dashboard | 8 | 1 | **8** |
| **TOTAL** | — | — | **841** |

> **Note:** 841 GVs is well within MetaTrader 5's generous limits (typically 65,536+).

---

## 10. DATA FLOW DIAGRAM

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    SIDEWAY KILLER — HYBRID SSoT                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  PERSISTENCE LAYER — Terminal Global Variables (SSoT)           │   │
│  │  ┌─────────────────────────────────────────────────────────┐   │   │
│  │  │ • 841 GVs total across 6 namespaces                      │   │   │
│  │  │ • Write-through on every state change                    │   │   │
│  │  │ • Survives restarts, accessible to UI                    │   │   │
│  │  └─────────────────────────────────────────────────────────┘   │   │
│  └────────────────────────┬────────────────────────────────────────┘   │
│                           │ Write-through (state changes)              │
│                           │ Periodic Sync (OnTimer, every 1s)          │
│                           ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  CACHE LAYER — In-Memory Working Copy                           │   │
│  │  ┌─────────────────────────────────────────────────────────┐   │   │
│  │  │ BasketCache  g_baskets[20]   ← Read-only on Hot Path   │   │   │
│  │  │ MarketState  g_market        ← Updated via OnTimer     │   │   │
│  │  │ SpreadStats  g_spreadStats   ← Updated via OnTimer     │   │   │
│  │  └─────────────────────────────────────────────────────────┘   │   │
│  └────────────────────────┬────────────────────────────────────────┘   │
│                           │                                            │
│          ┌────────────────┴────────────────┐                           │
│          ▼                                 ▼                           │
│  ┌───────────────┐              ┌───────────────────┐                  │
│  │   HOT PATH    │              │    COLD PATH      │                  │
│  │   OnTick()    │              │    OnTimer()      │                  │
│  │               │              │                   │                  │
│  │ • Read Cache  │              │ • Sync GVs        │                  │
│  │ • Live Price  │              │ • Refresh Cache   │                  │
│  │ • Calc Profit │              │ • Validate        │                  │
│  │ • Close       │              │ • Log diffs       │                  │
│  │               │              │                   │                  │
│  │ Target: <1ms  │              │ Target: <50ms     │                  │
│  └───────────────┘              └───────────────────┘                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 11. WRITE PATTERNS

### 11.1 Write-Through (Immediate)
Triggered on every state-changing event:

| Event | GVs Updated | Cache Updated |
|-------|-------------|---------------|
| New basket created | Basket core (9 GVs) + Level 0 (4 GVs) + State | Full entry |
| Grid level added | Basket core (3 GVs: WA, VOL, LVL) + New level (4 GVs) | Recalculated fields |
| Basket status change | `_STS` GV | `status` field |
| Basket closed | `_STS` → 2, Global stats (9 GVs), Dashboard | Mark invalid |
| Trade stats update | `SK_STATS_*` (9 GVs) | Full struct |
| Checkpoint save | `SK_T<id>_*` (4 GVs) | Sync timestamp |

### 11.2 Periodic Sync (Every 1 second)
Triggered by `OnTimer()`:
- Refresh entire cache from GVs
- Spot-check consistency (10-second intervals)
- Update dashboard GVs
- Save checkpoints (adaptive frequency)

### 11.3 Heartbeat Save (Every 30 seconds)
- Full basket state flush to GVs
- Trade statistics save
- Global state save

---

## 12. RECOVERY SEQUENCE

On `OnInit()`:

1. **Load Schema Version** — Verify `SK_STATS_VER` matches expected version
2. **Load Global State** — Restore `SK_STATE_*` to recover next basket ID
3. **Scan for Baskets** — Iterate basket IDs 0..19, check for `SK_B<id>_WA`
4. **Load Active Baskets** — For each found basket, load all core + level fields
5. **Load Trade Stats** — Restore `SK_STATS_*` for Bayesian calculations
6. **Load Checkpoints** — Restore `SK_T<id>_*` for virtual trailing state
7. **Validate Cache** — Cross-check totals, flag inconsistencies
8. **Mark Cache Valid** — Set `g_cacheValid = true`, enable Hot Path

---

## 13. CLEANUP OPERATIONS

### 13.1 Orphaned Record Detection
An orphaned GV is defined as:
- A GV matching the `SK_*` pattern
- Belonging to a basket ID where `SK_B<id>_WA` does not exist
- Or belonging to a closed basket (`SK_B<id>_STS` == 2)

### 13.2 Cleanup Triggers
- After basket closure (immediate)
- During `OnDeinit()` (optional, configurable)
- During version migration

### 13.3 Full Purge
`SSoT_ClearAllGlobals()` removes ALL `SK_*` GVs — used for clean uninstall.

---

## 14. VERSION MIGRATION

If `SK_STATS_VER` does not match `SK_SCHEMA_VERSION`:

1. Log warning: "Schema version mismatch detected"
2. Run `SSoT_PurgeOrphanedRecords()`
3. Attempt backward-compatible load
4. If incompatible: alert user, recommend manual clear

---

## 15. CRITICAL CONSTRAINTS

| Constraint | Rule | Enforcement |
|------------|------|-------------|
| **Hot Path Purity** | NO `GlobalVariable*` calls in `OnTick()` | Code review, static analysis |
| **Write Atomicity** | Basket GVs written as a group | Implementation in `SSoT_WriteBasketToGlobals()` |
| **Namespace Isolation** | Only `SK_*` prefix used | `GV_BasketField()`, `GV_LevelField()` helpers |
| **Cache Immutability** | No cache modification during iteration | Design pattern enforcement |
| **Consistency Window** | Max 1-second drift between GV and Cache | 1-second `OnTimer()` sync |

---

**END OF GV SCHEMA DOCUMENT**

*Next Phase: Phase 2 — Position Adoption System*
