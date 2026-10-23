--[[
    AdminTools_Tiles_UIUtil.lua  (client)

    UI pieces shared by the Loot Remover window, the Zone Editor mode and
    the Loot Adder window.
]]

require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "AdminTools_Tiles_Util"

AdminTools_Tiles_UIUtil = AdminTools_Tiles_UIUtil or {}
local UIUtil = AdminTools_Tiles_UIUtil

--- Green status text, or red when isError.
function UIUtil.setStatus(label, text, isError)
    if isError then
        label:setColor(1, 0.5, 0.5)
    else
        label:setColor(0.6, 1, 0.6)
    end
    label:setName(text)
end

--- x, y that centre a w*h popup over `panel`, kept fully on screen.
function UIUtil.centeredOn(panel, w, h)
    local x = panel:getX() + (panel:getWidth() - w) / 2
    local y = panel:getY() + (panel:getHeight() - h) / 2
    x = AdminTools_Tiles_Util.clamp(x, 0, math.max(0, getCore():getScreenWidth() - w))
    y = AdminTools_Tiles_Util.clamp(y, 0, math.max(0, getCore():getScreenHeight() - h))
    return x, y
end

--------------------------------------------------------------------------
-- "Floors: [from] to [to]" row
--------------------------------------------------------------------------

local FloorRow = {}
FloorRow.__index = FloorRow

--- Adds the row to `parent` at x,y. `row.right` is the x just past it.
function UIUtil.createFloorRow(parent, x, y, h)
    local row = setmetatable({}, FloorRow)
    local z = AdminTools_Tiles_Util.playerFloor()

    local label = ISLabel:new(x, y, h, "Floors:", 1, 1, 1, 1, UIFont.Small, true)
    parent:addChild(label)
    local fx = x + getTextManager():MeasureStringX(UIFont.Small, "Floors:") + 8

    row.fromEntry = ISTextEntryBox:new(tostring(z), fx, y, 40, h)
    row.fromEntry:initialise()
    row.fromEntry:instantiate()
    parent:addChild(row.fromEntry)

    local toLabel = ISLabel:new(fx + 46, y, h, "to", 1, 1, 1, 1, UIFont.Small, true)
    parent:addChild(toLabel)

    row.toEntry = ISTextEntryBox:new(tostring(z), fx + 66, y, 40, h)
    row.toEntry:initialise()
    row.toEntry:instantiate()
    parent:addChild(row.toEntry)

    row.right = fx + 106
    return row
end

--- Sorted, clamped z1, z2.
function FloorRow:getRange()
    return AdminTools_Tiles_Util.parseFloorRange(self.fromEntry:getText(), self.toEntry:getText())
end

function FloorRow:setFloor(z)
    self:setRange(z, z)
end

function FloorRow:setRange(z1, z2)
    self.fromEntry:setText(tostring(z1))
    self.toEntry:setText(tostring(z2))
end
