---
-- PlowExtension
-- Hooks into the Plow specialization to spawn following birds
---

PlowExtension = {}

---
-- Hook into plow area processing to track grid cells for bird feeding
-- @param superFunc: Original processPlowArea function
-- @param workArea: The work area being processed
-- @param dt: Delta time
---
function PlowExtension:processPlowArea(superFunc, workArea, dt)
    if g_currentMission:getIsServer() then return superFunc(self, workArea, dt) end

    local r1, r2 = superFunc(self, workArea, dt)

    if g_gridFeedingZones then
        local sx, sy, sz = getWorldTranslation(workArea.start)
        local wx, wy, wz = getWorldTranslation(workArea.width)
        local hx, hy, hz = getWorldTranslation(workArea.height)

        -- Get affected grid cells
        local cells = GridFeedingZones.getAffectedGridCells(sx, sz, wx, wz, hx, hz)

        -- Add cells to global grid system
        for _, cell in ipairs(cells) do
            g_gridFeedingZones:addCellImmediate(cell.gridX, cell.gridZ)
        end
    end

    return r1, r2
end

---
-- Extended onEndWorkAreaProcessing for Plow specialization
-- @param superFunc: Original function
-- @param dt: Delta time in milliseconds
---
function PlowExtension:onEndWorkAreaProcessing(superFunc, dt)
    if g_currentMission:getIsServer() then
        if superFunc ~= nil then
            superFunc(self, dt)
        end
        return
    end

    if superFunc ~= nil then
        superFunc(self, dt)
    end

    if not self.toolBirdsData or not self.toolBirdsData.initialized then
        ToolBirdsExtension:initialize(self, WorkAreaType.PLOW)
    end

    local spec = self.spec_plow
    local isCurrentlyWorking = spec and spec.isWorking or false

    ToolBirdsExtension:onUpdate(self, dt, isCurrentlyWorking)
end

---
-- Extended onDelete function for Plow specialization
-- @param superFunc: Original function
---
function PlowExtension:onDelete(superFunc)
    ToolBirdsExtension:onDelete(self)

    if superFunc ~= nil then
        superFunc(self)
    end
end

-- Hook into Plow specialization
Plow.processPlowArea = Utils.overwrittenFunction(
    Plow.processPlowArea,
    PlowExtension.processPlowArea
)

Plow.onEndWorkAreaProcessing = Utils.overwrittenFunction(
    Plow.onEndWorkAreaProcessing,
    PlowExtension.onEndWorkAreaProcessing
)

Plow.onDelete = Utils.overwrittenFunction(
    Plow.onDelete,
    PlowExtension.onDelete
)
