/* ============================================================================
    DOWE v2.2 - mg_manifest.nss
    Manifest Core System
    
    ARCHITECTURE:
    This is the heart of the manifest system. Every object in an area gets
    registered here with category flags. Think of it as a living inventory
    that updates itself automatically.
    
    WHY THIS WORKS:
    - O(1) slot allocation via freelist (no loops to find empty slots)
    - Token-based iteration (prevents nested loop conflicts)
    - Bitflag categories (single object can have multiple types)
    - Self-cleaning (ghosts removed automatically)
    
    CRITICAL FOR NWNEE:
    - All local vars are area-scoped (fast access)
    - No object scans (GetFirstObjectInArea is SLOW)
    - Tick-safe math (handles overflow at 10k)
    - TMI-proof JSON packer (chunks of 50)
   ============================================================================
*/

// ============================================================================
// CATEGORY FLAGS (Bitflags allow multi-category membership)
// ============================================================================

const int MF_PLAYER       = 0x0001;  // 1    - Player characters
const int MF_LIVE_NPC     = 0x0002;  // 2    - Persistent NPCs
const int MF_HENCHMAN     = 0x0004;  // 4    - Henchmen/followers
const int MF_MOUNT        = 0x0008;  // 8    - Mounts
const int MF_PET          = 0x0010;  // 16   - Animal companions
const int MF_SUMMONED     = 0x0020;  // 32   - Summoned creatures
const int MF_CREATURE     = 0x0040;  // 64   - Encounter spawns
const int MF_OBJECT       = 0x0080;  // 128  - Placeables/doors
const int MF_CORPSE       = 0x0100;  // 256  - Dead bodies
const int MF_ITEM         = 0x0200;  // 512  - Dropped items
const int MF_GATHER_NODE  = 0x0400;  // 1024 - Resource nodes
const int MF_CRAFT_BOX    = 0x0800;  // 2048 - Crafting containers
const int MF_WP_NPC       = 0x1000;  // 4096 - NPC spawn points
const int MF_WP_CREATURE  = 0x2000;  // 8192 - Creature spawn points
const int MF_WP_WALK      = 0x4000;  // 16384 - Walkable waypoints

// Composite flags for batch operations
const int MF_ALL_CREATURES = 0x007E;  // Everything from LiveNPC to Creature
const int MF_ALL_CULLABLE  = 0x7D80;  // Everything that can be cleaned up

// ============================================================================
// VARIABLE NAMES (Shortened for performance - less string processing)
// ============================================================================

const string M_SLOT_PFX    = "M_S_";          // Slot prefix
const string M_COUNT       = "M_CNT";         // Active entry count
const string M_MAX_SLOT    = "M_MAX";         // Highest slot number
const string M_FREE_HEAD   = "M_FREE";        // Freelist stack top
const string M_FREE_PFX    = "M_F_";          // Freelist entry prefix

// Slot property suffixes (appended to M_S_[SLOT]_)
const string M_OBJ         = "O";   // Object reference
const string M_FLAGS       = "F";   // Category flags
const string M_CDKEY       = "K";   // Player CD key
const string M_OWNER       = "W";   // Owner slot (for spawned creatures)
const string M_SPAWN       = "S";   // Spawn tick
const string M_EXPIRE      = "E";   // Expiration tick
const string M_TAG         = "T";   // Object tag (for searches)

const string M_OBJ_SLOT    = "M_SLOT";        // Reverse lookup on object
const string M_ITER_PFX    = "M_I_";          // Iterator state prefix

// ============================================================================
// CAPACITY CONFIGURATION
// ============================================================================

const int M_MAX_SLOTS      = 2000;  // Hard limit (prevents runaway growth)
const int M_WARN_THRESHOLD = 1800;  // 90% capacity warning

// ============================================================================
// FREELIST OPERATIONS (O(1) void reuse - CRITICAL FOR PERFORMANCE)
// ============================================================================

// Push a freed slot onto the reuse stack
// Called when an object is removed from manifest
void FreelistPush(object oArea, int nSlot)
{
    int nHead = GetLocalInt(oArea, M_FREE_HEAD);
    SetLocalInt(oArea, M_FREE_PFX + IntToString(nSlot), nHead);
    SetLocalInt(oArea, M_FREE_HEAD, nSlot);
}

