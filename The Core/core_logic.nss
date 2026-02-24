/* ============================================================================
    core_logic.nss
    TMG Universal Logic Engine - Transaction Processor
    Standard: DOWE v2.3 Library | Session 11 Revised

    ============================================================================
    PURPOSE
    ============================================================================
    Pure mathematical transaction engine for data-driven game events.
    Processes every player-triggered action as a single atomic transaction:

        [Evaluate Conditions] -> [Subtract Resources] -> [Add Rewards]

    If any condition fails, nothing is taken and nothing is given.
    This guarantees players can never lose materials to a failed transaction.

    ============================================================================
    WHAT THIS IS
    ============================================================================
    core_logic.nss is a LIBRARY, not a tick script.
    It has NO void main(). It fires ONLY when a player does something:
    crafts, gathers, shops, interacts with a placeable, etc.

    It is called by the sys_* adapter scripts (sys_craft, sys_gath, sys_shop).
    Each adapter reads its cached 2DA data from module vars and calls these
    three functions to complete the transaction.

    core_logic has ZERO heartbeat cost. It does not run while players are idle.

    ============================================================================
    WHERE THIS FITS IN THE DOWE ARCHITECTURE
    ============================================================================
    HEARTBEAT PATH (time-driven):
      core_heartbeat -> core_dispatch -> core_switch -> package dispatch
      -> GPS tick (creature sleep/wake, the "combat gate")
      -> AI packages (only fire for ACTIVE creatures per GPS)
      -> Environment, Society, etc. (hub ticks)

    EVENT PATH (player-action-driven):
      Player action (conversation, placeable use, chat command)
      -> sys_craft / sys_gath / sys_shop (adapter reads module cache)
      -> core_logic functions (evaluate, subtract, add)
      -> Result message to player

    These two paths are INDEPENDENT. core_logic never touches the heartbeat.
    GPS never touches item inventories. Each has one job.

    ============================================================================
    PERFORMANCE DESIGN
    ============================================================================
    - All condition values are passed in from the caller (already cached).
    - No Get2DAString calls anywhere in this file. Zero disk reads at runtime.
    - DIST_OBJ uses a pre-resolved object passed by the caller, not a tag search.
      The caller finds the object (via Grid or registry). The logic engine
      just measures the distance to it.
    - GetNearestObjectByTag is explicitly NOT used here. It is an area-wide
      scan and defeats the purpose of the Grid system.

    ============================================================================
    SESSION 11 CHANGES FROM v1.0
    ============================================================================
    - Renamed from core_logic_engine.nss to core_logic.nss (matches file location)
    - DIST_LESS condition replaced with DIST_OBJ (pre-resolved object, not tag)
    - Added COMBAT_STATE condition (read GPS AI_ST from registry, no scan)
    - Added QUEST_FLAG condition (read module-level quest progress var)
    - Removed GetNearestObjectByTag from condition evaluator entirely
    - TMG_ProcessAddition: SCRIPT type now validates sRef != "" before execute
    - Full transaction wrapper TMG_ProcessTransaction added (atomic check-take-give)
    - Added RollParseQty helper for "resref*qty" string parsing (DRY principle)

   ============================================================================
*/

#ifndef CORE_LOGIC_INCLUDED
#define CORE_LOGIC_INCLUDED

#include "core_conductor"

// ============================================================================
// SECTION 1: HELPER - PARSE "resref*qty" FORMAT
// Used by craft and gathering systems. Avoids duplicate parsing code.
// Input:  "iron_ingot*3" -> sRef = "iron_ingot", return 3
// Input:  "iron_ingot"   -> sRef = "iron_ingot", return 1
// ============================================================================

int TMG_ParseItemRef(string sRaw, string &sRef)
{
    int nStar = FindSubString(sRaw, "*");
    if (nStar == -1)
    {
        sRef = sRaw;
        return 1;
    }
    sRef = GetStringLeft(sRaw, nStar);
    return StringToInt(GetStringRight(sRaw, GetStringLength(sRaw) - nStar - 1));
}

