---
-- ToolBirdHotspotDirect
-- Generic bird hotspot for various tool types (plow, cultivator, etc.)
---

ToolBirdHotspotDirect = {}
local ToolBirdHotspotDirect_mt = Class(ToolBirdHotspotDirect)

-- Configuration
ToolBirdHotspotDirect.HOTSPOT_RADIUS = 5              -- Radius around the tool where birds gather (meters)
ToolBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND = 1       -- How far behind the tool to position the hotspot (meters)
ToolBirdHotspotDirect.MAX_BIRDS = 60                  -- Maximum number of birds around the tool
ToolBirdHotspotDirect.UPDATE_INTERVAL = 50            -- Update hotspot position every 50ms (20 times per second)
ToolBirdHotspotDirect.SPAWN_INTERVAL = 500            -- Spawn one bird every 500ms (instead of all at once)
ToolBirdHotspotDirect.SPAWN_DISTANCE_BEHIND = 50      -- Birds spawn 50m behind tractor
ToolBirdHotspotDirect.SPAWN_HEIGHT_ABOVE_TERRAIN = 40 -- Birds spawn 40m above terrain
ToolBirdHotspotDirect.DESPAWN_DELAY = 15000           -- Wait time before birds start flying away (milliseconds)
ToolBirdHotspotDirect.DESPAWN_DURATION = 10000        -- How long birds fly away before being deleted (milliseconds)

---
-- Get the working width of the tool from its work areas
-- @param vehicle: The vehicle with tool
-- @param workAreaType: The work area type to search for
-- @return width in meters, or 5.0 as default
---
function ToolBirdHotspotDirect.getToolWorkingWidth(vehicle, workAreaType)
    if not vehicle or not vehicle.spec_workArea then
        return 5.0 -- Default fallback
    end

    local workAreas = vehicle.spec_workArea.workAreas
    if not workAreas or #workAreas == 0 then
        return 5.0
    end

    -- Get the first work area of the specified type
    for _, workArea in ipairs(workAreas) do
        if workArea.type == workAreaType and workArea.start and workArea.width then
            local x1, _, z1 = getWorldTranslation(workArea.start)
            local x2, _, z2 = getWorldTranslation(workArea.width)
            local width = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
            return width
        end
    end

    return 5.0 -- Fallback if no work area found
end

---
-- Create a new ToolBirdHotspotDirect instance
-- @param vehicle: The vehicle this hotspot follows
-- @param workAreaType: The work area type enum
-- @return ToolBirdHotspotDirect instance
---
function ToolBirdHotspotDirect.new(vehicle, workAreaType)
    local self = setmetatable({}, ToolBirdHotspotDirect_mt)

    self.vehicle = vehicle
    self.workAreaType = workAreaType
    self.worldX = 0
    self.worldY = -200 -- Start below ground (inactive)
    self.worldZ = 0
    self.radius = ToolBirdHotspotDirect.HOTSPOT_RADIUS
    self.spawnedBirds = {}    -- Track our spawned birds
    self.despawningBirds = {} -- Track birds that are flying away
    self.isActive = false
    self.lastUpdateTime = 0
    self.lastBirdUpdateTime = 0                                           -- For updating bird movement targets
    self.movementDirection = 0                                            -- Direction the tool is moving
    self.birdsSpawned = false                                             -- Track if initial birds have been spawned
    self.numBirdsSpawned = 0                                              -- Track how many birds spawned so far
    self.lastSpawnTime = 0                                                -- Track when last bird was spawned
    self.isDespawning = false                                             -- Track if gradual despawn is in progress
    self.numBirdsDespawned = 0                                            -- Track how many birds marked for despawn
    self.lastDespawnTime = 0                                              -- Track when last bird was despawned
    self.workingWidth = ToolBirdHotspotDirect.getToolWorkingWidth(vehicle, workAreaType) -- Cache the working width
    
    -- Sound management (3D positional audio)
    self.soundNode = nil                                                  -- The audio source node (3D sound)
    self.soundSample = nil                                                -- The sample ID from the audio source
    self.soundTransform = nil                                             -- Transform node to position the sound
    self.soundVolume = 1.0                                                -- Volume level (loaded from XML)
    self.soundStartTime = nil                                             -- When spawning started (for 8s delay)
    self.soundStarted = false                                             -- Track if sound has started

    return self
