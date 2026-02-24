/* ============================================================================
    core_ai_gps.nss
    GPS Proximity System - Grid-Accelerated
    Standard: Production Hardened (DOWE v2.3)

    PURPOSE:
    Manages creature Sleep/Wake states and Despawn based on player proximity.
    Uses O(1) Grid cell lookups to eliminate search lag.

    ============================================================================
    SESSION 7 FEATURES ADDED
    ============================================================================
    GHOST MODE (/*vanish "pass"):
      Admin DMs can toggle MG_GHOST = 1 on their PC object.
      GpsTick() skips any PC with MG_GHOST = 1 in the player loop.
      NPCs in sleep state never wake for a vanished admin.
      NPCs already awake continue AI normally (other players still present).
      Use case: Observe AI behavior in natural sleep state without disturbing it.
      Command: /*vanish "password"  (Role 1+ / Moderator)

    GPS PHASE-SHIFT:
      Each tick, the area's GPS_HALF flag toggles between 0 and 1.
      Odd registry slots (1,3,5...) are scanned on GPS_HALF=0 ticks.
      Even registry slots (2,4,6...) are scanned on GPS_HALF=1 ticks.
      Result: ~50% CPU reduction per tick. NPCs respond within ~12s instead
      of 6s (one extra tick latency). Effective NPC capacity roughly doubles.
      To disable: Remove the (nSlot % 2) != nGpsHalf check below.

    SESSION 8 FIXES:
      RF_ALL_CREATURES replaced with RegistryFlagCreatures() so adding new
      creature types to core_registry.2da automatically includes them in GPS.
   ============================================================================
*/

#include "core_conductor"
#include "core_registry"
#include "core_grid"

// ============================================================================
// CONSTANTS
// ============================================================================

const string GPS_2DA = "core_ai_gps";

const int AI_STATE_ACTIVE  = 0;
const int AI_STATE_SLEEP   = 1;
const int AI_STATE_DESPAWN = 2;

const int XFER_PRI_NEAREST = 0;
const int XFER_PRI_LOW_HP  = 1;
const int XFER_PRI_HIGH_HP = 2;
const int XFER_PRI_RANDOM  = 3;

// Slot suffix matches in core_registry.nss
const string AI_SLEEP_DIST  = "AI_SLP";
const string AI_DESP_DIST   = "AI_DSP";
const string AI_DESP_OWNER  = "AI_DSO";
const string AI_TRANSFER    = "AI_XFR";
const string AI_STATE_VAR   = "AI_ST";

const string GPS_PFX              = "GPS_CFG_";
const string GPS_KEY_SLEEP_DIST   = "DEFAULT_SLEEP_DIST";
const string GPS_KEY_DESP_DIST    = "DEFAULT_DESP_DIST";
const string GPS_KEY_OWNER_DIST   = "DEFAULT_OWNER_DIST";
const string GPS_KEY_CANTEEN_INT  = "CANTEEN_REFILL_INTERVAL";
const string GPS_KEY_BOOTED       = "BOOTED";

// ============================================================================
// SECTION 1: BOOT
// ============================================================================

void GpsBoot()
{
    object oMod = GetModule();
    if (GetLocalInt(oMod, GPS_PFX + GPS_KEY_BOOTED)) return;
    SetLocalInt(oMod, GPS_PFX + GPS_KEY_BOOTED, 1);

    int nRows = Get2DARowCount(GPS_2DA);
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sKey    = Get2DAString(GPS_2DA, "KEY",         i);
        float  fFltVal = StringToFloat(Get2DAString(GPS_2DA, "FLOAT_VALUE", i));
        int    nIntVal = StringToInt(Get2DAString(GPS_2DA,   "INT_VALUE",   i));
        SetLocalFloat(oMod, GPS_PFX + sKey, fFltVal);
        SetLocalInt(oMod,   GPS_PFX + sKey, nIntVal);
    }
}

// ============================================================================
// SECTION 2: HELPERS
// ============================================================================

float FastDistSq(vector vA, vector vB)
{
    float dx = vA.x - vB.x; float dy = vA.y - vB.y; float dz = vA.z - vB.z;
    return (dx*dx) + (dy*dy) + (dz*dz);
}

int IsOwnerValid(object oOwner, object oCreature)
{
    if (!GetIsObjectValid(oOwner) || GetIsDead(oOwner) || GetArea(oOwner) != GetArea(oCreature)) return FALSE;
    return TRUE;
}

void RefillWaterContainers(object oPC)
{
    object oItem = GetFirstItemInInventory(oPC);
    while (GetIsObjectValid(oItem))
    {
        if (GetLocalInt(oItem, "MG_IS_CANTEEN"))
        {
            int nMax = GetLocalInt(oItem, "MG_WATER_MAX");
            if (nMax <= 0) nMax = 5;
            if (GetLocalInt(oItem, "MG_WATER_CHARGES") < nMax)
            {
                SetLocalInt(oItem, "MG_WATER_CHARGES", nMax);
                SetLocalInt(oItem, "MG_WATER_DIRTY", 0);
                SendMessageToPC(oPC, "*Water Source: Refilled " + GetName(oItem) + "*");
            }
        }
        oItem = GetNextItemInInventory(oPC);
    }
}

// ============================================================================
// SECTION 3: TRANSFER RESOLUTION
// Standard: Registry-driven (No illegal array parameters)
// ============================================================================

object FindBestTransferTarget(vector vCreature, float fMaxRange, int nPriority, object oArea)
{
    float fMaxRangeSq = fMaxRange * fMaxRange;
    object oBest      = OBJECT_INVALID;
    float  fBestVal   = 0.0;

