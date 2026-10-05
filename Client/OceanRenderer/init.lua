--!native
--
--	Author(s): Di
--	Module: OceanRenderer.lua
--

-- The ocean renderer: a camera-following clipmap of nested square levels
-- (dense center, coarser rings) in one rigid EditableMesh, snapped in whole
-- coarse cells so every vertex stays on a fixed world lattice. Each level
-- ticks at its own rate, sliced across frames for flat per-frame cost.
--
-- This file owns the mesh, the level state, the lattice (snap / rebase /
-- refresh), and the frame scheduler. The per-vertex work lives in two passes
-- it drives once per slice:
--		OceanRebuild	- statics, recomputed only when the lattice moves
--		OceanEmit		- the steady pass, every cycle
-- with OceanFoamSheet, OceanFarPlanes, OceanPalette and OceanTuning alongside.
--
-- Deep water is the FFT simulation (OceanWaves/OceanDeep). Each level freezes
-- a blended field snapshot at its cycle time, so a cycle sliced across frames
-- can never straddle a sim recompute. Positions write every cycle; normals
-- and colors alternate cycles. Land vertices never move, so steady cycles
-- skip their writes.
--
-- Owned by OceanClient, which feeds it the frame clock. Client-only: no
-- remotes, no replication -- determinism comes from OceanWaves running on the
-- synced server clock.

local AssetService = game:GetService("AssetService")

local FFTOcean = shared("FFTOcean") ---@module FFTOcean
local Maid = shared("Maid") ---@module Maid
local OceanEmit = require(script.OceanEmit) ---@module OceanEmit
local OceanFarPlanes = require(script.OceanFarPlanes) ---@module OceanFarPlanes
local OceanFoamSheet = require(script.OceanFoamSheet) ---@module OceanFoamSheet
local OceanMesh = require(script.OceanMesh) ---@module OceanMesh
local OceanPalette = require(script.OceanPalette) ---@module OceanPalette
local OceanRebuild = require(script.OceanRebuild) ---@module OceanRebuild
local OceanShading = require(script.OceanShading) ---@module OceanShading
local OceanTuning = require(script.OceanTuning) ---@module OceanTuning
local OceanWaves = shared("OceanWaves") ---@module OceanWaves

local LEVELS = OceanTuning.Levels
local SIM_BUDGET = OceanTuning.SimBudgetMs / 1000
local STAGE_HEADROOM = 0.001 -- typical single-stage cost: a stage only starts with this much budget left
local TIME_GRID = OceanTuning.TimeGrid
local MIN_CELLS_PER_WAVELENGTH = OceanTuning.MinCellsPerWavelength
local SNAP_STEP = OceanTuning.SnapStep
local REBASE_DISTANCE = OceanTuning.RebaseDistance
local SNAP_SYNC_LEVELS = OceanTuning.SnapSyncLevels
local FADE_BAND = OceanTuning.FadeBand
local TINT_LEVELS = OceanTuning.TintLevels
local FOAM_SHEET_LEVELS = OceanTuning.FoamSheetLevels
local LAND_SINK = OceanTuning.LandSink
local FRUSTUM_GATE = OceanTuning.FrustumGate
local GATE_MARGIN = math.rad(OceanTuning.FrustumGateMarginDeg)
local GATE_PITCH_MIN = OceanTuning.FrustumGatePitchMin
local GATE_HEARTBEAT = OceanTuning.FrustumGateHeartbeat
local GATE_TURN_COS = OceanTuning.FrustumGateTurnCos
local STORM_DARKEN = OceanTuning.StormDarken

local SHEET_LIFTS = {}
for index, layer in OceanTuning.FoamSheetLayers do
	SHEET_LIFTS[index] = layer.Lift
end
local FFT_DETAIL_LEVELS = OceanTuning.FftDetailLevels

local SHORE_TRANSPARENCY = OceanTuning.ShoreTransparency
local DEEP_TRANSPARENCY = OceanTuning.WaterTransparency
local SHORE_TRANSPARENCY_DISTANCE = OceanTuning.ShoreTransparencyDistance
local SHORE_TRANSPARENCY_SMOOTH = OceanTuning.ShoreTransparencySmoothTime

