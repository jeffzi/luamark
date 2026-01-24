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

--- Verify stats object exists and all its fields are non-nil.
---@param stats table
local function assert_stats_valid(stats)
   assert(stats, "stats should not be nil")
   for field, value in pairs(stats) do
      assert(value ~= nil, "stats." .. field .. " should not be nil")
   end
end

--- Create a mock benchmark result row (flat structure).
---@param name string
---@param median number
---@param rank_value integer
---@param ratio_value number
---@param opts? {unit?: "s"|"kb", ci_lower?: number, ci_upper?: number, is_approximate?: boolean}
---@return table
local function make_result_row(name, median, rank_value, ratio_value, opts)
   opts = opts or {}
   local unit = opts.unit or "s"
   local ci_lower = opts.ci_lower or (median * 0.9)
   local ci_upper = opts.ci_upper or (median * 1.1)
   local row = {
      name = name,
      median = median,
      ci_lower = ci_lower,
      ci_upper = ci_upper,
      ci_margin = (ci_upper - ci_lower) / 2,
      rounds = 10,
      iterations = 1000,
      unit = unit,
      rank = rank_value,
      ratio = ratio_value,
      is_approximate = opts.is_approximate or false,
   }
   if unit == "s" and median > 0 then
      row.ops = 1 / median
   end
   return row
end

return {
   ALL_CLOCKS = ALL_CLOCKS,
   CLOCKS = CLOCKS,
   assert_stats_valid = assert_stats_valid,
   clocks_except = clocks_except,
   load_luamark = load_luamark,
   make_result_row = make_result_row,
   noop = noop,
}
