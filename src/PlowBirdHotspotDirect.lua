---
-- PlowBirdHotspotDirect
-- Uses SimpleBirdDirect (direct i3d management) instead of wildlife system
---

PlowBirdHotspotDirect = {}
local PlowBirdHotspotDirect_mt = Class(PlowBirdHotspotDirect)

-- Configuration
PlowBirdHotspotDirect.HOTSPOT_RADIUS = 5              -- Radius around the plow where birds gather (meters)
PlowBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND = 2       -- How far behind the plow to position the hotspot (meters)
PlowBirdHotspotDirect.MAX_BIRDS = 20                  -- Maximum number of birds around the plow
PlowBirdHotspotDirect.UPDATE_INTERVAL = 50            -- Update hotspot position every 50ms (20 times per second)
PlowBirdHotspotDirect.SPAWN_DISTANCE_BEHIND = 50      -- Birds spawn 50m behind tractor
PlowBirdHotspotDirect.SPAWN_HEIGHT_ABOVE_TERRAIN = 40 -- Birds spawn 40m above terrain

---
-- Get the working width of the plow from its work areas
-- @param vehicle: The plow vehicle
-- @return width in meters, or 5.0 as default
---
function PlowBirdHotspotDirect.getPlowWorkingWidth(vehicle)
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
            return width
        end
    end

    return 5.0 -- Fallback if no plow work area found
end

---
-- Create a new PlowBirdHotspotDirect instance
-- @param plowVehicle: The plow vehicle this hotspot follows
-- @return PlowBirdHotspotDirect instance
---
function PlowBirdHotspotDirect.new(plowVehicle)
    local self = setmetatable({}, PlowBirdHotspotDirect_mt)

    self.plowVehicle = plowVehicle
    self.worldX = 0
    self.worldY = -200 -- Start below ground (inactive)
    self.worldZ = 0
    self.radius = PlowBirdHotspotDirect.HOTSPOT_RADIUS
    self.spawnedBirds = {}    -- Track our spawned birds
    self.despawningBirds = {} -- Track birds that are flying away
    self.isActive = false
    self.lastUpdateTime = 0
    self.lastBirdUpdateTime = 0                                                -- For updating bird movement targets
    self.movementDirection = 0                                                 -- Direction the plow is moving
    self.birdsSpawned = false                                                  -- Track if initial birds have been spawned
    self.workingWidth = PlowBirdHotspotDirect.getPlowWorkingWidth(plowVehicle) -- Cache the working width

    return self
end

---
-- Activate the hotspot at the plow's current position
-- @return true if activated successfully
---
function PlowBirdHotspotDirect:activate()
    if not self.plowVehicle or self.isActive then
        return false
    end

    -- Get plow position
    local plowX, plowY, plowZ = getWorldTranslation(self.plowVehicle.rootNode)

    -- Initialize movement direction (assume plow is moving forward)
    local dx, _, dz = localDirectionToWorld(self.plowVehicle.rootNode, 0, 0, 1)
    self.movementDirection = math.atan2(dx, dz)

    -- Position hotspot behind the plow from the start
    local behindAngle = self.movementDirection + math.pi
    self.worldX = plowX + math.sin(behindAngle) * PlowBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
    self.worldY = plowY
    self.worldZ = plowZ + math.cos(behindAngle) * PlowBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
    self.isActive = true
    self.lastUpdateTime = g_time
    self.birdsSpawned = false

    return true
end

---
-- Deactivate the hotspot
---
function PlowBirdHotspotDirect:deactivate()
    self.isActive = false
    self.worldY = -200 -- Move below ground
end

