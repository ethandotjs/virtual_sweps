util.AddNetworkString("VirtualWeapons_SendList")
util.AddNetworkString("VirtualWeapons_SwitchTo")

VirtualWeapons = VirtualWeapons or {}
VirtualWeapons.PlayerWeapons = VirtualWeapons.PlayerWeapons or {}
VirtualWeapons.BlockNextAmmo = VirtualWeapons.BlockNextAmmo or {}
VirtualWeapons.SwitchCooldowns = VirtualWeapons.SwitchCooldowns or {}
VirtualWeapons.BypassStripHook = false
VirtualWeapons.BypassGiveHook = false
VirtualWeapons.BypassAmmoHook = false

local SWITCH_COOLDOWN = 0.1 -- anti-spam

function VirtualWeapons:InitPlayer(ply)
    if not self.PlayerWeapons[ply] then
        self.PlayerWeapons[ply] = {
            weapons = {},    -- array for iteration/networking
            weaponSet = {},  -- hash table for O(1) lookups
            weaponData = {}, -- saved weapon states (clip, ammo, custom data)
            active = nil
        }
    else
        -- hotloading support
        if not self.PlayerWeapons[ply].weaponSet then
            self.PlayerWeapons[ply].weaponSet = {}
            for _, weaponClass in ipairs(self.PlayerWeapons[ply].weapons or {}) do
                self.PlayerWeapons[ply].weaponSet[weaponClass] = true
            end
        end
    end
end

-- deep copy with circular reference protection
local function DeepCopyTable(tbl, seen)
    if type(tbl) ~= "table" then return tbl end

    seen = seen or {}
    if seen[tbl] then return seen[tbl] end -- already copied, return reference

    local copy = {}
    seen[tbl] = copy

    for k, v in pairs(tbl) do
        if type(v) == "table" then
            copy[k] = DeepCopyTable(v, seen)
        elseif type(v) ~= "function" then
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
    if not IsValid(weapon) then return end

    local weaponClass = weapon:GetClass()

    -- tool gun doesn't play too nice
    if weaponClass == "gmod_tool" then
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

    -- save custom weapon data (only values that differ from defaults)
    state.customData = {}
    local wepTable = weapon:GetTable()
    local defaultTable = weapons.GetStored(weaponClass)

    if wepTable then
        for k, v in pairs(wepTable) do
            if not WEAPON_STATE_BLACKLIST[k] then
                local vType = type(v)
                if vType ~= "function" and vType ~= "userdata" then
                    local shouldSave = false

                    if defaultTable and defaultTable[k] ~= nil then
                        shouldSave = defaultTable[k] ~= v -- only save if changed
                    else
                        shouldSave = true -- no default, save it
                    end

                    if shouldSave then
                        if vType == "table" then
                            state.customData[k] = DeepCopyTable(v)
                        else
                            state.customData[k] = v
                        end
                    end
                end
            end
        end
    end

    self.PlayerWeapons[ply].weaponData[weaponClass] = state
end

function VirtualWeapons:RestoreWeaponState(ply, weapon)
    if not IsValid(weapon) then return end

    local weaponClass = weapon:GetClass()

    -- don't restore state for tool gun
    if weaponClass == "gmod_tool" then
        self.PlayerWeapons[ply].weaponData[weaponClass] = nil
        return
    end

    local state = self.PlayerWeapons[ply].weaponData[weaponClass]

    if not state then return end

    weapon:SetClip1(state.clip1 or 0)
    weapon:SetClip2(state.clip2 or 0)

    if state.customData then
        local wepTable = weapon:GetTable()
        for k, v in pairs(state.customData) do
            wepTable[k] = v
        end
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
end)