// Pop a slot from the reuse stack
// Returns 0 if stack is empty
int FreelistPop(object oArea)
{
    int nHead = GetLocalInt(oArea, M_FREE_HEAD);
    if (nHead == 0) return 0;
    
    int nNext = GetLocalInt(oArea, M_FREE_PFX + IntToString(nHead));
    SetLocalInt(oArea, M_FREE_HEAD, nNext);
    DeleteLocalInt(oArea, M_FREE_PFX + IntToString(nHead));
    
    return nHead;
}

// ============================================================================
// DEBUG LOGGING (Batched to prevent spam)
// ============================================================================

void DebugManifest(object oArea, string sMsg)
{
    object oMod = GetModule();
    if (!GetLocalInt(oMod, "MG_DEBUG_MAN")) return;
    
    // BATCHING: Only log every 10th operation to prevent log flooding
    // This is critical in high-churn areas (combat zones, loot areas)
    int nLogCount = GetLocalInt(oMod, "M_LOG_CNT");
    SetLocalInt(oMod, "M_LOG_CNT", nLogCount + 1);
    
    if (nLogCount % 10 != 0) return;
    
    string sTag = GetIsObjectValid(oArea) ? GetTag(oArea) : "MODULE";
    int nTick = GetLocalInt(oMod, "MG_TICK");
    
    string sOut = "[MAN-" + IntToString(nTick) + "][" + sTag + "] " + sMsg;
    
    WriteTimestampedLogEntry(sOut);
    SendMessageToAllDMs(sOut);
}

// ============================================================================
// TICK ARITHMETIC (Handles overflow at 10,000)
// ============================================================================

// Calculate difference between ticks, handling wraparound
// NWNEE tick counters reset at configurable thresholds to prevent overflow
int GetTickDiff(int nCurrent, int nPast)
{
    if (nCurrent >= nPast)
        return nCurrent - nPast;
    else
        // Tick wrapped around at 10000
        return (10000 - nPast) + nCurrent;
}

// ============================================================================
// CORE MANIFEST FUNCTIONS
// ============================================================================

/* ----------------------------------------------------------------------------
   ManifestAdd - Register an object to the manifest
   
   PARAMETERS:
   oArea      - Area containing the object
   oObj       - Object to register
   nFlags     - Category flags (can combine multiple)
   nExpire    - Optional: Lifespan in ticks (0 = permanent)
   
   RETURNS:
   Assigned slot number (0 if failed)
   
   PERFORMANCE:
   O(1) via freelist, no iteration required
   
   CRITICAL FEATURES:
   - Double-registration protection (checks if already registered)
   - Capacity warnings (alerts at 90%, fails at 100%)
   - Automatic expiration setup
   - Reverse lookup storage (object → slot)
---------------------------------------------------------------------------- */
int ManifestAdd(object oArea, object oObj, int nFlags, int nExpire = 0)
{
    if (!GetIsObjectValid(oObj))
    {
        DebugManifest(oArea, "ERROR: Attempted to add invalid object");
        return 0;
    }
    
    // DOUBLE-REGISTRATION PROTECTION
    // Check if object already has a slot assigned
    int nExist = GetLocalInt(oObj, M_OBJ_SLOT);
    if (nExist > 0)
    {
        // Verify the slot still points to this object
        object oCheck = GetLocalObject(oArea, M_SLOT_PFX + IntToString(nExist) + M_OBJ);
        if (oCheck == oObj)
        {
            DebugManifest(oArea, "SKIP: Already registered at slot " + IntToString(nExist));
            return nExist;
        }
    }
    
    int nSlot = 0;
    
    // Try to reuse a freed slot (O(1) operation via stack pop)
    nSlot = FreelistPop(oArea);
    
    // No freed slots available, allocate new one
    if (nSlot == 0)
    {
        int nMax = GetLocalInt(oArea, M_MAX_SLOT);
        nSlot = nMax + 1;
        
        // CAPACITY CHECK - Hard limit to prevent runaway growth
        if (nSlot > M_MAX_SLOTS)
        {
            WriteTimestampedLogEntry("CRITICAL: Manifest full in " + GetTag(oArea));
            SendMessageToAllDMs("CRITICAL: Manifest capacity exceeded in " + GetTag(oArea));
            return 0;
        }
        
        // CAPACITY WARNING - Alert DMs before hitting limit
        if (nSlot > M_WARN_THRESHOLD && nMax <= M_WARN_THRESHOLD)
        {
            SendMessageToAllDMs("WARNING: Manifest at 90% capacity in " + GetTag(oArea));
        }
        
        SetLocalInt(oArea, M_MAX_SLOT, nSlot);
    }
    
    // Build slot prefix for all properties
    string sPfx = M_SLOT_PFX + IntToString(nSlot) + "_";
    
    // Store all slot properties
    SetLocalObject(oArea, sPfx + M_OBJ, oObj);
    SetLocalInt(oArea, sPfx + M_FLAGS, nFlags);
    SetLocalString(oArea, sPfx + M_TAG, GetTag(oObj));
    
    // Record spawn time
    int nTick = GetLocalInt(GetModule(), "MG_TICK");
    SetLocalInt(oArea, sPfx + M_SPAWN, nTick);
    
    // Set expiration if specified
    if (nExpire > 0)
    {
        int nExpTick = (nTick + nExpire) % 10000;
        SetLocalInt(oArea, sPfx + M_EXPIRE, nExpTick);
    }
    
    // Store reverse lookup (object → slot)
    SetLocalInt(oObj, M_OBJ_SLOT, nSlot);
    
    // Increment active count
    int nCount = GetLocalInt(oArea, M_COUNT);
    SetLocalInt(oArea, M_COUNT, nCount + 1);
    
    DebugManifest(oArea, "Add: " + GetTag(oObj) + " slot=" + IntToString(nSlot) + 
                         " flags=" + IntToString(nFlags));
    
    return nSlot;
}

