-- LRZ_Client.lua
-- The Loot Remover window (LRZ_UI) and the Loot Adder (LRZ_AdderUI) are opened
-- from the right-click "Tile Admin" menu (see TileCopy_ClientCommands).
-- Server replies are routed back to them here.

require "LRZ_Shared"
require "LRZ_UI"
require "LRZ_AdderUI"
require "LRZ_ZoneEditorMode"

local function chat(msg)
    local player = getPlayer()
    if not player then return end
    player:setHaloNote(msg)
end

local function onServerCommand(module, command, args)
    if module ~= LRZ.ModuleName then return end
    local ui = LRZ_UI.instance
    local editorMode = LRZ_ZoneEditorMode.instance
    local adder = LRZ_AdderUI.instance

    if command == LRZ.RES_ADDED then
        if adder then adder:onAdded(args) end
        if not args.error then
            chat("Loot adding complete: " .. tostring(args.added) .. " item(s) added.")
        end
    elseif command == LRZ.RES_DONE then
        chat("Loot removal complete: " .. tostring(args.removed) .. " item(s) removed.")
        local msg, isError = "Removed " .. tostring(args.removed) .. " item(s) from " .. tostring(args.containers) .. " container(s)", false
        if args.ground then
            msg = msg .. " and the ground"
        end
        msg = msg .. "."
        if args.containers == 0 and (args.ground or 0) == 0 then
            msg, isError = "Nothing found - is the area loaded (near a player)?", true
        end
        if ui then ui:setStatus(msg, isError) end
        if editorMode then editorMode:setStatus(msg, isError) end
    elseif command == LRZ.RES_SCAN then
        if ui then ui:onScanResult(args) end
    elseif command == LRZ.RES_CONTAINERS then
        if adder then adder:onContainerTypes(args) end
    elseif command == LRZ.RES_TOO_BIG then
        local msg = "Area too big: " .. tostring(args.squares) .. " squares (max " .. tostring(args.max) .. ")"
        chat(msg)
        if ui then ui:setStatus(msg, true) end
        if editorMode then editorMode:setStatus(msg, true) end
        if adder then adder:setStatus(msg, true) end
    elseif command == LRZ.RES_DENIED then
        chat("You do not have permission to use loot removal zones.")
        if adder then adder:setStatus("Permission denied.", true) end
    end
end

Events.OnServerCommand.Add(onServerCommand)
