/* ============================================================================
    DOWE v2.2 - mg_livenpc.nss (COMPLETE 2DA-DRIVEN SYSTEM)
    
    100% 2DA-driven test NPC spawning for module testing
    Zero hardcoding, full creator control
   ============================================================================
*/

#include "mg_const"
#include "mg_manifest"
#include "mg_createobj"

void main()
{
    object oArea = OBJECT_SELF;
    
    // Check if system enabled
    if (!GetLocalInt(GetModule(), MG_LIVE_NPC)) return;
    
    // Get area tag for 2DA name
    string sAreaTag = GetTag(oArea);
    string s2DA = sAreaTag + "_livenpc";
    
    // Try module-wide 2DA first, then area-specific
    if (Get2DAString(s2DA, "Enabled", 0) == "")
    {
        s2DA = "mg_livenpc";  // Fall back to global
    }
    
    // Check if 2DA exists
    if (Get2DAString(s2DA, "Enabled", 0) == "") return;
    
    int nRow = 0;
    int nSpawned = 0;
    
    // Process all rows
    while (TRUE)
    {
        // Check if row exists
        string sEnabled = Get2DAString(s2DA, "Enabled", nRow);
        if (sEnabled == "") break;  // End of 2DA
        
        // Skip if not enabled
        if (StringToInt(sEnabled) != 1)
        {
            nRow++;
            continue;
        }
        
        // Read row data
        string sWPTag = Get2DAString(s2DA, "WPTag", nRow);
        string sResRef = Get2DAString(s2DA, "ResRef", nRow);
        int nTiming = StringToInt(Get2DAString(s2DA, "SpawnTiming", nRow));
        string sOnSpawn = Get2DAString(s2DA, "OnSpawnScript", nRow);
        int nAsPlayer = StringToInt(Get2DAString(s2DA, "AsPlayer", nRow));
        int nFlags = StringToInt(Get2DAString(s2DA, "ManifestFlags", nRow));
        int nPersist = StringToInt(Get2DAString(s2DA, "Persistent", nRow));
        
        // Get current PC count
        int nPCs = GetLocalInt(oArea, M_PC_COUNT);
        
        // Check spawn timing
        int bSpawn = FALSE;
        
        if (nTiming == 1 && nPCs == 0)  // Before players
            bSpawn = TRUE;
        else if (nTiming == 2 && nPCs > 0)  // After players
            bSpawn = TRUE;
        else if (nTiming == 0)  // Always
            bSpawn = TRUE;
        
        if (bSpawn)
        {
            // Find waypoint
            object oWP = GetObjectByTag(sWPTag);
            
            if (GetIsObjectValid(oWP))
            {
                // Check if already spawned
                string sSpawnedVar = "LIVENPC_SPAWNED_" + sWPTag;
                
                if (!GetLocalInt(oArea, sSpawnedVar))
                {
                    // Spawn NPC
                    object oNPC = CreateObject(OBJECT_TYPE_CREATURE, sResRef, GetLocation(oWP));
                    
                    if (GetIsObjectValid(oNPC))
                    {
                        // Default to MF_LIVE_NPC if no flags specified
                        if (nFlags == 0) nFlags = MF_LIVE_NPC;
                        
                        // Register as player if requested
                        if (nAsPlayer == 1)
                        {
                            ManifestAddPC(oNPC, oArea);
                        }
                        else
                        {
                            ManifestAdd(oArea, oNPC, nFlags);
                        }
                        
                        // Mark as persistent if requested
                        if (nPersist == 1)
                        {
                            SetPlotFlag(oNPC, TRUE);
                        }
                        
                        // Execute OnSpawn script if specified
                        if (sOnSpawn != "" && sOnSpawn != "****")
                        {
                            ExecuteScript(sOnSpawn, oNPC);
                        }
                        
                        // Mark as spawned
                        SetLocalInt(oArea, sSpawnedVar, TRUE);
                        
                        nSpawned++;
                    }
                }
            }
        }
        
        nRow++;
    }
    
    // Debug output
    if (nSpawned > 0 && GetMGDebug())
    {
        SendMessageToAllDMs("LIVENPC: Spawned " + IntToString(nSpawned) + 
                           " NPCs in " + GetTag(oArea));
    }
}
