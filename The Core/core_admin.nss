/* ============================================================================
    DOWE - core_admin.nss
    Role-Based Access Control (RBAC) Security Layer
    DOWE v2.3 | Production Standard | Final

    ============================================================================
    PURPOSE
    ============================================================================
    Manages administrator authentication for the DM console system.
    Reads core_admin.2da once at boot, caches CD keys, passwords, and roles
    to module locals for O(1) lookup during chat commands.

    This is a LIBRARY file. It has NO void main().
    It is #included by core_chat.nss (the OnPlayerChat handler).

    ============================================================================
    COMMAND SYNTAX
    ============================================================================
    All commands use the format: /*command "password"
    The password must be in double quotes.
    The message is silenced immediately by core_chat.nss so no one sees it.

    ROLE 1+ (Moderator):
      /*debug on "pass"               - Master debug: ON
      /*debug off "pass"              - Master debug: OFF (silences everything)
      /*debug all on "pass"           - All debug flags: ON
      /*debug all off "pass"          - All debug flags: OFF

      /*debug registry on/off "pass"  - Registry operations
      /*debug gps on/off "pass"       - GPS proximity system
      /*debug pkg on/off "pass"       - Package dispatch / core_switch
      /*debug switch on/off "pass"    - Alias for pkg (same variable)
      /*debug grid on/off "pass"      - Grid system
      /*debug enc on/off "pass"       - Encounter system (all enc)
      /*debug enc_spawn on/off "pass" - Encounter spawn specifically
      /*debug enc_hub on/off "pass"   - Encounter hub sub-system dispatch
      /*debug ai on/off "pass"        - AI system (all AI)
      /*debug ai_hub on/off "pass"    - AI hub sub-system dispatch
      /*debug sql on/off "pass"       - SQL operations
      /*debug disp on/off "pass"      - Dispatch active area registry
      /*debug admin on/off "pass"     - Admin console operations
      /*debug mud on/off "pass"       - MUD chat system

      /*trace [system] on/off "pass"  - Toggle a NAMED debug var directly.
                                        system = any MG_DEBUG_* suffix name
                                        e.g. /*trace AILOG on "pass"
                                        This sets MG_DEBUG_AILOG to 1.
                                        Use this for sub-system surgical debug.

      /*status "pass"                 - Server status: tick, areas, packages, load
      /*status area "pass"            - Package status for your current area
      /*status packages "pass"        - All package definitions from 2DA

    ROLE 5+ (Builder):
      /*reload "pass"                 - Reload all 2DA caches (registry, gps, package, ai)
      /*reload registry "pass"        - Reload core_registry.2da only
      /*reload gps "pass"             - Reload core_ai_gps.2da only
      /*reload admin "pass"           - Reload core_admin.2da (pick up roster changes)
      /*reload package "pass"         - Reload core_package.2da only
      /*pkg off [name] "pass"         - Disable a package globally
      /*pkg on [name] "pass"          - Enable a package globally
      /*pkg interval [name] [n] "pass"- Change a package's tick interval globally

    ROLE 10+ (Master):
      /*shutdown area "pass"          - Force area teardown (current area)
      /*lockdown "pass"               - Toggle console lockdown (disables all commands)

    ============================================================================
    NWSCRIPT COMPILE RULE
    ============================================================================
    core_admin includes only core_conductor.
    core_chat.nss (the compilation unit that calls AdminHandleCommand) must
    also include core_registry, core_package, and core_ai_gps so that the
    implementations of RegistryBoot(), GpsBoot(), PackageBoot(), etc. are
    present in the same compilation unit.

   ============================================================================
*/

#include "core_conductor"

// ============================================================================
// CONSTANTS
// ============================================================================

const string ADM_2DA          = "core_admin";
const string ADM_PFX          = "ADM_";
const string ADM_COUNT_VAR    = "ADM_COUNT";
const string ADM_LOCKDOWN_VAR = "ADM_LOCKDOWN";