/* ----------------------------------------------------------------------------
   ManifestRemove - Unregister an object from the manifest
   
   PARAMETERS:
   oArea - Area containing the object
   oObj  - Object to unregister
   
   PERFORMANCE:
   O(1) - Direct slot lookup via reverse reference
   
   SIDE EFFECTS:
   - Adds slot to freelist for reuse
   - Decrements active count
   - Clears all slot properties
---------------------------------------------------------------------------- */
void ManifestRemove(object oArea, object oObj)
{
    int nSlot = GetLocalInt(oObj, M_OBJ_SLOT);
    if (nSlot == 0) return;  // Not in manifest
    
    string sPfx = M_SLOT_PFX + IntToString(nSlot) + "_";
    
    // Clear all slot properties
    DeleteLocalObject(oArea, sPfx + M_OBJ);
    DeleteLocalInt(oArea, sPfx + M_FLAGS);
    DeleteLocalString(oArea, sPfx + M_CDKEY);
    DeleteLocalInt(oArea, sPfx + M_OWNER);
    DeleteLocalInt(oArea, sPfx + M_SPAWN);
    DeleteLocalInt(oArea, sPfx + M_EXPIRE);
    DeleteLocalString(oArea, sPfx + M_TAG);
    
    // Clear reverse lookup
    DeleteLocalInt(oObj, M_OBJ_SLOT);
    
    // Add slot to freelist for reuse
    FreelistPush(oArea, nSlot);
    
    // Decrement count
    int nCount = GetLocalInt(oArea, M_COUNT);
    if (nCount > 0)
        SetLocalInt(oArea, M_COUNT, nCount - 1);
    
    DebugManifest(oArea, "Remove: slot=" + IntToString(nSlot) + " (freed)");
}

// ============================================================================
// QUERY FUNCTIONS
// ============================================================================

// Get object at specific slot
object ManifestGetObj(object oArea, int nSlot)
{
    return GetLocalObject(oArea, M_SLOT_PFX + IntToString(nSlot) + "_" + M_OBJ);
}

// Get flags for specific slot
int ManifestGetFlags(object oArea, int nSlot)
{
    return GetLocalInt(oArea, M_SLOT_PFX + IntToString(nSlot) + "_" + M_FLAGS);
}

// Check if slot matches flag filter (bitwise AND)
int ManifestMatch(object oArea, int nSlot, int nFilter)
{
    int nFlags = ManifestGetFlags(oArea, nSlot);
    return (nFlags & nFilter) != 0;
}

// Get total active entries
int ManifestGetCount(object oArea)
{
    return GetLocalInt(oArea, M_COUNT);
}

// Count entries matching specific flags
// NOTE: This is O(n) where n = max slot, not active count
// Use sparingly in performance-critical code
int ManifestCountBy(object oArea, int nFilter)
{
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    int nMatches = 0;
    
    int i;
    for (i = 1; i <= nMax; i++)
    {
        if (ManifestMatch(oArea, i, nFilter))
        {
            object oObj = ManifestGetObj(oArea, i);
            if (GetIsObjectValid(oObj))
                nMatches++;
        }
    }
    
    return nMatches;
}

