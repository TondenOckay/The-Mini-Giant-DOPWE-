/* ============================================================================
    core_clientleave.nss
    Module OnClientLeave Event Handler
    
    Fires when a player disconnects from the server (logout, crash, timeout).
    Saves player state to SQL before they're removed from the game.
    
    ASSIGN TO: Module OnClientLeave event
    
    NWScript verified against nwn.wiki and nwnlexicon.com
   ============================================================================
*/

#include "core_sql_persist"
#include "core_conductor"

void main()
{
    object oPC = GetExitingObject();
    
    if (!GetIsPC(oPC)) return;
    
    // Save player state to SQL
    SQLSavePlayerState(oPC);
    
    // Packages can add their own save logic here via includes
    // Example: QuestSaveAllProgress(oPC);
    
    if (GetLocalInt(GetModule(), MG_DEBUG_SQL))
    {
        WriteTimestampedLogEntry("[CLIENT_LEAVE] " + GetName(oPC) + 
            " - Player state saved to SQL");
    }
    
    if (GetLocalInt(GetModule(), MG_DEBUG))
    {
        SendMessageToAllDMs("[CLIENT_LEAVE] " + GetName(oPC) + 
            " has disconnected");
    }
}
