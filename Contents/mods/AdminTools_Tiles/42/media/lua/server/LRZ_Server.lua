-- LRZ_Server.lua
-- Loot removal / adding: collects every container and ground item in the
-- zone (across a floor range) and either
--   - removes a percentage of each checked category (bulk), or
--   - reports a per-item breakdown (scan), or
--   - trims specific item types down to a target amount (apply edits), or
--   - adds picked items / rerolls vanilla loot / adds random items of the
--     categories picked per container type, on top of or replacing what's
--     there (add loot), or
--   - lists the container types in the zone (scan containers).

require "LRZ_Shared"

local Util = AdminTools_Tiles_Util

-- sendServerCommand goes nowhere in single player, so hand the reply
-- straight to the client's OnServerCommand listeners there.
local function reply(player, command, args)
    if isServer() then
        sendServerCommand(player, LRZ.ModuleName, command, args)
    else
        triggerEvent("OnServerCommand", LRZ.ModuleName, command, args)
    end
end
local getItemCategory = LRZ.GetItemCategory

-- The zone's containers and ground items (only when args.ground is set).
local function collectArea(args)
    local x1, y1, x2, y2, z1, z2 = LRZ.NormaliseBounds(args)
    return Util.collectLoot(x1, y1, x2, y2, z1, z2, args.ground == true)
end

-- Checks permissions and area size, then returns the zone's containers and
-- ground items (or nil after telling the client why not).
local function lootForRequest(player, args)
    if not LRZ.CanUse(player) then
        reply(player, LRZ.RES_DENIED, {})
        return nil
    end

    local x1, y1, x2, y2, z1, z2 = LRZ.NormaliseBounds(args)
    local squares = LRZ.SquareCount(x1, y1, x2, y2, z1, z2)
    if squares > LRZ.MAX_SQUARES then
        reply(player, LRZ.RES_TOO_BIG, { squares = squares, max = LRZ.MAX_SQUARES })
        return nil
    end

    return collectArea(args)
end

-- Every item as { item, container } or, for ground items, { item, worldObj }.
local function collectEntries(containers, ground)
    local entries = {}
    for _, container in ipairs(containers) do
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            table.insert(entries, { item = items:get(i), container = container })
        end
    end
    for _, worldObj in ipairs(ground) do
        table.insert(entries, { item = worldObj:getItem(), worldObj = worldObj })
    end
    return entries
end

