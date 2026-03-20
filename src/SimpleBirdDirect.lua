---
-- SimpleBirdDirect: Direct i3d management without wildlife system
-- Loads bird i3d directly and manages movement manually
-- Uses state machine and curved path support
-- Only supports AnimCharSet with frame-based animations
---

SimpleBirdDirect = {}
local SimpleBirdDirect_mt = Class(SimpleBirdDirect)
SimpleBirdDirect.dir = g_currentModDirectory

---
-- Create a new SimpleBirdDirect instance
-- @param x, y, z: Initial position
-- @param manager: Reference to the bird flock manager
-- @return SimpleBirdDirect instance or nil on failure
---
function SimpleBirdDirect.new(x, y, z, manager)
    local self = {}
    setmetatable(self, SimpleBirdDirect_mt)

    self.manager = manager
    self.isDespawning = false
    self.despawnStartTime = 0

    -- Movement configuration
    self.moveSpeed = 8.0 -- meters per second
    self.turnSpeed = 3.0 -- radians per second
    self.flyHeight = 0.3 -- meters above ground

    -- Create root node for position tracking
    self.rootNode = createTransformGroup("SimpleBirdDirect")
    link(getRootNode(), self.rootNode)
    setWorldTranslation(self.rootNode, x, y, z)

    -- Movement state
    self.targetX = x
    self.targetY = y
    self.targetZ = z
    self.hasTarget = false
    self.isMoving = false

    -- Curved path system
    self.curvedPath = nil -- CurvedPathPlanner instance
    self.pathDistance = 0 -- Distance traveled along current path
    self.usingCurvedPath = false

    -- Current flight direction (normalized) for smooth path transitions
    self.currentDirX = 0
    self.currentDirY = 0
    self.currentDirZ = 1

    -- Visual node (will be loaded async)
    self.visualNode = nil
    self.sceneNode = nil
    self.animCharSet = nil
    self.isLoading = false
    self.loadRequestId = nil

    -- Animation state tracking (frame-based only)
    self.currentAnimName = nil
    self.pendingAnimName = nil  -- Animation to apply once model loads
    self.animationTime = 0      -- Current time within animation (MILLISECONDS)
    self.animationStartTime = 0 -- Start time in clip (MILLISECONDS)
    self.animationEndTime = 0   -- End time in clip (MILLISECONDS)
    self.animationSpeed = 1.0   -- Playback speed
    self.clipDuration = 0       -- Total clip duration (MILLISECONDS)

    -- Get bird attributes from shared config
    self.attributes = BirdConfig.getConfig()
    if not self.attributes then
        delete(self.rootNode)
        return nil
    end

    -- Initialize state machine
    self.stateMachine = BirdStateMachine.new(self)

    -- Start loading the bird model
    self:loadVisualModel()

    return self
end

---
-- Load the bird visual model asynchronously
---
function SimpleBirdDirect:loadVisualModel()
    if self.isLoading then
        return
    end

    self.isLoading = true
    local modelPath = self.attributes.filename
    self.loadRequestId = g_i3DManager:loadSharedI3DFileAsync(
        modelPath,
        false, -- callOnCreate
        false, -- addToPhysics
        self.onBirdModelLoaded,
        self,
        nil
    )
end

---
-- Callback when bird model is loaded
-- @param i3dNode: Loaded i3d node
-- @param failedReason: Error code if loading failed
-- @param args: Additional arguments
---
function SimpleBirdDirect:onBirdModelLoaded(i3dNode, failedReason, args)
    self.isLoading = false

    if failedReason ~= 0 then
        return
    end

    if i3dNode and i3dNode ~= 0 then
        -- Get the base scene node from the loaded i3d
        local sceneNode = i3dNode
        local needsDelete = false

        if self.attributes.nodeIndex then
            sceneNode = I3DUtil.indexToObject(i3dNode, self.attributes.nodeIndex)
            if not sceneNode or sceneNode == 0 then
                delete(i3dNode)
                return
            end
            needsDelete = true -- Only delete if we extracted a sub-node
        end

        -- Find the AnimCharSet node (skeleton root) BEFORE any modifications
        local animCharSetNode = nil
        if self.attributes.animCharSetNode then
            animCharSetNode = I3DUtil.indexToObject(i3dNode, self.attributes.animCharSetNode)
        end

        -- Find the shape node for rendering
        local birdNode = sceneNode
        if self.attributes.shapeNodeIndex then
            local shapeNode = I3DUtil.indexToObject(i3dNode, self.attributes.shapeNodeIndex)
            if shapeNode and shapeNode ~= 0 then
                birdNode = shapeNode
            end
        end

        -- Set visibility BEFORE linking (while references are still valid)
        if birdNode and birdNode ~= 0 then
            setVisibility(birdNode, true)
        end

        -- Link to our root node
        link(self.rootNode, sceneNode)

        -- If we extracted a sub-node, delete the temporary root
        if needsDelete and i3dNode ~= sceneNode then
            delete(i3dNode)
        end

        -- After linking, store the nodes (they are now valid children of our rootNode)
        self.visualNode = birdNode
        self.sceneNode = sceneNode

        self:setupAnimations(animCharSetNode or sceneNode)
    end
