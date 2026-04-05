---
-- BirdSettings
-- In-game settings menu for Field Gulls mod
---

BirdSettings = {}
BirdSettings.CONTROLS = {}

BirdSettings.menuItems = {
    'birdSoundVolume',
    'maxBirds',
    'chanceOfBirds',
    'maxActiveTools'
}

-- SETTINGS DEFINITIONS
BirdSettings.SETTINGS = {}

BirdSettings.SETTINGS.birdSoundVolume = {
    ['default'] = 6,
    ['serverOnly'] = false,
    ['values'] = { 0, 0.08, 0.16, 0.24, 0.32, 0.4, 0.48, 0.56, 0.64, 0.72, 0.8 },
    ['strings'] = { "0%", "20%", "40%", "60%", "80%", "100%", "120%", "140%", "160%", "180%", "200%" }
}

BirdSettings.SETTINGS.maxBirds = {
    ['default'] = 8,
    ['serverOnly'] = false,
    ['values'] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 120, 140, 160, 180, 200 },
    ['strings'] = { "10", "20", "30", "40", "50", "60", "70", "80", "90", "100", "120", "140", "160", "180", "200" }
}

BirdSettings.SETTINGS.chanceOfBirds = {
    ['default'] = 7,
    ['serverOnly'] = false,
    ['values'] = { 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0 },
    ['strings'] = { "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%" }
}

BirdSettings.SETTINGS.maxActiveTools = {
    ['default'] = 2,
    ['serverOnly'] = false,
    ['values'] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0 },
    ['strings'] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "Unlimited" }
}

-- Current settings (stored locally, no network sync needed)
BirdSettings.settings = {
    birdSoundVolume = 1.0,
    maxBirds = 80,
    chanceOfBirds = 0.7,
    maxActiveTools = 2
}

function BirdSettings.getStateIndex(id, value)
    local value = value or BirdSettings.settings[id]
    local values = BirdSettings.SETTINGS[id].values
    if type(value) == 'number' then
        local index = BirdSettings.SETTINGS[id].default
        local initialdiff = math.huge
        for i, v in pairs(values) do
            local currentdiff = math.abs(v - value)
            if currentdiff < initialdiff then
                initialdiff = currentdiff
                index = i
            end
        end
        return index
    else
        for i, v in pairs(values) do
            if value == v then
                return i
            end
        end
    end
    return BirdSettings.SETTINGS[id].default
end

-- READ/WRITE SETTINGS
function BirdSettings.writeSettings()
    local key = "fieldGulls"
    local userSettingsFile = Utils.getFilename("modSettings/FieldGulls.xml", getUserProfileAppPath())
    
    local xmlFile = createXMLFile("settings", userSettingsFile, key)
    if xmlFile ~= 0 then
        
        local function setXmlValue(id)
            if not id or not BirdSettings.SETTINGS[id] then
                return
            end
            
            local xmlValueKey = "fieldGulls." .. id .. "#value"
            local value = BirdSettings.settings[id]
            if type(value) == 'number' then
                setXMLFloat(xmlFile, xmlValueKey, value)
            elseif type(value) == 'boolean' then
                setXMLBool(xmlFile, xmlValueKey, value)
            end
        end
        
        for _, id in pairs(BirdSettings.menuItems) do
            setXmlValue(id)
        end
        
        saveXMLFile(xmlFile)
        delete(xmlFile)
    end
end

function BirdSettings.readSettings()
    local userSettingsFile = Utils.getFilename("modSettings/FieldGulls.xml", getUserProfileAppPath())
    
    if not fileExists(userSettingsFile) then
        print("[FieldGulls] Creating user settings file: " .. userSettingsFile)
        BirdSettings.writeSettings()
        return
    end
    
    local xmlFile = loadXMLFile("fieldGulls", userSettingsFile)
    if xmlFile ~= 0 then
        
        local function getXmlValue(id)
            local setting = BirdSettings.SETTINGS[id]
            if setting then
                local xmlValueKey = "fieldGulls." .. id .. "#value"
                local value = BirdSettings.settings[id]
                local value_string = tostring(value)
                if hasXMLProperty(xmlFile, xmlValueKey) then
                    
                    if type(value) == 'number' then
                        value = getXMLFloat(xmlFile, xmlValueKey) or value
                        
                        if value == math.floor(value) then
                            value_string = tostring(value)
                        else
                            value_string = string.format("%.3f", value)
                        end
                        
                    elseif type(value) == 'boolean' then
                        value = getXMLBool(xmlFile, xmlValueKey) or false
                        value_string = tostring(value)
                    end
                    
                    BirdSettings.settings[id] = value
                    return value_string
                end
            end
            return "MISSING"
        end
        
        print("[FieldGulls] SETTINGS")
        for _, id in pairs(BirdSettings.menuItems) do
            local valueString = getXmlValue(id)
            print("  " .. id .. ": " .. valueString)
        end
        
        delete(xmlFile)
    end
end

