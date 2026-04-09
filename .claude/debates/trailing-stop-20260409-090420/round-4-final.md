# Round 4: Final Positions & Scoring

---

### 🔵 Sonnet - Final Position

**Verdict: THREE-LAYER SYSTEM WITH LIMITED EMERGENCY STOPS**

**Confidence Score: 9.0/10**

I accept that emergency stops are necessary for **extended planned downtime**. However, I maintain strict limits on their use.

**Final Architecture:**

```mql5
// ============================================================
// TRAILING STOP: Three-Layer System
// ============================================================

// LAYER 1: Virtual Trailing (Always)
void OnTick() {
    for (int i = 0; i < g_basketCount; i++) {
        UpdateVirtualTrailing(i);  // <0.1ms, basket-level
    }
}

// LAYER 2: Checkpoint (Adaptive Frequency)
void OnTimer() {
    int interval = GetCheckpointInterval();  // 1-30 seconds based on heat
    static datetime lastSave = 0;

    if (TimeCurrent() - lastSave >= interval) {
        SaveAllCheckpoints();
        lastSave = TimeCurrent();
    }
}

// LAYER 3: Emergency Stops (Strictly Limited)
bool ShouldUseEmergencyStops() {
    // ONLY for:
    if (g_userInitiatedShutdown) return true;  // User wants offline protection
    if (g_maintenancePlanned && g_duration > 3600) return true;  // >1 hour maintenance
    if (g_heat > 0.95) return true;  // Extreme heat only (not 90%)

    return false;
}
```

**My Strict Requirements for Emergency Stops:**

1. **User-Initiated Only:** Automatically disabled unless user explicitly requests
2. **Extreme Heat Only:** >95% heat, not >90%
3. **Extended Downtime Only:** >1 hour maintenance, not shorter
4. **Full Cost Buffer:** 3× spread + commission + swap
5. **Same Price for All:** All positions in basket get SAME stop price

**Why I Can Support This:**

- **Performance preserved:** Virtual trailing does all the work 99%+ of time
- **Basket integrity:** Emergency stops all at same price
- **User control:** Defaults to OFF, user must enable
- **Limited activation:** Only in truly critical scenarios

---

### 🟣 Gemini - Final Position

**Verdict: THREE-LAYER SYSTEM WITH ADAPTIVE ACTIVATION**

**Confidence Score: 9.5/10**

The three-layer system with adaptive activation is the clear winner.

**Final Architecture:**

```mql5
// ============================================================
// TRAILING STOP: Adaptive Three-Layer System
// ============================================================

enum EProtectionLevel {
    PROTECTION_NORMAL,      // Virtual + checkpoint every 30s
    PROTECTION_ELEVATED,    // Virtual + checkpoint every 10s
    PROTECTION_HIGH,         // Virtual + checkpoint every 3s
    PROTECTION_CRITICAL     // All layers active
};

void OnTimer() {
    EProtectionLevel level = DetermineProtectionLevel();

    // Checkpoint frequency adapts to level
    int intervals[] = {30, 10, 3, 1};
    int interval = intervals[level];

    static datetime lastSave = 0;
    if (TimeCurrent() - lastSave >= interval) {
        SaveAllCheckpoints();
        lastSave = TimeCurrent();
    }

    // Emergency stops activate at CRITICAL level
    bool needEmergencyStops = (level == PROTECTION_CRITICAL);
    ManageEmergencyStops(needEmergencyStops);
}

EProtectionLevel DetermineProtectionLevel() {
    double heat = CalculateCurrentHeat();

    // User-initiated shutdown: CRITICAL
    if (g_userInitiatedShutdown) return PROTECTION_CRITICAL;

    // Connection unstable: CRITICAL
    if (!IsConnectionStable()) return PROTECTION_CRITICAL;

    // Maintenance planned: Duration-based
    if (g_maintenancePlanned) {
        if (g_maintenanceDuration > 3600) return PROTECTION_CRITICAL;  // >1 hour
        if (g_maintenanceDuration > 300) return PROTECTION_HIGH;       // >5 min
    }

    // Heat-based thresholds
    if (heat > 0.90) return PROTECTION_CRITICAL;
    if (heat > 0.75) return PROTECTION_HIGH;
    if (heat > 0.60) return PROTECTION_ELEVATED;

    return PROTECTION_NORMAL;
}
```

