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

local has_posix, posix_time = pcall(original_require, "posix.time")

local ALL_CLOCKS = has_posix and { "chronos", "posix.time", "socket" } or { "chronos", "socket" }
local CLOCKS = (has_posix and posix_time.clock_gettime) and ALL_CLOCKS or { "chronos", "socket" }

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

local REQUIRED_STATS_FIELDS =
   { "median", "ci_lower", "ci_upper", "ci_margin", "rounds", "iterations", "unit" }

--- Verify stats object exists and all its fields are non-nil.
---@param stats table
local function assert_stats_valid(stats)
   assert(stats, "stats should not be nil")
   for i = 1, #REQUIRED_STATS_FIELDS do
      local field = REQUIRED_STATS_FIELDS[i]
      assert(stats[field] ~= nil, "stats." .. field .. " should not be nil")
   end
end

--- Create a mock benchmark result row.
---@param name string
---@param median number
---@param rank_value integer
---@param relative_value number
---@param opts? {unit?: "s"|"kb", ci_lower?: number, ci_upper?: number, ci_margin?: number, is_approximate?: boolean, params?: table}
---@return table
local function make_result_row(name, median, rank_value, relative_value, opts)
   opts = opts or {}
   local unit = opts.unit or "s"
   local ci_lower = opts.ci_lower or (median * 0.9)
   local ci_upper = opts.ci_upper or (median * 1.1)
   local ci_margin = opts.ci_margin or (ci_upper - ci_lower) / 2
   local row = {
      name = name,
      median = median,
      ci_lower = ci_lower,
      ci_upper = ci_upper,
      ci_margin = ci_margin,
      rounds = 10,
      iterations = 1000,
      unit = unit,
      rank = rank_value,
      relative = relative_value,
      is_approximate = opts.is_approximate or false,
      params = opts.params or {},
   }
   if unit == "s" and median > 0 then
      row.ops = 1 / median
   end
   return row
end

--- Create a mock Stats object (from timeit/memit).
---@param median number
---@param opts? {unit?: "s"|"kb", rounds?: integer, total?: number}
---@return table
local function make_stats(median, opts)
   opts = opts or {}
   local unit = opts.unit or "s"
   local rounds = opts.rounds or 100
   local ci_lower = median * 0.99
   local ci_upper = median * 1.01
   local stats = {
      median = median,
      ci_lower = ci_lower,
      ci_upper = ci_upper,
      ci_margin = (ci_upper - ci_lower) / 2,
      rounds = rounds,
      iterations = 1000,
      total = opts.total or (median * rounds),
      unit = unit,
      timestamp = "2025-01-01 00:00:00Z",
      samples = {},
   }
   if unit == "s" and median > 0 then
      stats.ops = 1 / median
   end
   return stats
end

return {
   ALL_CLOCKS = ALL_CLOCKS,
   CLOCKS = CLOCKS,
   assert_stats_valid = assert_stats_valid,
   clocks_except = clocks_except,
   load_luamark = load_luamark,
   make_result_row = make_result_row,
   make_stats = make_stats,
   noop = noop,
}
