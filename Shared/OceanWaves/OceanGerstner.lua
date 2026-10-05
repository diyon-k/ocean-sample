--!native
--
--	Author(s): Di
--	Module: OceanGerstner.lua
--
--	Bake-only: this does not render the ocean. The open sea is the FFT field
--	(OceanDeep); this Gerstner sum runs once per vertex at build time, from
--	OceanMesh, so the mesh's creation bounds have a plausible
--	vertical extent -- moving verts far outside baked bounds risks culling
--	artifacts. Nothing calls it per frame.
--
--	Keep it deterministic and roughly amplitude-matched to OceanDeep, or the
--	baked bounds stop bracketing the water that actually renders.
--

local OceanDeep = require(script.Parent.OceanDeep) ---@module OceanDeep
local OceanDepthField = require(script.Parent.OceanDepthField) ---@module OceanDepthField
local OceanNoise = require(script.Parent.OceanNoise) ---@module OceanNoise
local OceanZones = require(script.Parent.OceanZones) ---@module OceanZones

-- Dispersion gravity: THE wave-speed knob (phase speed ~ sqrt(g)). Roblox's
-- workspace.Gravity (196.2) makes water race ~4.5x faster than real-scale
-- seas; longer waves stay faster than short ones at any value here.
local WAVE_GRAVITY = 10

export type WaveSpec = {
	DirectionDegrees: number,
	Wavelength: number,
	Amplitude: number,
	Steepness: number,
}

-- Phase speed is never authored: it follows deep-water dispersion
-- (omega = sqrt(g * k)) from the wavelength, like real ocean waves.
-- Sorted by DESCENDING wavelength (asserted below): renderers pass a waveMax
-- loop bound to skip waves their mesh density cannot resolve.
--
-- Spectrum design, not a flat sum: a primary wind system (most waves within
-- ~30 deg of -10) crossed by a secondary swell system (~+55), non-harmonic
-- wavelength spacing so the surface never visibly repeats, and the two long
-- swells deliberately CLOSE in wavelength/direction -- their ~25s beat is
-- the wave-group "sets roll in, sea breathes" rhythm of a real ocean.
local WAVES: { WaveSpec } = {
	-- Two rival systems (~-10 deg and ~+45 deg) at comparable energy: crests
	-- collide and superpose into diamond seas instead of parallel rollers,
	-- and the jacobian foam paints the collisions.
	{ DirectionDegrees = -6, Wavelength = 181, Amplitude = 2.1, Steepness = 0.55 },
	{ DirectionDegrees = -14, Wavelength = 151, Amplitude = 1.6, Steepness = 0.6 },
	{ DirectionDegrees = 34, Wavelength = 133, Amplitude = 1.7, Steepness = 0.62 },
	{ DirectionDegrees = 52, Wavelength = 97, Amplitude = 1.5, Steepness = 0.7 },
	{ DirectionDegrees = -24, Wavelength = 71, Amplitude = 0.85, Steepness = 0.75 },
	{ DirectionDegrees = 8, Wavelength = 59, Amplitude = 0.7, Steepness = 0.75 },
	{ DirectionDegrees = 63, Wavelength = 43, Amplitude = 0.55, Steepness = 0.8 },
	{ DirectionDegrees = -18, Wavelength = 31, Amplitude = 0.32, Steepness = 0.85 },
	{ DirectionDegrees = 39, Wavelength = 23, Amplitude = 0.2, Steepness = 0.9 },
	{ DirectionDegrees = -2, Wavelength = 19, Amplitude = 0.14, Steepness = 0.9 },
	{ DirectionDegrees = 70, Wavelength = 16, Amplitude = 0.1, Steepness = 0.9 },
}

-- Gerstner chop: the textbook 1/N loop-safety bound reads as mushy sine
-- water when directions are spread (each wave gets ~1/11th of its pinch).
-- Boosting deliberately over-pinches; momentarily self-intersecting crests
-- land exactly where the jacobian foam paints white, so the artifact reads
-- as breaking water. 2 = subtle, 4 = stormy.
local CHOP_BOOST = 3

local sin = math.sin
local cos = math.cos

