//+------------------------------------------------------------------+
//|                                         SK_LotMultiplier.mqh     |
//|                                    SIDEWAY KILLER - Phase 3      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"
#include "SK_DataTypes.mqh"
#include "SK_GVSchema.mqh"
#include "SK_SSoT.mqh"

//+==================================================================+
//| LOT MULTIPLIER SYSTEM — Configurable Multi-Mode Architecture       |
//|                                                                    |
//|  Modes: FIXED (default), BAYESIAN KELLY, HYBRID                    |
//|  Heat Constraint: ALWAYS applied (overrides all modes)             |
//|  Cold Path: Bayesian stats, heat cache, Kelly pre-computation      |
//|  Hot Path: Cache-only — MathPow + comparison only                  |
//+==================================================================+

//+------------------------------------------------------------------+
//| COLD-PATH CACHED VALUES                                            |
//+------------------------------------------------------------------+

double  g_lotCachedKellyMult = 1.5;       // Pre-computed Kelly multiplier
double  g_lotCachedWinRate = 0.65;        // Current Bayesian win rate
double  g_lotCachedAvgWin = 0;            // Average win amount
double  g_lotCachedAvgLoss = 0;           // Average loss amount
double  g_lotCachedRewardRatio = 1.0;     // b = AvgWin / AvgLoss
double  g_lotCachedHeatPct = 0;           // Pre-computed current heat %

//+------------------------------------------------------------------+
//| PUBLIC API — Initialization                                        |
//+------------------------------------------------------------------+

/**
 * Initialize the lot multiplier system
 * Loads trade statistics from GVs, initializes Bayesian priors
 * @return true on success
 */
bool Lot_Init()
{
   //--- Load trade stats from GVs (via SSoT)
   SSoT_LoadTradeStats();

   //--- Initialize Bayesian priors if fresh start
   if(g_tradeStats.alpha <= 0 || g_tradeStats.beta <= 0)
     {
      g_tradeStats.alpha = Inp_Bayesian_PriorWR * Inp_Bayesian_PriorStr;
      g_tradeStats.beta = (1.0 - Inp_Bayesian_PriorWR) * Inp_Bayesian_PriorStr;
     }

   //--- Pre-compute initial values
   Lot_RefreshCache();

   Print("[Lot] Initialized. Mode: ",
         (Inp_LotMode == LOT_FIXED ? "FIXED" :
          Inp_LotMode == LOT_BAYESIAN ? "BAYESIAN" :
          Inp_LotMode == LOT_HYBRID ? "HYBRID" : "UNKNOWN"),
         " | Trades: ", g_tradeStats.totalTrades,
         " | WinRate: ", DoubleToString(g_lotCachedWinRate * 100, 1), "%");

   return true;
}

/**
 * Deinitialize the lot multiplier system
 * Saves trade statistics before shutdown
 */
void Lot_Deinit()
{
   SSoT_SaveTradeStats();
   Print("[Lot] Deinitialized. Saved ", g_tradeStats.totalTrades, " trades");
}

//+------------------------------------------------------------------+
//| COLD PATH — Refresh cache values                                   |
//| Called from OnTimer() — never from OnTick()                        |
//+------------------------------------------------------------------+

/**
 * Refresh lot multiplier cache values
 * Recomputes Bayesian stats, heat, Kelly fraction
 */
void Lot_RefreshCache()
{
   //--- Compute Bayesian win rate
   //--- AUDIT GUARD #2: Prevent div/0 if stats cleared manually
   double alphaBetaSum = g_tradeStats.alpha + g_tradeStats.beta;
   if(alphaBetaSum <= 0)
     {
      g_lotCachedWinRate = Inp_Bayesian_PriorWR;
      g_tradeStats.alpha = Inp_Bayesian_PriorWR * Inp_Bayesian_PriorStr;
      g_tradeStats.beta = (1.0 - Inp_Bayesian_PriorWR) * Inp_Bayesian_PriorStr;
      alphaBetaSum = g_tradeStats.alpha + g_tradeStats.beta;
     }
   else
     {
      g_lotCachedWinRate = g_tradeStats.alpha / alphaBetaSum;
     }

   //--- Compute average win/loss
   g_lotCachedAvgWin = 0;
   if(g_tradeStats.wins > 0)
      g_lotCachedAvgWin = g_tradeStats.totalWinAmount / g_tradeStats.wins;

   g_lotCachedAvgLoss = 0;
   if(g_tradeStats.losses > 0)
      g_lotCachedAvgLoss = g_tradeStats.totalLossAmount / g_tradeStats.losses;

   //--- Compute reward-to-risk ratio (b)
   //--- AUDIT GUARD #1: Handle case where b = 0 (no positive edge)
   if(g_lotCachedAvgLoss > 0 && g_lotCachedAvgWin > 0)
     {
      g_lotCachedRewardRatio = g_lotCachedAvgWin / g_lotCachedAvgLoss;
     }
   else
     {
      //--- No data yet — assume neutral edge
      g_lotCachedRewardRatio = 1.0;
     }

   //--- Pre-compute Kelly multiplier
   g_lotCachedKellyMult = Lot_CalculateKellyMultiplierInternal();

   //--- Pre-compute heat
   g_lotCachedHeatPct = Lot_CalculateCurrentHeatInternal();
}

