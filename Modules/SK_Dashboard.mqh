//+------------------------------------------------------------------+
//|                                           SK_Dashboard.mqh       |
//|                                    SIDEWAY KILLER - Phase 7      |
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
//| COMMAND CENTER DASHBOARD - Interactive Top-Right UI                |
//|                                                                    |
//|  CORNER_RIGHT_UPPER Coordinate System:                             |
//|    X=0 at chart RIGHT edge. X increases LEFTWARD.                  |
//|    Panel: X=330 (left edge), XSIZE=320 → spans 330→10 from right.  |
//|    All internal objects: X = g_dashBaseX - offset (pull-back).     |
//|    Labels use ANCHOR_LEFT_UPPER → text extends RIGHT (into panel). |
//|                                                                    |
//|  FIX v2.1:                                                         |
//|    - DASH_MARGIN_LEFT = 20px (was 8px)                             |
//|    - Manual trade: SSoT_UpdateDashboard() + ChartRedraw() after    |
//|    - Zero Alert() calls enforced                                   |
//+==================================================================+

//+------------------------------------------------------------------+
//| USER INPUT PARAMETERS                                              |
//+------------------------------------------------------------------+
input int    InpDashXOffset = 10;     // Dashboard X offset from right edge
input int    InpDashYOffset = 10;     // Dashboard Y offset from top

//+------------------------------------------------------------------+
//| DASHBOARD CONSTANTS                                                |
//+------------------------------------------------------------------+

#define DASH_PANEL_X_OFFSET  InpDashXOffset   // Pixels from right edge
#define DASH_PANEL_Y_OFFSET  InpDashYOffset   // Pixels from top
#define DASH_PANEL_WIDTH     320       // Panel width in pixels
#define DASH_PANEL_HEIGHT    380       // Panel height
#define DASH_MARGIN_LEFT     20        // Left margin inside panel (FIXED: was 8)
#define DASH_ROW_HEIGHT      16        // Standard row height
#define DASH_PANEL_BG_COLOR  C'20,20,20'
#define DASH_PANEL_BORDER_CLR clrSteelBlue
#define DASH_FONT            "Arial"
#define DASH_FONT_SIZE       8
#define DASH_FONT_SIZE_BOLD  8
#define DASH_ZORDER_BG       0
#define DASH_ZORDER_FG       1

//--- Timer
const int DASH_MS_TIMER_INTERVAL = 200;
const int DASH_CYCLES_PER_SECOND = 5;

//--- Close-All confirmation
const int DASH_CLOSE_CONFIRM_WINDOW = 5;
#define GV_DASH_CLOSE_ALL_ARMED "SK_DASH_CA_ARMED"
#define GV_DASH_CLOSE_ALL_ARM_TIME "SK_DASH_CA_TIME"

//--- Object name prefixes
#define DASH_OBJ_PANEL     "SK_Dash_Panel"
#define DASH_OBJ_HEADER    "SK_Dash_Header"
#define DASH_OBJ_LIVE      "SK_Dash_Live_"
#define DASH_OBJ_HEAT      "SK_Dash_Heat_"
#define DASH_OBJ_TRAIL     "SK_Dash_Trail_"
#define DASH_OBJ_PERF      "SK_Dash_Perf_"
#define DASH_OBJ_TRADE     "SK_Dash_Trade_"
#define DASH_OBJ_EMERG     "SK_Dash_Emergency_"
#define DASH_OBJ_STATUS    "SK_Dash_Status_"

//+------------------------------------------------------------------+
//| DASHBOARD STATE                                                    |
//+------------------------------------------------------------------+

bool    g_dashInitialized = false;
int     g_dashCycleCount = 0;
double  g_dashPrevPnL = 0;
double  g_dashPrevDD = 0;
double  g_dashPrevBid = 0;
bool    g_dashCloseAllArmed = false;
datetime g_dashCloseAllArmTime = 0;
int     g_dashBaseX = 0;
int     g_dashBaseY = 0;

//--- Status message display
string  g_dashStatusMsg = "Ready";
color   g_dashStatusColor = clrLightGray;

//+------------------------------------------------------------------+
//| PUBLIC API - Initialization                                        |
//+------------------------------------------------------------------+

