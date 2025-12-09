--[[
    Virtual Weapons System

    This system allows players to have a (basically) unlimited weapon inventory by only keeping one weapon
    entity loaded at a time. Weapons are "virtualized" - meaning their state is saved when holstered
    and restored when deployed.
    
    By default, weapons are NOT virtualized. To make a weapon virtualizable:
    - Add to weapon file: SWEP.CanVirtualize = true
    - Or add weapon class to VirtualWeapons.AlwaysVirtualize table
    - Or use a base that has CanVirtualize = true (inheritance supported)
    - The most specific rule applies (So, a SWEP being set to true will override it's base's setting of false)

    Optional hooks:

    - SWEP:OnVirtualHolster()
      Called when the weapon is being virtualized/stored away

    - SWEP:OnVirtualDeploy(wasDeployedBefore)
      Called when the weapon is being retrieved from virtual storage
      wasDeployedBefore: true if weapon state was restored, false if first time

    - SWEP:OnVirtualSave(stateTable)
      Called during state save. You can add custom data to stateTable
      Example: stateTable.myCustomVar = self.SomeValue

    - SWEP:OnVirtualRestore(stateTable)
      Called during state restore. You can read your custom data from stateTable
      Example: self.SomeValue = stateTable.myCustomVar
]]
util.AddNetworkString("VirtualWeapons_SendList")
util.AddNetworkString("VirtualWeapons_SwitchTo")

VirtualWeapons = VirtualWeapons or {}
VirtualWeapons.PlayerWeapons = VirtualWeapons.PlayerWeapons or {}
VirtualWeapons.BlockNextAmmo = VirtualWeapons.BlockNextAmmo or {}
VirtualWeapons.SwitchCooldowns = VirtualWeapons.SwitchCooldowns or {}
VirtualWeapons.StrippingWeapons = VirtualWeapons.StrippingWeapons or {}
VirtualWeapons.BypassGiveHook = false
VirtualWeapons.BypassAmmoHook = false

VirtualWeapons.AlwaysVirtualize = {
    ["weapon_physcannon"] = true,
    ["weapon_physgun"] = true,
    ["weapon_crowbar"] = true,
    ["gmod_camera"] = true,
    ["gmod_tool"] = true,
}

local SWITCH_COOLDOWN = 0.1 -- anti-spam

function VirtualWeapons:ShouldVirtualize(weaponClass)
    if (self.AlwaysVirtualize[weaponClass]) then
        return true
    end

    local wepTable = weapons.GetStored(weaponClass)
    if (not wepTable) then
        return false
    end

    -- check for explicit opt-out
    if (wepTable.CanVirtualize == false) then
        return false
    end

    -- walk inheritance chain
    local current = wepTable
    local visited = {}

    while (current) do
        local className = current.ClassName or ""

        if (visited[className]) then break end
        visited[className] = true

        if (self.AlwaysVirtualize[className]) then
            return true
        end

        if (current.CanVirtualize == true) then
            return true
        end

        if (current.Base and current.Base != "" and current.Base != "weapon_base") then
            current = weapons.GetStored(current.Base)
        else
            break
        end
    end

    return false
end

function VirtualWeapons:ShouldVirtualizeEntity(wep)
    if (not IsValid(wep)) then return false end
    return self:ShouldVirtualize(wep:GetClass())
end

function VirtualWeapons:InitPlayer(ply)
    if (not self.PlayerWeapons[ply]) then
        self.PlayerWeapons[ply] = {
            weapons = {},    -- array for iteration/networking
            weaponSet = {},  -- hash table for O(1) lookups
            weaponData = {}, -- saved weapon states (clip, ammo, custom data)
            active = nil
        }
    else
        -- hotloading support
        if (not self.PlayerWeapons[ply].weaponSet) then
            self.PlayerWeapons[ply].weaponSet = {}
            for _, weaponClass in ipairs(self.PlayerWeapons[ply].weapons or {}) do
                self.PlayerWeapons[ply].weaponSet[weaponClass] = true
            end
        end
    end
end

