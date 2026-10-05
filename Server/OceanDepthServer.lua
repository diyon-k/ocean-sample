--!native
--
--	Author(s): Di
--	Module: OceanDepthServer.lua
--
--	Bakes the water-depth grid once at server boot: amortized downward
--	raycasts over the Ocean part's footprint, quantized to bytes (0 = land).
--	Anything at or above the waterline covers its column entirely -- there is
--	no re-casting under structures, so the island skirt can never read as
--	below-sea water. Open-air basins with no path to the sea are then
--	re-classified as land, and the grid goes
--	RLE+base64 into the OceanDepth StringValue. Replication delivers it to
--	every client (late joiners included) -- no remotes. The single
--	deterministic source for shoaling, land masking, shore foam, and future
--	boat grounding / server-side validation.
--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OceanDepthCodec = shared("OceanDepthCodec") ---@module OceanDepthCodec
local OceanWaves = shared("OceanWaves") ---@module OceanWaves

local OCEAN_TAG = "Ocean"
local BOAT_TAG = "Boat"
local DEPTH_CELL = 8 -- studs per grid cell
local MAX_DEPTH = 80 -- studs mapped onto 1..255 (255 / no-hit = deep)
local RAYS_PER_STEP = 16384 -- bake amortization: rays per scheduler step
local RAY_UP = 300
local RAY_LENGTH = 1000
local BODY_RETRIES = 3 -- re-casts past player characters standing in the ray path
local INVISIBLE_RETRIES = 8 -- re-casts past fully transparent parts (triggers, zone volumes)
local VALUE_CHUNK = 190000 -- StringValue caps at 200k chars; big maps split across child chunks

local function bodyAncestor(instance: Instance): Model?
	local current: Instance? = instance
	while current do
		if current:IsA("Model") and current:FindFirstChildWhichIsA("Humanoid") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local OceanDepthServer = {}

-- One byte per column: 0 = land, else depth quantized over MAX_DEPTH.
function OceanDepthServer:_classifyColumn(x: number, z: number, seaLevel: number, params: RaycastParams, checkBodies: boolean): number
	local origin = Vector3.new(x, seaLevel + RAY_UP, z)
	local direction = Vector3.new(0, -RAY_LENGTH, 0)

	for _ = 1, 1 + BODY_RETRIES + INVISIBLE_RETRIES do
		local result = workspace:Raycast(origin, direction, params)
		if not result then
			return 255 -- open water / void: deep
		end

		local hit = result.Instance
		if hit:IsA("BasePart") and hit.Transparency >= 1 then
			params:AddToFilter(hit)
			continue
		end

		if checkBodies and not hit:IsA("Terrain") then
			local body = bodyAncestor(hit)
			if body then
				params:AddToFilter(body)
				continue
			end
		end

		local hitY = result.Position.Y
		if hitY > seaLevel - 0.05 then
			-- Covered = land, no exceptions: re-casting under elevated ground
			-- reads the island skirt's below-sea underside as ocean, which
			-- paints water inside the island. Costs water under docks and
			-- roofed sea caves; whitelist via re-cast if that ever matters.
			return 0
		end

		local depth = math.min(seaLevel - hitY, MAX_DEPTH)
		return math.max(1, math.min(255, math.ceil(depth / MAX_DEPTH * 255)))
	end

	return 0 -- retries exhausted with something still in the path: safest as land
end

-- Flood fill from the region border: water cells the fill never reaches have
-- no path to the open sea (open-air below-sea basins inside the island) and
-- become land. Covered columns always read as land, so the coastal barrier is
-- solid and plain connectivity is enough.
function OceanDepthServer:_sinkLandlockedPockets(grid: buffer, width: number, height: number): number
	local total = width * height
	local visited = buffer.create(total)
	local queue = buffer.create(total * 4)
	local head, tail = 0, 0

	local function push(index: number)
		if buffer.readu8(visited, index) == 0 and buffer.readu8(grid, index) ~= 0 then
			buffer.writeu8(visited, index, 1)
			buffer.writeu32(queue, tail * 4, index)
			tail += 1
		end
	end

	for column = 0, width - 1 do
		push(column)
		push((height - 1) * width + column)
	end
	for row = 1, height - 2 do
		push(row * width)
		push(row * width + width - 1)
	end

	while head < tail do
		local index = buffer.readu32(queue, head * 4)
		head += 1

		local column = index % width
		if column > 0 then
			push(index - 1)
		end
		if column < width - 1 then
			push(index + 1)
		end
		if index >= width then
			push(index - width)
		end
		if index + width < total then
			push(index + width)
		end
	end

	local sunk = 0
	for index = 0, total - 1 do
		if buffer.readu8(grid, index) ~= 0 and buffer.readu8(visited, index) == 0 then
			buffer.writeu8(grid, index, 0)
			sunk += 1
		end
	end

	return sunk
