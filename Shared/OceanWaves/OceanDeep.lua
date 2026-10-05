--!native
--
--	Author(s): Di
--	Module: OceanDeep.lua
--
--	The open-sea field: the FFT simulation sampled at the warped position and
--	calibrated into studs, damped by distance from land, and shoaled where the
--	seabed rises.
--
--	Amplitude calibration is deterministic: DEEP_AMP divided by the field's
--	fixed-seed t = 0 peak, probed once on first use.
--

local FFTOcean = shared("FFTOcean") ---@module FFTOcean
local OceanNoise = require(script.Parent.OceanNoise) ---@module OceanNoise

local DEEP_AMP = 9 -- studs: peak open-sea wave amplitude
local SHOAL_K = 0.06 -- scalar shoaling wavenumber
local DEEP_CUTOFF = 75 -- depth beyond which shoaling is skipped (tanh ~ 1)

-- Horizontal displacement share of the height scale -- the wave CHOPPINESS.
-- A flat constant makes every wave the same shape; instead it ramps with depth
-- so moderate water rolls in gentle swells and the open sea peaks up choppy.
-- ChopMax is a safe ceiling: higher pinches crests.
local CHOP_MIN = 0.75
local CHOP_MAX = 1.3
local CHOP_DEPTH = 60 -- depth (studs) at which chop reaches ChopMax
local CHOP_SPAN = CHOP_MAX - CHOP_MIN
local CHOP_DEPTH_INV = 1 / CHOP_DEPTH

-- Choppiness at a point's envelope depth: smoothstep MIN -> MAX over CHOP_DEPTH.
-- No grid (open sea) rides the deep ceiling.
local function chopAt(depthEff: number?): number
	if depthEff == nil then
		return CHOP_MAX
	end
	local cd = math.clamp((depthEff :: number) * CHOP_DEPTH_INV, 0, 1)
	return CHOP_MIN + CHOP_SPAN * cd * cd * (3 - 2 * cd)
end

-- Open-sea swell is silenced by DISTANCE from land, not depth: a long calm
-- band stretches out from every shore regardless of how fast the seabed
-- drops, then the swell ramps in smoothly far out. Keeps lee-shore swell from
-- emerging at the waterline, and leaves the nearshore entirely to the
-- breaker/surge system.
local SWELL_CALM_DIST = 350 -- studs from shore where the swell sits at the floor
local SWELL_FULL_DIST = 1000 -- full open-sea swell beyond this
local SWELL_CALM_FLOOR = 0.22 -- swell fraction kept in the calm band: gentle, never glass

local deepScale = 0

local OceanDeep = {}

OceanDeep.Amplitude = DEEP_AMP
OceanDeep.ChopAt = chopAt
OceanDeep.ChopMin = CHOP_MIN
OceanDeep.ChopMax = CHOP_MAX
OceanDeep.ChopDepth = CHOP_DEPTH
OceanDeep.ShoalK = SHOAL_K
OceanDeep.Cutoff = DEEP_CUTOFF
OceanDeep.SwellCalmDist = SWELL_CALM_DIST
OceanDeep.SwellFullDist = SWELL_FULL_DIST
OceanDeep.SwellCalmFloor = SWELL_CALM_FLOOR

-- Raw-field-to-studs factor, calibrated once against the deterministic t = 0
-- peak (initializes the simulation on first call).
function OceanDeep.GetScale(): number
	if deepScale == 0 then
		FFTOcean.Update()
		deepScale = DEEP_AMP / FFTOcean.RawAmplitude
	end
	return deepScale
end

-- Swell strength at a point, from its distance to the nearest land.
function OceanDeep.SwellDampAt(shoreDist: number): number
	local f = math.clamp((shoreDist - SWELL_CALM_DIST) / (SWELL_FULL_DIST - SWELL_CALM_DIST), 0, 1)
	return SWELL_CALM_FLOOR + (1 - SWELL_CALM_FLOOR) * f * f * (3 - 2 * f)
end

-- Deep-field displacement at world (x, z): a bilinear FFT sample at the
-- warped position, blended between the two sim snapshots at time t (smooth
-- bobbing). ampScale carries the caller's intensity and zone factors. The
-- fourth return is the local peak height in studs.
function OceanDeep.DisplacementAt(x: number, z: number, t: number, depthEff: number?, shoreDist: number, ampScale: number): (number, number, number, number)
	FFTOcean.Update(t)

	local scale = ampScale * OceanDeep.SwellDampAt(shoreDist) * OceanDeep.GetScale()
	if depthEff ~= nil and depthEff < DEEP_CUTOFF then
		scale *= math.tanh(SHOAL_K * depthEff)
	end

	local wx, wz = OceanNoise.WarpAt(x, z)
	local dx, dy, dz = FFTOcean.SampleAt(wx, wz, t)
	local chop = chopAt(depthEff)
	return dx * scale * chop, dy * scale, dz * scale * chop, scale * FFTOcean.RawAmplitude
end

return OceanDeep