//+------------------------------------------------------------------+
//| PUBLIC API — Get lot multiplier (Hot Path safe)                    |
//+------------------------------------------------------------------+

/**
 * Get lot multiplier for a grid level
 * Hot-path safe: reads only cached values, no indicator/GV calls
 * @param basketIndex  Basket cache index
 * @param level        Grid level (0 = original)
 * @return Final lot multiplier (after heat constraint)
 */
double GetLotMultiplier(const int basketIndex, const int level)
{
   if(level < 0)
      return 1.0;

   double multiplier;

   switch(Inp_LotMode)
     {
      case LOT_FIXED:
         multiplier = Lot_CalculateFixed(level);
         break;

      case LOT_BAYESIAN:
         multiplier = Lot_CalculateBayesianInternal(level);
         break;

      case LOT_HYBRID:
         multiplier = Lot_CalculateHybridInternal(level);
         break;

      default:
         multiplier = Lot_CalculateFixed(level);
         break;
     }

   //--- Apply heat constraint (ALWAYS, regardless of mode)
   multiplier = Lot_ApplyHeatConstraint(multiplier);

   return multiplier;
}

//+------------------------------------------------------------------+
//| MODE 1: FIXED — Constant multiplier with decay                     |
//+------------------------------------------------------------------+

/**
 * Calculate FIXED mode multiplier
 * Formula: BaseMultiplier × (Decay ^ Level)
 */
double Lot_CalculateFixed(const int level)
{
   double base = Inp_Fixed_Multiplier;
   double decay = Inp_Fixed_Decay;
   double levelDecay = MathPow(decay, level);
   double result = base * levelDecay;

   //--- Safety floor
   if(result < 1.0)
      result = 1.0;

   return result;
}

//+------------------------------------------------------------------+
//| MODE 2: BAYESIAN KELLY — Adaptive with priors                      |
//+------------------------------------------------------------------+

/**
 * Internal Kelly multiplier calculation
 * Uses cached values — no computation needed
 */
double Lot_CalculateKellyMultiplierInternal()
{
   double winRate = g_lotCachedWinRate;
   double b = g_lotCachedRewardRatio;
   double q = 1.0 - winRate;

   //--- AUDIT GUARD #1: Prevent division by zero when b = 0
   if(b < 0.01)
     {
      //--- No positive edge detected — conservative default
      //--- KellyFraction = -1.0 means negative edge
      return 1.0;  // Neutral multiplier base
     }

   //--- Kelly formula: f = (p × b - q) / b
   double kellyFraction = (winRate * b - q) / b;

   //--- Apply safety factor (Quarter Kelly)
   double appliedKelly = kellyFraction * Inp_Bayesian_Safety;
   double kellyMultiplier = 1.0 + appliedKelly;

   //--- Floor at minimum
   if(kellyMultiplier < Inp_Bayesian_MinMult)
      kellyMultiplier = Inp_Bayesian_MinMult;

   //--- Ceiling at maximum
   if(kellyMultiplier > Inp_Bayesian_MaxMult)
      kellyMultiplier = Inp_Bayesian_MaxMult;

   return kellyMultiplier;
}

/**
 * Calculate BAYESIAN KELLY mode multiplier for a specific level
 * Uses pre-computed Kelly multiplier + level decay
 */
double Lot_CalculateBayesianInternal(const int level)
{
   double kellyMult = g_lotCachedKellyMult;
   double decay = Inp_Bayesian_Decay;
   double levelDecay = MathPow(decay, level);
   double result = kellyMult * levelDecay;

   //--- Apply safety bounds
   result = MathMax(result, Inp_Bayesian_MinMult);
   result = MathMin(result, Inp_Bayesian_MaxMult);

   return result;
}

//+------------------------------------------------------------------+
//| MODE 3: HYBRID — Blended FIXED + Kelly                             |
//+------------------------------------------------------------------+

/**
 * Calculate HYBRID mode multiplier
 * Gradually transitions from FIXED to BAYESIAN as data accumulates
 */
double Lot_CalculateHybridInternal(const int level)
{
   double fixed = Lot_CalculateFixed(level);

   //--- Not enough data — use FIXED only
   if(g_tradeStats.totalTrades < Inp_Hybrid_MinTrades)
      return fixed;

   double kelly = Lot_CalculateBayesianInternal(level);

   //--- Calculate Kelly weight based on trade count
   double tradeRatio = (double)g_tradeStats.totalTrades / Inp_Hybrid_MinTrades;
   double kellyWeight = MathMin(tradeRatio, 1.0) * Inp_Hybrid_KellyWeight;
   double fixedWeight = 1.0 - kellyWeight;

   //--- Blend
   double result = fixedWeight * fixed + kellyWeight * kelly;

   //--- Safety floor
   if(result < 1.0)
      result = 1.0;

   return result;
}