end

---
-- Activate the hotspot at the tool's current position
-- @return true if activated successfully
---
function ToolBirdHotspotDirect:activate()
    if not self.vehicle or self.isActive then
        return false
    end

    -- Get vehicle position
    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)

    -- Initialize movement direction (assume tool is moving forward)
    local dx, _, dz = localDirectionToWorld(self.vehicle.rootNode, 0, 0, 1)
    self.movementDirection = math.atan2(dx, dz)

    -- Position hotspot behind the tool from the start
    local behindAngle = self.movementDirection + math.pi
    self.worldX = vehicleX + math.sin(behindAngle) * ToolBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
    self.worldY = vehicleY
    self.worldZ = vehicleZ + math.cos(behindAngle) * ToolBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
    self.isActive = true
    self.lastUpdateTime = g_time
    self.birdsSpawned = false
    self.numBirdsSpawned = 0
    self.lastSpawnTime = g_time
    
    -- Initialize sound
    self.soundStartTime = g_time
    self.soundStarted = false
    self:initializeSound()

    return true
end

---
-- Deactivate the hotspot
---
function ToolBirdHotspotDirect:deactivate()
    self.isActive = false
    self.worldY = -200 -- Move below ground
    self:stopSound()
end

---
-- Update hotspot position to follow the tool
-- @param dt: Delta time in milliseconds
---
function ToolBirdHotspotDirect:update(dt)
    -- ALWAYS update and cleanup despawning birds (even if inactive)
    for i = #self.despawningBirds, 1, -1 do
        local bird = self.despawningBirds[i]
        if bird then
            bird:update(dt) -- Keep updating the bird's movement
            local elapsed = g_time - bird.despawnStartTime
            if elapsed > ToolBirdHotspotDirect.DESPAWN_DURATION then
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

    if not self.isActive or not self.vehicle then
        return -- Only update despawning birds above
    end

    -- Update each bird EVERY FRAME for smooth movement
    -- The state machine within each bird handles all behavior
    for _, bird in ipairs(self.spawnedBirds) do
        if bird and bird.update then
            bird:update(dt)
        end
    end

    -- Gradually spawn birds over time (one every SPAWN_INTERVAL)
    if not self.birdsSpawned and self.numBirdsSpawned < ToolBirdHotspotDirect.MAX_BIRDS then
        if g_time - self.lastSpawnTime >= ToolBirdHotspotDirect.SPAWN_INTERVAL then
            self:spawnOneBird()
            self.lastSpawnTime = g_time
        end
    end
    
    -- Gradually despawn birds over time (one every SPAWN_INTERVAL)
    if self.isDespawning and self.numBirdsDespawned < #self.spawnedBirds then
        if g_time - self.lastDespawnTime >= ToolBirdHotspotDirect.SPAWN_INTERVAL then
            self:despawnOneBird()
            self.lastDespawnTime = g_time
        end
    end
    
    -- Start looping sound 8 seconds after spawning begins
    if not self.soundStarted and self.soundStartTime and (g_time - self.soundStartTime) >= 8000 then
        self:startSound()
        self.soundStarted = true
    end
    
    -- Update sound position to follow hotspot
    if self.soundStarted and self.soundTransform then
        setTranslation(self.soundTransform, self.worldX, self.worldY, self.worldZ)
    end

    -- Update hotspot position periodically (not every frame for performance)
    if g_time - self.lastUpdateTime < ToolBirdHotspotDirect.UPDATE_INTERVAL then
        return
    end

    self.lastUpdateTime = g_time

    -- Get current tool position and direction
    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)

    -- Get the tool's current facing direction
    local dx, _, dz = localDirectionToWorld(self.vehicle.rootNode, 0, 0, 1)
    self.movementDirection = math.atan2(dx, dz)

    -- Position hotspot behind the tool in the worked area
    local behindAngle = self.movementDirection + math.pi -- Opposite direction
    self.worldX = vehicleX + math.sin(behindAngle) * ToolBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
    self.worldY = vehicleY
    self.worldZ = vehicleZ + math.cos(behindAngle) * ToolBirdHotspotDirect.HOTSPOT_OFFSET_BEHIND
