--
--	Author(s): Di
--	Module: oceanfixtures.luau
--
--	Fixtures for the renderer tests. OceanTuning is not in this repo, so the
--	tests get a stand-in: plausible constants, plus the ring layout copied
--	from the shipped tuning (it is what the 9% / 17% claims are about). The
--	OceanWaves stand-in is a set of pure functions of world (x, z), shaped so
--	the bake runs through every branch: dry land, landlocked basins, swash,
--	the surf zone, shallows and open sea.
--

local Harness = require("./harness")

local Fixtures = {}

-- The shipped ring layout (cell size and half-extent in studs).
Fixtures.Levels = {
	{ Cell = 4, HalfExtent = 64 },
	{ Cell = 8, HalfExtent = 192 },
	{ Cell = 16, HalfExtent = 448 },
	{ Cell = 32, HalfExtent = 960 },
}
Fixtures.SnapStep = 32

-- Mirrors OceanRebuild's PERMUTE_F32: every f32 static a vertex carries.
Fixtures.F32 = {
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

-- Fill byte for "never written" slots. Both sides of a comparison start
-- from it, so unwritten slots only match if neither side wrote them.
Fixtures.Garbage = 0xA5

local TUNING = {
	ShallowDepth = 28,
	ShallowAbsorb = 10,
	ShallowSteps = 6,
	ShallowEdge = 0.06,
	DeepDarkSteps = 4,
	DeepDarkDepth = 80,
	ShoreFoamDepth = 12,
	GradTap = 4,
	FoamSheetWidth = 20,
	FoamSheetMinSlope = 0.05,
	FoamSheetTap = 4,
}

local function depthAt(x: number, z: number): number
	return math.max(0, 40 + 50 * math.sin(x * 0.011) * math.cos(z * 0.013))
end

local function newWaves(hasDepthGrid: boolean)
	return {
		DeepShoalK = 0.06,
		DeepCutoff = 75,
		SwellCalmDist = 350,
		SwellFullDist = 1000,
		SwellCalmFloor = 0.22,
		Surf = {
			FarDist = 500,
			NearDist = 60,
			BreakerAmp = 1.2,
			BreakerK = 0.1,
			SurgeAmp = 0.6,
			SwashDist = 45,
			FacingFloor = 0.35,
			FacingFull = 0.7,
			SwellX = 0.8,
			SwellZ = 0.6,
		},
		GetDeepScale = function()
			return 9
		end,
		GetDepthAt = function(x: number, z: number): number?
			return if hasDepthGrid then depthAt(x, z) else nil
		end,
		GetShoreDistanceAt = function(x: number, z: number): number
			if not hasDepthGrid then
				return 1e6
			end
			return math.max(0, depthAt(x, z) * 6 + 20 * math.sin(z * 0.02))
		end,
		EnvelopeDepthAt = function(x: number, z: number, depth: number): number
			return depth + 3 * math.sin(x * 0.05 + z * 0.03)
		end,
		EdgeNoiseAt = function(x: number, _z: number): number
			return 0.5 * math.cos(x * 0.07)
		end,
		CrestNoiseAt = function(_x: number, z: number): number
			return 0.6 + 0.4 * math.sin(z * 0.02)
		end,
		GetZoneScaleAt = function(x: number, _z: number): number
			return 1 + 0.2 * math.sin(x * 0.004)
		end,
		IsLandlocked = function(x: number, z: number): boolean
			return math.sin(x * 0.021 + z * 0.017) > 0.6
		end,
		IsLandNear = function(x: number, z: number): boolean
			return hasDepthGrid and depthAt(x, z) < 6
		end,
		WarpAt = function(x: number, z: number): (number, number)
			return x + 3 * math.sin(z * 0.01), z + 3 * math.cos(x * 0.01)
		end,
		-- OceanMesh.Build samples this once per vertex for the mesh bounds.
		GetSurfaceAt = function()
			return 0, 0, 0, 0, 1, 0
		end,
	}
end

local function mockMesh()
	local nextId = 0
	local function newId()
		nextId += 1
		return nextId
	end
	local function noop() end

	return {
		AddVertex = newId,
		AddNormal = newId,
		AddUV = newId,
		AddColor = newId,
		AddTriangle = newId,
		SetFaceNormals = noop,
		SetFaceUVs = noop,
		SetFaceColors = noop,
	}
end

-- Loads the real OceanMesh + OceanRebuild against the stand-ins and builds
-- the real ring layout around the origin.
function Fixtures.load(hasDepthGrid: boolean)
	local world = Harness.newWorld({
		Shared = { OceanWaves = newWaves(hasDepthGrid) },
		Modules = { ["Client/OceanRenderer/OceanTuning"] = TUNING },
	})

	local OceanMesh = world:Require("Client/OceanRenderer/OceanMesh")
	local OceanRebuild = world:Require("Client/OceanRenderer/OceanRebuild")

	local specs = {}
	for index, level in Fixtures.Levels do
		specs[index] = { Cell = level.Cell, HalfExtent = level.HalfExtent, Rate = 30, WaveMax = 0 }
	end
	local layout = OceanMesh.Build(mockMesh(), specs, 0, 0, 0, function()
		return nil
	end)

	return OceanRebuild, layout
end

-- A level's static buffers, every byte pre-filled with Garbage.
function Fixtures.newState(levelLayout)
	local count = levelLayout.Count
	local state = {
		Layout = levelLayout,
		Sheet = true,
		FlagsBuf = buffer.create(count),
		FoamCache = table.create(count, 7),
	}
	buffer.fill(state.FlagsBuf, 0, Fixtures.Garbage)
	for _, name in Fixtures.F32 do
		state[name] = buffer.create(count * 4)
		buffer.fill(state[name], 0, Fixtures.Garbage)
	end
	return state
end

function Fixtures.newRenderer(OceanRebuild, maxCount: number, originX: number, originZ: number)
	local scratch = OceanRebuild.CreateScratch(maxCount)
	buffer.fill(scratch.FlagsBuf, 0, Fixtures.Garbage)
	for _, name in Fixtures.F32 do
		buffer.fill(scratch[name], 0, Fixtures.Garbage)
	end
	return { _originX = originX, _originZ = originZ, _permuteScratch = scratch }
end

return Fixtures
