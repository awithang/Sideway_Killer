//+------------------------------------------------------------------+
//|                                            SK_Adoption.mqh       |
//|                                    SIDEWAY KILLER - Phase 2      |
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
//| POSITION ADOPTION SYSTEM — Configurable Smart Adaptive Protocol   |
//|                                                                    |
//|  Modes: AGGRESSIVE, SMART (default), CONSERVATIVE, MANUAL          |
//|  User Commands: NOADOPT, FORCE, CLEAR (via position comment)       |
//|  Adaptive Filters: Volatility ratio, spread ratio, price stability |
//|                                                                    |
//|  Scan Interval: Every 1 second (OnTimer)                           |
//|  Hot Path: NONE (all operations in cold path)                      |
//+==================================================================+

//+------------------------------------------------------------------+
//| INTERNAL TRACKING STRUCTURES                                       |
//+------------------------------------------------------------------+

struct AdoptionResult
{
   ulong  ticket;
   bool   eligible;
   string reason;
   double drawdownPct;
   int    ageSeconds;
   bool   userExcluded;
   bool   userForced;
};

struct PositionTracking
{
   ulong    ticket;
   datetime firstSeen;
   bool     processed;
};

//--- Tracking arrays
PositionTracking g_posTracking[256];
int              g_trackingCount = 0;

//--- User command tracking (in-memory, since MQL5 can't modify position comments)
struct CommandTracking
{
   ulong    ticket;
   string   command;      // "NOADOPT", "FORCE", "CLEAR"
   datetime issuedAt;
   bool     processed;
};
CommandTracking  g_commands[256];
int              g_commandCount = 0;

//--- Spread history buffer
double           g_spreadHistory[100];
int              g_spreadHistoryIndex = 0;
int              g_spreadHistoryCount = 0;

//--- ATR indicator handles (initialized once)
int              g_adoptionAtrHandle14 = INVALID_HANDLE;
int              g_adoptionAtrHandle100 = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| PUBLIC API — Initialization & Entry Point                          |
//+------------------------------------------------------------------+

/**
 * Initialize the adoption system
 * Called from EA OnInit() or after Phase 1 init
 * @return true on success
 */
bool Adoption_Init()
{
   g_trackingCount = 0;
   g_commandCount = 0;

   //--- Initialize tracking array
   for(int i = 0; i < 256; i++)
     {
      g_posTracking[i].ticket = 0;
      g_posTracking[i].firstSeen = 0;
      g_posTracking[i].processed = false;

      g_commands[i].ticket = 0;
      g_commands[i].command = "";
      g_commands[i].issuedAt = 0;
      g_commands[i].processed = false;
     }

   //--- Initialize spread history
   ArrayInitialize(g_spreadHistory, 0);
   g_spreadHistoryIndex = 0;
   g_spreadHistoryCount = 0;

   //--- Seed initial spread value
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   for(int i = 0; i < 100; i++)
      g_spreadHistory[i] = (double)currentSpread;

   //--- Create ATR handles for adaptive filtering
   g_adoptionAtrHandle14 = iATR(_Symbol, PERIOD_CURRENT, 14);
   g_adoptionAtrHandle100 = iATR(_Symbol, PERIOD_CURRENT, 100);

   if(g_adoptionAtrHandle14 == INVALID_HANDLE ||
      g_adoptionAtrHandle100 == INVALID_HANDLE)
     {
      Print("[Adoption] WARNING: ATR indicator handles failed to create");
     }

   Print("[Adoption] Initialized. Mode: ", EnumToString(Inp_AdoptMode));

   return true;
}

/**
 * Deinitialize the adoption system
 * Called from EA OnDeinit()
 */
void Adoption_Deinit()
{
   if(g_adoptionAtrHandle14 != INVALID_HANDLE)
      IndicatorRelease(g_adoptionAtrHandle14);
   if(g_adoptionAtrHandle100 != INVALID_HANDLE)
      IndicatorRelease(g_adoptionAtrHandle100);

   g_trackingCount = 0;
   g_commandCount = 0;

   Print("[Adoption] Deinitialized");
}

