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
BirdStateMachine.STATE_FEEDING_GLIDE = "feeding_glide"   -- Gliding at altitude before diving
BirdStateMachine.STATE_FEEDING_DOWN = "feeding_down"     -- Flying back down
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
        groundTargetRadius = 8.0,   -- Pick targets within 8m of plow area
        upwardHeight = 10.0,        -- Base height to fly up (will add 0-5m randomness)
        downwardTargetRadius = 5.0, -- Pick targets within 5m when going down
        minGroundHeight = 0.01,     -- Minimum height above ground
        maxGroundHeight = 0.02,     -- Maximum height above ground when feeding
        glideTimeMs = 200,          -- How long to glide at altitude (milliseconds)
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
    elseif state == BirdStateMachine.STATE_FEEDING_GLIDE then
        self:enterFeedingGlideState()
    elseif state == BirdStateMachine.STATE_FEEDING_DOWN then
        self:enterFeedingDownState()
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
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_GLIDE then
        self:updateFeedingGlideState(dt)
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_DOWN then
        self:updateFeedingDownState(dt)
    elseif self.currentState == BirdStateMachine.STATE_DESPAWNING then
        self:updateDespawningState(dt)
    end
end

---
-- SPAWNING STATE: Bird spawns 50m behind tractor at terrain + 40m height
---
function BirdStateMachine:enterSpawningState()
    -- The bird is already spawned at the correct position by PlowBirdHotspotDirect
    -- Transition immediately to approaching
    self:setState(BirdStateMachine.STATE_APPROACHING_PLOW)
end

function BirdStateMachine:updateSpawningState(dt)
    -- Should transition immediately in enterSpawningState
end

---
-- APPROACHING PLOW STATE: Fly towards plow (up to 10m distance)
---
function BirdStateMachine:enterApproachingPlowState()
    if not self.bird or not self.bird.hotspot then
        return
    end

    -- Set active flying animation
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY)
    end

    -- Get hotspot position (near the plow)
    local hotspot = self.bird.hotspot
    local targetX = hotspot.worldX
    local targetZ = hotspot.worldZ

    -- Target is 10m away from plow (stopping distance)
    -- Add some randomness for natural variation
    local randomAngle = math.random() * math.pi * 2
    local randomRadius = 5.0 + math.random() * 5.0 -- 5-10m from plow

    targetX = targetX + math.sin(randomAngle) * randomRadius
    targetZ = targetZ + math.cos(randomAngle) * randomRadius

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
-- FEEDING GROUND STATE: Pick a ground target close to plow area, fly to it
---
function BirdStateMachine:enterFeedingGroundState()
    if not self.bird or not self.bird.hotspot then
        return
    end

    -- Capture landing yaw (horizontal facing direction) to preserve
    if self.bird.sceneNode then
        local p, y, r = getRotation(self.bird.sceneNode)
        self.stateData.landingYaw = y  -- Store the yaw we want to keep
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
    local minTime = (self.bird.attributes.groundIdleTimeMin or 0.5) * 1000  -- Convert seconds to milliseconds
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

    -- Fly up in a curved arc (with significant horizontal drift for natural curved flight)
    local upHeight = self.feedingConfig.upwardHeight + math.random() * 5.0 -- 10-15m
    local driftX = (math.random() - 0.5) * 16.0                             -- Up to 8m drift in X
    local driftZ = (math.random() - 0.5) * 16.0                             -- Up to 8m drift in Z

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
        -- Transition to gliding state
        self:setState(BirdStateMachine.STATE_FEEDING_GLIDE)
    end
end

---
-- FEEDING GLIDE STATE: Glide at altitude for 1 second before diving
---
function BirdStateMachine:enterFeedingGlideState()
    -- Switch to glide animation (smooth gliding while looking down)
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_GLIDE)
    end

    -- Point bird downward as if looking at the ground (30-45 degrees down)
    local lookDownAngle = -30 - math.random() * 15 -- -30 to -45 degrees
    if self.bird.setPitchAngle then
        self.bird:setPitchAngle(lookDownAngle)
    end

    -- Record when gliding started
    self.stateData.glideStartTime = g_time
end

function BirdStateMachine:updateFeedingGlideState(dt)
    -- Wait for configured glide time
    local glideTime = g_time - self.stateData.glideStartTime
    if glideTime >= self.feedingConfig.glideTimeMs then
        -- Glide complete, now dive back down
        self:setState(BirdStateMachine.STATE_FEEDING_DOWN)
    end
end

---
-- FEEDING DOWN STATE: Fly back down to ground near plow
---
function BirdStateMachine:enterFeedingDownState()
    if not self.bird or not self.bird.hotspot then
        return
    end

    -- Set downward flying animation (with flapping)
    if self.bird.setAnimationByName then
        self.bird:setAnimationByName(SimpleBirdDirect.ANIM_FLY_DOWN_FLAP)
    end

    local hotspot = self.bird.hotspot

    -- Pick a new ground target near plow
    local randomAngle = math.random() * math.pi * 2
    local randomRadius = math.random() * self.feedingConfig.downwardTargetRadius

    local targetX = hotspot.worldX + math.sin(randomAngle) * randomRadius
    local targetZ = hotspot.worldZ + math.cos(randomAngle) * randomRadius

    -- Ground level target
    local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) +
        self.feedingConfig.minGroundHeight +
        math.random() * (self.feedingConfig.maxGroundHeight - self.feedingConfig.minGroundHeight)

    self.stateData.targetX = targetX
    self.stateData.targetY = targetY
    self.stateData.targetZ = targetZ

    -- Set bird target with curved path for natural diving
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 12.0) -- Medium-fast dive with curve
    else
        self.bird:moveToTarget(targetX, targetY, targetZ, 15.0) -- Fallback to straight line
    end
end

function BirdStateMachine:updateFeedingDownState(dt)
    -- Check if bird reached down target
    if not self.bird:getIsMoving() then
        -- Complete the loop - go back to ground feeding
        self:setState(BirdStateMachine.STATE_FEEDING_GROUND)
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
    local randomDistance = 40.0 + math.random() * 30.0 -- 40-70m away

    local targetX = currentX + math.sin(randomAngle) * randomDistance
    local targetZ = currentZ + math.cos(randomAngle) * randomDistance

    -- Target height: 40-50m above terrain
    local targetTerrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ)
    local targetHeight = 40.0 + math.random() * 10.0 -- 40-50m
    local targetY = targetTerrainY + targetHeight

    self.stateData.despawnStartTime = g_time

    -- Use straight line for fast despawn
    self.bird:moveToTarget(targetX, targetY, targetZ, 16.0) -- Fast despawn

    -- Mark bird as despawning
    if self.bird then
        self.bird.isDespawning = true
        self.bird.despawnStartTime = g_time
    end
end

function BirdStateMachine:updateDespawningState(dt)
    -- Bird will be deleted by PlowBirdHotspotDirect after timeout
    -- Just keep flying to target
end

---
-- Request state machine to enter despawning state (called by hotspot on cleanup)
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
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_GLIDE then
        return SimpleBirdDirect.ANIM_GLIDE
    elseif self.currentState == BirdStateMachine.STATE_FEEDING_DOWN then
        return SimpleBirdDirect.ANIM_FLY_DOWN_FLAP
    elseif self.currentState == BirdStateMachine.STATE_DESPAWNING then
        return SimpleBirdDirect.ANIM_FLY
    else
        return SimpleBirdDirect.ANIM_FLY -- Default fallback
    end
end
