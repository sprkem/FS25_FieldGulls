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

                    -- Add cells to global grid system
                    for _, cell in ipairs(cells) do
                        g_gridFeedingZones:addCell(cell.gridX, cell.gridZ)
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
    ToolBirdsExtension:onUpdate(self, dt, isCurrentlyWorking)
end

---
-- Extended onDelete function for SowingMachine specialization
-- @param superFunc: Original function
---
function SowingMachineExtension:onDelete(superFunc)
    ToolBirdsExtension:onDelete(self)

    if superFunc ~= nil then
        superFunc(self)
    end
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

SowingMachine.onDelete = Utils.overwrittenFunction(
    SowingMachine.onDelete,
    SowingMachineExtension.onDelete
)
