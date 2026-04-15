//+------------------------------------------------------------------+
//|                                               SK_Grid.mqh        |
//|                                    SIDEWAY KILLER - Phase 3      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"
#include "SK_DataTypes.mqh"
#include "SK_GVSchema.mqh"
#include "SK_SSoT.mqh"
#include "SK_Safety.mqh"

//+==================================================================+
//| DVASS GRID SPACING ENGINE — Configurable Multi-Mode Architecture   |
//|                                                                    |
//|  Modes: FIXED, DVASS (default), HYBRID                             |
//|  Hot Path: CheckGridLevels() — cache-only, < 0.5ms per basket      |
//|  Cold Path: ATR reads, spike detection, cache refresh              |
//+==================================================================+

//+------------------------------------------------------------------+
//| COLD-PATH CACHED VALUES                                            |
//+------------------------------------------------------------------+

double  g_gridCachedATR14 = 0;            // Cached ATR(14)
double  g_gridCachedATR5 = 0;             // Cached ATR(5) for spike detection
double  g_gridCachedSpikeMult = 1.0;      // Cached spike multiplier
double  g_gridCachedAdjustedBase = 250;   // Cached adjusted base step

//--- Indicator handles (shared with Adoption, initialized once)
int     g_gridAtrHandle14 = INVALID_HANDLE;
int     g_gridAtrHandle5 = INVALID_HANDLE;

//--- ATR buffers for cold-path reads (dynamic for ArraySetAsSeries)
double  g_gridBufATR14[];
double  g_gridBufATR5[];

//--- Per-basket grid cooldown (prevents global block when one basket adds)
datetime g_basketLastGridAddTime[SK_MAX_BASKETS];

//+------------------------------------------------------------------+
//| PUBLIC API — Initialization                                        |
//+------------------------------------------------------------------+

/**
 * Initialize the grid spacing system
 * Creates ATR indicator handles
 * @return true on success
 */
bool Grid_Init()
{
   //--- Create ATR handles
   g_gridAtrHandle14 = iATR(_Symbol, PERIOD_CURRENT, Inp_DVASS_ATRPeriod);
   g_gridAtrHandle5 = iATR(_Symbol, PERIOD_CURRENT, Inp_DVASS_ATRFastPeriod);

   if(g_gridAtrHandle14 == INVALID_HANDLE)
      Print("[Grid] WARNING: ATR(14) handle creation failed");
   if(g_gridAtrHandle5 == INVALID_HANDLE)
      Print("[Grid] WARNING: ATR(5) handle creation failed");

   //--- Seed cache with defaults
   g_gridCachedATR14 = 0;
   g_gridCachedATR5 = 0;
   g_gridCachedSpikeMult = 1.0;
   g_gridCachedAdjustedBase = Inp_DVASS_BaseStep;
   ArrayInitialize(g_basketLastGridAddTime, 0);

   //--- CRITICAL: Refresh cache immediately to get valid ATR values
   //--- Prevents 560-point spacing fallback on first grid check
   Grid_RefreshCache();

   //--- If ATR is still 0 after refresh, seed with a reasonable default
   //--- to prevent FIXED mode fallback causing excessive spacing
   if(g_gridCachedATR14 <= 0)
     {
      g_gridCachedATR14 = Inp_DVASS_ATRNorm / 2.0;  // 10.0 default
      g_gridCachedAdjustedBase = Inp_DVASS_BaseStep * 0.5;  // 125.0
      Print("[Grid] ATR not ready — using default ", g_gridCachedATR14,
            " pts, adjusted base = ", g_gridCachedAdjustedBase);
     }

   Print("[Grid] Initialized. Mode: ",
         (Inp_GridMode == GRID_FIXED ? "FIXED" :
          Inp_GridMode == GRID_DVASS ? "DVASS" :
          Inp_GridMode == GRID_HYBRID ? "HYBRID" : "UNKNOWN"),
         " ATR14=", DoubleToString(g_gridCachedATR14, 2),
         " Base=", DoubleToString(g_gridCachedAdjustedBase, 2));

   return true;
}

