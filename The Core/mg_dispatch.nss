/* ============================================================================
    DOWE v2.2 - mg_dispatch.nss
    Module Heartbeat Dispatcher
   ============================================================================
*/

#include "mg_const"

void main()
{
    object oModule = GetModule();

    // Increment tick
    int nTick = GetMGTick() + 1;
    if (nTick >= MG_TICK_MAX) nTick = 0;  // FIXED: Now defined!
    SetLocalInt(oModule, MG_TICK, nTick);

    // Count active areas
    object oArea = GetFirstArea();
    int nActive = 0;

    while (GetIsObjectValid(oArea))
    {
        int nPCs = GetLocalInt(oArea, M_PC_COUNT);  // FIXED: Now defined!
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
