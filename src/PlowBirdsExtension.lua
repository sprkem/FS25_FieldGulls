---
-- PlowBirdsExtension
-- Extends the Plow specialization to spawn following birds while working
---

PlowBirdsExtension = {}

-- Configuration
PlowBirdsExtension.DESPAWN_DELAY = 10000  -- 10 seconds in milliseconds
PlowBirdsExtension.MIN_WORKING_SPEED = 0.5  -- Minimum speed to be considered "working"

---
-- Initialize the extension on a plow vehicle
-- @param vehicle: The plow vehicle
---
function PlowBirdsExtension:initialize(vehicle)
    if not vehicle.spec_plow then
        return
    end
    
    -- Add our extension data to the vehicle
    vehicle.plowBirdsData = {
        hotspot = nil,
        isWorking = false,
        wasWorkingLastFrame = false,
        despawnTimer = 0,
        initialized = true
    }
end

---
-- Extended onUpdate function for Plow specialization
-- @param vehicle: The plow vehicle
-- @param dt: Delta time in milliseconds
---
function PlowBirdsExtension:onUpdate(vehicle, dt)
    -- Check if we have the necessary components
    if not vehicle.plowBirdsData or not vehicle.plowBirdsData.initialized then
        PlowBirdsExtension:initialize(vehicle)
    end
    
    if not vehicle.plowBirdsData then
        return
    end
    
    local data = vehicle.plowBirdsData
    local spec = vehicle.spec_plow
    
    if not spec then
        return
    end
    
    -- Check if wildlife manager exists
    if not g_wildlifeManager then
        return
    end
    
    -- Determine if plow is currently working
    local isLowered = vehicle.getIsLowered and vehicle:getIsLowered() or false
    local isPowered = vehicle:getIsPowered()
    local speed = vehicle:getLastSpeed()
    
    -- Plow is working if it's lowered, powered, and moving
    local isCurrentlyWorking = isLowered and isPowered and speed > PlowBirdsExtension.MIN_WORKING_SPEED
    
    -- Debug logging (occasionally)
    if math.random() < 0.01 then
        print(string.format("[PlowBirdsExtension] lowered=%s, powered=%s, speed=%.2f, working=%s",
            tostring(isLowered), tostring(isPowered), speed, tostring(isCurrentlyWorking)))
    end
    
    -- Handle state transitions
    if isCurrentlyWorking and not data.isWorking then
        -- Just started working - activate hotspot
        print("[PlowBirdsExtension] === PLOW STARTED WORKING ===")
        PlowBirdsExtension:activateHotspot(vehicle)
        data.isWorking = true
        data.despawnTimer = 0
    elseif not isCurrentlyWorking and data.isWorking then
        -- Just stopped working - start despawn timer
        print("[PlowBirdsExtension] === PLOW STOPPED WORKING - Starting despawn timer ===")
        data.isWorking = false
        data.despawnTimer = PlowBirdsExtension.DESPAWN_DELAY
    end
    
    -- Update hotspot position if active
    if data.hotspot and data.hotspot:getIsActive() then
        data.hotspot:update(dt)
    end
    
    -- Handle despawn timer
    if not data.isWorking and data.despawnTimer > 0 then
        data.despawnTimer = data.despawnTimer - dt
        
        if data.despawnTimer <= 0 then
            -- Timer expired - cleanup birds
            PlowBirdsExtension:deactivateHotspot(vehicle)
        end
    end
    
    data.wasWorkingLastFrame = isCurrentlyWorking
end

---
-- Activate the bird hotspot for this plow
-- @param vehicle: The plow vehicle
---
function PlowBirdsExtension:activateHotspot(vehicle)
    local data = vehicle.plowBirdsData
    
    if not data then
        return
    end
    
    -- Create hotspot if it doesn't exist
    if not data.hotspot then
        data.hotspot = PlowBirdHotspot.new(g_wildlifeManager, vehicle)
    end
    
    -- Activate the hotspot
    if data.hotspot:activate() then
        print("[PlowBirdsExtension] Hotspot activated, spawning birds for " .. vehicle:getName())
        -- Spawn initial birds once
        data.hotspot:spawnInitialBirds()
    else
        print("[PlowBirdsExtension] ERROR: Failed to activate hotspot for " .. vehicle:getName())
    end
end

---
-- Deactivate and cleanup the bird hotspot
-- @param vehicle: The plow vehicle
---
function PlowBirdsExtension:deactivateHotspot(vehicle)
    local data = vehicle.plowBirdsData
    
    if not data or not data.hotspot then
        return
    end
    
    print("[PlowBirdsExtension] === DEACTIVATING HOTSPOT ===")
    data.hotspot:cleanup()
    data.despawnTimer = 0
end

---
-- Cleanup when vehicle is deleted
-- @param vehicle: The plow vehicle
---
function PlowBirdsExtension:onDelete(vehicle)
    if vehicle.plowBirdsData and vehicle.plowBirdsData.hotspot then
        PlowBirdsExtension:deactivateHotspot(vehicle)
        vehicle.plowBirdsData = nil
    end
end

---
-- Extended onUpdate function for Plow specialization
-- @param superFunc: Original function
-- @param dt: Delta time in milliseconds
-- @param isActiveForInput: Whether active for input
-- @param isActiveForInputIgnoreSelection: Whether active for input ignoring selection
-- @param isSelected: Whether selected
---
function PlowBirdsExtension:plowOnUpdate(superFunc, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    -- Call original function
    if superFunc ~= nil then
        superFunc(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    end
    
    -- Add our bird spawning logic
    PlowBirdsExtension:onUpdate(self, dt)
end

---
-- Extended onDelete function for Plow specialization
-- @param superFunc: Original function
---
function PlowBirdsExtension:plowOnDelete(superFunc)
    -- Cleanup our extension
    PlowBirdsExtension:onDelete(self)
    
    -- Call original function
    if superFunc ~= nil then
        superFunc(self)
    end
end

-- Hook into Plow specialization using Utils.overwrittenFunction
Plow.onUpdate = Utils.overwrittenFunction(
    Plow.onUpdate,
    PlowBirdsExtension.plowOnUpdate
)

Plow.onDelete = Utils.overwrittenFunction(
    Plow.onDelete,
    PlowBirdsExtension.plowOnDelete
)
