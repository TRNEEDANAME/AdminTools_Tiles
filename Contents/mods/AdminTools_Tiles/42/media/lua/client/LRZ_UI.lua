-- LRZ_UI.lua
-- Loot Remover window.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISTickBox"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISTextBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISLabel"
require "LRZ_Shared"
require "LRZ_CategoryPicker"
require "LRZ_AdderUI"
require "AdminTools_Tiles_UIUtil"
require "ISTileCopyTool"

LRZ_UI = ISCollapsableWindow:derive("LRZ_UI")
LRZ_UI.instance = nil

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local WIDTH = 780
local CAT_COL_W = 140
local CAT_COLS = 3
local LIST_X = PADDING + CAT_COL_W * CAT_COLS + 10

local COLOR_NORMAL = { r = 0.9, g = 0.9, b = 0.9, a = 1 }
local COLOR_EDITED = { r = 1.0, g = 0.85, b = 0.3, a = 1 }
local COLOR_REMOVED = { r = 1.0, g = 0.4, b = 0.4, a = 1 }

function LRZ_UI:new()
    local height = 560
    local x = (getCore():getScreenWidth() / 2) - (WIDTH / 2)
    local y = (getCore():getScreenHeight() / 2) - (height / 2)

    local o = ISCollapsableWindow:new(x, y, WIDTH, height)
    setmetatable(o, self)
    self.__index = self

    o.title = "Loot Remover"
    o:setResizable(false)
    o.area = nil       -- { x1, y1, x2, y2 }
    o.zoneName = nil   -- set when the area came from an existing zone
    o.entries = {}     -- breakdown rows from the last scan
    return o
end

