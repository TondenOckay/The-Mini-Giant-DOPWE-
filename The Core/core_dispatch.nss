/* ============================================================================
    DOWE - core_dispatch.nss
    Module Heartbeat - Area Dispatch Driver

    ============================================================================
    PURPOSE
    ============================================================================
    This script is the module OnModuleHeartbeat handler.
    It advances the global tick counter and fires core_switch on every
    currently-active area with a staggered delay to spread CPU use.

    ============================================================================
    ACTIVE AREA REGISTRY
    ============================================================================
    The active area registry is maintained by core_registry.nss.
    When a PC enters an area, RegistryAdd calls RegistryActivateArea.
    When the last PC leaves, RegistryRemoveBySlot calls RegistryDeactivateArea.
    Both functions write directly to module object local variables.

    This dispatch script reads those variables. It does not scan ALL areas.
    On a server with 200 areas and 15 occupied, 185 area scans are avoided
    every single heartbeat.

    Module object keys used (written by core_registry, read here):
      MG_ACTIVE_CNT         int    - number of currently active areas
      MG_ACTIVE_[N]         object - reference to Nth active area (1-indexed)

    ============================================================================
    STAGGER LOGIC
    ============================================================================
    All active areas share a 4.5-second window within the 6-second heartbeat.
    With 15 active areas that is 0.3 seconds per area.
    With 1 active area that is 0.5 seconds (capped at 0.5 for safety).
    Minimum stagger is 0.1 seconds to prevent all areas firing simultaneously.

   ============================================================================
*/

#include "core_conductor"

// RecordScheduledTick is implemented in core_package.nss.
// It is forward-declared in core_conductor.nss so core_dispatch can call it
// without including core_package (which would cause duplicate function errors
// in any script that includes both core_dispatch and core_package).

// ============================================================================
// DISPATCH BOOT
// Call once from module OnModuleLoad after all Boot() calls.
// ============================================================================

void DispatchBoot()
{
    object oMod = GetModule();
    if (GetLocalInt(oMod, "MG_DISPATCH_BOOTED")) return;
    SetLocalInt(oMod, "MG_DISPATCH_BOOTED", 1);

    // Active area count starts at zero.
    // Areas self-register via RegistryActivateArea when a PC enters.
    SetLocalInt(oMod, "MG_ACTIVE_CNT", 0);

    WriteTimestampedLogEntry("[DISPATCH] Boot complete.");
}

// ============================================================================
// DISPATCH TICK
// Called from the module OnModuleHeartbeat event script.
// ============================================================================

void DispatchTick()
{
    object oMod = GetModule();

    // 1. Advance global tick counter
    int nTick = GetLocalInt(oMod, MG_TICK) + 1;
    if (nTick > MG_TICK_RESET) nTick = 1;
    SetLocalInt(oMod, MG_TICK,      nTick);
    SetLocalInt(oMod, MG_LAST_TICK, nTick);

    // 2. Record scheduled tick for load drift measurement
    RecordScheduledTick(oMod, nTick);

    // 3. Read active area count - no scan
    int nActive = GetLocalInt(oMod, "MG_ACTIVE_CNT");
    if (nActive == 0) return;

    // 4. Spread core_switch across a 4.5-second window
    float fInc = 4.5 / IntToFloat(nActive);
    if (fInc < 0.1) fInc = 0.1;
    if (fInc > 0.5) fInc = 0.5;

    float fStag = 0.0;
    int   i;
    for (i = 1; i <= nActive; i++)
    {
        object oArea = GetLocalObject(oMod, "MG_ACTIVE_" + IntToString(i));
        if (GetIsObjectValid(oArea))
        {
            DelayCommand(fStag, ExecuteScript("core_switch", oArea));
            fStag += fInc;
        }
    }

    // BUG FIX (Session 11): Master MG_DEBUG gate added.
    // Previously MG_DEBUG_DISP fired without checking the master toggle.
    if (GetLocalInt(GetModule(), MG_DEBUG) && GetLocalInt(GetModule(), MG_DEBUG_DISP))
        SendMessageToAllDMs("[DISPATCH] T=" + IntToString(nTick) +
                            " Active=" + IntToString(nActive));
}