/**
 * Deinitialize the grid spacing system
 */
void Grid_Deinit()
{
   if(g_gridAtrHandle14 != INVALID_HANDLE)
      IndicatorRelease(g_gridAtrHandle14);
   if(g_gridAtrHandle5 != INVALID_HANDLE)
      IndicatorRelease(g_gridAtrHandle5);

   g_gridAtrHandle14 = INVALID_HANDLE;
   g_gridAtrHandle5 = INVALID_HANDLE;

   Print("[Grid] Deinitialized");
}

//+------------------------------------------------------------------+
//| COLD PATH — Refresh ATR cache from indicators                      |
//| Called from OnTimer() — never from OnTick()                        |
//+------------------------------------------------------------------+

/**
 * Refresh ATR cache values from indicator handles
 * Called from OnTimer() every 1 second
 */
void Grid_RefreshCache()
{
   ArraySetAsSeries(g_gridBufATR14, true);
   ArraySetAsSeries(g_gridBufATR5, true);

   //--- Read ATR(14)
   if(g_gridAtrHandle14 != INVALID_HANDLE)
     {
      if(CopyBuffer(g_gridAtrHandle14, 0, 0, 1, g_gridBufATR14) > 0)
         g_gridCachedATR14 = g_gridBufATR14[0];
     }

   //--- Read ATR(5)
   if(g_gridAtrHandle5 != INVALID_HANDLE)
     {
      if(CopyBuffer(g_gridAtrHandle5, 0, 0, 1, g_gridBufATR5) > 0)
         g_gridCachedATR5 = g_gridBufATR5[0];
     }

   //--- Compute spike multiplier
   g_gridCachedSpikeMult = 1.0;
   if(Inp_DVASS_UseSpikeDetect && g_gridCachedATR5 > 0 && g_gridCachedATR14 > 0)
     {
      if(g_gridCachedATR5 > g_gridCachedATR14 * 1.5)
         g_gridCachedSpikeMult = 1.5;
     }

   //--- Compute adjusted base step (DVASS mode only)
   if(Inp_GridMode == GRID_DVASS)
     {
      double atr = g_gridCachedATR14;

      if(atr <= 0 || atr > 200.0)
        {
         //--- Invalid ATR — fallback to fixed base
         g_gridCachedAdjustedBase = Inp_Fixed_BaseStep;
        }
      else
        {
         double normalizedATR = atr / Inp_DVASS_ATRNorm;
         g_gridCachedAdjustedBase = Inp_DVASS_BaseStep * normalizedATR * g_gridCachedSpikeMult;
        }
     }
   else if(Inp_GridMode == GRID_HYBRID)
     {
      //--- HYBRID mode — base is determined by regime, computed in GetGridDistance
      g_gridCachedAdjustedBase = Inp_DVASS_BaseStep;
     }
   else
     {
      //--- FIXED mode — base is constant
      g_gridCachedAdjustedBase = Inp_Fixed_BaseStep;
     }
}

//+------------------------------------------------------------------+
//| PUBLIC API — Get grid distance (Hot Path safe)                     |
//| All data is from cache — zero indicator/GV calls                   |
//+------------------------------------------------------------------+

/**
 * Calculate grid spacing for a given level
 * Hot-path safe: reads only cached values
 * @param basketIndex  Basket cache index (for logging)
 * @param level        Grid level index (0 = original position)
 * @return Required distance in points before adding next level
 */
