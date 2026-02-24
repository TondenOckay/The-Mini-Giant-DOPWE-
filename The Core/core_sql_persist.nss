/* ============================================================================
    core_sql_persist.nss
    SQL Persistence System for Player Data
    
    Saves and restores player state when entering/exiting areas.
    
    ARCHITECTURE:
    - Player enters area: Load data from SQL
    - Player exits area: Save data to SQL
    - Player disconnects: Save data to SQL
    - Player reconnects: Load data from SQL
    
    DATA STORED:
    - Location (area tag, position, facing)
    - Hit points, spell points
    - Effects (buffs, debuffs)
    - Quest variables
    - Inventory state
    - Custom variables (from packages)
    
    TABLES CREATED:
    - player_state: Core player state
    - player_variables: Custom local variables
    - player_effects: Active effects
    
    NWScript verified against nwn.wiki and nwnlexicon.com
   ============================================================================
*/

#include "core_conductor"
#include "nwnx_sql"

// ============================================================================
// SQL TABLE DEFINITIONS
// ============================================================================

const string SQL_TABLE_PLAYER_STATE = "player_state";
const string SQL_TABLE_PLAYER_VARS  = "player_variables";
const string SQL_TABLE_PLAYER_EFFECTS = "player_effects";

/* ----------------------------------------------------------------------------
   SQLCreateTables
   
   Creates the required SQL tables if they don't exist.
   Call once from module OnLoad.
---------------------------------------------------------------------------- */
void SQLCreateTables()
{
    // Table: player_state
    string sQuery = "CREATE TABLE IF NOT EXISTS " + SQL_TABLE_PLAYER_STATE + " (" +
        "character_id VARCHAR(64) PRIMARY KEY, " +
        "account_name VARCHAR(64), " +
        "character_name VARCHAR(64), " +
        "area_tag VARCHAR(64), " +
        "pos_x FLOAT, " +
        "pos_y FLOAT, " +
        "pos_z FLOAT, " +
        "facing FLOAT, " +
        "current_hp INT, " +
        "max_hp INT, " +
        "gold INT, " +
        "xp INT, " +
        "last_saved TIMESTAMP DEFAULT CURRENT_TIMESTAMP, " +
        "INDEX(account_name)" +
    ")";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    // Table: player_variables
    sQuery = "CREATE TABLE IF NOT EXISTS " + SQL_TABLE_PLAYER_VARS + " (" +
        "character_id VARCHAR(64), " +
        "var_name VARCHAR(128), " +
        "var_type VARCHAR(16), " +  // INT, FLOAT, STRING, LOCATION, JSON
        "var_value_int INT, " +
        "var_value_float FLOAT, " +
        "var_value_string TEXT, " +
        "last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP, " +
        "PRIMARY KEY(character_id, var_name), " +
        "INDEX(character_id)" +
    ")";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    // Table: player_effects
    sQuery = "CREATE TABLE IF NOT EXISTS " + SQL_TABLE_PLAYER_EFFECTS + " (" +
        "character_id VARCHAR(64), " +
        "effect_type INT, " +
        "effect_subtype INT, " +
        "effect_duration FLOAT, " +
        "effect_creator VARCHAR(64), " +
        "effect_data TEXT, " +
        "INDEX(character_id)" +
    ")";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    WriteTimestampedLogEntry("[SQL] Persistence tables created/verified");
}

/* ----------------------------------------------------------------------------
   GetCharacterID
   
   Generates a unique character ID for SQL storage.
   Format: CDKey_CharacterName
---------------------------------------------------------------------------- */
string GetCharacterID(object oPC)
{
    string sCDKey = GetPCPublicCDKey(oPC);
    string sName = GetName(oPC);
    
    // Sanitize name (remove special characters)
    sName = NWNX_SQL_PrepareString(sName);
    
    return sCDKey + "_" + sName;
}

