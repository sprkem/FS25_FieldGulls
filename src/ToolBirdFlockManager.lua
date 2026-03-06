---
-- ToolBirdFlockManager
-- Generic bird flock manager for various tool types (plow, cultivator, etc.)
-- Manages spawning, updating, and despawning of bird flocks following working tools
---

ToolBirdFlockManager = {}
local ToolBirdFlockManager_mt = Class(ToolBirdFlockManager)

ToolBirdFlockManager.MAX_BIRDS = 80                  -- Maximum number of birds around the tool
ToolBirdFlockManager.SPAWN_INTERVAL = 500            -- Spawn one bird every 500ms (instead of all at once)
ToolBirdFlockManager.DESPAWN_INTERVAL = 250          -- Despawn one bird every 250ms
ToolBirdFlockManager.SPAWN_DISTANCE_BEHIND = 50      -- Birds spawn 50m behind tractor
ToolBirdFlockManager.SPAWN_HEIGHT_ABOVE_TERRAIN = 20 -- Birds spawn 20m above terrain
ToolBirdFlockManager.DESPAWN_DELAY = 15000           -- Wait time before birds start flying away (milliseconds)
ToolBirdFlockManager.DESPAWN_DURATION = 10000        -- How long birds fly away before being deleted (milliseconds)

