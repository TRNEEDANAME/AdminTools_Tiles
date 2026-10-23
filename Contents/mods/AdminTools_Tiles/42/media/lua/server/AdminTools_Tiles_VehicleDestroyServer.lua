--[[
    AdminTools_Tiles_VehicleDestroyServer.lua  (server)

    Receives the "Destroy Vehicle..." requests, re-checks admin rights and
    wrecks the vehicle (see AdminTools_Tiles_VehicleDestroy).
]]

require "TileCopy_Util"
require "AdminTools_Tiles_VehicleDestroy"

local Util = TileCopy.Util
local Destroy = AdminTools_Tiles_VehicleDestroy

local function onClientCommand(module, command, playerObj, args)
    if module ~= Destroy.ModuleName or command ~= Destroy.CMD_DESTROY then return end

    if not Util.isAdmin(playerObj) then
        sendServerCommand(playerObj, Destroy.ModuleName, Destroy.RES_DENIED, {})
        return
    end
    if not args then return end

    local result, err = Destroy.destroyVehicle(args.vehicle, args.percent)
    sendServerCommand(playerObj, Destroy.ModuleName, Destroy.RES_DESTROYED, { result = result, error = err })
end

Events.OnClientCommand.Add(onClientCommand)
