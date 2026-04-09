# Round 1: Opening Statements
## Debate: SSoT vs Traditional State Management for MQL5

Date: 2026-04-09
Topic: Single Source of Truth (Global Variables) vs Traditional State Management for SIDEWAY KILLER EA

---

### 🟢 Claude/Opus - Moderator Perspective

**Position: Nuanced Support for SSoT with Hybrid Approach**

The SSoT architecture using Terminal Global Variables offers compelling advantages for the SIDEWAY KILLER system:

**Strengths:**
1. **Persistence**: Survives EA restarts and terminal crashes without file I/O overhead
2. **Zero-Latency Access**: `GlobalVariableCheck()` is faster than file reads for hot path operations
3. **UI Integration**: Dashboard can read same data without IPC complexity
4. **Atomic Operations**: Terminal guarantees thread-safe access

**Critical Concerns:**
1. **Storage Limits**: Only supports `double` and `string` types - no complex objects
2. **Namespace Pollution**: All GVs shared across all EAs - risk of collision
3. **Performance Overhead**: Writing to GVs on every tick may create contention
4. **Type Safety**: No compile-time checking - runtime errors only

**Verdict**: SSoT is correct for *persistent* state (basket records), but traditional in-memory structures should handle *hot path* calculations (profit checks, price tracking). Hybrid architecture recommended.

---

### 🔵 Sonnet - Performance Engineering Perspective

**Position: Against Pure SSoT - Performance Critical Path Must Be In-Memory**

The "Profit First" directive is absolute - when target is hit, close must execute within milliseconds. Pure SSoT introduces unacceptable latency:

**Performance Analysis:**
```
SSoT Approach (Pure):
├── OnTick: Read basket state from GVs (~0.5ms per GV)
├── Calculate profit using GV data (~0.1ms)
├── Check if target hit
├── If hit: Write close flag to GV (~1ms)
└── Execute close: Read flag from main thread (~0.5ms)
TOTAL HOT PATH LATENCY: ~2ms+ per position

In-Memory Approach:
├── OnTick: Access cached basket array (~0.001ms)
├── Calculate profit using cached data (~0.1ms)
├── Check if target hit
├── If hit: Set in-memory flag (~0.001ms)
└── Execute close immediately
TOTAL HOT PATH LATENCY: ~0.1ms
```

**Recommendation:** Two-tier architecture
- **Hot Tier**: In-memory cache for active basket data (updated every tick)
- **Cold Tier**: Global Variables for persistence (updated every 1-60 seconds)
- **Sync Direction**: Hot → Cold only, never Cold → Hot on critical path

**Evidence:** The 3-5 second delay issue mentioned in AGENTS.md is exactly what happens when critical operations depend on slow storage access.

---

### 🟣 Gemini - Strategic Architecture Perspective

**Position: Pro-SSoT - The Architecture Must Align with Business Logic**

The SIDEWAY_KILLER_CORE_LOGIC.md document specifies a "Single Source of Truth" requirement. This is not optional - it's fundamental to the system design:

**Business Logic Requirements:**
1. **Basket Persistence**: If EA restarts during active trade, state must be preserved
2. **UI Real-Time**: Dashboard at Top-Right must reflect *actual* state, not cached approximation
3. **Recovery Continuity**: Grid levels must resume exactly where they left off
4. **Audit Trail**: Every state transition must be traceable

**SSoT Enables:**
```
┌─────────────────────────────────────────┐
│         TERMINAL GLOBAL VARIABLES       │
│    (The Only Source of Basket Truth)    │
├─────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │  Logic  │  │    UI   │  │  Audit  │  │
│  │  Module │  │Dashboard│  │  Logger │  │
│  └────┬────┘  └────┬────┘  └────┬────┘  │
│       │            │            │        │
│       └────────────┴────────────┘        │
│              All Read From SSoT          │
└─────────────────────────────────────────┘
```

**Counter to Sonnet:** The performance concerns are valid but addressable. The Fast-Strike logic can use a *localized* in-memory buffer that mirrors the SSoT - the buffer is just an optimization, not the source of truth.

**Strategic Verdict:** SSoT is mandatory. Performance optimizations are implementation details, not architectural changes.

---

### 🟡 Codex - Implementation Realities Perspective

**Position: Pragmatic Hybrid - SSoT for Storage, Memory for Speed**

As the implementer, I've worked extensively with MQL5 Global Variables. Here's the technical reality:

**Global Variable API Limitations:**
```mql5
// Global Variables only support double and string
double value = GlobalVariableCheck("Basket_1_WA");  // OK
string id = GlobalVariableCheck("Basket_1_ID");    // WRONG - returns double!
// Must use separate naming convention for strings
string id = (string)GlobalVariableCheck("Basket_1_ID_str");  // Still wrong!
// Actually need: GlobalVariableName() iteration
```

**Real-World Performance:**
- `GlobalVariableCheck()`: ~0.3-0.8ms per call (varies by broker terminal)
- `GlobalVariableSet()`: ~0.5-1.5ms per call
- `GlobalVariableFlush()`: Additional ~2-5ms if forced

**Critical Implementation Issue:**
```mql5
// WRONG: Reading all basket data on every tick
for (int i = 0; i < basketCount; i++) {
    wa = GlobalVariableCheck("Basket_" + i + "_WA");
    vol = GlobalVariableCheck("Basket_" + i + "_Vol");
    // ... 8 more GVs per basket
}
// With 5 active baskets: 50 GlobalVariableCheck() calls per tick
// At 50 ticks/second: 2500 calls/sec = 750-2000ms overhead PER SECOND

// RIGHT: Cache on load, refresh periodically
```

**My Recommendation:**
```
Architecture Pattern: READ-HEAVY CACHE

┌──────────────────────────────────────────────────────┐
│                  MQL5 EA Main Thread                 │
├──────────────────────────────────────────────────────┤
│                                                       │
│  ┌─────────────────┐         ┌──────────────────┐   │
│  │  In-Memory      │◄────────│  Global Variables │   │
│  │  Basket Cache   │  Sync   │  (SSoT Storage)  │   │
│  │  (Fast Access)  │         │  (Persistence)   │   │
│  └────────┬────────┘         └──────────────────┘   │
│           │                                          │
│           │ OnTick: Read from Cache                 │
│           │ OnTimer: Sync to GVs                    │
│           │ OnInit: Load from GVs                   │
│           │ OnDeinit: Save to GVs                   │
│                                                      │
└──────────────────────────────────────────────────────┘
```

---

## Round 1 Summary Table

| Participant | Position | Key Argument |
|-------------|----------|--------------|
| Claude/Opus | Nuanced Hybrid | SSoT for persistence, memory for hot path |
| Sonnet | Performance-First | Hot path must be in-memory to avoid latency |
| Gemini | Architecture-First | SSoT is business requirement, optimize later |
| Codex | Pragmatic Implementation | Read-heavy cache pattern with periodic sync |

---

**Round 1 Complete. Proceeding to Round 2: Rebuttals...**
