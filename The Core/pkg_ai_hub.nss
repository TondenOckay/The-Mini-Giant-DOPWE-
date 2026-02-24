/* ============================================================================
    DOWE - pkg_ai_hub.nss
    AI Hub Package Tick Script - Thin Wrapper
    DOWE v2.3 | Production Standard | Final

    ASSIGNED IN: core_package.2da SCRIPT column for "ai_hub" row.
    EXECUTED BY: core_switch via ExecuteScript("pkg_ai_hub", oArea)
    OBJECT_SELF: the area object.

    This script is a THIN WRAPPER only.
    All AI hub logic is in ai_hub.nss (the library).
    All AI configuration lives in ai_hub.2da.

    INCLUDE NOTE:
    ai_hub includes core_conductor.
    core_package must also be included here because ai_hub.nss calls
    PackageGetState / PackageSetState which are implemented in core_package.
    Without core_package in this compilation unit, those calls fail.

   ============================================================================
*/

#include "ai_hub"
#include "core_package"

void main()
{
    AiHubTick(OBJECT_SELF);
}
