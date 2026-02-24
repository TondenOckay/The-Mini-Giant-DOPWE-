/* ============================================================================
    DOWE - dm_hotreload.nss
    DEPRECATED - Superseded by core_chat.nss + core_admin.nss
    DOWE v2.3 | Compatibility Shim Only

    ============================================================================
    THIS FILE IS A COMPATIBILITY SHIM
    ============================================================================
    The hot-reload and debug system has been fully integrated into the
    RBAC admin console (core_admin.nss + core_chat.nss).

    DO NOT assign this script to OnPlayerChat.
    Assign core_chat.nss instead.

    core_chat.nss handles ALL chat commands including:
      /*reload registry "password"
      /*reload package "password"
      /*reload gps "password"
      /*reload "password"           (reloads all)
      /*debug all on "password"
      /*debug registry on "password"
      /*debug pkg on "password"
      /*debug switch on "password"
      /*debug enc on "password"
      /*debug enc_hub on "password"
      /*debug ai on "password"
      /*debug ai_hub on "password"
      /*trace [VAR] on "password"
      /*status "password"
      /*status area "password"
      /*status packages "password"
      /*pkg on [name] "password"
      /*pkg off [name] "password"
      /*pkg interval [name] [n] "password"
      /*shutdown area "password"
      /*lockdown "password"

    AUTHENTICATION: CD key + password from core_admin.2da (role-based).
    Password is hidden from chat via SetPCChatMessage("") before anyone sees it.

    ============================================================================
    TOOLSET WIRING
    ============================================================================
    Module Properties -> Events -> OnPlayerChat = core_chat

    ============================================================================
    IF YOU MUST USE THIS FILE (e.g. you have another script on OnPlayerChat):
    ============================================================================
    Add this to the TOP of your OnPlayerChat script BEFORE any other logic:

        if (GetStringLeft(GetPCChatMessage(), 2) == "/*")
        {
            SetPCChatMessage("");
            AdminHandleCommand(GetPCChatSpeaker(), GetPCChatMessage());
            return;
        }

    But ONLY if you included core_admin in that script's compilation unit.

   ============================================================================
*/

// This file intentionally has no void main().
// If you accidentally assign it to an event, nothing will break but nothing
// will happen either. Assign core_chat.nss instead.
