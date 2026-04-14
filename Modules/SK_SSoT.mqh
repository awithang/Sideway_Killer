//+------------------------------------------------------------------+
//|                                               SK_SSoT.mqh        |
//|                                    SIDEWAY KILLER - Phase 1      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"
#include "SK_DataTypes.mqh"
#include "SK_GVSchema.mqh"

//+==================================================================+
//| SINGLE SOURCE OF TRUTH (SSoT) - COMPLETE IMPLEMENTATION            |
//|                                                                    |
//|  Design: Hybrid SSoT with Hot/Cold Path Split                      |
//|                                                                    |
//|  LAYER 1: Terminal Global Variables (Persistence / SSoT)           |
//|  - Authoritative data store, survives restarts                     |
//|  - Write-through on ALL state changes                              |
//|                                                                    |
//|  LAYER 2: In-Memory Cache (Working Copy / Hot Path)                |
//|  - Read-only access during OnTick()                                |
//|  - Refreshed periodically from GVs via OnTimer()                   |
//|                                                                    |
//|  HOT PATH  (OnTick):   Cache read  + Live price  ->  < 1ms         |
//|  COLD PATH (OnTimer):  GV sync + Validation      ->  < 50ms        |
//+==================================================================+

//+------------------------------------------------------------------+
//| INITIALIZATION & LIFECYCLE                                         |
//+------------------------------------------------------------------+

/**
 * Initialize the SSoT system
 * Called from EA OnInit()
 * @return true on success
 */
bool SSoT_Initialize()
{
   g_eaInitTime = TimeCurrent();
   g_cacheValid = false;
   g_basketCount = 0;

   //--- Initialize spread stats with reasonable defaults
   g_spreadStats.average = 10.0;  // Default 10 points for XAUUSD
   g_spreadStats.variance = 4.0;
   g_spreadStats.stdDev = 2.0;

   //--- Initialize market state
   g_market.atr14 = 0;
   g_market.atr100 = 0;
   g_market.volatilityRatio = 1.0;
   g_market.currentSpread = 10.0;
   g_market.spreadRatio = 1.0;

   //--- Initialize trade statistics with Bayesian priors
   g_tradeStats.totalTrades = 0;
   g_tradeStats.wins = 0;
   g_tradeStats.losses = 0;
   g_tradeStats.totalWinAmount = 0;
   g_tradeStats.totalLossAmount = 0;
   g_tradeStats.alpha = Inp_Bayesian_PriorWR * Inp_Bayesian_PriorStr;
   g_tradeStats.beta = (1.0 - Inp_Bayesian_PriorWR) * Inp_Bayesian_PriorStr;

   //--- Initialize user overrides
   g_userOverrides.excludedCount = 0;
   g_userOverrides.forcedCount = 0;
   ArrayInitialize(g_userOverrides.excludedTickets, 0);
   ArrayInitialize(g_userOverrides.forcedTickets, 0);

   //--- Initialize trailing states
   for(int i = 0; i < SK_MAX_BASKETS; i++)
     {
      g_virtualTrail[i].peakPrice = 0;
      g_virtualTrail[i].stopLevel = 0;
      g_virtualTrail[i].isActivated = false;
      g_virtualTrail[i].peakTime = 0;
      g_virtualTrail[i].lastCheck = 0;

      g_checkpoint[i].peakPrice = 0;
      g_checkpoint[i].stopLevel = 0;
      g_checkpoint[i].isActivated = false;
      g_checkpoint[i].savedAt = 0;

      g_apiCache[i].verifiedProfit = 0;
      g_apiCache[i].lastVerify = 0;
      g_apiCache[i].isValid = false;

      g_hasEmergencyStops[i] = false;
      g_emergencyStopSetTime[i] = 0;

      //--- Clear basket cache
      g_baskets[i].basketId = 0;
      g_baskets[i].originalTicket = 0;
      g_baskets[i].originalMagic = 0;
      g_baskets[i].direction = -1;
      g_baskets[i].status = BASKET_CLOSED;
      g_baskets[i].levelCount = 0;
      g_baskets[i].created = 0;
      g_baskets[i].weightedAvg = 0;
      g_baskets[i].totalVolume = 0;
      g_baskets[i].targetProfit = 0;
      g_baskets[i].lastSync = 0;
      g_baskets[i].isValid = false;
      g_baskets[i].trailPeakPrice = 0;
      g_baskets[i].trailActivated = false;

      for(int j = 0; j < SK_MAX_LEVELS; j++)
        {
         g_baskets[i].levels[j].ticket = 0;
         g_baskets[i].levels[j].lotSize = 0;
         g_baskets[i].levels[j].openPrice = 0;
         g_baskets[i].levels[j].openTime = 0;
         g_baskets[i].levels[j].isOriginal = false;
        }
     }

   //--- Dashboard init
   g_dashboard.currentBid = 0;
   g_dashboard.currentAsk = 0;
   g_dashboard.activeBasketCount = 0;
   g_dashboard.totalExposureLots = 0;
   g_dashboard.currentHeatPct = 0;
   g_dashboard.totalFloatingPnL = 0;
   g_dashboard.closestBasketId = -1;
   g_dashboard.closestBasketProgress = 0;
   g_dashboard.lastUpdate = 0;

   //--- Create ATR indicator handles for market state
   g_atrHandle14 = iATR(_Symbol, PERIOD_CURRENT, Inp_DVASS_ATRPeriod);
   g_atrHandle100 = iATR(_Symbol, PERIOD_CURRENT, Inp_DVASS_ATRPeriod * 7);  // ~98 period

   Print("[SSoT] Initialized. Schema v", SK_SCHEMA_VERSION,
         ", Max baskets: ", SK_MAX_BASKETS,
         ", Max levels: ", SK_MAX_LEVELS);

   //--- One-Time GV Purge: Clean up orphan baskets from previous sessions
   SSoT_PurgeOrphanGVs();

   return true;
}

/**
 * Deinitialize the SSoT system
 * Called from EA OnDeinit()
 * @param reason  Deinitialization reason
 */
void SSoT_Deinit(const int reason)
{
   //--- Save final state
   SSoT_SaveToGlobals();

   //--- Release indicator handles
   if(g_atrHandle14 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle14);
   if(g_atrHandle100 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle100);

   //--- Optionally clear all GVs on clean removal
   if(reason == REASON_REMOVE)
     {
      //--- Keep basket data for potential restart, only clear temp state
      SSoT_WriteGlobalStateToGVs();
     }

   Print("[SSoT] Deinitialized. Reason: ", reason);
}

//--- Forward declarations for Adoption module functions
//--- (Adoption.mqh includes SSoT.mqh, so we can't #include it here)
void Adoption_MarkTicketAdopted(const ulong ticket);
void Adoption_ScanOrphansOnStartup();
bool Adoption_IsTicketAdopted(const ulong ticket);  // Added for GV-persistent check
void Adoption_LoadFromGVs();  // Added for GV-persistent adoption tracking

//+------------------------------------------------------------------+
//| HOT PATH: Cache-only read operations                               |
//| CRITICAL: These functions MUST NOT call any GlobalVariable API     |
//+------------------------------------------------------------------+

/**
 * Check if the cache is currently valid
 * @return true if cache is ready for hot-path reads
 */
bool SSoT_IsCacheValid()
{
   return g_cacheValid;
}

/**
 * Get current basket count from cache
 * @return Number of active baskets
 */
int SSoT_GetBasketCount()
{
   return g_basketCount;
}

/**
 * Get a basket from cache by index
 * @param index     Basket index (0-based)
 * @param outBasket Output structure
 * @return true if basket exists and is valid
 */
bool SSoT_GetBasket(const int index, BasketCache &outBasket)
{
   if(index < 0 || index >= g_basketCount)
      return false;
   if(!g_baskets[index].isValid)
      return false;

   outBasket = g_baskets[index];
   return true;
}

/**
 * Get weighted average price from cache (inline-able for speed)
 * @param index  Basket index
 * @return Weighted average price, or 0 if invalid
 */
double SSoT_GetWeightedAvg(const int index)
{
   if(index < 0 || index >= g_basketCount)
      return 0;
   if(!g_baskets[index].isValid)
      return 0;
   return g_baskets[index].weightedAvg;
}

/**
 * Get total volume from cache
 * @param index  Basket index
 * @return Total volume in lots
 */
double SSoT_GetTotalVolume(const int index)
{
   if(index < 0 || index >= g_basketCount)
      return 0;
   if(!g_baskets[index].isValid)
      return 0;
   return g_baskets[index].totalVolume;
}

/**
 * Get target profit from cache
 * @param index  Basket index
 * @return Target profit in USD
 */
