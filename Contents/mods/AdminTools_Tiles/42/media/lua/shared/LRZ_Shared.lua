-- LRZ_Shared.lua
-- Shared constants/helpers for the Loot Removal Zones mod (remover + adder).
-- Loaded on both client and server.

require "AdminTools_Tiles_Util"

LRZ = LRZ or {}
LRZ.ModuleName = "LRZ"

-- Client -> Server command names
LRZ.CMD_REMOVE_LOOT = "removeLoot"   -- bulk: % of the checked categories
LRZ.CMD_SCAN = "scanLoot"            -- breakdown: list every item type in the zone
LRZ.CMD_APPLY_EDITS = "applyEdits"   -- breakdown: set per-item target amounts
LRZ.CMD_ADD_LOOT = "addLoot"         -- adder: add picked items or reroll vanilla loot
LRZ.CMD_SCAN_CONTAINERS = "scanContainers" -- adder: list the container types in the zone

-- Server -> Client command names
LRZ.RES_DONE = "done"
LRZ.RES_DENIED = "denied"
LRZ.RES_SCAN = "scanResult"
LRZ.RES_TOO_BIG = "tooBig"
LRZ.RES_ADDED = "added"
LRZ.RES_CONTAINERS = "containerTypes"

-- Loot adder sources
LRZ.SOURCE_ITEMS = "items"     -- the item types / amounts the admin picked
LRZ.SOURCE_REROLL = "reroll"   -- vanilla loot tables, like the admin "Refill container"
LRZ.SOURCE_RANDOM = "random"   -- random items of the categories ticked per container type

-- Hard cap on squares visited per request (width * height * floors)
-- This cap is obscene bc there should be no limit (introduced the "Load" function)
LRZ.MAX_SQUARES = 5500000000

-- Hard cap on items spawned by one "add items" request
LRZ.MAX_ADD_ITEMS = 5000

-- Lowest/highest floor the Z range accepts (B42 has basements)
LRZ.MIN_Z = AdminTools_Tiles_Util.MIN_Z
LRZ.MAX_Z = AdminTools_Tiles_Util.MAX_Z

LRZ.ALL_KEY = "ALL"

-- Bucket for any item whose display category isn't in LRZ.Categories
LRZ.OTHER_KEY = "Other"

-- Display categories offered in the checkbox list (item script DisplayCategory keys).
LRZ.Categories = {
    -- weapons & ammo
    "Weapon", "WeaponPart", "Ammo", "Explosives", "Security",
    -- food, medical, clothing, containers
    "Food", "Cooking", "FirstAid", "Bandage", "Clothing",
    "ProtectiveGear", "Bag",
    "Literature", "SkillBook",
    -- materials & tools
    "Material", "RecipeResource", "Tool", "VehicleMaintenance", "Electronics",
    "Communications", "LightSource", "Camping", "Fishing",
    "Trapping", "Gardening", "Household",
    -- everything not listed above
    "Other",
}

LRZ.CategorySet = {}
for _, c in ipairs(LRZ.Categories) do
    LRZ.CategorySet[string.lower(c)] = c
end

-- Raw display categories never spawned as random loot (body parts, wounds,
-- corpses, live animals, furniture), lowercased.
LRZ.RandomSkip = {}
for _, c in ipairs({
    "ZedDmg", "Wound", "Hidden", "Corpse", "MaleBody", "Bug", "Ears", "Eye", "Tail",
    "Furniture", "Generic", "Animal", "Raccoon", "Bunny", "Fox", "Frog", "Duck", "Dog",
    "Goblin", "Spider", "Mole", "Badger", "Bear", "Beaver", "Hedgehog", "Squirrel",
}) do
    LRZ.RandomSkip[string.lower(c)] = true
end

-- Item list modes (see LRZ_ItemLists)
LRZ.LIST_WHITELIST = "whitelist"  -- only the listed items may be added
LRZ.LIST_BLACKLIST = "blacklist"  -- the listed items are never added

-- Predicate matching item full types against `entries`: full types
-- ("Base.Katana"), bare names ("Katana", in any module) or a whole module
-- ("SWMG.*"), case doesn't matter.
function LRZ.ItemMatcher(entries)
    local exact, bare, modules = {}, {}, {}
    for _, entry in ipairs(entries or {}) do
        local e = string.lower(tostring(entry))
        local module = string.match(e, "^(.+)%.%*$")
        if module then
            modules[module] = true
        elseif string.find(e, ".", 1, true) then
            exact[e] = true
        else
            bare[e] = true
        end
    end
    return function(fullType)
        local lower = string.lower(fullType)
        if exact[lower] then return true end
        local module, name = string.match(lower, "^(.-)%.(.+)$")
        if not module then return bare[lower] == true end
        return bare[name] == true or modules[module] == true
    end