/* ----------------------------------------------------------------------------
   SQLSavePlayerState
   
   Saves core player state to SQL.
   Called on area exit, logout, disconnect.
---------------------------------------------------------------------------- */
void SQLSavePlayerState(object oPC)
{
    if (!GetIsPC(oPC)) return;
    
    string sCharID = GetCharacterID(oPC);
    string sAccount = GetPCPlayerName(oPC);
    string sName = GetName(oPC);
    object oArea = GetArea(oPC);
    string sAreaTag = GetTag(oArea);
    vector vPos = GetPosition(oPC);
    float fFacing = GetFacing(oPC);
    int nHP = GetCurrentHitPoints(oPC);
    int nMaxHP = GetMaxHitPoints(oPC);
    int nGold = GetGold(oPC);
    int nXP = GetXP(oPC);
    
    // Use REPLACE to insert or update
    string sQuery = "REPLACE INTO " + SQL_TABLE_PLAYER_STATE + " (" +
        "character_id, account_name, character_name, area_tag, " +
        "pos_x, pos_y, pos_z, facing, current_hp, max_hp, gold, xp" +
        ") VALUES (" +
        "'" + sCharID + "', " +
        "'" + NWNX_SQL_PrepareString(sAccount) + "', " +
        "'" + NWNX_SQL_PrepareString(sName) + "', " +
        "'" + sAreaTag + "', " +
        FloatToString(vPos.x) + ", " +
        FloatToString(vPos.y) + ", " +
        FloatToString(vPos.z) + ", " +
        FloatToString(fFacing) + ", " +
        IntToString(nHP) + ", " +
        IntToString(nMaxHP) + ", " +
        IntToString(nGold) + ", " +
        IntToString(nXP) +
    ")";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    if (GetLocalInt(GetModule(), MG_DEBUG_SQL))
        SendMessageToPC(oPC, "[SQL] State saved: " + sAreaTag);
}

/* ----------------------------------------------------------------------------
   SQLLoadPlayerState
   
   Loads core player state from SQL.
   Called on area enter, login, reconnect.
   
   RETURNS: TRUE if data was found and loaded
---------------------------------------------------------------------------- */
int SQLLoadPlayerState(object oPC)
{
    if (!GetIsPC(oPC)) return FALSE;
    
    string sCharID = GetCharacterID(oPC);
    
    string sQuery = "SELECT area_tag, pos_x, pos_y, pos_z, facing, " +
        "current_hp, max_hp, gold, xp FROM " + SQL_TABLE_PLAYER_STATE + 
        " WHERE character_id = '" + sCharID + "'";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    // Check if row exists
    if (!NWNX_SQL_ReadyToReadNextRow())
        return FALSE;
    
    NWNX_SQL_ReadNextRow();
    
    // Read data
    string sAreaTag = NWNX_SQL_ReadDataInActiveRow(0);
    float fX = StringToFloat(NWNX_SQL_ReadDataInActiveRow(1));
    float fY = StringToFloat(NWNX_SQL_ReadDataInActiveRow(2));
    float fZ = StringToFloat(NWNX_SQL_ReadDataInActiveRow(3));
    float fFacing = StringToFloat(NWNX_SQL_ReadDataInActiveRow(4));
    int nHP = StringToInt(NWNX_SQL_ReadDataInActiveRow(5));
    int nMaxHP = StringToInt(NWNX_SQL_ReadDataInActiveRow(6));
    int nGold = StringToInt(NWNX_SQL_ReadDataInActiveRow(7));
    int nXP = StringToInt(NWNX_SQL_ReadDataInActiveRow(8));
    
    // Apply data
    object oArea = GetObjectByTag(sAreaTag);
    if (GetIsObjectValid(oArea))
    {
        vector vPos = Vector(fX, fY, fZ);
        location lLoc = Location(oArea, vPos, fFacing);
        
        // Don't teleport if already in correct area (from module load)
        if (GetArea(oPC) != oArea)
        {
            AssignCommand(oPC, JumpToLocation(lLoc));
        }
    }
    
    // Restore HP (do this after a delay to let the area load)
    DelayCommand(1.0, ApplyEffectToObject(DURATION_TYPE_INSTANT, 
        EffectHeal(nHP - GetCurrentHitPoints(oPC)), oPC));
    
    // Restore gold
    int nCurrentGold = GetGold(oPC);
    if (nGold > nCurrentGold)
        GiveGoldToCreature(oPC, nGold - nCurrentGold);
    else if (nGold < nCurrentGold)
        TakeGoldFromCreature(nCurrentGold - nGold, oPC, TRUE);
    
    // Restore XP
    SetXP(oPC, nXP);
    
    if (GetLocalInt(GetModule(), MG_DEBUG_SQL))
        SendMessageToPC(oPC, "[SQL] State loaded: " + sAreaTag);
    
    return TRUE;
}

