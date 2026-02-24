/* ============================================================================
    DOWE - core_onload.nss
    Module OnModuleLoad Event Handler

    This is the ONLY place where Boot() functions are called.
    Call order matters - each system depends on the one before it.

    REQUIRED WIRING IN NWNEE TOOLSET:
      Module Properties -> Events -> OnModuleLoad -> core_onload

    ============================================================================
    BOOT ORDER (Session 9 - all 5 master hubs added)
    ============================================================================
    CORE INFRASTRUCTURE (DOWE systems):
    1.  AdminBoot()         - RBAC auth table ready before anything else
    2.  RegistryBoot()      - object type system (all other systems depend on this)
    3.  GridBoot()          - spatial grid (needed by GPS and spawn)
    4.  GpsBoot()           - GPS proximity system
    5.  AiHubBoot()         - AI hub sub-system cache (ai_hub.2da)
    6.  PackageBoot()       - package registry (core_package.2da)
    7.  PackageCreateTable()- SQL area override table
    8.  DispatchBoot()      - active area registry (must be last core item)

    MASTER HUB BOOTS (called after core infra so 2DAs can be read safely):
    9.  CharactersHubBoot() - race/class/spell data cache (other hubs may read this)
    10. CommandHubBoot()    - command router + keyword engine boot
    11. EncountersHubBoot() - encounter/AI sub-system dispatch table
    12. SocietyHubBoot()    - economy/faction sub-system dispatch table
    13. EnvironmentHubBoot()- atmosphere/survival sub-system dispatch table
    14. MetricsBoot()       - performance monitoring (always last)

    After this, the server is ready. Areas boot lazily when the first PC
    enters via core_enter.nss. Each master hub's per-area init is handled
    by its BOOT_SCRIPT column in core_package.2da.

   ============================================================================
*/

// ============================================================================
// INCLUDE STRUCTURE - CAREFULLY ORDERED TO AVOID DUPLICATE FUNCTION ERRORS
// NWScript pastes includes literally with no deduplication guards.
// Each library must appear EXACTLY ONCE in the compiled unit.
//
// The #ifndef guards in hub libs (SOCIETY_HUB_LIB_INCLUDED etc.) prevent
// duplicate definitions if two files both include the same hub lib.
//
// core_admin         -> core_conductor (constants only)
// pkg_ai_hub_lib     -> ai_logic, caster_logic, caster_action, ai_physics,
//                       ai_race, ai_class (each -> core_conductor dup OK)
//                       Provides AiHubBoot.
// core_ai_gps        -> core_conductor, core_registry, core_grid
// core_package       -> core_conductor
// core_dispatch      -> core_conductor
// soc_hub_lib    -> core_conductor, core_package, core_registry
// env_hub_lib-> core_conductor, core_package, core_registry
// enc_hub_lib -> core_conductor, core_package, core_registry
// cmd_hub_lib    -> core_conductor, core_package, core_registry
// char_hub_lib -> core_conductor, core_package, core_registry
// core_metrics       -> core_conductor
//
// core_registry appears ONCE (via core_ai_gps).
// core_grid appears ONCE (via core_ai_gps).
// core_package appears ONCE directly.
// core_conductor appears multiple times - always safe (consts only).
// Hub libs: safe via #ifndef include guards.
// ============================================================================

#include "core_admin"
#include "pkg_ai_hub_lib"
#include "core_ai_gps"
#include "core_package"
#include "core_dispatch"
#include "soc_hub_lib"
#include "env_hub_lib"
#include "enc_hub_lib"
#include "cmd_hub_lib"
#include "char_hub_lib"
#include "core_metrics"

void main()
{
    // =========================================================
    // PHASE 1: CORE DOWE INFRASTRUCTURE
    // =========================================================

    // 1. Security layer - MUST be first
    AdminBoot();

    // 2. Object type system
    RegistryBoot();

    // 3. Spatial grid
    GridBoot();

    // 4. GPS proximity system
    GpsBoot();

    // 5. AI hub (reads ai_hub.2da)
    AiHubBoot();

    // 6. Package registry
    PackageBoot();
    PackageCreateTable();

    // 7. Dispatch (starts accepting heartbeat calls - must come after all Boot calls)
    DispatchBoot();

    // =========================================================
    // PHASE 2: MASTER HUB BOOTS
    // These cache their 2DA data to module variables.
    // Per-area init happens lazily via BOOT_SCRIPT in core_package.2da.
    // =========================================================

    // 8. Characters: must be first hub - caches Race/Class/Spell data
    //    that the AI, encounter, and UI systems read.
    CharactersHubBoot();

    // 9. Command: keyword engine and MUD command processor ready
    //    so PCs can interact the moment they enter any area.
    CommandHubBoot();

    // 10. Encounters: AI tactics and spawning sub-system cache
    EncountersHubBoot();

    // 11. Society: economy, shops, faction sub-system cache
    SocietyHubBoot();

    // 12. Environment: atmosphere and survival sub-system cache
    EnvironmentHubBoot();

    // 13. Metrics: always last - monitors everything else
    MetricsBoot();

    WriteTimestampedLogEntry("[DOWE] All systems online. 8 packages + 5 master hubs. Server ready.");
}
