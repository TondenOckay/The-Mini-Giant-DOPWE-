/* ============================================================================
    pkg_ai_gps.nss
    GPS Package Event Script - Thin Wrapper

    This is the script that core_package.2da points to for the ai_gps package.
    It is executed by core_switch via ExecuteScript("pkg_ai_gps", oArea).
    OBJECT_SELF will be the area.

    This script is a THIN WRAPPER only.
    All GPS logic lives in core_ai_gps.nss (the library).
    All GPS configuration lives in core_ai_gps.2da.

    WHY THIS SPLIT EXISTS:
    core_ai_gps.nss must be #included by other scripts (e.g. core_onload
    needs GpsBoot, core_switch needs GpsTick context). A file with void main()
    cannot be safely #included by another script that also has void main()
    without causing DUPLICATE FUNCTION IMPLEMENTATION errors.
    Separating the library from the event wrapper solves this permanently.

   ============================================================================
*/

// core_ai_gps brings: core_conductor, core_registry, core_grid
// core_registry calls PackageRunShutdownScripts and PackageUnload (in core_package).
// NWScript requires the IMPLEMENTATION to be in the same compilation unit.
// A forward declaration alone is not sufficient - core_package must be included here.
#include "core_ai_gps"
#include "core_package"

void main()
{
    GpsTick(OBJECT_SELF);
}
