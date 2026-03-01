---
-- GridFeedingZones
-- Global system for tracking grid cells where birds can feed
---

GridFeedingZones = {}
local GridFeedingZones_mt = Class(GridFeedingZones)

-- Configuration
GridFeedingZones.GRID_SIZE = 1          -- 1m x 1m grid cells
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
-- @return targetX, targetZ: Random position in selected cell, or nil if no cells available
---
function GridFeedingZones:requestFeedingTarget(birdX, birdZ)
    -- No cells available
    if #self.cellsByTimestamp == 0 then
        return nil, nil
    end
    
    local selectedCell = nil
    
    -- 70% chance: Pick randomly from top 10 most recent cells
    -- 30% chance: Pick weighted by inverse distance
    if math.random() < 0.70 then
        -- Pick randomly from newest 10 cells (or all if fewer than 10)
        local recentCount = math.min(10, #self.cellsByTimestamp)
        local randomIndex = math.random(1, recentCount)
        selectedCell = self.cellsByTimestamp[randomIndex]
    else
        -- Distance-weighted strategy: favor closer cells
        local weights = {}
        local totalWeight = 0
        
        for i, cell in ipairs(self.cellsByTimestamp) do
            local dx = cell.gridX - birdX
            local dz = cell.gridZ - birdZ
            local distanceSq = dx * dx + dz * dz
            local distance = math.sqrt(distanceSq)
            
            -- Inverse distance weight (closer = higher weight)
            -- Add small constant to avoid division by zero
            local weight = 1.0 / (distance + 1.0)
            weights[i] = weight
            totalWeight = totalWeight + weight
        end
        
        -- Weighted random selection
        local randomValue = math.random() * totalWeight
        local cumulativeWeight = 0
        
        for i, cell in ipairs(self.cellsByTimestamp) do
            cumulativeWeight = cumulativeWeight + weights[i]
            if randomValue <= cumulativeWeight then
                selectedCell = cell
                break
            end
        end
        
        -- Fallback to last cell if something went wrong
        if not selectedCell then
            selectedCell = self.cellsByTimestamp[#self.cellsByTimestamp]
        end
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
    local cells = {}
    local cellSet = {} -- Use set to avoid duplicates
    
    -- Calculate bounding box
    local minX = math.min(sx, wx, hx, sx + wx - hx, sx + hx - wx, wx + hx - sx)
    local maxX = math.max(sx, wx, hx, sx + wx - hx, sx + hx - wx, wx + hx - sx)
    local minZ = math.min(sz, wz, hz, sz + wz - hz, sz + hz - wz, wz + hz - sz)
    local maxZ = math.max(sz, wz, hz, sz + wz - hz, sz + hz - wz, wz + hz - sz)
    
    -- Sample points in a grid pattern across the work area
    local gridSize = GridFeedingZones.GRID_SIZE
    local samples = 5 -- Sample 5x5 grid across work area
    
    for i = 0, samples do
        for j = 0, samples do
            local u = i / samples
            local v = j / samples
            
            -- Interpolate position in the parallelogram
            local x = sx + (wx - sx) * u + (hx - sx) * v
            local z = sz + (wz - sz) * u + (hz - sz) * v
            
            -- Get grid cell
            local gridX, gridZ = GridFeedingZones.getGridPosition(x, z)
            local key = GridFeedingZones.getGridKey(gridX, gridZ)
            
            if not cellSet[key] then
                cellSet[key] = true
                table.insert(cells, { gridX = gridX, gridZ = gridZ })
            end
        end
    end
    
    return cells
end

---
-- Update function (call each frame to clean up expired cells)
-- @param dt: Delta time (ms)
---
function GridFeedingZones:update(dt)
    -- Remove expired cells periodically (every second)
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

-- Global instance (created by BirdManager)
g_gridFeedingZones = nil
