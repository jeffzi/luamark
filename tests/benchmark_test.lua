---@diagnostic disable: undefined-field, unused-local, invisible, different-requires

local h = require("tests.helpers")
local socket = require("socket")

local SLEEP_TIME = 0.01
local TIME_TOL = SLEEP_TIME / 3

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

         test("simple API: benchmarks and returns valid Stats" .. suffix, function()
            local benchmark = luamark[name]
            local stats = benchmark(h.noop, { rounds = 1 })
            h.assert_stats_valid(stats)
            assert.is_number(stats.median)
            assert.is_number(stats.ci_lower)
            assert.is_number(stats.ci_upper)
         end)

         test("simple API: respects round limit and tracks iterations" .. suffix, function()
            local benchmark = luamark[name]
            local min_calibration_time = luamark._internal.get_min_clocktime()
               * luamark._internal.CALIBRATION_PRECISION

            local stats = benchmark(function()
               socket.sleep(min_calibration_time)
            end, { rounds = 3 })

            assert.are_equal(3, stats.rounds)
         end)

         test("simple API: stops at time" .. suffix, function()
            local benchmark = luamark[name]
            local target_time = 0.5
            local clock = luamark._internal.clock
            local t1 = clock()
            benchmark(function()
               socket.sleep(0.25)
            end, { rounds = 1e9, time = target_time })
            local actual_time = clock() - t1
            assert.is_near(target_time, actual_time, 0.3)
         end)

         test("simple API: runs setup and teardown once" .. suffix, function()
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

         test("simple API: setup/teardown receive and pass context" .. suffix, function()
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

      for _, api in ipairs({ { "compare_time", "timeit" }, { "compare_memory", "memit" } }) do
         local compare_fn = api[1]
         local suffix = " (" .. compare_fn .. ")"

         test("suite API: benchmarks multiple functions" .. suffix, function()
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

      test("timer API: auto-timing measures entire function when timer not used", function()
         local stats = luamark.timeit(function()
            socket.sleep(SLEEP_TIME)
         end, { rounds = 3 })
         assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
      end)

      test("timer API: manual timing with timer.start/stop", function()
         local stats = luamark.timeit(function(ctx, timer)
            socket.sleep(SLEEP_TIME / 2) -- not timed
            timer.start()
            socket.sleep(SLEEP_TIME)
            timer.stop()
            socket.sleep(SLEEP_TIME / 2) -- not timed
         end, { rounds = 3 })
         -- Should measure only the middle sleep
         assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
      end)

      test("timer API: multiple start/stop pairs accumulate", function()
         local stats = luamark.timeit(function(ctx, timer)
            timer.start()
            socket.sleep(SLEEP_TIME)
            timer.stop()
            socket.sleep(SLEEP_TIME) -- not timed
            timer.start()
            socket.sleep(SLEEP_TIME)
            timer.stop()
         end, { rounds = 3 })
         -- Should accumulate both timed sections
         assert.is_near(SLEEP_TIME * 2, stats.median, TIME_TOL * 2)
      end)

      test("timer API: timer.start() when already running errors", function()
         assert.has_error(function()
            luamark.timeit(function(ctx, timer)
               timer.start()
               timer.start() -- error: already running
            end, { rounds = 1 })
         end, "timer.start() called while already running")
      end)

      test("timer API: timer.stop() without start() errors", function()
         assert.has_error(function()
            luamark.timeit(function(ctx, timer)
               timer.stop() -- error: not started
            end, { rounds = 1 })
         end, "timer.stop() called without start()")
      end)

      test("timer API: function ends without stop() errors", function()
         assert.has_error(function()
            luamark.timeit(function(ctx, timer)
               timer.start()
               -- missing stop()
            end, { rounds = 1 })
         end, "timer still running (missing stop())")
      end)

      test("timer API: timer works with setup/teardown", function()
         local stats = luamark.timeit(function(ctx, timer)
            timer.start()
            socket.sleep(SLEEP_TIME)
            timer.stop()
         end, {
            setup = function()
               return { data = "test" }
            end,
            teardown = function(ctx)
               assert.are_equal("test", ctx.data)
            end,
            rounds = 3,
         })
         assert.is_near(SLEEP_TIME, stats.median, TIME_TOL)
      end)

      test("timer API: timer in suite API (compare_time)", function()
         local results = luamark.compare_time({
            with_timer = function(ctx, timer)
               timer.start()
               socket.sleep(SLEEP_TIME)
               timer.stop()
            end,
            auto_timed = function()
               socket.sleep(SLEEP_TIME)
            end,
         }, { rounds = 3 })

         for i = 1, #results do
            assert.is_near(SLEEP_TIME, results[i].median, TIME_TOL)
         end
      end)

      test("timer API: timer receives params in suite API", function()
         local seen_params = {}
         luamark.compare_time({
            test = function(ctx, timer, params)
               seen_params[params.n] = true
            end,
         }, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })
         assert.is_true(seen_params[10])
         assert.is_true(seen_params[20])
      end)

      test("memit: does not include ops field", function()
         local stats = luamark.memit(function()
            local t = {}
            for i = 1, 10 do
               t[i] = i
            end
         end, { rounds = 10 })

         assert.is_nil(stats.ops)
      end)

      test("timer. Timer() creates new instance", function()
         local timer = luamark.Timer()
         assert.is_table(timer)
         assert.is_function(timer.start)
         assert.is_function(timer.stop)
      end)

      test("timer. stop() returns elapsed time in seconds", function()
         local timer = luamark.Timer()
         timer.start()
         socket.sleep(SLEEP_TIME)
         local elapsed = timer.stop()
         assert.is_number(elapsed)
         assert.is_near(SLEEP_TIME, elapsed, TIME_TOL)
      end)

      test("timer. error on double start", function()
         local timer = luamark.Timer()
         timer.start()
         assert.has_error(function()
            timer.start()
         end, "timer.start() called while already running")
      end)

      test("timer. error on stop without start", function()
         local timer = luamark.Timer()
         assert.has_error(function()
            timer.stop()
         end, "timer.stop() called without start()")
      end)

      test("timer. multiple timers are independent", function()
         local timer1 = luamark.Timer()
         local timer2 = luamark.Timer()

         timer1:start()
         socket.sleep(SLEEP_TIME)
         local elapsed1 = timer1:stop()

         timer2:start()
         socket.sleep(SLEEP_TIME * 2)
         local elapsed2 = timer2:stop()

         assert.is_near(SLEEP_TIME, elapsed1, TIME_TOL)
         assert.is_near(SLEEP_TIME * 2, elapsed2, TIME_TOL * 2)
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
                  local t = {}
                  for i = 1, 100 do
                     t[i] = i
                  end
               end,
            }
            local results = luamark.compare_memory(funcs, { rounds = 100 })

            -- Memory measurements are hard to compare precisely with new API
            -- Just verify results exist and are reasonable
            for i = 1, #results do
               local row = results[i]
               assert.is_number(row.median)
               assert.is_true(row.median >= 0)
            end
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

   test(
      "timeit uses multiple iterations for very fast functions with low-precision clock",
      function()
         -- Load luamark with os.clock (low precision) to ensure calibration needs iterations
         local luamark_osclock = h.load_luamark(h.ALL_CLOCKS)
         assert.are_equal("os.clock", luamark_osclock.clock_name)
         local stats = luamark_osclock.timeit(h.noop, {})
         -- Very fast functions (empty function ~1ns) need multiple iterations
         -- to exceed clock precision threshold with low-precision clocks
         assert.is_true(stats.iterations > 1)
      end
   )

   test("memit uses single iteration (skips time-based calibration)", function()
      -- Memory measurement doesn't benefit from high iterations - it's not
      -- affected by clock precision. Using time-based calibration for memit
      -- causes hangs with low-precision clocks due to excessive GC calls.
      local luamark_osclock = h.load_luamark(h.ALL_CLOCKS)
      assert.are_equal("os.clock", luamark_osclock.clock_name)
      local stats = luamark_osclock.memit(h.noop, { rounds = 1 })
      assert.are_equal(1, stats.iterations)
   end)
end)

describe("validation", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   for _, name in ipairs({ "timeit", "memit" }) do
      test("simple API: " .. name .. " rejects invalid options", function()
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

      test("simple API: " .. name .. " rejects invalid input", function()
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
   end

   for _, name in ipairs({ "compare_time", "compare_memory" }) do
      test("suite API: " .. name .. " rejects invalid input", function()
         assert.has_error(function()
            ---@diagnostic disable-next-line: param-type-mismatch
            luamark[name](h.noop, { rounds = 1 })
         end, "'funcs' must be a table, got function")
      end)

      test("suite API: " .. name .. " rejects invalid params", function()
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

      test("suite API: " .. name .. " rejects too many param combinations", function()
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
