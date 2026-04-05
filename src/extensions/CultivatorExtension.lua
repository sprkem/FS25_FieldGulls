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
    if not g_currentMission:getIsClient() then return superFunc(self, workArea, dt) end

    -- Call original function first
    local changedArea, totalArea = superFunc(self, workArea, dt)

    -- Track grid cells for bird feeding whenever we're called
    if g_gridFeedingZones then
        local sx, sy, sz = getWorldTranslation(workArea.start)
        local wx, wy, wz = getWorldTranslation(workArea.width)
        local hx, hy, hz = getWorldTranslation(workArea.height)

        -- Get affected grid cells
        local cells = GridFeedingZones.getAffectedGridCells(sx, sz, wx, wz, hx, hz)

        -- Add cells to global grid system, tagged with this tool's ID
        local toolId = self.toolBirdsData and self.toolBirdsData.toolId
        for _, cell in ipairs(cells) do
            g_gridFeedingZones:addCellImmediate(cell.gridX, cell.gridZ, toolId)
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
    if not g_currentMission:getIsClient() then
        if superFunc ~= nil then
            superFunc(self, dt)
        end
        return
    end

    if superFunc ~= nil then
        superFunc(self, dt)
    end

    if not self.toolBirdsData or not self.toolBirdsData.initialized then
        ToolBirdsExtension:initialize(self, WorkAreaType.CULTIVATOR)
    end

    local spec = self.spec_cultivator
    local isCurrentlyWorking = spec and spec.isWorking or false
    ToolBirdsExtension:reportToolActive(self, dt, isCurrentlyWorking)
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