local waveCount = #WAVES
local dirX = table.create(waveCount)
local dirZ = table.create(waveCount)
local waveK = table.create(waveCount)
local waveOmega = table.create(waveCount)
local waveAmp = table.create(waveCount)
local waveChop = table.create(waveCount) -- bounded chop magnitude S / (k * N)
local waveKA = table.create(waveCount)
local waveSN = table.create(waveCount) -- S / N: crest pinch share of the normal

do
	local gravity = WAVE_GRAVITY
	for index, spec in WAVES do
		if index > 1 then
			assert(spec.Wavelength < WAVES[index - 1].Wavelength, "WAVES must be sorted by descending wavelength")
		end

		local angle = math.rad(spec.DirectionDegrees)
		local k = 2 * math.pi / spec.Wavelength

		dirX[index] = math.cos(angle)
		dirZ[index] = math.sin(angle)
		waveK[index] = k
		waveOmega[index] = math.sqrt(gravity * k)
		waveAmp[index] = spec.Amplitude
		waveChop[index] = spec.Steepness * CHOP_BOOST / (k * waveCount)
		waveKA[index] = k * spec.Amplitude
		waveSN[index] = spec.Steepness * CHOP_BOOST / waveCount
	end
end

local OceanGerstner = {}

OceanGerstner.Waves = WAVES

-- Raw per-wave constant arrays: direction, spatial/temporal frequency, and
-- the amplitude/chop/slope/pinch factors. Read-only.
function OceanGerstner.GetWaveData(): ({ number }, { number }, { number }, { number }, { number }, { number }, { number }, { number })
	return dirX, dirZ, waveK, waveOmega, waveAmp, waveChop, waveKA, waveSN
end

-- The bake evaluation. OceanMesh calls this through OceanWaves once per vertex
-- at build time; runtime water is the FFT field, so this sum never runs per
-- frame.
function OceanGerstner.GetSurfaceAt(
	intensity: number,
	x: number,
	z: number,
	t: number?,
	waveMax: number?,
	marginalFrom: number?,
	marginalScale: number?,
	shallowDepth: number?
): (number, number, number, number, number, number, number)
	local time = t or workspace:GetServerTimeNow()
	local from = marginalFrom or math.huge
	local dx, dy, dz = 0, 0, 0
	local nx, ny, nz = 0, 1, 0
	local sxx, szz, sxz = 0, 0, 0
	local zone = OceanZones.GetZoneScaleAt(x, z)

	local shoreDist = OceanDepthField.GetShoreDistanceAt(x, z)
	local damp = OceanDeep.SwellDampAt(shoreDist)

	local wx, wz = OceanNoise.WarpAt(x, z)

	for index = 1, waveMax or waveCount do
		local waveDirX, waveDirZ = dirX[index], dirZ[index]
		local theta = waveK[index] * (waveDirX * wx + waveDirZ * wz) - waveOmega[index] * time
		local s = sin(theta)
		local c = cos(theta)

		local scale = (if index >= from then intensity * zone * (marginalScale :: number) else intensity * zone) * damp
		if shallowDepth then
			scale *= math.tanh(waveK[index] * shallowDepth)
		end

		local chop = waveChop[index] * scale * c
		dx += waveDirX * chop
		dz += waveDirZ * chop
		dy += waveAmp[index] * scale * s

		local slope = waveKA[index] * scale * c
		nx -= waveDirX * slope
		nz -= waveDirZ * slope

		local pinch = waveSN[index] * scale * s
		ny -= pinch
		sxx += waveDirX * waveDirX * pinch
		szz += waveDirZ * waveDirZ * pinch
		sxz += waveDirX * waveDirZ * pinch
	end

	local jacobian = (1 - sxx) * (1 - szz) - sxz * sxz

	return dx, dy, dz, nx, ny, nz, jacobian
end

function OceanGerstner.GetNormalAt(intensity: number, x: number, z: number, t: number?): Vector3
	local _, _, _, nx, ny, nz = OceanGerstner.GetSurfaceAt(intensity, x, z, t)
	return Vector3.new(nx, ny, nz).Unit
end

return OceanGerstner
