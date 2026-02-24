/* ============================================================================
    DOWE - core_registry.nss
    Data-Driven Object Registry

    ============================================================================
    PHILOSOPHY
    ============================================================================
    The 2DA is the authority. The script is the engine.

    Every object type, its flags, tag prefix, lifetime, despawn radius,
    presence variable, and classification behavior is a row in core_registry.2da.
    The script reads the 2DA once at module boot and caches it. After that, the
    2DA is never touched at runtime. All queries are O(1) local variable reads.

    To add a new object type: add a row to core_registry.2da. Zero script changes.
    To change type behavior: edit that row. Zero script changes.

    ============================================================================
    SLOT DATA LAYOUT (stored on area object)
    ============================================================================
    Slot prefix: RS_[N]_  where N is the slot number

      RS_[N]_O    object reference
      RS_[N]_F    bitflag (from 2DA BITFLAG column)
      RS_[N]_T    tag string (cached at registration time)
      RS_[N]_SP   spawn tick
      RS_[N]_EX   expire tick (0 = no expiry)
      RS_[N]_DD   despawn distance float (0 = no distance despawn)
      RS_[N]_OW   owner slot int (0 = no owner)
      RS_[N]_CK   CDKey string (players only)
      RS_[N]_AC   account name string (players only)
      RS_[N]_GC   grid cell int (set by core_grid)
      RS_[N]_RW   2DA row index for this slot (fast re-lookup)

    Object-local vars stamped on the object itself:
      RG_SLOT     int    - reverse lookup: object -> slot number
      RG_TYPE     string - type stamp from 2DA TYPE_STAMP column

    Area-level bookkeeping:
      RS_CNT      total registered object count
      RS_PCC      cached player-type count
      RS_MAX      highest slot number allocated
      RS_FREE     freelist head (0 = list empty, no recycled slots)
      RS_F_[N]    freelist next pointer for slot N
      RS_INIT     area initialization guard flag

   ============================================================================
*/

#include "core_conductor"

// ============================================================================
// SECTION 1: BITFLAG CONSTANTS
// Values MUST match BITFLAG column in core_registry.2da.
// If you add a row to the 2DA, add a matching const here.
// ============================================================================

const int RF_PLAYER       = 1;
const int RF_LIVE_NPC     = 2;
const int RF_HENCHMAN     = 4;
const int RF_MOUNT        = 8;
const int RF_PET          = 16;
const int RF_SUMMONED     = 32;
const int RF_CREATURE     = 64;
const int RF_OBJECT       = 128;
const int RF_CORPSE       = 256;
const int RF_ITEM         = 512;
const int RF_GATHER_NODE  = 1024;
const int RF_CRAFT_BOX    = 2048;
const int RF_WP_NPC       = 4096;
const int RF_WP_CREATURE  = 8192;
const int RF_WP_WALK      = 16384;
const int RF_TRIGGER      = 32768;
const int RF_QUEST        = 65536;
const int RF_LOOT_CHEST   = 131072;

// Composite flags. Rebuilt from 2DA at boot; also declared here for
// compile-time use. Must match IS_PLAYER_TYPE / IS_CREATURE / IS_CULLABLE
// column ORs across all rows.
const int RF_ALL_PLAYERS   = 3;       // RF_PLAYER | RF_LIVE_NPC
const int RF_ALL_CREATURES = 126;     // RF_LIVE_NPC|RF_HENCHMAN|RF_MOUNT|RF_PET|RF_SUMMONED|RF_CREATURE
const int RF_ALL_CULLABLE  = 992;     // RF_SUMMONED|RF_CREATURE|RF_CORPSE|RF_ITEM

// ============================================================================
// SECTION 2: KEY CONSTANTS
// ============================================================================

const string RG_SLOT_VAR   = "RG_SLOT";
const string RG_TYPE_VAR   = "RG_TYPE";
const string RG_2DA        = "core_registry";
const string RG_PFX        = "RG_";
const string RS_PFX        = "RS_";

// Slot bookkeeping vars on area
const string RS_COUNT      = "RS_CNT";
const string RS_PC_COUNT   = "RS_PCC";
const string RS_MAX_SLOT   = "RS_MAX";
const string RS_FREE_HEAD  = "RS_FREE";
const string RS_FREE_PFX   = "RS_F_";
const string RS_INIT       = "RS_INIT";

// Slot field suffixes (appended after RS_[N]_)
const string RSF_OBJ       = "O";
const string RSF_FLAG      = "F";
const string RSF_TAG       = "T";
const string RSF_SPAWN     = "SP";
const string RSF_EXPIRE    = "EX";
const string RSF_DESPDIST  = "DD";
const string RSF_OWNER     = "OW";
const string RSF_CDKEY     = "CK";
const string RSF_ACCOUNT   = "AC";
const string RSF_GRIDCELL  = "GC";
const string RSF_ROW       = "RW";

// Module cache field suffixes (appended after RG_[N])
const string RGC_FLAG      = "_FLAG";
const string RGC_STAMP     = "_STAMP";
const string RGC_PFX       = "_PFX";
const string RGC_CDKEY     = "_CDKEY";
const string RGC_ACCT      = "_ACCT";
const string RGC_OWNER     = "_OWNER";
const string RGC_AENT      = "_AENT";
const string RGC_ASPW      = "_ASPW";
const string RGC_GATE      = "_GATE";
const string RGC_GHOST     = "_GHOST";
const string RGC_DCULL     = "_DCULL";
const string RGC_EXP       = "_EXP";
const string RGC_DDIST     = "_DDIST";
const string RGC_ISPC      = "_ISPC";
const string RGC_ISCREAT   = "_ISCREAT";
const string RGC_CULL      = "_CULL";
const string RGC_PVAR      = "_PVAR";

// Slot capacity
const int    RG_MAX_SLOTS  = 2000;
const int    RG_WARN_AT    = 1800;

// ============================================================================
// SECTION 3: BOOT
// Reads core_registry.2da once. Caches to module object.
// Call once from module OnLoad before any area event fires.
// ============================================================================

