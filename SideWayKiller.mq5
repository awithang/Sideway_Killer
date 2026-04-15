//+------------------------------------------------------------------+
//|                                         SideWayKiller.mq5         |
//|                                 SIDEWAY KILLER Expert Advisor     |
//|                                 XAUUSD Recovery System v1.0.0     |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Team"
#property version   "1.000"
#property strict
#property description "SIDEWAY KILLER - High-Performance XAUUSD Recovery EA"
#property description "Phases 1-7 Fully Integrated | Command Center Dashboard"
#property description "SSoT Architecture | Fast-Strike | Handover Protocol | Safety Guards"

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

//--- Phase 5: Trailing Stop
#include "Modules/SK_TrailingStop.mqh"

//--- Phase 6: Heat & Safety
#include "Modules/SK_Safety.mqh"

//--- Phase 7: Command Center Dashboard
#include "Modules/SK_Dashboard.mqh"

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- STEP 1: Initialize SSoT system (Foundation)
   //--- This includes the one-time GV purge of orphan baskets
   if(!SSoT_Initialize())
     {
      Print("[ERROR] SSoT initialization failed!");
      return INIT_FAILED;
     }

   //--- STEP 1b: Purge orphan GVs (status = 2.0) from past sessions
   SSoT_PurgeOrphanGVs();

   //--- STEP 2: Load existing basket state from Global Variables
   //--- This MUST complete BEFORE Dashboard_Init() so cache is populated
   //--- This function also:
   //---   a) Deduplicates adoption loop debris (same ticket in multiple baskets)
   //---   b) Populates persistent adoption map from loaded tickets
   //---   c) Scans for orphan positions and adopts them immediately
   SSoT_LoadFromGlobals();

   //--- STEP 3: Load trailing checkpoints for handed-over baskets
   for(ulong id = 1; id <= (ulong)SK_MAX_BASKETS; id++)
     {
      string statusName = GV_Name(id, GV_BASKET_STATUS);
      if(!GlobalVariableCheck(statusName))
         continue;
      double status = GlobalVariableGet(statusName);
      if(status >= 2.0)
         continue;

      for(int i = 0; i < g_basketCount; i++)
        {
         if(g_baskets[i].basketId == id)
           {
            Trailing_LoadCheckpoint(id, i);
            break;
           }
        }
     }

   //--- STEP 4: Initialize all other modules
   Adoption_Init();
   Grid_Init();
   Lot_Init();
   FastStrike_Init();
   Trailing_Init();
   Safety_Init();

   //--- STEP 5: Initialize Dashboard LAST (after cache is 100% ready)
   Dashboard_Init();

   //--- STEP 6: Set up 200ms millisecond timer for all operations
   EventSetMillisecondTimer(DASH_MS_TIMER_INTERVAL);

   Print("[INIT] SIDEWAY KILLER v", SK_VERSION, " initialized. Active baskets: ", g_basketCount,
         " | Cache valid: ", g_cacheValid);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SSoT_Deinit(reason);

   //--- Deinitialize modules (reverse init order)
   Dashboard_Deinit();
   Safety_Deinit();
   Trailing_Deinit(reason);
   FastStrike_Deinit();
   Lot_Deinit();
   Grid_Deinit();
   Adoption_Deinit();

   EventKillTimer();

   Print("[DEINIT] SIDEWAY KILLER shutdown. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (HOT PATH)                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_cacheValid)
      return;

   g_dashboard.currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_dashboard.currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- PRIORITY 1: Fast-Strike with handover (FIRST)
   //--- Handover does NOT close baskets, so we continue to process other baskets
   FastStrikeCheckWithHandover();

   //--- PRIORITY 2: Virtual Trailing
   Trailing_UpdateAllVirtualTrailings(g_dashboard.currentBid, g_dashboard.currentAsk);

   //--- PRIORITY 3: Grid Level checks (safety-guarded)
   if(!Safety_IsOperationAllowed("GRID"))
     {
      static datetime s_lastSpreadAudit = 0;
      if(TimeCurrent() != s_lastSpreadAudit)
        {
         long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         Print("[AUDIT] OnTick GRID blocked | Spread:", currentSpread, "pts (Limit:", DEF_MAX_SPREAD_POINTS, ")");
         s_lastSpreadAudit = TimeCurrent();
        }
      return;
     }

   CheckGridLevels(g_dashboard.currentBid, g_dashboard.currentAsk);
}

//+------------------------------------------------------------------+
//| Timer function (200ms - SINGLE TIMER FOR ALL OPERATIONS)           |
//+------------------------------------------------------------------+
void OnTimer()
{
   Dashboard_TimerCycle();
}

//+------------------------------------------------------------------+
//| Chart event handler                                                |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                   const double &dparam, const string &sparam)
{
   Dashboard_OnChartEvent(id, lparam, dparam, sparam);
}
