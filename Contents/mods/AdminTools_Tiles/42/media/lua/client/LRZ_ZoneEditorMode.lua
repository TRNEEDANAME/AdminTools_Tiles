-- LRZ_ZoneEditorMode.lua
-- Adds a "Loot / Tile change zone" mode to the admin Zone Editor (Admin Panel -> Zone Editor).
-- Draw a rectangle on the map like a Non-PvP zone, pick floors / categories /
-- percent, and bulk-remove, or open the Loot Adder / Tile Swap window for the
-- drawn area.
-- Also what puts this mod's modes in the editor (this one and "Building",
-- see AdminTools_Tiles_BuildZoneMode), and what makes the editor usable in single player.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISModalDialog"
require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode"
require "ISUI/AdminPanel/ZoneEditor/ISMultiplayerZoneEditor"
require "ISUI/Maps/Editor/WorldMapEditorResizer"
require "LRZ_Shared"
require "LRZ_CategoryPicker"
require "LRZ_AdderUI"
require "ISTileSwapUI"
require "AdminTools_Tiles_UIUtil"

LRZ_ZoneEditorMode = MultiplayerZoneEditorMode:derive("LRZ_ZoneEditorMode")
LRZ_ZoneEditorMode.instance = nil
LRZ_ZoneEditorMode.MODE_KEY = "LootRemoval"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local CAT_COL_W = 140
local CAT_COLS = 3
local PANEL_W = CAT_COL_W * CAT_COLS + PADDING * 2

function LRZ_ZoneEditorMode:new(editor)
    local o = MultiplayerZoneEditorMode.new(self, editor)
    o.resizer = WorldMapEditorResizer:new(editor)
    o.resizer.snapMode = "square"
    o.hasArea = false
    o.mode = nil -- "StartDrawingBounds", "DrawBounds", "Resize"
    -- on the class it's made from: a mode derived from this one keeps its own
    self.instance = o
    return o
end

function LRZ_ZoneEditorMode:createChildren()
    local top = self.editor.modeCombo:getBottom() + PADDING

    -- Dark backing panel so the controls stay readable over the map
    local panel = ISPanel:new(PADDING, top, PANEL_W, 100)
    panel:initialise()
    panel.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    panel.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    -- Clicks on the panel background shouldn't start drawing / pan the map
    panel.onMouseDown = function() return true end
    panel.onMouseUp = function() return true end
    self:addChild(panel)
    self.panel = panel

    local y = PADDING
    local title = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "Loot Removal & Tile Swap", 1, 1, 1, 1, UIFont.Medium, true)
    panel:addChild(title)
    y = y + getTextManager():getFontHeight(UIFont.Medium) + 8

    self.drawBtn = ISButton:new(PADDING, y, 120, BTN_H, "Draw Area", self, LRZ_ZoneEditorMode.onDrawArea)
    self.drawBtn:initialise()
    panel:addChild(self.drawBtn)

    self.clearBtn = ISButton:new(PADDING + 130, y, 80, BTN_H, "Clear", self, LRZ_ZoneEditorMode.onClearArea)
    self.clearBtn:initialise()
    panel:addChild(self.clearBtn)
    y = y + BTN_H + 6

    self.areaLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "No area drawn", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel:addChild(self.areaLabel)
    y = y + FONT_HGT_SMALL + 8

    self.floors = AdminTools_Tiles_UIUtil.createFloorRow(panel, PADDING, y, BTN_H)
    y = y + BTN_H + 10

    self.categories = LRZ_CategoryPicker.create(panel, PADDING, y, CAT_COL_W, CAT_COLS, nil)
    y = self.categories.bottom + 10

    local percentLabel = ISLabel:new(PADDING, y, BTN_H, "Percent:", 1, 1, 1, 1, UIFont.Small, true)
    panel:addChild(percentLabel)
    local px = PADDING + getTextManager():MeasureStringX(UIFont.Small, "Percent:") + 8

    self.percentEntry = ISTextEntryBox:new("100", px, y, 45, BTN_H)
    self.percentEntry:initialise()
    self.percentEntry:instantiate()
    self.percentEntry:setOnlyNumbers(true)
    panel:addChild(self.percentEntry)

    self.removeBtn = ISButton:new(px + 55, y, 150, BTN_H, "Remove Loot", self, LRZ_ZoneEditorMode.onRemove)
    self.removeBtn:initialise()
    panel:addChild(self.removeBtn)
    y = y + BTN_H + 8

    self.adderBtn = ISButton:new(PADDING, y, PANEL_W - PADDING * 2, BTN_H, "Add Loot...", self, LRZ_ZoneEditorMode.onOpenAdder)
    self.adderBtn:initialise()
    panel:addChild(self.adderBtn)
    y = y + BTN_H + 8

    -- Tile Swap is admin only (see TileCopy.Util.isAdmin)
    if TileCopy.Util.isAdmin(getPlayer()) then
        self.swapBtn = ISButton:new(PADDING, y, PANEL_W - PADDING * 2, BTN_H, "Swap Tiles...", self, LRZ_ZoneEditorMode.onOpenSwap)
        self.swapBtn:initialise()
        panel:addChild(self.swapBtn)
        y = y + BTN_H + 8
    end

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    panel:addChild(self.statusLabel)
    y = y + FONT_HGT_SMALL + 4

    local note = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "Loot: loaded areas only. Tile swaps wait for the rest to load.", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    panel:addChild(note)
    y = y + FONT_HGT_SMALL + PADDING

    panel:setHeight(y)