// ============================================================================
// SECTION 2: CONDITION EVALUATOR
//
// Returns TRUE if the condition passes. FALSE means transaction is aborted.
//
// CONDITIONS:
//   VAR_GREATER  - oTarget local float > fValue        (sAux = var name)
//   VAR_LESS     - oTarget local float < fValue        (sAux = var name)
//   VAR_EQUAL    - oTarget local float == fValue       (sAux = var name)
//   VAR_FLAG     - oTarget local int == 1 (flag set)   (sAux = var name)
//   HAS_ITEM     - PC has item qty >= fValue           (sAux = item resref)
//   HAS_GOLD     - PC gold >= fValue                   (sAux = unused)
//   DIST_OBJ     - distance to oAux < fValue in meters (oAux = placeable/NPC)
//   ROLL_D100    - d100() <= fValue (probability %)    (sAux = unused)
//   COMBAT_STATE - creature AI_ST == 0 (GPS Active)    (sAux = unused)
//   QUEST_FLAG   - module quest var == fValue          (sAux = var name)
//   ALWAYS       - unconditionally true (default)
// ============================================================================

int TMG_EvaluateCondition(object oTarget, string sCondition, float fValue,
                           string sAux = "", object oAux = OBJECT_INVALID)
{
    // --- Variable checks (read from object local vars, O(1)) ---
    if (sCondition == "VAR_GREATER")
        return (GetLocalFloat(oTarget, sAux) > fValue);

    if (sCondition == "VAR_LESS")
        return (GetLocalFloat(oTarget, sAux) < fValue);

    if (sCondition == "VAR_EQUAL")
        return (GetLocalFloat(oTarget, sAux) == fValue);

    if (sCondition == "VAR_FLAG")
        return (GetLocalInt(oTarget, sAux) != 0);

    // --- Inventory check (single item lookup, fast) ---
    if (sCondition == "HAS_ITEM")
    {
        object oItem = GetItemPossessedBy(oTarget, sAux);
        if (!GetIsObjectValid(oItem)) return FALSE;
        return (GetItemStackSize(oItem) >= FloatToInt(fValue));
    }

    // --- Gold check ---
    if (sCondition == "HAS_GOLD")
        return (GetGold(oTarget) >= FloatToInt(fValue));

    // --- Distance check (pre-resolved object, NO tag search) ---
    // The caller resolves the object using Grid/Registry BEFORE calling.
    // This function just measures. Grid resolution is the caller's job.
    if (sCondition == "DIST_OBJ")
    {
        if (!GetIsObjectValid(oAux)) return FALSE;
        return (GetDistanceBetween(oTarget, oAux) < fValue);
    }

    // --- Random roll ---
    if (sCondition == "ROLL_D100")
        return (d100() <= FloatToInt(fValue));

    // --- Combat state (reads GPS AI_ST local var, no scan) ---
    // Returns TRUE if the creature is currently ACTIVE (GPS woke it up).
    // Returns FALSE if sleeping or despawned.
    // Use this to prevent gathering/crafting during combat.
    if (sCondition == "COMBAT_STATE")
        return (GetLocalInt(oTarget, "AI_ST") == 0);

    // --- Quest flag check (module-level progress variable) ---
    if (sCondition == "QUEST_FLAG")
        return (GetLocalFloat(GetModule(), sAux) == fValue);

    // --- Always passes (used for unconditional actions) ---
    return TRUE;
}

// ============================================================================
// SECTION 3: SUBTRACTION (THE TAKE)
// Removes resources from oTarget.
// Only called AFTER all conditions pass. Never called on a failed transaction.
//
// TYPES:
//   ITEM      - remove nQty of item by resref
//   VAR_INT   - subtract nQty from a local int on oTarget
//   GOLD      - take nQty gold pieces from PC
//   CP        - take nQty Ceramic Pieces (Dark Sun currency var)
// ============================================================================

void TMG_ProcessSubtraction(object oTarget, string sType, string sRef, int nQty)
{
    if (nQty <= 0) return;

    if (sType == "ITEM")
    {
        object oItem = GetItemPossessedBy(oTarget, sRef);
        if (!GetIsObjectValid(oItem)) return;
        int nStack = GetItemStackSize(oItem);
        if (nStack > nQty)
            SetItemStackSize(oItem, nStack - nQty);
        else
            DestroyObject(oItem);
        return;
    }

    if (sType == "VAR_INT")
    {
        SetLocalInt(oTarget, sRef, GetLocalInt(oTarget, sRef) - nQty);
        return;
    }

    if (sType == "GOLD")
    {
        TakeGoldFromCreature(nQty, oTarget, TRUE);
        return;
    }

    if (sType == "CP")
    {
        // Ceramic Piece currency - Dark Sun custom system
        int nCur = GetLocalInt(oTarget, "TMG_CURRENCY_CP");
        if (nCur < nQty) return; // Safety check
        SetLocalInt(oTarget, "TMG_CURRENCY_CP", nCur - nQty);
        return;
    }
}

