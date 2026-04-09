# Round 4: Final Positions & Scoring

---

### 🟢 Claude/Opus - Final Position

**Verdict: SUPPORT Hybrid SSoT Architecture**

**Confidence Score: 9.2/10**

After thorough debate, the hybrid architecture (SSoT for persistence + cache for hot path) is clearly the correct approach for SIDEWAY KILLER.

**Key Reasons:**

1. **Business Logic Alignment:** The dual-path architecture specified in Section 2.4 explicitly anticipates this pattern. We're not inventing something new - we're implementing what was already designed.

2. **Performance Requirement Satisfied:** Hot path uses cache (~0.1ms) not GVs (~8ms), achieving the "millisecond" execution requirement for Profit First.

3. **Persistence Requirement Satisfied:** SSoT in GVs ensures state survives EA restarts and is accessible to UI dashboard.

4. **Implementation Complexity Managed:** Clear separation between hot/cold paths prevents race conditions that Codex warned about.

**Concerns Addressed:**
- Sonnet's latency concerns → Cache eliminates hot-path GV access
- Gemini's architectural concerns → SSoT remains authoritative
- Codex's implementation concerns → Immutable snapshot pattern prevents races

**Recommendation:** Proceed with hybrid architecture as specified in synthesis.

---

### 🔵 Sonnet - Final Position

**Verdict: SUPPORT Hybrid with Strong Cache Priority**

**Confidence Score: 8.5/10**

I reluctantly support the hybrid approach, but with **strong emphasis on cache performance**.

**My Condition:**

The cache must be **truly read-only on hot path**. Any code that looks like this is unacceptable:

```mql5
// UNACCEPTABLE - Hot path touches GV
void OnTick() {
    if (NeedRefresh()) {
        RefreshFromGlobals();  // WRONG! Blocks hot path
    }
    // ...
}
```

**Acceptable Pattern:**
```mql5
// ACCEPTABLE - Hot path is pure read
void OnTick() {
    double profit = CalculateProfitFromCache();  // Fast
    if (profit >= target) {
        CloseImmediate();  // Even faster
    }
    // NEVER touches GVs
}

void OnTimer() {
    RefreshFromGlobals();  // Separate thread/event
}
```

**Performance Validation Required:**
Before deployment, we MUST benchmark:
- OnTick execution time: < 1ms (target: 0.1-0.5ms)
- OnTimer sync time: < 50ms (acceptable, not on hot path)
- Memory overhead: < 10MB (negligible)

If OnTick exceeds 1ms, the architecture has failed the "Profit First" directive.

---

### 🟣 Gemini - Final Position

**Verdict: FULLY SUPPORT Hybrid as SSoT-Compliant**

**Confidence Score: 9.8/10**

The hybrid architecture IS a Single Source of Truth architecture. The cache is merely an **access optimization**, not an alternative source.

**Critical Distinction:**

```
WRONG: "Cache + SSoT = Two sources of truth"
RIGHT: "Cache + SSoT = One truth (GV) + fast access (cache)"
```

**Evidence from Business Logic:**

The core logic document specifies this exact pattern in multiple places:
- Section 2.3: "Approximate Profit USD" for fast checks
- Section 2.4: "Hot Path vs Cold Path" dual architecture
- Section 4.1: "Global Variables to ensure persistence"

The cache exists to implement the "approximate" fast check. The SSoT exists to implement the "persistent" storage requirement. They are complementary, not contradictory.

**Final Validation:**

```
Question: "If EA restarts, what is the source of truth?"
Answer: "Global Variables" ✓

Question: "If UI needs current basket data, what does it read?"
Answer: "Global Variables" ✓

Question: "On every tick, what data does Fast-Strike use?"
Answer: "Cached data derived from GVs" ✓

Question: "Every 1 second, what refreshes the cache?"
Answer: "Global Variables" ✓
```

All answers point to GVs as SSoT. The cache is just an optimization layer.

---

### 🟡 Codex - Final Position

**Verdict: SUPPORT Hybrid with Implementation Safeguards**

**Confidence Score: 9.0/10**

As the implementer, I'm confident this architecture will work. But I need specific safeguards:

**Required Safeguards:**

1. **Namespace Convention:**
   ```mql5
   string PREFIX = "SK_";  // Sideway Killer
   // All GVs must use this prefix
   ```

