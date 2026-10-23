-- AdminTools_Tiles_BuildZoneMode.lua
-- Adds a "Building" mode to the Zone Editor, next to "Loot / Tile change zone".
-- Draw a rectangle on the map (the inside of a room), pick a floor tile and a
-- wall tile, and build the floor, the walls around it (corner and pillar
-- included) or both, on every floor of the range.
-- It also copies houses: "Copy House" takes the drawn area on every floor of
-- the range, "Paste House" puts it down where the map is clicked.
--
-- The area drawing is LRZ_ZoneEditorMode's; the building itself is
-- TileCopy.Admin.buildRoom, the copy / paste TileCopy.Core's, so "Undo Last"
-- takes either back.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISModalDialog"
require "LRZ_ZoneEditorMode"
require "ISTileBrushUI"
require "ISTileCopyUI"
require "TileAdmin_Core"
require "AdminTools_Tiles_UIUtil"

AdminTools_Tiles_BuildZoneMode = LRZ_ZoneEditorMode:derive("AdminTools_Tiles_BuildZoneMode")
AdminTools_Tiles_BuildZoneMode.MODE_KEY = "Building"

local Core = TileCopy.Core
local Admin = TileCopy.Admin

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local PANEL_W = 440
local PICK_W = 70

-- What the tile boxes start with: the wooden floor and a house wall
local DEFAULT_FLOOR = "carpentry_02_56"
local DEFAULT_WALL = "walls_exterior_house_01_0"

function AdminTools_Tiles_BuildZoneMode:new(editor)
    local o = LRZ_ZoneEditorMode.new(self, editor)
    -- o.mode can also be "StartPaste": the next click on the map pastes
    o.house = nil -- the last house copied (a clipboard, see Core.captureHouse)
    return o
end

--- Adds a "label: [sprite name] [Pick...]" row to the panel and returns its
--- text box.
function AdminTools_Tiles_BuildZoneMode:createTileRow(y, text, sprite, labelW)
    local label = ISLabel:new(PADDING, y, BTN_H, text, 1, 1, 1, 1, UIFont.Small, true)
    self.panel:addChild(label)

    local x = PADDING + labelW + 8
    local entry = ISTextEntryBox:new(sprite, x, y, PANEL_W - x - PICK_W - PADDING - 6, BTN_H)
    entry:initialise()
    entry:instantiate()
    self.panel:addChild(entry)

    local pickBtn = ISButton:new(PANEL_W - PADDING - PICK_W, y, PICK_W, BTN_H, "Pick...", self, AdminTools_Tiles_BuildZoneMode.onPickTile)
    pickBtn:initialise()
    pickBtn.entry = entry
    self.panel:addChild(pickBtn)
    return entry
end