end

---
-- Get current world position of the bird
-- @return x, y, z: Current position
---
function SimpleBirdDirect:getCurrentPosition()
    return getWorldTranslation(self.rootNode)
end

---
-- Setup AnimCharacterSet animations (skeletal animations)
-- @param animNode: The node containing the AnimCharacterSet
---
function SimpleBirdDirect:setupAnimations(animNode)
    if not animNode or animNode == 0 then
        return
    end

    local testAnimCharSet = getAnimCharacterSet(animNode)
    if testAnimCharSet and testAnimCharSet ~= 0 then
        self.animCharSet = testAnimCharSet
    else
        return
    end

    local animName = "fly"
    if self.pendingAnimName then
        animName = self.pendingAnimName
        self.pendingAnimName = nil
    elseif self.stateMachine and self.stateMachine.getCurrentStateAnimation then
        animName = self.stateMachine:getCurrentStateAnimation()
    end

    self:setAnimationByName(animName)
end

---
-- Set animation by name using loaded attributes
-- @param animationName: Name of animation from attributes (e.g., "fly", "flyUp", "idleEat")
---
function SimpleBirdDirect:setAnimationByName(animationName)
    local anim = self.attributes.animations[animationName]
    if not anim then
        return
    end

    -- If model not loaded yet, store as pending animation
    if not self.animCharSet then
        self.pendingAnimName = animationName
        return
    end

    -- AnimCharacterSet animation - use frame-based manual scrubbing
    if self.animCharSet and entityExists(self.animCharSet) then
        if anim.startFrame and anim.endFrame then
            -- Get clip duration and calculate ms per frame (24 FPS = 41.67ms/frame)
            self.clipDuration = getAnimClipDuration(self.animCharSet, 0)
            local msPerFrame = 1000.0 / 24.0 -- 24 FPS

            -- Calculate time positions
            local startTimeMs = anim.startFrame * msPerFrame
            local endTimeMs = anim.endFrame * msPerFrame

            -- Setup animation for manual scrubbing (BaleWrapper pattern)
            clearAnimTrackClip(self.animCharSet, 0)
            assignAnimTrackClip(self.animCharSet, 0, 0)
            setAnimTrackLoopState(self.animCharSet, 0, false) -- Disable auto-looping

            -- Store animation parameters (in MILLISECONDS)
            self.animationStartTime = startTimeMs
            self.animationEndTime = endTimeMs
            self.animationTime = startTimeMs
            self.animationSpeed = anim.speed or 1.0
            self.currentAnimName = animationName

            -- Set initial frame
            enableAnimTrack(self.animCharSet, 0)
            setAnimTrackTime(self.animCharSet, 0, startTimeMs, true)
            disableAnimTrack(self.animCharSet, 0)
        end
    end
end

---
-- Animation name constants (for convenience)
-- Use bird:setAnimationByName() with these
---
-- Flapping flight (active, high energy)
SimpleBirdDirect.ANIM_FLY = "fly"                       -- FlapForward: Active flying/flapping
SimpleBirdDirect.ANIM_FLY_UP = "flyUp"                  -- FlapUp: Flying upward
SimpleBirdDirect.ANIM_FLY_DOWN_FLAP = "flyDownFlapping" -- FlapDown: Descending with flapping
SimpleBirdDirect.ANIM_FLY_RIGHT = "flyRight"            -- FlapRight: Banking right
SimpleBirdDirect.ANIM_FLY_LEFT = "flyLeft"              -- FlapLeft: Banking left

-- Gliding (smooth, less energy)
SimpleBirdDirect.ANIM_GLIDE = "glide"          -- GlideForward: Smooth gliding
SimpleBirdDirect.ANIM_GLIDE_UP = "glideUp"     -- GlideUp: Rising glide
SimpleBirdDirect.ANIM_GLIDE_DOWN = "glideDown" -- GlideDown: Descending glide

-- Soaring (long distance smooth flight)
SimpleBirdDirect.ANIM_SOAR = "soar" -- Soar: Long smooth flight