void RegistryBoot()
{
    object oMod = GetModule();
    if (GetLocalInt(oMod, "RG_BOOTED")) return;
    SetLocalInt(oMod, "RG_BOOTED", 1);

    int nRows = Get2DARowCount(RG_2DA);
    SetLocalInt(oMod, "RG_ROW_CNT", nRows);

    int nCompPlayers  = 0;
    int nCompCreature = 0;
    int nCompCullable = 0;

    int i;
    for (i = 0; i < nRows; i++)
    {
        string sN = RG_PFX + IntToString(i);

        int    nFlag  = StringToInt(Get2DAString(RG_2DA, "BITFLAG",        i));
        string sStamp = Get2DAString(RG_2DA,             "TYPE_STAMP",     i);
        string sPfx   = Get2DAString(RG_2DA,             "TAG_PREFIX",     i);
        int    nCDKey = StringToInt(Get2DAString(RG_2DA, "TRACK_CDKEY",    i));
        int    nAcct  = StringToInt(Get2DAString(RG_2DA, "TRACK_ACCOUNT",  i));
        int    nOwner = StringToInt(Get2DAString(RG_2DA, "TRACK_OWNER",    i));
        int    nAEnt  = StringToInt(Get2DAString(RG_2DA, "AUTO_ENTER",     i));
        int    nASpw  = StringToInt(Get2DAString(RG_2DA, "AUTO_SPAWN",     i));
        int    nGate  = StringToInt(Get2DAString(RG_2DA, "PULSE_GATE",     i));
        int    nGhost = StringToInt(Get2DAString(RG_2DA, "RECLAIM_GHOST",  i));
        int    nDCull = StringToInt(Get2DAString(RG_2DA, "DESTROY_CULL",   i));
        int    nExp   = StringToInt(Get2DAString(RG_2DA, "EXPIRE_TICKS",   i));
        float  fDist  = StringToFloat(Get2DAString(RG_2DA,"DESPAWN_DIST",  i));
        int    nIsPC  = StringToInt(Get2DAString(RG_2DA, "IS_PLAYER_TYPE", i));
        int    nIsCr  = StringToInt(Get2DAString(RG_2DA, "IS_CREATURE",    i));
        int    nCull  = StringToInt(Get2DAString(RG_2DA, "IS_CULLABLE",    i));
        string sPVar  = Get2DAString(RG_2DA,             "PRESENCE_VAR",   i);

        if (sPfx  == "****") sPfx  = "";
        if (sPVar == "****") sPVar = "";

        SetLocalInt(oMod,    sN + RGC_FLAG,    nFlag);
        SetLocalString(oMod, sN + RGC_STAMP,   sStamp);
        SetLocalString(oMod, sN + RGC_PFX,     sPfx);
        SetLocalInt(oMod,    sN + RGC_CDKEY,   nCDKey);
        SetLocalInt(oMod,    sN + RGC_ACCT,    nAcct);
        SetLocalInt(oMod,    sN + RGC_OWNER,   nOwner);
        SetLocalInt(oMod,    sN + RGC_AENT,    nAEnt);
        SetLocalInt(oMod,    sN + RGC_ASPW,    nASpw);
        SetLocalInt(oMod,    sN + RGC_GATE,    nGate);
        SetLocalInt(oMod,    sN + RGC_GHOST,   nGhost);
        SetLocalInt(oMod,    sN + RGC_DCULL,   nDCull);
        SetLocalInt(oMod,    sN + RGC_EXP,     nExp);
        SetLocalFloat(oMod,  sN + RGC_DDIST,   fDist);
        SetLocalInt(oMod,    sN + RGC_ISPC,    nIsPC);
        SetLocalInt(oMod,    sN + RGC_ISCREAT, nIsCr);
        SetLocalInt(oMod,    sN + RGC_CULL,    nCull);
        SetLocalString(oMod, sN + RGC_PVAR,    sPVar);

        // Reverse lookup: flag -> row index
        if (nFlag > 0)
            SetLocalInt(oMod, "RG_FLAG_" + IntToString(nFlag), i);

        if (nIsPC)  nCompPlayers  = nCompPlayers  | nFlag;
        if (nIsCr)  nCompCreature = nCompCreature | nFlag;
        if (nCull)  nCompCullable = nCompCullable | nFlag;
    }

    SetLocalInt(oMod, "RG_COMP_PLAYERS",   nCompPlayers);
    SetLocalInt(oMod, "RG_COMP_CREATURES", nCompCreature);
    SetLocalInt(oMod, "RG_COMP_CULLABLE",  nCompCullable);

    WriteTimestampedLogEntry("[REGISTRY] Boot complete. " +
        IntToString(nRows) + " types loaded from " + RG_2DA + ".2da");
}

// ============================================================================
// SECTION 4: MODULE CACHE ACCESSORS - all O(1) local variable reads
// ============================================================================

int RegistryRowCount()
{ return GetLocalInt(GetModule(), "RG_ROW_CNT"); }

int RegistryRowForFlag(int nFlag)
{
    object oMod = GetModule();
    int nRow = GetLocalInt(oMod, "RG_FLAG_" + IntToString(nFlag));
    string sN = RG_PFX + IntToString(nRow);
    if (GetLocalInt(oMod, sN + RGC_FLAG) == nFlag) return nRow;
    return -1;
}