// Module cache field suffixes
const string ADMC_KEY   = "_KEY";
const string ADMC_PASS  = "_PASS";
const string ADMC_ROLE  = "_ROLE";
const string ADMC_NAME  = "_NAME";

// Role constants
const int ADM_ROLE_NONE     = 0;
const int ADM_ROLE_MOD      = 1;
const int ADM_ROLE_BUILDER  = 5;
const int ADM_ROLE_MASTER   = 10;

// ============================================================================
// SECTION 1: BOOT
// Reads core_admin.2da once. Caches to module locals for O(1) lookup.
// Call from core_onload.nss FIRST - before all other system boots.
// ============================================================================

void AdminBoot()
{
    object oMod = GetModule();
    if (GetLocalInt(oMod, "ADM_BOOTED")) return;
    SetLocalInt(oMod, "ADM_BOOTED", 1);

    int nRows = Get2DARowCount(ADM_2DA);
    int nLoaded = 0;
    int i;

    for (i = 0; i < nRows; i++)
    {
        int nActive = StringToInt(Get2DAString(ADM_2DA, "ACTIVE", i));
        if (nActive != 1) continue;

        string sKey  = Get2DAString(ADM_2DA, "CD_KEY",   i);
        string sPass = Get2DAString(ADM_2DA, "PASSWORD", i);
        string sName = Get2DAString(ADM_2DA, "LABEL",    i);
        int    nRole = StringToInt(Get2DAString(ADM_2DA, "ROLE", i));

        if (sKey == "" || sKey == "****") continue;
        if (sPass == "" || sPass == "****") continue;
        if (nRole <= 0) continue;

        string sPfx = ADM_PFX + IntToString(nLoaded);
        SetLocalString(oMod, sPfx + ADMC_KEY,  sKey);
        SetLocalString(oMod, sPfx + ADMC_PASS, sPass);
        SetLocalInt(oMod,    sPfx + ADMC_ROLE, nRole);
        SetLocalString(oMod, sPfx + ADMC_NAME, sName);

        nLoaded++;
    }

    SetLocalInt(oMod, ADM_COUNT_VAR, nLoaded);
    WriteTimestampedLogEntry("[ADMIN] Security layer online. " +
        IntToString(nLoaded) + " admin accounts loaded from " + ADM_2DA + ".2da");
}

// ============================================================================
// SECTION 2: AUTHENTICATION
// Returns the role level (0 = no access) for oPC + sPassword combination.
// Uses GetPCPublicCDKey() which is available in all script contexts in NWN:EE.
// Returns 0 if: lockdown active, credentials not found, AdminBoot not called.
// ============================================================================

int AdminGetRole(object oPC, string sPassword)
{
    object oMod = GetModule();

    // Lockdown: even masters cannot execute while locked
    if (GetLocalInt(oMod, ADM_LOCKDOWN_VAR)) return ADM_ROLE_NONE;

    string sPlayerKey = GetPCPublicCDKey(oPC, FALSE); // FALSE = public key, not sensitive key
    int nCount = GetLocalInt(oMod, ADM_COUNT_VAR);
    int i;

    for (i = 0; i < nCount; i++)
    {
        string sPfx = ADM_PFX + IntToString(i);
        if (sPlayerKey == GetLocalString(oMod, sPfx + ADMC_KEY) &&
            sPassword   == GetLocalString(oMod, sPfx + ADMC_PASS))
        {
            int nRole = GetLocalInt(oMod, sPfx + ADMC_ROLE);
            if (GetLocalInt(oMod, MG_DEBUG_ADMIN))
                WriteTimestampedLogEntry("[ADMIN] AUTH OK - " +
                    GetName(oPC) + " [" + sPlayerKey + "] Role=" + IntToString(nRole));
            return nRole;
        }
    }

    WriteTimestampedLogEntry("[ADMIN] AUTH FAIL - " + GetName(oPC) +
        " [" + sPlayerKey + "] bad password.");
    return ADM_ROLE_NONE;
}

// ============================================================================
// SECTION 3: COMMAND PARSING HELPERS
// ============================================================================

