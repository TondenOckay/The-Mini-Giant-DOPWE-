/* ============================================================================
    DOWE v2.2 PROPER FIX - mg_dispatch.nss
    
    FIXED: Line 6 - Added proper type declaration
   ============================================================================
*/

#include "mg_const"

void main()
{
    // Increment tick
    int nTick = GetMGTick() + 1;
    if (nTick >= MG_TICK_MAX) nTick = 0;
    SetLocalInt(GetModule(), MG_TICK, nTick);
    
    // Count active areas
    object oModule = GetModule();
    object oArea = GetFirstArea();
    int nActive = 0;
    
    while (GetIsObjectValid(oArea))
    {
        int nPCs = GetLocalInt(oArea, M_PC_COUNT);  // FIXED: Was missing M_ prefix
        if (nPCs > 0)
        {
            nActive++;
        }
        oArea = GetNextArea();
    }
    
    // Calculate stagger
    float fStagger = (nActive > 0) ? (6.0 / IntToFloat(nActive)) : 0.25;
    float fDelay = 0.0;
    
    // Dispatch to active areas
    oArea = GetFirstArea();
    while (GetIsObjectValid(oArea))
    {
        int nPCs = GetLocalInt(oArea, M_PC_COUNT);
        if (nPCs > 0)
        {
            DelayCommand(fDelay, ExecuteScript("mg_switch", oArea));
            fDelay += fStagger;
        }
        oArea = GetNextArea();
    }
}
