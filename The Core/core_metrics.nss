/* ============================================================================
    core_metrics.nss
    DOWE Performance Metrics Package - Area Stats Collector
    DOWE v2.3 | Production Standard

    ============================================================================
    PURPOSE
    ============================================================================
    Tracks real-time server performance data:
    - Average CPU load score per area per tick
    - Peak creature count per area
    - Active area count over time
    - Package run counts and pause events
    - Exposes data via DM command:  /*metrics "password"

    This is a LIBRARY file with no void main().
    It is #included by pkg_metrics.nss (the tick wrapper).

    ============================================================================
    INTEGRATION
    ============================================================================
    1. Add to core_package.2da:
       PACKAGE=metrics, ENABLED=1, PRIORITY=99, SCRIPT=pkg_metrics,
       BOOT_SCRIPT=****, SHUTDOWN_SCRIPT=****, INTERVAL=10, MIN_PLAYERS=0,
       PAUSE_THRESHOLD=0, AREA_OVERRIDE=0, PHASE=4.0,
       DEBUG_VAR=MG_DEBUG_METRICS, AUTH_LEVEL=1

    2. Add to core_conductor.nss:
       const string MG_DEBUG_METRICS = "MG_DEBUG_METR";

    3. Add to core_admin.nss AdminSetDebugAll():
       SetLocalInt(oMod, MG_DEBUG_METRICS, nVal);

    4. Add /*metrics to the admin command handler (see AdminShowMetrics below).
       In core_admin.nss, add inside AdminHandleCommand():
         if (sCmd == "/*metrics" && nRole >= ADM_ROLE_MOD)
         {
             AdminShowMetrics(oPC);
             return;
         }

    ============================================================================
    HOW IT WORKS
    ============================================================================
    Every 10 ticks (60 seconds), pkg_metrics.nss fires.
    MetricsTick(oArea) is called for each active area and records:
      - Current NPC count, PC count
      - Current load score (SW_LD local on area, written by core_switch)
      - Updates rolling averages on the MODULE object

    Module-level rolling stats:
      MET_TOTAL_TICKS       - total ticks since boot
      MET_AREA_PEAK         - peak simultaneous active areas ever seen
      MET_LOAD_SAMPLES      - number of load samples taken
      MET_LOAD_SUM          - sum of all load samples (for average)
      MET_LOAD_PEAK         - highest single load score ever seen
      MET_NPC_PEAK          - highest NPC count ever seen in one area
      MET_PAUSE_EVENTS      - total package pause events across all areas
      MET_BOOT_TICK         - MG_TICK value at MetricsBoot() call

    Per-session window (last 100 samples, rolling):
      MET_WIN_IDX           - current window index (0-99)
      MET_WIN_[N]_LOAD      - load score sample N
      MET_WIN_[N]_AREAS     - active area count sample N
      MET_WIN_[N]_NPCS      - NPC count sample N

   ============================================================================
*/

#include "core_conductor"

// ============================================================================
// CONSTANTS
// ============================================================================

const string MET_PFX       = "MET_";
const string MET_BOOTED    = "MET_BOOTED";
const int    MET_WIN_SIZE  = 100;  // Rolling window sample count

// ============================================================================
// BOOT
// Call from pkg_metrics_boot.nss (wired as BOOT_SCRIPT in core_package.2da).
// ============================================================================

void MetricsBoot()
{
    object oMod = GetModule();
    if (GetLocalInt(oMod, MET_BOOTED)) return;
    SetLocalInt(oMod, MET_BOOTED, 1);

    SetLocalInt(oMod, "MET_TOTAL_TICKS",  0);
    SetLocalInt(oMod, "MET_AREA_PEAK",    0);
    SetLocalInt(oMod, "MET_LOAD_SAMPLES", 0);
    SetLocalInt(oMod, "MET_LOAD_SUM",     0);
    SetLocalInt(oMod, "MET_LOAD_PEAK",    0);
    SetLocalInt(oMod, "MET_NPC_PEAK",     0);
    SetLocalInt(oMod, "MET_PAUSE_EVENTS", 0);
    SetLocalInt(oMod, "MET_WIN_IDX",      0);
    SetLocalInt(oMod, "MET_BOOT_TICK",    GetLocalInt(oMod, MG_TICK));

    WriteTimestampedLogEntry("[METRICS] Boot complete. Collecting performance data.");
}

