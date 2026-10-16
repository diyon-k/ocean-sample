--
--	Author(s): Di
--	Module: harness.luau
--
--	Loads the repo's modules outside the engine, unchanged. A World is one
--	machine: its own module cache and its own shared() table, so two Worlds
--	behave like two independent clients. The engine pieces the modules touch
--	(script, shared, game, workspace, Roblox datatypes) are stood in here; the
--	modules themselves are never edited for testing.
--

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- shared("Name") -> module path, for the modules the tests load for real.
local SHARED_PATHS = {
	FFTOcean = "Shared/FFTOcean",
	Maid = "Shared/Maid",
	OceanDepthCodec = "Shared/OceanDepthCodec",
	OceanWaves = "Shared/OceanWaves",
	OceanMesh = "Client/OceanRenderer/OceanMesh",
	OceanRebuild = "Client/OceanRenderer/OceanRebuild",
}

local hostEnv = getfenv(1)

local debugLib = setmetatable({
	profilebegin = function() end,
	profileend = function() end,
}, { __index = debug })

local function resolveFile(path: string): string?
	if fs.isFile(path .. ".lua") then
		return path .. ".lua"
	end
	if fs.isFile(path .. "/init.lua") then
		return path .. "/init.lua"
	end
	return nil
end

local function newSignal()
	return {
		Connect = function()
			return { Disconnect = function() end }
		end,
	}
end

--
--		Instance stand-in
--

-- A path into the repo that indexes like an Instance: script.Parent and
-- script.Child walk the folder tree the way Rojo maps it into the engine.
local Node = {}

local function newNode(world, path: string)
	return setmetatable({ _world = world, _path = path }, Node)
end

Node.__index = function(self, key)
	local path = rawget(self, "_path")
	if key == "Parent" then
		local parent = string.match(path, "^(.*)/[^/]+$")
		return if parent then newNode(rawget(self, "_world"), parent) else nil
	end
	return newNode(rawget(self, "_world"), path .. "/" .. key)
end

--
--		World
--

local World = {}
World.__index = World

export type WorldOptions = {
	IsClient: boolean?, -- RunService:IsClient()
	Time: number?, -- workspace:GetServerTimeNow()
	Shared: { [string]: any }?, -- shared("Name") stubs
	Modules: { [string]: any }?, -- stubs for files the repo leaves out, by path
}

local Harness = {}

function Harness.newWorld(options: WorldOptions?)
	local opts = options or {}

	local services = {
		CollectionService = {
			GetTagged = function()
				return {}
			end,
			GetInstanceAddedSignal = newSignal,
			GetInstanceRemovedSignal = newSignal,
		},
		RunService = {
			IsClient = function()
				return opts.IsClient == true
			end,
			IsServer = function()
				return opts.IsClient ~= true
			end,
		},
	}

	local world = setmetatable({
		_cache = {},
		_shared = opts.Shared or {},
		_modules = opts.Modules or {},
	}, World)

	world._globals = setmetatable({
		debug = debugLib,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Color3 = roblox.Color3,
		game = {
			GetService = function(_, name: string)
				return assert(services[name], `service not stubbed: {name}`)
			end,
		},
		workspace = {
			GetServerTimeNow = function()
				return opts.Time or 0
			end,
		},
		shared = function(name: string)
			local stub = world._shared[name]
			if stub ~= nil then
				return stub
			end
			return world:Require(assert(SHARED_PATHS[name], `shared: unknown module {name}`))
		end,
	}, { __index = hostEnv })

	return world
end

-- Loads (once per World) the module at a repo path, e.g. "Shared/OceanWaves".
function World:Require(path: string)
	local cached = self._cache[path]
	if cached ~= nil then
		return cached
	end

	local stub = self._modules[path]
	if stub ~= nil then
		self._cache[path] = stub
		return stub
	end

	local file = assert(resolveFile(path), `no module at {path}`)
	local env = setmetatable({
		script = newNode(self, path),
		require = function(target)
			assert(getmetatable(target) == Node, "require expects a script reference")
			return self:Require(rawget(target, "_path"))
		end,
	}, { __index = self._globals })

	local chunk = luau.load(fs.readFile(file), { debugName = file, environment = env })
	local result = chunk()
	self._cache[path] = result
	return result
end

--
--		Test runner
--

local results = { Passed = 0, Failed = {} }

function Harness.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		results.Passed += 1
		print(`  ok    {name}`)
	else
		table.insert(results.Failed, name)
		print(`  FAIL  {name}\n        {err}`)
	end
end

function Harness.expect(condition: any, message: string)
	if not condition then
		error(message, 2)
	end
end

function Harness.expectEqual(actual: any, expected: any, message: string)
	if actual ~= expected then
		error(`{message}: expected {expected}, got {actual}`, 2)
	end
end

function Harness.results()
	return results
end

-- Deterministic pseudo-random numbers (an LCG), so every run and every
-- machine tests the same inputs.
function Harness.rng(seed: number)
	local state = seed % 2147483647
	return function(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

return Harness