double SSoT_GetTargetProfit(const int index)
{
   if(index < 0 || index >= g_basketCount)
      return 0;
   if(!g_baskets[index].isValid)
      return 0;
   return g_baskets[index].targetProfit;
}

/**
 * Get level count from cache
 * @param index  Basket index
 * @return Number of levels in basket
 */
int SSoT_GetLevelCount(const int index)
{
   if(index < 0 || index >= g_basketCount)
      return 0;
   if(!g_baskets[index].isValid)
      return 0;
   return g_baskets[index].levelCount;
}

/**
 * Get direction from cache
 * @param index  Basket index
 * @return 0=BUY, 1=SELL, -1=invalid
 */
int SSoT_GetDirection(const int index)
{
   if(index < 0 || index >= g_basketCount)
      return -1;
   if(!g_baskets[index].isValid)
      return -1;
   return g_baskets[index].direction;
}

//+------------------------------------------------------------------+
//| COLD PATH: GV Synchronization (called from OnTimer)               |
//+------------------------------------------------------------------+

/**
 * Refresh entire cache from Global Variables
 * Called periodically from OnTimer()
 */
void SSoT_RefreshCacheFromGlobals()
{
   //--- Read global state first
   SSoT_ReadGlobalStateFromGVs();

   //--- PRESERVE fresh baskets (created < 30s ago) that might not have GVs yet
   //--- This prevents the 'Ghost Basket' wipe after manual trade creation
   //--- CRITICAL FIX: Extended from 5s to 30s to handle slow GV writes
   BasketCache preservedBaskets[];
   ArrayResize(preservedBaskets, SK_MAX_BASKETS);
   int preservedCount = 0;
   const int FRESH_WINDOW_SECONDS = 30;  // Increased from 5 to 30 seconds

   for(int i = 0; i < g_basketCount; i++)
     {
      if(g_baskets[i].isValid && (TimeCurrent() - g_baskets[i].created < FRESH_WINDOW_SECONDS))
        {
         preservedBaskets[preservedCount] = g_baskets[i];
         preservedCount++;
        }
     }

   //--- Load baskets from GVs (standard behavior)
   int loaded = 0;
   for(ulong id = 1; id <= (ulong)SK_MAX_BASKETS && loaded < SK_MAX_BASKETS; id++)
     {
      string statusName = GV_Name(id, GV_BASKET_STATUS);

      //--- Quick existence check
      if(!GlobalVariableCheck(statusName))
         continue;

      double statusVal = GlobalVariableGet(statusName);

      //--- Skip closed baskets
      if(statusVal >= 2.0)
         continue;

      //--- Read full basket from GVs
      BasketCache tempBasket;
      if(SSoT_ReadBasketFromGlobals(id, tempBasket) && tempBasket.isValid)
        {
         //--- Copy to cache
         g_baskets[loaded] = tempBasket;
         g_baskets[loaded].lastSync = TimeCurrent();
         g_baskets[loaded].isValid = true;

         //--- Sync inline trailing state
         g_baskets[loaded].trailPeakPrice = g_virtualTrail[loaded].peakPrice;
         g_baskets[loaded].trailActivated = g_virtualTrail[loaded].isActivated;

         //--- Load trailing checkpoint
         SSoT_LoadTrailingCheckpoint(id, loaded);

         loaded++;
        }
     }

   //--- MERGE: add preserved fresh baskets that weren't loaded from GVs
   for(int i = 0; i < preservedCount; i++)
     {
      bool alreadyLoaded = false;
      for(int j = 0; j < loaded; j++)
        {
         if(g_baskets[j].basketId == preservedBaskets[i].basketId)
           {
            alreadyLoaded = true;
            break;
           }
        }

      if(!alreadyLoaded && loaded < SK_MAX_BASKETS)
        {
         g_baskets[loaded] = preservedBaskets[i];
         loaded++;
        }
     }

   //--- Clear unused slots beyond merged count
   for(int i = loaded; i < g_basketCount; i++)
     {
      g_baskets[i].isValid = false;
      g_baskets[i].basketId = 0;
     }

   //--- Update basket count
   g_basketCount = loaded;
   g_cacheValid = true;

   //--- Update dashboard
   SSoT_UpdateDashboard();

   //--- CRITICAL: Emergency Adoption Re-Link
   //--- If basketCount == 0 but positions exist, force immediate rebuild
   if(g_basketCount == 0)
     {
      //--- Check if ANY physical positions exist
      bool hasPositions = false;
      ulong foundTicket = 0;

      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;

         if(PositionSelectByTicket(ticket))
           {
            hasPositions = true;
            foundTicket = ticket;
            break;
           }
        }

      if(hasPositions)
        {
         Print("[SSoT] EMERGENCY: No baskets in cache but physical positions exist!",
               " Found ticket: ", foundTicket, " - forcing orphan scan to rebuild baskets");

         //--- Force immediate orphan scan to rebuild baskets
         Adoption_ScanOrphansOnStartup();

         //--- If orphan scan found positions, update count
         if(g_basketCount > 0)
           {
            Print("[SSoT] EMERGENCY RECOVERY: Rebuilt ", g_basketCount, " basket(s) from orphaned positions");
            g_cacheValid = true;
           }
        }
     }

   //--- Load trade stats
   SSoT_LoadTradeStats();
}

/**
 * Load trailing checkpoint for a specific basket
 * @param basketId     Basket ID (1-based)
 * @param cacheIndex   Cache array index (0-based)
 */
void SSoT_LoadTrailingCheckpoint(const ulong basketId, const int cacheIndex)
{
   string trailName = GV_TrailName(basketId, GV_TRAIL_ACTIVE);
   if(!GlobalVariableCheck(trailName))
      return;

   g_virtualTrail[cacheIndex].isActivated =
      (GlobalVariableGet(trailName) != 0.0);
   g_virtualTrail[cacheIndex].peakPrice =
      GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_PEAK));
   g_virtualTrail[cacheIndex].stopLevel =
      GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_STOP));
   g_virtualTrail[cacheIndex].peakTime =
      (datetime)GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_TIME));
}

/**
 * Validate cache consistency against GVs
 * Called periodically to detect drift
 */
void SSoT_ValidateCacheConsistency()
{
   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;

      ulong id = g_baskets[i].basketId;

      //--- Spot-check weighted average
      string waName = GV_Name(id, GV_BASKET_WA);
      if(GlobalVariableCheck(waName))
        {
         double gvWA = GlobalVariableGet(waName);
         double cacheWA = g_baskets[i].weightedAvg;

         //--- Allow XAUUSD pricing precision tolerance (0.1 = 1 pip)
         if(MathAbs(cacheWA - gvWA) > 0.1)
           {
            Print("[SSoT] WARNING: Cache drift detected. Basket ", id,
                  " WA cache=", cacheWA, " GV=", gvWA);
            //--- Force re-sync
            SSoT_RefreshCacheFromGlobals();
            return;
           }
        }

      //--- Spot-check volume
      string volName = GV_Name(id, GV_BASKET_VOL);
      if(GlobalVariableCheck(volName))
        {
         double gvVol = GlobalVariableGet(volName);
         double cacheVol = g_baskets[i].totalVolume;

         if(MathAbs(cacheVol - gvVol) > 0.001)
           {
            Print("[SSoT] WARNING: Volume drift. Basket ", id,
                  " Vol cache=", cacheVol, " GV=", gvVol);
            SSoT_RefreshCacheFromGlobals();
            return;
           }
        }
     }
}

/**
 * Update dashboard metrics in Global Variables
 */
void SSoT_UpdateDashboard()
{
   //--- Count active baskets and total exposure
   int activeCount = 0;
   double totalVol = 0;

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(g_baskets[i].status != BASKET_ACTIVE)
         continue;

      activeCount++;
      totalVol += g_baskets[i].totalVolume;
     }

   g_dashboard.activeBasketCount = activeCount;
   g_dashboard.totalExposureLots = totalVol;

   //--- Get live prices
   g_dashboard.currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_dashboard.currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- Calculate heat
   g_dashboard.currentHeatPct = SSoT_CalculateHeatPct();

   //--- Find closest basket to target
   int closestId = -1;
   double closestProgress = 0;

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid || g_baskets[i].status != BASKET_ACTIVE)
         continue;

      double progress = SSoT_CalcBasketProgress(i);
      if(progress > closestProgress)
        {
         closestProgress = progress;
         closestId = (int)g_baskets[i].basketId;
        }
     }

   g_dashboard.closestBasketId = closestId;
   g_dashboard.closestBasketProgress = closestProgress;
   g_dashboard.lastUpdate = TimeCurrent();

   //--- Write to GVs
   GlobalVariableSet(GV_DashName(GV_DASH_BID), g_dashboard.currentBid);
   GlobalVariableSet(GV_DashName(GV_DASH_ASK), g_dashboard.currentAsk);
   GlobalVariableSet(GV_DashName(GV_DASH_COUNT), (double)activeCount);
   GlobalVariableSet(GV_DashName(GV_DASH_HEAT), g_dashboard.currentHeatPct);
   GlobalVariableSet(GV_DashName(GV_DASH_PNL), g_dashboard.totalFloatingPnL);
   GlobalVariableSet(GV_DashName(GV_DASH_CLOSEST_ID), (double)closestId);
   GlobalVariableSet(GV_DashName(GV_DASH_CLOSEST_PRG), closestProgress);
   GlobalVariableSet(GV_DashName(GV_DASH_UPDATED), (double)TimeCurrent());
}

