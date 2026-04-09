# Round 2: Rebuttals & Cross-Examination

---

### 🔵 Sonnet Rebuts Gemini

**Gemini's Claim:** *"SSoT is mandatory... Performance optimizations are implementation details."*

**Sonnet's Rebuttal:**

Gemini, you're treating "Profit First" as a suggestion rather than the **Priority Directive** stated in AGENTS.md line 54-55:

> "The team is officially instructed that the Profit-Taking System is the most critical component."

Let me demonstrate why pure SSoT **violates** this directive:

**Scenario: Market Spike Event**
```
Time 00:00.000: XAUUSD at 2050.00, Basket WA = 2045.00
Time 00:00.001: Price spikes to 2051.50 (Target Hit!)
Time 00:00.002: OnTick fires - needs to check profit
Time 00:00.003: GlobalVariableCheck("Basket_1_WA") called... waiting...
Time 00:00.008: Returns 2045.00 (5ms latency)
Time 00:00.009: Calculate: 2051.50 - 2045.00 = 6.50 points = $32 profit
Time 00:00.010: Above target! Execute close...
Time 00:00.011: But price already dropped to 2050.80
Time 00:00.012: Actual profit now: $8.40 (Profit Reversal!)
```

**Critical Question for Gemini:** If the Fast-Strike requirement states "orders close the millisecond a target is hit," how does adding 5-15ms of GV overhead to the hot path not violate the core business requirement?

---

### 🟣 Gemini Rebuts Sonnet

**Sonnet's Claim:** *"Hot path must be in-memory... Pure SSoT adds unacceptable latency."*

**Gemini's Rebuttal:**

Sonnet, you're attacking a straw man. The SSoT architecture doesn't require reading GVs on every tick. You're conflating **source of truth** with **access pattern**.

**The Distinction You're Missing:**

```
SOURCE OF TRUTH (What data is authoritative)
    ↓
Not the same as
    ↓
ACCESS PATTERN (How data is read/written)
```

The SIDEWAY_KILLER_CORE_LOGIC.md specifies a **Dual-Path Architecture** (Section 2.4):
- **Hot Path**: Fast math-based check every tick
- **Cold Path**: Full refresh and verification every 1 second

This **already accounts for your performance concern**! The Hot Path can use cached/mirrored data because it's only an *approximation* for rapid filtering. The Cold Path verifies against SSoT.

**Critical Question for Sonnet:** If the logic already specifies dual-path execution, why are you presenting "pure SSoT" as the only option? The business logic anticipates your concern and provides the solution.

---

### 🟡 Codex Rebuts Claude

**Claude's Claim:** *"SSoT for persistence, memory for hot path - hybrid approach."*

**Codex's Rebuttal:**

Claude, your "nuanced hybrid" sounds good but creates a **synchronization nightmare** in practice:

**The Cache Coherency Problem:**
```mql5
// Thread 1: OnTick - Reading from cache
double wa = basketCache[0].weightedAverage;  // 2045.00
double profit = (currentPrice - wa) * volume;

// Thread 2: OnTimer - Syncing from GVs (triggered mid-calculation!)
basketCache[0].weightedAverage = GlobalVariableCheck("Basket_1_WA");  // 2047.00

// Back to Thread 1: Using stale value
// But wait - should we have used 2045.00 or 2047.00?
// What if the sync happened BETWEEN the price check and profit calc?
```

**Real-World Race Conditions I've Seen:**
1. **Torn Reads**: Timer updates cache while OnTick is iterating → crash
2. **Stale Decisions**: Cache shows "not at target" but SSoT shows "at target" → missed close
3. **Double Grid Add**: Two threads both think "last level was 2 steps ago" → add twice

**Critical Question for Claude:** MQL5 doesn't have true multi-threading - it uses event handling. How do you prevent cache corruption when OnTick, OnTimer, and OnTrade events can fire in any sequence?

---

### 🟢 Claude Rebuts Codex

**Codex's Claim:** *"Cache coherency nightmare... Race conditions in MQL5."*

**Claude's Rebuttal:**

Codex, you're absolutely right about the risks, but the solution is **architectural discipline**, not abandoning the cache:

**The Immutable Cache Pattern:**
```mql5
// WRONG: Mutable cache with race conditions
struct BasketCache {
    double weightedAverage;  // Updated by timer
    double totalVolume;      // Updated by timer
};

// RIGHT: Immutable snapshots
struct BasketSnapshot {
    double weightedAverage;
    double totalVolume;
    datetime snapshotTime;
};

BasketSnapshot currentSnapshot;

// OnTick: Never modifies snapshot
void OnTick() {
    double profit = CalculateProfit(currentSnapshot);
    // Snapshot is read-only here - no race possible
}

// OnTimer: Atomically replaces snapshot
void OnTimer() {
    BasketSnapshot newSnapshot = LoadFromGlobals();
    currentSnapshot = newSnapshot;  // Single atomic assignment
}
```

**Why This Works:**
1. OnTick only **reads** snapshot - no modification, no race
2. OnTimer **replaces** entire snapshot - atomic operation
3. Between updates, OnTick works with **consistent but slightly stale** data
4. The "slightly stale" data is acceptable because:
   - Fast-Strike uses approximation anyway (Section 2.3)
   - Cold path corrects any drift within 1 second

**Critical Question for Codex:** Given that the core logic explicitly allows approximate profit calculations for the Fast-Strike trigger, why is "slightly stale cache data" a problem if it's refreshed every second?

---

## 📊 ROUND 2: Key Tensions Identified

| Tension | Pro-SSoT View | Performance View |
|---------|---------------|------------------|
| **Authority** | GV is always source of truth | Memory is faster access |
| **Latency** | Acceptable for persistence | Unacceptable for hot path |
| **Consistency** | All readers see same data | Cache may be stale |
| **Complexity** | Simple, single data source | Cache sync adds complexity |

---

**Round 2 Complete. Proceeding to Round 3: Synthesis Attempts...**