function VirtualWeapons:StripWeaponSafely(ply, weaponClass)
    if (not IsValid(ply) or not isstring(weaponClass)) then
        return
    end

    if (not self.StrippingWeapons[ply]) then
        self.StrippingWeapons[ply] = {}
    end
    self.StrippingWeapons[ply][weaponClass] = true

    VirtualWeapons.oldStripWeapon(ply, weaponClass)
end

-- deep copy with circular reference protection
local function DeepCopyTable(tbl, seen)
    if (type(tbl) != "table") then
        return tbl
    end

    seen = seen or {}
    if (seen[tbl]) then
        return seen[tbl]
    end -- already copied, return reference

    local copy = {}
    seen[tbl] = copy

    for k, v in pairs(tbl) do
        if (type(v) == "table") then
            copy[k] = DeepCopyTable(v, seen)
        elseif (type(v) != "function") then
            copy[k] = v
        end
    end

    return copy
end

-- weapon table keys to ignore when saving state
local WEAPON_STATE_BLACKLIST = {
    Owner = true,
    Weapon = true,
    Entity = true,
    m_bInitialized = true,
    BaseClass = true,
    Base = true,
    Primary = true,
    Secondary = true,
    PrintName = true,
    Author = true,
    Instructions = true,
    Purpose = true,
    Category = true,
    Spawnable = true,
    AdminOnly = true,
    ViewModel = true,
    WorldModel = true,
    ViewModelFOV = true,
    ViewModelFlip = true,
    UseHands = true,
    Slot = true,
    SlotPos = true,
    DrawAmmo = true,
    DrawCrosshair = true,
    Weight = true,
    AutoSwitchTo = true,
    AutoSwitchFrom = true,
    isReloading = true,
    ReloadSpeedMult = true,
    nextIdle = true,
    VW_FastDeploy = true,
    Mode = true,
    ToolObj = true,
}

function VirtualWeapons:SaveWeaponState(ply, weapon)
    if (not IsValid(weapon)) then
        return
    end

    local weaponClass = weapon:GetClass()

    -- tool gun doesn't play too nice
    if (weaponClass == "gmod_tool") then
        return
    end

    local state = {}

    state.clip1 = weapon:Clip1()
    state.clip2 = weapon:Clip2()

    local ammoType1 = weapon:GetPrimaryAmmoType()
    local ammoType2 = weapon:GetSecondaryAmmoType()
    state.ammo1 = ammoType1 > 0 and ply:GetAmmoCount(ammoType1) or 0
    state.ammo2 = ammoType2 > 0 and ply:GetAmmoCount(ammoType2) or 0
    state.ammoType1 = ammoType1
    state.ammoType2 = ammoType2

    state.nwVars = {}
    state.nw2Vars = {}

    local nwVarTable = weapon:GetNWVarTable()
    if (nwVarTable) then
        for key, value in pairs(nwVarTable) do
            local vType = type(value)

            if (vType == "Vector") then
                state.nwVars[key] = {x = value.x, y = value.y, z = value.z, _isVector = true}
            elseif (vType == "Angle") then
                state.nwVars[key] = {p = value.p, y = value.y, r = value.r, _isAngle = true}
            elseif (vType == "Entity" or vType == "Player" or vType == "Weapon" or vType == "Vehicle" or vType == "NPC") then
                state.nwVars[key] = {entIndex = IsValid(value) and value:EntIndex() or -1, _isEntity = true}
            elseif (vType == "table") then
                state.nwVars[key] = DeepCopyTable(value)
            elseif (vType != "function" and vType != "userdata" and vType != "thread") then
                state.nwVars[key] = value
            end
        end
    end

    local nw2VarTable = weapon:GetNW2VarTable()
    if (nw2VarTable) then
        for key, nw2Data in pairs(nw2VarTable) do
            if (type(nw2Data) == "table" and nw2Data.type and nw2Data.value != nil) then
                local nw2Type = nw2Data.type
                local actualValue = nw2Data.value
                local vType = type(actualValue)

                if (nw2Type == "Vector" and vType == "Vector") then
                    state.nw2Vars[key] = {x = actualValue.x, y = actualValue.y, z = actualValue.z, _nw2Type = "Vector"}
                elseif (nw2Type == "Angle" and vType == "Angle") then
                    state.nw2Vars[key] = {p = actualValue.p, y = actualValue.y, r = actualValue.r, _nw2Type = "Angle"}
                elseif (nw2Type == "Entity") then
                    state.nw2Vars[key] = {entIndex = IsValid(actualValue) and actualValue:EntIndex() or -1, _nw2Type = "Entity"}
                elseif (nw2Type == "Int" or nw2Type == "Float") then
                    state.nw2Vars[key] = {value = actualValue, _nw2Type = nw2Type}
                elseif (nw2Type == "String") then
                    state.nw2Vars[key] = {value = actualValue, _nw2Type = "String"}
                elseif (nw2Type == "Bool") then
                    state.nw2Vars[key] = {value = actualValue, _nw2Type = "Bool"}
                end
            end
        end
    end

    -- save custom weapon data (only values that differ from defaults)
    state.customData = {}
    local wepTable = weapon:GetTable()
    local defaultTable = weapons.GetStored(weaponClass)

    if (wepTable) then
        for k, v in pairs(wepTable) do
            if (not WEAPON_STATE_BLACKLIST[k]) then
                local vType = type(v)
                if (vType != "function" and vType != "userdata") then
                    local shouldSave = false

                    if (defaultTable and defaultTable[k] != nil) then
                        shouldSave = defaultTable[k] != v -- only save if changed
                    else
                        shouldSave = true -- no default, save it
                    end

                    if (shouldSave) then
                        if (vType == "table") then
                            state.customData[k] = DeepCopyTable(v)
                        else
                            state.customData[k] = v
                        end
                    end
                end
            end
        end
    end

    if (weapon.OnVirtualSave and isfunction(weapon.OnVirtualSave)) then
        pcall(weapon.OnVirtualSave, weapon, state)
    end

    self.PlayerWeapons[ply].weaponData[weaponClass] = state
