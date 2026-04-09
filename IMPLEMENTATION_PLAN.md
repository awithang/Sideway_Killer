# SIDEWAY KILLER - Implementation Plan

**Based on:** 6 Architecture Debates (2026-04-09)
**Status:** Ready for Implementation
**Target Platform:** MetaTrader 5 (MQL5) for XAUUSD/Gold Trading

---

## 📋 EXECUTIVE SUMMARY

This implementation plan consolidates decisions from 6 comprehensive debates into a phased build approach for the SIDEWAY KILLER Expert Advisor. Each component has been analyzed, debated, and approved with consensus from 4 AI perspectives (Claude/Opus, Sonnet, Gemini, Codex).

**Total Components:** 6 major systems
**Estimated Implementation Time:** 40-60 hours
**Testing Strategy:** Unit → Integration → Live Demo

---

## 🎯 APPROVED ARCHITECTURE DECISIONS

| # | Component | Approved Approach | Winner | Score |
|---|-----------|-------------------|--------|-------|
| 1 | Data Architecture | Hybrid SSoT (Cache + GV) | Codex | 59/60 |
| 2 | Grid Spacing | DVASS with modes | Codex | 57/60 |
| 3 | Lot Multiplier | Fixed with Bayesian | Codex | 58/60 |
| 4 | Profit Detection | Two-layer FastStrike | Claude | 56/60 |
| 5 | Trailing Stop | Three-layer protection | Codex | 56/60 |
| 6 | Adoption Protocol | Smart adaptive config | Codex | 57/60 |

---

## 🏗️ IMPLEMENTATION PHASES

### Phase 1: Foundation Layer (Prerequisites)
**Dependencies:** None
**Time Estimate:** 8-12 hours

This phase implements the data architecture that all other systems depend on.

#### 1.1 Single Source of Truth (SSoT) Implementation
- [ ] Define Global Variable namespace constants
- [ ] Implement GV read/write wrapper functions
- [ ] Create in-memory cache structures
- [ ] Implement cache-GV synchronization logic
- [ ] Add error handling for GV failures
- [ ] Implement recovery/restore from GV on startup

**Reference:** `.claude/debates/architecture-ssot-20260409-082357/SYNTHESIS.md`

#### 1.2 Core Data Structures
- [ ] BasketCache structure definition
- [ ] MarketState structure definition
- [ ] VirtualTrailingState structure
- [ ] CheckpointState structure
- [ ] Configuration parameter definitions

#### 1.3 Utility Functions
- [ ] ATR calculation (14, 100 period)
- [ ] Average spread calculator
- [ ] Drawdown percentage calculator
- [ ] Weighted average calculator
- [ ] Heat calculator

**Deliverable:** Foundation layer module with all data structures and utilities
**Test:** Verify GV persistence survives terminal restart

---

### Phase 2: Position Adoption System
**Dependencies:** Phase 1 (SSoT, Data Structures)
**Time Estimate:** 6-10 hours

#### 2.1 User Command Scanner
- [ ] Implement comment parser (NOADOPT, FORCE, CLEAR)
- [ ] Create exclusion/force tracking arrays
- [ ] Add command processing loop (OnTimer)
- [ ] Implement processed flag to prevent re-processing

#### 2.2 Market State Updater
- [ ] Implement volatility ratio calculation (ATR14/ATR100)
- [ ] Implement spread ratio calculation (current/average)
- [ ] Create market condition flags (high vol, wide spread, news time)
- [ ] Add news window detection (placeholder for calendar integration)

#### 2.3 Adoption Logic Engine
- [ ] Implement base criteria check (magic, symbol, loss, drawdown range)
- [ ] Implement Aggressive mode (30s min age, base criteria only)
- [ ] Implement Smart mode (adaptive age 60s+, spread/vol checks)
- [ ] Implement Conservative mode (90s age, strict checks)
- [ ] Implement Manual mode (force list only)
- [ ] Add mode selection via input parameter

**Reference:** `.claude/debates/adoption-protocol-20260409-091320/SYNTHESIS.md`