int    RegGetFlag(int nRow)     { return GetLocalInt(GetModule(),    RG_PFX + IntToString(nRow) + RGC_FLAG);    }
string RegGetStamp(int nRow)    { return GetLocalString(GetModule(), RG_PFX + IntToString(nRow) + RGC_STAMP);   }
string RegGetTagPrefix(int nRow){ return GetLocalString(GetModule(), RG_PFX + IntToString(nRow) + RGC_PFX);    }
int    RegGetAutoEnter(int nRow){ return GetLocalInt(GetModule(),    RG_PFX + IntToString(nRow) + RGC_AENT);   }
int    RegGetAutoSpawn(int nRow){ return GetLocalInt(GetModule(),    RG_PFX + IntToString(nRow) + RGC_ASPW);   }
int    RegGetReclaimGhost(int nRow){ return GetLocalInt(GetModule(), RG_PFX + IntToString(nRow) + RGC_GHOST);  }
int    RegGetDestroyCull(int nRow){ return GetLocalInt(GetModule(),  RG_PFX + IntToString(nRow) + RGC_DCULL);  }
int    RegGetExpireTicks(int nRow){ return GetLocalInt(GetModule(),  RG_PFX + IntToString(nRow) + RGC_EXP);    }
float  RegGetDespawnDist(int nRow){ return GetLocalFloat(GetModule(),RG_PFX + IntToString(nRow) + RGC_DDIST);  }
int    RegGetIsPlayerType(int nRow){ return GetLocalInt(GetModule(), RG_PFX + IntToString(nRow) + RGC_ISPC);   }
int    RegGetIsCreature(int nRow){ return GetLocalInt(GetModule(),   RG_PFX + IntToString(nRow) + RGC_ISCREAT);}
int    RegGetIsCullable(int nRow){ return GetLocalInt(GetModule(),   RG_PFX + IntToString(nRow) + RGC_CULL);   }
string RegGetPresenceVar(int nRow){ return GetLocalString(GetModule(),RG_PFX + IntToString(nRow) + RGC_PVAR);  }
int    RegGetTrackOwner(int nRow){ return GetLocalInt(GetModule(),   RG_PFX + IntToString(nRow) + RGC_OWNER);  }
int    RegGetTrackCDKey(int nRow){ return GetLocalInt(GetModule(),   RG_PFX + IntToString(nRow) + RGC_CDKEY);  }
int    RegGetTrackAccount(int nRow){ return GetLocalInt(GetModule(), RG_PFX + IntToString(nRow) + RGC_ACCT);   }

// Composite getters (from 2DA at boot)
int RegistryFlagPlayers()   { return GetLocalInt(GetModule(), "RG_COMP_PLAYERS");   }
int RegistryFlagCreatures() { return GetLocalInt(GetModule(), "RG_COMP_CREATURES"); }
int RegistryFlagCullable()  { return GetLocalInt(GetModule(), "RG_COMP_CULLABLE");  }

// ============================================================================
// SECTION 5: TYPE CLASSIFICATION
// Resolves an object to its 2DA row index. Returns -1 if unclassifiable.
// Resolution order: PC check -> associate check -> tag-prefix walk -> NWN type fallback.
// ============================================================================

int RegistryClassify(object oObj)
{
    if (!GetIsObjectValid(oObj)) return -1;

    object oMod     = GetModule();
    int    nRows    = GetLocalInt(oMod, "RG_ROW_CNT");
    int    nObjType = GetObjectType(oObj);

    // PCs: always PLAYER row, never tag-matched
    if (nObjType == OBJECT_TYPE_CREATURE && GetIsPC(oObj))
        return RegistryRowForFlag(RF_PLAYER);

    // Associates: check NWN relationship API (creatures with a master)
    if (nObjType == OBJECT_TYPE_CREATURE)
    {
        object oMaster = GetMaster(oObj);
        if (GetIsObjectValid(oMaster))
        {
            if (GetAssociate(ASSOCIATE_TYPE_HENCHMAN,       oMaster)    == oObj ||
                GetAssociate(ASSOCIATE_TYPE_HENCHMAN,       oMaster, 2) == oObj)
                return RegistryRowForFlag(RF_HENCHMAN);

            if (GetAssociate(ASSOCIATE_TYPE_ANIMALCOMPANION, oMaster) == oObj ||
                GetAssociate(ASSOCIATE_TYPE_FAMILIAR,        oMaster) == oObj)
                return RegistryRowForFlag(RF_PET);

            if (GetAssociate(ASSOCIATE_TYPE_SUMMONED,   oMaster) == oObj ||
                GetAssociate(ASSOCIATE_TYPE_DOMINATED,   oMaster) == oObj)
                return RegistryRowForFlag(RF_SUMMONED);
        }
        // No owner or unrecognized associate type - fall through to tag walk
    }

    // Tag-prefix walk: first match wins (row order = priority)
    string sTag = GetTag(oObj);
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sPfx = GetLocalString(oMod, RG_PFX + IntToString(i) + RGC_PFX);
        if (sPfx == "") continue;

        int nPfxLen = GetStringLength(sPfx);
        if (GetStringLeft(sTag, nPfxLen) == sPfx)
            return i;
    }

    // NWN object type fallback - explicit returns on every branch + final -1
    if (nObjType == OBJECT_TYPE_CREATURE)  return RegistryRowForFlag(RF_CREATURE);
    if (nObjType == OBJECT_TYPE_PLACEABLE) return RegistryRowForFlag(RF_OBJECT);
    if (nObjType == OBJECT_TYPE_ITEM)      return RegistryRowForFlag(RF_ITEM);
    if (nObjType == OBJECT_TYPE_WAYPOINT)  return RegistryRowForFlag(RF_WP_WALK);
    if (nObjType == OBJECT_TYPE_DOOR)      return RegistryRowForFlag(RF_OBJECT);
    if (nObjType == OBJECT_TYPE_TRIGGER)   return RegistryRowForFlag(RF_TRIGGER);

    return -1;
}

// ============================================================================
// SECTION 6: FREELIST - O(1) SLOT ALLOCATION
// ============================================================================

void FreelistPush(object oArea, int nSlot)
{
    int nHead = GetLocalInt(oArea, RS_FREE_HEAD);
    SetLocalInt(oArea, RS_FREE_PFX + IntToString(nSlot), nHead);
    SetLocalInt(oArea, RS_FREE_HEAD, nSlot);
}

int FreelistPop(object oArea)
{
    int nHead = GetLocalInt(oArea, RS_FREE_HEAD);
    if (nHead == 0) return 0;

    int nNext = GetLocalInt(oArea, RS_FREE_PFX + IntToString(nHead));
    SetLocalInt(oArea, RS_FREE_HEAD, nNext);
    DeleteLocalInt(oArea, RS_FREE_PFX + IntToString(nHead));
    return nHead;
}

// ============================================================================
// SECTION 7: PRESENCE FLAG MANAGEMENT
// Per-type object count stored as local int on the area object.
// The variable name comes from PRESENCE_VAR column in the 2DA.
// core_dispatch and core_switch read these to gate subsystem dispatch.
// ============================================================================

void PresenceUpdate(object oArea, string sPVar, int nDelta)
{
    if (sPVar == "") return;
    int nCur = GetLocalInt(oArea, sPVar) + nDelta;
    if (nCur < 0) nCur = 0;
    SetLocalInt(oArea, sPVar, nCur);
}

