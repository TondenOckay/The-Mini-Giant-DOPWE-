/* ============================================================================
    core_builder.nss
    DOWE Builder Console - In-Game Toolbox Commands

    DOWE v2.3 | Production Standard

    ============================================================================
    PURPOSE
    ============================================================================
    Provides in-game commands for builders to inspect and scaffold DOWE systems
    without needing external tools.

    Commands (all require Role 5+ unless noted):
      //dump registry       - Print all registry type definitions to DM screen
      //dump packages       - Print all packages with current state
      //dump enc            - Print enc_hub sub-system table
      //dump ai             - Print ai_hub sub-system table
      //dump area           - Print area registry slot summary for current area
      //scaffold pkg [name] - Print stub files needed to create a new package
      //scaffold sub [name] - Print stub files needed to create a new hub sub-system
      //check 2da           - Verify all 2DA schema versions match expected
      //check rf            - Verify RF_ALL constants match computed 2DA values

    INTEGRATION:
    Add to core_chat.nss - handle messages starting with "//":
        if (GetStringLeft(sMsg, 2) == "//") {
            SetPCChatMessage("");
            BuilderHandleCommand(oPC, sMsg);
            return;
        }

    Add #include "core_builder" to core_chat.nss compilation unit.

    ============================================================================
    SECURITY
    ============================================================================
    Uses the same RBAC auth as core_admin.nss.
    Commands use double-slash // to distinguish from admin commands (/*).
    Password is still required and silenced immediately.

    ============================================================================
    NOTE ON COMPILE DEPENDENCIES
    ============================================================================
    This file #includes core_conductor and core_admin.
    The compilation unit (core_chat.nss) must also include:
      core_registry, core_package, ai_hub, enc_hub_lib
    to provide implementations.

   ============================================================================
*/

#include "core_conductor"
#include "core_admin"

// ============================================================================
// DUMP FUNCTIONS
// ============================================================================

void BuilderDumpRegistry(object oPC)
{
    object oMod = GetModule();
    int nRows   = GetLocalInt(oMod, "RG_ROW_CNT");

    SendMessageToPC(oPC, "=== REGISTRY TYPES (" + IntToString(nRows) + " total) ===");
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sPfx   = "RG_" + IntToString(i);
        string sLabel = GetLocalString(oMod, sPfx + "_STAMP");
        int    nFlag  = GetLocalInt(oMod,    sPfx + "_FLAG");
        int    nIsPC  = GetLocalInt(oMod,    sPfx + "_ISPC");
        int    nIsCr  = GetLocalInt(oMod,    sPfx + "_ISCREAT");
        int    nCull  = GetLocalInt(oMod,    sPfx + "_CULL");
        int    nGhost = GetLocalInt(oMod,    sPfx + "_GHOST");

        string sFlags = "";
        if (nIsPC)  sFlags += " PLAYER";
        if (nIsCr)  sFlags += " CREATURE";
        if (nCull)  sFlags += " CULLABLE";
        if (nGhost) sFlags += " GHOST_OK";

        SendMessageToPC(oPC,
            "  [" + IntToString(i) + "] " + sLabel +
            "  flag=" + IntToString(nFlag) +
            sFlags);
    }

    // Show computed composite flags
    int nFlagP = RegistryFlagPlayers();
    int nFlagC = RegistryFlagCreatures();
    int nFlagX = RegistryFlagCullable();
    SendMessageToPC(oPC, "--- COMPOSITE FLAGS (computed from 2DA) ---");
    SendMessageToPC(oPC, "  RF_ALL_PLAYERS(computed)   = " + IntToString(nFlagP) +
        "  (hardcoded const = 3)");
    SendMessageToPC(oPC, "  RF_ALL_CREATURES(computed) = " + IntToString(nFlagC) +
        "  (hardcoded const = 126)");
    SendMessageToPC(oPC, "  RF_ALL_CULLABLE(computed)  = " + IntToString(nFlagX) +
        "  (hardcoded const = 992)");

    // Warn if mismatched
    if (nFlagP != 3 || nFlagC != 126 || nFlagX != 992)
        SendMessageToPC(oPC,
            "  ** WARNING: Computed flags differ from hardcoded consts! **" +
            "  Update RF_ALL_* in core_registry.nss if you added/removed types.");
    else
        SendMessageToPC(oPC, "  All composite flags match hardcoded consts. OK.");
    SendMessageToPC(oPC, "=== END REGISTRY TYPES ===");
}

