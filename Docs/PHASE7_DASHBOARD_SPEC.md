# SIDEWAY KILLER — Phase 7 Dashboard UI Specification (REVISED v2.0)

**Document Version:** 2.0.0 — COMMAND CENTER EDITION — DRAFT FOR AUDIT  
**Phase:** 7 — Dashboard & UX System  
**Architect:** KIMI-K2  
**Date:** 2026-04-09  
**Status:** ⏳ PENDING AUDIT (GLM-4.7) + USER APPROVAL  

**Scope:** Command Center dashboard with live metrics, manual trade controls, emergency intervention, and near-real-time dynamic updates. Logic design only — no implementation code.  

**Design Authority:**
- `AGENTS.md` — "0-delay dashboard at the Top-Right Corner"
- `Docs/PHASE6_LOGIC_SPEC.md` — Heat levels, halt states, drawdown calculations
- `Docs/PHASE5_LOGIC_SPEC.md` (v2.0) — Handed-over basket state
- `Docs/PHASE2_ADOPTION_PROTOCOL.md` — Manual trade adoption criteria
- `Docs/GV_SCHEMA.md` — Dashboard GV namespace (`SK_DASH_*`)
- `SYNTHESIS/SSoT.md` — Cache-first architecture

---

## EXECUTIVE SUMMARY (REVISED v2.0)

Phase 7 v2.0 transforms the dashboard from a **read-only monitor** into an **interactive Command Center**. The Captain requires:

1. **Live Metrics at a glance** — Price, P&L, and Drawdown prominently displayed
2. **Manual Trade Execution** — Direct BUY/SELL buttons for discretionary entries
3. **Emergency Override** — One-click CLOSE ALL for manual intervention
4. **Near-Real-Time Updates** — P&L and Drawdown refreshed every 200ms via millisecond timer

**Core Design Principles:**
1. **Top-Right Positioning:** Non-intrusive, standard UI convention
2. **Cold-Path Core:** Heavy logic remains in `OnTimer(1s)`
3. **Millisecond Sub-Timer:** Dashboard P&L/DD updates at 200ms (still cold path)
4. **Cache-First Data:** All values read from in-memory cache
5. **Interaction Safety:** All buttons require confirmation or have safeguards
6. **Color-Driven UX:** Status conveyed primarily through color

---

## CHANGE LOG (v1.0 → v2.0)

| Feature | v1.0 | v2.0 (Command Center) |
|---------|------|----------------------|
| **Live Price** | Not shown | **Bid/Ask prominently at top** |
| **Floating P&L** | Not shown | **Real-time $ display with color** |
| **Portfolio DD** | Indirect (via heat) | **Explicit % display at top** |
| **Trade Controls** | None | **BUY/SELL buttons** |
| **Emergency** | Status only | **CLOSE ALL button** |
| **Update Freq** | 1 second | **200ms for P&L/DD (millisecond timer)** |
| **Interaction** | Read-only | **Interactive buttons + inputs** |

---

## 1. ARCHITECTURE OVERVIEW (REVISED)

### 1.1 Dual-Timer Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DASHBOARD v2.0 — DUAL-TIMER SYSTEM                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  OnTick() Hot Path                                                       │
│  ─────────────────                                                       │
│  • FastStrikeCheck()        [Priority 1]                                │
│  • CheckGridLevels()        [Priority 2]                                │
│  • UpdateVirtualTrailing()  [Priority 3]                                │
│  • ════════════════════════════════════════                             │
│  • Dashboard_TickPriceUpdate()  [Phase 7] ← Light weight ONLY          │
│    Updates: Bid/Ask labels (2 objects, < 5μs)                          │
│                                                                          │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│                                                                          │
│  Timer 1: OnTimer() — 1 second (Standard)                                │
│  ────────────────────────────────────────                                │
│  • UpdateHeatCache()          [Phase 6]                                 │
│  • CheckHeatLimits()          [Phase 6]                                 │
│  • CheckSpreadGuard()         [Phase 6]                                 │
│  • CheckMarginGuard()         [Phase 6]                                 │
│  • CheckAutoResumeConditions() [Phase 6]                                │
│  • Adoption_ExecuteScan()     [Phase 2]                                 │
│  • UpdateCheckpointSystem()   [Phase 5]                                 │
│  • ManageEmergencyStops()     [Phase 5]                                 │
│  • Dashboard_Update()         [Phase 7] ← Full update                  │
│  • SSoT_SyncDashboardToGlobals() [Phase 1]                              │
│                                                                          │
│  Timer 2: OnTimerMQL() — 200 milliseconds (Millisecond Timer)           │
│  ─────────────────────────────────────────────────────────────         │
│  • Dashboard_UpdateLiveMetrics()  [Phase 7] ← NEAR-REAL-TIME           │
│    Updates: P&L, Drawdown, Price ( Bid/Ask from cache)                 │
│    Cost: < 1ms per 200ms cycle                                        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Why Millisecond Timer?

