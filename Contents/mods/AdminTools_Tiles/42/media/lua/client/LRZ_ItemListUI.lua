--[[
    LRZ_ItemListUI.lua  (client)

    Edits one Loot Filler item list (see LRZ_ItemLists), opened from the
    Loot Filler window:
      - name, and whether it's a whitelist or a blacklist
      - left: search every item in the game by name or type, double-click to
        add; "Add Typed" adds the search text as it is, for a bare name, a
        whole module ("SWMG.*") or an item of a mod that isn't loaded
      - right: what's in the list, double-click to remove
    Every change calls onChanged(), which saves the lists.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISLabel"
require "LRZ_Shared"
require "AdminTools_Tiles_UIUtil"

LRZ_ItemListUI = ISCollapsableWindow:derive("LRZ_ItemListUI")
LRZ_ItemListUI.instance = nil

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local WIDTH = 760
local COL_W = (WIDTH - PADDING * 3) / 2
local RIGHT_X = PADDING * 2 + COL_W
local LIST_H = 300
-- Most search results shown at once
local MAX_RESULTS = 200

local COLOR_UNKNOWN = { r = 0.55, g = 0.55, b = 0.55, a = 1 }
local COLOR_PATTERN = { r = 0.7, g = 0.85, b = 1.0, a = 1 }

local MODES = {
    { label = "Whitelist: only these items are added", mode = LRZ.LIST_WHITELIST },
    { label = "Blacklist: these items are never added", mode = LRZ.LIST_BLACKLIST },
}

-- { { type, name, search }, ... } for every item in the game, built on first use
local allItems = nil
local function getAllItems()
    if allItems then return allItems end
    allItems = {}
    local scripts = getScriptManager():getAllItems()
    for i = 0, scripts:size() - 1 do
        local script = scripts:get(i)
        if not script:getObsolete() then
            local fullType = script:getFullName()
            local name = script:getDisplayName() or fullType
            allItems[#allItems + 1] = { type = fullType, name = name, search = string.lower(name .. " " .. fullType) }
        end
    end
    table.sort(allItems, function(a, b) return a.name < b.name end)
    return allItems
end

function LRZ_ItemListUI:new()
    local x = (getCore():getScreenWidth() / 2) - (WIDTH / 2)
    local y = (getCore():getScreenHeight() / 2) - 250
    local o = ISCollapsableWindow:new(x, y, WIDTH, 500)
    setmetatable(o, self)
    self.__index = self
    o.title = "Item List"
    o:setResizable(false)
    o.list = nil       -- the list being edited
    o.onChanged = nil  -- called after every change
    return o
end

local function addButton(self, x, y, w, text, fn)
    local btn = ISButton:new(x, y, w, BTN_H, text, self, fn)
    btn:initialise()
    self:addChild(btn)
    return btn
end

local function addList(self, x, y, w, h)
    local list = ISScrollingListBox:new(x, y, w, h)
    list:initialise()
    list:instantiate()
    list:setFont(UIFont.Small, 2)
    list.drawBorder = true
    self:addChild(list)
    return list
end

function LRZ_ItemListUI:createChildren()
    ISCollapsableWindow.createChildren(self)
    local tm = getTextManager()
    local y = self:titleBarHeight() + PADDING

    -- Row: name + mode
    local nameLabel = ISLabel:new(PADDING, y, BTN_H, "Name:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(nameLabel)
    local nx = PADDING + tm:MeasureStringX(UIFont.Small, "Name:") + 8
    self.nameEntry = ISTextEntryBox:new("", nx, y, 220, BTN_H)
    self.nameEntry:initialise()
    self.nameEntry:instantiate()
    self.nameEntry.target = self
    self.nameEntry.onTextChangeFunction = LRZ_ItemListUI.onNameChanged
    self:addChild(self.nameEntry)

    local mx = nx + 230
    self.modeCombo = ISComboBox:new(mx, y, WIDTH - mx - PADDING, BTN_H, self, LRZ_ItemListUI.onModeChanged)
    self.modeCombo:initialise()
    for _, opt in ipairs(MODES) do
        self.modeCombo:addOptionWithData(opt.label, opt.mode)
    end
    self:addChild(self.modeCombo)
    y = y + BTN_H + 10

    -- Left: every item. Right: the list.
    local searchLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "Every item (search, double-click to add):", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(searchLabel)
    self.countLabel = ISLabel:new(RIGHT_X, y, FONT_HGT_SMALL, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.countLabel)
    y = y + FONT_HGT_SMALL + 4

    self.searchEntry = ISTextEntryBox:new("", PADDING, y, COL_W, BTN_H)
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = LRZ_ItemListUI.refreshResults
    self:addChild(self.searchEntry)

    self.resultList = addList(self, PADDING, y + BTN_H + 4, COL_W, LIST_H - BTN_H - 4)
    self.resultList:setOnMouseDoubleClick(self, LRZ_ItemListUI.onAddResult)

    self.entryList = addList(self, RIGHT_X, y, COL_W, LIST_H)
    self.entryList:setOnMouseDoubleClick(self, LRZ_ItemListUI.onRemoveEntry)
    y = y + LIST_H + 6

    local half = (COL_W - 5) / 2
    addButton(self, PADDING, y, half, "Add Selected", LRZ_ItemListUI.onAddSelected)
    self.addTypedBtn = addButton(self, PADDING + half + 5, y, half, "Add Typed", LRZ_ItemListUI.onAddTyped)
    self.addTypedBtn:setTooltip("Adds the search text as it is: Base.Axe, a bare name (Axe = any module), or Module.* for a whole mod.")
    addButton(self, RIGHT_X, y, half, "Remove", LRZ_ItemListUI.onRemoveSelected)
    addButton(self, RIGHT_X + half + 5, y, half, "Clear", LRZ_ItemListUI.onClear)
    y = y + BTN_H + 8

    local note = ISLabel:new(PADDING, y, FONT_HGT_SMALL,
        "Grey: not an item in this game (yet). Blue: a pattern (bare name or Module.*). The sandbox blacklist always applies too.",
        0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(note)
    y = y + FONT_HGT_SMALL + 8

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)
    addButton(self, WIDTH - PADDING - 100, y, 100, "Close", LRZ_ItemListUI.close)
    y = y + BTN_H + PADDING

    self:setHeight(y)
end

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------

function LRZ_ItemListUI:changed()
    if self.onChanged then self.onChanged() end
end

function LRZ_ItemListUI:onNameChanged()
    local name = self.nameEntry:getText()
    if not self.list or not name or name == "" then return end
    self.list.name = name
    self.title = "Item List: " .. name
    self:changed()
end

function LRZ_ItemListUI:onModeChanged()
    if not self.list then return end
    self.list.mode = self.modeCombo:getOptionData(self.modeCombo.selected)
    self:changed()
end

--- Row text and colour for a list entry.
local function describeEntry(entry)
    if string.match(entry, "%.%*$") then
        return entry .. "  (whole module)", COLOR_PATTERN
    end
    if not string.find(entry, ".", 1, true) then
        return entry .. "  (any module)", COLOR_PATTERN
    end
    local script = ScriptManager.instance:getItem(entry)
    if not script then
        return entry .. "  (not in this game)", COLOR_UNKNOWN
    end
    return (script:getDisplayName() or entry) .. "  (" .. entry .. ")", nil
end

function LRZ_ItemListUI:refreshEntries()
    local selected = self.entryList.selected
    self.entryList:clear()
    if not self.list then return end
    for _, entry in ipairs(self.list.items) do
        local text, color = describeEntry(entry)
        local row = self.entryList:addItem(text, entry)
        row.textColor = color
    end
    self.entryList.selected = math.min(selected, #self.entryList.items)
    self.countLabel:setName("In the list (" .. #self.list.items .. ", double-click to remove):")
end

function LRZ_ItemListUI:hasEntry(entry)
    local lower = string.lower(entry)
    for _, e in ipairs(self.list.items) do
        if string.lower(e) == lower then return true end
    end
    return false
end

function LRZ_ItemListUI:addEntry(entry)
    if not self.list or not entry or entry == "" then return end
    if self:hasEntry(entry) then
        self:setStatus(entry .. " is already in the list.", true)
        return
    end
    table.insert(self.list.items, entry)
    self:refreshEntries()
    self.entryList.selected = #self.entryList.items
    self.entryList:ensureVisible(self.entryList.selected)
    self:setStatus("Added " .. entry .. ".")
    self:changed()
end

function LRZ_ItemListUI:onRemoveEntry(entry)
    if not self.list then return end
    for i, e in ipairs(self.list.items) do
        if e == entry then
            table.remove(self.list.items, i)
            break
        end
    end
    self:refreshEntries()
    self:setStatus("Removed " .. tostring(entry) .. ".")
    self:changed()
end

function LRZ_ItemListUI:onRemoveSelected()
    local row = self.entryList.items[self.entryList.selected]
    if row then self:onRemoveEntry(row.item) end
end

function LRZ_ItemListUI:onClear()
    if not self.list then return end
    self.list.items = {}
    self:refreshEntries()
    self:setStatus("List emptied.")
    self:changed()
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------

function LRZ_ItemListUI:refreshResults()
    self.resultList:clear()
    local words = {}
    for word in string.gmatch(string.lower(self.searchEntry:getText() or ""), "%S+") do
        words[#words + 1] = word
    end
    if #words == 0 then return end

    local shown = 0
    for _, item in ipairs(getAllItems()) do
        local match = true
        for _, word in ipairs(words) do
            if not string.find(item.search, word, 1, true) then
                match = false
                break
            end
        end
        if match then
            self.resultList:addItem(item.name .. "  (" .. item.type .. ")", item)
            shown = shown + 1
            if shown >= MAX_RESULTS then break end
        end
    end
end

function LRZ_ItemListUI:onAddResult(item)
    self:addEntry(item.type)
end

function LRZ_ItemListUI:onAddSelected()
    local row = self.resultList.items[self.resultList.selected]
    if row then self:addEntry(row.item.type) end
end

function LRZ_ItemListUI:onAddTyped()
    local text = self.searchEntry:getText()
    text = text and string.match(text, "^%s*(.-)%s*$")
    if not text or text == "" or string.find(text, "%s") then
        self:setStatus("Type one entry: Base.Axe, Axe or Module.*", true)
        return
    end
    self:addEntry(text)
end

-------------------------------------------------------------------------------
-- Misc
-------------------------------------------------------------------------------

function LRZ_ItemListUI:setList(list, onChanged)
    self.list = list
    self.onChanged = onChanged
    self.nameEntry:setText(list.name or "")
    self.modeCombo.selected = list.mode == LRZ.LIST_WHITELIST and 1 or 2
    self.title = "Item List: " .. tostring(list.name)
    self:refreshEntries()
    self:setStatus("")
end

function LRZ_ItemListUI:setStatus(text, isError)
    AdminTools_Tiles_UIUtil.setStatus(self.statusLabel, text, isError)
end

function LRZ_ItemListUI:close()
    self:setVisible(false)
end

--- Opens the editor on `list`; onChanged() is called after every change.
function LRZ_ItemListUI.open(list, onChanged)
    if not LRZ_ItemListUI.instance then
        local ui = LRZ_ItemListUI:new()
        ui:initialise()
        ui:addToUIManager()
        LRZ_ItemListUI.instance = ui
    end
    local ui = LRZ_ItemListUI.instance
    ui:setList(list, onChanged)
    ui:setVisible(true)
    -- Shows over the Loot Filler, which is always on top too
    ui:setAlwaysOnTop(true)
    ui:bringToTop()
    return ui
end
