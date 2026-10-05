--!native
--
--	Author(s): Di
--	Module: OceanDepthField.lua
--
--	The server-baked depth grid and everything derived from it: bilinear water
--	depth, distance to the nearest land, and the land classifications the
--	renderer masks with. One byte per cell (0 = land), decoded from the
--	OceanDepth StringValue on every client and set directly on the server, so
--	all machines share one field.
--
--	The shore-distance transform runs here at grid arrival because the surf
--	system rides distance, not depth (see OceanSurf).
--

local depthGrid: buffer? = nil
local shoreDistGrid: buffer? = nil
local landDistGrid: buffer? = nil
local depthOriginX = 0
local depthOriginZ = 0
local depthCell = 0
local depthInvCell = 0
local depthWidth = 0
local depthHeight = 0
local depthMax = 0

local OceanDepthField = {}

--
--		Bake
--

-- Chamfer distance transform in CELL units: two O(n) sweeps over a buffer
-- pre-seeded with 0 at the sources and 1e9 everywhere else.
local function chamfer(dist: buffer, width: number, height: number)
	local DIAG = 1.41421356

	for row = 0, height - 1 do
		for column = 0, width - 1 do
			local index = row * width + column
			local best = buffer.readf32(dist, index * 4)
			if column > 0 then
				best = math.min(best, buffer.readf32(dist, (index - 1) * 4) + 1)
			end
			if row > 0 then
				local up = index - width
				best = math.min(best, buffer.readf32(dist, up * 4) + 1)
				if column > 0 then
					best = math.min(best, buffer.readf32(dist, (up - 1) * 4) + DIAG)
				end
				if column < width - 1 then
					best = math.min(best, buffer.readf32(dist, (up + 1) * 4) + DIAG)
				end
			end
			buffer.writef32(dist, index * 4, best)
		end
	end

	for row = height - 1, 0, -1 do
		for column = width - 1, 0, -1 do
			local index = row * width + column
			local best = buffer.readf32(dist, index * 4)
			if column < width - 1 then
				best = math.min(best, buffer.readf32(dist, (index + 1) * 4) + 1)
			end
			if row < height - 1 then
				local down = index + width
				best = math.min(best, buffer.readf32(dist, down * 4) + 1)
				if column < width - 1 then
					best = math.min(best, buffer.readf32(dist, (down + 1) * 4) + DIAG)
				end
				if column > 0 then
					best = math.min(best, buffer.readf32(dist, (down - 1) * 4) + DIAG)
				end
			end
			buffer.writef32(dist, index * 4, best)
		end
	end
end

-- Studs from every water cell to the nearest land.
local function buildShoreDistance(grid: buffer, width: number, height: number, cellSize: number)
	local dist = buffer.create(width * height * 4)
	for index = 0, width * height - 1 do
		buffer.writef32(dist, index * 4, if buffer.readu8(grid, index) == 0 then 0 else 1e9)
	end

	chamfer(dist, width, height)

	for index = 0, width * height - 1 do
		buffer.writef32(dist, index * 4, math.min(buffer.readf32(dist, index * 4) * cellSize, 1e6))
	end

	shoreDistGrid = dist
end

