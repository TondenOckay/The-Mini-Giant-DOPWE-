/* ============================================================================
    DOWE - core_grid.nss
    Spatial Grid System

    ============================================================================
    PHILOSOPHY
    ============================================================================
    The 2DA is the authority. The script is the engine.

    All grid configuration lives in core_grid.2da.
    Nothing is hardcoded here. CELL_SIZE, TILE_SIZE, neighbor radius,
    surface material IDs - all come from the 2DA at boot.

    To change grid cell size: edit CELL_SIZE in core_grid.2da and reboot.
    To change neighbor search radius: edit NEIGHBOR_RADIUS and reboot.
    No script changes ever needed.

    ============================================================================
    HOW THE GRID WORKS
    ============================================================================
    NWNEE tiles are always 10m x 10m in world units.
    An area 32 tiles wide is 320m wide (0.0 to 320.0 on the X axis).
    GetAreaSize(AREA_WIDTH, oArea) returns tile count, not world units.

    We divide the area into a grid of cells.
    CELL_SIZE (from 2DA) controls how many tiles form one grid cell.
      CELL_SIZE = 1: one cell per tile (finest grain, most memory use)
      CELL_SIZE = 2: one cell per 2x2 tile block (20m x 20m cells)
      CELL_SIZE = 4: one cell per 4x4 tile block (40m x 40m cells)

    Cell world size = CELL_SIZE * TILE_SIZE (e.g. 2 * 10.0 = 20.0m per cell).

    Cell index formula (0-based):
      col = FloatToInt(world_x / cell_world_size)
      row = FloatToInt(world_y / cell_world_size)
      cell_index = (row * area_cols_in_cells) + col

    Area columns in cells = area_width_tiles / CELL_SIZE
    Area rows in cells    = area_height_tiles / CELL_SIZE

    Grid dimensions and cell world size are cached per-area at first use.

    ============================================================================
    MODULE CACHE (set once at GridBoot, read-only after)
    ============================================================================
    GRD_TILE_SIZE         float  - world units per tile (10.0)
    GRD_CELL_SIZE         int    - tiles per cell side
    GRD_NEIGHBOR_RADIUS   int    - cell radius for neighbor search
    GRD_MAX_SLOTS         int    - max slots per cell
    GRD_UPDATE_INTERVAL   int    - ticks between position updates
    GRD_SURF_ENABLE       int    - surface material tracking enabled
    GRD_DEBUG             int    - debug messages enabled
    GRD_SURF_WATER        int    - water surface material ID
    GRD_SURF_PUDDLE       int    - puddle surface material ID
    GRD_SURF_SWAMP        int    - swamp surface material ID
    GRD_SURF_SHALLOW      int    - shallow water surface material ID
    GRD_MAX_AREA_TILES    int    - safety cap on area tile dimension
    GRD_SLOTS_WARN        int    - cell slot count warning threshold
    GRD_BOOTED            int    - boot guard

    ============================================================================
    PER-AREA CACHE (set at GridInitArea, read-only after per area)
    ============================================================================
    GRD_AREA_COLS         int    - number of grid columns in this area
    GRD_AREA_ROWS         int    - number of grid rows in this area
    GRD_AREA_CELLS        int    - total cells (cols * rows)
    GRD_AREA_CWS          float  - cell world size (CELL_SIZE * TILE_SIZE)
    GRD_AREA_INIT         int    - init guard

    ============================================================================
    PER-CELL DATA (stored on area object, keyed by cell index)
    ============================================================================
    GRD_C_[N]_CNT         int    - number of slots in this cell
    GRD_C_[N]_[I]         int    - Ith slot number in this cell (0-indexed)
    GRD_C_[N]_MAT         int    - surface material ID for this cell center

    ============================================================================
    NEIGHBOR RESULT (written to module object, consumed immediately)
    ============================================================================
    GRD_NC_CNT            int    - count of neighbor cells found
    GRD_NC_[I]            int    - Ith neighbor cell index

   ============================================================================
*/

#include "core_conductor"

