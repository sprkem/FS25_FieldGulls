---
-- CurvedPathPlanner
-- Generates curved flight paths using cubic Bezier curves for natural bird movement
---

CurvedPathPlanner = {}
local CurvedPathPlanner_mt = Class(CurvedPathPlanner)

---
-- Create a new curved path from start to end position
-- @param startX, startY, startZ: Starting position
-- @param endX, endY, endZ: Ending position
-- @param curvature: How curved the path should be (0.0-1.0, default 0.5)
-- @return CurvedPathPlanner instance
---
function CurvedPathPlanner.new(startX, startY, startZ, endX, endY, endZ, curvature)
    local self = setmetatable({}, CurvedPathPlanner_mt)
    
    curvature = curvature or 0.5
    
    -- Store start and end points
    self.startX = startX
    self.startY = startY
    self.startZ = startZ
    
    self.endX = endX
    self.endY = endY
    self.endZ = endZ
    
    -- Calculate control points for cubic Bezier curve
    -- P0 = start, P1 = control1, P2 = control2, P3 = end
    self:calculateControlPoints(curvature)
    
    -- Precompute path segments for efficient lookup
    self.segments = 20  -- Number of segments to divide the curve
    self.segmentPoints = {}
    self:precomputeSegments()
    
    -- Calculate total path length
    self.totalLength = self:calculatePathLength()
    
    return self
end

---
-- Calculate control points for the Bezier curve
-- Creates control points that make the path curve naturally
-- @param curvature: Strength of the curve (0.0-1.0)
---
function CurvedPathPlanner:calculateControlPoints(curvature)
    -- Direction vector from start to end
    local dx = self.endX - self.startX
    local dy = self.endY - self.startY
    local dz = self.endZ - self.startZ
    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
    
    if distance < 0.1 then
        -- Points are too close, use linear path
        self.control1X = self.startX
        self.control1Y = self.startY
        self.control1Z = self.startZ
        self.control2X = self.endX
        self.control2Y = self.endY
        self.control2Z = self.endZ
        return
    end
    
    -- Normalized direction
    local ndx = dx / distance
    local ndy = dy / distance
    local ndz = dz / distance
    
    -- Create perpendicular vector for curve offset
    -- Use world up vector (0,1,0) to create perpendicular
    local perpX = -ndz
    local perpZ = ndx
    local perpLength = math.sqrt(perpX*perpX + perpZ*perpZ)
    
    if perpLength > 0.001 then
        perpX = perpX / perpLength
        perpZ = perpZ / perpLength
    else
        -- Fallback if direction is straight up/down
        perpX = 1.0
        perpZ = 0.0
    end
    
    -- Add some randomness to curve direction for variety
    local curveOffset = distance * curvature * (0.2 + math.random() * 0.3)  -- 20-50% of distance
    local curveAngle = (math.random() - 0.5) * math.pi  -- Random curve direction
    
    -- Rotate perpendicular vector by random angle
    local offsetX = math.cos(curveAngle) * perpX * curveOffset
    local offsetZ = math.sin(curveAngle) * perpZ * curveOffset
    local offsetY = (math.random() - 0.5) * distance * curvature * 0.3  -- Slight vertical curve variation
    
    -- Control point 1: 1/3 along path, offset perpendicular for initial curve
    self.control1X = self.startX + dx * 0.33 + offsetX
    self.control1Y = self.startY + dy * 0.33 + offsetY
    self.control1Z = self.startZ + dz * 0.33 + offsetZ
    
    -- Control point 2: Much closer to end (90% of path) with minimal offset for straighter approach
    -- This makes the end of the curve much gentler
    self.control2X = self.startX + dx * 0.90 - offsetX * 0.1
    self.control2Y = self.startY + dy * 0.90 - offsetY * 0.1
    self.control2Z = self.startZ + dz * 0.90 - offsetZ * 0.1
    
    if math.random() < 0.05 then
        print(string.format("[CurvedPathPlanner] Created curve: start=(%.1f,%.1f,%.1f) end=(%.1f,%.1f,%.1f) curve=%.2f", 
            self.startX, self.startY, self.startZ, self.endX, self.endY, self.endZ, curvature))
    end
end

---
-- Cubic Bezier curve evaluation
-- B(t) = (1-t)³P0 + 3(1-t)²t*P1 + 3(1-t)t²*P2 + t³*P3
-- @param t: Parameter from 0 to 1
-- @return x, y, z: Position on curve at parameter t
---
function CurvedPathPlanner:evaluateBezier(t)
    -- Clamp t to [0, 1]
    t = math.max(0, math.min(1, t))
    
    local t2 = t * t
    local t3 = t2 * t
    local mt = 1 - t
    local mt2 = mt * mt
    local mt3 = mt2 * mt
    
    -- Bezier basis functions
    local b0 = mt3
    local b1 = 3 * mt2 * t
    local b2 = 3 * mt * t2
    local b3 = t3
    
    -- Calculate position
    local x = b0 * self.startX + b1 * self.control1X + b2 * self.control2X + b3 * self.endX
    local y = b0 * self.startY + b1 * self.control1Y + b2 * self.control2Y + b3 * self.endY
    local z = b0 * self.startZ + b1 * self.control1Z + b2 * self.control2Z + b3 * self.endZ
    
    return x, y, z