| Metric | 1-Second Update | 200ms Update | Improvement |
|--------|-----------------|--------------|-------------|
| P&L visibility latency | 1,000ms | 200ms | **5× faster** |
| Drawdown reaction time | 1,000ms | 200ms | **5× faster** |
| CPU overhead | ~0.1% | ~0.3% | Acceptable |
| User perception | "Slow" | "Real-time" | ✅ Target met |

**Implementation:**
```cpp
int OnInit()
{
    EventSetTimer(1);                    // Main system logic: 1 second
    EventSetMillisecondTimer(200);       // Dashboard live metrics: 200ms
    // ...
}

void OnTimer()        // 1-second standard timer
{
    // All system logic (heat, adoption, safety, checkpoints)
    // Dashboard full update (all sections)
}

void OnTimer()        // 200-millisecond millisecond timer (MQL5 syntax)
{
    // Only live metrics: P&L, DD, Price
    Dashboard_UpdateLiveMetrics();
}
```

> **Note:** In MQL5, both standard timer and millisecond timer use `void OnTimer()`. The framework distinguishes by the timer type set in `OnInit()`. Alternatively, use a single millisecond timer and count cycles (every 5th = 1s for system logic).

### 1.3 Simplified Single-Timer Alternative

If millisecond timer is unavailable or causes issues:

```cpp
void OnTimer()  // Set to 200ms via EventSetMillisecondTimer(200)
{
    static int cycleCount = 0;
    cycleCount++;
    
    // Live metrics: EVERY cycle (200ms)
    Dashboard_UpdateLiveMetrics();
    
    // System logic: EVERY 5th cycle (1 second)
    IF (cycleCount >= 5)
    {
        cycleCount = 0;
        CheckHeatLimits();
        CheckSpreadGuard();
        CheckMarginGuard();
        Adoption_ExecuteScan();
        UpdateCheckpointSystem();
        ManageEmergencyStops();
        Dashboard_Update();          // Full dashboard update
        SSoT_SyncDashboardToGlobals();
    }
}
```

**Recommendation:** Use **single 200ms millisecond timer** with cycle counting. Simpler, one callback, achieves all goals.

---

## 2. DASHBOARD LAYOUT SPECIFICATION (REVISED v2.0)

### 2.1 Position & Dimensions

| Property | Value | Notes |
|----------|-------|-------|
| Position | Top-Right corner | `x = ChartWidth - PanelWidth - 10`, `y = 10` |
| Panel Width | 320 pixels | Expanded from 280px for controls |
| Panel Height | Variable (auto) | Expands/contracts based on content |
| Maximum Height | 450 pixels | Scroll or collapse if exceeded |
| Background | `clrBlack` (85% opacity) | Slightly darker for Command Center |
| Border | 1 pixel, `clrSteelBlue` | Distinctive blue border |
| Font | "Segoe UI", 8pt | Clean, readable |
| Update Intervals | 200ms (live) / 1s (full) | Dual-speed updates |

### 2.2 Visual Structure (v2.0)

