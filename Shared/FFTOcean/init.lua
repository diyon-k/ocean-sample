--!native
--
--	Author(s): Di
--	Module: FFTOcean.lua
--
--	STUB. The shipped version is a Tessendorf FFT simulation that is not
--	included here. This keeps the interface the renderer and OceanWaves
--	consume, and outputs a flat field so everything runs out of the box.
--	Plug your own wave field into computeField.
--
--	Field buffers are complex-interleaved f32, 8 bytes per cell, row-major
--	(index = (z * n + x) * 8), tiling every TILE studs:
--		height	Re = dy
--		plane	Re = dx, Im = dz (horizontal chop)
--		normal	Re = d(dy)/dx, Im = d(dy)/dz
--	Values are raw units; RawAmplitude (the |dy| peak at t = 0) calibrates
--	them to studs. Must be deterministic in t so every machine agrees.
--

local RunService = game:GetService("RunService")

local IS_CLIENT = RunService:IsClient()

local RESOLUTION = 64
local LOW_RESOLUTION = 16 -- low-passed twin for the coarse LOD rings
local TILE = 512
local RATE = 20 -- field steps per second

local FFTOcean = {}
FFTOcean.Resolution = RESOLUTION
FFTOcean.LowResolution = LOW_RESOLUTION
FFTOcean.Tile = TILE
FFTOcean.Rate = RATE
FFTOcean.RawAmplitude = 1

local function createField(n: number)
	return {
		Height = buffer.create(n * n * 8),
		Plane = buffer.create(n * n * 8),
		Normal = buffer.create(n * n * 8),
	}
end

local current = { Full = createField(RESOLUTION), Low = createField(LOW_RESOLUTION) }
local previous = { Full = createField(RESOLUTION), Low = createField(LOW_RESOLUTION) }
local currentStep = -1
local currentTime = 0
local previousTime = 0
local isInitialized = false

-- Fill one n x n field for time t. Called for both resolutions.
local function computeField(t: number, n: number, field)
	buffer.fill(field.Height, 0, 0)
	buffer.fill(field.Plane, 0, 0)
	buffer.fill(field.Normal, 0, 0)
end

local function computeStep(target, t: number)
	computeField(t, RESOLUTION, target.Full)
	computeField(t, LOW_RESOLUTION, target.Low)
end

local function copyField(into, from)
	buffer.copy(into.Height, 0, from.Height)
	buffer.copy(into.Plane, 0, from.Plane)
	buffer.copy(into.Normal, 0, from.Normal)
end

local function getAlpha(t: number): number
	local span = currentTime - previousTime
	return if span > 0 then math.clamp((t - previousTime) / span, 0, 1) else 1
end

local function blendInto(alpha: number, from, to, height: buffer, plane: buffer, normal: buffer, n: number)
	for index = 0, n * n * 2 - 1 do
		local byte = index * 4
		local h = buffer.readf32(from.Height, byte)
		local p = buffer.readf32(from.Plane, byte)
		local d = buffer.readf32(from.Normal, byte)
		buffer.writef32(height, byte, h + (buffer.readf32(to.Height, byte) - h) * alpha)
		buffer.writef32(plane, byte, p + (buffer.readf32(to.Plane, byte) - p) * alpha)
		buffer.writef32(normal, byte, d + (buffer.readf32(to.Normal, byte) - d) * alpha)
	end
end

function FFTOcean.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	computeStep(current, 0)

	local peak = 0
	for index = 0, RESOLUTION * RESOLUTION - 1 do
		peak = math.max(peak, math.abs(buffer.readf32(current.Full.Height, index * 8)))
	end
	FFTOcean.RawAmplitude = if peak > 0 then peak else 1

	copyField(previous.Full, current.Full)
	copyField(previous.Low, current.Low)
end

-- Advances to the quantized step for t (default: synced server time). Clients
-- only compute when given a deadline (the renderer's budgeted call); gameplay
-- queries ride the published fields. Returns true when a new step publishes.
function FFTOcean.Update(t: number?, deadline: number?): boolean
	FFTOcean.Initialize()

	local time = t or workspace:GetServerTimeNow()
	local step = math.floor(time * RATE)
	if step == currentStep then
		return false
	end

	if deadline == nil and IS_CLIENT then
		return false
	end

	current, previous = previous, current
	computeStep(current, step / RATE)

	previousTime = if currentStep < 0 then step / RATE else currentTime
	currentTime = step / RATE
	currentStep = step
	return true
end

-- Steps are computed whole, so there is never a step in flight.
function FFTOcean.IsBusy(): boolean
	return false
end

function FFTOcean.GetStep(): number
	return currentStep
end

-- Blends the two latest steps at time t into the caller's buffers. Full
-- resolution outputs are optional.
function FFTOcean.WriteBlended(t: number, heightLow: buffer, planeLow: buffer, normalLow: buffer, height: buffer?, plane: buffer?, normal: buffer?)
	local alpha = getAlpha(t)
	blendInto(alpha, previous.Low, current.Low, heightLow, planeLow, normalLow, LOW_RESOLUTION)

	if height and plane and normal then
		blendInto(alpha, previous.Full, current.Full, height, plane, normal, RESOLUTION)
	end
end

function FFTOcean.GetBuffers(): (buffer, buffer, buffer)
	assert(isInitialized, "FFTOcean.Update must run before GetBuffers")
	return current.Full.Height, current.Full.Plane, current.Full.Normal
end

local function bilinear(field: buffer, offset: number, i00: number, i10: number, i01: number, i11: number, fx: number, fz: number): number
	return buffer.readf32(field, i00 + offset) * (1 - fx) * (1 - fz)
		+ buffer.readf32(field, i10 + offset) * fx * (1 - fz)
		+ buffer.readf32(field, i01 + offset) * (1 - fx) * fz
		+ buffer.readf32(field, i11 + offset) * fx * fz
end

-- Bilinear, tile-wrapped raw (dx, dy, dz) at world (x, z), blended at time t.
function FFTOcean.SampleAt(x: number, z: number, t: number): (number, number, number)
	local n = RESOLUTION
	local alpha = getAlpha(t)

	local u = (x / TILE) % 1 * n
	local v = (z / TILE) % 1 * n
	local x0 = math.floor(u) % n
	local z0 = math.floor(v) % n
	local x1 = (x0 + 1) % n
	local z1 = (z0 + 1) % n
	local fx = u % 1
	local fz = v % 1

	local i00 = (z0 * n + x0) * 8
	local i10 = (z0 * n + x1) * 8
	local i01 = (z1 * n + x0) * 8
	local i11 = (z1 * n + x1) * 8

	local curr, prev = current.Full, previous.Full
	local dxP = bilinear(prev.Plane, 0, i00, i10, i01, i11, fx, fz)
	local dyP = bilinear(prev.Height, 0, i00, i10, i01, i11, fx, fz)
	local dzP = bilinear(prev.Plane, 4, i00, i10, i01, i11, fx, fz)
	local dxC = bilinear(curr.Plane, 0, i00, i10, i01, i11, fx, fz)
	local dyC = bilinear(curr.Height, 0, i00, i10, i01, i11, fx, fz)
	local dzC = bilinear(curr.Plane, 4, i00, i10, i01, i11, fx, fz)

	return dxP + (dxC - dxP) * alpha, dyP + (dyC - dyP) * alpha, dzP + (dzC - dzP) * alpha
end

return FFTOcean
