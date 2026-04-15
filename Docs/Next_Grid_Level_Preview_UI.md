BLUEPRINT: Next Grid Level Preview UI Enhancement
1. Executive Summary
Scope: Add per-basket "Next Grid Distance" and "Next Grid Lot" fields to the dashboard.
Complexity: MEDIUM — requires new dashboard section creation, dynamic object lifecycle management, and real-time integration with SK_Grid.mqh and SK_LotMultiplier.mqh.
Constraint: The current dashboard panel (DASH_PANEL_HEIGHT = 380) has no existing per-basket info panel. A new expandable "Active Baskets" section must be created.

2. Current State Analysis
2.1 Dashboard Layout (Y-Axis usage)
Section	Start Y	Height Used
Header	+3	~20px
Live Metrics	+30	~55px
Heat Monitor	+90	~40px
Trailing Tracker	+135	~40px
Performance Metrics	+180	~40px
Trade Controls	+225	~50px
Emergency Controls	+280	~30px
System Status	+330	~40px
Total	—	~315px used / 380px available
Finding: Only ~65px of vertical space remains. A multi-line basket list will not fit inside the current 380px panel.

2.2 Existing Basket Display
None. The dashboard currently shows only aggregate P&L and a single-line trailing tracker.
The function Dashboard_UpdateBasketInfo() does not exist in SK_Dashboard.mqh.
2.3 Relevant Calculation APIs
Metric	Source Function	File	Parameters
Next Grid Distance	GetGridDistance(basketIndex, nextLevel)	SK_Grid.mqh	nextLevel = g_baskets[i].levelCount
Next Grid Trigger Price	Grid_CalculateNextTriggerPrice(basketIndex)	SK_Grid.mqh	Returns absolute price (already exists)
Next Grid Lot	GetLotMultiplier(basketIndex, nextLevel)	SK_LotMultiplier.mqh	nextLevel = g_baskets[i].levelCount
Normalized Lot	Lot_Normalize(lot)	SK_LotMultiplier.mqh	Applies broker step constraints
3. Proposed Architecture
3.1 Visual Design
Create a new section [BASKETS] ACTIVE RECOVERY inserted between Live Metrics and Heat Monitor.

Per-basket row format:

#744 BUY L2 | DD:$12.34 | NextGrid: 689.5pts @ 0.08lot
#745 SELL L1 | DD:$5.67 | NextGrid: 452.0pts @ 0.05lot
Fields per row:

BasketID — e.g., #744
Direction — BUY or SELL
LevelCount — L2 (current levels)
Drawdown — $12.34
NEW: NextGridDist — 689.5pts
NEW: NextGridLot — 0.08lot
3.2 Panel Sizing
Increase DASH_PANEL_HEIGHT from 380 to 460 to accommodate up to 3 active baskets.
Rationale: Inp_MaxConcurrentBaskets = 3 (default), so the UI must support 3 rows.

Revised Y-Layout:

Section	Start Y
Header	+3
Live Metrics	+30
Active Baskets	+90
Heat Monitor	+180
Trailing Tracker	+225
Performance Metrics	+270
Trade Controls	+315
Emergency Controls	+370
System Status	+420
4. Implementation Blueprint
4.1 New Constants & Object Naming
//--- In SK_Dashboard.mqh, add:
#define DASH_OBJ_BASKET    "SK_Dash_Basket_"
#define DASH_MAX_BASKET_ROWS 3   // Matches Inp_MaxConcurrentBaskets
4.2 New Functions to Create
A. Dashboard_CreateBasketInfo()
Purpose: Initialize the section header and dynamic basket rows.
Location: Call from Dashboard_Init(), between Dashboard_CreateLiveMetrics() and Dashboard_CreateHeatMonitor().

Logic:

Create section header label: [BASKETS] ACTIVE RECOVERY
Pre-create up to DASH_MAX_BASKET_ROWS label objects:
Name pattern: DASH_OBJ_BASKET + "Row_" + i
Default text: "" (empty, hidden when no basket)
Position: left = g_dashBaseX - DASH_MARGIN_LEFT, row = baseY + 108 + (i * DASH_ROW_HEIGHT)
B. Dashboard_UpdateBasketInfo()
Purpose: Populate real-time grid preview data for every active basket.
Location: Call from Dashboard_TimerCycle() (1-second update) and optionally from Dashboard_UpdateLiveMetrics() for faster refresh.

Pseudocode:

