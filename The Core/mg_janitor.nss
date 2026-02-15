/* ============================================================================
    DOWE v2.2 - mg_janitor.nss
    Player Exit Handler
   ============================================================================
*/

#include "mg_manifest"
#include "mg_sql"
#include "mg_const"  // FIXED: Added this include!

void main()
{
    object oPC = OBJECT_SELF;
    object oArea = GetArea(oPC);

    if (!GetIsPC(oPC)) return;

    int nSlot = GetLocalInt(oPC, M_OBJ_SLOT);

    // Save player data
    SQLSavePC(oPC);

    // Handle creature ownership transfer
    object oCreat = ManifestFirst(oArea, MF_CREATURE, "JANITOR_CRIT");
    int nTrans = 0;
    int nDesp = 0;

    while (GetIsObjectValid(oCreat))
    {
        string sPfx = M_SLOT_PFX + IntToString(GetLocalInt(oCreat, M_OBJ_SLOT)) + "_";
        int nOwner = GetLocalInt(oArea, sPfx + M_OWNER);

        if (nOwner == nSlot)
        {
            // Find nearest remaining player
            object oTarget = OBJECT_INVALID;
            float fNear = 999.0;

            object oIter = ManifestFirst(oArea, MF_PLAYER, "JANITOR_PC");
            while (GetIsObjectValid(oIter))
            {
                if (oIter != oPC)
                {
                    float fDist = GetDistanceBetween(oCreat, oIter);
                    if (fDist < MG_TRANSFER_RADIUS && fDist < fNear)  // FIXED: Now defined!
                    {
                        oTarget = oIter;
                        fNear = fDist;
                    }
                }
                oIter = ManifestNext(oArea, "JANITOR_PC");
            }

            if (GetIsObjectValid(oTarget))
            {
                // Transfer ownership
                int nNew = GetLocalInt(oTarget, M_OBJ_SLOT);
                SetLocalInt(oArea, sPfx + M_OWNER, nNew);
                nTrans++;
            }
            else
            {
                // No one nearby, despawn
                DestroyObject(oCreat, 0.5);
                ManifestRemove(oArea, oCreat);
                nDesp++;
            }
        }

        oCreat = ManifestNext(oArea, "JANITOR_CRIT");
    }

    // Remove player from manifest
    ManifestRemove(oArea, oPC);

    // Check if area is empty
    int nRemain = ManifestPCCount(oArea);

    if (nRemain == 0)
    {
        // ZERO-WASTE: Complete shutdown
        ManifestShutdown(oArea);

        if (GetMGDebug())
        {
            SendMessageToAllDMs("JANITOR: " + GetTag(oArea) + " shutdown (zero players)");
        }
    }
    else if (GetMGDebug())
    {
        SendMessageToAllDMs("JANITOR: " + GetName(oPC) + " exited | " +
                           "Transferred=" + IntToString(nTrans) + " " +
                           "Despawned=" + IntToString(nDesp) + " " +
                           "Remaining=" + IntToString(nRemain));
    }
}