**Why Adaptive is Better:**

Instead of binary (emergency ON/OFF), the system **gradually escalates** protection:

```
Heat rises from 50% → 65% → 80% → 92%

System response:
50%: Normal (virtual + checkpoint every 30s)
65%: Elevated (virtual + checkpoint every 10s)
80%: High (virtual + checkpoint every 3s)
92%: Critical (virtual + checkpoint every 1s + emergency stops)

Each step is proportional to the threat level.
```

**This Addresses:**
- Sonnet's concern: Emergency stops only at critical (90%+ heat)
- Codex's concern: Automatic escalation based on conditions
- Gemini's concern: Comprehensive adaptive protection

---

### 🟡 Codex - Final Position

**Verdict: THREE-LAYER WITH USER CONFIGURATION**

**Confidence Score: 9.5/10**

As the implementer, I provide **maximum flexibility** with sensible defaults:

**Final Architecture:**

```mql5
// ============================================================
// TRAILING STOP: User-Configurable System
// ============================================================

// USER OPTIONS
enum EEmergencyStopMode {
    EMERGENCY_OFF,           // Never use emergency stops
    EMERGENCY_AUTO,          // Automatic (RECOMMENDED)
    EMERGENCY_MANUAL         // User control only
};

input EEmergencyStopMode EmergencyStopMode = EMERGENCY_AUTO;
input double EmergencyHeatThreshold = 0.90;
input int EmergencyMaintenanceHours = 1;
input double EmergencySpreadMultiplier = 2.5;

// IMPLEMENTATION
void ManageEmergencyStops(int basketIndex) {
    bool activate = false;

    switch (EmergencyStopMode) {
        case EMERGENCY_OFF:
            activate = false;
            break;

        case EMERGENCY_AUTO:
            activate = ShouldAutoActivate();
            break;

        case EMERGENCY_MANUAL:
            activate = g_userEmergencyStopsEnabled;
            break;
    }

    if (activate && !g_hasEmergencyStops[basketIndex]) {
        SetEmergencyStop(basketIndex);
        g_hasEmergencyStops[basketIndex] = true;
    } else if (!activate && g_hasEmergencyStops[basketIndex]) {
        RemoveEmergencyStop(basketIndex);
        g_hasEmergencyStops[basketIndex] = false;
    }
}

bool ShouldAutoActivate() {
    // Heat threshold
    if (CalculateCurrentHeat() > EmergencyHeatThreshold) {
        return true;
    }

    // Maintenance duration
    if (g_maintenancePlanned &&
        g_maintenanceDuration > EmergencyMaintenanceHours * 3600) {
        return true;
    }

    // Connection instability
    if (!IsConnectionStable()) {
        return true;
    }

    // User-initiated
    if (g_userInitiatedShutdown) {
        return true;
    }

    return false;
}
```

**Configuration Presets:**

```mql5
// PRESET: Conservative (Sonnet's preference)
EmergencyStopMode = EMERGENCY_MANUAL
EmergencyHeatThreshold = 0.95
EmergencyMaintenanceHours = 2

// PRESET: Balanced (Recommended)
EmergencyStopMode = EMERGENCY_AUTO
EmergencyHeatThreshold = 0.90
EmergencyMaintenanceHours = 1

// PRESET: Aggressive Protection
EmergencyStopMode = EMERGENCY_AUTO
EmergencyHeatThreshold = 0.85
EmergencyMaintenanceHours = 0.5
```

---

### 🟢 Claude/Opus - Final Position

**Verdict: THREE-LAYER SYSTEM WITH ADAPTIVE ACTIVATION**

**Confidence Score: 9.5/10**

**Final Architecture Decision:**

| Setting | Value | Rationale |
|---------|-------|-----------|
| Default Mode | EMERGENCY_AUTO | Balance safety and performance |
| Heat Threshold | 90% | Critical exposure level |
| Maintenance Threshold | 1 hour | Extended downtime only |
| Spread Multiplier | 2.5× | Conservative buffer |
| Activation | Adaptive | Proportional to threat |

**Why Three-Layer is Optimal:**

1. **Layer 1 (Virtual):** 0.1ms execution, basket-level protection
2. **Layer 2 (Checkpoint):** Adaptive frequency (1-30 seconds)
3. **Layer 3 (Emergency):** <1% of time, critical scenarios only

