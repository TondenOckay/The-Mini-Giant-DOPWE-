/* ============================================================================
    DOWE - core_package.nss
    Package Registry Hub - Plug-and-Play Subsystem Manager

    ============================================================================
    PHILOSOPHY
    ============================================================================
    core_package.2da is the authority. This script is the engine.

    Every package (subsystem) plugs into core_package.2da by adding one row.
    This hub manages the entire lifecycle: boot, tick, throttle, pause, shutdown.
    No core script ever changes when a new package is added.

    ============================================================================
    TWO-LAYER CACHE DESIGN
    ============================================================================
    LAYER 1 - MODULE CACHE (read-only at runtime):
    PackageBoot() reads core_package.2da ONCE at server start and stores
    every row as local variables on the module object. These never change
    at runtime. They give core_switch O(1) access to script names, phases,
    priorities, and intervals without touching a 2DA or JSON string.

    Module cache keys (prefix PKG_PFX + row index):
      PKG_[N]_NAME    package ID string
      PKG_[N]_SCRIPT  tick script name
      PKG_[N]_BOOT    boot script name
      PKG_[N]_SHUT    shutdown script name
      PKG_[N]_ENBL    enabled flag (global)
      PKG_[N]_PRI     priority
      PKG_[N]_IVRL    interval in ticks
      PKG_[N]_MNPC    min players
      PKG_[N]_PSAT    pause threshold
      PKG_[N]_AOVR    area override flag
      PKG_[N]_PHAS    delay phase (float seconds)
    PKG_ROW_CNT       total row count

    LAYER 2 - PER-AREA JSON (mutable state):
    PackageLoad() builds a JSON blob per area at area boot, merging SQL
    area-specific overrides. This JSON carries mutable runtime state:
    paused flag, last_tick_ran, run_count. core_switch reads from module
    cache for scripts/phases and from area JSON only for mutable state.

    ============================================================================
    HOW TO ADD A NEW PACKAGE
    ============================================================================
    1. Add a row to core_package.2da.
    2. Write your tick script (.nss). It receives oArea = OBJECT_SELF.
    3. Optionally write boot and shutdown scripts.
    4. Done. No core scripts change. Ever.

   ============================================================================
*/

#include "core_conductor"

// ============================================================================
// CONSTANTS
// ============================================================================

const string PKG_2DA          = "core_package";
const string PKG_PFX          = "PKG_";
const string PKG_JSON_VAR     = "CORE_PKG_JSON";
const string PKG_LOAD_VAR     = "MG_LOAD";
const string PKG_SCHED_VAR    = "MG_PKG_SCHED";
const string PKG_SQL_TABLE    = "pkg_area_overrides";
const int    PKG_LOAD_HISTORY = 5;
const int    PKG_HYSTERESIS   = 10;

// Module cache field suffixes (appended after PKG_[N])
const string PKGC_NAME  = "_NAME";
const string PKGC_SCRP  = "_SCRIPT";
const string PKGC_BOOT  = "_BOOT";
const string PKGC_SHUT  = "_SHUT";
const string PKGC_ENBL  = "_ENBL";
const string PKGC_PRI   = "_PRI";
const string PKGC_IVRL  = "_IVRL";
const string PKGC_MNPC  = "_MNPC";
const string PKGC_PSAT  = "_PSAT";
const string PKGC_AOVR  = "_AOVR";
const string PKGC_PHAS  = "_PHAS";
const string PKGC_DBG   = "_DBG";   // Debug variable name string for this package
const string PKGC_AUTH  = "_AUTH";  // Min admin role to manually toggle via console

// Per-area JSON mutable state keys
const string PKGJ_PAUSED    = "paused";
const string PKGJ_LAST_TICK = "lt";
const string PKGJ_RUN_COUNT = "rc";
const string PKGJ_ENBL_OVR  = "eo";   // per-area enabled override (-1 = no override)
const string PKGJ_IVRL_OVR  = "io";   // per-area interval override (0 = no override)
const string PKGJ_PSAT_OVR  = "po";   // per-area pause threshold override (0 = no override)

// ============================================================================
// SECTION 1: MODULE BOOT
// Reads core_package.2da once. Caches everything to module object.
// Call once from module OnLoad. Never reads the 2DA again at runtime.
// ============================================================================