/**
 * Calculate current account heat as percentage
 * @return Heat percentage (0.0 - 100.0)
 */
double SSoT_CalculateHeatPct()
{
   double totalDrawdown = 0;

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid || g_baskets[i].status != BASKET_ACTIVE)
         continue;

      double currentPrice = 0;
      if(g_baskets[i].direction == 0)  // BUY
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      else
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double dist = 0;
      if(g_baskets[i].direction == 0)
         dist = g_baskets[i].weightedAvg - currentPrice;
      else
         dist = currentPrice - g_baskets[i].weightedAvg;

      if(dist > 0)
        {
         double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         double valuePerPoint = (tickSize > 0) ? tickValue / tickSize : 100.0;
         totalDrawdown += dist * g_baskets[i].totalVolume * valuePerPoint;
        }
     }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0)
      return 0;

   return (totalDrawdown / balance) * 100.0;
}

/**
 * Calculate how close a basket is to its profit target (0.0 - 1.0+)
 * @param index  Basket index
 * @return Progress ratio (1.0 = target reached)
 */
double SSoT_CalcBasketProgress(const int index)
{
   if(index < 0 || index >= g_basketCount)
      return 0;
   if(!g_baskets[index].isValid)
      return 0;
   if(g_baskets[index].targetProfit <= 0)
      return 0;

   double currentPrice = 0;
   if(g_baskets[index].direction == 0)
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double dist = 0;
   if(g_baskets[index].direction == 0)
      dist = currentPrice - g_baskets[index].weightedAvg;
   else
      dist = g_baskets[index].weightedAvg - currentPrice;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double valuePerPoint = (tickSize > 0) ? tickValue / tickSize : 100.0;

   double profit = dist * g_baskets[index].totalVolume * valuePerPoint;

   if(profit <= 0)
      return 0;

   return profit / g_baskets[index].targetProfit;
}

//+------------------------------------------------------------------+
//| STATE CHANGE: Write-through to SSoT                                |
//| All state changes MUST go through these functions                  |
//+------------------------------------------------------------------+

/**
 * Create a new basket and write to SSoT
 * @param ticket     Position ticket
 * @param openPrice  Position open price
 * @param lots       Position lot size
 * @param dir        Direction: 0=BUY, 1=SELL
 * @param magic      Position magic number
 * @return Cache index (0-based) or -1 on failure
 */
int SSoT_CreateBasket(const ulong ticket, const double openPrice,
                      const double lots, const int dir, const ulong magic)
{
   //--- Check capacity
   if(g_basketCount >= SK_MAX_BASKETS)
     {
      Print("[SSoT] ERROR: Max baskets reached (", SK_MAX_BASKETS, ")");
      return -1;
     }

   if(g_basketCount >= Inp_MaxConcurrentBaskets)
     {
      Print("[SSoT] WARNING: Max concurrent baskets limit reached (",
            Inp_MaxConcurrentBaskets, ")");
      return -1;
     }

   //--- Get next basket ID
   ulong basketId = SSoT_GetNextBasketId();

   //--- Find free slot in cache
   int slot = g_basketCount;

   //--- Initialize cache entry
   g_baskets[slot].basketId = basketId;
   g_baskets[slot].originalTicket = ticket;
   g_baskets[slot].originalMagic = magic;
   g_baskets[slot].direction = dir;
   g_baskets[slot].status = BASKET_ACTIVE;
   g_baskets[slot].levelCount = 1;
   g_baskets[slot].created = TimeCurrent();
   g_baskets[slot].weightedAvg = openPrice;
   g_baskets[slot].totalVolume = lots;
   g_baskets[slot].targetProfit = Inp_ProfitTargetUSD;
   g_baskets[slot].lastSync = TimeCurrent();
   g_baskets[slot].isValid = true;
   g_baskets[slot].trailPeakPrice = 0;
   g_baskets[slot].trailActivated = false;

   //--- Initialize Level 0
   g_baskets[slot].levels[0].ticket = ticket;
   g_baskets[slot].levels[0].lotSize = lots;
   g_baskets[slot].levels[0].openPrice = openPrice;
   g_baskets[slot].levels[0].openTime = TimeCurrent();
   g_baskets[slot].levels[0].isOriginal = true;

   //--- Clear remaining levels
   for(int i = 1; i < SK_MAX_LEVELS; i++)
     {
      g_baskets[slot].levels[i].ticket = 0;
      g_baskets[slot].levels[i].lotSize = 0;
      g_baskets[slot].levels[i].openPrice = 0;
      g_baskets[slot].levels[i].openTime = 0;
      g_baskets[slot].levels[i].isOriginal = false;
     }

   //--- Reset trailing state
   g_virtualTrail[slot].peakPrice = openPrice;
   g_virtualTrail[slot].stopLevel = 0;
   g_virtualTrail[slot].isActivated = false;
   g_virtualTrail[slot].peakTime = TimeCurrent();
   g_virtualTrail[slot].lastCheck = TimeCurrent();

   //--- Update basket count FIRST (so WriteBasketToGlobals boundary check passes)
   g_basketCount++;
   g_cacheValid = true;

   //--- Write-through to SSoT (atomic group)
   SSoT_WriteBasketToGlobals(slot);

   Print("[SSoT] Basket created: ID=", basketId,
         " Ticket=", ticket,
         " Dir=", (dir == 0 ? "BUY" : "SELL"),
         " Lots=", lots,
         " Price=", openPrice);

   return slot;
}

/**
 * Add a grid level to an existing basket
 * @param basketIndex  Cache index (0-based)
 * @param ticket       New position ticket
 * @param lots         New position lot size
 * @param price        Entry price
 * @return true on success
 */
bool SSoT_AddGridLevel(const int basketIndex, const ulong ticket,
                       const double lots, const double price)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return false;
   if(!g_baskets[basketIndex].isValid)
      return false;

   int currentLevels = g_baskets[basketIndex].levelCount;

   //--- Check max levels
   if(currentLevels >= Inp_MaxGridLevels)
     {
      Print("[SSoT] WARNING: Max grid levels reached for basket ",
            g_baskets[basketIndex].basketId);
      return false;
     }

   if(currentLevels >= SK_MAX_LEVELS)
     {
      Print("[SSoT] ERROR: Hard level limit reached (", SK_MAX_LEVELS, ")");
      return false;
     }

   //--- Calculate new weighted average
   double oldVol = g_baskets[basketIndex].totalVolume;
   double oldWA = g_baskets[basketIndex].weightedAvg;
   double newVol = oldVol + lots;
   double newWA = ((oldWA * oldVol) + (price * lots)) / newVol;

   //--- Update cache
   int newLevel = currentLevels;
   g_baskets[basketIndex].levels[newLevel].ticket = ticket;
   g_baskets[basketIndex].levels[newLevel].lotSize = lots;
   g_baskets[basketIndex].levels[newLevel].openPrice = price;
   g_baskets[basketIndex].levels[newLevel].openTime = TimeCurrent();
   g_baskets[basketIndex].levels[newLevel].isOriginal = false;

   g_baskets[basketIndex].levelCount = newLevel + 1;
   g_baskets[basketIndex].totalVolume = newVol;
   g_baskets[basketIndex].weightedAvg = newWA;
   g_baskets[basketIndex].lastSync = TimeCurrent();

   //--- Write-through to SSoT
   SSoT_WriteBasketToGlobals(basketIndex);

   //--- Update cooldown
   g_lastGridAddTime = TimeCurrent();

   Print("[SSoT] Grid level added: Basket=", g_baskets[basketIndex].basketId,
         " Level=", newLevel,
         " Ticket=", ticket,
         " Lots=", lots,
         " Price=", price,
         " New WA=", newWA);

   return true;
}

/**
 * Update basket status and write to SSoT
 * @param basketIndex  Cache index
 * @param status       New status
 */
