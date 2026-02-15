/* ============================================================================
    DOWE v2.2 - mg_switch.nss (ENHANCED FOR AI GPS)
    Area Switchboard with AI GPS Integration
   ============================================================================
*/

#include "mg_const"
#include "mg_manifest"

void main()
{
    object oArea = OBJECT_SELF;
    int nTick = GetMGTick();
    
    // Phase 1: Cleanup (instant)
    ExecuteScript("mg_cleanup", oArea);
    
    // Manifest maintenance
    if (nTick % 10 == 0)
        ManifestClean(oArea);
    
    if (nTick % 500 == 0)
        ManifestCheck(oArea, TRUE);
    
    if (GetMGDebugSub(MG_DEBUG_MAN) && nTick % 100 == 0)
        ManifestCheck(oArea, FALSE);
    
    // Phase 2: NPCs
    DelayCommand(1.5, ExecuteScript("mg_livenpc", oArea));
    
    // Phase 2.5: AI GPS (NEW - Eye in the Sky!)
    DelayCommand(2.0, ExecuteScript("mg_ai_gps", oArea));
    
    // Phase 3: Encounters
    DelayCommand(3.0, ExecuteScript("mg_enc", oArea));
}