local FIELD_N = FFTOcean.Resolution
local FIELD_LOW_N = FFTOcean.LowResolution

local OceanRenderer = {}
OceanRenderer.__index = OceanRenderer

-- A level only bakes the waves its cell size can resolve. The wave stack is
-- bake-only (OceanGerstner), so this only shapes the mesh's creation
-- bounds and the marginal fade OceanMesh bakes for them.
local function waveMaxForCell(cell: number): number
	local minWavelength = MIN_CELLS_PER_WAVELENGTH * cell
	local count = 0
	for _, wave in OceanWaves.Waves do
		if wave.Wavelength < minWavelength then
			break
		end
		count += 1
	end
	return math.max(count, 1)
end

--
--		*	OceanRenderer
--

-- Builds the mesh, the foam sheet, and the far planes around (atX, atZ),
-- snapped to the lattice. Returns nil when editable-mesh creation is denied
-- (a real device-level failure): no ocean, no crash.
function OceanRenderer.new(seaLevel: number, atX: number, atZ: number)
	local self = setmetatable({}, OceanRenderer)

	self._maid = Maid.new()
	self._seaLevel = seaLevel
	self._originX = math.round(atX / SNAP_STEP) * SNAP_STEP
	self._originZ = math.round(atZ / SNAP_STEP) * SNAP_STEP
	self._meshOriginX = self._originX
	self._meshOriginZ = self._originZ
	self._camX, self._camZ = self._originX, self._originZ
	self._drainNext = SNAP_SYNC_LEVELS + 1

	if not self:_buildMesh() then
		self._maid:Destroy()
		return nil
	end

	self._shading = OceanShading.new(self._maid)
	self._alphaFade = 0
	if self._shading then
		self._shading:ApplyTo({ self._meshPart })
	end

	self._farPlanes = OceanFarPlanes.Build(self._maid, self._shading)
	self:_placeFarPlanes()

	-- Full emission before any steady cycle: slices assume every cache is
	-- populated, and a camera that spawns on the origin never snaps.
	self:RefreshAll()

	return self
end

--
--		Build
--