bool Dashboard_Init()
{
   if(g_dashInitialized)
      return true;

   //--- CORNER_RIGHT_UPPER: XDISTANCE is distance from chart's RIGHT edge.
   //--- Panel left edge at 330, spans 320px rightward → right edge at 10.
   //--- 10px margin from chart right edge. All content uses g_dashBaseX - offset.
   g_dashBaseX = 330;  // DASH_PANEL_WIDTH + 10px margin
   g_dashBaseY = 20;

   Dashboard_CreatePanel();
   Dashboard_CreateHeader();
   Dashboard_CreateLiveMetrics();
   Dashboard_CreateHeatMonitor();
   Dashboard_CreateTrailingTracker();
   Dashboard_CreatePerformanceMetrics();
   Dashboard_CreateTradeControls();
   Dashboard_CreateEmergencyControls();
   Dashboard_CreateSystemStatus();

   Dashboard_LoadCloseAllState();
   Dashboard_FullUpdate();

   g_dashInitialized = true;

   Print("[Dashboard] Command Center initialized. Baskets in cache: ", g_basketCount);
   return true;
}

void Dashboard_Deinit()
{
   Dashboard_SaveCloseAllState();
   Dashboard_RemoveAll();
   g_dashInitialized = false;
   Print("[Dashboard] Deinitialized");
}

void Dashboard_TimerCycle()
{
   g_dashCycleCount++;

   //--- LIVE METRICS: Every cycle (200ms)
   Dashboard_UpdateLiveMetrics();

   //--- SYSTEM LOGIC: Every 5th cycle (1 second)
   if(g_dashCycleCount >= DASH_CYCLES_PER_SECOND)
     {
      g_dashCycleCount = 0;

      SSoT_SyncCacheFromGlobals();
      Grid_RefreshCache();
      FastStrike_RefreshCache();
      Trailing_RefreshCache();

      Adoption_UpdateMarketState();
      if(Safety_IsOperationAllowed("ADOPTION"))
         Adoption_ExecuteScan();

      FastStrike_UpdateApiCache();
      static int validateCounter = 0;
      validateCounter++;
      if(validateCounter >= 10)
        {
         validateCounter = 0;
         FastStrike_ValidateMathAccuracy();
        }

      Trailing_UpdateCheckpointSystem();
      Trailing_ManageEmergencyStops();
      Safety_ExecuteScan();

      Dashboard_FullUpdate();
      SSoT_UpdateDashboard();
     }
}

//+------------------------------------------------------------------+
//| PANEL CREATION                                                     |
//+------------------------------------------------------------------+

void Dashboard_CreatePanel()
{
   Dashboard_CreateRectangle(DASH_OBJ_PANEL,
                             g_dashBaseX, g_dashBaseY,
                             DASH_PANEL_WIDTH, DASH_PANEL_HEIGHT,
                             DASH_PANEL_BG_COLOR, 1, DASH_PANEL_BORDER_CLR,
                             DASH_ZORDER_BG);
}

void Dashboard_CreateHeader()
{
   int x = g_dashBaseX - DASH_MARGIN_LEFT;  // 310
   Dashboard_CreateLabel(DASH_OBJ_HEADER,
                         x, g_dashBaseY + 3,
                         "SIDEWAY KILLER  v" + SK_VERSION,
                         clrWhite, DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
}

void Dashboard_RemoveAll()
{
   string prefix = "SK_Dash_";
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(0, name);
     }
}

//+------------------------------------------------------------------+
//| SECTION 0: LIVE METRICS (200ms updates)                            |
//+------------------------------------------------------------------+

