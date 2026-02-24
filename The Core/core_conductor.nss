/* ============================================================================
    DOWE - core_conductor.nss
    System-Wide Constants and Forward Declarations
    DOWE v2.3 | Production Standard | Final

    All core scripts #include this file.
    These are true compile-time constants: system key names, timing values
    that are stable and never need tuning by a server owner.
    Anything a server owner would tune lives in a 2DA.

    ============================================================================
    INCLUDE RULE SUMMARY
    ============================================================================
    core_conductor has NO functions. Only const declarations and forward
    declarations. It is safe to include in ANY script without side effects.

    Forward declarations here tell the compiler "this function exists somewhere
    in this compilation unit." They only work if the implementation is also
    #included somewhere in the same .nss compilation unit.

    core_conductor itself does NOT include any implementation files.
   ============================================================================
*/

// ============================================================================
// DEBUG FLAG VARIABLE NAMES
// Stored as integer local variables on the module object (value 0 or 1).
// Set via /*debug commands in core_chat.nss.
// Check via: GetLocalInt(GetModule(), MG_DEBUG_*)
// All names must be <= 16 characters (NWN local variable name limit).
// ============================================================================

const string MG_DEBUG          = "MG_DEBUG";         // Master debug toggle (gates all below)
const string MG_DEBUG_VERBOSE  = "MG_DEBUG_VERB";    // Verbose logging (very noisy)          14 chars
const string MG_DEBUG_REG      = "MG_DEBUG_REG";     // Registry operations                   13 chars
const string MG_DEBUG_ENC      = "MG_DEBUG_ENC";     // Encounter system (all enc)            13 chars
const string MG_DEBUG_ENC_SPAWN= "MG_DEBUG_ENCSPWN"; // Encounter spawn                       16 chars (AT LIMIT)
const string MG_DEBUG_ENC_AI   = "MG_DEBUG_ENCAI";   // Encounter AI sub-system               14 chars
const string MG_DEBUG_ENC_DYN  = "MG_DEBUG_ENCDYN";  // Encounter dynamic system              15 chars
const string MG_DEBUG_ENC_RADAR= "MG_DEBUG_ENCRAD";  // Encounter radar sub-system            15 chars
const string MG_DEBUG_MUD      = "MG_DEBUG_MUD";     // MUD chat commands and society hub     13 chars
const string MG_DEBUG_KWD      = "MG_DEBUG_KWD";     // Keyword engine                        13 chars
const string MG_DEBUG_MUD_ATM  = "MG_DEBUG_MUDATM";  // Environment atmosphere sub-systems    15 chars
const string MG_DEBUG_UI       = "MG_DEBUG_UI";      // Characters UI/NUI interface           11 chars
const string MG_DEBUG_SQL      = "MG_DEBUG_SQL";     // SQL operations                        13 chars
const string MG_DEBUG_GPS      = "MG_DEBUG_GPS";     // GPS proximity system                  13 chars
const string MG_DEBUG_PKG      = "MG_DEBUG_PKG";     // Package system / core_switch dispatch 13 chars
const string MG_DEBUG_GRID     = "MG_DEBUG_GRID";    // Grid system                           14 chars
const string MG_DEBUG_DISP     = "MG_DEBUG_DISP";    // Dispatch / active area registry       14 chars
const string MG_DEBUG_AI       = "MG_DEBUG_AI";      // AI hub (all AI sub-systems)           11 chars
const string MG_DEBUG_AI_LOGIC = "MG_DEBUG_AILOG";   // AI logic archetype processor          14 chars
const string MG_DEBUG_AI_CAST  = "MG_DEBUG_AICST";   // AI caster tactics                     14 chars
const string MG_DEBUG_AI_PHYS  = "MG_DEBUG_AIPHY";   // AI physics zones                      14 chars
const string MG_DEBUG_AI_SURV  = "MG_DEBUG_AISRV";   // AI survival (hunger/thirst)           14 chars
const string MG_DEBUG_ADMIN    = "MG_DEBUG_ADMIN";   // Admin console operations              14 chars
const string MG_DEBUG_ENC_HUB  = "MG_DEBUG_ENCHUB";  // Encounter hub dispatch                15 chars
const string MG_DEBUG_AI_HUB   = "MG_DEBUG_AIHUB";   // AI hub dispatch                       14 chars
const string MG_DEBUG_METRICS  = "MG_DEBUG_METR";    // Performance metrics package           14 chars

// ============================================================================
// PRESENCE FLAG CONSTANTS
// Used by core_registry.nss to track object types in areas.
// ============================================================================

const string MG_HAS_PC         = "MG_HAS_PC";        // PC presence count for area
const string MG_HAS_NPC        = "MG_HAS_NPC";       // NPC presence count for area

// ============================================================================
// TICK SYSTEM
// ============================================================================

const string MG_TICK           = "MG_TICK";           // Current tick counter (int on module)
const string MG_LAST_TICK      = "MG_LAST_TICK";      // Last dispatch tick
const int    MG_TICK_RESET     = 10000;               // Tick wraps at this value

