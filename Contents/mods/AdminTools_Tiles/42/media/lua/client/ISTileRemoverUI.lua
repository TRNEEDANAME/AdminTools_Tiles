--[[
    ISTileRemoverUI.lua  (client)

    Tile Remover window:
      - drag out the area on the ground (same blue square as the Tile Copy tool)
      - pick a floor range (multiple Z levels) and which layers to remove
      - floors aren't left as a black void: at ground level they turn back
        into grass / dirt / sand ("Auto" matches the ground around the area)
      - "Undo Last" puts everything back (same undo as the Tile Copy paste)
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISTickBox"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISLabel"
require "ISUI/ISModalDialog"
require "TileAdmin_Core"
require "AdminTools_Tiles_UIUtil"
require "ISTileCopyTool"

ISTileRemoverUI = ISCollapsableWindow:derive("ISTileRemoverUI")
ISTileRemoverUI.instance = nil

local Util = TileCopy.Util
local Admin = TileCopy.Admin

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local WIDTH = 420

function ISTileRemoverUI:new()
    local height = 300
    local x = (getCore():getScreenWidth() / 2) - (WIDTH / 2)
    local y = (getCore():getScreenHeight() / 2) - (height / 2)

    local o = ISCollapsableWindow:new(x, y, WIDTH, height)
    setmetatable(o, self)
    self.__index = self

    o.title = "Tile Remover"
    o:setResizable(false)
    o.area = nil -- { x1, y1, x2, y2 }
    return o
end

function ISTileRemoverUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local y = self:titleBarHeight() + PADDING

    self.selectBtn = ISButton:new(PADDING, y, 150, BTN_H, "Drag Select Area", self, ISTileRemoverUI.onSelectArea)
    self.selectBtn:initialise()
    self:addChild(self.selectBtn)
    y = y + BTN_H + 6

    self.areaLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "No area selected", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.areaLabel)
    y = y + FONT_HGT_SMALL + 6

    self.floors = AdminTools_Tiles_UIUtil.createFloorRow(self, PADDING, y, BTN_H)

    self.myFloorBtn = ISButton:new(self.floors.right + 10, y, 90, BTN_H, "My Floor", self, ISTileRemoverUI.onMyFloor)
    self.myFloorBtn:initialise()
    self:addChild(self.myFloorBtn)
    y = y + BTN_H + 10

    -- What to remove
    self.optionsTick = ISTickBox:new(PADDING, y, WIDTH - PADDING * 2, FONT_HGT_SMALL, "", nil, nil)
    self.optionsTick:initialise()
    self.optionsTick:setFont(UIFont.Small)
    self.optionsTick:addOption("Furniture / structures")
    self.optionsTick:addOption("Walls / doors / windows")
    self.optionsTick:addOption("Overlay (clutter / decals / plants)")
    self.optionsTick:addOption("Floors (turned back into natural ground)")
    for i = 1, 4 do
        self.optionsTick:setSelected(i, true)
    end
    self:addChild(self.optionsTick)
    y = y + self.optionsTick.height + 10

    self.groundLabel = ISLabel:new(PADDING, y, BTN_H, "Ground:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.groundLabel)
    local gx = PADDING + getTextManager():MeasureStringX(UIFont.Small, "Ground:") + 8

    self.groundCombo = ISComboBox:new(gx, y, WIDTH - gx - PADDING, BTN_H, nil, nil)
    self.groundCombo:initialise()
    for _, ground in ipairs(Admin.GROUNDS) do
        self.groundCombo:addOptionWithData(ground.label, ground.id)
    end
    self:addChild(self.groundCombo)
    y = y + BTN_H + 12

    local btnW = (WIDTH - PADDING * 3) / 2
    self.removeBtn = ISButton:new(PADDING, y, btnW, BTN_H, "Remove Tiles", self, ISTileRemoverUI.onRemove)
    self.removeBtn:initialise()
    self:addChild(self.removeBtn)

    self.undoBtn = ISButton:new(PADDING * 2 + btnW, y, btnW, BTN_H, "Undo Last", self, ISTileRemoverUI.onUndo)
    self.undoBtn:initialise()
    self:addChild(self.undoBtn)
    y = y + BTN_H + 8

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)
    y = y + FONT_HGT_SMALL + 8

    self.closeBtn = ISButton:new(WIDTH - PADDING - 100, y, 100, BTN_H, "Close", self, ISTileRemoverUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
    y = y + BTN_H + PADDING

    self:setHeight(y)
    self.removeBtn:setEnable(false)
end

function ISTileRemoverUI:onMyFloor()
    self.floors:setFloor(AdminTools_Tiles_Util.playerFloor())
end

function ISTileRemoverUI:onSelectArea()
    if not ISTileCopyTool.instance then return end
    self:setVisible(false)
    ISTileCopyTool.instance:startSelecting(AdminTools_Tiles_Util.playerFloor(), function(x1, y1, x2, y2, zSel)
        ISTileCopyTool.instance:cancel()
        self.area = {
            x1 = math.min(x1, x2), y1 = math.min(y1, y2),
            x2 = math.max(x1, x2), y2 = math.max(y1, y2),
        }
        local w = self.area.x2 - self.area.x1 + 1
        local h = self.area.y2 - self.area.y1 + 1
        self.areaLabel:setName(w .. " x " .. h .. " tiles  (" .. self.area.x1 .. "," .. self.area.y1 .. " -> " .. self.area.x2 .. "," .. self.area.y2 .. ")")
        -- Default the floor range to the floor the drag was made on
        self.floors:setFloor(zSel)
        self.removeBtn:setEnable(true)
        self:setVisible(true)
        self:bringToTop()
    end)
end

function ISTileRemoverUI:buildArgs()
    local z1, z2 = self.floors:getRange()
    return {
        x1 = self.area.x1, y1 = self.area.y1, x2 = self.area.x2, y2 = self.area.y2,
        z1 = z1, z2 = z2,
        tiles = self.optionsTick:isSelected(1),
        walls = self.optionsTick:isSelected(2),
        overlay = self.optionsTick:isSelected(3),
        floors = self.optionsTick:isSelected(4),
        ground = self.groundCombo:getOptionData(self.groundCombo.selected),
    }
end

function ISTileRemoverUI:onRemove()
    if not self.area then return end
    local args = self:buildArgs()
    if not (args.tiles or args.walls or args.overlay or args.floors) then
        self:setStatus("Tick at least one thing to remove.", true)
        return
    end
    -- Client-side size check so the admin gets feedback before the round trip.
    local area, err = Admin.normalizeArea(args)
    if not area then
        self:setStatus(err, true)
        return
    end

    local w = area.x2 - area.x1 + 1
    local h = area.y2 - area.y1 + 1
    local floorCount = area.z2 - area.z1 + 1
    local text = "Remove the tiles in this " .. w .. " x " .. h .. " area (" .. floorCount .. " floor(s))?"
    local mx, my = AdminTools_Tiles_UIUtil.centeredOn(self, 340, 120)
    local modal = ISModalDialog:new(mx, my, 340, 120, text, true, self, ISTileRemoverUI.onRemoveConfirmed, nil, args)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function ISTileRemoverUI:onRemoveConfirmed(button, args)
    if button.internal ~= "YES" then return end
    self:setStatus("Removing...")
    TileCopy.ClientCommands.requestRemove(args)
end

--- Outcome of the last request (see Admin.removeArea), or nil plus a reason.
function ISTileRemoverUI:onResult(result, err)
    if not result then
        self:setStatus(tostring(err or "Removal failed."), true)
        return
    end
    if result.squares == 0 then
        self:setStatus("Nothing found - is the area loaded (near a player)?", true)
        return
    end
    self:setStatus("Removed " .. tostring(result.removed) .. " tile(s), reset " .. tostring(result.floors) .. " floor(s).")
end

function ISTileRemoverUI:onUndo()
    -- replaced by what the undo did once it's known (see TileCopy_ClientCommands)
    self:setStatus("Undo requested.")
    TileCopy.ClientCommands.requestUndo()
end

function ISTileRemoverUI:setStatus(text, isError)
    AdminTools_Tiles_UIUtil.setStatus(self.statusLabel, text, isError)
end

function ISTileRemoverUI:onClose()
    self:setVisible(false)
end

function ISTileRemoverUI:close()
    self:setVisible(false)
end

function ISTileRemoverUI.open()
    if not Util.isAdmin(getPlayer()) then return end

    if not ISTileRemoverUI.instance then
        local ui = ISTileRemoverUI:new()
        ui:initialise()
        ui:addToUIManager()
        ISTileRemoverUI.instance = ui
    else
        ISTileRemoverUI.instance:setVisible(true)
    end
    ISTileRemoverUI.instance:bringToTop()
    return ISTileRemoverUI.instance
end