/**
 * Execute full adoption scan — called from OnTimer()
 * Scans all open positions and adopts qualifying ones
 */
void Adoption_ExecuteScan()
{
   //--- Step 1: Process user commands first
   Adoption_ScanUserCommands();

   //--- Step 2: Update market state for adaptive filters
   Adoption_UpdateMarketState();

   //--- Step 3: Scan all positions for adoption candidates
   int total = PositionsTotal();
   int scanned = 0;
   int adopted = 0;

   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      scanned++;

      AdoptionResult result;
      if(Adoption_ShouldAdopt(ticket, result))
        {
         int basketIndex = Adoption_AdoptPosition(ticket);
         if(basketIndex >= 0)
            adopted++;
        }
     }

   //--- Maintain tracking list (cleanup old entries)
   Adoption_MaintainTracking();

   //--- Log scan summary (only when something changed)
   if(adopted > 0)
      Print("[Adoption] Scan complete: scanned=", scanned, " adopted=", adopted);
}

//+------------------------------------------------------------------+
//| MAIN ADOPTION LOGIC                                                |
//+------------------------------------------------------------------+

/**
 * Evaluate whether a position should be adopted
 * @param ticket   Position ticket
 * @param result   Output adoption result details
 * @return true if position qualifies for adoption
 */
bool Adoption_ShouldAdopt(const ulong ticket, AdoptionResult &result)
{
   ZeroMemory(result);
   result.ticket = ticket;

   //--- CHECK 1: User exclusion (overrides everything)
   if(Adoption_IsExcluded(ticket))
     {
      result.userExcluded = true;
      result.eligible = false;
      result.reason = "User excluded (NOADOPT)";
      return false;
     }

   //--- CHECK 2: User force (overrides everything)
   if(Adoption_IsForced(ticket))
     {
      result.userForced = true;
      result.eligible = true;
      result.reason = "User forced (FORCE)";

      //--- Still verify not already in basket
      if(Adoption_IsPositionInBasket(ticket))
        {
         result.eligible = false;
         result.reason = "Already in basket";
         return false;
        }

      return true;
     }

   //--- CHECK 3: Mode-based evaluation
   switch(Inp_AdoptMode)
     {
      case ADOPT_AGGRESSIVE:
         result.eligible = Adoption_Mode_Aggressive(ticket, result);
         break;

      case ADOPT_SMART:
         result.eligible = Adoption_Mode_Smart(ticket, result);
         break;

      case ADOPT_CONSERVATIVE:
         result.eligible = Adoption_Mode_Conservative(ticket, result);
         break;

      case ADOPT_MANUAL:
         result.eligible = Adoption_Mode_Manual(ticket);
         break;

      default:
         result.eligible = Adoption_Mode_Smart(ticket, result);
         break;
     }

   return result.eligible;
}

/**
 * Adopt a position — create a new basket with it as Level 0
 * @param ticket  Position ticket to adopt
 * @return Basket cache index (0-based) or -1 on failure
 */
int Adoption_AdoptPosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
     {
      Print("[Adoption] ERROR: Cannot select position ", ticket);
      return -1;
     }

   //--- Get position details
   int direction = (int)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double lots = PositionGetDouble(POSITION_VOLUME);
   ulong magic = PositionGetInteger(POSITION_MAGIC);

   //--- Create basket via SSoT (write-through to GVs)
   int basketIndex = SSoT_CreateBasket(ticket, openPrice, lots, direction, magic);

   if(basketIndex >= 0)
     {
      Print("[Adoption] Position ", ticket, " adopted as Basket ID=",
            g_baskets[basketIndex].basketId,
            " (", (direction == 0 ? "BUY" : "SELL"), " ", lots, " lots @ ",
            DoubleToString(openPrice, 5), ")");
     }
   else
     {
      Print("[Adoption] ERROR: Failed to create basket for ticket ", ticket);
     }

   return basketIndex;
}