// Returns the command portion of a raw message (everything before the first quote).
// Input:  "/*debug all on \"mypass\""
// Output: "/*debug all on"
string AdminParseCommand(string sRawMsg)
{
    int nQuote = FindSubString(sRawMsg, "\"");
    if (nQuote < 0) return sRawMsg;
    return TrimString(GetSubString(sRawMsg, 0, nQuote));
}

// Returns the password from inside the first pair of double quotes.
// Input:  "/*debug on \"mypass\""
// Output: "mypass"
string AdminParsePassword(string sRawMsg)
{
    int nLen  = GetStringLength(sRawMsg);
    int nOpen = -1;
    int i;

    // Find opening quote
    for (i = 0; i < nLen; i++)
    {
        if (GetSubString(sRawMsg, i, 1) == "\"") { nOpen = i; break; }
    }
    if (nOpen < 0) return "";

    // Find closing quote
    for (i = nOpen + 1; i < nLen; i++)
    {
        if (GetSubString(sRawMsg, i, 1) == "\"")
            return GetSubString(sRawMsg, nOpen + 1, i - nOpen - 1);
    }

    // No closing quote - take everything after opening
    return GetSubString(sRawMsg, nOpen + 1, nLen - nOpen - 1);
}

// ============================================================================
// SECTION 4: DEBUG TOGGLE HELPERS
// These are called by AdminHandleCommand. All use module object locals.
// ============================================================================

// Toggle every debug flag simultaneously.
void AdminSetDebugAll(int bOn)
{
    object oMod = GetModule();
    int nVal = bOn ? 1 : 0;
    // Master gate
    SetLocalInt(oMod, MG_DEBUG,          nVal);
    // Per-system flags
    SetLocalInt(oMod, MG_DEBUG_VERBOSE,  nVal);
    SetLocalInt(oMod, MG_DEBUG_REG,      nVal);
    SetLocalInt(oMod, MG_DEBUG_ENC,      nVal);
    SetLocalInt(oMod, MG_DEBUG_ENC_SPAWN,nVal);
    SetLocalInt(oMod, MG_DEBUG_ENC_HUB,  nVal);
    SetLocalInt(oMod, MG_DEBUG_MUD,      nVal);
    SetLocalInt(oMod, MG_DEBUG_SQL,      nVal);
    SetLocalInt(oMod, MG_DEBUG_GPS,      nVal);
    SetLocalInt(oMod, MG_DEBUG_PKG,      nVal);
    SetLocalInt(oMod, MG_DEBUG_GRID,     nVal);
    SetLocalInt(oMod, MG_DEBUG_DISP,     nVal);
    SetLocalInt(oMod, MG_DEBUG_AI,       nVal);
    SetLocalInt(oMod, MG_DEBUG_AI_LOGIC, nVal);
    SetLocalInt(oMod, MG_DEBUG_AI_CAST,  nVal);
    SetLocalInt(oMod, MG_DEBUG_AI_PHYS,  nVal);
    SetLocalInt(oMod, MG_DEBUG_AI_SURV,  nVal); // FIX: was missing
    SetLocalInt(oMod, MG_DEBUG_AI_HUB,   nVal);
    SetLocalInt(oMod, MG_DEBUG_ADMIN,    nVal);
}