---
-- Get the working width of the tool from its work areas
-- Calculates the total bounding box across ALL work areas of the specified type
-- (Wide cultivators/plows have multiple work areas that need to be combined)
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

    -- Collect ALL work areas of the specified type
    local minX, minZ = math.huge, math.huge
    local maxX, maxZ = -math.huge, -math.huge
    local foundAnyWorkArea = false
    local workAreaCount = 0

    for _, workArea in ipairs(workAreas) do
        if workArea.type == workAreaType and workArea.start and workArea.width and workArea.height then
            foundAnyWorkArea = true
            workAreaCount = workAreaCount + 1
            
            -- Get all three corner points of the work area
            local sx, _, sz = getWorldTranslation(workArea.start)
            local wx, _, wz = getWorldTranslation(workArea.width)
            local hx, _, hz = getWorldTranslation(workArea.height)
            
            -- Update bounding box
            minX = math.min(minX, sx, wx, hx)
            maxX = math.max(maxX, sx, wx, hx)
            minZ = math.min(minZ, sz, wz, hz)
            maxZ = math.max(maxZ, sz, wz, hz)
        end
    end

    if not foundAnyWorkArea then
        return 5.0 -- Fallback if no work area found
    end

    -- Calculate total width from bounding box
    local widthX = maxX - minX
    local widthZ = maxZ - minZ
    
    -- Return the maximum dimension (typically the width perpendicular to movement)
    local totalWidth = math.max(widthX, widthZ)
    
    return totalWidth
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
    self.spawnedBirds = {}                                                              -- Track our spawned birds
    self.despawningBirds = {}                                                           -- Track birds that are flying away
    self.isActive = false
    self.birdsSpawned = false                                                           -- Track if initial birds have been spawned
    self.numBirdsSpawned = 0                                                            -- Track how many birds spawned so far
    self.lastSpawnTime = 0                                                              -- Track when last bird was spawned
    self.isDespawning = false                                                           -- Track if gradual despawn is in progress
    self.numBirdsDespawned = 0                                                          -- Track how many birds marked for despawn
    self.lastDespawnTime = 0                                                            -- Track when last bird was despawned
    self.despawnTimer = 0                                                               -- Timer before starting gradual despawn (milliseconds)
    self.despawnTimerActive = false                                                     -- Whether the despawn timer is counting down
    self.targetNumberOfBirds = nil                                                      -- Random target (50%-100% of max), set on activation
    self.workingWidth = ToolBirdFlockManager.getToolWorkingWidth(vehicle, workAreaType) -- Cache the working width

    -- Sound management (using g_soundManager for automatic indoor/outdoor handling)
    self.soundSample = nil          -- The sample loaded by g_soundManager
    self.soundTransform = nil       -- Transform node to position the sound  
    self.soundStartTime = nil       -- When spawning started (for 8s delay)
    self.soundStarted = false       -- Track if sound has started

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

    if self.isDespawning then
        self:cancelDespawnTimer()

        -- Set new random target if we don't have one (e.g., after full despawn)
        if not self.targetNumberOfBirds then
            local maxBirds = BirdSettings and BirdSettings.settings and BirdSettings.settings.maxBirds or 80
            local minBirds = math.floor(maxBirds * 0.5)
            self.targetNumberOfBirds = minBirds + math.random(0, maxBirds - minBirds)
        end

        -- Keep existing birds and resume spawning to reach target
        self.numBirdsSpawned = #self.spawnedBirds
        self.birdsSpawned = self.numBirdsSpawned >= self.targetNumberOfBirds
        self.lastSpawnTime = g_time

        if not self.isActive then
            self.isActive = true

            if BirdManager and self.vehicle then
                BirdManager:registerFlockManager(self.vehicle, self)
            end

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

    -- Set random target number of birds (50%-100% of max setting)
    if not self.targetNumberOfBirds then
        local maxBirds = BirdSettings and BirdSettings.settings and BirdSettings.settings.maxBirds or 80
        local minBirds = math.floor(maxBirds * 0.5)
        self.targetNumberOfBirds = minBirds + math.random(0, maxBirds - minBirds)
    end

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

    if self.isDespawning then
        self.isDespawning = false
        self.numBirdsDespawned = 0
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

    -- Gradually despawn birds over time (one every DESPAWN_INTERVAL)
    if self.isDespawning and #self.spawnedBirds > 0 then
        if g_time - self.lastDespawnTime >= ToolBirdFlockManager.DESPAWN_INTERVAL then
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
    if self.isActive and not self.birdsSpawned and self.targetNumberOfBirds and self.numBirdsSpawned < self.targetNumberOfBirds then
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
    if not self.isActive or not self.targetNumberOfBirds or self.numBirdsSpawned >= self.targetNumberOfBirds then
        if self.targetNumberOfBirds and self.numBirdsSpawned >= self.targetNumberOfBirds then
            self.birdsSpawned = true -- Mark spawning complete
        end
        return false
    end

    if not self.vehicle or not self.vehicle.rootNode then
        return false
    end

    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)
    local dx, _, dz = localDirectionToWorld(self.vehicle.rootNode, 0, 0, 1)
    local movementDirection = math.atan2(dx, dz)

    local i = self.numBirdsSpawned + 1

    -- Calculate perpendicular angle (90 degrees to movement direction)
    local perpAngle = movementDirection + math.pi / 2

    -- Spread birds randomly across a fixed 50-meter width for natural flock appearance
    local lateralOffset = (math.random() - 0.5) * 50.0
    local longitudinalOffset = ToolBirdFlockManager.SPAWN_DISTANCE_BEHIND + (math.random() - 0.5) * 5 -- 50m ±2.5m

    local spawnX = vehicleX + math.sin(perpAngle) * lateralOffset -
        math.sin(movementDirection) * longitudinalOffset
    local spawnZ = vehicleZ + math.cos(perpAngle) * lateralOffset -
        math.cos(movementDirection) * longitudinalOffset

    -- Spawn at terrain height + 40m
    local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, spawnX, 0, spawnZ)
    local spawnY = terrainY + ToolBirdFlockManager.SPAWN_HEIGHT_ABOVE_TERRAIN +
        (math.random() - 0.5) * 5 -- ±2.5m variation

    local bird = SimpleBirdDirect.new(spawnX, spawnY, spawnZ, self)

    if bird then
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
        self.isActive = false
        self:stopSound()

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
    self.isActive = false
end

---
-- Despawn a single bird (called periodically to gradually despawn all birds)
---
function ToolBirdFlockManager:despawnOneBird()
    if #self.spawnedBirds == 0 then
        self.isDespawning = false
        return false
    end

    local bird = self.spawnedBirds[1]
    if bird and bird.rootNode and entityExists(bird.rootNode) then
        if bird.requestDespawn then
            bird:requestDespawn()
        end

        table.insert(self.despawningBirds, bird)
    end

    table.remove(self.spawnedBirds, 1)
    self.numBirdsDespawned = self.numBirdsDespawned + 1

    if #self.spawnedBirds == 0 then
        self.isDespawning = false
        self.birdsSpawned = false
        self.numBirdsSpawned = 0
        self.targetNumberOfBirds = nil  -- Reset target so new random value is picked on next activation
        self:stopSound()
    end

    return true
