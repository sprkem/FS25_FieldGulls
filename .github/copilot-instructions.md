# FS25_FollowingBirds - GitHub Copilot Instructions

## Project Overview
This is a Farming Simulator 25 (FS25) mod that adds realistic bird behavior where seagulls follow plowing implements and other ground-working tools. Birds spawn gradually behind the tool, feed from the ground, perform aerial search patterns, and despawn when work stops.

## Target Platform
- **Engine**: Farming Simulator 25 (Giants Engine)
- **Language**: Lua 5.1/LuaJIT
- **Framework**: Giants Engine API with custom i3d 3D models and AnimCharacterSet animations

## File Structure & Responsibilities

### Core System Files

#### `src/BirdManager.lua`
**Purpose**: Global manager for independent bird updates  
**Pattern**: Mod event listener registered with `addModEventListener(BirdManager)`  
**Key Responsibilities**:
- Maintains `activeHotspots` table tracking vehicle→hotspot pairs
- Provides `update(dt)` called every frame regardless of vehicle state
- Ensures birds continue updating even when player walks away from vehicle
- Handles hotspot registration/unregistration lifecycle
- Prevents game optimization from pausing bird updates

**Critical**: Must be loaded FIRST in modDesc.xml to ensure availability for other components.

#### `src/SimpleBirdDirect.lua`
**Purpose**: Individual bird instance with direct scene graph manipulation  
**Key Responsibilities**:
- Creates and manages bird's 3D rootNode in the scene
- Handles movement (straight paths and curved arcs)
- Updates animation frames manually (AnimCharacterSet at 24 FPS)
- Provides `moveToCurved(x, y, z, speed, curvature)` for arcing paths
- Cleans up scene nodes on deletion

**Animation System**: Frame-based manual scrubbing (not automatic playback). Must increment `animTime` manually and call `setAnimTime()` each frame.

#### `src/BirdStateMachine.lua`
**Purpose**: Controls bird lifecycle and behavior states  
**States**:
1. `SPAWNING` - Initial spawn, flying from behind to plow area
2. `APPROACHING_PLOW` - Flying to feeding zone
3. `FEEDING_GROUND` - On ground, pecking/eating (idle animation)
4. `FEEDING_UP` - Flying upward to ~10m height
5. `FEEDING_ARC` - Smooth arcing path looping back down to new ground position
6. `DESPAWNING` - Flying away when tool stops working

**Key Configuration**:
- `feedingConfig.groundTargetRadius` - Pick targets within 8m of plow
- `feedingConfig.upwardHeight` - Base height 10m + 0-5m random
- `feedingConfig.arcTargetRadius` - Pick landing spots within 5m
- `feedingConfig.arcCurvature` - Arc curvature (1.2 = smooth parabolic loop)

**Critical Behavior**: 
- Birds fly up, then arc smoothly back down in one continuous motion
- No hover/pause states - continuous fluid movement
- Curved paths use `CurvedPathPlanner` for natural flight

#### `src/ToolBirdHotspotDirect.lua`
**Purpose**: Manages bird flock for a specific tool/vehicle  
**Key Responsibilities**:
- Spawns birds gradually (one every 500ms, max 60 birds)
- Dynamic hotspot positioning: 0m offset when moving, 3m behind when stopped
- Movement detection using 0.1 m/s threshold comparing vehicle position
- Despawn timer system: 15000ms delay, then gradual 500ms per bird despawn
- 3D positional audio for bird flock sound
- Registers/unregisters with BirdManager based on active state

**Critical State Management**:
- `isActive` - Currently spawning/active
- `isDespawning` - Gradual despawn in progress
- `spawnedBirds` - Array of active feeding birds
- `despawningBirds` - Array of birds flying away
- Must re-register with BirdManager on reactivation after despawn completes

**Configuration Constants**:
```lua
HOTSPOT_OFFSET_MOVING = 0       -- Offset when moving
HOTSPOT_OFFSET_STOPPED = 3      -- Offset when stopped (meters)
MOVEMENT_THRESHOLD = 0.1        -- Speed to consider "moving" (m/s)
MAX_BIRDS = 60                  -- Max flock size
SPAWN_INTERVAL = 500            -- Milliseconds between bird spawns
DESPAWN_DELAY = 15000           -- Wait before despawn starts (ms)
DESPAWN_DURATION = 10000        -- How long birds fly away (ms)
```

#### `src/ToolBirdsExtension.lua`
**Purpose**: Generic vehicle extension coordinating tool work state  
**Key Responsibilities**:
- Detects work state changes via `getIsWorkAreaActive()`
- Calls `hotspot:activate()` when work starts
- Starts despawn timer via `hotspot:startDespawnTimer()` when work stops
- Cancels despawn via `hotspot:cancelDespawnTimer()` if work resumes
- Base class for tool-specific extensions

**Pattern**: Attached to vehicle via specialization system, polls work state every update.