void PackageBoot()
{
    object oMod = GetModule();
    if (GetLocalInt(oMod, "PKG_BOOTED")) return;
    SetLocalInt(oMod, "PKG_BOOTED", 1);

    int nRows = Get2DARowCount(PKG_2DA);
    SetLocalInt(oMod, "PKG_ROW_CNT", nRows);

    int i;
    for (i = 0; i < nRows; i++)
    {
        string sN = PKG_PFX + IntToString(i);

        string sName = Get2DAString(PKG_2DA, "PACKAGE",          i);
        int  nEnbl   = StringToInt(Get2DAString(PKG_2DA, "ENABLED",         i));
        int  nPri    = StringToInt(Get2DAString(PKG_2DA, "PRIORITY",        i));
        string sScrp = Get2DAString(PKG_2DA, "SCRIPT",           i);
        string sBoot = Get2DAString(PKG_2DA, "BOOT_SCRIPT",      i);
        string sShut = Get2DAString(PKG_2DA, "SHUTDOWN_SCRIPT",  i);
        int  nIvrl   = StringToInt(Get2DAString(PKG_2DA, "INTERVAL",        i));
        int  nMnpc   = StringToInt(Get2DAString(PKG_2DA, "MIN_PLAYERS",     i));
        int  nPsat   = StringToInt(Get2DAString(PKG_2DA, "PAUSE_THRESHOLD", i));
        int  nAovr   = StringToInt(Get2DAString(PKG_2DA, "AREA_OVERRIDE",   i));
        float fPhas  = StringToFloat(Get2DAString(PKG_2DA, "PHASE",         i));
        string sDbg  = Get2DAString(PKG_2DA, "DEBUG_VAR",  i);
        int    nAuth = StringToInt(Get2DAString(PKG_2DA, "AUTH_LEVEL", i));

        // Sanitize sentinels
        if (sScrp == "****") sScrp = "";
        if (sBoot == "****") sBoot = "";
        if (sShut == "****") sShut = "";
        if (sDbg  == "****") sDbg  = "";
        if (nIvrl <= 0) nIvrl = 1;
        if (nPri  <= 0) nPri  = 99;
        if (fPhas <= 0.0) fPhas = 0.5;

        SetLocalString(oMod, sN + PKGC_NAME, sName);
        SetLocalString(oMod, sN + PKGC_SCRP, sScrp);
        SetLocalString(oMod, sN + PKGC_BOOT, sBoot);
        SetLocalString(oMod, sN + PKGC_SHUT, sShut);
        SetLocalInt(oMod,    sN + PKGC_ENBL, nEnbl);
        SetLocalInt(oMod,    sN + PKGC_PRI,  nPri);
        SetLocalInt(oMod,    sN + PKGC_IVRL, nIvrl);
        SetLocalInt(oMod,    sN + PKGC_MNPC, nMnpc);
        SetLocalInt(oMod,    sN + PKGC_PSAT, nPsat);
        SetLocalInt(oMod,    sN + PKGC_AOVR, nAovr);
        SetLocalFloat(oMod,  sN + PKGC_PHAS, fPhas);
        SetLocalString(oMod, sN + PKGC_DBG,  sDbg);
        SetLocalInt(oMod,    sN + PKGC_AUTH, nAuth);

        // Reverse lookup: name -> row index
        if (sName != "")
            SetLocalInt(oMod, "PKG_IDX_" + sName, i);
    }

    WriteTimestampedLogEntry("[PACKAGE] Boot complete. " +
        IntToString(nRows) + " packages loaded from " + PKG_2DA + ".2da");
}

// ============================================================================
// SECTION 2: MODULE CACHE ACCESSORS - O(1) reads after boot
// ============================================================================

int PackageRowCount()
{ return GetLocalInt(GetModule(), "PKG_ROW_CNT"); }

// Get row index for a package name. Returns -1 if not found.
int PackageGetRow(string sName)
{
    object oMod = GetModule();
    int nRow = GetLocalInt(oMod, "PKG_IDX_" + sName);
    // Verify (row 0 is valid, GetLocalInt returns 0 for missing)
    if (GetLocalString(oMod, PKG_PFX + IntToString(nRow) + PKGC_NAME) == sName)
        return nRow;
    return -1;
}

