---
-- PlowBirdHotspot
-- A custom wildlife hotspot that follows a plow implement while it's working
---

---
-- SimpleBird: A minimal bird instance with only movement, no state machine or graphics loading
---
SimpleBird = {}
local SimpleBird_mt = Class(SimpleBird)

function SimpleBird.new(x, y, z, hotspot)
    local self = setmetatable({}, SimpleBird_mt)
    self.hotspot = hotspot
    self.isDespawning = false
    self.despawnStartTime = 0
    
    -- Create a minimal species object with just movement attributes
    self.species = {
        movementAttributes = {
            canFly = true,         -- Flying mode to prevent ground snapping
            walkSpeed = 48.0,      -- Walking speed in m/s (8x original)
            flySpeed = 48.0,       -- Flying speed in m/s (8x original)
            climbSpeed = 8.0,      -- Climb speed increased proportionally
            flyHeight = {          -- Very low fly height to stay near ground
                minimum = 0.2,
                maximum = 0.5
            },
            canSwim = false,
            canIdleInWater = false,
            wadeDepth = 0
        }
    }
    
    -- Create root node for position tracking
    self.rootNode = createTransformGroup("SimpleBird")
    link(getRootNode(), self.rootNode)
    setWorldTranslation(self.rootNode, x, y, z)
    
    -- Load crow visual model
    local crowModelPath = "dataS/character/animals/wild/crow/crow.i3d"
    local crowI3dNode = g_i3DManager:loadSharedI3DFile(crowModelPath, false, false)
    if crowI3dNode and crowI3dNode ~= 0 then
        local crowNode = getChildAt(crowI3dNode, 0)
        if crowNode then
            link(self.rootNode, crowNode)
            delete(crowI3dNode) -- Delete the temporary root
            setVisibility(crowNode, true)
            -- Scale down a bit (crows are quite large in the game model)
            setScale(crowNode, 0.8, 0.8, 0.8)
            self.visualNode = crowNode
            print("[SimpleBird] Loaded visual model")
        end
    else
        print("[SimpleBird] WARNING: Could not load crow model, bird will be invisible")
    end
    
    -- Create the mover component (handles actual movement)
    self.mover = WildlifeInstanceMover.new(self)
    
    -- State machine that gives new target immediately when reached
    self.stateMachine = {
        onMovementTargetReached = function()
            -- Don't give new targets if bird is despawning
            if not self.isDespawning and self.hotspot and self.hotspot.giveNewTargetToBird then
                if math.random() < 0.2 then  -- 20% logging chance
                    print("[SimpleBird] Target reached! Getting new target immediately...")
                end
                self.hotspot:giveNewTargetToBird(self)
            end
        end
    }
    
    -- Stub for graphics interface (mover calls animation methods)
    self.graphics = {
        transitionToAnimation = function() end,
        getHasStateAnimation = function() return false end
    }
    
    -- Stub for sounds interface (mover may call this)
    self.sounds = {
        playSound = function() end
    }
    
    print(string.format("[SimpleBird] Created at (%.2f, %.2f, %.2f)", x, y, z))
    
    return self
end

function SimpleBird:getCurrentPosition()
    return getWorldTranslation(self.rootNode)
end

function SimpleBird:update(dt)
    if self.mover then
        self.mover:update(dt)
        local isMoving = self.mover:getIsMoving()
        if math.random() < 0.05 then  -- 5% chance for verbose logging
            local x, y, z = self:getCurrentPosition()
            print(string.format("[SimpleBird] Update: pos=(%.1f,%.1f,%.1f) isMoving=%s isDespawning=%s", 
                x, y, z, tostring(isMoving), tostring(self.isDespawning)))
        end
    end
end

function SimpleBird:delete()
    print("[SimpleBird] Deleting bird")
    if self.mover then
        self.mover:cancelTarget()
    end
    if self.visualNode then
        delete(self.visualNode)
    end
    if self.rootNode then
        delete(self.rootNode)
    end
end

function SimpleBird:moveToTarget(x, y, z, speed)
    if self.mover then
        return self.mover:moveToTarget(x, y, z, speed)
    end
    return false