// ============================================================================
// TICK - Called by pkg_metrics.nss for each active area
// ============================================================================

void MetricsTick(object oArea)
{
    object oMod  = GetModule();

    // Read current state from area locals written by core_switch
    int nLoad    = GetLocalInt(oArea, "SW_LD");    // Load score 0-100
    int nNPCCnt  = GetLocalInt(oArea, MG_HAS_NPC); // NPC presence count
    int nPCCnt   = GetLocalInt(oArea, MG_HAS_PC);  // PC presence count
    int nActive  = GetLocalInt(oMod,  "MG_ACTIVE_CNT");
    int nTick    = GetLocalInt(oMod,  MG_TICK);

    // Update total ticks
    int nTotalTicks = GetLocalInt(oMod, "MET_TOTAL_TICKS") + 1;
    SetLocalInt(oMod, "MET_TOTAL_TICKS", nTotalTicks);

    // Peak active areas
    if (nActive > GetLocalInt(oMod, "MET_AREA_PEAK"))
        SetLocalInt(oMod, "MET_AREA_PEAK", nActive);

    // Peak NPC count per area
    if (nNPCCnt > GetLocalInt(oMod, "MET_NPC_PEAK"))
        SetLocalInt(oMod, "MET_NPC_PEAK", nNPCCnt);

    // Rolling load average
    int nSamples = GetLocalInt(oMod, "MET_LOAD_SAMPLES") + 1;
    int nSum     = GetLocalInt(oMod, "MET_LOAD_SUM") + nLoad;
    SetLocalInt(oMod, "MET_LOAD_SAMPLES", nSamples);
    SetLocalInt(oMod, "MET_LOAD_SUM",     nSum);

    // Peak load
    if (nLoad > GetLocalInt(oMod, "MET_LOAD_PEAK"))
        SetLocalInt(oMod, "MET_LOAD_PEAK", nLoad);

    // Pause event counting: check if this tick the area had any paused packages
    // core_switch writes SW_LC (last check) per area - used here as proxy for activity
    // A more precise count would require per-package pause event hooks (future work)

    // Rolling window (circular buffer for last MET_WIN_SIZE samples)
    int nWinIdx = GetLocalInt(oMod, "MET_WIN_IDX");
    string sW   = "MET_WIN_" + IntToString(nWinIdx) + "_";
    SetLocalInt(oMod, sW + "LOAD",  nLoad);
    SetLocalInt(oMod, sW + "AREAS", nActive);
    SetLocalInt(oMod, sW + "NPCS",  nNPCCnt + nPCCnt);
    SetLocalInt(oMod, sW + "TICK",  nTick);
    // Advance window index (wraps around)
    SetLocalInt(oMod, "MET_WIN_IDX", (nWinIdx + 1) % MET_WIN_SIZE);
}

// ============================================================================
// STATUS REPORT - Call from AdminHandleCommand via /*metrics
// ============================================================================

