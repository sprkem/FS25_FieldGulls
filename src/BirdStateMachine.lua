---
-- BirdStateMachine
-- Manages the lifecycle states of a bird
---

BirdStateMachine = {}
local BirdStateMachine_mt = Class(BirdStateMachine)

-- State constants
BirdStateMachine.STATE_SPAWNING = "spawning"             -- Bird is spawning and flying to plow
BirdStateMachine.STATE_APPROACHING_PLOW = "approaching"  -- Flying towards plow (initial approach)
BirdStateMachine.STATE_FEEDING_GROUND = "feeding_ground" -- Picking ground target and flying to it
BirdStateMachine.STATE_FEEDING_UP = "feeding_up"         -- Flying upward from ground
BirdStateMachine.STATE_FEEDING_ARC = "feeding_arc"       -- Arcing path back down to ground
BirdStateMachine.STATE_SEARCHING = "searching"           -- Flying in air searching for cells
BirdStateMachine.STATE_DESPAWNING = "despawning"         -- Flying away on deactivation

---
-- Create a new bird state machine
-- @param bird: The SimpleBirdDirect instance this state machine controls
-- @return BirdStateMachine instance
---
function BirdStateMachine.new(bird)
    local self = setmetatable({}, BirdStateMachine_mt)

    self.bird = bird
    self.currentState = BirdStateMachine.STATE_SPAWNING
    self.stateStartTime = g_time
    self.stateData = {} -- State-specific data

    -- Configuration for feeding loop
    self.feedingConfig = {
        groundTargetRadius = 8.0,      -- Pick targets within 8m of plow area
        upwardHeight = 10.0,           -- Base height to fly up (will add 0-5m randomness)
        arcTargetRadius = 5.0,         -- Pick targets within 5m when arcing down
        minGroundHeight = 0.01,        -- Minimum height above ground
        maxGroundHeight = 0.02,        -- Maximum height above ground when feeding
        arcCurvature = 1.2,            -- Curvature for the arcing path (higher = more arc)
        searchingHeight = 15.0,        -- Height to fly at when searching (10-20m)
        searchingDistance = 15.0,      -- Distance between search points (10-20m)
        searchingCheckInterval = 3000, -- Check for cells every 3 seconds
    }

    -- Enter the initial state to trigger behavior
    self:onStateEnter(self.currentState)

    return self
end

---
-- Get the current state
-- @return string: Current state name
---
function BirdStateMachine:getState()
    return self.currentState
end

---
-- Get time spent in current state (milliseconds)
-- @return number: Milliseconds in current state
---
function BirdStateMachine:getTimeInState()
    return g_time - self.stateStartTime
end

---
-- Transition to a new state
-- @param newState: State name to transition to
---
function BirdStateMachine:setState(newState)
    if self.currentState == newState then
        return
    end

    local oldState = self.currentState
    self.currentState = newState
    self.stateStartTime = g_time
    self.stateData = {} -- Clear state-specific data

    -- Call state entry handler
    self:onStateEnter(newState)
end

---
-- Called when entering a new state
-- @param state: The state being entered
---
function BirdStateMachine:onStateEnter(state)
    if state == BirdStateMachine.STATE_SPAWNING then
        self:enterSpawningState()
    elseif state == BirdStateMachine.STATE_APPROACHING_PLOW then
        self:enterApproachingPlowState()
    elseif state == BirdStateMachine.STATE_FEEDING_GROUND then
        self:enterFeedingGroundState()
    elseif state == BirdStateMachine.STATE_FEEDING_UP then
        self:enterFeedingUpState()
    elseif state == BirdStateMachine.STATE_FEEDING_ARC then
        self:enterFeedingArcState()
    elseif state == BirdStateMachine.STATE_SEARCHING then
        self:enterSearchingState()
    elseif state == BirdStateMachine.STATE_DESPAWNING then
        self:enterDespawningState()
    end
end

---
-- Update the state machine
-- @param dt: Delta time in milliseconds
---
function BirdStateMachine:update(dt)
    if self.currentState == BirdStateMachine.STATE_SPAWNING then
        self:updateSpawningState(dt)
    elseif self.currentState == BirdStateMachine.STATE_APPROACHING_PLOW then
        self:updateApproachingPlowState(dt)
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_GROUND then
        self:updateFeedingGroundState(dt)
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_UP then
        self:updateFeedingUpState(dt)
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_ARC then
        self:updateFeedingArcState(dt)
    elseif self.currentState == BirdStateMachine.STATE_SEARCHING then
        self:updateSearchingState(dt)
    elseif self.currentState == BirdStateMachine.STATE_DESPAWNING then
        self:updateDespawningState(dt)
    end
