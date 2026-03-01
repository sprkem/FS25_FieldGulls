---
-- BirdManager
-- Global manager for all bird hotspots that runs independent of vehicle state
-- This ensures birds continue to update even when vehicles are optimized/inactive
---

BirdManager = {}
BirdManager.activeHotspots = {}

---
-- Initialize the bird manager
---
function BirdManager:loadMap()
    print("[BirdManager] Manager initialized")
end

---
-- Global update function called every frame
-- @param dt: Delta time in milliseconds
---
function BirdManager:update(dt)
    -- Update all registered hotspots
    for vehicle, hotspot in pairs(self.activeHotspots) do
        if hotspot and hotspot.update then
            hotspot:update(dt)
        end
    end
end

---
-- Register a hotspot for continuous updates
-- @param vehicle: The vehicle this hotspot belongs to
-- @param hotspot: The hotspot instance
---
function BirdManager:registerHotspot(vehicle, hotspot)
    if vehicle and hotspot then
        self.activeHotspots[vehicle] = hotspot
    end
end

---
-- Unregister a hotspot (called when vehicle is deleted or hotspot deactivated)
-- @param vehicle: The vehicle that owned the hotspot
---
function BirdManager:unregisterHotspot(vehicle)
    if vehicle then
        self.activeHotspots[vehicle] = nil
    end
end

---
-- Cleanup on map unload
---
function BirdManager:deleteMap()
    self.activeHotspots = {}
end

-- Register with the mod event system so update() is called every frame
addModEventListener(BirdManager)
