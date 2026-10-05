--!native
--
--	Author(s): Di
--	Module: OceanMesh.lua
--
--	Build-time construction of the clipmap ocean topology: a solid center
--	square plus nested annulus rings, cell size doubling per level (geometry
--	clipmaps, Losasso & Hoppe 2004, reduced to one rigid mesh because the
--	displacement is a pure function of world position). Boundary vertices are
--	shared between adjacent levels and owned by the finer one; T-junction
--	midpoints are recorded for the renderer's chord constraint. The last
--	level's rim carries a baked displacement fade to flat sea level. Returns
--	flat parallel arrays -- the renderer's hot-path data.
--

local OceanWaves = shared("OceanWaves") ---@module OceanWaves

export type LevelSpec = {
	Cell: number,
	HalfExtent: number,
	Rate: number,
	WaveMax: number,
	MarginalFrom: number?, -- first wave index that fades toward this level's rim
	FadeFrom: number?,
}

export type LevelLayout = {
	Cell: number,
	HalfExtent: number,
	Rate: number,
	WaveMax: number,
	Count: number,
	BoundaryCount: number,
	VertexIds: { number },
	NormalIds: { number },
	LocalX: { number },
	LocalZ: { number },
	ColorIds: { number },
	UvIds: { number },
	FadeMul: { number }?,
	MarginalFrom: number?,
	MarginalFade: { number }?,
	Midpoints: { { number } }, -- {midpoint, neighborA, neighborB} owned-array indices
	IndexOf: { [number]: number }, -- OceanMesh.LatticeKey(lx, lz) -> owned index
}

export type Layout = {
	Levels: { LevelLayout },
	BoundsCenter: Vector3,
}

local MARGINAL_FADE_START = 0.5 -- fraction of a level's half-extent where its shortest waves start fading
-- World studs per UV repeat. MUST divide the renderer's SNAP_STEP so snaps
-- shift the texture by whole repeats and the pattern stays world-stable.
-- Trades px-per-stud against how close the repeat sits: OceanShading answers
-- the repeat by carrying no structure coarser than a couple of studs, so
-- there is no large-scale layout to recognize. Its octaves, speeds and
-- strength are all calibrated against this value.
local UV_TILE = 32

-- Lattice coordinates are whole studs bounded by the level's half-extent, so
-- biasing them positive and striding wider than any level packs a point into
-- one collision-free integer. Numeric, not string: OceanRebuild.Permute keys
-- every vertex on this and must allocate nothing.
local KEY_BIAS = 1024
local KEY_STRIDE = 8192

local OceanMesh = {}
OceanMesh.UV_TILE = UV_TILE

local function pointKey(x: number, z: number): string
	return x .. "_" .. z
end

-- Key into a level layout's IndexOf. Only valid for points the level could
-- own: |lx|, |lz| <= its half-extent (Build asserts the range).
function OceanMesh.LatticeKey(lx: number, lz: number): number
	return (lx + KEY_BIAS) * KEY_STRIDE + (lz + KEY_BIAS)
end

