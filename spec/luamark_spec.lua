---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

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

---@param stats table
local function assert_stats_not_nil(stats)
   assert.is_not_nil(stats)
   for _, stat in pairs(stats) do
      assert.is_not_nil(stat)
   end
end

--- Factory function to create stats tables with sensible defaults.
---@param overrides? table Optional fields to override defaults
---@return table
local function make_stats(overrides)
   local stats = {
      median = 100,
      mean = 100,
      min = 90,
      max = 110,
      stddev = 5,
      rounds = 10,
      unit = "s",
   }
   if overrides then
      for k, v in pairs(overrides) do
         stats[k] = v
      end
   end
   return stats
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

            test("runs setup and teardown" .. bench_suffix, function()
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
               assert.are_equal(setup_calls, teardown_calls)
               assert.are_equal(teardown_calls, counter_calls)
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
      assert.are_equal(1, data["test1"].rank)
      assert.are_equal(2, data["test2"].rank)
      assert.are_equal(1, data["test1"].ratio)
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

      assert.are_equal(1, data["test1"].rank)
      assert.are_equal(1, data["test2"].rank)
      assert.are_equal(1, data["test3"].rank)

      assert.are_equal(1.0, data["test1"].ratio)
      assert.are_equal(1.0, data["test2"].ratio)
      assert.are_equal(1.0, data["test3"].ratio)
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
      end, "'benchmark_results' is nil or empty.")
   end)

   test("nil error", function()
      assert.has.error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         rank(nil, "bar")
      end, "'benchmark_results' is nil or empty.")
   end)
end)

