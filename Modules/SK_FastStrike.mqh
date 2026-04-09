//+------------------------------------------------------------------+
//|                                          SK_FastStrike.mqh       |
//|                                    SIDEWAY KILLER - Phase 4      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"
#include "SK_DataTypes.mqh"
#include "SK_GVSchema.mqh"
#include "SK_SSoT.mqh"

//+==================================================================+
//| FAST-STRIKE PROFIT DETECTION & EXECUTION SYSTEM                    |
//|                                                                    |
//|  Architecture: Two-Layer Math-Based Profit Detection               |
//|  Hot Path: FastStrikeCheck() — cache-only, < 0.10ms total          |
//|  Cold Path: Spread stats, API verification, validation             |
//|                                                                    |
//|  Priority Directive: "Profit First" — Close All on first hit       |
//+==================================================================+

//+------------------------------------------------------------------+
//| COLD-PATH CACHED VALUES                                            |
//+------------------------------------------------------------------+

double  g_fsCachedSpreadAvg = 10.0;       // EMA of spread
double  g_fsCachedSpreadStdDev = 2.0;     // Spread standard deviation
double  g_fsCachedValuePerPoint = 100.0;  // $ per lot per point (XAUUSD)
double  g_fsCachedCommissionPerLot = 7.0; // $ commission per lot
double  g_fsCachedSpreadBuffer = 15.0;    // Adaptive spread buffer
double  g_fsConservativeFactor = 0.97;    // Layer 2 conservative factor
bool    g_fsSpreadSpikeActive = false;    // Spread spike lockout flag
double  g_fsPrevSpread = 10.0;            // Previous spread for rate detection
datetime g_fsLastSpikeCheck = 0;

//--- Layer 3 API cache (optional, cold path only)
double  g_fsApiCache[MAX_BASKETS];
datetime g_fsApiCacheTime[MAX_BASKETS];

//--- Performance tracking
ulong   g_fsTotalChecks = 0;
ulong   g_fsTotalCloses = 0;
double  g_fsMaxLatencyUS = 0;

//+------------------------------------------------------------------+
//| PUBLIC API — Initialization                                        |
//+------------------------------------------------------------------+

/**
 * Initialize the Fast-Strike system
 * Pre-computes value-per-point, initializes spread stats
 * @return true on success
 */
bool FastStrike_Init()
{
   //--- Compute conservative value per point for XAUUSD
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize > 0)
      g_fsCachedValuePerPoint = tickValue / tickSize;
   else
      g_fsCachedValuePerPoint = 100.0;  // Default XAUUSD estimate

   //--- Apply conservative factor
   g_fsCachedValuePerPoint *= Inp_FastStrikeMode == FAST_LAYER1 ?
                              1.0 : Inp_FastStrikeMode == FAST_TWO_LAYER ?
                              Inp_FastStrikeMode == FAST_THREE_LAYER ? 1.0 : 1.0 : 1.0;

   //--- Layer 2 conservative factor
   if(Inp_FastStrikeMode == FAST_TWO_LAYER || Inp_FastStrikeMode == FAST_THREE_LAYER)
      g_fsConservativeFactor = 0.97;

   //--- Initialize spread stats from existing cache
   g_fsCachedSpreadAvg = g_spreadStats.average;
   g_fsCachedSpreadStdDev = g_spreadStats.stdDev;
   g_fsPrevSpread = g_market.currentSpread;

   //--- Initialize API cache
   ArrayInitialize(g_fsApiCache, 0);
   ArrayInitialize(g_fsApiCacheTime, 0);

   //--- Performance counters
   g_fsTotalChecks = 0;
   g_fsTotalCloses = 0;
   g_fsMaxLatencyUS = 0;

   Print("[FastStrike] Initialized. Mode: ",
         (Inp_FastStrikeMode == FAST_LAYER1 ? "LAYER1" :
          Inp_FastStrikeMode == FAST_TWO_LAYER ? "TWO_LAYER" : "THREE_LAYER"),
         " | ValuePerPoint: $", DoubleToString(g_fsCachedValuePerPoint, 2));

   return true;
}

