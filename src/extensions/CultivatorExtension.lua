---
-- CultivatorExtension
-- Hooks into the Cultivator specialization to spawn following birds
-- Note: Cultivator doesn't have onUpdate, so we use onEndWorkAreaProcessing
---

CultivatorExtension = {}

---
-- Hook into cultivator area processing to track grid cells for bird feeding
-- @param superFunc: Original processCultivatorArea function
-- @param workArea: The work area being processed
-- @param dt: Delta time
---
function CultivatorExtension:processCultivatorArea(superFunc, workArea, dt)
    -- Call original function first
    local changedArea, totalArea = superFunc(self, workArea, dt)
    
    -- Track grid cells for bird feeding if we're working
    if changedArea and changedArea > 0 and g_gridFeedingZones then
        local sx, sy, sz = getWorldTranslation(workArea.start)
        local wx, wy, wz = getWorldTranslation(workArea.width)
        local hx, hy, hz = getWorldTranslation(workArea.height)
        
        -- Get affected grid cells
        local cells = GridFeedingZones.getAffectedGridCells(sx, sz, wx, wz, hx, hz)
        
        -- Add cells to global grid system
        for _, cell in ipairs(cells) do
            g_gridFeedingZones:addCell(cell.gridX, cell.gridZ)
        end
    end
    
    return changedArea, totalArea
end

---
-- Extended onEndWorkAreaProcessing for Cultivator specialization
-- @param superFunc: Original function
-- @param dt: Delta time in milliseconds
---
function CultivatorExtension:onEndWorkAreaProcessing(superFunc, dt)
    -- Call original function
    if superFunc ~= nil then
        superFunc(self, dt)
    end

    -- Initialize birds data if needed
    if not self.toolBirdsData or not self.toolBirdsData.initialized then
        ToolBirdsExtension:initialize(self, WorkAreaType.CULTIVATOR)
    end

    -- Determine if cultivator is currently working
    local spec = self.spec_cultivator
    local isCurrentlyWorking = spec and spec.isWorking or false

    -- Update bird spawning logic
    ToolBirdsExtension:onUpdate(self, dt, isCurrentlyWorking)
end

---
-- Extended onDelete function for Cultivator specialization
-- @param superFunc: Original function
---
function CultivatorExtension:onDelete(superFunc)
    -- Cleanup our extension
    ToolBirdsExtension:onDelete(self)

    -- Call original function
    if superFunc ~= nil then
        superFunc(self)
    end
end

-- Hook into Cultivator specialization
Cultivator.processCultivatorArea = Utils.overwrittenFunction(
    Cultivator.processCultivatorArea,
    CultivatorExtension.processCultivatorArea
)

Cultivator.onEndWorkAreaProcessing = Utils.overwrittenFunction(
    Cultivator.onEndWorkAreaProcessing,
    CultivatorExtension.onEndWorkAreaProcessing
)

Cultivator.onDelete = Utils.overwrittenFunction(
    Cultivator.onDelete,
    CultivatorExtension.onDelete
)

