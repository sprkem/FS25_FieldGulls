---
-- ToolBirdsExtension
-- Generic utility methods for spawning following birds on any tool type
---

ToolBirdsExtension = {}

---
-- Initialize bird data on a vehicle
-- @param vehicle: The vehicle to extend
-- @param workAreaType: The WorkAreaType enum value for this tool
---
function ToolBirdsExtension:initialize(vehicle, workAreaType)
    if not vehicle or not workAreaType then
        return
    end

    -- Add our extension data to the vehicle
    vehicle.toolBirdsData = {
        flockManager = nil,
        isWorking = false,
        initialized = true,
        workAreaType = workAreaType
    }
end

---
-- Generic update function to manage bird spawning/despawning
-- @param vehicle: The vehicle with tool
-- @param dt: Delta time in milliseconds
-- @param isCurrentlyWorking: Boolean indicating if the tool is currently working
---
function ToolBirdsExtension:onUpdate(vehicle, dt, isCurrentlyWorking)
    if not vehicle.toolBirdsData or not vehicle.toolBirdsData.initialized then
        return
    end

    local data = vehicle.toolBirdsData

    -- Handle state transitions
    if isCurrentlyWorking and not data.isWorking then
        -- Just started working - activate flock and cancel any despawn timer
        ToolBirdsExtension:activateFlockManager(vehicle)
        if data.flockManager then
            data.flockManager:cancelDespawnTimer()
        end
        data.isWorking = true
    elseif not isCurrentlyWorking and data.isWorking then
        -- Just stopped working - start despawn timer on flock
        data.isWorking = false
        if data.flockManager then
            data.flockManager:startDespawnTimer()
        end
    end
end

---
-- Activate the bird flock manager for this tool
-- @param vehicle: The vehicle with tool
---
function ToolBirdsExtension:activateFlockManager(vehicle)
    local data = vehicle.toolBirdsData

    if not data then
        return
    end

    if not data.flockManager then
        data.flockManager = ToolBirdFlockManager.new(vehicle, data.workAreaType)
    end

    data.flockManager:activate()
end

---
-- Deactivate and cleanup the bird flock manager
-- @param vehicle: The vehicle with tool
---
function ToolBirdsExtension:deactivateFlockManager(vehicle)
    local data = vehicle.toolBirdsData

    if not data or not data.flockManager then
        return
    end

    data.flockManager:cleanup()
end

---
-- Cleanup when vehicle is deleted
-- @param vehicle: The vehicle with tool
---
function ToolBirdsExtension:onDelete(vehicle)
    if vehicle.toolBirdsData and vehicle.toolBirdsData.flockManager then
        ToolBirdsExtension:deactivateFlockManager(vehicle)

        if BirdManager then
            BirdManager:unregisterFlockManager(vehicle)
        end

        vehicle.toolBirdsData = nil
    end
end