// Toggle a named debug group (all flags in that group).
// Called when the command is: /*debug [group] on/off
void AdminSetDebugGroup(string sGroup, int bOn)
{
    object oMod = GetModule();
    int nVal = bOn ? 1 : 0;

    if (sGroup == "ai")
    {
        SetLocalInt(oMod, MG_DEBUG_AI,       nVal);
        SetLocalInt(oMod, MG_DEBUG_AI_LOGIC, nVal);
        SetLocalInt(oMod, MG_DEBUG_AI_CAST,  nVal);
        SetLocalInt(oMod, MG_DEBUG_AI_PHYS,  nVal);
        SetLocalInt(oMod, MG_DEBUG_AI_SURV,  nVal);
        SetLocalInt(oMod, MG_DEBUG_AI_HUB,   nVal);
    }
    else if (sGroup == "enc")
    {
        SetLocalInt(oMod, MG_DEBUG_ENC,       nVal);
        SetLocalInt(oMod, MG_DEBUG_ENC_SPAWN, nVal);
        SetLocalInt(oMod, MG_DEBUG_ENC_HUB,   nVal);
    }
    else if (sGroup == "registry") SetLocalInt(oMod, MG_DEBUG_REG,      nVal);
    else if (sGroup == "gps")      SetLocalInt(oMod, MG_DEBUG_GPS,      nVal);
    else if (sGroup == "pkg")      SetLocalInt(oMod, MG_DEBUG_PKG,      nVal);
    else if (sGroup == "switch")   SetLocalInt(oMod, MG_DEBUG_PKG,      nVal); // alias
    else if (sGroup == "grid")     SetLocalInt(oMod, MG_DEBUG_GRID,     nVal);
    else if (sGroup == "sql")      SetLocalInt(oMod, MG_DEBUG_SQL,      nVal);
    else if (sGroup == "disp")     SetLocalInt(oMod, MG_DEBUG_DISP,     nVal);
    else if (sGroup == "mud")      SetLocalInt(oMod, MG_DEBUG_MUD,      nVal);
    else if (sGroup == "admin")    SetLocalInt(oMod, MG_DEBUG_ADMIN,    nVal);
    else if (sGroup == "enc_spawn")SetLocalInt(oMod, MG_DEBUG_ENC_SPAWN,nVal);
    else if (sGroup == "enc_hub")  SetLocalInt(oMod, MG_DEBUG_ENC_HUB,  nVal);
    else if (sGroup == "ai_hub")   SetLocalInt(oMod, MG_DEBUG_AI_HUB,   nVal);
    else if (sGroup == "enc_flag") SetLocalInt(oMod, MG_DEBUG_ENC,      nVal);
}

// Toggle a specific debug variable by its SUFFIX name (the part after MG_DEBUG_).
// e.g. AdminSetTrace("AILOG", 1) sets MG_DEBUG_AILOG = 1 on the module.
// Used for surgical sub-system traces via: /*trace AILOG on "pass"
void AdminSetTrace(string sVarSuffix, int bOn)
{
    SetLocalInt(GetModule(), "MG_DEBUG_" + sVarSuffix, bOn ? 1 : 0);
}

// ============================================================================
// SECTION 5: STATUS HELPERS
// ============================================================================

void AdminShowStatus(object oPC)
{
    object oMod    = GetModule();
    int    nActive = GetLocalInt(oMod, "MG_ACTIVE_CNT");
    int    nTick   = GetLocalInt(oMod, MG_TICK);
    int    nPkgs   = GetLocalInt(oMod, "PKG_ROW_CNT");
    int    nDebug  = GetLocalInt(oMod, MG_DEBUG);

    SendMessageToPC(oPC,
        "[DOWE STATUS]  Tick=" + IntToString(nTick) +
        "  ActiveAreas="  + IntToString(nActive) +
        "  Packages="     + IntToString(nPkgs) +
        "  MasterDebug="  + IntToString(nDebug));
}