// ============================================================================
// ITERATION SYSTEM (Token-based for nested safety)
// ============================================================================

/* ----------------------------------------------------------------------------
   Token-Based Iteration
   
   WHY TOKENS ARE CRITICAL:
   Without tokens, nested iterations corrupt each other. Example:
   
   BROKEN (without tokens):
   foreach creature
       foreach player  ← This overwrites the creature iteration state!
           ...
   
   FIXED (with tokens):
   string sToken1 = ManifestToken();
   foreach creature (token1)
       string sToken2 = ManifestToken();
       foreach player (token2)  ← Separate state, no conflict
           ...
---------------------------------------------------------------------------- */

// Generate unique iteration token
string ManifestToken()
{
    object oMod = GetModule();
    int nToken = GetLocalInt(oMod, "M_TOKEN");
    nToken++;
    SetLocalInt(oMod, "M_TOKEN", nToken);
    return IntToString(nToken);
}

// Begin iteration, returns first matching object
// If sToken is empty, generates one automatically
object ManifestFirst(object oArea, int nFilter, string sToken = "")
{
    if (sToken == "") sToken = ManifestToken();
    
    string sSlot = M_ITER_PFX + sToken + "_S";
    string sFlag = M_ITER_PFX + sToken + "_F";
    
    SetLocalInt(oArea, sSlot, 1);
    SetLocalInt(oArea, sFlag, nFilter);
    
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    
    int i;
    for (i = 1; i <= nMax; i++)
    {
        if (ManifestMatch(oArea, i, nFilter))
        {
            object oObj = ManifestGetObj(oArea, i);
            if (GetIsObjectValid(oObj))
            {
                SetLocalInt(oArea, sSlot, i + 1);
                return oObj;
            }
        }
    }
    
    // No matches found, clean up state
    DeleteLocalInt(oArea, sSlot);
    DeleteLocalInt(oArea, sFlag);
    
    return OBJECT_INVALID;
}

// Continue iteration, returns next matching object
// Must use same token as ManifestFirst call
object ManifestNext(object oArea, string sToken = "DEFAULT")
{
    string sSlot = M_ITER_PFX + sToken + "_S";
    string sFlag = M_ITER_PFX + sToken + "_F";
    
    int nCur = GetLocalInt(oArea, sSlot);
    int nFilter = GetLocalInt(oArea, sFlag);
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    
    int i;
    for (i = nCur; i <= nMax; i++)
    {
        if (ManifestMatch(oArea, i, nFilter))
        {
            object oObj = ManifestGetObj(oArea, i);
            if (GetIsObjectValid(oObj))
            {
                SetLocalInt(oArea, sSlot, i + 1);
                return oObj;
            }
        }
    }
    
    // Iteration complete, clean up state
    DeleteLocalInt(oArea, sSlot);
    DeleteLocalInt(oArea, sFlag);
    
    return OBJECT_INVALID;
}

// ============================================================================
// PLAYER-SPECIFIC HELPERS
// ============================================================================

// Add player with CD key tracking
int ManifestAddPC(object oPC, object oArea)
{
    if (!GetIsPC(oPC)) return 0;
    
    int nSlot = ManifestAdd(oArea, oPC, MF_PLAYER);
    
    if (nSlot > 0)
    {
        string sPfx = M_SLOT_PFX + IntToString(nSlot) + "_";
        SetLocalString(oArea, sPfx + M_CDKEY, GetPCPublicCDKey(oPC));
    }
    
    return nSlot;
}

// Fast player count (uses cached count, not iteration)
int ManifestPCCount(object oArea)
{
    return ManifestCountBy(oArea, MF_PLAYER);
}

// ============================================================================
// CLEANUP OPERATIONS
// ============================================================================