// ============================================================================
// 2DA AND CACHE KEY CONSTANTS
// ============================================================================

const string GRID_2DA           = "core_grid";

// Module cache key prefix
const string GRD_PFX            = "GRD_";

// Module cache keys (appended to GRD_PFX)
const string GRDK_TILE_SIZE     = "TILE_SIZE";
const string GRDK_CELL_SIZE     = "CELL_SIZE";
const string GRDK_NEIGHBOR_RAD  = "NEIGHBOR_RADIUS";
const string GRDK_MAX_SLOTS     = "MAX_SLOTS_PER_CELL";
const string GRDK_UPDATE_INT    = "UPDATE_INTERVAL";
const string GRDK_SURF_ENABLE   = "ENABLE_SURFACE_MAT";
const string GRDK_DEBUG         = "ENABLE_DEBUG";
const string GRDK_SURF_WATER    = "SURF_WATER";
const string GRDK_SURF_PUDDLE   = "SURF_PUDDLE";
const string GRDK_SURF_SWAMP    = "SURF_SWAMP";
const string GRDK_SURF_SHALLOW  = "SURF_SHALLOW_WATER";
const string GRDK_MAX_AREA      = "MAX_AREA_TILES";
const string GRDK_SLOTS_WARN    = "CELL_SLOTS_WARN";
const string GRDK_BOOTED        = "BOOTED";

// Per-area cache keys (stored on area object)
const string GRDA_COLS          = "GRD_AREA_COLS";
const string GRDA_ROWS          = "GRD_AREA_ROWS";
const string GRDA_CELLS         = "GRD_AREA_CELLS";
const string GRDA_CWS           = "GRD_AREA_CWS";
const string GRDA_INIT          = "GRD_AREA_INIT";

// Per-cell prefix on area object: GRD_C_[N]_
const string GRDC_PFX           = "GRD_C_";
const string GRDC_CNT           = "_CNT";
const string GRDC_MAT           = "_MAT";

// Neighbor result keys on module object
const string GRDN_CNT           = "GRD_NC_CNT";
const string GRDN_PFX           = "GRD_NC_";

// ============================================================================
// SECTION 1: BOOT
// Reads core_grid.2da once. Caches everything to module object.
// Call once from module OnLoad before any area or grid function is used.
// ============================================================================

void GridBoot()
{
    object oMod = GetModule();

    // Guard: already booted
    if (GetLocalInt(oMod, GRD_PFX + GRDK_BOOTED)) return;
    SetLocalInt(oMod, GRD_PFX + GRDK_BOOTED, 1);

    int nRows = Get2DARowCount(GRID_2DA);
    int i;
    for (i = 0; i < nRows; i++)
    {
        string sKey    = Get2DAString(GRID_2DA, "KEY",         i);
        int    nIntVal = StringToInt(Get2DAString(GRID_2DA, "INT_VALUE",   i));
        float  fFltVal = StringToFloat(Get2DAString(GRID_2DA, "FLOAT_VALUE", i));

        // Store both int and float under the same key.
        // Callers use the correct getter for the type they expect.
        SetLocalInt(oMod,   GRD_PFX + sKey, nIntVal);
        SetLocalFloat(oMod, GRD_PFX + sKey, fFltVal);
    }

    WriteTimestampedLogEntry("[GRID] Boot complete. " +
        IntToString(nRows) + " settings loaded from " + GRID_2DA + ".2da. " +
        "CellSize=" + IntToString(GetLocalInt(oMod, GRD_PFX + GRDK_CELL_SIZE)) +
        " TileSize=" + FloatToString(GetLocalFloat(oMod, GRD_PFX + GRDK_TILE_SIZE), 0, 1) +
        " NeighborRadius=" + IntToString(GetLocalInt(oMod, GRD_PFX + GRDK_NEIGHBOR_RAD)));
}

// ============================================================================
// SECTION 2: MODULE CACHE ACCESSORS
// All O(1) local variable reads after boot.
// ============================================================================

float GridGetTileSize()
{ return GetLocalFloat(GetModule(), GRD_PFX + GRDK_TILE_SIZE); }

