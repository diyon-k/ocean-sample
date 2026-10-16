--
--	Author(s): Di
--	Module: depthcodec.spec.luau
--
--	The depth grid reaches every client through OceanDepthCodec, so a decode
--	that differs from the server's grid by one byte puts the shoreline in a
--	different place for that client. Every grid must survive encode -> decode
--	byte for byte.
--

local Harness = require("./harness")

local test, expect, expectEqual = Harness.test, Harness.expect, Harness.expectEqual

local Codec = Harness.newWorld():Require("Shared/OceanDepthCodec")

local function roundTrip(grid: buffer, label: string)
	local encoded = Codec.Encode(grid)
	expect(typeof(encoded) == "string", `{label}: encode must return a string`)
	expect(not string.find(encoded, "[^A-Za-z0-9+/=]"), `{label}: encoded text must be plain base64`)

	local decoded = Codec.Decode(encoded, buffer.len(grid))
	expect(decoded ~= nil, `{label}: decode returned nil`)
	expect(buffer.tostring(decoded :: buffer) == buffer.tostring(grid), `{label}: decoded grid differs from the original`)
	return encoded
end

local function filled(length: number, value: number): buffer
	local grid = buffer.create(length)
	buffer.fill(grid, 0, value)
	return grid
end

-- An island: land (0) in the middle, water deepening toward the edges.
local function island(width: number, height: number): buffer
	local grid = buffer.create(width * height)
	for row = 0, height - 1 do
		for column = 0, width - 1 do
			local dist = math.sqrt((column - width / 2) ^ 2 + (row - height / 2) ^ 2)
			local value = if dist < width / 5 then 0 else math.min(255, math.floor((dist - width / 5) * 3) + 1)
			buffer.writeu8(grid, row * width + column, value)
		end
	end
	return grid
end

print("OceanDepthCodec")

test("random grids round-trip", function()
	local random = Harness.rng(1234)
	for size = 1, 300, 7 do
		local grid = buffer.create(size)
		for index = 0, size - 1 do
			buffer.writeu8(grid, index, math.floor(random() * 256))
		end
		roundTrip(grid, `random size {size}`)
	end
end)

test("random runs (map-like data) round-trip", function()
	local random = Harness.rng(99)
	local grid = buffer.create(20000)
	local index = 0
	while index < 20000 do
		local run = 1 + math.floor(random() * 600)
		local value = math.floor(random() * 256)
		for _ = 1, math.min(run, 20000 - index) do
			buffer.writeu8(grid, index, value)
			index += 1
		end
	end
	roundTrip(grid, "random runs")
end)

test("all-land grid round-trips", function()
	roundTrip(filled(625 * 625, 0), "all land")
end)

test("all-deep grid round-trips", function()
	roundTrip(filled(625 * 625, 255), "all deep")
end)

test("single-cell grids round-trip", function()
	for _, value in { 0, 1, 128, 255 } do
		roundTrip(filled(1, value), `single cell {value}`)
	end
end)

test("lengths around the base64 padding boundary round-trip", function()
	for length = 1, 12 do
		local grid = buffer.create(length)
		for index = 0, length - 1 do
			buffer.writeu8(grid, index, (index * 37) % 256)
		end
		roundTrip(grid, `length {length}`)
	end
end)

test("large map-sized grid round-trips", function()
	roundTrip(island(625, 625), "625 x 625 island")
end)

test("open sea compresses to a tiny fraction (why the codec uses RLE)", function()
	local grid = filled(625 * 625, 255)
	local encoded = roundTrip(grid, "open sea")
	expect(#encoded < buffer.len(grid) / 50, `expected over 50x smaller, got {buffer.len(grid)} -> {#encoded} chars`)
end)

test("malformed input decodes to nil instead of a wrong grid", function()
	local grid = island(40, 40)
	local encoded = Codec.Encode(grid)

	expectEqual(Codec.Decode(encoded, buffer.len(grid) + 1), nil, "wrong expected length")
	expectEqual(Codec.Decode(string.sub(encoded, 1, #encoded - 4), buffer.len(grid)), nil, "truncated text")
	expectEqual(Codec.Decode("", 10), nil, "empty text")
	expectEqual(Codec.Decode("abc", 10), nil, "length not a multiple of 4")
	expectEqual(Codec.Decode("!!!!", 1), nil, "non-base64 characters")
end)

return nil
