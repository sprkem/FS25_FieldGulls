---
-- BirdManager
-- Global manager for all bird flock managers that runs independent of vehicle state
-- This ensures birds continue to update even when vehicles are optimized/inactive
---

BirdManager = {}
BirdManager.activeFlockManagers = {}

---
-- Initialize the bird manager
---
function BirdManager:loadMap()
    print("[BirdManager] Manager initialized")
    
    -- Preload bird configuration to avoid lag spike on first bird spawn
    local birdConfig = BirdConfig.loadConfig()
    
    -- Preload the bird i3d model so it's cached when first bird spawns
    if birdConfig and birdConfig.filename then
        print("[BirdManager] Preloading bird i3d model...")
        g_i3DManager:loadSharedI3DFileAsync(
            birdConfig.filename,
            false, -- callOnCreate
            false, -- addToPhysics
            function(i3dNode, failedReason, args)
                if failedReason == 0 and i3dNode and i3dNode ~= 0 then
                    print("[BirdManager] Bird i3d model preloaded and cached")
                    -- Model is now cached, will be instant for actual birds
                    -- We don't need to do anything with the node, just let it cache
                else
                    print("[BirdManager] Warning: Failed to preload bird i3d model")
                end
            end,
            nil,
            nil
        )
    end
    
    -- Initialize global grid feeding zones system
    g_gridFeedingZones = GridFeedingZones.new()
    print("[BirdManager] Grid feeding zones initialized")
end

---
-- Global update function called every frame
-- @param dt: Delta time in milliseconds
---
function BirdManager:update(dt)
    -- Update grid feeding zones (expire old cells)
    if g_gridFeedingZones then
        g_gridFeedingZones:update(dt)
    end
    
    -- Update all registered flock managers
    for vehicle, flockManager in pairs(self.activeFlockManagers) do
        if flockManager and flockManager.update then
            flockManager:update(dt)
        end
    end
end

---
-- Register a flock manager for continuous updates
-- @param vehicle: The vehicle this flock manager belongs to
-- @param flockManager: The flock manager instance
---
function BirdManager:registerFlockManager(vehicle, flockManager)
    if vehicle and flockManager then
        self.activeFlockManagers[vehicle] = flockManager
    end
end

---
-- Unregister a flock manager (called when vehicle is deleted or flock deactivated)
-- @param vehicle: The vehicle that owned the flock manager
---
function BirdManager:unregisterFlockManager(vehicle)
    if vehicle then
        self.activeFlockManagers[vehicle] = nil
    end
end

    
    -- Clear grid feeding zones
    if g_gridFeedingZones then
        g_gridFeedingZones:clear()
        g_gridFeedingZones = nil
    end
---
-- Cleanup on map unload
---
function BirdManager:deleteMap()
    self.activeFlockManagers = {}
end

-- Register with the mod event system so update() is called every frame
addModEventListener(BirdManager)
