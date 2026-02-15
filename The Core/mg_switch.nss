/* ============================================================================
    DOWE v2.2 FIXED - mg_switch.nss
    Area Switchboard - Orchestrates all subsystems with proper phasing

    FIXES APPLIED:
    - Fixed DelayCommand syntax for ManifestClean/ManifestCheck
    - Uses wrapper scripts for delayed manifest operations
    - Improved comments
   ============================================================================
*/

#include "mg_const"
#include "mg_manifest"

void main()
{
    object oArea = OBJECT_SELF;
    int nTick = GetMGTick();

    // ========================================================================
    // PHASE 1: CLEANUP (Instant - 0.0s)
    // ========================================================================
    ExecuteScript("mg_cleanup", oArea);

    // ========================================================================
    // PERIODIC MAINTENANCE
    // ========================================================================

    // Ghost cleanup every 10 beats (removes invalid object references)
    if (nTick % 10 == 0)
    {
        ManifestClean(oArea);
    }

    // Light integrity check every 500 beats
    if (nTick % 500 == 0)
    {
        ManifestCheck(oArea, TRUE);
    }

    // Full integrity check every 100 beats (debug only)
    if (GetMGDebugSub(MG_DEBUG_MAN) && nTick % 100 == 0)
    {
        ManifestCheck(oArea, FALSE);
    }

    // ========================================================================
    // PHASE 2: NPCs & MAINTENANCE (Delayed 1.5s)
    // ========================================================================
    DelayCommand(MG_PHASE2_DELAY, ExecuteScript("mg_livenpc", oArea));

    // ========================================================================
    // PHASE 3: ENCOUNTERS (Delayed 3.0s)
    // ========================================================================
    DelayCommand(MG_PHASE3_DELAY, ExecuteScript("mg_enc", oArea));
}
