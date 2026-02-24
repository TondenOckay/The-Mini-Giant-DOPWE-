/* ============================================================================
    DOWE - core_enter.nss (COMPLETE WITH SQL PERSISTENCE)
    Area OnEnter Event Handler
    
    ENHANCEMENTS:
    - Added SQL player state restoration
    - Added debug logging
    - Added error handling
    
    NWScript verified against nwn.wiki and nwnlexicon.com
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

    // 1. Register entering object
    //    For PCs: RegistryAdd internally calls RegistryActivateArea when
    //    PC count crosses from 0 to 1, connecting this area to the dispatcher.
    RegistryAutoRegister(oEnter, oArea, TRUE);

    // 2. Non-PC objects stop here (no area init needed for creatures spawning in)
    if (!GetIsPC(oEnter) && !GetIsDMPossessed(oEnter)) return;

    // 3. Load player state from SQL (if available)
    //    This restores position, HP, gold, XP, and custom variables
    if (GetIsPC(oEnter))
    {
        // Load core state
        SQLLoadPlayerState(oEnter);
        
        // Packages can load their own variables in their boot scripts
        // Example: SQLLoadLocalInt(oEnter, "QUEST_DRAGON_SLAIN", 0);
        
        if (GetLocalInt(GetModule(), MG_DEBUG_SQL))
            SendMessageToPC(oEnter, "[SQL] Player state loaded");
    }

    // 4. Grid initialization - runs once per activation
    //    GRDA_INIT is set by GridInitArea and cleared by GridShutdownArea.
    if (!GetLocalInt(oArea, GRDA_INIT))
    {
        GridInitArea(oArea);
        
        if (GetLocalInt(GetModule(), MG_DEBUG_GRID))
            SendMessageToAllDMs("[GRID] Initialized: " + GetTag(oArea));
    }

    // 5. Registry cold-scan - registers pre-placed objects in the area
    //    RS_INIT is set by RegistryInitArea and cleared by RegistryShutdown.
    if (!GetLocalInt(oArea, RS_INIT))
    {
        RegistryInitArea(oArea);
        
        if (GetLocalInt(GetModule(), MG_DEBUG_REG))
            SendMessageToAllDMs("[REGISTRY] Initialized: " + GetTag(oArea));
    }

    // 6. Package system boot for this area
    //    Guard: PKG_JSON_VAR is empty string when not loaded.
    if (GetLocalString(oArea, PKG_JSON_VAR) == "")
    {
        PackageLoad(oArea);
        PackageRunBootScripts(oArea);
        
        if (GetLocalInt(GetModule(), MG_DEBUG_PKG))
            SendMessageToAllDMs("[PACKAGE] Booted: " + GetTag(oArea));
    }

    // 7. Debug output
    if (GetLocalInt(GetModule(), MG_DEBUG))
    {
        SendMessageToAllDMs("[ENTER] " + GetName(oEnter) +
                            " -> " + GetTag(oArea) +
                            " (PC=" + IntToString(RegistryPCCount(oArea)) + ")" +
                            " (Objects=" + IntToString(GetLocalInt(oArea, RS_COUNT)) + ")");
    }
}