// Row field accessors by row index
string PackageGetName(int nRow)   { return GetLocalString(GetModule(), PKG_PFX + IntToString(nRow) + PKGC_NAME); }
string PackageGetScript(int nRow) { return GetLocalString(GetModule(), PKG_PFX + IntToString(nRow) + PKGC_SCRP); }
string PackageGetBoot(int nRow)   { return GetLocalString(GetModule(), PKG_PFX + IntToString(nRow) + PKGC_BOOT); }
string PackageGetShut(int nRow)   { return GetLocalString(GetModule(), PKG_PFX + IntToString(nRow) + PKGC_SHUT); }
int    PackageIsEnabled(int nRow) { return GetLocalInt(GetModule(),    PKG_PFX + IntToString(nRow) + PKGC_ENBL); }
int    PackageGetPri(int nRow)    { return GetLocalInt(GetModule(),    PKG_PFX + IntToString(nRow) + PKGC_PRI);  }
int    PackageGetInterval(int nRow){ return GetLocalInt(GetModule(),   PKG_PFX + IntToString(nRow) + PKGC_IVRL); }
int    PackageGetMinPC(int nRow)  { return GetLocalInt(GetModule(),    PKG_PFX + IntToString(nRow) + PKGC_MNPC); }
int    PackageGetPauseAt(int nRow){ return GetLocalInt(GetModule(),    PKG_PFX + IntToString(nRow) + PKGC_PSAT); }
int    PackageGetAreaOvr(int nRow){ return GetLocalInt(GetModule(),    PKG_PFX + IntToString(nRow) + PKGC_AOVR); }
float  PackageGetPhase(int nRow)  { return GetLocalFloat(GetModule(),  PKG_PFX + IntToString(nRow) + PKGC_PHAS); }
string PackageGetDebugVar(int nRow){ return GetLocalString(GetModule(), PKG_PFX + IntToString(nRow) + PKGC_DBG); }
int    PackageGetAuthLevel(int nRow){ return GetLocalInt(GetModule(),   PKG_PFX + IntToString(nRow) + PKGC_AUTH); }

// ============================================================================
// SECTION 3: CPU LOAD HEURISTIC
// NWScript has no CPU access. We measure DelayCommand drift instead.
// core_dispatch records when it scheduled core_switch. core_switch reads
// the drift to estimate server load.
// ============================================================================

void RecordScheduledTick(object oMod, int nTick)
{
    SetLocalInt(oMod, PKG_SCHED_VAR, nTick);
}

int MeasureLoadDrift(object oMod)
{
    int nScheduled = GetLocalInt(oMod, PKG_SCHED_VAR);
    int nCurrent   = GetLocalInt(oMod, MG_TICK);
    int nDrift     = nCurrent - nScheduled;

    if      (nDrift <= 0) return 5;
    else if (nDrift == 1) return 35;
    else if (nDrift == 2) return 65;
    else                  return 90;
}

int UpdateLoadScore(object oMod, int nNewSample)
{
    int nSum = nNewSample;
    int i;
    for (i = PKG_LOAD_HISTORY - 1; i > 0; i--)
    {
        int nOld = GetLocalInt(oMod, "MG_LOAD_H" + IntToString(i - 1));
        SetLocalInt(oMod, "MG_LOAD_H" + IntToString(i), nOld);
        nSum += nOld;
    }
    SetLocalInt(oMod, "MG_LOAD_H0", nNewSample);
    int nAvg = nSum / PKG_LOAD_HISTORY;
    SetLocalInt(oMod, PKG_LOAD_VAR, nAvg);
    return nAvg;
}

int GetLoadScore()
{ return GetLocalInt(GetModule(), PKG_LOAD_VAR); }

// ============================================================================
// SECTION 4: SQL OVERRIDE LAYER
// ============================================================================

void PackageCreateTable()
{
    string sSQL =
        "CREATE TABLE IF NOT EXISTS " + PKG_SQL_TABLE + " (" +
        "area_tag TEXT NOT NULL, " +
        "package_id TEXT NOT NULL, " +
        "enabled INTEGER DEFAULT 1, " +
        "interval_ticks INTEGER DEFAULT 1, " +
        "pause_threshold INTEGER DEFAULT 0, " +
        "notes TEXT DEFAULT '', " +
        "PRIMARY KEY (area_tag, package_id)" +
        ");";
    sqlquery q = SqlPrepareQueryObject(GetModule(), sSQL);
    SqlStep(q);
}

