/* ============================================================================
    ai_hub.nss
    AI System Hub - Sub-System Manager Library

    ============================================================================
    PURPOSE
    ============================================================================
    This is the library half of the AI hub package. It mirrors the structure
    of core_package.nss but scoped to the AI domain.

    It reads ai_hub.2da once at server boot, caches sub-system definitions
    to module locals, and manages per-area JSON state for each sub-system.

    The thin event wrapper pkg_ai_hub.nss calls AiHubTick(OBJECT_SELF) each
    heartbeat. This library has NO void main().

    ============================================================================
    TWO-LAYER CACHE (mirrors core_package.nss pattern)
    ============================================================================
    LAYER 1 - MODULE CACHE (static, boot once):
      AI_ROW_CNT        - total sub-system rows
      AI_[N]_SYS        - system key string
      AI_[N]_SCRP       - tick script name
      AI_[N]_BOOT       - boot script name
      AI_[N]_SHUT       - shutdown script name
      AI_[N]_ENBL       - enabled flag
      AI_[N]_PRI        - priority
      AI_[N]_IVRL       - interval in ticks
      AI_[N]_PHAS       - phase offset float
      AI_IDX_[system]   - reverse lookup: system name -> row index

    LAYER 2 - PER-AREA JSON (mutable per-area state):
      "lt" = last_tick_ran
      "rc" = run_count
      "p"  = paused flag

    ============================================================================
    COMPILE NOTE
    ============================================================================
    This file includes only core_conductor.nss (constants + forward decls).
    Any event script that includes ai_hub.nss must ALSO include core_package.nss
    because ai_hub internally calls PackageGetState / PackageSetState via the
    module cache constants defined there. However ai_hub.nss does not call any
    Package* functions directly - it only uses core_conductor constants.
    Event scripts that use this library: pkg_ai_hub.nss, ai_hub boot scripts.

   ============================================================================
*/

#include "core_conductor"

// ============================================================================
// CONSTANTS
// ============================================================================

const string AI_HUB_2DA      = "ai_hub";
const string AI_HUB_PFX      = "AI_";
const string AI_HUB_JSON_VAR = "AI_HUB_JSON";
const string AI_HUB_BOOTED   = "AI_HUB_BOOTED";

// Module cache field suffixes
const string AIC_SYS   = "_SYS";
const string AIC_SCRP  = "_SCRP";
const string AIC_BOOT  = "_BOOT";
const string AIC_SHUT  = "_SHUT";
const string AIC_ENBL  = "_ENBL";
const string AIC_PRI   = "_PRI";
const string AIC_IVRL  = "_IVRL";
const string AIC_PHAS  = "_PHAS";
const string AIC_DBG   = "_DBG";   // Debug variable name for this sub-system
const string AIC_AUTH  = "_AUTH";  // Min admin role to manually toggle via console

// Per-area JSON state keys
const string AIJ_LAST_TICK = "lt";
const string AIJ_RUN_COUNT = "rc";
const string AIJ_PAUSED    = "p";

// ============================================================================
// SECTION 1: MODULE BOOT
// Call once from pkg_ai_hub_boot.nss which is wired as BOOT_SCRIPT in
// core_package.2da row for "ai_hub". This runs at server startup.
// ============================================================================