function OceanMesh.Build(
	mesh: EditableMesh,
	specs: { LevelSpec },
	originX: number,
	originZ: number,
	t0: number,
	tintFor: (dy: number) -> Color3
): Layout
	local levels = table.create(#specs)
	local sharedBoundary: { [string]: { number } } = {}

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

	for levelIndex, spec in specs do
		local cell = spec.Cell
		local half = spec.HalfExtent
		local innerHalf = if levelIndex > 1 then specs[levelIndex - 1].HalfExtent else nil
		local fadeFrom = spec.FadeFrom
		assert(half < KEY_BIAS, "ocean level half-extent outside the lattice key range")

		local vertexIds: { number } = {}
		local normalIds: { number } = {}
		local localX: { number } = {}
		local localZ: { number } = {}
		local colorIds: { number } = {}
		local uvIds: { number } = {}
		local fadeMul: { number }? = if fadeFrom then {} else nil
		local marginalFade: { number }? = if spec.MarginalFrom then {} else nil
		local midpoints: { { number } } = {}
		local pointIds: { [string]: { number } } = {} -- key -> {vertexId, normalId, uvId}
		local indexOf: { [number]: number } = {}
		local count = 0

		local function addOwned(lx: number, lz: number)
			local cheb = math.max(math.abs(lx), math.abs(lz))

			local fade = 1
			if fadeFrom then
				local alpha = math.clamp((cheb - fadeFrom) / (half - fadeFrom), 0, 1)
				fade = 1 - alpha * alpha * (3 - 2 * alpha)
			end

			-- The level's shortest waves fade to zero exactly where the next
			-- (coarser) level stops evaluating them, so ring boundaries never
			-- pop detail in or out as the grid follows the camera.
			local marginal = 1
			if spec.MarginalFrom then
				local start = half * MARGINAL_FADE_START
				local alpha = math.clamp((cheb - start) / (half - start), 0, 1)
				marginal = 1 - alpha * alpha * (3 - 2 * alpha)
			end

			local dx, dy, dz, nx, ny, nz =
				OceanWaves.GetSurfaceAt(originX + lx, originZ + lz, t0, spec.WaveMax, spec.MarginalFrom, marginal)
			local px, py, pz = lx + dx * fade, dy * fade, lz + dz * fade

			count += 1
			local vertexId = mesh:AddVertex(Vector3.new(px, py, pz))
			local normalId = mesh:AddNormal(Vector3.new(nx * fade, ny, nz * fade).Unit)
			local uvId = mesh:AddUV(Vector2.new(lx / UV_TILE, lz / UV_TILE))
			local colorId = mesh:AddColor(tintFor(py), 1)
			vertexIds[count] = vertexId
			normalIds[count] = normalId
			localX[count] = lx
			localZ[count] = lz
			colorIds[count] = colorId
			uvIds[count] = uvId
			if fadeMul then
				fadeMul[count] = fade
			end
			if marginalFade then
				marginalFade[count] = marginal
			end

			pointIds[pointKey(lx, lz)] = { vertexId, normalId, uvId, colorId }
			indexOf[OceanMesh.LatticeKey(lx, lz)] = count

			minX, maxX = math.min(minX, px), math.max(maxX, px)
			minY, maxY = math.min(minY, py), math.max(maxY, py)
			minZ, maxZ = math.min(minZ, pz), math.max(maxZ, pz)
		end

		-- Outer boundary first: the renderer's slice 0 must cover it so the
		-- chord constraint can run in the same pass it was updated in.
		for lx = -half, half, cell do
			addOwned(lx, -half)
			addOwned(lx, half)
		end
		for lz = -half + cell, half - cell, cell do
			addOwned(-half, lz)
			addOwned(half, lz)
		end
		local boundaryCount = count

		for lz = -half, half, cell do
			for lx = -half, half, cell do
				local rim = math.max(math.abs(lx), math.abs(lz))
				if rim == half then
					continue
				end

				if innerHalf then
					if rim < innerHalf then
						continue
					end
					if rim == innerHalf then
						local key = pointKey(lx, lz)
						pointIds[key] = assert(sharedBoundary[key], "ocean level missing shared boundary vertex")
						continue
					end
				end

				addOwned(lx, lz)
			end
		end

		-- Outer-boundary points at odd cell multiples sit mid-edge for the
		-- next (2x coarser) level; the renderer snaps them onto the chord.
		if levelIndex < #specs then
			local function addMidpoint(mx, mz, ax, az, bx, bz)
				table.insert(midpoints, {
					indexOf[OceanMesh.LatticeKey(mx, mz)],
					indexOf[OceanMesh.LatticeKey(ax, az)],
					indexOf[OceanMesh.LatticeKey(bx, bz)],
				})
			end

			for p = -half + cell, half - cell, 2 * cell do
				addMidpoint(p, -half, p - cell, -half, p + cell, -half)
				addMidpoint(p, half, p - cell, half, p + cell, half)
				addMidpoint(-half, p, -half, p - cell, -half, p + cell)
				addMidpoint(half, p, half, p - cell, half, p + cell)
			end
		end

		-- Two +Y-wound triangles per cell, skipping the interior hole.
		for cz = -half, half - cell, cell do
			for cx = -half, half - cell, cell do
				if innerHalf and cx >= -innerHalf and cx + cell <= innerHalf and cz >= -innerHalf and cz + cell <= innerHalf then
					continue
				end

				local p00 = pointIds[pointKey(cx, cz)]
				local p10 = pointIds[pointKey(cx + cell, cz)]
				local p01 = pointIds[pointKey(cx, cz + cell)]
				local p11 = pointIds[pointKey(cx + cell, cz + cell)]

				local face1 = mesh:AddTriangle(p00[1], p01[1], p10[1])
				mesh:SetFaceNormals(face1, { p00[2], p01[2], p10[2] })
				mesh:SetFaceUVs(face1, { p00[3], p01[3], p10[3] })
				mesh:SetFaceColors(face1, { p00[4], p01[4], p10[4] })

				local face2 = mesh:AddTriangle(p11[1], p10[1], p01[1])
				mesh:SetFaceNormals(face2, { p11[2], p10[2], p01[2] })
				mesh:SetFaceUVs(face2, { p11[3], p10[3], p01[3] })
				mesh:SetFaceColors(face2, { p11[4], p10[4], p01[4] })
			end
		end

		levels[levelIndex] = {
			Cell = cell,
			HalfExtent = half,
			Rate = spec.Rate,
			WaveMax = spec.WaveMax,
			Count = count,
			BoundaryCount = boundaryCount,
			VertexIds = vertexIds,
			NormalIds = normalIds,
			LocalX = localX,
			LocalZ = localZ,
			ColorIds = colorIds,
			UvIds = uvIds,
			FadeMul = fadeMul,
			MarginalFrom = spec.MarginalFrom,
			MarginalFade = marginalFade,
			Midpoints = midpoints,
			IndexOf = indexOf,
		}

		sharedBoundary = pointIds
	end

	return {
		Levels = levels,
		BoundsCenter = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2),
	}
end

return OceanMesh
