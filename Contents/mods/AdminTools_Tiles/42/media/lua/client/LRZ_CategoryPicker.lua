-- LRZ_CategoryPicker.lua
-- "ALL categories" tick + the category ticks laid out in columns.
-- Used by the Loot Remover / Loot Filler windows and the Zone Editor's Loot
-- Removal mode.

require "ISUI/ISTickBox"
require "LRZ_Shared"

LRZ_CategoryPicker = {}
LRZ_CategoryPicker.__index = LRZ_CategoryPicker

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

-- onChanged() is called after any category tick changes,
-- onGroundChanged() after the ground tick changes. noGround leaves the
-- ground tick out (the Loot Filler only fills containers).
function LRZ_CategoryPicker.create(parent, x, y, colW, cols, onChanged, onGroundChanged, noGround)
    local o = setmetatable({}, LRZ_CategoryPicker)
    o.onChanged = onChanged
    o.onGroundChanged = onGroundChanged
    o.ticks = {}
    o.index = {}

    o.allTick = ISTickBox:new(x, y, colW * cols, FONT_HGT_SMALL, "", o, LRZ_CategoryPicker.onAllToggle)
    o.allTick:initialise()
    o.allTick:addOption("ALL categories")
    o.allTick:setSelected(1, true)
    parent:addChild(o.allTick)
    y = y + o.allTick:getHeight() + 4

    local cats = LRZ.Categories
    local rows = math.ceil(#cats / cols)
    o.bottom = y
    for col = 1, cols do
        local tick = ISTickBox:new(x + (col - 1) * colW, y, colW, FONT_HGT_SMALL, "", o, LRZ_CategoryPicker.onCategoryToggle)
        tick:initialise()
        for row = 1, rows do
            local cat = cats[(col - 1) * rows + row]
            if cat then
                tick:addOption(cat)
                o.index[cat] = { tick = tick, index = row }
            end
        end
        parent:addChild(tick)
        table.insert(o.ticks, tick)
        o.bottom = math.max(o.bottom, y + tick:getHeight())
    end

    if not noGround then
        o.groundTick = ISTickBox:new(x, o.bottom + 8, colW * cols, FONT_HGT_SMALL, "", o, LRZ_CategoryPicker.onGroundToggle)
        o.groundTick:initialise()
        o.groundTick:addOption("Include items on the ground")
        parent:addChild(o.groundTick)
        o.bottom = o.groundTick:getY() + o.groundTick:getHeight()
    end

    return o
end

function LRZ_CategoryPicker:onGroundToggle()
    if self.onGroundChanged then self.onGroundChanged() end
end

function LRZ_CategoryPicker:includeGround()
    return self.groundTick ~= nil and self.groundTick:isSelected(1)
end

function LRZ_CategoryPicker:onAllToggle()
    if self.allTick:isSelected(1) then
        for _, tick in ipairs(self.ticks) do
            for i = 1, #tick.options do
                tick:setSelected(i, false)
            end
        end
    end
    if self.onChanged then self.onChanged() end
end

function LRZ_CategoryPicker:onCategoryToggle()
    local any = false
    for _, ref in pairs(self.index) do
        if ref.tick:isSelected(ref.index) then
            any = true
        end
    end
    self.allTick:setSelected(1, not any)
    if self.onChanged then self.onChanged() end
end

-- Returns a set of checked category keys, or nil when ALL is on.
function LRZ_CategoryPicker:getChecked()
    if self.allTick:isSelected(1) then return nil end
    local set = {}
    for cat, ref in pairs(self.index) do
        if ref.tick:isSelected(ref.index) then
            set[cat] = true
        end
    end
    return set
end

-- Shows `checked` (as returned by getChecked: nil = ALL). Doesn't call onChanged.
function LRZ_CategoryPicker:setChecked(checked)
    self.allTick:setSelected(1, checked == nil)
    for cat, ref in pairs(self.index) do
        ref.tick:setSelected(ref.index, checked ~= nil and checked[cat] == true)
    end
end

-- Category list for a removeLoot request, or nil when nothing is ticked.
function LRZ_CategoryPicker:getRequestCategories()
    local checked = self:getChecked()
    if not checked then return { LRZ.ALL_KEY } end
    local list = {}
    for cat in pairs(checked) do
        table.insert(list, cat)
    end
    if #list == 0 then return nil end
    return list
end

-- Short human-readable summary for confirmations.
function LRZ_CategoryPicker:describe()
    local list = self:getRequestCategories()
    if not list then return "nothing" end
    local text
    if list[1] == LRZ.ALL_KEY then
        text = "ALL categories"
    else
        table.sort(list)
        text = table.concat(list, ", ")
    end
    if self:includeGround() then
        text = text .. " (incl. items on the ground)"
    end
    return text
end
