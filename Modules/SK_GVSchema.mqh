//+------------------------------------------------------------------+
//|                                             SK_GVSchema.mqh      |
//|                                    SIDEWAY KILLER - Phase 1      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

#include "SK_Config.mqh"

//+==================================================================+
//| GLOBAL VARIABLE NAMING CONVENTION                                  |
//+==================================================================+
//| All GV names follow strict patterns to prevent collisions:         |
//|                                                                    |
//| Baskets:    SK_B<id>_<FIELD>                                       |
//| Levels:     SK_B<id>_L<lvl>_<FIELD>                                |
//| Trailing:   SK_T<id>_<FIELD>                                       |
//| Statistics: SK_STATS_<FIELD>                                       |
//| State:      SK_STATE_<FIELD>                                       |
//| Dashboard:  SK_DASH_<FIELD>                                        |
//+==================================================================+

//+------------------------------------------------------------------+
//| BASKET CORE FIELD SUFFIXES (9 fields per basket)                   |
//| Pattern: SK_B<id>_<FIELD>                                          |
//+------------------------------------------------------------------+
#define GV_BASKET_WA        "_WA"       // Weighted Average Price (double)
#define GV_BASKET_VOL       "_VOL"      // Total Volume in lots (double)
#define GV_BASKET_TARGET    "_TGT"      // Profit Target USD (double)
#define GV_BASKET_STATUS    "_STS"      // Status: 0=Active,1=Closing,2=Closed
#define GV_BASKET_LEVELS    "_LVL"      // Number of grid levels (double)
#define GV_BASKET_DIR       "_DIR"      // Direction: 0=BUY, 1=SELL (double)
#define GV_BASKET_CREATED   "_CRT"      // Creation timestamp (double)
#define GV_BASKET_MAGIC     "_MGC"      // Original magic number (double)
#define GV_BASKET_TICKET0   "_TK0"      // Original position ticket (double)

//+------------------------------------------------------------------+
//| PER-LEVEL FIELD SUFFIXES                                           |
//| Pattern: SK_B<id>_L<level>_<FIELD>                                 |
//+------------------------------------------------------------------+
#define GV_LEVEL_TICKET     "_TIX"      // Position ticket (double)
#define GV_LEVEL_LOT        "_LOT"      // Lot size (double)
#define GV_LEVEL_PRICE      "_PRC"      // Open price (double)
#define GV_LEVEL_TIME       "_TIM"      // Open timestamp (double)
#define GV_LEVEL_ORIGINAL   "_ORG"      // Is original flag: 0/1 (double)

//+------------------------------------------------------------------+
//| VIRTUAL TRAILING CHECKPOINT FIELD SUFFIXES                         |
//| Pattern: SK_T<id>_<FIELD>                                          |
//+------------------------------------------------------------------+
#define GV_TRAIL_PEAK       "_PEAK"     // Peak price (double)
#define GV_TRAIL_STOP       "_STOP"     // Virtual stop level (double)
#define GV_TRAIL_ACTIVE     "_ACT"      // Activated flag: 0/1 (double)
#define GV_TRAIL_TIME       "_TIME"     // Last checkpoint time (double)

//+------------------------------------------------------------------+
//| TRADE STATISTICS FIELD SUFFIXES                                    |
//| Pattern: SK_STATS_<FIELD>                                          |
//+------------------------------------------------------------------+
#define GV_STATS_VERSION    "_VER"      // Schema version (double)
#define GV_STATS_TOTAL      "_TOT"      // Total trades (double)
#define GV_STATS_WINS       "_WIN"      // Win count (double)
#define GV_STATS_LOSSES     "_LOS"      // Loss count (double)
#define GV_STATS_WINAMT     "_WAMT"     // Total win amount (double)
#define GV_STATS_LOSSAMT    "_LAMT"     // Total loss amount (double)
#define GV_STATS_ALPHA      "_ALPHA"    // Bayesian alpha (double)
#define GV_STATS_BETA       "_BETA"     // Bayesian beta (double)
#define GV_STATS_LASTUP     "_LUP"      // Last update time (double)