void SSoT_UpdateBasketStatus(const int basketIndex,
                              const ENUM_BASKET_STATUS status)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;

   g_baskets[basketIndex].status = status;
   g_baskets[basketIndex].lastSync = TimeCurrent();

   //--- Write-through
   string statusGV = GV_Name(g_baskets[basketIndex].basketId, GV_BASKET_STATUS);
   GlobalVariableSet(statusGV, (double)status);
}

/**
 * Close a basket completely
 * @param basketIndex  Cache index
 */
void SSoT_CloseBasket(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;

   ulong id = g_baskets[basketIndex].basketId;

   //--- CRITICAL: Check if physical positions still exist before deleting basket
   //--- This prevents orphaned trades from running without EA supervision
   if(SSoT_HasOpenPositions(g_baskets[basketIndex]))
     {
      Print("[SSoT] CRITICAL ERROR: Attempted to close basket ", id,
            " but physical positions still exist! ABORTING deletion to prevent orphaned trades.");

      //--- Force status back to ACTIVE to ensure EA continues managing these positions
      g_baskets[basketIndex].status = BASKET_ACTIVE;
      string statusGV = GV_Name(id, GV_BASKET_STATUS);
      GlobalVariableSet(statusGV, (double)BASKET_ACTIVE);

      return;  // Do NOT delete basket if positions still exist
     }

   //--- Update status
   g_baskets[basketIndex].status = BASKET_CLOSED;
   g_baskets[basketIndex].lastSync = TimeCurrent();

   //--- Clear trailing state BEFORE compaction (using current valid index)
   g_virtualTrail[basketIndex].isActivated = false;
   g_virtualTrail[basketIndex].peakPrice = 0;
   g_virtualTrail[basketIndex].stopLevel = 0;

   //--- Delete trailing GVs
   GlobalVariableDel(GV_TrailName(id, GV_TRAIL_PEAK));
   GlobalVariableDel(GV_TrailName(id, GV_TRAIL_STOP));
   GlobalVariableDel(GV_TrailName(id, GV_TRAIL_ACTIVE));
   GlobalVariableDel(GV_TrailName(id, GV_TRAIL_TIME));

   //--- Delete all basket core GVs (9 fields)
   GlobalVariableDel(GV_Name(id, GV_BASKET_WA));
   GlobalVariableDel(GV_Name(id, GV_BASKET_VOL));
   GlobalVariableDel(GV_Name(id, GV_BASKET_TARGET));
   GlobalVariableDel(GV_Name(id, GV_BASKET_STATUS));
   GlobalVariableDel(GV_Name(id, GV_BASKET_LEVELS));
   GlobalVariableDel(GV_Name(id, GV_BASKET_DIR));
   GlobalVariableDel(GV_Name(id, GV_BASKET_CREATED));
   GlobalVariableDel(GV_Name(id, GV_BASKET_MAGIC));
   GlobalVariableDel(GV_Name(id, GV_BASKET_TICKET0));

   //--- Delete all per-level GVs (5 fields per level)
   for(int i = 0; i < g_baskets[basketIndex].levelCount; i++)
     {
      GlobalVariableDel(GV_LevelName(id, i, GV_LEVEL_TICKET));
      GlobalVariableDel(GV_LevelName(id, i, GV_LEVEL_LOT));
      GlobalVariableDel(GV_LevelName(id, i, GV_LEVEL_PRICE));
      GlobalVariableDel(GV_LevelName(id, i, GV_LEVEL_TIME));
      GlobalVariableDel(GV_LevelName(id, i, GV_LEVEL_ORIGINAL));
     }

   //--- Invalidate cache entry
   g_baskets[basketIndex].isValid = false;

   //--- Compact basket array (remove gap)
   SSoT_CompactBaskets();

   //--- Update global state
   SSoT_WriteGlobalStateToGVs();

   //--- Update dashboard
   SSoT_UpdateDashboard();

   Print("[SSoT] Basket closed & GVs flushed: ID=", id);
}

/**
 * Compact the basket array after closure
 * Removes gaps by shifting valid entries down
 */
void SSoT_CompactBaskets()
{
   int writeIdx = 0;

   for(int readIdx = 0; readIdx < g_basketCount; readIdx++)
     {
      if(g_baskets[readIdx].isValid)
        {
         if(writeIdx != readIdx)
           {
            g_baskets[writeIdx] = g_baskets[readIdx];
            //--- Sync trailing state
            g_virtualTrail[writeIdx] = g_virtualTrail[readIdx];
            g_checkpoint[writeIdx] = g_checkpoint[readIdx];
            g_apiCache[writeIdx] = g_apiCache[readIdx];
           }
         writeIdx++;
        }
     }

   //--- Clear remaining slots
   for(int i = writeIdx; i < g_basketCount; i++)
     {
      g_baskets[i].isValid = false;
      g_baskets[i].basketId = 0;
      g_virtualTrail[i].isActivated = false;
      g_virtualTrail[i].peakPrice = 0;
      g_virtualTrail[i].stopLevel = 0;
     }

   g_basketCount = writeIdx;
}

/**
 * Save trailing checkpoint for a basket to GVs
 * @param basketIndex  Cache index
 */
void SSoT_SaveTrailingCheckpoint(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   ulong id = g_baskets[basketIndex].basketId;

   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_PEAK),
                     g_virtualTrail[basketIndex].peakPrice);
   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_STOP),
                     g_virtualTrail[basketIndex].stopLevel);
   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_ACTIVE),
                     g_virtualTrail[basketIndex].isActivated ? 1.0 : 0.0);
   GlobalVariableSet(GV_TrailName(id, GV_TRAIL_TIME),
                     (double)g_virtualTrail[basketIndex].peakTime);

   g_checkpoint[basketIndex].peakPrice = g_virtualTrail[basketIndex].peakPrice;
   g_checkpoint[basketIndex].stopLevel = g_virtualTrail[basketIndex].stopLevel;
   g_checkpoint[basketIndex].isActivated = g_virtualTrail[basketIndex].isActivated;
   g_checkpoint[basketIndex].savedAt = TimeCurrent();
}

/**
 * Load trailing checkpoint into a specific basket cache entry
 * Loads basic fields only — Trailing module loads v2.0 fields separately
 * @param basketId     Basket ID (1-based)
 * @param cacheIndex   Cache array index (0-based)
 */
void SSoT_LoadTrailingCheckpointIntoBasket(const ulong basketId, const int cacheIndex)
{
   if(cacheIndex < 0 || cacheIndex >= SK_MAX_BASKETS)
      return;

   string trailActive = GV_TrailName(basketId, GV_TRAIL_ACTIVE);
   if(!GlobalVariableCheck(trailActive))
      return;

   g_virtualTrail[cacheIndex].isActivated =
      (GlobalVariableGet(trailActive) != 0.0);
   g_virtualTrail[cacheIndex].peakPrice =
      GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_PEAK));
   g_virtualTrail[cacheIndex].stopLevel =
      GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_STOP));
   g_virtualTrail[cacheIndex].peakTime =
      (datetime)GlobalVariableGet(GV_TrailName(basketId, GV_TRAIL_TIME));

   //--- Sync inline cache trailing
   g_baskets[cacheIndex].trailPeakPrice = g_virtualTrail[cacheIndex].peakPrice;
   g_baskets[cacheIndex].trailActivated = g_virtualTrail[cacheIndex].isActivated;
}

//+------------------------------------------------------------------+
//| WRITE-THROUGH: Write basket to Global Variables                    |
//| Writes all 9 core fields + all level data + trailing as a group    |
//+------------------------------------------------------------------+

/**
 * Write a single basket to Global Variables (atomic group write)
 * Writes all core fields, all level fields, and trailing state
 * @param basketIndex  Cache index (0-based)
 */
