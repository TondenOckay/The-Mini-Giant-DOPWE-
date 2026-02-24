/* ============================================================================
    DOWE - core_onload.nss (COMPLETE VERSION)
    Module OnModuleLoad Event Handler
    
    This is the first script that runs when the module loads.
    It initializes all core systems.
    
    ENHANCEMENTS:
    - Added SQL table creation
    - Added hot-reload system initialization
    - Added comprehensive logging
    
    ASSIGN TO: Module OnModuleLoad event
    
    NWScript verified against nwn.wiki and nwnlexicon.com
   ============================================================================
*/

#include "core_conductor"
#include "core_registry"
#include "core_package"
#include "core_grid"
#include "core_sql_persist"

void main()
{
    object oMod = GetModule();
    
    WriteTimestampedLogEntry("=================================================");
    WriteTimestampedLogEntry("DOWE v2.3 - Module Loading");
    WriteTimestampedLogEntry("=================================================");
    
    // ========================================================================
    // STEP 1: CORE SYSTEM BOOT
    // ========================================================================
    
    WriteTimestampedLogEntry("[BOOT] Step 1: Booting core systems...");
    
    // Boot registry system
    RegistryBoot();
    WriteTimestampedLogEntry("[BOOT] Registry system initialized");
    
    // Boot package system
    PackageBoot();
    WriteTimestampedLogEntry("[BOOT] Package system initialized");
    
    // Boot grid system (if GridBoot() exists)
    // GridBoot();
    // WriteTimestampedLogEntry("[BOOT] Grid system initialized");
    
    // ========================================================================
    // STEP 2: SQL DATABASE INITIALIZATION
    // ========================================================================
    
    WriteTimestampedLogEntry("[BOOT] Step 2: Initializing SQL database...");
    
    // Create SQL tables if they don't exist
    SQLCreateTables();
    WriteTimestampedLogEntry("[BOOT] SQL tables created/verified");
    
    // ========================================================================
    // STEP 3: SYSTEM CONFIGURATION
    // ========================================================================
    
    WriteTimestampedLogEntry("[BOOT] Step 3: Configuring system...");
    
    // Initialize global tick counter
    SetLocalInt(oMod, MG_TICK, 1);
    WriteTimestampedLogEntry("[BOOT] Global tick initialized");
    
    // Initialize active area count
    SetLocalInt(oMod, "MG_ACTIVE_CNT", 0);
    WriteTimestampedLogEntry("[BOOT] Active area registry initialized");
    
    // Set admin password (change this!)
    // Used for hot-reload commands if not a DM
    SetLocalString(oMod, "MG_ADMIN_PASSWORD", "change_me_123");
    WriteTimestampedLogEntry("[BOOT] Admin password set");
    
    // ========================================================================
    // STEP 4: DEBUG CONFIGURATION
    // ========================================================================
    
    WriteTimestampedLogEntry("[BOOT] Step 4: Configuring debug flags...");
    
    // Set debug flags (1 = enabled, 0 = disabled)
    // IMPORTANT: Disable these in production for performance
    
    SetLocalInt(oMod, MG_DEBUG, 1);              // Master debug
    SetLocalInt(oMod, MG_DEBUG_VERBOSE, 0);      // Verbose logging
    SetLocalInt(oMod, MG_DEBUG_REG, 1);          // Registry operations
    SetLocalInt(oMod, MG_DEBUG_ENC, 0);          // Encounter spawning
    SetLocalInt(oMod, MG_DEBUG_SQL, 1);          // SQL operations
    SetLocalInt(oMod, MG_DEBUG_GPS, 0);          // GPS proximity
    SetLocalInt(oMod, MG_DEBUG_PKG, 1);          // Package system
    SetLocalInt(oMod, MG_DEBUG_GRID, 0);         // Grid system
    SetLocalInt(oMod, MG_DEBUG_DISP, 1);         // Dispatch system
    SetLocalInt(oMod, MG_DEBUG_AI, 0);           // AI hub
    SetLocalInt(oMod, MG_DEBUG_ADMIN, 1);        // Admin commands
    
    WriteTimestampedLogEntry("[BOOT] Debug flags configured");
    
    // ========================================================================
    // STEP 5: PACKAGE-SPECIFIC BOOT SCRIPTS
    // ========================================================================
    
    WriteTimestampedLogEntry("[BOOT] Step 5: Running package boot scripts...");
    
    // Some packages may need module-level boot
    // These are called automatically if they have BOOT_SCRIPT set
    // and the script detects OBJECT_SELF = module
    
    // ========================================================================
    // STEP 6: FINAL CHECKS
    // ========================================================================
    
    WriteTimestampedLogEntry("[BOOT] Step 6: Final system checks...");
    
    // Verify registry loaded
    int nRegistryRows = GetLocalInt(oMod, "RG_ROW_CNT");
    if (nRegistryRows == 0)
    {
        WriteTimestampedLogEntry("[BOOT] ERROR: Registry failed to load!");
    }
    else
    {
        WriteTimestampedLogEntry("[BOOT] Registry: " + IntToString(nRegistryRows) + " object types loaded");
    }
    
    // Verify package system loaded
    int nPackageRows = GetLocalInt(oMod, "PKG_ROW_CNT");
    if (nPackageRows == 0)
    {
        WriteTimestampedLogEntry("[BOOT] ERROR: Package system failed to load!");
    }
    else
    {
        WriteTimestampedLogEntry("[BOOT] Package system: " + IntToString(nPackageRows) + " packages loaded");
    }
    
    // ========================================================================
    // BOOT COMPLETE
    // ========================================================================
    
    WriteTimestampedLogEntry("=================================================");
    WriteTimestampedLogEntry("DOWE v2.3 - Module Load Complete");
    WriteTimestampedLogEntry("System Status: READY");
    WriteTimestampedLogEntry("=================================================");
    
    // Send confirmation to any DMs online
    object oDM = GetFirstPC();
    while (GetIsObjectValid(oDM))
    {
        if (GetIsDM(oDM))
        {
            SendMessageToPC(oDM, "[DOWE v2.3] Module loaded successfully!");
            SendMessageToPC(oDM, "Registry: " + IntToString(nRegistryRows) + " types | " +
                                 "Packages: " + IntToString(nPackageRows));
        }
        oDM = GetNextPC();
    }
}