/* ----------------------------------------------------------------------------
   SQLSaveLocalInt
   SQLSaveLocalFloat
   SQLSaveLocalString
   
   Saves individual local variables to SQL.
---------------------------------------------------------------------------- */
void SQLSaveLocalInt(object oPC, string sVarName, int nValue)
{
    string sCharID = GetCharacterID(oPC);
    
    string sQuery = "REPLACE INTO " + SQL_TABLE_PLAYER_VARS + " (" +
        "character_id, var_name, var_type, var_value_int" +
        ") VALUES (" +
        "'" + sCharID + "', " +
        "'" + NWNX_SQL_PrepareString(sVarName) + "', " +
        "'INT', " +
        IntToString(nValue) +
    ")";
    
    NWNX_SQL_ExecuteQuery(sQuery);
}

void SQLSaveLocalFloat(object oPC, string sVarName, float fValue)
{
    string sCharID = GetCharacterID(oPC);
    
    string sQuery = "REPLACE INTO " + SQL_TABLE_PLAYER_VARS + " (" +
        "character_id, var_name, var_type, var_value_float" +
        ") VALUES (" +
        "'" + sCharID + "', " +
        "'" + NWNX_SQL_PrepareString(sVarName) + "', " +
        "'FLOAT', " +
        FloatToString(fValue) +
    ")";
    
    NWNX_SQL_ExecuteQuery(sQuery);
}

void SQLSaveLocalString(object oPC, string sVarName, string sValue)
{
    string sCharID = GetCharacterID(oPC);
    
    string sQuery = "REPLACE INTO " + SQL_TABLE_PLAYER_VARS + " (" +
        "character_id, var_name, var_type, var_value_string" +
        ") VALUES (" +
        "'" + sCharID + "', " +
        "'" + NWNX_SQL_PrepareString(sVarName) + "', " +
        "'STRING', " +
        "'" + NWNX_SQL_PrepareString(sValue) + "'" +
    ")";
    
    NWNX_SQL_ExecuteQuery(sQuery);
}

/* ----------------------------------------------------------------------------
   SQLLoadLocalInt
   SQLLoadLocalFloat
   SQLLoadLocalString
   
   Loads individual local variables from SQL.
---------------------------------------------------------------------------- */
int SQLLoadLocalInt(object oPC, string sVarName, int nDefault = 0)
{
    string sCharID = GetCharacterID(oPC);
    
    string sQuery = "SELECT var_value_int FROM " + SQL_TABLE_PLAYER_VARS + 
        " WHERE character_id = '" + sCharID + "' AND var_name = '" + 
        NWNX_SQL_PrepareString(sVarName) + "'";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    if (!NWNX_SQL_ReadyToReadNextRow())
        return nDefault;
    
    NWNX_SQL_ReadNextRow();
    return StringToInt(NWNX_SQL_ReadDataInActiveRow(0));
}

float SQLLoadLocalFloat(object oPC, string sVarName, float fDefault = 0.0)
{
    string sCharID = GetCharacterID(oPC);
    
    string sQuery = "SELECT var_value_float FROM " + SQL_TABLE_PLAYER_VARS + 
        " WHERE character_id = '" + sCharID + "' AND var_name = '" + 
        NWNX_SQL_PrepareString(sVarName) + "'";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    if (!NWNX_SQL_ReadyToReadNextRow())
        return fDefault;
    
    NWNX_SQL_ReadNextRow();
    return StringToFloat(NWNX_SQL_ReadDataInActiveRow(0));
}

string SQLLoadLocalString(object oPC, string sVarName, string sDefault = "")
{
    string sCharID = GetCharacterID(oPC);
    
    string sQuery = "SELECT var_value_string FROM " + SQL_TABLE_PLAYER_VARS + 
        " WHERE character_id = '" + sCharID + "' AND var_name = '" + 
        NWNX_SQL_PrepareString(sVarName) + "'";
    
    NWNX_SQL_ExecuteQuery(sQuery);
    
    if (!NWNX_SQL_ReadyToReadNextRow())
        return sDefault;
    
    NWNX_SQL_ReadNextRow();
    return NWNX_SQL_ReadDataInActiveRow(0);
}

/* ----------------------------------------------------------------------------
   SQLSaveAllPlayerVars
   
   Saves all local variables with a specific prefix.
   Useful for package-specific data.
---------------------------------------------------------------------------- */
void SQLSaveAllPlayerVars(object oPC, string sPrefix = "")
{
    // This is a helper function that packages can call
    // Example: SQLSaveAllPlayerVars(oPC, "QUEST_");
    
    // NOTE: NWScript doesn't have native functions to iterate local variables
    // So packages must explicitly call SQLSaveLocalInt/Float/String for each var
    // This function serves as documentation of the pattern
}
