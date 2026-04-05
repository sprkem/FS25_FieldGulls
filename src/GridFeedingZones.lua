---
-- GridFeedingZones
-- Global system for tracking grid cells where birds can feed
---

GridFeedingZones = {}
local GridFeedingZones_mt = Class(GridFeedingZones)

-- Configuration
GridFeedingZones.GRID_SIZE = 1                      -- 1m x 1m grid cells
GridFeedingZones.CELL_EXPIRE_TIME = 90000           -- Cells expire after 90 seconds (ms)
GridFeedingZones.BUFFER_TIME = 8000                 -- Time before moving to recently eaten (ms)
GridFeedingZones.RECENTLY_EATEN_EXPIRE_TIME = 80000 -- Recently eaten cells expire after 80 seconds (ms)
GridFeedingZones.MAX_RECENT_CELLS = 80              -- Max recent cells to consider for priority feeding

---
-- Convert world position to grid coordinates
-- @param x: World X position
-- @param z: World Z position
-- @return gridX, gridZ: Grid cell coordinates
---
function GridFeedingZones.getGridPosition(x, z)
    local gridSize = GridFeedingZones.GRID_SIZE
    local gridX = math.floor(x / gridSize) * gridSize + gridSize / 2
    local gridZ = math.floor(z / gridSize) * gridSize + gridSize / 2
    return gridX, gridZ
end

---
-- Get grid key for storing in table
-- @param gridX, gridZ: Grid coordinates
-- @return string: Grid key
---
function GridFeedingZones.getGridKey(gridX, gridZ)
    return string.format("%d_%d", gridX, gridZ)
end

---
-- Create a new GridFeedingZones instance
-- @return GridFeedingZones instance
---
function GridFeedingZones.new()
    local self = setmetatable({}, GridFeedingZones_mt)

    -- Store cells as a flat table with grid keys
    -- Each entry: { gridX, gridZ, timestamp, key, toolId }
    self.cells = {}

    -- Index for fast spatial queries
    -- Structure: gridX -> gridZ -> cell
    self.spatialIndex = {}

    -- Ordered list of cells by timestamp (newest first)
    -- Each entry is a reference to the cell in self.cells
    self.cellsByTimestamp = {}

    -- Buffered cells waiting to move to RECENTLY_EATEN_CELLS
    -- Array of { gridX, gridZ, bufferTime, toolId }
    self.bufferedCells = {}

    -- Recently eaten cells that can be reused when no fresh cells available
    -- Array of { gridX, gridZ, timestamp, toolId }
    self.recentlyEatenCells = {}

    -- FieldState instance for checking ground type at positions
    self.fieldState = FieldState.new()

    -- Occupied cells by vehicles
    -- Structure: occupiedCells[vehicleId] = { [gridKey] = true }
    self.occupiedCells = {}

    -- Per-tool cell counts for fast lookups
    -- Structure: toolCellCounts[toolId] = number
    self.toolCellCounts = {}

    return self
end

---
-- Add a cell to the feeding zones
-- @param gridX, gridZ: Grid position
-- @param toolId: The tool that created this cell (nil allowed for backward compat)
---
function GridFeedingZones:addCellImmediate(gridX, gridZ, toolId)
    local key = GridFeedingZones.getGridKey(gridX, gridZ)

    -- Check if cell already exists - if so, refresh it
    if self.cells[key] then
        local cell = self.cells[key]

        -- Update timestamp to keep it fresh
        cell.timestamp = g_time

        -- Update toolId if a new one is provided (adopts the cell to the active tool)
        if toolId and cell.toolId ~= toolId then
            local oldToolId = cell.toolId
            if oldToolId and self.toolCellCounts[oldToolId] then
                self.toolCellCounts[oldToolId] = self.toolCellCounts[oldToolId] - 1
            end
            cell.toolId = toolId
            self.toolCellCounts[toolId] = (self.toolCellCounts[toolId] or 0) + 1
        end

        -- Move to front of timestamp list (newest first)
        for i, orderedCell in ipairs(self.cellsByTimestamp) do
            if orderedCell == cell then
                table.remove(self.cellsByTimestamp, i)
                table.insert(self.cellsByTimestamp, 1, cell)
                break
            end
        end
        -- Cell already exists, just refreshed
        return true
    end

    -- Check ground type at this position - only add cells on valid fields
    self.fieldState:update(gridX, gridZ)
    if self.fieldState.groundType == FieldGroundType.NONE then
        return false
    end

    -- Create new cell
    local cell = {
        gridX = gridX,
        gridZ = gridZ,
        timestamp = g_time,
        key = key,
        toolId = toolId
    }

    self.cells[key] = cell

    -- Track per-tool cell count
    if toolId then
        self.toolCellCounts[toolId] = (self.toolCellCounts[toolId] or 0) + 1
    end

    -- Add to spatial index
    if not self.spatialIndex[gridX] then
        self.spatialIndex[gridX] = {}
    end
    self.spatialIndex[gridX][gridZ] = cell

    -- Add to timestamp-ordered list (newest first)
    table.insert(self.cellsByTimestamp, 1, cell)
