--[[
    TileCopy_ServerCommands.lua  (server)

    Receives paste / remove / swap requests from clients, re-checks admin rights on the
    authoritative side (never trust the client, they always lie), and if valid, applies the
    change server-side. Core.applyArea/undoLast transmit every object they
    add/remove to all clients themselves
]]

require "TileCopy_Core"
require "TileAdmin_Core"

local Util = TileCopy.Util
local Core = TileCopy.Core
local Admin = TileCopy.Admin

-- A paste arrives in pieces (a big area doesn't fit in one packet), in
-- order. They're collected here per player and applied once the last one
-- is in.
local pendingPastes = {}

local function receivePasteChunk(playerObj, args)
    local key = playerObj:getUsername()
    local pending = pendingPastes[key]
    if args.index == 1 then
        pending = { id = args.id, received = 0, squares = {} }
        pendingPastes[key] = pending
    end
    if not pending or pending.id ~= args.id or args.index ~= pending.received + 1 then
        Util.info("paste: piece", args.index, "of", args.count, "from", key, "out of order - paste dropped")
        pendingPastes[key] = nil
        return
    end

    pending.received = args.index
    for _, entry in ipairs(args.squares) do
        pending.squares[#pending.squares + 1] = entry
    end
    if args.index < args.count then return end

    pendingPastes[key] = nil
    local _, loaded = Core.applyArea({ name = args.name, squares = pending.squares }, args.x, args.y, args.z)
    sendServerCommand(playerObj, "TileCopy", "pasted", { loaded = loaded or 0, total = #pending.squares })
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= "TileCopy" then return end

    if command == "pasteChunk" then
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end
        if not args or not args.squares then return end

        receivePasteChunk(playerObj, args)
    elseif command == "undo" then
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end

        local info, err = Admin.undoLast()
        sendServerCommand(playerObj, "TileCopy", "undone", { info = info, error = err })
    elseif command == "remove" or command == "swap" then
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end
        if not args then return end

        local result, err
        if command == "remove" then
            result, err = Admin.removeArea(args)
            sendServerCommand(playerObj, "TileCopy", "removed", { result = result, error = err })
        else
            result, err = Admin.swapArea(args.area, args.preset)
            sendServerCommand(playerObj, "TileCopy", "swapped", { result = result, error = err })
        end
    elseif command == "build" then
        -- the Tile Builder: one tile over a dragged line / area
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end
        if not args then return end

        local result, err = Admin.buildArea(args)
        sendServerCommand(playerObj, "TileCopy", "built", { result = result, error = err })
    elseif command == "buildRoom" then
        -- the Zone Editor's "Building" mode: floor and walls of a room
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end
        if not args then return end

        local result, err = Admin.buildRoom(args)
        sendServerCommand(playerObj, "TileCopy", "roomBuilt", { result = result, error = err })
    elseif command == "swapStops" or command == "swapLoadStop" then
        -- "Load Queued Chunks": the admin's client teleports them around, the
        -- queue is looked at here each time they land
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end

        if command == "swapStops" then
            sendServerCommand(playerObj, "TileCopy", "swapStops", { stops = Admin.queueStops() })
        elseif args and tonumber(args.x) and tonumber(args.y) then
            sendServerCommand(playerObj, "TileCopy", "swapStopLoaded", Admin.processStop(args))
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