function AdminTools_Tiles_BuildZoneMode:createChildren()
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
    local title = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "Building", 1, 1, 1, 1, UIFont.Medium, true)
    panel:addChild(title)
    y = y + getTextManager():getFontHeight(UIFont.Medium) + 8

    self.drawBtn = ISButton:new(PADDING, y, 120, BTN_H, "Draw Area", self, LRZ_ZoneEditorMode.onDrawArea)
    self.drawBtn:initialise()
    panel:addChild(self.drawBtn)

    self.clearBtn = ISButton:new(PADDING + 130, y, 80, BTN_H, "Clear", self, LRZ_ZoneEditorMode.onClearArea)
    self.clearBtn:initialise()
    panel:addChild(self.clearBtn)

    self.myBuildingBtn = ISButton:new(PADDING + 220, y, 130, BTN_H, "My Building", self, AdminTools_Tiles_BuildZoneMode.onMyBuilding)
    self.myBuildingBtn:initialise()
    self.myBuildingBtn:setTooltip("Sets the area to the building you are standing in.")
    panel:addChild(self.myBuildingBtn)
    y = y + BTN_H + 6

    self.areaLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "No area drawn", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel:addChild(self.areaLabel)
    y = y + FONT_HGT_SMALL + 8

    self.floors = AdminTools_Tiles_UIUtil.createFloorRow(panel, PADDING, y, BTN_H)
    y = y + BTN_H + 10

    -- Floor and walls
    local tm = getTextManager()
    local labelW = math.max(tm:MeasureStringX(UIFont.Small, "Floor tile:"), tm:MeasureStringX(UIFont.Small, "Wall tile:"))
    self.floorEntry = self:createTileRow(y, "Floor tile:", DEFAULT_FLOOR, labelW)
    y = y + BTN_H + 6
    self.wallEntry = self:createTileRow(y, "Wall tile:", DEFAULT_WALL, labelW)
    self.wallEntry:setTooltip("Any piece of the wall: its west / north walls, corner and pillar are found from it.")
    y = y + BTN_H + 8

    local btnW = (PANEL_W - PADDING * 4) / 3
    self.buildFloorBtn = ISButton:new(PADDING, y, btnW, BTN_H, "Build Floor", self, AdminTools_Tiles_BuildZoneMode.onBuildFloor)
    self.buildFloorBtn:initialise()
    panel:addChild(self.buildFloorBtn)

    self.buildWallsBtn = ISButton:new(PADDING * 2 + btnW, y, btnW, BTN_H, "Build Walls", self, AdminTools_Tiles_BuildZoneMode.onBuildWalls)
    self.buildWallsBtn:initialise()
    self.buildWallsBtn:setTooltip("Walls all around the area, with the corner and the pillar.")
    panel:addChild(self.buildWallsBtn)

    self.buildRoomBtn = ISButton:new(PADDING * 3 + btnW * 2, y, btnW, BTN_H, "Build Room", self, AdminTools_Tiles_BuildZoneMode.onBuildRoom)
    self.buildRoomBtn:initialise()
    self.buildRoomBtn:setTooltip("The floor and the walls.")
    panel:addChild(self.buildRoomBtn)
    y = y + BTN_H + 12

    -- Houses
    local houseTitle = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "Copy / paste a house", 1, 1, 1, 1, UIFont.Small, true)
    panel:addChild(houseTitle)
    y = y + FONT_HGT_SMALL + 4

    local halfW = (PANEL_W - PADDING * 3) / 2
    self.copyHouseBtn = ISButton:new(PADDING, y, halfW, BTN_H, "Copy House", self, AdminTools_Tiles_BuildZoneMode.onCopyHouse)
    self.copyHouseBtn:initialise()
    self.copyHouseBtn:setTooltip("Copies the drawn area on every floor of the range. It has to be loaded (near you).")
    panel:addChild(self.copyHouseBtn)

    self.pasteHouseBtn = ISButton:new(PADDING * 2 + halfW, y, halfW, BTN_H, "Paste House", self, AdminTools_Tiles_BuildZoneMode.onPasteHouse)
    self.pasteHouseBtn:initialise()
    self.pasteHouseBtn:setTooltip("Then click the map where its top-left corner goes. Its lowest floor lands on the first floor of the range.")
    panel:addChild(self.pasteHouseBtn)
    y = y + BTN_H + 4

    self.houseLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "No house copied", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel:addChild(self.houseLabel)
    y = y + FONT_HGT_SMALL + 10

    self.undoBtn = ISButton:new(PADDING, y, PANEL_W - PADDING * 2, BTN_H, "Undo Last", self, AdminTools_Tiles_BuildZoneMode.onUndo)
    self.undoBtn:initialise()
    panel:addChild(self.undoBtn)
    y = y + BTN_H + 8

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    panel:addChild(self.statusLabel)
    y = y + FONT_HGT_SMALL + 4

    local note = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "Loaded areas only: stand near what you build, copy or paste.", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    panel:addChild(note)
    y = y + FONT_HGT_SMALL + PADDING

    panel:setHeight(y)
end

-------------------------------------------------------------------------------
-- Area
-------------------------------------------------------------------------------

--- Area + floors, or nil and why not.
function AdminTools_Tiles_BuildZoneMode:getArea()
    if not self.hasArea then
        return nil, "Draw an area on the map first."
    end
    local x1, y1, x2, y2 = self:getTileBounds()
    local z1, z2 = self.floors:getRange()
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z1 = z1, z2 = z2 }
end

function AdminTools_Tiles_BuildZoneMode:onMyBuilding()
    local player = getPlayer()
    local square = player and player:getCurrentSquare()
    local building = square and square:getBuilding()
    local def = building and building:getDef()
    if not def then
        self:setStatus("Stand inside a building first.", true)
        return
    end
    self:cancelResize()
    -- + 1: the south and east walls stand on the squares just past the rooms
    self.resizer:setBounds(def:getX(), def:getY(), def:getX() + def:getW() + 1, def:getY() + def:getH() + 1)
    self.hasArea = true
    self:updateAreaLabel()
    self.mapAPI:centerOn(player:getX(), player:getY())
    self:setStatus("Area set to your building. Set its floors, then Copy House.")