int GridGetCellSize()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_CELL_SIZE); }

int GridGetNeighborRadius()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_NEIGHBOR_RAD); }

int GridGetMaxSlotsPerCell()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_MAX_SLOTS); }

int GridGetUpdateInterval()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_UPDATE_INT); }

int GridGetSurfaceEnable()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_SURF_ENABLE); }

int GridGetDebug()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_DEBUG); }

int GridGetSurfWater()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_SURF_WATER); }

int GridGetSurfPuddle()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_SURF_PUDDLE); }

int GridGetSurfSwamp()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_SURF_SWAMP); }

int GridGetSurfShallow()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_SURF_SHALLOW); }

int GridGetMaxAreaTiles()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_MAX_AREA); }

int GridGetSlotsWarn()
{ return GetLocalInt(GetModule(), GRD_PFX + GRDK_SLOTS_WARN); }

// ============================================================================
// SECTION 3: AREA INITIALIZATION
// Computes area-specific grid dimensions and caches them on the area object.
// Called once per area at first grid use (lazy init guard).
// ============================================================================

void GridInitArea(object oArea)
{
    if (!GetIsObjectValid(oArea)) return;
    if (GetLocalInt(oArea, GRDA_INIT)) return;
    SetLocalInt(oArea, GRDA_INIT, 1);

    object oMod      = GetModule();
    float  fTileSize = GetLocalFloat(oMod, GRD_PFX + GRDK_TILE_SIZE);
    int    nCellSize = GetLocalInt(oMod,   GRD_PFX + GRDK_CELL_SIZE);
    int    nMaxTiles = GetLocalInt(oMod,   GRD_PFX + GRDK_MAX_AREA);

    // Validate cell size - must be 1, 2, or 4 to divide area tiles evenly.
    // NWNEE areas are always multiples of 8 tiles.
    if (nCellSize != 1 && nCellSize != 2 && nCellSize != 4)
    {
        WriteTimestampedLogEntry("[GRID] WARNING: CELL_SIZE=" +
            IntToString(nCellSize) + " is invalid. Using 2.");
        nCellSize = 2;
    }

    // GetAreaSize returns tile count (not world units)
    int nWidthTiles  = GetAreaSize(AREA_WIDTH,  oArea);
    int nHeightTiles = GetAreaSize(AREA_HEIGHT, oArea);

    // Safety cap - should never be needed with valid areas but guards against edge cases
    if (nWidthTiles  > nMaxTiles) nWidthTiles  = nMaxTiles;
    if (nHeightTiles > nMaxTiles) nHeightTiles = nMaxTiles;

    // Compute cell dimensions.
    // Integer division: a 32-tile area with CELL_SIZE=2 gives 16 columns.
    // If area width is not a perfect multiple of CELL_SIZE, the last partial
    // column/row still exists but is smaller. We round up with (n + s - 1) / s.
    int nCols  = (nWidthTiles  + nCellSize - 1) / nCellSize;
    int nRows2 = (nHeightTiles + nCellSize - 1) / nCellSize;
    int nTotal = nCols * nRows2;

    // Cell world size = tiles per cell side * world units per tile
    float fCellWorldSize = IntToFloat(nCellSize) * fTileSize;

    SetLocalInt(oArea,   GRDA_COLS,  nCols);
    SetLocalInt(oArea,   GRDA_ROWS,  nRows2);
    SetLocalInt(oArea,   GRDA_CELLS, nTotal);
    SetLocalFloat(oArea, GRDA_CWS,   fCellWorldSize);

    if (GetLocalInt(oMod, GRD_PFX + GRDK_DEBUG))
        WriteTimestampedLogEntry("[GRID] Area init: " + GetTag(oArea) +
            " Tiles=" + IntToString(nWidthTiles) + "x" + IntToString(nHeightTiles) +
            " Cells=" + IntToString(nCols) + "x" + IntToString(nRows2) +
            " Total=" + IntToString(nTotal) +
            " CellWorldSize=" + FloatToString(fCellWorldSize, 0, 1) + "m");
}