double GetGridDistance(const int basketIndex, const int level)
{
   if(level < 0)
      return Inp_DVASS_BaseStep;

   double spacing;

   switch(Inp_GridMode)
     {
      case GRID_FIXED:
         spacing = Grid_CalculateFixed(level);
         break;

      case GRID_DVASS:
         spacing = Grid_CalculateDVASS(level);
         break;

      case GRID_HYBRID:
         spacing = Grid_CalculateHybrid(level);
         break;

      default:
         //--- Safe fallback
         spacing = Grid_CalculateFixed(level);
         break;
     }

   //--- Safety: ensure non-negative
   if(spacing < 0)
     {
      Print("[Grid] WARNING: Negative spacing detected for basket ",
            basketIndex, " level ", level, " value=", spacing,
            " — forcing minimum");
      spacing = Inp_DVASS_MinStep;
     }

   return spacing;
}

//+------------------------------------------------------------------+
//| MODE 1: FIXED — Constant spacing                                   |
//+------------------------------------------------------------------+

/**
 * Calculate FIXED mode spacing
 * Formula: BaseStep × (Expansion ^ Level)
 */
double Grid_CalculateFixed(const int level)
{
   double baseStep = Inp_Fixed_BaseStep;
   double expansion = Inp_Fixed_Expansion;
   double levelMult = MathPow(expansion, level);
   double step = baseStep * levelMult;

   //--- Apply DVASS bounds for safety
   step = MathMax(step, Inp_DVASS_MinStep);
   step = MathMin(step, Inp_DVASS_MaxStep);

   return step;
}

//+------------------------------------------------------------------+
//| MODE 2: DVASS — Dynamic Volatility-Adjusted Spacing                |
//+------------------------------------------------------------------+

/**
 * Calculate DVASS mode spacing
 * Formula: Base × (ATR/20) × SpikeMult × (1.3^Level), clamped
 * Uses cached ATR values — no indicator calls in hot path
 */
double Grid_CalculateDVASS(const int level)
{
   double atr = g_gridCachedATR14;

   //--- Fallback to FIXED if ATR is invalid
   if(atr <= 0 || atr > 200.0)
     {
      if(atr > 200.0)
         Print("[Grid] WARNING: ATR(", atr, ") > 200, falling back to FIXED spacing");
      return Grid_CalculateFixed(level);
     }

   //--- Use pre-computed adjusted base step
   double baseStep = g_gridCachedAdjustedBase;

   //--- Level expansion
   double expansion = 1.0 + Inp_DVASS_Expansion;  // 1.0 + 0.3 = 1.3
   double levelMult = MathPow(expansion, level);

   double step = baseStep * levelMult;

   //--- Apply safety bounds
   step = MathMax(step, Inp_DVASS_MinStep);
   step = MathMin(step, Inp_DVASS_MaxStep);

   return step;
}

//+------------------------------------------------------------------+
//| MODE 3: HYBRID — Regime-Based Adaptive Spacing                     |
//+------------------------------------------------------------------+

/**
 * Calculate HYBRID mode spacing
 * Determines volatility regime, then uses regime-specific parameters
 */
double Grid_CalculateHybrid(const int level)
{
   double atr = g_gridCachedATR14;

   //--- Fallback to FIXED if ATR is invalid
   if(atr <= 0)
      return Grid_CalculateFixed(level);

   //--- Detect volatility regime
   ENUM_VOL_REGIME regime = Grid_DetectRegime(atr);

   //--- Get regime-specific parameters
   double baseStep;
   double expansion;

   switch(regime)
     {
      case VOL_LOW:
         baseStep = DEF_HYBRID_LOW_STEP;
         expansion = 1.2;
         break;

      case VOL_NORMAL:
         baseStep = DEF_HYBRID_NORMAL_STEP;
         expansion = 1.3;
         break;

      case VOL_HIGH:
         baseStep = DEF_HYBRID_HIGH_STEP;
         expansion = 1.4;
         break;

      case VOL_EXTREME:
         baseStep = DEF_HYBRID_EXTREME_STEP;
         expansion = 1.5;
         break;

      default:
         baseStep = DEF_HYBRID_NORMAL_STEP;
         expansion = 1.3;
         break;
     }

   double levelMult = MathPow(expansion, level);
   double step = baseStep * levelMult;

   //--- Apply safety bounds
   step = MathMax(step, Inp_DVASS_MinStep);
   step = MathMin(step, Inp_DVASS_MaxStep);

   return step;
}

