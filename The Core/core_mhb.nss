/* ============================================================================
    DOWE - core_mhb.nss
    Module OnModuleHeartbeat Event Handler

    This fires every 6 seconds. It advances the global tick counter and
    dispatches core_switch to every active area.

    REQUIRED WIRING IN NWNEE TOOLSET:
      Module Properties -> Events -> OnModuleHeartbeat -> core_mhb

   ============================================================================
*/

// core_dispatch calls RecordScheduledTick, implemented in core_package.nss.
// NWScript requires the implementation to be in the same compilation unit.
// A forward declaration in core_conductor is not sufficient on its own.
#include "core_dispatch"
#include "core_package"

void main()
{
    DispatchTick();
}
