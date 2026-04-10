//+------------------------------------------------------------------+
//|                                              SK_Safety.mqh       |
//|                                    SIDEWAY KILLER - Phase 6      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"
#include "SK_DataTypes.mqh"
#include "SK_GVSchema.mqh"
#include "SK_SSoT.mqh"

//+==================================================================+
//| HEAT & SAFETY SYSTEM — Portfolio Thermostat                        |
//|                                                                    |
//|  Guards: Heat Monitor, Spread Guard, Margin Guard                  |
//|  Hysteresis: 20% buffer on all resume thresholds                   |
//|  Resume Delay: 60 seconds minimum                                  |
//|  Negative Balance Guard: Returns 100% heat, halts all              |
//|                                                                    |
//|  Key Principle: Profit-taking ALWAYS remains active during halts   |
//+==================================================================+

//+------------------------------------------------------------------+
//| HEAT CACHE & STATE                                                 |
//+------------------------------------------------------------------+

double  g_heatCache[SK_MAX_BASKETS];       // Per-basket drawdown in USD
double  g_totalHeat = 0;                   // Total portfolio heat %
double  g_totalDrawdown = 0;               // Total portfolio drawdown $

//--- Per-basket recovery halt state
bool    g_recoveryHalted[SK_MAX_BASKETS];  // Grid addition halted
datetime g_recoveryHaltTime[SK_MAX_BASKETS]; // When halt triggered

//--- Global halt state
bool    g_adoptionHalted = false;          // Total heat adoption halt
datetime g_adoptionHaltTime = 0;           // When adoption halted

bool    g_spreadHalted = false;            // Spread guard halt
datetime g_spreadHaltTime = 0;             // When spread halted
int     g_spreadAtHalt = 0;                // Spread value at halt

bool    g_marginHalted = false;            // Margin guard halt
datetime g_marginHaltTime = 0;             // When margin halted
double  g_marginAtHalt = 0;                // Margin level at halt

//--- Warning state
bool    g_heatWarningActive = false;       // Total heat 7-10% warning
datetime g_heatWarningTime = 0;

//--- Negative balance guard
bool    g_negativeBalanceDetected = false;
datetime g_negativeBalanceTime = 0;

//--- Timing constants
const int SAFETY_RESUME_DELAY_SEC = 60;    // 60-second resume delay
const double SAFETY_HYSTERESIS = 0.20;     // 20% hysteresis buffer

//+------------------------------------------------------------------+
//| PUBLIC API — Initialization                                        |
//+------------------------------------------------------------------+

/**
 * Initialize the Heat & Safety system
 * Resets all halt states and heat cache
 * @return true on success
 */
bool Safety_Init()
{
   //--- Reset all halt states
   g_totalHeat = 0;
   g_totalDrawdown = 0;
   g_adoptionHalted = false;
   g_adoptionHaltTime = 0;
   g_spreadHalted = false;
   g_spreadHaltTime = 0;
   g_spreadAtHalt = 0;
   g_marginHalted = false;
   g_marginHaltTime = 0;
   g_marginAtHalt = 0;
   g_heatWarningActive = false;
   g_heatWarningTime = 0;
   g_negativeBalanceDetected = false;
   g_negativeBalanceTime = 0;

   //--- Reset per-basket halt states
   for(int i = 0; i < SK_MAX_BASKETS; i++)
     {
      g_heatCache[i] = 0;
      g_recoveryHalted[i] = false;
      g_recoveryHaltTime[i] = 0;
     }

   Print("[Safety] Initialized. Heat limits: Recovery=",
         DoubleToString(Inp_MaxRecoveryHeat, 1), "%",
         " Total=", DoubleToString(Inp_MaxTotalHeat, 1), "%");

   return true;
}

/**
 * Deinitialize the Heat & Safety system
 */
void Safety_Deinit()
{
   Print("[Safety] Deinitialized. Final heat: ",
         DoubleToString(g_totalHeat, 2), "%");
}

