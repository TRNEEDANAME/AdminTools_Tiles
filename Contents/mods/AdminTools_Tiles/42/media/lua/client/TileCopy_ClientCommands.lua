--[[
    TileCopy_ClientCommands.lua  (client)
    ]]

require "ISTileCopyUI"
require "ISTileRemoverUI"
require "ISTileSwapUI"
require "ISTileBrushUI"
require "LRZ_Shared"
require "LRZ_UI"
require "LRZ_AdderUI"
require "AdminTools_Tiles_BuildZoneMode"
require "TileCopy_Core"
require "TileAdmin_Core"

TileCopy.ClientCommands = TileCopy.ClientCommands or {}
local ClientCommands = TileCopy.ClientCommands
local Util = TileCopy.Util
local Core = TileCopy.Core
local Admin = TileCopy.Admin

TILECOPY_KEY = Keyboard.KEY_F9

-- Done bc the game kept crashing
local PASTE_CHUNK_SQUARES = 40
local pasteQueue = {}
local pasteId = 0

local function sendNextPasteChunk()
    local args = table.remove(pasteQueue, 1)
    if args then
        sendClientCommand(getPlayer(), "TileCopy", "pasteChunk", args)
    end
    if #pasteQueue == 0 then
        Events.OnTick.Remove(sendNextPasteChunk)
    end
end

