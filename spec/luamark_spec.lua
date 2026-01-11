---@diagnostic disable: undefined-field, unused-local

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

local lua_require = require

--- @param clock_module string
--- @return table
local function try_require(clock_module)
   local module_installed, lib = pcall(lua_require, clock_module)
   assert(module_installed, string.format("Dependency '%s' is required for testing.", clock_module))
   return lib
end

local chronos = try_require("chronos")
local posix_time = try_require("posix.time")
local socket = try_require("socket")

local CLOCKS = { "chronos" }
if posix_time.clock_gettime then
   CLOCKS[#CLOCKS + 1] = "posix.time"
end

--- @param clock_module string
--- @return table
local function load_luamark(clock_module)
   package.loaded["luamark"] = nil
   for i = 1, #CLOCKS do
      package.loaded[CLOCKS[i]] = nil
   end

   local blocked = {}
   for i = 1, #CLOCKS do
      if CLOCKS[i] ~= clock_module then
         blocked[CLOCKS[i]] = true
      end
   end

   local original_require = _G.require
   _G.require = function(module_name)
      if blocked[module_name] then
         error(string.format("module '%s' not found", module_name))
      end
      return original_require(module_name)
   end

   local luamark = require("luamark")
   _G.require = original_require
   return luamark
end

local function noop() end

--- @param stats table
local function assert_stats_not_nil(stats)
   assert.is_not_nil(stats)
   for _, stat in pairs(stats) do
      assert.is_not_nil(stat)
   end
end

-- ----------------------------------------------------------------------------
-- Test parameters
-- ----------------------------------------------------------------------------

local SLEEP_TIME = 0.001
-- socket.sleep doesn't sleep the exact time
local TIME_TOL = SLEEP_TIME / 3
local MEMORY_TOL = 0.0005

-- ----------------------------------------------------------------------------
-- Tests per clock module
-- ----------------------------------------------------------------------------

for _, clock_name in ipairs(CLOCKS) do
   describe("clock = " .. clock_name .. " ->", function()
      local luamark

      setup(function()
         _G._TEST = true
         luamark = load_luamark(clock_name)
      end)

      teardown(function()
         _G._TEST = nil
      end)
      -- ----------------------------------------------------------------------------
      -- Base tests
      -- ----------------------------------------------------------------------------
      test("uses correct clock", function()
         assert.are_equal(clock_name, luamark.clock_name)
      end)

      describe("base", function()
         for name, benchmark in pairs({ timeit = luamark.timeit, memit = luamark.memit }) do
            local bench_suffix = string.format(" (%s)", name)

            -- ----------------------------------------------------------------------------
            -- test table stats
            -- ----------------------------------------------------------------------------

            test("single function " .. bench_suffix, function()
               local stats = benchmark(noop, { rounds = 1 })
               assert_stats_not_nil(stats)
            end)

            test("multiple functions " .. bench_suffix, function()
               local root_stats = benchmark({ a = noop, b = noop }, { rounds = 1 })

               assert.is_not_nil(root_stats.a)
               assert.is_not_nil(root_stats.b)
               local size = 0
               for _, stats in pairs(root_stats) do
                  size = size + 1
                  assert_stats_not_nil(stats)
               end
               assert.equal(size, 2)
            end)

            -- ----------------------------------------------------------------------------
            -- test stop condition
            -- ----------------------------------------------------------------------------

            local calls = 0

            local function counter()
               calls = calls + 1
               -- force 1 iteration per round
               socket.sleep(luamark.get_min_clocktime() * luamark.CALIBRATION_PRECISION)
            end

            local rounds = 3
            local stats = benchmark(counter, { rounds = rounds })

            test("count" .. bench_suffix, function()
               assert.are_equal(1, stats.iterations)
               assert.is_true(calls >= stats.count)
            end)

            test("rounds" .. bench_suffix, function()
               assert.are_equal(rounds, stats.rounds)
               assert.are_equal(stats.count, stats.rounds * stats.iterations)
            end)

            test("max_time" .. bench_suffix, function()
               local function sleep_250ms()
                  socket.sleep(0.25)
               end

               local expected_max_time = 0.5
               local actual_time = luamark.measure_time(function()
                  benchmark(sleep_250ms, { rounds = 1e9, max_time = expected_max_time })
               end, 1)
               -- Tolerance for calculating stats, garbage collection, etc.
               assert.is_near(expected_max_time, actual_time, 0.3)
            end)

            -- ----------------------------------------------------------------------------
            -- test setup/teardown
            -- ----------------------------------------------------------------------------

            test("setup / teardown" .. bench_suffix, function()
               local counter_calls, setup_calls, teardown_calls = 0, 0, 0

               local function counter()
                  counter_calls = counter_calls + 1
               end

               local function setup_counter()
                  setup_calls = setup_calls + 1
               end

               local function teardown_counter()
                  teardown_calls = teardown_calls + 1
               end

               local stats = benchmark(
                  counter,
                  { rounds = 1, setup = setup_counter, teardown = teardown_counter }
               )
               assert.is_true(setup_calls > 0)
               assert.is_equals(setup_calls, teardown_calls)
               assert.is_equals(teardown_calls, counter_calls)
            end)
         end
      end)

      -- ----------------------------------------------------------------------------
      -- timeit
      -- ----------------------------------------------------------------------------

      describe("timeit", function()
         local calls = 0
         local max_sleep_time = SLEEP_TIME * 2
         local function counter()
            calls = calls + 1
            local sleep_time = calls == 10 and max_sleep_time or SLEEP_TIME
            socket.sleep(sleep_time)
         end

         local rounds = 100

         local stats = luamark.timeit(counter, { rounds = rounds, max_time = 1 })

         test("min", function()
            assert.is_near(SLEEP_TIME, stats.min, TIME_TOL)
         end)

         test("max", function()
            assert.is_near(max_sleep_time, stats.max, TIME_TOL * 2)
         end)

         test("mean", function()
            assert.near(SLEEP_TIME, stats.mean, TIME_TOL)
         end)

         test("median", function()
            assert.near(SLEEP_TIME, stats.median, TIME_TOL)
         end)
      end)

      -- ----------------------------------------------------------------------------
      -- memit
      -- ----------------------------------------------------------------------------
      -- For unknown reasons, memory calls are not deterministic on 5.2 and 5.3

      local is_jit = type(jit) == "table"
      if _VERSION ~= "Lua 5.2" and _VERSION ~= "Lua 5.3" and not is_jit then
         describe("memit", function()
            local funcs = {
               noop = noop,
               empty_table = function()
                  local t = {}
                  t = nil
               end,
               complex = function()
                  local i = 1
                  local t = { 1, 2, 3 }
                  local s = "luamark"
                  t = nil
               end,
            }
            local all_stats = luamark.memit(funcs, { rounds = 100 })

            for func_name, stats in pairs(all_stats) do
               local single_call_memory = luamark.measure_memory(funcs[func_name], 1)

               test("mean: " .. func_name, function()
                  assert.near(single_call_memory, stats.mean, MEMORY_TOL)
               end)

               test("median: " .. func_name, function()
                  assert.near(single_call_memory, stats.median, MEMORY_TOL)
               end)
            end
         end)
      end
   end)
end

-- ----------------------------------------------------------------------------
-- Test Errors
-- ----------------------------------------------------------------------------

describe("error", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   describe("validation", function()
      for name, benchmark in pairs({ timeit = luamark.timeit, memit = luamark.memit }) do
         local bench_suffix = string.format(" (%s)", name)

         test("rounds " .. bench_suffix, function()
            assert.has.errors(function()
               benchmark(function() end, { rounds = -1 })
            end)
         end)

         test("max_time" .. bench_suffix, function()
            assert.has.errors(function()
               benchmark(function() end, { max_time = -1 })
            end)
         end)

         test("unknown option " .. bench_suffix, function()
            assert.has.errors(function()
               benchmark(function() end, { hello = "world" })
            end)
         end)

         test("function " .. bench_suffix, function()
            assert.has.errors(function()
               ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
               benchmark(nil)
            end)
         end)
      end
   end)
end)

-- ----------------------------------------------------------------------------
-- Test Rank
-- ----------------------------------------------------------------------------

describe("rank", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   test("unique values", function()
      local data = {
         ["test1"] = { mean = 8 },
         ["test2"] = { mean = 20 },
         ["test3"] = { mean = 5 },
         ["test4"] = { mean = 12 },
      }
      luamark.rank(data, "mean")
      assert.are.same({ rank = 1, mean = 5, ratio = 1 }, data["test3"])
      assert.are.same({ rank = 2, mean = 8, ratio = 1.6 }, data["test1"])
      assert.are.same({ rank = 3, mean = 12, ratio = 2.4 }, data["test4"])
      assert.are.same({ rank = 4, mean = 20, ratio = 4 }, data["test2"])
   end)

   test("identical values", function()
      local data = {
         ["test1"] = { mean = 10 },
         ["test2"] = { mean = 10 },
         ["test3"] = { mean = 10 },
      }
      luamark.rank(data, "mean")

      assert.are.equal(1, data["test1"].rank)
      assert.are.equal(1, data["test2"].rank)
      assert.are.equal(1, data["test3"].rank)

      assert.are.equal(1.0, data["test1"].ratio)
      assert.are.equal(1.0, data["test2"].ratio)
      assert.are.equal(1.0, data["test3"].ratio)
   end)

   test("keys", function()
      local data = {
         ["test1"] = { mean = 10, median = 18 },
         ["test2"] = { mean = 20, median = 8 },
      }
      luamark.rank(data, "mean")
      assert.are.same({ rank = 1, mean = 10, median = 18, ratio = 1 }, data["test1"])
      assert.are.same({ rank = 2, mean = 20, median = 8, ratio = 2 }, data["test2"])

      luamark.rank(data, "median")
      assert.are.same({ rank = 1, mean = 20, median = 8, ratio = 1.0 }, data["test2"])
      assert.are.same({ rank = 2, mean = 10, median = 18, ratio = 2.25 }, data["test1"])
   end)

   test("empty table error", function()
      assert.has.error(function()
         luamark.rank({}, "foo")
      end, "'benchmark_results' is nil or empty.")
   end)

   test("nil error", function()
      assert.has.error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         luamark.rank(nil, "bar")
      end, "'benchmark_results' is nil or empty.")
   end)
end)

