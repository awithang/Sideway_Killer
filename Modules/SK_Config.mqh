//+------------------------------------------------------------------+
//|                                              SK_Config.mqh       |
//|                                    SIDEWAY KILLER - Phase 1      |
//|                                     Architecture: KIMI-K2        |
//+------------------------------------------------------------------+
#property copyright "SIDEWAY KILLER Project"
#property strict

//+------------------------------------------------------------------+
//| SYSTEM CONSTANTS                                                   |
//+------------------------------------------------------------------+
#define SK_VERSION        "1.0.0"
#define SK_SCHEMA_VERSION 1
#define SK_MAX_BASKETS    20       // Maximum concurrent baskets
#define SK_MAX_LEVELS     7        // Hard limit per basket (config 3-15)
#define SK_GV_PREFIX      "SK_"    // Global Variable namespace prefix

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                       |
//+------------------------------------------------------------------+

//--- Grid Spacing Modes
enum ENUM_GRID_MODE
{
   GRID_FIXED,       // Constant spacing (simple, predictable)
   GRID_DVASS,       // Dynamic volatility-adjusted (DEFAULT)
   GRID_HYBRID       // Regime-based adaptive
};

//--- Lot Multiplier Modes
enum ENUM_LOT_MODE
{
   LOT_FIXED,         // Constant multiplier (DEFAULT)
   LOT_BAYESIAN,      // Adaptive Bayesian Kelly
   LOT_HYBRID         // Blended approach
};

//--- Adoption Modes
enum ENUM_ADOPT_MODE
{
   ADOPT_AGGRESSIVE,   // Base criteria only, 30s min age
   ADOPT_SMART,        // Adaptive filters, 60s min age (DEFAULT)
   ADOPT_CONSERVATIVE, // Strict filters, 90s min age
   ADOPT_MANUAL        // Force list only
};

//--- Fast-Strike Modes
enum ENUM_FASTSTRIKE_MODE
{
   FAST_LAYER1,        // Aggressive math only
   FAST_TWO_LAYER,     // Layer 1 + Layer 2 (DEFAULT)
   FAST_THREE_LAYER    // + API verification
};

//--- Emergency Stop Modes
enum ENUM_EMERGENCY_MODE
{
   EMERGENCY_OFF,      // Never use emergency stops
   EMERGENCY_AUTO,     // Automatic (DEFAULT)
   EMERGENCY_MANUAL    // User control only
};

//--- Basket Status
enum ENUM_BASKET_STATUS
{
   BASKET_ACTIVE = 0,
   BASKET_CLOSING = 1,
   BASKET_CLOSED = 2
};

//--- Protection Levels (for checkpoint frequency)
enum ENUM_PROTECTION_LEVEL
{
   PROTECTION_NORMAL,
   PROTECTION_ELEVATED,
   PROTECTION_HIGH,
   PROTECTION_CRITICAL
};

//--- Volatility Regimes (HYBRID grid mode)
enum ENUM_VOL_REGIME
{
   VOL_LOW,
   VOL_NORMAL,
   VOL_HIGH,
   VOL_EXTREME
};

//+------------------------------------------------------------------+
//| DEFAULT CONFIGURATION CONSTANTS                                    |
//+------------------------------------------------------------------+

//--- Data Architecture
const int    DEF_AUTO_SAVE_INTERVAL = 30;           // Seconds

//--- Grid Spacing (DVASS Default)
const double DEF_DVASS_BASE_STEP       = 250.0;     // Points
const double DEF_DVASS_ATR_NORM        = 20.0;      // ATR divisor
const double DEF_DVASS_EXPANSION       = 0.3;       // 30%
const double DEF_DVASS_MIN_STEP        = 150.0;     // Safety floor
const double DEF_DVASS_MAX_STEP        = 1200.0;    // Activity ceiling
const int    DEF_DVASS_ATR_PERIOD      = 14;
const int    DEF_DVASS_ATR_FAST_PERIOD = 5;

//--- Grid Spacing (FIXED Mode)
const double DEF_FIXED_BASE_STEP       = 400.0;     // Points
const double DEF_FIXED_EXPANSION       = 1.4;       // Multiplier

//--- Grid Spacing (HYBRID Mode)
const double DEF_HYBRID_LOW_STEP       = 180.0;
const double DEF_HYBRID_NORMAL_STEP    = 300.0;
const double DEF_HYBRID_HIGH_STEP      = 500.0;
const double DEF_HYBRID_EXTREME_STEP   = 800.0;
const double DEF_HYBRID_LOW_ATR        = 15.0;
const double DEF_HYBRID_NORMAL_ATR     = 35.0;
const double DEF_HYBRID_HIGH_ATR       = 60.0;