2. **Initialization Gate:**
   ```mql5
   int OnInit() {
       if (!LoadFromGlobals()) {
           Alert("Failed to load from GVs");
           return INIT_FAILED;
       }
       // Wait for first sync before trading
       g_readyToTrade = false;
       return INIT_SUCCEEDED;
   }
   ```

3. **Validation Alerts:**
   ```mql5
   if (DetectCacheMismatch()) {
       Alert("WARNING: Cache mismatch detected!");
       Print("Basket ID: ", basketId);
       Print("Cache WA: ", cacheWA);
       Print("GV WA: ", gvWA);
       ForceResync();
   }
   ```

4. **Deinitialization Safety:**
   ```mql5
   void OnDeinit(const int reason) {
       // Save final state before exit
       SaveToGlobals();
       // Optionally: Clear GVs if clean shutdown
       if (reason == REASON_REMOVE) {
           ClearAllBasketGVs();
       }
   }
   ```

**Implementation Priority:**
1. Phase 1: Core data structures (Basket, Cache)
2. Phase 2: GV read/write functions
3. Phase 3: Hot path (OnTick) - PURE CACHE
4. Phase 4: Cold path (OnTimer) - Sync with GVs
5. Phase 5: Validation and error handling

**Estimated Effort:** 4-6 hours for core architecture

---

## 📊 FINAL SCORING MATRIX

| Criterion | Claude | Sonnet | Gemini | Codex |
|-----------|--------|--------|--------|-------|
| **Business Logic Alignment** | 9/10 | 7/10 | 10/10 | 9/10 |
| **Performance Viability** | 9/10 | 10/10 | 8/10 | 9/10 |
| **Implementation Feasibility** | 8/10 | 8/10 | 7/10 | 10/10 |
| **Risk Assessment** | 9/10 | 8/10 | 9/10 | 9/10 |
| **Argument Quality** | 9/10 | 9/10 | 10/10 | 9/10 |
| **TOTAL SCORE** | **44/50** | **42/50** | **44/50** | **46/50** |

### 🏆 Winner: Codex (Pragmatic Implementation)

**Reasoning:** Codex provided the most concrete implementation guidance, identified real-world MQL5 limitations, and proposed actionable safeguards. While Gemini had the strongest theoretical argument, Codex's approach is what will actually work in production.

---

## 📋 FINAL RECOMMENDATION

### Approved Architecture: Hybrid SSoT with Hot/Cold Path Split

**Specification:**

```
┌─────────────────────────────────────────────────────────────┐
│                    SIDEWAY KILLER ARCHITECTURE              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  LAYER 1: SINGLE SOURCE OF TRUTH                     │   │
│  │  - Terminal Global Variables                         │   │
│  │  - Namespace: "SK_<BasketID>_<Field>"                │   │
│  │  - Purpose: Persistence, Authority, UI Access        │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                      │
│  ┌────────────────────▼────────────────────────────────┐   │
│  │  LAYER 2: IN-MEMORY CACHE (Working Copy)            │   │
│  │  - Immutable snapshots                              │   │
│  │  - Read-only on hot path                            │   │
│  │  - Updated by cold path                             │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                      │
│       ┌───────────────┴───────────────┐                     │
│       │                               │                     │
│  ┌────▼──────┐                  ┌────▼──────┐              │
│  │ HOT PATH  │                  │ COLD PATH │              │
│  │ OnTick    │                  │ OnTimer   │              │
│  │           │                  │           │              │
│  │ Read Cache│                  │ Sync GVs  │              │
│  │ + Price   │                  │ Refresh   │              │
│  │           │                  │ Validate  │              │
│  │ < 1ms     │                  │ < 50ms    │              │
│  └───────────┘                  └───────────┘              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Implementation Checklist:**

- [ ] Define GV namespace and field structure
- [ ] Create BasketCache struct with immutable snapshot pattern
- [ ] Implement LoadFromGlobals() for OnInit
- [ ] Implement OnTick with cache-only access
- [ ] Implement OnTimer sync (1 second interval)
- [ ] Add validation checks (every 10 seconds)
- [ ] Add namespace collision prevention
- [ ] Add deinitialization safety
- [ ] Benchmark hot path performance (< 1ms target)
- [ ] Test with restart scenarios

---

**Debate Complete. See final synthesis document for implementation guide.**
