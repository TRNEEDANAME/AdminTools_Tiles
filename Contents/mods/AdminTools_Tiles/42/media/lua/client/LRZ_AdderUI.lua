-- LRZ_AdderUI.lua
-- Loot Adder window, opened from the Loot Remover window or the Zone Editor's
-- Loot Removal mode (the "owner"), which supplies the area.
--   - source "Items": pick item types from your inventory (copies are
--     spawned, yours are untouched) and how many of each
--   - source "Reroll": every container gets a fresh roll from the game's
--     loot tables, like the admin "Refill container" option
--   - source "Random by container type": "Scan" lists the container types
--     in the area; each type gets its own category ticks and an amount, and
--     every container of that type gets that many random items from them
--   - either adds on top of what's there, or replaces it
--   - ticking categories (like the Loot Remover) filters the inventory list,
--     limits rerolled loot to those categories and makes "Replace" only
--     empty those categories (per container type for the random source)
--   - an item list (LRZ_ItemLists: a whitelist or a blacklist, edited in
--     LRZ_ItemListUI, shared as a string) limits what any source adds
--
-- The owner implements getLootArgs() -> args (x1, y1, x2, y2, z1, z2 and
-- optionally rescan) or nil, errorText.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISTickBox"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISTextBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISLabel"
require "ISUI/ISModalDialog"
require "LRZ_Shared"
require "LRZ_CategoryPicker"
require "LRZ_ItemLists"
require "LRZ_ItemListUI"
require "ISTileCopyStringUI"
require "AdminTools_Tiles_UIUtil"

LRZ_AdderUI = ISCollapsableWindow:derive("LRZ_AdderUI")
LRZ_AdderUI.instance = nil

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local CAT_COL_W = 140
local CAT_COLS = 3
local RIGHT_X = PADDING + CAT_COL_W * CAT_COLS + 10
local RIGHT_W = 440
local WIDTH = RIGHT_X + RIGHT_W + PADDING
local INV_LIST_H = 150
local ADD_LIST_H = 110
local TYPE_LIST_H = INV_LIST_H + 8 + FONT_HGT_SMALL + 4 + ADD_LIST_H
local DEFAULT_PER_CONTAINER = 3

local COLOR_SKIPPED = { r = 0.55, g = 0.55, b = 0.55, a = 1 }
local COLOR_PLANNED = { r = 0.9, g = 0.9, b = 0.9, a = 1 }

local SOURCE_OPTIONS = {
    { label = "Items from my inventory", source = LRZ.SOURCE_ITEMS },
    { label = "Reroll vanilla loot (admin refill)", source = LRZ.SOURCE_REROLL },
    { label = "Random items by container type", source = LRZ.SOURCE_RANDOM },
}

function LRZ_AdderUI:new()
    local x = (getCore():getScreenWidth() / 2) - (WIDTH / 2)
    local y = (getCore():getScreenHeight() / 2) - 300

    local o = ISCollapsableWindow:new(x, y, WIDTH, 600)
    setmetatable(o, self)
    self.__index = self

    o.title = "Loot Filler"
    o:setResizable(false)
    o.owner = nil
    o.inventory = {}   -- { type, name, cat, count } from the last refresh
    o.toAdd = {}       -- { type, name, count }
    o.containerTypes = {}  -- { type, name, count } from the last container scan
    o.typeConfig = {}      -- by container type: { checked (as getChecked), amount }
    o.sharedChecked = nil  -- the other sources' ticks while editing a container type
    o.itemLists = LRZ_ItemLists.load()  -- see LRZ_ItemLists
    return o
end

