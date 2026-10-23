--[[
    ISTileBuilderCursor.lua

    The Tile Builder's cursor, used like the wall tool of The Sims: press on
    a square, drag, release, and the picked tile is built on every square of
    the line (the longer side of the drag). Holding Shift fills the whole
    dragged rectangle instead, for floors. A plain click builds one tile.
    Right-click stops.

    A wall dragged the "wrong" way is swapped for its other version (north
    walls along x, west walls along y, see TileCopy.Admin.lineSprite); R
    turns that off and on.

    The building goes through TileCopy.Admin.buildArea, so "Undo Last" takes
    a whole drag back.

    Lives in server/ like the vanilla cursors: client files load before
    ISBuildingObject exists. The label next to the mouse is in
    client/ISTileBrushUI.lua.
]]

require "BuildingObjects/ISBuildingObject"

ISTileBuilderCursor = ISBuildingObject:derive("ISTileBuilderCursor")

function ISTileBuilderCursor.start(playerObj, spriteName)
    getCell():setDrag(ISTileBuilderCursor:new(spriteName, playerObj), playerObj:getPlayerNum())
end

function ISTileBuilderCursor:isValid(square)
    return true
end

--- Called every frame the button is held, with the square the mouse is on:
--- the vanilla cursors turn their object towards it, this one drags to it.
function ISTileBuilderCursor:rotateMouse(x, y)
    self.dragX, self.dragY = x, y
    self.fill = isShiftKeyDown()
end

--- The two ends of what a drag started on x, y covers.
function ISTileBuilderCursor:getArea(x, y)
    local endX, endY = self.dragX or x, self.dragY or y
    if not self.fill then
        -- a straight line, along the longer side of the drag
        if math.abs(endX - x) >= math.abs(endY - y) then
            endY = y
        else
            endX = x
        end
    end
    return x, y, endX, endY
end

--- The tile built on that area: the picked one, turned to follow a line.
function ISTileBuilderCursor:getAreaSprite(x1, y1, x2, y2)
    -- one square and a rectangle have no direction
    if not self.autoFace or (x1 ~= x2) == (y1 ~= y2) then return self.spriteName end
    return TileCopy.Admin.lineSprite(self.spriteName, x1 ~= x2)
end

function ISTileBuilderCursor:create(x, y, z, north, sprite)
    local x1, y1, x2, y2 = self:getArea(x, y)
    self.dragX, self.dragY = nil, nil
    -- in multiplayer the server builds it
    TileCopy.ClientCommands.requestBuild({
        sprite = self:getAreaSprite(x1, y1, x2, y2),
        x1 = x1, y1 = y1, x2 = x2, y2 = y2, z1 = z,
    })
end

function ISTileBuilderCursor:render(x, y, z, square)
    -- x, y stay on the square the drag started on while the button is held
    if not self.isLeftDown and not self.build then
        self.dragX, self.dragY = nil, nil
    end
    local x1, y1, x2, y2 = self:getArea(x, y)
    local spriteName = self:getAreaSprite(x1, y1, x2, y2)

    if not self.RENDER_SPRITE then
        self.RENDER_SPRITE = IsoSprite.new()
    end
    if self.RENDER_SPRITE_NAME ~= spriteName then
        self.RENDER_SPRITE:LoadSingleTexture(spriteName)
        self.RENDER_SPRITE_NAME = spriteName
    end
    for gy = math.min(y1, y2), math.max(y1, y2) do
        for gx = math.min(x1, x2), math.max(x1, x2) do
            self.RENDER_SPRITE:RenderGhostTile(gx, gy, z)
        end
    end

    -- for the label
    self.shownSprite = spriteName
    self.shownW = math.abs(x2 - x1) + 1
    self.shownH = math.abs(y2 - y1) + 1

    if not self.label and ISTileBuilderLabel then
        self.label = ISTileBuilderLabel:new(self)
        self.label:initialise()
        self.label:addToUIManager()
        self.label:setAlwaysOnTop(true)
    end
end

function ISTileBuilderCursor:rotateKey(key)
    if getCore():isKey(KeybindId.ROTATE_BUILDING, key) then
        self.autoFace = not self.autoFace
        getSoundManager():playUISound("UIObjectMenuObjectRotateOutline")
    end
end

-- Keep clicks from opening containers / doors under the cursor.
function ISTileBuilderCursor:onObjectLeftMouseButtonDown(object, x, y)
    return true
end

function ISTileBuilderCursor:deactivate()
    if self.label then
        self.label:removeFromUIManager()
        self.label = nil
    end
end

function ISTileBuilderCursor:new(spriteName, character)
    local o = ISBuildingObject.new(self)
    o:init()
    o:setSprite(spriteName)
    o:setNorthSprite(spriteName)
    o.spriteName = spriteName
    o.character = character
    o.player = character:getPlayerNum()
    o.noNeedHammer = true
    o.skipBuildAction = true
    o.skipWalk2 = true
    o.autoFace = true
    return o
end