// ============================================================================
// SECTION 4: AREA DIMENSION ACCESSORS
// Per-area values cached at GridInitArea.
// ============================================================================

int GridGetAreaCols(object oArea)
{ return GetLocalInt(oArea, GRDA_COLS); }

int GridGetAreaRows(object oArea)
{ return GetLocalInt(oArea, GRDA_ROWS); }

int GridGetAreaCells(object oArea)
{ return GetLocalInt(oArea, GRDA_CELLS); }

float GridGetAreaCellWorldSize(object oArea)
{ return GetLocalFloat(oArea, GRDA_CWS); }

// ============================================================================
// SECTION 5: COORDINATE CONVERSION
// Convert between world position and cell index.
// ============================================================================

/* ----------------------------------------------------------------------------
   GridPosToCell
   Converts a world-space position vector to a cell index (0-based, row-major).
   Returns -1 if the position is outside the area grid (should not happen
   for valid objects in the area, but guards against floating point edge cases).
---------------------------------------------------------------------------- */
int GridPosToCell(object oArea, vector vPos)
{
    float fCWS  = GetLocalFloat(oArea, GRDA_CWS);
    int   nCols = GetLocalInt(oArea,   GRDA_COLS);
    int   nRows = GetLocalInt(oArea,   GRDA_ROWS);

    // Guard: area not yet initialized
    if (fCWS <= 0.0 || nCols <= 0 || nRows <= 0)
    {
        GridInitArea(oArea);
        fCWS  = GetLocalFloat(oArea, GRDA_CWS);
        nCols = GetLocalInt(oArea,   GRDA_COLS);
        nRows = GetLocalInt(oArea,   GRDA_ROWS);
        if (fCWS <= 0.0) return 0;
    }

    int nCol = FloatToInt(vPos.x / fCWS);
    int nRow = FloatToInt(vPos.y / fCWS);

    // Clamp to valid range (floating point can push us just past the edge)
    if (nCol < 0)        nCol = 0;
    if (nCol >= nCols)   nCol = nCols - 1;
    if (nRow < 0)        nRow = 0;
    if (nRow >= nRows)   nRow = nRows - 1;

    return (nRow * nCols) + nCol;
}

/* ----------------------------------------------------------------------------
   GridCellToColRow
   Decomposes a cell index into its column and row components.
   Writes results to nCol and nRow by reference (NWScript pass-by-value only -
   we use output local vars on module object instead).
   Callers read GRD_DECOMP_COL and GRD_DECOMP_ROW from module after calling.
---------------------------------------------------------------------------- */
void GridCellDecompose(object oArea, int nCell)
{
    int nCols = GetLocalInt(oArea, GRDA_COLS);
    if (nCols <= 0) nCols = 1;

    int nRow = nCell / nCols;
    int nCol = nCell - (nRow * nCols);

    object oMod = GetModule();
    SetLocalInt(oMod, "GRD_DECOMP_COL", nCol);
    SetLocalInt(oMod, "GRD_DECOMP_ROW", nRow);
}

/* ----------------------------------------------------------------------------
   GridCellCenter
   Returns the world-space center position of a cell.
---------------------------------------------------------------------------- */
vector GridCellCenter(object oArea, int nCell)
{
    float fCWS  = GetLocalFloat(oArea, GRDA_CWS);
    int   nCols = GetLocalInt(oArea,   GRDA_COLS);
    if (nCols <= 0) nCols = 1;

    int nRow = nCell / nCols;
    int nCol = nCell - (nRow * nCols);

    vector v;
    v.x = (IntToFloat(nCol) * fCWS) + (fCWS * 0.5);
    v.y = (IntToFloat(nRow) * fCWS) + (fCWS * 0.5);
    v.z = 0.0;
    return v;
}

// ============================================================================
// SECTION 6: NEIGHBOR CELL LOOKUP
// Returns the set of cells within NEIGHBOR_RADIUS of a given cell.
// Results are written to module object as GRD_NC_CNT + GRD_NC_[I].
// This avoids NWScript array limitations for returning variable-length results.
//
// Returns the count of neighbor cells found.
// ============================================================================