end

---
-- Remove a specific cell by grid coordinates
-- @param gridX, gridZ: Grid coordinates
---
function GridFeedingZones:removeCell(gridX, gridZ)
    local key = GridFeedingZones.getGridKey(gridX, gridZ)

    if self.cells[key] then
        local cell = self.cells[key]

        -- Decrement per-tool count
        if cell.toolId and self.toolCellCounts[cell.toolId] then
            self.toolCellCounts[cell.toolId] = self.toolCellCounts[cell.toolId] - 1
            if self.toolCellCounts[cell.toolId] <= 0 then
                self.toolCellCounts[cell.toolId] = nil
            end
        end

        self.cells[key] = nil

        -- Remove from spatial index
        if self.spatialIndex[gridX] and self.spatialIndex[gridX][gridZ] then
            self.spatialIndex[gridX][gridZ] = nil

            -- Clean up empty gridX entries
            local isEmpty = true
            for _ in pairs(self.spatialIndex[gridX]) do
                isEmpty = false
                break
            end
            if isEmpty then
                self.spatialIndex[gridX] = nil
            end
        end

        -- Remove from timestamp-ordered list
        for i, orderedCell in ipairs(self.cellsByTimestamp) do
            if orderedCell == cell then
                table.remove(self.cellsByTimestamp, i)
                break
            end
        end
    end
end