function LRZ_AdderUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local innerW = WIDTH - PADDING * 2
    local y = self:titleBarHeight() + PADDING

    self.areaLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.areaLabel)
    y = y + FONT_HGT_SMALL + 8

    -- Row: source
    local sourceLabel = ISLabel:new(PADDING, y, BTN_H, "Source:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(sourceLabel)
    local sx = PADDING + getTextManager():MeasureStringX(UIFont.Small, "Source:") + 8
    self.sourceCombo = ISComboBox:new(sx, y, WIDTH - sx - PADDING, BTN_H, self, LRZ_AdderUI.onSourceChanged)
    self.sourceCombo:initialise()
    for _, opt in ipairs(SOURCE_OPTIONS) do
        self.sourceCombo:addOptionWithData(opt.label, opt.source)
    end
    self:addChild(self.sourceCombo)
    y = y + BTN_H + 6

    -- Row: item list
    local listLabel = ISLabel:new(PADDING, y, BTN_H, "Item list:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(listLabel)
    local listButtons = {
        { text = "Edit", w = 50, fn = LRZ_AdderUI.onEditList },
        { text = "New", w = 50, fn = LRZ_AdderUI.onNewList },
        { text = "Delete", w = 60, fn = LRZ_AdderUI.onDeleteList },
        { text = "Export", w = 60, fn = LRZ_AdderUI.onExportList },
        { text = "Import", w = 60, fn = LRZ_AdderUI.onImportList },
        { text = "Restore Defaults", w = 120, fn = LRZ_AdderUI.onRestoreLists },
    }
    local buttonsW = 0
    for _, def in ipairs(listButtons) do buttonsW = buttonsW + def.w + 5 end
    local lx = PADDING + getTextManager():MeasureStringX(UIFont.Small, "Item list:") + 8
    self.listCombo = ISComboBox:new(lx, y, WIDTH - lx - PADDING - buttonsW, BTN_H, self, LRZ_AdderUI.onListChanged)
    self.listCombo:initialise()
    self:addChild(self.listCombo)
    local bx = WIDTH - PADDING - buttonsW + 5
    for _, def in ipairs(listButtons) do
        local btn = ISButton:new(bx, y, def.w, BTN_H, def.text, self, def.fn)
        btn:initialise()
        self:addChild(btn)
        bx = bx + def.w + 5
    end
    self:refreshListCombo(1)
    y = y + BTN_H + 10

    -- Left: categories
    local top = y
    self.categories = LRZ_CategoryPicker.create(self, PADDING, y, CAT_COL_W, CAT_COLS, function()
        self:onCategoriesChanged()
    end, nil, true)

    -- Right: items section (hidden when rerolling)
    self.itemWidgets = {}
    local function addItemWidget(widget)
        self:addChild(widget)
        table.insert(self.itemWidgets, widget)
    end

    local invLabel = ISLabel:new(RIGHT_X, y, BTN_H, "Your inventory (double-click to add):", 1, 1, 1, 1, UIFont.Small, true)
    addItemWidget(invLabel)
    self.refreshBtn = ISButton:new(WIDTH - PADDING - 80, y, 80, BTN_H, "Refresh", self, LRZ_AdderUI.refreshInventory)
    self.refreshBtn:initialise()
    addItemWidget(self.refreshBtn)
    y = y + BTN_H + 4

    self.invList = ISScrollingListBox:new(RIGHT_X, y, RIGHT_W, INV_LIST_H)
    self.invList:initialise()
    self.invList:instantiate()
    self.invList:setFont(UIFont.Small, 2)
    self.invList.drawBorder = true
    self.invList:setOnMouseDoubleClick(self, LRZ_AdderUI.onPickItem)
    addItemWidget(self.invList)
    y = y + INV_LIST_H + 8

    local addLabel = ISLabel:new(RIGHT_X, y, FONT_HGT_SMALL, "To add (double-click to change the amount):", 1, 1, 1, 1, UIFont.Small, true)
    addItemWidget(addLabel)
    y = y + FONT_HGT_SMALL + 4

    self.addList = ISScrollingListBox:new(RIGHT_X, y, RIGHT_W, ADD_LIST_H)
    self.addList:initialise()
    self.addList:instantiate()
    self.addList:setFont(UIFont.Small, 2)
    self.addList.drawBorder = true
    self.addList:setOnMouseDoubleClick(self, LRZ_AdderUI.promptAmount)
    addItemWidget(self.addList)
    y = y + ADD_LIST_H + 6

    local btnW = (RIGHT_W - 10) / 3
    self.setAmountBtn = ISButton:new(RIGHT_X, y, btnW, BTN_H, "Set Amount", self, LRZ_AdderUI.onSetAmount)
    self.setAmountBtn:initialise()
    addItemWidget(self.setAmountBtn)

    self.removeBtn = ISButton:new(RIGHT_X + btnW + 5, y, btnW, BTN_H, "Remove", self, LRZ_AdderUI.onRemoveEntry)
    self.removeBtn:initialise()
    addItemWidget(self.removeBtn)

    self.clearBtn = ISButton:new(RIGHT_X + (btnW + 5) * 2, y, btnW, BTN_H, "Clear", self, LRZ_AdderUI.onClearEntries)
    self.clearBtn:initialise()
    addItemWidget(self.clearBtn)
    y = y + BTN_H + 8

    local amountLabel = ISLabel:new(RIGHT_X, y, BTN_H, "Amount is:", 1, 1, 1, 1, UIFont.Small, true)
    addItemWidget(amountLabel)
    local ax = RIGHT_X + getTextManager():MeasureStringX(UIFont.Small, "Amount is:") + 8
    self.spreadCombo = ISComboBox:new(ax, y, WIDTH - ax - PADDING, BTN_H, nil, nil)
    self.spreadCombo:initialise()
    self.spreadCombo:addOptionWithData("Total, spread over random containers", false)
    self.spreadCombo:addOptionWithData("Per container (every container gets it)", true)
    addItemWidget(self.spreadCombo)
    y = y + BTN_H

    -- Shown in the items section's place when rerolling
    self.rerollNotes = {}
    for i, line in ipairs({
        "Every container gets a fresh roll from the game's loot tables",
        "for its room. Only items in the ticked categories are kept.",
    }) do
        local note = ISLabel:new(RIGHT_X, top + (i - 1) * (FONT_HGT_SMALL + 2), FONT_HGT_SMALL, line,
            0.8, 0.8, 0.8, 1, UIFont.Small, true)
        self:addChild(note)
        table.insert(self.rerollNotes, note)
    end

    -- Shown in the items section's place for "Random by container type"
    self.typeWidgets = {}
    local function addTypeWidget(widget)
        self:addChild(widget)
        table.insert(self.typeWidgets, widget)
    end

    local ty = top
    local typeLabel = ISLabel:new(RIGHT_X, ty, BTN_H, "Container types (click one, tick its categories):", 1, 1, 1, 1, UIFont.Small, true)
    addTypeWidget(typeLabel)
    self.scanTypesBtn = ISButton:new(WIDTH - PADDING - 80, ty, 80, BTN_H, "Scan", self, LRZ_AdderUI.onScanContainers)
    self.scanTypesBtn:initialise()
    addTypeWidget(self.scanTypesBtn)
    ty = ty + BTN_H + 4

    self.typeList = ISScrollingListBox:new(RIGHT_X, ty, RIGHT_W, TYPE_LIST_H)
    self.typeList:initialise()
    self.typeList:instantiate()
    self.typeList:setFont(UIFont.Small, 2)
    self.typeList.drawBorder = true
    self.typeList:setOnMouseDownFunction(self, LRZ_AdderUI.onTypeSelected)
    self.typeList:setOnMouseDoubleClick(self, LRZ_AdderUI.promptTypeAmount)
    addTypeWidget(self.typeList)
    ty = ty + TYPE_LIST_H + 6

    self.typeAmountBtn = ISButton:new(RIGHT_X, ty, btnW, BTN_H, "Items per Container", self, LRZ_AdderUI.onSetTypeAmount)
    self.typeAmountBtn:initialise()
    addTypeWidget(self.typeAmountBtn)

    self.copyTypeBtn = ISButton:new(RIGHT_X + btnW + 5, ty, btnW, BTN_H, "Copy to All Types", self, LRZ_AdderUI.onCopyTypeToAll)
    self.copyTypeBtn:initialise()
    addTypeWidget(self.copyTypeBtn)

    self.clearTypeBtn = ISButton:new(RIGHT_X + (btnW + 5) * 2, ty, btnW, BTN_H, "Clear Type", self, LRZ_AdderUI.onClearType)
    self.clearTypeBtn:initialise()
    addTypeWidget(self.clearTypeBtn)
    ty = ty + BTN_H + 8

    local typeNote = ISLabel:new(RIGHT_X, ty, BTN_H, "Each container gets that many random items from its type's categories.",
        0.8, 0.8, 0.8, 1, UIFont.Small, true)
    addTypeWidget(typeNote)

    y = math.max(y, self.categories.bottom) + 10

    -- Mode
    self.replaceTick = ISTickBox:new(PADDING, y, innerW, FONT_HGT_SMALL, "", nil, nil)
    self.replaceTick:initialise()
    self.replaceTick:addOption("Replace existing contents (empty the ticked categories out of the containers first)")
    self:addChild(self.replaceTick)
    y = y + self.replaceTick:getHeight() + 10

    -- Actions
    self.addBtn = ISButton:new(PADDING, y, innerW, BTN_H, "Add Loot", self, LRZ_AdderUI.onAddLoot)
    self.addBtn:initialise()
    self:addChild(self.addBtn)
    y = y + BTN_H + 8

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)

    self.closeBtn = ISButton:new(WIDTH - PADDING - 100, y, 100, BTN_H, "Close", self, LRZ_AdderUI.close)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
    y = y + BTN_H + PADDING

    self:setHeight(y)
    self:onSourceChanged()
    self:refreshInventory()
end

-------------------------------------------------------------------------------
-- Source
-------------------------------------------------------------------------------

function LRZ_AdderUI:getSource()
    return self.sourceCombo:getOptionData(self.sourceCombo.selected)
end

function LRZ_AdderUI:onSourceChanged()
    local source = self:getSource()
    local random = source == LRZ.SOURCE_RANDOM

    -- The category ticks show the selected container type's categories while
    -- on the random source, and the shared ones otherwise
    if random and self.lastSource ~= LRZ.SOURCE_RANDOM then
        self.sharedChecked = self.categories:getChecked()
        self:loadSelectedType()
    elseif not random and self.lastSource == LRZ.SOURCE_RANDOM then
        self.categories:setChecked(self.sharedChecked)
        self:refreshInvList()
    end
    self.lastSource = source

    for _, widget in ipairs(self.itemWidgets) do
        widget:setVisible(source == LRZ.SOURCE_ITEMS)
    end
    for _, note in ipairs(self.rerollNotes) do
        note:setVisible(source == LRZ.SOURCE_REROLL)
    end
    for _, widget in ipairs(self.typeWidgets) do
        widget:setVisible(random)
    end
end

function LRZ_AdderUI:onCategoriesChanged()
    if self:getSource() ~= LRZ.SOURCE_RANDOM then
        self:refreshInvList()
        return
    end
    local t = self:getSelectedType()
    if not t then
        self:setStatus("Scan and pick a container type first.", true)
        return
    end
    self:getTypeConfig(t.type).checked = self.categories:getChecked()
    self:refreshTypeList()
end

-------------------------------------------------------------------------------
-- Container types (random source)
-------------------------------------------------------------------------------

local function containerTypeName(containerType)
    return getTextOrNull("IGUI_ContainerTitle_" .. containerType) or containerType
end

-- Request category list for a getChecked() result, or nil when nothing is ticked.
local function checkedToCategories(checked)
    if not checked then return { LRZ.ALL_KEY } end
    local list = {}
    for cat in pairs(checked) do
        table.insert(list, cat)
    end
    if #list == 0 then return nil end
    table.sort(list)
    return list
end

function LRZ_AdderUI:getTypeConfig(containerType)
    local cfg = self.typeConfig[containerType]
    if not cfg then
        cfg = { checked = {}, amount = DEFAULT_PER_CONTAINER }
        self.typeConfig[containerType] = cfg
    end
    return cfg
end

function LRZ_AdderUI:getSelectedType()
    local row = self.typeList.items[self.typeList.selected]
    return row and row.item
end

local function typeRowText(t, cfg)
    local cats = checkedToCategories(cfg.checked)
    if not cats then
        return string.format("%s  (x%d)  - skipped", t.name, t.count)
    end
    local catText = cats[1] == LRZ.ALL_KEY and "ALL categories" or table.concat(cats, ", ")
    return string.format("%s  (x%d)  - %d each: %s", t.name, t.count, cfg.amount, catText)
end

function LRZ_AdderUI:refreshTypeList()
    local selected = self:getSelectedType()
    self.typeList:clear()
    for _, t in ipairs(self.containerTypes) do
        local cfg = self:getTypeConfig(t.type)
        local row = self.typeList:addItem(typeRowText(t, cfg), t)
        row.textColor = checkedToCategories(cfg.checked) and COLOR_PLANNED or COLOR_SKIPPED
    end
    self.typeList.selected = #self.typeList.items > 0 and 1 or 0
    for i, row in ipairs(self.typeList.items) do
        if selected and row.item.type == selected.type then
            self.typeList.selected = i
        end
    end
end

-- Shows the selected container type's ticks.
function LRZ_AdderUI:loadSelectedType()
    local t = self:getSelectedType()
    if t then
        -- checked can be nil (ALL)
        self.categories:setChecked(self:getTypeConfig(t.type).checked)
    else
        self.categories:setChecked({})
    end
end

function LRZ_AdderUI:onTypeSelected(t)
    self:loadSelectedType()
end

function LRZ_AdderUI:onScanContainers()
    local args = self:getAreaArgs()
    if not args then return end
    self:setStatus("Scanning containers...")
    sendClientCommand(getPlayer(), LRZ.ModuleName, LRZ.CMD_SCAN_CONTAINERS, args)
end

-- Server reply (LRZ.RES_CONTAINERS).
function LRZ_AdderUI:onContainerTypes(args)
    self.containerTypes = {}
    for _, t in ipairs(args.types or {}) do
        table.insert(self.containerTypes, { type = t.type, name = containerTypeName(t.type), count = t.count })
    end
    table.sort(self.containerTypes, function(a, b) return a.name < b.name end)
    self:refreshTypeList()
    if self:getSource() == LRZ.SOURCE_RANDOM then
        self:loadSelectedType()
    end
    if #self.containerTypes == 0 then
        self:setStatus("No containers found - is the area loaded (near a player)?", true)
    else
        self:setStatus(string.format("Found %d container(s) of %d type(s).", args.containers or 0, #self.containerTypes))
    end
end

function LRZ_AdderUI:promptTypeAmount(t)
    local cfg = self:getTypeConfig(t.type)
    local modal = ISTextBox:new(0, 0, 280, 180, "Random items per " .. t.name .. "?", tostring(cfg.amount), self, LRZ_AdderUI.onTypeAmountEntered, getPlayer():getPlayerNum(), t)
    modal:initialise()
    modal:setOnlyNumbers(true)
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function LRZ_AdderUI:onTypeAmountEntered(button, t)
    if button.internal ~= "OK" then return end
    local n = tonumber(button.parent.entry:getText())
    if not n then return end
    self:getTypeConfig(t.type).amount = AdminTools_Tiles_Util.clamp(math.floor(n), 1, LRZ.MAX_ADD_ITEMS)
    self:refreshTypeList()
end

function LRZ_AdderUI:onSetTypeAmount()
    local t = self:getSelectedType()
    if t then self:promptTypeAmount(t) end
end

-- Gives every scanned container type the selected type's categories and amount.
function LRZ_AdderUI:onCopyTypeToAll()
    local t = self:getSelectedType()
    if not t then return end
    local src = self:getTypeConfig(t.type)
    for _, other in ipairs(self.containerTypes) do
        local cfg = self:getTypeConfig(other.type)
        cfg.amount = src.amount
        if src.checked then
            cfg.checked = {}
            for cat in pairs(src.checked) do cfg.checked[cat] = true end
        else
            cfg.checked = nil
        end
    end
    self:refreshTypeList()
end

function LRZ_AdderUI:onClearType()
    local t = self:getSelectedType()
    if not t then return end
    self:getTypeConfig(t.type).checked = {}
    self:loadSelectedType()
    self:refreshTypeList()
end

-------------------------------------------------------------------------------
-- Item lists
-------------------------------------------------------------------------------

-- Counts every item in `container` by type, including inside bags.
local function gatherInventory(container, byType, list)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local fullType = item:getFullType()
        local entry = byType[fullType]
        if not entry then
            entry = { type = fullType, name = item:getDisplayName(), cat = LRZ.GetItemCategory(item), count = 0 }
            byType[fullType] = entry
            table.insert(list, entry)
        end
        entry.count = entry.count + 1
        if instanceof(item, "InventoryContainer") then
            gatherInventory(item:getInventory(), byType, list)
        end
    end
end

function LRZ_AdderUI:refreshInventory()
    self.inventory = {}
    local player = getPlayer()
    if player then
        gatherInventory(player:getInventory(), {}, self.inventory)
        table.sort(self.inventory, function(a, b) return a.name < b.name end)
    end
    self:refreshInvList()
end

-- Shows the inventory rows in the ticked categories, greying out what the
-- item list / sandbox blacklist won't let through (the server skips those).
function LRZ_AdderUI:refreshInvList()
    local checked = self.categories:getChecked()
    local allowed = LRZ.AllowedFilter(self:getItemList())
    self.invList:clear()
    for _, e in ipairs(self.inventory) do
        if not checked or checked[e.cat] then
            local text = string.format("%s  [%s]  (x%d)", e.name, e.cat, e.count)
            if allowed and not allowed(e.type) then
                local row = self.invList:addItem(text .. "  - not allowed", e)
                row.textColor = COLOR_SKIPPED
            else
                self.invList:addItem(text, e)
            end
        end
    end
end

function LRZ_AdderUI:refreshAddList()
    local selected = self.addList.selected
    self.addList:clear()
    for _, e in ipairs(self.toAdd) do
        self.addList:addItem(string.format("%s   x%d", e.name, e.count), e)
    end
    self.addList.selected = math.min(selected, #self.addList.items)
end

function LRZ_AdderUI:findEntry(fullType)
    for _, e in ipairs(self.toAdd) do
        if e.type == fullType then return e end
    end
    return nil
end

-- Double-click in the inventory list: add the type (or bump it) and ask how many.
function LRZ_AdderUI:onPickItem(invEntry)
    local e = self:findEntry(invEntry.type)
    if not e then
        e = { type = invEntry.type, name = invEntry.name, count = 1 }
        table.insert(self.toAdd, e)
        self:refreshAddList()
    end
    self:promptAmount(e)
end

function LRZ_AdderUI:getSelectedEntry()
    local row = self.addList.items[self.addList.selected]
    return row and row.item
end

function LRZ_AdderUI:onSetAmount()
    local e = self:getSelectedEntry()
    if e then self:promptAmount(e) end
end

function LRZ_AdderUI:promptAmount(e)
    local modal = ISTextBox:new(0, 0, 280, 180, "Add how many " .. e.name .. "?", tostring(e.count), self, LRZ_AdderUI.onAmountEntered, getPlayer():getPlayerNum(), e)
    modal:initialise()
    modal:setOnlyNumbers(true)
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function LRZ_AdderUI:onAmountEntered(button, e)
    if button.internal ~= "OK" then return end
    local n = tonumber(button.parent.entry:getText())
    if not n then return end
    e.count = AdminTools_Tiles_Util.clamp(math.floor(n), 1, LRZ.MAX_ADD_ITEMS)
    self:refreshAddList()
end

function LRZ_AdderUI:onRemoveEntry()
    local e = self:getSelectedEntry()
    if not e then return end
    for i, entry in ipairs(self.toAdd) do
        if entry == e then
            table.remove(self.toAdd, i)
            break
        end
    end
    self:refreshAddList()
end

function LRZ_AdderUI:onClearEntries()
    self.toAdd = {}
    self:refreshAddList()
end

-------------------------------------------------------------------------------
-- Item lists (whitelists / blacklists, see LRZ_ItemLists)
-------------------------------------------------------------------------------

-- The picked list, or nil for "None".
function LRZ_AdderUI:getItemList()
    return self.listCombo:getOptionData(self.listCombo.selected)
end

function LRZ_AdderUI:refreshListCombo(index)
    self.listCombo:clear()
    self.listCombo:addOptionWithData("None (no list)", nil)
    for _, list in ipairs(self.itemLists) do
        self.listCombo:addOptionWithData(LRZ_ItemLists.describe(list), list)
    end
    self.listCombo.selected = AdminTools_Tiles_Util.clamp(index or 1, 1, #self.itemLists + 1)
end

-- Picks `list` in the dropdown (None when it's gone).
function LRZ_AdderUI:selectList(list)
    local index = 1
    for i, l in ipairs(self.itemLists) do
        if l == list then index = i + 1 end
    end
    self:refreshListCombo(index)
end

--- Call after any change to the lists: saves them and redraws.
function LRZ_AdderUI:itemListsChanged()
    LRZ_ItemLists.save(self.itemLists)
    self:selectList(self:getItemList())
    self:refreshInvList()
end

function LRZ_AdderUI:onListChanged()
    self:refreshInvList()
end

function LRZ_AdderUI:editList(list)
    LRZ_ItemListUI.open(list, function() self:itemListsChanged() end)
end

function LRZ_AdderUI:onEditList()
    local list = self:getItemList()
    if not list then
        self:setStatus("Pick a list to edit, or make a new one.", true)
        return
    end
    self:editList(list)
end

function LRZ_AdderUI:onNewList()
    local list = { name = "List " .. os.date("%H:%M:%S"), mode = LRZ.LIST_WHITELIST, items = {} }
    table.insert(self.itemLists, list)
    self:refreshListCombo(#self.itemLists + 1)
    self:itemListsChanged()
    self:editList(list)
    self:setStatus("Created '" .. list.name .. "'. Add items to it in the list window.")
end

function LRZ_AdderUI:onDeleteList()
    local list = self:getItemList()
    if not list then return end
    for i, l in ipairs(self.itemLists) do
        if l == list then
            table.remove(self.itemLists, i)
            break
        end
    end
    local editor = LRZ_ItemListUI.instance
    if editor and editor.list == list then editor:close() end
    self:refreshListCombo(1)
    self:itemListsChanged()
    self:setStatus("Deleted '" .. tostring(list.name) .. "'.")
end

-- The string popups have to show over this window, which is always on top.
local function onTop(popup)
    popup:setAlwaysOnTop(true)
    popup:bringToTop()
end

function LRZ_AdderUI:onExportList()
    local list = self:getItemList()
    if not list then
        self:setStatus("Pick a list first.", true)
        return
    end
    local str, err = LRZ_ItemLists.toString(list)
    if not str then
        self:setStatus("Could not build a string: " .. tostring(err), true)
        return
    end
    onTop(ISTileCopyStringUI.showExport(str))
end

function LRZ_AdderUI:onImportList()
    onTop(ISTileCopyStringUI.showImport(function(list)
        table.insert(self.itemLists, list)
        self:refreshListCombo(#self.itemLists + 1)
        self:itemListsChanged()
        self:setStatus("Imported '" .. tostring(list.name) .. "' (" .. #list.items .. " item(s)).")
    end, { titleText = "Paste an item list string", decode = LRZ_ItemLists.fromString }))
end

--- Puts the built-in lists back (replacing edited ones with the same name);
--- lists the admin made stay.
function LRZ_AdderUI:onRestoreLists()
    local selected = self:getItemList()
    for _, default in ipairs(LRZ_ItemLists.defaults()) do
        local replaced = false
        for i, list in ipairs(self.itemLists) do
            if list.name == default.name then
                if list == selected then selected = default end
                self.itemLists[i] = default
                replaced = true
            end
        end
        if not replaced then table.insert(self.itemLists, default) end
    end
    -- it may be editing a list that was just replaced
    local editor = LRZ_ItemListUI.instance
    if editor then editor:close() end
    self:selectList(selected)
    self:itemListsChanged()
    self:setStatus("Built-in item lists restored.")
end

-------------------------------------------------------------------------------
-- Request
-------------------------------------------------------------------------------

-- Area args from the owner, or nil after showing why not.
function LRZ_AdderUI:getAreaArgs()
    if not self.owner then
        self:setStatus("No area source - reopen from the Loot Remover.", true)
        return nil
    end
    local args, err = self.owner:getLootArgs()
    if not args then
        self:setStatus(err or "No area selected.", true)
        return nil
    end
    local tooBig = LRZ.TooBigMessage(args)
    if tooBig then
        self:setStatus(tooBig, true)
        return nil
    end
    return args
end

function LRZ_AdderUI:refreshArea()
    local args = self.owner and self.owner:getLootArgs()
    if args then
        self.areaLabel:setName("Area: " .. LRZ.DescribeArea(args))
    else
        self.areaLabel:setName("Area: none selected")
    end
end

function LRZ_AdderUI:onAddLoot()
    local args = self:getAreaArgs()
    if not args then return end

    args.source = self:getSource()
    args.replace = self.replaceTick:isSelected(1)
    local list = self:getItemList()
    if list then args.itemList = LRZ_ItemLists.toRequest(list) end

    if args.source == LRZ.SOURCE_RANDOM then
        self:confirmRandom(args)
        return
    end

    -- Categories scope the reroll and what "Replace" empties
    local reroll = args.source == LRZ.SOURCE_REROLL
    args.categories = self.categories:getRequestCategories()
    if not args.categories and (reroll or args.replace) then
        self:setStatus("Tick at least one category.", true)
        return
    end
    local filtered = args.categories and args.categories[1] ~= LRZ.ALL_KEY
    local cats = self.categories:describe()

    local what
    if reroll then
        what = "Reroll vanilla loot"
        if filtered then
            what = what .. " (keeping only " .. cats .. ")"
        end
    else
        if #self.toAdd == 0 then
            self:setStatus("Pick at least one item to add.", true)
            return
        end
        args.items = {}
        local total = 0
        for _, e in ipairs(self.toAdd) do
            table.insert(args.items, { type = e.type, count = e.count })
            total = total + e.count
        end
        args.perContainer = self.spreadCombo:getOptionData(self.spreadCombo.selected) == true
        if args.perContainer then
            what = string.format("Add %d item(s) of %d type(s) to EVERY container", total, #args.items)
        else
            what = string.format("Add %d item(s) of %d type(s), spread over random containers,", total, #args.items)
        end
    end

    local text = what .. " in " .. LRZ.DescribeArea(args)
    if args.replace and filtered then
        text = text .. ", first EMPTYING " .. cats .. " out of them?"
    elseif args.replace then
        text = text .. ", REPLACING what's in them?"
    else
        text = text .. "?"
    end
    self:confirmAdd(text, args)
end

-- "Random by container type": every scanned type with ticked categories.
function LRZ_AdderUI:confirmRandom(args)
    if #self.containerTypes == 0 then
        self:setStatus("Scan the container types first.", true)
        return
    end
    args.containerTypes = {}
    local total = 0
    for _, t in ipairs(self.containerTypes) do
        local cfg = self:getTypeConfig(t.type)
        local cats = checkedToCategories(cfg.checked)
        if cats then
            table.insert(args.containerTypes, { type = t.type, categories = cats, amount = cfg.amount })
            total = total + cfg.amount * t.count
        end
    end
    if #args.containerTypes == 0 then
        self:setStatus("Tick categories for at least one container type.", true)
        return
    end

    local text = string.format("Add about %d random item(s) to %d container type(s) in %s",
        total, #args.containerTypes, LRZ.DescribeArea(args))
    if args.replace then
        text = text .. ", first EMPTYING each type's ticked categories out of them?"
    else
        text = text .. "?"
    end
    self:confirmAdd(text, args)
end

function LRZ_AdderUI:confirmAdd(text, args)
    local list = args.itemList and self:getItemList()
    if list then
        text = "[" .. tostring(list.name) .. " " .. tostring(list.mode) .. "] " .. text
    end
    local mx, my = AdminTools_Tiles_UIUtil.centeredOn(self, 380, 150)
    local modal = ISModalDialog:new(mx, my, 380, 150, text, true, self, LRZ_AdderUI.onConfirmAdd, nil, args)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function LRZ_AdderUI:onConfirmAdd(button, args)
    if button.internal ~= "YES" then return end
    self:setStatus("Adding...")
    sendClientCommand(getPlayer(), LRZ.ModuleName, LRZ.CMD_ADD_LOOT, args)
end

-- Server reply (LRZ.RES_ADDED).
function LRZ_AdderUI:onAdded(args)
    if args.error then
        self:setStatus(args.error, true)
    elseif args.containers == 0 then
        self:setStatus("No containers found - is the area loaded (near a player)?", true)
    else
        local msg = "Added " .. tostring(args.added) .. " item(s) to " .. tostring(args.containers) .. " container(s)"
        if args.cleared and args.cleared > 0 then
            msg = msg .. ", " .. tostring(args.cleared) .. " removed first"
        end
        if args.skipped and args.skipped > 0 then
            msg = msg .. ", " .. tostring(args.skipped) .. " type(s) skipped (item list / blacklist)"
        end
        self:setStatus(msg .. ".")
    end
end

-------------------------------------------------------------------------------
-- Misc
-------------------------------------------------------------------------------

function LRZ_AdderUI:setStatus(text, isError)
    AdminTools_Tiles_UIUtil.setStatus(self.statusLabel, text, isError)
end

function LRZ_AdderUI:close()
    self:setVisible(false)
end

--- Opens the window for `owner` (see the top of this file).
function LRZ_AdderUI.open(owner)
    if not LRZ_AdderUI.instance then
        local ui = LRZ_AdderUI:new()
        ui:initialise()
        ui:addToUIManager()
        LRZ_AdderUI.instance = ui
    else
        LRZ_AdderUI.instance:refreshInventory()
        LRZ_AdderUI.instance:setVisible(true)
    end
    local ui = LRZ_AdderUI.instance
    ui.owner = owner
    ui:refreshArea()
    ui:setStatus("")
    -- Also has to show over the full-screen Zone Editor
    ui:setAlwaysOnTop(true)
    ui:bringToTop()
    return ui
end