void AiHubBoot()
{
    object oMod = GetModule();
    if (GetLocalInt(oMod, AI_HUB_BOOTED)) return;
    SetLocalInt(oMod, AI_HUB_BOOTED, 1);

    int nRows = Get2DARowCount(AI_HUB_2DA);
    SetLocalInt(oMod, "AI_ROW_CNT", nRows);

    int i;
    for (i = 0; i < nRows; i++)
    {
        string sN    = AI_HUB_PFX + IntToString(i);
        string sSys  = Get2DAString(AI_HUB_2DA, "SYSTEM",      i);
        string sScrp = Get2DAString(AI_HUB_2DA, "SCRIPT",      i);
        string sBoot = Get2DAString(AI_HUB_2DA, "BOOT_SCRIPT", i);
        string sShut = Get2DAString(AI_HUB_2DA, "SHUT_SCRIPT", i);
        int    nEnbl = StringToInt(Get2DAString(AI_HUB_2DA, "ENABLED",  i));
        int    nPri  = StringToInt(Get2DAString(AI_HUB_2DA, "PRIORITY", i));
        int    nIvrl = StringToInt(Get2DAString(AI_HUB_2DA, "INTERVAL", i));
        float  fPhas = StringToFloat(Get2DAString(AI_HUB_2DA, "PHASE",  i));
        string sDbg  = Get2DAString(AI_HUB_2DA, "DEBUG_VAR",  i);
        int    nAuth = StringToInt(Get2DAString(AI_HUB_2DA, "AUTH_LEVEL", i));

        if (sScrp == "****") sScrp = "";
        if (sBoot == "****") sBoot = "";
        if (sShut == "****") sShut = "";
        if (sDbg  == "****") sDbg  = "";
        if (nIvrl <= 0) nIvrl = 1;
        if (nPri  <= 0) nPri  = 99;

        SetLocalString(oMod, sN + AIC_SYS,  sSys);
        SetLocalString(oMod, sN + AIC_SCRP, sScrp);
        SetLocalString(oMod, sN + AIC_BOOT, sBoot);
        SetLocalString(oMod, sN + AIC_SHUT, sShut);
        SetLocalInt(oMod,    sN + AIC_ENBL, nEnbl);
        SetLocalInt(oMod,    sN + AIC_PRI,  nPri);
        SetLocalInt(oMod,    sN + AIC_IVRL, nIvrl);
        SetLocalFloat(oMod,  sN + AIC_PHAS, fPhas);
        SetLocalString(oMod, sN + AIC_DBG,  sDbg);
        SetLocalInt(oMod,    sN + AIC_AUTH, nAuth);

        // Reverse lookup: system name -> row index
        if (sSys != "")
            SetLocalInt(oMod, "AI_IDX_" + sSys, i);
    }

    WriteTimestampedLogEntry("[AI_HUB] Boot complete. " +
        IntToString(nRows) + " sub-systems loaded from " + AI_HUB_2DA + ".2da");
}

// ============================================================================
// SECTION 2: MODULE CACHE ACCESSORS
// ============================================================================

int    AiHubRowCount()             { return GetLocalInt(GetModule(), "AI_ROW_CNT"); }
int    AiHubGetRow(string sSys)    { return GetLocalInt(GetModule(), "AI_IDX_" + sSys); }
string AiHubGetScript(int nRow)    { return GetLocalString(GetModule(), AI_HUB_PFX + IntToString(nRow) + AIC_SCRP); }
string AiHubGetBoot(int nRow)      { return GetLocalString(GetModule(), AI_HUB_PFX + IntToString(nRow) + AIC_BOOT); }
string AiHubGetShut(int nRow)      { return GetLocalString(GetModule(), AI_HUB_PFX + IntToString(nRow) + AIC_SHUT); }
int    AiHubIsEnabled(int nRow)    { return GetLocalInt(GetModule(),    AI_HUB_PFX + IntToString(nRow) + AIC_ENBL); }
int    AiHubGetInterval(int nRow)  { return GetLocalInt(GetModule(),    AI_HUB_PFX + IntToString(nRow) + AIC_IVRL); }
float  AiHubGetPhase(int nRow)     { return GetLocalFloat(GetModule(),  AI_HUB_PFX + IntToString(nRow) + AIC_PHAS); }
string AiHubGetDebugVar(int nRow)  { return GetLocalString(GetModule(), AI_HUB_PFX + IntToString(nRow) + AIC_DBG); }
int    AiHubGetAuthLevel(int nRow) { return GetLocalInt(GetModule(),    AI_HUB_PFX + IntToString(nRow) + AIC_AUTH); }

// ============================================================================
// SECTION 3: PER-AREA JSON MANAGEMENT
// ============================================================================

void AiHubLoadArea(object oArea)
{
    if (!GetIsObjectValid(oArea)) return;
    if (GetLocalString(oArea, AI_HUB_JSON_VAR) != "") return;

    int  nRows = AiHubRowCount();
    json jArr  = JsonArray();
    int i;
    for (i = 0; i < nRows; i++)
    {
        json jSys = JsonObject();
        jSys = JsonObjectSet(jSys, AIJ_LAST_TICK, JsonInt(0));
        jSys = JsonObjectSet(jSys, AIJ_RUN_COUNT, JsonInt(0));
        jSys = JsonObjectSet(jSys, AIJ_PAUSED,    JsonInt(0));
        jArr = JsonArrayInsert(jArr, jSys);
    }
    SetLocalString(oArea, AI_HUB_JSON_VAR, JsonDump(jArr));
}

void AiHubUnloadArea(object oArea)
{
    DeleteLocalString(oArea, AI_HUB_JSON_VAR);
}