void Dashboard_CreateLiveMetrics()
{
   int left = g_dashBaseX - DASH_MARGIN_LEFT;   // 310
   int row = g_dashBaseY + 22;

   Dashboard_CreateLabel(DASH_OBJ_LIVE + "Header", left, row,
                         "[LIVE] METRICS", clrLightSkyBlue,
                         DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_LIVE + "Bid", left, row,
                         "Bid: ---", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_LIVE + "Ask", left - 95, row,
                         "Ask: ---", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_LIVE + "Spread", left - 190, row,
                         "Spr: ---", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_LIVE + "PnL", left, row,
                         "P&L: $0.00", clrWhite, DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_LIVE + "DD", left - 100, row,
                         "DD: 0.0%", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_LIVE + "Equity", left - 190, row,
                         "Eq: ---", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT + 2;

   Dashboard_CreateHLine(DASH_OBJ_LIVE + "Sep", g_dashBaseX, row, DASH_PANEL_WIDTH, clrDarkGray);
}

void Dashboard_UpdateLiveMetrics()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(MathAbs(bid - g_dashPrevBid) > Point())
     {
      ObjectSetString(0, DASH_OBJ_LIVE + "Bid", OBJPROP_TEXT,
                      "Bid: " + DoubleToString(bid, _Digits));
      ObjectSetString(0, DASH_OBJ_LIVE + "Ask", OBJPROP_TEXT,
                      "Ask: " + DoubleToString(ask, _Digits));
      g_dashPrevBid = bid;
     }

   color sprColor = clrWhite;
   if(spread < 60) sprColor = clrLimeGreen;
   else if(spread < 80) sprColor = clrOrange;
   else sprColor = clrRed;

   ObjectSetString(0, DASH_OBJ_LIVE + "Spread", OBJPROP_TEXT,
                   "Spr: " + IntegerToString((int)spread));
   ObjectSetInteger(0, DASH_OBJ_LIVE + "Spread", OBJPROP_COLOR, sprColor);

   double pnl = Dashboard_CalculateTotalFloatingPnL(bid, ask);
   double dd = g_totalHeat;

   color pnlColor = clrWhite;
   if(pnl > 0 && g_basketCount > 0)
      pnlColor = (pnl > g_baskets[0].targetProfit) ? clrGold : clrLimeGreen;
   else if(pnl < 0)
      pnlColor = (pnl < -20.0) ? clrCrimson : clrOrange;

   color ddColor = clrLimeGreen;
   if(dd > 10.0) ddColor = clrRed;
   else if(dd > 5.0) ddColor = clrOrange;

   string pnlText = "P&L: " + (pnl >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(pnl), 2);
   string ddText = "DD: " + DoubleToString(dd, 1) + "%";
   string eqText = "Eq: $" + DoubleToString(equity, 2);

   if(MathAbs(pnl - g_dashPrevPnL) > 0.01)
     {
      ObjectSetString(0, DASH_OBJ_LIVE + "PnL", OBJPROP_TEXT, pnlText);
      ObjectSetInteger(0, DASH_OBJ_LIVE + "PnL", OBJPROP_COLOR, pnlColor);
      g_dashPrevPnL = pnl;
     }

   if(MathAbs(dd - g_dashPrevDD) > 0.01)
     {
      ObjectSetString(0, DASH_OBJ_LIVE + "DD", OBJPROP_TEXT, ddText);
      ObjectSetInteger(0, DASH_OBJ_LIVE + "DD", OBJPROP_COLOR, ddColor);
      g_dashPrevDD = dd;
     }

   ObjectSetString(0, DASH_OBJ_LIVE + "Equity", OBJPROP_TEXT, eqText);
}

double Dashboard_CalculateTotalFloatingPnL(const double bid, const double ask)
{
   double totalPnL = 0;
   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid || g_baskets[i].status != BASKET_ACTIVE)
         continue;

      double currentPrice = (g_baskets[i].direction == 0) ? bid : ask;
      double diff = (g_baskets[i].direction == 0) ?
                    (currentPrice - g_baskets[i].weightedAvg) :
                    (g_baskets[i].weightedAvg - currentPrice);
      totalPnL += diff * g_baskets[i].totalVolume * 100.0;
     }
   return totalPnL;
}

//+------------------------------------------------------------------+
//| SECTION 1: HEAT MONITOR                                            |
//+------------------------------------------------------------------+

void Dashboard_CreateHeatMonitor()
{
   int left = g_dashBaseX - DASH_MARGIN_LEFT;   // 310
   int row = g_dashBaseY + 90;

   Dashboard_CreateLabel(DASH_OBJ_HEAT + "Header", left, row,
                         "[HEAT] MONITOR", clrOrange,
                         DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_HEAT + "Total", left, row,
                         "Total: 0.0%", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_HEAT + "Status", left - 135, row,
                         "NORMAL", clrLimeGreen, DASH_FONT_SIZE, false, DASH_ZORDER_FG);

   row += DASH_ROW_HEIGHT + 2;
   Dashboard_CreateHLine(DASH_OBJ_HEAT + "Sep", g_dashBaseX, row, DASH_PANEL_WIDTH, clrDarkGray);
}

