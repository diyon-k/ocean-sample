--!native
--
--	Author(s): Di
--	Module: OceanDepthCodec.lua
--
--	RLE + base64 codec for the server-baked ocean depth grid. The encoded
--	string travels in the OceanDepth StringValue, so it must be plain text
--	(base64), and open ocean is long runs of one byte (RLE crushes it).
--

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local B64_REVERSE: { [number]: number } = {}
for index = 1, 64 do
	B64_REVERSE[string.byte(BASE64, index)] = index - 1
end

local OceanDepthCodec = {}

--
--		RLE
--

-- (count, value) byte pairs, count 1..255.
local function rleEncode(source: buffer): buffer
	local length = buffer.len(source)
	local out = buffer.create(length * 2)
	local outAt = 0
	local at = 0

	while at < length do
		local value = buffer.readu8(source, at)
		local run = 1
		while run < 255 and at + run < length and buffer.readu8(source, at + run) == value do
			run += 1
		end

		buffer.writeu8(out, outAt, run)
		buffer.writeu8(out, outAt + 1, value)
		outAt += 2
		at += run
	end

	local packed = buffer.create(outAt)
	buffer.copy(packed, 0, out, 0, outAt)
	return packed
end

local function rleDecode(source: buffer, expectedLength: number): buffer?
	local length = buffer.len(source)
	if length % 2 ~= 0 then
		return nil
	end

	local out = buffer.create(expectedLength)
	local outAt = 0

	for at = 0, length - 2, 2 do
		local run = buffer.readu8(source, at)
		local value = buffer.readu8(source, at + 1)
		if run == 0 or outAt + run > expectedLength then
			return nil
		end
		buffer.fill(out, outAt, value, run)
		outAt += run
	end

	if outAt ~= expectedLength then
		return nil
	end
	return out
end

--
--		Base64
--

local function base64Encode(source: buffer): string
	local length = buffer.len(source)
	local parts = table.create(math.ceil(length / 3))
	local partCount = 0

	for at = 0, length - 1, 3 do
		local remaining = length - at
		local b0 = buffer.readu8(source, at)
		local b1 = if remaining > 1 then buffer.readu8(source, at + 1) else 0
		local b2 = if remaining > 2 then buffer.readu8(source, at + 2) else 0
		local chunk = b0 * 65536 + b1 * 256 + b2

		local c1 = math.floor(chunk / 262144) % 64
		local c2 = math.floor(chunk / 4096) % 64
		local c3 = math.floor(chunk / 64) % 64
		local c4 = chunk % 64

		partCount += 1
		parts[partCount] = string.sub(BASE64, c1 + 1, c1 + 1)
			.. string.sub(BASE64, c2 + 1, c2 + 1)
			.. (if remaining > 1 then string.sub(BASE64, c3 + 1, c3 + 1) else "=")
			.. (if remaining > 2 then string.sub(BASE64, c4 + 1, c4 + 1) else "=")
	end

	return table.concat(parts)
end

local function base64Decode(encoded: string): buffer?
	local length = #encoded
	if length == 0 or length % 4 ~= 0 then
		return nil
	end

	local padding = 0
	if string.byte(encoded, length) == 61 then -- "="
		padding += 1
		if string.byte(encoded, length - 1) == 61 then
			padding += 1
		end
	end

	local outLength = length / 4 * 3 - padding
	local out = buffer.create(outLength)
	local outAt = 0

	for at = 1, length, 4 do
		local a = B64_REVERSE[string.byte(encoded, at)]
		local b = B64_REVERSE[string.byte(encoded, at + 1)]
		local c = B64_REVERSE[string.byte(encoded, at + 2)] or 0
		local d = B64_REVERSE[string.byte(encoded, at + 3)] or 0
		if not a or not b then
			return nil
		end

		local chunk = a * 262144 + b * 4096 + c * 64 + d
		buffer.writeu8(out, outAt, math.floor(chunk / 65536))
		if outAt + 1 < outLength then
			buffer.writeu8(out, outAt + 1, math.floor(chunk / 256) % 256)
		end
		if outAt + 2 < outLength then
			buffer.writeu8(out, outAt + 2, chunk % 256)
		end
		outAt += 3
	end

	return out
end

--
--		Public
--

function OceanDepthCodec.Encode(grid: buffer): string
	return base64Encode(rleEncode(grid))
end

function OceanDepthCodec.Decode(encoded: string, expectedLength: number): buffer?
	local packed = base64Decode(encoded)
	if not packed then
		return nil
	end
	return rleDecode(packed, expectedLength)
end

return OceanDepthCodec
