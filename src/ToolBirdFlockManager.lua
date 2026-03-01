---
-- ToolBirdFlockManager
-- Generic bird flock manager for various tool types (plow, cultivator, etc.)
-- Manages spawning, updating, and despawning of bird flocks following working tools
---

ToolBirdFlockManager = {}
local ToolBirdFlockManager_mt = Class(ToolBirdFlockManager)

-- Configuration
ToolBirdFlockManager.MAX_BIRDS = 80                  -- Maximum number of birds around the tool
ToolBirdFlockManager.SPAWN_INTERVAL = 500            -- Spawn one bird every 500ms (instead of all at once)
ToolBirdFlockManager.SPAWN_DISTANCE_BEHIND = 50      -- Birds spawn 50m behind tractor
ToolBirdFlockManager.SPAWN_HEIGHT_ABOVE_TERRAIN = 40 -- Birds spawn 40m above terrain
ToolBirdFlockManager.DESPAWN_DELAY = 15000           -- Wait time before birds start flying away (milliseconds)
ToolBirdFlockManager.DESPAWN_DURATION = 10000        -- How long birds fly away before being deleted (milliseconds)

---
-- Get the working width of the tool from its work areas
-- @param vehicle: The vehicle with tool
-- @param workAreaType: The work area type to search for
-- @return width in meters, or 5.0 as default
---
function ToolBirdFlockManager.getToolWorkingWidth(vehicle, workAreaType)
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
-- Create a new ToolBirdFlockManager instance
-- @param vehicle: The vehicle this flock manager follows
-- @param workAreaType: The work area type enum
-- @return ToolBirdFlockManager instance
---
function ToolBirdFlockManager.new(vehicle, workAreaType)
    local self = setmetatable({}, ToolBirdFlockManager_mt)

    self.vehicle = vehicle
    self.workAreaType = workAreaType
    self.spawnedBirds = {}    -- Track our spawned birds
    self.despawningBirds = {} -- Track birds that are flying away
    self.isActive = false
    self.birdsSpawned = false                                             -- Track if initial birds have been spawned
    self.numBirdsSpawned = 0                                              -- Track how many birds spawned so far
    self.lastSpawnTime = 0                                                -- Track when last bird was spawned
    self.isDespawning = false                                             -- Track if gradual despawn is in progress
    self.numBirdsDespawned = 0                                            -- Track how many birds marked for despawn
    self.lastDespawnTime = 0                                              -- Track when last bird was despawned
    self.despawnTimer = 0                                                 -- Timer before starting gradual despawn (milliseconds)
    self.despawnTimerActive = false                                       -- Whether the despawn timer is counting down
    self.workingWidth = ToolBirdFlockManager.getToolWorkingWidth(vehicle, workAreaType) -- Cache the working width
    
    -- Sound management (3D positional audio)
    self.soundNode = nil                                                  -- The audio source node (3D sound)
    self.soundSample = nil                                                -- The sample ID from the audio source
    self.soundTransform = nil                                             -- Transform node to position the sound
    self.soundVolume = 1.0                                                -- Volume level (loaded from XML)
    self.soundStartTime = nil                                             -- When spawning started (for 8s delay)
    self.soundStarted = false                                             -- Track if sound has started

    -- Register with BirdManager for independent updates
    if BirdManager then
        BirdManager:registerFlockManager(vehicle, self)
    end

    return self
end

---
-- Activate the bird flock
-- @return true if activated successfully
---
function ToolBirdFlockManager:activate()
    if not self.vehicle then
        return false
    end
    
    -- If despawning is in progress, cancel it (regardless of isActive state)
    if self.isDespawning then
        self:cancelDespawnTimer()
        
        -- Keep existing birds and resume spawning to reach max
        self.numBirdsSpawned = #self.spawnedBirds
        self.birdsSpawned = self.numBirdsSpawned >= ToolBirdFlockManager.MAX_BIRDS
        self.lastSpawnTime = g_time
        
        -- Reactivate if we were inactive
        if not self.isActive then
            self.isActive = true
            
            -- Re-register with BirdManager for updates
            if BirdManager and self.vehicle then
                BirdManager:registerFlockManager(self.vehicle, self)
            end
            
            -- Restart sound if needed
            if not self.soundStarted then
                self.soundStartTime = g_time
                self:initializeSound()
            end
        end
        
        return true
    end
    
    if self.isActive then
        return false
    end

    self.isActive = true
    self.birdsSpawned = false
    self.numBirdsSpawned = 0
    self.lastSpawnTime = g_time
    
    -- Re-register with BirdManager for updates
    if BirdManager and self.vehicle then
        BirdManager:registerFlockManager(self.vehicle, self)
    end
    
    -- Initialize sound
    self.soundStartTime = g_time
    self.soundStarted = false
    self:initializeSound()

    return true