void SSoT_WriteBasketToGlobals(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   ulong id = g_baskets[basketIndex].basketId;

   //--- Write 9 core basket fields
   GlobalVariableSet(GV_Name(id, GV_BASKET_WA),
                     g_baskets[basketIndex].weightedAvg);
   GlobalVariableSet(GV_Name(id, GV_BASKET_VOL),
                     g_baskets[basketIndex].totalVolume);
   GlobalVariableSet(GV_Name(id, GV_BASKET_TARGET),
                     g_baskets[basketIndex].targetProfit);
   GlobalVariableSet(GV_Name(id, GV_BASKET_STATUS),
                     (double)g_baskets[basketIndex].status);
   GlobalVariableSet(GV_Name(id, GV_BASKET_LEVELS),
                     (double)g_baskets[basketIndex].levelCount);
   GlobalVariableSet(GV_Name(id, GV_BASKET_DIR),
                     (double)g_baskets[basketIndex].direction);
   GlobalVariableSet(GV_Name(id, GV_BASKET_CREATED),
                     (double)g_baskets[basketIndex].created);
   GlobalVariableSet(GV_Name(id, GV_BASKET_MAGIC),
                     (double)g_baskets[basketIndex].originalMagic);
   GlobalVariableSet(GV_Name(id, GV_BASKET_TICKET0),
                     (double)g_baskets[basketIndex].originalTicket);

   //--- Write per-level data
   int levels = g_baskets[basketIndex].levelCount;
   for(int i = 0; i < levels && i < SK_MAX_LEVELS; i++)
     {
      GlobalVariableSet(GV_LevelName(id, i, GV_LEVEL_TICKET),
                        (double)g_baskets[basketIndex].levels[i].ticket);
      GlobalVariableSet(GV_LevelName(id, i, GV_LEVEL_LOT),
                        g_baskets[basketIndex].levels[i].lotSize);
      GlobalVariableSet(GV_LevelName(id, i, GV_LEVEL_PRICE),
                        g_baskets[basketIndex].levels[i].openPrice);
      GlobalVariableSet(GV_LevelName(id, i, GV_LEVEL_TIME),
                        (double)g_baskets[basketIndex].levels[i].openTime);
      GlobalVariableSet(GV_LevelName(id, i, GV_LEVEL_ORIGINAL),
                        g_baskets[basketIndex].levels[i].isOriginal ? 1.0 : 0.0);
     }

   //--- Write trailing checkpoint
   SSoT_SaveTrailingCheckpoint(basketIndex);

   //--- Post-write verification: check 3 critical fields
   double verifyWA = GlobalVariableGet(GV_Name(id, GV_BASKET_WA));
   double verifyVol = GlobalVariableGet(GV_Name(id, GV_BASKET_VOL));
   double verifyStatus = GlobalVariableGet(GV_Name(id, GV_BASKET_STATUS));

   if(MathAbs(verifyWA - g_baskets[basketIndex].weightedAvg) > 0.1 ||
      MathAbs(verifyVol - g_baskets[basketIndex].totalVolume) > 0.001 ||
      verifyStatus != (double)g_baskets[basketIndex].status)
     {
      Print("[SSoT] ERROR: Write verification FAILED for basket ", id,
            " WA gv=", verifyWA, " cache=", g_baskets[basketIndex].weightedAvg,
            " VOL gv=", verifyVol, " cache=", g_baskets[basketIndex].totalVolume,
            " STS gv=", verifyStatus, " cache=", g_baskets[basketIndex].status);
      //--- CRITICAL FIX: Retry write ONCE and verify again
      SSoT_WriteBasketToGlobals(basketIndex);

      //--- Second verification
      verifyWA = GlobalVariableGet(GV_Name(id, GV_BASKET_WA));
      verifyVol = GlobalVariableGet(GV_Name(id, GV_BASKET_VOL));
      verifyStatus = GlobalVariableGet(GV_Name(id, GV_BASKET_STATUS));

      if(MathAbs(verifyWA - g_baskets[basketIndex].weightedAvg) > 0.1 ||
         MathAbs(verifyVol - g_baskets[basketIndex].totalVolume) > 0.001 ||
         verifyStatus != (double)g_baskets[basketIndex].status)
        {
         Print("[SSoT] CRITICAL: Basket ", id, " write FAILED after retry - marking invalid");
         g_baskets[basketIndex].isValid = false;
         g_basketCount--;  // Revert count
         return;  // Don't mark as valid if write failed
        }
     }

   //--- Update global state
   SSoT_WriteGlobalStateToGVs();
}

/**
 * Read a single basket from Global Variables
 * RESILIENT: Tolerates minor data inconsistencies
 * @param basketId   Basket ID (1-based)
 * @param outBasket  Output basket structure
 * @return true if basket was loaded (even partially)
 */
bool SSoT_ReadBasketFromGlobals(const ulong basketId, BasketCache &outBasket)
{
   //--- Check existence
   string statusName = GV_Name(basketId, GV_BASKET_STATUS);
   if(!GlobalVariableCheck(statusName))
      return false;

   //--- Read core fields with safe defaults
   outBasket.basketId = basketId;
   outBasket.weightedAvg = GlobalVariableGet(GV_Name(basketId, GV_BASKET_WA));
   outBasket.totalVolume = GlobalVariableGet(GV_Name(basketId, GV_BASKET_VOL));
   outBasket.targetProfit = GlobalVariableGet(GV_Name(basketId, GV_BASKET_TARGET));
   outBasket.status = (ENUM_BASKET_STATUS)(int)GlobalVariableGet(statusName);
   outBasket.levelCount = (int)GlobalVariableGet(GV_Name(basketId, GV_BASKET_LEVELS));
   outBasket.direction = (int)GlobalVariableGet(GV_Name(basketId, GV_BASKET_DIR));
   outBasket.created = (datetime)GlobalVariableGet(GV_Name(basketId, GV_BASKET_CREATED));
   outBasket.originalMagic = (ulong)GlobalVariableGet(GV_Name(basketId, GV_BASKET_MAGIC));
   outBasket.originalTicket = (ulong)GlobalVariableGet(GV_Name(basketId, GV_BASKET_TICKET0));

   //--- RESILIENT VALIDATION: Fix bad data instead of rejecting
   if(outBasket.levelCount <= 0)
      outBasket.levelCount = 1;  // Assume at least 1 level
   if(outBasket.levelCount > SK_MAX_LEVELS)
      outBasket.levelCount = SK_MAX_LEVELS;
   if(outBasket.direction != 0 && outBasket.direction != 1)
     {
      // Try to infer direction from price context
      outBasket.direction = 0;  // Default to BUY
     }

   //--- Read level data (needed before position check)
   for(int i = 0; i < outBasket.levelCount && i < SK_MAX_LEVELS; i++)
     {
      outBasket.levels[i].ticket =
         (ulong)GlobalVariableGet(GV_LevelName(basketId, i, GV_LEVEL_TICKET));
      outBasket.levels[i].lotSize =
         GlobalVariableGet(GV_LevelName(basketId, i, GV_LEVEL_LOT));
      outBasket.levels[i].openPrice =
         GlobalVariableGet(GV_LevelName(basketId, i, GV_LEVEL_PRICE));
      outBasket.levels[i].openTime =
         (datetime)GlobalVariableGet(GV_LevelName(basketId, i, GV_LEVEL_TIME));
      outBasket.levels[i].isOriginal =
         (GlobalVariableGet(GV_LevelName(basketId, i, GV_LEVEL_ORIGINAL)) != 0.0);
     }

   //--- Clear unused levels
   for(int i = outBasket.levelCount; i < SK_MAX_LEVELS; i++)
     {
      outBasket.levels[i].ticket = 0;
      outBasket.levels[i].lotSize = 0;
      outBasket.levels[i].openPrice = 0;
      outBasket.levels[i].openTime = 0;
      outBasket.levels[i].isOriginal = false;
     }

   //--- If level 0 ticket is 0 but originalTicket is set, use it
   if(outBasket.levels[0].ticket == 0 && outBasket.originalTicket > 0)
      outBasket.levels[0].ticket = outBasket.originalTicket;

   //--- CRITICAL: Check for CLOSED basket with open positions (orphaned trades)
   if(outBasket.status >= BASKET_CLOSED)
     {
      if(SSoT_HasOpenPositions(outBasket))
        {
         //--- EMERGENCY: Physical positions exist but basket marked CLOSED
         //--- Force basket back to ACTIVE to prevent orphaned trades
         Print("[SSoT] EMERGENCY: Basket ", basketId, " marked CLOSED but positions still open!",
               " Forcing ACTIVE status. Ticket: ", outBasket.levels[0].ticket);
         outBasket.status = BASKET_ACTIVE;
        }
      else
        {
         //--- Truly closed, skip loading
         Print("[SSoT] Skipping CLOSED basket ", basketId, " - no physical positions found");
         return false;
        }
     }

   outBasket.lastSync = TimeCurrent();
   outBasket.isValid = true;

   return true;
}

/**
 * CRITICAL: Check if ANY physical position exists for basket tickets
 * Prevents orphaned trades by verifying broker still holds positions
 * @param basket  Basket to check
 * @return true if at least one physical position is still open
 */
bool SSoT_HasOpenPositions(const BasketCache &basket)
{
   for(int i = 0; i < basket.levelCount && i < SK_MAX_LEVELS; i++)
     {
      ulong ticket = basket.levels[i].ticket;
      if(ticket == 0)
         continue;

      //--- Check if position exists at broker
      if(PositionSelectByTicket(ticket))
        {
         //--- Position is still open
         return true;
        }
     }
   return false;
}

//+------------------------------------------------------------------+
//| GLOBAL STATE MANAGEMENT                                            |
//+------------------------------------------------------------------+