void Dashboard_UpdateBasketInfo()
{
   int rowCount = 0;
   
   for(int i = 0; i < g_basketCount; i++)
   {
      if(!g_baskets[i].isValid || g_baskets[i].status != BASKET_ACTIVE)
         continue;
      if(rowCount >= DASH_MAX_BASKET_ROWS)
         break;
      
      //--- Calculate Next Grid Distance
      int nextLevel = g_baskets[i].levelCount;
      double nextGridDist = GetGridDistance(i, nextLevel);
      
      //--- Calculate Next Grid Lot
      double multiplier = GetLotMultiplier(i, nextLevel);
      double baseLot = g_baskets[i].levels[0].lotSize;
      double nextLot = Lot_Normalize(baseLot * multiplier);
      
      //--- Calculate drawdown for context
      double basketDD = Safety_GetBasketHeat(i);  // or use heatCache directly
      
      string objName = DASH_OBJ_BASKET + "Row_" + rowCount;
      string text = "#" + (string)g_baskets[i].basketId + " " +
                    (g_baskets[i].direction == 0 ? "BUY" : "SELL") + " L" + (string)(nextLevel) +
                    " | DD:" + DoubleToString(basketDD, 1) + "%" +
                    " | Next:" + DoubleToString(nextGridDist, 1) + "pts" +
                    " @ " + DoubleToString(nextLot, 2) + "lot";
      
      ObjectSetString(0, objName, OBJPROP_TEXT, text);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clrWhite);
      rowCount++;
   }
   
   //--- Hide unused rows
   for(int i = rowCount; i < DASH_MAX_BASKET_ROWS; i++)
   {
      ObjectSetString(0, DASH_OBJ_BASKET + "Row_" + i, OBJPROP_TEXT, "");
   }
}
C. Dashboard_RemoveBasketInfo()
Purpose: Clean up dynamic objects on deinit.
Location: Call from Dashboard_RemoveAll() or Dashboard_Deinit().

Logic:

for(int i = 0; i < DASH_MAX_BASKET_ROWS; i++)
   ObjectDelete(0, DASH_OBJ_BASKET + "Row_" + i);
5. Integration Points
5.1 Dashboard_Init() Modification
Add Dashboard_CreateBasketInfo(); after Dashboard_CreateLiveMetrics();.

5.2 Dashboard_TimerCycle() Modification
Add Dashboard_UpdateBasketInfo(); inside the 1-second block:

if(g_dashCycleCount >= DASH_CYCLES_PER_SECOND)
{
   // ... existing logic ...
   Dashboard_UpdateBasketInfo();   // NEW
   Dashboard_FullUpdate();
}
5.3 Dashboard_Deinit() / Dashboard_RemoveAll() Modification
Ensure basket row objects are deleted. Since Dashboard_RemoveAll() already deletes all SK_Dash_* prefixed objects, no extra work is needed provided the new objects use the DASH_OBJ_BASKET prefix.

6. Technical Considerations & Risks
6.1 DVASS Dynamic Update
Requirement: "Next Grid Dist" must update in real-time if ATR changes.
Solution: GetGridDistance() reads from g_gridCachedATR14, which is refreshed every 1 second by Grid_RefreshCache() inside Dashboard_TimerCycle(). The 1-second update frequency of Dashboard_UpdateBasketInfo() is sufficient for DVASS mode.

6.2 Lot Calculation Accuracy
Risk: GetLotMultiplier() returns the multiplier, not final lot size.
Mitigation: The blueprint explicitly multiplies by g_baskets[i].levels[0].lotSize and passes through Lot_Normalize() to match the exact lot that Grid_AddLevel() would send to the broker.

6.3 Heat Constraint Visibility
Risk: If heat throttling is active, GetLotMultiplier() already applies the heat constraint internally. The dashboard will correctly show the reduced lot size.
Enhancement opportunity: Change the lot color to clrOrange or clrYellow when heat-constrained to provide visual feedback.

6.4 Panel Overflow
Risk: If Inp_MaxConcurrentBaskets > 3, rows could exceed panel height.
Mitigation: Cap displayed rows at DASH_MAX_BASKET_ROWS = 3 and add a "+N more" indicator if exceeded.

6.5 Object Lifecycle
Risk: If basket compaction changes indices between Create and Update, row text might briefly flicker.
Mitigation: The loop reads directly from g_baskets[] during UpdateBasketInfo(), using the current compacted indices. No caching of basket IDs is needed.

7. Files to Modify
File	Changes
SK_Dashboard.mqh	Add constants, Dashboard_CreateBasketInfo(), Dashboard_UpdateBasketInfo(), integrate into Init/TimerCycle/RemoveAll, increase DASH_PANEL_HEIGHT
SK_Grid.mqh	No changes required — GetGridDistance() is already public
SK_LotMultiplier.mqh	No changes required — GetLotMultiplier() and Lot_Normalize() are already public
8. Acceptance Criteria
 New [BASKETS] ACTIVE RECOVERY section appears below Live Metrics.
 Each active basket displays: ID, Direction, Levels, Drawdown, NextGridDist, NextGridLot.
 NextGridDist updates automatically when ATR changes (DVASS mode).
 NextGridLot reflects current mode: FIXED, BAYESIAN, or HYBRID.
 Empty rows are hidden when basket count is below max.
 Panel height expanded to prevent clipping.
 No memory leaks (objects cleaned up on deinit).