/* ============================================================================
    pkg_metrics.nss
    Metrics Package Tick Wrapper

    ASSIGNED IN: core_package.2da SCRIPT column for "metrics" row.
    EXECUTED BY: core_switch via ExecuteScript("pkg_metrics", oArea)
    OBJECT_SELF: the area object.

    Thin wrapper only. All logic in core_metrics.nss.
   ============================================================================
*/

#include "core_metrics"

void main()
{
    MetricsTick(OBJECT_SELF);
}