/**
 * Write global state to Global Variables
 */
void SSoT_WriteGlobalStateToGVs()
{
   GlobalVariableSet(GV_StateName(GV_STATE_BCOUNT), (double)g_basketCount);
   GlobalVariableSet(GV_StateName(GV_STATE_NEXTID), (double)g_nextBasketId);
   GlobalVariableSet(GV_StateName(GV_STATE_INIT), (double)g_eaInitTime);
   GlobalVariableSet(GV_StateName(GV_STATE_HEAT), SSoT_CalculateHeatPct());
   GlobalVariableSet(GV_StateName(GV_STATE_SCHEMA), (double)SK_SCHEMA_VERSION);
}

/**
 * Read global state from Global Variables
 */
void SSoT_ReadGlobalStateFromGVs()
{
   string nextIdName = GV_StateName(GV_STATE_NEXTID);
   if(GlobalVariableCheck(nextIdName))
     {
      double val = GlobalVariableGet(nextIdName);
      if(val > 0)
         g_nextBasketId = (ulong)val;
     }

   string schemaName = GV_StateName(GV_STATE_SCHEMA);
   if(GlobalVariableCheck(schemaName))
     {
      double schemaVer = GlobalVariableGet(schemaName);
      if(schemaVer != SK_SCHEMA_VERSION)
        {
         Print("[SSoT] WARNING: Schema version mismatch. Expected ",
               SK_SCHEMA_VERSION, " found ", schemaVer,
               ". Clearing incompatible data.");
         //--- On schema mismatch, start fresh
         g_nextBasketId = 1;
         g_basketCount = 0;
        }
     }
}

/**
 * Save all basket data and global state to GVs
 * Called on auto-save interval or deinit
 */
void SSoT_SaveToGlobals()
{
   //--- Write all active baskets
   for(int i = 0; i < g_basketCount; i++)
     {
      if(g_baskets[i].isValid)
         SSoT_WriteBasketToGlobals(i);
     }

   //--- Write global state
   SSoT_WriteGlobalStateToGVs();

   //--- Write trade stats
   SSoT_SaveTradeStats();

   g_lastAutoSave = TimeCurrent();

   //--- SILENT: No logging for periodic auto-saves to avoid cluttering Experts tab
}

/**
 * Load all basket data and global state from GVs
 * Called during initialization
 */
void SSoT_LoadFromGlobals()
{
   //--- Read global state
   SSoT_ReadGlobalStateFromGVs();

   //--- CRITICAL FIX: Load adopted tickets from GVs FIRST
   //--- This prevents deduplication from purging legitimate baskets
   Adoption_LoadFromGVs();

   //--- CRITICAL FIX: Deduplicate GV baskets by ticket BEFORE loading
   //--- But SKIP deduplication for tickets in the persistent adoption map
   //--- If multiple baskets have the same original ticket (adoption loop debris),
   //--- keep only the FIRST one and delete duplicates from GVs
   ulong seenTickets[SK_MAX_BASKETS];
   int seenCount = 0;
   int purged = 0;

   for(ulong id = 1; id <= (ulong)SK_MAX_BASKETS; id++)
     {
      string statusName = GV_Name(id, GV_BASKET_STATUS);
      if(!GlobalVariableCheck(statusName))
         continue;

      double status = GlobalVariableGet(statusName);
      if(status >= 2.0)
         continue;  // Skip closed baskets

      //--- Read original ticket
      string ticketName = GV_Name(id, GV_BASKET_TICKET0);
      double ticketVal = 0;
      if(GlobalVariableCheck(ticketName))
         ticketVal = GlobalVariableGet(ticketName);

      if(ticketVal <= 0)
         continue;  // Empty basket — skip

      //--- CRITICAL FIX: Skip deduplication if ticket is in persistent adoption map
      if(Adoption_IsTicketAdopted((ulong)ticketVal))
        {
         //--- This ticket is legitimate (manually adopted or recovered)
         //--- Add to seen list to prevent other baskets with same ticket from being purged
         if(seenCount < SK_MAX_BASKETS)
           {
            seenTickets[seenCount] = (ulong)ticketVal;
            seenCount++;
           }
         continue;
        }

      //--- Check for duplicate ticket (only for untracked tickets)
      bool isDuplicate = false;
      for(int j = 0; j < seenCount; j++)
        {
         if(seenTickets[j] == (ulong)ticketVal)
           {
            isDuplicate = true;
            break;
           }
        }

      if(isDuplicate)
        {
         //--- Duplicate found — delete this basket's GVs
         SSoT_ClearBasketGlobals(id);
         purged++;
        }
      else
        {
         seenTickets[seenCount] = (ulong)ticketVal;
         seenCount++;
        }
     }

   if(purged > 0)
      Print("[SSoT] Purged ", purged, " duplicate basket(s) from adoption loop debris");

   //--- Now load clean baskets
   int loaded = 0;
   for(ulong id = 1; id <= (ulong)SK_MAX_BASKETS && loaded < SK_MAX_BASKETS; id++)
     {
      string statusName = GV_Name(id, GV_BASKET_STATUS);
      if(!GlobalVariableCheck(statusName))
         continue;

      double status = GlobalVariableGet(statusName);
      if(status >= 2.0)  // Closed
         continue;

      if(SSoT_ReadBasketFromGlobals(id, g_baskets[loaded]))
        {
         g_baskets[loaded].lastSync = TimeCurrent();

         //--- Load trailing
         SSoT_LoadTrailingCheckpointIntoBasket(id, loaded);

         loaded++;
        }
     }

   g_basketCount = loaded;
   g_cacheValid = (loaded > 0);

   //--- Load trade stats
   SSoT_LoadTradeStats();

   //--- Update next basket ID to avoid collision
   if(g_nextBasketId <= 1)
     {
      for(int i = 0; i < loaded; i++)
        {
         if(g_baskets[i].basketId >= g_nextBasketId)
            g_nextBasketId = g_baskets[i].basketId + 1;
        }
     }

   //--- CRITICAL: Populate in-memory adoption map with loaded tickets
   //--- (Already done by Adoption_LoadFromGVs() which fills g_adoptedTickets array)

   //--- CRITICAL: Scan for orphan positions not yet in any basket
   //--- This recovers positions that were opened before the EA was attached
   Adoption_ScanOrphansOnStartup();

   Print("[SSoT] Loaded from GVs. Baskets: ", g_basketCount,
         " Next ID: ", g_nextBasketId);
}

//+------------------------------------------------------------------+
//| TRADE STATISTICS PERSISTENCE                                       |
//+------------------------------------------------------------------+

/**
 * Save trade statistics to Global Variables
 */
void SSoT_SaveTradeStats()
{
   GlobalVariableSet(GV_StatsName(GV_STATS_VERSION), (double)SK_SCHEMA_VERSION);
   GlobalVariableSet(GV_StatsName(GV_STATS_TOTAL), (double)g_tradeStats.totalTrades);
   GlobalVariableSet(GV_StatsName(GV_STATS_WINS), (double)g_tradeStats.wins);
   GlobalVariableSet(GV_StatsName(GV_STATS_LOSSES), (double)g_tradeStats.losses);
   GlobalVariableSet(GV_StatsName(GV_STATS_WINAMT), g_tradeStats.totalWinAmount);
   GlobalVariableSet(GV_StatsName(GV_STATS_LOSSAMT), g_tradeStats.totalLossAmount);
   GlobalVariableSet(GV_StatsName(GV_STATS_ALPHA), g_tradeStats.alpha);
   GlobalVariableSet(GV_StatsName(GV_STATS_BETA), g_tradeStats.beta);
   GlobalVariableSet(GV_StatsName(GV_STATS_LASTUP), (double)g_tradeStats.lastUpdate);
}

/**
 * Load trade statistics from Global Variables
 */
