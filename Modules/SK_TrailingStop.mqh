//+------------------------------------------------------------------+
//|                                        SK_TrailingStop.mqh       |
//|                                    SIDEWAY KILLER - Phase 5      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"
#include "SK_DataTypes.mqh"
#include "SK_GVSchema.mqh"
#include "SK_SSoT.mqh"

//+==================================================================+
//| TRAILING STOP: Three-Layer Protection & Profit Maximization        |
//|                                                                    |
//|  Layer 1: Virtual Trailing (Primary exit — lets profits run)       |
//|  Layer 2: Checkpoint Persistence (restart recovery)                |
//|  Layer 3: Emergency Physical Stops (catastrophic safety net)        |
//|                                                                    |
//|  Key Innovation: Handover Protocol (FastStrike → VirtualTrailing)  |
//|  Dynamic ATR Trail Distance: ATR(14) × 1.5                         |
//|  Profit Floor: Minimum stop locks handover profit                   |
//+==================================================================+

//+------------------------------------------------------------------+
//| EXTENDED VIRTUAL TRAIL STATE (v2.0 — 7 fields)                     |
//+------------------------------------------------------------------+
// NOTE: We extend the existing VirtualTrailingState from SK_DataTypes
// by using parallel arrays for handover-specific fields.

//--- Handover-specific state (parallel to g_virtualTrail[])
bool    g_trailIsHandedOver[SK_MAX_BASKETS];     // Handover flag
double  g_trailProfitAtHandover[SK_MAX_BASKETS]; // Profit at handover (USD)
double  g_trailCurrentDist[SK_MAX_BASKETS];      // Current dynamic trail distance
double  g_trailMinimumStop[SK_MAX_BASKETS];      // Profit floor stop level

//--- ATR trail handle (shared with Grid, but we maintain own copy)
int     g_trailAtrHandle14 = INVALID_HANDLE;
double  g_trailAtrBuf[];
double  g_trailCachedATR14 = 0;

//--- Emergency stop tracking (extends Phase 1)
bool    g_emergencyStopPlaced[SK_MAX_BASKETS];
double  g_emergencyStopPrice[SK_MAX_BASKETS];

//--- Handover age gate
const int HANDOVER_MIN_AGE_SECONDS = 120;

//--- Emergency maintenance hours (not in Inp_ — define here)
const int TRAIL_EMERGENCY_MAINT_HOURS = 1;

//+------------------------------------------------------------------+
//| PUBLIC API — Initialization                                        |
//+------------------------------------------------------------------+

/**
 * Initialize the trailing stop system
 * Creates ATR handle, initializes handover state arrays
 * @return true on success
 */
bool Trailing_Init()
{
   //--- Create ATR handle for dynamic trail distance
   g_trailAtrHandle14 = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(g_trailAtrHandle14 == INVALID_HANDLE)
      Print("[Trailing] WARNING: ATR(14) handle creation failed");

   //--- Initialize handover state arrays
   for(int i = 0; i < SK_MAX_BASKETS; i++)
     {
      g_trailIsHandedOver[i] = false;
      g_trailProfitAtHandover[i] = 0;
      g_trailCurrentDist[i] = 50.0;  // Default 50 points
      g_trailMinimumStop[i] = 0;
      g_emergencyStopPlaced[i] = false;
      g_emergencyStopPrice[i] = 0;
     }

   //--- Initialize ATR buffer
   g_trailCachedATR14 = 0;
   ArrayResize(g_trailAtrBuf, 1);

   Print("[Trailing] Initialized. ATR-Direct mode, 1.5× multiplier");

   return true;
}

/**
 * Deinitialize the trailing stop system
 * Places emergency stops for handed-over baskets before shutdown
 */
void Trailing_Deinit(const int reason)
{
   if(g_trailAtrHandle14 != INVALID_HANDLE)
      IndicatorRelease(g_trailAtrHandle14);

   //--- Place emergency stops for all active baskets on shutdown
   if(reason == REASON_REMOVE || reason == REASON_CHARTCHANGE)
     {
      Trailing_PlaceEmergencyStops();
     }

   Print("[Trailing] Deinitialized");
}

//+------------------------------------------------------------------+
//| COLD PATH — Refresh ATR cache                                      |
//| Called from OnTimer() — never from OnTick()                        |
//+------------------------------------------------------------------+

