---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

local lua_require = require

--- Require a module, failing the test if not installed.
---@param module string Module name to require.
---@return table
local function try_require(module)
   local module_installed, lib = pcall(lua_require, module)
   assert(module_installed, string.format("Dependency '%s' is required for testing.", module))
   return lib
end

try_require("chronos")
try_require("allocspy")
local posix_time = try_require("posix.time")

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

   local blocked = {}
   for i = 1, #CLOCKS do
      local name = CLOCKS[i]
      package.loaded[name] = nil
      blocked[name] = (name ~= clock_module)
   end

   local original_require = _G.require
   _G.require = function(name)
      if blocked[name] then
         error(string.format("module '%s' not found", name))
      end
      return original_require(name)
   end

   local luamark = require("luamark")
   _G.require = original_require
   return luamark
end

local function noop() end

return {
   load_luamark = load_luamark,
   noop = noop,
   CLOCKS = CLOCKS,
}
