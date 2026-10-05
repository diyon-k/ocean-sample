--!native
--
--	Author(s): Di
--	Module: OceanRebuild.lua
--
--	The static pass. Computes every per-vertex factor that stays constant
--	between re-lattices -- pre-warped field texel coords, the one deep scale
--	folding zone / swell damp / shoaling, the depth class, and the surf
--	amplitude window -- and writes them into the level's buffers. The steady
--	pass never touches any of it.
--
--	Every output here is a pure function of WORLD position. That is what lets
--	Permute carry a vertex's statics over from whichever vertex last sat on the
--	same lattice point, so a re-lattice only bakes the strip that moved in. The
--	rim fade is deliberately absent -- it is local-space, so OceanEmit applies
--	it instead (OceanMesh bakes it into layout.FadeMul).
--
--	All the trig and every depth lookup live here; emit only reads buffers.
--

local FFTOcean = shared("FFTOcean") ---@module FFTOcean
local OceanMesh = require(script.Parent.OceanMesh) ---@module OceanMesh
local OceanTuning = require(script.Parent.OceanTuning) ---@module OceanTuning
local OceanWaves = shared("OceanWaves") ---@module OceanWaves

local SHALLOW_DEPTH = OceanTuning.ShallowDepth
local SHALLOW_ABSORB = OceanTuning.ShallowAbsorb
local SHALLOW_STEPS = OceanTuning.ShallowSteps
local SHALLOW_EDGE = OceanTuning.ShallowEdge
local DEEP_DARK_STEPS = OceanTuning.DeepDarkSteps
local DEEP_DARK_DEPTH = OceanTuning.DeepDarkDepth
local SHORE_FOAM_DEPTH = OceanTuning.ShoreFoamDepth
local GRAD_TAP = OceanTuning.GradTap
local SHEET_WIDTH = OceanTuning.FoamSheetWidth
local SHEET_MIN_SLOPE = OceanTuning.FoamSheetMinSlope
local SHEET_TAP = OceanTuning.FoamSheetTap

local FIELD_N = FFTOcean.Resolution

-- Every f32 static, by state field name. Authoritative: Permute sizes its
-- scratch, gathers, and copies back straight off this list, so a new static
-- buffer joins the permutation by being named here.
local PERMUTE_F32 = {
	"FieldU",
	"FieldV",
	"DeepScale",
	"DepthBuf",
	"ShoreDistBuf",
	"EdgeDepthBuf",
	"SheetSpanBuf",
	"ShoreAmpB",
	"ShoreAmpS",
	"ShoreSlopeX",
	"ShoreSlopeZ",
}

-- Surf-zone contract (shared with gameplay): the amplitude window and the
-- breaker's normal slope bake here; the phase trig stays in emit, where t
-- changes every cycle. See OceanWaves/OceanSurf for the theory.
local surf = OceanWaves.Surf
local BREAKER_FAR_DIST = surf.FarDist
local BREAKER_NEAR_DIST = surf.NearDist
local BREAKER_AMP = surf.BreakerAmp
local BREAKER_K = surf.BreakerK
local SURGE_AMP = surf.SurgeAmp
local SWASH_DIST = surf.SwashDist
local FACING_FLOOR = surf.FacingFloor
local FACING_FULL = surf.FacingFull
local SWELL_X = surf.SwellX
local SWELL_Z = surf.SwellZ

local OceanRebuild = {}

