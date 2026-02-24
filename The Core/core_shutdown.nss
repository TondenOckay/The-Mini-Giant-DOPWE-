/* ============================================================================
    DOWE - core_shutdown.nss
    Area OnExit Handler - Full Teardown When Last Player Leaves
    DOWE v2.3 | Production Standard | Final

    ASSIGN TO: Area OnExit event (all areas).

    ============================================================================
    BUGS FIXED FROM core_shutdown_COMPLETE.nss
    ============================================================================
    BUG 1 [CRITICAL]: GetMGDebug() called - this function does not exist.
      FIX: Replaced with GetLocalInt(GetModule(), MG_DEBUG)

    BUG 2 [CRITICAL]: #include "core_const" - file does not exist.
      FIX: Replaced with #include "core_conductor" (the correct name)

    BUG 3 [CRITICAL]: PackageShutdownArea(oArea) called - does not exist.
      FIX: Replaced with PackageRunShutdownScripts(oArea)

    BUG 4 [CRITICAL]: DispatchAreaDeactivate(oArea) called - not implemented.
      FIX: Replaced with RegistryDeactivateArea(oArea) which is the actual
           implementation in core_registry.nss. DispatchAreaActivate/Deactivate
           were redundant forward declarations pointing to the same logic.

    BUG 5 [MODERATE]: GetLocalInt(oMod, PKG_ROW_CNT) - PKG_ROW_CNT is not a
      compile-time const in any file. It is just a string stored on the module.
      FIX: Replaced with GetLocalInt(oMod, "PKG_ROW_CNT")

    ============================================================================
    TEARDOWN SEQUENCE
    ============================================================================
    1. Save PC state to SQL
    2. Deregister PC from registry (this decrements PC count)
    3. If PC count hits 0: schedule full teardown after 0.6s delay
    4. Full teardown:
       a. Guard - abort if a PC snuck back in during the delay
       b. Deactivate area in dispatch registry
       c. Run package shutdown scripts (packages save their state)
       d. Wipe grid data
       e. Wipe registry slots and bookkeeping
       f. Clean up switch timing vars and package pause vars
       g. Clear presence flags
       h. Delete per-area package JSON

   ============================================================================
*/

#include "core_registry"
#include "core_package"
#include "core_grid"
#include "core_conductor"
#include "core_sql_persist"

// ============================================================================
// FORWARD DECLARATION (implemented below)
// ============================================================================
void AreaTeardown(object oArea);

// ============================================================================
// CLEANUP HELPERS
// ============================================================================

// Cleans per-tick interval tracking vars written by core_switch.
void CleanSwitchVars(object oArea)
{
    // core_switch writes SW_LG, SW_LC, SW_LD, SW_LGD per area
    DeleteLocalInt(oArea, "SW_LG");
    DeleteLocalInt(oArea, "SW_LC");
    DeleteLocalInt(oArea, "SW_LD");
    DeleteLocalInt(oArea, "SW_LGD");
}

// Cleans per-package pause/timing state written to area locals.
// NOTE: As of v2.3, this state lives in the PKG_JSON_VAR blob.
// This function cleans any old-style individual locals for safety.
void CleanPackageVars(object oArea)
{
    object oMod  = GetModule();
    // FIX: Use literal string "PKG_ROW_CNT" not undefined constant PKG_ROW_CNT
    int nRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sName = GetLocalString(oMod, "PKG_" + IntToString(i) + "_NAME");
        if (sName == "") continue;
        // Remove any old-style per-package locals (may not exist - safe to delete)
        DeleteLocalInt(oArea, "PKG_PAUSED_" + sName);
        DeleteLocalInt(oArea, "PKG_LAST_"   + sName);
        DeleteLocalInt(oArea, "PKG_OFF_"    + sName);
    }
}

// ============================================================================
// FULL AREA TEARDOWN
// Called with a 0.6s delay after the last PC exits, to allow in-flight
// scripts from the previous tick to complete before wiping state.
// ============================================================================

