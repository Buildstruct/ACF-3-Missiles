AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")

local LoadingRadius, ReceivingRadius = include("shared.lua")
local LoadingBoxMin, LoadingBoxMax = -Vector(LoadingRadius, LoadingRadius, LoadingRadius), Vector(LoadingRadius, LoadingRadius, LoadingRadius)
local StillTimeToLink            = 3 -- Must be relatively still for X seconds to start loading
local DistanceTravelledTolerance = 2

ENT.ACF_Limit = 2
-- dbg cant be set in the same statement because shouldDbg isnt true until after that statement - hence the semicolon separator
local shouldDbg, dbg = true; dbg = shouldDbg and function(msg) print(msg) end or function() end

local ACF      		= ACF
local Clock         = ACF.Utilities.Clock
local Classes  		= ACF.Classes
local Entities 		= Classes.Entities
local Utilities   	= ACF.Utilities
local WireIO      	= Utilities.WireIO

ACF.RegisterClassLink("acf_groundloader", "acf_ammo", function(This, Crate)
	local Crates = This:ACF_GetUserVar("LinkedAmmoCrates")
	if not Crates then return false, "Internal error! Crates doesn't exist, auto-register went horribly wrong, get March..." end

	if Crates[Crate] then return false, "This ground loader is already linked to this crate." end
	if Crate.IsRefill then return false, "Refill crates cannot be linked to ground loaders." end
	if Crate:GetPos():Distance(This:GetPos()) > ReceivingRadius then return false, "This crate is too far away from this ground loader." end

	Crates[Crate] = true

	This:UpdateOverlay(true)
	return true, "Crate linked successfully."
end)

local Outputs = {
	"Entity (The entity itself) [ENTITY]"
}

function ENT:ACF_PreSpawn(_, _, _, _)
	self.ACF = self.ACF or {}
	ACF.Contraption.SetModel(self, "models/props_vehicles/generatortrailer01.mdl")
end

function ENT:PreEntityCopy()
	if IsValid(self.Pod) then
		duplicator.StoreEntityModifier(self, "LuaSeatID", {self.Pod:EntIndex()})
	end
end

function ENT:ACF_PostSpawn(_, _, _, ClientData)
	ACF.Contraption.SetMass(self, 20000)
	WireIO.SetupOutputs(self, Outputs, ClientData)
	WireLib.TriggerOutput(self, "Entity", self)

	self.TrackedRacks  = {}
	self.TrackData = {}
	ACF.AugmentedTimer(function(Cfg) self:CheckForNewRacks(Cfg) end, function() return IsValid(self) end, nil, {MinTime = 1, MaxTime = 2})
	ACF.AugmentedTimer(function(Cfg) self:CheckOnTrackedRacks(Cfg) end, function() return IsValid(self) end, nil, {MinTime = 0.5, MaxTime = 1})
end

local function SimpleClass()
	return setmetatable({}, {__call = function(self, ...)
		local obj = setmetatable({}, {__index = self, __tostring = self.ToString})
		if self.__new then self.__new(obj, ...) end
		return obj
	end})
end

local RackTrackData = SimpleClass()
do
	function RackTrackData:__new(Rack)
		self.Rack = Rack
		self.LastPos = Rack:GetPos()
		self.Complete = false
		self:ResetTime()
	end

	function RackTrackData:ResetTime()
		self.LastMoveTime = Clock.CurTime
	end

	function RackTrackData:IsComplete() return self.Complete end

	function RackTrackData:TryLink(Crates)
		if not IsValid(self.Rack) then return end
		-- Evaluate the validity of the rack.
		-- Only allow baseplate-parented & aircraft baseplates.
		local Rack       = self.Rack

		local Contraption = Rack:GetContraption()
		if not Contraption then self.Complete = true return end

		local Base = Contraption.Base
		if not IsValid(Base) then self.Complete = true return end
		if Base:ACF_GetUserVar("BaseplateType") ~= "Aircraft" then self.Complete = true return end

		-- Evaluate the current condition.
		local CurrentPos = Rack:GetPos()
		local LastPos    = self.LastPos
		local DeltaPos   = (CurrentPos - LastPos)
		self.LastPos = CurrentPos
		local DistanceTravelled = DeltaPos:Length()

		if DistanceTravelled > DistanceTravelledTolerance then
			-- Reset last move time
			self:ResetTime()
			dbg("Moved too much!")
		else
			-- Compare last still time to now
			local DeltaTime = Clock.CurTime - self.LastMoveTime
			dbg("Still, waiting... delta-time " .. DeltaTime)
			if DeltaTime > StillTimeToLink then -- We can link, the rack has been still for X seconds
				-- Try linking all crates to the rack
				for Crate in pairs(Crates) do
					if IsValid(Crate) then
						dbg(Crate, Rack, "linked!")
						Crate:Link(Rack)
					end
				end
				self.Complete = true
				return true
			end
		end

		return false
	end
end

function ENT:CheckForNewRacks(_)
	self.TrackedRacks = self.TrackedRacks or {}
	self.TrackData = self.TrackData or {}

	local TrackedRacks, TrackData = self.TrackedRacks, self.TrackData
	-- Empty the tracking table to start with a clean slate
	-- After processing entities close by, perform delta operations
	table.Empty(TrackedRacks)
	-- Find new racks in distance
	local LoadPos = self:GetPos()
	-- In theory this should be faster than FindInSphere because FindInBox uses spatial partitions
	-- which we can then get every rack from and do class/sphere checks on individually.
	local NewRacks = ents.FindInBox(LoadPos + LoadingBoxMin, LoadPos + LoadingBoxMax)
	for _, Ent in ipairs(NewRacks) do
		-- If rack and within loading distance, re-write it to the tracking table
		if Ent:GetClass() == "acf_rack" then
			local EntPos = Ent:GetPos()
			local Dist = EntPos:Distance(LoadPos)
			if Dist < LoadingRadius then
				TrackedRacks[Ent] = EntPos
			end
		end
	end

	-- Any rack that was in TrackData that is no longer in TrackedRacks must be untracked.
	for Rack in pairs(TrackData) do
		if not TrackedRacks[Rack] then
			TrackData[Rack] = nil
			dbg("Stopped tracking", Rack)
		end
	end
	-- Any rack that was not in TrackData but now is in TrackedRacks must be initially tracked
	-- We assume the rack was still when it entered
	for Rack in pairs(TrackedRacks) do
		if not TrackData[Rack] then
			TrackData[Rack] = RackTrackData(Rack)
			dbg("Started tracking", Rack)
		end
	end
end

function ENT:CheckOnTrackedRacks(_)
	local TrackedRacks, TrackData = self.TrackedRacks, self.TrackData

	-- Something hasn't run yet - that's ok we'll wait
	if not TrackedRacks then return end
	if not TrackData then return end

	local Crates = self:ACF_GetUserVar("LinkedAmmoCrates")

	for _, State in pairs(TrackData) do
		if not State:IsComplete() then
			State:TryLink(Crates)
		end
	end
end

-- TODO: status
local Text = "Ground Loader"
function ENT:SetStatus(Status)
	self.Status = Status
	self:UpdateOverlay()
end

function ENT:UpdateOverlayText()
	return Text:format()
end

function ENT:Think()

end

function ENT:ACF_PostMenuSpawn()
	self:DropToFloor()
	self:SetAngles(self:GetAngles() + Angle(0, -90, 0))
end

Entities.Register()