end

function SimpleBird:getIsMoving()
    if self.mover then
        return self.mover:getIsMoving()
    end
    return false
end

PlowBirdHotspot = {}
local PlowBirdHotspot_mt = Class(PlowBirdHotspot)

-- Configuration
PlowBirdHotspot.HOTSPOT_RADIUS = 5         -- Radius around the plow where birds gather (meters)
PlowBirdHotspot.HOTSPOT_OFFSET_BEHIND = 2  -- How far behind the plow to position the hotspot (meters)
PlowBirdHotspot.MAX_BIRDS = 20             -- Maximum number of birds around the plow
PlowBirdHotspot.UPDATE_INTERVAL = 50       -- Update hotspot position every 50ms (20 times per second)
PlowBirdHotspot.BIRD_UPDATE_INTERVAL = 100 -- Update bird targets every 100ms for variety
PlowBirdHotspot.TARGET_DISTANCE = 5        -- Birds get targets 5m away (longer movements)
PlowBirdHotspot.SPAWN_HEIGHT = 1.0         -- Spawn birds 1m above ground (visible spawn height)
PlowBirdHotspot.BIRD_HEIGHT_OFFSET = 0.3   -- Keep birds slightly above ground (prevents ground clipping)

---
-- Get the working width of the plow from its work areas
-- @param vehicle: The plow vehicle
-- @return width in meters, or 5.0 as default
---
function PlowBirdHotspot.getPlowWorkingWidth(vehicle)
    if not vehicle or not vehicle.spec_workArea then
        return 5.0 -- Default fallback
    end
    
    local workAreas = vehicle.spec_workArea.workAreas
    if not workAreas or #workAreas == 0 then
        return 5.0
    end
    
    -- Get the first plow work area
    for _, workArea in ipairs(workAreas) do
        if workArea.type == WorkAreaType.PLOW and workArea.start and workArea.width then
            local x1, _, z1 = getWorldTranslation(workArea.start)
            local x2, _, z2 = getWorldTranslation(workArea.width)
            local width = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
            print(string.format("[PlowBirdHotspot] Detected plow working width: %.2fm", width))
            return width
        end
    end
    
    return 5.0 -- Fallback if no plow work area found
end

---
-- Virtual leader object that wraps the plow vehicle for the wildlife follow state
---
PlowVirtualLeader = {}
local PlowVirtualLeader_mt = Class(PlowVirtualLeader)

function PlowVirtualLeader.new(plowVehicle, hotspot)
    local self = setmetatable({}, PlowVirtualLeader_mt)
    self.plowVehicle = plowVehicle
    self.hotspot = hotspot
    self.mover = {
        currentAverageSpeed = 1.0, -- Default walking speed
        isFlyingToTarget = false
    }
    return self
end

function PlowVirtualLeader:getCurrentPosition()
    -- Return hotspot position (behind the plow)
    return self.hotspot.worldX, self.hotspot.worldY, self.hotspot.worldZ
end

function PlowVirtualLeader:calculateDistanceFrom(x, z)
    local dx = self.hotspot.worldX - x
    local dz = self.hotspot.worldZ - z
    return math.sqrt(dx * dx + dz * dz)
end

function PlowVirtualLeader:update()
    -- Update speed based on vehicle speed
    if self.plowVehicle then
        local vx, _, vz = getWorldTranslation(self.plowVehicle.rootNode)
        if self.lastX then
            local dx = vx - self.lastX
            local dz = vz - self.lastZ
            local distance = math.sqrt(dx * dx + dz * dz)
            -- Speed in m/s (dt is in ms, convert to seconds)
            self.mover.currentAverageSpeed = math.max(0.5, distance * 5) -- Estimate speed
        end
        self.lastX, self.lastZ = vx, vz
    end
end

