# SIDEWAY KILLER - Core Trading Logic Extraction

**Document Type:** Business Logic Specification  
**Source System:** STORM RIDER V5 Recovery Architecture  
**Target:** 100% Real-time Lightweight Implementation  
**Constraint:** ZERO code references - Pure Mathematical Logic Only

---

## 1. BASKET & GRID LOGIC

### 1.1 Basket Formation Rules

A Basket is defined as a collection of related trading positions that share:
- **Common Direction:** All BUY or all SELL
- **Common Symbol:** All positions trade the same instrument
- **Common Origin:** One "Original" position + optional "Recovery" positions
- **Unique Identifier:** A basket ID that persists for the lifetime of the group

**Basket Lifecycle:**
1. **Creation:** Triggered when a new position (manual or automated) meets adoption criteria
2. **Active State:** Basket accepts additional recovery levels until maximum reached
3. **Closure:** All positions closed simultaneously when target conditions met
4. **Deletion:** Basket record purged after successful closure

---

### 1.2 Grid Spacing Mathematics (DVASS Model)

**Core Principle:** Dynamic spacing between recovery orders based on market volatility.

#### Step 1: Base Distance Calculation

The base spacing between grid levels is defined in **points** (not pips).

**Default Base:** 250 points (25 pips for XAUUSD)
**Range:** 50 - 1000 points (user configurable)

#### Step 2: Volatility Scaling (ATR Method)

The base distance is adjusted by current market volatility using the ATR (Average True Range):

```
Normalized ATR = Current ATR / 20.0
Adjusted Step = Base Step × Normalized ATR
```

**Example:**
- Base Step: 250 points
- Current ATR: 30 points
- Normalized ATR: 30 / 20 = 1.5
- Adjusted Step: 250 × 1.5 = 375 points

#### Step 3: Level Expansion Factor

Each successive grid level expands the spacing exponentially:

```
Level Multiplier = (1.0 + Expansion Factor) ^ Level Index
Final Step = Adjusted Step × Level Multiplier
```

**Default Expansion Factor:** 0.3 (30%)
**Mathematical Effect:**
- Level 0 (Original): × 1.00
- Level 1: × 1.30
- Level 2: × 1.69
- Level 3: × 2.20
- Level 4: × 2.86
- Level 5: × 3.71
- Level 6: × 4.83
- Level 7: × 6.27

#### Step 4: Trigger Condition

A new grid level is added when:

```
For BUY Baskets:
    (Last Level Price - Current Price) ≥ Required Step

For SELL Baskets:
    (Current Price - Last Level Price) ≥ Required Step
```

**Cooldown Protection:** Minimum 30 seconds between grid executions to prevent over-trading during volatile spikes.

---

### 1.3 Lot Multiplier Mathematics (RAKIM Model)

**Core Principle:** Each recovery level uses a progressively larger position size to accelerate breakeven recovery.

#### Base Multiplier

**Default:** 1.5× (each level 50% larger than the original)
**Range:** 1.1× - 5.0×

#### Kelly Criterion Enhancement

The system optionally applies the Kelly Formula to optimize position sizing:

```
Kelly Fraction = (p × b - q) / b
Where:
    p = Historical Win Rate (default: 0.65)
    q = 1 - p = Historical Loss Rate (0.35)
    b = Average Win / Average Loss (reward-to-risk ratio)

Applied Kelly = Kelly Fraction × Safety Factor (default: 0.25)
Kelly Multiplier = 1.0 + Applied Kelly
```

**Conservative Application:**
- If Kelly suggests lower risk than base multiplier → use base
- If Kelly suggests higher risk than base multiplier → use Kelly (if within max bounds)

#### Level Decay Factor

As the basket goes deeper (more levels), the multiplier decays slightly to control risk:

```
Decay Factor = 0.95 ^ Current Level
Final Multiplier = Raw Multiplier × Decay Factor
```

**Effect:**
- Level 0: × 1.00
- Level 3: × 0.86
- Level 5: × 0.77
- Level 7: × 0.70

#### Heat Constraint System