end

-------------------------------------------------------------------------------
-- Area
-------------------------------------------------------------------------------

-- The resizer's bounds sit on tile edges
function LRZ_ZoneEditorMode:getTileBounds()
    local r = self.resizer
    return r.x1, r.y1, r.x2 - 1, r.y2 - 1
end

function LRZ_ZoneEditorMode:isAreaValid()
    local r = self.resizer
    return r.x1 < r.x2 and r.y1 < r.y2
end

function LRZ_ZoneEditorMode:updateAreaLabel()
    if not self.hasArea then
        self.areaLabel:setName("No area drawn")
        return
    end
    local x1, y1, x2, y2 = self:getTileBounds()
    self.areaLabel:setName((x2 - x1 + 1) .. " x " .. (y2 - y1 + 1) .. " tiles  (" .. x1 .. "," .. y1 .. " -> " .. x2 .. "," .. y2 .. ")")
end

function LRZ_ZoneEditorMode:onDrawArea()
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        return
    end
    self.mode = "StartDrawingBounds"
end

function LRZ_ZoneEditorMode:onClearArea()
    self:cancelResize()
    self.hasArea = false
    self.resizer:setBounds(0, 0, 0, 0)
    self:updateAreaLabel()
end

-- Area + floors, or nil and why not. Also used by the Loot Adder window.
function LRZ_ZoneEditorMode:getLootArgs()
    if not self.hasArea then
        return nil, "Draw an area in the Zone Editor first."
    end
    local x1, y1, x2, y2 = self:getTileBounds()
    local z1, z2 = self.floors:getRange()
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z1 = z1, z2 = z2, ground = self.categories:includeGround() }
end

function LRZ_ZoneEditorMode:onOpenAdder()
    LRZ_AdderUI.open(self)
end

-- Opens the Tile Swap window on the drawn area and floors. Press again after
-- redrawing / resizing to hand it the new area.
function LRZ_ZoneEditorMode:onOpenSwap()
    local args, err = self:getLootArgs()
    if not args then
        self:setStatus(err, true)
        return
    end
    local ui = ISTileSwapUI.open()
    if not ui then return end
    ui:setArea(args.x1, args.y1, args.x2, args.y2, args.z1, args.z2)
    -- Has to show over the full-screen Zone Editor
    ui:setAlwaysOnTop(true)
    ui:bringToTop()
end

-------------------------------------------------------------------------------
-- Removal
-------------------------------------------------------------------------------

function LRZ_ZoneEditorMode:onRemove()
    local args, err = self:getLootArgs()
    if not args then
        self:setStatus(err, true)
        return
    end
    local percent = tonumber(self.percentEntry:getText()) or 100
    args.percent = AdminTools_Tiles_Util.clamp(percent, 0, 100)
    args.categories = self.categories:getRequestCategories()
    if not args.categories then
        self:setStatus("Tick at least one category.", true)
        return
    end
    local tooBig = LRZ.TooBigMessage(args)
    if tooBig then
        self:setStatus(tooBig, true)
        return
    end

    local text = string.format("Remove %d%% of %s in %s?",
        args.percent, self.categories:describe(), LRZ.DescribeArea(args))
    local mx, my = AdminTools_Tiles_UIUtil.centeredOn(self.panel, 450, 150)
    local modal = ISModalDialog:new(mx, my, 450, 150, text, true, self, LRZ_ZoneEditorMode.onConfirmRemove, nil, args)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    self.modalUI = modal