function LRZ_UI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local y = self:titleBarHeight() + PADDING

    -- Row: area source
    self.selectBtn = ISButton:new(PADDING, y, 150, BTN_H, "Drag Select Area", self, LRZ_UI.onSelectArea)
    self.selectBtn:initialise()
    self:addChild(self.selectBtn)

    self.zoneLabel = ISLabel:new(PADDING + 160, y, BTN_H, "or use zone:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.zoneLabel)

    local comboX = PADDING + 160 + getTextManager():MeasureStringX(UIFont.Small, "or use zone:") + 8
    self.zoneCombo = ISComboBox:new(comboX, y, WIDTH - comboX - PADDING, BTN_H, self, LRZ_UI.onZoneChanged)
    self.zoneCombo:initialise()
    self:addChild(self.zoneCombo)
    y = y + BTN_H + 6

    self.areaLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "No area selected", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.areaLabel)
    y = y + FONT_HGT_SMALL + 6

    -- Row: floor range
    self.floors = AdminTools_Tiles_UIUtil.createFloorRow(self, PADDING, y, BTN_H)

    self.myFloorBtn = ISButton:new(self.floors.right + 10, y, 90, BTN_H, "My Floor", self, LRZ_UI.onMyFloor)
    self.myFloorBtn:initialise()
    self:addChild(self.myFloorBtn)

    self.adderBtn = ISButton:new(WIDTH - PADDING - 150, y, 150, BTN_H, "Add Loot...", self, LRZ_UI.onOpenAdder)
    self.adderBtn:initialise()
    self:addChild(self.adderBtn)
    y = y + BTN_H + 8

    -- Row: scan
    self.scanBtn = ISButton:new(PADDING, y, 150, BTN_H, "Scan Containers", self, LRZ_UI.onScan)
    self.scanBtn:initialise()
    self:addChild(self.scanBtn)

    self.summaryLabel = ISLabel:new(PADDING + 160, y, BTN_H, "", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.summaryLabel)
    y = y + BTN_H + 10

    -- Left: categories
    local top = y
    self.categories = LRZ_CategoryPicker.create(self, PADDING, y, CAT_COL_W, CAT_COLS, function()
        self:refreshList()
    end, function()
        -- Counts change with the ground tick: rescan if a breakdown is showing
        if #self.entries > 0 then self:onScan() end
    end)
    local colBottom = self.categories.bottom

    -- Right: breakdown list
    local listW = WIDTH - LIST_X - PADDING
    local listH = math.max(colBottom - top, 220)
    self.itemList = ISScrollingListBox:new(LIST_X, top, listW, listH)
    self.itemList:initialise()
    self.itemList:instantiate()
    self.itemList:setFont(UIFont.Small, 2)
    self.itemList.drawBorder = true
    self.itemList:setOnMouseDoubleClick(self, LRZ_UI.onSetAmountFor)
    self:addChild(self.itemList)
    y = top + listH + 6

    local btnW = (listW - 10) / 3
    self.setAmountBtn = ISButton:new(LIST_X, y, btnW, BTN_H, "Set Amount", self, LRZ_UI.onSetAmount)
    self.setAmountBtn:initialise()
    self:addChild(self.setAmountBtn)

    self.removeItemBtn = ISButton:new(LIST_X + btnW + 5, y, btnW, BTN_H, "Remove Item", self, LRZ_UI.onRemoveItem)
    self.removeItemBtn:initialise()
    self:addChild(self.removeItemBtn)

    self.resetBtn = ISButton:new(LIST_X + (btnW + 5) * 2, y, btnW, BTN_H, "Reset", self, LRZ_UI.onReset)
    self.resetBtn:initialise()
    self:addChild(self.resetBtn)
    y = y + BTN_H + 12

    -- Bottom: actions
    self.percentLabel = ISLabel:new(PADDING, y, BTN_H, "Percent:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.percentLabel)
    local px = PADDING + getTextManager():MeasureStringX(UIFont.Small, "Percent:") + 8

    self.percentEntry = ISTextEntryBox:new("100", px, y, 45, BTN_H)
    self.percentEntry:initialise()
    self.percentEntry:instantiate()
    self.percentEntry:setOnlyNumbers(true)
    self:addChild(self.percentEntry)

    self.percentBtn = ISButton:new(px + 55, y, 190, BTN_H, "Remove % of Checked", self, LRZ_UI.onRemovePercent)
    self.percentBtn:initialise()
    self:addChild(self.percentBtn)

    self.applyBtn = ISButton:new(LIST_X, y, listW, BTN_H, "Apply Item Changes", self, LRZ_UI.onApplyEdits)
    self.applyBtn:initialise()
    self:addChild(self.applyBtn)
    y = y + BTN_H + 8

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)

    self.closeBtn = ISButton:new(WIDTH - PADDING - 100, y, 100, BTN_H, "Close", self, LRZ_UI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
    y = y + BTN_H + PADDING

    self:setHeight(y)
    self:refreshZones()
    self:updateButtons()
end

-------------------------------------------------------------------------------
-- Area / floors
-------------------------------------------------------------------------------

function LRZ_UI:onMyFloor()
    self.floors:setFloor(AdminTools_Tiles_Util.playerFloor())
end

function LRZ_UI:setArea(x1, y1, x2, y2, zoneName)
    self.area = {
        x1 = math.min(x1, x2), y1 = math.min(y1, y2),
        x2 = math.max(x1, x2), y2 = math.max(y1, y2),
    }
    self.zoneName = zoneName
    local w = self.area.x2 - self.area.x1 + 1
    local h = self.area.y2 - self.area.y1 + 1
    local text = w .. " x " .. h .. " tiles  (" .. self.area.x1 .. "," .. self.area.y1 .. " -> " .. self.area.x2 .. "," .. self.area.y2 .. ")"
    if zoneName then
        text = zoneName .. ": " .. text .. "  - bulk only"
    end
    self.areaLabel:setName(text)
    self:clearBreakdown()
    self:updateButtons()
end

function LRZ_UI:onSelectArea()
    if not ISTileCopyTool.instance then return end
    self.zoneCombo.selected = 1
    self:setVisible(false)
    ISTileCopyTool.instance:startSelecting(AdminTools_Tiles_Util.playerFloor(), function(x1, y1, x2, y2, zSel)
        ISTileCopyTool.instance:cancel()
        self:setArea(x1, y1, x2, y2, nil)
        -- Default the floor range to the floor the drag was made on
        self.floors:setFloor(zSel)
        self:setVisible(true)
        self:bringToTop()
    end)
end

-- Fills the zone dropdown with the admin zone editor's zones.
function LRZ_UI:refreshZones()
    self.zoneCombo:clear()
    self.zoneCombo:addOptionWithData("(drag select)", nil)

    if NonPvpZone and NonPvpZone.getAllZones then
        local zones = NonPvpZone.getAllZones()
        for i = 0, zones:size() - 1 do
            local zone = zones:get(i)
            self.zoneCombo:addOptionWithData("[Non-PvP] " .. zone:getTitle(), {
                name = zone:getTitle(), x1 = zone:getX(), y1 = zone:getY(), x2 = zone:getX2(), y2 = zone:getY2(),
            })
        end
    end

    if SafeHouse and SafeHouse.getSafehouseList then
        local houses = SafeHouse.getSafehouseList()
        for i = 0, houses:size() - 1 do
            local house = houses:get(i)
            self.zoneCombo:addOptionWithData("[Safehouse] " .. house:getTitle(), {
                name = house:getTitle(), x1 = house:getX(), y1 = house:getY(), x2 = house:getX2() - 1, y2 = house:getY2() - 1,
            })
        end
    end

    -- Keep the previously picked zone selected when the window is reopened
    self.zoneCombo.selected = 1
    if self.zoneName then
        for i = 2, #self.zoneCombo.options do
            local data = self.zoneCombo:getOptionData(i)
            if data and data.name == self.zoneName then
                self.zoneCombo.selected = i
            end
        end
    end
end

function LRZ_UI:onZoneChanged()
    local zone = self.zoneCombo:getOptionData(self.zoneCombo.selected)
    if zone then
        self:setArea(zone.x1, zone.y1, zone.x2, zone.y2, zone.name)
    else
        self.area = nil
        self.zoneName = nil
        self.areaLabel:setName("No area selected")
        self:clearBreakdown()
        self:updateButtons()
    end
end

function LRZ_UI:buildArgs()
    local z1, z2 = self.floors:getRange()
    return {
        x1 = self.area.x1, y1 = self.area.y1, x2 = self.area.x2, y2 = self.area.y2,
        z1 = z1, z2 = z2,
        ground = self.categories:includeGround(),
    }
end

-- Client-side size check so the admin gets feedback before the round trip.
function LRZ_UI:checkSize()
    local a = self:buildArgs()
    local tooBig = LRZ.TooBigMessage(a)
    if tooBig then
        self:setStatus(tooBig, true)
        return nil
    end
    return a
end

-- Area for the Loot Adder window.
function LRZ_UI:getLootArgs()
    if not self.area then
        return nil, "Select an area in the Loot Remover first."
    end
    local args = self:buildArgs()
    -- Refresh the breakdown afterwards if one is showing
    args.rescan = #self.entries > 0
    return args
end

function LRZ_UI:onOpenAdder()
    LRZ_AdderUI.open(self)
end

-------------------------------------------------------------------------------
-- Breakdown list
-------------------------------------------------------------------------------

function LRZ_UI:clearBreakdown()
    self.entries = {}
    self.summaryLabel:setName("")
    self:refreshList()
end

function LRZ_UI:onScanResult(args)
    self.entries = {}
    for _, e in ipairs(args.entries or {}) do
        table.insert(self.entries, { type = e.type, ground = e.ground == true, name = e.name, cat = e.cat, count = e.count, target = e.count })
    end
    table.sort(self.entries, function(a, b)
        if a.cat ~= b.cat then return a.cat < b.cat end
        if a.name ~= b.name then return a.name < b.name end
        -- Container row first, then the same item on the ground
        return b.ground and not a.ground
    end)
    local summary = tostring(args.total or 0) .. " item(s), " .. #self.entries .. " type(s) in " .. tostring(args.containers or 0) .. " container(s)"
    if args.ground then
        summary = summary .. " + " .. tostring(args.ground) .. " on the ground"
    end
    self.summaryLabel:setName(summary)
    if args.removed then
        self:setStatus("Removed " .. tostring(args.removed) .. " item(s).")
    else
        self:setStatus("Scan complete.")
    end
    self:refreshList()
    self:updateButtons()
end

local function rowText(e)
    local name = e.ground and (e.name .. " (on ground)") or e.name
    if e.target == e.count then
        return string.format("%s  [%s]   x%d", name, e.cat, e.count)
    end
    return string.format("%s  [%s]   x%d -> %d", name, e.cat, e.count, e.target)
end

function LRZ_UI:refreshList()
    local selected = self:getSelectedEntry()
    local checked = self.categories:getChecked()

    self.itemList:clear()
    for _, e in ipairs(self.entries) do
        if not checked or checked[e.cat] then
            local row = self.itemList:addItem(rowText(e), e)
            if e.target == 0 then
                row.textColor = COLOR_REMOVED
            elseif e.target ~= e.count then
                row.textColor = COLOR_EDITED
            else
                row.textColor = COLOR_NORMAL
            end
        end
    end

    self.itemList.selected = 0
    for i, row in ipairs(self.itemList.items) do
        if selected and row.item.type == selected.type and row.item.ground == selected.ground then
            self.itemList.selected = i
        end
    end
end

function LRZ_UI:getSelectedEntry()
    local row = self.itemList.items[self.itemList.selected]
    return row and row.item
end

function LRZ_UI:onSetAmount()
    local e = self:getSelectedEntry()
    if e then self:onSetAmountFor(e) end
end

function LRZ_UI:onSetAmountFor(e)
    local prompt = "Keep how many " .. e.name .. "? (0 - " .. e.count .. ")"
    local modal = ISTextBox:new(0, 0, 280, 180, prompt, tostring(e.target), self, LRZ_UI.onAmountEntered, getPlayer():getPlayerNum(), e)
    modal:initialise()
    modal:setOnlyNumbers(true)
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function LRZ_UI:onAmountEntered(button, e)
    if button.internal ~= "OK" then return end
    local n = tonumber(button.parent.entry:getText())
    if not n then return end
    -- Only removal for now: amounts above what's there are capped.
    e.target = math.max(0, math.min(e.count, math.floor(n)))
    self:refreshList()
end

function LRZ_UI:onRemoveItem()
    local e = self:getSelectedEntry()
    if not e then return end
    e.target = 0
    self:refreshList()
end

function LRZ_UI:onReset()
    for _, e in ipairs(self.entries) do
        e.target = e.count
    end
    self:refreshList()
end

-------------------------------------------------------------------------------
-- Requests
-------------------------------------------------------------------------------

function LRZ_UI:onScan()
    if not self.area or self.zoneName then return end
    local args = self:checkSize()
    if not args then return end
    self:setStatus("Scanning...")
    sendClientCommand(getPlayer(), LRZ.ModuleName, LRZ.CMD_SCAN, args)
end

function LRZ_UI:onRemovePercent()
    if not self.area then return end
    local args = self:checkSize()
    if not args then return end

    local percent = tonumber(self.percentEntry:getText()) or 100
    args.percent = math.max(0, math.min(100, percent))

    args.categories = self.categories:getRequestCategories()
    if not args.categories then
        self:setStatus("Tick at least one category.", true)
        return
    end

    -- Refresh the breakdown afterwards if one is showing
    args.rescan = #self.entries > 0
    self:setStatus("Removing...")
    sendClientCommand(getPlayer(), LRZ.ModuleName, LRZ.CMD_REMOVE_LOOT, args)
end

function LRZ_UI:onApplyEdits()
    if not self.area or self.zoneName then return end
    local edits = {}
    for _, e in ipairs(self.entries) do
        if e.target ~= e.count then
            table.insert(edits, { type = e.type, ground = e.ground, target = e.target })
        end
    end
    if #edits == 0 then
        self:setStatus("No item changes to apply.", true)
        return
    end
    local args = self:checkSize()
    if not args then return end
    args.edits = edits
    self:setStatus("Applying...")
    sendClientCommand(getPlayer(), LRZ.ModuleName, LRZ.CMD_APPLY_EDITS, args)
end

-------------------------------------------------------------------------------
-- Misc
-------------------------------------------------------------------------------

function LRZ_UI:setStatus(text, isError)
    AdminTools_Tiles_UIUtil.setStatus(self.statusLabel, text, isError)
end

function LRZ_UI:updateButtons()
    local hasArea = self.area ~= nil
    local breakdownAllowed = hasArea and not self.zoneName
    local hasEntries = #self.entries > 0
    self.scanBtn:setEnable(breakdownAllowed)
    self.percentBtn:setEnable(hasArea)
    self.applyBtn:setEnable(breakdownAllowed and hasEntries)
    self.setAmountBtn:setEnable(hasEntries)
    self.removeItemBtn:setEnable(hasEntries)
    self.resetBtn:setEnable(hasEntries)
end

function LRZ_UI:onClose()
    self:setVisible(false)
end

function LRZ_UI:close()
    self:setVisible(false)
end

function LRZ_UI.open()
    if not LRZ_UI.instance then
        local ui = LRZ_UI:new()
        ui:initialise()
        ui:addToUIManager()
        LRZ_UI.instance = ui
    else
        LRZ_UI.instance:refreshZones()
        LRZ_UI.instance:setVisible(true)
    end
    LRZ_UI.instance:bringToTop()
    return LRZ_UI.instance
end
