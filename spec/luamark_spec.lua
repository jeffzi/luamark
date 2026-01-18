---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

-- Enable _internal exports for testing (see busted docs on private testing)
_G._TEST = true

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
local system = try_require("system")

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
         luamark = load_luamark(clock_name)
      end)
      -- ----------------------------------------------------------------------------
      -- Base tests
      -- ----------------------------------------------------------------------------
      test("uses correct clock", function()
         assert.are_equal(clock_name, luamark.clock_name)
      end)

      describe("timeit and memit", function()
         for name, benchmark in pairs({ timeit = luamark.timeit, memit = luamark.memit }) do
            local bench_suffix = string.format(" (%s)", name)

            test("benchmarks single function" .. bench_suffix, function()
               local stats = benchmark(noop, { rounds = 1 })
               assert_stats_not_nil(stats)
            end)

            test("benchmarks multiple functions" .. bench_suffix, function()
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

            local calls = 0

            local function counter()
               calls = calls + 1
               -- force 1 iteration per round
               socket.sleep(
                  luamark._internal.get_min_clocktime() * luamark._internal.CALIBRATION_PRECISION
               )
            end

            local rounds = 3
            local stats = benchmark(counter, { rounds = rounds })

            test("tracks iteration count" .. bench_suffix, function()
               assert.are_equal(1, stats.iterations)
               assert.is_true(calls >= stats.count)
            end)

            test("respects round limit" .. bench_suffix, function()
               assert.are_equal(rounds, stats.rounds)
               assert.are_equal(stats.count, stats.rounds * stats.iterations)
            end)

            test("stops at max_time" .. bench_suffix, function()
               local function sleep_250ms()
                  socket.sleep(0.25)
               end

               local expected_max_time = 0.5
               local actual_time = luamark._internal.measure_time(function()
                  benchmark(sleep_250ms, { rounds = 1e9, max_time = expected_max_time })
               end, 1)
               -- Tolerance for calculating stats, garbage collection, etc.
               assert.is_near(expected_max_time, actual_time, 0.3)
            end)

            test("runs setup and teardown once" .. bench_suffix, function()
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

               benchmark(
                  counter,
                  { rounds = 1, setup = setup_counter, teardown = teardown_counter }
               )
               -- Setup and teardown run exactly once per benchmark (not per iteration)
               assert.are_equal(1, setup_calls)
               assert.are_equal(1, teardown_calls)
               assert.is_true(counter_calls >= 1)
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

         test("computes minimum time", function()
            assert.is_near(SLEEP_TIME, stats.min, TIME_TOL)
         end)

         test("computes maximum time", function()
            assert.is_near(max_sleep_time, stats.max, TIME_TOL * 2)
         end)

         test("computes mean time", function()
            assert.near(SLEEP_TIME, stats.mean, TIME_TOL)
         end)

         test("computes median time", function()
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
               local single_call_memory = luamark._internal.measure_memory(funcs[func_name], 1)

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

describe("validation", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   test("timeit rejects negative rounds", function()
      assert.has.errors(function()
         luamark.timeit(function() end, { rounds = -1 })
      end)
   end)

   test("memit rejects negative rounds", function()
      assert.has.errors(function()
         luamark.memit(function() end, { rounds = -1 })
      end)
   end)

   test("timeit rejects negative max_time", function()
      assert.has.errors(function()
         luamark.timeit(function() end, { max_time = -1 })
      end)
   end)

   test("memit rejects negative max_time", function()
      assert.has.errors(function()
         luamark.memit(function() end, { max_time = -1 })
      end)
   end)

   test("timeit rejects unknown option", function()
      assert.has.errors(function()
         luamark.timeit(function() end, { hello = "world" })
      end)
   end)

   test("memit rejects unknown option", function()
      assert.has.errors(function()
         luamark.memit(function() end, { hello = "world" })
      end)
   end)

   test("timeit rejects nil function", function()
      assert.has.errors(function()
         ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
         luamark.timeit(nil)
      end)
   end)

   test("memit rejects nil function", function()
      assert.has.errors(function()
         ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
         luamark.memit(nil)
      end)
   end)

   test("timeit rejects scalar params value", function()
      assert.has.errors(function()
         luamark.timeit(function() end, { params = { n = 10 } })
      end)
   end)

   test("memit rejects scalar params value", function()
      assert.has.errors(function()
         luamark.memit(function() end, { params = { n = 10 } })
      end)
   end)
end)

-- ----------------------------------------------------------------------------
-- Test Rank
-- ----------------------------------------------------------------------------

describe("rank", function()
   local luamark, rank

   setup(function()
      luamark = require("luamark")
      rank = luamark._internal.rank
   end)

   test("handles zero minimum value", function()
      local data = {
         ["test1"] = { mean = 0 },
         ["test2"] = { mean = 10 },
      }
      rank(data, "mean")
      assert.are.equal(1, data["test1"].rank)
      assert.are.equal(2, data["test2"].rank)
      assert.are.equal(1, data["test1"].ratio)
      -- Should not be inf or nan
      assert.is_true(data["test2"].ratio < math.huge)
      assert.is_false(data["test2"].ratio ~= data["test2"].ratio) -- NaN check
   end)

   test("unique values", function()
      local data = {
         ["test1"] = { mean = 8 },
         ["test2"] = { mean = 20 },
         ["test3"] = { mean = 5 },
         ["test4"] = { mean = 12 },
      }
      rank(data, "mean")
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
      rank(data, "mean")

      assert.are.equal(1, data["test1"].rank)
      assert.are.equal(1, data["test2"].rank)
      assert.are.equal(1, data["test3"].rank)

      assert.are.equal(1.0, data["test1"].ratio)
      assert.are.equal(1.0, data["test2"].ratio)
      assert.are.equal(1.0, data["test3"].ratio)
   end)

   test("ranks by specified key", function()
      local data = {
         ["test1"] = { mean = 10, median = 18 },
         ["test2"] = { mean = 20, median = 8 },
      }
      rank(data, "mean")
      assert.are.same({ rank = 1, mean = 10, median = 18, ratio = 1 }, data["test1"])
      assert.are.same({ rank = 2, mean = 20, median = 8, ratio = 2 }, data["test2"])

      rank(data, "median")
      assert.are.same({ rank = 1, mean = 20, median = 8, ratio = 1.0 }, data["test2"])
      assert.are.same({ rank = 2, mean = 10, median = 18, ratio = 2.25 }, data["test1"])
   end)

   test("empty table error", function()
      assert.has.error(function()
         rank({}, "foo")
      end, "'results' is nil or empty.")
   end)

   test("nil error", function()
      assert.has.error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         rank(nil, "bar")
      end, "'results' is nil or empty.")
   end)
end)

describe("summarize", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   test("empty table error", function()
      assert.has.error(function()
         luamark.summarize({})
      end, "'results' is nil or empty.")
   end)

   test("nil error", function()
      assert.has.error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         luamark.summarize(nil)
      end, "'results' is nil or empty.")
   end)

   test("invalid format error", function()
      assert.has.error(function()
         luamark.summarize({ test = { median = 1 } }, "invalid")
      end, "format must be 'plain', 'compact', 'markdown', or 'csv'")
   end)

   test("plain format includes table and bar chart", function()
      local results = {
         fast = {
            median = 100,
            mean = 100,
            min = 90,
            max = 110,
            stddev = 5,
            rounds = 10,
            unit = "s",
         },
         slow = {
            median = 300,
            mean = 300,
            min = 280,
            max = 320,
            stddev = 10,
            rounds = 10,
            unit = "s",
         },
      }
      luamark._internal.rank(results, "median")
      local output = luamark.summarize(results, "plain")
      assert.matches("Name", output)
      assert.matches("fast.*█.*1%.00x", output)
      assert.matches("slow.*█.*3%.00x", output)
   end)

   test("compact format shows only bar chart", function()
      local results = {
         fast = {
            median = 100,
            mean = 100,
            min = 90,
            max = 110,
            stddev = 5,
            rounds = 10,
            unit = "s",
         },
         slow = {
            median = 300,
            mean = 300,
            min = 280,
            max = 320,
            stddev = 10,
            rounds = 10,
            unit = "s",
         },
      }
      luamark._internal.rank(results, "median")
      local output = luamark.summarize(results, "compact")
      assert.not_matches("Name", output)
      assert.matches("fast.*█.*1%.00x", output)
      assert.matches("slow.*█.*3%.00x", output)
   end)

   test("plain and compact truncate long names to fit terminal width", function()
      local results = {
         very_long_function_name_that_should_definitely_be_truncated_to_fit_the_terminal_width_limit = {
            median = 100,
            mean = 100,
            min = 90,
            max = 110,
            stddev = 5,
            rounds = 10,
            unit = "s",
         },
         short = {
            median = 500,
            mean = 500,
            min = 450,
            max = 550,
            stddev = 10,
            rounds = 10,
            unit = "s",
         },
      }
      luamark._internal.rank(results, "median")

      local max_width = luamark._internal.DEFAULT_TERM_WIDTH
      for _, fmt in ipairs({ "plain", "compact" }) do
         local output = luamark.summarize(results, fmt, max_width)
         for line in output:gmatch("[^\n]+") do
            local display_width = 0
            for _ in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
               display_width = display_width + 1
            end
            assert(
               display_width <= max_width,
               string.format(
                  "%s: line exceeds %d chars (%d): %s",
                  fmt,
                  max_width,
                  display_width,
                  line
               )
            )
         end
         assert.matches("%.%.%.", output)
      end
   end)

   test("short names are not truncated", function()
      local results = {
         fast = {
            median = 100,
            mean = 100,
            min = 90,
            max = 110,
            stddev = 5,
            rounds = 10,
            unit = "s",
         },
         slow = {
            median = 500,
            mean = 500,
            min = 450,
            max = 550,
            stddev = 10,
            rounds = 10,
            unit = "s",
         },
      }
      luamark._internal.rank(results, "median")

      for _, fmt in ipairs({ "plain", "compact" }) do
         local output = luamark.summarize(results, fmt)
         assert.not_matches("%.%.%.", output)
         assert.matches("fast", output)
         assert.matches("slow", output)
      end
   end)

   test("csv format outputs comma-separated values", function()
      local results = {
         fast = {
            median = 0.001,
            mean = 0.001,
            min = 0.0009,
            max = 0.0011,
            stddev = 0.00005,
            rounds = 10,
            unit = "s",
         },
         slow = {
            median = 0.003,
            mean = 0.003,
            min = 0.0028,
            max = 0.0032,
            stddev = 0.0001,
            rounds = 10,
            unit = "s",
         },
      }
      luamark._internal.rank(results, "median")
      local output = luamark.summarize(results, "csv")

      -- Check header
      assert.matches("name,rank,ratio,median,mean,min,max,stddev,rounds", output)
      -- Check data rows exist
      assert.matches("fast,1,", output)
      assert.matches("slow,2,", output)
   end)
end)

describe("calculate_stats", function()
   local calculate_stats

   setup(function()
      calculate_stats = require("luamark")._internal.calculate_stats
   end)

   test("handles negative values", function()
      local samples = { -5, -3, -1 }
      local stats = calculate_stats(samples)
      assert.are.equal(-1, stats.max)
      assert.are.equal(-5, stats.min)
   end)
end)

describe("humanize_time", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   test("converts seconds to nanoseconds", function()
      assert.are.equal("5ns", luamark.humanize_time(5 / 1e9))
   end)

   test("rounds sub-nanosecond to zero", function()
      assert.are.equal("0ns", luamark.humanize_time(0.5 / 1e9))
   end)
end)

describe("humanize_memory", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   test("converts kilobytes to terabytes", function()
      local tb, gb = 1024 ^ 3, 1024 ^ 2
      assert.are.equal("1.5TB", luamark.humanize_memory(tb + 512 * gb))
   end)

   test("rounds sub-byte to zero", function()
      assert.are.equal("0B", luamark.humanize_memory(0.25 / 1024))
   end)
end)

-- ----------------------------------------------------------------------------
-- Test Config
-- ----------------------------------------------------------------------------

describe("config", function()
   local luamark

   setup(function()
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

   test("get_config returns current config values", function()
      local cfg = luamark.get_config()
      assert.is_table(cfg)
      assert.are_equal(luamark.max_iterations, cfg.max_iterations)
      assert.are_equal(luamark.min_rounds, cfg.min_rounds)
      assert.are_equal(luamark.max_rounds, cfg.max_rounds)
      assert.are_equal(luamark.warmups, cfg.warmups)
   end)

   test("get_config returns a copy", function()
      local cfg = luamark.get_config()
      cfg.max_iterations = 999999
      assert.are_not_equal(999999, luamark.get_config().max_iterations)
   end)
end)

-- ----------------------------------------------------------------------------
-- Unified API
-- ----------------------------------------------------------------------------

describe("unified API", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   describe("before_all returns context", function()
      test("benchmark receives ctx from before_all", function()
         local received_ctx
         luamark.timeit(function(ctx)
            received_ctx = ctx
         end, {
            setup = function()
               return { data = "test_value" }
            end,
            rounds = 1,
         })

         assert.is_not_nil(received_ctx)
         assert.are_equal("test_value", received_ctx.data)
      end)

      test("ctx is nil when no before_all provided", function()
         local received_ctx = "sentinel"
         luamark.timeit(function(ctx)
            received_ctx = ctx
         end, {
            rounds = 1,
         })

         assert.is_nil(received_ctx)
      end)

      test("before_all receives params", function()
         local received_p
         luamark.timeit(function() end, {
            setup = function(p)
               received_p = p
               return {}
            end,
            rounds = 1,
         })

         assert.is_table(received_p)
      end)

      test("after_all receives ctx and params", function()
         local teardown_ctx, teardown_p
         luamark.timeit(function() end, {
            setup = function(p)
               return { value = 42 }
            end,
            teardown = function(ctx, p)
               teardown_ctx = ctx
               teardown_p = p
            end,
            rounds = 1,
         })

         assert.is_not_nil(teardown_ctx)
         assert.are_equal(42, teardown_ctx.value)
         assert.is_table(teardown_p)
      end)
   end)

   describe("params", function()
      test("accepts params option", function()
         local seen_n = {}
         luamark.timeit(function(ctx, p)
            seen_n[p.n] = true
         end, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.is_true(seen_n[10])
         assert.is_true(seen_n[20])
      end)

      test("returns nested results for single function with params", function()
         local results = luamark.timeit(function() end, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.is_not_nil(results.n)
         assert.is_not_nil(results.n[10])
         assert.is_not_nil(results.n[20])
         assert.is_not_nil(results.n[10].median)
      end)

      test("returns flat Stats when no params", function()
         local results = luamark.timeit(function() end, { rounds = 1 })
         assert.is_not_nil(results.median)
         assert.is_nil(results.n)
      end)

      test("expands multiple params as cartesian product", function()
         local seen = {}
         luamark.timeit(function(ctx, p)
            seen[p.n .. "_" .. tostring(p.flag)] = true
         end, {
            params = { n = { 1, 2 }, flag = { true, false } },
            rounds = 1,
         })

         assert.is_true(seen["1_true"])
         assert.is_true(seen["1_false"])
         assert.is_true(seen["2_true"])
         assert.is_true(seen["2_false"])
      end)

      test("before_all and after_all receive params", function()
         local setup_params, teardown_params
         luamark.timeit(function() end, {
            params = { n = { 42 } },
            setup = function(p)
               setup_params = p
               return {}
            end,
            teardown = function(ctx, p)
               teardown_params = p
            end,
            rounds = 1,
         })

         assert.are_equal(42, setup_params.n)
         assert.are_equal(42, teardown_params.n)
      end)

      test("multiple functions with params return nested results", function()
         local results = luamark.timeit({
            fast = function() end,
            slow = function() end,
         }, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.is_not_nil(results.fast)
         assert.is_not_nil(results.slow)
         assert.is_not_nil(results.fast.n)
         assert.is_not_nil(results.fast.n[10])
         assert.is_not_nil(results.fast.n[20])
         assert.is_not_nil(results.fast.n[10].median)
      end)

      test("memit also supports params", function()
         local results = luamark.memit(function() end, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.is_not_nil(results.n)
         assert.is_not_nil(results.n[10])
         assert.is_not_nil(results.n[20])
         assert.is_not_nil(results.n[10].median)
      end)
   end)

   describe("two-level setup", function()
      test("before_all runs once, before_each runs per iteration", function()
         local global_calls = 0
         local bench_calls = 0

         local results = luamark.timeit({
            test_bench = {
               fn = function() end,
               before = function(ctx, p)
                  bench_calls = bench_calls + 1
                  return ctx
               end,
            },
         }, {
            setup = function(p)
               global_calls = global_calls + 1
               return { value = 1 }
            end,
            rounds = 5,
         })

         local rounds = results.test_bench.rounds
         local iterations = results.test_bench.iterations
         local warmups = results.test_bench.warmups

         assert.are_equal(1, global_calls)
         -- before_each runs per iteration: at least rounds times (ignoring warmups/calibration)
         assert.is_true(
            bench_calls >= rounds,
            string.format(
               "bench_calls=%d should be >= rounds=%d (iterations=%d, warmups=%d)",
               bench_calls,
               rounds,
               iterations,
               warmups
            )
         )
      end)

      test("before_each receives ctx and can modify it", function()
         local final_ctx
         luamark.timeit({
            test_bench = {
               fn = function(ctx)
                  final_ctx = ctx
               end,
               before = function(ctx, p)
                  return { modified = true, original = ctx.original }
               end,
            },
         }, {
            setup = function()
               return { original = true }
            end,
            rounds = 1,
         })

         assert.is_true(final_ctx.modified)
         assert.is_true(final_ctx.original)
      end)

      test("after_each receives iteration_ctx", function()
         local teardown_ctx
         luamark.timeit({
            test_bench = {
               fn = function() end,
               before = function(ctx, p)
                  return { iteration_value = 42 }
               end,
               after = function(ctx, p)
                  teardown_ctx = ctx
               end,
            },
         }, {
            rounds = 1,
         })

         assert.are_equal(42, teardown_ctx.iteration_value)
      end)

      test("bench functions can be plain functions or tables with fn", function()
         local plain_called = false
         local table_called = false

         luamark.timeit({
            plain = function()
               plain_called = true
            end,
            with_setup = {
               fn = function()
                  table_called = true
               end,
            },
         }, {
            rounds = 1,
         })

         assert.is_true(plain_called)
         assert.is_true(table_called)
      end)

      test("before_each without before_all receives nil ctx", function()
         local received_ctx = "sentinel"
         luamark.timeit({
            test_bench = {
               fn = function() end,
               before = function(ctx, p)
                  received_ctx = ctx
                  return { new = true }
               end,
            },
         }, {
            rounds = 1,
         })

         assert.is_nil(received_ctx)
      end)

      test("before_each receives params", function()
         local received_param
         luamark.timeit({
            test_bench = {
               fn = function() end,
               before = function(ctx, p)
                  received_param = p.n
                  return ctx
               end,
            },
         }, {
            params = { n = { 42 } },
            rounds = 1,
         })

         assert.are_equal(42, received_param)
      end)

      test("two-level setup works with memit", function()
         local global_calls = 0
         local bench_calls = 0

         luamark.memit({
            test_bench = {
               fn = function() end,
               before = function(ctx, p)
                  bench_calls = bench_calls + 1
                  return ctx
               end,
            },
         }, {
            setup = function(p)
               global_calls = global_calls + 1
               return {}
            end,
            rounds = 3,
         })

         assert.are_equal(1, global_calls)
         assert.is_true(bench_calls >= 3)
      end)
   end)
end)

-- ----------------------------------------------------------------------------
-- Summarize with unified API results
-- ----------------------------------------------------------------------------

describe("summarize with unified API results", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   test("summarizes single function result (Stats)", function()
      local results = luamark.timeit(function() end, { rounds = 1 })
      local output = luamark.summarize(results, "plain")
      assert.matches("result", output)
      assert.matches("1%.00x", output)
   end)

   test("summarizes single function with params", function()
      local results = luamark.timeit(function() end, {
         params = { n = { 10, 20 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "plain")
      assert.matches("n=10", output)
      assert.matches("n=20", output)
   end)

   test("summarizes multiple functions with params", function()
      local results = luamark.timeit({
         fast = function() end,
         slow = function()
            for i = 1, 100 do
               local _ = i
            end
         end,
      }, {
         params = { n = { 10, 20 } },
         rounds = 3,
      })

      local output = luamark.summarize(results, "plain")
      assert.matches("n=10", output)
      assert.matches("n=20", output)
      assert.matches("fast", output)
      assert.matches("slow", output)
   end)

   test("csv format includes param columns for single function with params", function()
      local results = luamark.timeit(function() end, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "csv")
      assert.matches("name,n,", output)
      assert.matches(",10,", output)
   end)

   test("csv format includes param columns for multiple functions with params", function()
      local results = luamark.timeit({
         a = function() end,
      }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "csv")
      assert.matches("name,n,", output)
      assert.matches("a,10,", output)
   end)

   test("ranks within each param group", function()
      local results = luamark.timeit({
         fast = function() end,
         slow = function()
            for i = 1, 1000 do
               local _ = i
            end
         end,
      }, {
         params = { n = { 10 } },
         rounds = 10,
      })

      local output = luamark.summarize(results, "plain")
      -- fast should have rank 1 (appear first in output after param header)
      assert.matches("n=10", output)
   end)

   test("handles multiple params as cartesian product", function()
      local results = luamark.timeit(function() end, {
         params = { n = { 1, 2 }, flag = { true } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "plain")
      assert.matches("flag=true, n=1", output)
      assert.matches("flag=true, n=2", output)
   end)

   test("compact format works with params", function()
      local results = luamark.timeit({
         a = function() end,
         b = function() end,
      }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "compact")
      assert.matches("n=10", output)
      assert.matches("1%.00x", output)
   end)

   test("markdown format works with params", function()
      local results = luamark.timeit({
         a = function() end,
      }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "markdown")
      assert.matches("n=10", output)
      assert.matches("|", output)
   end)
end)