void PackageSaveAreaOverride(string sAreaTag, string sPackageId,
    int bEnabled, int nInterval, int nPauseThresh, string sNotes = "")
{
    string sSQL =
        "INSERT OR REPLACE INTO " + PKG_SQL_TABLE +
        " (area_tag, package_id, enabled, interval_ticks, pause_threshold, notes)" +
        " VALUES (@area, @pkg, @en, @iv, @th, @nt);";
    sqlquery q = SqlPrepareQueryObject(GetModule(), sSQL);
    SqlBindString(q, "@area", sAreaTag);
    SqlBindString(q, "@pkg",  sPackageId);
    SqlBindInt(q,    "@en",   bEnabled);
    SqlBindInt(q,    "@iv",   nInterval);
    SqlBindInt(q,    "@th",   nPauseThresh);
    SqlBindString(q, "@nt",   sNotes);
    SqlStep(q);
}

void PackageDeleteAreaOverride(string sAreaTag, string sPackageId)
{
    string sSQL =
        "DELETE FROM " + PKG_SQL_TABLE +
        " WHERE area_tag = @area AND package_id = @pkg;";
    sqlquery q = SqlPrepareQueryObject(GetModule(), sSQL);
    SqlBindString(q, "@area", sAreaTag);
    SqlBindString(q, "@pkg",  sPackageId);
    SqlStep(q);
}

// ============================================================================
// SECTION 5: PER-AREA JSON - LOAD AND UNLOAD
// The JSON carries only mutable runtime state. Scripts/phases come from
// the module cache. This keeps the JSON small and fast to parse.
// ============================================================================

/* ----------------------------------------------------------------------------
   PackageLoad
   Called once at area boot (from core_enter.nss).
   Reads SQL area overrides (one query), builds per-area JSON.
   JSON structure (per package, stored in array indexed by 2DA row):
     { "p": paused, "lt": last_tick_ran, "rc": run_count,
       "eo": enabled_override, "io": interval_override, "po": pause_override }
---------------------------------------------------------------------------- */
void PackageLoad(object oArea)
{
    if (!GetIsObjectValid(oArea)) return;
    if (GetLocalString(oArea, PKG_JSON_VAR) != "") return;

    object oMod    = GetModule();
    int    nRows   = GetLocalInt(oMod, "PKG_ROW_CNT");
    string sAreaTag = GetTag(oArea);

    // Load SQL overrides into temporary module locals
    string sSQL =
        "SELECT package_id, enabled, interval_ticks, pause_threshold " +
        "FROM " + PKG_SQL_TABLE +
        " WHERE area_tag = @area;";
    sqlquery q = SqlPrepareQueryObject(oMod, sSQL);
    SqlBindString(q, "@area", sAreaTag);
    int nOvrCount = 0;
    while (SqlStep(q))
    {
        string sPkgId  = SqlGetString(q, 0);
        string sOvrPfx = "PKGO_" + sPkgId + "_";
        SetLocalInt(oMod, sOvrPfx + "HAS", 1);
        SetLocalInt(oMod, sOvrPfx + "EN",  SqlGetInt(q, 1));
        SetLocalInt(oMod, sOvrPfx + "IV",  SqlGetInt(q, 2));
        SetLocalInt(oMod, sOvrPfx + "PO",  SqlGetInt(q, 3));
        nOvrCount++;
    }

    // Build per-package JSON array.
    // Array is indexed by 2DA row number to allow O(1) lookup by row index.
    json jArr = JsonArray();
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sN    = PKG_PFX + IntToString(i);
        string sName = GetLocalString(oMod, sN + PKGC_NAME);
        int nAovr    = GetLocalInt(oMod,    sN + PKGC_AOVR);

        // Check for SQL area override
        int nEoOvr = -1;  // -1 = no override
        int nIoOvr = 0;
        int nPoOvr = 0;

        if (nAovr)
        {
            string sOvrPfx = "PKGO_" + sName + "_";
            if (GetLocalInt(oMod, sOvrPfx + "HAS"))
            {
                nEoOvr = GetLocalInt(oMod, sOvrPfx + "EN");
                nIoOvr = GetLocalInt(oMod, sOvrPfx + "IV");
                nPoOvr = GetLocalInt(oMod, sOvrPfx + "PO");
            }
        }

        json jPkg = JsonObject();
        jPkg = JsonObjectSet(jPkg, PKGJ_PAUSED,    JsonInt(0));
        jPkg = JsonObjectSet(jPkg, PKGJ_LAST_TICK,  JsonInt(0));
        jPkg = JsonObjectSet(jPkg, PKGJ_RUN_COUNT,  JsonInt(0));
        jPkg = JsonObjectSet(jPkg, PKGJ_ENBL_OVR,   JsonInt(nEoOvr));
        jPkg = JsonObjectSet(jPkg, PKGJ_IVRL_OVR,   JsonInt(nIoOvr));
        jPkg = JsonObjectSet(jPkg, PKGJ_PSAT_OVR,   JsonInt(nPoOvr));

        jArr = JsonArrayInsert(jArr, jPkg);
    }

    SetLocalString(oArea, PKG_JSON_VAR, JsonDump(jArr));

    // Clean up temporary override locals
    if (nOvrCount > 0)
    {
        for (i = 0; i < nRows; i++)
        {
            string sName   = GetLocalString(oMod, PKG_PFX + IntToString(i) + PKGC_NAME);
            string sOvrPfx = "PKGO_" + sName + "_";
            DeleteLocalInt(oMod, sOvrPfx + "HAS");
            DeleteLocalInt(oMod, sOvrPfx + "EN");
            DeleteLocalInt(oMod, sOvrPfx + "IV");
            DeleteLocalInt(oMod, sOvrPfx + "PO");
        }
    }

    if (GetLocalInt(oMod, MG_DEBUG_PKG))
        SendMessageToAllDMs("[PKG] Loaded " + IntToString(nRows) +
                            " packages for " + sAreaTag);
}

