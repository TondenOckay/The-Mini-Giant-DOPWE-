/* ============================================================================
    DOWE - core_registry_hotreload.nss
    Hot-Reload Library for Core 2DAs
    DOWE v2.3 | Production Standard | Final

    ============================================================================
    PURPOSE
    ============================================================================
    Allows the server admin to reload core 2DA files without a server restart.
    After hot-reload, the next time an area boots it uses the new 2DA data.
    Already-running areas keep their current data until they cycle.

    These functions are called by core_admin.nss via the /*reload commands.
    You do NOT need to call these directly. The admin system handles it.

    ============================================================================
    BUG FIXED
    ============================================================================
    ORIGINAL BUG: In the old hotreload script, line 84 read:
      int nFlag = GetLocalInt(oMod, sN + "_FLAG");
    AFTER deleting that same variable on line 66.
    So nFlag was always 0 and the reverse-lookup by flag was never cleaned.

    FIX: The reverse-lookup by flag now uses the cached nFlag value that was
    already read BEFORE the deletion loop begins.

   ============================================================================
*/

#include "core_conductor"
#include "core_registry"
#include "core_package"
#include "core_grid"
#include "core_ai_gps"

// ============================================================================
// REGISTRY HOT RELOAD
// ============================================================================

int RegistryHotReload()
{
    object oMod = GetModule();

    // Get current row count BEFORE clearing
    int nOldRows = GetLocalInt(oMod, "RG_ROW_CNT");

    // Clear boot guard so RegistryBoot() will re-read the 2DA
    DeleteLocalInt(oMod, "RG_BOOTED");

    // Clear all cached row data
    int i;
    for (i = 0; i < nOldRows; i++)
    {
        string sN = RG_PFX + IntToString(i);

        // FIX: Read the flag BEFORE deleting it, so we can delete the reverse-lookup
        int nFlag = GetLocalInt(oMod, sN + RGC_FLAG);

        // Delete all cached fields for this row
        DeleteLocalInt(oMod,    sN + RGC_FLAG);
        DeleteLocalString(oMod, sN + RGC_STAMP);
        DeleteLocalString(oMod, sN + RGC_PFX);
        DeleteLocalInt(oMod,    sN + RGC_CDKEY);
        DeleteLocalInt(oMod,    sN + RGC_ACCT);
        DeleteLocalInt(oMod,    sN + RGC_OWNER);
        DeleteLocalInt(oMod,    sN + RGC_AENT);
        DeleteLocalInt(oMod,    sN + RGC_ASPW);
        DeleteLocalInt(oMod,    sN + RGC_GATE);
        DeleteLocalInt(oMod,    sN + RGC_GHOST);
        DeleteLocalInt(oMod,    sN + RGC_DCULL);
        DeleteLocalInt(oMod,    sN + RGC_EXP);
        DeleteLocalFloat(oMod,  sN + RGC_DDIST);
        DeleteLocalInt(oMod,    sN + RGC_ISPC);
        DeleteLocalInt(oMod,    sN + RGC_ISCREAT);
        DeleteLocalInt(oMod,    sN + RGC_CULL);
        DeleteLocalString(oMod, sN + RGC_PVAR);

        // Delete reverse-lookup by flag (FIX: using value read BEFORE deletion)
        if (nFlag > 0)
            DeleteLocalInt(oMod, "RG_FLAG_" + IntToString(nFlag));
    }

    // Clear composite flags
    DeleteLocalInt(oMod, "RG_COMP_PLAYERS");
    DeleteLocalInt(oMod, "RG_COMP_CREATURES");
    DeleteLocalInt(oMod, "RG_COMP_CULLABLE");
    DeleteLocalInt(oMod, "RG_ROW_CNT");

    // Re-read from 2DA
    RegistryBoot();

    int nNewRows = GetLocalInt(oMod, "RG_ROW_CNT");
    if (nNewRows == 0)
    {
        WriteTimestampedLogEntry("[HOTRELOAD] ERROR: Registry reload failed - no rows.");
        SendMessageToAllDMs("[HOTRELOAD] ERROR: Registry reload FAILED.");
        return FALSE;
    }

    WriteTimestampedLogEntry("[HOTRELOAD] Registry: " +
        IntToString(nOldRows) + " old -> " + IntToString(nNewRows) + " new rows.");
    SendMessageToAllDMs("[HOTRELOAD] Registry reloaded (" +
        IntToString(nNewRows) + " types).");
    return TRUE;
}

// ============================================================================
// PACKAGE HOT RELOAD
// ============================================================================

int PackageHotReload()
{
    object oMod = GetModule();

    int nOldRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    DeleteLocalInt(oMod, "PKG_BOOTED");

    int i;
    for (i = 0; i < nOldRows; i++)
    {
        string sN    = PKG_PFX + IntToString(i);
        string sName = GetLocalString(oMod, sN + PKGC_NAME);

        DeleteLocalString(oMod, sN + PKGC_NAME);
        DeleteLocalString(oMod, sN + PKGC_SCRP);
        DeleteLocalString(oMod, sN + PKGC_BOOT);
        DeleteLocalString(oMod, sN + PKGC_SHUT);
        DeleteLocalInt(oMod,    sN + PKGC_ENBL);
        DeleteLocalInt(oMod,    sN + PKGC_PRI);
        DeleteLocalInt(oMod,    sN + PKGC_IVRL);
        DeleteLocalInt(oMod,    sN + PKGC_MNPC);
        DeleteLocalInt(oMod,    sN + PKGC_PSAT);
        DeleteLocalInt(oMod,    sN + PKGC_AOVR);
        DeleteLocalFloat(oMod,  sN + PKGC_PHAS);
        DeleteLocalString(oMod, sN + PKGC_DBG);
        DeleteLocalInt(oMod,    sN + PKGC_AUTH);

        if (sName != "")
            DeleteLocalInt(oMod, "PKG_IDX_" + sName);
    }
    DeleteLocalInt(oMod, "PKG_ROW_CNT");

    PackageBoot();

    int nNewRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    if (nNewRows == 0)
    {
        WriteTimestampedLogEntry("[HOTRELOAD] ERROR: Package reload failed - no rows.");
        SendMessageToAllDMs("[HOTRELOAD] ERROR: Package reload FAILED.");
        return FALSE;
    }

    WriteTimestampedLogEntry("[HOTRELOAD] Package: " +
        IntToString(nOldRows) + " old -> " + IntToString(nNewRows) + " new rows.");
    SendMessageToAllDMs("[HOTRELOAD] Package reloaded (" +
        IntToString(nNewRows) + " packages).");
    return TRUE;
}

// ============================================================================
// GRID HOT RELOAD
// ============================================================================

int GridHotReload()
{
    object oMod = GetModule();
    DeleteLocalInt(oMod, GRD_PFX + GRDK_BOOTED);
    GridBoot();

    WriteTimestampedLogEntry("[HOTRELOAD] Grid config reloaded.");
    SendMessageToAllDMs("[HOTRELOAD] Grid config reloaded.");
    return TRUE;
}

// ============================================================================
// GPS HOT RELOAD
// ============================================================================

int GpsHotReload()
{
    object oMod = GetModule();
    DeleteLocalInt(oMod, GPS_PFX + GPS_KEY_BOOTED);
    GpsBoot();

    WriteTimestampedLogEntry("[HOTRELOAD] GPS config reloaded.");
    SendMessageToAllDMs("[HOTRELOAD] GPS distances reloaded.");
    return TRUE;
}