int GridGetNeighborCells(object oArea, int nCell)
{
    object oMod   = GetModule();
    int    nCols  = GetLocalInt(oArea, GRDA_COLS);
    int    nRows  = GetLocalInt(oArea, GRDA_ROWS);
    int    nRad   = GetLocalInt(oMod,  GRD_PFX + GRDK_NEIGHBOR_RAD);

    if (nCols <= 0) nCols = 1;
    if (nRows <= 0) nRows = 1;
    if (nRad  <= 0) nRad  = 1;

    int nCellRow = nCell / nCols;
    int nCellCol = nCell - (nCellRow * nCols);

    int nCount = 0;
    int dr;
    int dc;

    for (dr = -nRad; dr <= nRad; dr++)
    {
        for (dc = -nRad; dc <= nRad; dc++)
        {
            int nNRow = nCellRow + dr;
            int nNCol = nCellCol + dc;

            // Skip cells outside the area boundary
            if (nNRow < 0)      continue;
            if (nNRow >= nRows) continue;
            if (nNCol < 0)      continue;
            if (nNCol >= nCols) continue;

            int nNeighCell = (nNRow * nCols) + nNCol;
            SetLocalInt(oMod, GRDN_PFX + IntToString(nCount), nNeighCell);
            nCount++;
        }
    }

    SetLocalInt(oMod, GRDN_CNT, nCount);
    return nCount;
}

// ============================================================================
// SECTION 7: CELL SLOT MANAGEMENT
// Track which registry slots are in which cells.
// ============================================================================

/* ----------------------------------------------------------------------------
   GridCellAddSlot
   Registers a slot as occupying the given cell.
   Checks for duplicate (object may not have moved) before adding.
---------------------------------------------------------------------------- */
void GridCellAddSlot(object oArea, int nCell, int nSlot)
{
    object oMod  = GetModule();
    string sCPfx = GRDC_PFX + IntToString(nCell);
    int    nMax  = GetLocalInt(oMod,  GRD_PFX + GRDK_MAX_SLOTS);
    int    nWarn = GetLocalInt(oMod,  GRD_PFX + GRDK_SLOTS_WARN);
    int    nCnt  = GetLocalInt(oArea, sCPfx + GRDC_CNT);

    // Duplicate guard: scan existing entries for this slot
    int i;
    for (i = 0; i < nCnt; i++)
    {
        if (GetLocalInt(oArea, sCPfx + "_" + IntToString(i)) == nSlot)
            return;  // Already in this cell
    }

    // Capacity guard
    if (nCnt >= nMax)
    {
        if (GetLocalInt(oMod, GRD_PFX + GRDK_DEBUG))
            SendMessageToAllDMs("[GRID] Cell " + IntToString(nCell) +
                " in " + GetTag(oArea) + " at capacity (" + IntToString(nMax) + ")");
        return;
    }

    // Warning threshold
    if (nCnt == nWarn && nWarn > 0)
        WriteTimestampedLogEntry("[GRID] WARNING: Cell " + IntToString(nCell) +
            " in " + GetTag(oArea) + " approaching capacity (" + IntToString(nCnt) + ")");

    SetLocalInt(oArea, sCPfx + "_" + IntToString(nCnt), nSlot);
    SetLocalInt(oArea, sCPfx + GRDC_CNT, nCnt + 1);
}

/* ----------------------------------------------------------------------------
   GridCellRemoveSlot
   Removes a slot from a cell using swap-and-shrink to avoid gaps.
---------------------------------------------------------------------------- */
void GridCellRemoveSlot(object oArea, int nCell, int nSlot)
{
    string sCPfx = GRDC_PFX + IntToString(nCell);
    int    nCnt  = GetLocalInt(oArea, sCPfx + GRDC_CNT);

    int i;
    for (i = 0; i < nCnt; i++)
    {
        if (GetLocalInt(oArea, sCPfx + "_" + IntToString(i)) == nSlot)
        {
            int nLast = nCnt - 1;
            if (i < nLast)
            {
                // Swap last entry into this position
                int nLastSlot = GetLocalInt(oArea, sCPfx + "_" + IntToString(nLast));
                SetLocalInt(oArea, sCPfx + "_" + IntToString(i), nLastSlot);
            }
            DeleteLocalInt(oArea, sCPfx + "_" + IntToString(nLast));
            SetLocalInt(oArea, sCPfx + GRDC_CNT, nLast);
            return;
        }
    }
}