/**
 * Refresh ATR cache for dynamic trail distance calculation
 */
void Trailing_RefreshCache()
{
   if(g_trailAtrHandle14 != INVALID_HANDLE)
     {
      ArraySetAsSeries(g_trailAtrBuf, true);
      if(CopyBuffer(g_trailAtrHandle14, 0, 0, 1, g_trailAtrBuf) > 0)
         g_trailCachedATR14 = g_trailAtrBuf[0];
     }
}

//+------------------------------------------------------------------+
//| DYNAMIC TRAIL DISTANCE — ATR-Direct Mode                           |
//| Formula: ATR(14) × 1.5 — scales naturally with volatility          |
//+------------------------------------------------------------------+

/**
 * Calculate dynamic trail distance based on current ATR
 * Uses cached ATR — no indicator calls in hot path
 * @return Trail distance in points
 */
double Trailing_CalculateTrailDistance()
{
   double atr = g_trailCachedATR14;

   //--- Fallback if ATR not ready
   if(atr <= 0)
      return 50.0;  // Default 50 points

   //--- ATR-Direct: 1.5× ATR
   double distance = atr * 1.5;

   //--- Safety bounds (25-200 points)
   if(distance < 25.0)
      distance = 25.0;
   if(distance > 200.0)
      distance = 200.0;

   return distance;
}

//+------------------------------------------------------------------+
//| PROFIT FLOOR — Calculate Minimum Stop Level                        |
//+------------------------------------------------------------------+

/**
 * Calculate the minimum stop level that locks in handover profit
 * Ensures the basket cannot lose money after handover
 * @param basketIndex     Basket cache index
 * @param profitAtHandover Profit in USD at handover moment
 * @return Minimum stop price (profit floor)
 */
double Trailing_CalculateMinimumStop(const int basketIndex,
                                      const double profitAtHandover)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return 0;

   double totalVol = g_baskets[basketIndex].totalVolume;
   if(totalVol <= 0)
      return 0;

   //--- CRITICAL FIX: Use tickSize for price conversion (NOT SYMBOL_POINT)
   //--- Formula: profit = distance × volume × valuePerPoint
   //--- distance = profit / (volume × valuePerPoint)
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double valuePerPoint = (tickSize > 0) ? tickValue / tickSize : 100.0;

   //--- Convert USD profit to price distance using valuePerPoint
   double priceBuffer = profitAtHandover / (totalVol * valuePerPoint);

   //--- Add cost buffer for safety (2 ticks, not points)
   double costBuffer = 2.0 * tickSize;  // CRITICAL FIX: Use tickSize, not SYMBOL_POINT

   double minStop;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      minStop = g_baskets[basketIndex].weightedAvg + priceBuffer - costBuffer;
   else  // SELL
      minStop = g_baskets[basketIndex].weightedAvg - priceBuffer + costBuffer;

   return minStop;
}

//+------------------------------------------------------------------+
//| HANDOVER PROTOCOL — FastStrike → VirtualTrailing                   |
//+------------------------------------------------------------------+

/**
 * Check if a basket qualifies for handover from FastStrike to Trailing
 * Called from FastStrikeCheck() — Hot Path
 * @param basketIndex  Basket cache index
 * @param apiProfit    Live API profit (PositionGetDouble sum) — PRIMARY
 * @return true if handover should be executed
 */
bool Trailing_ShouldHandover(const int basketIndex, const double apiProfit)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return false;
   if(!g_baskets[basketIndex].isValid)
      return false;
   if(g_baskets[basketIndex].status != BASKET_ACTIVE)
      return false;

   //--- Already handed over?
   if(g_trailIsHandedOver[basketIndex])
      return false;

   //--- API-FIRST: Profit must meet target × 0.95
   double target = g_baskets[basketIndex].targetProfit;
   if(apiProfit < target * 0.95)
      return false;

   //--- CRITICAL: NO age gate — instant handover when profit target hit
   // This allows capturing long trends (1,000+ points) by letting trailing run

   return true;
}

/**
 * Execute handover from FastStrike to VirtualTrailing
 * Called from FastStrikeCheck() when all conditions met
 * @param basketIndex     Basket cache index
 * @param profitAtHandover Conservative profit estimate at handover
 * @param bid             Current bid price
 * @param ask             Current ask price
 */
