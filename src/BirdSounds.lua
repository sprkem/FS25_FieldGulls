---
-- BirdSounds
-- Manages randomized sound playback for birds with cooldowns
-- Based on WildlifeInstanceSounds pattern
---

BirdSounds = {}
local BirdSounds_mt = Class(BirdSounds)

---
-- Register XML paths for bird sounds
-- @param xmlSchema: The XML schema to register paths to
---
function BirdSounds.registerXMLPaths(xmlSchema)
    xmlSchema:register(XMLValueType.STRING, "species.sounds.sound(?)#name", "The name of the sound group", nil, true)
    xmlSchema:register(XMLValueType.FLOAT, "species.sounds.sound(?)#cooldown", "The time in seconds in which the same sound group cannot be played more than once", 0, false)
    xmlSchema:register(XMLValueType.FLOAT, "species.sounds.sound(?)#chance", "The chance of the sound playing (0.0 to 1.0)", 1, false)
end

---
-- Create a new BirdSounds instance
-- @param bird: The SimpleBirdDirect instance this sounds manager is attached to
-- @return BirdSounds instance
---
function BirdSounds.new(bird)
    local self = setmetatable({}, BirdSounds_mt)

    self.bird = bird
    self.soundPlayedTimestamps = {}  -- Track when each sound group was last played
    self.activeSamples = {}          -- Track currently playing samples (allows multiple different sounds)
    self.soundSamples = {}           -- Per-bird sound samples created from templates

    return self
end

---
-- Initialize the sound system after bird model is loaded
---
function BirdSounds:initialize()
    if not self.bird or not self.bird.rootNode or not self.bird.attributes then
        return false
    end
    
    -- Create actual sound samples for this bird from the sound group templates
    local soundGroupTemplates = self.bird.attributes.soundGroups
    if soundGroupTemplates then
        for groupName, template in pairs(soundGroupTemplates) do
            if template.fileNames and #template.fileNames > 0 then
                -- Create samples for this bird from the file paths
                local samples = {}
                for i, fileName in ipairs(template.fileNames) do
                    -- Create unique sample name using table address
                    local sampleName = string.format("%s_bird%d_%s", groupName, i, tostring(self):gsub("table: ", ""))
                    local sample = createSample(sampleName)
                    
                    if sample then
                        local success = loadSample(sample, fileName, false)
                        if success then
                            setSampleGroup(sample, AudioGroup.ENVIRONMENT)
                            table.insert(samples, sample)
                        else
                            delete(sample)
                        end
                    end
                end
                
                -- Store the samples for this sound group
                if #samples > 0 then
                    self.soundSamples = self.soundSamples or {}
                    self.soundSamples[groupName] = {
                        cooldown = template.cooldown,
                        chance = template.chance,
                        samples = samples
                    }
                end
            end
        end
    end

    return true
end

---
-- Clean up all sound resources
---
function BirdSounds:delete()
    -- Stop and delete all active samples
    for soundGroupName, sample in pairs(self.activeSamples) do
        if sample and isSamplePlaying(sample) then
            stopSample(sample, 0, 0)
        end
    end

    table.clear(self.soundPlayedTimestamps)
    table.clear(self.activeSamples)
    
    -- Delete all per-bird sound samples
    if self.soundSamples then
        for _, soundGroup in pairs(self.soundSamples) do
            if soundGroup.samples then
                for _, sample in ipairs(soundGroup.samples) do
                    if sample then
                        delete(sample)
                    end
                end
            end
        end
        table.clear(self.soundSamples)
    end
end

---
-- Update function - cleanup finished samples from active tracking
-- @param dt: Delta time in milliseconds
---
function BirdSounds:update(dt)
    -- Clean up active sample tracking when sounds finish playing
    for soundGroupName, sample in pairs(self.activeSamples) do
        if sample and not isSamplePlaying(sample) then
            -- Just remove from tracking - don't delete the sample itself
            self.activeSamples[soundGroupName] = nil
        end
    end
end