void PackageUnload(object oArea)
{
    DeleteLocalString(oArea, PKG_JSON_VAR);
}

// ============================================================================
// SECTION 6: RUNTIME STATE ACCESSORS - per-area JSON reads/writes
// These are the only functions that touch the JSON at runtime.
// core_switch uses these together with the module cache.
// ============================================================================

// Get mutable state for one package row.
// Returns a copy of the json object for this row.
json PackageGetState(object oArea, int nRow)
{
    string sJson = GetLocalString(oArea, PKG_JSON_VAR);
    if (sJson == "") return JsonObject();
    return JsonArrayGet(JsonParse(sJson), nRow);
}

// Write back mutable state for one package row.
void PackageSetState(object oArea, int nRow, json jPkg)
{
    string sJson = GetLocalString(oArea, PKG_JSON_VAR);
    if (sJson == "") return;
    json jArr = JsonParse(sJson);
    jArr = JsonArraySet(jArr, nRow, jPkg);
    SetLocalString(oArea, PKG_JSON_VAR, JsonDump(jArr));
}

/* ----------------------------------------------------------------------------
   PackageIsRunnable
   THE primary gate. Returns TRUE if this package should execute this tick.
   Combines module cache (O(1)) with JSON mutable state (one array read).

   nRow      - 2DA row index (from module cache)
   nLoad     - current load score 0-100
   nTick     - current tick
   nPCCount  - cached PC count for this area
---------------------------------------------------------------------------- */
int PackageIsRunnable(object oArea, int nRow, int nLoad, int nTick, int nPCCount)
{
    object oMod = GetModule();
    string sN   = PKG_PFX + IntToString(nRow);

    // 1. Global enabled check (module cache, O(1))
    if (!GetLocalInt(oMod, sN + PKGC_ENBL)) return FALSE;

    // 2. Script exists?
    if (GetLocalString(oMod, sN + PKGC_SCRP) == "") return FALSE;

    // 3. Min player check (module cache)
    int nMinPC = GetLocalInt(oMod, sN + PKGC_MNPC);
    if (nMinPC > 0 && nPCCount < nMinPC) return FALSE;

    // 4. Mutable state from JSON (one array element read)
    json jPkg = PackageGetState(oArea, nRow);

    // 5. Per-area enabled override check (-1 = use global)
    int nEoOvr = JsonGetInt(JsonObjectGet(jPkg, PKGJ_ENBL_OVR));
    if (nEoOvr == 0) return FALSE;   // Area has disabled this package

    // 6. Paused check (set by UpdatePauseStates)
    if (JsonGetInt(JsonObjectGet(jPkg, PKGJ_PAUSED)) == 1) return FALSE;

    // 7. Load threshold (use per-area override if set, else module cache)
    int nPoOvr  = JsonGetInt(JsonObjectGet(jPkg, PKGJ_PSAT_OVR));
    int nPauseAt = (nPoOvr > 0) ? nPoOvr : GetLocalInt(oMod, sN + PKGC_PSAT);
    if (nPauseAt > 0 && nLoad >= nPauseAt) return FALSE;

    // 8. Interval check (use per-area override if set, else module cache)
    int nIoOvr   = JsonGetInt(JsonObjectGet(jPkg, PKGJ_IVRL_OVR));
    int nInterval = (nIoOvr > 0) ? nIoOvr : GetLocalInt(oMod, sN + PKGC_IVRL);
    int nLastTick = JsonGetInt(JsonObjectGet(jPkg, PKGJ_LAST_TICK));
    if (nInterval > 1 && (nTick - nLastTick) < nInterval) return FALSE;

    return TRUE;
}