hook.Add("PlayerSpawn", "VirtualWeapons_Init", function(ply)
    VirtualWeapons:InitPlayer(ply)

    timer.Simple(0.1, function()
        if IsValid(ply) then
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
    if tbl and tbl.cmd and string.find(tbl.cmd, "^team_") then
        VirtualWeapons:ClearAllWeapons(ply)
    end
end)

function VirtualWeapons:AddWeapon(ply, weaponClass)
    if not IsValid(ply) or not isstring(weaponClass) then return false end

    self:InitPlayer(ply)

    if self.PlayerWeapons[ply].weaponSet[weaponClass] then return false end

    table.insert(self.PlayerWeapons[ply].weapons, weaponClass)
    self.PlayerWeapons[ply].weaponSet[weaponClass] = true

    self:NetworkWeaponsToPlayer(ply)

    return true
end

function VirtualWeapons:RemoveWeapon(ply, weaponClass)
    if not IsValid(ply) or not isstring(weaponClass) then return false end

    self:InitPlayer(ply)

    if not self.PlayerWeapons[ply].weaponSet[weaponClass] then return false end

    for i, wep in ipairs(self.PlayerWeapons[ply].weapons) do
        if wep == weaponClass then
            table.remove(self.PlayerWeapons[ply].weapons, i)
            break
        end
    end

    self.PlayerWeapons[ply].weaponSet[weaponClass] = nil

    if self.PlayerWeapons[ply].active == weaponClass then
        local weapon = ply:GetWeapon(weaponClass)
        if IsValid(weapon) and weapon.Holster and isfunction(weapon.Holster) then
            pcall(weapon.Holster, weapon)
        end

        self.BypassStripHook = true
        VirtualWeapons.oldStripWeapon(ply, weaponClass)
        self.BypassStripHook = false
        self.PlayerWeapons[ply].active = nil
    end

    self:NetworkWeaponsToPlayer(ply)
    return true
end

function VirtualWeapons:HasWeapon(ply, weaponClass)
    if not IsValid(ply) or not isstring(weaponClass) then return false end

    self:InitPlayer(ply)

    return self.PlayerWeapons[ply].weaponSet[weaponClass] == true
end

function VirtualWeapons:ClearAllWeapons(ply)
    if not IsValid(ply) then return end

    self:InitPlayer(ply)

    if self.PlayerWeapons[ply].active then
        local weapon = ply:GetWeapon(self.PlayerWeapons[ply].active)
        if IsValid(weapon) and weapon.Holster and isfunction(weapon.Holster) then
            pcall(weapon.Holster, weapon)
        end

        self.BypassStripHook = true
        VirtualWeapons.oldStripWeapon(ply, self.PlayerWeapons[ply].active)
        self.BypassStripHook = false
    end

    self.PlayerWeapons[ply].weapons = {}
    self.PlayerWeapons[ply].weaponSet = {}
    self.PlayerWeapons[ply].weaponData = {}
    self.PlayerWeapons[ply].active = nil

    self:NetworkWeaponsToPlayer(ply)
end

function VirtualWeapons:GetWeapons(ply)
    if not IsValid(ply) then return {} end

    self:InitPlayer(ply)

    return self.PlayerWeapons[ply].weapons
end

function VirtualWeapons:SwitchToWeapon(ply, weaponClass)
    if not IsValid(ply) or not isstring(weaponClass) then return false end

    self:InitPlayer(ply)

    -- rate limiting
    local now = CurTime()
    local lastSwitch = self.SwitchCooldowns[ply] or 0
    if now - lastSwitch < SWITCH_COOLDOWN then return false end
    self.SwitchCooldowns[ply] = now

    if not self:HasWeapon(ply, weaponClass) then return false end

    if self.PlayerWeapons[ply].active == weaponClass then
        ply:SelectWeapon(weaponClass)
        return true
    end

    -- strip current weapon (save state, holster, remove entity)
    if self.PlayerWeapons[ply].active then
        local currentWeapon = ply:GetWeapon(self.PlayerWeapons[ply].active)
        if IsValid(currentWeapon) then
            self:SaveWeaponState(ply, currentWeapon)

            if currentWeapon.Holster and isfunction(currentWeapon.Holster) then
                pcall(currentWeapon.Holster, currentWeapon)
            end

            self.BypassStripHook = true
            VirtualWeapons.oldStripWeapon(ply, self.PlayerWeapons[ply].active)
            self.BypassStripHook = false
        end
    else
        local currentWeapon = ply:GetActiveWeapon()
        if IsValid(currentWeapon) then
            local currentClass = currentWeapon:GetClass()

            if currentWeapon.Holster and isfunction(currentWeapon.Holster) then
                pcall(currentWeapon.Holster, currentWeapon)
            end

            self.BypassStripHook = true
            VirtualWeapons.oldStripWeapon(ply, currentClass)
            self.BypassStripHook = false
        end
    end

    -- block some weaponbase's auto-ammo for re-equipped weapons
    local hasBeenDeployedBefore = self.PlayerWeapons[ply].weaponData[weaponClass] ~= nil
    local shouldGiveAmmo = not hasBeenDeployedBefore

    if hasBeenDeployedBefore then
        VirtualWeapons.BlockNextAmmo[ply] = {
            weaponClass = weaponClass,
            time = CurTime()
        }
    end

    self.BypassGiveHook = true
    local newWeapon = VirtualWeapons.oldGive(ply, weaponClass, not shouldGiveAmmo)
    self.BypassGiveHook = false

    if not IsValid(newWeapon) then
        VirtualWeapons.BlockNextAmmo[ply] = nil
        return false
    end

    self.PlayerWeapons[ply].active = weaponClass

    if hasBeenDeployedBefore then
        VirtualWeapons:RestoreWeaponState(ply, newWeapon)
    else
        VirtualWeapons:SaveWeaponState(ply, newWeapon)
    end

    ply:SelectWeapon(weaponClass)

    return true
end

function VirtualWeapons:NetworkWeaponsToPlayer(ply)
    if not IsValid(ply) then return end

    self:InitPlayer(ply)

    net.Start("VirtualWeapons_SendList")
    net.WriteUInt(#self.PlayerWeapons[ply].weapons, 16)
    for _, weaponClass in ipairs(self.PlayerWeapons[ply].weapons) do
        net.WriteString(weaponClass)
    end
    net.Send(ply)
end

net.Receive("VirtualWeapons_SwitchTo", function(len, ply)
    if not IsValid(ply) then return end

    local weaponClass = net.ReadString()

    -- validate client input
    if not weaponClass or weaponClass == "" or #weaponClass > 64 then return end
    if not isstring(weaponClass) then return end

    VirtualWeapons:SwitchToWeapon(ply, weaponClass)
end)

hook.Add("PlayerGiveSWEP", "VirtualWeapons_InterceptGive", function(ply, weaponClass, swep)
    if not VirtualWeapons.BypassGiveHook then
        VirtualWeapons:AddWeapon(ply, weaponClass)
        return false
    end
end)

hook.Add("PlayerSwitchWeapon", "VirtualWeapons_SmoothSwitch", function(ply, oldWeapon, newWeapon)
    if not IsValid(ply) or not IsValid(newWeapon) then return end

    VirtualWeapons:InitPlayer(ply)

    local weaponClass = newWeapon:GetClass()
    if VirtualWeapons.PlayerWeapons[ply].weaponData[weaponClass] then
        newWeapon.VW_FastDeploy = true
    end
end)

FindMetaTable("Player").Give = function(ply, weaponClass, bNoAmmo)
    if not IsValid(ply) or not isstring(weaponClass) then return NULL end

    VirtualWeapons:InitPlayer(ply)

    if VirtualWeapons:AddWeapon(ply, weaponClass) and not VirtualWeapons.PlayerWeapons[ply].active then
        VirtualWeapons:SwitchToWeapon(ply, weaponClass)
    end
    return NULL
end

FindMetaTable("Player").StripWeapons = function(ply)
    if not IsValid(ply) then return end
    VirtualWeapons:ClearAllWeapons(ply)
    return VirtualWeapons.oldStripWeapons(ply)
end

FindMetaTable("Player").StripWeapon = function(ply, weaponClass)
    if not IsValid(ply) or not isstring(weaponClass) then return end

    if not VirtualWeapons.BypassStripHook then
        VirtualWeapons:RemoveWeapon(ply, weaponClass)
    end
    return VirtualWeapons.oldStripWeapon(ply, weaponClass)
end

FindMetaTable("Player").GiveAmmo = function(ply, amount, ammoType, hidePopup)
    if not IsValid(ply) then return 0 end

    if VirtualWeapons.BypassAmmoHook then
        return VirtualWeapons.oldGiveAmmo(ply, amount, ammoType, hidePopup)
    end

    -- block some weaponbase's timer.Simple(0) ammo calls for re-equipped weapons
    local blockData = VirtualWeapons.BlockNextAmmo[ply]
    if blockData then
        local timeSinceBlock = CurTime() - blockData.time

        if timeSinceBlock < 0.2 then
            local activeWeapon = ply:GetActiveWeapon()
            if IsValid(activeWeapon) and activeWeapon:GetClass() == blockData.weaponClass then
                VirtualWeapons.BlockNextAmmo[ply] = nil
                return 0
            end
        else
            VirtualWeapons.BlockNextAmmo[ply] = nil
        end
    end

    return VirtualWeapons.oldGiveAmmo(ply, amount, ammoType, hidePopup)
end