```
┌────────────────────────────────────────────────┐
│  SIDEWAY KILLER  v2.0  COMMAND CENTER    [X]   │  ← Header
├────────────────────────────────────────────────┤
│  💰 LIVE METRICS                               │  ← NEW: Section 0
│  Bid: 2048.35  Ask: 2048.62  Spread: 27        │
│  P&L: +$127.50  DD: 2.3%  Equity: $10,127.50   │
├────────────────────────────────────────────────┤
│  🔥 HEAT MONITOR                               │  ← Section 1
│  Total:  8.5%  [████████░░]  🟠 WARN           │
│  B1:4.2%🟢  B2:0.0%🟢  B3:4.3%🟢              │
├────────────────────────────────────────────────┤
│  📈 TRAILING TRACKER                           │  ← Section 2
│  #1 ▲  Peak: 2049.00  Stop: 2048.45            │
│        Trail: 45pts  Locked: $12.50            │
│        Current: $45.00  Max: $67.00            │
├────────────────────────────────────────────────┤
│  📊 PERFORMANCE METRICS                        │  ← Section 3
│  Win Rate: 67.5%   α:23  β:11   Bayesian       │
│  Spread:  28 / 100    ATR: 42.5   DVASS 1.5×   │
├────────────────────────────────────────────────┤
│  🎮 TRADE CONTROLS                             │  ← NEW: Section 4
│  [  BUY  ]  Lot: 0.10  [  SELL  ]              │
│  Magic: 888  Auto-Adopt: ON                    │
├────────────────────────────────────────────────┤
│  🚨 EMERGENCY CONTROLS                         │  ← NEW: Section 5
│  [    CLOSE ALL BASKETS    ]                   │
├────────────────────────────────────────────────┤
│  ℹ️ SYSTEM STATUS                              │  ← Section 6
│  Active: 3 baskets   Uptime: 02:34:18          │
│  🟢 Trading Active  •  09:42:15                │
└────────────────────────────────────────────────┘
```

### 2.3 Section Breakdown (v2.0)

| Section | Height | Visible | Update Freq | Data Source |
|---------|--------|---------|-------------|-------------|
| **0. Live Metrics** | 50px | ✅ Always | **200ms** | `SymbolInfo`, `g_*` cache |
| 1. Heat Monitor | 50px | ✅ Always | 1s | `g_totalHeat`, `g_heatCache[]` |
| 2. Trailing Tracker | 60px/basket | Conditional | 1s | `g_virtualTrail[]` |
| 3. Performance Metrics | 50px | ✅ Always | 5s | `g_tradeStats`, `g_market` |
| **4. Trade Controls** | 45px | ✅ Always | Static | Input parameters |
| **5. Emergency** | 30px | ✅ Always | Static | Button only |
| 6. System Status | 40px | ✅ Always | 1s | `g_*` halt states |

---

## 3. SECTION 0: LIVE METRICS (NEW)

### 3.1 Purpose

The Live Metrics section provides **instant situational awareness** — the most critical numbers visible at a glance without scanning the entire panel.

### 3.2 Layout

```
💰 LIVE METRICS
Bid: 2048.35   Ask: 2048.62   Spread: 27
P&L: +$127.50  DD: 2.3%  Equity: $10,127.50
```

### 3.3 Components Specification

| Element | Object Type | Data Source | Update Freq | Color Logic |
|---------|-------------|-------------|-------------|-------------|
| Bid Price | `OBJ_LABEL` | `SymbolInfoDouble(SYMBOL_BID)` | **200ms** | White |
| Ask Price | `OBJ_LABEL` | `SymbolInfoDouble(SYMBOL_ASK)` | **200ms** | White |
| Spread | `OBJ_LABEL` | `SYMBOL_SPREAD` | **200ms** | Green <60, Orange 60-80, Red >80 |
| P&L | `OBJ_LABEL` | Calculated from cache | **200ms** | **Green if +, Red if -, Gold if > target** |
| Drawdown % | `OBJ_LABEL` | `g_totalHeat` | **200ms** | Green <5%, Orange 5-10%, Red >10% |
| Equity | `OBJ_LABEL` | `AccountInfoDouble(ACCOUNT_EQUITY)` | **200ms** | White |

### 3.4 P&L Calculation