end

function VirtualWeapons:RestoreWeaponState(ply, weapon)
    if (not IsValid(weapon)) then
        return
    end

    local weaponClass = weapon:GetClass()

    -- don't restore state for tool gun
    if (weaponClass == "gmod_tool") then
        self.PlayerWeapons[ply].weaponData[weaponClass] = nil
        return
    end

    local state = self.PlayerWeapons[ply].weaponData[weaponClass]

    if (not state) then
        return
    end

    weapon:SetClip1(state.clip1 or 0)
    weapon:SetClip2(state.clip2 or 0)

    -- restore NW variables
    if (state.nwVars) then
        for key, value in pairs(state.nwVars) do
            local vType = type(value)

            if (vType == "table" and value._isVector) then
                weapon:SetNWVector(key, Vector(value.x, value.y, value.z))
            elseif (vType == "table" and value._isAngle) then
                weapon:SetNWAngle(key, Angle(value.p, value.y, value.r))
            elseif (vType == "table" and value._isEntity) then
                local ent = Entity(value.entIndex)
                weapon:SetNWEntity(key, IsValid(ent) and ent or NULL)
            elseif (vType == "number") then
                if (value == math.floor(value)) then
                    weapon:SetNWInt(key, value)
                else
                    weapon:SetNWFloat(key, value)
                end
            elseif (vType == "string") then
                weapon:SetNWString(key, value)
            elseif (vType == "boolean") then
                weapon:SetNWBool(key, value)
            end
        end
    end

    -- restore NW2 variables
    if (state.nw2Vars) then
        for key, savedData in pairs(state.nw2Vars) do
            if (type(savedData) == "table" and savedData._nw2Type) then
                local nw2Type = savedData._nw2Type

                if (nw2Type == "Vector") then
                    weapon:SetNW2Vector(key, Vector(savedData.x, savedData.y, savedData.z))
                elseif (nw2Type == "Angle") then
                    weapon:SetNW2Angle(key, Angle(savedData.p, savedData.y, savedData.r))
                elseif (nw2Type == "Entity") then
                    local ent = Entity(savedData.entIndex)
                    weapon:SetNW2Entity(key, IsValid(ent) and ent or NULL)
                elseif (nw2Type == "Int") then
                    weapon:SetNW2Int(key, savedData.value)
                elseif (nw2Type == "Float") then
                    weapon:SetNW2Float(key, savedData.value)
                elseif (nw2Type == "String") then
                    weapon:SetNW2String(key, savedData.value)
                elseif (nw2Type == "Bool") then
                    weapon:SetNW2Bool(key, savedData.value)
                end
            end
        end
    end

    if (state.customData) then
        local wepTable = weapon:GetTable()
        for k, v in pairs(state.customData) do
            wepTable[k] = v
        end
    end

    if (weapon.OnVirtualRestore and isfunction(weapon.OnVirtualRestore)) then
        pcall(weapon.OnVirtualRestore, weapon, state)
    end