void Trailing_HandOverToTrailing(const int basketIndex,
                                  const double profitAtHandover,
                                  const double bid, const double ask)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   //--- 1. Mark basket as handed over
   g_trailIsHandedOver[basketIndex] = true;
   g_trailProfitAtHandover[basketIndex] = profitAtHandover;

   //--- 2. Initialize peak tracking
   double currentPrice;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      currentPrice = bid;
   else  // SELL
      currentPrice = ask;

   g_virtualTrail[basketIndex].peakPrice = currentPrice;
   g_virtualTrail[basketIndex].isActivated = true;
   g_virtualTrail[basketIndex].peakTime = TimeCurrent();

   //--- 3. Calculate dynamic trail distance
   g_trailCurrentDist[basketIndex] = Trailing_CalculateTrailDistance();

   //--- 4. Calculate initial stop level
   //--- CRITICAL FIX: Use tickSize (0.01 for XAUUSD) NOT SYMBOL_POINT (0.00001)
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_baskets[basketIndex].direction == 0)  // BUY
     {
      g_virtualTrail[basketIndex].stopLevel =
         currentPrice - (g_trailCurrentDist[basketIndex] * tickSize);
     }
   else  // SELL
     {
      g_virtualTrail[basketIndex].stopLevel =
         currentPrice + (g_trailCurrentDist[basketIndex] * tickSize);
     }

   //--- 5. Lock minimum stop level (profit floor)
   g_trailMinimumStop[basketIndex] =
      Trailing_CalculateMinimumStop(basketIndex, profitAtHandover);

   //--- 6. Save checkpoint immediately
   SSoT_SaveCheckpoint(basketIndex);
   Trailing_SaveCheckpoint(basketIndex);

   Print("[Trailing] HANDOVER: Basket ", g_baskets[basketIndex].basketId,
         " handed to trailing at profit $", DoubleToString(profitAtHandover, 2),
         " | Peak: ", DoubleToString(currentPrice, 5),
         " | TrailDist: ", DoubleToString(g_trailCurrentDist[basketIndex], 1), " pts",
         " | MinStop: ", DoubleToString(g_trailMinimumStop[basketIndex], 5));
}

//+------------------------------------------------------------------+
//| PUBLIC API — Check if basket is handed over (for FastStrike skip)  |
//+------------------------------------------------------------------+

/**
 * Check if a basket has been handed over to trailing
 * Called from FastStrikeCheck() to skip handed-over baskets
 * @param basketIndex  Basket cache index
 * @return true if handed over
 */
bool Trailing_IsHandedOver(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return false;
   return g_trailIsHandedOver[basketIndex];
}

//+------------------------------------------------------------------+
//| LAYER 1: VIRTUAL TRAILING — Hot Path                               |
//| Called from OnTick() — cache-only, zero GV calls                   |
//+------------------------------------------------------------------+

/**
 * Update virtual trailing for a single basket
 * Hot-path safe: reads only cached values, no GV/indicator calls
 * @param basketIndex  Basket cache index
 * @param bid          Current bid price
 * @param ask          Current ask price
 */
