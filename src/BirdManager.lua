---
-- BirdManager
-- Global manager for all bird flock managers that runs independent of vehicle state.
-- Owns the update lifecycle for all flocks. Tools only report activity; if a tool
-- disappears (returned/sold/deleted) the flock gracefully transitions to dispersal.
-- Also tracks ALL map vehicles for occupied-cell / bird-flee logic.
---

BirdManager = {}
BirdManager.activeFlockManagers = {}  -- toolId -> ToolBirdFlockManager
BirdManager.nextToolId = 1           -- Auto-incrementing ID for flock managers

-- How long (ms) after the last tool activity report before we consider the tool gone
BirdManager.TOOL_INACTIVE_TIMEOUT = 2000

-- Vehicle occupied-cell tracking
BirdManager.VEHICLE_CHECK_INTERVAL = 200  -- ms between vehicle scans
BirdManager.BIRD_FLEE_RADIUS = 3.0        -- meters – birds within this distance of an occupied cell flee
BirdManager.VEHICLE_MOVE_THRESHOLD = 0.5  -- meters – minimum movement before recalculating cells

---
-- Initialize the bird manager
---
function BirdManager:loadMap()
    if not g_currentMission:getIsClient() then return end

    local birdConfig = BirdConfig.loadConfig()
    if birdConfig and birdConfig.filename then
        g_i3DManager:loadSharedI3DFileAsync(
            birdConfig.filename,
            false, -- callOnCreate
            false, -- addToPhysics
            function(i3dNode, failedReason, args)
                if failedReason ~= 0 then
                    print("[BirdManager] Warning: Failed to preload bird i3d model")
                end
            end,
            nil,
            nil
        )
    end

    -- Initialize global grid feeding zones system
    g_gridFeedingZones = GridFeedingZones.new()

    -- Vehicle tracking state
    self.vehicleCheckTimer = 0
    self.trackedVehicles = {} -- rootNode -> { lastX, lastZ }
end

---
-- Global update function called every frame
-- @param dt: Delta time in milliseconds
---
function BirdManager:update(dt)
    if not g_currentMission:getIsClient() then return end

    if g_gridFeedingZones then
        g_gridFeedingZones:update(dt)
    end

    -- Update all flock managers and detect disappeared tools
    for toolId, flockManager in pairs(self.activeFlockManagers) do
        if flockManager and flockManager.update then
            -- Check if the tool has gone silent (deleted/returned without onDelete)
            if flockManager.isActive and flockManager.lastToolReportTime then
                local timeSinceReport = g_time - flockManager.lastToolReportTime
                if timeSinceReport > BirdManager.TOOL_INACTIVE_TIMEOUT then
                    -- Tool has disappeared or stopped reporting — treat as "stopped working"
                    flockManager:onToolLost()
                end
            end

            flockManager:update(dt)
        end
    end

    -- Periodically scan all map vehicles for occupied cells and bird flee
    self.vehicleCheckTimer = self.vehicleCheckTimer + dt
    if self.vehicleCheckTimer >= BirdManager.VEHICLE_CHECK_INTERVAL then
        self.vehicleCheckTimer = 0
        self:updateAllVehicleOccupiedCells()
        self:checkBirdFlee()
    end
end

---
-- Scan every vehicle in the map. If it moved since last check, recalculate
-- its occupied cells. Remove entries for vehicles that no longer exist.
---
function BirdManager:updateAllVehicleOccupiedCells()
    if not g_gridFeedingZones then return end
    if not g_currentMission or not g_currentMission.vehicleSystem then return end

    -- Build a set of currently-valid rootNodes so we can detect deletions
    local currentRootNodes = {}

    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.rootNode and entityExists(vehicle.rootNode) then
            currentRootNodes[vehicle.rootNode] = true

            local x, _, z = getWorldTranslation(vehicle.rootNode)
            local tracked = self.trackedVehicles[vehicle.rootNode]

            if not tracked then
                -- First time seeing this vehicle — track it and compute cells
                self.trackedVehicles[vehicle.rootNode] = { lastX = x, lastZ = z }
                self:computeVehicleOccupiedCells(vehicle)
            else
                -- Check if it moved enough to warrant a recalculation
                local dx = x - tracked.lastX
                local dz = z - tracked.lastZ
                local distSq = dx * dx + dz * dz
                if distSq >= BirdManager.VEHICLE_MOVE_THRESHOLD * BirdManager.VEHICLE_MOVE_THRESHOLD then
                    tracked.lastX = x
                    tracked.lastZ = z
                    self:computeVehicleOccupiedCells(vehicle)
                end
            end
        end
    end

    -- Clear occupied cells for vehicles that have been deleted / returned
    local toRemove = {}
    for rootNode, _ in pairs(self.trackedVehicles) do
        if not currentRootNodes[rootNode] then
            table.insert(toRemove, rootNode)
        end
    end
    for _, rootNode in ipairs(toRemove) do
        g_gridFeedingZones:clearOccupiedCells(rootNode)
        self.trackedVehicles[rootNode] = nil
    end