---
-- Create a new PlowBirdHotspot instance
-- @param wildlifeManager: The wildlife manager
-- @param plowVehicle: The plow vehicle this hotspot follows
-- @return PlowBirdHotspot instance
---
function PlowBirdHotspot.new(wildlifeManager, plowVehicle)
    local self = setmetatable({}, PlowBirdHotspot_mt)

    self.wildlifeManager = wildlifeManager
    self.plowVehicle = plowVehicle
    self.worldX = 0
    self.worldY = -200 -- Start below ground (inactive)
    self.worldZ = 0
    self.radius = PlowBirdHotspot.HOTSPOT_RADIUS
    self.attractedSpecies = {}
    self.spawnedBirds = {} -- Track our spawned birds
    self.despawningBirds = {} -- Track birds that are flying away
    self.isActive = false
    self.lastUpdateTime = 0
    self.lastBirdUpdateTime = 0                                   -- For updating bird movement targets
    self.movementDirection = 0                                    -- Direction the plow is moving
    self.birdsSpawned = false                                     -- Track if initial birds have been spawned
    self.virtualLeader = PlowVirtualLeader.new(plowVehicle, self) -- Virtual leader for follow state
    self.workingWidth = PlowBirdHotspot.getPlowWorkingWidth(plowVehicle) -- Cache the working width

    return self
end

---
-- Activate the hotspot at the plow's current position
-- @return true if activated successfully
---
function PlowBirdHotspot:activate()
    print("[PlowBirdHotspot] === ACTIVATE CALLED ===")
    if not self.plowVehicle or self.isActive then
        print("[PlowBirdHotspot] Already active or no vehicle")
        return false
    end

    -- Get plow position
    local plowX, plowY, plowZ = getWorldTranslation(self.plowVehicle.rootNode)

    -- Initialize movement direction (assume plow is moving forward)
    local dx, _, dz = localDirectionToWorld(self.plowVehicle.rootNode, 0, 0, 1)
    self.movementDirection = math.atan2(dx, dz)

    -- Position hotspot behind the plow from the start
    local behindAngle = self.movementDirection + math.pi
    self.worldX = plowX + math.sin(behindAngle) * PlowBirdHotspot.HOTSPOT_OFFSET_BEHIND
    self.worldY = plowY
    self.worldZ = plowZ + math.cos(behindAngle) * PlowBirdHotspot.HOTSPOT_OFFSET_BEHIND
    self.isActive = true
    self.lastUpdateTime = g_time
    self.birdsSpawned = false

    print("[PlowBirdHotspot] Hotspot activated with SimpleBird system (no species loading needed)")

    return true
end