void Dashboard_UpdateHeatMonitor()
{
   string totalText = "Total: " + DoubleToString(g_totalHeat, 1) + "%";
   ObjectSetString(0, DASH_OBJ_HEAT + "Total", OBJPROP_TEXT, totalText);

   color heatColor = clrLimeGreen;
   string status = "NORMAL";
   if(g_totalHeat > 10.0)
     { heatColor = clrRed; status = "HALTED"; }
   else if(g_totalHeat > 7.0)
     { heatColor = clrOrange; status = "WARNING"; }
   else if(g_totalHeat > 5.0)
     { heatColor = clrYellow; status = "ELEVATED"; }

   ObjectSetInteger(0, DASH_OBJ_HEAT + "Total", OBJPROP_COLOR, heatColor);
   ObjectSetString(0, DASH_OBJ_HEAT + "Status", OBJPROP_TEXT, status);
   ObjectSetInteger(0, DASH_OBJ_HEAT + "Status", OBJPROP_COLOR, heatColor);
}

//+------------------------------------------------------------------+
//| SECTION 2: TRAILING TRACKER                                        |
//+------------------------------------------------------------------+

void Dashboard_CreateTrailingTracker()
{
   int left = g_dashBaseX - DASH_MARGIN_LEFT;   // 310
   int row = g_dashBaseY + 135;

   Dashboard_CreateLabel(DASH_OBJ_TRAIL + "Header", left, row,
                         "[TRAIL] TREND TRACKER", clrLightGreen,
                         DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_TRAIL + "Info", left, row,
                         "No active trailing baskets", clrGray,
                         DASH_FONT_SIZE, false, DASH_ZORDER_FG);

   row += DASH_ROW_HEIGHT + 2;
   Dashboard_CreateHLine(DASH_OBJ_TRAIL + "Sep", g_dashBaseX, row, DASH_PANEL_WIDTH, clrDarkGray);
}

void Dashboard_UpdateTrailingTracker()
{
   int handedOverCount = 0;
   string info = "";

   for(int i = 0; i < g_basketCount; i++)
     {
      if(!g_baskets[i].isValid || !g_trailIsHandedOver[i])
         continue;
      handedOverCount++;

      double currentPrice = (g_baskets[i].direction == 0) ?
                            SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentPnL = (g_baskets[i].direction == 0) ?
                          ((currentPrice - g_virtualTrail[i].peakPrice) * g_baskets[i].totalVolume * 100.0) :
                          ((g_virtualTrail[i].peakPrice - currentPrice) * g_baskets[i].totalVolume * 100.0);

      if(info != "") info += " | ";
      info += "#" + IntegerToString((int)g_baskets[i].basketId) +
              " Pk:" + DoubleToString(g_virtualTrail[i].peakPrice, 2) +
              " St:" + DoubleToString(g_virtualTrail[i].stopLevel, 2) +
              " Trail:" + DoubleToString(g_trailCurrentDist[i], 0) + "pts" +
              " P&L:$" + DoubleToString(currentPnL, 2);
     }

   if(handedOverCount == 0)
      info = "No active trailing baskets";

   ObjectSetString(0, DASH_OBJ_TRAIL + "Info", OBJPROP_TEXT, info);
}

//+------------------------------------------------------------------+
//| SECTION 3: PERFORMANCE METRICS                                     |
//+------------------------------------------------------------------+

void Dashboard_CreatePerformanceMetrics()
{
   int left = g_dashBaseX - DASH_MARGIN_LEFT;   // 310
   int row = g_dashBaseY + 180;

   Dashboard_CreateLabel(DASH_OBJ_PERF + "Header", left, row,
                         "[STATS] PERFORMANCE", clrLightBlue,
                         DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_PERF + "WinRate", left, row,
                         "Win Rate: 0.0%", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_PERF + "Stats", left - 125, row,
                         "a:0 b:0", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_PERF + "Spread", left, row,
                         "Spread: -- / 100", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_PERF + "ATR", left - 135, row,
                         "ATR: --", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);

   row += DASH_ROW_HEIGHT + 2;
   Dashboard_CreateHLine(DASH_OBJ_PERF + "Sep", g_dashBaseX, row, DASH_PANEL_WIDTH, clrDarkGray);
}

void Dashboard_UpdatePerformanceMetrics()
{
   double winRate = 0;
   if(g_tradeStats.totalTrades > 0)
      winRate = ((double)g_tradeStats.wins / g_tradeStats.totalTrades) * 100.0;

   ObjectSetString(0, DASH_OBJ_PERF + "WinRate", OBJPROP_TEXT,
                   "Win Rate: " + DoubleToString(winRate, 1) + "%");

   ObjectSetString(0, DASH_OBJ_PERF + "Stats", OBJPROP_TEXT,
                   "a:" + IntegerToString((int)g_tradeStats.alpha) +
                   " b:" + IntegerToString((int)g_tradeStats.beta));

   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   ObjectSetString(0, DASH_OBJ_PERF + "Spread", OBJPROP_TEXT,
                   "Spread: " + IntegerToString((int)currentSpread) + " / 100");

   ObjectSetString(0, DASH_OBJ_PERF + "ATR", OBJPROP_TEXT,
                   "ATR: " + DoubleToString(g_market.atr14, 1));
}