// O(1) presence queries for use by switchboard and packages
int RegistryHasPC(object oArea)       { return GetLocalInt(oArea, "MG_HAS_PC")     > 0; }
int RegistryHasNPC(object oArea)      { return GetLocalInt(oArea, "MG_HAS_NPC")    > 0; }
int RegistryHasEncounter(object oArea){ return GetLocalInt(oArea, "MG_HAS_ENC")    > 0; }
int RegistryHasCorpse(object oArea)   { return GetLocalInt(oArea, "MG_HAS_CORPSE") > 0; }
int RegistryHasItem(object oArea)     { return GetLocalInt(oArea, "MG_HAS_ITEM")   > 0; }

// ============================================================================
// SECTION 8: ACTIVATE / DEACTIVATE AREA
// Called from here when PC count crosses zero boundary.
// Bridges to core_dispatch without creating a circular include.
// ============================================================================

void RegistryActivateArea(object oArea)
{
    // Implemented by forwarding to core_dispatch.
    // core_dispatch is NOT #included here to avoid circular dependency.
    // Instead, core_dispatch.nss must be ExecuteScript'd or the caller
    // (core_enter.nss) handles the bridge directly.
    // This function is defined here so any script with core_registry can call it.
    // The actual active-area registry manipulation is in core_dispatch.
    object oMod = GetModule();
    string sTag = GetTag(oArea);

    if (GetLocalInt(oMod, "MG_ACTIVE_IDX_" + sTag) > 0) return;

    int nCnt = GetLocalInt(oMod, "MG_ACTIVE_CNT") + 1;
    SetLocalInt(oMod, "MG_ACTIVE_CNT", nCnt);
    SetLocalObject(oMod, "MG_ACTIVE_" + IntToString(nCnt), oArea);
    SetLocalInt(oMod, "MG_ACTIVE_IDX_" + sTag, nCnt);

    if (GetLocalInt(oMod, MG_DEBUG_DISP))
        SendMessageToAllDMs("[DISP] Activated: " + sTag +
                            " (slot " + IntToString(nCnt) + ")");
}

void RegistryDeactivateArea(object oArea)
{
    object oMod = GetModule();
    string sTag = GetTag(oArea);

    int nIdx = GetLocalInt(oMod, "MG_ACTIVE_IDX_" + sTag);
    if (nIdx == 0) return;

    int nCnt = GetLocalInt(oMod, "MG_ACTIVE_CNT");

    // Swap-and-pop: keep list gapless
    if (nIdx < nCnt)
    {
        object oLast    = GetLocalObject(oMod, "MG_ACTIVE_" + IntToString(nCnt));
        string sLastTag = GetTag(oLast);
        SetLocalObject(oMod, "MG_ACTIVE_" + IntToString(nIdx), oLast);
        SetLocalInt(oMod, "MG_ACTIVE_IDX_" + sLastTag, nIdx);
    }

    DeleteLocalObject(oMod, "MG_ACTIVE_" + IntToString(nCnt));
    DeleteLocalInt(oMod, "MG_ACTIVE_IDX_" + sTag);
    SetLocalInt(oMod, "MG_ACTIVE_CNT", nCnt - 1);

    if (GetLocalInt(oMod, MG_DEBUG_DISP))
        SendMessageToAllDMs("[DISP] Deactivated: " + sTag);
}

// ============================================================================
// SECTION 9: CORE ADD
// All registration goes through this single function.
// Behavior is entirely driven by the cached 2DA row.
// Returns the allocated slot number, or 0 on failure.
// ============================================================================

int RegistryAdd(object oArea, object oObj, int nRow,
                int nOwnerSlot = 0, int nExpireOver = 0, float fDespawnOver = 0.0)
{
    if (!GetIsObjectValid(oObj))  return 0;
    if (!GetIsObjectValid(oArea)) return 0;
    if (nRow < 0)                 return 0;

    object oMod = GetModule();

    // Double-registration guard
    int nExist = GetLocalInt(oObj, RG_SLOT_VAR);
    if (nExist > 0)
    {
        string sExPfx = RS_PFX + IntToString(nExist) + "_";
        if (GetLocalObject(oArea, sExPfx + RSF_OBJ) == oObj) return nExist;
    }

    // Allocate slot from freelist or expand
    int nSlot = FreelistPop(oArea);
    if (nSlot == 0)
    {
        int nMax = GetLocalInt(oArea, RS_MAX_SLOT);
        nSlot = nMax + 1;
        if (nSlot > RG_MAX_SLOTS)
        {
            WriteTimestampedLogEntry("[REGISTRY] CRITICAL: Capacity exceeded in " +
                                    GetTag(oArea));
            SendMessageToAllDMs("[REGISTRY] CRITICAL: Capacity exceeded in " +
                                GetTag(oArea));
            return 0;
        }
        if (nSlot == RG_WARN_AT)
            SendMessageToAllDMs("[REGISTRY] WARNING: 90% capacity in " +
                                GetTag(oArea));
        SetLocalInt(oArea, RS_MAX_SLOT, nSlot);
    }

    string sPfx  = RS_PFX + IntToString(nSlot) + "_";
    string sN    = RG_PFX + IntToString(nRow);

    // Read all 2DA-driven values from module cache (O(1) each)
    int    nFlag    = GetLocalInt(oMod,    sN + RGC_FLAG);
    string sStamp   = GetLocalString(oMod, sN + RGC_STAMP);
    int    nExpDef  = GetLocalInt(oMod,    sN + RGC_EXP);
    float  fDistDef = GetLocalFloat(oMod,  sN + RGC_DDIST);
    int    nIsPC    = GetLocalInt(oMod,    sN + RGC_ISPC);
    string sPVar    = GetLocalString(oMod, sN + RGC_PVAR);

    int   nExpire  = (nExpireOver  > 0)   ? nExpireOver  : nExpDef;
    float fDespawn = (fDespawnOver > 0.0) ? fDespawnOver : fDistDef;

    int nTick = GetLocalInt(oMod, "MG_TICK");

    // Write slot data
    SetLocalObject(oArea, sPfx + RSF_OBJ,  oObj);
    SetLocalInt(oArea,    sPfx + RSF_FLAG,  nFlag);
    SetLocalString(oArea, sPfx + RSF_TAG,   GetTag(oObj));
    SetLocalInt(oArea,    sPfx + RSF_SPAWN, nTick);
    SetLocalInt(oArea,    sPfx + RSF_ROW,   nRow);

    if (nExpire > 0)
        SetLocalInt(oArea, sPfx + RSF_EXPIRE, (nTick + nExpire) % 10000);

    if (fDespawn > 0.0)
        SetLocalFloat(oArea, sPfx + RSF_DESPDIST, fDespawn);

    if (nOwnerSlot > 0)
        SetLocalInt(oArea, sPfx + RSF_OWNER, nOwnerSlot);

    // CDKey and account (driven by 2DA columns)
    if (GetLocalInt(oMod, sN + RGC_CDKEY) && GetIsPC(oObj))
    {
        string sCK = GetPCPublicCDKey(oObj);
        SetLocalString(oArea, sPfx + RSF_CDKEY,  sCK);
        SetLocalString(oObj,  "RG_CDKEY",          sCK);
    }
    if (GetLocalInt(oMod, sN + RGC_ACCT) && GetIsPC(oObj))
    {
        string sAC = GetPCPlayerName(oObj);
        SetLocalString(oArea, sPfx + RSF_ACCOUNT, sAC);
        SetLocalString(oObj,  "RG_ACCOUNT",         sAC);
    }

    // Stamp object
    SetLocalString(oObj, RG_TYPE_VAR, sStamp);
    SetLocalInt(oObj,    RG_SLOT_VAR, nSlot);

    // Bookkeeping
    SetLocalInt(oArea, RS_COUNT, GetLocalInt(oArea, RS_COUNT) + 1);

    if (nIsPC)
    {
        int nPC    = GetLocalInt(oArea, RS_PC_COUNT);
        int nOldPC = nPC;
        nPC++;
        SetLocalInt(oArea, RS_PC_COUNT, nPC);

        // Gate the active area registry as PC count crosses zero
        if (nOldPC == 0 && nPC > 0)
            RegistryActivateArea(oArea);
    }

    // Presence counter (drives core_switch dispatch gating)
    PresenceUpdate(oArea, sPVar, 1);

    if (GetLocalInt(oMod, MG_DEBUG_REG))
        SendMessageToAllDMs("[REG+] " + sStamp + " \"" + GetTag(oObj) +
                            "\" slot=" + IntToString(nSlot) +
                            " area=" + GetTag(oArea));

    return nSlot;
}