-- Hovering (in place)
SimpleBirdDirect.ANIM_HOVER = "hover"          -- Hover: Hovering in place
SimpleBirdDirect.ANIM_HOVER_UP = "hoverUp"     -- HoverUp: Rising hover
SimpleBirdDirect.ANIM_HOVER_DOWN = "hoverDown" -- HoverDown: Descending hover

-- Ground animations
SimpleBirdDirect.ANIM_IDLE_EAT = "idleEat" -- Eat: Eating on ground
SimpleBirdDirect.ANIM_WALK = "walk"        -- WalkForward: Walking on ground

---
-- Move to target using straight line (legacy method)
-- @param x, y, z: Target position
-- @param speed: Movement speed in m/s
---
function SimpleBirdDirect:moveToTarget(x, y, z, speed)
    self.targetX = x
    self.targetY = y
    self.targetZ = z
    self.moveSpeed = speed or self.moveSpeed
    self.hasTarget = true
    self.isMoving = true
    self.usingCurvedPath = false
    self.curvedPath = nil

    return true
end

---
-- Move to target using curved path (natural bird flight)
-- @param x, y, z: Target position
-- @param speed: Movement speed in m/s
-- @param curvature: Curve strength 0.0-1.0 (default 0.5)
---
function SimpleBirdDirect:moveToCurved(x, y, z, speed, curvature)
    curvature = curvature or 0.5

    local currX, currY, currZ = self:getCurrentPosition()

    -- Create curved path from current position to target, passing current flight direction
    self.curvedPath = CurvedPathPlanner.new(currX, currY, currZ, x, y, z, curvature,
        self.currentDirX, self.currentDirY, self.currentDirZ)
    self.pathDistance = 0

    self.targetX = x
    self.targetY = y
    self.targetZ = z
    self.moveSpeed = speed or self.moveSpeed
    self.hasTarget = true
    self.isMoving = true
    self.usingCurvedPath = true

    return true
end