describe("summarize", function()
   local luamark

   setup(function()
      _G._TEST = true
      luamark = require("luamark")
   end)

   test("empty table error", function()
      assert.has.error(function()
         luamark.summarize({})
      end, "'benchmark_results' is nil or empty.")
   end)

   test("nil error", function()
      assert.has.error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         luamark.summarize(nil)
      end, "'benchmark_results' is nil or empty.")
   end)

   test("invalid format error", function()
      assert.has.error(function()
         luamark.summarize({ test = { median = 1 } }, "invalid")
      end, "format must be 'plain' or 'markdown'")
   end)
end)

describe("format_stat", function()
   local luamark

   setup(function()
      _G._TEST = true
      luamark = require("luamark")
   end)

   test("converts kilobytes to terabytes", function()
      local tb, gb = 1024 ^ 3, 1024 ^ 2
      assert.are.equal("1.5TB", luamark.format_stat(tb + 512 * gb, "kb"))
   end)

   test("convert s to ns", function()
      assert.are.equal("5ns", luamark.format_stat(5 / 1e9, "s"))
   end)

   test("round < 1ns", function()
      assert.are.equal("0ns", luamark.format_stat(0.5 / 1e9, "s"))
   end)

   test("round < 1B", function()
      assert.are.equal("0B", luamark.format_stat(0.25 / 1024, "kb"))
   end)
end)

-- ----------------------------------------------------------------------------
-- Test Config
-- ----------------------------------------------------------------------------

describe("config", function()
   local luamark

   setup(function()
      _G._TEST = true
      luamark = require("luamark")
   end)

   test("accepts valid config option", function()
      for _, opt in ipairs({ "max_iterations", "min_rounds", "max_rounds", "warmups" }) do
         luamark[opt] = 1
      end
   end)

   test("rejects invalid config option", function()
      assert.has.errors(function()
         luamark.foo = 1
      end, "Invalid config option: foo")
   end)
end)