//--- Lot Multiplier (FIXED Default)
const double DEF_FIXED_MULTIPLIER      = 1.5;
const double DEF_FIXED_DECAY           = 0.98;

//--- Bayesian Kelly Parameters
const double DEF_BAYESIAN_PRIOR_WR     = 0.65;
const double DEF_BAYESIAN_PRIOR_STR    = 20.0;
const double DEF_BAYESIAN_SAFETY       = 0.25;      // Quarter Kelly
const double DEF_BAYESIAN_DECAY        = 0.95;
const double DEF_BAYESIAN_MIN_MULT     = 1.1;
const double DEF_BAYESIAN_MAX_MULT     = 2.5;

//--- HYBRID Lot Parameters
const double DEF_HYBRID_KELLY_WEIGHT   = 0.5;
const int    DEF_HYBRID_MIN_TRADES     = 50;

//--- Heat Management
const double DEF_HEAT_WARNING          = 0.70;      // 70%
const double DEF_HEAT_CRITICAL         = 0.90;      // 90%
const double DEF_HEAT_REDUCTION        = 0.80;      // 20% reduction
const double DEF_HEAT_MIN_MULTIPLIER   = 1.1;
const double DEF_MAX_RECOVERY_HEAT     = 10.0;      // % of account (reasonable for recovery)
const double DEF_MAX_TOTAL_HEAT        = 15.0;      // % of account (reasonable for recovery)
const int    DEF_MAX_CONCURRENT_BASKETS = 3;

//--- Fast-Strike
const double DEF_FS_VALUE_PER_PT       = 100.0;     // $100/lot/point (XAUUSD)
const double DEF_FS_CONSERVATIVE_FAC   = 0.97;      // 3% conservative
const double DEF_FS_SPREAD_MULT        = 1.5;
const double DEF_FS_COMMISSION_PER_LOT = 7.0;       // $7 round-turn

//--- Profit Target
const double DEF_PROFIT_TARGET_USD     = 5.0;
const int    DEF_MIN_BASKET_AGE        = 60;        // Seconds

//--- Virtual Trailing
const int    DEF_VT_ACTIVATION         = 100;       // Points
const int    DEF_VT_TRAIL_DISTANCE     = 50;        // Points

//--- Checkpoint Intervals
const int    DEF_CP_INTERVAL_NORMAL    = 30;
const int    DEF_CP_INTERVAL_ELEVATED  = 10;
const int    DEF_CP_INTERVAL_HIGH      = 3;
const int    DEF_CP_INTERVAL_CRITICAL  = 1;

//--- Emergency Stop
const double DEF_EMERGENCY_HEAT_THRESH = 0.90;
const int    DEF_EMERGENCY_MAINT_HOURS = 1;
const double DEF_EMERGENCY_SPREAD_MULT = 2.5;

//--- Adoption
const int    DEF_SMART_MIN_AGE         = 60;
const double DEF_SMART_SPREAD_MULT     = 3.0;
const double DEF_SMART_VOL_THRESHOLD   = 2.0;
const int    DEF_CONS_MIN_AGE          = 90;
const double DEF_CONS_SPREAD_MULT      = 2.0;
const double DEF_CONS_VOL_THRESHOLD    = 1.5;
const int    DEF_AGGR_MIN_AGE          = 30;        // Hardcoded

//--- Breakeven Target
const double DEF_COST_BUFFER_POINTS    = 2.0;       // 2 points slippage
const double DEF_PROFIT_BUFFER_POINTS  = 5.0;       // 5 points profit

//--- Grid Cooldown
const int    DEF_GRID_COOLDOWN_SECONDS = 30;        // Min seconds between grid adds

//--- Spread Limits
const int    DEF_MAX_SPREAD_POINTS     = 100;       // Max spread before halt

//--- Margin Requirements
const double DEF_MIN_MARGIN_LEVEL      = 200.0;     // Min margin level %

//+------------------------------------------------------------------+
//| PERFORMANCE TARGETS                                                |
//+------------------------------------------------------------------+
const int    TARGET_ONTICK_MS          = 1;         // < 1ms hot path
const int    TARGET_SYNC_MS            = 50;        // < 50ms cold path
const int    TARGET_FS_LATENCY_US      = 100;       // < 0.10ms Fast-Strike

//+------------------------------------------------------------------+
//| USER INPUT PARAMETERS (configurable via EA properties)             |
//+------------------------------------------------------------------+
input string     Inp_Separator1        = "--- DATA ARCHITECTURE ---";
input int        Inp_AutoSaveInterval  = 30;              // Auto-save interval (sec)

