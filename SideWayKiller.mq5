//+------------------------------------------------------------------+
//|                                         SideWayKiller.mq5         |
//|                                 SIDEWAY KILLER Expert Advisor     |
//|                                 XAUUSD Recovery System            |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Team"
#property version   "1.00"
#property strict

//--- Phase 1: Foundation Layer
#include "Modules/SK_Config.mqh"
#include "Modules/SK_DataTypes.mqh"
#include "Modules/SK_GVSchema.mqh"
#include "Modules/SK_SSoT.mqh"

//--- Phase 2: Position Adoption
#include "Modules/SK_Adoption.mqh"

//--- Phase 3: Grid & Lot Multiplier
#include "Modules/SK_Grid.mqh"
#include "Modules/SK_LotMultiplier.mqh"

//--- Phase 4: Fast-Strike
#include "Modules/SK_FastStrike.mqh"

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize SSoT system (Foundation)
   if(!SSoT_Initialize())
     {
      Print("[ERROR] SSoT initialization failed!");
      return INIT_FAILED;
     }

   //--- Load existing basket state from Global Variables
   SSoT_LoadFromGlobals();

   //--- Initialize Phase 2: Adoption
   Adoption_Init();

   //--- Initialize Phase 3: Grid & Lot
   Grid_Init();
   Lot_Init();

   //--- Initialize Phase 4: Fast-Strike
   FastStrike_Init();

   //--- Set up timer for cold path sync (1 second interval)
   EventSetTimer(1);

   Print("[INIT] SIDEWAY KILLER v", SK_VERSION, " initialized. Active baskets: ", g_basketCount);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Save final state before shutdown
   SSoT_Deinit(reason);

   //--- Deinitialize modules
   Adoption_Deinit();
   Lot_Deinit();
   FastStrike_Deinit();
   Grid_Deinit();

   //--- Kill timer
   EventKillTimer();

   Print("[DEINIT] SIDEWAY KILLER shutdown. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (HOT PATH)                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- HOT PATH: Fast operations using cache only
   //--- CRITICAL: NO GlobalVariable calls in this function
   //--- Priority Order: Profit First → Protection → Recovery

   if(!g_cacheValid)
      return;

   //--- Update dashboard prices (minimal overhead)
   g_dashboard.currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_dashboard.currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- PRIORITY 1: Fast-Strike profit check (FIRST operation)
   //--- Returns early if a basket was closed — Profit First directive
   if(FastStrikeCheck())
      return;  // Basket closed — exit immediately

   //--- PRIORITY 2: Virtual Trailing (Phase 5 placeholder)
   //--- Future: UpdateAllVirtualTrailings()

   //--- PRIORITY 3: Grid Level checks
   //--- Checks if any basket qualifies for new recovery level
   CheckGridLevels(g_dashboard.currentBid, g_dashboard.currentAsk);
}

//+------------------------------------------------------------------+
//| Timer function (COLD PATH)                                         |
//+------------------------------------------------------------------+
void OnTimer()
{
   //--- COLD PATH: Sync cache with Global Variables
   SSoT_SyncCacheFromGlobals();

   //--- Refresh all cold-path caches
   Grid_RefreshCache();
   FastStrike_RefreshCache();
   Lot_RefreshCache();

   //--- Update market state for adaptive systems
   Adoption_UpdateMarketState();

   //--- Scan for adoption candidates
   Adoption_ExecuteScan();

   //--- Phase 4: Update API verification cache (Layer 3)
   FastStrike_UpdateApiCache();

   //--- Phase 4: Validate math accuracy (every 10 seconds)
   static int validateCounter = 0;
   validateCounter++;
   if(validateCounter >= 10)
     {
      validateCounter = 0;
      FastStrike_ValidateMathAccuracy();
     }

   //--- Future: Checkpoint persistence
   //--- Future: User command scanning
}