end

---
-- Precompute segment points along the curve for efficient lookup
---
function CurvedPathPlanner:precomputeSegments()
    for i = 0, self.segments do
        local t = i / self.segments
        local x, y, z = self:evaluateBezier(t)
        table.insert(self.segmentPoints, {x = x, y = y, z = z, t = t})
    end
end

---
-- Calculate the approximate total length of the path
-- Uses segment approximation
-- @return number: Total path length in meters
---
function CurvedPathPlanner:calculatePathLength()
    local totalLength = 0
    
    for i = 2, #self.segmentPoints do
        local p1 = self.segmentPoints[i-1]
        local p2 = self.segmentPoints[i]
        
        local dx = p2.x - p1.x
        local dy = p2.y - p1.y
        local dz = p2.z - p1.z
        
        totalLength = totalLength + math.sqrt(dx*dx + dy*dy + dz*dz)
    end
    
    return totalLength
end

---
-- Get position on path given distance traveled
-- @param distance: Distance traveled along path in meters
-- @return x, y, z: Position on path
-- @return completed: True if reached end of path
---
function CurvedPathPlanner:getPositionAtDistance(distance)
    if distance <= 0 then
        return self.startX, self.startY, self.startZ, false
    end
    
    if distance >= self.totalLength then
        return self.endX, self.endY, self.endZ, true
    end
    
    -- Find which segment we're in
    local accumulatedLength = 0
    
    for i = 2, #self.segmentPoints do
        local p1 = self.segmentPoints[i-1]
        local p2 = self.segmentPoints[i]
        
        local dx = p2.x - p1.x
        local dy = p2.y - p1.y
        local dz = p2.z - p1.z
        local segmentLength = math.sqrt(dx*dx + dy*dy + dz*dz)
        
        if accumulatedLength + segmentLength >= distance then
            -- We're in this segment
            local segmentProgress = (distance - accumulatedLength) / segmentLength
            
            local x = p1.x + dx * segmentProgress
            local y = p1.y + dy * segmentProgress
            local z = p1.z + dz * segmentProgress
            
            return x, y, z, false
        end
        
        accumulatedLength = accumulatedLength + segmentLength
    end
    
    -- Fallback (shouldn't reach here)
    return self.endX, self.endY, self.endZ, true
end

---
-- Get position on path given parameter t (0 to 1)
-- @param t: Parameter from 0 (start) to 1 (end)
-- @return x, y, z: Position on path
---
function CurvedPathPlanner:getPositionAtParameter(t)
    return self:evaluateBezier(t)
end

---
-- Get tangent direction at position on path
-- Useful for orienting the bird
-- @param t: Parameter from 0 to 1
-- @return dx, dy, dz: Normalized direction vector
---
function CurvedPathPlanner:getTangentAtParameter(t)
    -- Derivative of cubic Bezier curve
    -- B'(t) = 3(1-t)²(P1-P0) + 6(1-t)t(P2-P1) + 3t²(P3-P2)
    
    t = math.max(0, math.min(1, t))
    
    local mt = 1 - t
    local mt2 = mt * mt
    local t2 = t * t
    
    -- Bezier derivative basis functions
    local b0 = 3 * mt2
    local b1 = 6 * mt * t
    local b2 = 3 * t2
    
    -- Direction vectors between control points
    local d1x = self.control1X - self.startX
    local d1y = self.control1Y - self.startY
    local d1z = self.control1Z - self.startZ
    
    local d2x = self.control2X - self.control1X
    local d2y = self.control2Y - self.control1Y
    local d2z = self.control2Z - self.control1Z
    
    local d3x = self.endX - self.control2X
    local d3y = self.endY - self.control2Y
    local d3z = self.endZ - self.control2Z
    
    -- Calculate tangent
    local dx = b0 * d1x + b1 * d2x + b2 * d3x
    local dy = b0 * d1y + b1 * d2y + b2 * d3y
    local dz = b0 * d1z + b1 * d2z + b2 * d3z
    
    -- Normalize
    local length = math.sqrt(dx*dx + dy*dy + dz*dz)
    if length > 0.001 then
        dx = dx / length
        dy = dy / length
        dz = dz / length
    else
        -- Fallback: direction from start to end
        dx = self.endX - self.startX
        dy = self.endY - self.startY
        dz = self.endZ - self.startZ
        length = math.sqrt(dx*dx + dy*dy + dz*dz)
        if length > 0.001 then
            dx = dx / length
            dy = dy / length
            dz = dz / length
        else
            dx, dy, dz = 0, 0, 1  -- Default forward
        end
    end
    
    return dx, dy, dz
end

---
-- Get the total length of the path
-- @return number: Path length in meters
---
function CurvedPathPlanner:getTotalLength()
    return self.totalLength
end

---
-- Check if a position is close to the end of the path
-- @param x, y, z: Position to check
-- @param threshold: Distance threshold (default 0.5m)
-- @return boolean: True if near end
---
function CurvedPathPlanner:isNearEnd(x, y, z, threshold)
    threshold = threshold or 0.5
    
    local dx = x - self.endX
    local dy = y - self.endY
    local dz = z - self.endZ
    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
    
    return distance < threshold
end
