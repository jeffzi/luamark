---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

local h = require("tests.helpers")
local socket = require("socket")

local SLEEP_TIME = 0.01
local TIME_TOL = SLEEP_TIME / 3
local MEMORY_TOL = 0.0005

--- Verify all stats fields are non-nil.
local function assert_stats_valid(stats)
   assert(stats ~= nil, "stats should not be nil")
   for field, value in pairs(stats) do
      assert(value ~= nil, string.format("stats.%s should not be nil", field))
   end
end

for _, clock_name in ipairs(h.CLOCKS) do
   describe("clock = " .. clock_name .. " ->", function()
      local luamark

      setup(function()
         luamark = h.load_luamark(clock_name)
      end)

      test("uses correct clock", function()
         assert.are_equal(clock_name, luamark.clock_name)
      end)

      describe("timeit and memit (simple API)", function()
         for _, name in ipairs({ "timeit", "memit" }) do
            local bench_suffix = string.format(" (%s)", name)

            test("benchmarks single function and returns Stats" .. bench_suffix, function()
               local benchmark = luamark[name]
               local stats = benchmark(h.noop, { rounds = 1 })
               assert_stats_valid(stats)
               assert.is_number(stats.mean)
               assert.is_number(stats.median)
            end)

            test("tracks iteration count" .. bench_suffix, function()
               local benchmark = luamark[name]
               local calls = 0

               local function counter()
                  calls = calls + 1
                  socket.sleep(
                     luamark._internal.get_min_clocktime() * luamark._internal.CALIBRATION_PRECISION
                  )
               end

               local stats = benchmark(counter, { rounds = 3 })

               assert.are_equal(1, stats.iterations)
               assert.is_true(calls >= stats.count)
            end)

            test("respects round limit" .. bench_suffix, function()
               local benchmark = luamark[name]
               local calls = 0

               local function counter()
                  calls = calls + 1
                  socket.sleep(
                     luamark._internal.get_min_clocktime() * luamark._internal.CALIBRATION_PRECISION
                  )
               end

               local stats = benchmark(counter, { rounds = 3 })

               assert.are_equal(3, stats.rounds)
               assert.are_equal(stats.count, stats.rounds * stats.iterations)
            end)

            test("stops at max_time" .. bench_suffix, function()
               local benchmark = luamark[name]
               local max_time = 0.5
               local actual_time = luamark._internal.measure_time(function()
                  benchmark(function()
                     socket.sleep(0.25)
                  end, { rounds = 1e9, max_time = max_time })
               end, 1)
               assert.is_near(max_time, actual_time, 0.3)
            end)

            test("runs setup and teardown once" .. bench_suffix, function()
               local bench = luamark[name]
               local fn_calls, setup_calls, teardown_calls = 0, 0, 0

               bench(function()
                  fn_calls = fn_calls + 1
               end, {
                  rounds = 1,
                  setup = function()
                     setup_calls = setup_calls + 1
                  end,
                  teardown = function()
                     teardown_calls = teardown_calls + 1
                  end,
               })

               assert.are_equal(1, setup_calls)
               assert.are_equal(1, teardown_calls)
               assert.is_true(fn_calls >= 1)
            end)
         end
      end)

      describe("compare_time and compare_memory (suite API)", function()
         for _, api in ipairs({ { "compare_time", "timeit" }, { "compare_memory", "memit" } }) do
            local compare_fn, simple_fn = api[1], api[2]
            local bench_suffix = string.format(" (%s)", compare_fn)

            test("benchmarks multiple functions" .. bench_suffix, function()
               local benchmark = luamark[compare_fn]
               local results = benchmark({ a = h.noop, b = h.noop }, { rounds = 1 })

               assert.are_equal(2, #results)
               local names = {}
               for i = 1, #results do
                  names[results[i].name] = true
               end
               assert.is_true(names.a)
               assert.is_true(names.b)
               for i = 1, #results do
                  assert_stats_valid(results[i].stats)
               end
            end)
         end
      end)

      describe("timeit", function()
         test("computes timing stats", function()
            local calls = 0
            local long_sleep = SLEEP_TIME * 2
            local function counter()
               calls = calls + 1
               socket.sleep(calls == 10 and long_sleep or SLEEP_TIME)
            end

            local stats = luamark.timeit(counter, { rounds = 100, max_time = 1 })

            assert.is_near(SLEEP_TIME, stats.min, TIME_TOL)
            assert.is_near(long_sleep, stats.max, TIME_TOL * 2)
            assert.near(SLEEP_TIME, stats.mean, TIME_TOL)
            assert.near(SLEEP_TIME, stats.median, TIME_TOL)
         end)
      end)

      local has_luacov = package.loaded["luacov"] or package.loaded["luacov.runner"]
      local can_test_memit = _VERSION ~= "Lua 5.2" and type(jit) ~= "table" and not has_luacov
      if can_test_memit then
         describe("compare_memory", function()
            test("measures memory correctly", function()
               local funcs = {
                  noop = h.noop,
                  empty_table = function()
                     local _ = {}
                  end,
                  complex = function()
                     local _ = { 1, 2, 3 }
                     local _ = "luamark"
                  end,
               }
               local results = luamark.compare_memory(funcs, { rounds = 100 })

               for i = 1, #results do
                  local row = results[i]
                  local single_call_memory = luamark._internal.measure_memory(funcs[row.name], 1)
                  assert.near(single_call_memory, row.stats.mean, MEMORY_TOL)
                  assert.near(single_call_memory, row.stats.median, MEMORY_TOL)
               end
            end)
         end)
      end
   end)
end

describe("validation", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   describe("simple API (timeit/memit)", function()
      test("timeit rejects negative rounds", function()
         assert.has_errors(function()
            luamark.timeit(h.noop, { rounds = -1 })
         end)
      end)

      test("memit rejects negative rounds", function()
         assert.has_errors(function()
            luamark.memit(h.noop, { rounds = -1 })
         end)
      end)

      test("timeit rejects negative max_time", function()
         assert.has_errors(function()
            luamark.timeit(h.noop, { max_time = -1 })
         end)
      end)

      test("memit rejects negative max_time", function()
         assert.has_errors(function()
            luamark.memit(h.noop, { max_time = -1 })
         end)
      end)

      test("timeit rejects unknown option", function()
         assert.has_errors(function()
            luamark.timeit(h.noop, { hello = "world" })
         end)
      end)

      test("memit rejects unknown option", function()
         assert.has_errors(function()
            luamark.memit(h.noop, { hello = "world" })
         end)
      end)

      test("timeit rejects nil function", function()
         assert.has_errors(function()
            ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
            luamark.timeit(nil)
         end)
      end)

      test("memit rejects nil function", function()
         assert.has_errors(function()
            ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
            luamark.memit(nil)
         end)
      end)

      test("timeit rejects params option", function()
         assert.has_errors(function()
            luamark.timeit(h.noop, { params = { n = { 10 } } })
         end, "'params' is not supported in timeit/memit. Use compare_time/compare_memory instead.")
      end)

      test("memit rejects params option", function()
         assert.has_errors(function()
            luamark.memit(h.noop, { params = { n = { 10 } } })
         end, "'params' is not supported in timeit/memit. Use compare_time/compare_memory instead.")
      end)

      test("timeit rejects wrong option type", function()
         assert.has_errors(function()
            luamark.timeit(h.noop, { rounds = "not a number" })
         end)
      end)

      test("timeit rejects non-integer rounds", function()
         assert.has_errors(function()
            luamark.timeit(h.noop, { rounds = 1.5 })
         end)
      end)

      test("timeit rejects table input", function()
         assert.has_errors(function()
            ---@diagnostic disable-next-line: param-type-mismatch
            luamark.timeit({ a = h.noop }, { rounds = 1 })
         end)
      end)

      test("memit rejects table input", function()
         assert.has_errors(function()
            ---@diagnostic disable-next-line: param-type-mismatch
            luamark.memit({ a = h.noop }, { rounds = 1 })
         end)
      end)
   end)

   describe("suite API (compare_time/compare_memory)", function()
      test("compare_time rejects non-table input", function()
         assert.has_errors(function()
            ---@diagnostic disable-next-line: param-type-mismatch
            luamark.compare_time(h.noop, { rounds = 1 })
         end)
      end)

      test("compare_memory rejects non-table input", function()
         assert.has_errors(function()
            ---@diagnostic disable-next-line: param-type-mismatch
            luamark.compare_memory(h.noop, { rounds = 1 })
         end)
      end)

      test("compare_time rejects scalar params value", function()
         assert.has_errors(function()
            luamark.compare_time({ a = h.noop }, { params = { n = 10 } })
         end)
      end)

      test("compare_memory rejects scalar params value", function()
         assert.has_errors(function()
            luamark.compare_memory({ a = h.noop }, { params = { n = 10 } })
         end)
      end)

      test("compare_time rejects non-string params key", function()
         assert.has_errors(function()
            luamark.compare_time({ a = h.noop }, { params = { [1] = { "a" } } })
         end)
      end)

      test("compare_time rejects non-primitive params value", function()
         assert.has_errors(function()
            luamark.compare_time({ a = h.noop }, { params = { n = { {} } } })
         end)
      end)
   end)
end)