```
FUNCTION CalculateTotalFloatingPnL()
    
    totalPnL = 0.0
    
    FOR i = 0 TO g_basketCount - 1:
        IF (NOT g_baskets[i].isValid)
            CONTINUE
        
        basket = g_baskets[i]
        
        // Get current price
        IF (basket.direction == BUY)
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID)
        ELSE
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
        
        // Calculate P&L for this basket
        IF (basket.direction == BUY)
            priceDiff = currentPrice - basket.weightedAvg
        ELSE
            priceDiff = basket.weightedAvg - currentPrice
        
        basketPnL = priceDiff × basket.totalVolume × 100.0
        totalPnL += basketPnL
    END FOR
    
    RETURN totalPnL
    
END FUNCTION
```

### 3.5 P&L Color Logic

```
IF (pnl > 0 AND pnl > totalTargetProfit)
    color = clrGold        // Exceeded all targets — exceptional
ELSE IF (pnl > 0)
    color = clrLimeGreen   // Profitable
ELSE IF (pnl == 0)
    color = clrWhiteSmoke  // Breakeven
ELSE IF (pnl > -totalTargetProfit)
    color = clrOrange      // Small loss — recoverable
ELSE
    color = clrCrimson     // Significant loss
END IF
```

### 3.6 Drawdown Display

```
DD: 2.3%
```

**Note:** This is the **Total Heat** (portfolio drawdown) from Phase 6, displayed as an explicit percentage. It complements the Heat Monitor section below with a large, prominent number.

### 3.7 Live Metrics Update Function (200ms)

```
FUNCTION Dashboard_UpdateLiveMetrics()
    
    // ── Row 1: Price Data ──
    bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
    ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
    spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
    
    UpdateLabelIfChanged("SK_Dash_Live_Bid", "Bid: " + DoubleToString(bid, 2))
    UpdateLabelIfChanged("SK_Dash_Live_Ask", "Ask: " + DoubleToString(ask, 2))
    UpdateLabelIfChanged("SK_Dash_Live_Spread", "Spread: " + IntegerToString(spread))
    SetLabelColor("SK_Dash_Live_Spread", GetSpreadColor(spread))
    
    // ── Row 2: Portfolio Metrics ──
    pnl = CalculateTotalFloatingPnL()
    dd = g_totalHeat
    equity = AccountInfoDouble(ACCOUNT_EQUITY)
    
    UpdateLabelIfChanged("SK_Dash_Live_PnL", 
                         "P&L: " + FormatCurrency(pnl))
    SetLabelColor("SK_Dash_Live_PnL", GetPnLColor(pnl))
    
    UpdateLabelIfChanged("SK_Dash_Live_DD",
                         "DD: " + DoubleToString(dd, 1) + "%")
    SetLabelColor("SK_Dash_Live_DD", GetHeatColor(dd))
    
    UpdateLabelIfChanged("SK_Dash_Live_Equity",
                         "Equity: " + FormatCurrency(equity))
    
END FUNCTION
```

---

## 4. SECTION 4: TRADE CONTROLS (NEW)

### 4.1 Purpose

Provides **manual trade execution** directly from the dashboard. Orders are placed with the adoption system's target magic number, ensuring automatic adoption by Phase 2.

### 4.2 Layout

```
🎮 TRADE CONTROLS
[  BUY  ]  Lot: 0.10  [  SELL  ]
Magic: 888  Auto-Adopt: ON
```

### 4.3 Input Parameters

```cpp
input group "=== MANUAL TRADE CONTROLS ==="
input double inpManualLotSize = 0.10;        // Default lot size for manual trades
input ulong  inpManualMagicNumber = 888;     // Magic number for manual trades
input bool   inpManualAutoAdopt = true;      // Auto-adopt manual trades
input string inpManualTradeComment = "MANUAL"; // Comment for manual trades
```

### 4.4 BUY Button

**Visual:**
```
┌──────────┐
│   BUY    │  ← Background: clrForestGreen, Text: White, Bold
└──────────┘     Size: 60px × 25px
```