**Deliverable:** Complete adoption system with 4 modes
**Test:** Verify adoption triggers correctly under different market conditions

---

### Phase 3: Grid System (Core Recovery Logic)
**Dependencies:** Phase 1, Phase 2
**Time Estimate:** 10-15 hours

#### 3.1 Grid Spacing Engine (DVASS)
- [ ] Implement ATR calculation for grid spacing
- [ ] Create spacing mode enumeration (DVASS, Fixed, Fibonacci)
- [ ] Implement DVASS calculation formula
- [ ] Add configurable multiplier (0.5-3.0)
- [ ] Implement minimum/maximum spacing limits
- [ ] Create spacing cache for performance

**Formula:**
```
Spacing = ATR(14) × Multiplier × VolatilityAdjustment
where VolatilityAdjustment = ATR(14) / ATR(100)
```

**Reference:** `.claude/debates/grid-spacing-dvass-20260409-082950/SYNTHESIS.md`

#### 3.2 Lot Multiplier System
- [ ] Implement fixed multiplier mode (default: 1.5)
- [ ] Create RAKIM formula implementation (optional)
- [ ] Add Kelly Criterion calculation (optional Bayesian mode)
- [ ] Implement maximum lot cap safeguard
- [ ] Add position sizing verification

**Formula:**
```
Fixed: Lot(n) = Lot(n-1) × Multiplier
RAKIM: Lot(n) = Lot(n-1) × (1 + Kelly × PriorWeight)
```

**Reference:** `.claude/debates/lot-multiplier-20260409-084213/SYNTHESIS.md`

#### 3.3 Grid Level Management
- [ ] Implement level addition logic
- [ ] Calculate level prices based on direction
- [ ] Manage basket weighted average updates
- [ ] Add level count limits (MAX_LEVELS)
- [ ] Implement basket integrity checks

**Deliverable:** Complete grid system with configurable spacing and lot sizing
**Test:** Verify grid levels add correctly and recover positions

---

### Phase 4: Profit Detection & Execution
**Dependencies:** Phase 3 (Basket, Grid)
**Time Estimate:** 8-12 hours

#### 4.1 Two-Layer Profit Detection
- [ ] Implement Layer 1: Quick spark check (current profit > 0)
- [ ] Implement Layer 2: Full basket verification
- [ ] Create profit threshold calculation (configurable %)
- [ ] Add profit type detection (spark vs sustained)
- [ ] Implement FastStrike execution path (<0.10ms latency)

**Detection Logic:**
```
Layer 1 (Hot Path): CurrentProfit > 0 AND (Price - AvgPrice) × Lots > Threshold
Layer 2 (Verification): Recalculate full basket profit
```

**Reference:** `.claude/debates/faststrike-20260409-085643/SYNTHESIS.md`

#### 4.2 FastStrike Execution
- [ ] Implement immediate basket closure on profit detection
- [ ] Add close-all-positions function (atomic operation)
- [ ] Implement error handling for partial closes
- [ ] Add profit confirmation logging
- [ ] Create user notification (Alert) on success

**Deliverable:** FastStrike profit detection and execution
**Test:** Verify profit detection triggers within 0.10ms and closes basket

---

### Phase 5: Trailing Stop Protection
**Dependencies:** Phase 3 (Basket, Weighted Average)
**Time Estimate:** 8-12 hours

#### 5.1 Virtual Trailing Implementation
- [ ] Implement peak price tracking (highest for BUY, lowest for SELL)
- [ ] Create activation distance logic (default: 100 points)
- [ ] Implement trail distance calculation (default: 50 points)
- [ ] Add virtual stop level calculation
- [ ] Create stop trigger detection
- [ ] Execute basket close on stop trigger

**Virtual Logic:**
```
Activation: (Price - WeightedAvg) ≥ ActivationDistance
Trail: StopLevel = PeakPrice - TrailDistance
Trigger: Price ≤ StopLevel (BUY) or Price ≥ StopLevel (SELL)
```

**Reference:** `.claude/debates/trailing-stop-20260409-090420/SYNTHESIS.md`