//+------------------------------------------------------------------+
//| SECTION 4: TRADE CONTROLS                                          |
//+------------------------------------------------------------------+

void Dashboard_CreateTradeControls()
{
   int left = g_dashBaseX - DASH_MARGIN_LEFT;   // 310
   int row = g_dashBaseY + 225;

   Dashboard_CreateLabel(DASH_OBJ_TRADE + "Header", left, row,
                         "[TRADE] MANUAL CONTROLS", clrLightGreen,
                         DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   //--- BUY / Lot / SELL - horizontal alignment within 320px panel
   Dashboard_CreateButton(DASH_OBJ_TRADE + "BuyBtn", left, row, 60, 24,
                          " BUY ", clrForestGreen, clrWhite, DASH_ZORDER_FG);
   Dashboard_CreateEdit(DASH_OBJ_TRADE + "LotInput", left - 72, row, 60, 24,
                        "0.01", DASH_ZORDER_FG);
   Dashboard_CreateButton(DASH_OBJ_TRADE + "SellBtn", left - 144, row, 60, 24,
                          " SELL ", clrCrimson, clrWhite, DASH_ZORDER_FG);

   row += DASH_ROW_HEIGHT + 6;
   Dashboard_CreateLabel(DASH_OBJ_TRADE + "Info", left, row,
                         "Lot: 0.01 | Auto-Adopt: ON", clrGray,
                         DASH_FONT_SIZE, false, DASH_ZORDER_FG);

   row += DASH_ROW_HEIGHT + 2;
   Dashboard_CreateHLine(DASH_OBJ_TRADE + "Sep", g_dashBaseX, row, DASH_PANEL_WIDTH, clrDarkGray);
}

void Dashboard_UpdateTradeControls()
{
   string lotText = ObjectGetString(0, DASH_OBJ_TRADE + "LotInput", OBJPROP_TEXT);
   string info = "Lot: " + (lotText != "" ? lotText : "0.01") + " | Auto-Adopt: ON";
   ObjectSetString(0, DASH_OBJ_TRADE + "Info", OBJPROP_TEXT, info);
}

//+------------------------------------------------------------------+
//| SECTION 5: EMERGENCY CONTROLS                                      |
//+------------------------------------------------------------------+

void Dashboard_CreateEmergencyControls()
{
   int left = g_dashBaseX - DASH_MARGIN_LEFT;   // 310
   int row = g_dashBaseY + 280;

   Dashboard_CreateLabel(DASH_OBJ_EMERG + "Header", left, row,
                         "[EMERG] EMERGENCY CONTROLS", clrRed,
                         DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   //--- Full-width button: spans from left edge (310) to right margin (30)
   Dashboard_CreateButton(DASH_OBJ_EMERG + "CloseAllBtn", left, row, 280, 26,
                          "CLOSE ALL BASKETS", clrDarkRed, clrWhite, DASH_ZORDER_FG);
}

void Dashboard_UpdateEmergencyControls()
{
   if(g_dashCloseAllArmed)
     {
      datetime now = TimeCurrent();
      if(now - g_dashCloseAllArmTime > DASH_CLOSE_CONFIRM_WINDOW)
        {
         g_dashCloseAllArmed = false;
         Dashboard_SaveCloseAllState();
         ObjectSetString(0, DASH_OBJ_EMERG + "CloseAllBtn", OBJPROP_TEXT,
                         "CLOSE ALL BASKETS");
         ObjectSetInteger(0, DASH_OBJ_EMERG + "CloseAllBtn", OBJPROP_BGCOLOR, clrDarkRed);
        }
      else
        {
         int remaining = DASH_CLOSE_CONFIRM_WINDOW - (int)(now - g_dashCloseAllArmTime);
         ObjectSetString(0, DASH_OBJ_EMERG + "CloseAllBtn", OBJPROP_TEXT,
                         "CLICK AGAIN TO CONFIRM (" + IntegerToString(remaining) + "s)");
         ObjectSetInteger(0, DASH_OBJ_EMERG + "CloseAllBtn", OBJPROP_BGCOLOR, clrRed);
        }
     }
}

//+------------------------------------------------------------------+
//| SECTION 6: SYSTEM STATUS                                           |
//+------------------------------------------------------------------+

void Dashboard_CreateSystemStatus()
{
   int left = g_dashBaseX - DASH_MARGIN_LEFT;   // 310
   int row = g_dashBaseY + 330;

   Dashboard_CreateLabel(DASH_OBJ_STATUS + "Header", left, row,
                         "[SYS] SYSTEM STATUS", clrLightGray,
                         DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_STATUS + "Baskets", left, row,
                         "Active: 0 baskets", clrWhite, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
   Dashboard_CreateLabel(DASH_OBJ_STATUS + "Dot", left - 135, row,
                         "o", clrLimeGreen, DASH_FONT_SIZE_BOLD, true, DASH_ZORDER_FG);
   row += DASH_ROW_HEIGHT;

   Dashboard_CreateLabel(DASH_OBJ_STATUS + "Msg", left, row,
                         "Ready", clrLightGray, DASH_FONT_SIZE, false, DASH_ZORDER_FG);
}

void Dashboard_UpdateSystemStatus()
{
   int activeCount = 0;
   for(int i = 0; i < g_basketCount; i++)
      if(g_baskets[i].isValid && g_baskets[i].status == BASKET_ACTIVE)
         activeCount++;

   ObjectSetString(0, DASH_OBJ_STATUS + "Baskets", OBJPROP_TEXT,
                   "Active: " + IntegerToString(activeCount) + " baskets");

   if(g_dashStatusMsg == "" || g_dashStatusMsg == "Ready")
     {
      string msg = "Trading Active";
      color msgColor = clrLimeGreen;

      if(g_negativeBalanceDetected)
        { msg = "NEGATIVE BALANCE - HALTED"; msgColor = clrRed; }
      else if(g_adoptionHalted)
        { msg = "Adoption Halted (Heat>=" + DoubleToString(Inp_MaxTotalHeat, 0) + "%)"; msgColor = clrOrange; }
      else if(g_spreadHalted)
        { msg = "Spread Halted"; msgColor = clrRed; }
      else if(g_marginHalted)
        { msg = "Margin Halted"; msgColor = clrRed; }
      else if(g_heatWarningActive)
        { msg = "Heat WARNING (" + DoubleToString(g_totalHeat, 1) + "%)"; msgColor = clrOrange; }

      ObjectSetString(0, DASH_OBJ_STATUS + "Msg", OBJPROP_TEXT, msg);
      ObjectSetInteger(0, DASH_OBJ_STATUS + "Msg", OBJPROP_COLOR, msgColor);
      g_dashStatusColor = msgColor;
     }
   else
     {
      ObjectSetString(0, DASH_OBJ_STATUS + "Msg", OBJPROP_TEXT, g_dashStatusMsg);
      ObjectSetInteger(0, DASH_OBJ_STATUS + "Msg", OBJPROP_COLOR, g_dashStatusColor);
     }

   color dotColor = (g_dashStatusColor == clrLimeGreen || g_dashStatusColor == clrLightGreen) ?
                    clrLimeGreen : clrRed;
   ObjectSetInteger(0, DASH_OBJ_STATUS + "Dot", OBJPROP_COLOR, dotColor);
}

//+------------------------------------------------------------------+
//| FULL DASHBOARD UPDATE (1-second cycle)                             |
//+------------------------------------------------------------------+

void Dashboard_FullUpdate()
{
   Dashboard_UpdateHeatMonitor();
   Dashboard_UpdateTrailingTracker();
   Dashboard_UpdatePerformanceMetrics();
   Dashboard_UpdateTradeControls();
   Dashboard_UpdateEmergencyControls();
   Dashboard_UpdateSystemStatus();
}

//+------------------------------------------------------------------+
//| CLOSE-ALL PERSISTENCE                                              |
//+------------------------------------------------------------------+

void Dashboard_LoadCloseAllState()
{
   string armedName = GV_DASH_CLOSE_ALL_ARMED;
   string timeName = GV_DASH_CLOSE_ALL_ARM_TIME;

   if(GlobalVariableCheck(armedName))
     {
      g_dashCloseAllArmed = (GlobalVariableGet(armedName) != 0.0);
      g_dashCloseAllArmTime = (datetime)GlobalVariableGet(timeName);

      if(g_dashCloseAllArmed &&
         TimeCurrent() - g_dashCloseAllArmTime > DASH_CLOSE_CONFIRM_WINDOW)
        {
         g_dashCloseAllArmed = false;
         GlobalVariableSet(armedName, 0);
         GlobalVariableSet(timeName, 0);
        }
     }
}

void Dashboard_SaveCloseAllState()
{
   GlobalVariableSet(GV_DASH_CLOSE_ALL_ARMED, g_dashCloseAllArmed ? 1.0 : 0.0);
   GlobalVariableSet(GV_DASH_CLOSE_ALL_ARM_TIME, (double)g_dashCloseAllArmTime);
}

void Dashboard_ClearCloseAllState()
{
   g_dashCloseAllArmed = false;
   g_dashCloseAllArmTime = 0;
   GlobalVariableSet(GV_DASH_CLOSE_ALL_ARMED, 0);
   GlobalVariableSet(GV_DASH_CLOSE_ALL_ARM_TIME, 0);
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                                |
//+------------------------------------------------------------------+

void Dashboard_OnChartEvent(const int id, const long &lparam,
                             const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == DASH_OBJ_TRADE + "BuyBtn")
        {
         Dashboard_OnBuyClick();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == DASH_OBJ_TRADE + "SellBtn")
        {
         Dashboard_OnSellClick();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == DASH_OBJ_EMERG + "CloseAllBtn")
        {
         Dashboard_OnCloseAllClick();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
     }
}

//+------------------------------------------------------------------+
//| FILLING MODE HELPER                                                |
//+------------------------------------------------------------------+

ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   long fillingMask = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMask & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fillingMask & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   Print("[Dashboard] WARNING: No filling mode detected for ", _Symbol,
         " (mask=", fillingMask, "). Defaulting to FOK.");
   return ORDER_FILLING_FOK;
}

//+------------------------------------------------------------------+
//| BUTTON CLICK HANDLERS                                              |
//+------------------------------------------------------------------+
//| FIX v2.1: After SSoT_CreateBasket(), immediately call             |
//|           SSoT_UpdateDashboard() + ChartRedraw() for <500ms sync  |
//+------------------------------------------------------------------+

void Dashboard_OnBuyClick()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lotSize = 0.01;
   string lotText = ObjectGetString(0, DASH_OBJ_TRADE + "LotInput", OBJPROP_TEXT);
   if(lotText != "") lotSize = StringToDouble(lotText);
   if(lotSize <= 0) lotSize = 0.01;
   lotSize = Lot_Normalize(lotSize);

   ENUM_ORDER_TYPE_FILLING fillMode = GetFillingMode();

   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = ask;
   request.deviation = 10;
   request.magic = 0;
   request.comment = "MANUAL_BUY";
   request.type_filling = fillMode;

   if(OrderSend(request, result))
     {
      Print("[Dashboard] BUY executed: Ticket=", result.order,
            " Lot=", lotSize, " Price=", result.price,
            " Filling=", EnumToString(fillMode));

      g_dashStatusMsg = "BUY " + DoubleToString(lotSize, 2) + " Executed";
      g_dashStatusColor = clrLightGreen;

      Sleep(100);
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetDouble(POSITION_VOLUME) == lotSize &&
            (int)PositionGetInteger(POSITION_TYPE) == 0)
           {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            int basketIdx = SSoT_CreateBasket(ticket, openPrice, lotSize, 0, 0);
            if(basketIdx >= 0)
              {
               Print("[Dashboard] Position ", ticket, " immediately adopted");
               //--- FIX: Immediate sync to prevent 60s cache-wipe delay
               SSoT_UpdateDashboard();
               Dashboard_FullUpdate();
               ChartRedraw();
              }
            break;
           }
        }
     }
   else
     {
      int err = GetLastError();
      Print("[Dashboard] BUY FAILED: Error=", err,
            " Filling=", EnumToString(fillMode),
            " Lot=", lotSize, " Price=", ask,
            " Retcode=", result.retcode);

      g_dashStatusMsg = "BUY FAILED - Error " + IntegerToString(err);
      g_dashStatusColor = clrRed;
     }
}