void AreaTeardown(object oArea)
{
    object oMod = GetModule();

    // Guard: a PC might have re-entered during the delay window
    if (RegistryPCCount(oArea) > 0)
    {
        if (GetLocalInt(oMod, MG_DEBUG))
            SendMessageToAllDMs("[SHUTDOWN] ABORTED - PC re-entered during teardown: " +
                GetTag(oArea));
        return;
    }

    if (GetLocalInt(oMod, MG_DEBUG))
        SendMessageToAllDMs("[SHUTDOWN] BEGIN teardown: " + GetTag(oArea));

    // Step 1: Remove from dispatch active area registry
    // FIX: Was DispatchAreaDeactivate(). The actual implementation is
    // RegistryDeactivateArea() in core_registry.nss.
    RegistryDeactivateArea(oArea);

    // Step 2: Run all package shutdown scripts (packages save data to SQL here)
    // FIX: Was PackageShutdownArea() - does not exist. Correct name:
    PackageRunShutdownScripts(oArea);

    // Step 3: Grid teardown - wipes all cell data for this area
    GridShutdownArea(oArea);

    // Step 4: Registry teardown - destroys cullable objects, wipes all slots
    // NOTE: RegistryShutdown internally calls PackageRunShutdownScripts and
    // PackageUnload. Calling PackageRunShutdownScripts before is intentional
    // (belt and suspenders - ensures shutdown scripts run even if registry
    //  teardown is interrupted).
    RegistryShutdown(oArea);

    // Step 5: Switch timing variables
    CleanSwitchVars(oArea);

    // Step 6: Package pause state (old-style locals)
    CleanPackageVars(oArea);

    // Step 7: Presence flags (belt-and-suspenders - registry wipes these too)
    DeleteLocalInt(oArea, "MG_HAS_PC");
    DeleteLocalInt(oArea, "MG_HAS_NPC");
    DeleteLocalInt(oArea, "MG_HAS_ENC");
    DeleteLocalInt(oArea, "MG_HAS_ITEM");
    DeleteLocalInt(oArea, "MG_HAS_CORPSE");

    // Step 8: Per-area package JSON blob
    DeleteLocalString(oArea, PKG_JSON_VAR);

    // Verify (belt-and-suspenders warning)
    int nRemaining = GetLocalInt(oArea, "RS_CNT");
    if (nRemaining > 0 && GetLocalInt(oMod, MG_DEBUG))
        SendMessageToAllDMs("[SHUTDOWN] WARNING: " + IntToString(nRemaining) +
            " objects remain in registry after teardown: " + GetTag(oArea));

    if (GetLocalInt(oMod, MG_DEBUG))
        SendMessageToAllDMs("[SHUTDOWN] COMPLETE: " + GetTag(oArea) + " - area clean.");
}

// ============================================================================
// MAIN: Area OnExit handler
// ============================================================================

void main()
{
    object oArea   = OBJECT_SELF;
    object oLeaver = GetExitingObject();
    object oMod    = GetModule();

    // Only process player characters and DM-possessed creatures
    if (!GetIsPC(oLeaver) && !GetIsDMPossessed(oLeaver)) return;

    // Save player state to SQL BEFORE deregistering
    if (GetIsPC(oLeaver))
    {
        SQLSavePlayerState(oLeaver);
        if (GetLocalInt(oMod, MG_DEBUG_SQL))
            WriteTimestampedLogEntry("[SQL] " + GetName(oLeaver) + " state saved on exit.");
    }

    // Deregister from registry (updates PC count, may trigger RegistryDeactivateArea)
    RegistryRemove(oArea, oLeaver);

    if (GetLocalInt(oMod, MG_DEBUG))
        SendMessageToAllDMs("[EXIT] " + GetName(oLeaver) +
            " <- " + GetTag(oArea) +
            " PC=" + IntToString(RegistryPCCount(oArea)));

    // If more players remain, nothing more to do
    if (RegistryPCCount(oArea) > 0) return;

    // Last player just left. Schedule teardown with a small delay so
    // any in-flight DelayCommand scripts from this tick can finish safely.
    if (GetLocalInt(oMod, MG_DEBUG))
        SendMessageToAllDMs("[SHUTDOWN] Scheduling teardown: " + GetTag(oArea));

    DelayCommand(0.6, AreaTeardown(oArea));
}
