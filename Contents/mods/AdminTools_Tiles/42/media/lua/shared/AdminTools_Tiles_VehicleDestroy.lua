--[[
    AdminTools_Tiles_VehicleDestroy.lua  (shared)

    Wrecks a vehicle: the admin "Destroy Vehicle..." option (see
    AdminTools_Tiles_VehicleDestroyUI). Runs on the server, or directly in single player.
]]

require "AdminTools_Tiles_Util"

AdminTools_Tiles_VehicleDestroy = AdminTools_Tiles_VehicleDestroy or {}
local Destroy = AdminTools_Tiles_VehicleDestroy

Destroy.ModuleName = "AdminTools_Tiles_VehicleDestroy"
Destroy.CMD_DESTROY = "Destroy"
Destroy.RES_DESTROYED = "Destroyed"
Destroy.RES_DENIED = "Denied"

Destroy.DEFAULT_PERCENT = 50

--- Whole percent between 1 and 100, or nil when `value` isn't a number.
function Destroy.clampPercent(value)
    local percent = tonumber(value)
    if not percent then return nil end
    return AdminTools_Tiles_Util.clamp(math.floor(percent), 1, 100)
end

--- Whether the part's item can be thrown away: it has one, and no loot in it.
local function canRemove(part)
    if not part:getInventoryItem() then return false end
    local container = part:getItemContainer()
    return not container or container:getItems():size() == 0
end

--- Takes the part's item off the vehicle, as the end of an uninstall does.
local function removePart(vehicle, part)
    local item = part:getInventoryItem()
    part:setInventoryItem(nil)
    local uninstall = part:getTable("uninstall")
    if uninstall and uninstall.complete then
        VehicleUtils.callLua(uninstall.complete, vehicle, part, item)
    end
    vehicle:transmitPartItem(part)
end

--- Lowers the part's condition by `points`. Returns false when it was
--- already at 0.
local function damagePart(vehicle, part, points)
    local condition = part:getCondition()
    if condition <= 0 then return false end
    condition = math.max(0, condition - points)

    part:setCondition(condition)
    local item = part:getInventoryItem()
    if item then
        item:setCondition(condition)
        part:doInventoryItemStats(item, part:getMechanicSkillInstaller())
    end
    vehicle:transmitPartCondition(part)
    return true
end

--- Wrecks `percent` % of the vehicle with that id. Returns
--- { removed=, damaged= } (numbers of parts), or nil plus a reason.
function Destroy.destroyVehicle(vehicleId, percent)
    percent = Destroy.clampPercent(percent)
    local vehicle = getVehicleById(tonumber(vehicleId) or -1)
    if not vehicle or not percent then
        return nil, "That vehicle isn't there anymore."
    end

    local result = { removed = 0, damaged = 0 }
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if ZombRand(100) < percent then
            if ZombRand(100) < percent and canRemove(part) then
                removePart(vehicle, part)
                result.removed = result.removed + 1
            elseif damagePart(vehicle, part, ZombRand(math.ceil(percent / 2), percent + 1)) then
                result.damaged = result.damaged + 1
            end
        end
    end

    vehicle:updatePartStats()
    vehicle:updateBulletStats()
    return result
end