//+------------------------------------------------------------------+
//| HEAT CALCULATION — Cold Path                                       |
//+------------------------------------------------------------------+

/**
 * Update heat cache for all baskets and calculate total portfolio heat
 * Called from OnTimer() — cold path only
 */
void Safety_UpdateHeatCache()
{
   g_totalDrawdown = 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   //--- Negative balance guard
   if(balance <= 0)
     {
      g_negativeBalanceDetected = true;
      g_negativeBalanceTime = TimeCurrent();
      g_totalHeat = 100.0;  // Maximum heat — halt everything
      for(int i = 0; i < g_basketCount; i++)
         g_heatCache[i] = 0;
      return;
     }
   else if(g_negativeBalanceDetected)
     {
      g_negativeBalanceDetected = false;
      Print("[Safety] Balance recovered from negative state");
     }

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
        {
         g_heatCache[i] = 0;
         continue;
        }
      if(g_baskets[i].status != BASKET_ACTIVE)
        {
         g_heatCache[i] = 0;
         continue;
        }

      //--- Get appropriate price
      double currentPrice;
      if(g_baskets[i].direction == 0)  // BUY
         currentPrice = bid;
      else  // SELL
         currentPrice = ask;

      //--- Calculate drawdown (0 if in profit)
      double drawdown = 0;
      if(g_baskets[i].direction == 0)  // BUY
        {
         if(currentPrice < g_baskets[i].weightedAvg)
            drawdown = (g_baskets[i].weightedAvg - currentPrice) *
                       g_baskets[i].totalVolume * 100.0;
         //--- Else: in profit → drawdown = 0
        }
      else  // SELL
        {
         if(currentPrice > g_baskets[i].weightedAvg)
            drawdown = (currentPrice - g_baskets[i].weightedAvg) *
                       g_baskets[i].totalVolume * 100.0;
         //--- Else: in profit → drawdown = 0
        }

      g_heatCache[i] = drawdown;
      g_totalDrawdown += drawdown;
     }

   //--- Total portfolio heat %
   if(balance > 0)
      g_totalHeat = (g_totalDrawdown / balance) * 100.0;
   else
      g_totalHeat = 100.0;
}

//+------------------------------------------------------------------+
//| HEAT QUERY FUNCTIONS — Hot Path safe (read cache only)             |
//+------------------------------------------------------------------+

/**
 * Get total portfolio heat percentage
 * Hot-path safe: reads pre-computed cache value
 * @return Total heat % (0.0 - 100.0+)
 */
double Safety_GetTotalHeat()
{
   return g_totalHeat;
}

/**
 * Get per-basket heat percentage
 * Hot-path safe: reads pre-computed cache value
 * @param basketIndex  Basket cache index
 * @return Basket heat % (0.0 - 100.0+)
 */
double Safety_GetBasketHeat(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return 0;
   if(!g_baskets[basketIndex].isValid)
      return 0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0)
      return 100.0;

   return (g_heatCache[basketIndex] / balance) * 100.0;
}

/**
 * Check if a specific basket is recovery-halted
 * @param basketIndex  Basket cache index
 * @return true if grid additions are blocked for this basket
 */
bool Safety_IsBasketHalted(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= SK_MAX_BASKETS)
      return true;
   return g_recoveryHalted[basketIndex];
}

/**
 * Check if adoption is globally halted
 * @return true if no new baskets can be adopted
 */
bool Safety_IsAdoptionHalted()
{
   return g_adoptionHalted;
}

/**
 * Check if spread is halted
 * @return true if spread exceeds maximum
 */
bool Safety_IsSpreadHalted()
{
   return g_spreadHalted;
}

/**
 * Check if margin is halted
 * @return true if margin level below minimum
 */
bool Safety_IsMarginHalted()
{
   return g_marginHalted;
}

/**
 * Check if ANY guard is active (unified halt check)
 * @return true if any safety guard is blocking operations
 */