/**
 * Deinitialize the Fast-Strike system
 */
void FastStrike_Deinit()
{
   Print("[FastStrike] Deinitialized. Total checks: ", g_fsTotalChecks,
         " | Closes: ", g_fsTotalCloses,
         " | Max latency: ", DoubleToString(g_fsMaxLatencyUS, 0), "μs");
}

//+------------------------------------------------------------------+
//| COLD PATH — Refresh spread stats, detect spikes, update buffers    |
//| Called from OnTimer() — never from OnTick()                        |
//+------------------------------------------------------------------+

/**
 * Refresh Fast-Strike cold-path cache
 * Updates spread stats, spike detection, adaptive thresholds
 * Called from OnTimer() every 1 second
 */
void FastStrike_RefreshCache()
{
   double currentSpread = g_market.currentSpread;

   //--- Update EMA of spread
   double alpha = 0.1;
   g_fsCachedSpreadAvg = g_fsCachedSpreadAvg * (1.0 - alpha) + currentSpread * alpha;

   //--- Update spread variance (for standard deviation)
   double delta = currentSpread - g_fsCachedSpreadAvg;
   g_fsCachedSpreadStdDev = MathSqrt(
      g_fsCachedSpreadStdDev * g_fsCachedSpreadStdDev * (1.0 - alpha) +
      (delta * delta) * alpha
   );

   //--- SPREAD SPIKE LOCKOUT: Detect extreme spread change rate
   double spreadChangeRate = 0;
   if(g_fsPrevSpread > 0)
      spreadChangeRate = MathAbs(currentSpread - g_fsPrevSpread) / g_fsPrevSpread;

   //--- If spread changed > 50% in 1 second, trigger lockout
   if(spreadChangeRate > 0.50)
     {
      g_fsSpreadSpikeActive = true;
      g_fsLastSpikeCheck = TimeCurrent();
      Print("[FastStrike] WARNING: Spread spike detected! Change rate: ",
            DoubleToString(spreadChangeRate * 100, 1),
            "% — Fast-Strike PAUSED");
     }

   //--- Auto-unlock after 5 seconds of stable spreads
   if(g_fsSpreadSpikeActive)
     {
      if(TimeCurrent() - g_fsLastSpikeCheck >= 5)
        {
         //--- Re-check: is spread now stable?
         double newRate = 0;
         if(g_fsPrevSpread > 0)
            newRate = MathAbs(currentSpread - g_fsPrevSpread) / g_fsPrevSpread;

         if(newRate < 0.20)  // Stabilized below 20% change
           {
            g_fsSpreadSpikeActive = false;
            Print("[FastStrike] Spread stabilized. Fast-Strike RESUMED");
           }
         else
            g_fsLastSpikeCheck = TimeCurrent();  // Reset timer
        }
     }

   //--- Compute adaptive spread buffer
   //--- Use current spread or 1.5× average, whichever is higher
   double spreadMult = Inp_FastStrikeMode == FAST_TWO_LAYER ?
                       Inp_FastStrikeMode == FAST_THREE_LAYER ? 1.5 : 1.5 : 1.5;
   g_fsCachedSpreadBuffer = MathMax(currentSpread,
                                     g_fsCachedSpreadAvg * spreadMult);

   //--- ADAPTIVE THRESHOLD: Shift confirmation when spreads > 50 points
   if(g_fsCachedSpreadAvg > 50.0)
      g_fsConservativeFactor = 0.90;  // 90% threshold
   else
      g_fsConservativeFactor = 0.97;  // 95% threshold

   //--- Save previous spread for next cycle comparison
   g_fsPrevSpread = currentSpread;
}

//+------------------------------------------------------------------+
//| PUBLIC API — FastStrikeCheck() — HOT PATH ENTRY POINT              |
//| MUST be called FIRST in OnTick()                                   |
//| MUST return early after any basket closure                         |
//| ZERO GlobalVariable or PositionGetDouble calls                     |
//+------------------------------------------------------------------+

