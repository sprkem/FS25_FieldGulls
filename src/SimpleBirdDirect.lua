---
-- SimpleBirdDirect: Direct i3d management without wildlife system
-- Loads bird i3d directly and manages movement manually
-- Now with state machine and curved path support
---

SimpleBirdDirect = {}
local SimpleBirdDirect_mt = Class(SimpleBirdDirect)
SimpleBirdDirect.dir = g_currentModDirectory

---
-- Load bird attributes from XML file
-- @param xmlFile: XML file handle (from loadXMLFile)
-- @param key: Base XML key path
-- @return attributes table with filename, nodeIndex, shaderNodeIndex, and animations
---
function SimpleBirdDirect.loadAttributesFromXML(xmlFile, key)
    -- Load basic asset info
    local filename = getXMLString(xmlFile, key .. ".asset#filename")
    local modName = getXMLString(xmlFile, key .. ".asset#modName")
    
    -- Construct full path: if modName is specified, use DLC mod directory
    if modName and modName ~= "" and g_modNameToDirectory and g_modNameToDirectory[modName] then
        filename = g_modNameToDirectory[modName] .. filename
    end
    
    local attributes = {
        filename = filename,
        nodeIndex = getXMLString(xmlFile, key .. ".asset#node"),
        shapeNodeIndex = getXMLString(xmlFile, key .. ".animation#shapeNode"),
        shaderNodeIndex = getXMLString(xmlFile, key .. ".animation#shaderNode"),
        animCharSetNode = getXMLString(xmlFile, key .. ".animation#animCharSetNode"),
        animations = {},
        -- Behavior settings (with defaults)
        groundIdleTimeMin = getXMLFloat(xmlFile, key .. ".behavior#groundIdleTimeMin") or 0.5,
        groundIdleTimeMax = getXMLFloat(xmlFile, key .. ".behavior#groundIdleTimeMax") or 2.0
    }

    -- Load all animation definitions (supports opcode, clipName, or frame range)
    local x = 0
    while true do
        local animKey = string.format("%s.animation.animation(%d)", key, x)
        if not hasXMLProperty(xmlFile, animKey) then
            break
        end

        local stateName = getXMLString(xmlFile, animKey .. "#stateName")
        local anim = {
            name = stateName,
            opcode = getXMLInt(xmlFile, animKey .. "#opcode"),
            clipName = getXMLString(xmlFile, animKey .. "#clipName"),
            speed = getXMLFloat(xmlFile, animKey .. "#speed"),
            transitionTime = getXMLFloat(xmlFile, animKey .. "#transitionTime") * 1000,
            startFrame = getXMLInt(xmlFile, animKey .. "#startFrame"),
            endFrame = getXMLInt(xmlFile, animKey .. "#endFrame")
        }
        attributes.animations[stateName] = anim
        x = x + 1
    end
    return attributes
end

function SimpleBirdDirect.new(x, y, z, hotspot)
    local self = setmetatable({}, SimpleBirdDirect_mt)

    self.hotspot = hotspot
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

    -- Visual node (will be loaded async)
    self.visualNode = nil
    self.shaderNode = nil
    self.animCharSet = nil
    self.isLoading = false
    self.loadRequestId = nil
    
    -- Animation state tracking
    self.currentAnimName = nil

    -- Load bird attributes from XML (no schema needed with old-style API)
    local xmlFilename = Utils.getFilename("data/seagull.xml", SimpleBirdDirect.dir)
    local xmlFile = loadXMLFile("BirdSpeciesTemp", xmlFilename)
    

    if xmlFile and xmlFile ~= 0 then
        self.attributes = SimpleBirdDirect.loadAttributesFromXML(xmlFile, "species")
        delete(xmlFile)
    else
        print("Error: Failed to load bird species XML from: " .. tostring(xmlFilename))
        self.attributes = nil
        return nil
    end

    -- Initialize state machine
    self.stateMachine = BirdStateMachine.new(self)

    -- Start loading the bird model
    self:loadVisualModel()


    return self
end



function SimpleBirdDirect:loadVisualModel()
    if self.isLoading then
        return
    end

    self.isLoading = true

    -- Use filename from attributes (loaded from XML or fallback)
    local modelPath = self.attributes.filename

    -- Using async loading for better performance
    self.loadRequestId = g_i3DManager:loadSharedI3DFileAsync(
        modelPath,
        false, -- callOnCreate
        false, -- addToPhysics
        self.onBirdModelLoaded,
        self,
        nil
    )