// ============================================================================
// SECTION 10: CORE REMOVE
// ============================================================================

void RegistryRemoveBySlot(object oArea, int nSlot)
{
    if (nSlot <= 0) return;

    object oMod = GetModule();
    string sPfx = RS_PFX + IntToString(nSlot) + "_";

    object oObj  = GetLocalObject(oArea, sPfx + RSF_OBJ);
    int    nRow  = GetLocalInt(oArea,    sPfx + RSF_ROW);

    string sPVar = "";
    if (nRow >= 0)
        sPVar = GetLocalString(oMod, RG_PFX + IntToString(nRow) + RGC_PVAR);

    // Clear all slot fields
    DeleteLocalObject(oArea, sPfx + RSF_OBJ);
    DeleteLocalInt(oArea,    sPfx + RSF_FLAG);
    DeleteLocalString(oArea, sPfx + RSF_TAG);
    DeleteLocalInt(oArea,    sPfx + RSF_SPAWN);
    DeleteLocalInt(oArea,    sPfx + RSF_EXPIRE);
    DeleteLocalFloat(oArea,  sPfx + RSF_DESPDIST);
    DeleteLocalInt(oArea,    sPfx + RSF_OWNER);
    DeleteLocalString(oArea, sPfx + RSF_CDKEY);
    DeleteLocalString(oArea, sPfx + RSF_ACCOUNT);
    DeleteLocalInt(oArea,    sPfx + RSF_GRIDCELL);
    DeleteLocalInt(oArea,    sPfx + RSF_ROW);

    // Clear object-local vars if object still exists
    if (GetIsObjectValid(oObj))
    {
        DeleteLocalInt(oObj,    RG_SLOT_VAR);
        DeleteLocalString(oObj, RG_TYPE_VAR);
        DeleteLocalString(oObj, "RG_CDKEY");
        DeleteLocalString(oObj, "RG_ACCOUNT");
    }

    FreelistPush(oArea, nSlot);

    // Update total count
    int nCount = GetLocalInt(oArea, RS_COUNT);
    if (nCount > 0) SetLocalInt(oArea, RS_COUNT, nCount - 1);

    // Update PC count and deactivate area if last PC leaves
    if (nRow >= 0 && GetLocalInt(oMod, RG_PFX + IntToString(nRow) + RGC_ISPC))
    {
        int nPC = GetLocalInt(oArea, RS_PC_COUNT) - 1;
        if (nPC < 0) nPC = 0;
        SetLocalInt(oArea, RS_PC_COUNT, nPC);

        // Deactivate when last player leaves
        if (nPC == 0)
        {
            // Stagger shutdown slightly - saves/cleanup can complete
            // before the area goes dark
            DelayCommand(3.0, RegistryShutdown(oArea));
            RegistryDeactivateArea(oArea);
        }
    }

    // Decrement presence counter
    PresenceUpdate(oArea, sPVar, -1);

    if (GetLocalInt(oMod, MG_DEBUG_REG))
        SendMessageToAllDMs("[REG-] slot=" + IntToString(nSlot) +
                            " area=" + GetTag(oArea));
}

void RegistryRemove(object oArea, object oObj)
{
    if (!GetIsObjectValid(oObj)) return;
    int nSlot = GetLocalInt(oObj, RG_SLOT_VAR);
    if (nSlot > 0) RegistryRemoveBySlot(oArea, nSlot);
}

// ============================================================================
// SECTION 11: AUTO-REGISTER
// Universal single entry point for all registration sources.
// Gates on AUTO_ENTER vs AUTO_SPAWN columns from the 2DA.
// ============================================================================