local function queuePaste(data, x, y, z)
    local squares = data.squares
    local count = math.max(1, math.ceil(#squares / PASTE_CHUNK_SQUARES))
    pasteId = pasteId + 1

    local wasEmpty = #pasteQueue == 0
    for index = 1, count do
        local part = {}
        local first = (index - 1) * PASTE_CHUNK_SQUARES + 1
        for i = first, math.min(first + PASTE_CHUNK_SQUARES - 1, #squares) do
            part[#part + 1] = squares[i]
        end
        pasteQueue[#pasteQueue + 1] = {
            id = pasteId, index = index, count = count,
            name = data.name, x = x, y = y, z = z, squares = part,
        }
    end
    if wasEmpty then Events.OnTick.Add(sendNextPasteChunk) end
    Util.info("paste: sending", data.name, "-", #squares, "squares in", count, "pieces")
end

--- Tells the Zone Editor's "Building" mode how much of a paste landed:
--- `loaded` of its `total` squares were loaded.
local function showPasted(loaded, total)
    local mode = AdminTools_Tiles_BuildZoneMode.instance
    if mode then mode:onPasted(loaded, total) end
end

--- Called by the UI when the admin confirms where to paste.
function ClientCommands.requestPaste(data, x, y, z)
    if not Util.isAdmin(getPlayer()) then return end

    if isClient() then
        queuePaste(data, x, y, z)
    else
        -- Single player: we own the world, just do it now.
        local _, loaded = Core.applyArea(data, x, y, z)
        showPasted(loaded or 0, #data.squares)
    end
end

--- Tells the open Tile Admin windows what an undo did. `info` is what
--- Admin.undoLast returned, or nil plus `err`.
local function showUndone(info, err)
    local text = info and Admin.describeUndo(info) or tostring(err or "Nothing to undo.")
    local swapUI, removerUI, brushUI = ISTileSwapUI.instance, ISTileRemoverUI.instance, ISTileBrushUI.instance
    local buildMode = AdminTools_Tiles_BuildZoneMode.instance
    if swapUI then swapUI:setStatus(text, info == nil) end
    if removerUI then removerUI:setStatus(text, info == nil) end
    if brushUI then brushUI:setShownText(text) end
    if buildMode then buildMode:setStatus(text, info == nil) end
end

--- Takes back the newest paste / remove / swap. Press again for the one
--- before it.
function ClientCommands.requestUndo()
    if not Util.isAdmin(getPlayer()) then return end

    if isClient() then
        sendClientCommand(getPlayer(), "TileCopy", "undo", {})
    else
        showUndone(Admin.undoLast())
    end
end

--- Hands the outcome of a remove / swap to its window. `result` is what
--- Admin.removeArea / Admin.swapArea returned, or nil plus `err`.
local function showResult(ui, result, err)
    if ui and ui.onResult then ui:onResult(result, err) end
end

--- Called by the Tile Remover. args: see Admin.removeArea.
function ClientCommands.requestRemove(args)
    if not Util.isAdmin(getPlayer()) then return end

    if isClient() then
        sendClientCommand(getPlayer(), "TileCopy", "remove", args)
    else
        showResult(ISTileRemoverUI.instance, Admin.removeArea(args))
    end
end

--- Tells the Tile Builder window what a drag built. `result` is what
--- Admin.buildArea returned, or nil plus `err`.
local function showBuilt(result, err)
    local ui = ISTileBrushUI.instance
    if ui then ui:onBuilt(result, err) end
end

--- Called by the Tile Builder cursor. args: see Admin.buildArea.
function ClientCommands.requestBuild(args)
    if not Util.isAdmin(getPlayer()) then return end

    if isClient() then
        sendClientCommand(getPlayer(), "TileCopy", "build", args)
    else
        showBuilt(Admin.buildArea(args))
    end
end

--- Tells the Zone Editor's "Building" mode what it built. `result` is what
--- Admin.buildRoom returned, or nil plus `err`.
local function showRoomBuilt(result, err)
    local mode = AdminTools_Tiles_BuildZoneMode.instance
    if mode then mode:onRoomBuilt(result, err) end
end

--- Called by the Zone Editor's "Building" mode. args: see Admin.buildRoom.
function ClientCommands.requestBuildRoom(args)
    if not Util.isAdmin(getPlayer()) then return end

    if isClient() then
        sendClientCommand(getPlayer(), "TileCopy", "buildRoom", args)
    else
        showRoomBuilt(Admin.buildRoom(args))
    end
end

--- Called by the Tile Swap window. args: { x1, y1, x2, y2, z1, z2 }.
function ClientCommands.requestSwap(args, preset)
    if not Util.isAdmin(getPlayer()) then return end

    if isClient() then
        sendClientCommand(getPlayer(), "TileCopy", "swap", { area = args, preset = preset })
    else
        showResult(ISTileSwapUI.instance, Admin.swapArea(args, preset))
    end
end

--------------------------------------------------------------------------
-- Loading tour ("Load Queued Chunks")
--------------------------------------------------------------------------
-- The part of a swap that isn't loaded waits until a player gets near it.
-- This teleports the admin over it, stop by stop, waiting at each one until
-- what's queued around it is swapped, then brings them back.
-- The queue is the server's, shared by every admin: once the stops run out
-- the tour asks for them again, so swaps other admins queued meanwhile (in
-- other places) are loaded in the same tour, and a stop that didn't load
-- gets another go.

-- Time between two looks at the queue while standing on a stop
local STOP_WAIT_MS = 400
-- Longest stay on a stop that doesn't get loaded (the edge of the map...)
local STOP_TIMEOUT_MS = 8000
-- Most times one tour stands on the same stop
local MAX_VISITS = 2

-- { home = { x, y, z }, stops = { { x, y }, ... }, index=, arrived=,
--   nextLook=, asked=, total=, visits = { ["x,y"] = n }, wantStops= },
-- nil when no tour is running
local tour = nil

local function teleport(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    if isClient() then
        SendCommandToServer("/teleportto " .. x .. "," .. y .. "," .. z)
    else
        getPlayer():teleportTo(x, y, z)
    end
end

local function showTour(text, isError)
    local ui = ISTileSwapUI.instance
    if ui then ui:onLoadTour(text, isError, tour ~= nil) end
end

local tourTick
local beginTour

local function stopKey(stop)
    return stop.x .. "," .. stop.y
end

--- Asks for what's queued now (see beginTour).
local function requestStops()
    tour.wantStops = true
    showTour(tour.stops and "Looking for more queued chunks..." or "Looking for queued chunks...")
    if isClient() then
        sendClientCommand(getPlayer(), "TileCopy", "swapStops", {})
    else
        beginTour(Admin.queueStops())
    end
end

--- Ends the tour and brings the admin back where they started.
local function finishTour(text, isError)
    local home = tour.home
    local moved = tour.stops ~= nil
    tour = nil
    Events.OnTick.Remove(tourTick)
    if moved then teleport(home.x, home.y, home.z) end
    showTour(text, isError)
end

local function nextStop()
    tour.index = tour.index + 1
    local stop = tour.stops[tour.index]
    if not stop then
        requestStops()
        return
    end

    local key = stopKey(stop)
    tour.visits[key] = (tour.visits[key] or 0) + 1
    teleport(stop.x, stop.y, 0)
    tour.arrived = getTimestampMs()
    tour.nextLook = tour.arrived + STOP_WAIT_MS
    showTour("Loading queued chunks: stop " .. tour.index .. " of " .. #tour.stops .. "...")
end

--- `counts` is what Admin.processStop returned for the stop the admin is on.
local function onStopLooked(counts)
    if not tour or not tour.stops then return end
    tour.asked = false
    tour.total = counts.total
    local now = getTimestampMs()
    if counts.here == 0 or now - tour.arrived > STOP_TIMEOUT_MS then
        nextStop()
    else
        tour.nextLook = now + STOP_WAIT_MS
    end
end

tourTick = function()
    if not tour or tour.wantStops or tour.asked or getTimestampMs() < tour.nextLook then return end
    local stop = tour.stops[tour.index]
    if isClient() then
        tour.asked = true
        sendClientCommand(getPlayer(), "TileCopy", "swapLoadStop", stop)
    else
        onStopLooked(Admin.processStop(stop))
    end
end

--- `stops` is what Admin.queueStops returned: everything queued, by every
--- admin. Goes over the ones this tour hasn't stood on MAX_VISITS times yet,
--- or ends the tour when there are none.
beginTour = function(stops)
    if not tour or not tour.wantStops then return end
    tour.wantStops = false
    stops = stops or {}

    local todo = {}
    for _, stop in ipairs(stops) do
        if (tour.visits[stopKey(stop)] or 0) < MAX_VISITS then todo[#todo + 1] = stop end
    end
    if #todo == 0 then
        if not tour.stops then
            finishTour("Nothing is waiting to load.")
        elseif #stops > 0 then
            finishTour((tour.total or 0) .. " chunk(s) didn't load in time and are still queued. Press it again to retry.", true)
        else
            finishTour("Done: everything that was queued is swapped.")
        end
        return
    end

    if not tour.stops then Events.OnTick.Add(tourTick) end
    tour.stops = todo
    tour.index = 0
    nextStop()
end

--- Called by the Tile Swap window: starts the tour, or stops the one running.
function ClientCommands.toggleLoadTour()
    local player = getPlayer()
    if not Util.isAdmin(player) then return end

    if tour then
        finishTour("Stopped. What's left stays queued.")
        return
    end

    tour = { home = { x = player:getX(), y = player:getY(), z = player:getZ() }, visits = {} }
    requestStops()
end

local function onServerCommand(module, command, args)
    if module ~= "TileCopy" then return end
    -- The server already placed/removed the objects and synced them to
    -- every client, so these are just confirmations - never re-apply here.
    if command == "pasted" then
        Util.log("server confirmed", command)
        showPasted(args.loaded or 0, args.total or 0)
    elseif command == "roomBuilt" then
        showRoomBuilt(args.result, args.error)
    elseif command == "undone" then
        showUndone(args.info, args.error)
    elseif command == "removed" then
        showResult(ISTileRemoverUI.instance, args.result, args.error)
    elseif command == "built" then
        showBuilt(args.result, args.error)
    elseif command == "swapped" then
        showResult(ISTileSwapUI.instance, args.result, args.error)
    elseif command == "swapStops" then
        beginTour(args.stops)
    elseif command == "swapStopLoaded" then
        onStopLooked(args)
    elseif command == "denied" then
        if tour then finishTour("The server rejected that request.", true) end
        if getPlayer() then
            getPlayer():Say("Tile Admin: server rejected that request (admin check failed).")
        end
    end
end
Events.OnServerCommand.Add(onServerCommand)

local function onKeyStartPressed(key)
    if key == TILECOPY_KEY then
        ISTileCopyUI.toggle()
    end
end
Events.OnKeyStartPressed.Add(onKeyStartPressed)

local function openLootRemover()
    LRZ_UI.open()
end

-- The Loot Filler takes its area from the Loot Remover window, so both open
local function openLootFiller()
    LRZ_AdderUI.open(LRZ_UI.open())
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    -- The tile and loot tools have their own allowed access levels
    local tiles, loot = Util.isAdmin(playerObj), LRZ.CanUse(playerObj)
    if not tiles and not loot then return end

    local option = context:addOption("Admin Tools", worldobjects, nil)
    local subMenu = ISContextMenu:getNew(context)
    context:addSubMenu(option, subMenu)
    if tiles then
        subMenu:addOption("Tile Copy", nil, ISTileCopyUI.toggle)
        subMenu:addOption("Tile Remover", nil, ISTileRemoverUI.open)
        subMenu:addOption("Tile Swap", nil, ISTileSwapUI.open)
        subMenu:addOption("Tile Brush", nil, ISTileBrushUI.open)
        subMenu:addOption("Tile Builder", true, ISTileBrushUI.open)
    end
    if loot then
        subMenu:addOption("Loot Remover", nil, openLootRemover)
        subMenu:addOption("Loot Filler", nil, openLootFiller)
    end
    -- in multiplayer it's in the Admin Panel; single player has no such panel
    if not isClient() then
        subMenu:addOption("Zone Editor", nil, ISMultiplayerZoneEditor.ShowEditor)
    end
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
