---
-- SowingMachineExtension
-- Hooks into the SowingMachine specialization to spawn following birds
---

SowingMachineExtension = {}

---
-- Hook into onStartWorkAreaProcessing to initialize frame tracking
-- @param superFunc: Original function
-- @param dt: Delta time
---
function SowingMachineExtension:onStartWorkAreaProcessing(superFunc, dt)
    if not g_currentMission:getIsClient() then
        if superFunc ~= nil then
            superFunc(self, dt)
        end
        return
    end

    if superFunc ~= nil then
        superFunc(self, dt)
    end
end

---
-- Extended onEndWorkAreaProcessing for SowingMachine specialization
-- @param superFunc: Original function
-- @param dt: Delta time in milliseconds
-- @param hasProcessed: Whether areas were processed
---
function SowingMachineExtension:onEndWorkAreaProcessing(superFunc, dt, hasProcessed)
    if not g_currentMission:getIsClient() then
        if superFunc ~= nil then
            superFunc(self, dt, hasProcessed)
        end
        return
    end

    if superFunc ~= nil then
        superFunc(self, dt, hasProcessed)
    end

    -- Track work areas when processing happened
    if hasProcessed and g_gridFeedingZones then
        local workAreaSpec = self.spec_workArea
        if workAreaSpec and workAreaSpec.workAreas then
            for _, workArea in ipairs(workAreaSpec.workAreas) do
                if workArea.type == WorkAreaType.SOWINGMACHINE then
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
            end
        end
    end

    if not self.toolBirdsData or not self.toolBirdsData.initialized then
        ToolBirdsExtension:initialize(self, WorkAreaType.SOWINGMACHINE)
    end

    local spec = self.spec_sowingMachine
    local isCurrentlyWorking = spec and spec.isWorking or false
    ToolBirdsExtension:reportToolActive(self, dt, isCurrentlyWorking)
end

-- Hook into SowingMachine specialization
SowingMachine.onStartWorkAreaProcessing = Utils.overwrittenFunction(
    SowingMachine.onStartWorkAreaProcessing,
    SowingMachineExtension.onStartWorkAreaProcessing
)

SowingMachine.onEndWorkAreaProcessing = Utils.overwrittenFunction(
    SowingMachine.onEndWorkAreaProcessing,
    SowingMachineExtension.onEndWorkAreaProcessing
)
