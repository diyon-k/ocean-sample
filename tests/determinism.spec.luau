--
--	Author(s): Di
--	Module: determinism.spec.luau
--
--	The no-sync claim: the server bakes the depth grid and ships it once
--	through OceanDepthCodec; every client then computes the water itself.
--	Three independent copies of the real OceanWaves -- one server, two
--	clients fed only the encoded grid -- must agree exactly at every point
--	and time, or clients would see different seas.
--

local Harness = require("./harness")

local test, expect = Harness.test, Harness.expect

local WIDTH, HEIGHT, CELL, MAX_DEPTH = 64, 64, 8, 80
local ORIGIN_X, ORIGIN_Z = -256, -256

-- An island in the middle of the grid, the seabed falling away from it.
local function bakeGrid(): buffer
	local grid = buffer.create(WIDTH * HEIGHT)
	for row = 0, HEIGHT - 1 do
		for column = 0, WIDTH - 1 do
			local dist = math.sqrt((column - 31.5) ^ 2 + (row - 31.5) ^ 2)
			local value = if dist < 10 then 0 else math.min(255, math.floor((dist - 10) * 12) + 1)
			buffer.writeu8(grid, row * WIDTH + column, value)
		end
	end
	return grid
end

local function newMachine(isClient: boolean, grid: buffer?, encoded: string?)
	local world = Harness.newWorld({ IsClient = isClient })
	local OceanWaves = world:Require("Shared/OceanWaves")
	local Codec = world:Require("Shared/OceanDepthCodec")

	local depth = grid or assert(Codec.Decode(encoded :: string, WIDTH * HEIGHT), "client failed to decode the grid")
	OceanWaves.SetDepthGrid(depth, ORIGIN_X, ORIGIN_Z, CELL, WIDTH, HEIGHT, MAX_DEPTH)
	return OceanWaves
end

local serverGrid = bakeGrid()
local encoded = Harness.newWorld():Require("Shared/OceanDepthCodec").Encode(serverGrid)

local server = newMachine(false, serverGrid, nil)
local clientA = newMachine(true, nil, encoded)
local clientB = newMachine(true, nil, encoded)

local TIMES = { 0, 1.25, 7.5, 1234.5 }

print("\nOceanWaves determinism")

test("server and two clients compute identical water everywhere", function()
	local compared = 0
	for _, t in TIMES do
		for x = -300, 300, 13 do
			for z = -300, 300, 13 do
				local s = { server.GetDisplacementAt(x, z, t) }
				local a = { clientA.GetDisplacementAt(x, z, t) }
				local b = { clientB.GetDisplacementAt(x, z, t) }
				for i = 1, 4 do
					if s[i] ~= a[i] or s[i] ~= b[i] then
						error(`({x}, {z}) at t={t}: server {s[i]}, client A {a[i]}, client B {b[i]} (return {i})`)
					end
				end
				compared += 1
			end
		end
	end
	expect(compared > 1000, "too few samples compared")
end)

test("the same query twice gives the same answer", function()
	for x = -200, 200, 37 do
		local first = { clientA.GetDisplacementAt(x, 40, 3.3) }
		local second = { clientA.GetDisplacementAt(x, 40, 3.3) }
		for i = 1, 4 do
			expect(first[i] == second[i], `repeat query at x={x} changed (return {i})`)
		end
	end
end)

-- Guards against a vacuous pass: if the water never moved, identical
-- answers would prove nothing.
test("the shoreline water actually moves over time", function()
	local moving = 0
	for x = -300, 300, 13 do
		for z = -300, 300, 13 do
			local _, dyEarly = server.GetDisplacementAt(x, z, 0)
			local _, dyLate = server.GetDisplacementAt(x, z, 1.25)
			if dyEarly ~= dyLate then
				moving += 1
			end
		end
	end
	expect(moving > 50, `expected surf to move near the island, only {moving} points changed`)
end)

return nil
