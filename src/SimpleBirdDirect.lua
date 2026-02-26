---
-- SimpleBirdDirect: Direct i3d management without wildlife system
-- Loads crow i3d directly and manages movement manually
-- Now with state machine and curved path support
---

SimpleBirdDirect = {}
local SimpleBirdDirect_mt = Class(SimpleBirdDirect)

function SimpleBirdDirect.new(x, y, z, hotspot)
    local self = setmetatable({}, SimpleBirdDirect_mt)
    
    self.hotspot = hotspot
    self.isDespawning = false
    self.despawnStartTime = 0
    
    -- Movement configuration
    self.moveSpeed = 8.0  -- meters per second
    self.turnSpeed = 3.0  -- radians per second
    self.flyHeight = 0.3  -- meters above ground
    
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
    self.curvedPath = nil  -- CurvedPathPlanner instance
    self.pathDistance = 0  -- Distance traveled along current path
    self.usingCurvedPath = false
    
    -- Visual node (will be loaded async)
    self.visualNode = nil
    self.shaderNode = nil
    self.isLoading = false
    self.loadRequestId = nil
    
    -- Animation offset for variety (0-1 random value)
    self.animationOffset = math.random()
    
    -- Initialize state machine
    self.stateMachine = BirdStateMachine.new(self)
    
    -- Start loading the crow model
    self:loadVisualModel()
    
    print(string.format("[SimpleBirdDirect] Created at (%.2f, %.2f, %.2f) with state machine", x, y, z))
    
    return self
end

function SimpleBirdDirect:loadVisualModel()
    if self.isLoading then
        return
    end
    
    self.isLoading = true
    
    -- Load crow model asynchronously
    local crowModelPath = "dataS/character/animals/wild/crow/crow.i3d"
    
    -- Using async loading for better performance
    self.loadRequestId = g_i3DManager:loadSharedI3DFileAsync(
        crowModelPath,
        false,  -- callOnCreate
        false,  -- addToPhysics
        self.onCrowModelLoaded,
        self,
        nil
    )
    
    print("[SimpleBirdDirect] Started loading crow model")
end

function SimpleBirdDirect:onCrowModelLoaded(i3dNode, failedReason, args)
    self.isLoading = false
    
    if failedReason ~= 0 then
        print(string.format("[SimpleBirdDirect] ERROR: Failed to load crow model, reason: %d", failedReason))
        return
    end
    
    if i3dNode and i3dNode ~= 0 then
        -- Get the visual node and shader node from the loaded i3d (before we modify it)
        local crowNode = I3DUtil.indexToObject(i3dNode, "0")  -- Index "0" is the crow mesh
        local shaderNode = I3DUtil.indexToObject(i3dNode, "0")  -- Shader node is the same as visual node
        
        if crowNode and crowNode ~= 0 then
            -- Link to our root node
            link(self.rootNode, crowNode)
            delete(i3dNode)  -- Delete the temporary root
            
            -- Configure visibility and scale
            setVisibility(crowNode, true)
            setScale(crowNode, 0.8, 0.8, 0.8)
            
            self.visualNode = crowNode
            self.shaderNode = shaderNode
            
            -- Setup initial fly animation using shader parameters
            if self.shaderNode ~= nil then
                -- Set animation offset first (required for animation system)
                setShaderParameter(self.shaderNode, "animOffset", self.animationOffset, 0, 0, 0, false)
                
                -- Start with active fly animation (opcode 1, speed 4.0)
                self:setAnimation(1, 4.0)
                
                if math.random() < 0.1 then
                    print(string.format("[SimpleBirdDirect] Fly animation setup with offset %.2f", self.animationOffset))
                end
            else
                print("[SimpleBirdDirect] WARNING: Shader node not found in crow model")
            end
            
            print("[SimpleBirdDirect] Crow model loaded successfully")
        else
            print("[SimpleBirdDirect] ERROR: Could not get crow mesh from i3d")
            delete(i3dNode)
        end
    end
end

function SimpleBirdDirect:getCurrentPosition()
    return getWorldTranslation(self.rootNode)
end

---
-- Set animation using shader parameters
-- Based on crow.xml animation definitions
-- @param opcode: Animation opcode (0-6)
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
    -- Animation offset is set once at load, doesn't change
end

