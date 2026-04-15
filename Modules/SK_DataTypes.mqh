//+------------------------------------------------------------------+
//|                                            SK_DataTypes.mqh      |
//|                                    SIDEWAY KILLER - Phase 1      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"

//+------------------------------------------------------------------+
//| BASKET LEVEL DATA                                                  |
//| Per-level position tracking within a basket                        |
//+------------------------------------------------------------------+
struct BasketLevel
{
   ulong    ticket;        // Position ticket
   double   lotSize;       // Lot size for this level
   double   openPrice;     // Entry price
   datetime openTime;      // Entry timestamp
   bool     isOriginal;    // true for Level 0 only
};

//+------------------------------------------------------------------+
//| BASKET CACHE - In-Memory Working Copy (HOT PATH)                   |
//| All fields optimized for zero-latency read access in OnTick()      |
//+------------------------------------------------------------------+
struct BasketCache
{
   //--- Core Identification
   ulong                basketId;        // Unique basket identifier
   ulong                originalTicket;  // Level 0 position ticket
   ulong                originalMagic;   // Magic number for adoption tracking
   int                  direction;       // 0=BUY, 1=SELL
   ENUM_BASKET_STATUS   status;          // ACTIVE/CLOSING/CLOSED

   //--- Basket State
   int                  levelCount;      // Current number of levels (1..SK_MAX_LEVELS)
   datetime             created;         // Creation timestamp
   double               weightedAvg;     // Volume-weighted average price
   double               totalVolume;     // Sum of all lots
   double               targetProfit;    // Target profit USD for closure

   //--- Per-Level Data (up to SK_MAX_LEVELS)
   BasketLevel          levels[SK_MAX_LEVELS];

   //--- Cache Metadata
   datetime             lastSync;        // Last GV sync timestamp
   bool                 isValid;         // Cache entry validity flag

   //--- Trailing State (inline for hot-path access)
   double               trailPeakPrice;  // Peak price for trailing
   bool                 trailActivated;  // Has virtual trailing activated?
};

//+------------------------------------------------------------------+
//| MARKET STATE - Adaptive filtering data (COLD PATH)                 |
//| Updated periodically via OnTimer()                                 |
//+------------------------------------------------------------------+
struct MarketState
{
   double   atr14;              // ATR 14-period
   double   atr100;             // ATR 100-period
   double   volatilityRatio;    // ATR14 / ATR100
   double   currentSpread;      // Current spread in points
   double   spreadRatio;        // Current Spread / Average Spread
   bool     isHighVolatility;   // volRatio > threshold
   bool     isWideSpread;       // spreadRatio > threshold
   bool     isNewsTime;         // Known news window
   datetime lastUpdate;         // Last market state update
};

//+------------------------------------------------------------------+
//| SPREAD STATISTICS - For adaptive spread buffering                  |
//+------------------------------------------------------------------+
struct SpreadStats
{
   double   average;            // EMA of spread
   double   variance;           // EMA of variance
   double   stdDev;             // Standard deviation
   datetime lastUpdate;         // Last update time
};

//+------------------------------------------------------------------+
//| TRADE STATISTICS - For Bayesian Kelly (persisted to GV)            |
//+------------------------------------------------------------------+
struct TradeStatistics
{
   int      totalTrades;
   int      wins;
   int      losses;
   double   totalWinAmount;
   double   totalLossAmount;
   double   alpha;              // Prior wins + actual wins
   double   beta;               // Prior losses + actual losses
   datetime lastUpdate;
};

//+------------------------------------------------------------------+
//| VIRTUAL TRAILING STATE - Layer 1 Protection (per basket)           |
//| Stored in-memory for <0.1ms hot path execution                     |
//+------------------------------------------------------------------+
struct VirtualTrailingState
{
   double   peakPrice;          // Highest (BUY) or lowest (SELL)
   double   stopLevel;          // Current virtual stop price
   bool     isActivated;        // Has trailing started?
   datetime peakTime;           // When peak was reached
   datetime lastCheck;          // Last tick check
};

//+------------------------------------------------------------------+
//| CHECKPOINT STATE - Layer 2 Persistence (mirrors VirtualTrailing)   |
//| Saved to Global Variables for restart recovery                     |
//+------------------------------------------------------------------+
struct CheckpointState
{
   double   peakPrice;
   double   stopLevel;
   bool     isActivated;
   datetime savedAt;
};

//+------------------------------------------------------------------+
//| FAST-STRIKE VALIDATION CACHE - Optional Layer 3 (cold path)        |
//+------------------------------------------------------------------+
struct APIVerificationCache
{
   double   verifiedProfit;
   datetime lastVerify;
   bool     isValid;
};

//+------------------------------------------------------------------+
//| USER OVERRIDE TRACKING                                             |
//+------------------------------------------------------------------+
struct UserOverrides
{
   ulong    excludedTickets[SK_MAX_BASKETS];  // NOADOPT tickets
   int      excludedCount;
   ulong    forcedTickets[SK_MAX_BASKETS];    // FORCE tickets
   int      forcedCount;
};

//+------------------------------------------------------------------+
//| DASHBOARD METRICS - Real-time display data (written to GV)         |
//+------------------------------------------------------------------+
struct DashboardMetrics
{
   double   currentBid;
   double   currentAsk;
   int      activeBasketCount;
   double   totalExposureLots;
   double   currentHeatPct;
   double   totalFloatingPnL;
   int      closestBasketId;
   double   closestBasketProgress;
   datetime lastUpdate;
};

//+------------------------------------------------------------------+
//| GLOBAL INSTANCE DEFINITIONS (NOT extern - actual storage)          |
//| These are the single in-memory instances for the entire EA         |
//+------------------------------------------------------------------+

//--- Basket cache array - the HOT PATH working layer
BasketCache           g_baskets[SK_MAX_BASKETS];
int                   g_basketCount = 0;           // Number of active baskets
bool                  g_cacheValid = false;        // Global cache validity flag

//--- Market & statistics - COLD PATH data
MarketState           g_market;
SpreadStats           g_spreadStats;
TradeStatistics       g_tradeStats;

//--- Protection layers
VirtualTrailingState  g_virtualTrail[SK_MAX_BASKETS];
CheckpointState       g_checkpoint[SK_MAX_BASKETS];
APIVerificationCache  g_apiCache[SK_MAX_BASKETS];

//--- Emergency tracking
bool                  g_hasEmergencyStops[SK_MAX_BASKETS];
datetime              g_emergencyStopSetTime[SK_MAX_BASKETS];

//--- User controls
UserOverrides         g_userOverrides;

//--- Dashboard
DashboardMetrics      g_dashboard;

//--- System state
ulong                 g_nextBasketId = 1;          // Monotonic ID counter
datetime              g_lastCheckpointSave = 0;
datetime              g_lastAutoSave = 0;
bool                  g_maintenancePlanned = false;
datetime              g_maintenanceTime = 0;
bool                  g_userEmergencyEnabled = false;
bool                  g_userInitiatedShutdown = false;
datetime              g_eaInitTime = 0;

//--- Grid cooldown tracker (per-basket, see SK_Grid.mqh)
// datetime           g_lastGridAddTime = 0;  // REMOVED: replaced by per-basket array

//--- Indicator handles (initialized once, used throughout)
int                   g_atrHandle14 = INVALID_HANDLE;
int                   g_atrHandle100 = INVALID_HANDLE;