When account "heat" (risk exposure) approaches limits, the multiplier is reduced:

```
Heat Ratio = Current Heat / Maximum Heat

If Heat Ratio > 0.90:
    Multiplier = Minimum (1.1×)
    
If Heat Ratio > 0.70 (threshold):
    Multiplier = Calculated × 0.80 (20% reduction)
```

#### Final Lot Size Calculation

```
Base Lot = Original Position Lot Size
Proposed Lot = Base Lot × Final Multiplier

Normalized to broker constraints:
    - Minimum lot size
    - Maximum lot size  
    - Lot step increment
```

---

### 1.4 Maximum Grid Depth

**Hard Limit:** 7 levels maximum (configurable 3-15)

**Safety Rationale:** Prevents catastrophic exposure in trending markets where price continues moving against the basket direction.

**Level Cap Logic:** When maximum reached, no new recovery orders are placed. The system waits for either:
- Price recovery to breakeven/profit target
- Manual intervention
- Hard stop loss trigger

---

## 2. PROFIT & EXIT STRATEGY

### 2.1 Weighted Average Price (Breakeven) Calculation

**Core Formula:** Volume-weighted average of all positions in the basket.

```
Weighted Average = Σ (Open Price × Lot Size) / Σ (Lot Size)
```

**Example:**
- Position 1: Buy 0.10 lot at 2050.00
- Position 2: Buy 0.15 lot at 2047.50
- Position 3: Buy 0.23 lot at 2045.00

```
Weighted Average = (2050×0.10 + 2047.5×0.15 + 2045×0.23) / (0.10+0.15+0.23)
                 = (205.00 + 307.125 + 470.35) / 0.48
                 = 982.475 / 0.48
                 = 2046.82
```

### 2.2 Breakeven Target with Cost Buffer

**Pure Breakeven:** The weighted average price where P&L = 0

**Executable Breakeven:** Pure BE + Cost Buffer + Profit Buffer

```
Cost Buffer = 2 points (execution slippage estimate)
Profit Buffer = 5 points (user configurable)

For BUY Baskets:
    BE Target = Weighted Average + Cost Buffer + Profit Buffer
    
For SELL Baskets:
    BE Target = Weighted Average - Cost Buffer - Profit Buffer
```

**Example (BUY):**
- Weighted Average: 2046.82
- Cost Buffer: 0.20 (2 points)
- Profit Buffer: 0.50 (5 points)
- BE Target: 2046.82 + 0.20 + 0.50 = 2047.52

### 2.3 USD Profit Target Calculation

**Primary Target:** Fixed USD amount for entire basket (default: $5.00)

**Alternative:** Dynamic target based on basket heat/risk

#### Net Profit Calculation (Fast-Strike Method)

For rapid execution without API overhead:

```
For BUY Baskets:
    Price Distance = Current Price - Weighted Average
    
For SELL Baskets:
    Price Distance = Weighted Average - Current Price

Approximate Profit USD = Price Distance × Total Volume × USD-per-Lot-per-Point
```

**XAUUSD Convention:**
- 1 lot = $100 per point (approximately)
- 0.01 lot = $1 per point

**Commission Adjustment:**
- Estimated commission: $7 per lot round-turn
- Adjusted Target = User Target + (Total Volume × Commission per Lot)

**Example:**
- Target: $5.00
- Total Volume: 0.48 lots
- Commission: $7 × 0.48 = $3.36
- Adjusted Target: $5.00 + $3.36 = $8.36

### 2.4 Fast-Strike Execution Rules

**Trigger Condition:**
```
If (Approximate Profit USD ≥ Adjusted Target) 
   AND (Basket Age ≥ Minimum Age)
   → EXECUTE IMMEDIATE CLOSE
```

**Minimum Age Rule:** 60 seconds (prevents premature closure on micro-fluctuations)

**Execution Priority:**
1. Fast profit check (pure math, <5ms)
2. Position re-verification (safety check)
3. Order execution
4. Basket cleanup

**Dual-Path Architecture:**
- **Hot Path:** Fast math-based check every tick
- **Cold Path:** Full refresh and verification every 1 second

