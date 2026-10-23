--[[
    TileAdmin_Core.lua  (shared)

    Logic behind the other "Tile Admin" tools, kept apart from any UI so
    it runs on the client (single player) and on the server:
      - Tile Remover: clears an area and puts natural ground (grass / dirt /
        sand) back where the floor was
      - Tile Builder: puts one tile on every square of a dragged line / area;
        the Zone Editor's "Building" mode floors and walls in a whole room
      - Tile Swap: runs a preset (a list of rules) over an area. A rule picks
        tiles by group ("all floors") or by sprite and swaps them, attaches
        an overlay to them, places something on their square or removes them

    A swap also reaches the part of its area that isn't loaded: that part
    waits in a queue until it is (see "Tile Swap: queue").
]]

require "TileCopy_Core"

TileCopy = TileCopy or {}
TileCopy.Admin = TileCopy.Admin or {}
local Admin = TileCopy.Admin
local Util = TileCopy.Util
local Core = TileCopy.Core

-- Biggest area (squares x floors) one request may touch. Same cap as the
-- loot tools, so a zone drawn in the Zone Editor fits both.
-- This cap is obscene bc there should be no limit (introduced the "Load" function)
Admin.MAX_SQUARES = 5500000000

--------------------------------------------------------------------------
-- Area helpers
--------------------------------------------------------------------------

--- Sorted, whole-number copy of an { x1, y1, x2, y2, z1, z2 } request.
--- Returns nil plus a reason when it's unusable or too big.
function Admin.normalizeArea(args)
    if not args then return nil, "No area selected." end
    local x1, y1, x2, y2 = tonumber(args.x1), tonumber(args.y1), tonumber(args.x2), tonumber(args.y2)
    if not (x1 and y1 and x2 and y2) then return nil, "No area selected." end
    local z1 = tonumber(args.z1) or 0
    local z2 = tonumber(args.z2) or z1

    local area = {
        x1 = math.floor(math.min(x1, x2)), x2 = math.floor(math.max(x1, x2)),
        y1 = math.floor(math.min(y1, y2)), y2 = math.floor(math.max(y1, y2)),
        z1 = AdminTools_Tiles_Util.clampZ(math.min(z1, z2)), z2 = AdminTools_Tiles_Util.clampZ(math.max(z1, z2)),
    }
    local squares = (area.x2 - area.x1 + 1) * (area.y2 - area.y1 + 1) * (area.z2 - area.z1 + 1)
    if squares > Admin.MAX_SQUARES then
        return nil, "Area too big: " .. squares .. " squares (max " .. Admin.MAX_SQUARES .. ")"
    end
    return area
end

--- Calls fn(square) for every loaded square of an area.
local function forEachSquare(area, fn)
    local cell = getCell()
    if not cell then return end
    for z = area.z1, area.z2 do
        for y = area.y1, area.y2 do
            for x = area.x1, area.x2 do
                local sq = cell:getGridSquare(x, y, z)
                if sq then fn(sq) end
            end
        end
    end
end