end

VirtualWeapons.oldGive = VirtualWeapons.oldGive or FindMetaTable("Player").Give
VirtualWeapons.oldStripWeapons = VirtualWeapons.oldStripWeapons or FindMetaTable("Player").StripWeapons
VirtualWeapons.oldStripWeapon = VirtualWeapons.oldStripWeapon or FindMetaTable("Player").StripWeapon
VirtualWeapons.oldGiveAmmo = VirtualWeapons.oldGiveAmmo or FindMetaTable("Player").GiveAmmo

hook.Add("PlayerDisconnected", "VirtualWeapons_Cleanup", function(ply)
    VirtualWeapons.PlayerWeapons[ply] = nil
    VirtualWeapons.BlockNextAmmo[ply] = nil
    VirtualWeapons.SwitchCooldowns[ply] = nil
    VirtualWeapons.StrippingWeapons[ply] = nil
end)

hook.Add("PlayerSpawn", "VirtualWeapons_Init", function(ply)
    VirtualWeapons:InitPlayer(ply)

    timer.Simple(0.1, function()
        if (IsValid(ply)) then
            VirtualWeapons:NetworkWeaponsToPlayer(ply)
        end
    end)
end)

hook.Add("PlayerDeath", "VirtualWeapons_ClearOnDeath", function(ply, inflictor, attacker)
    VirtualWeapons:ClearAllWeapons(ply)
end)

hook.Add("OnPlayerChangedTeam", "VirtualWeapons_ClearOnJobChange", function(ply, oldTeam, newTeam)
    VirtualWeapons:ClearAllWeapons(ply)
end)

hook.Add("playerBoughtCustomEntity", "VirtualWeapons_JobChange", function(ply, tbl, entity, price)
    if (tbl and tbl.cmd and string.find(tbl.cmd, "^team_")) then
        VirtualWeapons:ClearAllWeapons(ply)
    end
end)

hook.Add("EntityRemoved", "VirtualWeapons_CleanupRemoved", function(ent)
    if (not ent:IsWeapon()) then
        return
    end

    local owner = ent:GetOwner()
    if (not IsValid(owner) or not owner:IsPlayer()) then
        return
    end

    local weaponClass = ent:GetClass()
    if (not VirtualWeapons:ShouldVirtualizeEntity(ent)) then
        return
    end

    if (VirtualWeapons.StrippingWeapons[owner] and VirtualWeapons.StrippingWeapons[owner][weaponClass]) then
        VirtualWeapons.StrippingWeapons[owner][weaponClass] = nil
        return
    end

    VirtualWeapons:InitPlayer(owner)

    if (VirtualWeapons.PlayerWeapons[owner].active == weaponClass) then
        for i, wep in ipairs(VirtualWeapons.PlayerWeapons[owner].weapons) do
            if (wep == weaponClass) then
                table.remove(VirtualWeapons.PlayerWeapons[owner].weapons, i)
                break
            end
        end

        VirtualWeapons.PlayerWeapons[owner].weaponSet[weaponClass] = nil
        VirtualWeapons.PlayerWeapons[owner].weaponData[weaponClass] = nil
        VirtualWeapons.PlayerWeapons[owner].active = nil

        VirtualWeapons:NetworkWeaponsToPlayer(owner)
    end
end)

