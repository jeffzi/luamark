---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

local h = require("tests.helpers")
local socket = require("socket")

local SLEEP_TIME = 0.01
local TIME_TOL = SLEEP_TIME / 3
local MEMORY_TOL = 0.1

--- Verify stats object exists and all its fields are non-nil.
---@param stats table
local function assert_stats_valid(stats)
   assert(stats, "stats should not be nil")
   for field, value in pairs(stats) do
      assert(value ~= nil, "stats." .. field .. " should not be nil")
   end
end

for _, clock_name in ipairs(h.CLOCKS) do
   describe("clock = " .. clock_name .. " ->", function()
      local luamark

      setup(function()
         luamark = h.load_luamark(h.clocks_except(clock_name))
      end)

      test("uses correct clock", function()
         assert.are_equal(clock_name, luamark.clock_name)
      end)

      describe("timeit and memit (simple API)", function()
         for _, name in ipairs({ "timeit", "memit" }) do
            local suffix = " (" .. name .. ")"

            test("benchmarks and returns valid Stats" .. suffix, function()
               local benchmark = luamark[name]
               local stats = benchmark(h.noop, { rounds = 1 })
               assert_stats_valid(stats)
               assert.is_number(stats.median)
               assert.is_number(stats.ci_lower)
               assert.is_number(stats.ci_upper)
            end)

            test("respects round limit and tracks iterations" .. suffix, function()
               local benchmark = luamark[name]
               local min_calibration_time = luamark._internal.get_min_clocktime()
                  * luamark._internal.CALIBRATION_PRECISION

               local stats = benchmark(function()
                  socket.sleep(min_calibration_time)
               end, { rounds = 3 })

               assert.are_equal(3, stats.rounds)
               assert.are_equal(stats.count, stats.rounds * stats.iterations)
            end)

            test("stops at time" .. suffix, function()
               local benchmark = luamark[name]
               local target_time = 0.5
               local actual_time = luamark._internal.measure_time(function()
                  benchmark(function()
                     socket.sleep(0.25)
                  end, { rounds = 1e9, time = target_time })
               end, 1)
               assert.is_near(target_time, actual_time, 0.3)
            end)

            test("runs setup and teardown once" .. suffix, function()
               local benchmark = luamark[name]
               local setup_calls, teardown_calls = 0, 0

               benchmark(h.noop, {
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
            end)
         end
      end)

      describe("compare_time and compare_memory (suite API)", function()
         for _, api in ipairs({ { "compare_time", "timeit" }, { "compare_memory", "memit" } }) do
            local compare_fn = api[1]
            local suffix = " (" .. compare_fn .. ")"

            test("benchmarks multiple functions" .. suffix, function()
               local results = luamark[compare_fn]({ a = h.noop, b = h.noop }, { rounds = 1 })

               assert.are_equal(2, #results)
               local names = {}
               for i = 1, #results do
                  names[results[i].name] = true
                  assert_stats_valid(results[i].stats)
               end
               assert.is_true(names.a)
               assert.is_true(names.b)
            end)
         end
      end)

      describe("timeit", function()
         test("computes timing stats and ops", function()
            local stats = luamark.timeit(function()
               socket.sleep(SLEEP_TIME)
            end, {
               rounds = 10,
               time = 0.5,
            })

            assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
            assert.is_number(stats.ops)
            assert.is_near(1 / stats.median, stats.ops, 1e-10)
            assert.is_number(stats.ci_lower)
            assert.is_number(stats.ci_upper)
            assert.is_true(stats.ci_lower <= stats.median)
            assert.is_true(stats.ci_upper >= stats.median)
         end)
      end)

      describe("batch timing optimization", function()
         test("fast path (no hooks) measures time correctly", function()
            local stats = luamark.timeit(function()
               socket.sleep(SLEEP_TIME)
            end, { rounds = 3 })

            assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
         end)

         test("slow path (with before hook) measures time correctly", function()
            local stats = luamark.timeit(function()
               socket.sleep(SLEEP_TIME)
            end, {
               rounds = 3,
               before = h.noop,
            })

            assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
         end)

         test("slow path (with after hook) measures time correctly", function()
            local stats = luamark.timeit(function()
               socket.sleep(SLEEP_TIME)
            end, {
               rounds = 3,
               after = h.noop,
            })

            assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
         end)

         test("fast path has less overhead than slow path", function()
            local function work()
               socket.sleep(SLEEP_TIME)
            end

            local fast_stats = luamark.timeit(work, { rounds = 5 })
            local slow_stats = luamark.timeit(work, { rounds = 5, before = h.noop })

            assert.is_near(fast_stats.median, slow_stats.median, TIME_TOL)
            assert.is_true(fast_stats.median <= slow_stats.median + TIME_TOL)
         end)
      end)

      describe("memit", function()
         test("does not include ops field", function()
            local stats = luamark.memit(function()
               local t = {}
               for i = 1, 10 do
                  t[i] = i
               end
            end, { rounds = 10 })

            assert.is_nil(stats.ops)
         end)
      end)

      local has_luacov = package.loaded["luacov"] or package.loaded["luacov.runner"]
      local can_test_memit = _VERSION ~= "Lua 5.2" and type(jit) ~= "table" and not has_luacov
      if can_test_memit then
         describe("compare_memory", function()
            test("measures memory correctly", function()
               local funcs = {
                  noop = h.noop,
                  string_1kb = function()
                     local _ = string.rep("x", 1024)
                  end,
                  table_100 = function()
                     local t = {}
                     for i = 1, 100 do
                        t[i] = i
                     end
                  end,
               }
               local results = luamark.compare_memory(funcs, { rounds = 100 })

               for i = 1, #results do
                  local row = results[i]
                  local _, single_call_memory = luamark._internal.measure_memory(funcs[row.name], 1)
                  assert.is_near(single_call_memory, row.stats.median, MEMORY_TOL)
               end
            end)
         end)
      end
   end)
end

describe("calibration", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("caps rounds at MAX_ROUNDS for fast functions", function()
      local stats = luamark.timeit(h.noop, {})
      assert.is_true(stats.rounds <= luamark._internal.MAX_ROUNDS)
   end)

   test("uses multiple iterations for very fast functions with low-precision clock", function()
      -- Load luamark with os.clock (low precision) to ensure calibration needs iterations
      local luamark_osclock = h.load_luamark(h.ALL_CLOCKS)
      assert.are_equal("os.clock", luamark_osclock.clock_name)
      local stats = luamark_osclock.timeit(h.noop, {})
      -- Very fast functions (empty function ~1ns) need multiple iterations
      -- to exceed clock precision threshold with low-precision clocks
      assert.is_true(stats.iterations > 1)
   end)
end)

describe("validation", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   describe("simple API (timeit/memit)", function()
      for _, name in ipairs({ "timeit", "memit" }) do
         test(name .. " rejects invalid options", function()
            assert.has_errors(function()
               luamark[name](h.noop, { rounds = -1 })
            end)
            assert.has_errors(function()
               luamark[name](h.noop, { time = -1 })
            end)
            assert.has_errors(function()
               luamark[name](h.noop, { hello = "world" })
            end)
            assert.has_errors(function()
               luamark[name](h.noop, { rounds = "not a number" })
            end)
            assert.has_errors(function()
               luamark[name](h.noop, { rounds = 1.5 })
            end)
         end)

         test(name .. " rejects invalid input", function()
            assert.has_errors(function()
               ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
               luamark[name](nil)
            end)
            assert.has_errors(function()
               ---@diagnostic disable-next-line: param-type-mismatch
               luamark[name]({ a = h.noop }, { rounds = 1 })
            end)
            assert.has_errors(function()
               luamark[name](h.noop, { params = { n = { 10 } } })
            end)
         end)
      end
   end)

   describe("suite API (compare_time/compare_memory)", function()
      for _, name in ipairs({ "compare_time", "compare_memory" }) do
         test(name .. " rejects invalid input", function()
            assert.has_errors(function()
               ---@diagnostic disable-next-line: param-type-mismatch
               luamark[name](h.noop, { rounds = 1 })
            end)
         end)

         test(name .. " rejects invalid params", function()
            assert.has_errors(function()
               luamark[name]({ a = h.noop }, { params = { n = 10 } })
            end)
            assert.has_errors(function()
               luamark[name]({ a = h.noop }, { params = { [1] = { "a" } } })
            end)
            assert.has_errors(function()
               luamark[name]({ a = h.noop }, { params = { n = { {} } } })
            end)

            local ok, err = pcall(luamark[name], { a = h.noop }, { params = { n = {} } })
            assert.is_false(ok)
            assert.matches("must not be empty", err)
         end)

         test(name .. " rejects too many param combinations", function()
            local many_values = {}
            for i = 1, 101 do
               many_values[i] = i
            end
            local ok, err = pcall(luamark[name], { a = h.noop }, {
               params = { a = many_values, b = many_values },
            })
            assert.is_false(ok)
            assert.matches("Too many parameter combinations", err)
         end)
      end
   end)
end)
