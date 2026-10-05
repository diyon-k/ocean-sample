--!native
--
--	Author(s): Di
--	Module: OceanNoise.lua
--
--	The ocean's seeded noise fields. All three are pure functions of world
--	position over math.noise with a fixed seed, so every client evaluates them
--	identically and consumers can bake their output per vertex and never
--	re-evaluate it until the lattice moves.
--

local WARP_SEED = 41.7

-- Domain warp: push the sample position by a low-frequency seeded noise field
-- before evaluating the waves, so straight crests bend into organic wandering
-- lines. Low frequency survives the coarse far LOD without aliasing.
local WARP_AMP = 24 -- studs of lateral push at full noise
local WARP_FREQ = 1 / 200 -- noise cycles per stud (bigger divisor = broader bends)

-- Envelope depth: the depth value the band envelopes (swell fade, breaker
-- window, breaker phase) actually see. Wobbled so no wave system starts or
-- dies along a clean depth-contour line; the wobble fades out approaching the
-- waterline so foam still hugs the beach.
local SHORE_JITTER = 9 -- +- studs of wobble at full ramp
local SHORE_JITTER_FREQ = 1 / 90
local SHORE_JITTER_RAMP = 12 -- real depth over which the wobble ramps in

-- Static along-coast crest size multiplier for the surf window. Swings hard
-- enough to CUT to zero in patches, so crests arrive as finite segments with
-- calm gaps between them -- never one unbroken ring around the shore.
local BREAKER_NOISE = 1.4 -- crest size swing along the coast
local BREAKER_NOISE_FREQ = 1 / 180

-- The waterline's along-coast wiggle. Finer than the envelope jitter, and it
-- does NOT fade at the waterline -- it IS the waterline: the visible edge
-- sits where DEPTH plus this crosses the swash threshold, so the water ends
-- on an organic line instead of the terrain clip contour. Depth studs: on a
-- beach the slope multiplies this into a several-stud horizontal wander.
local EDGE_NOISE_AMP = 0.5 -- +- depth studs the waterline wanders
local EDGE_NOISE_FREQ = 1 / 45 -- long enough to survive 16-stud outer cells

local noise = math.noise

local OceanNoise = {}

function OceanNoise.WarpAt(x: number, z: number): (number, number)
	local a = noise(x * WARP_FREQ, z * WARP_FREQ, WARP_SEED)
	local b = noise(x * WARP_FREQ, z * WARP_FREQ, WARP_SEED + 19.3)
	return x + a * WARP_AMP, z + b * WARP_AMP
end

function OceanNoise.EnvelopeDepthAt(x: number, z: number, depth: number): number
	local ramp = math.min(depth / SHORE_JITTER_RAMP, 1)
	return depth + SHORE_JITTER * ramp * noise(x * SHORE_JITTER_FREQ, z * SHORE_JITTER_FREQ, WARP_SEED + 47.7)
end

function OceanNoise.CrestNoiseAt(x: number, z: number): number
	return math.max(1 + BREAKER_NOISE * noise(x * BREAKER_NOISE_FREQ, z * BREAKER_NOISE_FREQ, WARP_SEED + 83.1), 0)
end

function OceanNoise.EdgeNoiseAt(x: number, z: number): number
	return EDGE_NOISE_AMP * noise(x * EDGE_NOISE_FREQ, z * EDGE_NOISE_FREQ, WARP_SEED + 129.4)
end

return OceanNoise