/* ----------------------------------------------------------------------------
   GridCellGetCount
   Returns the number of slots currently in a cell.
---------------------------------------------------------------------------- */
int GridCellGetCount(object oArea, int nCell)
{
    return GetLocalInt(oArea, GRDC_PFX + IntToString(nCell) + GRDC_CNT);
}

/* ----------------------------------------------------------------------------
   GridCellGetSlot
   Returns the Nth slot in a cell (0-indexed).
   Returns 0 if index is out of range.
---------------------------------------------------------------------------- */
int GridCellGetSlot(object oArea, int nCell, int nIndex)
{
    string sCPfx = GRDC_PFX + IntToString(nCell);
    int    nCnt  = GetLocalInt(oArea, sCPfx + GRDC_CNT);
    if (nIndex < 0 || nIndex >= nCnt) return 0;
    return GetLocalInt(oArea, sCPfx + "_" + IntToString(nIndex));
}

// ============================================================================
// SECTION 8: SURFACE MATERIAL CACHE
// Caches the surface material at each cell center.
// Called during GridTickUpdate or GridInitArea for surface-aware systems.
// Only runs if ENABLE_SURFACE_MAT = 1 in the 2DA.
// ============================================================================

/* ----------------------------------------------------------------------------
   GridCacheSurfaceMaterial
   Records the surface material ID at the center of the given cell on the area.
   GetSurfaceMaterial() returns the material under a world-space position.
---------------------------------------------------------------------------- */
void GridCacheSurfaceMaterial(object oArea, int nCell)
{
    if (!GetLocalInt(GetModule(), GRD_PFX + GRDK_SURF_ENABLE)) return;

    // Build a location at the center of this cell.
    // GetSurfaceMaterial takes a location, not a vector.
    // Location() takes (object oArea, vector vPosition, float fOrientation).
    vector   vCenter = GridCellCenter(oArea, nCell);
    location lCenter = Location(oArea, vCenter, 0.0);
    int      nMat    = GetSurfaceMaterial(lCenter);

    SetLocalInt(oArea, GRDC_PFX + IntToString(nCell) + GRDC_MAT, nMat);
}

/* ----------------------------------------------------------------------------
   GridGetCellSurfaceMaterial
   Returns the cached surface material for a cell.
   Returns 0 if not yet cached or surface tracking disabled.
---------------------------------------------------------------------------- */
int GridGetCellSurfaceMaterial(object oArea, int nCell)
{
    return GetLocalInt(oArea, GRDC_PFX + IntToString(nCell) + GRDC_MAT);
}

// ============================================================================
// SECTION 9: WATER PROXIMITY CHECK
// Used by core_ai_gps.nss to detect whether a position is near water.
// All water surface material IDs come from the 2DA cache.
// ============================================================================

/* ----------------------------------------------------------------------------
   GridIsWaterMaterial
   Returns TRUE if the given surface material ID is any water type.
   Material IDs come from core_grid.2da SURF_* rows.
---------------------------------------------------------------------------- */
int GridIsWaterMaterial(int nMat)
{
    object oMod = GetModule();
    if (nMat == GetLocalInt(oMod, GRD_PFX + GRDK_SURF_WATER))   return TRUE;
    if (nMat == GetLocalInt(oMod, GRD_PFX + GRDK_SURF_PUDDLE))  return TRUE;
    if (nMat == GetLocalInt(oMod, GRD_PFX + GRDK_SURF_SWAMP))   return TRUE;
    if (nMat == GetLocalInt(oMod, GRD_PFX + GRDK_SURF_SHALLOW)) return TRUE;
    return FALSE;
}