int RegistryAutoRegister(object oObj, object oArea, int bFromEnter,
                         int nOwnerSlot = 0)
{
    if (!GetIsObjectValid(oObj))  return 0;
    if (!GetIsObjectValid(oArea)) return 0;

    // Double-registration guard
    int nExist = GetLocalInt(oObj, RG_SLOT_VAR);
    if (nExist > 0)
    {
        if (GetLocalObject(oArea,
            RS_PFX + IntToString(nExist) + "_" + RSF_OBJ) == oObj)
            return nExist;
    }

    int nRow = RegistryClassify(oObj);
    if (nRow < 0) return 0;

    object oMod = GetModule();
    string sN   = RG_PFX + IntToString(nRow);

    // Gate by registration source
    if (bFromEnter  && !GetLocalInt(oMod, sN + RGC_AENT)) return 0;
    if (!bFromEnter && !GetLocalInt(oMod, sN + RGC_ASPW)) return 0;

    // Auto-resolve owner slot for associate types
    if (nOwnerSlot == 0 && GetLocalInt(oMod, sN + RGC_OWNER))
    {
        object oMaster = GetMaster(oObj);
        if (GetIsObjectValid(oMaster))
            nOwnerSlot = GetLocalInt(oMaster, RG_SLOT_VAR);
    }

    return RegistryAdd(oArea, oObj, nRow, nOwnerSlot);
}

// ============================================================================
// SECTION 12: QUERY API - all O(1)
// ============================================================================

object RegistryGetObj(object oArea, int nSlot)
{ return GetLocalObject(oArea, RS_PFX + IntToString(nSlot) + "_" + RSF_OBJ); }

// RegistryGetSlotFlag - returns the bitflag stored in a slot.
// Also exposed as RegistryGetFlag(oArea, nSlot) for API consistency.
int RegistryGetSlotFlag(object oArea, int nSlot)
{ return GetLocalInt(oArea, RS_PFX + IntToString(nSlot) + "_" + RSF_FLAG); }

// Alias kept for backward compatibility
int RegistryGetFlag(object oArea, int nSlot)
{ return RegistryGetSlotFlag(oArea, nSlot); }

int RegistryMatch(object oArea, int nSlot, int nFilter)
{ return (RegistryGetSlotFlag(oArea, nSlot) & nFilter) != 0; }

int RegistryGetCount(object oArea)
{ return GetLocalInt(oArea, RS_COUNT); }

int RegistryPCCount(object oArea)
{ return GetLocalInt(oArea, RS_PC_COUNT); }

string RegistryGetType(object oObj)
{ return GetLocalString(oObj, RG_TYPE_VAR); }

int RegistryGetOwnerSlot(object oArea, int nSlot)
{ return GetLocalInt(oArea, RS_PFX + IntToString(nSlot) + "_" + RSF_OWNER); }

int RegistryGetGridCell(object oArea, int nSlot)
{ return GetLocalInt(oArea, RS_PFX + IntToString(nSlot) + "_" + RSF_GRIDCELL); }

void RegistrySetGridCell(object oArea, int nSlot, int nCell)
{ SetLocalInt(oArea, RS_PFX + IntToString(nSlot) + "_" + RSF_GRIDCELL, nCell); }

// ============================================================================
// SECTION 13: ITERATION - token-based, nested-safe
// ============================================================================

string RegistryToken()
{
    object oMod = GetModule();
    int nT = GetLocalInt(oMod, "RG_TOKEN") + 1;
    SetLocalInt(oMod, "RG_TOKEN", nT);
    return IntToString(nT);
}

object RegistryFirst(object oArea, int nFilter, string sToken)
{
    int nMax = GetLocalInt(oArea, RS_MAX_SLOT);
    SetLocalInt(oArea, "RT_" + sToken + "_F", nFilter);

    int i;
    for (i = 1; i <= nMax; i++)
    {
        if (RegistryMatch(oArea, i, nFilter))
        {
            object oObj = RegistryGetObj(oArea, i);
            if (GetIsObjectValid(oObj))
            {
                SetLocalInt(oArea, "RT_" + sToken + "_S", i + 1);
                return oObj;
            }
        }
    }

    SetLocalInt(oArea, "RT_" + sToken + "_S", nMax + 1);
    return OBJECT_INVALID;
}

object RegistryNext(object oArea, string sToken)
{
    int nCur    = GetLocalInt(oArea, "RT_" + sToken + "_S");
    int nFilter = GetLocalInt(oArea, "RT_" + sToken + "_F");
    int nMax    = GetLocalInt(oArea, RS_MAX_SLOT);

    int i;
    for (i = nCur; i <= nMax; i++)
    {
        if (RegistryMatch(oArea, i, nFilter))
        {
            object oObj = RegistryGetObj(oArea, i);
            if (GetIsObjectValid(oObj))
            {
                SetLocalInt(oArea, "RT_" + sToken + "_S", i + 1);
                return oObj;
            }
        }
    }

    // Iteration complete - clean up
    DeleteLocalInt(oArea, "RT_" + sToken + "_S");
    DeleteLocalInt(oArea, "RT_" + sToken + "_F");
    return OBJECT_INVALID;
}

// ============================================================================
// SECTION 14: AREA INITIALIZATION
// One-time cold-boot scan. GetFirstObjectInArea is ONLY called here.
// ============================================================================

void RegistryInitArea(object oArea)
{
    if (!GetIsObjectValid(oArea)) return;
    if (GetLocalInt(oArea, RS_INIT)) return;
    SetLocalInt(oArea, RS_INIT, 1);

    object oObj = GetFirstObjectInArea(oArea);
    while (GetIsObjectValid(oObj))
    {
        if (GetLocalInt(oObj, RG_SLOT_VAR) == 0)
            RegistryAutoRegister(oObj, oArea, TRUE);
        oObj = GetNextObjectInArea(oArea);
    }

    if (GetLocalInt(GetModule(), MG_DEBUG_REG))
        SendMessageToAllDMs("[REGISTRY] Area init: " + GetTag(oArea) +
                            " count=" + IntToString(RegistryGetCount(oArea)));
}

// ============================================================================
// SECTION 15: MAINTENANCE
// ============================================================================