-- The mirror transform: distance from every LAND cell out to the nearest
-- water, zero over water. Stored as one byte of whole cells because only the
-- first few hundred studs inland are ever asked about, and the f32 shore field
-- is already megabytes. Subtracting it from the shore distance gives one
-- continuous signed field across the waterline.
local function buildLandDistance(grid: buffer, width: number, height: number)
	local dist = buffer.create(width * height * 4)
	for index = 0, width * height - 1 do
		buffer.writef32(dist, index * 4, if buffer.readu8(grid, index) == 0 then 1e9 else 0)
	end

	chamfer(dist, width, height)

	local packed = buffer.create(width * height)
	for index = 0, width * height - 1 do
		buffer.writeu8(packed, index, math.min(buffer.readf32(dist, index * 4) // 1, 255))
	end

	landDistGrid = packed
end

function OceanDepthField.SetDepthGrid(grid: buffer, originX: number, originZ: number, cellSize: number, width: number, height: number, maxDepth: number)
	depthGrid = grid
	depthOriginX = originX
	depthOriginZ = originZ
	depthCell = cellSize
	depthInvCell = 1 / cellSize
	depthWidth = width
	depthHeight = height
	depthMax = maxDepth

	buildShoreDistance(grid, width, height, cellSize)
	buildLandDistance(grid, width, height)
end

--
--		Queries
--

-- Bilinear water depth at world (x, z); land cells contribute zero, outside
-- the grid clamps to the border, nil until a grid has been set.
function OceanDepthField.GetDepthAt(x: number, z: number): number?
	local grid = depthGrid
	if not grid then
		return nil
	end

	local gx = (x - depthOriginX) * depthInvCell - 0.5
	local gz = (z - depthOriginZ) * depthInvCell - 0.5

	-- Outside the baked footprint is open sea beyond the map: deep water,
	-- never a clamp to whatever happens to sit on the border.
	if gx < -0.5 or gz < -0.5 or gx > depthWidth - 0.5 or gz > depthHeight - 0.5 then
		return depthMax
	end

	local x0 = math.clamp(math.floor(gx), 0, depthWidth - 1)
	local z0 = math.clamp(math.floor(gz), 0, depthHeight - 1)
	local x1 = math.min(x0 + 1, depthWidth - 1)
	local z1 = math.min(z0 + 1, depthHeight - 1)
	local fx = math.clamp(gx - x0, 0, 1)
	local fz = math.clamp(gz - z0, 0, 1)

	local d00 = buffer.readu8(grid, z0 * depthWidth + x0)
	local d10 = buffer.readu8(grid, z0 * depthWidth + x1)
	local d01 = buffer.readu8(grid, z1 * depthWidth + x0)
	local d11 = buffer.readu8(grid, z1 * depthWidth + x1)

	local top = d00 + (d10 - d00) * fx
	local bottom = d01 + (d11 - d01) * fx
	return (top + (bottom - top) * fz) * depthMax / 255
end

-- Bilinear distance (studs) to the nearest land at world (x, z). Huge when
-- no grid has arrived yet or outside the footprint: open sea, no shore.
function OceanDepthField.GetShoreDistanceAt(x: number, z: number): number
	local grid = shoreDistGrid
	if not grid then
		return 1e6
	end

	local gx = (x - depthOriginX) * depthInvCell - 0.5
	local gz = (z - depthOriginZ) * depthInvCell - 0.5

	if gx < -0.5 or gz < -0.5 or gx > depthWidth - 0.5 or gz > depthHeight - 0.5 then
		return 1e6
	end

	local x0 = math.clamp(math.floor(gx), 0, depthWidth - 1)
	local z0 = math.clamp(math.floor(gz), 0, depthHeight - 1)
	local x1 = math.min(x0 + 1, depthWidth - 1)
	local z1 = math.min(z0 + 1, depthHeight - 1)
	local fx = math.clamp(gx - x0, 0, 1)
	local fz = math.clamp(gz - z0, 0, 1)

	local d00 = buffer.readf32(grid, (z0 * depthWidth + x0) * 4)
	local d10 = buffer.readf32(grid, (z0 * depthWidth + x1) * 4)
	local d01 = buffer.readf32(grid, (z1 * depthWidth + x0) * 4)
	local d11 = buffer.readf32(grid, (z1 * depthWidth + x1) * 4)

	local top = d00 + (d10 - d00) * fx
	local bottom = d01 + (d11 - d01) * fx
	return top + (bottom - top) * fz
end

-- Bilinear studs from land out to the nearest water at world (x, z). Zero over
-- water, and zero outside the baked footprint -- beyond the map edge is open sea.
local function sampleLandDistance(x: number, z: number): number
	local grid = landDistGrid
	if not grid then
		return 0
	end

	local gx = (x - depthOriginX) * depthInvCell - 0.5
	local gz = (z - depthOriginZ) * depthInvCell - 0.5

	if gx < -0.5 or gz < -0.5 or gx > depthWidth - 0.5 or gz > depthHeight - 0.5 then
		return 0
	end

	local x0 = math.clamp(math.floor(gx), 0, depthWidth - 1)
	local z0 = math.clamp(math.floor(gz), 0, depthHeight - 1)
	local x1 = math.min(x0 + 1, depthWidth - 1)
	local z1 = math.min(z0 + 1, depthHeight - 1)
	local fx = math.clamp(gx - x0, 0, 1)
	local fz = math.clamp(gz - z0, 0, 1)

	local d00 = buffer.readu8(grid, z0 * depthWidth + x0)
	local d10 = buffer.readu8(grid, z0 * depthWidth + x1)
	local d01 = buffer.readu8(grid, z1 * depthWidth + x0)
	local d11 = buffer.readu8(grid, z1 * depthWidth + x1)

	local top = d00 + (d10 - d00) * fx
	local bottom = d01 + (d11 - d01) * fx
	return (top + (bottom - top) * fz) * depthCell
end

-- Signed studs to the waterline at world (x, z): positive out to sea, negative
-- inland, zero on the shoreline itself. nil until a grid has arrived, so
-- callers can hold off rather than treat an unbaked map as open ocean.
--
-- The two transforms are complementary -- each is zero wherever the other is
-- not -- so their difference is continuous across the boundary. That makes the
-- field's gradient a usable "which way is the sea" vector, which is how the
-- shore ambience finds the coast without a search.
function OceanDepthField.GetSignedShoreDistanceAt(x: number, z: number): number?
	if not shoreDistGrid then
		return nil
	end

	return OceanDepthField.GetShoreDistanceAt(x, z) - sampleLandDistance(x, z)
end

-- True when any depth cell within two cells of (x, z) is land: the swash
-- foam band belongs to actual waterlines, not offshore shallow shelves.
function OceanDepthField.IsLandNear(x: number, z: number): boolean
	local grid = depthGrid
	if not grid then
		return false
	end

	local column = math.floor((x - depthOriginX) * depthInvCell)
	local row = math.floor((z - depthOriginZ) * depthInvCell)

	for rowOffset = -2, 2 do
		local r = row + rowOffset
		if r >= 0 and r < depthHeight then
			for columnOffset = -2, 2 do
				local c = column + columnOffset
				if c >= 0 and c < depthWidth and buffer.readu8(grid, r * depthWidth + c) == 0 then
					return true
				end
			end
		end
	end

	return false
end

-- True when every depth cell within two cells of (x, z) is land. Only these
-- vertices sink: the beach strip stays at sea level so the terrain clips the
-- waterline per-pixel, far smoother than any vertex-resolution masking.
function OceanDepthField.IsLandlocked(x: number, z: number): boolean
	local grid = depthGrid
	if not grid then
		return false
	end

	local column = math.floor((x - depthOriginX) * depthInvCell)
	local row = math.floor((z - depthOriginZ) * depthInvCell)

	for rowOffset = -2, 2 do
		local r = row + rowOffset
		for columnOffset = -2, 2 do
			local c = column + columnOffset
			if r < 0 or r >= depthHeight or c < 0 or c >= depthWidth then
				return false -- the region edge counts as open water
			end
			if buffer.readu8(grid, r * depthWidth + c) ~= 0 then
				return false
			end
		end
	end

	return true
end

-- Nearest-cell land test (the renderer's sinking mask). False until a grid
-- has been set, and outside the grid (beyond the map edge is open sea).
function OceanDepthField.IsLandAt(x: number, z: number): boolean
	local grid = depthGrid
	if not grid then
		return false
	end

	local column = math.floor((x - depthOriginX) * depthInvCell)
	local row = math.floor((z - depthOriginZ) * depthInvCell)
	if column < 0 or column >= depthWidth or row < 0 or row >= depthHeight then
		return false
	end
	return buffer.readu8(grid, row * depthWidth + column) == 0
end

return OceanDepthField