/* ----------------------------------------------------------------------------
   GridIsNearWater
   Returns TRUE if vPos or any neighbor cell contains a water surface material.
   This is the function called by core_ai_gps.nss for canteen refill checks.
---------------------------------------------------------------------------- */
int GridIsNearWater(object oArea, vector vPos)
{
    int nCell = GridPosToCell(oArea, vPos);
    int nMat  = GridGetCellSurfaceMaterial(oArea, nCell);

    if (GridIsWaterMaterial(nMat)) return TRUE;

    // Check neighboring cells - player may be standing at a cell boundary
    int nNeighborCount = GridGetNeighborCells(oArea, nCell);
    object oMod = GetModule();
    int i;
    for (i = 0; i < nNeighborCount; i++)
    {
        int nNeigh = GetLocalInt(oMod, GRDN_PFX + IntToString(i));
        int nNMat  = GridGetCellSurfaceMaterial(oArea, nNeigh);
        if (GridIsWaterMaterial(nNMat)) return TRUE;
    }

    return FALSE;
}

// ============================================================================
// SECTION 10: TICK UPDATE
// Called each tick to update grid cell occupancy for moving objects.
// Reads registry slots and moves them between cells as objects move.
// ============================================================================

/* ----------------------------------------------------------------------------
   GridUpdateSlot
   Updates the cell assignment for a single registry slot.
   Reads the object position, computes the new cell, moves the slot if needed.

   nOldCell - the cell the slot was last known to be in (0 or -1 if unknown)
   Returns the new cell index.
---------------------------------------------------------------------------- */
int GridUpdateSlot(object oArea, int nSlot, int nOldCell, object oObj)
{
    if (!GetIsObjectValid(oObj)) return nOldCell;

    vector vPos    = GetPosition(oObj);
    int    nNewCell = GridPosToCell(oArea, vPos);

    if (nNewCell == nOldCell) return nOldCell;  // No movement across cell boundary

    // Remove from old cell
    if (nOldCell >= 0)
        GridCellRemoveSlot(oArea, nOldCell, nSlot);

    // Add to new cell
    GridCellAddSlot(oArea, nNewCell, nSlot);

    return nNewCell;
}

/* ----------------------------------------------------------------------------
   GridTickUpdate
   Called from core_switch.nss on the grid update interval.
   Iterates all registry slots and refreshes their cell assignments.
   Only processes slots for creature types (anything that moves).
   Uses the registry iteration API.
---------------------------------------------------------------------------- */
void GridTickUpdate(object oArea)
{
    // Lazy area init
    if (!GetLocalInt(oArea, GRDA_INIT))
        GridInitArea(oArea);

    object oMod = GetModule();

    // Registry slot keys - must match core_registry.nss constants exactly.
    // RS_MAX_SLOT = "RS_MAX", RSF_OBJ = "O", RSF_FLAG = "F", RSF_GRIDCELL = "GC"
    // We use literal string values here because core_grid is #included BY
    // core_registry and we cannot reverse-include without a circular dependency.
    string sRSMax   = "RS_MAX";
    string sSlotPfx = "RS_";
    string sObjSuf  = "O";
    string sFlagSuf = "F";
    string sGCSuf   = "GC";

    int nMax   = GetLocalInt(oArea, sRSMax);
    int nCreat = GetLocalInt(oMod,  "RG_COMP_CREATURES");
    int nDebug = GetLocalInt(oMod,  GRD_PFX + GRDK_DEBUG);

    // On the first tick after area init, cache surface materials for all cells.
    // Guarded by GRD_SURF_CACHED flag so it runs exactly once per activation.
    if (!GetLocalInt(oArea, "GRD_SURF_CACHED") &&
        GetLocalInt(oMod, GRD_PFX + GRDK_SURF_ENABLE))
    {
        int nCells = GetLocalInt(oArea, GRDA_CELLS);
        int ci;
        for (ci = 0; ci < nCells; ci++)
            GridCacheSurfaceMaterial(oArea, ci);
        SetLocalInt(oArea, "GRD_SURF_CACHED", 1);
        if (nDebug)
            WriteTimestampedLogEntry("[GRID] Surface materials cached for " +
                GetTag(oArea) + " (" + IntToString(nCells) + " cells)");
    }

    int nMoved = 0;
    int nTotal = 0;

    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx  = sSlotPfx + IntToString(i) + "_";
        int    nFlag = GetLocalInt(oArea, sPfx + sFlagSuf);
        if (nFlag == 0) continue;           // Empty slot

        // Only update grid cell for creature types (they move)
        if ((nFlag & nCreat) == 0) continue;

        object oObj = GetLocalObject(oArea, sPfx + sObjSuf);
        if (!GetIsObjectValid(oObj)) continue;

        int nOldCell = GetLocalInt(oArea, sPfx + sGCSuf);
        int nNewCell = GridUpdateSlot(oArea, i, nOldCell, oObj);

        if (nNewCell != nOldCell)
        {
            SetLocalInt(oArea, sPfx + sGCSuf, nNewCell);
            nMoved++;
        }
        nTotal++;
    }

    if (nDebug)
        SendMessageToAllDMs("[GRID] " + GetTag(oArea) +
            " Updated=" + IntToString(nTotal) +
            " Moved=" + IntToString(nMoved));
}