---
-- Try to play a sound from the given sound group
-- @param soundGroupName: Name of the sound group (e.g., "flying", "landing", "eating")
-- @param chanceOverride: Optional override for the play chance (0.0 to 1.0)
-- @return boolean: True if sound was played, false otherwise
---
function BirdSounds:playSound(soundGroupName, chanceOverride)
    if not self.soundSamples then
        return false
    end

    -- Check if this sound group is already playing (prevent same sound overlapping)
    if self.activeSamples[soundGroupName] and isSamplePlaying(self.activeSamples[soundGroupName]) then
        return false  -- This specific sound is already playing
    end

    -- Get the sound group for this bird
    local soundGroup = self.soundSamples[soundGroupName]
    if not soundGroup then
        return false
    end

    -- Check if there are any samples in this group
    if not soundGroup.samples or #soundGroup.samples == 0 then
        return false
    end

    -- Check cooldown (time since last played)
    local lastPlayedTime = self.soundPlayedTimestamps[soundGroupName] or 0
    local cooldown = (soundGroup.cooldown or 0) * 1000  -- Convert seconds to milliseconds
    if g_time - lastPlayedTime < cooldown then
        return false  -- Still in cooldown period
    end

    -- Check random chance
    local chance = chanceOverride or soundGroup.chance or 1.0
    if math.random() > chance then
        return false  -- Random chance failed
    end

    -- Pick a random sample from the group
    local randomSample = soundGroup.samples[math.random(#soundGroup.samples)]
    if not randomSample then
        return false
    end

    -- Play the sample
    playSample(randomSample, 1, 1, 0, 0, 0)
    
    -- Track this sample
    self.activeSamples[soundGroupName] = randomSample
    self.soundPlayedTimestamps[soundGroupName] = g_time
    
    return true
end

---
-- Stop a specific sound group
-- @param soundGroupName: Name of the sound group to stop
---
function BirdSounds:stopSound(soundGroupName)
    local sample = self.activeSamples[soundGroupName]
    if sample then
        if isSamplePlaying(sample) then
            stopSample(sample, 0, 0)
        end
        self.activeSamples[soundGroupName] = nil
    end
end

---
-- Check if a specific sound group is currently playing
-- @param soundGroupName: Name of the sound group
-- @return boolean: True if playing, false otherwise
---
function BirdSounds:isSoundPlaying(soundGroupName)
    local sample = self.activeSamples[soundGroupName]
    return sample ~= nil and isSamplePlaying(sample)
end

---
-- Load sound attributes from XML file (called from BirdConfig)
-- @param xmlFile: The XML file handle (from loadXMLFile)
-- @param baseDirectory: Base directory for sound files
-- @param linkNode: Link node for sound positioning (not used, kept for API compatibility)
-- @return soundGroups table with file paths (not actual samples)
---
function BirdSounds.loadSoundGroupsFromXML(xmlFile, baseDirectory, linkNode)
    local soundGroups = {}

    -- Iterate through all sound groups
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
                fileNames = {}  -- Store file paths, not samples
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
                    -- Handle path resolution
                    if filename:find("$data") then
                        -- Replace $data with game data path
                        filename = filename:gsub("$data", getUserProfileAppPath() .. "data")
                    else
                        -- Relative path - prepend base directory
                        filename = baseDirectory .. filename
                    end
                    table.insert(soundGroup.fileNames, filename)
                end

                sampleIndex = sampleIndex + 1
            end

            -- Only add sound group if it has file paths
            if #soundGroup.fileNames > 0 then
                soundGroups[soundGroupName] = soundGroup
            end
        end

        soundIndex = soundIndex + 1
    end

    return soundGroups
end

---
-- Delete all loaded sound groups (cleanup)
-- @param soundGroups: The soundGroups table loaded from XML
---
function BirdSounds.deleteSoundGroups(soundGroups)
    -- No cleanup needed - we only store file paths, not actual samples
    -- Actual samples are created per-bird and cleaned up when each bird is deleted
end