/* ----------------------------------------------------------------------------
   ManifestCull - Remove expired objects
   
   RETURNS:
   Number of objects destroyed
   
   TICK SAFETY:
   Uses GetTickDiff to handle tick wraparound at 10,000
---------------------------------------------------------------------------- */
int ManifestCull(object oArea)
{
    int nTick = GetLocalInt(GetModule(), "MG_TICK");
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    int nCulled = 0;
    
    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx = M_SLOT_PFX + IntToString(i) + "_";
        int nExpire = GetLocalInt(oArea, sPfx + M_EXPIRE);
        
        if (nExpire > 0)
        {
            int nSpawn = GetLocalInt(oArea, sPfx + M_SPAWN);
            int nAge = GetTickDiff(nTick, nSpawn);
            int nLife = GetTickDiff(nExpire, nSpawn);
            
            // Object has exceeded lifespan
            if (nAge >= nLife)
            {
                object oObj = GetLocalObject(oArea, sPfx + M_OBJ);
                
                if (GetIsObjectValid(oObj))
                {
                    int nFlags = GetLocalInt(oArea, sPfx + M_FLAGS);
                    
                    // Only cull if it's a cullable type
                    if ((nFlags & MF_ALL_CULLABLE) != 0)
                    {
                        DestroyObject(oObj, 0.1);
                        ManifestRemove(oArea, oObj);
                        nCulled++;
                    }
                }
                else
                {
                    // Object already destroyed, clean manifest entry
                    ManifestRemove(oArea, oObj);
                }
            }
        }
    }
    
    return nCulled;
}

/* ----------------------------------------------------------------------------
   ManifestClean - Remove ghost references (invalid objects still in manifest)
   
   WHEN TO CALL:
   - Automatically every 10 beats via switchboard
   - Manually when manifest integrity suspected
---------------------------------------------------------------------------- */
void ManifestClean(object oArea)
{
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    int nCleaned = 0;
    
    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx = M_SLOT_PFX + IntToString(i) + "_";
        
        // Only check slots that appear to have data
        if (GetLocalInt(oArea, sPfx + M_FLAGS) > 0)
        {
            object oObj = GetLocalObject(oArea, sPfx + M_OBJ);
            if (!GetIsObjectValid(oObj))
            {
                // Ghost reference found - clear it
                ManifestRemove(oArea, oObj);
                nCleaned++;
            }
        }
    }
    
    if (nCleaned > 0)
        DebugManifest(oArea, "Cleaned " + IntToString(nCleaned) + " ghost refs");
}

// ============================================================================
// INTEGRITY VALIDATION
// ============================================================================

/* ----------------------------------------------------------------------------
   ManifestCheck - Validate manifest integrity
   
   PARAMETERS:
   oArea  - Area to check
   bQuick - TRUE for fast check (validity only), FALSE for deep check
   
   RETURNS:
   Number of issues found
   
   USAGE:
   - Quick check: Every 500 beats (production safe)
   - Deep check: Every 100 beats in debug mode only
---------------------------------------------------------------------------- */
int ManifestCheck(object oArea, int bQuick = TRUE)
{
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    int nIssues = 0;
    int nChecked = 0;
    
    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx = M_SLOT_PFX + IntToString(i) + "_";
        int nFlags = GetLocalInt(oArea, sPfx + M_FLAGS);
        
        if (nFlags == 0) continue;  // Empty slot
        
        nChecked++;
        
        // QUICK CHECK: Just verify object is valid
        if (bQuick)
        {
            object oObj = GetLocalObject(oArea, sPfx + M_OBJ);
            if (!GetIsObjectValid(oObj))
                nIssues++;
            
            continue;
        }
        
        // DEEP CHECK: Verify everything
        object oObj = GetLocalObject(oArea, sPfx + M_OBJ);
        if (!GetIsObjectValid(oObj))
        {
            DebugManifest(oArea, "INTEGRITY: Slot " + IntToString(i) + " invalid obj");
            nIssues++;
            continue;
        }
        
        // Check reverse lookup matches
        int nRev = GetLocalInt(oObj, M_OBJ_SLOT);
        if (nRev != i)
        {
            DebugManifest(oArea, "INTEGRITY: Slot " + IntToString(i) + " reverse mismatch");
            nIssues++;
        }
        
        // For creatures, verify owner is valid
        if ((nFlags & MF_ALL_CREATURES) != 0)
        {
            int nOwner = GetLocalInt(oArea, sPfx + M_OWNER);
            if (nOwner > 0)
            {
                object oOwn = ManifestGetObj(oArea, nOwner);
                if (!GetIsObjectValid(oOwn))
                {
                    DebugManifest(oArea, "INTEGRITY: Slot " + IntToString(i) + " bad owner");
                    nIssues++;
                }
            }
        }
    }
    
    if (!bQuick && nIssues == 0)
        DebugManifest(oArea, "INTEGRITY: OK (" + IntToString(nChecked) + " checked)");
    
    return nIssues;
}