end

---
-- SPAWNING STATE: Bird spawns 50m behind tractor at terrain + 40m height
---
function BirdStateMachine:enterSpawningState()
    -- The bird is already spawned at the correct position by ToolBirdFlockManager
    -- Transition immediately to approaching
    self:setState(BirdStateMachine.STATE_APPROACHING_PLOW)
end

function BirdStateMachine:updateSpawningState(dt)
    -- Should transition immediately in enterSpawningState
end

---
-- APPROACHING PLOW STATE: Find and fly to a worked grid cell
---
function BirdStateMachine:enterApproachingPlowState()
    if not self.bird then
        return
    end

    -- Set active flying animation
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY)
    end

    local currentX, currentY, currentZ = self.bird:getCurrentPosition()
    local targetX = currentX
    local targetZ = currentZ

    -- Check if we already have a target from exiting search mode
    if self.stateData.foundTarget then
        targetX = self.stateData.foundTarget.x
        targetZ = self.stateData.foundTarget.z
        self.stateData.foundTarget = nil -- Clear it
    else
        -- Request a feeding target from the central grid system
        local isMoving = self:isVehicleMoving()
        local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.bird.manager.vehicle.rootNode)

        if g_gridFeedingZones then
            local cellTargetX, cellTargetZ = g_gridFeedingZones:requestFeedingTarget(currentX, currentZ, vehicleX, vehicleZ,
                isMoving)
            if cellTargetX and cellTargetZ then
                targetX = cellTargetX
                targetZ = cellTargetZ
            else
                -- No cell found - transition to searching state
                local totalCells = g_gridFeedingZones:getCellCount()
                self:setState(BirdStateMachine.STATE_SEARCHING)
                return
            end
        end
    end

    -- Target height is near ground level (feeding height)
    local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) +
        self.feedingConfig.minGroundHeight +
        math.random() * (self.feedingConfig.maxGroundHeight - self.feedingConfig.minGroundHeight)

    -- Set bird target with curved path
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 10.0) -- 10 m/s approach speed
    else
        self.bird:moveToTarget(targetX, targetY, targetZ, 10.0)
    end
end

function BirdStateMachine:updateApproachingPlowState(dt)
    -- Check if bird reached target
    if not self.bird:getIsMoving() then
        -- Reached plow area, start feeding loop
        self:setState(BirdStateMachine.STATE_FEEDING_GROUND)
    end
end

---
-- FEEDING GROUND STATE: Bird is on ground, pecking and eating
---
function BirdStateMachine:enterFeedingGroundState()
    if not self.bird then
        return
    end

    -- Capture landing yaw (horizontal facing direction) to preserve
    if self.bird.sceneNode then
        local p, y, r = getRotation(self.bird.sceneNode)
        self.stateData.landingYaw = y -- Store the yaw we want to keep
    end

    -- Set landing/eating animation when reaching ground
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_IDLE_EAT)
    end

    -- Force bird flat on ground (pitch=0, roll=0) with preserved yaw for eating
    if self.bird.sceneNode and self.stateData.landingYaw then
        setRotation(self.bird.sceneNode, 0, self.stateData.landingYaw, 0)
    end
end

function BirdStateMachine:updateFeedingGroundState(dt)
    -- Continuously enforce flat rotation with preserved yaw (idleEat should be flat on ground)
    if self.bird.sceneNode and self.stateData.landingYaw then
        -- Always force flat rotation: pitch=0, roll=0, yaw=landing direction
        setRotation(self.bird.sceneNode, 0, self.stateData.landingYaw, 0)
    end

    -- Stay on ground briefly before flying up again (time configured per species in XML)
    if not self.stateData.groundStartTime then
        self.stateData.groundStartTime = g_time
    end

    local timeOnGround = g_time - self.stateData.groundStartTime

    -- Get idle time from bird attributes (loaded from XML)
    local minTime = (self.bird.attributes.groundIdleTimeMin or 0.5) * 1000 -- Convert seconds to milliseconds
    local maxTime = (self.bird.attributes.groundIdleTimeMax or 2.0) * 1000
    local requiredGroundTime = minTime + math.random() * (maxTime - minTime)

    if timeOnGround >= requiredGroundTime then
        -- Fly upward again
        self:setState(BirdStateMachine.STATE_FEEDING_UP)
    end