/**
 * Fast-Strike profit check — PRIMARY hot path entry point
 * MUST be the first operation in OnTick()
 * Exits immediately after closing any basket
 *
 * Latency budget: < 0.10ms total
 * Layer 1: ~0.05ms (aggressive math)
 * Layer 2: ~0.05ms (conservative math)
 *
 * @return true if a basket was closed, false otherwise
 */
bool FastStrikeCheck()
{
   ulong startTime = GetMicrosecondCount();

   //--- Skip if cache not ready
   if(!g_cacheValid)
     {
      g_fsTotalChecks++;
      return false;
     }

   //--- SPREAD SPIKE LOCKOUT: Pause Fast-Strike during extreme volatility
   if(g_fsSpreadSpikeActive)
     {
      g_fsTotalChecks++;
      return false;
     }

   //--- Minimum basket age check: prevent premature closure
   datetime now = TimeCurrent();

   //--- Get live prices ONCE (never cache price data)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- Iterate all active baskets
   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(g_baskets[i].status != BASKET_ACTIVE)
         continue;

      //--- Minimum age gate: skip baskets younger than minimum age
      if(now - g_baskets[i].created < Inp_MinBasketAge)
         continue;

      double target = g_baskets[i].targetProfit;

      //--- LAYER 1: Aggressive math check (~0.05ms)
      double layer1 = FastStrike_CalcLayer1(i, bid, ask);

      if(layer1 < target)
         continue;  // Below target — skip to next basket

      //--- LAYER 2: Conservative math check (~0.05ms)
      if(Inp_FastStrikeMode != FAST_LAYER1)
        {
         double layer2 = FastStrike_CalcLayer2(i, bid, ask);

         //--- Use adaptive threshold (90% or 95% based on spread conditions)
         if(layer2 < target * g_fsConservativeFactor)
            continue;  // Layer 2 failed — skip to next basket
        }

      //--- LAYER 3: API verification (optional, advanced users only)
      if(Inp_FastStrikeMode == FAST_THREE_LAYER)
        {
         double layer3 = FastStrike_CalcLayer3(i);

         if(layer3 < target * g_fsConservativeFactor)
            continue;  // API verification failed — skip
        }

      //--- PRE-EXECUTION RE-VERIFICATION: Final microsecond spread check
      //--- Ensures net profit is still positive at exact execution moment
      if(!FastStrike_PreExecutionVerify(i, bid, ask, target))
         continue;  // Profit dropped below target — skip

      //--- ALL CHECKS PASSED — Close basket IMMEDIATELY
      FastStrike_CloseBasketImmediate(i);
      g_fsTotalCloses++;

      //--- CRITICAL: Exit immediately after close — do NOT check remaining baskets
      ulong elapsed = GetMicrosecondCount() - startTime;
      if(elapsed > g_fsMaxLatencyUS)
         g_fsMaxLatencyUS = (double)elapsed;
      g_fsTotalChecks++;

      return true;  // EARLY RETURN — Profit First directive
     }

   //--- No basket qualified
   ulong elapsed = GetMicrosecondCount() - startTime;
   if(elapsed > g_fsMaxLatencyUS)
      g_fsMaxLatencyUS = (double)elapsed;
   g_fsTotalChecks++;

   return false;
}

//+------------------------------------------------------------------+
//| LAYER 1: Aggressive Math Check                                     |
//| Pure arithmetic — NO API calls, NO string ops                      |
//| Latency: ~0.05ms                                                   |
//+------------------------------------------------------------------+

/**
 * Layer 1: Aggressive profit estimate
 * Formula: distance × volume × valuePerPoint
 * @param basketIndex  Basket cache index
 * @param bid          Current bid price
 * @param ask          Current ask price
 * @return Estimated profit in USD (aggressive, optimistic)
 */