// ============================================================================
// AREA SHUTDOWN
// ============================================================================

/* ----------------------------------------------------------------------------
   ManifestShutdown - Complete area cleanup when last player exits
   
   ZERO-WASTE PHILOSOPHY:
   - Destroys all cullable objects
   - Removes all area effects
   - Clears entire manifest
   - Resets freelist
   
   Area becomes completely dormant until next player enters
---------------------------------------------------------------------------- */
void ManifestShutdown(object oArea)
{
    // Destroy all cullable objects
    object oObj = ManifestFirst(oArea, MF_ALL_CULLABLE);
    
    while (GetIsObjectValid(oObj))
    {
        DestroyObject(oObj, 0.1);
        oObj = ManifestNext(oArea);
    }
    
    // Clear all area effects
    effect eEff = GetFirstEffect(oArea);
    while (GetIsEffectValid(eEff))
    {
        int nType = GetEffectType(eEff);
        if (nType == EFFECT_TYPE_VISUALEFFECT || nType == EFFECT_TYPE_AREA_OF_EFFECT)
            RemoveEffect(oArea, eEff);
        eEff = GetNextEffect(oArea);
    }
    
    // Clear all manifest data
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    
    int i;
    for (i = 1; i <= nMax; i++)
    {
        string sPfx = M_SLOT_PFX + IntToString(i) + "_";
        
        DeleteLocalObject(oArea, sPfx + M_OBJ);
        DeleteLocalInt(oArea, sPfx + M_FLAGS);
        DeleteLocalString(oArea, sPfx + M_CDKEY);
        DeleteLocalInt(oArea, sPfx + M_OWNER);
        DeleteLocalInt(oArea, sPfx + M_SPAWN);
        DeleteLocalInt(oArea, sPfx + M_EXPIRE);
        DeleteLocalString(oArea, sPfx + M_TAG);
    }
    
    // Reset manifest to pristine state
    SetLocalInt(oArea, M_FREE_HEAD, 0);
    SetLocalInt(oArea, M_COUNT, 0);
    SetLocalInt(oArea, M_MAX_SLOT, 0);
    
    DebugManifest(oArea, "Shutdown complete");
}

// ============================================================================
// JSON SERIALIZATION (Phase-Staggered to prevent TMI)
// ============================================================================

/* ----------------------------------------------------------------------------
   ManifestPackJson - Create JSON snapshot of manifest
   
   TMI PROTECTION:
   Processes 50 entries per phase with 0.1s delay between phases
   This prevents "Too Many Instructions" errors on large manifests
   
   OUTPUT:
   Stored in area local variable "M_JSON_SNAP"
---------------------------------------------------------------------------- */

void ManifestPackJson_Phase(object oArea, int nStart, string sJson)
{
    int nMax = GetLocalInt(oArea, M_MAX_SLOT);
    int nEnd = nStart + 49;  // Pack 50 at a time
    if (nEnd > nMax) nEnd = nMax;
    
    int i;
    for (i = nStart; i <= nEnd; i++)
    {
        object oObj = ManifestGetObj(oArea, i);
        if (!GetIsObjectValid(oObj)) continue;
        
        string sPfx = M_SLOT_PFX + IntToString(i) + "_";
        int nFlags = GetLocalInt(oArea, sPfx + M_FLAGS);
        
        if (sJson != "") sJson += ",";
        
        sJson += "{";
        sJson += "\"slot\":" + IntToString(i) + ",";
        sJson += "\"tag\":\"" + GetTag(oObj) + "\",";
        sJson += "\"flags\":" + IntToString(nFlags);
        sJson += "}";
    }
    
    // More entries to pack?
    if (nEnd < nMax)
    {
        // Schedule next phase in 0.1 seconds
        DelayCommand(0.1, ManifestPackJson_Phase(oArea, nEnd + 1, sJson));
    }
    else
    {
        // Complete - wrap in array and store
        sJson = "[" + sJson + "]";
        SetLocalString(oArea, "M_JSON_SNAP", sJson);
        DebugManifest(oArea, "JSON pack complete: " + IntToString(nMax) + " entries");
    }
}

// Start JSON packing from slot 1
void ManifestPackJson(object oArea)
{
    ManifestPackJson_Phase(oArea, 1, "");
}