end

---
-- Compute and store occupied cells for a single vehicle
-- @param vehicle: A vehicle from g_currentMission.vehicleSystem.vehicles
---
function BirdManager:computeVehicleOccupiedCells(vehicle)
    if not vehicle.rootNode or not entityExists(vehicle.rootNode) then return end
    if not vehicle.size then return end

    local x, _, z = getWorldTranslation(vehicle.rootNode)
    local _, rotY, _ = getRotation(vehicle.rootNode)
    local length = vehicle.size.length or 5
    local width = vehicle.size.width or 2.5

    g_gridFeedingZones:updateOccupiedCells(vehicle.rootNode, x, z, rotY, length, width)
end

---
-- After occupied cells are refreshed, check every ground-level bird across all
-- flocks. If a bird is within BIRD_FLEE_RADIUS of any occupied cell's world
-- position, tell it to flee (transition to FEEDING_UP) and re-add its feeding
-- target to the available pool.
---
function BirdManager:checkBirdFlee()
    if not g_gridFeedingZones then return end

    local fleeRadiusSq = BirdManager.BIRD_FLEE_RADIUS * BirdManager.BIRD_FLEE_RADIUS

    for _, flockManager in pairs(self.activeFlockManagers) do
        if flockManager and flockManager.spawnedBirds then
            for _, bird in ipairs(flockManager.spawnedBirds) do
                if bird and bird.stateMachine then
                    local state = bird.stateMachine:getState()
                    -- Only check birds that are on or very near the ground
                    if state == BirdStateMachine.STATE_FEEDING_GROUND
                        or state == BirdStateMachine.STATE_DIVING then
                        local bx, by, bz = bird:getCurrentPosition()
                        if self:isBirdNearOccupiedCell(bx, bz, fleeRadiusSq) then
                            bird.stateMachine:requestFlee()
                        end
                    end
                end
            end
        end
    end
end

---
-- Check if a world position is within fleeRadiusSq of any occupied cell
-- @param bx: Bird world X
-- @param bz: Bird world Z
-- @param fleeRadiusSq: Squared flee radius
-- @return boolean
---
function BirdManager:isBirdNearOccupiedCell(bx, bz, fleeRadiusSq)
    -- Convert bird position to grid cell
    local birdGridX, birdGridZ = GridFeedingZones.getGridPosition(bx, bz)

    -- Check a small neighbourhood of grid cells around the bird
    -- (flee radius of 3m with 1m grid = check ±3 cells)
    local checkRange = math.ceil(BirdManager.BIRD_FLEE_RADIUS / GridFeedingZones.GRID_SIZE)
    local gridSize = GridFeedingZones.GRID_SIZE

    for dx = -checkRange, checkRange do
        for dz = -checkRange, checkRange do
            local cellX = birdGridX + dx * gridSize
            local cellZ = birdGridZ + dz * gridSize
            if g_gridFeedingZones:isCellOccupied(cellX, cellZ) then
                -- Check actual distance from bird to cell center
                local distX = bx - cellX
                local distZ = bz - cellZ
                local distSq = distX * distX + distZ * distZ
                if distSq <= fleeRadiusSq then
                    return true
                end
            end
        end
    end

    return false
end

---
-- Register a flock manager for continuous updates (keyed by unique tool ID)
-- @param toolId: Unique numeric ID for this tool's flock
-- @param flockManager: The flock manager instance
---
function BirdManager:registerFlockManager(toolId, flockManager)
    if toolId and flockManager then
        self.activeFlockManagers[toolId] = flockManager
    end
end

---
-- Unregister a flock manager when fully inactive (all birds despawned)
-- @param toolId: The unique tool ID
---
function BirdManager:unregisterFlockManager(toolId)
    if toolId then
        self.activeFlockManagers[toolId] = nil
    end
end

---
-- Generate a unique tool ID for a new flock manager
-- @return number: Unique tool ID
---
function BirdManager:generateToolId()
    local id = self.nextToolId
    self.nextToolId = self.nextToolId + 1
    return id
end

---
-- Cleanup on map unload
---
function BirdManager:deleteMap()
    -- Cleanup all active flock managers
    for toolId, flockManager in pairs(self.activeFlockManagers) do
        if flockManager and flockManager.forceCleanup then
            flockManager:forceCleanup()
        end
    end

    self.activeFlockManagers = {}
    self.nextToolId = 1
    self.trackedVehicles = {}
    self.vehicleCheckTimer = 0

    if g_gridFeedingZones then
        g_gridFeedingZones:clear()
        g_gridFeedingZones = nil
    end
end

addModEventListener(BirdManager)
