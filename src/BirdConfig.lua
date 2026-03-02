---
-- BirdConfig
-- Centralized bird configuration manager
-- Loads bird XML configuration once and provides it to all bird instances
---

BirdConfig = {}
BirdConfig.dir = g_currentModDirectory
BirdConfig.config = nil -- Shared config loaded once

---
-- Load bird attributes from XML file
-- @param xmlFile: XML file handle (from loadXMLFile)
-- @param key: Base XML key path
-- @return attributes table with filename, nodeIndex, and animations
---
function BirdConfig.loadAttributesFromXML(xmlFile, key)
    local filename = getXMLString(xmlFile, key .. ".asset#filename")
    local modName = getXMLString(xmlFile, key .. ".asset#modName")

    if modName and modName ~= "" and g_modNameToDirectory and g_modNameToDirectory[modName] then
        filename = g_modNameToDirectory[modName] .. filename
    else
        filename = BirdConfig.dir .. filename
    end

    local attributes = {
        filename = filename,
        nodeIndex = getXMLString(xmlFile, key .. ".asset#node"),
        animCharSetNode = getXMLString(xmlFile, key .. ".animation#animCharSetNode"),
        shapeNodeIndex = getXMLString(xmlFile, key .. ".animation#shapeNode"),
        animations = {},
        soundGroups = {},
        groundIdleTimeMin = getXMLFloat(xmlFile, key .. ".behavior#groundIdleTimeMin") or 0.5,
        groundIdleTimeMax = getXMLFloat(xmlFile, key .. ".behavior#groundIdleTimeMax") or 2.0
    }

    local x = 0
    while true do
        local animKey = string.format("%s.animation.animation(%d)", key, x)
        if not hasXMLProperty(xmlFile, animKey) then
            break
        end

        local stateName = getXMLString(xmlFile, animKey .. "#stateName")
        local anim = {
            name = stateName,
            speed = getXMLFloat(xmlFile, animKey .. "#speed"),
            transitionTime = getXMLFloat(xmlFile, animKey .. "#transitionTime") * 1000, -- Convert to ms
            startFrame = getXMLInt(xmlFile, animKey .. "#startFrame"),
            endFrame = getXMLInt(xmlFile, animKey .. "#endFrame")
        }
        attributes.animations[stateName] = anim
        x = x + 1
    end

    return attributes
end

---
-- Load the bird configuration from XML file
-- Only loads once, subsequent calls return cached config
-- @return attributes table or nil on failure
---
function BirdConfig.loadConfig()
    if BirdConfig.config then
        return BirdConfig.config
    end

    -- Load bird attributes from XML
    local xmlFilename = Utils.getFilename("data/seagull.xml", BirdConfig.dir)
    local xmlFile = loadXMLFile("BirdSpeciesConfig", xmlFilename)

    if xmlFile and xmlFile ~= 0 then
        BirdConfig.config = BirdConfig.loadAttributesFromXML(xmlFile, "species")

        if BirdConfig.config then
            local baseDirectory = BirdConfig.dir
            BirdConfig.config.soundGroups = BirdConfig.loadSoundGroupsFromXML(
                xmlFile,
                baseDirectory
            )

            local soundGroupCount = 0
            for _ in pairs(BirdConfig.config.soundGroups or {}) do
                soundGroupCount = soundGroupCount + 1
            end
        end

        delete(xmlFile)
        return BirdConfig.config
    else
        return nil
    end
end

---
-- Get the shared bird configuration
-- Loads on first call, returns cached config on subsequent calls
-- @return attributes table or nil
---
function BirdConfig.getConfig()
    return BirdConfig.loadConfig()
end

---
-- Reset the cached configuration (useful for debugging/reloading)
---
function BirdConfig.resetConfig()
    BirdConfig.config = nil
end

---
-- Load sound groups from XML (returns file paths, not actual samples)
-- @param xmlFile: XML file handle
-- @param baseDirectory: Base directory for relative paths
-- @return soundGroups table with file paths
---
function BirdConfig.loadSoundGroupsFromXML(xmlFile, baseDirectory)
    local soundGroups = {}

    local soundIndex = 0
    while true do
        local soundKey = string.format("species.sounds.sound(%d)", soundIndex)
        if not hasXMLProperty(xmlFile, soundKey) then
            break
        end

        local soundGroupName = getXMLString(xmlFile, soundKey .. "#name")
        if soundGroupName then
            local soundGroup = {
                name = soundGroupName,
                cooldown = getXMLFloat(xmlFile, soundKey .. "#cooldown") or 0,
                chance = getXMLFloat(xmlFile, soundKey .. "#chance") or 1.0,
                volume = getXMLFloat(xmlFile, soundKey .. "#volume") or 1.0, -- Default to 1.0 if not specified
                fileNames = {}                                               -- Store file paths, not samples
            }

            -- Load all sample file paths in this sound group
            local sampleIndex = 0
            while true do
                local sampleKey = string.format("%s.sample(%d)", soundKey, sampleIndex)
                if not hasXMLProperty(xmlFile, sampleKey) then
                    break
                end

                local filename = getXMLString(xmlFile, sampleKey .. "#filename")
                if filename then
                    if filename:find("$data") then
                        filename = filename:gsub("$data", getUserProfileAppPath() .. "data")
                    else
                        filename = baseDirectory .. filename
                    end
                    table.insert(soundGroup.fileNames, filename)
                end

                sampleIndex = sampleIndex + 1
            end

            if #soundGroup.fileNames > 0 then
                soundGroups[soundGroupName] = soundGroup
            end
        end

        soundIndex = soundIndex + 1
    end

    return soundGroups
end