// ============================================================================
// SWITCH MAINTENANCE INTERVALS
// How many ticks between each maintenance pass in core_switch.
// ============================================================================

const int MG_SW_GHOST_INTERVAL = 10;   // Ticks between ghost reclaim passes
const int MG_SW_CULL_INTERVAL  = 5;    // Ticks between expiry cull passes
const int MG_SW_DESP_INTERVAL  = 3;    // Ticks between encounter despawn checks

// Phase constants for maintenance tasks within a tick window.
const float MG_SW_PHASE_MAINT  = 0.1;   // Ghost clean stagger
const float MG_SW_PHASE_CULL   = 0.2;   // Expiry cull stagger
const float MG_SW_PHASE_DESP   = 0.3;   // Despawn check stagger
const float MG_SW_PHASE_GRID   = 0.4;   // Grid position update stagger

// ============================================================================
// SQL CONFIGURATION
// ============================================================================

const string MG_SQL_DB         = "dowe_server";       // External database name
const float  MG_SQL_STAGGER    = 0.2;                 // Seconds between batched saves

// ============================================================================
// FAILSAFE
// ============================================================================

const int MG_FAILSAFE_BEATS    = 3;    // Missed module heartbeats before area failsafe fires

// ============================================================================
// FORWARD DECLARATIONS
// Functions implemented in their respective core libraries.
// Declared here so all core scripts can see signatures without circular includes.
//
// IMPORTANT: The IMPLEMENTATION must be #included in the same compilation
// unit as any script that calls these. A forward decl alone is not enough.
// ============================================================================

// core_registry.nss
void RegistryBoot();
void RegistryActivateArea(object oArea);
void RegistryDeactivateArea(object oArea);
int  RegistryPCCount(object oArea);
void RegistryInitArea(object oArea);
void RegistryClean(object oArea);
int  RegistryCull(object oArea);
void RegistryCull_Void(object oArea);
int  RegistryCheckDespawn(object oArea);
void RegistryCheckDespawn_Void(object oArea);
void RegistryShutdown(object oArea);
int  RegistryAutoRegister(object oObj, object oArea, int bFromEnter, int nOwnerSlot = 0);

// core_package.nss
void PackageBoot();
void PackageCreateTable();
void PackageLoad(object oArea);
void PackageUnload(object oArea);
void PackageRunBootScripts(object oArea);
void PackageRunShutdownScripts(object oArea);
void RecordScheduledTick(object oMod, int nTick);
int  PackageGetRow(string sName);
string PackageGetDebugVar(int nRow);
int    PackageGetAuthLevel(int nRow);

// core_grid.nss
void GridBoot();
void GridInitArea(object oArea);
void GridShutdownArea(object oArea);
void GridTickUpdate(object oArea);
object GridGetNearestEnemy(object oSearcher, object oArea, float fMaxRange, int nSearcherSlot = 0);
object GridGetNearestAlly(object oSearcher, object oArea, float fMaxRange, float fHPThreshold = 0.0, int nSearcherSlot = 0);
int    GridGetObjectsInRange(object oSearcher, object oArea, float fRange, int nFlagFilter, int nSearcherSlot = 0);
object GridGetObjectInRange(object oSearcher, object oArea, float fRange, int nFlagFilter, int nSearcherSlot = 0);

// core_ai_gps.nss
void GpsBoot();
void GpsTick(object oArea);

// core_dispatch.nss
void DispatchBoot();
void DispatchTick();

// core_admin.nss
void AdminBoot();
int  AdminGetRole(object oPC, string sPassword);
void AdminHandleCommand(object oPC, string sRawMsg);
void AdminShowMetrics(object oPC);

// ai_hub.nss (AI Hub library - has sub-system dispatch)
void AiHubBoot();
void AiHubLoadJson(object oArea);
void AiHubUnloadJson(object oArea);

// MASTER HUB FORWARD DECLARATIONS
// All six master hub Boot functions called from core_onload.nss

// encounters_hub_lib.nss
void EncountersHubBoot();

// society_hub_lib.nss
void SocietyHubBoot();

// environment_hub_lib.nss
void EnvironmentHubBoot();

// command_hub_lib.nss
void CommandHubBoot();

// characters_hub_lib.nss
void CharactersHubBoot();

// core_metrics.nss
void MetricsBoot();
void MetricsReport(object oPC);

// ============================================================================
// SOCIETY/ECONOMY BOOT FUNCTIONS (sys_craft.nss, sys_gath.nss, sys_shop.nss)
// Forward declared here so society_hub_lib.nss can call them without
// including the full adapter libraries in the hub lib compilation unit.
// Implementation is in each sys_*.nss file respectively.
// Called from SocietyHubBoot() during module OnModuleLoad.
// ============================================================================
void CraftBoot();
void GathBoot();
void ShopBoot();