//+------------------------------------------------------------------+
//| BASE CRITERIA CHECK                                                |
//| Applied to ALL modes (except MANUAL and FORCE)                     |
//+------------------------------------------------------------------+

/**
 * Check if a position meets the base adoption criteria
 * @param ticket   Position ticket
 * @param result   Output result (updated with drawdown, age)
 * @return true if base criteria met
 */
bool Adoption_MeetsBaseCriteria(const ulong ticket, AdoptionResult &result)
{
   //--- CRITERION 1: Symbol match
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
     {
      result.reason = "Symbol mismatch";
      return false;
     }

   //--- CRITERION 2: Magic number match (0 or EA target magic)
   //--- For this system, we adopt magic 0 (manual positions) and any matching magic
   ulong magic = PositionGetInteger(POSITION_MAGIC);
   //--- Accept all manual trades (magic 0) and any matching EA magic
   //--- Magic check is intentionally permissive — the EA manages adopted baskets

   //--- CRITERION 3: Must be in loss
   double profit = PositionGetDouble(POSITION_PROFIT);
   double swap = PositionGetDouble(POSITION_SWAP);
   //--- Commission: estimate from volume × $7/lot round-turn (avoid deprecated POSITION_COMMISSION)
   double volume = PositionGetDouble(POSITION_VOLUME);
   double commission = volume * 7.0;
   double netPnL = profit + swap - commission;

   if(netPnL >= 0)
     {
      result.reason = "Position in profit";
      return false;
     }

   //--- CRITERION 4: Drawdown in acceptable range (0% - 2%)
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   int direction = (int)PositionGetInteger(POSITION_TYPE);
   double currentPrice = Adoption_GetCurrentPrice(direction);
   double drawdownPct = Adoption_CalcDrawdownPct(openPrice, currentPrice, direction);

   result.drawdownPct = drawdownPct;

   if(drawdownPct <= 0.0)
     {
      result.reason = "No drawdown";
      return false;
     }

   //--- Max drawdown: 2% default (configurable via logic)
   double maxDrawdown = 2.0;
   if(drawdownPct > maxDrawdown)
     {
      result.reason = "Drawdown too deep (" + DoubleToString(drawdownPct, 2) + "%)";
      return false;
     }

   //--- CRITERION 5: Not already adopted
   if(Adoption_IsPositionInBasket(ticket))
     {
      result.reason = "Already in basket";
      return false;
     }

   //--- CRITERION 6: Position age minimum (mode-specific)
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   int ageSeconds = (int)(TimeCurrent() - openTime);
   result.ageSeconds = ageSeconds;

   return true;
}

//+------------------------------------------------------------------+
//| MODE-SPECIFIC LOGIC                                                |
//+------------------------------------------------------------------+

/**
 * AGGRESSIVE MODE: Base criteria only, 30s minimum age
 * Fast adoption with minimal filters
 */
bool Adoption_Mode_Aggressive(const ulong ticket, const AdoptionResult &baseResult)
{
   //--- Re-check base criteria (we need the fresh drawdownPct and ageSeconds)
   AdoptionResult temp;
   if(!Adoption_MeetsBaseCriteria(ticket, temp))
      return false;

   //--- Minimum age check (30s hardcoded)
   if(temp.ageSeconds < DEF_AGGR_MIN_AGE)
      return false;

   return true;
}

/**
 * SMART MODE: Adaptive filters (RECOMMENDED DEFAULT)
 * Volatility ratio, spread sanity, price stability checks
 */
