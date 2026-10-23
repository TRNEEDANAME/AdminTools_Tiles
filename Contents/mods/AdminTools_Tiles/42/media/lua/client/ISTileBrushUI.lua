--[[
    ISTileBrushUI.lua  (client)

    Tile Brush window: a bigger tile picker for the vanilla brush tool.
      - left: the categories. "Favourites", "All tiles", "Vanilla", then one
        per active mod that brings its own tiles
      - middle: the tiles of the category, narrowed down by the search box
        (every word typed has to be in the tile's name)
         -- Search is still being refined, I'm not a UX dev ok
      - right: a big preview of the selected tile

    Opened as the "Tile Builder" it is the same window, but the tile goes on
    the Tile Builder cursor instead: drag in the world to build a line of it
    (see server/BuildingObjects/ISTileBuilderCursor.lua), "Undo Last" takes
    a drag back.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISLabel"
require "BuildingObjects/ISBrushToolTileCursor"
require "TileCopy_Util"
require "AdminTools_Tiles_UIUtil"

ISTileBrushUI = ISCollapsableWindow:derive("ISTileBrushUI")
ISTileBrushUI.instance = nil

local Util = TileCopy.Util

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local WIDTH = 1010
local HEIGHT = 660
local CAT_W = 230
local PREVIEW_W = 290
local PREVIEW_H = 400
local GRID_W = WIDTH - CAT_W - PREVIEW_W - PADDING * 4
local GRID_X = CAT_W + PADDING * 2
local RIGHT_X = GRID_X + GRID_W + PADDING
local CELL_W = 62
local CELL_H = 112
local SCROLLBAR_W = 14

local FAVOURITES_FILE = "TileBrush_Favourites.txt"

--------------------------------------------------------------------------
-- Catalog: every tile, sorted into categories
--------------------------------------------------------------------------

local function newCategory(name)
    return { name = name, tiles = {} }
end

--- Name of the mod that defines each tileset: { [tileset] = mod name }.
--- A .tiles file is binary, but every tileset in it starts with two plain
--- lines, its name and its image ("name.png"), and that's all that's read.
--- Is it efficient ? No. Is it needed ? Maybe
local function readTilesetOwners()
    local owners = {}
    local mods = getActivatedMods()
    for i = 0, mods:size() - 1 do
        local modID = mods:get(i)
        local info = getModInfoByID(modID)
        local files = info and listFilesInModDirectory(modID, "media")
        for j = 0, (files and files:size() or 0) - 1 do
            local file = files:get(j)
            local reader = string.lower(file):sub(-6) == ".tiles" and getModFileReader(modID, "media/" .. file, false)
            if reader then
                local modName = info:getName() or modID
                local previous
                while true do
                    local line = reader:readLine()
                    if not line then break end
                    if line:sub(-4) == ".png" then
                        -- the name line can start with what's left of the
                        -- tileset before it
                        local name = previous and previous:match("([%w_%-]+)$")
                        if name and not owners[name] then owners[name] = modName end
                        local image = line:sub(1, -5)
                        if not owners[image] then owners[image] = modName end
                    end
                    previous = line
                end
                reader:close()
            end
        end
    end
    return owners
end

-- the vanilla picker (BrushToolChooseTileUI) shows 256 rows of 8 tiles
local TILESET_COLUMNS = 8
local TILESET_ROWS = 256
-- rows without a tile after which the rest of a tileset isn't looked at:
-- trying all 2048 numbers of every tileset freezes the game for a while
local MAX_EMPTY_ROWS = 32

--- Every tileset and its tiles
local function findTilesets()
    local tilesets, tilesetNames = {}, {}
    local images = getWorld():getTileImageNames()
    for i = 0, images:size() - 1 do
        local tileset = images:get(i):match("^[^.]+")
        if tileset and not tilesets[tileset] and getTexture(tileset .. "_0") then
            local tiles = {}
            local emptyRows = 0
            for row = 0, TILESET_ROWS - 1 do
                local found = false
                for column = 0, TILESET_COLUMNS - 1 do
                    local name = tileset .. "_" .. (row * TILESET_COLUMNS + column)
                    if getTexture(name) then
                        tiles[#tiles + 1] = name
                        found = true
                    end
                end
                emptyRows = found and 0 or emptyRows + 1
                if emptyRows >= MAX_EMPTY_ROWS then break end
            end
            tilesets[tileset] = tiles
            tilesetNames[#tilesetNames + 1] = tileset
        end
    end
    table.sort(tilesetNames)
    return tilesets, tilesetNames
end

local catalog

--- { all = category, vanilla = category, mods = { category, ... } }, a
--- category being { name=, tiles = { sprite names } }. Built on first use.
local function getCatalog()
    if catalog then return catalog end
    local owners = readTilesetOwners()
    local tilesets, tilesetNames = findTilesets()

    catalog = { all = newCategory("All tiles"), vanilla = newCategory("Vanilla"), mods = {} }
    local byMod = {}
    for _, tileset in ipairs(tilesetNames) do
        local category = catalog.vanilla
        local owner = owners[tileset]
        if owner then
            category = byMod[owner]
            if not category then
                category = newCategory(owner)
                byMod[owner] = category
                catalog.mods[#catalog.mods + 1] = category
            end
        end
        for _, name in ipairs(tilesets[tileset]) do
            category.tiles[#category.tiles + 1] = name
            catalog.all.tiles[#catalog.all.tiles + 1] = name
        end
    end
    table.sort(catalog.mods, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return catalog
end

--- The tiles of a category whose name contains every word of `text`.
local function filterTiles(category, text)
    local words = {}
    for word in string.gmatch(string.lower(text or ""), "%S+") do
        words[#words + 1] = word
    end
    if #words == 0 then return category.tiles end

    -- lower-case copies, kept for the next search
    if not category.lower then
        category.lower = {}
        for i, name in ipairs(category.tiles) do category.lower[i] = string.lower(name) end
    end
    local results = {}
    for i, lower in ipairs(category.lower) do
        local matches = true
        for _, word in ipairs(words) do
            if not lower:find(word, 1, true) then
                matches = false
                break
            end
        end
        if matches then results[#results + 1] = category.tiles[i] end
    end
    return results
end

--------------------------------------------------------------------------
-- Tile grid
--------------------------------------------------------------------------

ISTileBrushGrid = ISPanel:derive("ISTileBrushGrid")

function ISTileBrushGrid:new(x, y, w, h, window)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.window = window
    o.tiles = {}
    o.selected = nil -- sprite name
    o.columns = math.max(1, math.floor((w - SCROLLBAR_W) / CELL_W))
    return o
end

function ISTileBrushGrid:createChildren()
    ISPanel.createChildren(self)
    self:addScrollBars()
end

function ISTileBrushGrid:setTiles(tiles)
    self.tiles = tiles
    self:setScrollHeight(math.ceil(#tiles / self.columns) * CELL_H)
    self:setYScroll(0)
end

--- Index in self.tiles of the cell at x, y (as the mouse events give them), or nil.
function ISTileBrushGrid:indexAt(x, y)
    if x < 0 or y < 0 then return nil end
    local column = math.floor(x / CELL_W)
    if column >= self.columns then return nil end
    local index = math.floor(y / CELL_H) * self.columns + column + 1
    return self.tiles[index] and index or nil
end

function ISTileBrushGrid:prerender()
    local scroll = self:getYScroll()
    self:drawRect(0, -scroll, self.width, self.height, 0.8, 0, 0, 0)
    self:setStencilRect(1, 1, self.width - 2, self.height - 2)

    local hovered = self:isMouseOver() and self:indexAt(self:getMouseX(), self:getMouseY())
    -- only the rows in view: a category can hold tens of thousands of tiles
    local firstRow = math.floor(-scroll / CELL_H)
    local lastRow = math.floor((-scroll + self.height) / CELL_H)
    for row = firstRow, lastRow do
        for column = 0, self.columns - 1 do
            local index = row * self.columns + column + 1
            local name = self.tiles[index]
            if name then
                local x, y = column * CELL_W, row * CELL_H
                if name == self.selected then
                    self:drawRect(x + 1, y + 1, CELL_W - 2, CELL_H - 2, 0.35, 0.3, 0.6, 1)
                elseif index == hovered then
                    self:drawRect(x + 1, y + 1, CELL_W - 2, CELL_H - 2, 0.15, 1, 1, 1)
                end
                local texture = getTexture(name)
                if texture then
                    self:drawTextureScaledAspect(texture, x + 3, y + 3, CELL_W - 6, CELL_H - 6, 1, 1, 1, 1)
                end
                if self.window:isFavourite(name) then
                    self:drawText("*", x + 4, y + 1, 1, 0.85, 0.2, 1, UIFont.Medium)
                end
            end
        end
    end

    self:clearStencilRect()
    self:drawRectBorder(0, -scroll, self.width, self.height, 0.5, 0.4, 0.4, 0.4)
    self.window:setHovered(hovered and self.tiles[hovered] or nil)
end

function ISTileBrushGrid:onMouseWheel(del)
    self:setYScroll(self:getYScroll() - del * CELL_H)
    return true
end

function ISTileBrushGrid:onMouseDown(x, y)
    local index = self:indexAt(x, y)
    if index then self.window:selectTile(self.tiles[index]) end
    return true
end

function ISTileBrushGrid:onMouseDoubleClick(x, y)
    local index = self:indexAt(x, y)
    if index then
        self.window:selectTile(self.tiles[index])
        self.window:onPlace()
    end
    return true
end

function ISTileBrushGrid:onRightMouseUp(x, y)
    local index = self:indexAt(x, y)
    if index then self.window:toggleFavourite(self.tiles[index]) end
    return true
end

--------------------------------------------------------------------------
-- Tile Builder label
--------------------------------------------------------------------------
-- Small text next to the mouse while the Tile Builder cursor is out: what a
-- release would build, and the keys. The cursor itself is in
-- server/BuildingObjects/ISTileBuilderCursor.lua.

ISTileBuilderLabel = ISUIElement:derive("ISTileBuilderLabel")

function ISTileBuilderLabel:render()
    local cursor = self.cursor
    if getCell():getDrag(cursor.player) ~= cursor then
        cursor:deactivate()
        return
    end
    if not wasMouseActiveMoreRecentlyThanJoypad() then return end

    -- 1x1 element kept off the pointer so it never eats world clicks
    self:setX(getMouseX() + 24)
    self:setY(getMouseY() + 20)

    local font = UIFont.Small
    local tm = getTextManager()
    local w, h = cursor.shownW or 1, cursor.shownH or 1
    local size = (w > 1 and h > 1) and (w .. " x " .. h) or (math.max(w, h) .. " tile(s)")
    local key = Keyboard.getKeyName(getCore():getKey(KeybindId.ROTATE_BUILDING))
    local lines = {
        { "Build: " .. tostring(cursor.shownSprite) .. "   " .. size, 0.6, 1, 0.6 },
        { "Drag: line   Shift+drag: area   " .. key .. ": turn walls along the line (" .. (cursor.autoFace and "on" or "off") .. ")", 0.85, 0.85, 0.85 },
    }

    local textW = 0
    for _, line in ipairs(lines) do
        textW = math.max(textW, tm:MeasureStringX(font, line[1]))
    end
    self:drawRect(-4, -2, textW + 8, #lines * FONT_HGT_SMALL + 4, 0.6, 0, 0, 0)
    for i, line in ipairs(lines) do
        self:drawText(line[1], 0, (i - 1) * FONT_HGT_SMALL, line[2], line[3], line[4], 1, font)
    end
end

function ISTileBuilderLabel:new(cursor)
    local o = ISUIElement.new(self, getMouseX() + 24, getMouseY() + 20, 1, 1)
    o.cursor = cursor
    return o
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

function ISTileBrushUI:new()
    local x = (getCore():getScreenWidth() / 2) - (WIDTH / 2)
    local y = (getCore():getScreenHeight() / 2) - (HEIGHT / 2)

    local o = ISCollapsableWindow:new(x, y, WIDTH, HEIGHT)
    setmetatable(o, self)
    self.__index = self

    o.title = "Tile Brush"
    o:setResizable(false)
    o.favourites = newCategory("Favourites")
    o.favouriteSet = {}  -- { [sprite name] = true }
    o.category = nil     -- the one shown
    o.selected = nil     -- sprite name
    o.hovered = nil      -- sprite name under the mouse in the grid
    o.builder = false    -- opened as the Tile Builder
    o.onPick = nil       -- opened to pick a tile: who gets it (see ISTileBrushUI.pick)
    return o
end

function ISTileBrushUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local top = self:titleBarHeight() + PADDING
    local listH = HEIGHT - top - PADDING * 2 - FONT_HGT_SMALL

    -- Left: categories
    self.categoryList = ISScrollingListBox:new(PADDING, top, CAT_W, listH)
    self.categoryList:initialise()
    self.categoryList:instantiate()
    self.categoryList:setFont(UIFont.Small, 4)
    self.categoryList.drawBorder = true
    self.categoryList:setOnMouseDownFunction(self, ISTileBrushUI.onCategorySelected)
    self:addChild(self.categoryList)

    -- Middle: search + tiles
    self.searchEntry = ISTextEntryBox:new("", GRID_X, top, GRID_W - 65, BTN_H)
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = ISTileBrushUI.onSearchChanged
    self.searchEntry:setTooltip("Search this category: every word has to be in the tile's name")
    self:addChild(self.searchEntry)

    self.clearBtn = ISButton:new(GRID_X + GRID_W - 60, top, 60, BTN_H, "Clear", self, ISTileBrushUI.onClearSearch)
    self.clearBtn:initialise()
    self:addChild(self.clearBtn)

    self.grid = ISTileBrushGrid:new(GRID_X, top + BTN_H + 4, GRID_W, listH - BTN_H - 4, self)
    self.grid:initialise()
    self.grid:instantiate()
    self:addChild(self.grid)

    -- Right: preview
    self.preview = ISPanel:new(RIGHT_X, top, PREVIEW_W, PREVIEW_H)
    self.preview:initialise()
    self.preview.window = self
    self.preview.render = ISTileBrushUI.renderPreview
    self:addChild(self.preview)

    local y = top + PREVIEW_H + 6
    self.nameLabel = ISLabel:new(RIGHT_X, y, FONT_HGT_SMALL, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.nameLabel)
    y = y + FONT_HGT_SMALL + 2
    self.numberLabel = ISLabel:new(RIGHT_X, y, FONT_HGT_SMALL, "", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.numberLabel)
    y = y + FONT_HGT_SMALL + 8

    self.placeBtn = ISButton:new(RIGHT_X, y, PREVIEW_W, BTN_H + 4, "Place with Brush", self, ISTileBrushUI.onPlace)
    self.placeBtn:initialise()
    self:addChild(self.placeBtn)
    y = y + BTN_H + 10

    self.favouriteBtn = ISButton:new(RIGHT_X, y, PREVIEW_W, BTN_H, "Add to Favourites", self, ISTileBrushUI.onToggleFavourite)
    self.favouriteBtn:initialise()
    self:addChild(self.favouriteBtn)
    y = y + BTN_H + 10

    self.undoBtn = ISButton:new(RIGHT_X, y, PREVIEW_W, BTN_H, "Undo Last", self, ISTileBrushUI.onUndo)
    self.undoBtn:initialise()
    self.undoBtn:setTooltip("Takes back the last drag (or the last paste / remove / swap of the other Tile Admin tools).")
    self:addChild(self.undoBtn)
    y = y + BTN_H + 10

    self.hintLabel = ISLabel:new(RIGHT_X, y, FONT_HGT_SMALL, "", 0.6, 0.6, 0.6, 1, UIFont.Small, true)
    self:addChild(self.hintLabel)

    -- Bottom: what the mouse is on / how many tiles are shown
    self.statusLabel = ISLabel:new(PADDING, top + listH + PADDING / 2, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)

    self:loadFavourites()
    self:refreshCategories()
    self:showCategory(#self.favourites.tiles > 0 and self.favourites or getCatalog().all)
    self:setBuilder(self.builder)
    self:updateButtons()
end

--- Switches between the Tile Brush (false) and the Tile Builder (true).
function ISTileBrushUI:setBuilder(builder)
    self.builder = builder == true
    self.onPick = nil
    self:setAlwaysOnTop(false)
    self.title = self.builder and "Tile Builder" or "Tile Brush"
    self.placeBtn:setTitle(self.builder and "Build by Dragging" or "Place with Brush")
    self.undoBtn:setVisible(self.builder)
    self.hintLabel:setName((self.builder and "Double-click: build." or "Double-click: place.") .. "  Right-click: favourite.")
end

--- render of the preview panel: the selected tile, as big as it fits.
function ISTileBrushUI.renderPreview(panel)
    panel:drawRect(0, 0, panel.width, panel.height, 0.8, 0, 0, 0)
    panel:drawRectBorder(0, 0, panel.width, panel.height, 0.5, 0.4, 0.4, 0.4)
    local name = panel.window.hovered or panel.window.selected
    local texture = name and getTexture(name)
    if texture then
        panel:drawTextureScaledAspect(texture, 8, 8, panel.width - 16, panel.height - 16, 1, 1, 1, 1)
    end
end

-------------------------------------------------------------------------------
-- Categories
-------------------------------------------------------------------------------

--- Fills the category list, keeping the shown one selected.
function ISTileBrushUI:refreshCategories()
    local data = getCatalog()
    local categories = { self.favourites, data.all, data.vanilla }
    for _, category in ipairs(data.mods) do categories[#categories + 1] = category end

    self.categoryList:clear()
    for i, category in ipairs(categories) do
        self.categoryList:addItem(category.name .. "  (" .. #category.tiles .. ")", category)
        if category == self.category then self.categoryList.selected = i end
    end
end

function ISTileBrushUI:onCategorySelected(category)
    self:showCategory(category)
end

function ISTileBrushUI:showCategory(category)
    self.category = category
    for i, item in ipairs(self.categoryList.items) do
        if item.item == category then self.categoryList.selected = i end
    end
    self:refreshTiles()
end

-------------------------------------------------------------------------------
-- Tiles
-------------------------------------------------------------------------------

function ISTileBrushUI:onSearchChanged()
    self:refreshTiles()
end

function ISTileBrushUI:onClearSearch()
    self.searchEntry:setText("")
    self:refreshTiles()
end

--- Shows the tiles of the category that match the search.
function ISTileBrushUI:refreshTiles()
    if not self.category then return end
    local tiles = filterTiles(self.category, self.searchEntry:getText())
    self.grid:setTiles(tiles)
    self.shownText = #tiles .. " of " .. #self.category.tiles .. " tiles in " .. self.category.name
    self:setHovered(nil)
end

--- Called by the grid every frame with the tile under the mouse (or nil).
function ISTileBrushUI:setHovered(name)
    self.hovered = name
    self.statusLabel:setName(name or self.shownText or "")
end

function ISTileBrushUI:selectTile(name)
    self.selected = name
    self.grid.selected = name
    local tileset, number = name:match("^(.*)_(%d+)$")
    self.nameLabel:setName(tileset or name)
    self.numberLabel:setName(number and ("tile " .. number) or "")
    self:updateButtons()
end

function ISTileBrushUI:onPlace()
    if not self.selected then return end
    local player = getPlayer()
    if not player then return end
    if self.onPick then
        self:setVisible(false)
        self.onPick(self.selected)
        return
    end
    if self.builder then
        ISTileBuilderCursor.start(player, self.selected)
        self:setShownText("Tile Builder: drag in the world to build a line, right-click to stop.")
        return
    end
    getCell():setDrag(ISBrushToolTileCursor:new(self.selected, self.selected, player), player:getPlayerNum())
end

--- Outcome of a Tile Builder drag (see Admin.buildArea), or nil plus a
--- reason.
function ISTileBrushUI:onBuilt(result, err)
    if not result then
        self:setShownText(tostring(err or "Nothing built."))
    elseif result.squares == 0 then
        self:setShownText("Nothing built - is the area loaded (near a player)?")
    else
        self:setShownText("Built " .. tostring(result.placed) .. " x " .. tostring(result.sprite) .. ".")
    end
end

function ISTileBrushUI:onUndo()
    -- replaced by what the undo did once it's known (see TileCopy_ClientCommands)
    self:setShownText("Undo requested.")
    TileCopy.ClientCommands.requestUndo()
end

--- Text of the bottom line while the mouse isn't on a tile.
function ISTileBrushUI:setShownText(text)
    self.shownText = text
end

-------------------------------------------------------------------------------
-- Favourites
-------------------------------------------------------------------------------

function ISTileBrushUI:isFavourite(name)
    return self.favouriteSet[name] == true
end

function ISTileBrushUI:onToggleFavourite()
    if self.selected then self:toggleFavourite(self.selected) end
end

function ISTileBrushUI:toggleFavourite(name)
    local tiles = self.favourites.tiles
    if self.favouriteSet[name] then
        self.favouriteSet[name] = nil
        for i, other in ipairs(tiles) do
            if other == name then
                table.remove(tiles, i)
                break
            end
        end
    else
        self.favouriteSet[name] = true
        tiles[#tiles + 1] = name
    end
    self.favourites.lower = nil -- the search's copy of the names
    self:saveFavourites()

    self:refreshCategories()
    if self.category == self.favourites then
        -- keep the place in the list: only the tile toggled changes
        local scroll = self.grid:getYScroll()
        self:refreshTiles()
        self.grid:setYScroll(scroll)
    end
    self:updateButtons()
end

function ISTileBrushUI:saveFavourites()
    local writer = getFileWriter(FAVOURITES_FILE, true, false)
    if not writer then
        Util.info("tile brush: could not open", FAVOURITES_FILE, "for writing")
        return
    end
    writer:write(Util.serialize(self.favourites.tiles))
    writer:close()
end

function ISTileBrushUI:loadFavourites()
    local reader = getFileReader(FAVOURITES_FILE, false)
    if not reader then return end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    if #lines == 0 then return end

    local loaded, err = Util.deserialize(table.concat(lines, "\n"))
    if type(loaded) ~= "table" then
        Util.info("tile brush favourites: parse FAILED -", err)
        return
    end
    for _, name in ipairs(loaded) do
        if type(name) == "string" and not self.favouriteSet[name] then
            self.favouriteSet[name] = true
            self.favourites.tiles[#self.favourites.tiles + 1] = name
        end
    end
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

function ISTileBrushUI:updateButtons()
    self.placeBtn:setEnable(self.selected ~= nil)
    self.favouriteBtn:setEnable(self.selected ~= nil)
    local isFavourite = self.selected and self:isFavourite(self.selected)
    self.favouriteBtn:setTitle(isFavourite and "Remove from Favourites" or "Add to Favourites")
end

function ISTileBrushUI:onClose()
    self:setVisible(false)
end

function ISTileBrushUI:close()
    self:setVisible(false)
end

--- `builder` true opens it as the Tile Builder.
function ISTileBrushUI.open(builder)
    if not Util.isAdmin(getPlayer()) then return end

    if not ISTileBrushUI.instance then
        local ui = ISTileBrushUI:new()
        ui.builder = builder == true
        ui:initialise()
        ui:addToUIManager()
        ISTileBrushUI.instance = ui
    else
        ISTileBrushUI.instance:setVisible(true)
        ISTileBrushUI.instance:setBuilder(builder)
    end
    ISTileBrushUI.instance:bringToTop()
    return ISTileBrushUI.instance
end

--- Opens the window to choose a tile for something else (the Zone Editor's
--- "Building" mode): onPick(sprite name) is called with the one picked.
function ISTileBrushUI.pick(onPick)
    local ui = ISTileBrushUI.open()
    if not ui then return end
    ui.onPick = onPick
    ui.title = "Pick a Tile"
    ui.placeBtn:setTitle("Use This Tile")
    ui.hintLabel:setName("Double-click: use it.  Right-click: favourite.")
    -- Has to show over the full-screen Zone Editor
    ui:setAlwaysOnTop(true)
    ui:bringToTop()
    return ui
end