### 2.5 Exit Sequence

When target reached:

1. **Flag Basket for Closure** → Prevents new grid additions
2. **Close All Positions** → Individual close orders for each level
3. **Verify Closure** → Confirm all positions closed
4. **Purge Basket Record** → Remove from active baskets
5. **Log Results** → Profit/loss, duration, number of levels

---

## 3. MANUAL ADOPTION PROTOCOL

### 3.1 Adoption Trigger Conditions

A position becomes eligible for adoption when:

1. **Magic Number Match:** Position magic equals target magic (0 or 888)
2. **Symbol Match:** Position symbol matches EA symbol
3. **Drawdown Threshold:** Position is in loss within acceptable range
4. **Not Already Adopted:** Position not in existing basket

### 3.2 Drawdown Calculation

```
For BUY Positions:
    Drawdown % = ((Open Price - Current Price) / Open Price) × 100

For SELL Positions:
    Drawdown % = ((Current Price - Open Price) / Open Price) × 100
```

**Adoption Range:**
- Minimum: > 0% (position must be in loss)
- Maximum: < 2% (configurable, default 2%)

**Rejections:**
- Drawdown = 0%: Position in profit (wait for drawdown)
- Drawdown > Max: Loss too deep (risk management)

### 3.3 Automatic Adoption Flow

1. **Scan:** Every 1 second, scan all open positions
2. **Filter:** Identify positions matching magic criteria
3. **Calculate:** Determine drawdown percentage
4. **Evaluate:** Check if within adoption range
5. **Create Basket:** Generate new basket with position as "Level 0"
6. **Set Target:** Assign profit target to basket
7. **Persist:** Store basket state for recovery after restart

### 3.4 Manual Adoption Override

Traders may manually flag positions for adoption via UI:
- **Ignore Ticket:** Mark position to never adopt
- **Force Adopt:** Override drawdown limits
- **Clear History:** Reset adoption tracking

---

## 4. DATA MAPPING (GLOBAL VARIABLES)

### 4.1 Single Source of Truth Architecture

All critical data must be stored in Terminal Global Variables to ensure:
- Persistence across EA restarts
- Shared state between UI and Logic
- Real-time dashboard updates

### 4.2 Basket Data Structure

Each active basket requires storage of:

**Core Identification:**
- Basket ID (integer)
- Original Position Ticket (unique identifier)
- Original Magic Number (for adoption tracking)
- Direction (BUY or SELL)
- Status (ACTIVE or CLOSED)

**Basket State:**
- Number of Levels (count of positions in basket)
- Creation Time (datetime)
- Weighted Average Price (breakeven reference)
- Total Volume (sum of all lots)
- Target Profit USD (closure target)

**Per-Level Data:**
For each recovery level (up to maximum):
- Position Ticket
- Lot Size
- Open Price
- Open Time
- Is Original Flag (true for Level 0 only)

### 4.3 Dashboard Data Requirements

**Real-Time Metrics (Updated Every Tick):**
- Current Bid/Ask Price
- Active Basket Count
- Total Exposure (lots)
- Current Heat Level (% of max allowed)

**Calculated Metrics (Updated Every Second):**
- Total Floating P&L (all baskets)
- Closest Basket to Target
- Average Recovery Progress

**Configuration Parameters:**
- Target Magic Numbers (adoption targets)
- Maximum Grid Levels
- Base Step Points
- Lot Multiplier Settings
- Profit Target USD

### 4.4 Persistence Strategy

**Save Trigger:**
- New basket created
- Grid level added
- Basket closed
- Every 60 seconds (heartbeat)

**Load Trigger:**
- EA initialization
- After terminal restart

**Cleanup:**
- Delete orphaned records (basket closed but GV remains)
- Clear old-format data on version upgrade
- Purge all on EA deinitialization (optional)

---

## 5. SIMPLE TRAILING STOP (VIRTUAL)

### 5.1 Virtual vs Physical Stops

**Physical Stop Loss:**
- Modifies position directly
- Broker sees the stop level
- May be hunted by spread manipulation

