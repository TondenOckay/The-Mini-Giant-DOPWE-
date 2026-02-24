/* ============================================================================
    DOWE - core_chat.nss
    OnPlayerChat Event Handler - Security Gateway + Command Router
    DOWE v2.3 | Production Standard | Final

    ASSIGN TO: Module Properties -> Events -> OnPlayerChat

    ============================================================================
    ARCHITECTURE - SESSION 10 REVISED ROUTING
    ============================================================================
    THREE-GATE ROUTING:

    GATE 1: "/*" prefix  -> GM/Admin command
      Silenced immediately. Password never appears in chat.
      Role-gated via RBAC. Examples:
        /*debug on "pass"    /*reload "pass"    /*vanish "pass"

    GATE 2: "//" prefix  -> Player interaction command OR builder console
      Silenced immediately. Two sub-routes:
        a) Builder keywords (//dump, //check, //scaffold) -> BuilderHandleCommand()
           Requires Role 5+ internally. Players without access get no output.
        b) Everything else -> CommandHubQueuePlayerCmd()
           Queued per-PC, processed by pkg_mud_proc.nss next tick.
           This is how players speak TO the world deliberately:
             //hail          - greet nearest NPC
             //hi            - same as hail
             //help          - show available player commands
             //stats         - show character stats
             //buy <item>    - attempt to purchase from a merchant
             //I need a job  - triggers the keyword engine with that phrase

    GATE 3: Everything else -> NORMAL NWN CHAT ONLY
      Plain speech ("lol", "brb", "Nice armor!") passes through to NWN's
      native channel system without ANY processing overhead.
      The keyword engine does NOT scan plain chat.
      Players do not need a prefix to socialize.

    ============================================================================
    DESIGN RATIONALE (Session 10)
    ============================================================================
    Previous design scanned ALL plain chat through the keyword engine. This had
    two problems:
      1. Performance: Every "lol" typed by anyone in the area fires keyword
         scanning logic, even with an early-out O(1) lookup. On a busy server
         with 30 players chatting freely this is measurable overhead.
      2. False positives: A player chatting to another player says "I need
         water" and accidentally triggers the thirst mechanic or a quest NPC.

    The "//" prefix solves both:
      - Zero overhead for normal social chat
      - Player INTENTION is explicit: // means "I am talking TO the world"
      - Keyword engine only runs on deliberate interaction
      - Natural NWN roleplay chat is completely unaffected

    PLAYER EXPERIENCE:
      Normal chat:     "That sandstorm was brutal."    -> just broadcasts
      Talk to NPC:     "//hail"                        -> triggers keyword engine
      Buy something:   "//buy sword"                   -> queued command
      Ask for work:    "//I need a job"                -> keyword match fires

    This mirrors how classic MUD text parsers worked: you had to ADDRESS
    the world to interact with it. Casual chat was separate.

    ============================================================================
    NWN:EE CHAT CHANNEL REFERENCE
    ============================================================================
    /s  (or no prefix) = say (area broadcast)  <- normal chat, no prefix needed
    /w <name>          = whisper               <- private
    /p                 = party chat            <- group only
    /shout             = zone-wide shout
    /dm                = DM channel
    /* and //          = NOT intercepted by NWN engine. Safe custom prefixes.

    ============================================================================
    REQUIRED INCLUDES
    ============================================================================
    core_admin needs these implementations in the same compilation unit:
      core_registry  - for RegistryBoot(), RegistryShutdown()
      core_package   - for PackageBoot(), PackageGetRow()
      core_ai_gps    - for GpsBoot()
      pkg_ai_hub_lib - for AiHubBoot()

    All master hub libs are included to provide their forward-declared Boot()
    implementations (required by core_admin /*reload command).

   ============================================================================
*/

// DOWE core systems
#include "core_admin"
#include "core_registry"
#include "core_package"
#include "core_ai_gps"
#include "pkg_ai_hub_lib"

// Master hub libraries (provide Boot() implementations for /*reload)
#include "enc_hub_lib"
#include "soc_hub_lib"
#include "env_hub_lib"
#include "cmd_hub_lib"
#include "char_hub_lib"
#include "core_metrics"

// Builder console (provides BuilderHandleCommand)
#include "core_builder"

// ============================================================================
// If your MUD system is a library, add its include here:
// #include "your_mud_lib"
// ============================================================================

void main()
{
    object oPC  = GetPCChatSpeaker();
    string sMsg = GetPCChatMessage();

    // ========================================================================
    // GATE 1: GM/ADMIN COMMANDS  ("/*" prefix)
    // Silenced immediately so passwords never appear in chat.
    // AdminHandleCommand() handles role verification and routing.
    // ========================================================================

    if (GetStringLeft(sMsg, 2) == "/*")
    {
        SetPCChatMessage("");
        AdminHandleCommand(oPC, sMsg);
        return;
    }

    // ========================================================================
    // GATE 2: PLAYER INTERACTION + BUILDER COMMANDS  ("//" prefix)
    //
    // "//" is the player's signal that they are talking TO the world, not to
    // other players. This keeps normal chat completely free of overhead.
    //
    // Sub-routing:
    //   //dump, //check, //scaffold  -> Builder console (role 5+ required)
    //   Everything else              -> Player command queue (pkg_mud_proc)
    //
    // Examples of player interaction commands:
    //   //hail            Greet nearest NPC, triggers keyword match
    //   //hi              Same as hail
    //   //help            Show available commands
    //   //stats           Show character stats
    //   //who             Show players online
    //   //buy sword       Purchase item from merchant
    //   //I need a job    Triggers keyword engine with that phrase
    //   //where is water  Triggers keyword engine with that phrase
    // ========================================================================

    if (GetStringLeft(sMsg, 2) == "//")
    {
        SetPCChatMessage("");

        // Builder console commands (//dump, //check, //scaffold)
        // BuilderHandleCommand() does its own role check internally.
        string sTrim = GetStringLeft(sMsg, 12);
        if (GetStringLeft(sTrim, 7)  == "//dump "   ||
            GetStringLeft(sTrim, 9)  == "//check "  ||
            GetStringLeft(sTrim, 12) == "//scaffold ")
        {
            BuilderHandleCommand(oPC, sMsg);
        }
        else
        {
            // Route to player command queue.
            // pkg_mud_proc.nss dequeues and processes this each tick.
            // The keyword engine (tmg_keywords_lib) runs inside pkg_mud_proc,
            // matching the stripped command text against the keyword 2DA.
            CommandHubQueuePlayerCmd(oPC, sMsg);
        }
        return;
    }

    // ========================================================================
    // GATE 3: NORMAL NWN CHAT - NO PROCESSING
    //
    // Plain chat falls through here untouched.
    // NWN's native system broadcasts it normally.
    // The keyword engine does NOT run on plain chat.
    // Players can speak freely without triggering any game systems.
    //
    // If you have a MUD chat library for things like custom emotes,
    // channel colors, or profanity filtering, add it here:
    // ========================================================================

    // Uncomment and replace with your MUD chat handler if needed:
    // MudHandleChat(oPC, sMsg);
}