end

-------------------------------------------------------------------------------
-- Floor and walls
-------------------------------------------------------------------------------

function AdminTools_Tiles_BuildZoneMode:onPickTile(button)
    local entry = button.entry
    ISTileBrushUI.pick(function(sprite)
        entry:setText(sprite)
    end)
end

local function entryText(entry)
    return entry:getText():match("^%s*(.-)%s*$")
end

function AdminTools_Tiles_BuildZoneMode:build(withFloor, withWalls)
    local args, err = self:getArea()
    if not args then
        self:setStatus(err, true)
        return
    end
    -- Checked here too so the admin gets the reason before the round trip
    if withFloor then
        args.floor = entryText(self.floorEntry)
        if not getSprite(args.floor) then
            self:setStatus("Unknown floor tile: " .. args.floor, true)
            return
        end
    end
    if withWalls then
        args.wall = entryText(self.wallEntry)
        local set, wallErr = Admin.wallSet(args.wall)
        if not set then
            self:setStatus(wallErr, true)
            return
        end
    end
    local area, areaErr = Admin.normalizeArea(args)
    if not area then
        self:setStatus(areaErr, true)
        return
    end

    self:setStatus("Building...")
    TileCopy.ClientCommands.requestBuildRoom(args)
end

function AdminTools_Tiles_BuildZoneMode:onBuildFloor()
    self:build(true, false)
end

function AdminTools_Tiles_BuildZoneMode:onBuildWalls()
    self:build(false, true)
end

function AdminTools_Tiles_BuildZoneMode:onBuildRoom()
    self:build(true, true)
end

--- Outcome of the last build (see Admin.buildRoom), or nil plus a reason.
function AdminTools_Tiles_BuildZoneMode:onRoomBuilt(result, err)
    if not result then
        self:setStatus(tostring(err or "Nothing built."), true)
        return
    end
    if result.loaded == 0 then
        self:setStatus("Nothing built - is the area loaded (near a player)?", true)
        return
    end
    self:setStatus("Built " .. tostring(result.floors) .. " floor tile(s) and " .. tostring(result.walls) .. " wall(s).")
end

-------------------------------------------------------------------------------
-- Houses
-------------------------------------------------------------------------------

local function describeHouse(house)
    return "'" .. tostring(house.name) .. "' (" .. house.width .. " x " .. house.height .. ", " .. house.floors .. " floor(s))"
end

function AdminTools_Tiles_BuildZoneMode:onCopyHouse()
    local args, err = self:getArea()
    if not args then
        self:setStatus(err, true)
        return
    end

    local house = Core.captureHouse(args.x1, args.y1, args.x2, args.y2, args.z1, args.z2)
    if #house.squares == 0 then
        self:setStatus("Nothing copied - is the area loaded (near you)?", true)
        return
    end
    house.name = "House " .. os.date("%H:%M:%S")
    self.house = house
    self.houseLabel:setName("Copied: " .. describeHouse(house))

    -- also a clipboard of the Tile Copy tool, which can paste it in the world
    TileCopy.Clipboards = TileCopy.Clipboards or {}
    table.insert(TileCopy.Clipboards, house)
    if ISTileCopyUI.instance then ISTileCopyUI.instance:refreshList() end

    if house.loaded < house.width * house.height then
        self:setStatus("Copied, but only part of the area was loaded: get closer and copy again.", true)
    else
        self:setStatus("Copied " .. describeHouse(house) .. ".")
    end
end

function AdminTools_Tiles_BuildZoneMode:onPasteHouse()
    if self.mode == "StartPaste" then
        self.mode = nil
        return
    end
    if not self.house then
        self:setStatus("Copy a house first.", true)
        return
    end
    self:cancelResize()
    self.mode = "StartPaste"
    self:setStatus("Click the map where the house's top-left corner goes. Right-click cancels.")
end

--- `at` is { x, y, z }: where the top-left corner of its lowest floor goes.
function AdminTools_Tiles_BuildZoneMode:onConfirmPaste(button, at)
    self.modalUI = nil
    if button.internal ~= "YES" then return end
    self:setStatus("Pasting...")
    TileCopy.ClientCommands.requestPaste(self.house, at.x, at.y, at.z)