---
-- Deactivate the hotspot
---
function PlowBirdHotspot:deactivate()
    print(string.format("[PlowBirdHotspot] === DEACTIVATE CALLED === Active birds: %d, Despawning birds: %d", 
        #self.spawnedBirds, #self.despawningBirds))
    self.isActive = false
    self.worldY = -200 -- Move below ground
end

---
-- Update hotspot position to follow the plow
-- @param dt: Delta time in milliseconds
---
function PlowBirdHotspot:update(dt)
    -- ALWAYS update and cleanup despawning birds (even if inactive)
    for i = #self.despawningBirds, 1, -1 do
        local bird = self.despawningBirds[i]
        if bird then
            bird:update(dt)  -- Keep updating the bird's movement
            local elapsed = g_time - bird.despawnStartTime
            if elapsed > 5000 then
                print(string.format("[PlowBirdHotspot] Despawning bird %d deleted after %.1fs", i, elapsed/1000))
                if bird.delete then
                    bird:delete()
                end
                table.remove(self.despawningBirds, i)
            elseif math.random() < 0.1 then  -- 10% logging chance
                local x, y, z = bird:getCurrentPosition()
                print(string.format("[PlowBirdHotspot] Despawning bird %d: pos=(%.1f,%.1f,%.1f) elapsed=%.1fs",
                    i, x, y, z, elapsed/1000))
            end
        end
    end
    
    -- Auto-deactivate when no active birds and no despawning birds
    if not self.isActive and #self.despawningBirds == 0 then
        return  -- Fully inactive, nothing to update
    end
    
    if not self.isActive or not self.plowVehicle then
        return  -- Only update despawning birds above
    end

    -- Update each bird's mover EVERY FRAME for smooth movement
    for _, bird in ipairs(self.spawnedBirds) do
        if bird and bird.update then
            bird:update(dt)
        end
    end

    -- Update hotspot position periodically (not every frame for performance)
    if g_time - self.lastUpdateTime < PlowBirdHotspot.UPDATE_INTERVAL then
        return
    end

    self.lastUpdateTime = g_time

    -- Get current plow position and direction
    local plowX, plowY, plowZ = getWorldTranslation(self.plowVehicle.rootNode)

    -- Get the plow's current facing direction (always current, not based on movement)
    local dx, _, dz = localDirectionToWorld(self.plowVehicle.rootNode, 0, 0, 1)
    self.movementDirection = math.atan2(dx, dz)

    -- Position hotspot behind the plow in the worked area
    local behindAngle = self.movementDirection + math.pi -- Opposite direction
    self.worldX = plowX + math.sin(behindAngle) * PlowBirdHotspot.HOTSPOT_OFFSET_BEHIND
    self.worldY = plowY
    self.worldZ = plowZ + math.cos(behindAngle) * PlowBirdHotspot.HOTSPOT_OFFSET_BEHIND

    -- Update the virtual leader (for follow state)
    self.virtualLeader:update()

    -- Update bird movement targets periodically to keep them following
    if g_time - self.lastBirdUpdateTime >= PlowBirdHotspot.BIRD_UPDATE_INTERVAL then
        self.lastBirdUpdateTime = g_time
        self:updateBirdMovement()
    end
end

---
-- Spawn initial set of birds at this hotspot
-- Birds are spawned once and then manually controlled
---
function PlowBirdHotspot:spawnInitialBirds()
    if self.birdsSpawned or not self.isActive then
        return false
    end

    print(string.format("[PlowBirdHotspot] Spawning %d SimpleBirds 20m behind hotspot", PlowBirdHotspot.MAX_BIRDS))

    -- Spawn birds spread perpendicular to movement direction (left-right), 20m back
    local totalSpawned = 0
    for i = 1, PlowBirdHotspot.MAX_BIRDS do
        -- Calculate perpendicular angle (90 degrees to movement direction)
        local perpAngle = self.movementDirection + math.pi / 2
        
        -- Spread birds along perpendicular axis based on plow working width
        local lateralOffset = (i / PlowBirdHotspot.MAX_BIRDS - 0.5) * self.workingWidth * 1.2
        -- Spawn 20 meters behind the hotspot (opposite of movement direction)
        local longitudinalOffset = 20 + (math.random() - 0.5) * 3 -- 20m back with slight variation
        
        -- Calculate spawn position: hotspot + lateral offset perpendicular + backward offset
        local spawnX = self.worldX + math.sin(perpAngle) * lateralOffset - math.sin(self.movementDirection) * longitudinalOffset
        local spawnZ = self.worldZ + math.cos(perpAngle) * lateralOffset - math.cos(self.movementDirection) * longitudinalOffset
        local spawnY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, spawnX, 0, spawnZ) +
            PlowBirdHotspot.SPAWN_HEIGHT

        -- Create a SimpleBird (bypasses species loading)
        local bird = SimpleBird.new(spawnX, spawnY, spawnZ, self)
        
        if bird then
            -- Track it
            table.insert(self.spawnedBirds, bird)
            totalSpawned = totalSpawned + 1

            -- Give the bird an initial target at the hotspot center (fly-in effect from 20m back)
            local targetX = self.worldX
            local targetZ = self.worldZ
            local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) + PlowBirdHotspot.BIRD_HEIGHT_OFFSET
            
            print(string.format("[PlowBirdHotspot] Spawned bird %d at (%.1f, %.1f, %.1f)", i, spawnX, spawnY, spawnZ))
            bird.mover:flyToTarget(targetX, targetY, targetZ, 48.0, true)
            print(string.format("[PlowBirdHotspot] -> Set fly target to hotspot center (%.1f, %.1f, %.1f)", targetX, targetY, targetZ))
            
            -- Force immediate mover update to initiate movement
            bird.mover:update(50)  -- 50ms initial update to start movement
            print(string.format("[PlowBirdHotspot] -> Initial mover update completed, isMoving=%s", 
                tostring(bird.mover:getIsMoving())))
        end
    end

    self.birdsSpawned = true
    self.lastBirdUpdateTime = g_time
    print(string.format("[PlowBirdHotspot] === Spawned %d SimpleBirds ===", totalSpawned))
    return totalSpawned > 0
