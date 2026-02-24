/* ============================================================================
    DOWE - core_switch.nss
    Area Switchboard - Data-Driven Single-Pass Dispatch

    ============================================================================
    PURPOSE
    ============================================================================
    The area's central nervous system. Runs once per heartbeat per active area.
    Executes in a strict sequence:

      Phase 0: Maintenance (ghost clean, expiry cull, despawn checks)
      Phase 1: Load measurement
      Phase 2: Pause state update
      Phase 3: Package dispatch (one pass, reads module cache + per-area JSON)
      Phase 4: Grid position update

    ============================================================================
    DESIGN
    ============================================================================
    This script never lists package names. It reads the row count from the
    module cache (written by PackageBoot) and iterates numerically.
    Adding a package to core_package.2da is sufficient - no changes here.

    The script is an ExecuteScript target with OBJECT_SELF = the area.
    It is called by core_dispatch with a small per-area stagger so multiple
    areas don't all process simultaneously.

   ============================================================================
*/

#include "core_conductor"
#include "core_registry"
#include "core_package"
#include "core_grid"

void main()
{
    object oArea = OBJECT_SELF;
    object oMod  = GetModule();
    int    nTick = GetLocalInt(oMod, MG_TICK);

    // =========================================================================
    // PHASE 0: MAINTENANCE
    // Staggered slightly into the tick window so they don't fire simultaneously.
    // Uses interval guards so they don't run every single tick.
    // =========================================================================

    int nLastGhost = GetLocalInt(oArea, "SW_LG");
    if (nTick >= nLastGhost + MG_SW_GHOST_INTERVAL)
    {
        SetLocalInt(oArea, "SW_LG", nTick);
        DelayCommand(MG_SW_PHASE_MAINT, RegistryClean(oArea));
    }

    int nLastCull = GetLocalInt(oArea, "SW_LC");
    if (nTick >= nLastCull + MG_SW_CULL_INTERVAL)
    {
        SetLocalInt(oArea, "SW_LC", nTick);
        DelayCommand(MG_SW_PHASE_CULL, RegistryCull_Void(oArea));
    }

    int nLastDesp = GetLocalInt(oArea, "SW_LD");
    if (nTick >= nLastDesp + MG_SW_DESP_INTERVAL)
    {
        SetLocalInt(oArea, "SW_LD", nTick);
        DelayCommand(MG_SW_PHASE_DESP, RegistryCheckDespawn_Void(oArea));
    }

    // =========================================================================
    // PHASE 1: LOAD MEASUREMENT
    // =========================================================================

    int nLoadSample = MeasureLoadDrift(oMod);
    int nLoad       = UpdateLoadScore(oMod, nLoadSample);

    // =========================================================================
    // PHASE 2: PAUSE STATE UPDATE
    // Must happen before any package is dispatched.
    // =========================================================================

    PackageUpdatePauseStates(oArea, nLoad);

    // =========================================================================
    // PHASE 3: PACKAGE DISPATCH
    // Reads module cache (O(1)) for script/phase/interval.
    // Reads per-area JSON for mutable state (paused, last_tick, override).
    // No package names hardcoded here - fully data-driven from 2DA.
    // =========================================================================

    int nRows    = GetLocalInt(oMod, "PKG_ROW_CNT");
    int nPCCount = RegistryPCCount(oArea);

    int i;
    for (i = 0; i < nRows; i++)
    {
        // PackageIsRunnable combines module cache + JSON in one call
        if (!PackageIsRunnable(oArea, i, nLoad, nTick, nPCCount)) continue;

        // Get script and phase from module cache (O(1))
        string sScript = GetLocalString(oMod, PKG_PFX + IntToString(i) + PKGC_SCRP);
        float  fPhase  = GetLocalFloat(oMod,  PKG_PFX + IntToString(i) + PKGC_PHAS);

        if (sScript == "") continue;

        // ---------------------------------------------------------------
        // SURGICAL DEBUG WRAPPER (zero cost in production)
        // Fires ONLY if: master debug on AND this package's DEBUG_VAR is on.
        // DEBUG_VAR is the string name of a module-level int (e.g. "MG_DEBUG_AI").
        // Set it via: /*debug ai on "password"
        // ---------------------------------------------------------------
        if (GetLocalInt(oMod, MG_DEBUG))
        {
            string sDbgVar = GetLocalString(oMod, PKG_PFX + IntToString(i) + PKGC_DBG);
            if (sDbgVar != "" && GetLocalInt(oMod, sDbgVar))
            {
                string sPkgName = GetLocalString(oMod, PKG_PFX + IntToString(i) + PKGC_NAME);
                SendMessageToAllDMs("[DEBUG] Dispatch: " + sPkgName +
                    "  Area=" + GetTag(oArea) +
                    "  T="    + IntToString(nTick) +
                    "  Load=" + IntToString(nLoad) + "%");
            }
        }

        // Record the run BEFORE dispatching (updates last_tick)
        PackageRecordRun(oArea, i, nTick);

        // Dispatch with phase stagger
        DelayCommand(fPhase, ExecuteScript(sScript, oArea));
    }

    // =========================================================================
    // PHASE 4: GRID POSITION UPDATE
    // Handled separately from the package loop because it is infrastructure,
    // not a package. It always fires on its own interval when load < 95.
    // =========================================================================

    int nLastGrid = GetLocalInt(oArea, "SW_LGD");
    int nGridIvrl = GridGetUpdateInterval();
    if (nTick >= nLastGrid + nGridIvrl && nLoad < 95)
    {
        SetLocalInt(oArea, "SW_LGD", nTick);
        DelayCommand(MG_SW_PHASE_GRID, GridTickUpdate(oArea));
    }

    // BUG FIX (Session 11): Master MG_DEBUG gate added.
    // Previously MG_DEBUG_PKG fired debug output even when master debug was OFF.
    // Now requires both the master toggle AND the specific sub-toggle to be set.
    if (GetLocalInt(oMod, MG_DEBUG) && GetLocalInt(oMod, MG_DEBUG_PKG))
        SendMessageToAllDMs("[SWITCH] " + GetTag(oArea) +
                            " T=" + IntToString(nTick) +
                            " Load=" + IntToString(nLoad) + "%");
}