//+------------------------------------------------------------------+
//| GLOBAL STATE FIELD SUFFIXES                                        |
//| Pattern: SK_STATE_<FIELD>                                          |
//+------------------------------------------------------------------+
#define GV_STATE_BCOUNT     "_BCNT"     // Active basket count (double)
#define GV_STATE_NEXTID     "_NEXT"     // Next basket ID (double)
#define GV_STATE_INIT       "_INIT"     // Init timestamp (double)
#define GV_STATE_HEAT       "_HEAT"     // Current heat % (double)
#define GV_STATE_SCHEMA     "_SCHEMA"   // Schema version (double)

//+------------------------------------------------------------------+
//| DASHBOARD FIELD SUFFIXES                                           |
//| Pattern: SK_DASH_<FIELD>                                           |
//+------------------------------------------------------------------+
#define GV_DASH_BID         "_BID"      // Current bid (double)
#define GV_DASH_ASK         "_ASK"      // Current ask (double)
#define GV_DASH_HEAT        "_HEAT"     // Heat percentage (double)
#define GV_DASH_PNL         "_PNL"      // Total floating P&L (double)
#define GV_DASH_COUNT       "_CNT"      // Active basket count (double)
#define GV_DASH_CLOSEST_ID  "_CID"      // Closest basket ID (double)
#define GV_DASH_CLOSEST_PRG "_CPRG"     // Closest basket progress % (double)
#define GV_DASH_UPDATED     "_UPD"      // Dashboard last update (double)

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS - GV NAME GENERATORS                              |
//| All functions generate collision-proof GV names                    |
//+------------------------------------------------------------------+

/**
 * Generate Global Variable name for a basket core field
 * @param basketId  Basket identifier (1-based)
 * @param field     Field suffix (e.g., GV_BASKET_WA)
 * @return Fully qualified GV name, e.g. "SK_B001_WA"
 */
string GV_Name(const ulong basketId, const string field)
{
   return SK_GV_PREFIX + "B" + IntegerToString((int)basketId, 3, '0') + field;
}

/**
 * Generate Global Variable name for a level field
 * @param basketId  Basket identifier (1-based)
 * @param level     Level index (0..SK_MAX_LEVELS-1)
 * @param field     Field suffix (e.g., GV_LEVEL_TICKET)
 * @return Fully qualified GV name, e.g. "SK_B001_L00_TIX"
 */
string GV_LevelName(const ulong basketId, const int level, const string field)
{
   return SK_GV_PREFIX + "B" + IntegerToString((int)basketId, 3, '0') +
          "_L" + IntegerToString(level, 2, '0') + field;
}

/**
 * Generate Global Variable name for a trailing checkpoint field
 * @param basketId  Basket identifier (1-based)
 * @param field     Field suffix (e.g., GV_TRAIL_PEAK)
 * @return Fully qualified GV name, e.g. "SK_T001_PEAK"
 */
string GV_TrailName(const ulong basketId, const string field)
{
   return SK_GV_PREFIX + "T" + IntegerToString((int)basketId, 3, '0') + field;
}

/**
 * Generate Global Variable name for a statistics field
 * @param field     Field suffix (e.g., GV_STATS_TOTAL)
 * @return Fully qualified GV name, e.g. "SK_STATS_TOT"
 */
string GV_StatsName(const string field)
{
   return SK_GV_PREFIX + "STATS" + field;
}

/**
 * Generate Global Variable name for a global state field
 * @param field     Field suffix (e.g., GV_STATE_NEXTID)
 * @return Fully qualified GV name, e.g. "SK_STATE_NEXT"
 */
string GV_StateName(const string field)
{
   return SK_GV_PREFIX + "STATE" + field;
}

