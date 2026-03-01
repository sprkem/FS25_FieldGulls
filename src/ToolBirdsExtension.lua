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
        hotspot = nil,
        isWorking = false,
        despawnTimer = 0,
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
        -- Just started working - activate hotspot
        ToolBirdsExtension:activateHotspot(vehicle)
        data.isWorking = true
        data.despawnTimer = 0
    elseif not isCurrentlyWorking and data.isWorking then
        -- Just stopped working - start despawn timer
        data.isWorking = false
        data.despawnTimer = ToolBirdHotspotDirect.DESPAWN_DELAY
    end

    -- Update hotspot position even when inactive (for despawning birds)
    if data.hotspot then
        data.hotspot:update(dt)
    end

    -- Handle despawn timer
    if not data.isWorking and data.despawnTimer > 0 then
        data.despawnTimer = data.despawnTimer - dt

        if data.despawnTimer <= 0 then
            -- Timer expired - cleanup birds
            ToolBirdsExtension:deactivateHotspot(vehicle)
        end
    end
end

---
-- Activate the bird hotspot for this tool
-- @param vehicle: The vehicle with tool
---
function ToolBirdsExtension:activateHotspot(vehicle)
    local data = vehicle.toolBirdsData

    if not data then
        return
    end

    -- Create hotspot if it doesn't exist
    if not data.hotspot then
        data.hotspot = ToolBirdHotspotDirect.new(vehicle, data.workAreaType)
    end

    -- Activate the hotspot
    if data.hotspot:activate() then
        -- Spawn initial birds once
        data.hotspot:spawnInitialBirds()
    end
end

---
-- Deactivate and cleanup the bird hotspot
-- @param vehicle: The vehicle with tool
---
function ToolBirdsExtension:deactivateHotspot(vehicle)
    local data = vehicle.toolBirdsData

    if not data or not data.hotspot then
        return
    end

    data.hotspot:cleanup()
    data.despawnTimer = 0
end

---
-- Cleanup when vehicle is deleted
-- @param vehicle: The vehicle with tool
---
function ToolBirdsExtension:onDelete(vehicle)
    if vehicle.toolBirdsData and vehicle.toolBirdsData.hotspot then
        ToolBirdsExtension:deactivateHotspot(vehicle)
        vehicle.toolBirdsData = nil
    end
end