/* ----------------------------------------------------------------------------
   PackageRecordRun
   Updates last_tick_ran and run_count in the JSON.
   Called by core_switch after every successful dispatch.
---------------------------------------------------------------------------- */
void PackageRecordRun(object oArea, int nRow, int nTick)
{
    string sJson = GetLocalString(oArea, PKG_JSON_VAR);
    if (sJson == "") return;
    json jArr = JsonParse(sJson);
    json jPkg = JsonArrayGet(jArr, nRow);
    int  nCnt = JsonGetInt(JsonObjectGet(jPkg, PKGJ_RUN_COUNT)) + 1;
    jPkg = JsonObjectSet(jPkg, PKGJ_LAST_TICK,  JsonInt(nTick));
    jPkg = JsonObjectSet(jPkg, PKGJ_RUN_COUNT,  JsonInt(nCnt));
    jArr = JsonArraySet(jArr, nRow, jPkg);
    SetLocalString(oArea, PKG_JSON_VAR, JsonDump(jArr));
}

/* ----------------------------------------------------------------------------
   PackageUpdatePauseStates
   Called ONCE per tick before any package dispatches.
   Applies hysteresis: package paused at load 80 stays paused until load <= 70.
   Only writes JSON if something actually changed.
---------------------------------------------------------------------------- */
void PackageUpdatePauseStates(object oArea, int nLoad)
{
    string sJson = GetLocalString(oArea, PKG_JSON_VAR);
    if (sJson == "") return;

    object oMod  = GetModule();
    int    nRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    json   jArr  = JsonParse(sJson);
    int    bChanged = FALSE;

    int i;
    for (i = 0; i < nRows; i++)
    {
        // Read pause threshold: per-area override wins, then module cache
        json jPkg   = JsonArrayGet(jArr, i);
        int nPoOvr  = JsonGetInt(JsonObjectGet(jPkg, PKGJ_PSAT_OVR));
        int nThresh = (nPoOvr > 0) ? nPoOvr :
                      GetLocalInt(oMod, PKG_PFX + IntToString(i) + PKGC_PSAT);

        if (nThresh == 0) continue;  // Never pauses

        int bPaused = JsonGetInt(JsonObjectGet(jPkg, PKGJ_PAUSED));
        int bShouldPause;

        if (bPaused)
            bShouldPause = (nLoad >= (nThresh - PKG_HYSTERESIS)) ? 1 : 0;
        else
            bShouldPause = (nLoad >= nThresh) ? 1 : 0;

        if (bShouldPause != bPaused)
        {
            jPkg = JsonObjectSet(jPkg, PKGJ_PAUSED, JsonInt(bShouldPause));
            jArr = JsonArraySet(jArr, i, jPkg);
            bChanged = TRUE;

            if (GetLocalInt(oMod, MG_DEBUG_PKG))
            {
                string sName  = GetLocalString(oMod, PKG_PFX + IntToString(i) + PKGC_NAME);
                string sState = bShouldPause ? "PAUSED" : "RESUMED";
                SendMessageToAllDMs("[PKG] " + sName + " " + sState +
                    " (load=" + IntToString(nLoad) +
                    " thresh=" + IntToString(nThresh) + ")");
            }
        }
    }

    if (bChanged)
        SetLocalString(oArea, PKG_JSON_VAR, JsonDump(jArr));
}

// ============================================================================
// SECTION 7: BOOT AND SHUTDOWN LIFECYCLE
// ============================================================================

void PackageRunBootScripts(object oArea)
{
    object oMod  = GetModule();
    int    nRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    float  fDelay = 0.1;
    int i;
    for (i = 0; i < nRows; i++)
    {
        if (!GetLocalInt(oMod, PKG_PFX + IntToString(i) + PKGC_ENBL)) continue;
        string sBoot = GetLocalString(oMod, PKG_PFX + IntToString(i) + PKGC_BOOT);
        if (sBoot == "") continue;

        // Check per-area enabled override
        json jPkg  = PackageGetState(oArea, i);
        int nEoOvr = JsonGetInt(JsonObjectGet(jPkg, PKGJ_ENBL_OVR));
        if (nEoOvr == 0) continue;   // Area has disabled this package

        DelayCommand(fDelay, ExecuteScript(sBoot, oArea));
        fDelay += 0.1;
    }
}