// RegistryClean: free ghost slots (invalid object refs) for types with RECLAIM_GHOST=1
void RegistryClean(object oArea)
{
    object oMod  = GetModule();
    int    nMax  = GetLocalInt(oArea, RS_MAX_SLOT);
    int    nFixed = 0;

    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx = RS_PFX + IntToString(i) + "_";
        int    nFlag = GetLocalInt(oArea, sPfx + RSF_FLAG);
        if (nFlag == 0) continue;

        object oObj = GetLocalObject(oArea, sPfx + RSF_OBJ);
        if (GetIsObjectValid(oObj)) continue;

        int nRow = GetLocalInt(oArea, sPfx + RSF_ROW);
        int bReclaim = (nRow >= 0) ?
            GetLocalInt(oMod, RG_PFX + IntToString(nRow) + RGC_GHOST) : 1;

        if (bReclaim)
        {
            RegistryRemoveBySlot(oArea, i);
            nFixed++;
        }
    }

    if (nFixed > 0 && GetLocalInt(oMod, MG_DEBUG_REG))
        SendMessageToAllDMs("[REGISTRY] Clean: " + IntToString(nFixed) +
                            " ghosts in " + GetTag(oArea));
}

// RegistryCull: expire objects whose EXPIRE_TICKS has elapsed
int RegistryCull(object oArea)
{
    object oMod  = GetModule();
    int    nTick = GetLocalInt(oMod, "MG_TICK");
    int    nMax  = GetLocalInt(oArea, RS_MAX_SLOT);
    int    nCull = 0;

    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx    = RS_PFX + IntToString(i) + "_";
        int    nExpire = GetLocalInt(oArea, sPfx + RSF_EXPIRE);
        if (nExpire == 0) continue;

        int nSpawn = GetLocalInt(oArea, sPfx + RSF_SPAWN);
        int nAge   = (nTick >= nSpawn) ? (nTick - nSpawn) :
                     (10000 - nSpawn + nTick);
        int nLife  = (nExpire >= nSpawn) ? (nExpire - nSpawn) :
                     (10000 - nSpawn + nExpire);

        if (nAge < nLife) continue;

        object oObj    = GetLocalObject(oArea, sPfx + RSF_OBJ);
        int    nRow    = GetLocalInt(oArea, sPfx + RSF_ROW);
        int    bDestroy = (nRow >= 0) ?
            GetLocalInt(oMod, RG_PFX + IntToString(nRow) + RGC_DCULL) : 0;

        if (GetIsObjectValid(oObj) && bDestroy)
            DestroyObject(oObj, 0.1);

        RegistryRemoveBySlot(oArea, i);
        nCull++;
    }

    return nCull;
}

// Void wrapper for RegistryCull - required for DelayCommand
void RegistryCull_Void(object oArea)
{
    RegistryCull(oArea);
}

// RegistryCheckDespawn: remove owned creatures that wandered too far from owner.
// Defined BEFORE RegistryCheckDespawn_Void - NWScript compiles top-down,
// the implementation must appear before any function that calls it.
int RegistryCheckDespawn(object oArea)
{
    int nMax  = GetLocalInt(oArea, RS_MAX_SLOT);
    int nDesp = 0;

    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx = RS_PFX + IntToString(i) + "_";
        float  fDist = GetLocalFloat(oArea, sPfx + RSF_DESPDIST);
        if (fDist <= 0.0) continue;

        object oObj = GetLocalObject(oArea, sPfx + RSF_OBJ);
        if (!GetIsObjectValid(oObj))
        {
            RegistryRemoveBySlot(oArea, i);
            continue;
        }

        int nOwner = GetLocalInt(oArea, sPfx + RSF_OWNER);
        if (nOwner == 0) continue;

        object oOwner = RegistryGetObj(oArea, nOwner);
        if (!GetIsObjectValid(oOwner) ||
            GetDistanceBetween(oObj, oOwner) > fDist)
        {
            DestroyObject(oObj, 0.1);
            RegistryRemoveBySlot(oArea, i);
            nDesp++;
        }
    }

    return nDesp;
}

// Void wrapper for RegistryCheckDespawn - required for DelayCommand.
// Placed AFTER the implementation above so the compiler sees it first.
void RegistryCheckDespawn_Void(object oArea)
{
    RegistryCheckDespawn(oArea);
}

// ============================================================================
// SECTION 16: SHUTDOWN
// Full area teardown to zero state. Called when last PC leaves (via delay).
// ============================================================================

void RegistryShutdown(object oArea)
{
    // Guard: a PC might have re-entered during the 3-second delay
    if (RegistryPCCount(oArea) > 0) return;

    object oMod  = GetModule();

    // Run package shutdown scripts first (saves state to SQL)
    PackageRunShutdownScripts(oArea);

    // Destroy all cullable objects
    int nComp = GetLocalInt(oMod, "RG_COMP_CULLABLE");
    string sTok = RegistryToken();
    object oObj = RegistryFirst(oArea, nComp, sTok);
    while (GetIsObjectValid(oObj))
    {
        DestroyObject(oObj, 0.1);
        oObj = RegistryNext(oArea, sTok);
    }

    // Clear area effects
    effect eEff = GetFirstEffect(oArea);
    while (GetIsEffectValid(eEff))
    {
        int nType = GetEffectType(eEff);
        if (nType == EFFECT_TYPE_VISUALEFFECT || nType == EFFECT_TYPE_AREA_OF_EFFECT)
            RemoveEffect(oArea, eEff);
        eEff = GetNextEffect(oArea);
    }

    // Wipe all slot data
    int nMax = GetLocalInt(oArea, RS_MAX_SLOT);
    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx = RS_PFX + IntToString(i) + "_";
        DeleteLocalObject(oArea, sPfx + RSF_OBJ);
        DeleteLocalInt(oArea,    sPfx + RSF_FLAG);
        DeleteLocalString(oArea, sPfx + RSF_TAG);
        DeleteLocalInt(oArea,    sPfx + RSF_SPAWN);
        DeleteLocalInt(oArea,    sPfx + RSF_EXPIRE);
        DeleteLocalFloat(oArea,  sPfx + RSF_DESPDIST);
        DeleteLocalInt(oArea,    sPfx + RSF_OWNER);
        DeleteLocalString(oArea, sPfx + RSF_CDKEY);
        DeleteLocalString(oArea, sPfx + RSF_ACCOUNT);
        DeleteLocalInt(oArea,    sPfx + RSF_GRIDCELL);
        DeleteLocalInt(oArea,    sPfx + RSF_ROW);
    }

    // Reset bookkeeping
    SetLocalInt(oArea, RS_FREE_HEAD, 0);
    SetLocalInt(oArea, RS_COUNT,     0);
    SetLocalInt(oArea, RS_PC_COUNT,  0);
    SetLocalInt(oArea, RS_MAX_SLOT,  0);
    DeleteLocalInt(oArea, RS_INIT);

    // Clear all presence counters
    int nRows = GetLocalInt(oMod, "RG_ROW_CNT");
    for (i = 0; i < nRows; i++)
    {
        string sPVar = GetLocalString(oMod, RG_PFX + IntToString(i) + RGC_PVAR);
        if (sPVar != "") DeleteLocalInt(oArea, sPVar);
    }

    // Unload package JSON
    PackageUnload(oArea);

    // Shut down grid
    GridShutdownArea(oArea);

    if (GetLocalInt(oMod, MG_DEBUG_REG))
        SendMessageToAllDMs("[REGISTRY] Shutdown: " + GetTag(oArea));
}