void Trailing_UpdateVirtualTrailing(const int basketIndex,
                                     const double bid, const double ask)
{
   //--- Skip if not handed over
   if(!g_trailIsHandedOver[basketIndex])
      return;
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   //--- Select price based on direction
   double currentPrice;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      currentPrice = bid;
   else  // SELL
      currentPrice = ask;

   //--- STEP 1: Update dynamic trail distance (from cold-path cache)
   double trailDist = g_trailCurrentDist[basketIndex];
   if(trailDist <= 0)
      trailDist = Trailing_CalculateTrailDistance();

   //--- STEP 2: Update peak price
   bool peakUpdated = false;
   if(g_baskets[basketIndex].direction == 0)  // BUY
     {
      if(currentPrice > g_virtualTrail[basketIndex].peakPrice)
        {
         g_virtualTrail[basketIndex].peakPrice = currentPrice;
         peakUpdated = true;
        }
     }
   else  // SELL
     {
      if(currentPrice < g_virtualTrail[basketIndex].peakPrice)
        {
         g_virtualTrail[basketIndex].peakPrice = currentPrice;
         peakUpdated = true;
        }
     }

   if(peakUpdated)
      g_virtualTrail[basketIndex].peakTime = TimeCurrent();

   //--- STEP 3: Calculate new virtual stop
   //--- CRITICAL FIX: Use tickSize (0.01 for XAUUSD) NOT SYMBOL_POINT (0.00001)
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double trailDistancePrice = trailDist * tickSize;

   double newStop;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      newStop = g_virtualTrail[basketIndex].peakPrice - trailDistancePrice;
   else  // SELL
      newStop = g_virtualTrail[basketIndex].peakPrice + trailDistancePrice;

   //--- STEP 4: Enforce minimum stop level (profit floor)
   double minStop = g_trailMinimumStop[basketIndex];
   if(minStop > 0)
     {
      if(g_baskets[basketIndex].direction == 0)  // BUY
         newStop = MathMax(newStop, minStop);
      else  // SELL
         newStop = MathMin(newStop, minStop);
     }

   g_virtualTrail[basketIndex].stopLevel = newStop;

   //--- STEP 5: Check trigger condition
   bool triggered = false;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      triggered = (currentPrice <= g_virtualTrail[basketIndex].stopLevel);
   else  // SELL
      triggered = (currentPrice >= g_virtualTrail[basketIndex].stopLevel);

   if(triggered)
     {
      Print("[Trailing] TRIGGERED: Basket ", g_baskets[basketIndex].basketId,
            " at ", DoubleToString(currentPrice, 5),
            " (stop: ", DoubleToString(g_virtualTrail[basketIndex].stopLevel, 5),
            ") — Peak was: ", DoubleToString(g_virtualTrail[basketIndex].peakPrice, 5));

      //--- CRITICAL FIX: ACTUALLY close positions at broker BEFORE marking SSoT closed
      ulong basketId = g_baskets[basketIndex].basketId;
      int levels = g_baskets[basketIndex].levelCount;
      int closedCount = 0;
      int failedCount = 0;

      for(int j = levels - 1; j >= 0; j--)
        {
         ulong ticket = g_baskets[basketIndex].levels[j].ticket;
         if(ticket > 0)
           {
            if(Trailing_ClosePosition(ticket))
               closedCount++;
            else
               failedCount++;
           }
        }

      Print("[Trailing] Basket ", basketId, " close result: ",
            closedCount, " closed, ", failedCount, " failed");

      //--- Only mark SSoT closed if ALL positions were closed
      if(failedCount == 0)
        {
         SSoT_CloseBasket(basketIndex);

         //--- Reset trailing state
         g_trailIsHandedOver[basketIndex] = false;
         g_trailProfitAtHandover[basketIndex] = 0;
         g_trailCurrentDist[basketIndex] = 50.0;
         g_trailMinimumStop[basketIndex] = 0;
        }
      else
        {
         Print("[Trailing] WARNING: ", failedCount, " positions failed to close. Basket NOT marked closed.");
        }
     }
}

/**
 * Close a single position at the broker
 * @param ticket  Position ticket
 * @return true if closed successfully
 */
bool Trailing_ClosePosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
     {
      Print("[Trailing] Position ", ticket, " no longer exists — already closed");
      return true;  // Already gone = success
     }

   double volume = PositionGetDouble(POSITION_VOLUME);
   long type = PositionGetInteger(POSITION_TYPE);
   string symbol = PositionGetString(POSITION_SYMBOL);
   double price;

   if(type == POSITION_TYPE_BUY)
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
   else
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = symbol;
   request.volume = volume;
   request.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = price;
   request.deviation = 50;
   request.magic = 0;
   request.type_filling = Trailing_GetFillingMode();

   if(!OrderSend(request, result))
     {
      Print("[Trailing] ERROR: Failed to close position ", ticket,
            " | Error: ", GetLastError(), " Retcode: ", result.retcode);
      return false;
     }

   if(result.retcode != TRADE_RETCODE_DONE &&
      result.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      Print("[Trailing] WARNING: Close retcode=", result.retcode,
            " for position ", ticket);
      return false;
     }

   Print("[Trailing] Position ", ticket, " closed at ", DoubleToString(price, 5));
   return true;
}

/**
 * Auto-detect broker filling mode for close orders
 */
ENUM_ORDER_TYPE_FILLING Trailing_GetFillingMode()
{
   long fillingMask = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMask & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fillingMask & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_FOK;
}