function VirtualWeapons:AddWeapon(ply, weaponClass)
    if (not IsValid(ply) or not isstring(weaponClass)) then return false end

    if (not self:ShouldVirtualize(weaponClass)) then return false end

    self:InitPlayer(ply)

    if (self.PlayerWeapons[ply].weaponSet[weaponClass]) then return false end

    table.insert(self.PlayerWeapons[ply].weapons, weaponClass)
    self.PlayerWeapons[ply].weaponSet[weaponClass] = true

    self:NetworkWeaponsToPlayer(ply)

    return true
end

function VirtualWeapons:RemoveWeapon(ply, weaponClass)
    if (not IsValid(ply) or not isstring(weaponClass)) then return false end

    self:InitPlayer(ply)

    if (not self.PlayerWeapons[ply].weaponSet[weaponClass]) then return false end

    for i, wep in ipairs(self.PlayerWeapons[ply].weapons) do
        if (wep == weaponClass) then
            table.remove(self.PlayerWeapons[ply].weapons, i)
            break
        end
    end

    self.PlayerWeapons[ply].weaponSet[weaponClass] = nil

    if (self.PlayerWeapons[ply].active == weaponClass) then
        local weapon = ply:GetWeapon(weaponClass)
        if (IsValid(weapon) and weapon.Holster and isfunction(weapon.Holster)) then
            pcall(weapon.Holster, weapon)
        end

        self:StripWeaponSafely(ply, weaponClass)
        self.PlayerWeapons[ply].active = nil
    end

    self:NetworkWeaponsToPlayer(ply)
    return true
end

function VirtualWeapons:HasWeapon(ply, weaponClass)
    if (not IsValid(ply) or not isstring(weaponClass)) then return false end

    self:InitPlayer(ply)

    return self.PlayerWeapons[ply].weaponSet[weaponClass] == true
end

function VirtualWeapons:ClearAllWeapons(ply)
    if (not IsValid(ply)) then
        return
    end

    self:InitPlayer(ply)

    if (self.PlayerWeapons[ply].active) then
        local weapon = ply:GetWeapon(self.PlayerWeapons[ply].active)
        if (IsValid(weapon) and weapon.Holster and isfunction(weapon.Holster)) then
            pcall(weapon.Holster, weapon)
        end

        self:StripWeaponSafely(ply, self.PlayerWeapons[ply].active)
    end

    self.PlayerWeapons[ply].weapons = {}
    self.PlayerWeapons[ply].weaponSet = {}
    self.PlayerWeapons[ply].weaponData = {}
    self.PlayerWeapons[ply].active = nil

    self:NetworkWeaponsToPlayer(ply)
end

function VirtualWeapons:GetWeapons(ply)
    if (not IsValid(ply)) then
        return {}
    end

    self:InitPlayer(ply)

    return self.PlayerWeapons[ply].weapons
end