---
-- Animation presets from crow.xml
---
SimpleBirdDirect.ANIM_FLY = {opcode = 1, speed = 4.0}           -- Active flying/flapping
SimpleBirdDirect.ANIM_FLY_GLIDE = {opcode = 0, speed = 0.4}     -- Slow gliding
SimpleBirdDirect.ANIM_FLY_UP = {opcode = 1, speed = 4.0}        -- Flying upward
SimpleBirdDirect.ANIM_FLY_DOWN = {opcode = 0, speed = 0.4}      -- Gliding down
SimpleBirdDirect.ANIM_FLY_DOWN_FLAP = {opcode = 1, speed = 4.0} -- Descending with flapping
SimpleBirdDirect.ANIM_LAND = {opcode = 2, speed = 3.0}          -- Landing
SimpleBirdDirect.ANIM_TAKE_OFF = {opcode = 3, speed = 4.0}      -- Taking off
SimpleBirdDirect.ANIM_IDLE_EAT = {opcode = 5, speed = 1.0}      -- Eating on ground

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
    
    if math.random() < 0.15 then
        local currX, currY, currZ = self:getCurrentPosition()
        print(string.format("[SimpleBirdDirect] New target (straight): from (%.1f,%.1f,%.1f) to (%.1f,%.1f,%.1f) speed=%.1f", 
            currX, currY, currZ, x, y, z, self.moveSpeed))
    end
    
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
    
    if math.random() < 0.15 then
        print(string.format("[SimpleBirdDirect] New curved target: from (%.1f,%.1f,%.1f) to (%.1f,%.1f,%.1f) speed=%.1f curve=%.2f", 
            currX, currY, currZ, x, y, z, self.moveSpeed, curvature))
    end
    
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
                local horizontalLength = math.sqrt(dx*dx + dz*dz)
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
            
            if math.random() < 0.2 then
                print("[SimpleBirdDirect] Curved path completed!")
            end
            return
        end
        
        -- Occasional debug logging
        if math.random() < 0.005 then
            print(string.format("[SimpleBirdDirect] Curved movement: pos=(%.1f,%.1f,%.1f) progress=%.1f%%", 
                newX, newY, newZ, (self.pathDistance / self.curvedPath:getTotalLength()) * 100))
        end
        
    else
        -- Straight line movement (legacy)
        local currentX, currentY, currentZ = self:getCurrentPosition()
        
        -- Calculate direction to target (XZ only for main movement)
        local dx = self.targetX - currentX
        local dy = self.targetY - currentY
        local dz = self.targetZ - currentZ
        local distanceXZ = math.sqrt(dx*dx + dz*dz)
        local distance3D = math.sqrt(dx*dx + dy*dy + dz*dz)
        
        -- Check if we've reached the target
        if distanceXZ < 0.3 and math.abs(dy) < 1.0 then
            setWorldTranslation(self.rootNode, self.targetX, self.targetY, self.targetZ)
            self.hasTarget = false
            self.isMoving = false
            
            if math.random() < 0.2 then
                print("[SimpleBirdDirect] Target reached!")
            end
            return
        end
        
        -- Normalize direction
        dx = dx / distance3D
        dy = dy / distance3D
        dz = dz / distance3D
        
        -- Calculate movement for this frame
        local moveDistance = self.moveSpeed * dtSeconds
        
        -- Clamp to remaining distance
        if moveDistance > distance3D then
            moveDistance = distance3D
        end
        
        -- Update position
        local newX = currentX + dx * moveDistance
        local newY = currentY + dy * moveDistance
        local newZ = currentZ + dz * moveDistance
        
        -- Ensure bird doesn't go below terrain + minimum height
        local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, newX, newY, newZ)
        local minHeight = terrainY + self.flyHeight
        if newY < minHeight then
            newY = minHeight
        end
        
        setWorldTranslation(self.rootNode, newX, newY, newZ)
        
        -- Orient the bird toward movement direction
        if self.visualNode and (dx ~= 0 or dz ~= 0) then
            local rotY = math.atan2(dx, dz)
            local horizontalLength = math.sqrt(dx*dx + dz*dz)
            local pitch = -math.atan2(dy, horizontalLength)
            setRotation(self.visualNode, pitch, rotY, 0)
        end
        
        -- Occasional debug logging
        if math.random() < 0.005 then
            print(string.format("[SimpleBirdDirect] Straight movement: pos=(%.1f,%.1f,%.1f) target=(%.1f,%.1f,%.1f) dist=%.1f", 
                newX, newY, newZ, self.targetX, self.targetY, self.targetZ, distance3D))
        end
    end
end

function SimpleBirdDirect:delete()
    print("[SimpleBirdDirect] Deleting bird")
    
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
-- Request this bird to enter despawning state
---
function SimpleBirdDirect:requestDespawn()
    if self.stateMachine then
        self.stateMachine:requestDespawn()
    end
end