end

function LRZ_ZoneEditorMode:onConfirmRemove(button, args)
    self.modalUI = nil
    if button.internal ~= "YES" then return end
    self:setStatus("Removing...")
    sendClientCommand(getPlayer(), LRZ.ModuleName, LRZ.CMD_REMOVE_LOOT, args)
end

function LRZ_ZoneEditorMode:setStatus(text, isError)
    AdminTools_Tiles_UIUtil.setStatus(self.statusLabel, text, isError)
end

-------------------------------------------------------------------------------
-- Map interaction (same flow as the vanilla Non-PvP mode)
-------------------------------------------------------------------------------

function LRZ_ZoneEditorMode:prerender()
    self.clearBtn:setEnable(self.hasArea)
    self.removeBtn:setEnable(self.hasArea)
    if self.swapBtn then self.swapBtn:setEnable(self.hasArea) end
    self.drawBtn:setTitle(self.mode == "StartDrawingBounds" and "Cancel Draw" or "Draw Area")
end

function LRZ_ZoneEditorMode:render()
    if self.hasArea or self.mode == "DrawBounds" or self.mode == "Resize" then
        local r, g, b = 1, 0.45, 0
        if (self.mode == "DrawBounds" or self.mode == "Resize") and not self:isAreaValid() then
            r, g, b = 1, 0, 0
        end
        self.resizer:render(r, g, b, 1)
    end

    if self.mode == "StartDrawingBounds" then
        local mx = self.mapUI:getMouseX()
        local my = self.mapUI:getMouseY()
        local worldX = self.resizer:snap(self.mapAPI:uiToWorldX(mx, my))
        local worldY = self.resizer:snap(self.mapAPI:uiToWorldY(mx, my))
        mx = self.mapAPI:worldToUIX(worldX, worldY)
        my = self.mapAPI:worldToUIY(worldX, worldY)
        self.mapUI:drawRectBorder(mx - 10, my - 10, 20, 20, 1, 1, 0.45, 0)
        self.mapUI:drawRectBorder(mx - 10 - 1, my - 10 - 1, 20 + 2, 20 + 2, 1, 1, 0.45, 0)
    end
end

function LRZ_ZoneEditorMode:onMouseDown(x, y)
    if self.mode == "StartDrawingBounds" then
        self.mode = "DrawBounds"
        local worldX = self.resizer:snap(self.mapAPI:uiToWorldX(x, y))
        local worldY = self.resizer:snap(self.mapAPI:uiToWorldY(x, y))
        self.resizer:setBounds(worldX, worldY, worldX, worldY)
        self.resizer:startResizing()
        return true
    end
    if self.hasArea then
        local resizeMode = self.resizer:hitTest(x, y)
        if not resizeMode then return false end
        self.resizer:startResizing()
        self.mode = "Resize"
        self.resizeMode = resizeMode
        return true
    end
    return false -- allow clicks in the map
end

function LRZ_ZoneEditorMode:onMouseUp(x, y)
    if self.mode == "DrawBounds" then
        self.mode = nil
        self.resizer:endResizing()
        self.hasArea = self:isAreaValid()
        self:updateAreaLabel()
        return true
    end
    if self.mode == "Resize" then
        self.mode = nil
        self.resizeMode = nil
        if self:isAreaValid() then
            self.resizer:endResizing()
        else
            self.resizer:cancelResize()
        end
        self:updateAreaLabel()
        return true
    end
    return false -- allow clicks in the map
end

function LRZ_ZoneEditorMode:onMouseUpOutside(x, y)
    return self:onMouseUp(x, y)
end

function LRZ_ZoneEditorMode:onMouseMove(dx, dy)
    if self.mode == "DrawBounds" then
        self.resizer:onMouseMove(self:getMouseX(), self:getMouseY(), "BottomRight")
        return true
    end
    if self.mode == "Resize" then
        self.resizer:onMouseMove(self:getMouseX(), self:getMouseY(), self.resizeMode)
        return true
    end
    if self.mode then
        return true
    end
    return false -- allow clicks in the map
end

function LRZ_ZoneEditorMode:onRightMouseDown(x, y)
    return self:cancelResize()
end

function LRZ_ZoneEditorMode:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then
        return self:cancelResize()
    end
    return false
end