function VirtualWeapons:SwitchToWeapon(ply, weaponClass)
    if (not IsValid(ply) or not isstring(weaponClass)) then return false end

    self:InitPlayer(ply)

    -- rate limiting
    local now = CurTime()
    local lastSwitch = self.SwitchCooldowns[ply] or 0
    if (now - lastSwitch < SWITCH_COOLDOWN) then return false end
    self.SwitchCooldowns[ply] = now

    if (not self:HasWeapon(ply, weaponClass)) then
        return false
    end

    if (self.PlayerWeapons[ply].active == weaponClass) then
        ply:SelectWeapon(weaponClass)
        return true
    end

    -- strip current weapon (save state, holster, remove entity)
    if (self.PlayerWeapons[ply].active) then
        local currentWeapon = ply:GetWeapon(self.PlayerWeapons[ply].active)
        if (IsValid(currentWeapon)) then
            if (currentWeapon.OnVirtualHolster and isfunction(currentWeapon.OnVirtualHolster)) then
                pcall(currentWeapon.OnVirtualHolster, currentWeapon)
            end

            self:SaveWeaponState(ply, currentWeapon)

            if (currentWeapon.Holster and isfunction(currentWeapon.Holster)) then
                pcall(currentWeapon.Holster, currentWeapon)
            end

            self:StripWeaponSafely(ply, self.PlayerWeapons[ply].active)
        end
    else
        local currentWeapon = ply:GetActiveWeapon()
        if (IsValid(currentWeapon)) then
            local currentClass = currentWeapon:GetClass()

            if (self:ShouldVirtualizeEntity(currentWeapon)) then
                local wasAdded = false
                if (not self.PlayerWeapons[ply].weaponSet[currentClass]) then
                    table.insert(self.PlayerWeapons[ply].weapons, currentClass)
                    self.PlayerWeapons[ply].weaponSet[currentClass] = true
                    wasAdded = true
                end

                if (currentWeapon.OnVirtualHolster and isfunction(currentWeapon.OnVirtualHolster)) then
                    pcall(currentWeapon.OnVirtualHolster, currentWeapon)
                end

                self:SaveWeaponState(ply, currentWeapon)

                if (currentWeapon.Holster and isfunction(currentWeapon.Holster)) then
                    pcall(currentWeapon.Holster, currentWeapon)
                end

                self:StripWeaponSafely(ply, currentClass)
                self.PlayerWeapons[ply].active = currentClass

                if (wasAdded) then
                    self:NetworkWeaponsToPlayer(ply)
                end
            else
                if (currentWeapon.Holster and isfunction(currentWeapon.Holster)) then
                    pcall(currentWeapon.Holster, currentWeapon)
                end

                self:StripWeaponSafely(ply, currentClass)
            end
        end
    end

    -- block some weaponbase's auto-ammo for re-equipped weapons
    local hasBeenDeployedBefore = self.PlayerWeapons[ply].weaponData[weaponClass] != nil
    local shouldGiveAmmo = not hasBeenDeployedBefore

    if (hasBeenDeployedBefore) then
        VirtualWeapons.BlockNextAmmo[ply] = {
            weaponClass = weaponClass,
            time = CurTime()
        }
    end

    self.BypassGiveHook = true
    local newWeapon = VirtualWeapons.oldGive(ply, weaponClass, not shouldGiveAmmo)
    self.BypassGiveHook = false

    if (not IsValid(newWeapon)) then
        VirtualWeapons.BlockNextAmmo[ply] = nil
        return false
    end

    self.PlayerWeapons[ply].active = weaponClass

    if (hasBeenDeployedBefore) then
        VirtualWeapons:RestoreWeaponState(ply, newWeapon)
    else
        VirtualWeapons:SaveWeaponState(ply, newWeapon)
    end

    if (newWeapon.OnVirtualDeploy and isfunction(newWeapon.OnVirtualDeploy)) then
        pcall(newWeapon.OnVirtualDeploy, newWeapon, hasBeenDeployedBefore)
    end

    ply:SelectWeapon(weaponClass)

    return true
end