void MetricsReport(object oPC)
{
    object oMod = GetModule();

    int nTotalTicks  = GetLocalInt(oMod, "MET_TOTAL_TICKS");
    int nAreaPeak    = GetLocalInt(oMod, "MET_AREA_PEAK");
    int nLoadSamples = GetLocalInt(oMod, "MET_LOAD_SAMPLES");
    int nLoadSum     = GetLocalInt(oMod, "MET_LOAD_SUM");
    int nLoadPeak    = GetLocalInt(oMod, "MET_LOAD_PEAK");
    int nNPCPeak     = GetLocalInt(oMod, "MET_NPC_PEAK");
    int nBootTick    = GetLocalInt(oMod, "MET_BOOT_TICK");
    int nNowTick     = GetLocalInt(oMod, MG_TICK);
    int nActive      = GetLocalInt(oMod, "MG_ACTIVE_CNT");

    int nAvgLoad = (nLoadSamples > 0) ? (nLoadSum / nLoadSamples) : 0;
    int nUptimeT = nNowTick - nBootTick;
    int nUptimeM = (nUptimeT * 6) / 60;  // ticks to minutes (6s/tick)
    int nUptimeH = nUptimeM / 60;
    int nUptimeRm= nUptimeM % 60;

    // Compute rolling window stats (last MET_WIN_SIZE samples)
    int nWinIdx  = GetLocalInt(oMod, "MET_WIN_IDX");
    int nWinLoad = 0; int nWinArea = 0; int nWinNPC = 0; int nWinCnt = 0;
    int wi;
    for (wi = 0; wi < MET_WIN_SIZE; wi++)
    {
        string sW = "MET_WIN_" + IntToString(wi) + "_";
        int nSampleTick = GetLocalInt(oMod, sW + "TICK");
        if (nSampleTick == 0) continue;  // Slot not filled yet
        nWinLoad += GetLocalInt(oMod, sW + "LOAD");
        nWinArea += GetLocalInt(oMod, sW + "AREAS");
        nWinNPC  += GetLocalInt(oMod, sW + "NPCS");
        nWinCnt++;
    }
    int nWinAvgLoad = (nWinCnt > 0) ? (nWinLoad / nWinCnt) : 0;
    int nWinAvgArea = (nWinCnt > 0) ? (nWinArea / nWinCnt) : 0;
    int nWinAvgNPC  = (nWinCnt > 0) ? (nWinNPC  / nWinCnt) : 0;

    // Output to DM
    SendMessageToPC(oPC, "============= DOWE METRICS =============");
    SendMessageToPC(oPC,
        "Uptime: " + IntToString(nUptimeH) + "h " + IntToString(nUptimeRm) + "m" +
        "  |  Tick: " + IntToString(nNowTick) +
        "  |  ActiveAreas: " + IntToString(nActive));
    SendMessageToPC(oPC,
        "ALL-TIME:  AvgLoad=" + IntToString(nAvgLoad) + "%" +
        "  PeakLoad=" + IntToString(nLoadPeak) + "%" +
        "  PeakAreas=" + IntToString(nAreaPeak) +
        "  PeakNPCs=" + IntToString(nNPCPeak));
    SendMessageToPC(oPC,
        "LAST " + IntToString(nWinCnt) + " SAMPLES:  AvgLoad=" + IntToString(nWinAvgLoad) + "%" +
        "  AvgAreas=" + IntToString(nWinAvgArea) +
        "  AvgNPCs=" + IntToString(nWinAvgNPC));

    // Per-package run counts
    object oArea = GetArea(oPC);
    if (GetIsObjectValid(oArea))
    {
        int nRows = GetLocalInt(oMod, "PKG_ROW_CNT");
        string sJson = GetLocalString(oArea, "PKG_JSON");
        if (sJson != "")
        {
            json jArr = JsonParse(sJson);
            SendMessageToPC(oPC, "--- PACKAGES in " + GetTag(oArea) + " ---");
            int pi;
            for (pi = 0; pi < nRows; pi++)
            {
                string sPfx  = "PKG_" + IntToString(pi);
                string sName = GetLocalString(oMod, sPfx + "_NAME");
                if (sName == "") continue;
                json   jPkg  = JsonArrayGet(jArr, pi);
                int    nRC   = JsonGetInt(JsonObjectGet(jPkg, "rc"));
                int    nPaus = JsonGetInt(JsonObjectGet(jPkg, "p"));
                SendMessageToPC(oPC,
                    "  " + sName + "  runs=" + IntToString(nRC) +
                    (nPaus ? "  [PAUSED]" : ""));
            }
        }
    }
    SendMessageToPC(oPC, "========================================");
}