function SimpleBirdDirect:update(dt)
    if self.stateMachine then
        self.stateMachine:update(dt)
    end

    if self.animCharSet and self.animCharSet ~= 0 and self.clipDuration > 0 and self.animationEndTime > self.animationStartTime then
        self.animationTime = self.animationTime + (dt * self.animationSpeed)

        -- Loop animation when it reaches the end
        local animDuration = self.animationEndTime - self.animationStartTime
        while self.animationTime >= self.animationEndTime do
            self.animationTime = self.animationTime - animDuration
        end

        if self.animationTime < self.animationStartTime then
            self.animationTime = self.animationStartTime
        end

        -- Manual scrubbing: enable -> set time -> disable each frame
        enableAnimTrack(self.animCharSet, 0)
        setAnimTrackTime(self.animCharSet, 0, self.animationTime, true)
        disableAnimTrack(self.animCharSet, 0)
    end

    if not self.hasTarget or not self.isMoving then
        return
    end

    local dtSeconds = dt / 1000

    -- Movement along curved path
    if self.usingCurvedPath and self.curvedPath then
        local moveDistance = self.moveSpeed * dtSeconds
        self.pathDistance = self.pathDistance + moveDistance

        local newX, newY, newZ, completed = self.curvedPath:getPositionAtDistance(self.pathDistance)

        local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, newX, newY, newZ)
        local minHeight = terrainY + self.flyHeight
        if newY < minHeight then
            newY = minHeight
        end

        setWorldTranslation(self.rootNode, newX, newY, newZ)

        -- Orient the bird using tangent of the curve (only while moving)
        -- Rotate sceneNode (parent) instead of visualNode to override animation
        if self.sceneNode and not completed then
            local t = self.pathDistance / self.curvedPath:getTotalLength()
            local dx, dy, dz = self.curvedPath:getTangentAtParameter(t)

            -- Track current flight direction for smooth next-path transitions
            self.currentDirX = dx
            self.currentDirY = dy
            self.currentDirZ = dz

            if dx ~= 0 or dz ~= 0 then
                local rotY = math.atan2(dx, dz)
                local pitch = 0

                -- Only allow pitch when moving downward or level, capped for natural glide look
                if dy <= 0 then
                    local horizontalLength = math.sqrt(dx * dx + dz * dz)
                    pitch = -math.atan2(dy, horizontalLength)
                    local maxPitch = math.rad(30)
                    if pitch > maxPitch then
                        pitch = maxPitch
                    end
                end

                setRotation(self.sceneNode, pitch, rotY, 0)
            end
        end

        -- Check if reached end of path
        if completed then
            setWorldTranslation(self.rootNode, self.targetX, self.targetY, self.targetZ)
            self.hasTarget = false
            self.isMoving = false
            self.usingCurvedPath = false
            self.curvedPath = nil
            return
        end
    else
        local currentX, currentY, currentZ = self:getCurrentPosition()

        local dx = self.targetX - currentX
        local dy = self.targetY - currentY
        local dz = self.targetZ - currentZ
        local distance3D = math.sqrt(dx * dx + dy * dy + dz * dz)

        local reachedTarget = distance3D < 0.5
        if reachedTarget then
            setWorldTranslation(self.rootNode, self.targetX, self.targetY, self.targetZ)
            self.hasTarget = false
            self.isMoving = false

            return
        end

        local targetTerrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, self.targetX, 0, self
            .targetZ)
        local isGroundTarget = self.targetY < (targetTerrainY + self.flyHeight)

        local moveDistance = self.moveSpeed * dtSeconds

        -- Normalize direction
        dx = dx / distance3D
        dy = dy / distance3D
        dz = dz / distance3D

        if moveDistance > distance3D then
            moveDistance = distance3D
        end

        local newX = currentX + dx * moveDistance
        local newY = currentY + dy * moveDistance
        local newZ = currentZ + dz * moveDistance

        -- Only apply terrain clamp for non-ground targets
        if not isGroundTarget then
            local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, newX, newY, newZ)
            local minHeight = terrainY + self.flyHeight
            if newY < minHeight then
                newY = minHeight
            end
        end

        setWorldTranslation(self.rootNode, newX, newY, newZ)

        -- Orient the bird toward movement direction (only during active movement, not when landing)
        -- Check if we're about to reach target on next frame
        local willReachTarget = distance3D < 1.0 -- Within 1m of target = about to land
        local moveDX = newX - currentX
        local moveDY = newY - currentY
        local moveDZ = newZ - currentZ

        if self.sceneNode and (moveDX ~= 0 or moveDZ ~= 0) and not willReachTarget then
            -- Track current flight direction for smooth next-path transitions
            local moveLen = math.sqrt(moveDX * moveDX + moveDY * moveDY + moveDZ * moveDZ)
            if moveLen > 0.001 then
                self.currentDirX = moveDX / moveLen
                self.currentDirY = moveDY / moveLen
                self.currentDirZ = moveDZ / moveLen
            end

            local rotY = math.atan2(moveDX, moveDZ)
            local pitch = 0

            -- Only allow pitch when moving downward or level, capped for natural glide look
            if moveDY <= 0 then
                local horizontalLength = math.sqrt(moveDX * moveDX + moveDZ * moveDZ)
                pitch = -math.atan2(moveDY, horizontalLength)
                local maxPitch = math.rad(30)
                if pitch > maxPitch then
                    pitch = maxPitch
                end
            end
            
            setRotation(self.sceneNode, pitch, rotY, 0)
        end
    end
end

function SimpleBirdDirect:delete()
    if self.isLoading and self.loadRequestId then
        g_i3DManager:cancelStreamI3DFile(self.loadRequestId)
    end

    if self.loadRequestId then
        g_i3DManager:releaseSharedI3DFile(self.loadRequestId)
    end

    if self.visualNode and self.visualNode ~= 0 then
        delete(self.visualNode)
        self.visualNode = nil
    end

    if self.rootNode and self.rootNode ~= 0 then
        delete(self.rootNode)
        self.rootNode = nil
    end

    self.stateMachine = nil
    self.curvedPath = nil
end

function SimpleBirdDirect:getIsMoving()
    return self.isMoving
end

function SimpleBirdDirect:cancelTarget()
    self.hasTarget = false
    self.isMoving = false
    self.usingCurvedPath = false
    self.curvedPath = nil
end

---
-- Get the state machine for this bird
-- @return BirdStateMachine instance
---
function SimpleBirdDirect:getStateMachine()
    return self.stateMachine
end

---
-- Set the bird's rotation to look downward at a specific pitch angle
-- @param pitchDegrees: Pitch angle in degrees (negative = looking down)
---
function SimpleBirdDirect:setPitchAngle(pitchDegrees)
    if not self.visualNode then
        return
    end

    local pitchRadians = math.rad(pitchDegrees)

    if self.visualNode then
        local _, currentYaw, _ = getRotation(self.visualNode)
        setRotation(self.visualNode, pitchRadians, currentYaw, 0)
    end
end

---
-- Request this bird to enter despawning state
---
function SimpleBirdDirect:requestDespawn()
    if self.stateMachine then
        self.stateMachine:requestDespawn()
    end
end