end

---
-- Spawn initial set of birds at this hotspot (called from extension to start spawning)
---
function ToolBirdHotspotDirect:spawnInitialBirds()
    -- This now just marks that we should start spawning
    -- Actual spawning happens gradually in update()
    if self.birdsSpawned or not self.isActive then
        return false
    end

    -- Spawn the first bird immediately
    self:spawnOneBird()
    self.lastBirdUpdateTime = g_time
    return true
end

---
-- Spawn a single bird (called periodically to gradually spawn all birds)
---
function ToolBirdHotspotDirect:spawnOneBird()
    if not self.isActive or self.numBirdsSpawned >= ToolBirdHotspotDirect.MAX_BIRDS then
        if self.numBirdsSpawned >= ToolBirdHotspotDirect.MAX_BIRDS then
            self.birdsSpawned = true -- Mark spawning complete
        end
        return false
    end

    local i = self.numBirdsSpawned + 1

    -- Calculate perpendicular angle (90 degrees to movement direction)
    local perpAngle = self.movementDirection + math.pi / 2

    -- Spread birds in a wide radius for initial spawn
    local lateralOffset = (i / ToolBirdHotspotDirect.MAX_BIRDS - 0.5) * 65.0

    -- Calculate spawn position: hotspot + lateral offset perpendicular + 50m backward
    local longitudinalOffset = ToolBirdHotspotDirect.SPAWN_DISTANCE_BEHIND + (math.random() - 0.5) * 5 -- 50m ±2.5m

    local spawnX = self.worldX + math.sin(perpAngle) * lateralOffset -
        math.sin(self.movementDirection) * longitudinalOffset
    local spawnZ = self.worldZ + math.cos(perpAngle) * lateralOffset -
        math.cos(self.movementDirection) * longitudinalOffset

    -- Spawn at terrain height + 40m
    local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, spawnX, 0, spawnZ)
    local spawnY = terrainY + ToolBirdHotspotDirect.SPAWN_HEIGHT_ABOVE_TERRAIN +
        (math.random() - 0.5) * 5 -- ±2.5m variation

    -- Create a SimpleBirdDirect (has built-in state machine)
    local bird = SimpleBirdDirect.new(spawnX, spawnY, spawnZ, self)

    if bird then
        -- Track it
        table.insert(self.spawnedBirds, bird)
        self.numBirdsSpawned = self.numBirdsSpawned + 1
        return true
    end

    return false
end

---
-- Start gradual despawn of birds (called when tool stops working)
---
function ToolBirdHotspotDirect:cleanup()
    if #self.spawnedBirds == 0 then
        -- No birds to despawn, fully deactivate
        self.isActive = false
        self:stopSound()
        return
    end
    
    -- Start the gradual despawn process
    self.isDespawning = true
    self.numBirdsDespawned = 0
    self.lastDespawnTime = g_time
    
    -- Despawn the first bird immediately
    self:despawnOneBird()
    
    -- Stop spawning new ones, but keep updating existing/despawning birds
    self.isActive = false
    
    -- Stop sound
    self:stopSound()
end

---
-- Despawn a single bird (called periodically to gradually despawn all birds)
---
function ToolBirdHotspotDirect:despawnOneBird()
    if self.numBirdsDespawned >= #self.spawnedBirds then
        self.isDespawning = false
        return false
    end
    
    local index = self.numBirdsDespawned + 1
    local bird = self.spawnedBirds[index]
    
    if bird and bird.rootNode and entityExists(bird.rootNode) then
        -- Request bird to enter despawning state
        -- State machine will handle flying away automatically
        if bird.requestDespawn then
            bird:requestDespawn()
        end
        
        -- Move to despawning list for tracking
        table.insert(self.despawningBirds, bird)
    end
    
    self.numBirdsDespawned = self.numBirdsDespawned + 1
    
    -- Check if all birds have been marked for despawn
    if self.numBirdsDespawned >= #self.spawnedBirds then
        self.isDespawning = false
        self.spawnedBirds = {}  -- Clear the list since all are now despawning
        self.birdsSpawned = false
        self.numBirdsSpawned = 0
    end
    
    return true