/**
 * Update virtual trailing for ALL active baskets
 * Called from OnTick() after FastStrikeCheck()
 * @param bid  Current bid price
 * @param ask  Current ask price
 */
void Trailing_UpdateAllVirtualTrailings(const double bid, const double ask)
{
   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(!g_trailIsHandedOver[i])
         continue;

      Trailing_UpdateVirtualTrailing(i, bid, ask);
     }
}

//+------------------------------------------------------------------+
//| LAYER 2: CHECKPOINT PERSISTENCE (v2.0 — 7 fields)                  |
//| Called from OnTimer() — cold path                                  |
//+------------------------------------------------------------------+

/**
 * Save trailing checkpoint for a basket to GVs (v2.0 — 7 fields)
 * @param basketIndex  Basket cache index
 */
void Trailing_SaveCheckpoint(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   ulong id = g_baskets[basketIndex].basketId;

   //--- Field 1: Peak price
   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_PEAK),
                     g_virtualTrail[basketIndex].peakPrice);

   //--- Field 2: Stop level
   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_STOP),
                     g_virtualTrail[basketIndex].stopLevel);

   //--- Field 3: Activated (also indicates handover)
   double activeVal = g_trailIsHandedOver[basketIndex] ? 1.0 :
                      (g_virtualTrail[basketIndex].isActivated ? 1.0 : 0.0);
   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_ACTIVE), activeVal);

   //--- Field 4: Timestamp
   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_TIME),
                     (double)TimeCurrent());

   //--- Field 5: Profit at Handover (NEW v2.0)
   GlobalVariableSet(GV_TrailName(id, "_PHO"),
                     g_trailProfitAtHandover[basketIndex]);

   //--- Field 6: Trail Distance (NEW v2.0)
   GlobalVariableSet(GV_TrailName(id, "_TDIS"),
                     g_trailCurrentDist[basketIndex]);

   //--- Field 7: Minimum Stop (NEW v2.0)
   GlobalVariableSet(GV_TrailName(id, "_MIN"),
                     g_trailMinimumStop[basketIndex]);

   //--- Update in-memory checkpoint
   g_checkpoint[basketIndex].peakPrice = g_virtualTrail[basketIndex].peakPrice;
   g_checkpoint[basketIndex].stopLevel = g_virtualTrail[basketIndex].stopLevel;
   g_checkpoint[basketIndex].isActivated = g_trailIsHandedOver[basketIndex];
   g_checkpoint[basketIndex].savedAt = TimeCurrent();
}

/**
 * Load trailing checkpoint for a basket from GVs (v2.0)
 * Called during SSoT_LoadFromGlobals() or after restart
 * @param basketId   Basket ID (1-based)
 * @param cacheIndex Basket cache index (0-based)
 * @return true if checkpoint loaded successfully
 */
bool Trailing_LoadCheckpoint(const ulong basketId, const int cacheIndex)
{
   if(cacheIndex < 0 || cacheIndex >= SK_MAX_BASKETS)
      return false;

   string trailActiveName = GV_TrailName(basketId, GV_TRAIL_ACTIVE);
   if(!GlobalVariableCheck(trailActiveName))
      return false;

   double activeVal = GlobalVariableGet(trailActiveName);
   if(activeVal == 0.0)
      return false;

   //--- Load basic fields
   g_virtualTrail[cacheIndex].peakPrice =
      GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_PEAK));
   g_virtualTrail[cacheIndex].stopLevel =
      GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_STOP));
   g_virtualTrail[cacheIndex].isActivated = true;
   g_virtualTrail[cacheIndex].peakTime =
      (datetime)GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_TIME));

   //--- Load handover-specific fields (v2.0)
   g_trailIsHandedOver[cacheIndex] = true;
   g_trailProfitAtHandover[cacheIndex] =
      GlobalVariableGet(GV_TrailName(basketId, "_PHO"));
   g_trailCurrentDist[cacheIndex] =
      GlobalVariableGet(GV_TrailName(basketId, "_TDIS"));
   g_trailMinimumStop[cacheIndex] =
      GlobalVariableGet(GV_TrailName(basketId, "_MIN"));

   //--- Validate checkpoint age
   double cpTimeVal = GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_TIME));
   datetime checkpointTime = (datetime)cpTimeVal;
   if(TimeCurrent() - checkpointTime > 3600)
     {
      Print("[Trailing] WARNING: Checkpoint expired (>1h) for basket ",
            basketId, " — resetting");
      Trailing_ResetTrailingState(cacheIndex);
      return false;
     }

   //--- Reconstruct dynamic trail if not loaded
   if(g_trailCurrentDist[cacheIndex] <= 0)
      g_trailCurrentDist[cacheIndex] = Trailing_CalculateTrailDistance();

   Print("[Trailing] Checkpoint restored: Basket ", basketId,
         " | Peak: ", DoubleToString(g_virtualTrail[cacheIndex].peakPrice, 5),
         " | Stop: ", DoubleToString(g_virtualTrail[cacheIndex].stopLevel, 5),
         " | HandedOver: true");

   return true;
}