**On Click:**
```
FUNCTION OnBuyButtonClick()
    
    // Prepare market order
    MqlTradeRequest request = {}
    MqlTradeResult result = {}
    
    request.action = TRADE_ACTION_DEAL
    request.symbol = _Symbol
    request.volume = inpManualLotSize
    request.type = ORDER_TYPE_BUY
    request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
    request.deviation = 10                      // 10 points slippage
    request.magic = inpManualMagicNumber        // 888 — matches adoption target
    request.comment = inpManualTradeComment
    
    // Send order
    IF (OrderSend(request, result))
        Print("BUY order executed: ", result.order,
              " Volume: ", inpManualLotSize,
              " Price: ", result.price)
        
        Alert("BUY " + DoubleToString(inpManualLotSize, 2) + 
              " lot executed at " + DoubleToString(result.price, 2))
    ELSE
        Print("BUY order FAILED: ", GetLastError())
        Alert("BUY order FAILED — check terminal journal")
    END IF
    
END FUNCTION
```

### 4.5 SELL Button

**Visual:**
```
┌──────────┐
│   SELL   │  ← Background: clrCrimson, Text: White, Bold
└──────────┘     Size: 60px × 25px
```

**On Click:**
```
FUNCTION OnSellButtonClick()
    
    MqlTradeRequest request = {}
    MqlTradeResult result = {}
    
    request.action = TRADE_ACTION_DEAL
    request.symbol = _Symbol
    request.volume = inpManualLotSize
    request.type = ORDER_TYPE_SELL
    request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID)
    request.deviation = 10
    request.magic = inpManualMagicNumber
    request.comment = inpManualTradeComment
    
    IF (OrderSend(request, result))
        Print("SELL order executed: ", result.order,
              " Volume: ", inpManualLotSize,
              " Price: ", result.price)
        
        Alert("SELL " + DoubleToString(inpManualLotSize, 2) + 
              " lot executed at " + DoubleToString(result.price, 2))
    ELSE
        Print("SELL order FAILED: ", GetLastError())
        Alert("SELL order FAILED — check terminal journal")
    END IF
    
END FUNCTION
```

### 4.6 Auto-Adopt Compatibility

**How it works:**
1. User clicks BUY/SELL
2. Order executes with `magic = 888`
3. Phase 2 Adoption system scans positions every 1 second
4. Position matches: `magic == 888` AND `symbol == XAUUSD`
5. Position is in loss (likely, due to spread)
6. Drawdown < 2%
7. ✅ **Basket automatically created** with this position as Level 0

**Visual Confirmation:**
```
After BUY click:
🎮 TRADE CONTROLS
[  BUY  ]  Lot: 0.10  [  SELL  ]
Magic: 888  Auto-Adopt: ON  ✅ Order #12345 placed
```

### 4.7 Lot Size Input

**Visual:** An `OBJ_EDIT` field showing current lot size, editable by user.

```
┌────────┐
│  0.10  │  ← Editable field
└────────┘
```

**Behavior:**
- User can click and type new lot size
- On change: validate against broker constraints (min/max/step)
- Invalid input: revert to last valid value
- Valid input: update `inpManualLotSize`

```
FUNCTION OnLotSizeChange(newValue)
    
    lot = StringToDouble(newValue)
    normalizedLot = NormalizeLot(lot)
    
    IF (normalizedLot > 0)
        inpManualLotSize = normalizedLot
        UpdateEditField("SK_Dash_Trade_LotInput", DoubleToString(normalizedLot, 2))
    ELSE
        // Revert to previous value
        UpdateEditField("SK_Dash_Trade_LotInput", DoubleToString(inpManualLotSize, 2))
    END IF
    
END FUNCTION
```

---

## 5. SECTION 5: EMERGENCY CONTROLS (NEW)

### 5.1 Purpose

One-click **manual intervention** to close all active baskets. Used when:
- User wants to take all profits/losses immediately
- Market conditions change unexpectedly
- System behavior requires human override

### 5.2 Layout

```
🚨 EMERGENCY CONTROLS
[    CLOSE ALL BASKETS    ]
```

### 5.3 CLOSE ALL Button