end

---
-- Initialize the shared looping sound sample using g_soundManager
-- This provides automatic indoor/outdoor volume handling
---
function ToolBirdFlockManager:initializeSound()
    -- Clean up any existing sound
    if self.soundSample then
        g_soundManager:deleteSample(self.soundSample)
        self.soundSample = nil
    end

    -- Load bird config
    local config = BirdConfig.getConfig()
    if not config or not config.xmlFilename then
        return
    end

    -- Check user volume setting
    local userVolume = 1.0
    if BirdSettings and BirdSettings.settings then
        userVolume = BirdSettings.settings.birdSoundVolume or 1.0
    end

    -- Don't create sound if user has it disabled
    if userVolume == 0 then
        return
    end

    -- Get initial vehicle position for sound
    local vehicleX, vehicleY, vehicleZ = 0, 0, 0
    if self.vehicle and self.vehicle.rootNode then
        vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)
    end

    -- Create a transform node to position the sound in the world
    if not self.soundTransform or self.soundTransform == 0 then
        self.soundTransform = createTransformGroup("birdFlockSoundEmitter")
        setTranslation(self.soundTransform, vehicleX, vehicleY, vehicleZ)
        link(getRootNode(), self.soundTransform)
    end

    -- Load the XML file to pass to g_soundManager
    local xmlFile = loadXMLFile("BirdSpeciesConfig", config.xmlFilename)
    if not xmlFile or xmlFile == 0 then
        return
    end

    -- Load sample using g_soundManager (provides automatic indoor/outdoor handling)
    self.soundSample = g_soundManager:loadSampleFromXML(
        xmlFile,
        "species.sounds",
        "ambient",
        config.baseDirectory,
        self.soundTransform,  -- Link node for 3D positioning
        0,                    -- loops: 0 = infinite
        AudioGroup.ENVIRONMENT,
        nil,                  -- i3dMappings
        self,                 -- modifierTargetObject
        true                  -- requiresFile
    )

    delete(xmlFile)

    -- Apply user volume scale
    if self.soundSample then
        g_soundManager:setSampleVolumeScale(self.soundSample, userVolume)
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

    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.rootNode)
    setTranslation(self.soundTransform, vehicleX, vehicleY, vehicleZ)
end

---
-- Update the sound volume (called when user changes setting)
-- @param newUserVolume: New user volume setting (0.0 to 2.0)
---
function ToolBirdFlockManager:updateSoundVolume(newUserVolume)
    if newUserVolume == 0 then
        -- User disabled sound
        if self.soundSample and g_soundManager:getIsSamplePlaying(self.soundSample) then
            g_soundManager:stopSample(self.soundSample)
        end
        return
    end
    
    -- If sound was never initialized (because volume was 0), initialize it now
    if not self.soundSample then
        if self.isActive then  -- Only initialize if flock is active
            self:initializeSound()
            -- If sound should be playing (8 seconds passed since spawn start), start it
            if self.soundStartTime and (g_time - self.soundStartTime) >= 8000 then
                self:startSound()
                self.soundStarted = true
            end
        end
        return
    end
    
    -- Update volume scale
    g_soundManager:setSampleVolumeScale(self.soundSample, newUserVolume)
    
    -- If sound should be playing but isn't (e.g., user raised volume from 0), start it
    if self.isActive and self.soundStarted and not g_soundManager:getIsSamplePlaying(self.soundSample) then
        if self.soundStartTime and (g_time - self.soundStartTime) >= 8000 then
            self:startSound()
        end
    end
end

---
-- Start playing the looping sound
---
function ToolBirdFlockManager:startSound()
    if self.soundSample then
        g_soundManager:playSample(self.soundSample)
    end
end

---
-- Stop the looping sound and cleanup
---
function ToolBirdFlockManager:stopSound()
    if self.soundSample then
        g_soundManager:stopSample(self.soundSample)
        g_soundManager:deleteSample(self.soundSample)
        self.soundSample = nil
    end

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