**Performance Impact:**
- Normal operation: 0.1ms (virtual only)
- Elevated: 0.1ms (virtual) + periodic checkpoint
- Critical: 0.1ms (virtual) + frequent checkpoint + emergency stops (one-time cost)

**Safety Coverage:**
- Normal trading: ✅ Virtual trailing
- Short crashes (<5 min): ✅ Checkpoint recovery
- Extended downtime: ✅ Emergency stops
- User offline: ✅ Emergency stops (user-initiated)

---

## 📊 FINAL SCORING MATRIX

| Criterion | Sonnet | Gemini | Codex | Claude |
|-----------|--------|--------|-------|--------|
| **Performance** | 10/10 | 9/10 | 9/10 | 9/10 |
| **Safety** | 8/10 | 10/10 | 10/10 | 10/10 |
| **Basket Integrity** | 10/10 | 9/10 | 9/10 | 9/10 |
| **Crash Protection** | 7/10 | 10/10 | 10/10 | 10/10 |
| **User Experience** | 9/10 | 9/10 | 10/10 | 9/10 |
| **Implementation** | 8/10 | 9/10 | 10/10 | 9/10 |
| **TOTAL SCORE** | **52/60** | **56/60** | **58/60** | **56/60** |

### 🏆 Winner: Codex (User-Configurable Implementation)

**Reasoning:** Codex's user-configurable approach provides maximum flexibility while maintaining safety. Users can choose their risk tolerance (OFF/AUTO/MANUAL) with sensible defaults.

---

## 📋 FINAL RECOMMENDATION

### Approved Architecture: Three-Layer Protection System

```
┌─────────────────────────────────────────────────────────────┐
│           TRAILING STOP: Three-Layer System                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  USER CONFIGURATION                                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Emergency Mode: AUTO (default)                      │   │
│  │ Heat Threshold: 90%                                  │   │
│  │ Maintenance Threshold: 1 hour                        │   │
│  │ Spread Multiplier: 2.5×                              │   │
│  └─────────────────────────────────────────────────────┘   │
│                      │                                      │
│  ┌────────────────────▼────────────────────────────────┐   │
│  │  LAYER 1: VIRTUAL TRAILING (Always Active)          │   │
│  │  ─────────────────────────────────────────────────   │   │
│  │  Execution: Every tick (<0.1ms)                     │   │
│  │  Peak Tracking: Maximum favorable excursion         │   │
│  │  Stop Calculation: Peak - Trail Distance            │   │
│  │  Basket Integrity: Maintained (closes all together) │   │
│  │  Broker Visibility: HIDDEN                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                      │                                      │
│  ┌────────────────────▼────────────────────────────────┐   │
│  │  LAYER 2: CHECKPOINT PERSISTENCE (Adaptive)        │   │
│  │  ─────────────────────────────────────────────────   │   │
│  │  Storage: Global Variables                          │   │
│  │  Frequency: 1-30 seconds (based on threat level)    │   │
│  │  Normal (Heat <60%): Every 30 seconds                │   │
│  │  Elevated (Heat 60-75%): Every 10 seconds            │   │
│  │  High (Heat 75-90%): Every 3 seconds                 │   │
│  │  Critical (Heat >90%): Every 1 second                │   │
│  │  Purpose: Recovery after terminal restart           │   │
│  └─────────────────────────────────────────────────────┘   │
│                      │                                      │
│  ┌────────────────────▼────────────────────────────────┐   │
│  │  LAYER 3: EMERGENCY PHYSICAL STOPS (Conditional)     │   │
│  │  ─────────────────────────────────────────────────   │   │
│  │  Activation Conditions:                             │   │
│  │  • Heat > 90% (critical exposure)                   │   │
│  │  • Maintenance planned >1 hour                      │   │
│  │  • User-initiated shutdown                         │   │
│  │  • Connection unstable                              │   │
│  │                                                     │   │
│  │  Stop Calculation:                                 │   │
│  │  • Weighted average + (2.5× spread) + commission    │   │
│  │  • All positions at SAME price (basket integrity)   │   │
│  │                                                     │   │
│  │  Usage: <1% of time (critical scenarios only)       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Default Configuration:**
- Mode: AUTO
- Heat Threshold: 90%
- Maintenance: 1 hour
- Spread Multiplier: 2.5×

---

**Debate Complete. See final synthesis document for implementation guide.**