**Visual:**
```
┌─────────────────────────┐
│    CLOSE ALL BASKETS    │  ← Background: clrDarkRed
└─────────────────────────┘     Text: White, Bold, 9pt
        Size: 200px × 28px
```

**Safety Features:**
1. **Double-Click Required:** First click highlights, second click executes
2. **Confirmation Alert:** Pop-up confirmation before execution
3. **Status Feedback:** Button text changes to "CLOSING..." during execution

### 5.4 Execution Logic

```
FUNCTION OnCloseAllButtonClick()
    
    STATIC bool firstClick = false
    STATIC datetime firstClickTime = 0
    
    IF (NOT firstClick)
        // First click — arm the button
        firstClick = true
        firstClickTime = TimeCurrent()
        
        SetButtonText("SK_Dash_Emergency_CloseAll", "CLICK AGAIN TO CONFIRM")
        SetButtonColor("SK_Dash_Emergency_CloseAll", clrRed)
        
        // Auto-disarm after 5 seconds
        RETURN
    END IF
    
    // Check if within 5-second confirmation window
    IF (TimeCurrent() - firstClickTime > 5)
        // Expired — reset
        firstClick = false
        SetButtonText("SK_Dash_Emergency_CloseAll", "CLOSE ALL BASKETS")
        SetButtonColor("SK_Dash_Emergency_CloseAll", clrDarkRed)
        RETURN
    END IF
    
    // ═══════════════════════════════════════════════════
    // EXECUTE CLOSE ALL
    // ═══════════════════════════════════════════════════
    firstClick = false
    SetButtonText("SK_Dash_Emergency_CloseAll", "CLOSING...")
    
    Print("EMERGENCY CLOSE ALL initiated by user")
    Alert("CLOSING ALL BASKETS — Please wait...")
    
    closedCount = 0
    failedCount = 0
    
    FOR i = g_basketCount - 1 DOWNTO 0:
        
        IF (NOT g_baskets[i].isValid)
            CONTINUE
        
        IF (g_baskets[i].status == BASKET_ACTIVE)
            
            // Attempt to close basket
            IF (CloseBasket(i))
                closedCount++
                Print("Basket ", i, " closed successfully")
            ELSE
                failedCount++
                Print("ERROR: Basket ", i, " failed to close")
            END IF
            
        END IF
    END FOR
    
    // Reset button
    SetButtonText("SK_Dash_Emergency_CloseAll", "CLOSE ALL BASKETS")
    SetButtonColor("SK_Dash_Emergency_CloseAll", clrDarkRed)
    
    // Report
    Alert("CLOSE ALL COMPLETE: ", closedCount, " closed, ", failedCount, " failed")
    Print("Emergency Close All: ", closedCount, " baskets closed, ", failedCount, " failed")
    
END FUNCTION
```

### 5.5 CloseBasket() Implementation

```
FUNCTION CloseBasket(basketIndex)
    
    basket = g_baskets[basketIndex]
    
    // Flag as closing
    g_baskets[basketIndex].status = BASKET_CLOSING
    SSoT_UpdateBasketStatus(basketIndex, BASKET_CLOSING)
    
    // Close all positions
    allClosed = true
    
    FOR level = basket.levelCount - 1 DOWNTO 0:
        
        ticket = basket.levels[level].ticket
        
        IF (NOT ClosePosition(ticket))
            allClosed = false
            Print("Failed to close position ", ticket, " in basket ", basketIndex)
        END IF
    END FOR
    
    IF (allClosed)
        g_baskets[basketIndex].status = BASKET_CLOSED
        g_baskets[basketIndex].isValid = false
        SSoT_UpdateBasketStatus(basketIndex, BASKET_CLOSED)
        RETURN true
    ELSE
        RETURN false
    END IF
    
END FUNCTION
```

### 5.6 Emergency During Halt States

The CLOSE ALL button **always works**, even when trading is halted:

```
FUNCTION IsCloseAllAllowed()
    
    // Close All is ALWAYS allowed — it's manual override
    RETURN true
    
END FUNCTION
```

---

## 6. ONCHARTEVENT HANDLER (Button Interactions)