void SSoT_LoadTradeStats()
{
   string totalName = GV_StatsName(GV_STATS_TOTAL);
   if(!GlobalVariableCheck(totalName))
     {
      //--- First run, use priors
      g_tradeStats.alpha = Inp_Bayesian_PriorWR * Inp_Bayesian_PriorStr;
      g_tradeStats.beta = (1.0 - Inp_Bayesian_PriorWR) * Inp_Bayesian_PriorStr;
      return;
     }

   g_tradeStats.totalTrades = (int)GlobalVariableGet(GV_StatsName(GV_STATS_TOTAL));
   g_tradeStats.wins = (int)GlobalVariableGet(GV_StatsName(GV_STATS_WINS));
   g_tradeStats.losses = (int)GlobalVariableGet(GV_StatsName(GV_STATS_LOSSES));
   g_tradeStats.totalWinAmount = GlobalVariableGet(GV_StatsName(GV_STATS_WINAMT));
   g_tradeStats.totalLossAmount = GlobalVariableGet(GV_StatsName(GV_STATS_LOSSAMT));
   g_tradeStats.alpha = GlobalVariableGet(GV_StatsName(GV_STATS_ALPHA));
   g_tradeStats.beta = GlobalVariableGet(GV_StatsName(GV_STATS_BETA));
   g_tradeStats.lastUpdate = (datetime)GlobalVariableGet(GV_StatsName(GV_STATS_LASTUP));

   //--- If alpha/beta are zero (old format), rebuild from priors
   if(g_tradeStats.alpha <= 0)
      g_tradeStats.alpha = Inp_Bayesian_PriorWR * Inp_Bayesian_PriorStr;
   if(g_tradeStats.beta <= 0)
      g_tradeStats.beta = (1.0 - Inp_Bayesian_PriorWR) * Inp_Bayesian_PriorStr;
}

/**
 * Record a completed basket trade
 * @param profit  Net profit/loss in USD
 */
void SSoT_OnBasketClosed(const double profit)
{
   g_tradeStats.totalTrades++;

   bool isWin = (profit > 0);
   if(isWin)
     {
      g_tradeStats.wins++;
      g_tradeStats.alpha++;
      g_tradeStats.totalWinAmount += profit;
     }
   else
     {
      g_tradeStats.losses++;
      g_tradeStats.beta++;
      g_tradeStats.totalLossAmount += MathAbs(profit);
     }

   g_tradeStats.lastUpdate = TimeCurrent();
   SSoT_SaveTradeStats();

   double winRate = 0;
   if(g_tradeStats.totalTrades > 0)
      winRate = ((double)g_tradeStats.wins / g_tradeStats.totalTrades) * 100.0;

   Print("[SSoT] Trade recorded: ", (isWin ? "WIN" : "LOSS"),
         " $", DoubleToString(profit, 2),
         " | WinRate: ", DoubleToString(winRate, 1), "%",
         " | Total: ", g_tradeStats.totalTrades);
}

//+------------------------------------------------------------------+
//| BASKET ID MANAGEMENT                                               |
//+------------------------------------------------------------------+

/**
 * Get next available basket ID (monotonic counter)
 * @return Next basket ID
 */
ulong SSoT_GetNextBasketId()
{
   ulong id = g_nextBasketId;
   g_nextBasketId++;

   //--- Safety wrap (unlikely to ever happen)
   if(g_nextBasketId > 999)
      g_nextBasketId = 1;

   return id;
}

/**
 * Check if a basket ID is available (not in use)
 * @param id  Basket ID to check
 * @return true if available
 */
bool SSoT_IsBasketIdAvailable(const ulong id)
{
   for(int i = 0; i < g_basketCount; i++)
     {
      if(g_baskets[i].basketId == id && g_baskets[i].isValid)
         return false;
     }
   return true;
}

//+------------------------------------------------------------------+
//| CLEANUP & MAINTENANCE                                              |
//+------------------------------------------------------------------+

/**
 * Count orphaned GV records (no matching basket in cache)
 * @return Number of orphaned basket IDs found
 */
int SSoT_CountOrphanedRecords()
{
   int orphaned = 0;

   for(ulong id = 1; id <= (ulong)SK_MAX_BASKETS; id++)
     {
      string statusName = GV_Name(id, GV_BASKET_STATUS);
      if(!GlobalVariableCheck(statusName))
         continue;

      double status = GlobalVariableGet(statusName);
      if(status >= 2.0)
         orphaned++;
     }

   return orphaned;
}

/**
 * Purge orphaned GV records (closed baskets no longer in cache)
 */
void SSoT_PurgeOrphanedRecords()
{
   for(ulong id = 1; id <= (ulong)SK_MAX_BASKETS; id++)
     {
      string statusName = GV_Name(id, GV_BASKET_STATUS);
      if(!GlobalVariableCheck(statusName))
         continue;

      double status = GlobalVariableGet(statusName);
      if(status >= 2.0)
        {
         //--- Clear all GVs for this basket
         SSoT_ClearBasketGlobals(id);
        }
     }

   Print("[SSoT] Orphaned records purged");
}

/**
 * Clear all Global Variables for a specific basket
 * @param basketId  Basket ID to clear
 */
void SSoT_ClearBasketGlobals(const ulong basketId)
{
   //--- Clear core fields
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_WA), 0);
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_VOL), 0);
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_TARGET), 0);
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_STATUS), 2);  // Closed
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_LEVELS), 0);
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_DIR), 0);
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_CREATED), 0);
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_MAGIC), 0);
   GlobalVariableSet(GV_Name(basketId, GV_BASKET_TICKET0), 0);

   //--- Clear level fields
   for(int i = 0; i < SK_MAX_LEVELS; i++)
     {
      GlobalVariableSet(GV_LevelName(basketId, i, GV_LEVEL_TICKET), 0);
      GlobalVariableSet(GV_LevelName(basketId, i, GV_LEVEL_LOT), 0);
      GlobalVariableSet(GV_LevelName(basketId, i, GV_LEVEL_PRICE), 0);
      GlobalVariableSet(GV_LevelName(basketId, i, GV_LEVEL_TIME), 0);
      GlobalVariableSet(GV_LevelName(basketId, i, GV_LEVEL_ORIGINAL), 0);
     }

   //--- Clear trailing
   GlobalVariableSet(GV_TrailName(basketId, GV_TRAIL_PEAK), 0);
   GlobalVariableSet(GV_TrailName(basketId, GV_TRAIL_STOP), 0);
   GlobalVariableSet(GV_TrailName(basketId, GV_TRAIL_ACTIVE), 0);
   GlobalVariableSet(GV_TrailName(basketId, GV_TRAIL_TIME), 0);
}

/**
 * One-Time GV Purge: Delete orphan baskets with status = 2.0 (CLOSED)
 * Scans all SK_ GVs, finds closed baskets, and deletes all their GVs
 * Called from SSoT_Initialize() on EA startup to clean past debris
 */
void SSoT_PurgeOrphanGVs()
{
   int purgedBaskets = 0;
   int deletedGVs = 0;

   for(int i = 0; i < GlobalVariablesTotal(); i++)
     {
      string name = GlobalVariableName(i);

      //--- Only process basket STATUS GVs: SK_B###_STS
      if(!IsSK_GlobalVariable(name))
         continue;
      if(StringFind(name, "_STS") < 0)  // Not a status field
         continue;

      //--- Extract basket ID from name (SK_B###_STS)
      ulong basketId = GV_ExtractBasketId(name);
      if(basketId == 0)
         continue;

      //--- Check if status is CLOSED (2.0)
      double statusVal = GlobalVariableGet(name);
      if(statusVal < 2.0 - 0.001)
         continue;  // Active or Closing -- skip

      //--- Found an orphan -- delete all its GVs
      purgedBaskets++;

      //--- Delete basket core GVs (9 fields)
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_WA)))     deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_VOL)))    deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_TARGET))) deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_STATUS))) deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_LEVELS))) deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_DIR)))    deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_CREATED)))deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_MAGIC)))  deletedGVs++;
      if(GlobalVariableDel(GV_Name(basketId, GV_BASKET_TICKET0)))deletedGVs++;

      //--- Delete trailing GVs (4 fields)
      if(GlobalVariableDel(GV_TrailName(basketId, GV_TRAIL_PEAK)))  deletedGVs++;
      if(GlobalVariableDel(GV_TrailName(basketId, GV_TRAIL_STOP)))  deletedGVs++;
      if(GlobalVariableDel(GV_TrailName(basketId, GV_TRAIL_ACTIVE)))deletedGVs++;
      if(GlobalVariableDel(GV_TrailName(basketId, GV_TRAIL_TIME)))  deletedGVs++;

      //--- Delete per-level GVs (max SK_MAX_LEVELS levels x 5 fields each)
      for(int lvl = 0; lvl < SK_MAX_LEVELS; lvl++)
        {
         if(GlobalVariableDel(GV_LevelName(basketId, lvl, GV_LEVEL_TICKET)))  deletedGVs++;
         if(GlobalVariableDel(GV_LevelName(basketId, lvl, GV_LEVEL_LOT)))     deletedGVs++;
         if(GlobalVariableDel(GV_LevelName(basketId, lvl, GV_LEVEL_PRICE)))   deletedGVs++;
         if(GlobalVariableDel(GV_LevelName(basketId, lvl, GV_LEVEL_TIME)))    deletedGVs++;
         if(GlobalVariableDel(GV_LevelName(basketId, lvl, GV_LEVEL_ORIGINAL)))deletedGVs++;
        }
     }

   if(purgedBaskets > 0)
      Print("[SSoT] Orphan GV purge complete: ", purgedBaskets,
            " baskets purged, ", deletedGVs, " GVs deleted");
}

