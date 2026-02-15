/* ============================================================================
    mg_enc_wp_ULTIMATE.nss - Ultimate Waypoint Encounter System
    
    FEATURES:
    ✅ Day/Night creature variants
    ✅ Weather-dependent spawning
    ✅ Rare creature chances
    ✅ Configurable respawn timers
    ✅ Level restrictions (min/max)
    ✅ Quest gating
    ✅ Spawn messages
    ✅ Boss + minion system
    ✅ Patrol routes
    ✅ Level scaling
    ✅ Full Mini Giant integration
   ============================================================================
*/

#include "mg_const"
#include "mg_manifest"

// ============================================================================
// TIME & WEATHER HELPERS
// ============================================================================

int GetIsNight()
{
    int nHour = GetTimeHour();
    return (nHour >= 18 || nHour < 6);
}

int GetCurrentWeather()
{
    // NWN weather constants: 0=clear, 1=rain, 2=snow, 3=invalid
    // We'll use area fog for storm detection
    return GetWeather();
}

int MatchesWeatherReq(string sWeatherReq)
{
    if (sWeatherReq == "" || sWeatherReq == "****" || sWeatherReq == "ANY")
        return TRUE;
    
    int nWeather = GetCurrentWeather();
    string sWeather = "";
    
    switch (nWeather)
    {
        case 0: sWeather = "CLEAR"; break;
        case 1: sWeather = "RAIN"; break;
        case 2: sWeather = "SNOW"; break;
    }
    
    // Check for storm (high fog = storm conditions)
    // This is approximate - servers may have custom weather systems
    if (sWeather == "RAIN")
    {
        // Could add storm detection here
        sWeather = "RAIN,STORM";
    }
    
    // Check if current weather matches any in requirement list
    return FindSubString(sWeatherReq, sWeather) != -1;
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

string GetAreaPrefix(object oArea)
{
    string sTag = GetTag(oArea);
    int nUnderscore = FindSubString(sTag, "_");
    if (nUnderscore != -1)
        return GetStringLeft(sTag, nUnderscore);
    return sTag;
}

void ApplySpawnVFX(object oCreature, int nVFX)
{
    if (nVFX <= 0) return;
    
    effect eVFX;
    switch (nVFX)
    {
        case 1: eVFX = EffectVisualEffect(VFX_FNF_SMOKE_PUFF); break;
        case 2: eVFX = EffectVisualEffect(VFX_FNF_STRIKE_HOLY); break;
        case 3: eVFX = EffectVisualEffect(VFX_FNF_FIREBALL); break;
        default: eVFX = EffectVisualEffect(nVFX); break;
    }
    
    ApplyEffectAtLocation(DURATION_TYPE_INSTANT, eVFX, GetLocation(oCreature));
}

void ApplyVariableList(object oCreature, string sVarList)
{
    if (sVarList == "" || sVarList == "****") return;
    
    int i;
    string sPair = "";
    
    for (i = 0; i <= GetStringLength(sVarList); i++)
    {
        string sChar = GetSubString(sVarList, i, 1);
        
        if (sChar == "," || i == GetStringLength(sVarList))
        {
            if (sPair != "")
            {
                int nEquals = FindSubString(sPair, "=");
                
                if (nEquals != -1)
                {
                    string sVar = GetStringLeft(sPair, nEquals);
                    string sVal = GetSubString(sPair, nEquals + 1, 10);
                    
                    if (sVar == "HP_MULT")
                    {
                        float fMult = StringToFloat(sVal);
                        int nHP = GetMaxHitPoints(oCreature);
                        int nBonus = FloatToInt(IntToFloat(nHP) * (fMult - 1.0));
                        
                        effect eTempHP = EffectTemporaryHitpoints(nBonus);
                        ApplyEffectToObject(DURATION_TYPE_PERMANENT, eTempHP, oCreature);
                    }
                    else if (sVar == "SPEED")
                    {
                        float fSpeed = StringToFloat(sVal);
                        int nPercent = FloatToInt((fSpeed - 1.0) * 100.0);
                        
                        effect eSpeed = EffectMovementSpeedIncrease(nPercent);
                        ApplyEffectToObject(DURATION_TYPE_PERMANENT, eSpeed, oCreature);
                    }
                    else if (sVar == "DMG_MULT")
                    {
                        SetLocalFloat(oCreature, "DMG_MULT", StringToFloat(sVal));
                    }
                    else
                    {
                        SetLocalString(oCreature, sVar, sVal);
                    }
                }
                
                sPair = "";
            }
        }
        else if (sChar != " ")
        {
            sPair += sChar;
        }
    }
}

void ApplyLevelScaling(object oCreature, int nScaleEnabled, int nAvgPartyLevel)
{
    if (nScaleEnabled != 1 || nAvgPartyLevel <= 0) return;
    
    int nCreatureLevel = GetHitDice(oCreature);
    int nLevelDiff = nAvgPartyLevel - nCreatureLevel;
    
    if (nLevelDiff == 0) return;
    
    if (nLevelDiff > 0)
    {
        // Scale UP for higher level party
        float fHPMult = 1.0 + (IntToFloat(nLevelDiff) * 0.15);
        int nHP = GetMaxHitPoints(oCreature);
        int nBonus = FloatToInt(IntToFloat(nHP) * (fHPMult - 1.0));
        
        effect eTempHP = EffectTemporaryHitpoints(nBonus);
        ApplyEffectToObject(DURATION_TYPE_PERMANENT, eTempHP, oCreature);
        
        int nABBonus = nLevelDiff / 2;
        if (nABBonus > 0)
        {
            effect eAB = EffectAttackIncrease(nABBonus);
            ApplyEffectToObject(DURATION_TYPE_PERMANENT, eAB, oCreature);
        }
    }
    else
    {
        // Scale DOWN for lower level party (easier)
        int nABPenalty = abs(nLevelDiff) / 2;
        if (nABPenalty > 0)
        {
            effect eAB = EffectAttackDecrease(nABPenalty);
            ApplyEffectToObject(DURATION_TYPE_PERMANENT, eAB, oCreature);
        }
    }
}

void SetupPatrol(object oCreature, string sWaypointTag, string sPatrolWPs)
{
    if (sPatrolWPs == "" || sPatrolWPs == "****") return;
    
    int nWP = 0;
    string sNum = "";
    
    int i;
    for (i = 0; i <= GetStringLength(sPatrolWPs); i++)
    {
        string sChar = GetSubString(sPatrolWPs, i, 1);
        
        if (sChar == "," || i == GetStringLength(sPatrolWPs))
        {
            if (sNum != "")
            {
                string sWPTag = sWaypointTag + "_" + sNum;
                SetLocalString(oCreature, "WP_" + IntToString(nWP), sWPTag);
                nWP++;
                sNum = "";
            }
        }
        else if (sChar != " ")
        {
            sNum += sChar;
        }
    }
    
    SetLocalInt(oCreature, "PATROL_WP_COUNT", nWP);
    SetLocalInt(oCreature, "PATROL_CURRENT", 0);
    
    if (nWP > 0)
    {
        string sFirstWP = GetLocalString(oCreature, "WP_0");
        object oFirstWP = GetWaypointByTag(sFirstWP);
        
        if (GetIsObjectValid(oFirstWP))
        {
            AssignCommand(oCreature, ActionMoveToObject(oFirstWP, TRUE));
        }
    }
}

// ============================================================================
// CREATURE SELECTION (Day/Night + Rare Variants)
// ============================================================================

string SelectCreature(string s2DA, int nRow, int bIsNight)
{
    int nDayNightMode = StringToInt(Get2DAString(s2DA, "DayNightMode", nRow));
    
    string sCreature1 = "";
    string sCreature2 = "";
    int nChance1 = 100;
    int nChance2 = 0;
    
    // NIGHT MODE
    if (bIsNight && nDayNightMode == 1)
    {
        sCreature1 = Get2DAString(s2DA, "NightCreature", nRow);
        sCreature2 = Get2DAString(s2DA, "NightCreature2", nRow);
        
        // If no night creatures defined, fall back to day
        if (sCreature1 == "" || sCreature1 == "****")
        {
            sCreature1 = Get2DAString(s2DA, "CreatureTag", nRow);
            sCreature2 = Get2DAString(s2DA, "Creature2Tag", nRow);
        }
    }
    // DAY MODE (or no day/night system)
    else
    {
        sCreature1 = Get2DAString(s2DA, "CreatureTag", nRow);
        sCreature2 = Get2DAString(s2DA, "Creature2Tag", nRow);
    }
    
    // Get chances
    nChance1 = StringToInt(Get2DAString(s2DA, "Creature1Chance", nRow));
    nChance2 = StringToInt(Get2DAString(s2DA, "Creature2Chance", nRow));
    
    // Validate chances
    if (nChance1 <= 0) nChance1 = 100;
    if (nChance2 <= 0) nChance2 = 0;
    
    // If no creature2, return creature1
    if (sCreature2 == "" || sCreature2 == "****")
        return sCreature1;
    
    // Roll for rare variant
    int nRoll = Random(100);
    
    if (nRoll < nChance1)
        return sCreature1;
    else
        return sCreature2;
}

// ============================================================================
// CREATURE SPAWNING
// ============================================================================

object SpawnCreature(string s2DA, int nRow, object oWP, object oArea, 
                    string sFaction, int nAvgLevel, int nLevelScale, 
                    object oOwnerPC, float fDespawn, int bIsNight)
{
    // Select creature based on day/night and rarity
    string sCreatureTag = SelectCreature(s2DA, nRow, bIsNight);
    
    if (sCreatureTag == "" || sCreatureTag == "****") 
        return OBJECT_INVALID;
    
    location lSpawn = GetLocation(oWP);
    object oCreature = CreateObject(OBJECT_TYPE_CREATURE, sCreatureTag, lSpawn);
    
    if (!GetIsObjectValid(oCreature)) return OBJECT_INVALID;
    
    // Apply enhancements
    int nVFX = StringToInt(Get2DAString(s2DA, "SpawnVFX", nRow));
    string sVars = Get2DAString(s2DA, "VariableList", nRow);
    
    ApplySpawnVFX(oCreature, nVFX);
    ApplyVariableList(oCreature, sVars);
    ApplyLevelScaling(oCreature, nLevelScale, nAvgLevel);
    
    // Set faction
    if (sFaction == "HOSTILE")
        ChangeToStandardFaction(oCreature, STANDARD_FACTION_HOSTILE);
    else if (sFaction == "DEFENDER")
        ChangeToStandardFaction(oCreature, STANDARD_FACTION_DEFENDER);
    else if (sFaction == "COMMONER")
        ChangeToStandardFaction(oCreature, STANDARD_FACTION_COMMONER);
    
    // Set loot table
    string sLootTable = Get2DAString(s2DA, "LootTable", nRow);
    if (sLootTable != "" && sLootTable != "****")
    {
        SetLocalString(oCreature, "LOOT_TABLE", sLootTable);
    }
    
    // Add to manifest with despawn distance
    int nSlot = ManifestAdd(oArea, oCreature, MF_CREATURE, 0, fDespawn);
    
    // Set ownership for janitor
    if (GetIsObjectValid(oOwnerPC) && nSlot > 0)
    {
        int nOwnerSlot = GetLocalInt(oOwnerPC, M_OBJ_SLOT);
        string sPfx = M_SLOT_PFX + IntToString(nSlot) + "_";
        SetLocalInt(oArea, sPfx + M_OWNER, nOwnerSlot);
    }
    
    // Setup behavior
    int nBehavior = StringToInt(Get2DAString(s2DA, "Behavior", nRow));
    if (nBehavior == 1)
    {
        string sPatrolWPs = Get2DAString(s2DA, "PatrolWPs", nRow);
        string sWaypointTag = Get2DAString(s2DA, "WaypointTag", nRow);
        SetupPatrol(oCreature, sWaypointTag, sPatrolWPs);
    }
    
    // Run spawn script
    string sScript = Get2DAString(s2DA, "OnSpawnScript", nRow);
    if (sScript != "" && sScript != "****")
    {
        ExecuteScript(sScript, oCreature);
    }
    
    return oCreature;
}

// ============================================================================
// BOSS + MINION SPAWNING
// ============================================================================

void SpawnBoss(string s2DA, int nRow, object oWP, object oArea, string sFaction, 
              int nAvgLevel, int nLevelScale, object oOwnerPC, float fDespawn, int bIsNight)
{
    int nIsBoss = StringToInt(Get2DAString(s2DA, "IsBoss", nRow));
    if (nIsBoss != 1) return;
    
    int nBossRow = StringToInt(Get2DAString(s2DA, "BossRow", nRow));
    if (nBossRow > 0) nRow = nBossRow;
    
    object oBoss = SpawnCreature(s2DA, nRow, oWP, oArea, sFaction, nAvgLevel, 
                                nLevelScale, oOwnerPC, fDespawn, bIsNight);
    
    if (!GetIsObjectValid(oBoss)) return;
    
    // Spawn minions
    string sMinionResRef = Get2DAString(s2DA, "MinionResRef", nRow);
    string sMinionCount = Get2DAString(s2DA, "MinionCount", nRow);
    
    if (sMinionResRef != "" && sMinionResRef != "****" && 
        sMinionCount != "" && sMinionCount != "****")
    {
        int nMinions = 0;
        int nDash = FindSubString(sMinionCount, "-");
        
        if (nDash != -1)
        {
            int nMin = StringToInt(GetStringLeft(sMinionCount, nDash));
            int nMax = StringToInt(GetSubString(sMinionCount, nDash + 1, 5));
            nMinions = nMin + Random(nMax - nMin + 1);
        }
        else
        {
            nMinions = StringToInt(sMinionCount);
        }
        
        int i;
        for (i = 0; i < nMinions; i++)
        {
            location lBoss = GetLocation(oBoss);
            vector vBoss = GetPositionFromLocation(lBoss);
            float fAngle = IntToFloat(Random(360)) * 3.14159 / 180.0;
            float fDist = 2.0 + IntToFloat(Random(3));
            
            vector vMinion;
            vMinion.x = vBoss.x + fDist * cos(fAngle);
            vMinion.y = vBoss.y + fDist * sin(fAngle);
            vMinion.z = vBoss.z;
            
            location lMinion = Location(oArea, vMinion, IntToFloat(Random(360)));
            
            object oMinion = CreateObject(OBJECT_TYPE_CREATURE, sMinionResRef, lMinion);
            
            if (GetIsObjectValid(oMinion))
            {
                string sVars = Get2DAString(s2DA, "VariableList", nRow);
                ApplyVariableList(oMinion, sVars);
                ApplyLevelScaling(oMinion, nLevelScale, nAvgLevel);
                
                AssignCommand(oMinion, ActionForceFollowObject(oBoss, 3.0));
                
                ManifestAdd(oArea, oMinion, MF_CREATURE, 0, fDespawn);
            }
        }
    }
}

// ============================================================================
// MAIN SPAWN ENCOUNTER FUNCTION
// ============================================================================

void SpawnEncounter(string s2DA, int nRow, object oArea, int nAvgLevel, object oNearestPC)
{
    string sWaypointTag = Get2DAString(s2DA, "WaypointTag", nRow);
    if (sWaypointTag == "" || sWaypointTag == "****") return;
    
    object oWP = GetWaypointByTag(sWaypointTag);
    if (!GetIsObjectValid(oWP)) return;
    
    // ========================================================================
    // RESPAWN TIMER CHECK
    // ========================================================================
    
    int nRespawnTime = StringToInt(Get2DAString(s2DA, "RespawnTime", nRow));
    if (nRespawnTime <= 0) nRespawnTime = 1800; // Default 30 min
    
    int nLastDeath = GetLocalInt(oWP, "ENC_LAST_DEATH");
    
    if (nLastDeath > 0)
    {
        int nTimeSinceDeath = GetLocalInt(GetModule(), "MG_TICK") - nLastDeath;
        
        // Convert ticks to seconds (assuming 6 second ticks)
        int nSecondsSinceDeath = nTimeSinceDeath * 6;
        
        if (nSecondsSinceDeath < nRespawnTime)
            return; // Not ready to respawn yet
    }
    
    // Check if already spawned and alive
    if (GetLocalInt(oWP, "ENC_ALIVE")) return;
    
    // ========================================================================
    // WEATHER CHECK
    // ========================================================================
    
    string sWeatherReq = Get2DAString(s2DA, "WeatherSpawn", nRow);
    if (!MatchesWeatherReq(sWeatherReq)) return;
    
    // ========================================================================
    // LEVEL RESTRICTIONS
    // ========================================================================
    
    int nMinLevel = StringToInt(Get2DAString(s2DA, "MinLevel", nRow));
    int nMaxLevel = StringToInt(Get2DAString(s2DA, "MaxLevel", nRow));
    
    if (nMaxLevel == 0) nMaxLevel = 99;
    
    if (nAvgLevel < nMinLevel || nAvgLevel > nMaxLevel)
        return;
    
    // ========================================================================
    // QUEST REQUIREMENT
    // ========================================================================
    
    string sRequiredQuest = Get2DAString(s2DA, "RequiredQuest", nRow);
    if (sRequiredQuest != "" && sRequiredQuest != "****")
    {
        if (!GetIsObjectValid(oNearestPC))
            return;
        
        if (!GetLocalInt(oNearestPC, sRequiredQuest))
            return;
    }
    
    // ========================================================================
    // SPAWN CREATURES
    // ========================================================================
    
    string sFaction = Get2DAString(s2DA, "FactionType", nRow);
    int nLevelScale = StringToInt(Get2DAString(s2DA, "LevelScale", nRow));
    float fDespawn = StringToFloat(Get2DAString(s2DA, "DespawnRadius", nRow));
    if (fDespawn == 0.0) fDespawn = 50.0;
    
    int bIsNight = GetIsNight();
    int nIsBoss = StringToInt(Get2DAString(s2DA, "IsBoss", nRow));
    
    if (nIsBoss == 1)
    {
        SpawnBoss(s2DA, nRow, oWP, oArea, sFaction, nAvgLevel, nLevelScale, 
                 oNearestPC, fDespawn, bIsNight);
    }
    else
    {
        string sNumApp = Get2DAString(s2DA, "NumAppearing", nRow);
        int nCount = 1;
        
        int nDash = FindSubString(sNumApp, "-");
        if (nDash != -1)
        {
            int nMin = StringToInt(GetStringLeft(sNumApp, nDash));
            int nMax = StringToInt(GetSubString(sNumApp, nDash + 1, 5));
            nCount = nMin + Random(nMax - nMin + 1);
        }
        else
        {
            nCount = StringToInt(sNumApp);
        }
        
        int i;
        for (i = 0; i < nCount; i++)
        {
            object oSpawned = SpawnCreature(s2DA, nRow, oWP, oArea, sFaction, 
                                          nAvgLevel, nLevelScale, oNearestPC, 
                                          fDespawn, bIsNight);
            
            if (GetIsObjectValid(oSpawned))
            {
                SetLocalInt(oWP, "ENC_ALIVE", TRUE);
            }
        }
    }
    
    // ========================================================================
    // SPAWN MESSAGE
    // ========================================================================
    
    string sSpawnMsg = Get2DAString(s2DA, "SpawnMessage", nRow);
    if (sSpawnMsg != "" && sSpawnMsg != "****")
    {
        if (GetIsObjectValid(oNearestPC))
        {
            FloatingTextStringOnCreature(sSpawnMsg, oNearestPC, FALSE);
        }
    }
}

// ============================================================================
// MAIN ENTRY POINT
// ============================================================================

void main()
{
    object oArea = OBJECT_SELF;
    
    string sPrefix = GetAreaPrefix(oArea);
    string s2DA = sPrefix + "_waypoint_encounters";
    
    // Calculate party average level
    int nAvgLevel = 0;
    int nPCCount = 0;
    
    string sToken = ManifestToken();
    object oPC = ManifestFirst(oArea, MF_PLAYER, sToken);
    
    while (GetIsObjectValid(oPC))
    {
        nAvgLevel += GetHitDice(oPC);
        nPCCount++;
        oPC = ManifestNext(oArea, sToken);
    }
    
    if (nPCCount > 0)
        nAvgLevel = nAvgLevel / nPCCount;
    
    // Get nearest PC for ownership
    object oNearestPC = ManifestFirst(oArea, MF_PLAYER);
    
    // Process all encounter rows
    int nRow = 0;
    int nSafety = 0;
    
    while (nSafety++ < 1000)
    {
        string sName = Get2DAString(s2DA, "CreatureName", nRow);
        if (sName == "") break;
        
        SpawnEncounter(s2DA, nRow, oArea, nAvgLevel, oNearestPC);
        
        nRow++;
    }
}
