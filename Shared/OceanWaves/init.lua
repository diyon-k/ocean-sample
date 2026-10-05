--!native
--
--	Author(s): Di
--	Module: OceanWaves.lua
--

-- The ocean's deterministic contract. No RunService, no side effects: every
-- client (and the server, for validation) evaluates the same function of the
-- synced server clock, so all machines see an identical ocean with zero
-- replication. The mesh renderer, boats, and shore systems all consume this
-- module.
--
-- The water is a sum of layers, one child each:
--		OceanDeep	- the open sea (FFT field, calibrated, damped, shoaled)
--		OceanSurf	- the nearshore (breakers + waterline surge)
--		OceanNoise	- the seeded fields that bend and break up both
-- over data from OceanDepthField (the baked depth grid) and OceanZones
-- (authored amplitude regions). OceanGerstner is bake-only -- see its header.
--
-- This file owns the anchors (the Ocean part, sea level, the playable
-- region), the global sea state, and the public evaluations. Everything else
-- it re-exports, so consumers only ever need shared("OceanWaves").

local CollectionService = game:GetService("CollectionService")

local OceanDeep = require(script.OceanDeep) ---@module OceanDeep
local OceanDepthField = require(script.OceanDepthField) ---@module OceanDepthField
local OceanGerstner = require(script.OceanGerstner) ---@module OceanGerstner
local OceanNoise = require(script.OceanNoise) ---@module OceanNoise
local OceanSurf = require(script.OceanSurf) ---@module OceanSurf
local OceanZones = require(script.OceanZones) ---@module OceanZones
local FFTOceanSpectrum = require(script.Parent.FFTOcean.FFTOceanSpectrum) ---@module FFTOceanSpectrum

-- Dominant swell/wind travel direction in world XZ (unit). The FFT field is built
-- around this, so floating bodies drift along it (Stokes drift).
local SWELL_LEN = math.sqrt(FFTOceanSpectrum.WindX ^ 2 + FFTOceanSpectrum.WindZ ^ 2)
local SWELL_X = if SWELL_LEN > 0 then FFTOceanSpectrum.WindX / SWELL_LEN else 0
local SWELL_Z = if SWELL_LEN > 0 then FFTOceanSpectrum.WindZ / SWELL_LEN else 0

local OCEAN_TAG = "Ocean"
local HEIGHT_ITERATIONS = 3

-- Minimum baked depth (studs) that counts as real water. GetHeightAt returns
-- sea level for ANY (x, z) -- including dry land below sea level -- so submersion
-- queries must gate on the depth field, not the surface alone.
local MIN_WATER_DEPTH = 0.5

export type WaveSpec = OceanGerstner.WaveSpec

-- Global sea state. Modulates every layer. Any new input must stay
-- deterministic: baked data, replicated instances, synced clock only.
local intensity = 1

local oceanPart: BasePart? = nil
local seaLevelCache: number? = nil

local OceanWaves = {}

--
--		Re-exports
--

OceanWaves.Waves = OceanGerstner.Waves
OceanWaves.GetWaveData = OceanGerstner.GetWaveData

OceanWaves.DeepAmplitude = OceanDeep.Amplitude
OceanWaves.DeepChopMin = OceanDeep.ChopMin
OceanWaves.DeepChopMax = OceanDeep.ChopMax
OceanWaves.DeepChopDepth = OceanDeep.ChopDepth
OceanWaves.DeepShoalK = OceanDeep.ShoalK
OceanWaves.DeepCutoff = OceanDeep.Cutoff
OceanWaves.SwellCalmDist = OceanDeep.SwellCalmDist
OceanWaves.SwellFullDist = OceanDeep.SwellFullDist
OceanWaves.SwellCalmFloor = OceanDeep.SwellCalmFloor
OceanWaves.GetDeepScale = OceanDeep.GetScale

OceanWaves.Surf = OceanSurf.Surf

OceanWaves.WarpAt = OceanNoise.WarpAt
OceanWaves.EnvelopeDepthAt = OceanNoise.EnvelopeDepthAt
OceanWaves.CrestNoiseAt = OceanNoise.CrestNoiseAt
OceanWaves.EdgeNoiseAt = OceanNoise.EdgeNoiseAt

OceanWaves.SetDepthGrid = OceanDepthField.SetDepthGrid
OceanWaves.GetDepthAt = OceanDepthField.GetDepthAt
OceanWaves.GetShoreDistanceAt = OceanDepthField.GetShoreDistanceAt
OceanWaves.GetSignedShoreDistanceAt = OceanDepthField.GetSignedShoreDistanceAt
OceanWaves.IsLandNear = OceanDepthField.IsLandNear
OceanWaves.IsLandlocked = OceanDepthField.IsLandlocked
OceanWaves.IsLandAt = OceanDepthField.IsLandAt

OceanWaves.GetZoneScaleAt = OceanZones.GetZoneScaleAt
OceanWaves.GetZoneVersion = OceanZones.GetVersion

--
--		Sea state
--

function OceanWaves.GetIntensity(): number
	return intensity
end

function OceanWaves.SetIntensity(alpha: number)
	intensity = alpha
end

-- Unit XZ direction the swell travels (waves roll downwind). Floating bodies get
-- carried along this.
function OceanWaves.GetSwellDirection(): (number, number)
	return SWELL_X, SWELL_Z
end

--
--		Anchors
--

