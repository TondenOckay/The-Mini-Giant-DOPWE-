/* ============================================================================
    DOWE - core_enter.nss
    Area OnEnter Event Handler
    DOWE v2.3 | Production Standard | Final

    ============================================================================
    ASSIGN TO: Area Properties -> Scripts -> OnEnter (every area)
    ============================================================================

    Fires every time any object (PC, creature, placeable) enters an area.
    For PCs: boots up all area systems if this is the first PC to enter.
    For creatures: auto-registers them (for encounter tracking).

   ============================================================================
*/

#include "core_registry"
#include "core_grid"
#include "core_package"
#include "core_conductor"
#include "core_sql_persist"

void main()
{
    object oArea  = OBJECT_SELF;
    object oEnter = GetEnteringObject();
    object oMod   = GetModule();

    // Register entering object.
    // For PCs: if PC count was 0, this calls RegistryActivateArea internally,
    //          which adds this area to the dispatch active list.
    RegistryAutoRegister(oEnter, oArea, TRUE);

    // Non-PC objects (creatures, placeables spawning in) stop here.
    // Area systems only need to boot on first PC entry.
    if (!GetIsPC(oEnter) && !GetIsDMPossessed(oEnter)) return;

    // -----------------------------------------------------------------------
    // PC ENTER PATH
    // -----------------------------------------------------------------------

    // Load player state from SQL (restores position, HP, XP, gold)
    if (GetIsPC(oEnter))
    {
        SQLLoadPlayerState(oEnter);
        if (GetLocalInt(oMod, MG_DEBUG_SQL))
            WriteTimestampedLogEntry("[SQL] " + GetName(oEnter) + " state loaded.");
    }

    // Grid initialization - runs once per area activation.
    // GRDA_INIT is set by GridInitArea, cleared by GridShutdownArea.
    if (!GetLocalInt(oArea, GRDA_INIT))
    {
        GridInitArea(oArea);
        if (GetLocalInt(oMod, MG_DEBUG_GRID))
            SendMessageToAllDMs("[GRID] Initialized: " + GetTag(oArea));
    }

    // Registry cold-scan - registers pre-placed objects already in the area.
    // RS_INIT is set by RegistryInitArea, cleared by RegistryShutdown.
    if (!GetLocalInt(oArea, RS_INIT))
    {
        RegistryInitArea(oArea);
        if (GetLocalInt(oMod, MG_DEBUG_REG))
            SendMessageToAllDMs("[REGISTRY] Initialized: " + GetTag(oArea));
    }

    // Package system boot for this area.
    // PKG_JSON_VAR is empty string when not loaded.
    if (GetLocalString(oArea, PKG_JSON_VAR) == "")
    {
        PackageLoad(oArea);
        PackageRunBootScripts(oArea);
        if (GetLocalInt(oMod, MG_DEBUG_PKG))
            SendMessageToAllDMs("[PACKAGE] Booted: " + GetTag(oArea));
    }

    // Master debug summary
    if (GetLocalInt(oMod, MG_DEBUG))
        SendMessageToAllDMs("[ENTER] " + GetName(oEnter) +
            " -> " + GetTag(oArea) +
            " PC=" + IntToString(RegistryPCCount(oArea)) +
            " Objs=" + IntToString(GetLocalInt(oArea, RS_COUNT)));
}