void AdminShowAreaStatus(object oPC)
{
    object oArea = GetArea(oPC);
    if (!GetIsObjectValid(oArea))
    {
        SendMessageToPC(oPC, "[ADMIN] Not in a valid area.");
        return;
    }

    object oMod = GetModule();
    int nRows   = GetLocalInt(oMod, "PKG_ROW_CNT");

    SendMessageToPC(oPC, "=== AREA PACKAGES: " + GetTag(oArea) + " ===");

    string sJson = GetLocalString(oArea, PKG_JSON_VAR);
    if (sJson == "")
    {
        SendMessageToPC(oPC, "  [NOT LOADED - no players in area]");
        return;
    }

    json jArr = JsonParse(sJson);
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sN    = "PKG_" + IntToString(i);
        string sName = GetLocalString(oMod, sN + "_NAME");
        int    nEnbl = GetLocalInt(oMod,    sN + "_ENBL");

        json   jPkg  = JsonArrayGet(jArr, i);
        int nPaused  = JsonGetInt(JsonObjectGet(jPkg, "paused"));
        int nRuns    = JsonGetInt(JsonObjectGet(jPkg, "rc"));
        int nLast    = JsonGetInt(JsonObjectGet(jPkg, "lt"));
        int nEoOvr   = JsonGetInt(JsonObjectGet(jPkg, "eo"));

        string sState;
        if (!nEnbl)           sState = "DISABLED";
        else if (nEoOvr == 0) sState = "AREA-OFF";
        else if (nPaused)     sState = "PAUSED";
        else                  sState = "RUNNING";

        SendMessageToPC(oPC, "  [" + IntToString(i) + "] " + sName +
            " - " + sState +
            "  runs=" + IntToString(nRuns) +
            "  lastT=" + IntToString(nLast));
    }
}

void AdminShowPackageList(object oPC)
{
    object oMod = GetModule();
    int nRows   = GetLocalInt(oMod, "PKG_ROW_CNT");

    SendMessageToPC(oPC, "=== PACKAGE DEFINITIONS (" + IntToString(nRows) + " total) ===");
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sN    = "PKG_" + IntToString(i);
        string sName = GetLocalString(oMod, sN + "_NAME");
        int  nEnbl   = GetLocalInt(oMod, sN + "_ENBL");
        int  nIvrl   = GetLocalInt(oMod, sN + "_IVRL");
        int  nAuth   = GetLocalInt(oMod, sN + "_AUTH");
        string sDbg  = GetLocalString(oMod, sN + "_DBG");

        SendMessageToPC(oPC, "  [" + IntToString(i) + "] " + sName +
            "  en=" + IntToString(nEnbl) +
            "  ivrl=" + IntToString(nIvrl) +
            "  auth=" + IntToString(nAuth) +
            "  dbg=" + sDbg);
    }
}

// ============================================================================
// SECTION 6: MAIN COMMAND HANDLER
// Drop this call into your MUD chat script (OnPlayerChat handler).
// core_chat.nss handles the silencing and calls this.
//
// REQUIRED INCLUDES in the compilation unit that includes core_admin:
//   core_admin      (this file)
//   core_registry   (for RegistryBoot, RegistryShutdown)
//   core_package    (for PackageBoot, PackageGetRow)
//   core_ai_gps     (for GpsBoot)
//   ai_hub          (for AiHubBoot)
// ============================================================================