//+------------------------------------------------------------------+
//| HEAT CONSTRAINT — Applies to ALL modes (NON-NEGOTIABLE)            |
//+------------------------------------------------------------------+

/**
 * Apply heat constraint to lot multiplier
 * Called for EVERY mode after mode-specific calculation
 *
 * Zones:
 *   Normal    (HeatRatio ≤ 0.70): No change
 *   Warning   (0.70 < HeatRatio ≤ 0.90): Reduce 20%
 *   Critical  (HeatRatio > 0.90): Force minimum (1.1)
 *
 * @param multiplier  Mode-specific multiplier
 * @return Constrained multiplier
 */
double Lot_ApplyHeatConstraint(const double multiplier)
{
   //--- AUDIT GUARD #3: Prevent div/0 if user sets MaxRecoveryHeat = 0
   if(Inp_MaxRecoveryHeat <= 0)
      return multiplier;  // Normal zone — most permissive

   double currentHeat = g_lotCachedHeatPct;

   if(currentHeat < 0)
      currentHeat = 0;
   if(currentHeat > 100.0)
      currentHeat = 100.0;

   double heatRatio = currentHeat / Inp_MaxRecoveryHeat;

   if(heatRatio > 0.90)
     {
      //--- CRITICAL: Force minimum multiplier
      Print("[Lot] CRITICAL: Heat at ", DoubleToString(currentHeat, 1),
            "% (ratio=", DoubleToString(heatRatio, 2), "), forcing minimum multiplier");
      return Inp_Bayesian_MinMult;
     }
   else if(heatRatio > 0.70)
     {
      //--- WARNING: Reduce multiplier by 20%
      double reduced = multiplier * DEF_HEAT_REDUCTION;
      Print("[Lot] WARNING: Heat at ", DoubleToString(currentHeat, 1),
            "% (ratio=", DoubleToString(heatRatio, 2), "), reducing multiplier ",
            DoubleToString(multiplier, 3), " → ", DoubleToString(reduced, 3));
      return reduced;
     }

   //--- NORMAL: No constraint
   return multiplier;
}

/**
 * Calculate current account heat percentage
 * Uses cached basket data — no position API calls
 * @return Heat as percentage (0.0 - 100.0+)
 */
double Lot_CalculateCurrentHeatInternal()
{
   double totalDrawdown = 0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0)
     {
      Print("[Lot] WARNING: Account balance is 0 — returning max heat");
      return 100.0;
     }

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid)
         continue;
      if(g_baskets[i].status != BASKET_ACTIVE)
         continue;

      double currentPrice;
      if(g_baskets[i].direction == 0)  // BUY
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      else  // SELL
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double dist = 0;
      if(g_baskets[i].direction == 0)
         dist = g_baskets[i].weightedAvg - currentPrice;
      else
         dist = currentPrice - g_baskets[i].weightedAvg;

      //--- Only count drawdown (positive = in loss)
      if(dist > 0)
         totalDrawdown += dist * g_baskets[i].totalVolume * 100.0;
     }

   return (totalDrawdown / balance) * 100.0;
}

//+------------------------------------------------------------------+
//| LOT NORMALIZATION — Broker constraints                             |
//+------------------------------------------------------------------+

/**
 * Normalize lot size to broker constraints
 * @param lot  Raw lot size
 * @return Normalized lot size
 */
double Lot_Normalize(const double lot)
{
   if(lot <= 0)
      return 0;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0) minLot = 0.01;
   if(maxLot <= 0) maxLot = 100.0;
   if(lotStep <= 0) lotStep = 0.01;

   double normalized = lot;

   //--- Floor at minimum
   if(normalized < minLot)
      normalized = minLot;

   //--- Ceiling at maximum
   if(normalized > maxLot)
      normalized = maxLot;

   //--- Round to lot step
   normalized = MathFloor(normalized / lotStep) * lotStep;

   //--- Final safety check
   if(normalized < minLot)
      normalized = minLot;
   if(normalized > maxLot)
      normalized = maxLot;

   return NormalizeDouble(normalized, 2);
}

//+------------------------------------------------------------------+
//| TRADE STATISTICS — Updated on basket close                         |
//+------------------------------------------------------------------+

/**
 * Record a completed basket trade
 * Updates Bayesian parameters and persists to GVs
 * @param profit  Net profit/loss in USD
 */
void Lot_OnBasketClosed(const double profit)
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

   //--- Persist to GVs via SSoT
   SSoT_SaveTradeStats();

   //--- Refresh cache with new stats
   Lot_RefreshCache();

   double winRate = 0;
   if(g_tradeStats.totalTrades > 0)
      winRate = ((double)g_tradeStats.wins / g_tradeStats.totalTrades) * 100.0;

   Print("[Lot] Trade recorded: ", (isWin ? "WIN" : "LOSS"),
         " $", DoubleToString(profit, 2),
         " | WinRate: ", DoubleToString(winRate, 1), "%",
         " | Total: ", g_tradeStats.totalTrades,
         " | KellyMult: ", DoubleToString(g_lotCachedKellyMult, 3));
}

//+------------------------------------------------------------------+
