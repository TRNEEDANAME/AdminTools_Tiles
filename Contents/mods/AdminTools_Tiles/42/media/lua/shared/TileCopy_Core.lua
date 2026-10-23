--[[
    TileCopy_Core.lua  (shared)

    The actual "copy" and "paste" logic, kept separate from any UI so it can
    be called from the client (single player / previewing) and from the
    server
--]]

require "TileCopy_Util"
require "Moveables/ISMoveableSpriteProps"

TileCopy = TileCopy or {}
TileCopy.Core = TileCopy.Core or {}
local Core = TileCopy.Core
local Util = TileCopy.Util

local function propsHasFlag(props, flag)
    local key = (IsoFlagType and IsoFlagType[flag]) or flag
    if props.has and props:has(key) then return true end
    if props.Is and props:Is(key) then return true end
    return false
end

local function hasPropertyFlag(obj, flags)
    if not obj or not obj.getProperties then return false end
    local props = obj:getProperties()
    if not props then return false end

    for _, flag in ipairs(flags) do
        if propsHasFlag(props, flag) then return true end
    end
    return false
end
local WALL_FLAGS = {
    "WallN", "WallW", "WallNW", "WallSE", "WallNTrans", "WallWTrans",
    "doorN", "doorW", "DoorWallN", "DoorWallW",
    "windowN", "windowW", "WindowN", "WindowW",
}
local STRUCTURAL_FLAGS = { "solid", "solidtrans", "collideN", "collideW", "HoppableN", "HoppableW" }

-- Subclasses of IsoObject (stoves, light switches, curtains, washers...)
local function isSpecialObject(obj)
    local name = obj.getObjectName and obj:getObjectName()
    return name ~= nil and name ~= "" and name ~= "IsoObject"
end

local function isMoveable(obj)
    return hasPropertyFlag(obj, { "IsMoveAble" })
end

local function isStairs(obj)
    return obj.isStairsObject and obj:isStairsObject()
end

local function isInstance(obj, className)
    if not instanceof then return false end
    return instanceof(obj, className)
end

local WALL_TYPES = { "wall", "doorFrN", "doorFrW" }

local function hasWallType(obj)
    if not IsoObjectType then return false end
    local objType = obj.getType and obj:getType()
    local spriteType = nil
    local sprite = obj.getSprite and obj:getSprite()
    if sprite and sprite.getType then spriteType = sprite:getType() end
    for _, name in ipairs(WALL_TYPES) do
        local t = IsoObjectType[name]
        if t and (objType == t or spriteType == t) then return true end
    end
    return false
end

local function isWallObject(obj)
    if isInstance(obj, "IsoDoor") or isInstance(obj, "IsoWindow") or isInstance(obj, "IsoWindowFrame") then
        return true
    end
    return hasPropertyFlag(obj, WALL_FLAGS) or hasWallType(obj)
end

local function hasContainer(obj)
    if not (obj and obj.getContainer) then return false end
    return obj:getContainer() ~= nil
end

local function isWallHanging(obj)
    local props = obj.getProperties and obj:getProperties()
    if not (props and props.get) then return false end
    return props:get("MoveType") == "WallObject"
end

local function isStructuralObject(obj)
    return hasContainer(obj)
        or isWallHanging(obj)
        or hasPropertyFlag(obj, STRUCTURAL_FLAGS)
        or isMoveable(obj)
        or isStairs(obj)
        or isInstance(obj, "IsoThumpable")
        or isSpecialObject(obj)
end

function Core.classifyObject(obj)
    if isInstance(obj, "IsoWorldInventoryObject") or isInstance(obj, "IsoMovingObject") then
        return "skip"
    end
    if isWallObject(obj) then return "wall" end
    if isStructuralObject(obj) then return "structural" end
    return "overlay"
end

local function getSpriteNameSafe(obj)
    if obj and obj.getSpriteName then
        local name = obj:getSpriteName()
        if name then return name end
    end
    if obj and obj.getSprite then
        local sprite = obj:getSprite()
        if sprite and sprite.getName then
            return sprite:getName()
        end
    end
    return nil
end