function LRZ_ZoneEditorMode:cancelResize()
    if self.mode == "DrawBounds" then
        self.mode = nil
        self.resizer:endResizing()
        self.hasArea = false
        self:updateAreaLabel()
        return true
    end
    if self.mode == "Resize" then
        self.mode = nil
        self.resizeMode = nil
        self.resizer:cancelResize()
        return true
    end
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        return true
    end
    return false
end

function LRZ_ZoneEditorMode:undisplay()
    if self.modalUI then
        self.modalUI:setVisible(false)
        self.modalUI:removeFromUIManager()
        self.modalUI = nil
    end
    self:cancelResize()
    MultiplayerZoneEditorMode.undisplay(self)
end

-------------------------------------------------------------------------------
-- Hooking into the vanilla editor
-------------------------------------------------------------------------------

-- The modes this mod adds to the editor, in the order of the dropdown:
-- { key=, label=, class=, canUse=function(player) }. Other files add theirs
-- with LRZ_ZoneEditorMode.registerMode (see AdminTools_Tiles_BuildZoneMode).
local modes = {
    {
        key = LRZ_ZoneEditorMode.MODE_KEY, label = "Loot / Tile change zone",
        class = LRZ_ZoneEditorMode, canUse = LRZ.CanUse,
    },
}

function LRZ_ZoneEditorMode.registerMode(mode)
    modes[#modes + 1] = mode
end

-- Adds our modes to the editor's mode dropdown (once each) for allowed users.
local function addModeOptions(editor)
    if not editor.mode then return end
    local player = getPlayer()
    local combo = editor.modeCombo

    for _, mode in ipairs(modes) do
        local listed = false
        for i = 1, #combo.options do
            if combo:getOptionData(i) == mode.key then listed = true end
        end
        if not listed and editor.mode[mode.key] and mode.canUse(player) then
            combo:addOptionWithData(mode.label, mode.key)
            -- Nothing else available to this user: open straight into our mode
            if not editor.currentMode then
                combo.selected = #combo.options
                editor:onSwitchMode(mode.key)
            end
        end
    end
end

-- What the vanilla createChildren builds, without its Non-PvP and Safehouse
-- modes: single player has no roles, and those look the player's up as soon
-- as they are created (the editor is opened from the right-click "Tile
-- Admin" menu there).
local function createChildrenSinglePlayer(editor)
    editor.modeCombo = ISComboBox:new(PADDING, PADDING, 200, FONT_HGT_SMALL + 4, editor, editor.onComboChangeMode)
    editor:addChild(editor.modeCombo)
    editor.mode = {}

    local btnSize = editor.texViewIsometric and editor.texViewIsometric:getWidth() or 48
    editor.buttonPanel = ISMultiplayerZoneEditor_ButtonPanel:new(editor.width - 200, editor.height - PADDING - btnSize, 200, btnSize, editor)
    editor.buttonPanel.anchorLeft = false
    editor.buttonPanel.anchorRight = true
    editor.buttonPanel.anchorTop = false
    editor.buttonPanel.anchorBottom = true
    editor:addChild(editor.buttonPanel)
end

local originalCreateChildren = ISMultiplayerZoneEditor.createChildren
function ISMultiplayerZoneEditor:createChildren()
    if isClient() then
        originalCreateChildren(self)
    else
        createChildrenSinglePlayer(self)
    end

    for _, mode in ipairs(modes) do
        local panel = mode.class:new(self)
        self.mode[mode.key] = panel
        self:addChild(panel)
        panel:setVisible(false)
    end

    -- Keep the zoom / close buttons on top of our full-screen mode panels
    if self.buttonPanel then
        self:removeChild(self.buttonPanel)
        self:addChild(self.buttonPanel)
    end

    addModeOptions(self)
end

-- Single player has no roles to look up here either: only our modes are listed.
local originalOnRolesReceived = ISMultiplayerZoneEditor.OnRolesReceived
function ISMultiplayerZoneEditor.OnRolesReceived()
    if isClient() then
        originalOnRolesReceived()
    elseif ISMultiplayerZoneEditor_instance then
        ISMultiplayerZoneEditor_instance.modeCombo:clear()
    end
end
Events.OnRolesReceived.Remove(originalOnRolesReceived)
Events.OnRolesReceived.Add(ISMultiplayerZoneEditor.OnRolesReceived)

-- Vanilla rebuilds the dropdown whenever roles arrive
Events.OnRolesReceived.Add(function()
    if ISMultiplayerZoneEditor_instance then
        addModeOptions(ISMultiplayerZoneEditor_instance)
    end
end)