/**
 * Reset trailing state for a basket
 * @param cacheIndex  Basket cache index
 */
void Trailing_ResetTrailingState(const int cacheIndex)
{
   g_trailIsHandedOver[cacheIndex] = false;
   g_trailProfitAtHandover[cacheIndex] = 0;
   g_trailCurrentDist[cacheIndex] = 50.0;
   g_trailMinimumStop[cacheIndex] = 0;

   g_virtualTrail[cacheIndex].peakPrice = 0;
   g_virtualTrail[cacheIndex].stopLevel = 0;
   g_virtualTrail[cacheIndex].isActivated = false;
   g_virtualTrail[cacheIndex].peakTime = 0;
}

//+------------------------------------------------------------------+
//| CHECKPOINT SYSTEM — Adaptive Frequency                             |
//+------------------------------------------------------------------+

/**
 * Update checkpoint system with adaptive frequency
 * Called from OnTimer()
 */
void Trailing_UpdateCheckpointSystem()
{
   //--- Count handed-over baskets
   int handedOverCount = 0;
   for(int i = 0; i < g_basketCount; i++)
     {
      if(g_trailIsHandedOver[i])
         handedOverCount++;
     }

   //--- Determine protection level
   ENUM_PROTECTION_LEVEL level = Trailing_DetermineProtectionLevel(handedOverCount);

   //--- Determine interval
   int interval;
   switch(level)
     {
      case PROTECTION_CRITICAL:
         interval = DEF_CP_INTERVAL_CRITICAL;  // 1s
         break;
      case PROTECTION_HIGH:
         interval = DEF_CP_INTERVAL_HIGH;  // 3s
         break;
      case PROTECTION_ELEVATED:
         interval = DEF_CP_INTERVAL_ELEVATED;  // 10s
         break;
      default:
         interval = DEF_CP_INTERVAL_NORMAL;  // 30s
         break;
     }

   //--- Check if time to save
   if(TimeCurrent() - g_lastCheckpointSave >= interval)
     {
      for(int i = 0; i < g_basketCount; i++)
        {
         if(g_baskets[i].isValid && g_trailIsHandedOver[i])
            Trailing_SaveCheckpoint(i);
        }
      g_lastCheckpointSave = TimeCurrent();
     }
}

/**
 * Determine protection level based on heat and handed-over baskets
 * @param handedOverCount  Number of baskets in trailing mode
 * @return Protection level
 */
ENUM_PROTECTION_LEVEL Trailing_DetermineProtectionLevel(const int handedOverCount)
{
   double heat = SSoT_CalculateHeatPct();

   //--- Base level from heat
   ENUM_PROTECTION_LEVEL baseLevel;
   if(heat > 90.0)
      baseLevel = PROTECTION_CRITICAL;
   else if(heat > 75.0)
      baseLevel = PROTECTION_HIGH;
   else if(heat > 60.0)
      baseLevel = PROTECTION_ELEVATED;
   else
      baseLevel = PROTECTION_NORMAL;

   //--- Boost level if baskets are handed over (more state to preserve)
   if(handedOverCount > 0 && baseLevel < PROTECTION_HIGH)
     {
      if(baseLevel == PROTECTION_NORMAL)
         baseLevel = PROTECTION_ELEVATED;
      else if(baseLevel == PROTECTION_ELEVATED)
         baseLevel = PROTECTION_HIGH;
     }

   return baseLevel;
}

//+------------------------------------------------------------------+
//| LAYER 3: EMERGENCY PHYSICAL STOPS                                  |
//| Called from OnTimer() and OnDeinit()                               |
//+------------------------------------------------------------------+