--- Captures the contents of every container on an object (a fridge has a
--- fridge + freezer, for example). Returns a list, or nil if there are none.
function Core.captureContainers(obj)
    local list = {}
    for _, container in ipairs(AdminTools_Tiles_Util.getObjectContainers(obj)) do
        list[#list + 1] = Core.captureContainer(obj, container)
    end
    return #list > 0 and list or nil
end

--- Captures the contents (items) of one container (defaults to the
--- object's main container).
function Core.captureContainer(obj, container)
    if not container then
        if not obj.getContainer then return nil end
        container = obj:getContainer()
        if not container then return nil end
    end

    local items = {}
    local itemList = container:getItems()
    if itemList then
        for i = 0, itemList:size() - 1 do
            local item = itemList:get(i)
            local entry = {}
            entry.fullType = item:getFullType()

            if item.getCount then entry.count = item:getCount() end
            if item.getCondition then entry.condition = item:getCondition() end
            if item.getCurrentUsesFloat then entry.uses = item:getCurrentUsesFloat() end

            if entry.fullType then
                items[#items + 1] = entry
            end
        end
    end

    local containerType = container:getType()
    local capacity = container:getCapacity()

    return {
        containerType = containerType,
        capacity = capacity,
        items = items,
    }
end

local function captureAttached(obj, includeMoveable, includeDecals)
    local list = obj.getAttachedAnimSprite and obj:getAttachedAnimSprite()
    if not list then return nil end
    local out = {}
    for i = 0, list:size() - 1 do
        local inst = list:get(i)
        local spr = inst and inst.getParentSprite and inst:getParentSprite()
        local name = spr and spr:getName()
        if name then
            local props = spr:getProperties()
            local moveable = props and propsHasFlag(props, "IsMoveAble")
            if (moveable and includeMoveable) or (not moveable and includeDecals) then
                out[#out + 1] = name
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

--- Captures a rectangular region into a data table.
-- @param x1,y1,x2,y2 any two opposite corners (order doesn't matter)
-- @param z            floor/z-level to copy
-- @param opts         { includeTiles=bool, includeContainers=bool, includeOverlay=bool }
function Core.captureArea(x1, y1, x2, y2, z, opts)
    opts = opts or {}
    local includeTiles = opts.includeTiles ~= false
    local includeWalls = opts.includeWalls ~= false
    local includeGround = opts.includeGround ~= false
    local includeContainers = opts.includeContainers ~= false
    local includeOverlay = opts.includeOverlay ~= false

    local minX, maxX = math.min(x1, x2), math.max(x1, x2)
    local minY, maxY = math.min(y1, y2), math.max(y1, y2)

    local cell = getCell()
    local data = {
        width = maxX - minX + 1,
        height = maxY - minY + 1,
        includeTiles = includeTiles,
        includeWalls = includeWalls,
        includeGround = includeGround,
        includeContainers = includeContainers,
        includeOverlay = includeOverlay,
        squares = {},
    }

    for y = minY, maxY do
        for x = minX, maxX do
            local sq = cell and cell:getGridSquare(x, y, z)
            local entry = { dx = x - minX, dy = y - minY }

            if sq then
                if includeGround then
                    local floorObj = sq:getFloor()
                    if floorObj then
                        entry.floor = getSpriteNameSafe(floorObj)
                        -- floor-layer overlays (grime, blends, mod decals)
                        -- are often attached to the floor object itself
                        entry.floorAttached = captureAttached(floorObj, includeTiles, includeOverlay)
                    end
                end

                local structObjects, overlayObjects = {}, {}
                local objs = sq:getObjects()
                if objs then
                    local floorRef = sq:getFloor()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj ~= floorRef then
                            local spriteName = getSpriteNameSafe(obj)
                            -- An open door's current sprite is the "open"
                            -- frame, which doesn't carry the door flags, so
                            -- it wouldn't be rebuilt as a door. Save the
                            -- closed sprite instead.
                            if obj.IsOpen and obj.getClosedSprite and obj:IsOpen() then
                                local closed = obj:getClosedSprite()
                                if closed and closed:getName() then spriteName = closed:getName() end
                            end
                            if spriteName then
                                local class = Core.classifyObject(obj)
                                Util.log("sq", x, y, "obj", spriteName, "class=", class)

                                if class == "skip" then
                                    -- dropped items etc. - not part of the build
                                elseif class == "wall" then
                                    if includeWalls then
                                        structObjects[#structObjects + 1] = {
                                            sprite = spriteName, layer = "wall",
                                            attached = captureAttached(obj, includeTiles, includeOverlay),
                                        }
                                    end
                                elseif class == "structural" then
                                    if includeTiles then
                                        local rec = {
                                            sprite = spriteName, layer = "structural",
                                            attached = captureAttached(obj, includeTiles, includeOverlay),
                                        }
                                        if includeContainers then
                                            rec.containers = Core.captureContainers(obj)
                                        end
                                        structObjects[#structObjects + 1] = rec
                                    end
                                else -- overlay
                                    if includeOverlay then
                                        overlayObjects[#overlayObjects + 1] = {
                                            sprite = spriteName,
                                            attached = captureAttached(obj, includeTiles, includeOverlay),
                                        }
                                    end
                                end
                            end
                        end
                    end
                end

                if includeTiles or includeWalls then entry.objects = structObjects end
                if includeOverlay then entry.overlay = overlayObjects end
            end

            data.squares[#data.squares + 1] = entry
        end
    end

    Util.info("copy: captured", data.width, "x", data.height, "at", minX, minY, z,
        "- tiles/walls/ground/containers/overlay =",
        includeTiles, includeWalls, includeGround, includeContainers, includeOverlay)
    return data
end

--- Captures the same rectangle on floors z1 to z2 as one clipboard: a
--- house. Its squares carry `dz`, their floor counted from z1, and the
--- empty ones (open air, squares that aren't loaded) are left out.
--- `data.floors` is the number of floors, `data.loaded` how many squares of
--- the area were loaded.
-- @param opts  see Core.captureArea
function Core.captureHouse(x1, y1, x2, y2, z1, z2, opts)
    z1, z2 = math.min(z1, z2), math.max(z1, z2)
    local cell = getCell()
    local house
    for z = z1, z2 do
        local data = Core.captureArea(x1, y1, x2, y2, z, opts)
        local squares = data.squares
        if not house then
            -- the first floor's table becomes the house: its own squares are
            -- gone through below like the other floors'
            house = data
            house.squares = {}
            house.floors = z2 - z1 + 1
            house.loaded = 0
        end
        local minX, minY = math.min(x1, x2), math.min(y1, y2)
        for _, entry in ipairs(squares) do
            if z == z1 and cell:getGridSquare(minX + entry.dx, minY + entry.dy, 0) then
                house.loaded = house.loaded + 1
            end
            if entry.floor or (entry.objects and #entry.objects > 0) or (entry.overlay and #entry.overlay > 0) then
                entry.dz = z - z1
                house.squares[#house.squares + 1] = entry
            end
        end
    end
    return house
end

-- Shareable strings -------------------------------------------------------
-- For sharing with another person we additionally base64-wrap it so the
-- result is one line of plain A-Z/a-z/0-9/+//= text with no quotes or
-- newlines to mangle when pasted into chat, a forum post, a text file, etc.
local STRING_FORMAT_TAG = "TCS1" -- TileCopy String

--- Turns a captured area (as returned by Core.captureArea, or any clipboard
--- entry) into a single shareable string.
--- Also decodes the result straight back, so a string that can't be
--- imported is caught at export time instead of by whoever receives it.
--- Returns the string, or nil plus a reason.
local function firstDifference(a, b)
    local n = math.min(#a, #b)
    for i = 1, n do
        if a:sub(i, i) ~= b:sub(i, i) then return i end
    end
    if #a ~= #b then return n + 1 end
    return nil
end

function Core.areaToString(data)
    Util.info("export: start", data and data.name, data and data.width, "x", data and data.height,
        "squares=", data and data.squares and #data.squares)
    if not data then return nil, "nothing selected" end

    local serialized = Util.serialize(data)
    if not serialized then
        Util.info("export: serialize FAILED")
        return nil, "serialize failed"
    end
    Util.info("export: serialized", Util.preview(serialized))

    local encoded = Util.base64Encode(serialized)
    if not encoded then
        Util.info("export: base64 encode FAILED")
        return nil, "encode failed"
    end
    Util.info("export: encoded length", #encoded, "(expected", math.ceil(#serialized / 3) * 4 .. ")")
    local str = STRING_FORMAT_TAG .. ":" .. encoded

    -- Self-check: decode straight back and compare byte for byte.
    local decoded = Util.base64Decode(encoded)
    if not decoded then
        Util.info("export: self-check decode FAILED")
    elseif decoded ~= serialized then
        local at = firstDifference(decoded, serialized)
        Util.info("export: self-check MISMATCH at byte", at, "of", #serialized, "(decoded", #decoded, "bytes)")
        Util.info("export:   original near there:", serialized:sub(math.max(1, (at or 1) - 20), (at or 1) + 20))
        Util.info("export:   decoded  near there:", decoded:sub(math.max(1, (at or 1) - 20), (at or 1) + 20))
    else
        Util.info("export: self-check base64 round trip OK")
    end

    local check, err = Core.areaFromString(str)
    if not check then
        Util.info("export: self-check import FAILED -", err)
        return nil, "self-check failed: " .. tostring(err)
    end
    Util.info("export: done,", #str, "chars")
    return str
end

--- Reverses Core.areaToString. Returns the captured-area table on success,
--- or nil plus a human-readable reason on failure.
function Core.areaFromString(str)
    Util.info("import: input", Util.preview(str))
    if not str or str == "" then return nil, "that field is empty" end

    -- Find the tag with a plain find (no pattern over the whole string)
    local tagPos = str:find(STRING_FORMAT_TAG .. ":", 1, true)
    if not tagPos then
        Util.info("import: no", STRING_FORMAT_TAG .. ":", "prefix found")
        return nil, "not a Tile Copy string (no " .. STRING_FORMAT_TAG .. ": prefix, got " .. #str .. " chars)"
    end
    local encoded = str:sub(tagPos + #STRING_FORMAT_TAG + 1)
    Util.info("import: prefix at char", tagPos, "- encoded part is", #encoded, "chars",
        "(length mod 4 =", #encoded % 4 .. ", should be 0)")

    local serialized = Util.base64Decode(encoded)
    if not serialized or serialized == "" then
        Util.info("import: base64 decode FAILED")
        return nil, "base64 decode failed (" .. #encoded .. " chars)"
    end
    Util.info("import: decoded", Util.preview(serialized))

    local data, desErr = Util.deserialize(serialized)
    if not data or type(data) ~= "table" or not data.squares then
        Util.info("import: parse FAILED -", desErr, "| got type", type(data),
            "| has squares:", type(data) == "table" and data.squares ~= nil)
        return nil, "could not read it (" .. #encoded .. " chars, truncated?): " .. tostring(desErr)
    end

    Util.info("import: OK -", data.name, data.width, "x", data.height, "squares=", #data.squares)
    return data
end

--- Removes one object from a square. In multiplayer this only ever runs on
--- the server (see TileCopy_ServerCommands)
local function removeSquareObject(square, object)
    if not square or not object then return false end
    if isServer() then
        square:transmitRemoveItemFromSquareOnClients(object)
    end
    square:RemoveTileObject(object)
    return true
end

--- Grass, vegetation and extra floor layers that vanilla floor building
--- (BuildRecipeCode.floor.OnCreate) clears off a square first. Left in
--- place they draw over a pasted floor. Trees and rugs are kept.
local GROUND_COVER_FLAGS = { "canBeRemoved", "solidfloor", "noStart", "taintedWater" }

local function isGroundCover(obj)
    local name = getSpriteNameSafe(obj)
    if name and name:find("floors_rugs", 1, true) then return false end
    if name and name:find("blends_grassoverlays", 1, true) then return true end
    if hasPropertyFlag(obj, GROUND_COVER_FLAGS) then return true end
    return hasPropertyFlag(obj, { "vegitation" })
        and not (IsoObjectType and obj:getType() == IsoObjectType.tree)
end

--- Removes ground cover from a square (everything except floorObj) and
--- records each removed sprite so undo can put it back.
local function clearGroundCover(sq, floorObj, applied)
    local objs = sq:getObjects()
    for i = objs:size() - 1, 0, -1 do
        local obj = objs:get(i)
        if obj ~= floorObj and isGroundCover(obj) then
            local name = getSpriteNameSafe(obj)
            removeSquareObject(sq, obj)
            if name then
                applied.objects[#applied.objects + 1] = { square = sq, removedSprite = name }
            end
        end
    end
end

local function placeSprite(sq, spriteName)
    local sprite = getSprite and getSprite(spriteName)
    if sprite and ISMoveableSpriteProps and ISMoveableSpriteProps.new then
        local props = ISMoveableSpriteProps.new(sprite)
        props.rawWeight = 10
        -- nil result is still a success for tiles that get merged into
        -- something already there (wall overlays, trees, floor tiles).
        -- no character: placeMoveableInternal only uses it for halo notes
        local result = props:placeMoveableInternal(nil, sq, instanceItem("Base.Plank"), spriteName)
        return result, true
    end

    if not sprite then return nil, false end
    local obj = IsoObject.new(getCell(), sq, sprite)
    if not obj then return nil, false end
    sq:AddTileObject(obj)
    if isServer() then obj:transmitCompleteItemToClients() end
    return obj, true
end

local function applyAttached(obj, rec)
    if not rec.attached or not obj.AttachExistingAnim then return end
    for _, name in ipairs(rec.attached) do
        local spr = getSprite(name)
        if spr then
            obj:AttachExistingAnim(spr, 0, 0, false, 0, false, 0)
        end
    end
    if isServer() then obj:transmitUpdatedSpriteToClients() end
end

--- Plain decorative sprite (rug, clutter, grime) - no behaviour needed.
local function placeOverlay(sq, spriteName)
    local sprite = getSprite(spriteName)
    if not sprite then
        Util.info("paste: unknown sprite", spriteName, "- tile pack not loaded here?")
        return nil
    end
    -- Must be the registered sprite: IsoObject.new(sq, name) builds a
    -- texture-only copy with no properties and a placeholder id, so it
    -- doesn't survive a save or the sync to MP clients.
    local obj = IsoObject.new(getCell(), sq, sprite)
    if not obj then return nil end
    sq:AddTileObject(obj)
    if isServer() then obj:transmitCompleteItemToClients() end
    return obj
end

local function fillContainer(container, containerData)
    if not container or not containerData or not containerData.items then return end
    for _, itemData in ipairs(containerData.items) do
        if itemData.fullType then
            local newItem = container:AddItem(itemData.fullType)
            if newItem then
                if itemData.count and newItem.setCount then
                    newItem:setCount(itemData.count)
                end
                if itemData.condition and newItem.setCondition then
                    newItem:setCondition(itemData.condition)
                end
                if itemData.uses and newItem.setCurrentUsesFloat then
                    newItem:setCurrentUsesFloat(itemData.uses)
                end
                -- synced after the stats are set, so clients get the real values
                if isServer() and sendAddItemToContainer then
                    sendAddItemToContainer(container, newItem)
                end
            end
        end
    end
    container:setExplored(true)
    container:setDrawDirty(true)
end

--- Places the saved items into a freshly placed object's containers.
function Core.applyContainers(obj, rec)
    local list = rec.containers or (rec.container and { rec.container }) or nil
    if not list then return end

    local count = obj.getContainerCount and obj:getContainerCount()
    for i, containerData in ipairs(list) do
        local container
        if count and count >= i then
            container = obj:getContainerByIndex(i - 1)
        elseif i == 1 and obj.getContainer then
            container = obj:getContainer()
        end
        fillContainer(container, containerData)
    end
end

--- Whether a copied square has anything to paste.
local function entryHasTiles(entry)
    return entry.floor ~= nil
        or (entry.objects ~= nil and #entry.objects > 0)
        or (entry.overlay ~= nil and #entry.overlay > 0)
end

--- Pastes a previously captured data table with its (0,0) corner at
--- destX,destY,destZ. `label` is how its undo is described ("paste 'name'"
--- when not given). An entry with a `dz` goes that many floors above destZ
--- (a house, see Core.captureHouse).
--- Returns true plus how many of its squares were loaded.
function Core.applyArea(data, destX, destY, destZ, label)
    if not data or not data.squares then return false end
    local cell = getCell()
    if not cell then return false end

    local applied = { objects = {} }

    local touchedSquares = {}

    for _, entry in ipairs(data.squares) do
        local x, y, z = destX + entry.dx, destY + entry.dy, destZ + (entry.dz or 0)
        local sq = cell:getGridSquare(x, y, z)
        -- above ground a square only exists once something is on it
        if not sq and z > 0 and z <= AdminTools_Tiles_Util.MAX_Z and entryHasTiles(entry) and cell:getGridSquare(x, y, 0) then
            sq = cell:getOrCreateGridSquare(x, y, z)
        end
        if sq then
            touchedSquares[#touchedSquares + 1] = sq

            if entry.floor then
                local existingFloor = sq:getFloor()
                if existingFloor then
                    local oldSprite = existingFloor:getSpriteName()
                    local newSprite = getSprite(entry.floor)
                    if newSprite and (oldSprite ~= entry.floor or entry.floorAttached) then
                        clearGroundCover(sq, existingFloor, applied)
                        -- blend tiles (grass/dirt edges) are attached to
                        -- the floor object itself
                        local oldAttached = captureAttached(existingFloor, true, true)
                        existingFloor:setSprite(newSprite)
                        existingFloor:RemoveAttachedAnims()
                        applyAttached(existingFloor, { attached = entry.floorAttached })
                        if isServer() then
                            existingFloor:transmitUpdatedSpriteToClients()
                        end
                        applied.objects[#applied.objects + 1] = {
                            square = sq, floor = existingFloor, oldSprite = oldSprite,
                            oldAttached = oldAttached,
                        }
                    end
                else
                    local floorObj = sq:addFloor(entry.floor)
                    if floorObj then
                        if isServer() then
                            floorObj:transmitCompleteItemToClients()
                        end
                        applyAttached(floorObj, { attached = entry.floorAttached })
                        applied.objects[#applied.objects + 1] = { square = sq, object = floorObj }
                    end
                end
            end

            if entry.objects then
                for _, rec in ipairs(entry.objects) do
                    local obj = placeSprite(sq, rec.sprite)
                    if obj then
                        applied.objects[#applied.objects + 1] = { square = sq, object = obj }
                        Core.applyContainers(obj, rec)
                        applyAttached(obj, rec)
                    end
                end
            end

            if entry.overlay then
                for _, rec in ipairs(entry.overlay) do
                    local obj = placeOverlay(sq, rec.sprite)
                    if obj then
                        applied.objects[#applied.objects + 1] = { square = sq, object = obj }
                        applyAttached(obj, rec)
                    end
                end
            end
        else
            Util.log("applyArea: target square not loaded at", x, y, z, "- skipped")
        end
    end
    local recalced = {}
    local function squareKey(sq)
        return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
    end
    local function recalcSquare(sq)
        if not sq then return end
        local key = squareKey(sq)
        if recalced[key] then return end
        recalced[key] = true
        sq:RecalcProperties()
        sq:RecalcAllWithNeighbours(true)
    end

    for _, sq in ipairs(touchedSquares) do
        recalcSquare(sq)
    end
    local BORDER_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    for _, entry in ipairs(data.squares) do
        local x, y, z = destX + entry.dx, destY + entry.dy, destZ + (entry.dz or 0)
        for _, off in ipairs(BORDER_OFFSETS) do
            recalcSquare(cell:getGridSquare(x + off[1], y + off[2], z))
        end
    end

    Util.info("paste:", data.name, "at", destX, destY, destZ, "-", #touchedSquares, "of", #data.squares,
        "squares loaded,", #applied.objects, "changes made",
        isServer() and "(server)" or (isClient() and "(client)" or "(single player)"))
    if #applied.objects > 0 then
        Core.pushUndo(applied, label or ("paste '" .. tostring(data.name) .. "'"))
    end
    return true, #touchedSquares
end

-- Undo ------------------------------------------------------------------------
-- Every paste / remove / swap pushes what it changed (an `applied` table:
-- { label=, objects={ record, ... } }) on Core.undoStack, and each undo takes
-- the newest one back. The history is kept in memory only: it's gone after a
-- restart.

Core.undoStack = {}
-- Oldest entries are dropped past this many
Core.MAX_UNDO = 20
-- Parts of an undo whose squares weren't loaded, oldest first: each is a
-- list of records of one map block, put back when it loads
-- (see Core.retryPendingUndos).
Core.pendingUndos = {}

local UNDO_BLOCK = 8

--- Saves where each new record of `applied` is and which sprite its object
--- has now. An undo can come long after the change, when the square was
--- unloaded and loaded again: the square / object kept in the record are no
--- longer the ones in the world then, and have to be found again.
function Core.stampUndo(applied)
    for i = (applied.stamped or 0) + 1, #applied.objects do
        local item = applied.objects[i]
        local square = item.square
        if square then
            item.x, item.y, item.z = square:getX(), square:getY(), square:getZ()
            local obj = item.floor or item.object
            if obj then item.sprite = getSpriteNameSafe(obj) end
        end
    end
    applied.stamped = #applied.objects
end

--- Adds a finished change to the undo history. `label` is how the undo is
--- described to the admin ("swap 'Bloody'").
function Core.pushUndo(applied, label)
    applied.label = label
    Core.stampUndo(applied)
    local stack = Core.undoStack
    stack[#stack + 1] = applied
    while #stack > Core.MAX_UNDO do
        local oldest = table.remove(stack, 1)
        oldest.dropped = true
    end
    return applied
end

--- The square of an undo record, or nil while its part of the map isn't
--- loaded. An emptied square above ground isn't always kept by the game, so
--- it's the ground square that tells whether the map is loaded there.
local function recordSquare(cell, item)
    if not item.x or not cell:getGridSquare(item.x, item.y, 0) then return nil end
    return cell:getGridSquare(item.x, item.y, item.z) or cell:getOrCreateGridSquare(item.x, item.y, item.z)
end

--- The object a record changed / added, or nil when it's gone (removing one
--- part of a multi-tile object can take the other parts with it).
--- When the object itself isn't there any more, a copy with the same sprite
--- stands for it: a later change took it out and its undo put a new one back
--- (a swap run twice, undone twice).
local function recordObject(item, obj)
    local objs = item.square:getObjects()
    if not item.stale and objs:contains(obj) then return obj end
    for i = objs:size() - 1, 0, -1 do
        local other = objs:get(i)
        if getSpriteNameSafe(other) == item.sprite then return other end
    end
    return nil
end

--- Reverts the records whose square is loaded. Returns how many that was
--- and the rest, still in order.
local function revertRecords(records)
    local cell = getCell()
    local ready, left = {}, {}
    for _, item in ipairs(records) do
        local square = recordSquare(cell, item)
        if square then
            if square ~= item.square then
                item.square = square
                item.stale = true
            end
            ready[#ready + 1] = item
        elseif item.x then
            left[#left + 1] = item
        end
    end

    -- First take back what was added / changed, newest first...
    for i = #ready, 1, -1 do
        local item = ready[i]
        local square = item.square
        if item.floor then
            local floorObj = recordObject(item, item.floor)
            local oldSprite = floorObj and item.oldSprite and getSprite(item.oldSprite)
            if oldSprite then
                floorObj:setSprite(oldSprite)
                floorObj:RemoveAttachedAnims()
                applyAttached(floorObj, { attached = item.oldAttached })
                if isServer() then
                    floorObj:transmitUpdatedSpriteToClients()
                end
            end
        elseif item.removedSprite then
            placeOverlay(square, item.removedSprite)
        elseif item.object then
            local obj = recordObject(item, item.object)
            if obj then removeSquareObject(square, obj) end
        end
    end

    -- ...then put back what the Tile Remover / Tile Swap took out, in the
    -- order it was recorded (floor first, objects bottom to top), so the
    -- parts of multi-tile furniture and stacked objects go back like a paste.
    for _, item in ipairs(ready) do
        local square = item.square
        if item.removedFloor then
            local floorObj = square:addFloor(item.removedFloor)
            if floorObj then
                if isServer() then floorObj:transmitCompleteItemToClients() end
                applyAttached(floorObj, { attached = item.attached })
            end
        elseif item.removedRec then
            Core.restoreRecord(square, item.removedRec)
        end
    end

    for _, item in ipairs(ready) do
        item.square:RecalcProperties()
        item.square:RecalcAllWithNeighbours(true)
    end
    return #ready, left
end

--- Keeps the records an undo couldn't reach, grouped by map block so the
--- retry only has to look at one square per block.
local function deferUndo(records)
    local blocks = {}
    for _, item in ipairs(records) do
        local key = math.floor(item.x / UNDO_BLOCK) .. "," .. math.floor(item.y / UNDO_BLOCK)
        local block = blocks[key]
        if not block then
            block = {}
            blocks[key] = block
            Core.pendingUndos[#Core.pendingUndos + 1] = block
        end
        block[#block + 1] = item
    end
end

--- Takes back the newest change of the history. Returns false when there's
--- none, else { label=, changes=, deferred=, remaining= }: `deferred` changes
--- are in a part of the map that isn't loaded and are put back when it is.
function Core.undoLast()
    local applied = table.remove(Core.undoStack)
    if not applied then return false end
    applied.undone = true
    Core.stampUndo(applied)

    local changes, left = revertRecords(applied.objects)
    if #left > 0 then deferUndo(left) end

    Util.info("undo:", applied.label, "- reverted", changes, "changes,", #left, "waiting for their area to load")
    return { label = applied.label, changes = changes, deferred = #left, remaining = #Core.undoStack }
end

--- Finishes the undos that were waiting for their part of the map to load.
--- Called now and then by TileAdmin_Core.
function Core.retryPendingUndos()
    local pending = Core.pendingUndos
    if #pending == 0 then return end
    local cell = getCell()
    if not cell then return end

    local kept = {}
    for _, block in ipairs(pending) do
        if cell:getGridSquare(block[1].x, block[1].y, 0) then
            local _, left = revertRecords(block)
            block = left
        end
        if #block > 0 then kept[#kept + 1] = block end
    end
    Core.pendingUndos = kept
end

-- Tile Remover / Tile Swap (TileAdmin_Core) ---------------------------------
-- They push their changes with Core.pushUndo too, so the same undo works.

--- Saves what's needed to put an object back: { sprite, layer, attached, containers }.
--- `class` is Core.classifyObject(obj). Returns nil for an object with no sprite.
function Core.captureRecord(obj, class)
    local spriteName = getSpriteNameSafe(obj)
    if obj.IsOpen and obj.getClosedSprite and obj:IsOpen() then
        local closed = obj:getClosedSprite()
        if closed and closed:getName() then spriteName = closed:getName() end
    end
    if not spriteName then return nil end
    local rec = { sprite = spriteName, layer = class, attached = captureAttached(obj, true, true) }
    if class == "structural" then rec.containers = Core.captureContainers(obj) end
    return rec
end

--- Places an object saved by Core.captureRecord back on a square.
function Core.restoreRecord(sq, rec)
    local obj
    if rec.layer == "overlay" then
        obj = placeOverlay(sq, rec.sprite)
    else
        obj = placeSprite(sq, rec.sprite)
    end
    if obj then
        Core.applyContainers(obj, rec)
        applyAttached(obj, rec)
    end
    return obj
end

Core.getSpriteName = getSpriteNameSafe
Core.hasPropertyFlag = hasPropertyFlag
Core.captureAttached = captureAttached
Core.applyAttached = applyAttached
Core.removeSquareObject = removeSquareObject
Core.placeSprite = placeSprite
Core.placeOverlay = placeOverlay

return Core