void PackageRunShutdownScripts(object oArea)
{
    object oMod  = GetModule();
    int    nRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    int i;
    for (i = 0; i < nRows; i++)
    {
        if (!GetLocalInt(oMod, PKG_PFX + IntToString(i) + PKGC_ENBL)) continue;
        string sShut = GetLocalString(oMod, PKG_PFX + IntToString(i) + PKGC_SHUT);
        if (sShut == "") continue;

        // Check per-area enabled override
        json jPkg  = PackageGetState(oArea, i);
        int nEoOvr = JsonGetInt(JsonObjectGet(jPkg, PKGJ_ENBL_OVR));
        if (nEoOvr == 0) continue;

        ExecuteScript(sShut, oArea);
    }
}

// ============================================================================
// SECTION 8: RUNTIME ADMINISTRATION API
// ============================================================================

// Enable or disable a package for a specific area. bPersist saves to SQL.
void PackageSetEnabled(object oArea, string sName, int bEnabled, int bPersist = FALSE)
{
    int nRow = PackageGetRow(sName);
    if (nRow < 0) return;
    if (!PackageGetAreaOvr(nRow))
    {
        SendMessageToAllDMs("[PKG] Cannot override " + sName + ": AREA_OVERRIDE=0");
        return;
    }

    json jPkg = PackageGetState(oArea, nRow);
    jPkg = JsonObjectSet(jPkg, PKGJ_ENBL_OVR, JsonInt(bEnabled ? 1 : 0));
    PackageSetState(oArea, nRow, jPkg);

    if (bPersist)
    {
        int nIvrl = PackageGetInterval(nRow);
        int nPsat = PackageGetPauseAt(nRow);
        PackageSaveAreaOverride(GetTag(oArea), sName, bEnabled, nIvrl, nPsat);
    }

    SendMessageToAllDMs("[PKG] " + sName + " " +
        (bEnabled ? "ENABLED" : "DISABLED") + " in " + GetTag(oArea) +
        (bPersist ? " [SAVED]" : " [RUNTIME]"));
}

// Change interval for a specific area.
void PackageSetInterval(object oArea, string sName, int nNewInterval,
                        int bPersist = FALSE)
{
    if (nNewInterval < 1) nNewInterval = 1;
    int nRow = PackageGetRow(sName);
    if (nRow < 0) return;

    json jPkg = PackageGetState(oArea, nRow);
    jPkg = JsonObjectSet(jPkg, PKGJ_IVRL_OVR, JsonInt(nNewInterval));
    PackageSetState(oArea, nRow, jPkg);

    if (bPersist)
    {
        int nEnbl = PackageIsEnabled(nRow);
        int nPsat = PackageGetPauseAt(nRow);
        PackageSaveAreaOverride(GetTag(oArea), sName, nEnbl, nNewInterval, nPsat);
    }

    SendMessageToAllDMs("[PKG] " + sName + " interval=" + IntToString(nNewInterval) +
        " in " + GetTag(oArea) + (bPersist ? " [SAVED]" : " [RUNTIME]"));
}

// Change pause threshold for a specific area.
void PackageSetThreshold(object oArea, string sName, int nNewThresh,
                         int bPersist = FALSE)
{
    int nRow = PackageGetRow(sName);
    if (nRow < 0) return;

    json jPkg = PackageGetState(oArea, nRow);
    jPkg = JsonObjectSet(jPkg, PKGJ_PSAT_OVR, JsonInt(nNewThresh));
    PackageSetState(oArea, nRow, jPkg);

    if (bPersist)
    {
        int nEnbl = PackageIsEnabled(nRow);
        int nIvrl = PackageGetInterval(nRow);
        PackageSaveAreaOverride(GetTag(oArea), sName, nEnbl, nIvrl, nNewThresh);
    }

    SendMessageToAllDMs("[PKG] " + sName + " threshold=" + IntToString(nNewThresh) +
        " in " + GetTag(oArea) + (bPersist ? " [SAVED]" : " [RUNTIME]"));
}