end

---
-- FEEDING UP STATE: Fly upward 10-15 meters
---
function BirdStateMachine:enterFeedingUpState()
    local currentX, currentY, currentZ = self.bird:getCurrentPosition()

    -- Set takeoff/fly up animation
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY_UP)
    end

    -- Fly upward with some horizontal drift
    local upHeight = self.feedingConfig.upwardHeight + math.random() * 5.0 -- 10-15m
    local driftX = (math.random() - 0.5) * 10.0                            -- Small horizontal drift
    local driftZ = (math.random() - 0.5) * 10.0

    local targetX = currentX + driftX
    local targetY = currentY + upHeight
    local targetZ = currentZ + driftZ

    self.stateData.targetX = targetX
    self.stateData.targetY = targetY
    self.stateData.targetZ = targetZ

    -- Set bird target with curved path
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 8.0) -- Medium speed up
    else
        self.bird:moveToTarget(targetX, targetY, targetZ, 8.0)
    end
end

function BirdStateMachine:updateFeedingUpState(dt)
    -- Check if bird reached up target
    if not self.bird:getIsMoving() then
        -- Transition to arcing state for smooth loop down
        self:setState(BirdStateMachine.STATE_FEEDING_ARC)
    end
end

---
-- FEEDING ARC STATE: Create smooth arcing path back down to a new feeding spot
-- Two-phase approach: First fly toward work area if far away, then request fresh target and dive
---
function BirdStateMachine:enterFeedingArcState()
    if not self.bird then
        return
    end

    -- Set flying animation for the arc
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY)
    end

    local currentX, currentY, currentZ = self.bird:getCurrentPosition()

    -- Check if we have cells and get work area position
    if not g_gridFeedingZones or g_gridFeedingZones:getCellCount() == 0 then
        -- No cells - circle at height
        local randomAngle = math.random() * math.pi * 2
        local randomRadius = 15 + math.random() * 10
        local targetX = currentX + math.sin(randomAngle) * randomRadius
        local targetZ = currentZ + math.cos(randomAngle) * randomRadius

        self.stateData.seekingWorkArea = false
        if self.bird.moveToCurved then
            self.bird:moveToCurved(targetX, currentY, targetZ, 10.0, 0.5)
        else
            self.bird:moveToTarget(targetX, currentY, targetZ, 10.0)
        end
        return
    end

    -- Get position of newest cell (work area center)
    local workAreaX, workAreaZ = g_gridFeedingZones:getWorkAreaPosition()
    if not workAreaX then
        -- Shouldn't happen but handle gracefully
        self.stateData.seekingWorkArea = false
        return
    end

    -- Calculate distance to work area (2D horizontal distance)
    local dx = workAreaX - currentX
    local dz = workAreaZ - currentZ
    local distanceToWorkArea = math.sqrt(dx * dx + dz * dz)

    -- If far from work area (>20m), fly toward it first at current height
    if distanceToWorkArea > 20 then
        self.stateData.seekingWorkArea = true
        self.stateData.workAreaX = workAreaX
        self.stateData.workAreaZ = workAreaZ

        -- Fly toward work area at current height
        if self.bird.moveToCurved then
            self.bird:moveToCurved(workAreaX, currentY, workAreaZ, 10.0, 0.3)
        else
            self.bird:moveToTarget(workAreaX, currentY, workAreaZ, 10.0)
        end
    else
        -- Close enough - request target immediately and dive down
        self.stateData.seekingWorkArea = false
        self:requestTargetAndDive()
    end
end

function BirdStateMachine:updateFeedingArcState(dt)
    -- If we're seeking work area, check if we're close enough now
    if self.stateData.seekingWorkArea then
        local currentX, currentY, currentZ = self.bird:getCurrentPosition()

        -- Check distance to work area
        if self.stateData.workAreaX and self.stateData.workAreaZ then
            local dx = self.stateData.workAreaX - currentX
            local dz = self.stateData.workAreaZ - currentZ
            local distance = math.sqrt(dx * dx + dz * dz)

            -- Within 2m or stopped moving? Request target and dive
            if distance <= 1 or not self.bird:getIsMoving() then
                self.stateData.seekingWorkArea = false
                self:requestTargetAndDive()
            end
        end
    else
        -- Already diving - check if we reached ground
        if not self.bird:getIsMoving() then
            -- Arc complete - go back to ground feeding
            self:setState(BirdStateMachine.STATE_FEEDING_GROUND)
        end
    end