end

-- Predicate for the item types the Loot Filler never spawns (the "Loot Filler
-- blacklist" sandbox option), or nil when there are none. Entries as in
-- LRZ.ItemMatcher, separated by ; , or spaces. Read again on every call, so
-- a sandbox change applies right away.
function LRZ.BlacklistFilter()
    local settings = SandboxVars and SandboxVars.AdminTools_Tiles
    local raw = settings and settings.LootFillerBlacklist
    local entries = {}
    for entry in string.gmatch(tostring(raw or ""), "[^;,%s]+") do
        table.insert(entries, entry)
    end
    if #entries == 0 then return nil end
    return LRZ.ItemMatcher(entries)
end

-- Predicate for the item types a Loot Filler request may add, or nil when
-- they all may: never what's on the sandbox blacklist and, with `itemList`
-- ({ mode, items }, see LRZ_ItemLists), only what a whitelist has / nothing a
-- blacklist has.
function LRZ.AllowedFilter(itemList)
    local banned = LRZ.BlacklistFilter()
    local listed, whitelist
    if type(itemList) == "table" and type(itemList.items) == "table" then
        listed = LRZ.ItemMatcher(itemList.items)
        whitelist = itemList.mode == LRZ.LIST_WHITELIST
    end
    if not banned and not listed then return nil end
    return function(fullType)
        if banned and banned(fullType) then return false end
        if listed then return listed(fullType) == whitelist end
        return true
    end
end

-- The item's LRZ.Categories bucket; anything not listed goes to "Other".
function LRZ.GetItemCategory(item)
    local cat = item:getDisplayCategory()
    if cat and cat ~= "" then
        return LRZ.CategorySet[string.lower(tostring(cat))] or LRZ.OTHER_KEY
    end
    return LRZ.OTHER_KEY
end

-- Predicate for a request's category list (see LRZ_CategoryPicker), or nil
-- when it covers everything.
function LRZ.CategoryFilter(categories)
    local wanted = {}
    for _, c in ipairs(categories or { LRZ.ALL_KEY }) do
        if c == LRZ.ALL_KEY then return nil end
        wanted[string.lower(c)] = true
    end
    return function(item)
        return wanted[string.lower(LRZ.GetItemCategory(item))] == true
    end
end

-- Normalises a request's bounds: sorted corners and a clamped, sorted Z range.
-- Older clients only send `z`, so fall back to that for both ends.
function LRZ.NormaliseBounds(args)
    local x1, x2 = math.min(args.x1, args.x2), math.max(args.x1, args.x2)
    local y1, y2 = math.min(args.y1, args.y2), math.max(args.y1, args.y2)
    local z1 = tonumber(args.z1) or tonumber(args.z) or 0
    local z2 = tonumber(args.z2) or tonumber(args.z) or z1
    z1, z2 = AdminTools_Tiles_Util.clampZ(math.min(z1, z2)), AdminTools_Tiles_Util.clampZ(math.max(z1, z2))
    return x1, y1, x2, y2, z1, z2
end

function LRZ.SquareCount(x1, y1, x2, y2, z1, z2)
    return (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
end

-- Error text when a request's area is over LRZ.MAX_SQUARES, else nil.
function LRZ.TooBigMessage(args)
    local squares = LRZ.SquareCount(args.x1, args.y1, args.x2, args.y2, args.z1, args.z2)
    if squares > LRZ.MAX_SQUARES then
        return "Area too big: " .. squares .. " squares (max " .. LRZ.MAX_SQUARES .. ")"
    end
    return nil
end

LRZ.AllowedAccessLevels = {
    admin = true,
    moderator = false,
    overseer = false,
    gm = false,
    builder = true
}

function LRZ.CanUse(player)
    return AdminTools_Tiles_Util.hasAccess(player, LRZ.AllowedAccessLevels)
end

-- "W x H tiles on floors a to b" for status lines / confirmations.
function LRZ.DescribeArea(args)
    local text = (args.x2 - args.x1 + 1) .. " x " .. (args.y2 - args.y1 + 1) .. " tiles"
    if args.z1 == args.z2 then
        return text .. " on floor " .. args.z1
    end
    return text .. " on floors " .. args.z1 .. " to " .. args.z2
end