bool Adoption_Mode_Smart(const ulong ticket, const AdoptionResult &baseResult)
{
   //--- Must meet base criteria first
   AdoptionResult temp;
   if(!Adoption_MeetsBaseCriteria(ticket, temp))
      return false;

   //--- Adaptive minimum age
   int minAge = Inp_Smart_MinAge;  // Default 60s

   //--- Double age during high volatility
   if(g_market.isHighVolatility)
      minAge *= 2;

   //--- 1.5x age during wide spread
   if(g_market.isWideSpread)
      minAge = (int)(minAge * 1.5);

   if(temp.ageSeconds < minAge)
      return false;

   //--- Spread sanity check (adaptive threshold)
   double currentSpread = g_market.currentSpread;
   double avgSpread = Adoption_GetAverageSpread(100);
   double maxSpread = avgSpread * (Inp_Smart_SpreadMult + g_market.volatilityRatio);

   if(currentSpread > maxSpread && maxSpread > 0)
      return false;

   //--- Volatility sanity check
   if(g_market.isHighVolatility)
     {
      if(!Adoption_IsPriceStable(ticket, 15))
         return false;  // Too chaotic to adopt
     }

   return true;
}

/**
 * CONSERVATIVE MODE: Strict filters, 90s minimum age
 * Maximum safety, may miss some opportunities
 */
bool Adoption_Mode_Conservative(const ulong ticket, const AdoptionResult &baseResult)
{
   //--- Must meet base criteria first
   AdoptionResult temp;
   if(!Adoption_MeetsBaseCriteria(ticket, temp))
      return false;

   //--- Stricter minimum age (90s default)
   if(temp.ageSeconds < Inp_Smart_MinAge + 30)  // 60 + 30 = 90
      return false;

   //--- Stricter spread check
   double currentSpread = g_market.currentSpread;
   double avgSpread = Adoption_GetAverageSpread(100);

   if(currentSpread > avgSpread * 2.0 && avgSpread > 0)
      return false;

   //--- Stricter volatility check
   if(g_market.volatilityRatio > 1.5)
      return false;

   //--- Require price stability
   if(!Adoption_IsPriceStable(ticket, 30))
      return false;

   return true;
}

/**
 * MANUAL MODE: Only forced tickets
 * No automatic adoption
 */
bool Adoption_Mode_Manual(const ulong ticket)
{
   return Adoption_IsForced(ticket);
}

//+------------------------------------------------------------------+
//| SMART FILTERS                                                      |
//+------------------------------------------------------------------+

/**
 * Calculate adaptive minimum age based on market conditions
 * @return Minimum age in seconds
 */
int Adoption_CalcAdaptiveMinAge()
{
   int minAge = Inp_Smart_MinAge;

   if(g_market.isHighVolatility)
      minAge *= 2;
   if(g_market.isWideSpread)
      minAge = (int)(minAge * 1.5);

   return minAge;
}

/**
 * Calculate adaptive maximum spread threshold
 * @return Max acceptable spread in points
 */
double Adoption_CalcAdaptiveMaxSpread()
{
   double avgSpread = Adoption_GetAverageSpread(100);
   return avgSpread * (Inp_Smart_SpreadMult + g_market.volatilityRatio);
}

/**
 * Check if price has been stable for a given window
 * Used to avoid adoption during flash crashes
 * @param ticket        Position ticket
 * @param secondsWindow Stability check window
 * @return true if price movement was within acceptable range
 */
bool Adoption_IsPriceStable(const ulong ticket, const int secondsWindow)
{
   if(!PositionSelectByTicket(ticket))
      return true;  // Can't check, assume stable

   int direction = (int)PositionGetInteger(POSITION_TYPE);
   double priceNow = Adoption_GetCurrentPrice(direction);

   //--- Get historical price from M1 bars
   int barsToCheck = (int)MathCeil(secondsWindow / 60.0) + 1;
   if(barsToCheck < 1)
      barsToCheck = 1;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(_Symbol, PERIOD_M1, 0, barsToCheck, rates) < barsToCheck)
      return true;  // Can't get history, assume stable

   double priceThen = rates[barsToCheck - 1].close;
   double movePct = 0;

   if(priceThen > 0)
      movePct = MathAbs(priceNow - priceThen) / priceThen * 100.0;

   //--- Stable if moved less than 0.5% in the window
   return (movePct < 0.5);
}

