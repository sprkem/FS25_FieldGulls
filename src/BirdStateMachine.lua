---
-- BirdStateMachine
-- Manages the lifecycle states of a bird
---

BirdStateMachine = {}
local BirdStateMachine_mt = Class(BirdStateMachine)

-- State constants
BirdStateMachine.STATE_SPAWNING = "spawning"           -- Bird is spawning and flying to plow
BirdStateMachine.STATE_APPROACHING_PLOW = "approaching" -- Flying towards plow (initial approach)
BirdStateMachine.STATE_FEEDING_GROUND = "feeding_ground" -- Picking ground target and flying to it
BirdStateMachine.STATE_FEEDING_UP = "feeding_up"       -- Flying upward from ground
BirdStateMachine.STATE_FEEDING_DOWN = "feeding_down"   -- Flying back down
BirdStateMachine.STATE_DESPAWNING = "despawning"       -- Flying away on deactivation

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
    self.stateData = {}  -- State-specific data
    
    -- Configuration for feeding loop
    self.feedingConfig = {
        groundTargetRadius = 8.0,      -- Pick targets within 8m of plow area
        upwardHeight = 10.0,            -- Base height to fly up (will add 0-5m randomness)
        downwardTargetRadius = 5.0,     -- Pick targets within 5m when going down
        minGroundHeight = 0.01,          -- Minimum height above ground
        maxGroundHeight = 0.02,          -- Maximum height above ground when feeding
    }
    
    print(string.format("[BirdStateMachine] Created in state: %s", self.currentState))
    
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
    self.stateData = {}  -- Clear state-specific data
    
    print(string.format("[BirdStateMachine] State transition: %s -> %s", oldState, newState))
    
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
        print("[BirdStateMachine] ERROR: No bird or hotspot for approaching state")
        return
    end
    
    -- Set active flying animation
    if self.bird.setAnimation then
        self.bird:setAnimation(SimpleBirdDirect.ANIM_FLY.opcode, SimpleBirdDirect.ANIM_FLY.speed)
    end
    
    -- Get hotspot position (near the plow)
    local hotspot = self.bird.hotspot
    local targetX = hotspot.worldX
    local targetZ = hotspot.worldZ
    
    -- Target is 10m away from plow (stopping distance)
    -- Add some randomness for natural variation
    local randomAngle = math.random() * math.pi * 2
    local randomRadius = 5.0 + math.random() * 5.0  -- 5-10m from plow
    
    targetX = targetX + math.sin(randomAngle) * randomRadius
    targetZ = targetZ + math.cos(randomAngle) * randomRadius
    
    -- Target height is near ground level (feeding height)
    local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) + 
        self.feedingConfig.minGroundHeight + 
        math.random() * (self.feedingConfig.maxGroundHeight - self.feedingConfig.minGroundHeight)
    
    print(string.format("[BirdStateMachine] Approaching plow: target=(%.1f, %.1f, %.1f) radius=%.1f", 
        targetX, targetY, targetZ, randomRadius))
    
    -- Set bird target with curved path
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 10.0)  -- 10 m/s approach speed
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
        print("[BirdStateMachine] ERROR: No bird or hotspot for feeding ground state")
        return
    end
    
    -- Set landing/eating animation when reaching ground
    if self.bird.setAnimation then
        self.bird:setAnimation(SimpleBirdDirect.ANIM_IDLE_EAT.opcode, SimpleBirdDirect.ANIM_IDLE_EAT.speed)
    end
    
    local hotspot = self.bird.hotspot
    
    -- Pick a random ground target near the plow area
    local randomAngle = math.random() * math.pi * 2
    local randomRadius = math.random() * self.feedingConfig.groundTargetRadius
    
    local targetX = hotspot.worldX + math.sin(randomAngle) * randomRadius
    local targetZ = hotspot.worldZ + math.cos(randomAngle) * randomRadius
    
    -- Ground level target (low, for feeding)
    local targetY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ) + 
        self.feedingConfig.minGroundHeight + 
        math.random() * (self.feedingConfig.maxGroundHeight - self.feedingConfig.minGroundHeight)
    
    -- Store target for reference
    self.stateData.targetX = targetX
    self.stateData.targetY = targetY
    self.stateData.targetZ = targetZ
    
    if math.random() < 0.2 then
        print(string.format("[BirdStateMachine] Feeding ground target: (%.1f, %.1f, %.1f)", 
            targetX, targetY, targetZ))
    end
    
    -- Set bird target with curved path
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 6.0)  -- Slower feeding speed
    else
        self.bird:moveToTarget(targetX, targetY, targetZ, 6.0)
    end
end