end

---
-- Deactivate the bird flock
---
function ToolBirdFlockManager:deactivate()
    self.isActive = false
    self:stopSound()
end

---
-- Start the despawn timer (called when tool stops working)
---
function ToolBirdFlockManager:startDespawnTimer()
    if not self.despawnTimerActive then
        self.despawnTimer = ToolBirdFlockManager.DESPAWN_DELAY
        self.despawnTimerActive = true
    end
end

---
-- Cancel the despawn timer (called when tool starts working again)
---
function ToolBirdFlockManager:cancelDespawnTimer()
    self.despawnTimer = 0
    self.despawnTimerActive = false
    
    -- Also stop any ongoing gradual despawn process
    if self.isDespawning then
        self.isDespawning = false
        self.numBirdsDespawned = 0
        -- Birds that haven't been marked for despawn yet will continue normal feeding
        -- Birds already marked for despawn (in despawningBirds array) will continue flying away
    end
end

---
-- Update bird flock
-- @param dt: Delta time in milliseconds
---
function ToolBirdFlockManager:update(dt)
    -- ALWAYS update and cleanup despawning birds (even if inactive)
    for i = #self.despawningBirds, 1, -1 do
        local bird = self.despawningBirds[i]
        if bird then
            bird:update(dt) -- Keep updating the bird's movement
            local elapsed = g_time - bird.despawnStartTime
            if elapsed > ToolBirdFlockManager.DESPAWN_DURATION then
                if bird.delete then
                    bird:delete()
                end
                table.remove(self.despawningBirds, i)
            end
        end
    end

    -- Handle despawn timer countdown (runs via BirdManager even when vehicle is inactive)
    if self.despawnTimerActive and self.despawnTimer > 0 then
        self.despawnTimer = self.despawnTimer - dt

        if self.despawnTimer <= 0 then
            -- Timer expired - start cleanup
            self.despawnTimerActive = false
            self:cleanup()
        end
    end

    -- Gradually despawn birds over time (one every SPAWN_INTERVAL)
    if self.isDespawning and #self.spawnedBirds > 0 then
        if g_time - self.lastDespawnTime >= ToolBirdFlockManager.SPAWN_INTERVAL then
            self:despawnOneBird()
            self.lastDespawnTime = g_time
        end
    end

    -- Auto-deactivate when no active birds and no despawning birds
    if not self.isActive and #self.despawningBirds == 0 and not self.isDespawning then
        -- Unregister from BirdManager when fully inactive
        if BirdManager and self.vehicle then
            BirdManager:unregisterFlockManager(self.vehicle)
        end
        return -- Fully inactive, nothing to update
    end

    -- Update each bird EVERY FRAME for smooth movement (even during despawn)
    -- The state machine within each bird handles all behavior
    for _, bird in ipairs(self.spawnedBirds) do
        if bird and bird.update then
            bird:update(dt)
        end
    end

    -- Check if we have a valid vehicle
    if not self.vehicle then
        return
    end

    -- Gradually spawn birds over time (one every SPAWN_INTERVAL) - only when active
    if self.isActive and not self.birdsSpawned and self.numBirdsSpawned < ToolBirdFlockManager.MAX_BIRDS then
        if g_time - self.lastSpawnTime >= ToolBirdFlockManager.SPAWN_INTERVAL then
            self:spawnOneBird()
            self.lastSpawnTime = g_time
        end
    end
    
    -- Start looping sound 8 seconds after spawning begins
    if self.isActive and not self.soundStarted and self.soundStartTime and (g_time - self.soundStartTime) >= 8000 then
        self:startSound()
        self.soundStarted = true
    end
    
    -- Update sound position to follow the vehicle
    if self.soundStarted and self.soundTransform and self.soundTransform ~= 0 then
        self:updateSoundPosition()
    end
end

