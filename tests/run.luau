--
--	Author(s): Di
--	Module: run.luau
--
--	Runs every spec and exits non-zero if any test fails. Run from the repo
--	root: lune run tests/run
--

local process = require("@lune/process")

local Harness = require("./harness")

require("./depthcodec.spec")

local results = Harness.results()
print(`\n{results.Passed} passed, {#results.Failed} failed`)

if #results.Failed > 0 then
	process.exit(1)
end
