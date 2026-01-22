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
local ALL_CLOCKS = { "chronos", "posix.time", "socket" }

--- Return all clocks except the specified one.
---@param clock_name string Clock to keep.
---@return string[]
local function clocks_except(clock_name)
   local result = {}
   for i = 1, #ALL_CLOCKS do
      if ALL_CLOCKS[i] ~= clock_name then
         result[#result + 1] = ALL_CLOCKS[i]
      end
   end
   return result
end

--- Load luamark for testing. Sets _G._TEST and optionally blocks specific clock modules.
---@param blocked_modules? string[] Modules to block.
---@return table
local function load_luamark(blocked_modules)
   _G._TEST = true
   package.loaded["luamark"] = nil

   if not blocked_modules then
      return require("luamark")
   end

   local blocked = {}
   for i = 1, #blocked_modules do
      local name = blocked_modules[i]
      package.loaded[name] = nil
      blocked[name] = true
   end

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
   ALL_CLOCKS = ALL_CLOCKS,
   CLOCKS = CLOCKS,
   clocks_except = clocks_except,
   load_luamark = load_luamark,
   noop = noop,
}