/**
 * Update market state: volatility ratio, spread ratio, flags
 * Called from Adoption_ExecuteScan()
 */
void Adoption_UpdateMarketState()
{
   double atr14 = 0;
   double atr100 = 0;

   //--- Get ATR values from handles
   if(g_adoptionAtrHandle14 != INVALID_HANDLE)
     {
      double buf[];
      ArrayResize(buf, 1);
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(g_adoptionAtrHandle14, 0, 0, 1, buf) > 0)
         atr14 = buf[0];
     }

   if(g_adoptionAtrHandle100 != INVALID_HANDLE)
     {
      double buf2[];
      ArrayResize(buf2, 1);
      ArraySetAsSeries(buf2, true);
      if(CopyBuffer(g_adoptionAtrHandle100, 0, 0, 1, buf2) > 0)
         atr100 = buf2[0];
     }

   //--- Store in market state
   g_market.atr14 = atr14;
   g_market.atr100 = atr100;

   //--- Volatility ratio
   if(atr100 > 0)
      g_market.volatilityRatio = atr14 / atr100;
   else
      g_market.volatilityRatio = 1.0;

   //--- Current spread
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_market.currentSpread = (double)currentSpread;

   //--- Update spread history buffer
   g_spreadHistory[g_spreadHistoryIndex] = g_market.currentSpread;
   g_spreadHistoryIndex = (g_spreadHistoryIndex + 1) % 100;
   if(g_spreadHistoryCount < 100)
      g_spreadHistoryCount++;

   //--- Spread ratio vs average
   double avgSpread = Adoption_GetAverageSpread(g_spreadHistoryCount);
   if(avgSpread > 0)
      g_market.spreadRatio = g_market.currentSpread / avgSpread;
   else
      g_market.spreadRatio = 1.0;

   //--- Update flags
   g_market.isHighVolatility = (g_market.volatilityRatio > Inp_Smart_VolThresh);
   g_market.isWideSpread = (g_market.spreadRatio > Inp_Smart_SpreadMult);
   g_market.isNewsTime = false;  // Placeholder — can integrate news calendar later

   g_market.lastUpdate = TimeCurrent();

   //--- Also update spread stats
   double alpha = 0.1;
   g_spreadStats.average = g_spreadStats.average * (1.0 - alpha) +
                           g_market.currentSpread * alpha;

   double delta = g_market.currentSpread - g_spreadStats.average;
   g_spreadStats.variance = g_spreadStats.variance * (1.0 - alpha) +
                            (delta * delta) * alpha;
   g_spreadStats.stdDev = MathSqrt(g_spreadStats.variance);
   g_spreadStats.lastUpdate = TimeCurrent();
}

/**
 * Get average spread over N periods
 * @param periods  Number of periods to average
 * @return Average spread in points
 */
double Adoption_GetAverageSpread(const int periods)
{
   if(periods <= 0)
      return g_spreadStats.average;

   int count = MathMin(periods, g_spreadHistoryCount);
   if(count == 0)
      return 10.0;  // Default fallback

   double sum = 0;
   int idx = g_spreadHistoryIndex;

   for(int i = 0; i < count; i++)
     {
      idx = (idx - 1 + 100) % 100;
      sum += g_spreadHistory[idx];
     }

   return sum / count;
}

//+------------------------------------------------------------------+
//| USER COMMAND SCANNER                                               |
//| Parses position comments for NOADOPT, FORCE, CLEAR commands        |
//+------------------------------------------------------------------+

/**
 * Scan all positions for user commands in comments
 * Called from Adoption_ExecuteScan()
 */
