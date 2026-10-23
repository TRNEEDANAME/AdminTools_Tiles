--[[
    AdminTools_Tiles_VehicleDestroyUI.lua  (client)

    Admin "Destroy Vehicle..." option of a vehicle's right-click menu, and
    its window: a slider for how much of the vehicle to wreck and a
    "Destroy" button. Each press wrecks some more (see AdminTools_Tiles_VehicleDestroy).
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "RadioCom/ISUIRadio/ISSliderPanel"
require "TileCopy_Util"
require "AdminTools_Tiles_UIUtil"
require "AdminTools_Tiles_VehicleDestroy"

AdminTools_Tiles_VehicleDestroyUI = ISCollapsableWindow:derive("AdminTools_Tiles_VehicleDestroyUI")
AdminTools_Tiles_VehicleDestroyUI.instance = nil

local Util = TileCopy.Util
local Destroy = AdminTools_Tiles_VehicleDestroy

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BTN_H = FONT_HGT_SMALL + 6
local PADDING = 10
local WIDTH = 320
local SLIDER_H = 18

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

function AdminTools_Tiles_VehicleDestroyUI:new()
    local height = 160
    local x = (getCore():getScreenWidth() / 2) - (WIDTH / 2)
    local y = (getCore():getScreenHeight() / 2) - (height / 2)

    local o = ISCollapsableWindow:new(x, y, WIDTH, height)
    setmetatable(o, self)
    self.__index = self

    o.title = "Destroy Vehicle"
    o:setResizable(false)
    o.vehicle = nil
    return o
end

function AdminTools_Tiles_VehicleDestroyUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local y = self:titleBarHeight() + PADDING

    self.vehicleLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.vehicleLabel)
    y = y + FONT_HGT_SMALL + PADDING

    self.percentLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.percentLabel)
    y = y + FONT_HGT_SMALL + 4

    self.slider = ISSliderPanel:new(PADDING, y, WIDTH - PADDING * 2, SLIDER_H, self, AdminTools_Tiles_VehicleDestroyUI.onPercentChanged)
    self.slider:initialise()
    self.slider:instantiate()
    self.slider:setValues(1, 100, 1, 10)
    self.slider:setCurrentValue(Destroy.DEFAULT_PERCENT)
    self:addChild(self.slider)
    y = y + SLIDER_H + PADDING

    local btnW = (WIDTH - PADDING * 3) / 2
    self.destroyBtn = ISButton:new(PADDING, y, btnW, BTN_H, "Destroy", self, AdminTools_Tiles_VehicleDestroyUI.onDestroy)
    self.destroyBtn:initialise()
    self.destroyBtn:setTooltip("Tears off / damages a random part of the vehicle. Press again for more.")
    self:addChild(self.destroyBtn)

    self.closeBtn = ISButton:new(PADDING * 2 + btnW, y, btnW, BTN_H, "Close", self, AdminTools_Tiles_VehicleDestroyUI.close)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
    y = y + BTN_H + 6

    self.statusLabel = ISLabel:new(PADDING, y, FONT_HGT_SMALL, "", 0.6, 1, 0.6, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)
    y = y + FONT_HGT_SMALL + PADDING

    self:setHeight(y)
end

function AdminTools_Tiles_VehicleDestroyUI:onPercentChanged(value)
    self.percentLabel:setName("Destruction: " .. value .. "%")
end

function AdminTools_Tiles_VehicleDestroyUI:setVehicle(vehicle)
    self.vehicle = vehicle
    self.vehicleLabel:setName(getText("IGUI_VehicleName" .. vehicle:getScript():getName()))
    self:setStatus("")
end

function AdminTools_Tiles_VehicleDestroyUI:onDestroy()
    local player = getPlayer()
    if not self.vehicle or not Util.isAdmin(player) then return end

    local vehicleId = self.vehicle:getId()
    local percent = self.slider:getCurrentValue()
    if isClient() then
        self:setStatus("Destroying...")
        sendClientCommand(player, Destroy.ModuleName, Destroy.CMD_DESTROY, { vehicle = vehicleId, percent = percent })
    else
        self:onResult(Destroy.destroyVehicle(vehicleId, percent))
    end
end

--- Outcome of the last press (see AdminTools_Tiles_VehicleDestroy.destroyVehicle), or
--- nil plus a reason.
function AdminTools_Tiles_VehicleDestroyUI:onResult(result, err)
    if not result then
        self:setStatus(tostring(err or "Destroy failed."), true)
        return
    end
    self:setStatus("Removed " .. result.removed .. ", damaged " .. result.damaged .. " part(s).")
end

function AdminTools_Tiles_VehicleDestroyUI:setStatus(text, isError)
    AdminTools_Tiles_UIUtil.setStatus(self.statusLabel, text, isError)
end

function AdminTools_Tiles_VehicleDestroyUI:close()
    self:setVisible(false)
end

function AdminTools_Tiles_VehicleDestroyUI.open(vehicle)
    if not vehicle or not Util.isAdmin(getPlayer()) then return end

    if not AdminTools_Tiles_VehicleDestroyUI.instance then
        local ui = AdminTools_Tiles_VehicleDestroyUI:new()
        ui:initialise()
        ui:addToUIManager()
        AdminTools_Tiles_VehicleDestroyUI.instance = ui
    else
        AdminTools_Tiles_VehicleDestroyUI.instance:setVisible(true)
    end
    AdminTools_Tiles_VehicleDestroyUI.instance:setVehicle(vehicle)
    AdminTools_Tiles_VehicleDestroyUI.instance:bringToTop()
    return AdminTools_Tiles_VehicleDestroyUI.instance
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function onServerCommand(module, command, args)
    if module ~= Destroy.ModuleName then return end
    local ui = AdminTools_Tiles_VehicleDestroyUI.instance
    if not ui then return end

    if command == Destroy.RES_DESTROYED then
        ui:onResult(args.result, args.error)
    elseif command == Destroy.RES_DENIED then
        ui:setStatus("The server rejected that request (admin check failed).", true)
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- Same vehicle as the vanilla menu: the one the player is in, or the one
-- under the mouse
local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not Util.isAdmin(player) then return end

    local vehicle = player:getVehicle() or IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
    if not vehicle then return end

    context:addOption("Destroy Vehicle...", vehicle, AdminTools_Tiles_VehicleDestroyUI.open)
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