end

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
                print("[SimpleBirdDirect] ERROR: Could not find node at index " .. tostring(self.attributes.nodeIndex))
                delete(i3dNode)
                return
            end
            needsDelete = true  -- Only delete if we extracted a sub-node
        end

        -- Find the AnimCharSet node (skeleton root) and shape node BEFORE any modifications
        local animCharSetNode = nil
        if self.attributes.animCharSetNode then
            animCharSetNode = I3DUtil.indexToObject(i3dNode, self.attributes.animCharSetNode)
            if animCharSetNode and animCharSetNode ~= 0 then
                print("[SimpleBirdDirect] Found AnimCharSet node at index " .. tostring(self.attributes.animCharSetNode))
            end
        end

        -- Find the shape node for rendering
        local birdNode = sceneNode
        if self.attributes.shapeNodeIndex then
            local shapeNode = I3DUtil.indexToObject(i3dNode, self.attributes.shapeNodeIndex)
            if shapeNode and shapeNode ~= 0 then
                birdNode = shapeNode
                print("[SimpleBirdDirect] Found shape node at index " .. tostring(self.attributes.shapeNodeIndex))
            else
                print("[SimpleBirdDirect] WARNING: Could not find shape at index " .. tostring(self.attributes.shapeNodeIndex))
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
        
        -- Setup animations using the skeleton node
        self:setupAnimations(animCharSetNode or sceneNode)
    end
end

function SimpleBirdDirect:getCurrentPosition()
    return getWorldTranslation(self.rootNode)
end

---
-- Setup animations - try shader-based first, fall back to AnimCharSet
-- @param animNode: The node containing the AnimCharSet or shader system
---
function SimpleBirdDirect:setupAnimations(animNode)
    if not animNode or animNode == 0 then
        print("[SimpleBirdDirect] WARNING: No animation node provided")
        return
    end

    -- Check if we have opcode-based animations (shader system)
    local hasOpcodes = false
    for _, animData in pairs(self.attributes.animations) do
        if animData.opcode then
            hasOpcodes = true
            break
        end
    end
    
    -- Try shader-based animations first (opcode system)
    if hasOpcodes then
        self:setupShaderAnimations(animNode)
    else
        -- Fall back to AnimCharSet system
        self:setupAnimCharSetAnimations(animNode)
    end
end

---
-- Setup shader-based animations (opcode system)
---
function SimpleBirdDirect:setupShaderAnimations(birdNode)
    -- Get shader node from loaded attributes
    self.shaderNode = I3DUtil.indexToObject(birdNode, self.attributes.shaderNodeIndex)
    
    if not self.shaderNode or self.shaderNode == 0 then
        print("[SimpleBirdDirect] ERROR: Shader node not found at index " .. tostring(self.attributes.shaderNodeIndex))
        return
    end
    
    print("[SimpleBirdDirect] Using shader-based animations (opcode system)")
    
    -- Set animation offset for variety
    setShaderParameter(self.shaderNode, "animOffset", math.random(), nil, nil, nil, false)
    
    -- Start with the fly animation
    self:setAnimationByName("fly")
end

---
-- Setup AnimCharacterSet animations (skeletal animations)
-- @param animNode: The node containing the AnimCharacterSet
---
function SimpleBirdDirect:setupAnimCharSetAnimations(animNode)
    if not animNode or animNode == 0 then
        print("[SimpleBirdDirect] ERROR: No animation node provided")
        return
    end

    -- Get the AnimCharSet from the provided node
    local testAnimCharSet = getAnimCharacterSet(animNode)
    if testAnimCharSet and testAnimCharSet ~= 0 then
        self.animCharSet = testAnimCharSet
        print("[SimpleBirdDirect] Found AnimCharSet on skeleton node")
    else
        print("[SimpleBirdDirect] ERROR: No AnimCharSet found on provided node")
        return
    end
    
    print("[SimpleBirdDirect] Using AnimCharSet system")
    
    -- Diagnostic: Try to enumerate available animation clips (if API supports it)
    local success, numClips = pcall(function() return getNumOfClips(self.animCharSet) end)
    if success and numClips then
        print(string.format("[SimpleBirdDirect] AnimCharSet has %d clip(s)", numClips))
        
        for clipIdx = 0, numClips - 1 do
            local clipSuccess, clipName = pcall(function() return getClipName(self.animCharSet, clipIdx) end)
            if clipSuccess and clipName then
                print(string.format("[SimpleBirdDirect]   Clip[%d]: '%s'", clipIdx, clipName))
            end
        end
    else
        print("[SimpleBirdDirect] Cannot enumerate clips (API not available) - will check individual clips")
    end
    
    -- Check if we're using named clips or frame-based animations
    local usingNamedClips = false
    local usingFrameBased = false
    
    for stateName, animData in pairs(self.attributes.animations) do
        if animData.clipName then
            usingNamedClips = true
        elseif animData.startFrame or animData.endFrame then
            usingFrameBased = true
        end
    end
    
    if usingNamedClips then
        print("[SimpleBirdDirect] Configuration uses named animation clips")
        -- Verify all clips are available
        local allClipsFound = true
        for stateName, animData in pairs(self.attributes.animations) do
            if animData.clipName then
                local clipIndex = getAnimClipIndex(self.animCharSet, animData.clipName)
                if clipIndex >= 0 then
                    print(string.format("[SimpleBirdDirect]   Found '%s' -> '%s'", stateName, animData.clipName))
                else
                    print(string.format("[SimpleBirdDirect]   MISSING '%s' -> '%s'", stateName, animData.clipName))
                    allClipsFound = false
                end
            end
        end
        
        if not allClipsFound then
            print("[SimpleBirdDirect] WARNING: Some animation clips are missing - may need frame-based approach")
        else
            -- Start with the fly animation if all clips found
            self:setAnimationByName("fly")
        end
    elseif usingFrameBased then
        print("[SimpleBirdDirect] Configuration uses frame-based animations")
        -- TODO: Implement frame-based animation support
    else
        print("[SimpleBirdDirect] WARNING: No animation configuration found")
    end