end

function OceanDepthServer:StartAsync()
	debug.setmemorycategory("OceanDepth")

	local oceanPart = OceanWaves.GetOceanPart()
	if not oceanPart then
		CollectionService:GetInstanceAddedSignal(OCEAN_TAG):Wait()
		oceanPart = OceanWaves.GetOceanPart()
	end

	local seaLevel = oceanPart.Position.Y
	local originX, originZ, sizeX, sizeZ = OceanWaves.GetOceanRegion()
	assert(originX and originZ and sizeX and sizeZ, "ocean region unavailable")
	local width = math.max(1, math.ceil(sizeX / DEPTH_CELL))
	local height = math.max(1, math.ceil(sizeZ / DEPTH_CELL))

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- The seabed is collidable geometry only: terrain water and decorative
	-- non-collide planes at sea level would otherwise read as depth ~0 and
	-- flatten the whole ocean.
	params.IgnoreWater = true
	params.RespectCanCollide = true
	local exclude: { Instance } = { oceanPart }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	-- Boats float ON the water; their hulls must never bake as seabed.
	for _, boat in CollectionService:GetTagged(BOAT_TAG) do
		table.insert(exclude, boat)
	end
	params.FilterDescendantsInstances = exclude

	local grid = buffer.create(width * height)
	local started = os.clock()
	local sinceStep = 0
	local checkBodies = #Players:GetPlayers() > 0

	for row = 0, height - 1 do
		local z = originZ + (row + 0.5) * DEPTH_CELL
		for column = 0, width - 1 do
			local x = originX + (column + 0.5) * DEPTH_CELL
			local value = self:_classifyColumn(x, z, seaLevel, params, checkBodies)
			buffer.writeu8(grid, row * width + column, value)

			sinceStep += 1
			if sinceStep >= RAYS_PER_STEP then
				sinceStep = 0
				task.wait()
				checkBodies = #Players:GetPlayers() > 0
			end
		end
	end

	local pocketCells = self:_sinkLandlockedPockets(grid, width, height)

	local landCells, shallowCells = 0, 0
	for index = 0, width * height - 1 do
		local value = buffer.readu8(grid, index)
		if value == 0 then
			landCells += 1
		elseif value < 26 then -- < ~8 studs deep
			shallowCells += 1
		end
	end

	OceanWaves.SetDepthGrid(grid, originX, originZ, DEPTH_CELL, width, height, MAX_DEPTH)

	local encoded = OceanDepthCodec.Encode(grid)

	local value = Instance.new("StringValue")
	value.Name = "OceanDepth"
	value:SetAttribute("CellSize", DEPTH_CELL)
	value:SetAttribute("OriginX", originX)
	value:SetAttribute("OriginZ", originZ)
	value:SetAttribute("Width", width)
	value:SetAttribute("Height", height)
	value:SetAttribute("MaxDepth", MAX_DEPTH)
	local chunkCount = math.ceil(#encoded / VALUE_CHUNK)
	value:SetAttribute("ChunkCount", chunkCount)
	for index = 1, chunkCount do
		local chunk = Instance.new("StringValue")
		chunk.Name = tostring(index)
		chunk.Value = string.sub(encoded, (index - 1) * VALUE_CHUNK + 1, index * VALUE_CHUNK)
		chunk.Parent = value
	end
	-- ReplicatedStorage, NOT the ocean part: the part lives in the streamed
	-- world, and the depth data must reach every client unconditionally.
	value.Parent = ReplicatedStorage

	print(string.format(
		"Ocean depth baked: %dx%d cells in %.1fs, %d KB encoded (%d land incl %d landlocked, %d shallow, %d deep)",
		width,
		height,
		os.clock() - started,
		math.ceil(#encoded / 1024),
		landCells,
		pocketCells,
		shallowCells,
		width * height - landCells - shallowCells
	))
end

return OceanDepthServer