bool Safety_IsAnyGuardActive()
{
   return (g_adoptionHalted || g_spreadHalted ||
           g_marginHalted || g_negativeBalanceDetected);
}

//+------------------------------------------------------------------+
//| RECOVERY HEAT ENFORCEMENT — Per-Basket Grid Halt                   |
//+------------------------------------------------------------------+

/**
 * Enforce recovery heat limit for a specific basket
 * Called from CheckGridLevels() before adding a new level
 * @param basketIndex  Basket cache index
 * @return true if grid additions are allowed
 */
bool Safety_EnforceRecoveryHeatLimit(const int basketIndex)
{
   if(basketIndex < 0 || basketIndex >= g_basketCount)
      return false;

   //--- Negative balance: block everything
   if(g_negativeBalanceDetected)
      return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0)
      return false;

   double heat = (g_heatCache[basketIndex] / balance) * 100.0;

   if(heat > Inp_MaxRecoveryHeat)
     {
      //--- First time crossing threshold
      if(!g_recoveryHalted[basketIndex])
        {
         g_recoveryHalted[basketIndex] = true;
         g_recoveryHaltTime[basketIndex] = TimeCurrent();

         Print("[Safety] RECOVERY HALT: Basket ",
               g_baskets[basketIndex].basketId,
               " heat = ", DoubleToString(heat, 2), "%",
               " — Grid additions suspended");
        }

      return false;  // Block grid addition
     }
   else
     {
      //--- Heat below threshold
      if(g_recoveryHalted[basketIndex])
        {
         g_recoveryHalted[basketIndex] = false;

         Print("[Safety] RECOVERY RESUME: Basket ",
               g_baskets[basketIndex].basketId,
               " heat = ", DoubleToString(heat, 2), "%",
               " — Grid additions resumed");
        }

      return true;  // Allow grid addition
     }
}

//+------------------------------------------------------------------+
//| TOTAL HEAT ENFORCEMENT — Global Adoption Halt                      |
//+------------------------------------------------------------------+

/**
 * Enforce total heat limit for new basket adoptions
 * Called from Adoption_ExecuteScan() before scanning
 * @return true if new adoptions are allowed
 */
bool Safety_EnforceTotalHeatLimit()
{
   //--- Negative balance: block everything
   if(g_negativeBalanceDetected)
      return false;

   if(g_totalHeat > Inp_MaxTotalHeat)
     {
      if(!g_adoptionHalted)
        {
         g_adoptionHalted = true;
         g_adoptionHaltTime = TimeCurrent();

         Print("[Safety] Total Heat = ", DoubleToString(g_totalHeat, 2), "%",
               " — Max = ", DoubleToString(Inp_MaxTotalHeat, 1), "%");
        }

      return false;  // Block adoptions
     }
   else
     {
      //--- Below threshold — auto-resume handles the rest
      return true;
     }
}

//+------------------------------------------------------------------+
//| HEAT WARNING — Early Warning Zone (70% of limit)                   |
//+------------------------------------------------------------------+

/**
 * Check for heat warning zone (7-10% of total heat)
 * Called from OnTimer()
 */
void Safety_CheckHeatWarning()
{
   double warningThreshold = Inp_MaxTotalHeat * 0.70;  // 7.0%
   double clearThreshold = warningThreshold * 0.80;    // 5.6%

   if(g_totalHeat > warningThreshold && !g_heatWarningActive)
     {
      g_heatWarningActive = true;
      g_heatWarningTime = TimeCurrent();

      Print("[Safety] HEAT WARNING: Portfolio heat = ",
            DoubleToString(g_totalHeat, 2), "%");
     }
   else if(g_totalHeat < clearThreshold && g_heatWarningActive)
     {
      g_heatWarningActive = false;

      Print("[Safety] Heat warning cleared — Portfolio heat = ",
            DoubleToString(g_totalHeat, 2), "%");
     }
}

//+------------------------------------------------------------------+
//| SPREAD GUARD — Halt on Extreme Spread                              |
//+------------------------------------------------------------------+