/**
 * Clear ALL SIDEWAY KILLER Global Variables
 * WARNING: This is destructive - use only for testing
 */
void SSoT_ClearAllGlobals()
{
   int deleted = 0;

   for(int i = 0; i < GlobalVariablesTotal(); i++)
     {
      string name = GlobalVariableName(i);
      if(IsSK_GlobalVariable(name))
        {
         GlobalVariableDel(name);
         deleted++;
        }
     }

   //--- Reset all in-memory state
   g_basketCount = 0;
   g_cacheValid = false;
   g_nextBasketId = 1;

   Print("[SSoT] All GVs cleared. Deleted: ", deleted);
}

//+------------------------------------------------------------------+
//| PUBLIC SYNC INTERFACE (called from OnTimer in main EA)             |
//+------------------------------------------------------------------+

/**
 * Full sync: Refresh cache from GVs + validate + update dashboard
 * This is the primary cold-path sync function
 */
void SSoT_SyncCacheFromGlobals()
{
   //--- Refresh cache from GVs
   SSoT_RefreshCacheFromGlobals();

   //--- Validate consistency (every 10 seconds)
   static int validateCounter = 0;
   validateCounter++;
   if(validateCounter >= 10)
     {
      validateCounter = 0;
      SSoT_ValidateCacheConsistency();
     }

   //--- Auto-save on interval
   if(Inp_AutoSaveInterval > 0)
     {
      if(TimeCurrent() - g_lastAutoSave >= Inp_AutoSaveInterval)
        {
         SSoT_SaveToGlobals();
        }
     }

   //--- Save trailing checkpoints every sync
   for(int i = 0; i < g_basketCount; i++)
     {
      if(g_baskets[i].isValid && g_baskets[i].status == BASKET_ACTIVE)
        {
         SSoT_SaveTrailingCheckpoint(i);
        }
     }
}

//+------------------------------------------------------------------+
//| UTILITY: Calculate approximate profit for a basket (math only)     |
//| Used by Fast-Strike in hot path - NO API calls                     |
//+------------------------------------------------------------------+

/**
 * Calculate approximate profit for a basket using math only
 * @param index       Basket cache index
 * @param currentPrice Current market price (bid for BUY, ask for SELL)
 * @return Approximate profit in USD
 */
double SSoT_CalcApproxProfit(const int index, const double currentPrice)
{
   if(index < 0 || index >= g_basketCount)
      return 0;
   if(!g_baskets[index].isValid)
      return 0;

   double distance = 0;
   if(g_baskets[index].direction == 0)  // BUY
      distance = currentPrice - g_baskets[index].weightedAvg;
   else  // SELL
      distance = g_baskets[index].weightedAvg - currentPrice;

   //--- Use live tick value for accurate calculation
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double valuePerPoint = (tickSize > 0) ? tickValue / tickSize : 100.0;
   return distance * g_baskets[index].totalVolume * valuePerPoint;
}

/**
 * Get the correct price for profit calculation based on direction
 * @param direction  0=BUY, 1=SELL
 * @return Bid for BUY, Ask for SELL
 */
double SSoT_GetPriceForDirection(const int direction)
{
   if(direction == 0)  // BUY
      return SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else  // SELL
      return SymbolInfoDouble(_Symbol, SYMBOL_ASK);
}

//+------------------------------------------------------------------+
//| UTILITY: Basket find by ticket                                     |
//+------------------------------------------------------------------+

/**
 * Find basket index by position ticket
 * @param ticket  Position ticket to search for
 * @return Basket index or -1 if not found
 */
int SSoT_FindBasketByTicket(const ulong ticket)
{
   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;

      for(int j = 0; j < g_baskets[i].levelCount; j++)
        {
         if(g_baskets[i].levels[j].ticket == ticket)
            return i;
        }
     }
   return -1;
}

/**
 * Check if a position ticket is already in any basket
 * @param ticket  Position ticket
 * @return true if ticket exists in any active basket
 */
bool SSoT_IsTicketInBasket(const ulong ticket)
{
   return (SSoT_FindBasketByTicket(ticket) >= 0);
}

//+------------------------------------------------------------------+
//| UTILITY: Recalculate weighted average from level data              |
//+------------------------------------------------------------------+

/**
 * Recalculate weighted average from scratch using level data
 * Used as a safety check after level additions
 * @param basketIndex  Cache index
 */
void SSoT_RecalcWeightedAvg(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   if(!g_baskets[basketIndex].isValid)
      return;

   double totalValue = 0;
   double totalLots = 0;

   for(int i = 0; i < g_baskets[basketIndex].levelCount; i++)
     {
      double lots = g_baskets[basketIndex].levels[i].lotSize;
      double price = g_baskets[basketIndex].levels[i].openPrice;

      totalValue += lots * price;
      totalLots += lots;
     }

   if(totalLots > 0)
      g_baskets[basketIndex].weightedAvg = totalValue / totalLots;
}

//+------------------------------------------------------------------+
//| GV WRAPPER FUNCTIONS — safe wrappers with error handling           |
//| Task 1.1: Required interface                                      |
//+------------------------------------------------------------------+

/**
 * Set a Global Variable value (cold path only)
 * @param name   GV name
 * @param value  Value to set
 * @return true on success
 */
bool SSoT_GV_Set(const string name, const double value)
{
   if(name == "")
     {
      Print("[SSoT] ERROR: GV_Set empty name");
      return false;
     }

   bool result = GlobalVariableSet(name, value);
   if(!result)
      Print("[SSoT] ERROR: GVSet failed for ", name, " err=", GetLastError());

   return result;
}

/**
 * Get a Global Variable value (cold path only)
 * @param name  GV name
 * @return Value or 0 on error
 */
double SSoT_GV_Get(const string name)
{
   if(name == "")
     {
      Print("[SSoT] ERROR: GV_Get empty name");
      return 0;
     }

   ResetLastError();
   double value = GlobalVariableGet(name);
   if(GetLastError() != 0)
     {
      Print("[SSoT] WARNING: GVGet failed for ", name, " err=", GetLastError());
      return 0;
     }

   return value;
}

/**
 * Check if a Global Variable exists
 * @param name  GV name
 * @return true if exists
 */
bool SSoT_GV_Exists(const string name)
{
   if(name == "")
      return false;
   return GlobalVariableCheck(name);
}

/**
 * Delete a Global Variable
 * @param name  GV name
 * @return true on success
 */
bool SSoT_GV_Delete(const string name)
{
   if(name == "")
     {
      Print("[SSoT] ERROR: GV_Delete empty name");
      return false;
     }
   return GlobalVariableDel(name);
}

//+------------------------------------------------------------------+
//| ALIAS FUNCTIONS — Task 1.1 spec naming compatibility               |
//+------------------------------------------------------------------+

/**
 * Alias: SSoT_Init → SSoT_Initialize
 */
bool SSoT_Init()
{
   return SSoT_Initialize();
}

/**
 * Alias: SSoT_SaveCheckpoint → SSoT_SaveTrailingCheckpoint
 */
void SSoT_SaveCheckpoint(const int basketIndex)
{
   SSoT_SaveTrailingCheckpoint(basketIndex);
}

/**
 * Alias: SSoT_LoadCheckpoint → SSoT_LoadTrailingCheckpointIntoBasket
 */
void SSoT_LoadCheckpoint(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return;
   ulong id = g_baskets[basketIndex].basketId;
   SSoT_LoadTrailingCheckpointIntoBasket(id, basketIndex);
}

/**
 * Alias: SSoT_SaveAllBaskets → SSoT_SaveToGlobals
 */
void SSoT_SaveAllBaskets()
{
   SSoT_SaveToGlobals();
}

/**
 * Alias: SSoT_LoadAllBaskets → SSoT_LoadFromGlobals
 */
void SSoT_LoadAllBaskets()
{
   SSoT_LoadFromGlobals();
}

/**
 * Alias: SSoT_SaveGlobalState → SSoT_WriteGlobalStateToGVs
 */
void SSoT_SaveGlobalState()
{
   SSoT_WriteGlobalStateToGVs();
}

/**
 * Alias: SSoT_LoadGlobalState → SSoT_ReadGlobalStateFromGVs
 */
void SSoT_LoadGlobalState()
{
   SSoT_ReadGlobalStateFromGVs();
}

/**
 * Alias: SSoT_SyncDashboardToGlobals → SSoT_UpdateDashboard
 */
void SSoT_SyncDashboardToGlobals()
{
   SSoT_UpdateDashboard();
}

//+------------------------------------------------------------------+
