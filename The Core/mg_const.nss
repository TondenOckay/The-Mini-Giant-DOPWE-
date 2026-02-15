/* ============================================================================
    DOWE v2.2 - mg_const.nss
    System Constants and Configuration
    
    All system-wide constants in one place for easy tuning
   ============================================================================
*/

// ============================================================================
// DEBUG FLAGS (Enable/disable specific subsystems)
// ============================================================================

const string MG_DEBUG          = "MG_DEBUG";         // Master debug toggle
const string MG_DEBUG_VERBOSE  = "MG_DEBUG_VERB";   // Verbose logging
const string MG_DEBUG_MAN      = "MG_DEBUG_MAN";    // Manifest operations
const string MG_DEBUG_ENC      = "MG_DEBUG_ENC";    // Encounter spawning
const string MG_DEBUG_MUD      = "MG_DEBUG_MUD";    // MUD commands
const string MG_DEBUG_SQL      = "MG_DEBUG_SQL";    // SQL operations

// ============================================================================
// TICK SYSTEM (Heartbeat counter)
// ============================================================================

const string MG_TICK           = "MG_TICK";         // Current tick
const string MG_LAST_TICK      = "MG_LAST_TICK";    // Last dispatch tick
const int MG_TICK_RESET        = 10000;             // Reset threshold

// ============================================================================
// SQL CONFIGURATION
// ============================================================================

const string MG_SQL_EXTERNAL   = "MG_SQL_EXT";      // Use external DB?
const string MG_SQL_DB         = "dowe_server";     // Database name
const float MG_SQL_STAGGER     = 0.2;               // 200ms between saves

// ============================================================================
// CLEANUP LIFESPANS (Ticks before removal)
// ============================================================================

const string MG_CFG_CORPSE     = "MG_CFG_CORPSE";   // NPC corpse life
const string MG_CFG_ITEM       = "MG_CFG_ITEM";     // Dropped item life
const string MG_CFG_PCCORPSE   = "MG_CFG_PCCORP";   // PC corpse life

// ============================================================================
// ENCOUNTER SYSTEM
// ============================================================================

const int MG_ENC_INTERVAL      = 4;      // Check every 4 beats (24 sec)
const float MG_ENC_CHANCE      = 0.40;   // 40% base spawn chance
const int MG_ENC_PER_TICK      = 5;      // Process 5 players/tick

// Spawn distance ranges
const float MG_ENC_DIST_CLOSE  = 10.0;   // Very close spawn
const float MG_ENC_DIST_MED    = 20.0;   // Medium distance
const float MG_ENC_DIST_FAR    = 30.0;   // Far spawn

const float MG_ENC_WALK_CHECK  = 2.0;    // Walkable radius check

// ============================================================================
// LIVE NPC SYSTEM
// ============================================================================

const string MG_LIVE_NPC       = "MG_LIVE_NPC";     // System enabled?
const string MG_LIVE_TAG_PFX   = "LIVENPC_";        // Tag prefix

// ============================================================================
// PERFORMANCE TUNING (DelayCommand timings)
// ============================================================================

const float MG_PHASE2_DELAY    = 1.5;    // Phase 2 stagger (NPCs)
const float MG_PHASE3_DELAY    = 3.0;    // Phase 3 stagger (Encounters)
const int MG_FAILSAFE_BEATS    = 3;      // Missed beats before failsafe

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

// Check if debug is enabled
int GetMGDebug()
{
    return GetLocalInt(GetModule(), MG_DEBUG);
}

// Get current tick
int GetMGTick()
{
    return GetLocalInt(GetModule(), MG_TICK);
}

// Check if specific debug subsystem is enabled
int GetMGDebugSub(string sSubsystem)
{
    return GetLocalInt(GetModule(), sSubsystem);
}