// ============================================================================
// SECTION 11: AREA SHUTDOWN
// Clears all grid data for an area when it goes inactive.
// ============================================================================

void GridShutdownArea(object oArea)
{
    int nCells = GetLocalInt(oArea, GRDA_CELLS);
    int i;
    for (i = 0; i < nCells; i++)
    {
        string sCPfx = GRDC_PFX + IntToString(i);
        int    nCnt  = GetLocalInt(oArea, sCPfx + GRDC_CNT);
        int    j;
        for (j = 0; j < nCnt; j++)
            DeleteLocalInt(oArea, sCPfx + "_" + IntToString(j));
        DeleteLocalInt(oArea, sCPfx + GRDC_CNT);
        DeleteLocalInt(oArea, sCPfx + GRDC_MAT);
    }

    DeleteLocalInt(oArea,   GRDA_COLS);
    DeleteLocalInt(oArea,   GRDA_ROWS);
    DeleteLocalInt(oArea,   GRDA_CELLS);
    DeleteLocalFloat(oArea, GRDA_CWS);
    DeleteLocalInt(oArea,   GRDA_INIT);
    DeleteLocalInt(oArea,   "GRD_SURF_CACHED");
}

// ============================================================================
// SECTION 12: DM DIAGNOSTICS
// ============================================================================

void GridDump(object oArea, object oTarget)
{
    int nCols  = GetLocalInt(oArea, GRDA_COLS);
    int nRows  = GetLocalInt(oArea, GRDA_ROWS);
    int nCells = GetLocalInt(oArea, GRDA_CELLS);
    float fCWS = GetLocalFloat(oArea, GRDA_CWS);
    int nCS    = GetLocalInt(GetModule(), GRD_PFX + GRDK_CELL_SIZE);

    SendMessageToPC(oTarget,
        "=== GRID: " + GetTag(oArea) +
        "  Cols=" + IntToString(nCols) +
        "  Rows=" + IntToString(nRows) +
        "  Cells=" + IntToString(nCells) +
        "  CellSize=" + IntToString(nCS) + " tiles" +
        "  CellWorld=" + FloatToString(fCWS, 0, 1) + "m ===");

    // Report cells that have objects in them
    int i;
    for (i = 0; i < nCells; i++)
    {
        int nCnt = GetLocalInt(oArea, GRDC_PFX + IntToString(i) + GRDC_CNT);
        if (nCnt > 0)
        {
            int nMat = GetLocalInt(oArea, GRDC_PFX + IntToString(i) + GRDC_MAT);
            SendMessageToPC(oTarget,
                "  Cell " + IntToString(i) +
                ": " + IntToString(nCnt) + " slots" +
                "  Mat=" + IntToString(nMat));
        }
    }
}
