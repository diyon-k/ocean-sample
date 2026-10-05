--!native
--
--	Author(s): Di
--	Module: OceanZones.lua
--
--	OceanZone parts (tagged, authored, replicated -- deterministic on every
--	machine): AmpScale scales every wave inside the part's XZ footprint,
--	smoothstepped over FalloffStuds beyond the edge. Choppy straits, calm
--	coves, storm patches -- all data. Session-lifetime tag listeners.
--	GetZoneScaleAt runs per vertex on every re-lattice, so the parts are
--	snapshotted into flat arrays: instance property/attribute reads are engine
--	calls and must never sit in that loop.
--

local CollectionService = game:GetService("CollectionService")

local ZONE_TAG = "OceanZone"
-- Wide enough to span several cells on the coarsest (32-stud) ring and a
-- swell wavelength up close; shorter bands read as a step in the water.
local DEFAULT_FALLOFF = 160

local zoneParts: { BasePart } = {}
local zoneCount = 0
local zoneVersion = 0
local zoneCenterX: { number } = {}
local zoneCenterZ: { number } = {}
local zoneHalfX: { number } = {}
local zoneHalfZ: { number } = {}
local zoneAmp: { number } = {}
local zoneFalloff: { number } = {}

local function rebuildZoneCache()
	zoneCount = 0
	zoneVersion += 1

	for _, part in zoneParts do
		local ampScale = part:GetAttribute("AmpScale")
		if typeof(ampScale) ~= "number" then
			continue
		end

		local falloffAttr = part:GetAttribute("FalloffStuds")
		zoneCount += 1
		zoneCenterX[zoneCount] = part.Position.X
		zoneCenterZ[zoneCount] = part.Position.Z
		zoneHalfX[zoneCount] = part.Size.X / 2
		zoneHalfZ[zoneCount] = part.Size.Z / 2
		zoneAmp[zoneCount] = ampScale
		zoneFalloff[zoneCount] = if typeof(falloffAttr) == "number" then math.max(falloffAttr, 1) else DEFAULT_FALLOFF
	end
end

local function watchZonePart(part: BasePart)
	table.insert(zoneParts, part)
	part.AttributeChanged:Connect(rebuildZoneCache)
	part:GetPropertyChangedSignal("Position"):Connect(rebuildZoneCache)
	part:GetPropertyChangedSignal("Size"):Connect(rebuildZoneCache)
end

CollectionService:GetInstanceAddedSignal(ZONE_TAG):Connect(function(instance)
	if instance:IsA("BasePart") then
		watchZonePart(instance)
		rebuildZoneCache()
	end
end)
CollectionService:GetInstanceRemovedSignal(ZONE_TAG):Connect(function(instance)
	local at = table.find(zoneParts, instance)
	if at then
		table.remove(zoneParts, at)
		rebuildZoneCache()
	end
end)
for _, instance in CollectionService:GetTagged(ZONE_TAG) do
	if instance:IsA("BasePart") then
		watchZonePart(instance)
	end
end
rebuildZoneCache()

local OceanZones = {}

-- Bumped every time the zone cache changes. Zone parts are live-editable, so
-- anything that BAKES GetZoneScaleAt rather than calling it per frame must key
-- that bake on this and redo it when the number moves.
function OceanZones.GetVersion(): number
	return zoneVersion
end

-- Amplitude multiplier from authored OceanZone parts at world (x, z).
function OceanZones.GetZoneScaleAt(x: number, z: number): number
	local scale = 1

	for index = 1, zoneCount do
		local outside = math.max(
			math.abs(x - zoneCenterX[index]) - zoneHalfX[index],
			math.abs(z - zoneCenterZ[index]) - zoneHalfZ[index]
		)
		local falloff = zoneFalloff[index]

		if outside < falloff then
			local alpha = 1 - math.max(outside, 0) / falloff
			alpha = alpha * alpha * (3 - 2 * alpha)
			scale *= 1 + (zoneAmp[index] - 1) * alpha
		end
	end

	return scale
end

return OceanZones