#### 5.2 Checkpoint Persistence
- [ ] Implement checkpoint save to Global Variables
- [ ] Create adaptive checkpoint frequency (1-30 seconds based on threat)
- [ ] Implement checkpoint restore on startup
- [ ] Add checkpoint validation (time-based expiration)
- [ ] Create protection level determination logic

#### 5.3 Emergency Stop System
- [ ] Implement emergency stop condition detection
- [ ] Create physical stop placement function
- [ ] Add basket integrity protection (same price for all positions)
- [ ] Implement emergency stop removal when conditions normalize
- [ ] Add OnDeinit emergency stop placement

**Emergency Conditions:**
- Heat > 90%
- Planned maintenance > 1 hour
- User-initiated shutdown
- Connection instability

**Deliverable:** Three-layer trailing stop protection
**Test:** Verify virtual trailing works, checkpoints persist, emergency stops protect

---

### Phase 6: Heat Management & Safety
**Dependencies:** Phase 3 (Basket calculations)
**Time Estimate:** 4-6 hours

#### 6.1 Heat Calculation
- [ ] Implement total exposure calculation
- [ ] Create recovery heat calculator (5% max)
- [ ] Implement total heat calculator (10% max)
- [ ] Add heat-based throttling logic
- [ ] Create heat alert system

#### 6.2 Safety Limits
- [ ] Implement maximum concurrent baskets limit
- [ ] Add maximum total lots limit
- [ ] Create maximum drawdown limit
- [ ] Implement emergency shutdown on limit breach
- [ ] Add safety override for user commands

**Deliverable:** Complete heat and safety management system
**Test:** Verify system stops adding baskets when heat limits reached

---

### Phase 7: Integration & Testing
**Dependencies:** All previous phases
**Time Estimate:** 8-12 hours

#### 7.1 Main Integration
- [ ] Integrate OnTick handler (profit check, grid logic, virtual trailing)
- [ ] Integrate OnTimer handler (user commands, checkpoint, adoption scan)
- [ ] Integrate OnInit (load from GV, restore checkpoints)
- [ ] Integrate OnDeinit (emergency stops, save state)
- [ ] Add comprehensive logging throughout

#### 7.2 Configuration Interface
- [ ] Create input parameter definitions for all user options
- [ ] Implement configuration presets (Aggressive, Balanced, Conservative)
- [ ] Add configuration validation
- [ ] Create configuration documentation

#### 7.3 Testing Suite
- [ ] Unit tests for each major function
- [ ] Integration tests for system interactions
- [ ] Edge case testing (flash crashes, extreme volatility)
- [ ] Performance testing (latency verification)
- [ ] Demo account live testing

**Deliverable:** Production-ready SIDEWAY KILLER Expert Advisor
**Test:** Complete testing suite with all tests passing

---

## 📊 CONFIGURATION DEFAULTS

### Default Mode: Balanced (Recommended)

```mql5
// Data Architecture
AutoSaveInterval = 30;           // Seconds

// Grid Spacing
GridSpacingMode = GRID_DVASS;    // DVASS
DVASS_Multiplier = 1.0;          // 1.0 × ATR
DVASS_VolatilityAdjust = true;   // Enable adjustment

// Lot Multiplier
LotMultiplierMode = LOT_FIXED;   // Fixed
FixedMultiplier = 1.5;           // 1.5×

// Profit Detection
ProfitTargetPercent = 0.5;       // 0.5% of basket value
FastStrikeLatencyTarget = 0.10;  // <0.10ms

// Trailing Stop
VirtualTrail_Activation = 100;   // Points
VirtualTrail_Distance = 50;      // Points
CheckpointInterval = 30;         // Seconds (normal conditions)
EmergencyStopMode = EMERGENCY_AUTO;

// Adoption
AdoptionMode = ADOPT_SMART;      // Smart adaptive
Smart_MinAge = 60;               // Seconds
Smart_SpreadMult = 3.0;          // 3.0× average

// Heat Management
MaxRecoveryHeat = 5.0;           // 5% of account
MaxTotalHeat = 10.0;             // 10% of account
MaxConcurrentBaskets = 3;        // Maximum baskets
```

