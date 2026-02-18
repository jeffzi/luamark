---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

local h = require("tests.helpers")
local socket = require("socket")

local SLEEP_TIME = 0.01
local TIME_TOL = SLEEP_TIME / 3
local MEMORY_TOL = 0.1

for _, clock_name in ipairs(h.CLOCKS) do
   describe("clock = " .. clock_name .. " ->", function()
      local luamark

      setup(function()
         luamark = h.load_luamark(h.clocks_except(clock_name))
      end)

      test("uses correct clock", function()
         assert.are_equal(clock_name, luamark.clock_name)
      end)

      for _, name in ipairs({ "timeit", "memit" }) do
         local suffix = " (" .. name .. ")"

         test("benchmarks and returns valid Stats" .. suffix, function()
            local benchmark = luamark[name]
            local stats = benchmark(h.noop, { rounds = 1 })
            h.assert_stats_valid(stats)
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

         test("setup/teardown receive and pass context" .. suffix, function()
            local benchmark = luamark[name]
            local received_ctx, teardown_ctx

            benchmark(function(ctx)
               received_ctx = ctx
            end, {
               setup = function()
                  return { data = "test_value" }
               end,
               teardown = function(ctx)
                  teardown_ctx = ctx
               end,
               rounds = 1,
            })

            assert.are_equal("test_value", received_ctx.data)
            assert.are_equal("test_value", teardown_ctx.data)

            -- setup returning nil passes nil to fn and teardown
            received_ctx, teardown_ctx = "sentinel", "sentinel"
            benchmark(function(ctx)
               received_ctx = ctx
            end, {
               setup = function()
                  return nil
               end,
               teardown = function(ctx)
                  teardown_ctx = ctx
               end,
               rounds = 1,
            })

            assert.is_nil(received_ctx)
            assert.is_nil(teardown_ctx)
         end)
      end

      for _, compare_fn in ipairs({ "compare_time", "compare_memory" }) do
         local suffix = " (" .. compare_fn .. ")"

         test("benchmarks multiple functions" .. suffix, function()
            local results = luamark[compare_fn]({ a = h.noop, b = h.noop }, { rounds = 1 })

            assert.are_equal(2, #results)
            local names = {}
            for i = 1, #results do
               names[results[i].name] = true
               h.assert_stats_valid(results[i])
            end
            assert.is_true(names.a)
            assert.is_true(names.b)
         end)
      end

      test("timeit: computes timing stats and ops", function()
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

      test("timeit: fast path (no hooks) measures time correctly", function()
         local stats = luamark.timeit(function()
            socket.sleep(SLEEP_TIME)
         end, { rounds = 3 })
         assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
      end)

      test("memit: does not include ops field", function()
         local stats = luamark.memit(h.noop, { rounds = 10 })
         assert.is_nil(stats.ops)
      end)

      local has_luacov = package.loaded["luacov"] or package.loaded["luacov.runner"]
      local can_test_memit = _VERSION ~= "Lua 5.2" and type(jit) ~= "table" and not has_luacov
      if can_test_memit then
         test("compare_memory: measures memory correctly", function()
            local funcs = {
               noop = h.noop,
               string_1kb = function()
                  local _ = string.rep("x", 1024)
               end,
               table_100 = function()
                  local t = {} -- luacheck: ignore t
                  for i = 1, 100 do
                     t[i] = i
                  end
               end,
            }
            local results = luamark.compare_memory(funcs, { rounds = 100 })

            for i = 1, #results do
               local row = results[i]
               local _, single_call_memory = luamark._internal.measure_memory(funcs[row.name], 1)
               assert.is_near(single_call_memory, row.median, MEMORY_TOL)
            end
         end)
      end
   end)
end

if type(jit) == "table" and jit.status and jit.status() then
   -- Shells out because LuaJIT does not compile traces inside
   -- coroutines (busted runs tests in coroutines), which hides the bug.
   test("JIT trace overhead excluded from measurement", function()
      local result = os.execute("lua tests/jit_trace_check.lua > /dev/null 2>&1")
      assert.are_equal(0, result, "JIT trace overhead leaked into measurement")
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

   test("Spec.before/after hooks run per iteration with high iteration count", function()
      -- Use os.clock to force iterations > 1
      local luamark_osclock = h.load_luamark(h.ALL_CLOCKS)
      local global_calls, bench_calls = 0, 0
      local final_ctx

      local results = luamark_osclock.compare_time({
         test_bench = {
            fn = function(ctx)
               final_ctx = ctx
            end,
            before = function(ctx)
               bench_calls = bench_calls + 1
               return { modified = true, original = ctx and ctx.original }
            end,
         },
      }, {
         setup = function()
            global_calls = global_calls + 1
            return { original = true }
         end,
         rounds = 3,
      })

      local stats = results[1]
      assert.is_true(stats.iterations > 1)
      assert.are_equal(1, global_calls)
      -- Bench-level before runs per iteration; calibration adds extra calls
      local total_iterations = stats.rounds * stats.iterations
      assert.is_true(bench_calls >= total_iterations)
      assert.is_true(final_ctx.modified)
      assert.is_true(final_ctx.original)
   end)
end)

describe("validation", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   for _, name in ipairs({ "timeit", "memit" }) do
      test(name .. " rejects invalid options", function()
         assert.has_error(function()
            luamark[name](h.noop, { rounds = -1 })
         end, "'rounds' must be > 0.")
         assert.has_error(function()
            luamark[name](h.noop, { time = -1 })
         end, "'time' must be > 0.")
         assert.has_error(function()
            luamark[name](h.noop, { hello = "world" })
         end, "Unknown option: hello")
         assert.has_error(function()
            luamark[name](h.noop, { rounds = "not a number" })
         end, "Option 'rounds' should be number")
         assert.has_error(function()
            luamark[name](h.noop, { rounds = 1.5 })
         end, "Option 'rounds' must be an integer")
      end)

      test(name .. " rejects invalid input", function()
         assert.has_error(function()
            ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
            luamark[name](nil)
         end, "'fn' must be a function, got nil")
         assert.has_error(function()
            ---@diagnostic disable-next-line: param-type-mismatch
            luamark[name]({ a = h.noop }, { rounds = 1 })
         end, "'fn' must be a function, got table")
         local ok, err = pcall(luamark[name], h.noop, { params = { n = { 10 } } })
         assert.is_false(ok)
         assert.matches("'params' is not supported in timeit/memit", err)
      end)

      test(name .. " rejects global before/after hooks", function()
         -- Global before/after were removed; only Spec-level hooks are supported
         assert.has_error(function()
            luamark[name](h.noop, { before = h.noop })
         end, "Unknown option: before")
         assert.has_error(function()
            luamark[name](h.noop, { after = h.noop })
         end, "Unknown option: after")
      end)
   end

   for _, name in ipairs({ "compare_time", "compare_memory" }) do
      test(name .. " rejects invalid input", function()
         assert.has_error(function()
            ---@diagnostic disable-next-line: param-type-mismatch
            luamark[name](h.noop, { rounds = 1 })
         end, "'funcs' must be a table, got function")
      end)

      test(name .. " rejects invalid params", function()
         local ok, err

         ok, err = pcall(luamark[name], { a = h.noop }, { params = { n = 10 } })
         assert.is_false(ok)
         assert.matches("params%['n'%] must be an array", err)

         ok, err = pcall(luamark[name], { a = h.noop }, { params = { [1] = { "a" } } })
         assert.is_false(ok)
         assert.matches("params key must be a string", err)

         ok, err = pcall(luamark[name], { a = h.noop }, { params = { n = { {} } } })
         assert.is_false(ok)
         assert.matches("params%['n'%]%[1%] must be string, number, or boolean", err)

         ok, err = pcall(luamark[name], { a = h.noop }, { params = { n = {} } })
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

describe("clock warning", function()
   test("warns once on first benchmark when using os.clock", function()
      local warn_output = {}
      local original_warn = _G.warn
      _G.warn = function(msg)
         warn_output[#warn_output + 1] = msg
      end

      finally(function()
         _G.warn = original_warn
      end)

      local luamark = h.load_luamark(h.ALL_CLOCKS)
      assert.are_equal("os.clock", luamark.clock_name)

      luamark.timeit(h.noop, { rounds = 1 })
      local first_output = table.concat(warn_output)

      warn_output = {}
      luamark.timeit(h.noop, { rounds = 1 })
      local second_output = table.concat(warn_output)

      assert.matches("luamark: using os.clock", first_output)
      assert.are_equal("", second_output)
   end)
end)