void Adoption_ScanUserCommands()
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      if(comment == "")
         continue;

      //--- Trim whitespace to prevent mismatches
      comment = Adoption_StringTrim(comment);
      if(comment == "")
         continue;

      //--- Check if already processed (in-memory)
      if(Adoption_CommandAlreadyProcessed(ticket))
         continue;

      //--- Parse commands
      if(comment == "NOADOPT")
        {
         Adoption_AddExclusion(ticket);
         Adoption_RecordCommand(ticket, "NOADOPT");
         Print("[Adoption] Ticket ", ticket, " EXCLUDED from adoption");
        }
      else if(comment == "FORCE")
        {
         Adoption_AddForce(ticket);
         Adoption_RecordCommand(ticket, "FORCE");
         Print("[Adoption] Ticket ", ticket, " MARKED FOR FORCE adoption");
        }
      else if(comment == "CLEAR")
        {
         Adoption_ClearOverrides(ticket);
         Adoption_RecordCommand(ticket, "CLEAR");
         Print("[Adoption] Ticket ", ticket, " overrides CLEARED");
        }
     }
}

/**
 * Check if a command has already been processed for a ticket
 */
bool Adoption_CommandAlreadyProcessed(const ulong ticket)
{
   for(int i = 0; i < g_commandCount; i++)
     {
      if(g_commands[i].ticket == ticket && g_commands[i].processed)
         return true;
     }
   return false;
}

/**
 * Record a user command in memory
 */
void Adoption_RecordCommand(const ulong ticket, const string command)
{
   if(g_commandCount < 256)
     {
      g_commands[g_commandCount].ticket = ticket;
      g_commands[g_commandCount].command = command;
      g_commands[g_commandCount].issuedAt = TimeCurrent();
      g_commands[g_commandCount].processed = true;
      g_commandCount++;
     }
}

/**
 * Check if a ticket is in the exclusion list
 */
bool Adoption_IsExcluded(const ulong ticket)
{
   for(int i = 0; i < g_userOverrides.excludedCount; i++)
     {
      if(g_userOverrides.excludedTickets[i] == ticket)
         return true;
     }
   return false;
}

/**
 * Check if a ticket is in the force list
 */
bool Adoption_IsForced(const ulong ticket)
{
   for(int i = 0; i < g_userOverrides.forcedCount; i++)
     {
      if(g_userOverrides.forcedTickets[i] == ticket)
         return true;
     }
   return false;
}

/**
 * Add a ticket to the exclusion list
 */
void Adoption_AddExclusion(const ulong ticket)
{
   if(Adoption_IsExcluded(ticket))
      return;

   if(g_userOverrides.excludedCount < SK_MAX_BASKETS)
     {
      g_userOverrides.excludedTickets[g_userOverrides.excludedCount] = ticket;
      g_userOverrides.excludedCount++;
     }
   else
     {
      Print("[Adoption] WARNING: Exclusion list full");
     }
}

/**
 * Add a ticket to the force list
 */
void Adoption_AddForce(const ulong ticket)
{
   if(Adoption_IsForced(ticket))
      return;

   if(g_userOverrides.forcedCount < SK_MAX_BASKETS)
     {
      g_userOverrides.forcedTickets[g_userOverrides.forcedCount] = ticket;
      g_userOverrides.forcedCount++;
     }
   else
     {
      Print("[Adoption] WARNING: Force list full");
     }
}

/**
 * Clear all overrides for a specific ticket
 */