#### `src/extensions/PlowExtension.lua`
**Purpose**: Plow-specific implementation  
**Extends**: ToolBirdsExtension  
**Specifics**:
- Uses `WorkAreaType.PLOW` to identify plow work areas
- Calculates working width from work area geometry
- Spawns hotspot on first plow activation
- Can be duplicated for other tool types (cultivator, seeder, etc.)

### Utility Files

#### `src/CurvedPathPlanner.lua`
**Purpose**: Generates smooth curved paths between two 3D points  
**Algorithm**: 
- Creates arc with configurable curvature parameter
- Calculates control point perpendicular to start→end line
- Uses quadratic Bezier curve interpolation
- Returns position at parameter `t` (0.0 to 1.0)

**Usage**: `path = CurvedPathPlanner.new(x1, y1, z1, x2, y2, z2, curvature)`  
Then call `path:getPointAt(t)` for position along curve.

#### `src/BirdConfig.lua`
**Purpose**: Loads bird species configuration from XML  
**Loads**:
- i3d model path and asset references
- Animation frame ranges (AnimCharacterSet mappings)
- Sound files and volumes
- Behavior parameters

**Location**: Reads from `data/seagull.xml` in mod folder.

#### `src/BirdSounds.lua`
**Purpose**: Individual bird sound management (currently not actively used)  
**Note**: Flock sound is now handled by ToolBirdHotspotDirect with 3D positional audio. Individual bird sounds may be added later for variety.

### Data Files

#### `data/seagull.xml`
**Purpose**: Bird species configuration  
**Contents**:
- i3d model path: `seagull/SeagullBigScale.i3d`
- AnimCharacterSet animation mappings (frame ranges):
  - `fly`: 135-155 (standard flight)
  - `flyUp`: 235-255 (upward flight)
  - `flyDownFlapping`: 210-230 (diving)
  - `idleEat`: 520-550 (ground feeding)
  - Others: glide, soar, hover variations
- Sound files: `seagull/sounds/1.ogg`
- Behavior timings: ground idle 4-6 seconds

#### `seagull/` folder
Contains:
- `SeagullBigScale.i3d` - 3D model and scene graph
- `SeagullBigScale.i3d.shapes` - Mesh geometry
- `SeagullBigScale.i3d.anim` - AnimCharacterSet animation data
- `seagull_diffuse.dds` - Texture
- `sounds/` - Audio files

### Reference Files (`refs/` folder)
**Purpose**: Giants Engine source code references for learning patterns  
**Notable References**:
- `WildlifeManager.lua` - Original wildlife system
- `WildlifeInstanceMover.lua` - Movement patterns
- `WildlifeStateMachine.lua` - State machine patterns
- `SeasonsDownfallUpdater.lua` - Mod event listener pattern
- `MathUtil.lua` - Math utilities

These are NOT loaded by the mod - they're documentation only.

## Key Architecture Patterns

### Independent Update System
**Problem**: Vehicle updates pause when player walks away (engine optimization).  
**Solution**: BirdManager uses `addModEventListener` pattern (like MoistureSystem) to receive updates every frame regardless of vehicle state.

### Gradual Spawn/Despawn
**Why**: Spawning 60 birds instantly looks unnatural and causes performance spike.  
**Implementation**: 
- Spawn one bird every 500ms until reaching MAX_BIRDS
- Despawn waits 15000ms (15 sec) after work stops, then removes one bird every 500ms
- Sound plays during spawn/despawn until last bird starts flying away

### Dynamic Hotspot Positioning
**Behavior**: 
- Hotspot (bird feeding center) moves with vehicle
- When moving (>0.1 m/s): hotspot at vehicle position (0m offset)
- When stopped: hotspot 3m behind vehicle (birds settle behind)
- Uses last frame position comparison for movement detection

### Curved Flight Paths
**Purpose**: Natural bird movement with arcing trajectories  
**Usage**: `bird:moveToCurved(targetX, targetY, targetZ, speed, curvature)`  
Higher curvature = more pronounced arc. Used for:
- Upward flight transitions
- Arcing search loops (feeding cycle)
- Natural-looking dives back to ground

### State Machine Feeding Loop
**Cycle**: FEEDING_GROUND → FEEDING_UP → FEEDING_ARC → FEEDING_GROUND (repeat)
1. Peck ground for random 4-6 seconds
2. Fly up to ~10-15m height with upward animation
3. Arc smoothly to new horizontal position with fly animation
4. Dive back down with curved path
5. Land and repeat

**Critical**: No hover/pause states - continuous motion creates fluid, realistic behavior.

## Coding Conventions

### Lua Version
- **Target**: Lua 5.1/LuaJIT (not Lua 5.4)
- Use `math.atan2()` not `math.atan(y, x)`
- No integer division `//` operator
- No `goto` statements

