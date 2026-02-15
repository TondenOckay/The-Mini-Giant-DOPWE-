/* ============================================================================
    DOWE v2.2 - mg_cleanup.nss
    Cull Expired Objects
   ============================================================================
*/

#include "mg_manifest"
#include "mg_const"

void main()
{
    object oArea = OBJECT_SELF;

    int nCulled = ManifestCull(oArea);

    if (nCulled > 0 && GetMGDebug())
        SendMessageToAllDMs("CLEANUP: Culled " + IntToString(nCulled) + " from " + GetTag(oArea));
}