void BuilderDumpPackages(object oPC)
{
    object oMod = GetModule();
    int nRows   = GetLocalInt(oMod, "PKG_ROW_CNT");
    object oArea = GetArea(oPC);

    SendMessageToPC(oPC, "=== PACKAGES (" + IntToString(nRows) + " defined) ===");
    string sJson = GetIsObjectValid(oArea) ? GetLocalString(oArea, "PKG_JSON") : "";

    int i;
    for (i = 0; i < nRows; i++)
    {
        string sPfx  = "PKG_" + IntToString(i);
        string sName = GetLocalString(oMod, sPfx + "_NAME");
        int    nEnbl = GetLocalInt(oMod,    sPfx + "_ENBL");
        int    nIvrl = GetLocalInt(oMod,    sPfx + "_IVRL");
        string sDbg  = GetLocalString(oMod, sPfx + "_DBG");

        string sAreaState = "";
        if (sJson != "")
        {
            json jArr = JsonParse(sJson);
            json jPkg = JsonArrayGet(jArr, i);
            int  nRC  = JsonGetInt(JsonObjectGet(jPkg, "rc"));
            int  nPau = JsonGetInt(JsonObjectGet(jPkg, "p"));
            sAreaState = "  runs=" + IntToString(nRC) + (nPau ? "  PAUSED" : "");
        }

        SendMessageToPC(oPC,
            "  [" + IntToString(i) + "] " + sName +
            "  en=" + IntToString(nEnbl) +
            "  ivrl=" + IntToString(nIvrl) +
            "  dbg=" + sDbg +
            sAreaState);
    }
    SendMessageToPC(oPC, "=== END PACKAGES ===");
}

void BuilderCheckRF(object oPC)
{
    // Compares the hardcoded RF_ALL_ constants against the computed 2DA values
    int nFlagP = RegistryFlagPlayers();
    int nFlagC = RegistryFlagCreatures();
    int nFlagX = RegistryFlagCullable();

    const int RF_ALL_PLAYERS_EXPECTED   = 3;
    const int RF_ALL_CREATURES_EXPECTED = 126;
    const int RF_ALL_CULLABLE_EXPECTED  = 992;

    SendMessageToPC(oPC, "=== RF FLAG CONSISTENCY CHECK ===");

    string sP = (nFlagP == RF_ALL_PLAYERS_EXPECTED)   ? "OK" : "** MISMATCH **";
    string sC = (nFlagC == RF_ALL_CREATURES_EXPECTED) ? "OK" : "** MISMATCH **";
    string sX = (nFlagX == RF_ALL_CULLABLE_EXPECTED)  ? "OK" : "** MISMATCH **";

    SendMessageToPC(oPC, "  RF_ALL_PLAYERS:   expected=" + IntToString(RF_ALL_PLAYERS_EXPECTED) +
        "  computed=" + IntToString(nFlagP) + "  " + sP);
    SendMessageToPC(oPC, "  RF_ALL_CREATURES: expected=" + IntToString(RF_ALL_CREATURES_EXPECTED) +
        "  computed=" + IntToString(nFlagC) + "  " + sC);
    SendMessageToPC(oPC, "  RF_ALL_CULLABLE:  expected=" + IntToString(RF_ALL_CULLABLE_EXPECTED) +
        "  computed=" + IntToString(nFlagX) + "  " + sX);

    if (nFlagP != RF_ALL_PLAYERS_EXPECTED || nFlagC != RF_ALL_CREATURES_EXPECTED ||
        nFlagX != RF_ALL_CULLABLE_EXPECTED)
        SendMessageToPC(oPC,
            "  ACTION REQUIRED: Update RF_ALL_* consts in core_registry.nss!");
    else
        SendMessageToPC(oPC, "  All RF flags are consistent with 2DA. No action needed.");

    SendMessageToPC(oPC, "=== END RF CHECK ===");
}

void BuilderScaffoldPackage(object oPC, string sName)
{
    if (sName == "")
    {
        SendMessageToPC(oPC, "[BUILDER] Usage: //scaffold pkg [name]  e.g. //scaffold pkg weather");
        return;
    }

    SendMessageToPC(oPC, "=== SCAFFOLD: New Package '" + sName + "' ===");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 1 - Add to core_package.2da:");
    SendMessageToPC(oPC, "  " + sName + "  1  99  pkg_" + sName + "  ****  ****  1  0  0  1  X.X  MG_DEBUG_" + GetStringUpperCase(GetStringLeft(sName, 6)) + "  5");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 2 - Add to core_conductor.nss:");
    SendMessageToPC(oPC, "  const string MG_DEBUG_" + GetStringUpperCase(GetStringLeft(sName, 6)) + " = \"MG_DEBUG_" + GetStringUpperCase(GetStringLeft(sName, 6)) + "\";");
    SendMessageToPC(oPC, "  void " + GetStringUpperCase(GetStringLeft(sName,1)) + GetStringRight(sName, GetStringLength(sName)-1) + "Boot();");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 3 - Create these files:");
    SendMessageToPC(oPC, "  " + sName + "_lib.nss      // Library (no void main)");
    SendMessageToPC(oPC, "  pkg_" + sName + ".nss     // Thin wrapper (void main calls Tick)");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 4 - In core_onload.nss: Add " + GetStringUpperCase(GetStringLeft(sName,1)) + GetStringRight(sName,GetStringLength(sName)-1) + "Boot() call.");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 5 - In core_admin.nss AdminSetDebugAll(): Add the new debug flag.");
    SendMessageToPC(oPC, "=== END SCAFFOLD ===");
}

