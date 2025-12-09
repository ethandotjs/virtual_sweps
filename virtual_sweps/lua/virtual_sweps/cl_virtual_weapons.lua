VirtualWeapons = VirtualWeapons or {}
VirtualWeapons.ClientWeapons = VirtualWeapons.ClientWeapons or {}

local needsRebuild = true

net.Receive("VirtualWeapons_SendList", function()
    local count = net.ReadUInt(16)
    VirtualWeapons.ClientWeapons = {}

    for i = 1, count do
        local weaponClass = net.ReadString()
        table.insert(VirtualWeapons.ClientWeapons, weaponClass)
    end

    needsRebuild = true
end)

local lastSwitchRequest = 0
local SWITCH_REQUEST_COOLDOWN = 0.05 -- client-side anti-spam

function VirtualWeapons:RequestSwitch(weaponClass)
    -- rate limit NW requests
    local now = CurTime()
    if (now - lastSwitchRequest < SWITCH_REQUEST_COOLDOWN) then
        return
    end

    lastSwitchRequest = now

    net.Start("VirtualWeapons_SwitchTo")
    net.WriteString(weaponClass)
    net.SendToServer()
end

local sel = { active = false, last = 0, index = 1 }

local BASE_ALPHA = 180
local ROW_H      = 34
local ROW_GAP    = 2
local PANEL_WIDTH = 200
local FADE_TIME = 3

local col_bg        = Color(20, 20, 20, BASE_ALPHA)
local col_highlight = Color(50, 150, 250, BASE_ALPHA)
local col_text      = Color(200, 200, 200, 255)
local col_text_sel  = Color(255, 255, 255, 255)

hook.Add("HUDShouldDraw", "VirtualWeapons_HideDefault", function(name)
    if (name == "CHudWeaponSelection") then return false end
end)

hook.Add("WeaponEquip", "VirtualWeapons_RebuildOnEquip", function(weapon, ply)
    if (ply == LocalPlayer()) then
        needsRebuild = true
    end
end)

hook.Add("EntityRemoved", "VirtualWeapons_RebuildOnRemove", function(ent)
    if (ent:IsWeapon() and IsValid(LocalPlayer())) then
        local owner = ent:GetOwner()
        if (owner == LocalPlayer()) then
            needsRebuild = true
        end
    end
end)

local function WS_PlaySound()
    local ply = LocalPlayer()
    if (IsValid(ply)) then
        ply:EmitSound("common/wpn_moveselect.wav", 50, 100, 0.25)
    end
end

local function GetSlot(wepTable)
    return math.Clamp(wepTable.Slot or 0, 0, 9)
end

local function GetSlotPos(wepTable)
    return wepTable.SlotPos or 0
end

