---
-- GridFeedingZones
-- Global system for tracking grid cells where birds can feed
---

GridFeedingZones = {}
local GridFeedingZones_mt = Class(GridFeedingZones)

-- Configuration
GridFeedingZones.GRID_SIZE = 1            -- 1m x 1m grid cells
GridFeedingZones.CELL_EXPIRE_TIME = 30000 -- Cells expire after 30 seconds (ms)

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
    -- Each entry: { gridX, gridZ, timestamp, key }
    self.cells = {}

    -- Index for fast spatial queries
    -- Structure: gridX -> gridZ -> cell
    self.spatialIndex = {}

    -- Ordered list of cells by timestamp (newest first)
    -- Each entry is a reference to the cell in self.cells
    self.cellsByTimestamp = {}

    return self
end

---
-- Add a cell to the feeding zones
-- @param x, z: World position
---
function GridFeedingZones:addCell(x, z)
    local gridX, gridZ = GridFeedingZones.getGridPosition(x, z)
    local key = GridFeedingZones.getGridKey(gridX, gridZ)

    -- Check if cell already exists
    if self.cells[key] then
        -- Cell already tracked, don't update timestamp (preserve original expiration)
        return
    end

    -- Create new cell
    local cell = {
        gridX = gridX,
        gridZ = gridZ,
        timestamp = g_time,
        key = key
    }

    self.cells[key] = cell

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
-- @return x, z: Center position of newest cell, or nil if no cells available
---
function GridFeedingZones:getWorkAreaPosition()
    if #self.cellsByTimestamp == 0 then
        return nil, nil
    end

    local newestCell = self.cellsByTimestamp[1]
    return newestCell.gridX, newestCell.gridZ
end

---
-- Request a feeding target for a bird (centralized selection system)
-- @param birdX, birdZ: Bird's current world position
-- @param isMoving: Boolean indicating if the vehicle/plow is currently moving
-- @return targetX, targetZ: Random position in selected cell, or nil if no cells available
---
function GridFeedingZones:requestFeedingTarget(birdX, birdZ, vehicleX, vehicleZ, isMoving)
    -- No cells available
    if #self.cellsByTimestamp == 0 then
        return nil, nil
    end

    local selectedCell = nil
    local MIN_DISTANCE_FROM_TOOL = 2.0 -- Minimum 2 meters from tool

    -- 75% chance: Pick randomly from top 10 most recent cells
    -- 25% chance: Pick weighted by inverse distance
    if math.random() < 0.75 then
        -- Build list of valid cells (excluding those within 2m of tool)
        local validCells = {}
        for i = 1, math.min(20, #self.cellsByTimestamp) do
            local cell = self.cellsByTimestamp[i]
            local dx = cell.gridX - vehicleX
            local dz = cell.gridZ - vehicleZ
            local distFromTool = math.sqrt(dx * dx + dz * dz)

            if distFromTool >= MIN_DISTANCE_FROM_TOOL then
                table.insert(validCells, cell)
            end
        end

        -- Check if we have any valid cells
        if #validCells == 0 then
            return nil, nil
        end

        -- Pick randomly from valid cells (up to first 10)
        local endIndex = math.min(10, #validCells)
        local randomIndex = math.random(1, endIndex)
        selectedCell = validCells[randomIndex]
    else
        -- Distance-weighted strategy: favor closer cells (to bird)
        -- Build list of valid cells (excluding those within 2m of tool)
        local validCells = {}
        local weights = {}
        local totalWeight = 0

        -- Consider recent cells, excluding those too close to the tool
        for i = 1, #self.cellsByTimestamp do
            local cell = self.cellsByTimestamp[i]

            -- Check distance from tool
            local dxTool = cell.gridX - vehicleX
            local dzTool = cell.gridZ - vehicleZ
            local distFromTool = math.sqrt(dxTool * dxTool + dzTool * dzTool)

            if distFromTool >= MIN_DISTANCE_FROM_TOOL then
                -- Calculate weight based on distance to bird
                local dx = cell.gridX - birdX
                local dz = cell.gridZ - birdZ
                local distanceSq = dx * dx + dz * dz
                local distance = math.sqrt(distanceSq)

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
        return nil, nil
    end

    -- Get random position within selected cell
    local targetX, targetZ = GridFeedingZones.getRandomPositionInCell(selectedCell.gridX, selectedCell.gridZ)

    -- Remove the selected cell
    self:removeCell(selectedCell.gridX, selectedCell.gridZ)

    return targetX, targetZ
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
end

---
-- Get total number of cells
-- @return number: Total cells
---
function GridFeedingZones:getCellCount()
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
end
