--[[
    LRZ_ItemLists.lua  (client)

    Item lists for the Loot Filler: a whitelist (only those items may be
    added) or a blacklist (those never are), picked in its window and sent
    with the request (see LRZ.AllowedFilter).
      { name=, mode = LRZ.LIST_WHITELIST / LRZ.LIST_BLACKLIST, items = { entry, ... } }
    Entries are full types ("Base.Axe"), bare names ("Axe", any module) or a
    whole module ("SWMG.*"), see LRZ.ItemMatcher.
    Saved to disk every time they change, and shared as a string like the
    Tile Swap presets ("Export" / "Import").
]]

require "LRZ_Shared"
require "TileCopy_Util"

LRZ_ItemLists = LRZ_ItemLists or {}
local Lists = LRZ_ItemLists
local Util = TileCopy.Util

--------------------------------------------------------------------------
-- Built-in lists
--------------------------------------------------------------------------

local function inModule(module, names)
    local items = {}
    for _, name in ipairs(names) do
        items[#items + 1] = module .. "." .. name
    end
    return items
end

local function military()
    return {
        name = "Military",
        mode = LRZ.LIST_WHITELIST,
        items = inModule("Base", {
            -- guns: M16, M14, shotguns, sniper / hunting rifles, service pistols
            "AssaultRifle", "AssaultRifle2", "JS14_Rifle", "MSR7T_Rifle", "HuntingRifle",
            "Shotgun", "ShotgunSawnoff", "JS3T_Shotgun", "DoubleBarrelShotgun",
            "Pistol", "Pistol2",
            -- ammo and magazines
            "556Bullets", "556Box", "556Carton", "556Clip", "JS14_Clip",
            "308Bullets", "308Box", "308Carton", "M14Clip",
            "ShotgunShells", "ShotgunShellsBox", "ShotgunShellsCarton",
            "Bullets9mm", "Bullets9mmBox", "Bullets9mmCarton", "9mmClip",
            "Bullets45", "Bullets45Box", "Bullets45Carton", "45Clip",
            -- weapon parts
            "x2Scope", "x4Scope", "x8Scope", "RedDot", "Laser", "GunLight", "TritiumSights",
            "RecoilPad", "AmmoStraps", "ChokeTubeFull", "ChokeTubeImproved",
            -- headwear
            "Hat_Army", "Hat_ArmyDesert", "Hat_ArmyDesertNew", "Hat_BeretArmy",
            "Hat_PeakedCapArmy", "Hat_BaseballCapArmy", "Hat_GasMask",
            -- uniforms
            "Jacket_ArmyCamoGreen", "Jacket_ArmyCamoDesert", "Jacket_ArmyCamoDesertNew",
            "Jacket_ArmyCamoUrban", "Jacket_ArmyCamoMilius", "Jacket_ArmyCamoTigerStripe",
            "Jacket_ArmyOliveDrab", "Jacket_CoatArmy",
            "Shirt_CamoGreen", "Shirt_CamoDesert", "Shirt_CamoDesertNew", "Shirt_CamoUrban",
            "Shirt_CamoMilius", "Shirt_CamoTigerStripe",
            "Tshirt_ArmyGreen", "Tshirt_CamoGreen", "Tshirt_CamoDesert", "Tshirt_CamoDesertNew",
            "Tshirt_CamoUrban",
            "Trousers_ArmyService", "Trousers_CamoGreen", "Trousers_CamoDesert",
            "Trousers_CamoDesertNew", "Trousers_CamoUrban", "Trousers_CamoMilius",
            "Trousers_CamoTigerStripe",
            "Shoes_ArmyBoots", "Shoes_ArmyBootsDesert",
            -- armour
            "Vest_BulletArmy", "Vest_BulletDesert", "Vest_BulletDesertNew", "Vest_BulletOliveDrab",
            "Kneepad_Left_Military", "Kneepad_Right_Military",
            "ElbowPad_Left_Military", "ElbowPad_Right_Military",
            "GreaveBodyArmour_Left_Army", "GreaveBodyArmour_Right_Army",
            "ThighBodyArmour_L_Army", "ThighBodyArmour_R_Army",
            "Vambrace_BodyArmour_Left_Army", "Vambrace_BodyArmour_Right_Army",
            -- bags, holsters and kit
            "Bag_ALICEpack", "Bag_ALICEpack_Army", "Bag_ALICEpack_DesertCamo",
            "Bag_ALICE_BeltSus", "Bag_ALICE_BeltSus_Camo", "Bag_ALICE_BeltSus_Green",
            "Bag_Military", "Bag_Satchel_Military",
            "HolsterSimple", "HolsterDouble", "HolsterShoulder",
            "AmmoStrap_Bullets", "AmmoStrap_Bullets_308",
            "CanteenMilitary", "CanteenMilitaryFull", "FirstAidKit_Military",
            "FlashLight_AngleHead_Army",
        }),
    }
end

-- The ammo of the Gunworks Gang framework (workshop 3722064198,
-- AmmunitionLibrary/ammo.txt)
local function gunworksAmmo()
    return {
        name = "Gunworks ammo",
        mode = LRZ.LIST_BLACKLIST,
        items = inModule("SWMG", {
            "12Gauge_Shell_Buckshot", "12Gauge_Shell_Slug",
            "9x19_Bullet", "45_Bullet", "38_Bullet", "44_Bullet", "50_Bullet",
            "762x51_Bullet", "308_Bullet", "762x54_Bullet",
            "556x45_Bullet", "556x45_Bullet_HollowPoint", "556x45_Bullet_ArmorPiercing",
            "556x45_Bullet_Subsonic", "556x45_Bullet_Overpressured",
            "223_Bullet", "545x39_Bullet", "762x39_Bullet", "9x39_Bullet",
            "3006_Bullet", "3030_Bullet", "357_Bullet", "4570_Bullet",
            "40mm_Round_Buckshot", "40mm_Round_HE", "40mm_Round_Incendiary",
            "Rocket_PG7V", "2Bore_Bullet",
        }),
    }
end

local function survivor()
    return {
        name = "Survivor",
        mode = LRZ.LIST_WHITELIST,
        items = inModule("Base", {
            -- melee weapons
            "Axe", "WoodAxe", "HandAxe", "BaseballBat", "BaseballBat_Nails", "BaseballBat_Metal",
            "Crowbar", "Hammer", "ClubHammer", "Machete", "HuntingKnife", "KitchenKnife",
            "MeatCleaver", "PipeWrench", "LeadPipe", "MetalPipe", "Nightstick", "Shovel",
            "Sledgehammer", "SpearCrafted", "Golfclub", "TireIron", "Wrench", "Pan",
            -- canned food and water
            "TinnedBeans", "TinnedSoup", "TunaTin", "Dogfood", "CannedBolognese",
            "CannedCarrots2", "CannedChili", "CannedCornedBeef", "CannedCorn",
            "CannedFruitCocktail", "CannedMilk", "CannedMushroomSoup", "CannedPeaches",
            "CannedPeas", "CannedPineapple", "CannedPotato2", "CannedSardines",
            "CannedTomato2", "CannedFruitBeverage", "WaterRationCan", "TinOpener",
            "WaterBottle", "GranolaBar", "Crisps", "Cereal", "DriedBlackBeans",
            -- a few civilian guns and their ammo
            "Pistol", "Revolver", "Revolver_Short", "Shotgun", "DoubleBarrelShotgun",
            "HuntingRifle", "VarmintRifle",
            "Bullets9mm", "Bullets9mmBox", "9mmClip", "Bullets38", "Bullets38Box",
            "Bullets357", "Bullets357Box", "ShotgunShells", "ShotgunShellsBox",
            "308Bullets", "308Box", "556Bullets", "556Box",
            -- medical
            "Bandage", "Pills", "Disinfectant", "AlcoholWipes", "Antibiotics",
            "SutureNeedle", "Needle", "Thread", "FirstAidKit",
            -- tools and bags
            "Lighter", "Matches", "HandTorch", "Battery", "DuctTape", "Rope", "Saw",
            "Screwdriver", "Nails",
            "Bag_Schoolbag", "Bag_NormalHikingBag", "Bag_DuffelBag",
        }),
    }
end

-- Raise this whenever a built-in list changes: saved copies from an older
-- version are then replaced by the new ones (see Lists.load).
local BUILTIN_VERSION = 1

--- Fresh copies of the built-in lists.
function Lists.defaults()
    local lists = { military(), gunworksAmmo(), survivor() }
    for _, list in ipairs(lists) do list.builtin = BUILTIN_VERSION end
    return lists
end

local function validList(list)
    return type(list) == "table" and type(list.items) == "table"
end

--- `list` with a usable name and mode (blacklist unless it says whitelist).
local function normalise(list)
    if not list.name or list.name == "" then list.name = "Imported list" end
    if list.mode ~= LRZ.LIST_WHITELIST then list.mode = LRZ.LIST_BLACKLIST end
    return list
end

--- "Military (whitelist, 120 items)"
function Lists.describe(list)
    return string.format("%s (%s, %d items)", tostring(list.name), tostring(list.mode), #list.items)
end

--- What goes with a request: { mode, items }.
function Lists.toRequest(list)
    local items = {}
    for i, entry in ipairs(list.items) do items[i] = entry end
    return { mode = list.mode, items = items }
end

--------------------------------------------------------------------------
-- Shareable strings (same idea as the Tile Swap presets)
--------------------------------------------------------------------------

local FORMAT_TAG = "LIL1" -- Loot Item List

--- Turns a list into a single shareable string.
function Lists.toString(list)
    if not validList(list) then return nil, "nothing selected" end
    local serialized = Util.serialize({ name = list.name, mode = list.mode, items = list.items })
    if not serialized then return nil, "serialize failed" end
    local str = FORMAT_TAG .. ":" .. Util.base64Encode(serialized)

    -- same self-check as the Tile Copy strings
    local check, checkErr = Lists.fromString(str)
    if not check then return nil, "self-check failed: " .. tostring(checkErr) end
    return str
end

--- Reverses Lists.toString. Returns the list, or nil plus a reason.
function Lists.fromString(str)
    if not str or str == "" then return nil, "that field is empty" end
    local tagPos = str:find(FORMAT_TAG .. ":", 1, true)
    if not tagPos then
        return nil, "not an item list string (no " .. FORMAT_TAG .. ": prefix)"
    end
    local serialized = Util.base64Decode(str:sub(tagPos + #FORMAT_TAG + 1))
    if not serialized or serialized == "" then return nil, "base64 decode failed" end

    local list, desErr = Util.deserialize(serialized)
    if not validList(list) then
        return nil, "could not read it (truncated?): " .. tostring(desErr)
    end
    list.builtin = nil
    return normalise(list)
end

--------------------------------------------------------------------------
-- File persistence
--------------------------------------------------------------------------

local LIST_FILE = "LRZ_ItemLists.txt"

function Lists.save(lists)
    local writer = getFileWriter(LIST_FILE, true, false)
    if not writer then
        Util.info("item lists: could not open", LIST_FILE, "for writing")
        return false
    end
    writer:write(Util.serialize(lists))
    writer:close()
    return true
end

--- The saved lists, or the built-in ones when nothing was saved yet.
function Lists.load()
    local reader = getFileReader(LIST_FILE, false)
    if not reader then return Lists.defaults() end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    if #lines == 0 then return Lists.defaults() end

    local loaded, err = Util.deserialize(table.concat(lines, "\n"))
    if type(loaded) ~= "table" then
        Util.info("item lists: parse FAILED -", err)
        return Lists.defaults()
    end
    local defaults = {}
    for _, list in ipairs(Lists.defaults()) do defaults[list.name] = list end
    local lists = {}
    for _, list in ipairs(loaded) do
        if validList(list) then
            -- a built-in saved before it last changed: take the new one
            local default = defaults[list.name]
            local outdated = default and list.builtin and list.builtin ~= BUILTIN_VERSION
            lists[#lists + 1] = outdated and default or normalise(list)
        end
    end
    -- an empty file is fine: the admin deleted every list
    return lists
end

return Lists