json AiHubGetState(object oArea, int nRow)
{
    string sJson = GetLocalString(oArea, AI_HUB_JSON_VAR);
    if (sJson == "") return JsonObject();
    return JsonArrayGet(JsonParse(sJson), nRow);
}

void AiHubSetState(object oArea, int nRow, json jSys)
{
    string sJson = GetLocalString(oArea, AI_HUB_JSON_VAR);
    if (sJson == "") return;
    json jArr = JsonParse(sJson);
    jArr = JsonArraySet(jArr, nRow, jSys);
    SetLocalString(oArea, AI_HUB_JSON_VAR, JsonDump(jArr));
}

// ============================================================================
// SECTION 4: HUB TICK - called every heartbeat by pkg_ai_hub.nss
// ============================================================================

void AiHubTick(object oArea)
{
    object oMod = GetModule();

    string sJson = GetLocalString(oArea, AI_HUB_JSON_VAR);
    if (sJson == "") return;  // Area not fully booted yet

    int nTick    = GetLocalInt(oMod, MG_TICK);
    int nRows    = AiHubRowCount();
    json jArr    = JsonParse(sJson);
    int  bChanged = FALSE;

    int i;
    for (i = 0; i < nRows; i++)
    {
        if (!AiHubIsEnabled(i)) continue;

        string sScript = AiHubGetScript(i);
        if (sScript == "") continue;

        int   nIvrl  = AiHubGetInterval(i);
        float fPhase = AiHubGetPhase(i);

        json jSys  = JsonArrayGet(jArr, i);
        int  nLast = JsonGetInt(JsonObjectGet(jSys, AIJ_LAST_TICK));
        int  nPaus = JsonGetInt(JsonObjectGet(jSys, AIJ_PAUSED));

        if (nPaus) continue;
        if (nIvrl > 1 && (nTick - nLast) < nIvrl) continue;

        // Update last_tick and run_count before dispatching
        jSys = JsonObjectSet(jSys, AIJ_LAST_TICK, JsonInt(nTick));
        int nCnt = JsonGetInt(JsonObjectGet(jSys, AIJ_RUN_COUNT)) + 1;
        jSys = JsonObjectSet(jSys, AIJ_RUN_COUNT, JsonInt(nCnt));
        jArr = JsonArraySet(jArr, i, jSys);
        bChanged = TRUE;

        // -------------------------------------------------------------------
        // SURGICAL DEBUG WRAPPER (zero cost in production)
        // Only fires if master debug AND this sub-system's DEBUG_VAR are on.
        // Set via: /*debug ai on "pass"  or  /*debug ai_logic on "pass"
        // -------------------------------------------------------------------
        if (GetLocalInt(oMod, MG_DEBUG))
        {
            string sDbgVar = GetLocalString(oMod, AI_HUB_PFX + IntToString(i) + AIC_DBG);
            if (sDbgVar != "" && GetLocalInt(oMod, sDbgVar))
            {
                string sSysName = GetLocalString(oMod, AI_HUB_PFX + IntToString(i) + AIC_SYS);
                SendMessageToAllDMs("[AI_DEBUG] " + sSysName +
                    "  Area=" + GetTag(oArea) +
                    "  T="    + IntToString(nTick) +
                    "  Run="  + IntToString(nCnt));
            }
        }

        DelayCommand(fPhase, ExecuteScript(sScript, oArea));
    }

    if (bChanged)
        SetLocalString(oArea, AI_HUB_JSON_VAR, JsonDump(jArr));
}

// ============================================================================
// SECTION 5: BOOT AND SHUTDOWN SCRIPT DISPATCHERS
// ============================================================================

void AiHubRunBootScripts(object oArea)
{
    object oMod = GetModule();
    int nRows = AiHubRowCount();
    float fDelay = 0.1;
    int i;
    for (i = 0; i < nRows; i++)
    {
        if (!AiHubIsEnabled(i)) continue;
        string sBoot = AiHubGetBoot(i);
        if (sBoot == "") continue;
        DelayCommand(fDelay, ExecuteScript(sBoot, oArea));
        fDelay += 0.05;
    }
}

void AiHubRunShutScripts(object oArea)
{
    int nRows = AiHubRowCount();
    int i;
    for (i = 0; i < nRows; i++)
    {
        if (!AiHubIsEnabled(i)) continue;
        string sShut = AiHubGetShut(i);
        if (sShut == "") continue;
        ExecuteScript(sShut, oArea);
    }
}