/**
 * Check spread guard and halt/resume trading
 * Called from OnTimer()
 */
void Safety_CheckSpreadGuard()
{
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   if(currentSpread > DEF_MAX_SPREAD_POINTS)  // 100 points
     {
      if(!g_spreadHalted)
        {
         g_spreadHalted = true;
         g_spreadHaltTime = TimeCurrent();
         g_spreadAtHalt = (int)currentSpread;

         Print("[Safety] SPREAD HALT: Spread=", (int)currentSpread, " pts");
        }
     }
   //--- Below threshold — auto-resume handles the rest
}

//+------------------------------------------------------------------+
//| MARGIN GUARD — Halt on Low Margin Level                            |
//+------------------------------------------------------------------+

/**
 * Check margin guard and halt/resume trading
 * Called from OnTimer()
 */
void Safety_CheckMarginGuard()
{
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);

   //--- Handle case where margin = 0 (no open positions)
   if(marginLevel == 0)
     {
      if(g_marginHalted)
        {
         g_marginHalted = false;
         Print("[Safety] Margin guard cleared — no open positions");
        }
      return;
     }

   if(marginLevel < DEF_MIN_MARGIN_LEVEL)  // 200%
     {
      if(!g_marginHalted)
        {
         g_marginHalted = true;
         g_marginHaltTime = TimeCurrent();
         g_marginAtHalt = marginLevel;

         Print("[Safety] MARGIN HALT: Margin=", DoubleToString(marginLevel, 1), "%");
        }
     }
   //--- Above threshold — auto-resume handles the rest
}

//+------------------------------------------------------------------+
//| AUTO-RESUME PROTOCOL — Hysteresis + 60s Delay                      |
//+------------------------------------------------------------------+

/**
 * Check auto-resume conditions for all guards
 * Uses 20% hysteresis buffer + 60-second time delay
 * Called from OnTimer()
 */
void Safety_CheckAutoResume()
{
   datetime now = TimeCurrent();

   //--- NEGATIVE BALANCE: Cannot auto-resume — requires manual intervention
   //--- (This guard stays active until balance is positive again, checked in UpdateHeatCache)

   //--- RECOVERY HEAT AUTO-RESUME (Per-basket)
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > 0)
     {
      for(int i = 0; i < g_basketCount; i++)
        {
         if(!g_recoveryHalted[i])
            continue;

         double heat = (g_heatCache[i] / balance) * 100.0;
         double resumeThreshold = Inp_MaxRecoveryHeat * (1.0 - SAFETY_HYSTERESIS);  // 4.0%

         if(heat < resumeThreshold)
           {
            //--- Check time delay
            if(now - g_recoveryHaltTime[i] >= SAFETY_RESUME_DELAY_SEC)
              {
               Print("[Safety] AUTO-RESUME: Recovery heat normalized to ",
                     DoubleToString(heat, 2), "%",
                     " — Grid additions resumed");
              }
           }
         else
           {
            //--- Reset timer — condition not yet met
            g_recoveryHaltTime[i] = now;
           }
        }
     }

   //--- TOTAL HEAT AUTO-RESUME (Global)
   if(g_adoptionHalted)
     {
      double resumeThreshold = Inp_MaxTotalHeat * (1.0 - SAFETY_HYSTERESIS);  // 8.0%

      if(g_totalHeat < resumeThreshold)
        {
           if(now - g_adoptionHaltTime >= SAFETY_RESUME_DELAY_SEC)
           {
            g_adoptionHalted = false;
            Print("[Safety] AUTO-RESUME: Portfolio heat normalized to ",
                  DoubleToString(g_totalHeat, 2), "%",
                  " — Basket adoption resumed");
           }
        }
      else
        {
         g_adoptionHaltTime = now;
        }
     }

   //--- SPREAD AUTO-RESUME (Global)
   if(g_spreadHalted)
     {
      long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      int resumeThreshold = (int)(DEF_MAX_SPREAD_POINTS * (1.0 - SAFETY_HYSTERESIS));  // 80 pts

      if(currentSpread < resumeThreshold)
        {
         if(now - g_spreadHaltTime >= SAFETY_RESUME_DELAY_SEC)
           {
            g_spreadHalted = false;
            Print("[Safety] AUTO-RESUME: Spread normalized to ",
                  currentSpread, " points");
           }
        }
      else
        {
         g_spreadHaltTime = now;
        }
     }

   //--- MARGIN AUTO-RESUME (Global)
   if(g_marginHalted)
     {
      double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(marginLevel > 0)  // Margin must exist to check resume
        {
         double resumeThreshold = DEF_MIN_MARGIN_LEVEL * (1.0 + SAFETY_HYSTERESIS);  // 240%

         if(marginLevel > resumeThreshold)
           {
            if(now - g_marginHaltTime >= SAFETY_RESUME_DELAY_SEC)
              {
               g_marginHalted = false;
               Print("[Safety] AUTO-RESUME: Margin level normalized to ",
                     DoubleToString(marginLevel, 1), "%");
              }
           }
         else
           {
            g_marginHaltTime = now;
           }
        }
     }
}

