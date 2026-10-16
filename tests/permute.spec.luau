--
--	Author(s): Di
--	Module: permute.spec.luau
--
--	The caching claim: when the rings shift, Permute carries each vertex's
--	statics over from whichever vertex already sat on that world point and
--	RunIndices bakes only the misses. That shortcut must give exactly the same
--	statics as baking every vertex from scratch at the new origin.
--

local Harness = require("./harness")
local Fixtures = require("./oceanfixtures")

local test, expect, expectEqual = Harness.test, Harness.expect, Harness.expectEqual

local ORIGIN_X, ORIGIN_Z = 64, -96 -- whole snap steps, like the renderer's lattice

local SHIFTS = {
	{ Name = "straight +X", X = 32, Z = 0 },
	{ Name = "straight -Z", X = 0, Z = -32 },
	{ Name = "diagonal", X = 32, Z = 32 },
	{ Name = "diagonal (other way)", X = -32, Z = 32 },
	{ Name = "multi-cell", X = 96, Z = -160 },
}

local function firstDifference(a: buffer, b: buffer, stride: number): number?
	for offset = 0, buffer.len(a) - 1, stride do
		if buffer.readu32(a, offset) ~= buffer.readu32(b, offset) then
			return offset // stride + 1
		end
	end
	return nil
end

local function expectSameStatics(cached, fresh, label: string)
	local layout = cached.Layout
	for _, name in Fixtures.F32 do
		local index = firstDifference(cached[name], fresh[name], 4)
		if index then
			error(`{label}: {name} differs at vertex {index} (local {layout.LocalX[index]}, {layout.LocalZ[index]}): cached {buffer.readf32(cached[name], (index - 1) * 4)}, fresh {buffer.readf32(fresh[name], (index - 1) * 4)}`, 2)
		end
	end

	expect(buffer.tostring(cached.FlagsBuf) == buffer.tostring(fresh.FlagsBuf), `{label}: FlagsBuf differs`)
	for index = 1, layout.Count do
		expectEqual(cached.FoamCache[index], fresh.FoamCache[index], `{label}: FoamCache[{index}]`)
	end
end

-- Bakes the level at the old origin, shifts it with Permute + RunIndices, and
-- compares against a from-scratch bake at the new origin. Returns the misses.
local function shiftAndCompare(OceanRebuild, levelLayout, shiftX: number, shiftZ: number, label: string): number
	local count = levelLayout.Count

	local cached = Fixtures.newState(levelLayout)
	local renderer = Fixtures.newRenderer(OceanRebuild, count, ORIGIN_X, ORIGIN_Z)
	OceanRebuild.Run(renderer, cached, 1, count)

	renderer._originX += shiftX
	renderer._originZ += shiftZ
	local misses = OceanRebuild.Permute(renderer, cached, shiftX, shiftZ)
	OceanRebuild.RunIndices(renderer, cached, misses)

	local fresh = Fixtures.newState(levelLayout)
	local freshRenderer = Fixtures.newRenderer(OceanRebuild, count, ORIGIN_X + shiftX, ORIGIN_Z + shiftZ)
	OceanRebuild.Run(freshRenderer, fresh, 1, count)

	expectSameStatics(cached, fresh, label)
	return #misses
end

print("\nOceanRebuild.Permute")

for _, variant in { { Name = "with a depth grid", HasGrid = true }, { Name = "before the depth grid arrives", HasGrid = false } } do
	local OceanRebuild, layout = Fixtures.load(variant.HasGrid)

	for _, shift in SHIFTS do
		test(`{shift.Name} shift matches a full bake ({variant.Name})`, function()
			for levelIndex, levelLayout in layout.Levels do
				local misses = shiftAndCompare(OceanRebuild, levelLayout, shift.X, shift.Z, `ring {levelIndex}`)

				-- A ring only keeps vertices when the shift is smaller than its width.
				local span = 2 * levelLayout.HalfExtent
				if math.abs(shift.X) <= span and math.abs(shift.Z) <= span then
					expect(misses > 0 and misses < levelLayout.Count, `ring {levelIndex}: an overlapping shift should reuse some vertices and bake the rest`)
				else
					expectEqual(misses, levelLayout.Count, `ring {levelIndex}: a shift wider than the ring misses every vertex`)
				end
			end
		end)
	end

	test(`teleport (no overlap) misses every vertex ({variant.Name})`, function()
		for levelIndex, levelLayout in layout.Levels do
			local misses = shiftAndCompare(OceanRebuild, levelLayout, 4096, -4096, `ring {levelIndex}`)
			expectEqual(misses, levelLayout.Count, `ring {levelIndex} misses`)
		end
	end)
end

test("the fixture reaches every bake branch", function()
	local OceanRebuild, layout = Fixtures.load(true)
	local seen = { Land = false, Swash = false, Open = false, Surf = false, Calm = false }

	for _, levelLayout in layout.Levels do
		local state = Fixtures.newState(levelLayout)
		OceanRebuild.Run(Fixtures.newRenderer(OceanRebuild, levelLayout.Count, ORIGIN_X, ORIGIN_Z), state, 1, levelLayout.Count)
		for index = 0, levelLayout.Count - 1 do
			local class = buffer.readu8(state.FlagsBuf, index) % 4
			seen.Land = seen.Land or class == 1
			seen.Swash = seen.Swash or class == 2
			seen.Open = seen.Open or class == 0
			local surf = class ~= 1 and buffer.readf32(state.ShoreAmpS, index * 4) > 0
			seen.Surf = seen.Surf or surf
			seen.Calm = seen.Calm or (class == 0 and not surf)
		end
	end

	for branch, reached in seen do
		expect(reached, `fixture never reaches the {branch} branch`)
	end
end)

return nil