// Reload JSON for an area from 2DA+SQL. Picks up 2DA edits without restart.
void PackageResetArea(object oArea)
{
    PackageUnload(oArea);
    PackageLoad(oArea);
    SendMessageToAllDMs("[PKG] Packages reloaded for " + GetTag(oArea));
}

// ============================================================================
// SECTION 9: DM DIAGNOSTICS
// ============================================================================

void PackageDump(object oArea, object oTarget)
{
    string sJson = GetLocalString(oArea, PKG_JSON_VAR);
    if (sJson == "")
    {
        SendMessageToPC(oTarget, "[PKG] Not loaded in " + GetTag(oArea));
        return;
    }

    object oMod  = GetModule();
    int    nRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    int    nLoad = GetLoadScore();
    json   jArr  = JsonParse(sJson);

    SendMessageToPC(oTarget,
        "=== PACKAGES: " + GetTag(oArea) + "  Load=" + IntToString(nLoad) + "% ===");

    int i;
    for (i = 0; i < nRows; i++)
    {
        string sN    = PKG_PFX + IntToString(i);
        string sName = GetLocalString(oMod, sN + PKGC_NAME);
        int  nEnbl   = GetLocalInt(oMod, sN + PKGC_ENBL);
        int  nPri    = GetLocalInt(oMod, sN + PKGC_PRI);
        int  nPsat   = GetLocalInt(oMod, sN + PKGC_PSAT);
        int  nIvrl   = GetLocalInt(oMod, sN + PKGC_IVRL);
        float fPhas  = GetLocalFloat(oMod, sN + PKGC_PHAS);

        json jPkg    = JsonArrayGet(jArr, i);
        int nPaused  = JsonGetInt(JsonObjectGet(jPkg, PKGJ_PAUSED));
        int nRuns    = JsonGetInt(JsonObjectGet(jPkg, PKGJ_RUN_COUNT));
        int nEoOvr   = JsonGetInt(JsonObjectGet(jPkg, PKGJ_ENBL_OVR));

        string sState;
        if (!nEnbl)              sState = "DISABLED";
        else if (nEoOvr == 0)    sState = "AREA-OFF";
        else if (nPaused)        sState = "PAUSED";
        else                     sState = "RUNNING";

        string sPad = sName;
        while (GetStringLength(sPad) < 18) sPad = sPad + " ";

        SendMessageToPC(oTarget,
            " [" + IntToString(nPri) + "] " + sPad + " " + sState +
            "  thresh=" + IntToString(nPsat) +
            "  ivrl=" + IntToString(nIvrl) +
            "  phase=" + FloatToString(fPhas, 0, 1) +
            "  runs=" + IntToString(nRuns));
    }
}

void PackageDumpAll(object oTarget)
{
    object oMod    = GetModule();
    int    nActive = GetLocalInt(oMod, "MG_ACTIVE_CNT");

    if (nActive == 0)
    {
        SendMessageToPC(oTarget, "[PKG] No active areas.");
        return;
    }

    SendMessageToPC(oTarget, "[PKG] Active areas: " + IntToString(nActive));
    int i;
    for (i = 1; i <= nActive; i++)
    {
        object oArea = GetLocalObject(oMod, "MG_ACTIVE_" + IntToString(i));
        if (GetIsObjectValid(oArea))
            PackageDump(oArea, oTarget);
    }
}

// Single-line status string for a named package in an area
string PackageGetStatus(object oArea, string sName)
{
    int nRow = PackageGetRow(sName);
    if (nRow < 0) return "[PKG] Package '" + sName + "' not found";
    if (GetLocalString(oArea, PKG_JSON_VAR) == "")
        return "[PKG] Not loaded in " + GetTag(oArea);

    json jPkg   = PackageGetState(oArea, nRow);
    int nPaused = JsonGetInt(JsonObjectGet(jPkg, PKGJ_PAUSED));
    int nRuns   = JsonGetInt(JsonObjectGet(jPkg, PKGJ_RUN_COUNT));
    int nLast   = JsonGetInt(JsonObjectGet(jPkg, PKGJ_LAST_TICK));
    int nEnbl   = PackageIsEnabled(nRow);

    string sState;
    if (!nEnbl)        sState = "DISABLED";
    else if (nPaused)  sState = "PAUSED";
    else               sState = "RUNNING";

    return sName + ": " + sState +
           " | runs=" + IntToString(nRuns) +
           " | lastTick=" + IntToString(nLast);
}
