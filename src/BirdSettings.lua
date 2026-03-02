---
-- BirdSettings
-- In-game settings menu for Field Gulls mod
---

BirdSettings = {}
BirdSettings.CONTROLS = {}

BirdSettings.menuItems = {
    'birdSoundVolume'
}

-- SETTINGS DEFINITIONS
BirdSettings.SETTINGS = {}

BirdSettings.SETTINGS.birdSoundVolume = {
    ['default'] = 6,  -- 1.0 volume (index 6 in the values array)
    ['serverOnly'] = false,
    ['values'] = { 0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 },
    ['strings'] = { "0%", "20%", "40%", "60%", "80%", "100%", "120%", "140%", "160%", "180%", "200%" }
}

-- Current settings (stored locally, no network sync needed)
BirdSettings.settings = {
    birdSoundVolume = 1.0
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
    BirdSettings.addSettingsToMenu()
end)