function OceanWaves.GetOceanPart(): BasePart?
	if oceanPart and oceanPart.Parent then
		return oceanPart
	end

	-- Stray tagged instances (old markers, duplicates) must never win, and
	-- the server and every client must agree: pick the largest footprint.
	local best: BasePart? = nil
	local bestArea = 0
	local tagged = CollectionService:GetTagged(OCEAN_TAG)
	for _, instance in tagged do
		if instance:IsA("BasePart") then
			local area = instance.Size.X * instance.Size.Z
			if area > bestArea then
				best = instance
				bestArea = area
			end
		end
	end

	if best and #tagged > 1 then
		warn(`{#tagged} instances carry the Ocean tag; using the largest: {best:GetFullName()}`)
	end

	oceanPart = best
	return best
end

-- Sea level is static per map: cache it so queries stay valid even when the
-- (streamed) Ocean part is not currently replicated to this client.
function OceanWaves.GetSeaLevel(): number?
	if seaLevelCache then
		return seaLevelCache
	end

	local part = OceanWaves.GetOceanPart()
	seaLevelCache = part and part.Position.Y
	return seaLevelCache
end

-- TEMP: hardcoded playable-sea region for testing. Set to nil to hand
-- control back to the Ocean part (position + RegionSizeX/Z attributes).
local REGION_OVERRIDE: { CenterX: number, CenterZ: number, SizeX: number, SizeZ: number }? = {
	CenterX = -325.4,
	CenterZ = 1066.6,
	SizeX = 5000,
	SizeZ = 5000,
}

-- Footprint of the playable sea, centered on the Ocean part: RegionSizeX /
-- RegionSizeZ attributes override Size (BaseParts cap at 2048 studs and the
-- region is usually bigger). Returns originX, originZ, sizeX, sizeZ.
function OceanWaves.GetOceanRegion(): (number?, number?, number?, number?)
	local override = REGION_OVERRIDE
	if override then
		return override.CenterX - override.SizeX / 2, override.CenterZ - override.SizeZ / 2, override.SizeX, override.SizeZ
	end

	local part = OceanWaves.GetOceanPart()
	if not part then
		return nil
	end

	local sizeX = part:GetAttribute("RegionSizeX")
	local sizeZ = part:GetAttribute("RegionSizeZ")
	local spanX = if typeof(sizeX) == "number" then sizeX else part.Size.X
	local spanZ = if typeof(sizeZ) == "number" then sizeZ else part.Size.Z

	return part.Position.X - spanX / 2, part.Position.Z - spanZ / 2, spanX, spanZ
end

function OceanWaves.GetTime(): number
	return workspace:GetServerTimeNow()
end

--
--		Surface evaluation
--

-- Horizontal chop + height of the material point resting at (x, z), relative
-- to sea level: the open-sea field plus the nearshore surf terms. The surf
-- terms are vertical only, so GetHeightAt's chop inversion is untouched.
-- The fourth return is the local peak height dy can reach (crest tests).
function OceanWaves.GetDisplacementAt(x: number, z: number, t: number?): (number, number, number, number)
	local time = t or workspace:GetServerTimeNow()

	local depth = OceanDepthField.GetDepthAt(x, z)
	local depthEff = if depth ~= nil then OceanNoise.EnvelopeDepthAt(x, z, depth) else nil
	local shoreDist = OceanDepthField.GetShoreDistanceAt(x, z)
	local ampScale = intensity * OceanZones.GetZoneScaleAt(x, z)

	local dx, dy, dz, peak = OceanDeep.DisplacementAt(x, z, time, depthEff, shoreDist, ampScale)

	if depthEff ~= nil then
		local surf, surfPeak = OceanSurf.DisplacementAt(x, z, depth :: number, depthEff :: number, shoreDist, time, ampScale)
		dy += surf
		peak += surfPeak
	end

	return dx, dy, dz, peak
end

-- BAKE-ONLY Gerstner evaluation: OceanMesh calls this once at build time so
-- the mesh's creation bounds have a plausible vertical extent. Runtime water
-- is the FFT field -- this sum never runs per frame. See OceanGerstner.
function OceanWaves.GetSurfaceAt(
	x: number,
	z: number,
	t: number?,
	waveMax: number?,
	marginalFrom: number?,
	marginalScale: number?,
	shallowDepth: number?
): (number, number, number, number, number, number, number)
	return OceanGerstner.GetSurfaceAt(intensity, x, z, t, waveMax, marginalFrom, marginalScale, shallowDepth)
end

function OceanWaves.GetNormalAt(x: number, z: number, t: number?): Vector3
	return OceanGerstner.GetNormalAt(intensity, x, z, t)
end

-- World-space water height at world (x, z): the boat / gameplay query. The
-- field displaces material points horizontally, so fixed-point iterate to find
-- the rest point whose displaced position lands on (x, z).
function OceanWaves.GetHeightAt(x: number, z: number, t: number?): number
	local time = t or workspace:GetServerTimeNow()
	local seaLevel = OceanWaves.GetSeaLevel()
	assert(seaLevel, "OceanWaves.GetHeightAt requires an Ocean-tagged part")

	local u, w = x, z
	for _ = 1, HEIGHT_ITERATIONS do
		local dx, _, dz = OceanWaves.GetDisplacementAt(u, w, time)
		u = x - dx
		w = z - dz
	end

	local _, dy, _ = OceanWaves.GetDisplacementAt(u, w, time)
	return seaLevel + dy
end

-- Gameplay submersion query: world-space Y of the animated surface at (x, z),
-- or nil where there is no real water to be under -- dry land, or a map with no
-- Ocean part. Drowning and the underwater camera both consume this so the
-- water/land gate lives in one place. Callers compare their own point's Y.
function OceanWaves.GetWaterSurfaceAt(x: number, z: number): number?
	if not OceanWaves.GetSeaLevel() then
		return nil
	end

	local depth = OceanDepthField.GetDepthAt(x, z)
	if not depth or depth <= MIN_WATER_DEPTH then
		return nil
	end

	return OceanWaves.GetHeightAt(x, z)
end

return OceanWaves