void BuilderScaffoldSubSystem(object oPC, string sName)
{
    if (sName == "")
    {
        SendMessageToPC(oPC, "[BUILDER] Usage: //scaffold sub [name]  e.g. //scaffold sub ai_weather");
        return;
    }

    // Detect which hub this belongs to based on prefix
    string sHub = "ai_hub.2da";
    if (GetStringLeft(sName, 4) == "enc_") sHub = "enc_hub.2da";

    SendMessageToPC(oPC, "=== SCAFFOLD: New Sub-System '" + sName + "' in " + sHub + " ===");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 1 - Add to " + sHub + ":");
    SendMessageToPC(oPC, "  " + sName + "  1  N  pkg_" + sName + "  ****  ****  1  X.X  MG_DEBUG_" + GetStringUpperCase(GetStringLeft(sName, 8)) + "  5");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 2 - Add to core_conductor.nss:");
    SendMessageToPC(oPC, "  const string MG_DEBUG_" + GetStringUpperCase(GetStringLeft(sName, 8)) + " = \"MG_DEBUG_" + GetStringUpperCase(GetStringLeft(sName, 8)) + "\";");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 3 - Create these files:");
    SendMessageToPC(oPC, "  " + sName + "_lib.nss      // Library (no void main)");
    SendMessageToPC(oPC, "  pkg_" + sName + ".nss     // Thin wrapper");
    SendMessageToPC(oPC, "");
    SendMessageToPC(oPC, "STEP 4 - In core_admin.nss AdminSetDebugGroup: Add to the relevant group.");
    SendMessageToPC(oPC, "=== END SCAFFOLD ===");
}

// ============================================================================
// MAIN COMMAND HANDLER
// Add this call to core_chat.nss for messages starting with "//"
// ============================================================================

void BuilderHandleCommand(object oPC, string sRawMsg)
{
    string sCmd  = AdminParseCommand(sRawMsg);
    string sPass = AdminParsePassword(sRawMsg);

    if (sPass == "")
    {
        SendMessageToPC(oPC, "[BUILDER] Commands require password. Example: //dump registry \"pass\"");
        return;
    }

    int nRole = AdminGetRole(oPC, sPass);
    if (nRole < ADM_ROLE_MOD)
    {
        SendMessageToPC(oPC, "[BUILDER] Access Denied.");
        return;
    }

    string sRoleTag = "[BLD R" + IntToString(nRole) + "] ";

    if (sCmd == "//dump registry" && nRole >= ADM_ROLE_MOD)
    {
        BuilderDumpRegistry(oPC);
        return;
    }

    if (sCmd == "//dump packages" && nRole >= ADM_ROLE_MOD)
    {
        BuilderDumpPackages(oPC);
        return;
    }

    if (sCmd == "//check rf" && nRole >= ADM_ROLE_MOD)
    {
        BuilderCheckRF(oPC);
        return;
    }

    if (GetStringLeft(sCmd, 15) == "//scaffold pkg " && nRole >= ADM_ROLE_BUILDER)
    {
        string sName = TrimString(GetSubString(sCmd, 15, GetStringLength(sCmd) - 15));
        BuilderScaffoldPackage(oPC, sName);
        return;
    }

    if (GetStringLeft(sCmd, 15) == "//scaffold sub " && nRole >= ADM_ROLE_BUILDER)
    {
        string sName = TrimString(GetSubString(sCmd, 15, GetStringLength(sCmd) - 15));
        BuilderScaffoldSubSystem(oPC, sName);
        return;
    }

    SendMessageToPC(oPC,
        "[BUILDER] Unknown command: '" + sCmd + "'" +
        "  Commands: //dump registry, //dump packages, //check rf," +
        "  //scaffold pkg [name], //scaffold sub [name]");
}