--- Lua copy of a square's object list, safe to loop over while removing.
local function squareObjects(sq)
    local list = {}
    local objs = sq:getObjects()
    if objs then
        for i = 0, objs:size() - 1 do
            list[#list + 1] = objs:get(i)
        end
    end
    return list
end

local BORDER_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

--- Recalculates the changed squares and the ones right next to them.
local function recalcSquares(squares)
    local cell = getCell()
    local done = {}
    local function recalc(sq)
        if not sq or done[sq] then return end
        done[sq] = true
        sq:RecalcProperties()
        sq:RecalcAllWithNeighbours(true)
    end
    for _, sq in ipairs(squares) do recalc(sq) end
    for _, sq in ipairs(squares) do
        for _, off in ipairs(BORDER_OFFSETS) do
            recalc(cell:getGridSquare(sq:getX() + off[1], sq:getY() + off[2], sq:getZ()))
        end
    end
end

--------------------------------------------------------------------------
-- Natural ground
--------------------------------------------------------------------------

-- blends_natural_01 is laid out in rows of 16: sand, dark / medium / light
-- grass, dirt... In each row tiles 0, 5, 6 and 7 are the plain full floors,
-- the rest are the blend edges.
local NATURAL_PREFIX = "blends_natural_01_"
local SOLID_OFFSETS = { 0, 5, 6, 7 }
local GROUND_BASE = { grass = 32, dirt = 64, sand = 0 }

-- Choices for the Tile Remover's "Ground" dropdown
Admin.GROUNDS = {
    { id = "auto", label = "Auto (match the surroundings)" },
    { id = "grass", label = "Grass" },
    { id = "dirt", label = "Dirt" },
    { id = "sand", label = "Sand" },
}

--- Row start (0, 16, 32...) of a plain natural floor sprite, nil for
--- anything else.
local function naturalBase(spriteName)
    if not spriteName or spriteName:sub(1, #NATURAL_PREFIX) ~= NATURAL_PREFIX then return nil end
    local index = tonumber(spriteName:sub(#NATURAL_PREFIX + 1))
    if not index then return nil end
    local base = math.floor(index / 16) * 16
    local offset = index - base
    for _, solid in ipairs(SOLID_OFFSETS) do
        if offset == solid then return base end
    end
    return nil
end

local function randomGround(base)
    return NATURAL_PREFIX .. (base + SOLID_OFFSETS[ZombRand(#SOLID_OFFSETS) + 1])
end

--- The natural ground seen most in and around the area on floor z
--- (medium grass when there's none in sight).
local function detectGround(area, z)
    local cell = getCell()
    local counts = {}
    local best, bestCount = GROUND_BASE.grass, 0
    for y = area.y1 - 3, area.y2 + 3 do
        for x = area.x1 - 3, area.x2 + 3 do
            local sq = cell:getGridSquare(x, y, z)
            local floorObj = sq and sq:getFloor()
            local base = floorObj and naturalBase(Core.getSpriteName(floorObj))
            if base then
                counts[base] = (counts[base] or 0) + 1
                if counts[base] > bestCount then
                    best, bestCount = base, counts[base]
                end
            end
        end
    end
    return best
end

--------------------------------------------------------------------------
-- Tile Remover
--------------------------------------------------------------------------

--- The other parts of a multi-tile object (bed, 2-tile table), each with
--- its square and undo record. Empty for a single-tile object.
local function otherParts(obj)
    local parts = {}
    if not obj.getSpriteGridObjectsIncludingSelf then return parts end
    local list = obj:getSpriteGridObjectsIncludingSelf(ArrayList.new())
    if not list then return parts end
    for i = 0, list:size() - 1 do
        local part = list:get(i)
        local partSq = part ~= obj and part:getSquare()
        if partSq then
            parts[#parts + 1] = { obj = part, sq = partSq, rec = Core.captureRecord(part, Core.classifyObject(part)) }
        end
    end
    return parts
end

--- Removes an object whose undo record `rec` (Core.captureRecord) was saved
--- earlier, adding what undo needs to `records`.
--- Removing one part of a multi-tile object can take the other parts with
--- it - whether or not they're in the area or matched by a rule. Those are
--- recorded here too, or undo would only bring back the part asked for.
--- `recorded` (set of objects) keeps a part from being recorded twice when
--- its own turn comes.
local function removeWithUndo(sq, obj, rec, records, recorded)
    local parts = {}
    if sq:getObjects():contains(obj) then
        parts = otherParts(obj)
        Core.removeSquareObject(sq, obj)
    end
    if rec and not recorded[obj] then
        recorded[obj] = true
        records[#records + 1] = { square = sq, removedRec = rec }
    end

    for _, part in ipairs(parts) do
        if part.rec and not recorded[part.obj] and not part.sq:getObjects():contains(part.obj) then
            recorded[part.obj] = true
            records[#records + 1] = { square = part.sq, removedRec = part.rec }
        end
    end
end

--- Removes an object and, for a multi-tile one, every other part of it (see
--- removeWithUndo). Marks them all in `consumed` and returns their squares.
local function removeWhole(sq, obj, rec, records, recorded, consumed)
    local squares = { sq }
    local parts = {}
    if sq:getObjects():contains(obj) then
        parts = otherParts(obj)
    end
    consumed[obj] = true
    removeWithUndo(sq, obj, rec, records, recorded)
    for _, part in ipairs(parts) do
        consumed[part.obj] = true
        removeWithUndo(part.sq, part.obj, part.rec, records, recorded)
        squares[#squares + 1] = part.sq
    end
    return squares
end

--- Where each tile goes when the tile `target` lands on the square
local function targetPlacements(sq, target)
    local sprite = getSprite(target)
    local grid = sprite:getSpriteGrid()
    if not grid then return { { sq = sq, sprite = target } } end

    local cell = getCell()
    local originX = sq:getX() - grid:getSpriteGridPosX(sprite)
    local originY = sq:getY() - grid:getSpriteGridPosY(sprite)
    local placements = {}
    for x = 0, grid:getWidth() - 1 do
        for y = 0, grid:getHeight() - 1 do
            local part = grid:getSprite(x, y)
            local partSq = part and cell:getGridSquare(originX + x, originY + y, sq:getZ())
            if partSq and part:getName() then
                placements[#placements + 1] = { sq = partSq, sprite = part:getName() }
            end
        end
    end
    return placements
end

--- Turns a square's floor back into natural ground. Above ground level
--- there's no ground underneath, so the floor is just taken out.
local function resetFloor(sq, groundBase, applied)
    local floorObj = sq:getFloor()

    if sq:getZ() > 0 then
        if not floorObj then return false end
        local name = Core.getSpriteName(floorObj)
        local attached = Core.captureAttached(floorObj, true, true)
        Core.removeSquareObject(sq, floorObj)
        if name then
            applied.objects[#applied.objects + 1] = { square = sq, removedFloor = name, attached = attached }
        end
        return true
    end

    if not floorObj then
        local newFloor = sq:addFloor(randomGround(groundBase))
        if not newFloor then return false end
        if isServer() then newFloor:transmitCompleteItemToClients() end
        applied.objects[#applied.objects + 1] = { square = sq, object = newFloor }
        return true
    end

    local oldSprite = Core.getSpriteName(floorObj)
    -- already natural ground: nothing to dig up
    if naturalBase(oldSprite) then return false end

    local newSprite = getSprite(randomGround(groundBase))
    if not newSprite then return false end
    local oldAttached = Core.captureAttached(floorObj, true, true)
    floorObj:setSprite(newSprite)
    floorObj:RemoveAttachedAnims()
    if isServer() then floorObj:transmitUpdatedSpriteToClients() end
    applied.objects[#applied.objects + 1] = {
        square = sq, floor = floorObj, oldSprite = oldSprite, oldAttached = oldAttached,
    }
    return true
end

--- Removes everything in an area.
-- @param args  { x1, y1, x2, y2, z1, z2,
--               tiles=bool, walls=bool, overlay=bool, floors=bool,
--               ground="auto"|"grass"|"dirt"|"sand" }
-- Returns { removed=, floors=, squares= }, or nil plus a reason.
function Admin.removeArea(args)
    local area, err = Admin.normalizeArea(args)
    if not area then return nil, err end

    local applied = { objects = {} }

    local result = { removed = 0, floors = 0, squares = 0 }
    local touched = {}
    local groundByFloor = {}

    -- Save everything before taking anything out: removing one half of a
    -- multi-tile object (2-tile table, couch) can take the other half with it,
    -- and that half would be gone before its square is reached.
    local plan = {}
    forEachSquare(area, function(sq)
        result.squares = result.squares + 1
        local floorObj = sq:getFloor()
        local items = {}
        for _, obj in ipairs(squareObjects(sq)) do
            if obj ~= floorObj then
                local class = Core.classifyObject(obj)
                local wanted = (class == "wall" and args.walls)
                    or (class == "structural" and args.tiles)
                    or (class == "overlay" and args.overlay)
                if wanted then
                    items[#items + 1] = { obj = obj, rec = Core.captureRecord(obj, class) }
                end
            end
        end
        plan[#plan + 1] = { sq = sq, items = items }
    end)

    -- Recorded in the order undo puts things back: floor, then the objects
    -- bottom to top, square after square (the same order a paste uses).
    local recorded = {}
    for _, entry in ipairs(plan) do
        local sq = entry.sq
        local changed = false

        local objectRecords = {}
        for _, item in ipairs(entry.items) do
            removeWithUndo(sq, item.obj, item.rec, objectRecords, recorded)
            result.removed = result.removed + 1
            changed = true
        end

        if args.floors then
            local z = sq:getZ()
            if not groundByFloor[z] then
                -- nothing grows in a basement
                groundByFloor[z] = GROUND_BASE[args.ground] or (z < 0 and GROUND_BASE.dirt) or detectGround(area, z)
            end
            if resetFloor(sq, groundByFloor[z], applied) then
                result.floors = result.floors + 1
                changed = true
            end
        end
        for _, record in ipairs(objectRecords) do
            applied.objects[#applied.objects + 1] = record
        end

        if changed then touched[#touched + 1] = sq end
    end

    recalcSquares(touched)
    if #applied.objects > 0 then Core.pushUndo(applied, "remove") end
    Util.info("remove:", area.x1, area.y1, "->", area.x2, area.y2, "floors", area.z1, "to", area.z2, "-",
        result.removed, "objects removed,", result.floors, "floors reset,", result.squares, "squares loaded")
    return result
end

--------------------------------------------------------------------------
-- Tile Builder
--------------------------------------------------------------------------

-- Flags of the tiles that face a side, as { west, north }. In a tileset the
-- north version of such a tile comes right after its west version.
local FACING_FLAGS = {
    { "WallW", "WallN" },
    { "WallWTrans", "WallNTrans" },
    { "DoorWallW", "DoorWallN" },
    { "WindowW", "WindowN" },
    { "HoppableW", "HoppableN" },
}

--- The version of a wall-like tile (wall, window wall, door frame, fence)
--- that follows a line: its north version along x, its west version along
--- y. Any other tile, or one whose tileset has no such twin, comes back as
--- it is.
function Admin.lineSprite(spriteName, alongX)
    local sprite = getSprite(spriteName)
    local tileset, number = spriteName:match("^(.*)_(%d+)$")
    if not sprite or not number then return spriteName end

    local has = Core.hasPropertyFlag
    for _, pair in ipairs(FACING_FLAGS) do
        local west, north = has(sprite, { pair[1] }), has(sprite, { pair[2] })
        if west ~= north then
            if north == alongX then return spriteName end
            local wanted, unwanted = pair[alongX and 2 or 1], pair[alongX and 1 or 2]
            local twinName = tileset .. "_" .. (tonumber(number) + (west and 1 or -1))
            local twin = getSprite(twinName)
            if twin and has(twin, { wanted }) and not has(twin, { unwanted }) then return twinName end
            return spriteName
        end
    end
    return spriteName
end

local function hasSprite(sq, spriteName)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        if Core.getSpriteName(objs:get(i)) == spriteName then return true end
    end
    return false
end

--- The Tile Builder: puts one tile on every square of an area (a line is an
--- area one square wide), the way the Brush Tool places a single one. A floor
--- tile replaces the floor. Squares that already have the tile are skipped.
-- @param args  { sprite=, x1, y1, x2, y2, z1 }
-- Returns { sprite=, placed=, squares= }, or nil plus a reason.
function Admin.buildArea(args)
    local area, err = Admin.normalizeArea(args)
    if not area then return nil, err end
    local spriteName = args.sprite
    local sprite = type(spriteName) == "string" and getSprite(spriteName)
    if not sprite then return nil, "Unknown tile: " .. tostring(spriteName) end

    local cell = getCell()
    local z = area.z1
    local isFloor = Core.hasPropertyFlag(sprite, { "solidfloor" })
    local data = { name = spriteName, squares = {} }
    local result = { sprite = spriteName, placed = 0, squares = 0 }
    for y = area.y1, area.y2 do
        for x = area.x1, area.x2 do
            local sq = cell:getGridSquare(x, y, z)
            -- above ground a square only exists once something is on it
            if not sq and cell:getGridSquare(x, y, 0) then
                sq = cell:getOrCreateGridSquare(x, y, z)
            end
            if sq then
                result.squares = result.squares + 1
                if not hasSprite(sq, spriteName) then
                    local entry = { dx = x - area.x1, dy = y - area.y1 }
                    if isFloor then
                        entry.floor = spriteName
                    else
                        entry.objects = { { sprite = spriteName } }
                    end
                    data.squares[#data.squares + 1] = entry
                    result.placed = result.placed + 1
                end
            end
        end
    end

    if result.placed > 0 then
        Core.applyArea(data, area.x1, area.y1, z, "build " .. spriteName)
    end
    return result
end

-- A wall set is four tiles in a row in its tileset: west wall, north wall,
-- north-west corner, south-east pillar.
local WALL_PIECES = { "w", "n", "nw", "se" }
local WALL_PIECE_OFFSET = { w = 0, n = 1, nw = 2, se = 3 }

--- Which piece of a wall set a sprite is ("w", "n", "nw", "se"), nil when
--- it isn't a plain wall.
local function wallPiece(sprite)
    local has = Core.hasPropertyFlag
    local west = has(sprite, { "WallW", "WallWTrans" })
    local north = has(sprite, { "WallN", "WallNTrans" })
    if has(sprite, { "WallNW" }) or (west and north) then return "nw" end
    if has(sprite, { "WallSE" }) then return "se" end
    if west then return "w" end
    if north then return "n" end
    return nil
end

--- The wall set a wall tile belongs to: { w=, n=, nw=, se= } sprite names,
--- found from any one of its pieces. `nw` and `se` are nil when the tileset
--- doesn't have them where expected. Returns nil plus a reason for a tile
--- that isn't a wall, or whose set has no west / north wall.
function Admin.wallSet(spriteName)
    local sprite = type(spriteName) == "string" and getSprite(spriteName)
    if not sprite then return nil, "Unknown tile: " .. tostring(spriteName) end
    local tileset, number = spriteName:match("^(.*)_(%d+)$")
    local piece = wallPiece(sprite)
    if not piece or not number then return nil, tostring(spriteName) .. " isn't a wall tile." end

    local base = tonumber(number) - WALL_PIECE_OFFSET[piece]
    local set = {}
    for _, key in ipairs(WALL_PIECES) do
        local name = tileset .. "_" .. (base + WALL_PIECE_OFFSET[key])
        local other = base + WALL_PIECE_OFFSET[key] >= 0 and getSprite(name)
        if other and wallPiece(other) == key then set[key] = name end
    end
    if not (set.w and set.n) then
        return nil, "Couldn't find the west and north walls that go with " .. spriteName .. "."
    end
    return set
end

--- The Zone Editor's "Building" mode: lays a floor over an area and / or
--- walls it in, on every floor from z1 to z2. The area is the inside of the
--- room: the south and east walls stand on the squares just past it, where
--- the game wants them. Tiles already there are skipped.
-- @param args  { x1, y1, x2, y2, z1, z2, floor=sprite or nil, wall=sprite or nil }
--              `wall` is any piece of the wall set (see Admin.wallSet)
-- Returns { floors=, walls=, loaded= }, or nil plus a reason.
function Admin.buildRoom(args)
    local area, err = Admin.normalizeArea(args)
    if not area then return nil, err end

    local floor = args.floor
    if floor and not getSprite(floor) then return nil, "Unknown tile: " .. tostring(floor) end
    local walls
    if args.wall then
        walls, err = Admin.wallSet(args.wall)
        if not walls then return nil, err end
    end
    if not floor and not walls then return nil, "Pick a floor tile or a wall tile first." end

    local cell = getCell()
    local w, h = area.x2 - area.x1 + 1, area.y2 - area.y1 + 1
    local data = { name = "room", squares = {} }
    local result = { floors = 0, walls = 0, loaded = 0 }

    for z = area.z1, area.z2 do
        local dz = z - area.z1
        local entries = {}
        local function entryAt(dx, dy)
            local key = dx .. "," .. dy
            local entry = entries[key]
            if not entry then
                entry = { dx = dx, dy = dy, dz = dz }
                entries[key] = entry
                data.squares[#data.squares + 1] = entry
            end
            return entry
        end
        local function addWall(dx, dy, spriteName)
            if not spriteName then return end
            local sq = cell:getGridSquare(area.x1 + dx, area.y1 + dy, z)
            if sq and hasSprite(sq, spriteName) then return end
            local entry = entryAt(dx, dy)
            entry.objects = entry.objects or {}
            entry.objects[#entry.objects + 1] = { sprite = spriteName }
            result.walls = result.walls + 1
        end

        if floor then
            for dy = 0, h - 1 do
                for dx = 0, w - 1 do
                    entryAt(dx, dy).floor = floor
                    result.floors = result.floors + 1
                end
            end
        end
        if walls then
            if walls.nw then
                addWall(0, 0, walls.nw)
            else
                addWall(0, 0, walls.w)
                addWall(0, 0, walls.n)
            end
            for dx = 0, w - 1 do
                if dx > 0 then addWall(dx, 0, walls.n) end
                addWall(dx, h, walls.n)
            end
            for dy = 0, h - 1 do
                if dy > 0 then addWall(0, dy, walls.w) end
                addWall(w, dy, walls.w)
            end
            addWall(w, h, walls.se)
        end
    end

    if #data.squares > 0 then
        local _, loaded = Core.applyArea(data, area.x1, area.y1, area.z1, "build room")
        result.loaded = loaded or 0
    end
    Util.info("build room:", area.x1, area.y1, "->", area.x2, area.y2, "floors", area.z1, "to", area.z2, "-",
        result.floors, "floor tiles,", result.walls, "walls,", result.loaded, "squares loaded")
    return result
end

--------------------------------------------------------------------------
-- Tile Swap: groups
--------------------------------------------------------------------------

-- What a rule can target besides one exact sprite. Walls are split by
-- direction because their replacement has to face the same way.
Admin.GROUPS = {
    { id = "all", label = "Everything" },
    { id = "floor", label = "All floors" },
    { id = "floor_built", label = "Floors - built (not natural ground)" },
    { id = "floor_natural", label = "Floors - natural ground" },
    { id = "wall", label = "All walls (any kind)" },
    { id = "wall_w", label = "Walls - west" },
    { id = "wall_n", label = "Walls - north" },
    { id = "wall_nw", label = "Walls - corner (north-west)" },
    { id = "wall_se", label = "Walls - pillar (south-east)" },
    { id = "windowwall_w", label = "Window walls - west" },
    { id = "windowwall_n", label = "Window walls - north" },
    { id = "doorframe_w", label = "Door frames - west" },
    { id = "doorframe_n", label = "Door frames - north" },
    { id = "fence_w", label = "Low walls / fences - west" },
    { id = "fence_n", label = "Low walls / fences - north" },
    { id = "door", label = "Doors" },
    { id = "window", label = "Windows" },
    { id = "furniture", label = "Furniture / structures" },
    { id = "overlay", label = "Overlay (clutter / decals / plants)" },
}

local GROUP_LABELS = {}
for _, group in ipairs(Admin.GROUPS) do GROUP_LABELS[group.id] = group.label end

function Admin.groupLabel(id)
    return GROUP_LABELS[id] or tostring(id)
end

--- Set of group ids an object belongs to. `class` is Core.classifyObject(obj).
function Admin.objectGroups(obj, sq, class)
    local groups = { all = true }

    if obj == sq:getFloor() then
        groups.floor = true
        if naturalBase(Core.getSpriteName(obj)) then
            groups.floor_natural = true
        else
            groups.floor_built = true
        end
        return groups
    end

    if class == "structural" then
        groups.furniture = true
        return groups
    elseif class ~= "wall" then
        groups.overlay = true
        return groups
    end

    groups.wall = true
    local has = Core.hasPropertyFlag
    if instanceof(obj, "IsoDoor") or (obj.isDoor and obj:isDoor()) then
        groups.door = true
    elseif instanceof(obj, "IsoWindow") then
        groups.window = true
    elseif has(obj, { "DoorWallW" }) then
        groups.doorframe_w = true
    elseif has(obj, { "DoorWallN" }) then
        groups.doorframe_n = true
    elseif has(obj, { "WindowW", "windowW" }) then
        groups.windowwall_w = true
    elseif has(obj, { "WindowN", "windowN" }) then
        groups.windowwall_n = true
    elseif has(obj, { "HoppableW", "HoppableN" }) then
        if has(obj, { "HoppableW" }) then groups.fence_w = true end
        if has(obj, { "HoppableN" }) then groups.fence_n = true end
    elseif has(obj, { "WallNW", "WallNWTrans" }) then
        groups.wall_nw = true
    elseif has(obj, { "WallW", "WallWTrans" }) then
        groups.wall_w = true
    elseif has(obj, { "WallN", "WallNTrans" }) then
        groups.wall_n = true
    elseif has(obj, { "WallSE" }) then
        groups.wall_se = true
    end
    return groups
end

--- Every sprite in an area with how often it shows up and what kind of
--- tile it is, most common first: { { sprite=, count=, kind= }, ... }
function Admin.scanArea(args)
    local area, err = Admin.normalizeArea(args)
    if not area then return nil, err end

    local bySprite = {}
    local list = {}
    forEachSquare(area, function(sq)
        local floorObj = sq:getFloor()
        for _, obj in ipairs(squareObjects(sq)) do
            local class = Core.classifyObject(obj)
            local name = class ~= "skip" and Core.getSpriteName(obj)
            if name then
                local entry = bySprite[name]
                if not entry then
                    local kind = "Overlay"
                    if obj == floorObj then
                        kind = "Floor"
                    elseif class == "wall" then
                        kind = "Wall"
                    elseif class == "structural" then
                        kind = "Furniture"
                    end
                    entry = { sprite = name, count = 0, kind = kind }
                    bySprite[name] = entry
                    list[#list + 1] = entry
                end
                entry.count = entry.count + 1
            end
        end
    end)

    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.sprite < b.sprite
    end)
    return list
end

--------------------------------------------------------------------------
-- Tile Swap: rules
--------------------------------------------------------------------------
-- A preset is { name=, chance=, rules={ rule, ... } }. chance (0-100, nil
-- = 100) is the percent of tiles in the area it touches at all. A rule is:
--   group  = id from Admin.GROUPS      } what it applies to (one of the two
--   sprite = "walls_x_01_4" / "walls_x_01_*"  } a trailing * matches a tileset)
--   action = "swap" | "overlay" | "place" | "remove"
--   sprites = { names }   one is picked at random each time. In a swap,
--                         Admin.BURNT_TILE means the tile's own burnt version
--                         (for a fence without one: the burnt fence that fits it),
--   chance = 0-100        percent of matching tiles it applies to
--   where  = nil | "inside" | "outside"
--
-- Rules run top to bottom on every tile. A tile is swapped / removed by the
-- first such rule that applies

Admin.BURNT_TILE = "@BurntTile"

Admin.ACTIONS = {
    { id = "swap", label = "Swap for" },
    { id = "overlay", label = "Add overlay on it" },
    { id = "place", label = "Place on its square" },
    { id = "remove", label = "Remove" },
}

Admin.WHERE = {
    { id = "any", label = "Anywhere" },
    { id = "inside", label = "Indoors only" },
    { id = "outside", label = "Outdoors only" },
}

local ACTION_TEXT = { swap = "swap for", overlay = "add overlay", place = "place", remove = "remove" }

--- One-line description of a rule for the rules list.
function Admin.describeRule(rule)
    local parts = {}
    parts[#parts + 1] = rule.group and Admin.groupLabel(rule.group) or tostring(rule.sprite)
    parts[#parts + 1] = "->"
    parts[#parts + 1] = ACTION_TEXT[rule.action] or tostring(rule.action)
    if rule.action ~= "remove" and rule.sprites and #rule.sprites > 0 then
        local first = rule.sprites[1]
        if first == Admin.BURNT_TILE then first = "its burnt version" end
        if #rule.sprites > 1 then
            first = first .. " (+" .. (#rule.sprites - 1) .. " more)"
        end
        parts[#parts + 1] = first
    end
    if rule.chance and rule.chance < 100 then
        parts[#parts + 1] = "[" .. rule.chance .. "%]"
    end
    if rule.where == "inside" then
        parts[#parts + 1] = "[indoors]"
    elseif rule.where == "outside" then
        parts[#parts + 1] = "[outdoors]"
    end
    return table.concat(parts, " ")
end

local function ruleMatches(rule, spriteName, groups, outside)
    if rule.where == "inside" and outside then return false end
    if rule.where == "outside" and not outside then return false end
    if rule.group then return groups[rule.group] == true end
    local wanted = rule.sprite
    if not wanted or wanted == "" then return false end
    if wanted:sub(-1) == "*" then
        return spriteName:sub(1, #wanted - 1) == wanted:sub(1, -2)
    end
    return spriteName == wanted
end

local function rollChance(rule)
    local chance = tonumber(rule.chance) or 100
    if chance >= 100 then return true end
    return ZombRand(100) < chance
end

-- fencing_burnt_01 tiles for the fences that don't name a burnt version, by
-- material and height, as { west, north, corner } lists of tile numbers
local BURNT_FENCE_TILES = {
    wood = { tall = { { 10, 11 }, { 8, 9 }, { 12 } }, low = { { 0 }, { 1 }, { 2 } } },
    wire = { tall = { { 50, 51 }, { 48, 49 }, { 52 } }, low = { { 66, 67 }, { 64, 65 }, { 68 } } },
    bars = { tall = { { 58, 59 }, { 56, 57 }, { 60 } }, low = { { 74 }, { 73 }, { 75 } } },
}

local function propValue(props, key)
    local value = props:get(key)
    return value and tostring(value) or ""
end

--- "wood", "wire" (chain-link), "bars" (any other metal), or nil for
--- anything else (stone, brick, sandbags...)
local function materialKind(value)
    if value == "MetalWire" then return "wire" end
    if value:find("Metal") then return "bars" end
    if value:find("Wood") or value == "Log" then return "wood" end
    return nil
end

--- The burnt fence that fits a fence with no burnt version of its own: same
--- material, height and side. nil when it isn't a fence or none fits.
local function burntFence(obj, props)
    local name = Core.getSpriteName(obj)
    if not name or name:sub(1, 14) == "fencing_burnt_" then return nil end

    local has = Core.hasPropertyFlag
    local tall = has(obj, { "TallHoppableW", "TallHoppableN" }) or propValue(props, "FenceTypeHigh") ~= ""
    if not tall and not has(obj, { "HoppableW", "HoppableN" }) and propValue(props, "FenceTypeLow") == "" then
        return nil
    end

    local material = propValue(props, "Material")
    local kind
    if material ~= "" then
        kind = materialKind(material)
    else
        kind = materialKind(propValue(props, "MaterialType"))
            or materialKind(propValue(props, "FenceTypeHigh"))
            or materialKind(propValue(props, "FenceTypeLow"))
    end
    if not kind then return nil end

    local west = has(obj, { "HoppableW", "TallHoppableW", "WallW", "WallWTrans" })
    local north = has(obj, { "HoppableN", "TallHoppableN", "WallN", "WallNTrans" })
    if not west and not north then return nil end
    local side = (west and north and 3) or (north and 2) or 1

    local ids = BURNT_FENCE_TILES[kind][tall and "tall" or "low"][side]
    return "fencing_burnt_01_" .. ids[ZombRand(#ids) + 1]
end

--- Random pick from a rule's sprite list
local function pickSprite(rule, obj)
    local sprites = rule.sprites
    if not sprites or #sprites == 0 then return nil end
    local name = sprites[ZombRand(#sprites) + 1]
    if name == Admin.BURNT_TILE then
        local sprite = obj:getSprite()
        local props = sprite and sprite:getProperties()
        name = props and props:get("BurntTile")
        if (not name or name == "") and props then name = burntFence(obj, props) end
    end
    if not name or name == "" or not getSprite(name) then return nil end
    return name
end

--- Gives an object another sprite where it stands (what's in it stays),
--- adding what undo needs to `records`.
local function swapInPlace(sq, obj, target, records)
    records[#records + 1] = {
        square = sq, floor = obj, oldSprite = Core.getSpriteName(obj),
        oldAttached = Core.captureAttached(obj, true, true),
    }
    obj:setSprite(getSprite(target))
    if isServer() then obj:transmitUpdatedSpriteToClients() end
end

local function hasAttached(obj, spriteName)
    local attached = Core.captureAttached(obj, true, true)
    if not attached then return false end
    for _, name in ipairs(attached) do
        if name == spriteName then return true end
    end
    return false
end

--- Runs a preset over the loaded squares of `blocks` (each { x1, y1, x2, y2 })
--- on floors z1 to z2. Adds what it did to `result` and what undo needs to
--- `applied`.
local function swapBlocks(blocks, z1, z2, preset, applied, result)
    local touched = {}
    -- percent of the tiles the preset touches at all
    local presetChance = tonumber(preset.chance) or 100

    -- Look at every tile before changing any: swapping one part of a
    -- multi-tile object (bed, 2-tile table) can take the other parts with it
    local plan = {}
    local function planSquare(sq)
        result.squares = result.squares + 1
        -- stairs stay as they are, with nothing dropped on their steps
        if sq:HasStairs() then return end
        local floorObj = sq:getFloor()
        local items = {}
        for _, obj in ipairs(squareObjects(sq)) do
            local class = Core.classifyObject(obj)
            local spriteName = class ~= "skip" and Core.getSpriteName(obj)
            -- a step the square's own flags didn't give away
            local stairs = obj.isStairsObject and obj:isStairsObject()
            if spriteName and not stairs then
                items[#items + 1] = {
                    obj = obj, class = class, spriteName = spriteName,
                    groups = Admin.objectGroups(obj, sq, class),
                    rec = obj ~= floorObj and Core.captureRecord(obj, class) or nil,
                    -- anything walked on, not just the one sq:getFloor() picks:
                    -- a flat roof laid over a floor, a second floor layer
                    standsOn = obj == floorObj or Core.hasPropertyFlag(obj, { "solidfloor" }),
                }
            end
        end
        plan[#plan + 1] = { sq = sq, items = items }
    end
    for _, block in ipairs(blocks) do
        forEachSquare({ x1 = block.x1, y1 = block.y1, x2 = block.x2, y2 = block.y2, z1 = z1, z2 = z2 }, planSquare)
    end

    local recorded = {}
    -- parts of multi-tile objects already swapped / removed with another part
    local consumed = {}
    for _, entry in ipairs(plan) do
        local sq = entry.sq
        local changed = false
        local outside = sq:isOutside()

        for _, item in ipairs(entry.items) do
            local obj, class, spriteName, groups = item.obj, item.class, item.spriteName, item.groups
            if not consumed[obj] and (presetChance >= 100 or ZombRand(100) < presetChance) then
                -- walls, floors and decals keep their object and only change
                -- sprite
                local inPlace = item.standsOn or class == "overlay"
                    or (class == "wall" and not groups.door and not groups.window)
                local replaced = false

                for _, rule in ipairs(preset.rules) do
                    if ruleMatches(rule, spriteName, groups, outside) then
                        local action = rule.action
                        if action == "swap" then
                            local target
                            if not replaced and rollChance(rule) then
                                target = pickSprite(rule, obj)
                            end
                            if target and target ~= spriteName then
                                replaced = true
                                changed = true
                                result.swapped = result.swapped + 1
                                if inPlace then
                                    swapInPlace(sq, obj, target, applied.objects)
                                else
                                    -- a multi-tile object (bed, 2-tile table) is
                                    -- swapped whole: every part goes, every part
                                    -- of the new one is placed
                                    local placements = targetPlacements(sq, target)
                                    for _, partSq in ipairs(removeWhole(sq, obj, item.rec, applied.objects, recorded, consumed)) do
                                        touched[#touched + 1] = partSq
                                    end
                                    for _, placement in ipairs(placements) do
                                        local newObj
                                        if Core.hasPropertyFlag(getSprite(placement.sprite), { "IsMoveAble" }) then
                                            newObj = Core.placeSprite(placement.sq, placement.sprite)
                                        else
                                            newObj = Core.placeOverlay(placement.sq, placement.sprite)
                                        end
                                        if newObj then
                                            applied.objects[#applied.objects + 1] = { square = placement.sq, object = newObj }
                                        end
                                        touched[#touched + 1] = placement.sq
                                    end
                                    break -- the matched object is gone
                                end
                            end
                        elseif action == "remove" then
                            -- a removed floor is a hole: that's the Tile Remover's job
                            if not replaced and not item.standsOn and rollChance(rule) then
                                for _, partSq in ipairs(removeWhole(sq, obj, item.rec, applied.objects, recorded, consumed)) do
                                    touched[#touched + 1] = partSq
                                end
                                result.removed = result.removed + 1
                                changed = true
                                break
                            end
                        elseif action == "overlay" then
                            local target = rollChance(rule) and pickSprite(rule, obj)
                            if target and not hasAttached(obj, target) then
                                applied.objects[#applied.objects + 1] = {
                                    square = sq, floor = obj, oldSprite = Core.getSpriteName(obj),
                                    oldAttached = Core.captureAttached(obj, true, true),
                                }
                                Core.applyAttached(obj, { attached = { target } })
                                result.overlays = result.overlays + 1
                                changed = true
                            end
                        elseif action == "place" then
                            local target = rollChance(rule) and pickSprite(rule, obj)
                            local newObj = target and Core.placeOverlay(sq, target)
                            if newObj then
                                applied.objects[#applied.objects + 1] = { square = sq, object = newObj }
                                result.placed = result.placed + 1
                                changed = true
                            end
                        end
                    end
                end
            end
        end

        if changed then touched[#touched + 1] = sq end
    end

    recalcSquares(touched)
end

--------------------------------------------------------------------------
-- Tile Swap: queue
--------------------------------------------------------------------------
-- A swap only reaches the part of the map that is loaded (near a player),
-- and nothing can make the game load the rest. So the area is cut into
-- blocks: the loaded ones are swapped right away, the others wait in a queue
-- saved with the world and are swapped when a player gets close enough.

local QUEUE_KEY = "AdminTools_Tiles_TileSwapQueue"
-- Squares per block side: the size of a map chunk
local BLOCK = 8
-- Most queued blocks swapped per look at the queue
local BLOCKS_PER_PASS = 60

-- job id -> its entry in the undo history, so the blocks swapped later are
-- undone with the rest of the job
local jobUndo = {}

--- { jobs = { { id=, name=, z1=, z2=, preset=, blocks={...} }, ... }, nextId= }
local function getQueue()
    local queue = ModData.getOrCreate(QUEUE_KEY)
    queue.jobs = queue.jobs or {}
    queue.nextId = queue.nextId or 1
    return queue
end

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = copyTable(v) end
    return copy
end

local function newResult()
    return { swapped = 0, overlays = 0, placed = 0, removed = 0, squares = 0, pending = 0 }
end

--- The area cut along the chunk grid: a list of { x1, y1, x2, y2 }.
local function splitBlocks(area)
    local blocks = {}
    for by = math.floor(area.y1 / BLOCK), math.floor(area.y2 / BLOCK) do
        for bx = math.floor(area.x1 / BLOCK), math.floor(area.x2 / BLOCK) do
            blocks[#blocks + 1] = {
                x1 = math.max(area.x1, bx * BLOCK), y1 = math.max(area.y1, by * BLOCK),
                x2 = math.min(area.x2, bx * BLOCK + BLOCK - 1), y2 = math.min(area.y2, by * BLOCK + BLOCK - 1),
            }
        end
    end
    return blocks
end

--- Whether a whole block is loaded. Checked on the ground floor, which every
--- loaded square has. A half-loaded block has to wait: swapping it twice
--- would roll its chances twice.
local function blockLoaded(cell, block)
    if not cell:getGridSquare(block.x1, block.y1, 0) then return false end
    for y = block.y1, block.y2 do
        for x = block.x1, block.x2 do
            if not cell:getGridSquare(x, y, 0) then return false end
        end
    end
    return true
end

--- Splits blocks into the loaded ones (`max` at most, when given) and the rest.
local function takeLoaded(blocks, max)
    local cell = getCell()
    local ready, isReady = {}, {}
    if cell then
        for i, block in ipairs(blocks) do
            if max and #ready >= max then break end
            if blockLoaded(cell, block) then
                ready[#ready + 1] = block
                isReady[i] = true
            end
        end
    end
    if #ready == 0 then return ready, blocks end

    local waiting = {}
    for i, block in ipairs(blocks) do
        if not isReady[i] then waiting[#waiting + 1] = block end
    end
    return ready, waiting
end

--- Runs a preset over an area: right away where it's loaded, the rest is
--- queued (see above).
-- @param args    { x1, y1, x2, y2, z1, z2 }
-- @param preset  { name=, rules={...} }
-- Returns { swapped=, overlays=, placed=, removed=, squares=, pending= }, or
-- nil plus a reason. `pending` is the number of blocks left in the queue.
function Admin.swapArea(args, preset)
    local area, err = Admin.normalizeArea(args)
    if not area then return nil, err end
    if type(preset) ~= "table" or type(preset.rules) ~= "table" or #preset.rules == 0 then
        return nil, "That preset has no rules."
    end

    local applied = { objects = {} }
    local result = newResult()
    local ready, waiting = takeLoaded(splitBlocks(area))
    swapBlocks(ready, area.z1, area.z2, preset, applied, result)

    if #waiting > 0 then
        local queue = getQueue()
        local job = {
            id = queue.nextId, name = tostring(preset.name), z1 = area.z1, z2 = area.z2,
            -- a copy: the admin can go on editing the preset
            preset = copyTable(preset), blocks = waiting,
        }
        queue.nextId = queue.nextId + 1
        queue.jobs[#queue.jobs + 1] = job
        applied.jobId = job.id
        jobUndo[job.id] = applied
        result.pending = #waiting
    end
    if #applied.objects > 0 or applied.jobId then
        Core.pushUndo(applied, "swap '" .. tostring(preset.name) .. "'")
    end

    Util.info("swap:", preset.name, "at", area.x1, area.y1, "->", area.x2, area.y2, "floors", area.z1, "to", area.z2,
        "-", result.swapped, "swapped,", result.overlays, "overlays,", result.placed, "placed,",
        result.removed, "removed,", result.squares, "squares loaded,", result.pending, "blocks queued")
    return result
end

--- Swaps the queued blocks that got loaded (`max` at most, BLOCKS_PER_PASS
--- when not given), and finishes the undos that were waiting for the same
--- reason.
function Admin.processQueue(max)
    -- in multiplayer the queue is the server's
    if isClient() then return end
    Core.retryPendingUndos()

    local queue = getQueue()
    if #queue.jobs == 0 then return end

    local budget = tonumber(max) or BLOCKS_PER_PASS
    local kept = {}
    for _, job in ipairs(queue.jobs) do
        local ready, waiting = takeLoaded(job.blocks, budget)
        if #ready > 0 then
            budget = budget - #ready
            local applied = jobUndo[job.id]
            if applied and applied.dropped then
                jobUndo[job.id] = nil
                applied = nil
            end
            local result = newResult()
            swapBlocks(ready, job.z1, job.z2, job.preset, applied or { objects = {} }, result)
            if applied then Core.stampUndo(applied) end
            job.blocks = waiting
            Util.info("swap queue:", job.name, "-", #ready, "blocks loaded:", result.swapped, "swapped,",
                result.overlays, "overlays,", result.placed, "placed,", result.removed, "removed,",
                #waiting, "blocks still queued")
        end
        if #job.blocks > 0 then
            kept[#kept + 1] = job
        else
            jobUndo[job.id] = nil
        end
    end
    queue.jobs = kept
end

Events.EveryOneMinute.Add(Admin.processQueue)

-- Squares per side of the part of the map one stop covers
local STOP = 64

--- Calls fn(x, y) with a square of everything that waits for its part of the
--- map to load: the queued blocks and the undos that couldn't finish.
local function forEachWaiting(fn)
    for _, job in ipairs(getQueue().jobs) do
        for _, block in ipairs(job.blocks) do fn(block.x1, block.y1) end
    end
    for _, block in ipairs(Core.pendingUndos) do fn(block[1].x, block[1].y) end
end

--- Where to stand to get everything that's waiting loaded: { { x=, y= }, ... }
function Admin.queueStops()
    local stops, seen = {}, {}
    forEachWaiting(function(x, y)
        local sx, sy = math.floor(x / STOP), math.floor(y / STOP)
        local key = sx .. "," .. sy
        if not seen[key] then
            seen[key] = true
            stops[#stops + 1] = { x = sx * STOP + STOP / 2, y = sy * STOP + STOP / 2 }
        end
    end)
    return stops
end

--- Swaps whatever is loaded now, then returns { here=, total= }: how many
--- blocks are still waiting around a stop of Admin.queueStops, and everywhere.
function Admin.processStop(stop)
    Admin.processQueue(math.huge)

    local sx, sy = math.floor(stop.x / STOP), math.floor(stop.y / STOP)
    local counts = { here = 0, total = 0 }
    forEachWaiting(function(x, y)
        counts.total = counts.total + 1
        if math.floor(x / STOP) == sx and math.floor(y / STOP) == sy then
            counts.here = counts.here + 1
        end
    end)
    return counts
end

--- Takes back the newest paste / remove / swap, one per call. A swap that
--- still had blocks in the queue stops there.
function Admin.undoLast()
    local queue = getQueue()
    local top = Core.undoStack[#Core.undoStack]
    if not top then
        local job = table.remove(queue.jobs)
        if not job then return nil, "Nothing to undo." end
        jobUndo[job.id] = nil
        return { label = "queued swap '" .. tostring(job.name) .. "'", changes = 0, deferred = 0, remaining = 0, cancelled = #job.blocks }
    end

    local cancelled = 0
    if top.jobId then
        for i, job in ipairs(queue.jobs) do
            if job.id == top.jobId then
                cancelled = #job.blocks
                table.remove(queue.jobs, i)
                break
            end
        end
        jobUndo[top.jobId] = nil
    end
    local info = Core.undoLast()
    info.cancelled = cancelled
    return info
end

--- What an undo did (see Admin.undoLast), as a line for the admin.
function Admin.describeUndo(info)
    local parts = { info.changes .. " change(s) reverted" }
    if info.deferred > 0 then
        parts[#parts + 1] = info.deferred .. " more when their area loads"
    end
    if info.cancelled > 0 then
        parts[#parts + 1] = info.cancelled .. " queued chunk(s) cancelled"
    end
    local text = "Undid " .. tostring(info.label) .. ": " .. table.concat(parts, ", ") .. "."
    if info.remaining > 0 then
        text = text .. " " .. info.remaining .. " more to undo."
    end
    return text
end

--------------------------------------------------------------------------
-- Tile Swap: presets
--------------------------------------------------------------------------

--- { "prefix_1", "prefix_2", ... } for a list of tile numbers.
local function tiles(prefix, ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = prefix .. id end
    return out
end

--- Tile numbers from..to (inclusive).
local function range(from, to)
    local out = {}
    for i = from, to do out[#out + 1] = i end
    return out
end

-- f_wallvines_1 has 6 tiles per row: 2 for west walls, 2 for north walls
-- and 2 for corners. Rows 0 to 5 unless told otherwise.
local function vines(first, fromRow, toRow)
    local ids = {}
    for row = fromRow or 0, toRow or 5 do
        ids[#ids + 1] = row * 6 + first
        ids[#ids + 1] = row * 6 + first + 1
    end
    return tiles("f_wallvines_1_", ids)
end

-- d_wallcracks_1 has 9 tiles per row: 3 for west walls, 3 for north walls
-- and 3 that fit neither.
local function cracks(first)
    local ids = {}
    for row = 0, 7 do
        for i = 0, 2 do ids[#ids + 1] = row * 9 + first + i end
    end
    return tiles("d_wallcracks_1_", ids)
end

local function tenYearsLater()
    local grime = "overlay_grime_wall_01_"
    return {
        name = "10Y Later",
        rules = {
            -- grime, facing the same way as the wall it's on
            { group = "wall_w", action = "overlay", chance = 70, sprites = tiles(grime, { 0, 16, 32 }) },
            { group = "wall_n", action = "overlay", chance = 70, sprites = tiles(grime, { 1, 17, 33 }) },
            { group = "wall_nw", action = "overlay", chance = 70, sprites = tiles(grime, { 2, 18, 34 }) },
            { group = "windowwall_w", action = "overlay", chance = 70, sprites = tiles(grime, { 8, 24 }) },
            { group = "windowwall_n", action = "overlay", chance = 70, sprites = tiles(grime, { 9, 25 }) },
            { group = "doorframe_w", action = "overlay", chance = 70, sprites = tiles(grime, { 10, 26 }) },
            { group = "doorframe_n", action = "overlay", chance = 70, sprites = tiles(grime, { 11, 27 }) },
            -- vines up the outside walls
            { group = "wall_w", action = "overlay", chance = 75, where = "outside", sprites = vines(0) },
            { group = "wall_n", action = "overlay", chance = 75, where = "outside", sprites = vines(2) },
            { group = "wall_nw", action = "overlay", chance = 75, where = "outside", sprites = vines(4) },
            { group = "windowwall_w", action = "overlay", chance = 50, where = "outside", sprites = vines(0) },
            { group = "windowwall_n", action = "overlay", chance = 50, where = "outside", sprites = vines(2) },
            { group = "doorframe_w", action = "overlay", chance = 50, where = "outside", sprites = vines(0) },
            { group = "doorframe_n", action = "overlay", chance = 50, where = "outside", sprites = vines(2) },
            -- and creeping in on some of the inside ones
            { group = "wall_w", action = "overlay", chance = 15, where = "inside", sprites = vines(0) },
            { group = "wall_n", action = "overlay", chance = 15, where = "inside", sprites = vines(2) },
            { group = "wall_nw", action = "overlay", chance = 15, where = "inside", sprites = vines(4) },
            -- dirty floors indoors, cracked pavement outdoors
            { group = "floor_built", action = "overlay", chance = 35, where = "inside",
                sprites = tiles("overlay_grime_floor_01_", range(0, 23)) },
            { group = "floor_built", action = "overlay", chance = 30, where = "outside",
                sprites = tiles("d_streetcracks_1_", range(0, 23)) },
            { group = "floor_built", action = "place", chance = 4, sprites = tiles("trash_01_", range(0, 12)) },
            { group = "floor_built", action = "place", chance = 6, where = "outside",
                sprites = tiles("d_floorleaves_1_", range(0, 11)) },
            -- nature taking the ground back
            { group = "floor_natural", action = "place", chance = 30, where = "outside",
                sprites = tiles("e_newgrass_1_", { 8, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21 }) },
            { group = "floor_natural", action = "place", chance = 12, where = "outside",
                sprites = tiles("d_plants_1_", range(0, 15)) },
        },
    }
end


local function trueTenYearsLater()
    local grime = "overlay_grime_wall_01_"
    local plants = tiles("d_plants_tyl_1_", range(5, 48))
    for _, name in ipairs(tiles("d_plants_tyl_2_", range(0, 48))) do plants[#plants + 1] = name end
    local grass = tiles("e_newgrass_1_", { 24, 27, 28, 29, 33, 34, 48, 51, 52, 53, 73, 74, 75 })
    local leaves = tiles("d_floorleaves_1_", range(0, 11))
    local trash = tiles("trash_01_", range(0, 51))
    return {
        name = "True 10Y Later",
        rules = {
            -- the house falls apart: what's removed here gets nothing below
            { group = "window", action = "remove", chance = 45 },
            { group = "door", action = "remove", chance = 35 },
            { group = "wall_w", action = "remove", chance = 5 },
            { group = "wall_n", action = "remove", chance = 5 },
            { group = "wall_nw", action = "remove", chance = 5 },
            { group = "fence_w", action = "remove", chance = 40 },
            { group = "fence_n", action = "remove", chance = 40 },
            { sprite = "roofs_*", action = "remove", chance = 10 },
            { sprite = "furniture_*", action = "remove", chance = 12 },
            { sprite = "appliances_*", action = "remove", chance = 8 },
            -- glass under the windows that are left
            { group = "window", action = "place", chance = 30, sprites = tiles("brokenglass_1_", range(0, 3)) },
            -- cracked, dirty walls
            { group = "wall_w", action = "overlay", chance = 35, sprites = cracks(0) },
            { group = "wall_n", action = "overlay", chance = 35, sprites = cracks(3) },
            { group = "wall_w", action = "overlay", chance = 85, sprites = tiles(grime, { 0, 16, 32 }) },
            { group = "wall_n", action = "overlay", chance = 85, sprites = tiles(grime, { 1, 17, 33 }) },
            { group = "wall_nw", action = "overlay", chance = 85, sprites = tiles(grime, { 2, 18, 34 }) },
            { group = "windowwall_w", action = "overlay", chance = 85, sprites = tiles(grime, { 8, 24 }) },
            { group = "windowwall_n", action = "overlay", chance = 85, sprites = tiles(grime, { 9, 25 }) },
            { group = "doorframe_w", action = "overlay", chance = 85, sprites = tiles(grime, { 10, 26 }) },
            { group = "doorframe_n", action = "overlay", chance = 85, sprites = tiles(grime, { 11, 27 }) },
            -- vines all over the outside walls, and through the holes
            { group = "wall_w", action = "overlay", chance = 75, where = "outside", sprites = vines(0, 4, 7) },
            { group = "wall_n", action = "overlay", chance = 75, where = "outside", sprites = vines(2, 4, 7) },
            { group = "wall_nw", action = "overlay", chance = 75, where = "outside", sprites = vines(4, 4, 7) },
            { group = "windowwall_w", action = "overlay", chance = 60, where = "outside", sprites = vines(0, 4, 7) },
            { group = "windowwall_n", action = "overlay", chance = 60, where = "outside", sprites = vines(2, 4, 7) },
            { group = "doorframe_w", action = "overlay", chance = 60, where = "outside", sprites = vines(0, 4, 7) },
            { group = "doorframe_n", action = "overlay", chance = 60, where = "outside", sprites = vines(2, 4, 7) },
            { group = "wall_w", action = "overlay", chance = 30, where = "inside", sprites = vines(0, 4, 7) },
            { group = "wall_n", action = "overlay", chance = 30, where = "inside", sprites = vines(2, 4, 7) },
            { group = "wall_nw", action = "overlay", chance = 30, where = "inside", sprites = vines(4, 4, 7) },
            -- indoors: filthy floors, litter, and the outside moving in
            { group = "floor_built", action = "overlay", chance = 70, where = "inside",
                sprites = tiles("overlay_grime_floor_01_", range(0, 23)) },
            { group = "floor_built", action = "place", chance = 9, where = "inside", sprites = trash },
            { group = "floor_built", action = "place", chance = 24, where = "inside", sprites = grass },
            { group = "floor_built", action = "place", chance = 8, where = "inside", sprites = leaves },
            -- outdoors: broken up roads and pavement, grass coming through
            { sprite = "blends_street_01_*", action = "overlay", chance = 30,
                sprites = tiles("blends_streetoverlays_01_", range(0, 31)) },
            { group = "floor_built", action = "overlay", chance = 45, where = "outside",
                sprites = tiles("d_streetcracks_1_", range(0, 23)) },
            { group = "floor_built", action = "place", chance = 45, where = "outside", sprites = grass },
            { group = "floor_built", action = "place", chance = 15, where = "outside", sprites = leaves },
            { group = "floor_built", action = "place", chance = 4, where = "outside", sprites = trash },
            -- nature taking the ground back
            { group = "floor_natural", action = "overlay", chance = 25, where = "outside",
                sprites = tiles("blends_dirtoverlays_01_", range(0, 31)) },
            { group = "floor_natural", action = "place", chance = 45, where = "outside", sprites = grass },
            { group = "floor_natural", action = "place", chance = 15, where = "outside", sprites = leaves },
            { group = "floor_natural", action = "place", chance = 12, where = "outside",
                sprites = tiles("d_plants_1_", range(0, 15)) },
            { group = "floor_natural", action = "place", chance = 6, where = "outside", sprites = plants },
        },
    }
end

-- fencing_01 picket fences -> the burnt picket fences (BURNT_TILE would
-- give them the plain burnt fence), facing the same way.
local BURNT_PICKET_FENCES = {
    { from = { 116, 117, 118, 119, 120 }, to = { 40, 41 } },
    { from = { 121 }, to = { 42, 43 } },
    { from = { 122 }, to = { 44 } },
    { from = { 123 }, to = { 45 } },
}

local function burnt()
    local walls = "walls_burnt_01_"
    local rules = {}
    for _, map in ipairs(BURNT_PICKET_FENCES) do
        local sprites = tiles("fencing_burnt_01_", map.to)
        for _, id in ipairs(map.from) do
            rules[#rules + 1] = { sprite = "fencing_01_" .. id, action = "swap", sprites = sprites }
        end
    end
    -- end post of the metal plate fence: no burnt version, and it isn't a
    -- wooden wall pillar
    rules[#rules + 1] = { sprite = "fencing_01_43", action = "remove" }
    -- most vanilla tiles name their own burnt version, and the fences that
    -- don't get the burnt fence that fits them (wood / metal, tall / low)
    rules[#rules + 1] = { group = "all", action = "swap", sprites = { Admin.BURNT_TILE } }
    for _, rule in ipairs({
            -- the rest falls back to the generic burnt tiles
            { group = "floor", action = "swap", sprites = { "floors_burnt_01_0" } },
            { group = "wall_w", action = "swap", sprites = { walls .. 0 } },
            { group = "wall_n", action = "swap", sprites = { walls .. 1 } },
            { group = "wall_nw", action = "swap", sprites = { walls .. 2 } },
            { group = "wall_se", action = "swap", sprites = { walls .. 3 } },
            { group = "fence_w", action = "swap", sprites = { walls .. 4 } },
            { group = "fence_n", action = "swap", sprites = { walls .. 5 } },
            { group = "windowwall_w", action = "swap", sprites = { walls .. 8 } },
            { group = "windowwall_n", action = "swap", sprites = { walls .. 9 } },
            { group = "doorframe_w", action = "swap", sprites = { walls .. 10 } },
            { group = "doorframe_n", action = "swap", sprites = { walls .. 11 } },
            { group = "door", action = "remove" },
            { group = "window", action = "remove" },
            -- a third of the furniture leaves a pile of ash, the rest is gone
            { group = "furniture", action = "swap", chance = 35, sprites = { "floors_burnt_01_1", "floors_burnt_01_2" } },
            { group = "furniture", action = "remove" },
            { group = "overlay", action = "remove" },
        }) do
        rules[#rules + 1] = rule
    end
    return { name = "Burnt", rules = rules }
end

-- Blood sheets have `perRow` tiles per row: the first half of a row is for
-- west walls, the second half for north walls.
local function blood(prefix, perRow, rows, first)
    local ids = {}
    local half = perRow / 2
    for row = 0, rows - 1 do
        for i = 0, half - 1 do ids[#ids + 1] = row * perRow + first + i end
    end
    return tiles(prefix, ids)
end

local function bloody()
    local wall = "overlay_blood_wall_01_"
    local fence = "overlay_blood_fence_01_"
    local floorIds = range(0, 27)
    for _, id in ipairs(range(32, 46)) do floorIds[#floorIds + 1] = id end
    return {
        name = "Bloody",
        rules = {
            -- splatter, facing the same way as the wall it's on
            { group = "wall_w", action = "overlay", chance = 35, sprites = blood(wall, 8, 8, 0) },
            { group = "wall_n", action = "overlay", chance = 35, sprites = blood(wall, 8, 8, 4) },
            -- corners have no tile of their own: either side can get some
            { group = "wall_nw", action = "overlay", chance = 25, sprites = blood(wall, 8, 8, 0) },
            { group = "wall_nw", action = "overlay", chance = 25, sprites = blood(wall, 8, 8, 4) },
            { group = "fence_w", action = "overlay", chance = 25, sprites = blood(fence, 8, 3, 0) },
            { group = "fence_n", action = "overlay", chance = 25, sprites = blood(fence, 8, 3, 4) },
            -- pools on the floor
            { group = "floor", action = "overlay", chance = 30, sprites = tiles("overlay_blood_floor_01_", floorIds) },
            -- bodies
            { group = "floor", action = "place", chance = 4, sprites = tiles("fear_corpses_", range(0, 31)) },
        },
    }
end

--- Fresh copies of the built-in presets.
function Admin.defaultPresets()
    return { tenYearsLater(), trueTenYearsLater(), burnt(), bloody() }
end

local function validPreset(preset)
    return type(preset) == "table" and type(preset.rules) == "table"
end

-- Shareable strings (same idea as the Tile Copy ones) ----------------------
local PRESET_FORMAT_TAG = "TSS1" -- Tile Swap Settings

--- Turns a preset into a single shareable string.
function Admin.presetToString(preset)
    if not validPreset(preset) then return nil, "nothing selected" end
    local serialized = Util.serialize(preset)
    if not serialized then return nil, "serialize failed" end
    local str = PRESET_FORMAT_TAG .. ":" .. Util.base64Encode(serialized)

    -- same self-check as the Tile Copy strings
    local check, checkErr = Admin.presetFromString(str)
    if not check then return nil, "self-check failed: " .. tostring(checkErr) end
    return str
end

--- Reverses Admin.presetToString. Returns the preset, or nil plus a reason.
function Admin.presetFromString(str)
    if not str or str == "" then return nil, "that field is empty" end
    local tagPos = str:find(PRESET_FORMAT_TAG .. ":", 1, true)
    if not tagPos then
        return nil, "not a Tile Swap string (no " .. PRESET_FORMAT_TAG .. ": prefix)"
    end
    local encoded = str:sub(tagPos + #PRESET_FORMAT_TAG + 1)
    local serialized = Util.base64Decode(encoded)
    if not serialized or serialized == "" then return nil, "base64 decode failed" end

    local preset, desErr = Util.deserialize(serialized)
    if not validPreset(preset) then
        return nil, "could not read it (truncated?): " .. tostring(desErr)
    end
    if not preset.name or preset.name == "" then preset.name = "Imported preset" end
    return preset
end

-- File persistence -----------------------------------------------------------
local PRESET_FILE = "TileSwap_Presets.txt"

function Admin.savePresets(presets)
    local writer = getFileWriter(PRESET_FILE, true, false)
    if not writer then
        Util.info("swap presets: could not open", PRESET_FILE, "for writing")
        return false
    end
    writer:write(Util.serialize(presets))
    writer:close()
    return true
end

--- The saved presets, or the built-in ones when nothing was saved yet.
function Admin.loadPresets()
    local reader = getFileReader(PRESET_FILE, false)
    if not reader then return Admin.defaultPresets() end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    if #lines == 0 then return Admin.defaultPresets() end

    local loaded, err = Util.deserialize(table.concat(lines, "\n"))
    if type(loaded) ~= "table" then
        Util.info("swap presets: parse FAILED -", err)
        return Admin.defaultPresets()
    end
    local presets = {}
    for _, preset in ipairs(loaded) do
        if validPreset(preset) then presets[#presets + 1] = preset end
    end
    if #presets == 0 then return Admin.defaultPresets() end
    return presets
end

return Admin