**Virtual Trailing Stop:**
- Monitors price in memory
- No modification to position
- Closes position when threshold breached
- Hidden from broker

### 5.2 Trailing Stop Mathematics

**Three Parameters:**
1. **Activation Distance:** Points in profit before trailing begins (default: 100)
2. **Step Distance:** Minimum price movement to adjust stop (default: 50)
3. **Trail Distance:** Distance from peak price to virtual stop (default: 50)

#### Peak Price Tracking

```
For BUY Positions:
    Peak Price = Maximum of (Peak Price, Current Price)
    
For SELL Positions:
    Peak Price = Minimum of (Peak Price, Current Price)
```

#### Trailing Stop Calculation

```
For BUY Positions:
    Virtual Stop = Peak Price - Trail Distance
    Trigger if: Current Price ≤ Virtual Stop
    
For SELL Positions:
    Virtual Stop = Peak Price + Trail Distance
    Trigger if: Current Price ≥ Virtual Stop
```

### 5.3 Single Position Trailing

**Activation Condition:**
```
Current Profit Points ≥ Activation Distance
```

**Initial Stop Placement:**
- No existing stop loss → Set at Entry Price + Step Distance
- Existing stop loss → Keep if better than calculated

**Adjustment Logic:**
```
If (Current Price - Stop Loss) > Step Distance:
    New Stop = Current Price - Step Distance
```

### 5.4 Basket Virtual Trailing

**Unified Approach:** Apply trailing to entire basket as single unit.

**Reference Point:** Weighted Average Price (same as BE calculation)

**Distance from Open:**
```
For BUY Baskets:
    Distance = Current Price - Weighted Average
    
For SELL Baskets:
    Distance = Weighted Average - Current Price
```

**Peak Tracking:** Maximum favorable excursion from weighted average

**Trigger:** When price retreats from peak by Trail Distance, close entire basket.

### 5.5 Non-Interference Rule

**Critical Constraint:** Virtual trailing must not interfere with recovery grid logic.

**Priority Hierarchy:**
1. Profit Target (closes entire basket)
2. Breakeven Target (closes entire basket)
3. Virtual Trailing (closes entire basket)
4. Hard Stop Loss (emergency only)
5. Grid Addition (recovery only)

**Visual Indicators:**
- Breakeven Line: Gold color, dashed
- Trailing Line: Lime green, dotted
- Virtual Stop Level: Orange, dot

---

## 6. SAFETY SYSTEM INTEGRATION

### 6.1 Heat Calculation

**Definition:** Total account exposure as percentage of balance.

```
Basket Drawdown $ = (Weighted Average - Current Price) × Volume × Value-per-Point
Heat % = (Basket Drawdown $ / Account Balance) × 100
```

**Maximum Recovery Heat:** 3% (configurable)
**Maximum Total Heat:** 5% (configurable)

### 6.2 Safety Halts

**Automatic Trading Halt When:**
- Heat exceeds maximum threshold
- Margin level below 200%
- Spread exceeds 100 points (XAUUSD)
- Broker connection lost

**Recovery:** Auto-resume when all conditions normalize.

---

## 7. SUMMARY: KEY MATHEMATICAL FORMULAS

| Component | Formula | Default Value |
|-----------|---------|---------------|
| **Grid Step** | Base × (ATR/20) × (1.3^Level) | 250 pts base |
| **Lot Multiplier** | Base × Kelly × 0.95^Level × Heat Constraint | 1.5× base |
| **Weighted Average** | Σ(Price × Lot) / Σ(Lot) | - |
| **BE Target** | WA ± (Cost Buffer + Profit Buffer) | +7 points |
| **Fast Profit** | Distance × Volume × $100/lot/pt | - |
| **Trail Stop** | Peak ∓ Trail Distance | 50 points |
| **Drawdown %** | (|Open - Current| / Open) × 100 | < 2% for adoption |

---

**END OF CORE LOGIC EXTRACTION**

*This document contains pure business logic. No implementation details, function names, or file references are included. Suitable for complete system rewrite.*
