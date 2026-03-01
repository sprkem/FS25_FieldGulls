---
-- CultivatorExtension
-- Hooks into the Cultivator specialization to spawn following birds
-- Note: Cultivator doesn't have onUpdate, so we use onEndWorkAreaProcessing
---

CultivatorExtension = {}

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
Cultivator.onEndWorkAreaProcessing = Utils.overwrittenFunction(
    Cultivator.onEndWorkAreaProcessing,
    CultivatorExtension.onEndWorkAreaProcessing
)

Cultivator.onDelete = Utils.overwrittenFunction(
    Cultivator.onDelete,
    CultivatorExtension.onDelete
)