---
-- Spawn a single bird (called periodically to gradually spawn all birds)
---
function ToolBirdFlockManager:spawnOneBird()
    if not self.isActive or self.numBirdsSpawned >= ToolBirdFlockManager.MAX_BIRDS then
        if self.numBirdsSpawned >= ToolBirdFlockManager.MAX_BIRDS then
            self.birdsSpawned = true -- Mark spawning complete
        end
        return false
    end

    if not self.vehicle or not self.vehicle.rootNode then
        return false
    end

    -- Get current vehicle position
    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)
    
    -- Get the tool's current facing direction
    local dx, _, dz = localDirectionToWorld(self.vehicle.rootNode, 0, 0, 1)
    local movementDirection = math.atan2(dx, dz)

    local i = self.numBirdsSpawned + 1

    -- Calculate perpendicular angle (90 degrees to movement direction)
    local perpAngle = movementDirection + math.pi / 2

    -- Spread birds in a wide radius for initial spawn
    local lateralOffset = (i / ToolBirdFlockManager.MAX_BIRDS - 0.5) * 65.0

    -- Calculate spawn position: vehicle + lateral offset perpendicular + 50m backward
    local longitudinalOffset = ToolBirdFlockManager.SPAWN_DISTANCE_BEHIND + (math.random() - 0.5) * 5 -- 50m ±2.5m

    local spawnX = vehicleX + math.sin(perpAngle) * lateralOffset -
        math.sin(movementDirection) * longitudinalOffset
    local spawnZ = vehicleZ + math.cos(perpAngle) * lateralOffset -
        math.cos(movementDirection) * longitudinalOffset

    -- Spawn at terrain height + 40m
    local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, spawnX, 0, spawnZ)
    local spawnY = terrainY + ToolBirdFlockManager.SPAWN_HEIGHT_ABOVE_TERRAIN +
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
function ToolBirdFlockManager:cleanup()
    if #self.spawnedBirds == 0 then
        -- No birds to despawn, fully deactivate and unregister
        self.isActive = false
        self:stopSound()
        
        -- Unregister from BirdManager when fully inactive
        if BirdManager and self.vehicle then
            BirdManager:unregisterFlockManager(self.vehicle)
        end
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
    
    -- Note: Sound continues playing until last bird starts flying away
end

---
-- Despawn a single bird (called periodically to gradually despawn all birds)
---
function ToolBirdFlockManager:despawnOneBird()
    -- Check if we have any birds left to despawn
    if #self.spawnedBirds == 0 then
        self.isDespawning = false
        return false
    end
    
    -- Always take the first bird from the array
    local bird = self.spawnedBirds[1]
    
    if bird and bird.rootNode and entityExists(bird.rootNode) then
        -- Request bird to enter despawning state
        -- State machine will handle flying away automatically
        if bird.requestDespawn then
            bird:requestDespawn()
        end
        
        -- Move to despawning list for tracking
        table.insert(self.despawningBirds, bird)
    end
    
    -- Remove this bird from spawnedBirds immediately
    table.remove(self.spawnedBirds, 1)
    self.numBirdsDespawned = self.numBirdsDespawned + 1
    
    -- Check if all birds have been marked for despawn
    if #self.spawnedBirds == 0 then
        self.isDespawning = false
        self.birdsSpawned = false
        self.numBirdsSpawned = 0
        
        -- Stop sound now that last bird has started flying away
        self:stopSound()
    end
    
    return true
end

---
-- Initialize the shared looping sound sample (3D positional audio)
---
function ToolBirdFlockManager:initializeSound()
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
    
    -- Get initial vehicle position for sound
    local vehicleX, vehicleY, vehicleZ = 0, 0, 0
    if self.vehicle and self.vehicle.rootNode then
        vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)
    end
    
    -- Create a transform node to position the sound in the world
    self.soundTransform = createTransformGroup("birdFlockSoundEmitter")
    setTranslation(self.soundTransform, vehicleX, vehicleY, vehicleZ)
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
            
            -- Link audio source to our transform node so it moves with the flock
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
-- Update the 3D sound position to follow the vehicle
---
function ToolBirdFlockManager:updateSoundPosition()
    if not self.soundTransform or self.soundTransform == 0 then
        return
    end
    
    if not self.vehicle or not self.vehicle.rootNode then
        return
    end
    
    -- Get current vehicle position
    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)
    
    -- Update sound transform position
    setTranslation(self.soundTransform, vehicleX, vehicleY, vehicleZ)
end

---
-- Start playing the looping sound (3D positional)
---
function ToolBirdFlockManager:startSound()
    if self.soundNode and self.soundNode ~= 0 then
        -- Play the audio source (volume is set via createAudioSource, this just triggers playback)
        -- Note: For 3D audio sources, the volume parameter here is ignored in favor of the AudioSource's volume
        playSample(self.soundSample, 0, self.soundVolume, 0, 0, 0)
    end
end

---
-- Stop the looping sound and cleanup
---
function ToolBirdFlockManager:stopSound()
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
-- Get the number of active birds in this flock
-- @return number of birds
---
function ToolBirdFlockManager:getNumBirds()
    return #self.spawnedBirds
end

---
-- Check if flock manager is active
-- @return boolean
---
function ToolBirdFlockManager:getIsActive()
    return self.isActive
end