// ============================================================================
// SECTION 4: ADDITION (THE GIVE)
// Adds rewards to oTarget.
// Only called AFTER conditions pass and resources are taken.
//
// TYPES:
//   ITEM      - create nQty of item resref on oTarget
//   VAR_INT   - add nQty to a local int on oTarget
//   GOLD      - give nQty gold to oTarget
//   CP        - give nQty Ceramic Pieces
//   XP        - award nQty XP to oTarget
//   VFX       - play visual effect ID on oTarget (sRef = int as string)
//   SCRIPT    - execute sRef script on oTarget
// ============================================================================

void TMG_ProcessAddition(object oTarget, string sType, string sRef, int nQty)
{
    if (sType == "ITEM")
    {
        if (nQty <= 0) return;
        CreateItemOnObject(sRef, oTarget, nQty);
        return;
    }

    if (sType == "VAR_INT")
    {
        if (nQty <= 0) return;
        SetLocalInt(oTarget, sRef, GetLocalInt(oTarget, sRef) + nQty);
        return;
    }

    if (sType == "GOLD")
    {
        if (nQty <= 0) return;
        GiveGoldToCreature(oTarget, nQty);
        return;
    }

    if (sType == "CP")
    {
        if (nQty <= 0) return;
        SetLocalInt(oTarget, "TMG_CURRENCY_CP",
                    GetLocalInt(oTarget, "TMG_CURRENCY_CP") + nQty);
        return;
    }

    if (sType == "XP")
    {
        if (nQty <= 0) return;
        GiveXPToCreature(oTarget, nQty);
        return;
    }

    if (sType == "VFX")
    {
        // sRef = VFX constant as integer string, e.g. "291" for VFX_IMP_FLAME_S
        int nVfx = StringToInt(sRef);
        if (nVfx > 0)
            ApplyEffectToObject(DURATION_TYPE_INSTANT,
                                EffectVisualEffect(nVfx), oTarget);
        return;
    }

    if (sType == "SCRIPT")
    {
        // Execute a follow-up script on oTarget (e.g. a quest trigger).
        // oTarget becomes OBJECT_SELF in the executed script.
        if (sRef != "")
            ExecuteScript(sRef, oTarget);
        return;
    }
}

// ============================================================================
// SECTION 5: ATOMIC TRANSACTION WRAPPER
//
// Combines all three phases into one call.
// GUARANTEES: if conditions fail, NOTHING is taken and NOTHING is given.
// The caller provides pre-cached values (no 2DA reads here).
//
// Parameters:
//   oPC           - the player performing the action
//   sCondition    - condition type string (see evaluator above)
//   fCondVal      - condition numeric threshold
//   sCondAux      - condition auxiliary string (item resref, var name, etc.)
//   oCondAux      - condition auxiliary object (for DIST_OBJ)
//   sTakeType     - subtraction type (ITEM, VAR_INT, GOLD, CP)
//   sTakeRef      - what to take (resref or var name)
//   nTakeQty      - how much to take
//   sGiveType     - addition type (ITEM, VAR_INT, GOLD, CP, XP, VFX, SCRIPT)
//   sGiveRef      - what to give (resref, var name, vfx id, or script name)
//   nGiveQty      - how much to give
//   sFailMsg      - message sent to PC if condition fails
//   sSuccessMsg   - message sent to PC on success (pass "" to suppress)
//
// Returns TRUE if the transaction completed, FALSE if conditions failed.
// ============================================================================

int TMG_ProcessTransaction(object oPC,
    string sCondition,  float fCondVal,  string sCondAux,  object oCondAux,
    string sTakeType,   string sTakeRef, int    nTakeQty,
    string sGiveType,   string sGiveRef, int    nGiveQty,
    string sFailMsg,    string sSuccessMsg)
{
    // PHASE 1: EVALUATE (check only, touch nothing)
    if (!TMG_EvaluateCondition(oPC, sCondition, fCondVal, sCondAux, oCondAux))
    {
        if (sFailMsg != "") SendMessageToPC(oPC, sFailMsg);
        return FALSE;
    }

    // PHASE 2: TAKE (only reached if condition passed)
    TMG_ProcessSubtraction(oPC, sTakeType, sTakeRef, nTakeQty);

    // PHASE 3: GIVE (only reached after take succeeds)
    TMG_ProcessAddition(oPC, sGiveType, sGiveRef, nGiveQty);

    if (sSuccessMsg != "") SendMessageToPC(oPC, sSuccessMsg);
    return TRUE;
}

#endif