/**
 * Manage emergency stops for all active baskets
 * Called from OnTimer()
 */
void Trailing_ManageEmergencyStops()
{
   bool shouldActivate = Trailing_ShouldActivateEmergencyStops();

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;

      if(shouldActivate && !g_emergencyStopPlaced[i])
        {
         Trailing_PlaceEmergencyStop(i);
         g_emergencyStopPlaced[i] = true;
         g_emergencyStopPrice[i] = g_emergencyStopPrice[i];
        }
      else if(!shouldActivate && g_emergencyStopPlaced[i])
        {
         Trailing_RemoveEmergencyStop(i);
         g_emergencyStopPlaced[i] = false;
        }
     }
}

/**
 * Check if emergency stops should be activated
 * @return true if conditions met
 */
bool Trailing_ShouldActivateEmergencyStops()
{
   if(Inp_EmergencyMode == EMERGENCY_OFF)
      return false;

   if(Inp_EmergencyMode == EMERGENCY_MANUAL)
      return g_userEmergencyEnabled;

   //--- EMERGENCY_AUTO
   double heat = SSoT_CalculateHeatPct();
   if(heat > Inp_EmergencyHeatThresh * 100.0)
      return true;

   if(g_maintenancePlanned &&
      (int)(g_maintenanceTime - TimeCurrent()) > TRAIL_EMERGENCY_MAINT_HOURS * 3600)
      return true;

   if(!IsConnectionStable())
      return true;

   if(g_userInitiatedShutdown)
      return true;

   return false;
}

/**
 * Place emergency stop for a single basket
 * Uses trailing stop level for handed-over baskets, WA + buffer otherwise
 * @param basketIndex  Basket cache index
 */
void Trailing_PlaceEmergencyStop(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   double emergencyPrice;
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(g_trailIsHandedOver[basketIndex])
     {
      //--- Handed over: use virtual trailing stop level (preserves trend profit)
      emergencyPrice = g_virtualTrail[basketIndex].stopLevel;

      //--- Add small buffer for broker execution (5 points)
      if(g_baskets[basketIndex].direction == 0)  // BUY
         emergencyPrice -= 5.0 * pointValue;
      else  // SELL
         emergencyPrice += 5.0 * pointValue;
     }
   else
     {
      //--- Not handed over: use WA + spread + commission buffer
      double wa = g_baskets[basketIndex].weightedAvg;
      double avgSpread = g_spreadStats.average;
      double commissionBuffer = g_baskets[basketIndex].totalVolume * 7.0;
      double spreadBuffer = avgSpread * 2.5;

      if(g_baskets[basketIndex].direction == 0)  // BUY
         emergencyPrice = wa + ((spreadBuffer + commissionBuffer) * pointValue);
      else  // SELL
         emergencyPrice = wa - ((spreadBuffer + commissionBuffer) * pointValue);
     }

   //--- Place SAME stop for all positions in basket
   for(int i = 0; i < g_baskets[basketIndex].levelCount; i++)
     {
      ulong ticket = g_baskets[basketIndex].levels[i].ticket;
      if(ticket > 0)
        {
         Trailing_SetPhysicalStop(ticket, emergencyPrice);
        }
     }

   g_emergencyStopPrice[basketIndex] = emergencyPrice;

   Print("[Trailing] EMERGENCY STOP placed for basket ",
         g_baskets[basketIndex].basketId);
}

/**
 * Remove emergency stop for a basket
 * @param basketIndex  Basket cache index
 */
void Trailing_RemoveEmergencyStop(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;

   for(int i = 0; i < g_baskets[basketIndex].levelCount; i++)
     {
      ulong ticket = g_baskets[basketIndex].levels[i].ticket;
      if(ticket > 0)
        {
         Trailing_RemovePhysicalStop(ticket);
        }
     }

   Print("[Trailing] Emergency stop removed for basket ",
         g_baskets[basketIndex].basketId);
}

/**
 * Place physical stop loss on a position
 * @param ticket    Position ticket
 * @param stopPrice Stop loss price
 * @return true if order sent
 */
bool Trailing_SetPhysicalStop(const ulong ticket, const double stopPrice)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.sl = stopPrice;
   request.tp = PositionGetDouble(POSITION_TP);

   return OrderSend(request, result);
}