void Dashboard_OnSellClick()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lotSize = 0.01;
   string lotText = ObjectGetString(0, DASH_OBJ_TRADE + "LotInput", OBJPROP_TEXT);
   if(lotText != "") lotSize = StringToDouble(lotText);
   if(lotSize <= 0) lotSize = 0.01;
   lotSize = Lot_Normalize(lotSize);

   ENUM_ORDER_TYPE_FILLING fillMode = GetFillingMode();

   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = bid;
   request.deviation = 10;
   request.magic = 0;
   request.comment = "MANUAL_SELL";
   request.type_filling = fillMode;

   if(OrderSend(request, result))
     {
      Print("[Dashboard] SELL executed: Ticket=", result.order,
            " Lot=", lotSize, " Price=", result.price,
            " Filling=", EnumToString(fillMode));

      g_dashStatusMsg = "SELL " + DoubleToString(lotSize, 2) + " Executed";
      g_dashStatusColor = clrLightGreen;

      Sleep(100);
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetDouble(POSITION_VOLUME) == lotSize &&
            (int)PositionGetInteger(POSITION_TYPE) == 1)
           {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            int basketIdx = SSoT_CreateBasket(ticket, openPrice, lotSize, 1, 0);
            if(basketIdx >= 0)
              {
               Print("[Dashboard] Position ", ticket, " immediately adopted");
               //--- FIX: Immediate sync to prevent 60s cache-wipe delay
               SSoT_UpdateDashboard();
               Dashboard_FullUpdate();
               ChartRedraw();
              }
            break;
           }
        }
     }
   else
     {
      int err = GetLastError();
      Print("[Dashboard] SELL FAILED: Error=", err,
            " Filling=", EnumToString(fillMode),
            " Lot=", lotSize, " Price=", bid,
            " Retcode=", result.retcode);

      g_dashStatusMsg = "SELL FAILED - Error " + IntegerToString(err);
      g_dashStatusColor = clrRed;
     }
}