local function bake(renderer, state, from: number, to: number, list: { number }?)
	debug.profilebegin("OceanRebuild")

	local layout = state.Layout
	local localX, localZ = layout.LocalX, layout.LocalZ
	local fieldU, fieldV = state.FieldU, state.FieldV
	local deepScaleBuf = state.DeepScale
	local depthBuf, flagsBuf = state.DepthBuf, state.FlagsBuf
	local shoreDistBuf = state.ShoreDistBuf
	local edgeDepthBuf = state.EdgeDepthBuf
	local sheetSpanBuf = state.SheetSpanBuf
	local sheet = state.Sheet
	local shoreAmpB, shoreAmpS = state.ShoreAmpB, state.ShoreAmpS
	local shoreSlopeX, shoreSlopeZ = state.ShoreSlopeX, state.ShoreSlopeZ
	local foamCache = state.FoamCache
	local originX, originZ = renderer._originX, renderer._originZ
	local deepHeightScale = OceanWaves.GetDeepScale()
	local deepShoalK = OceanWaves.DeepShoalK
	local invTile = 1 / FFTOcean.Tile
	local warpAt = OceanWaves.WarpAt
	local envelopeDepthAt = OceanWaves.EnvelopeDepthAt
	local crestNoiseAt = OceanWaves.CrestNoiseAt
	local edgeNoiseAt = OceanWaves.EdgeNoiseAt
	local getShoreDistanceAt = OceanWaves.GetShoreDistanceAt
	local getDepthAt = OceanWaves.GetDepthAt
	local getZoneScaleAt = OceanWaves.GetZoneScaleAt
	local isLandlocked = OceanWaves.IsLandlocked
	local isLandNear = OceanWaves.IsLandNear
	local deepCutoff = OceanWaves.DeepCutoff
	local swellCalmDist = OceanWaves.SwellCalmDist
	local swellFadeInv = 1 / (OceanWaves.SwellFullDist - swellCalmDist)
	local swellCalmFloor = OceanWaves.SwellCalmFloor
	local tanh = math.tanh
	local exp = math.exp

	local total = if list then #list else to - from + 1

	for step = 1, total do
		local index = if list then list[step] else from + step - 1
		local lx, lz = localX[index], localZ[index]
		local worldX, worldZ = originX + lx, originZ + lz

		-- This vertex's water is new (Permute found no vertex already sitting
		-- on its lattice point), so it has no whitecap history to inherit.
		if foamCache then
			foamCache[index] = 0
		end

		local off4 = (index - 1) * 4
		local depth = getDepthAt(worldX, worldZ)
		-- The buffer carries the ENVELOPE depth (organic wobble): emit-time
		-- breaker/surge phases and the swash factor read it, so the whole
		-- surf system shares one irregular front. Classification and the
		-- color gradient below stay on the real depth.
		local depthEff = if depth ~= nil then envelopeDepthAt(worldX, worldZ, depth) else nil
		buffer.writef32(depthBuf, off4, depthEff or 1e6)

		-- The swash edge rides RAW depth: the visible waterline is the depth-0
		-- contour, which the land-cell distance field misses by up to a grid
		-- cell -- and lands on the SINK boundary at flood-filled basins.
		buffer.writef32(edgeDepthBuf, off4, if depth ~= nil then (depth :: number) + edgeNoiseAt(worldX, worldZ) else 1e6)

		-- Sheet span static, covered levels only. Span folds the local bottom
		-- slope in, so the depth band holds a constant HORIZONTAL width on every
		-- beach -- the deep sheet reads it to place its shoreV = 1 surfacing
		-- threshold. Flat bottoms (and no grid) get the span zeroed.
		if sheet then
			local spanInv = 0
			if depth ~= nil then
				local dgx = ((getDepthAt(worldX + SHEET_TAP, worldZ) :: number) - (getDepthAt(worldX - SHEET_TAP, worldZ) :: number)) / (2 * SHEET_TAP)
				local dgz = ((getDepthAt(worldX, worldZ + SHEET_TAP) :: number) - (getDepthAt(worldX, worldZ - SHEET_TAP) :: number)) / (2 * SHEET_TAP)
				spanInv = 1 / (SHEET_WIDTH * math.max(math.sqrt(dgx * dgx + dgz * dgz), SHEET_MIN_SLOPE))
			end
			buffer.writef32(sheetSpanBuf, off4, spanInv)
		end

		-- Depth tint step packed into the flag high bits (class stays in
		-- the low two): static between re-lattices, free at emit time.
		local depthStep = DEEP_DARK_STEPS
		if depth ~= nil then
				if depth < SHALLOW_DEPTH then
			local alpha = (exp(-depth / SHALLOW_ABSORB) - SHALLOW_EDGE) / (1 - SHALLOW_EDGE)
			depthStep = DEEP_DARK_STEPS + math.floor(alpha * SHALLOW_STEPS + 0.5)
				else
					local d = math.clamp((depth - SHALLOW_DEPTH) / (DEEP_DARK_DEPTH - SHALLOW_DEPTH), 0, 1)
					depthStep = DEEP_DARK_STEPS - math.floor(d * DEEP_DARK_STEPS + 0.5)
				end
		end

		if depth ~= nil and depth <= 0.01 and isLandlocked(worldX, worldZ) then
			buffer.writeu8(flagsBuf, index - 1, 1 + depthStep * 4)
			buffer.writef32(shoreAmpB, off4, 0)
			buffer.writef32(shoreAmpS, off4, 0)
			continue
		end

		local swash = depth ~= nil and depth < SHORE_FOAM_DEPTH and isLandNear(worldX, worldZ)
		buffer.writeu8(flagsBuf, index - 1, (if swash then 2 else 0) + depthStep * 4)

		local shoreDist = getShoreDistanceAt(worldX, worldZ)
		local shallow = depthEff ~= nil and depthEff < deepCutoff
		local f = math.clamp((shoreDist - swellCalmDist) * swellFadeInv, 0, 1)
		local damp = swellCalmFloor + (1 - swellCalmFloor) * f * f * (3 - 2 * f)

		local static = getZoneScaleAt(worldX, worldZ)

		-- Surf statics: breaker/surge amplitude window over the surf zone and
		-- the breaker's normal slope from the baked depth gradient. Phase and
		-- trig stay in the emit pass (t changes every cycle; these do not).
		if depthEff ~= nil and shoreDist < BREAKER_FAR_DIST then
			-- Window is DISTANCE-based like the phase: crests are born small
			-- far out in the calm band and grow as they travel in. Facing
			-- gates it to swell-side shores; breakers alone roll off into
			-- thin swash at the sand (surge IS the waterline breathing).
			local dist = shoreDist + ((depthEff :: number) - (depth :: number)) * 2
			local s = math.clamp((BREAKER_FAR_DIST - dist) / (BREAKER_FAR_DIST - BREAKER_NEAR_DIST), 0, 1)
			local window = s * s * (3 - 2 * s)
			local gx = (getShoreDistanceAt(worldX + GRAD_TAP, worldZ) - getShoreDistanceAt(worldX - GRAD_TAP, worldZ)) / (2 * GRAD_TAP)
			local gz = (getShoreDistanceAt(worldX, worldZ + GRAD_TAP) - getShoreDistanceAt(worldX, worldZ - GRAD_TAP)) / (2 * GRAD_TAP)
			local gradLen = math.sqrt(gx * gx + gz * gz)
			local facing = if gradLen > 1e-4
				then math.clamp(-(gx * SWELL_X + gz * SWELL_Z) / (gradLen * FACING_FULL), FACING_FLOOR, 1)
				else FACING_FLOOR
			window = window * window * crestNoiseAt(worldX, worldZ) * static * facing
			local r = math.clamp(dist / SWASH_DIST, 0, 1)
			local rolloff = r * r * (3 - 2 * r)
			local ampB = BREAKER_AMP * window * rolloff
			buffer.writef32(shoreDistBuf, off4, dist)
			buffer.writef32(shoreAmpB, off4, ampB)
			buffer.writef32(shoreAmpS, off4, SURGE_AMP * window)
			buffer.writef32(shoreSlopeX, off4, ampB * BREAKER_K * gx)
			buffer.writef32(shoreSlopeZ, off4, ampB * BREAKER_K * gz)
		else
			buffer.writef32(shoreAmpB, off4, 0)
			buffer.writef32(shoreAmpS, off4, 0)
		end

		-- Distance-based swell damp and the scalar shoaling fold in AFTER the
		-- surf statics: the calm band silences the open sea, never the
		-- breakers. deepHeightScale calibrates raw field units into studs.
		static *= damp * deepHeightScale
		if shallow then
			static *= tanh(deepShoalK * (depthEff :: number))
		end

		local wx, wz = warpAt(worldX, worldZ)
		buffer.writef32(fieldU, off4, (wx * invTile) % 1 * FIELD_N)
		buffer.writef32(fieldV, off4, (wz * invTile) % 1 * FIELD_N)
		buffer.writef32(deepScaleBuf, off4, static)
	end

	debug.profileend()