end

---
-- Set animation by name using loaded attributes
-- @param animationName: Name of animation from attributes (e.g., "fly", "flyUp", "idleEat")
---
function SimpleBirdDirect:setAnimationByName(animationName)
    local anim = self.attributes.animations[animationName]
    if not anim then
        print("[SimpleBirdDirect] Animation not found: " .. tostring(animationName))
        return
    end

    -- Shader-based animation (opcode system)
    if self.shaderNode then
        -- Set animation opcode and speed
        setShaderParameter(self.shaderNode, "indicesAndBlend", anim.opcode, 0, 0, 0, false)
        setShaderParameter(self.shaderNode, "speeds", anim.speed, 0, 0, 0, false)
        
        -- Store current animation
        self.currentAnimName = animationName
    -- AnimCharacterSet animation - use named clip
    elseif self.animCharSet and entityExists(self.animCharSet) then
        -- Frame-based animation support
        if anim.startFrame and anim.endFrame then
            -- Assume only one clip (index 0)
            clearAnimTrackClip(self.animCharSet, 0)
            assignAnimTrackClip(self.animCharSet, 0, 0)
            setAnimTrackLoopState(self.animCharSet, 0, true)
            -- Calculate normalized time for startFrame
            local startFrame = anim.startFrame
            local endFrame = anim.endFrame
            local totalFrames = endFrame - startFrame
            -- Set the animation to the start frame
            setAnimTrackTime(self.animCharSet, 0, startFrame / 30, true) -- assuming 30 FPS
            enableAnimTrack(self.animCharSet, 0)
            -- Store current animation
            self.currentAnimName = animationName
        elseif anim.clipName then
            local clipIndex = getAnimClipIndex(self.animCharSet, anim.clipName)
            if clipIndex >= 0 then
                clearAnimTrackClip(self.animCharSet, 0)
                assignAnimTrackClip(self.animCharSet, 0, clipIndex)
                setAnimTrackLoopState(self.animCharSet, 0, true)
                setAnimTrackTime(self.animCharSet, 0, 0, true)
                enableAnimTrack(self.animCharSet, 0)
                self.currentAnimName = animationName
            else
                print(string.format("[SimpleBirdDirect] WARNING: Animation clip '%s' not found for animation '%s'", anim.clipName, animationName))
            end
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
SimpleBirdDirect.ANIM_GLIDE = "glide"                   -- GlideForward: Smooth gliding
SimpleBirdDirect.ANIM_GLIDE_UP = "glideUp"              -- GlideUp: Rising glide
SimpleBirdDirect.ANIM_GLIDE_DOWN = "glideDown"          -- GlideDown: Descending glide

-- Soaring (long distance smooth flight)
SimpleBirdDirect.ANIM_SOAR = "soar"                     -- Soar: Long smooth flight

-- Hovering (in place)
SimpleBirdDirect.ANIM_HOVER = "hover"                   -- Hover: Hovering in place
SimpleBirdDirect.ANIM_HOVER_UP = "hoverUp"              -- HoverUp: Rising hover
SimpleBirdDirect.ANIM_HOVER_DOWN = "hoverDown"          -- HoverDown: Descending hover

