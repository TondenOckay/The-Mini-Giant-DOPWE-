/* ============================================================================
    DOWE - core_shutdown.nss (COMPLETE WITH SQL PERSISTENCE)
    Area Full Shutdown - Complete Teardown When Last Player Leaves
    
    ENHANCEMENTS:
    - Added SQL player state saving
    - Added debug logging
    - Added safety checks
    
    NWScript verified against nwn.wiki and nwnlexicon.com
   ============================================================================
*/

#include "core_registry"
#include "core_package"
#include "core_grid"
#include "core_dispatch"
#include "core_const"
#include "core_sql_persist"

// ============================================================================
// FORWARD DECLARATION
// ============================================================================
void AreaTeardown(object oArea);

// ============================================================================
// CLEANUP OF SWITCH TIMING VARIABLES
// ============================================================================

void CleanSwitchVars(object oArea)
{
    DeleteLocalInt(oArea, "SW_LAST_GHOST");
    DeleteLocalInt(oArea, "SW_LAST_CULL");
    DeleteLocalInt(oArea, "SW_LAST_INIT");
}

// ============================================================================
// CLEANUP OF PACKAGE STATE VARIABLES
// ============================================================================

void CleanPackageVars(object oArea)
{
    object oMod  = GetModule();
    int    nRows = GetLocalInt(oMod, PKG_ROW_CNT);

    int i;
    for (i = 0; i < nRows; i++)
    {
        string sName = GetLocalString(oMod, PKG_PFX + IntToString(i) + "_NAME");
        if (sName == "") continue;
        DeleteLocalInt(oArea, "PKG_PAUSED_" + sName);
        DeleteLocalInt(oArea, "PKG_LAST_"   + sName);
        DeleteLocalInt(oArea, "PKG_OFF_"    + sName);
    }
}

// ============================================================================
// FULL AREA TEARDOWN
// ============================================================================

void AreaTeardown(object oArea)
{
    // Guard: double-check no player snuck in during the delay window
    if (RegistryPCCount(oArea) > 0)
    {
        if (GetMGDebug())
            SendMessageToAllDMs("[SHUTDOWN] ABORTED: Player entered during teardown delay: " + GetTag(oArea));
        return;
    }

    if (GetMGDebug())
        SendMessageToAllDMs("[SHUTDOWN] BEGIN teardown: " + GetTag(oArea));

    // Step 1: Remove from dispatch registry
    DispatchAreaDeactivate(oArea);

    // Step 2: Run all package shutdown scripts
    PackageShutdownArea(oArea);

    // Step 3: Grid teardown
    GridShutdownArea(oArea);

    // Step 4: Registry teardown
    RegistryShutdown(oArea);

    // Step 5: Switch timing variables
    CleanSwitchVars(oArea);

    // Step 6: Package pause state
    CleanPackageVars(oArea);

    // Step 7: Presence flags
    DeleteLocalInt(oArea, "MG_HAS_PC");
    DeleteLocalInt(oArea, "MG_HAS_NPC");
    DeleteLocalInt(oArea, "MG_HAS_ENC");
    DeleteLocalInt(oArea, "MG_HAS_ITEM");
    DeleteLocalInt(oArea, "MG_HAS_CORPSE");

    // Step 8: Package JSON (complete cleanup)
    DeleteLocalString(oArea, PKG_JSON_VAR);

    // Verify complete cleanup
    int nRemainingObjects = GetLocalInt(oArea, RS_COUNT);
    if (nRemainingObjects > 0 && GetMGDebug())
    {
        SendMessageToAllDMs("[SHUTDOWN] WARNING: " + IntToString(nRemainingObjects) + 
            " objects remain in " + GetTag(oArea));
    }

    if (GetMGDebug())
        SendMessageToAllDMs("[SHUTDOWN] COMPLETE: " + GetTag(oArea) + " - area is clean.");
}

// ============================================================================
// MAIN: Area OnExit handler
// ============================================================================

void main()
{
    object oArea   = OBJECT_SELF;
    object oLeaver = GetExitingObject();

    // Only care about player characters leaving
    if (!GetIsPC(oLeaver) && !GetIsDMPossessed(oLeaver)) return;

    // Save player state to SQL BEFORE deregistering
    if (GetIsPC(oLeaver))
    {
        SQLSavePlayerState(oLeaver);
        
        // Packages can save their own variables here
        // Example: SQLSaveLocalInt(oLeaver, "QUEST_DRAGON_SLAIN", GetLocalInt(oLeaver, "QUEST_DRAGON_SLAIN"));
        
        if (GetLocalInt(GetModule(), MG_DEBUG_SQL))
            SendMessageToPC(oLeaver, "[SQL] Player state saved");
    }

    // Deregister from the registry
    // This updates MG_HAS_PC, which in turn calls DispatchAreaDeactivate
    // if the player count just hit 0.
    RegistryRemove(oArea, oLeaver);

    if (GetLocalInt(GetModule(), MG_DEBUG))
    {
        SendMessageToAllDMs("[EXIT] " + GetName(oLeaver) + 
            " <- " + GetTag(oArea) +
            " (PC=" + IntToString(RegistryPCCount(oArea)) + ")");
    }

    // Check if any players remain after this departure
    if (RegistryPCCount(oArea) > 0) return;

    // Last player just left.
    // Schedule teardown with a small delay so in-flight scripts can finish.
    if (GetMGDebug())
        SendMessageToAllDMs("[SHUTDOWN] Scheduling teardown for: " + GetTag(oArea));

    DelayCommand(0.6, AreaTeardown(oArea));
}
