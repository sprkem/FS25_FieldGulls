---
-- PlowExtension
-- Hooks into the Plow specialization to spawn following birds
---

PlowExtension = {}

-- Configuration
PlowExtension.MIN_WORKING_SPEED = 0.5 -- Minimum speed to be considered "working"

---
-- Extended onUpdate function for Plow specialization
-- @param superFunc: Original function
-- @param dt: Delta time in milliseconds
-- @param isActiveForInput: Whether active for input
-- @param isActiveForInputIgnoreSelection: Whether active for input ignoring selection
-- @param isSelected: Whether selected
---
function PlowExtension:onUpdate(superFunc, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    -- Call original function
    if superFunc ~= nil then
        superFunc(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    end

    -- Initialize birds data if needed
    if not self.toolBirdsData or not self.toolBirdsData.initialized then
        ToolBirdsExtension:initialize(self, WorkAreaType.PLOW)
    end

    -- Determine if plow is currently working
    local isLowered = self.getIsLowered and self:getIsLowered() or false
    local isPowered = self:getIsPowered()
    local speed = self:getLastSpeed()
    local isCurrentlyWorking = isLowered and isPowered and speed > PlowExtension.MIN_WORKING_SPEED

    -- Update bird spawning logic
    ToolBirdsExtension:onUpdate(self, dt, isCurrentlyWorking)
end

---
-- Extended onDelete function for Plow specialization
-- @param superFunc: Original function
---
function PlowExtension:onDelete(superFunc)
    -- Cleanup our extension
    ToolBirdsExtension:onDelete(self)

    -- Call original function
    if superFunc ~= nil then
        superFunc(self)
    end
end

-- Hook into Plow specialization
Plow.onUpdate = Utils.overwrittenFunction(
    Plow.onUpdate,
    PlowExtension.onUpdate
)

Plow.onDelete = Utils.overwrittenFunction(
    Plow.onDelete,
    PlowExtension.onDelete
)