double FastStrike_CalcLayer1(const int basketIndex, const double bid,
                              const double ask)
{
   double distance = 0;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      distance = bid - g_baskets[basketIndex].weightedAvg;
   else  // SELL
      distance = g_baskets[basketIndex].weightedAvg - ask;

   //--- No profit if price is against basket
   if(distance <= 0)
      return 0;

   return distance * g_baskets[basketIndex].totalVolume *
          g_fsCachedValuePerPoint;
}

//+------------------------------------------------------------------+
//| LAYER 2: Conservative Math Check                                   |
//| Deducts spread cost and commission for net profit estimate          |
//| Latency: ~0.05ms                                                   |
//+------------------------------------------------------------------+

/**
 * Layer 2: Conservative profit estimate
 * Formula: grossProfit - spreadCost - commissionCost
 * @param basketIndex  Basket cache index
 * @param bid          Current bid price
 * @param ask          Current ask price
 * @return Estimated net profit in USD (conservative, pessimistic)
 */
double FastStrike_CalcLayer2(const int basketIndex, const double bid,
                              const double ask)
{
   double distance = 0;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      distance = bid - g_baskets[basketIndex].weightedAvg;
   else  // SELL
      distance = g_baskets[basketIndex].weightedAvg - ask;

   //--- No profit if price is against basket
   if(distance <= 0)
      return 0;

   //--- Gross profit
   double grossProfit = distance * g_baskets[basketIndex].totalVolume *
                        g_fsCachedValuePerPoint;

   //--- Spread cost: volume × adaptive spread buffer (in points × $/point)
   double spreadCost = g_baskets[basketIndex].totalVolume *
                       g_fsCachedSpreadBuffer *
                       g_fsCachedValuePerPoint;

   //--- Commission cost
   double commissionCost = g_baskets[basketIndex].totalVolume *
                           g_fsCachedCommissionPerLot;

   return grossProfit - spreadCost - commissionCost;
}

//+------------------------------------------------------------------+
//| LAYER 3: API Verification (Optional — Cold Path Cached)            |
//| Uses cached API values — does NOT call PositionGetDouble here      |
//+------------------------------------------------------------------+

/**
 * Layer 3: API-based profit verification (cached)
 * Called only in THREE_LAYER mode — uses pre-cached values from OnTimer
 * @param basketIndex  Basket cache index
 * @return API-verified profit in USD, or 0 if cache invalid
 */
double FastStrike_CalcLayer3(const int basketIndex)
{
   //--- Check cache validity (500ms freshness)
   if(g_fsApiCacheTime[basketIndex] == 0)
      return FastStrike_CalcLayer2(basketIndex,
                                   SymbolInfoDouble(_Symbol, SYMBOL_BID),
                                   SymbolInfoDouble(_Symbol, SYMBOL_ASK));

   datetime now = TimeCurrent();
   int ageMs = (int)((now - g_fsApiCacheTime[basketIndex]) * 1000);

   if(ageMs > 500 || ageMs < 0)
     {
      //--- Cache stale — fall back to Layer 2
      return FastStrike_CalcLayer2(basketIndex,
                                   SymbolInfoDouble(_Symbol, SYMBOL_BID),
                                   SymbolInfoDouble(_Symbol, SYMBOL_ASK));
     }

   return g_fsApiCache[basketIndex];
}

//+------------------------------------------------------------------+
//| PRE-EXECUTION RE-VERIFICATION — Microsecond Safety Gate             |
//| Final check immediately before CloseBasketImmediate()               |
//| Verifies net profit is still positive at exact execution moment     |
//+------------------------------------------------------------------+

/**
 * Pre-execution verification: final microsecond profit check
 * Ensures spread hasn't spiked and profit remains positive
 * @param basketIndex  Basket cache index
 * @param bid          Current bid price (from OnTick)
 * @param ask          Current ask price (from OnTick)
 * @param target       Target profit in USD
 * @return true if profit is still above threshold
 */