end

---
-- Helper: Request a fresh target from grid and start diving
---
function BirdStateMachine:requestTargetAndDive()
    if not self.bird then
        return
    end

    local currentX, currentY, currentZ = self.bird:getCurrentPosition()
    local targetX = currentX
    local targetZ = currentZ

    -- Check if vehicle is moving
    local isMoving = self:isVehicleMoving()

    -- Get vehicle position for distance filtering
    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.bird.manager.vehicle.rootNode)

    -- Request a feeding target from the central grid system
    if g_gridFeedingZones then
        local cellTargetX, cellTargetZ = g_gridFeedingZones:requestFeedingTarget(currentX, currentZ, vehicleX, vehicleZ,
            isMoving)
        if cellTargetX and cellTargetZ then
            targetX = cellTargetX
            targetZ = cellTargetZ
        else
            -- No cells found - transition to searching state
            local totalCells = g_gridFeedingZones:getCellCount()
            self:setState(BirdStateMachine.STATE_SEARCHING)
            return
        end
    else
        self:setState(BirdStateMachine.STATE_SEARCHING)
        return
    end

    -- Ground level target
    local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) +
        self.feedingConfig.minGroundHeight +
        math.random() * (self.feedingConfig.maxGroundHeight - self.feedingConfig.minGroundHeight)

    self.stateData.targetX = targetX
    self.stateData.targetY = targetY
    self.stateData.targetZ = targetZ

    -- Create arcing path with high curvature for smooth loop down
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 10.0, self.feedingConfig.arcCurvature)
    else
        self.bird:moveToTarget(targetX, targetY, targetZ, 10.0)
    end
end

---
-- SEARCHING STATE: Fly around in the air searching for available grid cells
---
function BirdStateMachine:enterSearchingState()
    local currentX, currentY, currentZ = self.bird:getCurrentPosition()

    -- Set flying animation
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY)
    end

    -- Store when we last checked for cells
    self.stateData.lastCellCheck = g_time

    -- Pick a random aerial point to fly to
    local randomAngle = math.random() * math.pi * 2
    local randomDistance = 10 + math.random() * 10 -- 10-20 meters

    local targetX = currentX + math.sin(randomAngle) * randomDistance
    local targetZ = currentZ + math.cos(randomAngle) * randomDistance

    -- Target height: 10-20m above terrain
    local targetTerrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ)
    local targetHeight = self.feedingConfig.searchingHeight + math.random() * 5 -- 15-20m
    local targetY = targetTerrainY + targetHeight

    self.bird:moveToTarget(targetX, targetY, targetZ, 8.0)
end

function BirdStateMachine:updateSearchingState(dt)
    -- Check if reached current target
    if not self.bird.hasTarget or not self.bird.isMoving then
        -- Pick new aerial target
        local currentX, currentY, currentZ = self.bird:getCurrentPosition()
        local randomAngle = math.random() * math.pi * 2
        local randomDistance = 10 + math.random() * 10 -- 10-20 meters

        local targetX = currentX + math.sin(randomAngle) * randomDistance
        local targetZ = currentZ + math.cos(randomAngle) * randomDistance

        local targetTerrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ)
        local targetHeight = self.feedingConfig.searchingHeight + math.random() * 5
        local targetY = targetTerrainY + targetHeight

        self.bird:moveToTarget(targetX, targetY, targetZ, 8.0)
    end

    -- Periodically check if valid feeding targets are now available
    local timeSinceLastCheck = g_time - (self.stateData.lastCellCheck or 0)
    if timeSinceLastCheck > self.feedingConfig.searchingCheckInterval then
        self.stateData.lastCellCheck = g_time

        -- Try to actually get a valid target (not just check if cells exist)
        if g_gridFeedingZones and g_gridFeedingZones:getCellCount() > 0 then
            local currentX, currentY, currentZ = self.bird:getCurrentPosition()
            local isMoving = self:isVehicleMoving()
            local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.bird.manager.vehicle.rootNode)
            
            -- Try to get a valid target (this will filter by distance from tool)
            local testX, testZ = g_gridFeedingZones:requestFeedingTarget(currentX, currentZ, vehicleX, vehicleZ, isMoving)
            
            if testX and testZ then
                -- Valid target available - store it and return to feeding
                self.stateData.foundTarget = { x = testX, z = testZ }
                self:setState(BirdStateMachine.STATE_APPROACHING_PLOW)
            end
        end
    end