end

---
-- Initialize the shared looping sound sample (3D positional audio)
---
function ToolBirdHotspotDirect:initializeSound()
    -- Load bird config to get sound file path
    local config = BirdConfig.getConfig()
    if not config or not config.soundGroups then
        return
    end
    
    -- Get the first sound group (should only be one now)
    local soundFilePath = nil
    local soundVolume = 1.0  -- Default volume
    for groupName, soundGroup in pairs(config.soundGroups) do
        if soundGroup.fileNames and #soundGroup.fileNames > 0 then
            soundFilePath = soundGroup.fileNames[1]
            soundVolume = soundGroup.volume or 1.0
            break
        end
    end
    
    if not soundFilePath then
        return
    end
    
    -- Store volume for later use
    self.soundVolume = soundVolume
    
    -- Create a transform node to position the sound in the world
    self.soundTransform = createTransformGroup("birdFlockSoundEmitter")
    setTranslation(self.soundTransform, self.worldX, self.worldY, self.worldZ)
    link(getRootNode(), self.soundTransform)
    
    -- Create 3D audio source with spatial audio properties
    local sampleName = "birdFlock_" .. tostring(self):gsub("table: ", "")
    local outerRadius = 80.0  -- Sound audible up to 80m away
    local innerRadius = 20.0  -- Full volume within 20m
    local loops = 0  -- 0 = infinite loop
    
    self.soundNode = createAudioSource(sampleName, soundFilePath, outerRadius, innerRadius, soundVolume, loops)
    
    if self.soundNode and self.soundNode ~= 0 then
        -- Get the sample from the audio source
        self.soundSample = getAudioSourceSample(self.soundNode)
        
        if self.soundSample and self.soundSample ~= 0 then
            setSampleGroup(self.soundSample, AudioGroup.ENVIRONMENT)
            setAudioSourceAutoPlay(self.soundNode, false)
            
            -- Link audio source to our transform node so it moves with the hotspot
            link(self.soundTransform, self.soundNode)
        else
            -- Failed to get sample - cleanup
            delete(self.soundNode)
            delete(self.soundTransform)
            self.soundNode = nil
            self.soundTransform = nil
            self.soundSample = nil
        end
    else
        -- Failed to create audio source - cleanup
        delete(self.soundTransform)
        self.soundTransform = nil
    end
end

---
-- Start playing the looping sound (3D positional)
---
function ToolBirdHotspotDirect:startSound()
    if self.soundNode and self.soundNode ~= 0 then
        -- Play the audio source (volume is set via createAudioSource, this just triggers playback)
        -- Note: For 3D audio sources, the volume parameter here is ignored in favor of the AudioSource's volume
        playSample(self.soundSample, 0, self.soundVolume, 0, 0, 0)
    end
end

---
-- Stop the looping sound and cleanup
---
function ToolBirdHotspotDirect:stopSound()
    if self.soundSample and self.soundSample ~= 0 then
        if isSamplePlaying(self.soundSample) then
            stopSample(self.soundSample, 0, 0)
        end
    end
    
    -- Delete audio source node
    if self.soundNode and self.soundNode ~= 0 then
        delete(self.soundNode)
        self.soundNode = nil
    end
    
    -- Delete transform node
    if self.soundTransform and self.soundTransform ~= 0 then
        delete(self.soundTransform)
        self.soundTransform = nil
    end
    
    self.soundSample = nil
    self.soundStarted = false
end

---
-- Get the number of active birds in this hotspot
-- @return number of birds
---
function ToolBirdHotspotDirect:getNumBirds()
    return #self.spawnedBirds
end

---
-- Check if hotspot is active
-- @return boolean
---
function ToolBirdHotspotDirect:getIsActive()
    return self.isActive
end
