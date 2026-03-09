---
-- BirdManager
-- Global manager for all bird flock managers that runs independent of vehicle state
---

BirdManager = {}
BirdManager.activeFlockManagers = {}

---
-- Initialize the bird manager
---
function BirdManager:loadMap()
    if g_currentMission:getIsServer() then return end

    local birdConfig = BirdConfig.loadConfig()
    if birdConfig and birdConfig.filename then
        g_i3DManager:loadSharedI3DFileAsync(
            birdConfig.filename,
            false, -- callOnCreate
            false, -- addToPhysics
            function(i3dNode, failedReason, args)
                if failedReason ~= 0 then
                    print("[BirdManager] Warning: Failed to preload bird i3d model")
                end
            end,
            nil,
            nil
        )
    end

    -- Initialize global grid feeding zones system
    g_gridFeedingZones = GridFeedingZones.new()
end

---
-- Global update function called every frame
-- @param dt: Delta time in milliseconds
---
function BirdManager:update(dt)
    if g_currentMission:getIsServer() then return end

    if g_gridFeedingZones then
        g_gridFeedingZones:update(dt)
    end

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

---
-- Cleanup on map unload
---
function BirdManager:deleteMap()
    self.activeFlockManagers = {}

    if g_gridFeedingZones then
        g_gridFeedingZones:clear()
        g_gridFeedingZones = nil
    end
end

addModEventListener(BirdManager)