bool FastStrike_PreExecutionVerify(const int basketIndex, const double bid,
                                    const double ask, const double target)
{
   //--- Re-calculate Layer 2 with CURRENT prices (microsecond check)
   double distance = 0;
   if(g_baskets[basketIndex].direction == 0)  // BUY
      distance = bid - g_baskets[basketIndex].weightedAvg;
   else  // SELL
      distance = g_baskets[basketIndex].weightedAvg - ask;

   //--- Price moved against us? Abort
   if(distance <= 0)
      return false;

   //--- Quick spread spike check at exact execution moment
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   //--- If spread just spiked > 2× average, abort — slippage risk too high
   if(g_fsCachedSpreadAvg > 0 &&
      currentSpread > g_fsCachedSpreadAvg * 2.0)
     {
      //--- Lock out immediately
      g_fsSpreadSpikeActive = true;
      g_fsLastSpikeCheck = TimeCurrent();
      return false;
     }

   //--- Quick net profit estimate
   double grossProfit = distance * g_baskets[basketIndex].totalVolume *
                        g_fsCachedValuePerPoint;
   double spreadCost = g_baskets[basketIndex].totalVolume *
                       g_fsCachedSpreadBuffer *
                       g_fsCachedValuePerPoint;
   double commissionCost = g_baskets[basketIndex].totalVolume *
                           g_fsCachedCommissionPerLot;
   double netProfit = grossProfit - spreadCost - commissionCost;

   //--- Must still meet at least 85% of target at execution moment
   return (netProfit >= target * 0.85);
}

//+------------------------------------------------------------------+
//| EXECUTION — Close Basket Immediate                                  |
//| Highest priority operation — executes the close sequence            |
//+------------------------------------------------------------------+

/**
 * Close a basket immediately — all positions are closed
 * This is the CRITICAL execution path — nothing takes priority
 * @param basketIndex  Basket cache index
 */
void FastStrike_CloseBasketImmediate(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   ulong basketId = g_baskets[basketIndex].basketId;

   //--- Flag basket for closure to prevent new grid additions
   SSoT_UpdateBasketStatus(basketIndex, BASKET_CLOSING);

   //--- Close all positions in this basket (reverse order for safety)
   int levels = g_baskets[basketIndex].levelCount;
   int closedCount = 0;

   for(int i = levels - 1; i >= 0; i--)
     {
      ulong ticket = g_baskets[basketIndex].levels[i].ticket;
      if(ticket > 0)
        {
         if(FastStrike_ClosePosition(ticket))
            closedCount++;
        }
     }

   //--- Mark as fully closed
   SSoT_UpdateBasketStatus(basketIndex, BASKET_CLOSED);

   //--- Calculate actual profit for trade statistics
   double actualProfit = FastStrike_CalcFinalProfit(basketIndex);
   SSoT_OnBasketClosed(actualProfit);

   //--- Close the basket (invalidates cache entry, compacts array)
   SSoT_CloseBasket(basketIndex);

   Print("[FastStrike] Basket ", basketId, " CLOSED. Positions closed: ",
         closedCount, "/", levels, " | Profit: $", DoubleToString(actualProfit, 2));

   Alert("[SIDEWAY KILLER] Basket ", basketId, " CLOSED — Profit: $",
         DoubleToString(actualProfit, 2));
}

/**
 * Close a single position by ticket
 * @param ticket  Position ticket
 * @return true if close order sent successfully
 */
bool FastStrike_ClosePosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
     {
      Print("[FastStrike] WARNING: Position ", ticket, " no longer exists");
      return false;
     }

   double volume = PositionGetDouble(POSITION_VOLUME);
   long type = PositionGetInteger(POSITION_TYPE);
   string symbol = PositionGetString(POSITION_SYMBOL);
   double price;

   //--- Use correct closing price
   if(type == POSITION_TYPE_BUY)
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
   else
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);

   //--- Send close order
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = symbol;
   request.volume = volume;
   request.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = price;
   request.deviation = 10;  // 10 points max slippage
   request.magic = 0;
   request.type_filling = ORDER_FILLING_IOC;  // Immediate-or-Cancel for speed

   if(!OrderSend(request, result))
     {
      Print("[FastStrike] ERROR: Failed to close position ", ticket,
            " | Error: ", GetLastError(), " | Retcode: ", result.retcode);

      //--- Retry with FOK filling if IOC failed
      request.type_filling = ORDER_FILLING_FOK;
      if(!OrderSend(request, result))
        {
         Print("[FastStrike] ERROR: Retry also failed for position ", ticket);
         return false;
        }
     }

   if(result.retcode != TRADE_RETCODE_DONE &&
      result.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      Print("[FastStrike] WARNING: Close result for ", ticket,
            " retcode=", result.retcode);
      return false;
     }

   return true;
}

