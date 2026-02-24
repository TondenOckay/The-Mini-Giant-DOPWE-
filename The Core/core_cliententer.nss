/* ============================================================================
    core_cliententer.nss
    Module OnClientEnter Event Handler
    
    Fires when a player connects to the server.
    Loads player state from SQL if it exists.
    
    ASSIGN TO: Module OnClientEnter event
    
    FLOW:
    1. Player connects → OnClientEnter fires
    2. Load basic state from SQL (position, HP, XP, gold)
    3. Player enters first area → OnAreaEnter fires
    4. Area boots up and loads additional data
    
    NWScript verified against nwn.wiki and nwnlexicon.com
   ============================================================================
*/

#include "core_sql_persist"
#include "core_conductor"

void main()
{
    object oPC = GetEnteringObject();
    
    if (!GetIsPC(oPC)) return;
    
    // Attempt to load player state from SQL
    int bLoaded = SQLLoadPlayerState(oPC);
    
    if (bLoaded)
    {
        if (GetLocalInt(GetModule(), MG_DEBUG_SQL))
        {
            SendMessageToPC(oPC, "[WELCOME BACK] Your character state has been restored.");
            WriteTimestampedLogEntry("[CLIENT_ENTER] " + GetName(oPC) + 
                " - Player state loaded from SQL");
        }
    }
    else
    {
        // New character or first login since SQL system added
        if (GetLocalInt(GetModule(), MG_DEBUG_SQL))
        {
            SendMessageToPC(oPC, "[WELCOME] This appears to be your first login with the new system.");
            WriteTimestampedLogEntry("[CLIENT_ENTER] " + GetName(oPC) + 
                " - No saved state found (new character)");
        }
    }
    
    // Packages can add their own load logic here
    // Example: QuestLoadProgress(oPC);
    
    if (GetLocalInt(GetModule(), MG_DEBUG))
    {
        SendMessageToAllDMs("[CLIENT_ENTER] " + GetName(oPC) + 
            " (" + GetPCPlayerName(oPC) + ") has connected");
    }
}