function VirtualWeapons:NetworkWeaponsToPlayer(ply)
    if (not IsValid(ply)) then
        return
    end

    self:InitPlayer(ply)

    net.Start("VirtualWeapons_SendList")
    net.WriteUInt(#self.PlayerWeapons[ply].weapons, 16)
    for _, weaponClass in ipairs(self.PlayerWeapons[ply].weapons) do
        net.WriteString(weaponClass)
    end
    net.Send(ply)
end

net.Receive("VirtualWeapons_SwitchTo", function(len, ply)
    if (not IsValid(ply)) then
        return
    end

    local weaponClass = net.ReadString()

    -- validate client input
    if (not weaponClass or weaponClass == "" or #weaponClass > 64) then
        return
    end

    if (not isstring(weaponClass)) then
        return
    end

    VirtualWeapons:SwitchToWeapon(ply, weaponClass)
end)

hook.Add("PlayerGiveSWEP", "VirtualWeapons_InterceptGive", function(ply, weaponClass, swep)
    if (not VirtualWeapons.BypassGiveHook and VirtualWeapons:ShouldVirtualize(weaponClass)) then
        if (VirtualWeapons:AddWeapon(ply, weaponClass)) then
            VirtualWeapons:SwitchToWeapon(ply, weaponClass)
        end
        return false
    end
end)

hook.Add("PlayerSwitchWeapon", "VirtualWeapons_SmoothSwitch", function(ply, oldWeapon, newWeapon)
    if (not IsValid(ply) or not IsValid(newWeapon)) then
        return
    end

    VirtualWeapons:InitPlayer(ply)

    if (IsValid(oldWeapon)) then
        local oldClass = oldWeapon:GetClass()
        local newClass = newWeapon:GetClass()

        if (VirtualWeapons.PlayerWeapons[ply].active == oldClass and oldClass != newClass) then
            if (oldWeapon.OnVirtualHolster and isfunction(oldWeapon.OnVirtualHolster)) then
                pcall(oldWeapon.OnVirtualHolster, oldWeapon)
            end

            VirtualWeapons:SaveWeaponState(ply, oldWeapon)

            if (oldWeapon.Holster and isfunction(oldWeapon.Holster)) then
                pcall(oldWeapon.Holster, oldWeapon)
            end

            if (not VirtualWeapons.PlayerWeapons[ply].weaponSet[newClass]) then
                VirtualWeapons:StripWeaponSafely(ply, oldClass)
                VirtualWeapons.PlayerWeapons[ply].active = nil
            end
        end
    end

    local weaponClass = newWeapon:GetClass()
    if (VirtualWeapons.PlayerWeapons[ply].weaponData[weaponClass]) then
        newWeapon.VW_FastDeploy = true
    end
end)

FindMetaTable("Player").Give = function(ply, weaponClass, bNoAmmo)
    if (not IsValid(ply) or not isstring(weaponClass)) then return NULL end

    VirtualWeapons:InitPlayer(ply)

    local wep = VirtualWeapons.oldGive(ply, weaponClass, bNoAmmo)

    if (IsValid(wep) and VirtualWeapons:ShouldVirtualizeEntity(wep)) then
        local currentActive = ply:GetActiveWeapon()
        local shouldSwitch = not IsValid(currentActive) or not VirtualWeapons.PlayerWeapons[ply].active

        VirtualWeapons:StripWeaponSafely(ply, weaponClass)

        if (VirtualWeapons:AddWeapon(ply, weaponClass) and shouldSwitch) then
            VirtualWeapons:SwitchToWeapon(ply, weaponClass)
        end
        return NULL
    end

    return wep
end

FindMetaTable("Player").StripWeapons = function(ply)
    if (not IsValid(ply)) then
        return
    end

    VirtualWeapons:ClearAllWeapons(ply)
    return VirtualWeapons.oldStripWeapons(ply)
end

FindMetaTable("Player").StripWeapon = function(ply, weaponClass)
    if (not IsValid(ply) or not isstring(weaponClass)) then
        return
    end

    local isSafeStrip = VirtualWeapons.StrippingWeapons[ply] and VirtualWeapons.StrippingWeapons[ply][weaponClass]
    if (not isSafeStrip) then
        VirtualWeapons:RemoveWeapon(ply, weaponClass)
    end
    return VirtualWeapons.oldStripWeapon(ply, weaponClass)
end

FindMetaTable("Player").GiveAmmo = function(ply, amount, ammoType, hidePopup)
    if (not IsValid(ply)) then
        return 0
    end

    if (VirtualWeapons.BypassAmmoHook) then
        return VirtualWeapons.oldGiveAmmo(ply, amount, ammoType, hidePopup)
    end

    -- block some weaponbase's timer.Simple(0) ammo calls for re-equipped weapons
    local blockData = VirtualWeapons.BlockNextAmmo[ply]
    if (blockData) then
        local timeSinceBlock = CurTime() - blockData.time

        if (timeSinceBlock < 0.2) then
            local activeWeapon = ply:GetActiveWeapon()
            if (IsValid(activeWeapon) and activeWeapon:GetClass() == blockData.weaponClass) then
                VirtualWeapons.BlockNextAmmo[ply] = nil
                return 0
            end
        else
            VirtualWeapons.BlockNextAmmo[ply] = nil
        end
    end

    return VirtualWeapons.oldGiveAmmo(ply, amount, ammoType, hidePopup)
end