/**
 * Detect current volatility regime based on cached ATR(14)
 * @param atr  Current ATR(14) value
 * @return Volatility regime
 */
ENUM_VOL_REGIME Grid_DetectRegime(const double atr)
{
   if(atr < DEF_HYBRID_LOW_ATR)
      return VOL_LOW;
   else if(atr < DEF_HYBRID_NORMAL_ATR)
      return VOL_NORMAL;
   else if(atr < DEF_HYBRID_HIGH_ATR)
      return VOL_HIGH;
   else
      return VOL_EXTREME;
}

//+------------------------------------------------------------------+
//| GRID LEVEL MANAGEMENT — Check & Add                                |
//+------------------------------------------------------------------+

/**
 * Check all active baskets for grid level additions
 * Called from OnTick() — HOT PATH (cache-only)
 * @param bid  Current bid price
 * @param ask  Current ask price
 */
void CheckGridLevels(const double bid, const double ask)
{
   static datetime s_lastAuditTime[SK_MAX_BASKETS];
   static int      s_lastAuditState[SK_MAX_BASKETS];
   datetime now = TimeCurrent();

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(g_baskets[i].status != BASKET_ACTIVE)
         continue;

      int nextLevel = g_baskets[i].levelCount;
      double nextGridDist = GetGridDistance(i, nextLevel);
      bool shouldAdd = Grid_ShouldAddLevel(i, bid, ask);
      double basketHeat = Safety_GetBasketHeat(i);
      int cooldownRemaining = (g_basketLastGridAddTime[i] > 0) ?
                              (DEF_GRID_COOLDOWN_SECONDS - (int)(TimeCurrent() - g_basketLastGridAddTime[i])) : 0;

      int currentState = 0;  // 0=waiting, 1=cooldown, 2=maxlevels, 3=hardmax, 4=heat

      //--- Per-basket cooldown check
      if(g_basketLastGridAddTime[i] > 0 &&
         (TimeCurrent() - g_basketLastGridAddTime[i]) < DEF_GRID_COOLDOWN_SECONDS)
        {
         currentState = 1;
         bool shouldPrint = (currentState != s_lastAuditState[i]) || (now - s_lastAuditTime[i] >= 60);
         if(shouldPrint && Inp_EnableAuditLog)
           {
            Print("[AUDIT] Basket ", g_baskets[i].basketId,
                  " BLOCKED: Cooldown (", cooldownRemaining, "s left)");
            s_lastAuditState[i] = currentState;
            s_lastAuditTime[i] = now;
           }
         continue;
        }

      //--- Skip if already at max levels
      if(g_baskets[i].levelCount >= Inp_MaxGridLevels)
        {
         currentState = 2;
         bool shouldPrint = (currentState != s_lastAuditState[i]) || (now - s_lastAuditTime[i] >= 60);
         if(shouldPrint && Inp_EnableAuditLog)
           {
            Print("[AUDIT] Basket ", g_baskets[i].basketId,
                  " BLOCKED: Max levels (", Inp_MaxGridLevels, ")");
            s_lastAuditState[i] = currentState;
            s_lastAuditTime[i] = now;
           }
         continue;
        }
      if(g_baskets[i].levelCount >= SK_MAX_LEVELS)
        {
         currentState = 3;
         bool shouldPrint = (currentState != s_lastAuditState[i]) || (now - s_lastAuditTime[i] >= 60);
         if(shouldPrint && Inp_EnableAuditLog)
           {
            Print("[AUDIT] Basket ", g_baskets[i].basketId,
                  " BLOCKED: Hard max levels (", SK_MAX_LEVELS, ")");
            s_lastAuditState[i] = currentState;
            s_lastAuditTime[i] = now;
           }
         continue;
        }

      //--- Check per-basket recovery heat limit (Phase 6 safety)
      if(!Safety_EnforceRecoveryHeatLimit(i))
        {
         currentState = 4;
         bool shouldPrint = (currentState != s_lastAuditState[i]) || (now - s_lastAuditTime[i] >= 60);
         if(shouldPrint && Inp_EnableAuditLog)
           {
            Print("[AUDIT] Basket ", g_baskets[i].basketId,
                  " BLOCKED: Heat (", DoubleToString(basketHeat, 2), "% > ", Inp_MaxRecoveryHeat, ")");
            s_lastAuditState[i] = currentState;
            s_lastAuditTime[i] = now;
           }
         continue;
        }

      //--- Check if this basket qualifies for a new level
      if(shouldAdd)
        {
         Print("[AUDIT] Basket ", g_baskets[i].basketId,
               " EXECUTING Grid_AddLevel | NextDist:", DoubleToString(nextGridDist, 1), "pts",
               " | Heat:", DoubleToString(basketHeat, 2), "%",
               " | Levels:", g_baskets[i].levelCount, "/", Inp_MaxGridLevels);
         Grid_AddLevel(i, bid, ask);
         //--- Only one level per tick cycle to respect cooldown
         return;
        }
      else
        {
         currentState = 0;
         bool shouldPrint = (currentState != s_lastAuditState[i]) || (now - s_lastAuditTime[i] >= 60);
         if(shouldPrint && Inp_EnableAuditLog)
           {
            Print("[AUDIT] Basket ", g_baskets[i].basketId,
                  " WAITING | NextDist:", DoubleToString(nextGridDist, 1), "pts",
                  " | Heat:", DoubleToString(basketHeat, 2), "%");
            s_lastAuditState[i] = currentState;
            s_lastAuditTime[i] = now;
           }
        }
     }
}