### 6.1 Event Routing

```cpp
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
    // Button click events
    IF (id == CHARTEVENT_OBJECT_CLICK)
    {
        IF (sparam == "SK_Dash_Trade_BuyBtn")
            OnBuyButtonClick()
        
        ELSE IF (sparam == "SK_Dash_Trade_SellBtn")
            OnSellButtonClick()
        
        ELSE IF (sparam == "SK_Dash_Emergency_CloseAll")
            OnCloseAllButtonClick()
        
        ELSE IF (sparam == "SK_Dash_CloseBtn")
            OnDashboardCloseClick()
    }
    
    // Edit field change events
    ELSE IF (id == CHARTEVENT_OBJECT_ENDEDIT)
    {
        IF (sparam == "SK_Dash_Trade_LotInput")
            OnLotSizeChange(ObjectGetString(0, sparam, OBJPROP_TEXT))
    }
    
    // Chart resize
    ELSE IF (id == CHARTEVENT_CHART_CHANGE)
    {
        Dashboard_Reposition()
    }
}
```

---

## 7. REVISED PERFORMANCE BUDGET

### 7.1 Object Count Estimate (v2.0)

| Section | Objects | Notes |
|---------|---------|-------|
| Panel + Header | 5 | Background, title, version, symbol, close button |
| **Live Metrics (NEW)** | 8 | Bid, Ask, Spread, P&L, DD, Equity, labels, icons |
| Heat Monitor | 12 | Icon, label, value, bar (2), status, 5 basket indicators |
| Trailing Tracker | 10/basket | Header + 9 data fields per basket |
| Performance Metrics | 10 | 5 labels × 2 rows |
| **Trade Controls (NEW)** | 6 | BUY btn, SELL btn, lot input, magic label, adopt label |
| **Emergency (NEW)** | 1 | CLOSE ALL button |
| System Status | 6 | Status text, dot, baskets, levels, uptime, timestamp |
| **Total (3 baskets, 1 trailing)** | **~70 objects** | Expanded from 50 |

### 7.2 Update Latency Budget

| Operation | Frequency | Cost | Notes |
|-----------|-----------|------|-------|
| Live Metrics update | 200ms | ~200 μs | 8 labels, mostly text changes |
| Price refresh (Bid/Ask) | 200ms | ~50 μs | 2 SymbolInfo calls |
| P&L calculation | 200ms | ~100 μs | Simple arithmetic on cache |
| Full dashboard update | 1s | ~1,500 μs | All sections, all objects |
| SSoT GV sync | 1s | ~2,000 μs | 8 GV writes |
| **Total 200ms cycle** | **~350 μs** | **< 1ms** | ✅ Well within budget |
| **Total 1s cycle** | **~2,000 μs** | **< 3ms** | ✅ Within 5ms budget |

### 7.3 CPU Impact

| Timer | Interval | CPU Load | Purpose |
|-------|----------|----------|---------|
| Millisecond Timer | 200ms | ~0.15% | Live metrics only |
| Standard Timer | 1s | ~0.05% | Full system logic |
| **Combined** | — | **~0.20%** | **Negligible** |

---

## 8. REVISED OBJECT NAMING CONVENTION

### 8.1 New Objects (v2.0)

```
// Live Metrics
SK_Dash_Live_Bid          // Bid price label
SK_Dash_Live_Ask          // Ask price label
SK_Dash_Live_Spread       // Spread label
SK_Dash_Live_PnL          // P&L label
SK_Dash_Live_DD           // Drawdown label
SK_Dash_Live_Equity       // Equity label

// Trade Controls
SK_Dash_Trade_BuyBtn      // BUY button (OBJ_BUTTON)
SK_Dash_Trade_SellBtn     // SELL button (OBJ_BUTTON)
SK_Dash_Trade_LotInput    // Lot size input (OBJ_EDIT)
SK_Dash_Trade_MagicLabel  // Magic number display
SK_Dash_Trade_AdoptLabel  // Auto-adopt status

// Emergency Controls
SK_Dash_Emergency_CloseAll // CLOSE ALL button (OBJ_BUTTON)
```