void Dashboard_OnCloseAllClick()
{
   if(!g_dashCloseAllArmed)
     {
      g_dashCloseAllArmed = true;
      g_dashCloseAllArmTime = TimeCurrent();
      Dashboard_SaveCloseAllState();
      Print("[Dashboard] CLOSE ALL armed - click again within 5s to confirm");
      g_dashStatusMsg = "CLOSE ALL armed - confirm within 5s";
      g_dashStatusColor = clrYellow;
     }
   else
     {
      if(TimeCurrent() - g_dashCloseAllArmTime > DASH_CLOSE_CONFIRM_WINDOW)
        {
         Dashboard_ClearCloseAllState();
         g_dashStatusMsg = "CLOSE ALL expired - not confirmed";
         g_dashStatusColor = clrGray;
         return;
        }

      Dashboard_ClearCloseAllState();

      g_dashStatusMsg = "CLOSING ALL BASKETS - Please wait...";
      g_dashStatusColor = clrOrange;
      Print("[Dashboard] CLOSE ALL started by user");

      int closedCount = 0;
      for(int i = g_basketCount - 1; i >= 0; i--)
        {
         if(!g_baskets[i].isValid)
            continue;
         if(g_baskets[i].status != BASKET_ACTIVE)
            continue;

         SSoT_UpdateBasketStatus(i, BASKET_CLOSING);

         for(int j = g_baskets[i].levelCount - 1; j >= 0; j--)
           {
            ulong ticket = g_baskets[i].levels[j].ticket;
            if(ticket > 0)
               FastStrike_ClosePosition(ticket);
           }

         SSoT_CloseBasket(i);
         closedCount++;
        }

      g_dashStatusMsg = "CLOSE ALL COMPLETE: " + IntegerToString(closedCount) + " baskets";
      g_dashStatusColor = clrGold;

      Print("[Dashboard] CLOSE ALL executed: ", closedCount, " baskets closed");
      g_dashStatusMsg = "CLOSE ALL: " + IntegerToString(closedCount) + " baskets closed";
      g_dashStatusColor = clrGold;
     }
}

//+------------------------------------------------------------------+
//| HELPER: Create Chart Objects                                       |
//+------------------------------------------------------------------+

void Dashboard_CreateRectangle(const string name, int x, int y, int w, int h,
                                color bgColor, int borderWidth, color borderColor, int zOrder)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, zOrder);
}

void Dashboard_CreateLabel(const string name, int x, int y, string text,
                            color clr, int fontSize, bool isBold, int zOrder)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, isBold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, zOrder);
}

void Dashboard_CreateButton(const string name, int x, int y, int w, int h,
                             string text, color bgColor, color textColor, int zOrder)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, DASH_FONT_SIZE_BOLD);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, zOrder);
}

void Dashboard_CreateEdit(const string name, int x, int y, int w, int h, string text, int zOrder)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clrDarkSlateGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, DASH_FONT_SIZE);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_READONLY, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, zOrder);
}

void Dashboard_CreateHLine(const string name, int x, int y, int w, color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, DASH_ZORDER_FG);
}

//+------------------------------------------------------------------+