/**
 * Check if a basket qualifies for a new grid level
 * @param basketIndex  Basket cache index
 * @param bid          Current bid
 * @param ask          Current ask
 * @return true if new level should be added
 */
bool Grid_ShouldAddLevel(const int basketIndex, const double bid, const double ask)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return false;
   if(!g_baskets[basketIndex].isValid)
      return false;

   //--- Get last level price
   int lastLevel = g_baskets[basketIndex].levelCount - 1;
   if(lastLevel < 0)
      return false;

   double lastPrice = g_baskets[basketIndex].levels[lastLevel].openPrice;
   int direction = g_baskets[basketIndex].direction;

   //--- Calculate required spacing for next level
   int nextLevel = g_baskets[basketIndex].levelCount;
   double requiredSpacing = GetGridDistance(basketIndex, nextLevel);

   //--- Convert points to price distance (CRITICAL: XAUUSD tickSize = 0.01)
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double requiredPriceDistance = requiredSpacing * tickSize;

   //--- Check if price has moved far enough
   double priceDistance;

   if(direction == 0)  // BUY basket — price must drop below last level
     {
      priceDistance = lastPrice - bid;
      return (priceDistance >= requiredPriceDistance);
     }
   else  // SELL basket — price must rise above last level
     {
      priceDistance = ask - lastPrice;
      return (priceDistance >= requiredPriceDistance);
     }
}

/**
 * Add a grid level to a basket
 * @param basketIndex  Basket cache index
 * @param bid          Current bid (for BUY)
 * @param ask          Current ask (for SELL)
 */