---
-- Update hotspot position to follow the plow
-- @param dt: Delta time in milliseconds
---
function PlowBirdHotspotDirect:update(dt)
    -- ALWAYS update and cleanup despawning birds (even if inactive)
    for i = #self.despawningBirds, 1, -1 do
        local bird = self.despawningBirds[i]
        if bird then
            bird:update(dt) -- Keep updating the bird's movement
            local elapsed = g_time - bird.despawnStartTime
            if elapsed > 5000 then
                if bird.delete then
                    bird:delete()
                end
                table.remove(self.despawningBirds, i)
            end
        end
    end

    -- Auto-deactivate when no active birds and no despawning birds
    if not self.isActive and #self.despawningBirds == 0 then
        return -- Fully inactive, nothing to update
    end

    if not self.isActive or not self.plowVehicle then
        return -- Only update despawning birds above
    end

    -- Update each bird EVERY FRAME for smooth movement
    -- The state machine within each bird handles all behavior
    for _, bird in ipairs(self.spawnedBirds) do
        if bird and bird.update then
            bird:update(dt)
        end
    end

    -- Update hotspot position periodically (not every frame for performance)
    if g_time - self.lastUpdateTime < PlowBirdHotspotDirect.UPDATE_INTERVAL then
        return
    end

    self.lastUpdateTime = g_time

    -- Get current plow position and direction
    local plowX, plowY, plowZ = getWorldTranslation(self.plowVehicle.rootNode)

    -- Get the plow's current facing direction
    local dx, _, dz = localDirectionToWorld(self.plowVehicle.rootNode, 0, 0, 1)
    self.movementDirection = math.atan2(dx, dz)

    -- Position hotspot behind the plow in the worked area
    local behindAngle = self.movementDirection + math.pi -- Opposite direction
    self.worldX = plowX + math.sin(behindAngle) * PlowBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
    self.worldY = plowY
    self.worldZ = plowZ + math.cos(behindAngle) * PlowBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
end

---
-- Spawn initial set of birds at this hotspot
---
function PlowBirdHotspotDirect:spawnInitialBirds()
    if self.birdsSpawned or not self.isActive then
        return false
    end

    -- Spawn birds spread perpendicular to movement direction, 50m behind, 40m up
    local totalSpawned = 0
    for i = 1, PlowBirdHotspotDirect.MAX_BIRDS do
        -- Calculate perpendicular angle (90 degrees to movement direction)
        local perpAngle = self.movementDirection + math.pi / 2

        -- Spread birds along perpendicular axis based on plow working width
        local lateralOffset = (i / PlowBirdHotspotDirect.MAX_BIRDS - 0.5) * self.workingWidth * 1.5

        -- Calculate spawn position: hotspot + lateral offset perpendicular + 50m backward
        local longitudinalOffset = PlowBirdHotspotDirect.SPAWN_DISTANCE_BEHIND + (math.random() - 0.5) * 5 -- 50m ±2.5m

        local spawnX = self.worldX + math.sin(perpAngle) * lateralOffset -
            math.sin(self.movementDirection) * longitudinalOffset
        local spawnZ = self.worldZ + math.cos(perpAngle) * lateralOffset -
            math.cos(self.movementDirection) * longitudinalOffset

        -- Spawn at terrain height + 40m
        local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, spawnX, 0, spawnZ)
        local spawnY = terrainY + PlowBirdHotspotDirect.SPAWN_HEIGHT_ABOVE_TERRAIN +
            (math.random() - 0.5) *
            5                     -- ±2.5m variation

        -- Create a SimpleBirdDirect (has built-in state machine)
        local bird = SimpleBirdDirect.new(spawnX, spawnY, spawnZ, self)

        if bird then
            -- Track it
            table.insert(self.spawnedBirds, bird)
            totalSpawned = totalSpawned + 1
        end
    end

    self.birdsSpawned = true
    self.lastBirdUpdateTime = g_time
    return totalSpawned > 0
end

---
-- Clean up all birds spawned by this hotspot
---
function PlowBirdHotspotDirect:cleanup()
    -- Request each bird to enter despawn state via state machine
    local despawnCount = 0
    for i, bird in ipairs(self.spawnedBirds) do
        if bird and bird.rootNode and entityExists(bird.rootNode) then
            -- Request bird to enter despawning state
            -- State machine will handle flying away automatically
            if bird.requestDespawn then
                bird:requestDespawn()
            end

            -- Move to despawning list
            table.insert(self.despawningBirds, bird)
            despawnCount = despawnCount + 1
        end
    end

    self.spawnedBirds = {}
    self.birdsSpawned = false

    -- Stop spawning new ones, but keep updating despawning birds
    self.isActive = false
end

---
-- Get the number of active birds in this hotspot
-- @return number of birds
---
function PlowBirdHotspotDirect:getNumBirds()
    return #self.spawnedBirds
end

---
-- Check if hotspot is active
-- @return boolean
---
function PlowBirdHotspotDirect:getIsActive()
    return self.isActive
end