input string     Inp_Separator2        = "--- GRID SPACING ---";
input ENUM_GRID_MODE  Inp_GridMode     = GRID_DVASS;      // Grid spacing mode

input string     Inp_Separator3        = "--- DVASS MODE ---";
input double     Inp_DVASS_BaseStep    = 250.0;           // Base step (points)
input double     Inp_DVASS_ATRNorm     = 20.0;            // ATR normalization
input double     Inp_DVASS_Expansion   = 0.3;             // Level expansion factor
input double     Inp_DVASS_MinStep     = 150.0;           // Minimum step
input double     Inp_DVASS_MaxStep     = 1200.0;          // Maximum step
input int        Inp_DVASS_ATRPeriod   = 14;              // ATR period
input bool       Inp_DVASS_UseSpikeDetect = true;         // Spike detection
input int        Inp_DVASS_ATRFastPeriod = 5;             // Fast ATR period

input string     Inp_Separator4        = "--- FIXED MODE ---";
input double     Inp_Fixed_BaseStep    = 400.0;           // Fixed base step
input double     Inp_Fixed_Expansion   = 1.4;             // Fixed expansion factor

input string     Inp_Separator5        = "--- LOT MULTIPLIER ---";
input ENUM_LOT_MODE   Inp_LotMode      = LOT_FIXED;       // Lot multiplier mode

input string     Inp_Separator6        = "--- FIXED LOT ---";
input double     Inp_Fixed_Multiplier  = 1.5;             // Fixed lot multiplier
input double     Inp_Fixed_Decay       = 0.98;            // Level decay factor

input string     Inp_Separator7        = "--- BAYESIAN KELLY ---";
input double     Inp_Bayesian_PriorWR  = 0.65;            // Prior win rate
input double     Inp_Bayesian_PriorStr = 20.0;            // Prior strength
input double     Inp_Bayesian_Safety   = 0.25;            // Safety factor (quarter Kelly)
input double     Inp_Bayesian_Decay    = 0.95;            // Level decay
input double     Inp_Bayesian_MinMult  = 1.1;             // Minimum multiplier
input double     Inp_Bayesian_MaxMult  = 2.5;             // Maximum multiplier

input string     Inp_Separator7b       = "--- HYBRID LOT ---";
input double     Inp_Hybrid_KellyWeight = 0.5;            // Kelly influence (0-1)
input int        Inp_Hybrid_MinTrades  = 50;              // Min trades before Kelly

input string     Inp_Separator8        = "--- PROFIT TARGET ---";
input double     Inp_ProfitTargetUSD   = 5.0;             // Target profit USD
input int        Inp_MinBasketAge      = 60;              // Minimum basket age (sec)
input double     Inp_CostBuffer        = 2.0;             // Cost buffer (points)
input double     Inp_ProfitBuffer      = 5.0;             // Profit buffer (points)

input string     Inp_Separator9        = "--- VIRTUAL TRAILING ---";
input int        Inp_VT_Activation     = 100;             // Activation distance (points)
input int        Inp_VT_TrailDist      = 50;              // Trail distance (points)

input string     Inp_Separator10       = "--- EMERGENCY STOPS ---";
input ENUM_EMERGENCY_MODE Inp_EmergencyMode = EMERGENCY_AUTO; // Emergency stop mode
input double     Inp_EmergencyHeatThresh = 0.90;          // Heat threshold

input string     Inp_Separator11       = "--- ADOPTION ---";
input ENUM_ADOPT_MODE   Inp_AdoptMode  = ADOPT_SMART;     // Adoption mode
input int        Inp_Smart_MinAge      = 60;              // Smart mode min age
input double     Inp_Smart_SpreadMult  = 3.0;             // Smart spread multiplier
input double     Inp_Smart_VolThresh   = 2.0;             // Smart volatility threshold

input string     Inp_Separator12       = "--- FAST-STRIKE ---";
input ENUM_FASTSTRIKE_MODE Inp_FastStrikeMode = FAST_TWO_LAYER; // Fast-strike mode

input string     Inp_Separator13       = "--- HEAT MANAGEMENT ---";
input double     Inp_MaxRecoveryHeat   = 5.0;             // Max recovery heat %
input double     Inp_MaxTotalHeat      = 10.0;            // Max total heat %
input int        Inp_MaxConcurrentBaskets = 3;            // Max baskets
input int        Inp_MaxGridLevels     = SK_MAX_LEVELS;   // Max grid levels per basket

//+------------------------------------------------------------------+