---

## 9. SAFETY & VALIDATION

### 9.1 Trade Button Safeguards

| Check | Behavior on Failure |
|-------|---------------------|
| Trading halted (spread/margin) | Allow trade but show warning: "⚠️ Trading halted — order may not be adopted" |
| Max baskets reached | Block order: "❌ Max baskets reached" |
| Invalid lot size | Revert to last valid lot size |
| `OrderSend()` fails | Alert user with error code |
| Duplicate click (< 1s) | Ignore second click |

### 9.2 CLOSE ALL Safeguards

| Check | Behavior |
|-------|----------|
| Double-click required | First click arms, second executes |
| 5-second timeout | Auto-disarm if no second click |
| No active baskets | Alert: "No active baskets to close" |
| Partial close failure | Alert: "X closed, Y failed — check positions" |
| Button state during execution | Shows "CLOSING..." to prevent double-trigger |

---

## 10. DECISION LOG (v2.0)

| Decision | Rationale | Source |
|----------|-----------|--------|
| Millisecond timer (200ms) | Captain's "near-real-time" requirement | User requirement |
| Single timer with cycle counting | Simpler than dual timer callbacks | §1.3 |
| P&L at top of panel | Most important metric, needs highest visibility | User requirement |
| BUY/SELL buttons with magic 888 | Matches Phase 2 adoption criteria | §4.6 |
| Lot size editable field | User flexibility | §4.7 |
| Double-click CLOSE ALL | Prevents accidental clicks | §5.3 |
| 5-second confirmation timeout | Safety without being annoying | §5.3 |
| CLOSE ALL bypasses halt states | Manual override must always work | §5.6 |
| Auto-adopt ON by default | Seamless workflow | §4.6 |
| 320px panel width | Accommodates trade buttons | §2.1 |

---

## 11. CHANGE SUMMARY (v1.0 → v2.0)

| Section | v1.0 | v2.0 |
|---------|------|------|
| **Live Metrics** | ❌ Not present | ✅ Bid/Ask/Spread/P&L/DD/Equity at top |
| **Update Frequency** | 1 second | **200ms** for live metrics |
| **Trade Controls** | ❌ None | ✅ BUY/SELL buttons with lot input |
| **Emergency** | Status display only | ✅ CLOSE ALL button with double-click |
| **Panel Width** | 280px | **320px** |
| **Object Count** | ~50 | **~70** |
| **Interactions** | Close button only | **BUY, SELL, Lot edit, CLOSE ALL** |
| **OnChartEvent** | Resize only | **Button clicks, edit changes, resize** |

---

## 12. AUDIT CHECKLIST (FOR GLM-4.7) — v2.0

- [ ] Live Metrics section displays all 6 required values (Bid, Ask, Spread, P&L, DD, Equity)
- [ ] P&L updates every 200ms via millisecond timer
- [ ] P&L color changes based on profit/loss magnitude
- [ ] DD color matches Phase 6 heat thresholds
- [ ] BUY button executes market order with magic 888
- [ ] SELL button executes market order with magic 888
- [ ] Lot size field validates against broker constraints
- [ ] CLOSE ALL requires double-click with 5s timeout
- [ ] CLOSE ALL works even during trading halts
- [ ] Millisecond timer approach is cold-path (not OnTick)
- [ ] Object naming convention prevents collisions
- [ ] Performance budget < 1ms per 200ms cycle
- [ ] OnChartEvent handler routes all button clicks
- [ ] No hot-path dashboard operations

---

## 13. APPROVAL SIGNATURES

| Role | Name | Status | Date |
|------|------|--------|------|
| Architect | KIMI-K2 | ✅ Delivered v2.0 | 2026-04-09 |
| QA Auditor | GLM-4.7 | ⏳ Pending Audit | — |
| Project Lead (Captain) | User | ⏳ Pending Approval | — |

---

**END OF PHASE 7 DASHBOARD UI SPECIFICATION (REVISED v2.0 — COMMAND CENTER)**

*This document supersedes all previous Phase 7 specifications. No files shall be modified pending audit and sign-off.*