// ============================================================================
// SECTION 17: JSON SNAPSHOT (diagnostic)
// ============================================================================

string RegistryJsonSafe(string s)
{
    int i;
    string sOut = "";
    int nLen = GetStringLength(s);
    for (i = 0; i < nLen; i++)
    {
        string c = GetSubString(s, i, 1);
        if (c == "\"") c = "'";
        if (c == "\\") c = "/";
        sOut += c;
    }
    return sOut;
}

void RegistryPackJson_Phase(object oArea, int nStart, string sJson)
{
    int nMax = GetLocalInt(oArea, RS_MAX_SLOT);
    int nEnd = nStart + 49;
    if (nEnd > nMax) nEnd = nMax;

    int i;
    for (i = nStart; i <= nEnd; i++)
    {
        string sPfx = RS_PFX + IntToString(i) + "_";
        int    nFlag = GetLocalInt(oArea, sPfx + RSF_FLAG);
        if (nFlag == 0) continue;

        object oObj = GetLocalObject(oArea, sPfx + RSF_OBJ);
        if (!GetIsObjectValid(oObj)) continue;

        string sType = GetLocalString(oObj, RG_TYPE_VAR);
        string sCK   = GetLocalString(oArea, sPfx + RSF_CDKEY);
        string sAC   = GetLocalString(oArea, sPfx + RSF_ACCOUNT);

        if (sJson != "") sJson += ",";
        sJson += "{\"slot\":" + IntToString(i) +
                 ",\"tag\":\"" + RegistryJsonSafe(GetTag(oObj)) + "\"" +
                 ",\"type\":\"" + sType + "\"" +
                 ",\"flags\":" + IntToString(nFlag);
        if (sCK != "") sJson += ",\"cdkey\":\"" + RegistryJsonSafe(sCK) + "\"";
        if (sAC != "") sJson += ",\"account\":\"" + RegistryJsonSafe(sAC) + "\"";
        sJson += "}";
    }

    if (nEnd < nMax)
    {
        DelayCommand(0.1, RegistryPackJson_Phase(oArea, nEnd + 1, sJson));
    }
    else
    {
        int nTick = GetLocalInt(GetModule(), "MG_TICK");
        sJson = "{\"area\":\"" + RegistryJsonSafe(GetTag(oArea)) + "\"" +
                ",\"tick\":" + IntToString(nTick) +
                ",\"count\":" + IntToString(RegistryGetCount(oArea)) +
                ",\"entries\":[" + sJson + "]}";
        SetLocalString(oArea, "RG_JSON_SNAP", sJson);
    }
}

void RegistryPackJson(object oArea)
{ RegistryPackJson_Phase(oArea, 1, ""); }

// ============================================================================
// SECTION 18: DM DIAGNOSTICS
// ============================================================================

void RegistryDump(object oArea, object oTarget)
{
    object oMod  = GetModule();
    int    nRows = GetLocalInt(oMod, "RG_ROW_CNT");
    int    nMax  = GetLocalInt(oArea, RS_MAX_SLOT);

    SendMessageToPC(oTarget, "=== REGISTRY: " + GetTag(oArea) +
        "  total=" + IntToString(RegistryGetCount(oArea)) +
        "  PCs=" + IntToString(RegistryPCCount(oArea)) + " ===");

    int i;
    for (i = 0; i < nRows; i++)
    {
        string sPVar  = GetLocalString(oMod, RG_PFX + IntToString(i) + RGC_PVAR);
        string sStamp = GetLocalString(oMod, RG_PFX + IntToString(i) + RGC_STAMP);
        if (sPVar == "") continue;

        int nPresence = GetLocalInt(oArea, sPVar);
        if (nPresence > 0)
            SendMessageToPC(oTarget, "  " + sStamp + ": " + IntToString(nPresence));
    }

    SendMessageToPC(oTarget, "  MaxSlot=" + IntToString(nMax) +
        "  FreeHead=" + IntToString(GetLocalInt(oArea, RS_FREE_HEAD)));
}

void RegistryDumpSlot(object oArea, int nSlot, object oTarget)
{
    string sPfx  = RS_PFX + IntToString(nSlot) + "_";
    int    nFlag = GetLocalInt(oArea, sPfx + RSF_FLAG);
    if (nFlag == 0)
    {
        SendMessageToPC(oTarget, "Slot " + IntToString(nSlot) + ": empty");
        return;
    }

    object oObj  = GetLocalObject(oArea, sPfx + RSF_OBJ);
    string sType = GetLocalString(oObj, RG_TYPE_VAR);
    int    nRow  = GetLocalInt(oArea, sPfx + RSF_ROW);
    int    nExp  = GetLocalInt(oArea, sPfx + RSF_EXPIRE);
    float  fDist = GetLocalFloat(oArea, sPfx + RSF_DESPDIST);
    int    nOwn  = GetLocalInt(oArea, sPfx + RSF_OWNER);

    SendMessageToPC(oTarget,
        "Slot " + IntToString(nSlot) + ": [" + sType + "] " +
        (GetIsObjectValid(oObj) ? GetTag(oObj) : "INVALID") +
        "  row=" + IntToString(nRow) +
        "  expire=" + IntToString(nExp) +
        "  despawn=" + FloatToString(fDist, 0, 1) +
        "  owner=" + IntToString(nOwn));
}