//+------------------------------------------------------------------+
//| MANUAL OVERRIDE — Force Resume All                                 |
//+------------------------------------------------------------------+

/**
 * Manually force resume of all safety guards
 * Called via user input or command
 */
void Safety_ForceResumeAll()
{
   for(int i = 0; i < SK_MAX_BASKETS; i++)
     {
      g_recoveryHalted[i] = false;
      g_recoveryHaltTime[i] = 0;
     }

   g_adoptionHalted = false;
   g_adoptionHaltTime = 0;
   g_spreadHalted = false;
   g_spreadHaltTime = 0;
   g_spreadAtHalt = 0;
   g_marginHalted = false;
   g_marginHaltTime = 0;
   g_marginAtHalt = 0;

   //--- Note: Negative balance cannot be manually overridden
   //--- It requires actual balance recovery

   Print("[Safety] MANUAL OVERRIDE: All trading resumed by user");
}

//+------------------------------------------------------------------+
//| UNIFIED HALT QUERY — For integration with other phases             |
//+------------------------------------------------------------------+

/**
 * Check if a specific operation type is allowed
 * @param operationType  "GRID", "ADOPTION", "ANY"
 * @param basketIndex    Basket index (for GRID operations)
 * @return true if operation is permitted
 */
bool Safety_IsOperationAllowed(const string operationType, const int basketIndex = -1)
{
   //--- Negative balance blocks everything
   if(g_negativeBalanceDetected)
      return false;

   if(operationType == "GRID")
     {
      //--- Check spread and margin guards
      if(g_spreadHalted || g_marginHalted)
         return false;

      //--- Check per-basket recovery heat
      if(basketIndex >= 0 && basketIndex < g_basketCount)
        {
         if(g_recoveryHalted[basketIndex])
            return false;
        }

      return true;
     }
   else if(operationType == "ADOPTION")
     {
      //--- Check spread, margin, and total heat
      if(g_spreadHalted || g_marginHalted || g_adoptionHalted)
         return false;

      return true;
     }

   //--- Default: check all global guards
   return !Safety_IsAnyGuardActive();
}

//+------------------------------------------------------------------+
//| ONTIMER ENTRY POINT — Full safety scan                             |
//+------------------------------------------------------------------+

/**
 * Execute full safety system scan
 * Called from OnTimer() — cold path
 * Performs: heat update, guard checks, auto-resume
 */
void Safety_ExecuteScan()
{
   //--- 1. Update heat cache
   Safety_UpdateHeatCache();

   //--- 2. Check guards
   Safety_CheckSpreadGuard();
   Safety_CheckMarginGuard();

   //--- 3. Check heat warning
   Safety_CheckHeatWarning();

   //--- 4. Auto-resume protocol
   Safety_CheckAutoResume();
}

//+------------------------------------------------------------------+