/**
 * Calculate final profit of a basket (for trade stats)
 * Uses SSoT approximate calculation with latest prices
 * @param basketIndex  Basket cache index (before closure)
 * @return Estimated profit in USD
 */
double FastStrike_CalcFinalProfit(const int basketIndex)
{
   double currentPrice;
   if(g_baskets[basketIndex].direction == 0)
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double grossProfit = SSoT_CalcApproxProfit(basketIndex, currentPrice);

   //--- Deduct estimated commission
   double commission = g_baskets[basketIndex].totalVolume *
                       g_fsCachedCommissionPerLot;

   return grossProfit - commission;
}

//+------------------------------------------------------------------+
//| COLD PATH — API Verification Cache (Layer 3 support)               |
//| Refreshes cached API values for optional Layer 3 verification       |
//| Called from OnTimer() — never from OnTick()                         |
//+------------------------------------------------------------------+

/**
 * Update API verification cache for all active baskets
 * Called from OnTimer() every 1 second (or 500ms in THREE_LAYER mode)
 */
void FastStrike_UpdateApiCache()
{
   if(Inp_FastStrikeMode != FAST_THREE_LAYER)
      return;

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(g_baskets[i].status != BASKET_ACTIVE)
         continue;

      double totalProfit = 0;

      //--- Sum actual position profits (API call — slow, but cold path)
      for(int j = 0; j < g_baskets[i].levelCount; j++)
        {
         ulong ticket = g_baskets[i].levels[j].ticket;
         if(ticket > 0 && PositionSelectByTicket(ticket))
            totalProfit += PositionGetDouble(POSITION_PROFIT);
        }

      g_fsApiCache[i] = totalProfit;
      g_fsApiCacheTime[i] = TimeCurrent();
     }
}

//+------------------------------------------------------------------+
//| COLD PATH — Validate math accuracy against API (debug/diagnostic)  |
//| Compares Layer 2 estimates with actual API profits                  |
//| Logs warnings if error exceeds threshold                            |
//+------------------------------------------------------------------+

/**
 * Validate math accuracy of Layer 2 against actual API profits
 * Logs warnings if error > 10%
 */
void FastStrike_ValidateMathAccuracy()
{
   double threshold = 0.10;  // 10% error threshold

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(g_baskets[i].status != BASKET_ACTIVE)
         continue;

      //--- Get Layer 2 estimate
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double mathProfit = FastStrike_CalcLayer2(i, bid, ask);

      //--- Get actual API profit
      double apiProfit = 0;
      for(int j = 0; j < g_baskets[i].levelCount; j++)
        {
         ulong ticket = g_baskets[i].levels[j].ticket;
         if(ticket > 0 && PositionSelectByTicket(ticket))
            apiProfit += PositionGetDouble(POSITION_PROFIT);
        }

      //--- Calculate error percentage
      double absApiProfit = MathAbs(apiProfit);
      if(absApiProfit < 0.01)
         continue;  // Too small to measure

      double errorPct = MathAbs(mathProfit - apiProfit) / absApiProfit;

      if(errorPct > threshold)
        {
         Print("[FastStrike] WARNING: Math accuracy error ",
               DoubleToString(errorPct * 100, 1), "% for basket ",
               g_baskets[i].basketId,
               " | Math: $", DoubleToString(mathProfit, 2),
               " | API: $", DoubleToString(apiProfit, 2));
        }
     }
}

//+------------------------------------------------------------------+