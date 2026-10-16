--
--	Author(s): Di
--	Module: misscount.spec.luau
--
--	The README's numbers, measured on the real ring layout: 8,705 vertices,
--	and the share Permute has to re-bake when the rings shift one 32-stud
--	snap step -- about 9% in a straight line, about 17% diagonally.
--

local Harness = require("./harness")
local Fixtures = require("./oceanfixtures")

local test, expectEqual = Harness.test, Harness.expectEqual

local OceanRebuild, layout = Fixtures.load(true)

local function totalVertices(): number
	local total = 0
	for _, levelLayout in layout.Levels do
		total += levelLayout.Count
	end
	return total
end

-- Misses across every ring for one snap, as a percentage of all vertices.
local function missShare(shiftX: number, shiftZ: number): (number, number)
	local misses = 0
	for _, levelLayout in layout.Levels do
		local state = Fixtures.newState(levelLayout)
		local renderer = Fixtures.newRenderer(OceanRebuild, levelLayout.Count, shiftX, shiftZ)
		misses += #OceanRebuild.Permute(renderer, state, shiftX, shiftZ)
	end
	return misses, misses / totalVertices() * 100
end

print("\nRing layout numbers")

test("the ring layout has 8,705 vertices", function()
	expectEqual(totalVertices(), 8705, "total vertices")
end)

local step = Fixtures.SnapStep

test("a straight snap re-bakes about 9% of vertices", function()
	for _, shift in { { step, 0 }, { -step, 0 }, { 0, step }, { 0, -step } } do
		local misses, share = missShare(shift[1], shift[2])
		print(string.format("        shift (%d, %d): %d misses = %.2f%%", shift[1], shift[2], misses, share))
		expectEqual(math.round(share), 9, "rounded straight-shift share (%)")
	end
end)

test("a diagonal snap re-bakes about 17% of vertices", function()
	for _, shift in { { step, step }, { -step, step }, { step, -step }, { -step, -step } } do
		local misses, share = missShare(shift[1], shift[2])
		print(string.format("        shift (%d, %d): %d misses = %.2f%%", shift[1], shift[2], misses, share))
		expectEqual(math.round(share), 17, "rounded diagonal-shift share (%)")
	end
end)

return nil