describe("tostring on stats", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   test("single function stats tostring includes mean and stddev", function()
      local stats = luamark.timeit(function() end, { rounds = 3 })
      local str = tostring(stats)
      assert.matches("per round", str)
      assert.matches("%d+ rounds", str)
   end)

   test("multiple function stats tostring produces summary", function()
      local stats = luamark.timeit({ a = function() end, b = function() end }, { rounds = 3 })
      local str = tostring(stats)
      assert.matches("Name", str)
      assert.matches("Rank", str)
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

   test("markdown format outputs pipe-delimited table", function()
      local results = {
         fast = make_stats(),
         slow = make_stats({ median = 300, mean = 300, min = 280, max = 320, stddev = 10 }),
      }
      luamark._internal.rank(results, "median")
      local output = luamark.summarize(results, "markdown")
      assert.matches("^|", output)
      assert.matches("| Name |", output)
      assert.matches("| fast |", output)
      assert.matches("| slow |", output)
      assert.not_matches("%.%.%.", output) -- No bar chart
   end)

   test("suite markdown format outputs pipe-delimited table", function()
      local results = luamark.suite_timeit({
         add = {
            fast = function() end,
            slow = function() end,
            opts = {
               params = { n = { 100 } },
               rounds = 3,
            },
         },
      })

      local output = luamark.summarize(results, "markdown")
      assert.matches("^add %(n=100%)", output)
      assert.matches("| Name |", output)
      assert.matches("| fast |", output)
      assert.matches("| slow |", output)
   end)

   test("suite compact format shows only bar chart", function()
      local results = luamark.suite_timeit({
         add = {
            fast = function() end,
            slow = function() end,
            opts = {
               params = { n = { 100 } },
               rounds = 3,
            },
         },
      })

      local output = luamark.summarize(results, "compact")
      assert.not_matches("| Name |", output)
      assert.matches("|", output)
      assert.matches("x", output)
   end)

   test("plain format includes table and bar chart", function()
      local results = {
         fast = make_stats(),
         slow = make_stats({ median = 300, mean = 300, min = 280, max = 320, stddev = 10 }),
      }
      luamark._internal.rank(results, "median")
      local output = luamark.summarize(results, "plain")
      assert.matches("Name", output)
      assert.matches("fast.*|.*1%.00x", output)
      assert.matches("slow.*|.*3%.00x", output)
   end)

   test("compact format shows only bar chart", function()
      local results = {
         fast = make_stats(),
         slow = make_stats({ median = 300, mean = 300, min = 280, max = 320, stddev = 10 }),
      }
      luamark._internal.rank(results, "median")
      local output = luamark.summarize(results, "compact")
      assert.not_matches("Name", output)
      assert.matches("fast.*|.*1%.00x", output)
      assert.matches("slow.*|.*3%.00x", output)
   end)

   test("plain and compact truncate long names to fit terminal width", function()
      local results = {
         very_long_function_name_that_should_definitely_be_truncated_to_fit_the_terminal_width_limit = make_stats(),
         short = make_stats({ median = 500, mean = 500, min = 450, max = 550, stddev = 10 }),
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
         fast = make_stats(),
         slow = make_stats({ median = 500, mean = 500, min = 450, max = 550, stddev = 10 }),
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
         fast = make_stats({
            median = 0.001,
            mean = 0.001,
            min = 0.0009,
            max = 0.0011,
            stddev = 0.00005,
         }),
         slow = make_stats({
            median = 0.003,
            mean = 0.003,
            min = 0.0028,
            max = 0.0032,
            stddev = 0.0001,
         }),
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
      assert.are_equal(-1, stats.max)
      assert.are_equal(-5, stats.min)
   end)
end)

describe("format_stat", function()
   local format_stat

   setup(function()
      format_stat = require("luamark")._internal.format_stat
   end)

   test("converts kilobytes to terabytes", function()
      local tb, gb = 1024 ^ 3, 1024 ^ 2
      assert.are_equal("1.5TB", format_stat(tb + 512 * gb, "kb"))
   end)

   test("converts seconds to nanoseconds", function()
      assert.are_equal("5ns", format_stat(5 / 1e9, "s"))
   end)

   test("rounds sub-nanosecond to zero", function()
      assert.are_equal("0ns", format_stat(0.5 / 1e9, "s"))
   end)

   test("rounds sub-byte to zero", function()
      assert.are_equal("0B", format_stat(0.25 / 1024, "kb"))
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
end)

-- ----------------------------------------------------------------------------
-- Test Suite
-- ----------------------------------------------------------------------------

describe("suite", function()
   local luamark

   setup(function()
      luamark = require("luamark")
   end)

   describe("input parsing", function()
      test("parses simple function benchmarks", function()
         local parsed = luamark._internal.parse_suite({
            add = {
               impl_a = function() end,
               impl_b = function() end,
            },
         })

         assert.is_not_nil(parsed.add)
         assert.is_not_nil(parsed.add.impl_a)
         assert.is_not_nil(parsed.add.impl_b)
         assert.is_function(parsed.add.impl_a.fn)
         assert.is_function(parsed.add.impl_b.fn)
      end)

      test("parses benchmark with config", function()
         local setup_fn = function() end
         local teardown_fn = function() end
         local run_fn = function() end

         local parsed = luamark._internal.parse_suite({
            add = {
               impl_a = { fn = run_fn, setup = setup_fn, teardown = teardown_fn },
            },
         })

         assert.are_equal(run_fn, parsed.add.impl_a.fn)
         assert.are_equal(setup_fn, parsed.add.impl_a.setup)
         assert.are_equal(teardown_fn, parsed.add.impl_a.teardown)
      end)

      test("parses opts separately from benchmarks", function()
         local global_setup = function() end

         local parsed = luamark._internal.parse_suite({
            add = {
               impl_a = function() end,
               opts = {
                  setup = global_setup,
                  params = { n = { 100, 1000 } },
               },
            },
         })

         assert.is_nil(parsed.add.opts.fn) -- opts is not a benchmark (no fn field)
         assert.are_equal(global_setup, parsed.add.opts.setup)
         assert.are.same({ n = { 100, 1000 } }, parsed.add.opts.params)
      end)
   end)

   describe("param key", function()
      test("builds nested structure for single param", function()
         local result = {}
         luamark._internal.set_nested(result, { n = 100 }, "stats")

         assert.are_equal("stats", result.n[100])
      end)

      test("builds nested structure for multiple params", function()
         local result = {}
         luamark._internal.set_nested(result, { m = 10, n = 100 }, "stats")

         assert.are_equal("stats", result.m[10].n[100])
      end)

      test("returns false for empty params", function()
         local result = {}
         local stored = luamark._internal.set_nested(result, {}, "stats")

         assert.is_false(stored)
         assert.is_nil(next(result))
      end)
   end)

   describe("parameter expansion", function()
      test("expands single parameter", function()
         local combos = luamark._internal.expand_params({ n = { 100, 1000 } })

         assert.are_equal(2, #combos)
         assert.are.same({ n = 100 }, combos[1])
         assert.are.same({ n = 1000 }, combos[2])
      end)

      test("expands multiple parameters as cartesian product", function()
         local combos = luamark._internal.expand_params({
            n = { 10, 20 },
            m = { 1, 2 },
         })

         assert.are_equal(4, #combos)
         -- Sorted by param name (m before n), then value
         assert.are.same({ m = 1, n = 10 }, combos[1])
         assert.are.same({ m = 1, n = 20 }, combos[2])
         assert.are.same({ m = 2, n = 10 }, combos[3])
         assert.are.same({ m = 2, n = 20 }, combos[4])
      end)

      test("returns single empty combo when no params", function()
         local combos = luamark._internal.expand_params({})
         assert.are_equal(1, #combos)
         assert.are.same({}, combos[1])
      end)
   end)

   describe("runner", function()
      test("runs single group with single benchmark", function()
         local call_count = 0
         local results = luamark.suite_timeit({
            add = {
               impl_a = function()
                  call_count = call_count + 1
               end,
               opts = { rounds = 1 },
            },
         })

         assert.is_true(call_count > 0)
         assert.is_not_nil(results.add)
         assert.is_not_nil(results.add.impl_a)
         assert.is_not_nil(results.add.impl_a.median)
      end)

      test("runs with parameters", function()
         local seen_params = {}
         local results = luamark.suite_timeit({
            add = {
               impl_a = {
                  fn = function() end,
                  setup = function(p)
                     seen_params[p.n] = true
                  end,
               },
               opts = {
                  params = { n = { 100, 200 } },
                  rounds = 1,
               },
            },
         })

         assert.is_true(seen_params[100])
         assert.is_true(seen_params[200])
         assert.is_not_nil(results.add.impl_a.n[100])
         assert.is_not_nil(results.add.impl_a.n[200])
      end)

      test("runs shared setup before benchmark setup", function()
         local order = {}
         local results = luamark.suite_timeit({
            add = {
               impl_a = {
                  fn = function() end,
                  setup = function()
                     order[#order + 1] = "impl"
                  end,
               },
               opts = {
                  setup = function()
                     order[#order + 1] = "shared"
                  end,
                  rounds = 1,
               },
            },
         })

         assert.are_equal("shared", order[1])
         assert.are_equal("impl", order[2])
      end)

      test("setup receives params", function()
         local received_n
         local results = luamark.suite_timeit({
            add = {
               impl_a = function() end,
               opts = {
                  setup = function(p)
                     received_n = p.n
                  end,
                  params = { n = { 42 } },
                  rounds = 1,
               },
            },
         })

         assert.are_equal(42, received_n)
      end)
   end)

   test("suite_memit measures memory", function()
      local results = luamark.suite_memit({
         alloc = {
            impl_a = function()
               local t = { 1, 2, 3 }
            end,
            opts = { rounds = 5 },
         },
      })

      assert.is_not_nil(results.alloc.impl_a.unit)
      assert.are_equal("kb", results.alloc.impl_a.unit)
   end)

   describe("validation", function()
      test("rejects empty suite", function()
         assert.has.error(function()
            luamark.suite_timeit({})
         end, "spec is empty")
      end)

      test("rejects group with no benchmarks", function()
         assert.has.error(function()
            luamark.suite_timeit({
               add = {
                  opts = { rounds = 1 },
               },
            })
         end, "group 'add' has no benchmarks")
      end)

      test("rejects invalid benchmark", function()
         assert.has.error(function()
            luamark.suite_timeit({
               add = {
                  impl_a = "not a function",
               },
            })
         end, "benchmark 'impl_a' must be a function or table with 'fn'")
      end)
   end)

   describe("summarize", function()
      test("summarizes suite results grouped by group and params", function()
         local results = luamark.suite_timeit({
            add = {
               fast = function() end,
               slow = function()
                  for i = 1, 1000 do
                     local _ = i -- prevent empty block warning
                  end
               end,
               opts = {
                  params = { n = { 100 } },
                  rounds = 5,
               },
            },
         })

         local output = luamark.summarize(results, "plain")

         assert.matches("add %(n=100%)", output)
         assert.matches("fast", output)
         assert.matches("slow", output)
      end)

      test("csv includes group, benchmark and params columns", function()
         local results = luamark.suite_timeit({
            add = {
               impl_a = function() end,
               opts = {
                  params = { n = { 100 } },
                  rounds = 1,
               },
            },
         })

         local output = luamark.summarize(results, "csv")

         assert.matches("group,benchmark,", output)
         assert.matches("n,", output)
         assert.matches("add,", output)
         assert.matches(",100,", output)
      end)
   end)

   describe("integration", function()
      test("full workflow with multiple groups, benchmarks, and params", function()
         local setup_calls = {}
         local teardown_calls = {}

         local results = luamark.suite_timeit({
            add = {
               fast = function() end,
               slow = function()
                  for i = 1, 100 do
                     local _ = i -- prevent empty block warning
                  end
               end,
               opts = {
                  params = { n = { 10, 20 } },
                  setup = function(p)
                     setup_calls[#setup_calls + 1] = { benchmark = "add", n = p.n }
                  end,
                  teardown = function(p)
                     teardown_calls[#teardown_calls + 1] = { benchmark = "add", n = p.n }
                  end,
                  rounds = 3,
               },
            },
            remove = {
               fast = function() end,
               opts = {
                  params = { n = { 10 } },
                  rounds = 3,
               },
            },
         })

         -- Check structure
         assert.is_not_nil(results.add.fast.n[10])
         assert.is_not_nil(results.add.fast.n[20])
         assert.is_not_nil(results.add.slow.n[10])
         assert.is_not_nil(results.add.slow.n[20])
         assert.is_not_nil(results.remove.fast.n[10])

         -- Check setup/teardown were called
         assert.is_true(#setup_calls > 0)
         assert.is_true(#teardown_calls > 0)

         -- Check summarize works
         local plain = luamark.summarize(results, "plain")
         assert.matches("add %(n=10%)", plain)
         assert.matches("add %(n=20%)", plain)
         assert.matches("remove %(n=10%)", plain)

         local csv = luamark.summarize(results, "csv")
         assert.matches("group,benchmark,n,", csv)
         assert.matches("add,fast,10,", csv)
         assert.matches("add,slow,20,", csv)
         assert.matches("remove,fast,10,", csv)
      end)
   end)
end)