---
-- Remove expired cells (older than CELL_EXPIRE_TIME)
---
function GridFeedingZones:removeExpiredCells()
    local currentTime = g_time
    local expireTime = currentTime - GridFeedingZones.CELL_EXPIRE_TIME

    -- Collect keys to remove (can't modify table while iterating)
    local toRemove = {}
    for key, cell in pairs(self.cells) do
        if cell.timestamp < expireTime then
            table.insert(toRemove, cell)
        end
    end

    -- Remove expired cells
    for _, cell in ipairs(toRemove) do
        self:removeCell(cell.gridX, cell.gridZ)
    end
end

---
-- Get a random position within a grid cell's bounds
-- @param gridX, gridZ: Grid cell center coordinates
-- @return x, z: Random world position within the cell
---
function GridFeedingZones.getRandomPositionInCell(gridX, gridZ)
    local halfSize = GridFeedingZones.GRID_SIZE / 2
    local randomX = gridX + (math.random() - 0.5) * GridFeedingZones.GRID_SIZE
    local randomZ = gridZ + (math.random() - 0.5) * GridFeedingZones.GRID_SIZE
    return randomX, randomZ
end

---
-- Get the position of the active work area (newest cell) without removing it
-- @param toolId: If provided, only consider cells from this tool
-- @return x, z: Center position of newest cell, or nil if no cells available
---
function GridFeedingZones:getWorkAreaPosition(toolId)
    if #self.cellsByTimestamp == 0 then
        return nil, nil
    end

    if toolId then
        -- Find newest cell belonging to this tool
        for _, cell in ipairs(self.cellsByTimestamp) do
            if cell.toolId == toolId then
                return cell.gridX, cell.gridZ
            end
        end
        return nil, nil
    end

    local newestCell = self.cellsByTimestamp[1]
    return newestCell.gridX, newestCell.gridZ
end

---
-- Request a feeding target for a bird (centralized selection system)
-- @param birdX, birdZ: Bird's current world position
-- @param vehicleX, vehicleZ: Vehicle center position
-- @param isMoving: Boolean indicating if the vehicle/plow is currently moving
-- @param workingWidth: Working width of the tool (meters)
-- @param toolId: If provided, only consider cells from this tool
-- @return targetX, targetZ: Random position in selected cell, or nil if no cells available
---
function GridFeedingZones:requestFeedingTarget(birdX, birdZ, vehicleX, vehicleZ, isMoving, workingWidth, toolId)
    -- No cells available
    if #self.cellsByTimestamp == 0 then
        return nil, nil
    end

    local selectedCell = nil

    -- 80% chance: Pick randomly from top most recent cells
    -- 20% chance: Pick weighted by inverse distance
    local useRecentCells = math.random() < 0.80

    if useRecentCells then
        -- Pick randomly from recent cells, excluding occupied cells and filtering by toolId
        -- Scan through timestamp list collecting up to MAX_RECENT_CELLS matching cells
        local validCells = {}

        for i = 1, #self.cellsByTimestamp do
            local cell = self.cellsByTimestamp[i]
            if (not toolId or cell.toolId == toolId) and not self:isCellOccupied(cell.gridX, cell.gridZ) then
                table.insert(validCells, cell)
                if #validCells >= GridFeedingZones.MAX_RECENT_CELLS then
                    break
                end
            end
        end

        if #validCells > 0 then
            local randomIndex = math.random(1, #validCells)
            selectedCell = validCells[randomIndex]
        end
    else
        -- Distance-weighted strategy: favor closer cells (to bird), excluding occupied cells
        local validCells = {}
        local weights = {}
        local totalWeight = 0

        -- Consider all cells, weighted by distance to bird
        for i = 1, #self.cellsByTimestamp do
            local cell = self.cellsByTimestamp[i]

            -- Skip cells from other tools, skip occupied cells
            if (not toolId or cell.toolId == toolId) and not self:isCellOccupied(cell.gridX, cell.gridZ) then
                -- Calculate weight based on distance to bird
                local distance = MathUtil.vector2Length(cell.gridX - birdX, cell.gridZ - birdZ)

                -- Inverse distance weight (closer to bird = higher weight)
                local weight = 1.0 / (distance + 1.0)
                table.insert(validCells, cell)
                table.insert(weights, weight)
                totalWeight = totalWeight + weight
            end
        end

        -- Check if we have any valid cells
        if #validCells == 0 then
            return nil, nil
        end

        -- Weighted random selection
        local randomValue = math.random() * totalWeight
        local cumulativeWeight = 0

        for i = 1, #validCells do
            cumulativeWeight = cumulativeWeight + weights[i]
            if randomValue <= cumulativeWeight then
                selectedCell = validCells[i]
                break
            end
        end

        -- Fallback: pick first valid cell if weighted selection failed
        if not selectedCell and #validCells > 0 then
            selectedCell = validCells[1]
        end
    end

    -- Safety check: make sure we have a valid cell
    if not selectedCell then
        -- No valid fresh cells - try RECENTLY_EATEN_CELLS as fallback
        if #self.recentlyEatenCells > 0 then
            -- Collect matching recently eaten cells
            local matchingIndices = {}
            for i, recentCell in ipairs(self.recentlyEatenCells) do
                if not toolId or recentCell.toolId == toolId then
                    table.insert(matchingIndices, i)
                end
            end

            if #matchingIndices > 0 then
                local picked = matchingIndices[math.random(1, #matchingIndices)]
                local recentCell = self.recentlyEatenCells[picked]

                -- Remove from recently eaten cells
                table.remove(self.recentlyEatenCells, picked)

                -- Add back to buffer to cycle through the system again
                table.insert(self.bufferedCells, {
                    gridX = recentCell.gridX,
                    gridZ = recentCell.gridZ,
                    bufferTime = g_time,
                    toolId = recentCell.toolId
                })

                -- Get random position within the cell
                local targetX, targetZ = GridFeedingZones.getRandomPositionInCell(recentCell.gridX, recentCell.gridZ)
                return targetX, targetZ
            end
        end

        return nil, nil
    end

    -- Get random position within selected cell
    local targetX, targetZ = GridFeedingZones.getRandomPositionInCell(selectedCell.gridX, selectedCell.gridZ)

    -- Remove the selected cell
    self:removeCell(selectedCell.gridX, selectedCell.gridZ)

    -- Buffer the cell before moving to RECENTLY_EATEN_CELLS
    table.insert(self.bufferedCells, {
        gridX = selectedCell.gridX,
        gridZ = selectedCell.gridZ,
        bufferTime = g_time,
        toolId = selectedCell.toolId
    })

    return targetX, targetZ
end

---
-- Update occupied cells for a vehicle based on its physical dimensions
-- @param vehicleId: Unique identifier for the vehicle (e.g., vehicle.rootNode)
-- @param x, z: Vehicle center position
-- @param rotY: Vehicle rotation (yaw)
-- @param length: Vehicle length in meters (sizeLength)
-- @param width: Vehicle width in meters (sizeWidth)
---
function GridFeedingZones:updateOccupiedCells(vehicleId, x, z, rotY, length, width)
    if not vehicleId then
        return
    end

    -- Clear previous occupied cells for this vehicle
    self.occupiedCells[vehicleId] = {}

    -- Calculate the four corners of the vehicle's bounding box
    local halfLength = length / 2
    local halfWidth = width / 2

    -- Local corners (relative to vehicle center)
    -- In local space: X = width (left/right), Z = length (forward/backward)
    local corners = {
        { x = -halfWidth, z = -halfLength },
        { x = halfWidth, z = -halfLength },
        { x = halfWidth, z = halfLength },
        { x = -halfWidth, z = halfLength }
    }

    -- Rotate corners and convert to world coordinates
    local cosRot = math.cos(rotY)
    local sinRot = math.sin(rotY)
    local worldCorners = {}

    for _, corner in ipairs(corners) do
        local worldX = x + corner.x * cosRot - corner.z * sinRot
        local worldZ = z + corner.x * sinRot + corner.z * cosRot
        table.insert(worldCorners, { x = worldX, z = worldZ })
    end

    -- Find bounding box of rotated vehicle
    local minX = math.min(worldCorners[1].x, worldCorners[2].x, worldCorners[3].x, worldCorners[4].x)
    local maxX = math.max(worldCorners[1].x, worldCorners[2].x, worldCorners[3].x, worldCorners[4].x)
    local minZ = math.min(worldCorners[1].z, worldCorners[2].z, worldCorners[3].z, worldCorners[4].z)
    local maxZ = math.max(worldCorners[1].z, worldCorners[2].z, worldCorners[3].z, worldCorners[4].z)

    -- Convert to grid cells
    local startGridX = math.floor(minX / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE
    local endGridX = math.floor(maxX / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE
    local startGridZ = math.floor(minZ / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE
    local endGridZ = math.floor(maxZ / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE

    -- Mark all grid cells within the bounding box as occupied
    for gx = startGridX, endGridX, GridFeedingZones.GRID_SIZE do
        for gz = startGridZ, endGridZ, GridFeedingZones.GRID_SIZE do
            local gridX, gridZ = GridFeedingZones.getGridPosition(
                gx + GridFeedingZones.GRID_SIZE / 2,
                gz + GridFeedingZones.GRID_SIZE / 2
            )
            local key = GridFeedingZones.getGridKey(gridX, gridZ)
            self.occupiedCells[vehicleId][key] = true
        end
    end

    -- Debug visualization: Draw the vehicle's bounding box
    -- if g_currentMission and g_currentMission.terrainRootNode then
    --     local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z) + 1.0 -- 1m above ground
    --     local halfSizeX = width / 2
    --     local halfSizeY = 1.0                                                                 -- Visual height (half of 2m)
    --     local halfSizeZ = length / 2

    --     DebugUtil.drawOverlapBox(x, y, z, 0, rotY, 0, halfSizeX, halfSizeY, halfSizeZ, 1, 0, 0) -- Red box
    -- end
end

---
-- Clear occupied cells for a vehicle (call when vehicle is deleted)
-- @param vehicleId: Unique identifier for the vehicle
---
function GridFeedingZones:clearOccupiedCells(vehicleId)
    if vehicleId then
        self.occupiedCells[vehicleId] = nil
    end
end

---
-- Check if a grid cell is occupied by any vehicle
-- @param gridX, gridZ: Grid cell coordinates
-- @return boolean: true if occupied, false otherwise
---
function GridFeedingZones:isCellOccupied(gridX, gridZ)
    local key = GridFeedingZones.getGridKey(gridX, gridZ)

    for _, vehicleCells in pairs(self.occupiedCells) do
        if vehicleCells[key] then
            return true
        end
    end

    return false
end

---
-- Get affected grid cells from a work area (rectangular area)
-- @param sx, sz: Start corner world position
-- @param wx, wz: Width corner world position
-- @param hx, hz: Height corner world position
-- @return table: Array of {gridX, gridZ} cells
---
function GridFeedingZones.getAffectedGridCells(sx, sz, wx, wz, hx, hz)
    local minX = math.min(sx, wx, hx)
    local maxX = math.max(sx, wx, hx)
    local minZ = math.min(sz, wz, hz)
    local maxZ = math.max(sz, wz, hz)

    local areaWidth = maxX - minX
    local areaHeight = maxZ - minZ

    local startGridX = math.floor(minX / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE
    local endGridX = math.floor(maxX / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE
    local startGridZ = math.floor(minZ / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE
    local endGridZ = math.floor(maxZ / GridFeedingZones.GRID_SIZE) * GridFeedingZones.GRID_SIZE

    local cells = {}

    -- Iterate through all grid cells in the bounding box
    for gx = startGridX, endGridX, GridFeedingZones.GRID_SIZE do
        for gz = startGridZ, endGridZ, GridFeedingZones.GRID_SIZE do
            local gridX, gridZ = GridFeedingZones.getGridPosition(
                gx + GridFeedingZones.GRID_SIZE / 2,
                gz + GridFeedingZones.GRID_SIZE / 2
            )
            table.insert(cells, { gridX = gridX, gridZ = gridZ })
        end
    end

    return cells
end

---
-- Update function (call each frame to clean up expired cells)
-- @param dt: Delta time (ms)
---
function GridFeedingZones:update(dt)
    if not self.lastCleanupTime then
        self.lastCleanupTime = 0
    end

    self.lastCleanupTime = self.lastCleanupTime + dt
    if self.lastCleanupTime >= 1000 then
        self:removeExpiredCells()
        self.lastCleanupTime = 0
    end

    -- Process buffered cells: move to RECENTLY_EATEN_CELLS after BUFFER_TIME
    local currentTime = g_time
    local toMove = {}

    for i, bufferedCell in ipairs(self.bufferedCells) do
        if currentTime - bufferedCell.bufferTime >= GridFeedingZones.BUFFER_TIME then
            -- Move to recently eaten cells with timestamp
            table.insert(self.recentlyEatenCells, {
                gridX = bufferedCell.gridX,
                gridZ = bufferedCell.gridZ,
                timestamp = currentTime,
                toolId = bufferedCell.toolId
            })
            table.insert(toMove, i)
        end
    end

    -- Remove processed buffered cells (iterate backwards to avoid index issues)
    for i = #toMove, 1, -1 do
        table.remove(self.bufferedCells, toMove[i])
    end

    -- Clean up expired recently eaten cells (unused for 60 seconds)
    local expireTime = currentTime - GridFeedingZones.RECENTLY_EATEN_EXPIRE_TIME
    local toRemove = {}

    for i, recentCell in ipairs(self.recentlyEatenCells) do
        if recentCell.timestamp < expireTime then
            table.insert(toRemove, i)
        end
    end

    -- Remove expired recently eaten cells (iterate backwards to avoid index issues)
    for i = #toRemove, 1, -1 do
        table.remove(self.recentlyEatenCells, toRemove[i])
    end
end

---
-- Get total number of cells, optionally filtered by toolId
-- @param toolId: If provided, return count for this tool only
-- @return number: Total cells
---
function GridFeedingZones:getCellCount(toolId)
    if toolId then
        return self.toolCellCounts[toolId] or 0
    end
    local count = 0
    for _ in pairs(self.cells) do
        count = count + 1
    end
    return count
end

---
-- Clear all cells
---
function GridFeedingZones:clear()
    self.cells = {}
    self.spatialIndex = {}
    self.bufferedCells = {}
    self.recentlyEatenCells = {}
    self.occupiedCells = {}
    self.toolCellCounts = {}
end
