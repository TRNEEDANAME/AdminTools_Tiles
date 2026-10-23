--[[
    ISTileSwapUI.lua  (client)

    Tile Swap window
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISContextMenu"
require "ISUI/ISTextBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISLabel"
require "ISUI/ISModalDialog"
require "TileAdmin_Core"
require "TileCopy_Util"
require "AdminTools_Tiles_UIUtil"
require "ISTileCopyTool"
require "ISTileCopyStringUI"

ISTileSwapUI = ISCollapsableWindow:derive("ISTileSwapUI")
ISTileSwapUI.instance = nil

local Util = TileCopy.Util
local Admin = TileCopy.Admin

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local WIDTH = 860
local COL_W = (WIDTH - PADDING * 3) / 2
local RIGHT_X = PADDING * 2 + COL_W
local LIST_H = 230
local RULES_H = 110
local TILE_ROW_H = 36
local PREVIEW_W = 30
-- Most search results shown at once (there are tens of thousands of tiles)
local MAX_RESULTS = 200

local LOAD_TEXT = "Load Queued Chunks"

local COLOR_GROUP = { r = 0.7, g = 0.85, b = 1.0, a = 1 }
local COLOR_TILE = { r = 0.9, g = 0.9, b = 0.9, a = 1 }
local COLOR_HINT = { r = 0.6, g = 0.6, b = 0.6, a = 1 }

--------------------------------------------------------------------------
-- Every tile in the game (for the search)
--------------------------------------------------------------------------

local allTiles, allTilesLower

--- Names of every tile of every loaded tileset. Built on first use.
local function getAllTiles()
    if allTiles then return allTiles, allTilesLower end
    allTiles, allTilesLower = {}, {}
    local tilesets, tilesetNames = TileCopy.Util.getTilesets()
    for _, tileset in ipairs(tilesetNames) do
        for _, name in ipairs(tilesets[tileset]) do
            allTiles[#allTiles + 1] = name
            allTilesLower[#allTilesLower + 1] = string.lower(name)
        end
    end
    return allTiles, allTilesLower
end

--- "walls_exterior_house_01" for "walls_exterior_house_01_12".
local function tilesetOf(spriteName)
    return spriteName and spriteName:match("^(.*)_%d+$")
end

--- The words typed in a search box, lower-case.
local function searchWords(text)
    local words = {}
    for word in string.gmatch(string.lower(text or ""), "%S+") do
        words[#words + 1] = word
    end
    return words
end

--- Whether a lower-case name contains every one of the words.
local function matchesWords(lower, words)
    for _, word in ipairs(words) do
        if not lower:find(word, 1, true) then return false end
    end
    return true
end

--- Tiles whose name contains every word of `text`, plus whether the list
--- was cut short.
local function searchTiles(text)
    local words = searchWords(text)
    local results = {}
    if #words == 0 then return results, false end

    local names, lower = getAllTiles()
    for i = 1, #names do
        if matchesWords(lower[i], words) then
            if #results >= MAX_RESULTS then return results, true end
            results[#results + 1] = names[i]
        end
    end
    return results, false
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

function ISTileSwapUI:new()
    local height = 620
    local x = (getCore():getScreenWidth() / 2) - (WIDTH / 2)
    local y = (getCore():getScreenHeight() / 2) - (height / 2)

    local o = ISCollapsableWindow:new(x, y, WIDTH, height)
    setmetatable(o, self)
    self.__index = self

    o.title = "Tile Swap"
    o:setResizable(false)
    o.area = nil     -- { x1, y1, x2, y2 }
    o.presets = {}   -- see TileAdmin_Core for the format
    o.scanned = {}   -- tiles found in the area (and ones picked in the world)
    return o
end

--- Adds a row of same-height buttons left to right. Returns the buttons.
local function addButtonRow(self, x, y, defs)
    local buttons = {}
    for _, def in ipairs(defs) do
        local btn = ISButton:new(x, y, def.w, BTN_H, def.text, self, def.fn)
        btn:initialise()
        self:addChild(btn)
        buttons[#buttons + 1] = btn
        x = x + def.w + 5
    end
    return buttons
end

--- A list whose rows show a preview of their tile (see drawTileItem).
local function addTileList(self, x, y, w, h)
    local list = ISScrollingListBox:new(x, y, w, h)
    list:initialise()
    list:instantiate()
    list:setFont(UIFont.Small, 2)
    list.itemheight = TILE_ROW_H
    list.drawBorder = true
    list.doDrawItem = ISTileSwapUI.drawTileItem
    self:addChild(list)
    return list
end

function ISTileSwapUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local tm = getTextManager()
    local y = self:titleBarHeight() + PADDING

    -- Row: preset
    self.presetLabel = ISLabel:new(PADDING, y, BTN_H, "Preset:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.presetLabel)
    local px = PADDING + tm:MeasureStringX(UIFont.Small, "Preset:") + 8

    self.presetCombo = ISComboBox:new(px, y, 220, BTN_H, self, ISTileSwapUI.onPresetChanged)
    self.presetCombo:initialise()
    self:addChild(self.presetCombo)

    addButtonRow(self, px + 230, y, {
        { text = "New", w = 60, fn = ISTileSwapUI.onNewPreset },
        { text = "Rename", w = 70, fn = ISTileSwapUI.onRenamePreset },
        { text = "Delete", w = 65, fn = ISTileSwapUI.onDeletePreset },
        { text = "Export", w = 65, fn = ISTileSwapUI.onExport },
        { text = "Import", w = 65, fn = ISTileSwapUI.onImport },
        { text = "Restore Defaults", w = 130, fn = ISTileSwapUI.onRestoreDefaults },
    })
    y = y + BTN_H + 8

    -- Row: area + floor range
    self.selectBtn = ISButton:new(PADDING, y, 130, BTN_H, "Select Area", self, ISTileSwapUI.onSelectArea)
    self.selectBtn:initialise()
    self:addChild(self.selectBtn)

    self.floors = AdminTools_Tiles_UIUtil.createFloorRow(self, PADDING + 140, y, BTN_H)

    self.areaLabel = ISLabel:new(self.floors.right + 12, y, BTN_H, "No area selected", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.areaLabel)
    y = y + BTN_H + 10

    -- Left: the tile to swap. Right: the tile to swap it with.
    self.sourceLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "1. Tile to swap (in the area, groups, or search any tile)", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.sourceLabel)
    self.targetLabel = ISLabel:new(RIGHT_X, y, FONT_HGT_SMALL, "2. Swap with (search every tile by name)", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.targetLabel)
    y = y + FONT_HGT_SMALL + 4

    self.sourceSearchEntry = ISTextEntryBox:new("", PADDING, y, COL_W, BTN_H)
    self.sourceSearchEntry:initialise()
    self.sourceSearchEntry:instantiate()
    self.sourceSearchEntry.target = self
    self.sourceSearchEntry.onTextChangeFunction = ISTileSwapUI.onSourceSearchChanged
    self:addChild(self.sourceSearchEntry)

    self.sourceList = addTileList(self, PADDING, y + BTN_H + 4, COL_W, LIST_H - BTN_H - 4)
    self.sourceList:setOnMouseDownFunction(self, ISTileSwapUI.onSourceSelected)

    self.searchEntry = ISTextEntryBox:new("", RIGHT_X, y, COL_W, BTN_H)
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = ISTileSwapUI.onSearchChanged
    self:addChild(self.searchEntry)

    self.targetList = addTileList(self, RIGHT_X, y + BTN_H + 4, COL_W, LIST_H - BTN_H - 4)
    y = y + LIST_H + 6

    addButtonRow(self, PADDING, y, {
        { text = "Pick in World", w = 130, fn = ISTileSwapUI.onPickSource },
        { text = "Clear Search", w = 110, fn = ISTileSwapUI.onClearSourceSearch },
    })
    addButtonRow(self, RIGHT_X, y, {
        { text = "Pick in World", w = 130, fn = ISTileSwapUI.onPickTarget },
        { text = "Clear Search", w = 110, fn = ISTileSwapUI.onClearSearch },
    })
    y = y + BTN_H + 10

    -- Row: 3. add (the dropdowns can stay as they are for a plain swap)
    local addBtns = addButtonRow(self, PADDING, y, {
        { text = "3. Add to Preset", w = 150, fn = ISTileSwapUI.onAddRule },
    })
    self.addBtn = addBtns[1]
    local x = PADDING + 165

    self.actionCombo = ISComboBox:new(x, y, 160, BTN_H, nil, nil)
    self.actionCombo:initialise()
    for _, action in ipairs(Admin.ACTIONS) do
        self.actionCombo:addOptionWithData(action.label, action.id)
    end
    self:addChild(self.actionCombo)
    x = x + 170

    self.whereCombo = ISComboBox:new(x, y, 130, BTN_H, nil, nil)
    self.whereCombo:initialise()
    for _, where in ipairs(Admin.WHERE) do
        self.whereCombo:addOptionWithData(where.label, where.id)
    end
    self:addChild(self.whereCombo)
    x = x + 140

    self.chanceLabel = ISLabel:new(x, y, BTN_H, "This swap's chance %:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.chanceLabel)
    x = x + tm:MeasureStringX(UIFont.Small, "This swap's chance %:") + 8

    self.chanceEntry = ISTextEntryBox:new("100", x, y, 45, BTN_H)
    self.chanceEntry:initialise()
    self.chanceEntry:instantiate()
    self.chanceEntry:setOnlyNumbers(true)
    self:addChild(self.chanceEntry)
    y = y + BTN_H + 10

    -- The preset's swaps
    self.rulesLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "In this preset:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.rulesLabel)
    y = y + FONT_HGT_SMALL + 4

    self.ruleList = ISScrollingListBox:new(PADDING, y, WIDTH - PADDING * 2, RULES_H)
    self.ruleList:initialise()
    self.ruleList:instantiate()
    self.ruleList:setFont(UIFont.Small, 2)
    self.ruleList.drawBorder = true
    self:addChild(self.ruleList)
    y = y + RULES_H + 6

    -- Bottom: actions
    local bottomBtns = addButtonRow(self, PADDING, y, {
        { text = "Apply Swap", w = 150, fn = ISTileSwapUI.onApply },
        { text = "Undo Last", w = 100, fn = ISTileSwapUI.onUndo },
        { text = "Remove from Preset", w = 150, fn = ISTileSwapUI.onRemoveRule },
    })
    self.applyBtn = bottomBtns[1]

    -- Preset-wide chance: how much of the area the preset touches
    local cx = PADDING + 150 + 100 + 150 + 25
    self.presetChanceLabel = ISLabel:new(cx, y, BTN_H, "Tiles affected %:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.presetChanceLabel)
    cx = cx + tm:MeasureStringX(UIFont.Small, "Tiles affected %:") + 8

    self.presetChanceEntry = ISTextEntryBox:new("100", cx, y, 45, BTN_H)
    self.presetChanceEntry:initialise()
    self.presetChanceEntry:instantiate()
    self.presetChanceEntry:setOnlyNumbers(true)
    self:addChild(self.presetChanceEntry)

    self.loadBtn = ISButton:new(WIDTH - PADDING - 100 - 5 - 150, y, 150, BTN_H, LOAD_TEXT, self, ISTileSwapUI.onLoadQueued)
    self.loadBtn:initialise()
    self.loadBtn:setTooltip("Teleports you over the queued part of the swapped area so it loads and gets swapped now, then brings you back.")
    self:addChild(self.loadBtn)

    self.closeBtn = ISButton:new(WIDTH - PADDING - 100, y, 100, BTN_H, "Close", self, ISTileSwapUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
    y = y + BTN_H + 6

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)
    y = y + FONT_HGT_SMALL + PADDING

    self:setHeight(y)

    self.presets = Admin.loadPresets()
    self:refreshPresets(1)
    self:refreshSources()
    self:refreshTargets()
    self:updateButtons()
end

--- doDrawItem of both tile lists: tile rows get a preview of their sprite.
function ISTileSwapUI.drawTileItem(list, y, item, alt)
    if not item.height then item.height = list.itemheight end
    if (y + list:getYScroll() + item.height < 0) or (y + list:getYScroll() >= list.height) then
        return y + item.height
    end

    local data = item.item
    if not data.hint then
        if list.selected == item.index then
            list:drawSelection(0, y, list:getWidth(), item.height - 1)
        elseif list.mouseoverselected == item.index and list:isMouseOver() and not list:isMouseOverScrollBar() then
            list:drawMouseOverHighlight(0, y, list:getWidth(), item.height - 1)
        end
    end
    list:drawRectBorder(0, y, list:getWidth(), item.height, 0.5, list.borderColor.r, list.borderColor.g, list.borderColor.b)

    local color = COLOR_GROUP
    if data.hint then
        color = COLOR_HINT
    elseif data.sprite then
        color = COLOR_TILE
        local texture = getTexture(data.sprite)
        if texture then
            list:drawTextureScaledAspect(texture, 4, y + 2, PREVIEW_W, item.height - 4, 1, 1, 1, 1)
        end
    end
    list:drawText(item.text, PREVIEW_W + 10, y + (item.height - list.fontHgt) / 2, color.r, color.g, color.b, color.a, list.font)
    return y + item.height
end

-------------------------------------------------------------------------------
-- Area
-------------------------------------------------------------------------------

function ISTileSwapUI:onSelectArea()
    if not ISTileCopyTool.instance then return end
    self:setVisible(false)
    ISTileCopyTool.instance:startSelecting(AdminTools_Tiles_Util.playerFloor(), function(x1, y1, x2, y2, zSel)
        ISTileCopyTool.instance:cancel()
        self:setVisible(true)
        self:bringToTop()
        -- Default the floor range to the floor the drag was made on
        self:setArea(x1, y1, x2, y2, zSel, zSel)
    end)
end

--- Sets the area to work on and lists its tiles. Also how the Zone Editor
--- hands over the area drawn on its map (see LRZ_ZoneEditorMode).
function ISTileSwapUI:setArea(x1, y1, x2, y2, z1, z2)
    self.area = {
        x1 = math.min(x1, x2), y1 = math.min(y1, y2),
        x2 = math.max(x1, x2), y2 = math.max(y1, y2),
    }
    local w = self.area.x2 - self.area.x1 + 1
    local h = self.area.y2 - self.area.y1 + 1
    self.areaLabel:setName(w .. " x " .. h .. " tiles  (" .. self.area.x1 .. "," .. self.area.y1 .. " -> " .. self.area.x2 .. "," .. self.area.y2 .. ")")
    self.floors:setRange(z1, z2)
    self:scan()
    self:updateButtons()
end

--- Area + floors as request args, or nil (with the status set) when there's
--- no usable area.
function ISTileSwapUI:buildArgs()
    if not self.area then
        self:setStatus("Select an area first.", true)
        return nil
    end
    local z1, z2 = self.floors:getRange()
    local args = {
        x1 = self.area.x1, y1 = self.area.y1, x2 = self.area.x2, y2 = self.area.y2,
        z1 = z1, z2 = z2,
    }
    -- Client-side size check so the admin gets feedback before the round trip.
    local area, err = Admin.normalizeArea(args)
    if not area then
        self:setStatus(err, true)
        return nil
    end
    return args
end

--- Lists the area's tiles on the left. The squares around the admin are
--- loaded on their client too, so this doesn't need the server.
function ISTileSwapUI:scan()
    local args = self:buildArgs()
    if not args then return end
    self.scanned = Admin.scanArea(args) or {}
    self:refreshSources()
    self:refreshTargets()
    if #self.scanned == 0 then
        -- an area drawn in the Zone Editor can be far from the admin: what
        -- isn't loaded on the server either is queued until it is
        self:setStatus("No tiles listed - the area isn't loaded near you. Groups and presets can still be applied.", true)
    else
        self:setStatus(#self.scanned .. " different tile(s) in the area. Pick the one to swap.")
    end
end

-------------------------------------------------------------------------------
-- 1. Tile to swap (scanned tiles + groups)
-------------------------------------------------------------------------------

function ISTileSwapUI:onSourceSearchChanged()
    self:refreshSources()
    self:onSourceSelected()
end

function ISTileSwapUI:onClearSourceSearch()
    self.sourceSearchEntry:setText("")
    self:onSourceSearchChanged()
end

--- Fills the left list: the area's tiles, then the groups. With something
--- typed in the search, only the ones that match, then every other tile in
--- the game that does (to swap a tile the area doesn't have).
function ISTileSwapUI:refreshSources()
    self.sourceList:clear()
    local text = self.sourceSearchEntry:getText() or ""
    local words = searchWords(text)

    local listed = {} -- { [sprite name] = true }
    for _, entry in ipairs(self.scanned) do
        if matchesWords(string.lower(entry.sprite), words) then
            local label = entry.sprite .. "  [" .. entry.kind .. "]"
            if entry.count > 0 then label = label .. "  x" .. entry.count end
            self.sourceList:addItem(label, { sprite = entry.sprite })
            listed[entry.sprite] = true
        end
    end
    for _, group in ipairs(Admin.GROUPS) do
        if matchesWords(string.lower(group.label), words) then
            self.sourceList:addItem(group.label, { group = group.id })
        end
    end

    local names, cut = searchTiles(text)
    for _, name in ipairs(names) do
        if not listed[name] then
            self.sourceList:addItem(name, { sprite = name })
        end
    end
    if cut then
        self.sourceList:addItem("First " .. MAX_RESULTS .. " shown - type more to narrow it down", { hint = true })
    elseif #self.sourceList.items == 0 then
        self.sourceList:addItem("No tile matches that", { hint = true })
    end
    self.sourceList.selected = 1
end

--- The tile or group selected on the left ({ sprite= } or { group= }), or nil.
function ISTileSwapUI:getSelectedSource()
    local row = self.sourceList.items[self.sourceList.selected]
    if not row or row.item.hint then return nil end
    return row.item
end

-- With nothing typed in the search, the right list follows the tile picked
-- on the left (see refreshTargets).
function ISTileSwapUI:onSourceSelected()
    if self.searchEntry:getText() == "" then
        self:refreshTargets()
    end
end

--- Selects a tile on the left, adding it when the area doesn't have it.
function ISTileSwapUI:selectSource(sprite, kind)
    local found = false
    for _, entry in ipairs(self.scanned) do
        if entry.sprite == sprite then found = true end
    end
    if not found then
        table.insert(self.scanned, 1, { sprite = sprite, kind = kind or "Picked", count = 0 })
    end
    -- a search could be hiding it
    self.sourceSearchEntry:setText("")
    self:refreshSources()
    for i, row in ipairs(self.sourceList.items) do
        if row.item.sprite == sprite then
            self.sourceList.selected = i
            self.sourceList:ensureVisible(i)
        end
    end
    self:onSourceSelected()
end

-------------------------------------------------------------------------------
-- 2. Tile to swap with (search)
-------------------------------------------------------------------------------

function ISTileSwapUI:onSearchChanged()
    self:refreshTargets()
end

function ISTileSwapUI:onClearSearch()
    self.searchEntry:setText("")
    self:refreshTargets()
end

--- Fills the right list: the search results, or with nothing typed the rest
--- of the tileset of the tile picked on the left (same kind of wall, floor...).
function ISTileSwapUI:refreshTargets()
    self.targetList:clear()
    local text = self.searchEntry:getText() or ""

    local names, cut = searchTiles(text)
    if #names == 0 and text == "" then
        local source = self:getSelectedSource()
        local tileset = source and tilesetOf(source.sprite)
        if tileset then
            -- nil for a tileset the game doesn't list (some mod / erosion tiles)
            local tiles = TileCopy.Util.getTilesets()[tileset]
            if tiles then
                for _, name in ipairs(tiles) do
                    names[#names + 1] = name
                end
            else
                names, cut = searchTiles(tileset .. "_")
            end
        end
    end

    for _, name in ipairs(names) do
        self.targetList:addItem(name, { sprite = name })
    end
    if cut then
        self.targetList:addItem("First " .. MAX_RESULTS .. " shown - type more to narrow it down", { hint = true })
    elseif #names == 0 then
        local hint = text == "" and "Type part of a tile name, e.g. \"walls house 01\"" or "No tile matches that"
        self.targetList:addItem(hint, { hint = true })
    end
    self.targetList.selected = 1
end

--- The tile selected on the right, or nil.
function ISTileSwapUI:getSelectedTarget()
    local row = self.targetList.items[self.targetList.selected]
    return row and row.item.sprite
end

--- Shows one tile on the right and selects it.
function ISTileSwapUI:selectTarget(sprite)
    self.searchEntry:setText(sprite)
    self:refreshTargets()
    for i, row in ipairs(self.targetList.items) do
        if row.item.sprite == sprite then self.targetList.selected = i end
    end
end

-------------------------------------------------------------------------------
-- Pick in World
-------------------------------------------------------------------------------

function ISTileSwapUI:onPickSource()
    self:pickInWorld(false)
end

function ISTileSwapUI:onPickTarget()
    self:pickInWorld(true)
end

--- Lets the admin click a square, then choose one of the tiles on it.
function ISTileSwapUI:pickInWorld(forTarget)
    if not ISTileCopyTool.instance then return end
    self:setVisible(false)
    ISTileCopyTool.instance:startPicking(AdminTools_Tiles_Util.playerFloor(), function(x, y, z)
        ISTileCopyTool.instance:cancel()
        self:setVisible(true)
        self:bringToTop()
        if not x then return end

        local found = Admin.scanArea({ x1 = x, y1 = y, x2 = x, y2 = y, z1 = z, z2 = z }) or {}
        if #found == 0 then
            self:setStatus("There's no tile on that square.", true)
        elseif #found == 1 then
            self:onTilePicked(found[1], forTarget)
        else
            -- floor, wall, furniture... ask which one
            local context = ISContextMenu.get(getPlayer():getPlayerNum(), getMouseX(), getMouseY())
            for _, entry in ipairs(found) do
                context:addOption(entry.sprite .. "  [" .. entry.kind .. "]", self, ISTileSwapUI.onTilePicked, entry, forTarget)
            end
        end
    end)
end

function ISTileSwapUI:onTilePicked(entry, forTarget)
    if forTarget then
        self:selectTarget(entry.sprite)
        self:setStatus("Swap with: " .. entry.sprite)
    else
        self:selectSource(entry.sprite, entry.kind)
        self:setStatus("Tile to swap: " .. entry.sprite)
    end
end

-------------------------------------------------------------------------------
-- Presets
-------------------------------------------------------------------------------

function ISTileSwapUI:getPreset()
    return self.presets[self.presetCombo.selected]
end

--- Rebuilds the preset dropdown and selects preset number `index`.
function ISTileSwapUI:refreshPresets(index)
    self.presetCombo:clear()
    for i, preset in ipairs(self.presets) do
        self.presetCombo:addOptionWithData(preset.name or ("Preset " .. i), preset)
    end
    self.presetCombo.selected = AdminTools_Tiles_Util.clamp(index or 1, 1, math.max(1, #self.presets))
    self:refreshRules()
end

--- Call after any change to the presets: saves them and redraws.
function ISTileSwapUI:presetsChanged(index)
    Admin.savePresets(self.presets)
    self:refreshPresets(index or self.presetCombo.selected)
    self:updateButtons()
end

function ISTileSwapUI:onPresetChanged()
    self:refreshRules()
    self:updateButtons()
end

function ISTileSwapUI:askName(prompt, default, onEntered)
    local mx, my = AdminTools_Tiles_UIUtil.centeredOn(self, 280, 180)
    local modal = ISTextBox:new(mx, my, 280, 180, prompt, default, self, onEntered, getPlayer():getPlayerNum())
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function ISTileSwapUI:onNewPreset()
    self:askName("Name of the new preset:", "Preset " .. os.date("%H:%M:%S"), ISTileSwapUI.onNewPresetNamed)
end

function ISTileSwapUI:onNewPresetNamed(button)
    if button.internal ~= "OK" then return end
    local name = button.parent.entry:getText()
    if not name or name == "" then return end
    table.insert(self.presets, { name = name, rules = {} })
    self:presetsChanged(#self.presets)
    if self.area then
        self:setStatus("Created '" .. name .. "'. Pick a tile to swap, then what to swap it with.")
    else
        self:setStatus("Created '" .. name .. "'. Now select an area.")
    end
end

function ISTileSwapUI:onRenamePreset()
    local preset = self:getPreset()
    if not preset then return end
    self:askName("New name for '" .. tostring(preset.name) .. "':", preset.name or "", ISTileSwapUI.onPresetRenamed)
end

function ISTileSwapUI:onPresetRenamed(button)
    if button.internal ~= "OK" then return end
    local preset = self:getPreset()
    local name = button.parent.entry:getText()
    if not preset or not name or name == "" then return end
    preset.name = name
    self:presetsChanged()
end

function ISTileSwapUI:onDeletePreset()
    local preset = self:getPreset()
    if not preset then return end
    table.remove(self.presets, self.presetCombo.selected)
    -- never leave the dropdown empty
    if #self.presets == 0 then self.presets = Admin.defaultPresets() end
    self:presetsChanged()
    self:setStatus("Deleted '" .. tostring(preset.name) .. "'.")
end

--- Puts the built-in presets back (replacing edited ones with the same
--- name)
function ISTileSwapUI:onRestoreDefaults()
    for _, default in ipairs(Admin.defaultPresets()) do
        local replaced = false
        for i, preset in ipairs(self.presets) do
            if preset.name == default.name then
                self.presets[i] = default
                replaced = true
            end
        end
        if not replaced then table.insert(self.presets, default) end
    end
    self:presetsChanged()
    self:setStatus("Built-in presets restored.")
end

function ISTileSwapUI:onExport()
    local preset = self:getPreset()
    if not preset then
        self:setStatus("Select a preset first.", true)
        return
    end
    local str, err = Admin.presetToString(preset)
    if not str then
        self:setStatus("Could not build a string: " .. tostring(err), true)
        return
    end
    ISTileCopyStringUI.showExport(str)
end

function ISTileSwapUI:onImport()
    ISTileCopyStringUI.showImport(function(preset)
        table.insert(self.presets, preset)
        self:presetsChanged(#self.presets)
        self:setStatus("Imported '" .. tostring(preset.name) .. "' (" .. #preset.rules .. " swap(s)).")
    end, { titleText = "Paste a Tile Swap string", decode = Admin.presetFromString })
end

-------------------------------------------------------------------------------
-- 3. The preset's swaps
-------------------------------------------------------------------------------

function ISTileSwapUI:refreshRules(selected)
    self.ruleList:clear()
    local preset = self:getPreset()
    if preset then
        for i, rule in ipairs(preset.rules) do
            self.ruleList:addItem(i .. ". " .. Admin.describeRule(rule), rule)
        end
    end
    self.ruleList.selected = AdminTools_Tiles_Util.clamp(selected or 1, 1, math.max(1, #self.ruleList.items))
    self.presetChanceEntry:setText(tostring(preset and preset.chance or 100))
end

--- Stores the "Tiles affected %" box in the preset (saved and exported
--- with it).
function ISTileSwapUI:readPresetChance(preset)
    local chance = AdminTools_Tiles_Util.clamp(math.floor(tonumber(self.presetChanceEntry:getText()) or 100), 1, 100)
    local stored = chance < 100 and chance or nil
    if preset.chance ~= stored then
        preset.chance = stored
        Admin.savePresets(self.presets)
    end
    self.presetChanceEntry:setText(tostring(chance))
end

--- A plain swap / remove (always applies, anywhere) is the tile's one fate:
--- adding another for the same tile replaces it instead of piling up.
local function isPlainFate(rule)
    return (rule.action == "swap" or rule.action == "remove") and not rule.chance and not rule.where
end

function ISTileSwapUI:onAddRule()
    local preset = self:getPreset()
    if not preset then
        self:setStatus("Create a preset first.", true)
        return
    end
    local source = self:getSelectedSource()
    if not source then
        self:setStatus("Pick the tile to swap in the left list.", true)
        return
    end

    local rule = { group = source.group, sprite = source.sprite }
    rule.action = self.actionCombo:getOptionData(self.actionCombo.selected)

    if rule.action ~= "remove" then
        local target = self:getSelectedTarget()
        if not target then
            self:setStatus("Pick the tile to swap it with in the right list (search for it, or Pick in World).", true)
            return
        end
        if not getSprite(target) then
            self:setStatus("That tile isn't loaded: " .. target, true)
            return
        end
        if rule.action == "swap" and target == source.sprite then
            self:setStatus("That's the same tile.", true)
            return
        end
        rule.sprites = { target }
    end

    local chance = AdminTools_Tiles_Util.clamp(math.floor(tonumber(self.chanceEntry:getText()) or 100), 1, 100)
    if chance < 100 then rule.chance = chance end
    local where = self.whereCombo:getOptionData(self.whereCombo.selected)
    if where ~= "any" then rule.where = where end

    local index = #preset.rules + 1
    if isPlainFate(rule) then
        for i, existing in ipairs(preset.rules) do
            if isPlainFate(existing) and existing.group == rule.group and existing.sprite == rule.sprite then
                index = i
            end
        end
    end
    preset.rules[index] = rule

    Admin.savePresets(self.presets)
    self:refreshRules(index)
    self.ruleList:ensureVisible(index)
    self:updateButtons()
    self:setStatus("Added: " .. Admin.describeRule(rule))
end

function ISTileSwapUI:onRemoveRule()
    local preset = self:getPreset()
    local index = self.ruleList.selected
    if not preset or not preset.rules[index] then return end
    table.remove(preset.rules, index)
    Admin.savePresets(self.presets)
    self:refreshRules(index)
    self:updateButtons()
end

-------------------------------------------------------------------------------
-- Requests
-------------------------------------------------------------------------------

function ISTileSwapUI:onApply()
    local preset = self:getPreset()
    if not preset or #preset.rules == 0 then
        self:setStatus("That preset is empty: add a swap to it first.", true)
        return
    end
    local args = self:buildArgs()
    if not args then return end
    self:readPresetChance(preset)

    local w = args.x2 - args.x1 + 1
    local h = args.y2 - args.y1 + 1
    local text = "Apply '" .. tostring(preset.name) .. "' to this " .. w .. " x " .. h .. " area?"
    if preset.chance then
        text = "Apply '" .. tostring(preset.name) .. "' to " .. preset.chance .. "% of this " .. w .. " x " .. h .. " area?"
    end
    local mx, my = AdminTools_Tiles_UIUtil.centeredOn(self, 340, 120)
    local modal = ISModalDialog:new(mx, my, 340, 120, text, true, self, ISTileSwapUI.onApplyConfirmed, nil, args, preset)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function ISTileSwapUI:onApplyConfirmed(button, args, preset)
    if button.internal ~= "YES" then return end
    self:setStatus("Swapping...")
    TileCopy.ClientCommands.requestSwap(args, preset)
end

--- Outcome of the last request (see Admin.swapArea), or nil plus a reason.
function ISTileSwapUI:onResult(result, err)
    if not result then
        self:setStatus(tostring(err or "Swap failed."), true)
        return
    end
    local pending = result.pending or 0
    if result.squares == 0 then
        if pending > 0 then
            self:setStatus("Queued: none of the area is loaded yet. It's swapped as players get near it (" .. pending .. " chunk(s) waiting).")
        else
            self:setStatus("Nothing found in that area.", true)
        end
        return
    end
    -- the tiles in the area changed
    self:scan()
    local text = "Swapped " .. tostring(result.swapped) .. ", added " .. tostring(result.overlays) .. " overlay(s), placed "
        .. tostring(result.placed) .. ", removed " .. tostring(result.removed) .. " tile(s)."
    if pending > 0 then
        text = text .. " " .. pending .. " chunk(s) queued until they load."
    end
    self:setStatus(text)
end

--- Teleports the admin over everything that's queued so it loads and gets
--- swapped now (see TileCopy_ClientCommands). Pressed again, stops.
function ISTileSwapUI:onLoadQueued()
    TileCopy.ClientCommands.toggleLoadTour()
end

--- Progress of that tour
function ISTileSwapUI:onLoadTour(text, isError, running)
    self.loadBtn:setTitle(running and "Stop Loading" or LOAD_TEXT)
    -- back home: the tiles of the area may have changed
    if not running and self.area then self:scan() end
    self:setStatus(text, isError)
end

--- Takes back the newest change, one per press (the history holds the last
--- TileCopy.Core.MAX_UNDO pastes / removes / swaps).
function ISTileSwapUI:onUndo()
    -- replaced by what the undo did once it's known (see TileCopy_ClientCommands)
    self:setStatus("Undo requested.")
    TileCopy.ClientCommands.requestUndo()
end

-------------------------------------------------------------------------------
-- Misc
-------------------------------------------------------------------------------

function ISTileSwapUI:setStatus(text, isError)
    AdminTools_Tiles_UIUtil.setStatus(self.statusLabel, text, isError)
end

function ISTileSwapUI:updateButtons()
    local preset = self:getPreset()
    self.addBtn:setEnable(preset ~= nil)
    self.applyBtn:setEnable(self.area ~= nil and preset ~= nil and #preset.rules > 0)
end

function ISTileSwapUI:onClose()
    self:setVisible(false)
end

function ISTileSwapUI:close()
    self:setVisible(false)
end

function ISTileSwapUI.open()
    if not Util.isAdmin(getPlayer()) then return end

    if not ISTileSwapUI.instance then
        local ui = ISTileSwapUI:new()
        ui:initialise()
        ui:addToUIManager()
        ISTileSwapUI.instance = ui
    else
        ISTileSwapUI.instance:setVisible(true)
    end
    ISTileSwapUI.instance:bringToTop()
    return ISTileSwapUI.instance
end