-- Ground animations
SimpleBirdDirect.ANIM_IDLE_EAT = "idleEat"              -- Eat: Eating on ground
SimpleBirdDirect.ANIM_WALK = "walk"                     -- WalkForward: Walking on ground

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

    -- Create curved path from current position to target
    self.curvedPath = CurvedPathPlanner.new(currX, currY, currZ, x, y, z, curvature)
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
    -- Update state machine first
    if self.stateMachine then
        self.stateMachine:update(dt)
    end

    if not self.hasTarget or not self.isMoving then
        return
    end

    local dtSeconds = dt / 1000

    -- Movement along curved path
    if self.usingCurvedPath and self.curvedPath then
        -- Calculate distance to move this frame
        local moveDistance = self.moveSpeed * dtSeconds
        self.pathDistance = self.pathDistance + moveDistance

        -- Get position on curve
        local newX, newY, newZ, completed = self.curvedPath:getPositionAtDistance(self.pathDistance)

        -- Ensure bird doesn't go below terrain + minimum height
        local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, newX, newY, newZ)
        local minHeight = terrainY + self.flyHeight
        if newY < minHeight then
            newY = minHeight
        end

        setWorldTranslation(self.rootNode, newX, newY, newZ)

        -- Orient the bird using tangent of the curve
        if self.visualNode then
            local t = self.pathDistance / self.curvedPath:getTotalLength()
            local dx, dy, dz = self.curvedPath:getTangentAtParameter(t)

            if dx ~= 0 or dz ~= 0 then
                local rotY = math.atan2(dx, dz)
                -- Add pitch based on vertical component
                local horizontalLength = math.sqrt(dx * dx + dz * dz)
                local pitch = -math.atan2(dy, horizontalLength)
                setRotation(self.visualNode, pitch, rotY, 0)
            end
        end

        -- Check if reached end of path
        if completed then
            setWorldTranslation(self.rootNode, self.targetX, self.targetY, self.targetZ)
            self.hasTarget = false
            self.isMoving = false
            self.usingCurvedPath = false
            self.curvedPath = nil

            -- Notify state machine or hotspot that we reached the target
            -- State machine will handle what to do next
            return
        end
    else
        -- Straight line movement (legacy)
        local currentX, currentY, currentZ = self:getCurrentPosition()

        -- Calculate direction to target
        local dx = self.targetX - currentX
        local dy = self.targetY - currentY
        local dz = self.targetZ - currentZ
        local distance3D = math.sqrt(dx * dx + dy * dy + dz * dz)

        -- Check if we've reached the target (simple 3D distance check)
        if distance3D < 0.5 then
            setWorldTranslation(self.rootNode, self.targetX, self.targetY, self.targetZ)
            self.hasTarget = false
            self.isMoving = false

            return
        end

        -- Check if we're diving to ground target
        local targetTerrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, self.targetX, 0, self
            .targetZ)
        local isGroundTarget = self.targetY < (targetTerrainY + self.flyHeight)

        -- Normal straight-line movement
        local moveDistance = self.moveSpeed * dtSeconds

        -- Normalize direction
        dx = dx / distance3D
        dy = dy / distance3D
        dz = dz / distance3D

        -- Clamp to remaining distance
        if moveDistance > distance3D then
            moveDistance = distance3D
        end

        local newX = currentX + dx * moveDistance
        local newY = currentY + dy * moveDistance
        local newZ = currentZ + dz * moveDistance

        local beforeClamp = newY
        local wasClampApplied = false

        -- Only apply terrain clamp for non-ground targets
        if not isGroundTarget then
            local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, newX, newY, newZ)
            local minHeight = terrainY + self.flyHeight
            if newY < minHeight then
                newY = minHeight
                wasClampApplied = true
            end
        end

        setWorldTranslation(self.rootNode, newX, newY, newZ)

        -- Orient the bird toward movement direction (using actual movement delta)
        local moveDX = newX - currentX
        local moveDY = newY - currentY
        local moveDZ = newZ - currentZ

        if self.visualNode and (moveDX ~= 0 or moveDZ ~= 0) then
            local rotY = math.atan2(moveDX, moveDZ)
            local horizontalLength = math.sqrt(moveDX * moveDX + moveDZ * moveDZ)
            local pitch = -math.atan2(moveDY, horizontalLength)
            setRotation(self.visualNode, pitch, rotY, 0)
        end
    end
end

function SimpleBirdDirect:delete()
    -- Cancel loading if still in progress
    if self.isLoading and self.loadRequestId then
        g_i3DManager:cancelStreamI3DFile(self.loadRequestId)
    end

    -- Release the shared i3d file if loaded
    if self.loadRequestId then
        g_i3DManager:releaseSharedI3DFile(self.loadRequestId)
    end

    -- Delete visual node
    if self.visualNode and self.visualNode ~= 0 then
        delete(self.visualNode)
        self.visualNode = nil
    end

    -- Delete root node
    if self.rootNode and self.rootNode ~= 0 then
        delete(self.rootNode)
        self.rootNode = nil
    end

    -- Clean up state machine
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

    -- Convert degrees to radians
    local pitchRadians = math.rad(pitchDegrees)

    -- Get current rotation to preserve yaw (horizontal direction)
    if self.visualNode then
        local _, currentYaw, _ = getRotation(self.visualNode)

        -- Set new rotation with specified pitch
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