/**
 * Generate Global Variable name for a dashboard field
 * @param field     Field suffix (e.g., GV_DASH_BID)
 * @return Fully qualified GV name, e.g. "SK_DASH_BID"
 */
string GV_DashName(const string field)
{
   return SK_GV_PREFIX + "DASH" + field;
}

//+------------------------------------------------------------------+
//| GV ORPHANED RECORD IDENTIFICATION                                  |
//+------------------------------------------------------------------+

/**
 * Check if a given string is a SIDEWAY KILLER GV name
 * Used for cleanup and migration operations
 * @param name  GV name to check
 * @return true if name starts with SK_ prefix
 */
bool IsSK_GlobalVariable(const string name)
{
   return (StringFind(name, SK_GV_PREFIX) == 0);
}

/**
 * Extract basket ID from a GV name
 * @param name  GV name (e.g., "SK_B001_WA")
 * @return Basket ID (1-based) or 0 if invalid
 */
ulong GV_ExtractBasketId(const string name)
{
   if(!IsSK_GlobalVariable(name))
      return 0;

   // Look for pattern "B" followed by 3 digits
   int bPos = StringFind(name, "B");
   if(bPos < 0)
      return 0;

   // Ensure we have enough characters after "B"
   if((int)StringLen(name) < bPos + 4)
      return 0;

   string idStr = StringSubstr(name, bPos + 1, 3);

   // Validate that all 3 chars are digits
   for(int i = 0; i < 3; i++)
     {
      ushort ch = StringGetCharacter(idStr, i);
      if(ch < '0' || ch > '9')
         return 0;
     }

   int id = (int)StringToInteger(idStr);
   if(id > 0 && id <= SK_MAX_BASKETS)
      return (ulong)id;

   return 0;
}

/**
 * Determine the type of GV from its name
 * @param name  GV name
 * @return Type string: "BASKET", "LEVEL", "TRAIL", "STATS", "STATE", "DASH", "UNKNOWN"
 */
string GV_GetType(const string name)
{
   if(!IsSK_GlobalVariable(name))
      return "UNKNOWN";

   int pos = (int)StringLen(SK_GV_PREFIX);
   if(pos >= (int)StringLen(name))
      return "UNKNOWN";

   string suffix = StringSubstr(name, pos);

   if(StringFind(suffix, "B") == 0)
     {
      if(StringFind(suffix, "_L") >= 0)
         return "LEVEL";
      return "BASKET";
     }
   if(StringFind(suffix, "T") == 0)
      return "TRAIL";
   if(StringFind(suffix, "STATS") == 0)
      return "STATS";
   if(StringFind(suffix, "STATE") == 0)
      return "STATE";
   if(StringFind(suffix, "DASH") == 0)
      return "DASH";

   return "UNKNOWN";
}

//+------------------------------------------------------------------+
//| GV TOTAL COUNT ESTIMATION                                          |
//+------------------------------------------------------------------+

/**
 * Calculate maximum possible GVs per basket
 * Core fields: 9
 * Level fields: SK_MAX_LEVELS * 5 (TIX, LOT, PRC, TIM, ORG)
 * Trailing fields: 4 (PEAK, STOP, ACT, TIME)
 * Total per basket: 9 + (SK_MAX_LEVELS * 5) + 4
 * With SK_MAX_LEVELS=7: 9 + 35 + 4 = 48 GVs per basket
 * With SK_MAX_BASKETS=20: 960 basket GVs
 * Plus: ~9 stats + ~6 state + ~8 dashboard = ~23 global GVs
 * Maximum total: ~983 GVs (well within MT5 limit of ~4096)
 */
int GV_MaxGVsPerBasket()
{
   return 9 + (SK_MAX_LEVELS * 5) + 4;  // core + levels + trailing
}

int GV_MaxTotalGVs()
{
   return (GV_MaxGVsPerBasket() * SK_MAX_BASKETS) + 23;  // + stats/state/dash
}

//+------------------------------------------------------------------+