function OceanRenderer:_buildLevelSpecs()
	local specs = table.create(#LEVELS)

	for index, level in LEVELS do
		local waveMax = waveMaxForCell(level.Cell)
		local nextWaveMax = if index < #LEVELS then waveMaxForCell(LEVELS[index + 1].Cell) else nil

		specs[index] = {
			Cell = level.Cell,
			HalfExtent = level.HalfExtent,
			Rate = level.Rate,
			WaveMax = waveMax,
			MarginalFrom = if nextWaveMax and nextWaveMax < waveMax then nextWaveMax + 1 else nil,
			FadeFrom = if index == #LEVELS then level.HalfExtent - FADE_BAND else nil,
		}
	end

	return specs
end

function OceanRenderer:_buildLevelState(index: number, levelLayout)
	local sliceCount = math.max(1, math.round(60 / levelLayout.Rate))
	local sliceSize = math.ceil(levelLayout.Count / sliceCount)
	-- Slice 0 must cover the whole boundary: the chord constraint runs right
	-- after it, from positions cached in the same pass.
	assert(sliceSize >= levelLayout.BoundaryCount, "ocean level slice 0 smaller than its boundary")

	local detail = index <= FFT_DETAIL_LEVELS

	return {
		Layout = levelLayout,
		Label = "OceanL" .. index,
		SliceCount = sliceCount,
		SliceSize = sliceSize,
		Interval = 1 / levelLayout.Rate,
		SliceIndex = nil,
		NextDue = 0,
		CycleT = 0,
		Parity = 0,
		-- Per-level field scratch: the sim snapshots blended at this level's
		-- cycle time, so a cycle sliced across frames can never straddle a
		-- recompute. Coarse rings carry only the low twin.
		Detail = detail,
		Sheet = index <= FOAM_SHEET_LEVELS,
		FieldHeight = if detail then buffer.create(FIELD_N * FIELD_N * 8) else nil,
		FieldPlane = if detail then buffer.create(FIELD_N * FIELD_N * 8) else nil,
		FieldNormal = if detail then buffer.create(FIELD_N * FIELD_N * 8) else nil,
		FieldHeightLow = buffer.create(FIELD_LOW_N * FIELD_LOW_N * 8),
		FieldPlaneLow = buffer.create(FIELD_LOW_N * FIELD_LOW_N * 8),
		FieldNormalLow = buffer.create(FIELD_LOW_N * FIELD_LOW_N * 8),
		FieldU = buffer.create(levelLayout.Count * 4),
		FieldV = buffer.create(levelLayout.Count * 4),
		DeepScale = buffer.create(levelLayout.Count * 4),
		DepthBuf = buffer.create(levelLayout.Count * 4),
		ShoreDistBuf = buffer.create(levelLayout.Count * 4),
		EdgeDepthBuf = buffer.create(levelLayout.Count * 4),
		SheetSpanBuf = buffer.create(levelLayout.Count * 4),
		ShoreAmpB = buffer.create(levelLayout.Count * 4),
		ShoreAmpS = buffer.create(levelLayout.Count * 4),
		ShoreSlopeX = buffer.create(levelLayout.Count * 4),
		ShoreSlopeZ = buffer.create(levelLayout.Count * 4),
		FlagsBuf = buffer.create(levelLayout.Count),
		PosCache = table.create(levelLayout.Count),
		NormCache = table.create(levelLayout.Count),
		ColorCache = if index <= TINT_LEVELS then table.create(levelLayout.Count) else nil,
		FoamCache = if index <= TINT_LEVELS then table.create(levelLayout.Count) else nil,
		AlphaCache = if index <= TINT_LEVELS then table.create(levelLayout.Count) else nil,
	}
end

function OceanRenderer:_buildMesh(): boolean
	local mesh = AssetService:CreateEditableMesh()
	local specs = self:_buildLevelSpecs()

	-- Through StormStep so this reads the same row the emit path will. The build
	-- runs before the driver's first SetStorm, so a join mid-storm still bakes the
	-- clear ramp -- emit rewrites every vertex color on its next cycle, so it
	-- corrects itself before the water is on screen.
	local layout = OceanMesh.Build(mesh, specs, self._originX, self._originZ, OceanWaves.GetTime(), function(dy)
		return OceanPalette.Tint[OceanPalette.StormStep[OceanPalette.StepFor(dy)]]
	end)

	-- Editable-mesh memory budget denial is a real device-level failure: no
	-- ocean, no crash.
	local ok, result = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
		})
	end)
	if not ok then
		warn("Ocean mesh creation failed:", result)
		mesh:Destroy()
		return false
	end

	local meshPart = result
	meshPart.Name = "Ocean"
	meshPart.Anchored = true
	meshPart.CastShadow = false
	meshPart.CanCollide = false
	meshPart.CanQuery = false
	meshPart.CanTouch = false
	meshPart.DoubleSided = true
	-- WaterColor is white: it MULTIPLIES the vertex tint, which supplies all
	-- the actual color. Baking a tint in here too would apply the palette
	-- TWICE (mid x mid) and leave the mesh darker than the far planes it has
	-- to meet -- the appearance carries no ColorMap, so the vertex tint under
	-- it renders exactly as it does anywhere else.
	meshPart.Color = OceanTuning.WaterColor
	meshPart.Transparency = OceanTuning.WaterTransparency
	meshPart.Reflectance = OceanTuning.WaterReflectance
	meshPart.Material = Enum.Material.SmoothPlastic
	meshPart.Parent = workspace.Terrain


	self._mesh = mesh
	self._meshPart = meshPart
	self._boundsCenter = layout.BoundsCenter
	self._maid:GiveTask(mesh)
	self._maid:GiveTask(meshPart)

	self:_buildDetailTextures(meshPart)

	self._levels = table.create(#layout.Levels)
	local maxCount = 0
	for index, levelLayout in layout.Levels do
		self._levels[index] = self:_buildLevelState(index, levelLayout)
		maxCount = math.max(maxCount, levelLayout.Count)
	end
	self._permuteScratch = OceanRebuild.CreateScratch(maxCount)

	self._sheetLayers = OceanFoamSheet.Build(specs, self._originX, self._originZ, self._maid)

	self:_positionMesh()
	return true
end

function OceanRenderer:_buildDetailTextures(meshPart: BasePart)
	self._detailTextures = {}

	for _, spec in OceanTuning.DetailTextures do
		if spec.Asset ~= "" then
			local texture = Instance.new("Texture")
			texture.Texture = spec.Asset
			texture.Face = Enum.NormalId.Top
			texture.StudsPerTileU = spec.StudsPerTile
			texture.StudsPerTileV = spec.StudsPerTile
			texture.Transparency = spec.Transparency
			texture.Parent = meshPart
			table.insert(self._detailTextures, { Texture = texture, Spec = spec })
		end
	end
end

function OceanRenderer:_positionMesh()
	-- Mesh coordinates render relative to the creation-bounds center; offset
	-- the pivot so the mesh origin sits exactly at (origin, sea level).
	local pivot = CFrame.new(Vector3.new(self._meshOriginX, self._seaLevel, self._meshOriginZ) + self._boundsCenter)
	self._meshPart.CFrame = pivot
	if self._sheetLayers then
		-- Same pivot compensation as the MAIN part, not each sheet's own
		-- bounds: measured in-game, the engine offsets the sheet's geometry
		-- by the bounds-center DIFFERENCE otherwise (sheet under + behind
		-- the water by exactly that delta).
		for _, layer in self._sheetLayers do
			layer.Part.CFrame = pivot
		end
	end
end

function OceanRenderer:_placeFarPlanes()
	OceanFarPlanes.Place(self._farPlanes, self._originX, self._originZ, self._seaLevel)
end

--
--		Storm
--

-- Storm amount per Lighting.Weather state, re-exported so the driver does not
-- have to reach inside the renderer's folder for the tuning table.
OceanRenderer.StormLevels = OceanTuning.StormLevels

-- 0 = clear, 1 = full storm. Three part-color writes and a 49-entry remap, so
-- this is cheap enough to call every frame of a transition. Vertex tints
-- MULTIPLY the part color, so scaling it dims the whole surface -- foam
-- included -- without touching the baked palette.
function OceanRenderer:SetStorm(amount: number)
	OceanPalette.SetStorm(amount)
	local scale = 1 - STORM_DARKEN * math.clamp(amount, 0, 1)
	self:SetShade(Color3.new(scale, scale, scale))
end

-- Multiplies the three part colors the vertex tints multiply into: white =
-- authored colors, black = black water.
function OceanRenderer:SetShade(shade: Color3)
	local water = OceanTuning.WaterColor
	self._meshPart.Color = Color3.new(water.R * shade.R, water.G * shade.G, water.B * shade.B)

	-- The far planes are flat, so they have no vertex tint to carry the storm --
	-- their baked DeepMidTint has to take the same scale or the horizon stays
	-- bright against a darkened sea.
	local mid = OceanPalette.DeepMidTint
	local planeColor = Color3.new(mid.R * water.R * shade.R, mid.G * water.G * shade.G, mid.B * water.B * shade.B)
	for _, entry in self._farPlanes do
		entry.Part.Color = planeColor
	end

	if not self._sheetLayers then
		return
	end

	local foam = OceanTuning.FoamSheetColor
	local sheetColor = Color3.new(foam.R * shade.R, foam.G * shade.G, foam.B * shade.B)
	for _, layer in self._sheetLayers do
		layer.Part.Color = sheetColor
	end
end

--
--		Lattice
--

function OceanRenderer:_snapTo(originX: number, originZ: number)
	local deltaX = originX - self._meshOriginX
	local deltaZ = originZ - self._meshOriginZ
	if math.max(math.abs(deltaX), math.abs(deltaZ)) > REBASE_DISTANCE then
		-- Re-anchor ONLY: move the part and translate every cached vertex in
		-- the same frame. World geometry is identical before and after, so
		-- this is SetPosition-only -- no wave math, no normal writes. The
		-- origin is deliberately left untouched: next frame's hysteresis
		-- check re-triggers a normal snap for the lattice catch-up, putting
		-- the two cost peaks on separate frames.
		self._meshOriginX = originX
		self._meshOriginZ = originZ
		self:_positionMesh()
		self:_rebaseTranslate(deltaX, deltaZ)
		return
	end

	self._originX = originX
	self._originZ = originZ
	self:RefreshAll()
end

-- Drops every level's baked statics, then re-lattices. For when the statics
-- themselves went stale rather than the lattice moving under them -- the depth
-- bake landing rewrites the shore of every vertex, including the ones that
-- never moved, so there is nothing for Permute to carry over.
function OceanRenderer:RebuildAll()
	for _, state in self._levels do
		state.StaticOriginX = nil
		state.StaticOriginZ = nil
	end
	self:RefreshAll()
end

-- Re-lattice everything: the nearest levels together in this frame so the
-- closest ring seams never show a mixed-lattice frame; the outer levels drain
-- round-robin, one whole level per frame, so sustained snapping can never
-- starve or freeze a level.
--
-- The part does NOT move: stale vertices keep rendering at their old (still
-- world-correct) positions while levels slide to the new lattice.
function OceanRenderer:RefreshAll()
	for levelIndex, state in self._levels do
		state.SliceIndex = nil
		if levelIndex > SNAP_SYNC_LEVELS then
			state.PendingRefresh = true
		end
	end
	for levelIndex = 1, SNAP_SYNC_LEVELS do
		self:_refreshLevel(levelIndex)
	end
end

-- Blend the sim snapshots into this level's field scratch at its cycle time.
-- Runs at cycle arm and refresh -- everything the cycle emits then samples one
-- consistent field state.
--
-- Levels sharing a rate arm on the same grid at the same quantized time, so
-- their blends come out byte-identical: the first to run pays the lerp and the
-- rest copy its scratch. Only a detail level's scratch can serve any level -- a
-- coarse one carries no full trio to hand over.
function OceanRenderer:_blendLevelField(state)
	debug.profilebegin("OceanBlend")
	FFTOcean.Update()

	local step = FFTOcean.GetStep()
	local source = self._blendSource
	if source and self._blendStep == step and self._blendT == state.CycleT and (source.Detail or not state.Detail) then
		if source ~= state then
			buffer.copy(state.FieldHeightLow, 0, source.FieldHeightLow)
			buffer.copy(state.FieldPlaneLow, 0, source.FieldPlaneLow)
			buffer.copy(state.FieldNormalLow, 0, source.FieldNormalLow)
			if state.Detail then
				buffer.copy(state.FieldHeight, 0, source.FieldHeight)
				buffer.copy(state.FieldPlane, 0, source.FieldPlane)
				buffer.copy(state.FieldNormal, 0, source.FieldNormal)
			end
		end
		debug.profileend()
		return
	end

	FFTOcean.WriteBlended(
		state.CycleT,
		state.FieldHeightLow, state.FieldPlaneLow, state.FieldNormalLow,
		state.FieldHeight, state.FieldPlane, state.FieldNormal
	)

	self._blendStep = step
	self._blendT = state.CycleT
	self._blendSource = state
	debug.profileend()
end

-- Brings this level's statics onto the current lattice. The statics are a pure
-- function of world position and the lattice only ever shifts by whole cells,
-- so nearly every vertex lands on a point some other vertex already baked:
-- slide those over and bake only the strip that moved in.
--
-- Sliding is only valid while the world the statics were baked from still
-- agrees with them. It bakes whole instead when this level has no statics yet
-- (first build, or the depth bake landing dropped them) or when an OceanZone
-- part moved under them -- zones are live-editable and every vertex reads them,
-- so an edit invalidates the ones that never moved too.
function OceanRenderer:_bakeStatics(state)
	local zoneVersion = OceanWaves.GetZoneVersion()

	if state.StaticOriginX and state.StaticZoneVersion == zoneVersion then
		local misses = OceanRebuild.Permute(self, state, self._originX - state.StaticOriginX, self._originZ - state.StaticOriginZ)
		OceanRebuild.RunIndices(self, state, misses)
	else
		OceanRebuild.Run(self, state, 1, state.Layout.Count)
	end

	state.StaticOriginX = self._originX
	state.StaticOriginZ = self._originZ
	state.StaticZoneVersion = zoneVersion
end

-- Full rebuild of a level this frame: its statics onto the current lattice,
-- then a full emission (positions, normals, colors).
function OceanRenderer:_refreshLevel(levelIndex: number)
	local state = self._levels[levelIndex]
	state.CycleT = math.floor(OceanWaves.GetTime() / TIME_GRID) * TIME_GRID
	state.Parity = 0
	self:_blendLevelField(state)
	self:_bakeStatics(state)

	OceanEmit.Run(self, levelIndex, state, 1, state.Layout.Count, nil, true, true)

	state.PendingRefresh = nil
	state.SliceIndex = nil
	state.NextDue = (math.floor(os.clock() / state.Interval) + 1) * state.Interval

	-- The far planes re-center with the rim in the same frame: moving them
	-- at snap time opens a brief gap strip at the horizon.
	if levelIndex == #self._levels then
		self:_placeFarPlanes()
	end
end

-- A rebase is a pure translation of mesh-local space: the cached positions
-- shift by the anchor delta and normals are untouched.
function OceanRenderer:_rebaseTranslate(deltaX: number, deltaZ: number)
	local delta = Vector3.new(deltaX, 0, deltaZ)
	local mesh = self._mesh

	for levelIndex, state in self._levels do
		local layout = state.Layout
		local vertexIds = layout.VertexIds
		local posCache = state.PosCache

		if posCache[layout.Count] == nil then
			-- Cache not fully populated yet (session start): full recompute.
			self:_refreshLevel(levelIndex)
			continue
		end

		debug.profilebegin(state.Label)
		local sheetLayers = if levelIndex <= FOAM_SHEET_LEVELS then self._sheetLayers else nil
		local flagsBuf = if sheetLayers then state.FlagsBuf else nil
		for index = 1, layout.Count do
			local position = posCache[index] - delta
			posCache[index] = position
			mesh:SetPosition(vertexIds[index], position)
			if sheetLayers then
				-- Land verts hold the surface height (see OceanEmit), so undo the
				-- water's sink here or the strips stretch down the wall.
				local sheetY = position.Y
				if buffer.readu8(flagsBuf :: buffer, index - 1) % 4 == 1 then
					sheetY += LAND_SINK
				end
				for k, layer in sheetLayers do
					layer.Mesh:SetPosition(layer.Levels[levelIndex].VertexIds[index], Vector3.new(position.X, sheetY + SHEET_LIFTS[k], position.Z))
				end
			end
		end
		debug.profileend()
	end
end

--
--		Frame
--

-- The view cone the steady pass gates against: normalized horizontal camera
-- forward plus cos^2 of (horizontal half-FOV + margin). Steep pitch or a
-- near-panoramic cone turns gating off for the frame.
function OceanRenderer:_updateGate()
	self._gateActive = false
	if not FRUSTUM_GATE then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local look = camera.CFrame.LookVector
	local hx, hz = look.X, look.Z
	local len = math.sqrt(hx * hx + hz * hz)
	if len < GATE_PITCH_MIN then
		return
	end

	local halfV = math.rad(camera.FieldOfView) * 0.5
	local viewport = camera.ViewportSize
	local aspect = viewport.X / math.max(viewport.Y, 1)
	local half = math.atan(math.tan(halfV) * aspect) + GATE_MARGIN
	if half >= 1.48 then
		return
	end

	local cosHalf = math.cos(half)
	self._gateFwdX = hx / len
	self._gateFwdZ = hz / len
	self._gateCos2 = cosHalf * cosHalf
	self._gateActive = true
end

function OceanRenderer:_followCamera(): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end

	local at = camera.CFrame.Position
	self._camX, self._camZ = at.X, at.Z

	-- Hysteresis: re-center only once the camera leaves a full-step window
	-- around the current origin, so orbiting or shake across a rounding
	-- boundary cannot re-snap every frame.
	local drift = math.max(math.abs(at.X - self._originX), math.abs(at.Z - self._originZ))
	if drift <= SNAP_STEP then
		return false
	end

	self:_snapTo(math.round(at.X / SNAP_STEP) * SNAP_STEP, math.round(at.Z / SNAP_STEP) * SNAP_STEP)
	return true
end

-- Drain one stale outer level, round-robin so sustained snapping can never
-- starve a level into a frozen lattice.
function OceanRenderer:_drainStaleLevel(): boolean
	local levelCount = #self._levels

	for _ = SNAP_SYNC_LEVELS + 1, levelCount do
		local candidate = self._drainNext
		self._drainNext = if candidate >= levelCount then SNAP_SYNC_LEVELS + 1 else candidate + 1
		if self._levels[candidate].PendingRefresh then
			self:_refreshLevel(candidate)
			return true
		end
	end

	return false
end

-- Whether this cycle may skip out-of-view verts. Goes fully live on the
-- heartbeat, after a real turn since the last live cycle, or when the gate
-- itself is unusable this frame.
function OceanRenderer:_armGate(state): boolean
	if not self._gateActive then
		state.GateBaseX = nil
		return false
	end

	state.GateBeat = (state.GateBeat or 0) + 1
	local baseX, baseZ = state.GateBaseX, state.GateBaseZ
	local turned = baseX ~= nil and baseX * self._gateFwdX + baseZ * self._gateFwdZ < GATE_TURN_COS
	if baseX == nil or turned or state.GateBeat >= GATE_HEARTBEAT then
		state.GateBeat = 0
		state.GateBaseX, state.GateBaseZ = self._gateFwdX, self._gateFwdZ
		return false
	end

	return true
end

function OceanRenderer:_stepLevel(levelIndex: number, state, now: number)
	if state.PendingRefresh then
		return
	end

	if not state.SliceIndex and now >= state.NextDue then
		-- Arm a cycle on the shared time grid and freeze this level's field
		-- scratch at that instant: every slice of the cycle then emits one
		-- consistent sim state.
		state.SliceIndex = 0
		state.CycleT = math.floor(OceanWaves.GetTime() / TIME_GRID) * TIME_GRID
		state.Parity = 1 - state.Parity
		state.NextDue = (math.floor(now / state.Interval) + 1) * state.Interval
		self:_blendLevelField(state)
		state.Gate = self:_armGate(state)
	end

	if not state.SliceIndex then
		return
	end

	local from = state.SliceIndex * state.SliceSize + 1
	local to = math.min(from + state.SliceSize - 1, state.Layout.Count)
	if from <= to then
		-- Color every cycle, normals every second one. Position writes every
		-- cycle unconditionally, and tint is a function of the height being
		-- written: skip a cycle and the color a vertex wears belongs to a wave
		-- shape it no longer has, so the tint visibly slides against the
		-- crests. Normals tolerate the parity -- lighting has no edge to
		-- misalign.
		OceanEmit.Run(self, levelIndex, state, from, to, true, state.Parity == 0, true, state.Gate)
	end

	state.SliceIndex += 1
	if state.SliceIndex * state.SliceSize >= state.Layout.Count then
		state.SliceIndex = nil
	end
end

function OceanRenderer:_scrollDetailTextures()
	local t = OceanWaves.GetTime()

	for _, entry in self._detailTextures do
		local spec = entry.Spec
		entry.Texture.OffsetStudsU = t * spec.SpeedU % spec.StudsPerTile
		entry.Texture.OffsetStudsV = t * spec.SpeedV % spec.StudsPerTile
	end
end

function OceanRenderer:Step()
	if OceanTuning.DebugFreeze then
		return
	end

	-- One per-frame ms budget caps every ocean burst: the sim's staged IFFTs
	-- and the shading composite's staged draws drain under this deadline
	-- instead of landing whole on single frames. A step's composite finishes
	-- before the sim arms its next step, so the two peaks can never stack.
	local deadline = os.clock() + SIM_BUDGET

	local published = false
	if self._shading and self._shading:HasWork() then
		-- Headroom check BEFORE each stage: the drain stays inside the budget
		-- instead of always overshooting on its last stage.
		debug.profilebegin("OceanShading")
		while self._shading:HasWork() and os.clock() + STAGE_HEADROOM <= deadline do
			self._shading:RunStage()
		end
		debug.profileend()
	end
	if not (self._shading and self._shading:HasWork()) and os.clock() < deadline then
		published = FFTOcean.Update(nil, deadline)
	end
	if published and self._shading then
		self._shading:Arm()
	end

	local snapped = self:_followCamera()
	self:_updateGate()

	-- Never drain on a snap frame, which already carries the near levels'
	-- re-lattice.
	local drained = false
	if not snapped then
		drained = self:_drainStaleLevel()
	end

	-- Snap and drain frames are the remaining cost peaks; deferring normal
	-- slices onto the frames right after flattens the per-frame cost. Sim
	-- and shading stages are budget-capped above, so slices coexist.
	if not (drained or snapped) then
		local now = os.clock()
		local freezeFrom = OceanTuning.DebugFreezeFromLevel
		for levelIndex, state in self._levels do
			if not freezeFrom or levelIndex < freezeFrom then
				self:_stepLevel(levelIndex, state, now)
			end
		end
	end

	if #self._detailTextures > 0 then
		self:_scrollDetailTextures()
	end

	self:_updateSurfaceTransparency()
end

-- Fades the near surface from ShoreTransparency at the waterline to the opaque
-- floor as the camera moves away from land. Shore distance grows 1:1 with
-- movement (unlike depth, which can plunge in a step at a drop-off), so the
-- target ramps at a constant visible rate both ways; the smoothing only irons
-- out grid bilinearity.
function OceanRenderer:_updateSurfaceTransparency()
	local dist = OceanWaves.GetShoreDistanceAt(self._camX, self._camZ)

	local away = math.clamp(dist / SHORE_TRANSPARENCY_DISTANCE, 0, 1)
	local eased = away * away * (3 - 2 * away)
	local target = SHORE_TRANSPARENCY + (DEEP_TRANSPARENCY - SHORE_TRANSPARENCY) * eased

	local now = os.clock()
	local dt = now - (self._transparencyClock or now)
	self._transparencyClock = now
	local alpha = 1 - math.exp(-dt / SHORE_TRANSPARENCY_SMOOTH)

	local part = self._meshPart
	part.Transparency = part.Transparency + (target - part.Transparency) * alpha

	-- The vertex-alpha gradient rides the same smoothed fade: full strength at
	-- the shore value, gone by the opaque floor. Quantized so emit's alpha
	-- cache still swallows repeat writes while this drifts.
	local fade = (part.Transparency - DEEP_TRANSPARENCY) / (SHORE_TRANSPARENCY - DEEP_TRANSPARENCY)
	self._alphaFade = math.floor(math.clamp(fade, 0, 1) * 16 + 0.5) * 0.0625

	-- Foam sheets: ANY part transparency > 0 rejoins the distance-sorted
	-- translucent pass and the sort flip against the see-through shore water
	-- returns -- so no ramp. Hard 0 until the camera fully clears the shore
	-- fade distance (water opaque there), then snap to the authored value.
	if self._sheetLayers then
		for _, layer in self._sheetLayers do
			layer.Part.Transparency = if away >= 1 then layer.Transparency else 0
		end
	end
end

function OceanRenderer:Destroy()
	self._maid:Destroy()
end

return OceanRenderer
