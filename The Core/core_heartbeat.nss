/* ============================================================================
    DOWE - core_heartbeat.nss
    Area Heartbeat Failsafe

    Assign to the area OnHeartbeat event for every area in the module.

    This fires on each area's native heartbeat (every 6 seconds by default).
    If the module-level dispatch has stalled (e.g. server overload prevented
    the module heartbeat from firing for MG_FAILSAFE_BEATS beats), this
    triggers an emergency core_switch execution for areas that have players.

    This script requires no configuration. All tuning is in core_conductor.nss.
   ============================================================================
*/

#include "core_registry"
#include "core_conductor"

void main()
{
    object oArea = OBJECT_SELF;
    object oMod  = GetModule();

    int nCur  = GetLocalInt(GetModule(), MG_TICK);
    int nLast = GetLocalInt(oMod, MG_LAST_TICK);

    // If the dispatch has missed too many beats and this area has players,
    // fire an emergency core_switch to keep the area alive.
    if ((nCur - nLast) > MG_FAILSAFE_BEATS)
    {
        if (RegistryPCCount(oArea) > 0)
        {
            ExecuteScript("core_switch", oArea);
            SendMessageToAllDMs("[FAILSAFE] Emergency switch for: " +
                                GetTag(oArea));
        }
    }
}