end

-- Bakes the contiguous range [from, to]. The cold path: a level with no
-- statics yet (first build, or a rebase that outran its cache).
function OceanRebuild.Run(renderer, state, from: number, to: number)
	bake(renderer, state, from, to, nil)
end

-- Bakes exactly the listed indices -- Permute's miss set, the strip of genuinely
-- new water a re-lattice pulled in.
function OceanRebuild.RunIndices(renderer, state, list: { number })
	bake(renderer, state, 0, 0, list)
end

--
--		Permute
--

-- Scratch for Permute. It gathers into these and copies back rather than
-- shuffling in place, because the index -> donor map is a ring-ordered
-- permutation: a donor may already have been overwritten by the time its
-- reader comes up. Renderer-owned, sized to the largest level, reused by all.
function OceanRebuild.CreateScratch(maxCount: number)
	local scratch = {
		Donors = table.create(maxCount),
		FlagsBuf = buffer.create(maxCount),
		FoamCache = table.create(maxCount),
	}
	for _, name in PERMUTE_F32 do
		scratch[name] = buffer.create(maxCount * 4)
	end
	return scratch
end

-- Slides the level's statics along the lattice by (deltaX, deltaZ) studs and
-- returns the indices that found no donor -- the caller bakes those with
-- RunIndices. Because the statics are world-pure and the lattice only ever
-- shifts by whole cells, a vertex landing on a point some other vertex already
-- holds can just take its values. One 32-stud snap re-bakes 9% of the lattice
-- along an axis, 17% diagonally, versus all of it; a delta too big to overlap
-- (a teleport) misses everywhere and degrades to a full bake.
--
-- Values in slots the bake never wrote ride along as garbage: emit's
-- flag/amplitude gating means nothing ever reads them.
function OceanRebuild.Permute(renderer, state, deltaX: number, deltaZ: number): { number }
	debug.profilebegin("OceanPermute")

	local layout = state.Layout
	local localX, localZ = layout.LocalX, layout.LocalZ
	local indexOf = layout.IndexOf
	local half = layout.HalfExtent
	local count = layout.Count
	local scratch = renderer._permuteScratch
	local donors = scratch.Donors
	local latticeKey = OceanMesh.LatticeKey

	local misses: { number } = {}
	local missCount = 0

	-- 0 marks a miss: keeps `donors` a dense array, and no owned index is ever 0.
	for index = 1, count do
		local targetX = localX[index] + deltaX
		local targetZ = localZ[index] + deltaZ
		local donor = 0
		if targetX >= -half and targetX <= half and targetZ >= -half and targetZ <= half then
			donor = indexOf[latticeKey(targetX, targetZ)] or 0
		end

		donors[index] = donor
		if donor == 0 then
			missCount += 1
			misses[missCount] = index
		end
	end

	for _, name in PERMUTE_F32 do
		local live = state[name]
		local into = scratch[name]
		for index = 1, count do
			local donor = donors[index]
			if donor ~= 0 then
				buffer.writef32(into, (index - 1) * 4, buffer.readf32(live, (donor - 1) * 4))
			end
		end
		buffer.copy(live, 0, into, 0, count * 4)
	end

	local flagsBuf = state.FlagsBuf
	local flagsInto = scratch.FlagsBuf
	for index = 1, count do
		local donor = donors[index]
		if donor ~= 0 then
			buffer.writeu8(flagsInto, index - 1, buffer.readu8(flagsBuf, donor - 1))
		end
	end
	buffer.copy(flagsBuf, 0, flagsInto, 0, count)

	-- Foam is bound to its world position, so it survives the slide: whitecaps
	-- stop dying every time the lattice moves. Misses re-zero in the bake.
	local foamCache = state.FoamCache
	if foamCache then
		local foamInto = scratch.FoamCache
		for index = 1, count do
			local donor = donors[index]
			foamInto[index] = if donor ~= 0 then foamCache[donor] else 0
		end
		table.move(foamInto, 1, count, 1, foamCache)
	end

	debug.profileend()
	return misses
end

return OceanRebuild