end

---
-- Update bird movement to follow the hotspot
---
function PlowBirdHotspot:updateBirdMovement()
    if not self.isActive or #self.spawnedBirds == 0 then
        return
    end

    -- Clean up despawned birds
    for i = #self.spawnedBirds, 1, -1 do
        local bird = self.spawnedBirds[i]
        if not bird or not bird.rootNode or not entityExists(bird.rootNode) then
            table.remove(self.spawnedBirds, i)
        end
    end

    -- Update each bird's target to keep them following the hotspot
    for i, bird in ipairs(self.spawnedBirds) do
        if bird and bird.mover and bird.rootNode and entityExists(bird.rootNode) then
            local bx, by, bz = getWorldTranslation(bird.rootNode)
            local distanceFromHotspot = math.sqrt((bx - self.worldX) ^ 2 + (bz - self.worldZ) ^ 2)
            local isMoving = bird.mover:getIsMoving()

            -- If bird is too far behind, teleport it closer
            if distanceFromHotspot > self.radius * 3 then
                -- Teleport bird perpendicular to movement direction
                local perpAngle = self.movementDirection + math.pi / 2
                local lateralOffset = (math.random() - 0.5) * self.radius * 2.5
                local longitudinalOffset = (math.random() - 0.5) * self.radius * 0.5
                local newX = self.worldX + math.sin(perpAngle) * lateralOffset + math.sin(self.movementDirection) * longitudinalOffset
                local newZ = self.worldZ + math.cos(perpAngle) * lateralOffset + math.cos(self.movementDirection) * longitudinalOffset
                local newY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, newX, 0, newZ) + PlowBirdHotspot.SPAWN_HEIGHT
                
                setWorldTranslation(bird.rootNode, newX, newY, newZ)
                bird.mover:cancelTarget()
                
                print(string.format("[PlowBirdHotspot] Bird %d teleported (was %.1fm away)", i, distanceFromHotspot))
            -- Only give new targets if bird is far from hotspot (whether moving or idle)
            elseif distanceFromHotspot > self.radius * 1.5 then
                -- Calculate perpendicular angle (left-right relative to plow movement)
                local perpAngle = self.movementDirection + math.pi / 2
                
                -- Target positions spread perpendicular to movement with slight randomness
                local lateralTarget = (math.random() - 0.5) * self.radius * 2.5
                local longitudinalTarget = (math.random() - 0.5) * self.radius * 0.5
                
                local targetX = self.worldX + math.sin(perpAngle) * lateralTarget + math.sin(self.movementDirection) * longitudinalTarget
                local targetZ = self.worldZ + math.cos(perpAngle) * lateralTarget + math.cos(self.movementDirection) * longitudinalTarget
                
                -- Variable height: birds fly between 0.1m and 5.1m above ground (can swoop down close to ground)
                local heightVariation = 0.1 + math.random() * 5.0 -- 0.1m to 5.1m
                local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) + heightVariation

                -- Cancel current movement and give new target
                bird.mover:cancelTarget()

                -- Use flying movement with 8x speed
                local flySpeed = 48.0 -- m/s (8x original speed)

                -- Use flyToTarget to maintain altitude above ground
                bird.mover:flyToTarget(targetX, targetY, targetZ, flySpeed, false)
            end
        end
    end
end