---

## 🧪 TESTING CHECKLIST

### Foundation Tests
- [ ] GV persistence survives terminal restart
- [ ] Cache synchronization works correctly
- [ ] Data structures initialize properly
- [ ] Utility functions return accurate values

### Adoption Tests
- [ ] NOADOPT command prevents adoption
- [ ] FORCE command overrides all checks
- [ ] CLEAR command removes overrides
- [ ] Smart mode adapts to market conditions
- [ ] Conservative mode is stricter than smart
- [ ] Aggressive mode is fastest

### Grid Tests
- [ ] DVASS spacing adjusts to volatility
- [ ] Grid levels add at correct prices
- [ ] Lot multipliers apply correctly
- [ ] Weighted average updates accurately
- [ ] Basket integrity maintained

### Profit Detection Tests
- [ ] Layer 1 detects profit quickly
- [ ] Layer 2 verifies full basket
- [ ] FastStrike executes within 0.10ms
- [ ] Basket closes completely
- [ ] No positions left behind

### Trailing Stop Tests
- [ ] Virtual trailing activates at correct distance
- [ ] Stop level trails peak correctly
- [ ] Stop trigger closes basket
- [ ] Checkpoints persist and restore
- [ ] Emergency stops protect during shutdown

### Integration Tests
- [ ] Full adoption → grid → profit → close cycle
- [ ] Multiple baskets operate independently
- [ ] Heat limits prevent over-extension
- [ ] System handles terminal restart
- [ ] Emergency procedures work correctly

---

## 📈 IMPLEMENTATION ORDER SUMMARY

**Sequential Build Order (Critical Path):**

1. **Foundation** → Must be first (everything depends on SSoT)
2. **Adoption** → Second (creates baskets for system to manage)
3. **Grid** → Third (operates on adopted baskets)
4. **Profit Detection** → Fourth (needs basket with levels)
5. **Trailing Stop** → Fifth (protects profitable baskets)
6. **Heat Management** → Sixth (regulates entire system)
7. **Integration** → Last (ties everything together)

**Parallel Work Opportunities:**
- Phases 2-3 can start in parallel after Phase 1
- Phases 4-5 can develop independently after Phase 3
- Phase 6 can run parallel to Phase 7

---

## 🎯 SUCCESS CRITERIA

### Functional Requirements
- [ ] System automatically adopts qualifying positions
- [ ] Grid levels add at mathematically optimal spacing
- [ ] Profit detection executes in <0.10ms
- [ ] Virtual trailing protects profits without broker visibility
- [ ] Emergency stops protect against unexpected shutdowns

### Performance Requirements
- [ ] OnTick execution: <1ms average
- [ ] Checkpoint save: <10ms
- [ ] GV read/write: <5ms per operation
- [ ] Memory usage: <50MB

### Safety Requirements
- [ ] Heat limits never exceeded
- [ ] No orphaned positions after basket close
- [ ] Emergency stops activate before critical failures
- [ ] User commands always respected

---

## 📚 REFERENCE DOCUMENTS

For detailed implementation guidance, refer to:

1. **Data Architecture:** `.claude/debates/architecture-ssot-20260409-082357/SYNTHESIS.md`
2. **Grid Spacing:** `.claude/debates/grid-spacing-dvass-20260409-082950/SYNTHESIS.md`
3. **Lot Multiplier:** `.claude/debates/lot-multiplier-20260409-084213/SYNTHESIS.md`
4. **Profit Detection:** `.claude/debates/faststrike-20260409-085643/SYNTHESIS.md`
5. **Trailing Stop:** `.claude/debates/trailing-stop-20260409-090420/SYNTHESIS.md`
6. **Adoption Protocol:** `.claude/debates/adoption-protocol-20260409-091320/SYNTHESIS.md`

---

## 🚀 READY TO BEGIN

All architectural decisions are finalized and consensus-approved.
Implementation plan is complete with phased approach.
Reference documents contain detailed code examples.

**Next Step:** Begin Phase 1 implementation or request clarification on any component.
