/* ============================================================================
    mg_enc_ondeath.nss - Encounter Death Handler
    
    Call this from creature OnDeath events to enable respawn timers
    
    USAGE:
    In your module's OnCreatureDeath event, add:
    if (GetLocalString(OBJECT_SELF, "LOOT_TABLE") != "")
        ExecuteScript("mg_enc_ondeath", OBJECT_SELF);
   ============================================================================
*/

#include "mg_manifest"

void main()
{
    object oCreature = OBJECT_SELF;
    object oArea = GetArea(oCreature);
    
    // Get creature's manifest slot
    int nSlot = GetLocalInt(oCreature, M_OBJ_SLOT);
    if (nSlot == 0) return;
    
    // Check if this is a waypoint spawn
    string sPfx = M_SLOT_PFX + IntToString(nSlot) + "_";
    string sTag = GetLocalString(oArea, sPfx + M_TAG);
    
    // Find the waypoint this creature came from
    // We store this on spawn
    string sWaypointTag = GetLocalString(oCreature, "SPAWN_WP");
    
    if (sWaypointTag != "")
    {
        object oWP = GetWaypointByTag(sWaypointTag);
        
        if (GetIsObjectValid(oWP))
        {
            // Check if this was the last creature from this waypoint
            int nCount = GetLocalInt(oWP, "ENC_COUNT");
            nCount--;
            
            SetLocalInt(oWP, "ENC_COUNT", nCount);
            
            if (nCount <= 0)
            {
                // All creatures dead - mark for respawn
                SetLocalInt(oWP, "ENC_ALIVE", FALSE);
                SetLocalInt(oWP, "ENC_LAST_DEATH", GetLocalInt(GetModule(), "MG_TICK"));
                DeleteLocalInt(oWP, "ENC_COUNT");
            }
        }
    }
    
    // Handle loot table
    string sLootTable = GetLocalString(oCreature, "LOOT_TABLE");
    if (sLootTable != "" && sLootTable != "****")
    {
        // TODO: Implement loot table system
        // For now, this is a placeholder
        // You would call your loot generation system here
    }
    
    // Remove from manifest (janitor will handle if player-owned)
    ManifestRemove(oArea, oCreature);
}
