---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

local original_require = require

--- Require a module, failing the test if not installed.
---@param name string Module name to require.
---@return table
local function require_or_fail(name)
   local ok, module = pcall(original_require, name)
   assert(ok, string.format("Dependency '%s' is required for testing.", name))
   return module
end

require_or_fail("chronos")
require_or_fail("allocspy")
local posix_time = require_or_fail("posix.time")

local CLOCKS = posix_time.clock_gettime and { "chronos", "posix.time" } or { "chronos" }

--- Load luamark for testing. Sets _G._TEST and optionally forces a specific clock.
---@param clock_module? string Clock module to use (blocks others). If nil, uses default.
---@return table
local function load_luamark(clock_module)
   _G._TEST = true
   package.loaded["luamark"] = nil

   if not clock_module then
      return require("luamark")
   end

   -- Build set of blocked clock modules and clear their cache
   local blocked = {}
   for i = 1, #CLOCKS do
      package.loaded[CLOCKS[i]] = nil
      blocked[CLOCKS[i]] = (CLOCKS[i] ~= clock_module)
   end

   -- Temporarily replace require to block other clocks
   _G.require = function(name)
      if blocked[name] then
         error(string.format("module '%s' not found", name))
      end
      return original_require(name)
   end

   local ok, result = pcall(require, "luamark")
   _G.require = original_require
   assert(ok, result)
   return result
end

local function noop() end

return {
   load_luamark = load_luamark,
   noop = noop,
   CLOCKS = CLOCKS,
}