end

--- Outcome of the last paste: `loaded` of its `total` squares were loaded.
function AdminTools_Tiles_BuildZoneMode:onPasted(loaded, total)
    if loaded < total then
        self:setStatus("Pasted " .. loaded .. " of " .. total .. " squares: the rest isn't loaded. Undo, get closer, paste again.", true)
    else
        self:setStatus("Pasted " .. loaded .. " squares.")
    end
end

function AdminTools_Tiles_BuildZoneMode:onUndo()
    -- replaced by what the undo did once it's known (see TileCopy_ClientCommands)
    self:setStatus("Undo requested.")
    TileCopy.ClientCommands.requestUndo()
end

-------------------------------------------------------------------------------
-- Map interaction (the area drawing is LRZ_ZoneEditorMode's)
-------------------------------------------------------------------------------

function AdminTools_Tiles_BuildZoneMode:prerender()
    self.clearBtn:setEnable(self.hasArea)
    self.buildFloorBtn:setEnable(self.hasArea)
    self.buildWallsBtn:setEnable(self.hasArea)
    self.buildRoomBtn:setEnable(self.hasArea)
    self.copyHouseBtn:setEnable(self.hasArea)
    self.pasteHouseBtn:setEnable(self.house ~= nil)
    self.drawBtn:setTitle(self.mode == "StartDrawingBounds" and "Cancel Draw" or "Draw Area")
    self.pasteHouseBtn:setTitle(self.mode == "StartPaste" and "Cancel Paste" or "Paste House")
end

function AdminTools_Tiles_BuildZoneMode:render()
    LRZ_ZoneEditorMode.render(self)

    -- the outline of the house, its top-left corner on the tile under the mouse
    if self.mode == "StartPaste" and self.house then
        local mx, my = self.mapUI:getMouseX(), self.mapUI:getMouseY()
        local x1 = math.floor(self.mapAPI:uiToWorldX(mx, my))
        local y1 = math.floor(self.mapAPI:uiToWorldY(mx, my))
        local x2, y2 = x1 + self.house.width, y1 + self.house.height
        local corners = { { x1, y1 }, { x2, y1 }, { x2, y2 }, { x1, y2 } }
        for i, from in ipairs(corners) do
            local to = corners[i % 4 + 1]
            self.mapUI.javaObject:DrawLine(Texture:getWhite(),
                self.mapAPI:worldToUIX(from[1], from[2]), self.mapAPI:worldToUIY(from[1], from[2]),
                self.mapAPI:worldToUIX(to[1], to[2]), self.mapAPI:worldToUIY(to[1], to[2]),
                2, 0.2, 0.6, 1, 1)
        end
    end
end

function AdminTools_Tiles_BuildZoneMode:onMouseDown(x, y)
    if self.mode == "StartPaste" then
        self.mode = nil
        local worldX = math.floor(self.mapAPI:uiToWorldX(x, y))
        local worldY = math.floor(self.mapAPI:uiToWorldY(x, y))
        local z = self.floors:getRange()

        local text = "Paste " .. describeHouse(self.house) .. " at " .. worldX .. "," .. worldY .. ", floor " .. z .. "?"
        local mx, my = AdminTools_Tiles_UIUtil.centeredOn(self.panel, 450, 150)
        local modal = ISModalDialog:new(mx, my, 450, 150, text, true, self, AdminTools_Tiles_BuildZoneMode.onConfirmPaste, nil, { x = worldX, y = worldY, z = z })
        modal:initialise()
        modal:addToUIManager()
        modal:setAlwaysOnTop(true)
        self.modalUI = modal
        return true
    end
    return LRZ_ZoneEditorMode.onMouseDown(self, x, y)
end

function AdminTools_Tiles_BuildZoneMode:cancelResize()
    if self.mode == "StartPaste" then
        self.mode = nil
        return true
    end
    return LRZ_ZoneEditorMode.cancelResize(self)
end

LRZ_ZoneEditorMode.registerMode({
    key = AdminTools_Tiles_BuildZoneMode.MODE_KEY, label = "Building",
    class = AdminTools_Tiles_BuildZoneMode, canUse = TileCopy.Util.isAdmin,
})