---
-- Give a single bird a new target immediately
-- @param bird: The SimpleBird to give a new target to
---
function PlowBirdHotspot:giveNewTargetToBird(bird)
    if not self.isActive or not bird or not bird.rootNode or not entityExists(bird.rootNode) then
        return
    end
    
    -- Calculate perpendicular angle (left-right relative to plow movement)
    local perpAngle = self.movementDirection + math.pi / 2
    
    -- Target positions spread across plow working width with slight randomness
    local lateralTarget = (math.random() - 0.5) * self.workingWidth * 2
    local longitudinalTarget = (math.random() - 0.5) * self.radius * 0.5
    
    local targetX = self.worldX + math.sin(perpAngle) * lateralTarget + math.sin(self.movementDirection) * longitudinalTarget
    local targetZ = self.worldZ + math.cos(perpAngle) * lateralTarget + math.cos(self.movementDirection) * longitudinalTarget
    
    -- Variable height: birds fly between 0.1m and 5.1m above ground (can swoop down close to ground)
    local heightVariation = 0.1 + math.random() * 5.0 -- 0.1m to 5.1m
    local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) + heightVariation
    
    if math.random() < 0.15 then  -- 15% logging chance
        local bx, by, bz = bird:getCurrentPosition()
        print(string.format("[PlowBirdHotspot] New target assigned: from (%.1f,%.1f,%.1f) to (%.1f,%.1f,%.1f) height=%.1fm", 
            bx, by, bz, targetX, targetY, targetZ, heightVariation))
    end
    
    -- Use flying movement with 8x speed
    local flySpeed = 48.0 -- m/s (8x original speed)
    
    -- Use flyToTarget to maintain altitude above ground
    bird.mover:flyToTarget(targetX, targetY, targetZ, flySpeed, false)
end

---
-- Clean up all birds spawned by this hotspot
---
function PlowBirdHotspot:cleanup()
    print(string.format("[PlowBirdHotspot] === CLEANUP: Sending %d birds flying away for despawn ===", #self.spawnedBirds))

    -- Send each bird flying away upward/random direction for 5 seconds before deletion
    local despawnCount = 0
    for i, bird in ipairs(self.spawnedBirds) do
        if bird and bird.rootNode and entityExists(bird.rootNode) then
            bird.isDespawning = true
            bird.despawnStartTime = g_time
            
            -- Calculate a random upward flying direction
            local bx, by, bz = getWorldTranslation(bird.rootNode)
            local randomAngle = math.random() * 2 * math.pi
            local horizontalDistance = 30 + math.random() * 20 -- 30-50m away
            local verticalDistance = 20 + math.random() * 15 -- 20-35m up
            
            local targetX = bx + math.sin(randomAngle) * horizontalDistance
            local targetZ = bz + math.cos(randomAngle) * horizontalDistance
            local targetY = by + verticalDistance
            
            print(string.format("[PlowBirdHotspot] Bird %d despawn: from (%.1f, %.1f, %.1f) flying to (%.1f, %.1f, %.1f)",
                i, bx, by, bz, targetX, targetY, targetZ))
            
            -- Send bird flying away fast with takeoff enabled
            bird.mover:cancelTarget()
            bird.mover:flyToTarget(targetX, targetY, targetZ, 48.0, true)
            
            -- Force immediate mover update to initiate movement
            bird.mover:update(50)
            print(string.format("[PlowBirdHotspot] -> Bird %d despawn initiated, isMoving=%s", 
                i, tostring(bird.mover:getIsMoving())))
            
            -- Move to despawning list
            table.insert(self.despawningBirds, bird)
            despawnCount = despawnCount + 1
        end
    end

    self.spawnedBirds = {}
    self.birdsSpawned = false
    print(string.format("[PlowBirdHotspot] === %d birds now despawning (will auto-delete in 5s) ===", despawnCount))
    
    -- Don't call deactivate() here - let update() handle cleanup when despawning is done
    -- The update loop will continue to update despawning birds
    self.isActive = false  -- Stop spawning new ones, but keep updating despawning birds
end

---
-- Get the number of active birds in this hotspot
-- @return number of birds
---
function PlowBirdHotspot:getNumBirds()
    return #self.spawnedBirds
end

---
-- Check if hotspot is active
-- @return boolean
---
function PlowBirdHotspot:getIsActive()
    return self.isActive
end
