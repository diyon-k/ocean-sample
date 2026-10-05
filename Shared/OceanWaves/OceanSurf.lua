--!native
--
--	Author(s): Di
--	Module: OceanSurf.lua
--
--	The nearshore, where shoaling has silenced the open-sea swell: breakers
--	(the visible rollers) plus a much slower surge that breathes the near-flat
--	waterline sheet up and down the beach.
--
--	Both ride the SHORE-DISTANCE field, not depth: phase = K * dist + omega * t
--	gives a constant world wavelength always traveling inshore on every beach
--	no matter its orientation, with no per-wave direction and full determinism.
--	Depth-driven phase pumps flat shelves in unison and folds into artifacts at
--	slope breaks, because depth is a bad proxy for distance traveled.
--
--	Two incommensurate trains superpose into natural wave sets (a few big, a
--	few small, always changing), and OceanNoise's crest noise varies crest size
--	along the coast -- together they kill the uniform "wrinkle rows" read of one
--	perfect sinusoid. The amplitude window is distance-based too, and a SQUARED
--	smoothstep: crests are born imperceptibly far out in the calm band, visibly
--	develop as they travel in, and peak just before the shore -- waves arrive,
--	they do not materialize next to the beach.
--
--	The renderer does not call DisplacementAt: it bakes the window into static
--	per-vertex buffers at re-lattice and does the trig itself at emit. It reads
--	the constants below through OceanWaves.Surf, so the two must stay in step.
--

local OceanNoise = require(script.Parent.OceanNoise) ---@module OceanNoise
local OceanDepthField = require(script.Parent.OceanDepthField) ---@module OceanDepthField
local FFTOceanSpectrum = require(script.Parent.Parent.FFTOcean.FFTOceanSpectrum) ---@module FFTOceanSpectrum

local BREAKER_FAR_DIST = 500 -- studs from shore where breakers begin to exist
local BREAKER_NEAR_DIST = 60 -- full size from here inshore
local BREAKER_AMP = 1.3
local BREAKER_K = 0.07 -- radians per stud of SHORE DISTANCE (2*pi / ~90-stud wavelength)
local BREAKER_OMEGA = 0.45 -- ~14s period; inshore crest speed = omega/K studs/s
local BREAKER2_SHARE = 0.55 -- second train amplitude, fraction of the first
local BREAKER2_K = 0.047 -- ~134-stud wavelength
local BREAKER2_OMEGA = 0.34
local BREAKER2_PHASE = 2.1
local SURGE_AMP = 0.8
local SURGE_K = 0.02
local SURGE_OMEGA = 0.26 -- ~24s waterline breathing
local SWASH_DIST = 45 -- breaker rolloff span: full crest here, thin swash at the waterline
local FACING_FLOOR = 0.35 -- lee-shore residual (fakes refraction around headlands)
local FACING_FULL = 0.7 -- cos ~45deg: shores within this cone of the swell break full-size
local GRAD_TAP = 4 -- studs; matches OceanTuning.GradTap so renderer facing == gameplay facing

-- Swell travel direction, single-sourced from the FFT spectrum so retuning
-- the storm re-aims the breakers.
local swellLen = math.sqrt(FFTOceanSpectrum.WindX ^ 2 + FFTOceanSpectrum.WindZ ^ 2)
local SWELL_X = FFTOceanSpectrum.WindX / swellLen
local SWELL_Z = FFTOceanSpectrum.WindZ / swellLen

local sin = math.sin

local OceanSurf = {}

-- Read by the renderer through OceanWaves.Surf to bake its static buffers.
OceanSurf.Surf = {
	FarDist = BREAKER_FAR_DIST,
	NearDist = BREAKER_NEAR_DIST,
	BreakerAmp = BREAKER_AMP,
	BreakerK = BREAKER_K,
	BreakerOmega = BREAKER_OMEGA,
	Breaker2Share = BREAKER2_SHARE,
	Breaker2K = BREAKER2_K,
	Breaker2Omega = BREAKER2_OMEGA,
	Breaker2Phase = BREAKER2_PHASE,
	SurgeAmp = SURGE_AMP,
	SurgeK = SURGE_K,
	SurgeOmega = SURGE_OMEGA,
	SwashDist = SWASH_DIST,
	FacingFloor = FACING_FLOOR,
	FacingFull = FACING_FULL,
	SwellX = SWELL_X,
	SwellZ = SWELL_Z,
}

-- Vertical surf displacement at world (x, z). Vertical only, so GetHeightAt's
-- chop inversion is untouched. ampScale carries the caller's intensity and
-- zone factors. Must match the renderer's emit pass exactly. The second
-- return is the local peak height in studs.
function OceanSurf.DisplacementAt(
	x: number,
	z: number,
	depth: number,
	depthEff: number,
	shoreDist: number,
	t: number,
	ampScale: number
): (number, number)
	if shoreDist >= BREAKER_FAR_DIST then
		return 0, 0
	end

	-- Phase AND window ride the shore-distance field (constant world
	-- wavelength, always traveling inshore, growing as it comes).
	local dist = shoreDist + (depthEff - depth) * 2
	local s = math.clamp((BREAKER_FAR_DIST - dist) / (BREAKER_FAR_DIST - BREAKER_NEAR_DIST), 0, 1)
	local window = s * s * (3 - 2 * s)

	-- Only shores facing the swell break hard; lee coasts keep a gentle
	-- floor. Shore normal = distance-field gradient (land -> sea).
	local getShoreDistanceAt = OceanDepthField.GetShoreDistanceAt
	local gx = (getShoreDistanceAt(x + GRAD_TAP, z) - getShoreDistanceAt(x - GRAD_TAP, z)) / (2 * GRAD_TAP)
	local gz = (getShoreDistanceAt(x, z + GRAD_TAP) - getShoreDistanceAt(x, z - GRAD_TAP)) / (2 * GRAD_TAP)
	local gradLen = math.sqrt(gx * gx + gz * gz)
	local facing = if gradLen > 1e-4
		then math.clamp(-(gx * SWELL_X + gz * SWELL_Z) / (gradLen * FACING_FULL), FACING_FLOOR, 1)
		else FACING_FLOOR

	window = window * window * OceanNoise.CrestNoiseAt(x, z) * ampScale * facing

	-- Breakers collapse into thin swash at the sand; surge is the waterline
	-- breathing itself, so it keeps the full window.
	local r = math.clamp(dist / SWASH_DIST, 0, 1)
	local rolloff = r * r * (3 - 2 * r)

	local breaker = sin(BREAKER_K * dist + BREAKER_OMEGA * t)
		+ BREAKER2_SHARE * sin(BREAKER2_K * dist + BREAKER2_OMEGA * t + BREAKER2_PHASE)

	local breakerAmp = BREAKER_AMP * window * rolloff
	local surgeAmp = SURGE_AMP * window
	return breakerAmp * breaker + surgeAmp * sin(SURGE_K * dist + SURGE_OMEGA * t),
		breakerAmp * (1 + BREAKER2_SHARE) + surgeAmp
end

return OceanSurf