BirdSettingsControls = {}
function BirdSettingsControls.onMenuOptionChanged(self, state, menuOption)
    local id = menuOption.id
    local setting = BirdSettings.SETTINGS
    local value = setting[id].values[state]

    if value ~= nil then
        BirdSettings.settings[id] = value
        
        -- Immediately update all active bird flock sound volumes
        if id == 'birdSoundVolume' and BirdManager then
            for _, flockManager in pairs(BirdManager.activeFlockManagers or {}) do
                if flockManager.updateSoundVolume then
                    flockManager:updateSoundVolume(value)
                end
            end
        end
        
        -- Save settings to disk
        BirdSettings.writeSettings()
    end
end

local function updateFocusIds(element)
    if not element then
        return
    end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        updateFocusIds(child)
    end
end

function BirdSettings.addSettingsToMenu()
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    local settingsPage = inGameMenu.pageSettings
    -- The name is required as otherwise the focus manager would ignore any control which has BirdSettings as a callback target
    BirdSettingsControls.name = settingsPage.name

    function BirdSettings.addMultiMenuOption(id)
        local callback = "onMenuOptionChanged"
        local i18n_title = "setting_birds_" .. id
        local i18n_tooltip = "setting_birds_" .. id .. "_tooltip"
        local options = BirdSettings.SETTINGS[id].strings

        local originalBox = settingsPage.multiVolumeVoiceBox

        local menuOptionBox = originalBox:clone(settingsPage.gameSettingsLayout)
        menuOptionBox.id = id .. "box"

        local menuMultiOption = menuOptionBox.elements[1]
        menuMultiOption.id = id
        menuMultiOption.target = BirdSettingsControls

        menuMultiOption:setCallback("onClickCallback", callback)
        menuMultiOption:setDisabled(false)

        local toolTip = menuMultiOption.elements[1]
        toolTip:setText(g_i18n:getText(i18n_tooltip))

        local setting = menuOptionBox.elements[2]
        setting:setText(g_i18n:getText(i18n_title))

        menuMultiOption:setTexts({ table.unpack(options) })
        menuMultiOption:setState(BirdSettings.getStateIndex(id))

        BirdSettings.CONTROLS[id] = menuMultiOption

        -- Assign new focus IDs to the controls as clone() copies the existing ones which are supposed to be unique
        updateFocusIds(menuOptionBox)
        table.insert(settingsPage.controlsList, menuOptionBox)
        return menuOptionBox
    end

    -- Add section
    local sectionTitle = nil
    for idx, elem in ipairs(settingsPage.gameSettingsLayout.elements) do
        if elem.name == "sectionHeader" then
            sectionTitle = elem:clone(settingsPage.gameSettingsLayout)
            break
        end
    end

    if sectionTitle then
        sectionTitle:setText(g_i18n:getText("setting_birds_section"))
    else
        sectionTitle = TextElement.new()
        sectionTitle:applyProfile("fs25_settingsSectionHeader", true)
        sectionTitle:setText(g_i18n:getText("setting_birds_section"))
        sectionTitle.name = "sectionHeader"
        settingsPage.gameSettingsLayout:addElement(sectionTitle)
    end
    -- Apply a new focus ID in either case
    sectionTitle.focusId = FocusManager:serveAutoFocusId()
    table.insert(settingsPage.controlsList, sectionTitle)
    BirdSettings.CONTROLS[sectionTitle.name] = sectionTitle

    -- Resolve l10n strings that need translation (must happen after g_i18n is available)
    local unlimitedText = g_i18n:getText("setting_birds_unlimited")
    local maxToolsStrings = BirdSettings.SETTINGS.maxActiveTools.strings
    maxToolsStrings[#maxToolsStrings] = unlimitedText

    for _, id in pairs(BirdSettings.menuItems) do
        BirdSettings.addMultiMenuOption(id)
    end

    settingsPage.gameSettingsLayout:invalidateLayout()

    -- ENABLE/DISABLE OPTIONS FOR CLIENTS
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
        for _, id in pairs(BirdSettings.menuItems) do
            local menuOption = BirdSettings.CONTROLS[id]
            menuOption:setState(BirdSettings.getStateIndex(id))

            if BirdSettings.SETTINGS[id].disabled then
                menuOption:setDisabled(true)
            else
                menuOption:setDisabled(false)
            end
        end
    end)
end

-- Allow keyboard navigation of menu options
FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui == "ingameMenuSettings" then
        -- Let the focus manager know about our custom controls now
        for _, control in pairs(BirdSettings.CONTROLS) do
            if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                if not FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                    print(
                        "Could not register control %s with the focus manager. Selecting the control might be bugged",
                        control.id or control.name or control.focusId)
                end
            end
        end
        -- Invalidate the layout so the up/down connections are analyzed again
        local settingsPage = g_gui.screenControllers[InGameMenu].pageSettings
        settingsPage.gameSettingsLayout:invalidateLayout()
    end
end)

-- Initialize settings menu when mission loads
Mission00.load = Utils.appendedFunction(Mission00.load, function()
    -- Load settings from disk first
    BirdSettings.readSettings()
    
    -- Then add menu controls
    BirdSettings.addSettingsToMenu()
end)