end

---
-- DESPAWNING STATE: Pick random direction at 40-50m height and fly away
---
function BirdStateMachine:enterDespawningState()
    local currentX, currentY, currentZ = self.bird:getCurrentPosition()

    -- Set fast active flying animation for fleeing
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY)
    end

    -- Pick a random direction
    local randomAngle = math.random() * math.pi * 2
    local targetDistance = 200.0 -- 200m away (far enough to be out of sight)

    local targetX = currentX + math.sin(randomAngle) * targetDistance
    local targetZ = currentZ + math.cos(randomAngle) * targetDistance

    -- Target height: 40-50m above terrain
    local targetTerrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ)
    local targetHeight = 40.0 + math.random() * 10.0 -- 40-50m
    local targetY = targetTerrainY + targetHeight

    self.stateData.despawnStartTime = g_time

    -- Use straight line for fast despawn
    self.bird:moveToTarget(targetX, targetY, targetZ, 12.0) -- Fast despawn (increased speed)

    -- Mark bird as despawning
    if self.bird then
        self.bird.isDespawning = true
        self.bird.despawnStartTime = g_time
    end
end

function BirdStateMachine:updateDespawningState(dt)
    -- Bird will be deleted by ToolBirdFlockManager after timeout
    -- Just keep flying to target
end

---
-- Request state machine to enter despawning state (called by flock manager on cleanup)
---
function BirdStateMachine:requestDespawn()
    if self.currentState ~= BirdStateMachine.STATE_DESPAWNING then
        self:setState(BirdStateMachine.STATE_DESPAWNING)
    end
end

---
-- Check if bird is in despawning state
-- @return boolean: True if despawning
---
function BirdStateMachine:isDespawning()
    return self.currentState == BirdStateMachine.STATE_DESPAWNING
end

---
-- Check if the vehicle is currently moving
-- @return boolean: True if moving (speed > 0.5 km/h), false if stopped or no vehicle
---
function BirdStateMachine:isVehicleMoving()
    -- Check if we have access to the vehicle through the bird's manager
    if not self.bird or not self.bird.manager or not self.bird.manager.vehicle then
        return true -- Default to true (assume moving) if we can't check
    end

    local vehicle = self.bird.manager.vehicle

    -- Check vehicle's lastSpeedReal (in m/s) or lastSpeed (in km/h)
    if vehicle.lastSpeedReal then
        -- Speed in m/s - consider moving if > 0.14 m/s (~0.5 km/h)
        return vehicle.lastSpeedReal > 0.14
    elseif vehicle.lastSpeed then
        -- Speed in km/h - consider moving if > 0.5 km/h
        return vehicle.lastSpeed > 0.5
    end

    return true -- Default to true if we can't determine speed
end

---
-- Get the appropriate animation name for the current state
-- @return string: Animation name (e.g., "fly", "idleEat", etc.)
---
function BirdStateMachine:getCurrentStateAnimation()
    if self.currentState == BirdStateMachine.STATE_SPAWNING then
        return SimpleBirdDirect.ANIM_FLY
    elseif self.currentState == BirdStateMachine.STATE_APPROACHING_PLOW then
        return SimpleBirdDirect.ANIM_FLY
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_GROUND then
        return SimpleBirdDirect.ANIM_IDLE_EAT
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_UP then
        return SimpleBirdDirect.ANIM_FLY_UP
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_ARC then
        return SimpleBirdDirect.ANIM_FLY
    elseif self.currentState == BirdStateMachine.STATE_SEARCHING then
        return SimpleBirdDirect.ANIM_FLY
    elseif self.currentState == BirdStateMachine.STATE_DESPAWNING then
        return SimpleBirdDirect.ANIM_FLY
    else
        return SimpleBirdDirect.ANIM_FLY -- Default fallback
    end
end