    string sTok = RegistryToken();
    object oPC  = RegistryFirst(oArea, RF_PLAYER, sTok);
    while (GetIsObjectValid(oPC))
    {
        float fDSq = FastDistSq(vCreature, GetPosition(oPC));
        if (fDSq <= fMaxRangeSq)
        {
            switch (nPriority)
            {
                case XFER_PRI_NEAREST:
                    if (oBest == OBJECT_INVALID || fDSq < fBestVal) { fBestVal = fDSq; oBest = oPC; }
                    break;
                case XFER_PRI_LOW_HP:
                    float fHP = IntToFloat(GetCurrentHitPoints(oPC));
                    if (oBest == OBJECT_INVALID || fHP < fBestVal) { fBestVal = fHP; oBest = oPC; }
                    break;
            }
        }
        oPC = RegistryNext(oArea, sTok);
    }
    return oBest;
}

// ============================================================================
// SECTION 4: MAIN GPS TICK
// Called by pkg_ai_gps.nss (the package event script).
// core_ai_gps.nss is a LIBRARY - it has no void main().
// pkg_ai_gps.nss is the thin event wrapper that core_package.2da points to.
// ============================================================================

void GpsTick(object oArea)
{
    object oMod  = GetModule();
    int nTick    = GetLocalInt(GetModule(), MG_TICK);

    float fSleep = GetLocalFloat(oMod, GPS_PFX + GPS_KEY_SLEEP_DIST);
    float fDesp  = GetLocalFloat(oMod, GPS_PFX + GPS_KEY_DESP_DIST);
    float fOwn   = GetLocalFloat(oMod, GPS_PFX + GPS_KEY_OWNER_DIST);
    if (fSleep <= 0.0) fSleep = 40.0; if (fDesp <= 0.0) fDesp = 80.0;

    // Phase-shift: alternate which half of registry slots are scanned each tick.
    // Tick A: odd slots (1,3,5...). Tick B: even slots (2,4,6...).
    // Result: 50% CPU reduction per tick, 12s NPC reaction time (vs 6s without).
    // To disable: remove the (nSlot % 2) != nGpsHalf check in the inner loop.
    int nGpsHalf = GetLocalInt(oArea, "GPS_HALF");
    SetLocalInt(oArea, "GPS_HALF", nGpsHalf ? 0 : 1);

    // 1. Process each Player's Neighborhood
    string sPCTok = RegistryToken();
    object oPC = RegistryFirst(oArea, RF_PLAYER, sPCTok);
    while (GetIsObjectValid(oPC))
    {
        // Ghost Mode: Skip this PC entirely if they are in admin ghost mode.
        // NPCs in sleep state will never wake for a ghosted admin.
        // NPCs already awake (from other nearby players) continue normally.
        if (GetLocalInt(oPC, "MG_GHOST"))
        {
            oPC = RegistryNext(oArea, sPCTok);
            continue;
        }

        vector vPC = GetPosition(oPC);
        int nCell = GridPosToCell(oArea, vPC);

        // Water Source Check
        if (GridIsNearWater(oArea, vPC)) RefillWaterContainers(oPC);

        // Neighborhood Scan
        int nNeighCount = GridGetNeighborCells(oArea, nCell);
        int ni; for (ni = 0; ni < nNeighCount; ni++)
        {
            int nNeigh = GetLocalInt(oMod, "GRD_NC_" + IntToString(ni));
            int nSlotCount = GridCellGetCount(oArea, nNeigh);
            int si; for (si = 0; si < nSlotCount; si++)
            {
                int nSlot = GridCellGetSlot(oArea, nNeigh, si);

                // Phase-shift: only process slots in this tick's half
                if ((nSlot % 2) != nGpsHalf) continue;

                // Only process creature-type registry slots
                if (!(RegistryGetSlotFlag(oArea, nSlot) & RegistryFlagCreatures())) continue;

                object oCreature = RegistryGetObj(oArea, nSlot);
                if (!GetIsObjectValid(oCreature) || GetLocalInt(oCreature, "GPS_TICK") == nTick) continue;
                SetLocalInt(oCreature, "GPS_TICK", nTick);

                string sPfx = RS_PFX + IntToString(nSlot) + "_";
                vector vC = GetPosition(oCreature);
                float fDSq = FastDistSq(vC, vPC);

                // State Management
                int nNewState = AI_STATE_SLEEP;
                if (fDSq <= (fSleep * fSleep))
                {
                    nNewState = AI_STATE_ACTIVE;
                    if (GetLocalInt(oCreature, "AI_ST") == AI_STATE_SLEEP) {
                        effect eLoop = GetFirstEffect(oCreature);
                        while (GetIsEffectValid(eLoop))
                        {
                            if (GetEffectType(eLoop) == EFFECT_TYPE_SLEEP) RemoveEffect(oCreature, eLoop);
                            eLoop = GetNextEffect(oCreature);
                        }
                    }
                }
                else if (fDSq > (fDesp * fDesp) && !GetPlotFlag(oCreature))
                {
                    DestroyObject(oCreature, 0.1); RegistryRemoveBySlot(oArea, nSlot); continue;
                }

                SetLocalInt(oCreature, "AI_ST", nNewState);
                SetLocalInt(oArea, sPfx + AI_STATE_VAR, nNewState);
            }
        }
        oPC = RegistryNext(oArea, sPCTok);
    }

    // Debug output (two-level gate: master debug AND GPS debug)
    if (GetLocalInt(oMod, MG_DEBUG) && GetLocalInt(oMod, MG_DEBUG_GPS))
        SendMessageToAllDMs("[GPS] Area=" + GetTag(oArea) + " T=" + IntToString(nTick) +
                            " Half=" + IntToString(nGpsHalf));
}