function BirdStateMachine:updateFeedingGroundState(dt)
    -- Check if bird reached ground target
    if not self.bird:getIsMoving() then
        -- Stay on ground briefly (0.5-2 seconds) before flying up
        if not self.stateData.groundStartTime then
            self.stateData.groundStartTime = g_time
        end
        
        local timeOnGround = g_time - self.stateData.groundStartTime
        local requiredGroundTime = 500 + math.random() * 1500  -- 0.5-2 seconds
        
        if timeOnGround >= requiredGroundTime then
            -- Fly upward
            self:setState(BirdStateMachine.STATE_FEEDING_UP)
        end
    end
end

---
-- FEEDING UP STATE: Fly upward 10-15 meters
---
function BirdStateMachine:enterFeedingUpState()
    local currentX, currentY, currentZ = self.bird:getCurrentPosition()
    
    -- Set takeoff/fly up animation
    if self.bird.setAnimation then
        self.bird:setAnimation(SimpleBirdDirect.ANIM_FLY_UP.opcode, SimpleBirdDirect.ANIM_FLY_UP.speed)
    end
    
    -- Fly straight up from current position (with slight horizontal drift for realism)
    local upHeight = self.feedingConfig.upwardHeight + math.random() * 5.0  -- 10-15m
    local driftX = (math.random() - 0.5) * 3.0  -- Up to 1.5m drift in X
    local driftZ = (math.random() - 0.5) * 3.0  -- Up to 1.5m drift in Z
    
    local targetX = currentX + driftX
    local targetY = currentY + upHeight
    local targetZ = currentZ + driftZ
    
    self.stateData.targetX = targetX
    self.stateData.targetY = targetY
    self.stateData.targetZ = targetZ
    
    if math.random() < 0.2 then
        print(string.format("[BirdStateMachine] Flying up: from (%.1f, %.1f, %.1f) to (%.1f, %.1f, %.1f)", 
            currentX, currentY, currentZ, targetX, targetY, targetZ))
    end
    
    -- Set bird target with curved path
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 8.0)  -- Medium speed up
    else
        self.bird:moveToTarget(targetX, targetY, targetZ, 8.0)
    end
end

function BirdStateMachine:updateFeedingUpState(dt)
    -- Check if bird reached up target
    if not self.bird:getIsMoving() then
        -- Now fly back down
        self:setState(BirdStateMachine.STATE_FEEDING_DOWN)
    end
end

---
-- FEEDING DOWN STATE: Fly back down to ground near plow
---
function BirdStateMachine:enterFeedingDownState()
    if not self.bird or not self.bird.hotspot then
        print("[BirdStateMachine] ERROR: No bird or hotspot for feeding down state")
        return
    end
    
    -- Set downward flying animation (with flapping)
    if self.bird.setAnimation then
        self.bird:setAnimation(SimpleBirdDirect.ANIM_FLY_DOWN_FLAP.opcode, SimpleBirdDirect.ANIM_FLY_DOWN_FLAP.speed)
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
    
    if math.random() < 0.2 then
        print(string.format("[BirdStateMachine] Flying down: target (%.1f, %.1f, %.1f)", 
            targetX, targetY, targetZ))
    end
    
    -- Set bird target with curved path
    if self.bird.moveToCurved then
        self.bird:moveToCurved(targetX, targetY, targetZ, 7.0)  -- Gentle descent
    else
        self.bird:moveToTarget(targetX, targetY, targetZ, 7.0)
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
    if self.bird.setAnimation then
        self.bird:setAnimation(SimpleBirdDirect.ANIM_FLY.opcode, SimpleBirdDirect.ANIM_FLY.speed)
    end
    
    -- Pick a random direction
    local randomAngle = math.random() * math.pi * 2
    local randomDistance = 40.0 + math.random() * 30.0  -- 40-70m away
    
    local targetX = currentX + math.sin(randomAngle) * randomDistance
    local targetZ = currentZ + math.cos(randomAngle) * randomDistance
    
    -- Target height: 40-50m above terrain
    local targetTerrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, targetX, 0, targetZ)
    local targetHeight = 40.0 + math.random() * 10.0  -- 40-50m
    local targetY = targetTerrainY + targetHeight
    
    self.stateData.despawnStartTime = g_time
    
    print(string.format("[BirdStateMachine] Despawning: flying from (%.1f, %.1f, %.1f) to (%.1f, %.1f, %.1f)", 
        currentX, currentY, currentZ, targetX, targetY, targetZ))
    
    -- Use straight line for fast despawn
    self.bird:moveToTarget(targetX, targetY, targetZ, 16.0)  -- Fast despawn
    
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
