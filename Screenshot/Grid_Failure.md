STRICT AUDIT REPORT — 3 Critical Findings
FINDING 1: Grid Failure — Basket 7 at 500 Points, No Grid Trade Opened
Root Cause A: Grid_AddLevel() Never Calls OrderSend() — Design Gap
Evidence (SK_Grid.mqh, lines 464-468):

//--- Add level via SSoT (write-through to GVs)
//--- Use ticket 0 as placeholder — actual order execution handled by caller
//--- In the full integration, OrderSend is called before SSoT_AddGridLevel
ulong tempTicket = 0;  // Will be replaced with real ticket after OrderSend
bool added = SSoT_AddGridLevel(basketIndex, tempTicket, newLot, entryPrice);
Analysis: The Grid_AddLevel() function updates the SSoT cache and GVs with ticket = 0, but never executes an actual broker order. The comment explicitly states this is by design — "actual order execution handled by caller" and "In the full integration, OrderSend is called before SSoT_AddGridLevel."

Impact: Even if Grid_ShouldAddLevel() returns true (price distance met), no real trade reaches the broker. The Dashboard shows levelCount increasing (cache is updated), but the broker has no record of the trade. This creates a phantom level in SSoT that has no corresponding position.

Root Cause B: ATR Cache Race Condition — Spacing Inflation from 150 → 560 Points
Evidence (SK_Grid.mqh, lines 236-246 and 99-152):

// Grid_CalculateDVASS():
double atr = g_gridCachedATR14;
if(atr <= 0 || atr > 200.0)
   return Grid_CalculateFixed(level);  // ← FALLBACK