### Giants Engine API
Common functions used:
- `getWorldTranslation(node)` - Get 3D position
- `setTranslation(node, x, y, z)` - Set position
- `getRotation(node)` - Get rotation (pitch, yaw, roll)
- `setRotation(node, pitch, yaw, roll)` - Set rotation
- `localDirectionToWorld(node, x, y, z)` - Convert local direction to world
- `getTerrainHeightAtWorldPos(terrainNode, x, y, z)` - Get ground height
- `createTransformGroup(name)` - Create scene node
- `link(parent, child)` - Attach child to parent in scene graph
- `delete(node)` - Remove from scene and free memory
- `g_time` - Global time in milliseconds
- `g_currentMission.terrainRootNode` - Terrain reference

### Animation System (AnimCharacterSet)
**NOT automatic playback** - manual frame scrubbing required:
```lua
-- Set animation by name (loads frame range)
bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY)

-- Each frame, increment time and update
bird.animTime = bird.animTime + dt * bird.animSpeed
if bird.animTime > bird.animDuration then
    bird.animTime = bird.animTime - bird.animDuration -- Loop
end
setAnimTime(bird.animCharSet, bird.animTime)
```

### Memory Management
**Critical**: Always clean up scene nodes:
```lua
function cleanup()
    if self.rootNode and self.rootNode ~= 0 then
        delete(self.rootNode)
        self.rootNode = nil
    end
end
```

### Class Pattern
```lua
MyClass = {}
local MyClass_mt = Class(MyClass)

function MyClass.new(param)
    local self = setmetatable({}, MyClass_mt)
    -- Initialize
    return self
end
```

## Common Pitfalls

1. **Animation Reset Bug**: Don't call `setAnimationByName()` every frame - it resets animation time. Call only on state enter.

2. **Config Field Renames**: When refactoring config, search ALL files for old field names (e.g., `downwardTargetRadius` → `arcTargetRadius`).

3. **Despawn Re-registration**: After despawn completes, hotspot unregisters from BirdManager. Must re-register on reactivation or birds won't spawn.

4. **State Machine Transitions**: Check `isDespawning` flag before `isActive` in activation logic to properly cancel despawn-in-progress.

5. **Movement Detection**: Must store `lastX`/`lastZ` and compare to current position each frame to detect if vehicle is moving.

6. **Curved Path Speed**: The `speed` parameter in `moveToCurved()` is movement speed in m/s. Common values:
   - Spawning/approaching: 8.0 m/s
   - Upward flight: 8.0 m/s
   - Arcing descent: 10.0 m/s
   - Despawning: 20.0 m/s

7. **Sound Lifecycle**: Initialize sound on activate, play after 8 seconds, stop only when last bird marked for despawn.

## Testing Checklist

When modifying code, test these scenarios:
- [ ] Birds spawn gradually when plowing starts
- [ ] Birds continue moving when player exits vehicle and walks away
- [ ] Hotspot stays at plow when moving, settles 3m behind when stopped
- [ ] Despawn triggers 15 seconds after stopping
- [ ] Birds despawn one at a time over 30 seconds (60 birds * 0.5s)
- [ ] Restarting plow during despawn cancels it and resumes spawning
- [ ] Restarting plow after despawn completes spawns new birds
- [ ] Birds perform smooth arcing loops (up → arc → down) without pauses
- [ ] Animations play correctly without resetting
- [ ] No Lua errors in game log

## Performance Considerations

- **Max Birds**: Currently 60. Can be increased but affects performance.
- **Update Frequency**: Birds update every frame (smooth), hotspot position every 50ms (optimization).
- **Curved Paths**: Slightly more expensive than straight paths but negligible for 60 birds.
- **Scene Graph**: Each bird is a transformGroup node. Keep cleanup rigorous to prevent memory leaks.

## Future Enhancement Ideas

- Support for other tool types (cultivator, seeder, spreader)
- Multiple bird species with different behaviors
- Weather-dependent spawning (more birds after rain)
- Seasonal variations
- Individual bird sounds (currently only flock sound)
- Perching on vehicles when stopped for extended periods
- Interaction with other mods (Seasons, Precision Farming)

## modDesc.xml Load Order
**Critical**: Files must load in this order:
1. BirdManager (global manager, must be first)
2. CurvedPathPlanner (used by SimpleBirdDirect)
3. BirdStateMachine (used by SimpleBirdDirect)
4. BirdConfig (loads data, used by SimpleBirdDirect)
5. SimpleBirdDirect (bird instances, used by ToolBirdHotspotDirect)
6. ToolBirdHotspotDirect (hotspot manager, used by extensions)
7. ToolBirdsExtension (base extension)
8. PlowExtension (specific tool extension)

Changing this order may cause `nil` references or undefined globals.

## Git Workflow Notes

Build scripts in root:
- `package.bat` - Creates zip for distribution
- `moveDebug.bat` - Copies to FS25 mods folder for testing
- `moveZip.bat` - Copies packaged zip to FS25 mods folder

The user frequently commits with message "reasonable state" when features are working.