void Adoption_ClearOverrides(const ulong ticket)
{
   //--- Remove from exclusion list
   for(int i = 0; i < g_userOverrides.excludedCount; i++)
     {
      if(g_userOverrides.excludedTickets[i] == ticket)
        {
         //--- Shift array
         for(int j = i; j < g_userOverrides.excludedCount - 1; j++)
            g_userOverrides.excludedTickets[j] = g_userOverrides.excludedTickets[j + 1];
         g_userOverrides.excludedTickets[g_userOverrides.excludedCount - 1] = 0;
         g_userOverrides.excludedCount--;
         break;
        }
     }

   //--- Remove from force list
   for(int i = 0; i < g_userOverrides.forcedCount; i++)
     {
      if(g_userOverrides.forcedTickets[i] == ticket)
        {
         for(int j = i; j < g_userOverrides.forcedCount - 1; j++)
            g_userOverrides.forcedTickets[j] = g_userOverrides.forcedTickets[j + 1];
         g_userOverrides.forcedTickets[g_userOverrides.forcedCount - 1] = 0;
         g_userOverrides.forcedCount--;
         break;
        }
     }
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                   |
//+------------------------------------------------------------------+

/**
 * Calculate drawdown percentage for a position
 * @param openPrice     Position open price
 * @param currentPrice  Current market price
 * @param direction     0=BUY, 1=SELL
 * @return Drawdown as percentage
 */
double Adoption_CalcDrawdownPct(const double openPrice, const double currentPrice,
                                 const int direction)
{
   if(openPrice <= 0)
      return 0;

   double diff = 0;
   if(direction == 0)  // BUY
      diff = openPrice - currentPrice;
   else  // SELL
      diff = currentPrice - openPrice;

   return (diff / openPrice) * 100.0;
}

/**
 * Check if a position ticket is already in any basket
 * @param ticket  Position ticket
 * @return true if already adopted
 */
bool Adoption_IsPositionInBasket(const ulong ticket)
{
   return SSoT_IsTicketInBasket(ticket);
}

/**
 * Get current price based on position direction
 * @param direction  0=BUY (use BID), 1=SELL (use ASK)
 * @return Current market price
 */
double Adoption_GetCurrentPrice(const int direction)
{
   if(direction == 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      return SymbolInfoDouble(_Symbol, SYMBOL_ASK);
}

//+------------------------------------------------------------------+
//| TRACKING MAINTENANCE                                               |
//+------------------------------------------------------------------+

/**
 * Maintain position tracking list — cleanup processed/old entries
 * Called from Adoption_ExecuteScan()
 */
void Adoption_MaintainTracking()
{
   int writeIdx = 0;
   datetime now = TimeCurrent();

   for(int i = 0; i < g_trackingCount; i++)
     {
      //--- Keep entries less than 5 minutes old
      if(now - g_posTracking[i].firstSeen < 300)
        {
         if(writeIdx != i)
            g_posTracking[writeIdx] = g_posTracking[i];
         writeIdx++;
        }
     }

   //--- Clear removed entries
   for(int i = writeIdx; i < g_trackingCount; i++)
     {
      g_posTracking[i].ticket = 0;
      g_posTracking[i].processed = false;
     }

   g_trackingCount = writeIdx;
}

/**
 * Get or create tracking index for a ticket
 * @param ticket  Position ticket
 * @return Tracking array index
 */
int Adoption_GetTrackingIndex(const ulong ticket)
{
   //--- Search existing
   for(int i = 0; i < g_trackingCount; i++)
     {
      if(g_posTracking[i].ticket == ticket)
         return i;
     }

   //--- Create new if space available
   if(g_trackingCount < 256)
     {
      int idx = g_trackingCount;
      g_posTracking[idx].ticket = ticket;
      g_posTracking[idx].firstSeen = TimeCurrent();
      g_posTracking[idx].processed = false;
      g_trackingCount++;
      return idx;
     }

   return -1;  // No space
}

//+------------------------------------------------------------------+
//| STRING UTILITIES                                                   |
//+------------------------------------------------------------------+

/**
 * Trim leading and trailing whitespace from a string
 * @param text  Input string
 * @return Trimmed string
 */
string Adoption_StringTrim(const string text)
{
   string result = text;
   int len = StringLen(result);

   //--- Trim leading
   while(len > 0 && StringGetCharacter(result, 0) <= 32)
      result = StringSubstr(result, 1);

   //--- Trim trailing
   len = StringLen(result);
   while(len > 0 && StringGetCharacter(result, len - 1) <= 32)
      result = StringSubstr(result, 0, len - 1);

   return result;
}

//+------------------------------------------------------------------+
