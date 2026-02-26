---
-- SimpleBirdDirect: Direct i3d management without wildlife system
-- Loads crow i3d directly and manages movement manually
-- Now with state machine and curved path support
---

SimpleBirdDirect = {}
local SimpleBirdDirect_mt = Class(SimpleBirdDirect)

---
-- Load bird attributes from XML file (similar to WildlifeInstanceGraphics.loadAttributesTable)
-- @param xmlFile: XML file handle (from loadXMLFile)
-- @param key: Base XML key path
-- @return attributes table with filename, nodeIndex, shaderNodeIndex, and animations
---
function SimpleBirdDirect.loadAttributesFromXML(xmlFile, key)
    local attributes = {
        filename = getXMLString(xmlFile, key .. ".asset#filename"),
        nodeIndex = getXMLString(xmlFile, key .. ".asset#node") or "0",
        shaderNodeIndex = getXMLString(xmlFile, key .. ".animation#shaderNode") or "0",
        animations = {}
    }

    -- Load all animation definitions
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
            speed = getXMLFloat(xmlFile, animKey .. "#speed"),
            transitionTime = getXMLFloat(xmlFile, animKey .. "#transitionTime") * 1000
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
    self.isLoading = false
    self.loadRequestId = nil

    -- Animation offset for variety (0-1 random value)
    self.animationOffset = math.random()

    -- Load bird attributes from XML (no schema needed with old-style API)
    local xmlFilename = Utils.getFilename("data/animals/wildlife/species/crow.xml", g_currentMission.baseDirectory)
    local xmlFile = loadXMLFile("WildlifespeciesTemp", xmlFilename)

    self.attributes = SimpleBirdDirect.loadAttributesFromXML(xmlFile, "species")
    delete(xmlFile)

    -- Initialize state machine
    self.stateMachine = BirdStateMachine.new(self)

    -- Start loading the crow model
    self:loadVisualModel()


    return self
end

---
-- Create fallback attributes when XML loading is not available
-- TODO: Remove this once XML loading is implemented
---
-- function SimpleBirdDirect:createFallbackAttributes()
--     return {
--         filename = "dataS/character/animals/wild/crow/crow.i3d",
--         nodeIndex = "0",
--         shaderNodeIndex = "0",
--         animations = {
--             flyGlide = { name = "flyGlide", opcode = 0, speed = 0.4, transitionTime = 150 },
--             fly = { name = "fly", opcode = 1, speed = 4.0, transitionTime = 150 },
--             flyUp = { name = "flyUp", opcode = 1, speed = 4.0, transitionTime = 150 },
--             flyDown = { name = "flyDown", opcode = 0, speed = 0.4, transitionTime = 150 },
--             flyDownFlapping = { name = "flyDownFlapping", opcode = 1, speed = 4.0, transitionTime = 150 },
--             land = { name = "land", opcode = 2, speed = 3.0, transitionTime = 150 },
--             takeOff = { name = "takeOff", opcode = 3, speed = 4.0, transitionTime = 150 },
--             idleWalk = { name = "idleWalk", opcode = 4, speed = 2.0, transitionTime = 300 },
--             idleEat = { name = "idleEat", opcode = 5, speed = 1.0, transitionTime = 250 },
--             idleAttention = { name = "idleAttention", opcode = 6, speed = 0.5, transitionTime = 150 }
--         }
--     }
-- end

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
        self.onCrowModelLoaded,
        self,
        nil
    )
end

function SimpleBirdDirect:onCrowModelLoaded(i3dNode, failedReason, args)
    self.isLoading = false

    if failedReason ~= 0 then
        return
    end

    if i3dNode and i3dNode ~= 0 then
        -- Get the visual node and shader node from the loaded i3d using loaded attributes
        local birdNode = I3DUtil.indexToObject(i3dNode, self.attributes.nodeIndex)
        local shaderNode = I3DUtil.indexToObject(i3dNode, self.attributes.shaderNodeIndex)

        if birdNode and birdNode ~= 0 then
            -- Link to our root node
            link(self.rootNode, birdNode)
            delete(i3dNode) -- Delete the temporary root

            -- Configure visibility and scale
            setVisibility(birdNode, true)
            setScale(birdNode, 0.8, 0.8, 0.8)

            self.visualNode = birdNode
            self.shaderNode = shaderNode

            -- Setup initial fly animation using shader parameters
            if self.shaderNode ~= nil then
                -- Set animation offset first (required for animation system)
                setShaderParameter(self.shaderNode, "animOffset", self.animationOffset, 0, 0, 0, false)

                -- Start with active fly animation using loaded attributes
                local flyAnim = self.attributes.animations.fly
                if flyAnim then
                    self:setAnimationByName("fly")
                end
            end
        else
            delete(i3dNode)
        end
    end
end

function SimpleBirdDirect:getCurrentPosition()
    return getWorldTranslation(self.rootNode)
end

---
-- Set animation by name using loaded attributes
-- @param animationName: Name of animation from attributes (e.g., "fly", "flyUp", "idleEat")
---
function SimpleBirdDirect:setAnimationByName(animationName)
    if not self.shaderNode then
        return
    end

    local anim = self.attributes.animations[animationName]
    if not anim then
        return
    end

    -- Set animation opcode and speed from loaded attributes
    setShaderParameter(self.shaderNode, "indicesAndBlend", anim.opcode, 0, 0, 0, false)
    setShaderParameter(self.shaderNode, "speeds", anim.speed, 0, 0, 0, false)
end

---
-- Set animation using shader parameters (legacy method for direct opcode/speed control)
-- @param opcode: Animation opcode
-- @param speed: Animation speed
---
function SimpleBirdDirect:setAnimation(opcode, speed)
    if not self.shaderNode then
        return
    end

    -- Set animation opcode
    setShaderParameter(self.shaderNode, "indicesAndBlend", opcode, 0, 0, 0, false)
    -- Set animation speed
    setShaderParameter(self.shaderNode, "speeds", speed, 0, 0, 0, false)
end

---
-- Animation name constants (for convenience)
-- Use bird:setAnimationByName() with these
---
SimpleBirdDirect.ANIM_FLY_GLIDE = "flyGlide"            -- Slow gliding
SimpleBirdDirect.ANIM_FLY = "fly"                       -- Active flying/flapping
SimpleBirdDirect.ANIM_FLY_UP = "flyUp"                  -- Flying upward
SimpleBirdDirect.ANIM_FLY_DOWN = "flyDown"              -- Gliding down
SimpleBirdDirect.ANIM_FLY_DOWN_FLAP = "flyDownFlapping" -- Descending with flapping
SimpleBirdDirect.ANIM_LAND = "land"                     -- Landing
SimpleBirdDirect.ANIM_TAKE_OFF = "takeOff"              -- Taking off
SimpleBirdDirect.ANIM_IDLE_WALK = "idleWalk"            -- Walking on ground
SimpleBirdDirect.ANIM_IDLE_EAT = "idleEat"              -- Eating on ground
SimpleBirdDirect.ANIM_IDLE_ATTENTION = "idleAttention"  -- Alert/looking around

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
    local _, currentYaw, _ = getRotation(self.visualNode)

    -- Set new rotation with specified pitch
    setRotation(self.visualNode, pitchRadians, currentYaw, 0)
end

---
-- Request this bird to enter despawning state
---
function SimpleBirdDirect:requestDespawn()
    if self.stateMachine then
        self.stateMachine:requestDespawn()
    end
end