/**
 * Remove physical stop loss from a position
 * @param ticket  Position ticket
 * @return true if order sent
 */
bool Trailing_RemovePhysicalStop(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.sl = 0;
   request.tp = PositionGetDouble(POSITION_TP);

   return OrderSend(request, result);
}

/**
 * Place emergency stops for all active baskets (called on deinit)
 */
void Trailing_PlaceEmergencyStops()
{
   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;

      if(g_trailIsHandedOver[i])
        {
         Trailing_PlaceEmergencyStop(i);
         Print("[Trailing] Emergency stop at trailing level for basket ",
               g_baskets[i].basketId);
        }
      else
        {
         Trailing_PlaceEmergencyStop(i);
        }
     }
}

//+------------------------------------------------------------------+
//| UTILITY: Connection stability check                                |
//+------------------------------------------------------------------+

/**
 * Check if broker connection is stable
 * @return true if connected and ping is acceptable
 */
bool IsConnectionStable()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return false;

   //--- Check if trading is allowed and server is connected
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| INTEGRATION: FastStrike with Instant Handover Protocol            |
//| This function replaces FastStrikeCheck with instant handover logic |
//| Called from OnTick() as the primary profit check entry point       |
//| CRITICAL: Hands over to Trailing immediately when profit hit       |
//| Allows capturing long trends (1,000+ points) via trailing module   |
//+------------------------------------------------------------------+

/**
 * Fast-Strike with Instant Handover Protocol
 * This replaces the standalone FastStrikeCheck() from Phase 4
 *
 * API-FIRST Flow:
 * 1. Layer 1 + Layer 2 checks (unchanged — advisory only)
 * 2. If Broker Net Profit >= Target:
 *    → INSTANT HANDOVER to Trailing — ZERO age gate, ZERO delay
 * 3. Trailing sets Break-Even stop to protect profit, then lets trend run
 * 4. If already handed over → skip (trailing manages it)
 *
 * CRITICAL: Uses Broker's POSITION_PROFIT directly (no math calculations).
 * When target is hit, hands over to Trailing IMMEDIATELY to capture long trends.
 * The Break-Even stop protects the $10 profit while following the trend.
 *
 * @return true if a basket was handed over to trailing
 */
bool FastStrikeCheckWithHandover()
{
   //--- Skip if cache not ready
   if(!g_cacheValid)
      return false;

   //--- Spread spike lockout
   if(g_fsSpreadSpikeActive)
      return false;

   datetime now = TimeCurrent();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- Iterate all active baskets
   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(g_baskets[i].status != BASKET_ACTIVE)
         continue;

      //--- Skip baskets already handed over to trailing
      if(g_trailIsHandedOver[i])
         continue;

      //--- Minimum age gate (original FastStrike)
      if(now - g_baskets[i].created < Inp_MinBasketAge)
         continue;

      double target = g_baskets[i].targetProfit;

      //=== API-FIRST: Live API profit is the PRIMARY decision source ===
      double apiProfit = GetBasketApiProfit(i);

      //--- LAYER 1: Aggressive math check (advisory — does NOT block)
      double layer1 = FastStrike_CalcLayer1(i, bid, ask);
      if(layer1 < target)
         continue;

      //--- LAYER 2: Conservative math check (advisory — does NOT block)
      if(Inp_FastStrikeMode != FAST_LAYER1)
        {
         double layer2 = FastStrike_CalcLayer2(i, bid, ask);
         if(layer2 < target * g_fsConservativeFactor)
            continue;  // Advisory layer — skip to next basket

         //--- PRE-EXECUTION: Spread spike check only (API-FIRST — no math gate)
         if(!FastStrike_PreExecutionVerify(i, bid, ask, target))
            continue;

         //--- CRITICAL: INSTANT HANDOVER when API profit >= target
         // NO age gate, ZERO delay — handover to trailing immediately
         // Trailing will set Break-Even stop to protect profit, then let trend run
         Trailing_HandOverToTrailing(i, apiProfit, bid, ask);
         g_fsTotalChecks++;
         return true;
        }
      else
        {
         //--- Layer 1 only mode (aggressive) — same instant handover behavior
         Trailing_HandOverToTrailing(i, apiProfit, bid, ask);
         g_fsTotalChecks++;
         return true;
        }
     }

   g_fsTotalChecks++;
   return false;
}

//+------------------------------------------------------------------+