void AdminHandleCommand(object oPC, string sRawMsg)
{
    object oMod = GetModule();

    string sCmd  = AdminParseCommand(sRawMsg);
    string sPass = AdminParsePassword(sRawMsg);

    if (sPass == "")
    {
        SendMessageToPC(oPC,
            "[ADMIN] Commands require password in double quotes. " +
            "Example: /*debug on \"mypass\"");
        return;
    }

    int nRole = AdminGetRole(oPC, sPass);
    if (nRole <= ADM_ROLE_NONE)
    {
        SendMessageToPC(oPC, "[ADMIN] Access Denied: Invalid credentials.");
        return;
    }

    string sRoleTag = "[ADMIN R" + IntToString(nRole) + "] ";

    // -------------------------------------------------------------------------
    // ROLE 1+: MODERATOR COMMANDS
    // -------------------------------------------------------------------------

    // Master debug on/off
    if (sCmd == "/*debug on" && nRole >= ADM_ROLE_MOD)
    {
        SetLocalInt(oMod, MG_DEBUG, 1);
        SendMessageToPC(oPC, sRoleTag + "Master debug: ON (system flags unchanged)");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " MG_DEBUG ON");
        return;
    }

    if (sCmd == "/*debug off" && nRole >= ADM_ROLE_MOD)
    {
        SetLocalInt(oMod, MG_DEBUG, 0);
        SendMessageToPC(oPC, sRoleTag + "Master debug: OFF (silences all output)");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " MG_DEBUG OFF");
        return;
    }

    // Debug all on/off
    if (sCmd == "/*debug all on" && nRole >= ADM_ROLE_MOD)
    {
        AdminSetDebugAll(TRUE);
        SendMessageToPC(oPC, sRoleTag + "ALL debug tracers: ONLINE");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " ALL debug ON");
        return;
    }

    if (sCmd == "/*debug all off" && nRole >= ADM_ROLE_MOD)
    {
        AdminSetDebugAll(FALSE);
        SendMessageToPC(oPC, sRoleTag + "ALL debug tracers: OFFLINE");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " ALL debug OFF");
        return;
    }

    // -----------------------------------------------------------------------
    // Per-group debug: /*debug [group] on/off
    // Groups: ai, enc, registry, gps, pkg, switch, grid, sql, disp, mud,
    //         admin, enc_spawn, enc_hub, ai_hub, enc_flag
    // -----------------------------------------------------------------------
    // Check if sCmd starts with "/*debug " (8 chars) and ends with " on" or " off"
    if (GetStringLeft(sCmd, 8) == "/*debug " && nRole >= ADM_ROLE_MOD)
    {
        string sRest = GetSubString(sCmd, 8, GetStringLength(sCmd) - 8);
        int    nLen  = GetStringLength(sRest);
        int bOn;
        string sGroup;

        if (GetStringRight(sRest, 3) == " on")
        {
            bOn    = TRUE;
            sGroup = GetSubString(sRest, 0, nLen - 3);
        }
        else if (GetStringRight(sRest, 4) == " off")
        {
            bOn    = FALSE;
            sGroup = GetSubString(sRest, 0, nLen - 4);
        }
        else
        {
            SendMessageToPC(oPC, "[ADMIN] Usage: /*debug [group] on/off \"pass\"");
            return;
        }

        // Ensure master gate is on when enabling anything
        if (bOn) SetLocalInt(oMod, MG_DEBUG, 1);

        AdminSetDebugGroup(sGroup, bOn);
        SendMessageToPC(oPC, sRoleTag + "Debug [" + sGroup + "]: " +
            (bOn ? "ON" : "OFF"));
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) +
            " debug " + sGroup + " " + (bOn ? "ON" : "OFF"));
        return;
    }

    // -----------------------------------------------------------------------
    // Surgical tracer: /*trace [SUFFIX] on/off "pass"
    // Directly sets MG_DEBUG_[SUFFIX] on the module.
    // Example: /*trace AILOG on "pass"  -> MG_DEBUG_AILOG = 1
    // -----------------------------------------------------------------------
    if (GetStringLeft(sCmd, 8) == "/*trace " && nRole >= ADM_ROLE_MOD)
    {
        string sRest = GetSubString(sCmd, 8, GetStringLength(sCmd) - 8);
        int    nLen  = GetStringLength(sRest);
        int bOn;
        string sSuffix;

        if (GetStringRight(sRest, 3) == " on")
        {
            bOn     = TRUE;
            sSuffix = GetSubString(sRest, 0, nLen - 3);
        }
        else if (GetStringRight(sRest, 4) == " off")
        {
            bOn     = FALSE;
            sSuffix = GetSubString(sRest, 0, nLen - 4);
        }
        else
        {
            SendMessageToPC(oPC, "[ADMIN] Usage: /*trace [MG_DEBUG_suffix] on/off \"pass\"");
            return;
        }

        if (bOn) SetLocalInt(oMod, MG_DEBUG, 1);
        AdminSetTrace(sSuffix, bOn);
        SendMessageToPC(oPC, sRoleTag + "Trace [MG_DEBUG_" + sSuffix + "]: " +
            (bOn ? "ON" : "OFF"));
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) +
            " trace MG_DEBUG_" + sSuffix + " " + (bOn ? "ON" : "OFF"));
        return;
    }

    // Status commands
    if (sCmd == "/*status" && nRole >= ADM_ROLE_MOD)
    {
        AdminShowStatus(oPC);
        return;
    }

    if (sCmd == "/*status area" && nRole >= ADM_ROLE_MOD)
    {
        AdminShowAreaStatus(oPC);
        return;
    }

    if (sCmd == "/*status packages" && nRole >= ADM_ROLE_MOD)
    {
        AdminShowPackageList(oPC);
        return;
    }

    // -------------------------------------------------------------------------
    // ROLE 5+: BUILDER COMMANDS
    // -------------------------------------------------------------------------

    if (sCmd == "/*reload" && nRole >= ADM_ROLE_BUILDER)
    {
        DeleteLocalInt(oMod, "ADM_BOOTED");
        AdminBoot();
        DeleteLocalInt(oMod, "RG_BOOTED");
        RegistryBoot();
        DeleteLocalInt(oMod, "GPS_CFG_BOOTED");
        GpsBoot();
        DeleteLocalInt(oMod, "PKG_BOOTED");
        PackageBoot();
        DeleteLocalInt(oMod, "AI_HUB_BOOTED");
        AiHubBoot();
        DeleteLocalInt(oMod, "ENC_HUB_BOOTED");
        EncHubBoot();
        SendMessageToPC(oPC, sRoleTag + "All 2DA caches reloaded.");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " reloaded ALL 2DAs.");
        return;
    }

    if (sCmd == "/*reload admin" && nRole >= ADM_ROLE_BUILDER)
    {
        DeleteLocalInt(oMod, "ADM_BOOTED");
        AdminBoot();
        SendMessageToPC(oPC, sRoleTag + "Admin 2DA reloaded. Credentials updated.");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " reloaded admin credentials.");
        return;
    }

    if (sCmd == "/*reload registry" && nRole >= ADM_ROLE_BUILDER)
    {
        DeleteLocalInt(oMod, "RG_BOOTED");
        RegistryBoot();
        SendMessageToPC(oPC, sRoleTag + "Registry 2DA reloaded.");
        return;
    }

    if (sCmd == "/*reload gps" && nRole >= ADM_ROLE_BUILDER)
    {
        DeleteLocalInt(oMod, "GPS_CFG_BOOTED");
        GpsBoot();
        SendMessageToPC(oPC, sRoleTag + "GPS 2DA reloaded.");
        return;
    }

    if (sCmd == "/*reload package" && nRole >= ADM_ROLE_BUILDER)
    {
        DeleteLocalInt(oMod, "PKG_BOOTED");
        PackageBoot();
        SendMessageToPC(oPC, sRoleTag + "Package 2DA reloaded.");
        return;
    }

    // /*pkg off [name] "pass"
    if (GetStringLeft(sCmd, 9) == "/*pkg off" && nRole >= ADM_ROLE_BUILDER)
    {
        string sPkgName = TrimString(GetSubString(sCmd, 9, GetStringLength(sCmd) - 9));
        int nRow = PackageGetRow(sPkgName);
        if (nRow < 0)
        {
            SendMessageToPC(oPC, "[ADMIN] Package '" + sPkgName + "' not found.");
            return;
        }
        // Check auth level required for this specific package
        if (PackageGetAuthLevel(nRow) > nRole)
        {
            SendMessageToPC(oPC, "[ADMIN] Package '" + sPkgName +
                "' requires Role " + IntToString(PackageGetAuthLevel(nRow)) + ".");
            return;
        }
        SetLocalInt(oMod, "PKG_" + IntToString(nRow) + "_ENBL", 0);
        SendMessageToPC(oPC, sRoleTag + "Package '" + sPkgName + "' DISABLED globally.");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " disabled pkg: " + sPkgName);
        return;
    }

    // /*pkg on [name] "pass"
    if (GetStringLeft(sCmd, 8) == "/*pkg on" && nRole >= ADM_ROLE_BUILDER)
    {
        string sPkgName = TrimString(GetSubString(sCmd, 8, GetStringLength(sCmd) - 8));
        int nRow = PackageGetRow(sPkgName);
        if (nRow < 0)
        {
            SendMessageToPC(oPC, "[ADMIN] Package '" + sPkgName + "' not found.");
            return;
        }
        if (PackageGetAuthLevel(nRow) > nRole)
        {
            SendMessageToPC(oPC, "[ADMIN] Package '" + sPkgName +
                "' requires Role " + IntToString(PackageGetAuthLevel(nRow)) + ".");
            return;
        }
        SetLocalInt(oMod, "PKG_" + IntToString(nRow) + "_ENBL", 1);
        SendMessageToPC(oPC, sRoleTag + "Package '" + sPkgName + "' ENABLED globally.");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) + " enabled pkg: " + sPkgName);
        return;
    }

    // /*pkg interval [name] [n] "pass"
    // Sets interval for all areas (module cache). Existing areas pick up on next area boot.
    // Format of sCmd: "/*pkg interval enc_hub 5"
    if (GetStringLeft(sCmd, 15) == "/*pkg interval " && nRole >= ADM_ROLE_BUILDER)
    {
        string sRest = GetSubString(sCmd, 15, GetStringLength(sCmd) - 15);
        // sRest = "enc_hub 5"
        int nSpace = FindSubString(sRest, " ");
        if (nSpace < 0)
        {
            SendMessageToPC(oPC, "[ADMIN] Usage: /*pkg interval [name] [ticks] \"pass\"");
            return;
        }
        string sPkgName = GetSubString(sRest, 0, nSpace);
        int    nNewIvrl = StringToInt(GetSubString(sRest, nSpace + 1, GetStringLength(sRest) - nSpace - 1));
        if (nNewIvrl < 1) nNewIvrl = 1;

        int nRow = PackageGetRow(sPkgName);
        if (nRow < 0)
        {
            SendMessageToPC(oPC, "[ADMIN] Package '" + sPkgName + "' not found.");
            return;
        }
        SetLocalInt(oMod, "PKG_" + IntToString(nRow) + "_IVRL", nNewIvrl);
        SendMessageToPC(oPC, sRoleTag + "Package '" + sPkgName +
            "' interval set to " + IntToString(nNewIvrl) + " ticks globally.");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) +
            " set " + sPkgName + " interval=" + IntToString(nNewIvrl));
        return;
    }

    // -------------------------------------------------------------------------
    // ROLE 10+: MASTER COMMANDS
    // -------------------------------------------------------------------------

    if (sCmd == "/*lockdown" && nRole >= ADM_ROLE_MASTER)
    {
        int bLocked = GetLocalInt(oMod, ADM_LOCKDOWN_VAR);
        SetLocalInt(oMod, ADM_LOCKDOWN_VAR, bLocked ? 0 : 1);
        string sState = bLocked ? "LIFTED" : "ACTIVE";
        SendMessageToAllDMs("[ADMIN] CONSOLE LOCKDOWN " + sState +
            " by " + GetName(oPC));
        WriteTimestampedLogEntry("[ADMIN] Lockdown " + sState +
            " by " + GetName(oPC));
        return;
    }

    if (sCmd == "/*shutdown area" && nRole >= ADM_ROLE_MASTER)
    {
        object oArea = GetArea(oPC);
        if (!GetIsObjectValid(oArea))
        {
            SendMessageToPC(oPC, "[ADMIN] Not in a valid area.");
            return;
        }
        DelayCommand(0.5, RegistryShutdown(oArea));
        SendMessageToPC(oPC, sRoleTag + "Area '" + GetTag(oArea) + "' shutdown queued.");
        WriteTimestampedLogEntry("[ADMIN] " + GetName(oPC) +
            " forced shutdown: " + GetTag(oArea));
        return;
    }

    // Unrecognized command
    SendMessageToPC(oPC,
        "[ADMIN] Unknown command: '" + sCmd + "'  (Role=" + IntToString(nRole) + ")" +
        "  Type /*debug all on \"pass\" for help or see DOWE_SYSTEM_GUIDE.txt");
}