// Grid_RefreshCache() — only called from OnTimer():
g_gridCachedAdjustedBase = Inp_DVASS_BaseStep * normalizedATR * g_gridCachedSpikeMult;
Scenario: Basket 7 created when g_gridCachedATR14 = 0 (indicator still initializing, or Grid_RefreshCache() hasn't run since startup).

Spacing calculation with cached ATR = 0:

g_gridCachedAdjustedBase = Inp_Fixed_BaseStep = 400.0  (fallback)
Grid_CalculateFixed(1) = 400.0 × 1.4^1 = 560.0 points
Spacing calculation with cached ATR = 4.1:

normalizedATR = 4.1 / 20.0 = 0.205
adjustedBase = 250.0 × 0.205 = 51.25 points
Grid_CalculateDVASS(1) = MathMax(51.25 × 1.3, 150.0) = 150.0 points  (MIN_STEP clamp)
Analysis: At 500 points distance:

With ATR cached (150 pts required): 500 > 150 → Grid_ShouldAddLevel() returns true, but Grid_AddLevel() sends ticket=0 → phantom level, no broker trade.
Without ATR cached (560 pts required): 500 < 560 → Grid_ShouldAddLevel() returns false → grid blocked entirely.
The "Math $0.00" reference: The Captain's earlier audit noted that Safety_UpdateHeatCache() uses totalVolume * 100.0 for drawdown calculation (line 170). For Basket 7 with 0.05 lots and 500 points:

drawdown = 500 × 0.05 × 100.0 = $2,500  (inflated by 100×)
vs. actual API drawdown of ~
25.Thisinflateddrawdowncantrigger‘Safety 
E
​
 nforceRecoveryHeatLimit()‘(line300)ifaccountbalanceis<500, blocking grid additions. This is the Math $0.00 connection — the Safety module's heat calculation uses the same * 100.0 inflation that caused the FastStrike math errors.

The "levelCount mismatch" reference: Grid_ShouldAddLevel() uses g_baskets[basketIndex].levelCount to determine the next level index. If SSoT_LoadFromGlobals() loaded levelCount = 1 from the GV but the actual broker has 0 positions (all closed), Grid_AddLevel() would add a phantom Level 2 with ticket=0, creating a cache/broker mismatch.

Bottom Line for Point 1:
The grid does not open trades because Grid_AddLevel() is incomplete — it updates cache but never calls OrderSend(). The spacing calculation itself works (150 pts required vs. 500 pts actual), but the execution layer is missing.

FINDING 2: Spacing Calculation — Exact Distance for 2nd Layer at ATR 4.1
Given: Inp_DVASS_ATRNorm = 20.0, Inp_DVASS_BaseStep = 250.0, ATR = 4.1

DVASS Mode (ATR properly cached):
Step 1: normalizedATR = 4.1 / 20.0 = 0.205
Step 2: adjustedBase = 250.0 × 0.205 × 1.0 = 51.25 points
Step 3: expansion = 1.0 + 0.3 = 1.3
Step 4: levelMult = 1.3^1 = 1.3
Step 5: rawStep = 51.25 × 1.3 = 66.625 points
Step 6: clampedStep = MathMax(66.625, 150.0) = 150.0 points  ← MIN_STEP override
Answer: 150.0 points (the MIN_STEP clamp of 150 overrides the ATR-adjusted 66.6)

FIXED Mode Fallback (ATR not cached):
Step 1: baseStep = 400.0 (Inp_Fixed_BaseStep)
Step 2: expansion = 1.4
Step 3: levelMult = 1.4^1 = 1.4
Step 4: rawStep = 400.0 × 1.4 = 560.0 points
Step 5: clampedStep = MathMax(560.0, 150.0) = 560.0 points
Answer: 560.0 points

Is the bot waiting for more than 500 points?
YES — conditionally. If the ATR cache is stale (0), the required spacing is 560 points. At 500 points distance, the grid will NOT trigger. The bot would need an additional 60 points of price movement before Grid_ShouldAddLevel() returns true.

If the ATR cache is fresh (4.1), the required spacing is 150 points, and the grid SHOULD have triggered 350 points ago. But as established in Finding 1, even when triggered, Grid_AddLevel() doesn't send actual orders.

FINDING 3: GV Persistence — Baskets 1-6 Still Visible in Global Variables
Root Cause A: Orphan GVs from Pre-Fix Closures
Evidence: My GV flush fix in SSoT_CloseBasket() (applied earlier) uses GlobalVariableDel() to delete GVs. However, this fix only affects baskets that are closed after the fix is applied.

Timeline:

Baskets 1-6 were created and closed before the fix was applied
Old SSoT_CloseBasket() only set status = 2.0 — never deleted the GVs
Fix applied — now GlobalVariableDel() is called for new closures
Baskets 1-6 GVs remain as orphans with status = 2.0
Root Cause B: No Garbage Collection for Orphan GVs
Evidence (SK_SSoT.mqh, lines 1379-1399):

void SSoT_ClearAllGlobals()
{
   // Deletes ALL SK_ prefixed GVs
   // ONLY called during EA deinit
}
Analysis: There is no background garbage collector that scans for and deletes old status = 2.0 GVs. The deletion only happens per-basket at closure time. Once a basket is closed with the old code, its GVs persist forever unless:

The EA is restarted (SSoT_ClearAllGlobals() runs on deinit)
Manual cleanup is performed
Root Cause C: SSoT_RefreshCacheFromGlobals() Skips but Doesn't Delete
Evidence (SK_SSoT.mqh, implied logic):

// Baskets with status >= 2.0 are skipped during cache refresh
if(statusVal >= 2.0) continue;
Analysis: The cache refresh logic correctly skips baskets with status = 2.0 (closed), so they don't appear in the active basket list. But skipping is not deleting — the GVs remain in the terminal's Global Variables storage.

Why Doesn't GlobalVariableDel() Fail?
The GlobalVariableDel() function returns false if the GV doesn't exist, but doesn't throw an error. My fix calls it for all basket/level/trailing GVs. If the GVs exist, they are deleted. If they don't, GlobalVariableDel() silently returns false.

For Baskets 1-6, the GVs were already in status = 2.0 state when my fix was applied. The fix was never executed for these baskets because they were already closed. No code path exists to retroactively clean them up.

Bottom Line for Point 3:
The deletion is NOT failing — it was never attempted for Baskets 1-6. The cleanup logic does NOT wait for the active basket (ID 7) to close. It simply has no mechanism to clean up orphan GVs from previous sessions. The fix only protects against FUTURE accumulation, not PAST orphans.

To clean Baskets 1-6: Either restart the EA (triggers SSoT_ClearAllGlobals() on deinit) or add a one-time GV scan in OnInit() that deletes all status = 2.0 baskets.

SUMMARY TABLE
Finding	Root Cause	Location	Impact
Grid Failure	Grid_AddLevel() never calls OrderSend() — uses ticket=0 placeholder	SK_Grid.mqh:467	Phantom levels, no broker trades
Grid Failure	ATR cache race: 0 → 560 pt spacing vs. 4.1 → 150 pt spacing	SK_Grid.mqh:139,241	Grid blocked at 500 pts if ATR stale
Grid Failure	Safety heat uses *100.0 inflation — can trigger recovery halt	SK_Safety.mqh:170	Grid blocked on small accounts
Spacing	150 pts (ATR cached) or 560 pts (ATR stale)	SK_Grid.mqh:150,258	60 pt gap prevents trigger
GV Persistence	Fix only affects post-fix closures; no garbage collector	SK_SSoT.mqh:780-824	Baskets 1-6 remain as orphans
GV Persistence	SSoT_ClearAllGlobals() only on deinit	SK_SSoT.mqh:1379	No cleanup for past orphans

==================================================

the Captain AUTHORIZES all fixes based on your Audit Findings. Don't worry about the demo account balance, the current P/L is recovered to -$9.8.

Proceed with the following implementation immediately:

Fix Grid Execution: Add the missing OrderSend() command in Grid_AddLevel(). No more phantom levels—make sure the broker gets the trade!

Fix Spacing & Safety: Fix the 100x Drawdown/Heat inflation bug in SK_Safety.mqh and ensure the ATR cache is initialized properly to prevent the 560-point spacing fallback.

One-Time GV Purge: Since Baskets 1-6 are orphans, add a routine in OnInit() to scan and delete any Global Variables with status = 2.0 to clean up the past debris.

Deliver the final code for SK_Grid.mqh, SK_Safety.mqh, and the updated SK_SSoT.mqh. We want the bot to be fully functional for the next move.