local function removeEntries(entries, count)
    local removed = 0
    for i = 1, math.min(count, #entries) do
        local entry = entries[i]
        if entry.worldObj then
            Util.removeGroundItem(entry.worldObj)
        else
            Util.removeItem(entry.container, entry.item)
        end
        removed = removed + 1
    end
    return removed
end

-- Breakdown rows are per item type, with ground items in their own row.
local function rowKey(fullType, onGround)
    return onGround and (fullType .. "|ground") or fullType
end

-- Per item type totals for the breakdown list.
local function buildBreakdown(containers, ground)
    local byType = {}
    local list = {}
    local total = 0
    for _, e in ipairs(collectEntries(containers, ground)) do
        local item = e.item
        local fullType = item:getFullType()
        local onGround = e.worldObj ~= nil
        local key = rowKey(fullType, onGround)
        local entry = byType[key]
        if not entry then
            local cat = getItemCategory(item)
            entry = { type = fullType, ground = onGround, name = item:getDisplayName(), cat = cat, count = 0 }
            byType[key] = entry
            table.insert(list, entry)
        end
        entry.count = entry.count + 1
        total = total + 1
    end
    return list, total
end

-- Without containers / ground the area is collected again, so items taken
-- off the ground aren't counted after a removal.
-- `ground` in the reply is only set when ground items were included.
local function sendBreakdown(player, args, removed, containers, ground)
    if not containers then
        containers, ground = collectArea(args)
    end
    local list, total = buildBreakdown(containers, ground)
    reply(player, LRZ.RES_SCAN, {
        entries = list,
        total = total,
        containers = #containers,
        ground = args.ground and #ground or nil,
        removed = removed,
    })
end

local function sendDone(player, args, removed, containers, ground)
    reply(player, LRZ.RES_DONE, {
        removed = removed,
        containers = #containers,
        ground = args.ground and #ground or nil,
    })
end

-- Bulk: removes `percent` of every checked category.
local function removeLoot(player, args)
    local containers, ground = lootForRequest(player, args)
    if not containers then return end

    local percent = tonumber(args.percent) or 100
    percent = Util.clamp(percent, 0, 100)

    local inCategories = LRZ.CategoryFilter(args.categories)

    -- buckets are cool
    local buckets = {}
    for _, e in ipairs(collectEntries(containers, ground)) do
        if not inCategories or inCategories(e.item) then
            local cat = getItemCategory(e.item)
            buckets[cat] = buckets[cat] or {}
            table.insert(buckets[cat], e)
        end
    end

    local totalRemoved = 0
    for _, entries in pairs(buckets) do
        Util.shuffle(entries)
        local toRemove = math.floor((#entries * percent / 100) + 0.5)
        totalRemoved = totalRemoved + removeEntries(entries, toRemove)
    end

    sendDone(player, args, totalRemoved, containers, ground)
    if args.rescan then
        sendBreakdown(player, args, totalRemoved)
    end
end

-- Breakdown: just report what's in there.
local function scanLoot(player, args)
    local containers, ground = lootForRequest(player, args)
    if not containers then return end
    sendBreakdown(player, args, nil, containers, ground)
end

-- Breakdown: args.edits = { { type = "Base.Axe", ground = false, target = 2 }, ... }
-- Removes random copies of each row until only `target` are left.
local function applyEdits(player, args)
    local containers, ground = lootForRequest(player, args)
    if not containers then return end

    local targets = {}
    for _, edit in ipairs(args.edits or {}) do
        local target = tonumber(edit.target)
        if edit.type and target then
            targets[rowKey(edit.type, edit.ground == true)] = math.max(0, math.floor(target))
        end
    end

    local byKey = {}
    for _, e in ipairs(collectEntries(containers, ground)) do
        local key = rowKey(e.item:getFullType(), e.worldObj ~= nil)
        if targets[key] then
            byKey[key] = byKey[key] or {}
            table.insert(byKey[key], e)
        end
    end

    local totalRemoved = 0
    for key, entries in pairs(byKey) do
        local excess = #entries - targets[key]
        if excess > 0 then
            Util.shuffle(entries)
            totalRemoved = totalRemoved + removeEntries(entries, excess)
        end
    end

    sendDone(player, args, totalRemoved, containers, ground)
    sendBreakdown(player, args, totalRemoved)
end

-- Only real item types, with a sane amount, that are `allowed` (see
-- LRZ.AllowedFilter). Also returns how many were left out for not being.
local function validItemRequests(list, allowed)
    local valid = {}
    local skipped = 0
    for _, req in ipairs(list or {}) do
        local count = tonumber(req.count)
        if type(req.type) == "string" and count and count >= 1
            and ScriptManager.instance:getItem(req.type) then
            if allowed and not allowed(req.type) then
                skipped = skipped + 1
            else
                table.insert(valid, { type = req.type, count = math.floor(count) })
            end
        end
    end
    return valid, skipped
end

-- The `allowed` ones of `types` (the list itself when they all are).
local function onlyAllowed(types, allowed)
    if not allowed then return types end
    local kept = {}
    for _, t in ipairs(types) do
        if allowed(t) then table.insert(kept, t) end
    end
    return kept
end

-- Removes the container's items that match `filter`. Returns how many.
local function clearMatching(container, filter)
    local items = container:getItems()
    local matching = {}
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if filter(item) then table.insert(matching, item) end
    end
    for _, item in ipairs(matching) do
        Util.removeItem(container, item)
    end
    return #matching
end

-- Every spawnable item type by LRZ.Categories bucket, built on first use.
local randomPool = nil
local function getRandomPool()
    if randomPool then return randomPool end
    randomPool = {}
    local all = getScriptManager():getAllItems()
    for i = 0, all:size() - 1 do
        local script = all:get(i)
        local raw = script:getDisplayCategory()
        local skip = raw and LRZ.RandomSkip[string.lower(tostring(raw))]
        if not skip and not script:getObsolete() and not script:isHidden() then
            local cat = getItemCategory(script)
            randomPool[cat] = randomPool[cat] or {}
            table.insert(randomPool[cat], script:getFullName())
        end
    end
    return randomPool
end

-- args.containerTypes = { { type = "locker", categories = { ... }, amount = 3 } }
-- -> plans by container type: { amount, buckets = { itemTypeLists }, filter },
-- and how many there are. Only `allowed` item types are picked (see
-- LRZ.AllowedFilter); types with no usable category are left out.
local function validRandomPlans(list, allowed)
    local pool = {}
    for cat, types in pairs(getRandomPool()) do
        pool[cat] = onlyAllowed(types, allowed)
    end
    local plans = {}
    local count = 0
    for _, req in ipairs(list or {}) do
        local amount = tonumber(req.amount)
        if type(req.type) == "string" and amount and amount >= 1 then
            local filter = LRZ.CategoryFilter(req.categories)
            local wanted = {}
            for _, c in ipairs(req.categories or {}) do
                wanted[string.lower(c)] = true
            end
            local buckets = {}
            for _, cat in ipairs(LRZ.Categories) do
                local types = pool[cat]
                if types and #types > 0 and (not filter or wanted[string.lower(cat)]) then
                    table.insert(buckets, types)
                end
            end
            if #buckets > 0 then
                if not plans[req.type] then count = count + 1 end
                plans[req.type] = {
                    amount = Util.clamp(math.floor(amount), 1, LRZ.MAX_ADD_ITEMS),
                    buckets = buckets,
                    filter = filter,
                }
            end
        end
    end
    return plans, count
end

-- Random item type from a plan: a random ticked category first, so small
-- categories (Ammo) aren't drowned out by big ones (Food).
local function pickRandomType(plan)
    local bucket = plan.buckets[ZombRand(#plan.buckets) + 1]
    return bucket[ZombRand(#bucket) + 1]
end

-- The zone's containers that can take loot (or nil after telling the client
-- why not). Loot only goes into containers, never on the ground, and
-- corpses aren't loot spots.
local function lootContainersForRequest(player, args)
    local zoneContainers = lootForRequest(player, args)
    if not zoneContainers then return nil end
    local containers = {}
    for _, c in ipairs(zoneContainers) do
        if not instanceof(c:getParent(), "IsoDeadBody") then
            table.insert(containers, c)
        end
    end
    return containers
end

-- Adder: lists the zone's container types and how many of each.
local function scanContainers(player, args)
    local containers = lootContainersForRequest(player, args)
    if not containers then return end
    local byType = {}
    local types = {}
    for _, c in ipairs(containers) do
        local t = c:getType()
        if not byType[t] then
            byType[t] = { type = t, count = 0 }
            table.insert(types, byType[t])
        end
        byType[t].count = byType[t].count + 1
    end
    reply(player, LRZ.RES_CONTAINERS, {
        types = types,
        containers = #containers,
    })
end

-- Adder: args.source = LRZ.SOURCE_ITEMS (args.items = { { type, count } },
-- args.perContainer), LRZ.SOURCE_REROLL or LRZ.SOURCE_RANDOM
-- (args.containerTypes, see validRandomPlans). args.replace empties the
-- containers first. args.categories (like removeLoot) limits what replace
-- clears and which rerolled items are kept; for SOURCE_RANDOM each
-- container type's own categories do. args.itemList ({ mode, items }, see
-- LRZ_ItemLists) is a whitelist / blacklist of what may be added; the
-- sandbox blacklist always applies too (see LRZ.AllowedFilter), whatever
-- the source.
local function addLoot(player, args)
    local containers = lootContainersForRequest(player, args)
    if not containers then return end

    local allowed = LRZ.AllowedFilter(args.itemList)
    local items, plans, skipped
    if args.source == LRZ.SOURCE_RANDOM then
        local planCount
        plans, planCount = validRandomPlans(args.containerTypes, allowed)
        if planCount == 0 then
            local msg = "Tick categories for at least one container type."
            if allowed then
                msg = "Nothing in the ticked categories is allowed by the item list / sandbox blacklist."
            end
            reply(player, LRZ.RES_ADDED, { error = msg })
            return
        end
        -- Only the container types that have a plan
        local planned = {}
        local total = 0
        for _, c in ipairs(containers) do
            local plan = plans[c:getType()]
            if plan then
                table.insert(planned, c)
                total = total + plan.amount
            end
        end
        containers = planned
        if total > LRZ.MAX_ADD_ITEMS then
            reply(player, LRZ.RES_ADDED, {
                error = "Too many items: " .. total .. " (max " .. LRZ.MAX_ADD_ITEMS .. ")",
            })
            return
        end
    elseif args.source ~= LRZ.SOURCE_REROLL then
        items, skipped = validItemRequests(args.items, allowed)
        if #items == 0 then
            local msg = "No valid items to add."
            if skipped > 0 then
                msg = "None of the picked items is allowed by the item list / sandbox blacklist."
            end
            reply(player, LRZ.RES_ADDED, { error = msg })
            return
        end
        local total = 0
        for _, req in ipairs(items) do
            total = total + (args.perContainer and req.count * #containers or req.count)
        end
        if total > LRZ.MAX_ADD_ITEMS then
            reply(player, LRZ.RES_ADDED, {
                error = "Too many items: " .. total .. " (max " .. LRZ.MAX_ADD_ITEMS .. ")",
            })
            return
        end
    end

    local inCategories = LRZ.CategoryFilter(args.categories)

    local cleared = 0
    if args.replace then
        for _, c in ipairs(containers) do
            local filter = inCategories
            if plans then filter = plans[c:getType()].filter end
            if filter then
                cleared = cleared + clearMatching(c, filter)
            else
                cleared = cleared + Util.clearContainer(c)
            end
        end
    end

    local added = 0
    if #containers > 0 then
        if args.source == LRZ.SOURCE_REROLL then
            local keep = inCategories
            if allowed then
                keep = function(item)
                    return allowed(item:getFullType()) and (not inCategories or inCategories(item))
                end
            end
            for _, c in ipairs(containers) do
                added = added + Util.rerollContainer(c, player, keep)
            end
        elseif plans then
            for _, c in ipairs(containers) do
                local plan = plans[c:getType()]
                for _ = 1, plan.amount do
                    if Util.addItem(c, pickRandomType(plan)) then added = added + 1 end
                end
            end
        else
            for _, req in ipairs(items) do
                if args.perContainer then
                    for _, c in ipairs(containers) do
                        for _ = 1, req.count do
                            if Util.addItem(c, req.type) then added = added + 1 end
                        end
                    end
                else
                    for _ = 1, req.count do
                        local c = containers[ZombRand(#containers) + 1]
                        if Util.addItem(c, req.type) then added = added + 1 end
                    end
                end
            end
        end
        Util.finishContainers(containers)
    end

    reply(player, LRZ.RES_ADDED, {
        added = added,
        cleared = cleared,
        containers = #containers,
        skipped = skipped,
    })
    if args.rescan then
        sendBreakdown(player, args, nil)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= LRZ.ModuleName then return end
    if command == LRZ.CMD_REMOVE_LOOT then
        removeLoot(player, args)
    elseif command == LRZ.CMD_SCAN then
        scanLoot(player, args)
    elseif command == LRZ.CMD_APPLY_EDITS then
        applyEdits(player, args)
    elseif command == LRZ.CMD_ADD_LOOT then
        addLoot(player, args)
    elseif command == LRZ.CMD_SCAN_CONTAINERS then
        scanContainers(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
