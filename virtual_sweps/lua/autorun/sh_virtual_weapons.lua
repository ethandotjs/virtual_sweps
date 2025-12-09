AddCSLuaFile("virtual_sweps/cl_virtual_weapons.lua")

if (SERVER) then
    include("virtual_sweps/sv_virtual_weapons.lua")
else
    include("virtual_sweps/cl_virtual_weapons.lua")
end