-- engine-defined slots for HL2 weapons (fallback when weapon table doesn't define slot)
local ENGINE_WEAPON_SLOTS = {
    weapon_crowbar = 0,
    weapon_physcannon = 0,
    weapon_physgun = 0,
    weapon_stunstick = 0,
    weapon_pistol = 1,
    weapon_357 = 1,
    weapon_smg1 = 2,
    weapon_ar2 = 2,
    weapon_shotgun = 3,
    weapon_crossbow = 3,
    weapon_frag = 4,
    weapon_rpg = 4,
    weapon_slam = 4,
    weapon_bugbait = 5,
    gmod_tool = 5,
}

local function WrapTextToWidth(text, font, maxWidth)
    text = tostring(text or "")
    if (text == "") then return {""}, 0, 0 end

    surface.SetFont(font)
    local lineHeight = draw.GetFontHeight(font)
    local words = string.Explode(" ", text)
    local lines = {}
    local line = ""

    for i = 1, #words do
        local word = words[i]
        local candidate = (line == "" and word) or (line .. " " .. word)
        local w = surface.GetTextSize(candidate)

        if (w > maxWidth) then
            if (line != "") then
                lines[#lines + 1] = line
                line = word
            else
                local cut = word
                while (#cut > 1 and surface.GetTextSize(cut .. "…") > maxWidth) do
                    cut = string.sub(cut, 1, #cut - 1)
                end
                lines[#lines + 1] = cut .. "…"
                line = ""
            end
        else
            line = candidate
        end
    end

    if (line != "") then lines[#lines + 1] = line end
    local totalHeight = #lines * lineHeight
    return lines, totalHeight, lineHeight
end

local cachedSlots, cachedFlat, cachedNonEmpty = {}, {}, {}
local lastWeaponCount = 0
local lastBuildTime = 0
local BUILD_THROTTLE = 0.05 -- throttle rebuilds to 50ms

local function BuildWeapons(ply)
    if (not IsValid(ply)) then return cachedSlots, cachedFlat, cachedNonEmpty end

    local virtualWeps = VirtualWeapons.ClientWeapons or {}

    local realWeapons = ply:GetWeapons()
    local totalWepCount = #virtualWeps + #realWeapons

    -- return cache if nothing changed
    if (totalWepCount == lastWeaponCount and not needsRebuild) then
        return cachedSlots, cachedFlat, cachedNonEmpty
    end

    -- throttle rebuilds
    local now = CurTime()
    if (needsRebuild and now - lastBuildTime < BUILD_THROTTLE) then
        return cachedSlots, cachedFlat, cachedNonEmpty
    end
    lastBuildTime = now

    table.Empty(cachedSlots)
    table.Empty(cachedFlat)
    table.Empty(cachedNonEmpty)
    lastWeaponCount = totalWepCount

    local maxTextW = PANEL_WIDTH - 12
    surface.SetFont("Trebuchet24")

    local virtualSet = {}
    for i = 1, #virtualWeps do
        virtualSet[virtualWeps[i]] = true
    end

    local allWeapons = {}

    for i = 1, #virtualWeps do
        table.insert(allWeapons, {class = virtualWeps[i], isVirtual = true})
    end

    for i = 1, #realWeapons do
        local wep = realWeapons[i]
        if (IsValid(wep)) then
            local class = wep:GetClass()
            if (not virtualSet[class]) then
                table.insert(allWeapons, {class = class, isVirtual = false, entity = wep})
            end
        end
    end

    for i = 1, #allWeapons do
        local weaponInfo = allWeapons[i]
        local class = weaponInfo.class
        local wepTable = weapons.Get(class)

        local slot, pos, rawName

        if (wepTable) then
            slot = wepTable.Slot and GetSlot(wepTable) or ENGINE_WEAPON_SLOTS[class] or 0
            pos = GetSlotPos(wepTable)
            if (not wepTable.PrintName) then continue end
            rawName = wepTable.PrintName
        else
            local realWep = ply:GetWeapon(class)
            if (IsValid(realWep)) then
                slot = realWep:GetSlot()
                pos = realWep:GetSlotPos()
                rawName = realWep:GetPrintName()
                if (not rawName) then continue end
            else
                slot = ENGINE_WEAPON_SLOTS[class] or 0
                pos = 0
                rawName = class
            end
        end

        local text = language.GetPhrase(rawName)
        local lines, wrappedH, lineH = WrapTextToWidth(text, "Trebuchet24", maxTextW)

        local entry = {
            class = class,
            pos = pos,
            text = text,
            lines = lines,
            wrappedH = wrappedH,
            lineH = lineH,
            isVirtual = weaponInfo.isVirtual
        }

        if (not cachedSlots[slot]) then cachedSlots[slot] = {} end
        cachedSlots[slot][#cachedSlots[slot] + 1] = entry
    end

    for slot = 0, 9 do
        local slotWeapons = cachedSlots[slot]
        if (slotWeapons and #slotWeapons > 0) then
            table.sort(slotWeapons, function(a, b)
                return a.pos == b.pos and a.text < b.text or a.pos < b.pos
            end)

            for j = 1, #slotWeapons do
                cachedFlat[#cachedFlat + 1] = { slot = slot, class = slotWeapons[j].class, isVirtual = slotWeapons[j].isVirtual }
            end
            cachedNonEmpty[#cachedNonEmpty + 1] = slot
        end
    end

    needsRebuild = false
    return cachedSlots, cachedFlat, cachedNonEmpty
end

local function BindSlotToIndex(bind)
    local num = tonumber(string.sub(bind, 5))
    if (not num) then return nil end
    if (num == 0) then return 9 end
    return math.Clamp(num - 1, 0, 9)
end

hook.Add("PlayerBindPress", "VirtualWeapons_HandleInput", function(ply, bind, pressed)
    if (not pressed) then
        return
    end

    local _, flat = BuildWeapons(ply)
    if (not gui.IsGameUIVisible() and not vgui.CursorVisible()) then
        local flatCount = #flat
        if (flatCount == 0) then
            return
        end

        if (string.sub(bind, 1, 4) == "slot") then
            local targetSlot = BindSlotToIndex(bind)
            if (targetSlot) then
                sel.active = true
                sel.last = CurTime()

                local currentSlot = sel.index and flat[sel.index] and flat[sel.index].slot
                local found = nil

                if (currentSlot == targetSlot) then
                    for i = sel.index + 1, flatCount do
                        if (flat[i].slot == targetSlot) then
                            found = i
                            break
                        elseif (flat[i].slot != targetSlot) then
                            break
                        end
                    end
                end

                if (not found) then
                    for i = 1, flatCount do
                        if (flat[i].slot == targetSlot) then
                            found = i
                            break
                        end
                    end
                end

                if (found) then
                    sel.index = found
                    WS_PlaySound()
                end
                return true
            end
        end

        if (bind == "invnext" or bind == "invprev") then
            -- don't interrupt physgun while grabbing
            local activeWep = ply:GetActiveWeapon()
            if (IsValid(activeWep) and activeWep:GetClass() == "weapon_physgun" and input.IsMouseDown(MOUSE_LEFT)) then
                return false
            end

            local wasActive = sel.active
            sel.active = true
            sel.last = CurTime()

            sel.index = sel.index or 1
            if (not wasActive and IsValid(activeWep)) then
                local currentClass = activeWep:GetClass()
                for i = 1, flatCount do
                    if (flat[i].class == currentClass) then
                        sel.index = i
                        break
                    end
                end
            end

            if (bind == "invnext") then
                sel.index = sel.index >= flatCount and 1 or sel.index + 1
            else
                sel.index = sel.index <= 1 and flatCount or sel.index - 1
            end
            WS_PlaySound()
            return true
        end

        if (bind == "+attack" and sel.active) then
            if (sel.index and sel.index >= 1 and sel.index <= flatCount) then
                local selectedWeapon = flat[sel.index]
                if (selectedWeapon and selectedWeapon.class) then
                    if (selectedWeapon.isVirtual) then
                        VirtualWeapons:RequestSwitch(selectedWeapon.class)
                    else
                        RunConsoleCommand("use", selectedWeapon.class)
                    end
                end
            end
            sel.active = false
            sel.index = nil
            return true
        end

        if (bind == "lastinv") then
            return false
        end
    end
end)

hook.Add("HUDPaint", "VirtualWeapons_DrawSelector", function()
    if (not sel.active) then
        return
    end

    local curTime = CurTime()
    if (curTime - sel.last > FADE_TIME) then
        sel.active = false
        return
    end

    local ply = LocalPlayer()
    if (not IsValid(ply)) then
        return
    end

    local slots, flat, nonEmpty = BuildWeapons(ply)
    local flatCount = #flat
    if (flatCount == 0) then
        return
    end

    if (not sel.index or sel.index > flatCount or sel.index < 1) then
        sel.index = 1
    end

    local selectedEntry = flat[sel.index]
    if (not selectedEntry) then
        return
    end

    local activeSlot = selectedEntry.slot
    local nonEmptyCount = #nonEmpty

    col_bg.a = BASE_ALPHA
    col_highlight.a = BASE_ALPHA

    local totalWidth = nonEmptyCount * PANEL_WIDTH
    local startX = (ScrW() - totalWidth) / 2
    local topY = 40

    surface.SetFont("Trebuchet24")

    for i = 1, nonEmptyCount do
        local slotNum = nonEmpty[i]
        local list = slots[slotNum]
        local listCount = #list
        local isActiveSlot = slotNum == activeSlot

        local slotLabel = slotNum == 9 and "0" or tostring(slotNum + 1)

        local x = startX + (i - 1) * PANEL_WIDTH
        local y = topY
        local panelWidth = PANEL_WIDTH - 4
        local centerX = x + PANEL_WIDTH / 2

        draw.RoundedBox(6, x, y, panelWidth, ROW_H,
            isActiveSlot and col_highlight or col_bg)
        draw.SimpleText(slotLabel, "Trebuchet24", centerX, y + ROW_H / 2,
            col_text_sel, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local curY = y + ROW_H + ROW_GAP

        for j = 1, listCount do
            local entry = list[j]
            local isSelected = selectedEntry and entry.class == selectedEntry.class
            local effectiveRowH = math.max(ROW_H, entry.wrappedH + 6)

            draw.RoundedBox(6, x, curY, panelWidth, effectiveRowH,
                isSelected and col_highlight or col_bg)

            local textColor = isSelected and col_text_sel or col_text
            local textTop = curY + math.floor((effectiveRowH - entry.wrappedH) / 2)
            local lines = entry.lines

            for k = 1, #lines do
                draw.SimpleText(lines[k], "Trebuchet24", centerX,
                    textTop + (k - 1) * entry.lineH, textColor,
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
            end

            curY = curY + effectiveRowH + ROW_GAP
        end
    end
end)