void Grid_AddLevel(const int basketIndex, const double bid, const double ask)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   int direction = g_baskets[basketIndex].direction;
   double entryPrice;
   ENUM_ORDER_TYPE orderType;

   if(direction == 0)  // BUY
     {
      entryPrice = ask;
      orderType = ORDER_TYPE_BUY;
     }
   else  // SELL
     {
      entryPrice = bid;
      orderType = ORDER_TYPE_SELL;
     }

   //--- Calculate lot size using lot multiplier system
   int newLevel = g_baskets[basketIndex].levelCount;
   double multiplier = GetLotMultiplier(basketIndex, newLevel);
   double baseLot = g_baskets[basketIndex].levels[0].lotSize;
   double newLot = NormalizeDouble(baseLot * multiplier, 2);

   //--- Apply broker constraints
   newLot = Lot_Normalize(newLot);

   //--- Sanity check: don't add if lot is invalid
   if(newLot <= 0)
     {
      Print("[Grid] ERROR: Invalid lot size calculated: ", newLot);
      return;
     }

   //=== EXECUTE REAL TRADE — OrderSend to broker ===
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = newLot;
   request.type = orderType;
   request.price = entryPrice;
   request.deviation = 50;  // 50 points slippage for XAUUSD
   request.magic = g_baskets[basketIndex].originalMagic;
   request.type_filling = Grid_GetFillingMode();
   request.comment = "SK_Grid_L" + IntegerToString(newLevel);

   if(!OrderSend(request, result))
     {
      Print("[Grid] ERROR: OrderSend failed for basket ",
            g_baskets[basketIndex].basketId,
            " | Error: ", GetLastError(),
            " | Retcode: ", result.retcode);
      return;  // Do NOT update SSoT if broker rejected
     }

   if(result.retcode != TRADE_RETCODE_DONE &&
      result.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      Print("[Grid] ERROR: Order not filled for basket ",
            g_baskets[basketIndex].basketId,
            " | Retcode: ", result.retcode);
      return;  // Do NOT update SSoT if not filled
     }

   //--- Get real ticket from broker
   ulong realTicket = result.order;
   if(realTicket <= 0)
      realTicket = result.deal;  // Fallback to deal ticket

   //--- Add level to SSoT with REAL ticket
   bool added = SSoT_AddGridLevel(basketIndex, realTicket, newLot, entryPrice);

   if(added)
     {
      Print("[Grid] Level added: Basket ", g_baskets[basketIndex].basketId,
            " Level ", newLevel,
            " Ticket ", realTicket,
            " Lots ", newLot,
            " Price ", entryPrice);
      g_basketLastGridAddTime[basketIndex] = TimeCurrent();
     }
   else
     {
      Print("[Grid] WARNING: SSoT update failed for basket ",
            g_baskets[basketIndex].basketId,
            " but broker order ", realTicket, " was filled");
     }
}

//+------------------------------------------------------------------+
//| FILLING MODE HELPER — Auto-detect broker support for grid orders   |
//+------------------------------------------------------------------+

ENUM_ORDER_TYPE_FILLING Grid_GetFillingMode()
{
   long fillingMask = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMask & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fillingMask & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_FOK;  // Default fallback
}

//+------------------------------------------------------------------+
//| PUBLIC: Compute next level price for a basket (read-only)          |
//+------------------------------------------------------------------+

/**
 * Calculate the price at which the next grid level would trigger
 * @param basketIndex  Basket cache index
 * @return Next trigger price, or 0 if invalid
 */
double Grid_GetNextLevelPrice(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return 0;
   if(!g_baskets[basketIndex].isValid)
      return 0;

   int lastLevel = g_baskets[basketIndex].levelCount - 1;
   if(lastLevel < 0)
      return 0;

   double lastPrice = g_baskets[basketIndex].levels[lastLevel].openPrice;
   int direction = g_baskets[basketIndex].direction;
   int nextLevel = g_baskets[basketIndex].levelCount;

   double spacing = GetGridDistance(basketIndex, nextLevel);

   //--- Convert points to price distance for XAUUSD
   //--- CRITICAL FIX: Use tickSize (0.01) not SYMBOL_POINT (0.00001)
   //--- 1 EA "point" = 0.01 price units for XAUUSD
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double priceDist = spacing * tickSize;

   if(direction == 0)  // BUY — next level below
      return lastPrice - priceDist;
   else  // SELL — next level above
      return lastPrice + priceDist;
}
