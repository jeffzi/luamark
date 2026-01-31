---@diagnostic disable: undefined-field, unused-local, unused-function, invisible

local h = require("tests.helpers")

describe("config", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("accepts valid options and rejects invalid", function()
      for _, opt in ipairs({ "rounds", "time" }) do
         luamark[opt] = 1
      end

      assert.has_errors(function()
         luamark.foo = 1
      end)

      for _, invalid in ipairs({ "not a number", 0, -1 }) do
         for _, opt in ipairs({ "rounds", "time" }) do
            assert.has_errors(function()
               luamark[opt] = invalid
            end)
         end
      end
   end)
end)

describe("simple API (timeit/memit)", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("ctx is nil when no setup provided", function()
      local received_ctx = "sentinel"
      luamark.timeit(function(ctx)
         received_ctx = ctx
      end, { rounds = 1 })

      assert.is_nil(received_ctx)
   end)

   test("Stats has readable __tostring", function()
      local stats = luamark.timeit(h.noop, { rounds = 3 })
      local str = tostring(stats)

      -- Should contain humanized time (ns, us, ms, or s)
      assert.matches("[num]s", str)
   end)
end)

describe("suite API (compare_time/compare_memory)", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("params are passed to function and nested in results", function()
      local seen_n = {}
      local results = luamark.compare_time({
         test = function(ctx, p)
            seen_n[p.n] = true
         end,
      }, {
         params = { n = { 10, 20 } },
         rounds = 1,
      })

      assert.is_true(seen_n[10])
      assert.is_true(seen_n[20])
      assert.are_equal(2, #results)
      assert.is_not_nil(results[1].median)
      -- Params are nested in result.params
      assert.is_not_nil(results[1].params)
      assert.is_true(results[1].params.n == 10 or results[1].params.n == 20)
   end)

   test("reserved names can be used as param keys without collision", function()
      local results = luamark.compare_time({
         test = h.noop,
      }, {
         params = { median = { "test_value" }, name = { "custom" }, factor = { 99 } },
         rounds = 1,
      })

      assert.are_equal(1, #results)
      -- Stats fields are preserved
      assert.is_number(results[1].median)
      assert.is_string(results[1].name)
      assert.is_number(results[1].factor)
      -- User params are accessible via nested params table
      assert.are_equal("test_value", results[1].params.median)
      assert.are_equal("custom", results[1].params.name)
      assert.are_equal(99, results[1].params.factor)
   end)

   test("multiple params expand as cartesian product", function()
      local seen = {}
      luamark.compare_time({
         test = function(ctx, p)
            seen[p.n .. "_" .. tostring(p.flag)] = true
         end,
      }, {
         params = { n = { 1, 2 }, flag = { true, false } },
         rounds = 1,
      })

      assert.is_true(seen["1_true"])
      assert.is_true(seen["1_false"])
      assert.is_true(seen["2_true"])
      assert.is_true(seen["2_false"])
   end)

   test("setup/teardown receive params", function()
      local setup_params, teardown_params
      luamark.compare_time({ test = h.noop }, {
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

   test("multiple functions with params return flat array", function()
      local results = luamark.compare_time({
         fast = h.noop,
         slow = h.noop,
      }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      assert.are_equal(2, #results) -- 2 functions × 1 param
   end)

   test("bench functions can be plain functions or tables with fn", function()
      local plain_called, table_called = false, false

      luamark.compare_time({
         plain = function()
            plain_called = true
         end,
         with_setup = {
            fn = function()
               table_called = true
            end,
         },
      }, { rounds = 1 })

      assert.is_true(plain_called)
      assert.is_true(table_called)
   end)

   for _, name in ipairs({ "compare_time", "compare_memory" }) do
      test(name .. " rejects array (numeric keys)", function()
         assert.has_error(function()
            luamark[name]({ h.noop, h.noop }, { rounds = 1 })
         end, "'funcs' keys must be strings, got number. Use named keys: { name = fn }")
      end)
   end
end)

describe("Timer", function()
   local luamark
   local socket = require("socket")

   setup(function()
      luamark = h.load_luamark()
   end)

   test("Timer() creates a new timer instance", function()
      local timer = luamark.Timer()
      assert.is_table(timer)
      assert.is_function(timer.start)
      assert.is_function(timer.stop)
      assert.is_function(timer.elapsed)
      assert.is_function(timer.reset)
   end)

   test("start/stop measures elapsed time", function()
      local timer = luamark.Timer()
      timer.start()
      socket.sleep(0.01)
      local elapsed = timer.stop()
      assert.is_near(0.01, elapsed, 0.005)
   end)

   test("elapsed returns total accumulated time", function()
      local timer = luamark.Timer()
      timer.start()
      socket.sleep(0.01)
      timer.stop()
      timer.start()
      socket.sleep(0.01)
      timer.stop()
      assert.is_near(0.02, timer.elapsed(), 0.01)
   end)

   test("reset clears accumulated time", function()
      local timer = luamark.Timer()
      timer.start()
      socket.sleep(0.01)
      timer.stop()
      timer.reset()
      assert.are_equal(0, timer.elapsed())
   end)

   test("start while running throws error", function()
      local timer = luamark.Timer()
      timer.start()
      assert.has_error(function()
         timer.start()
      end, "timer.start() called while already running")
   end)

   test("stop without start throws error", function()
      local timer = luamark.Timer()
      assert.has_error(function()
         timer.stop()
      end, "timer.stop() called without start()")
   end)

   test("elapsed while running throws error", function()
      local timer = luamark.Timer()
      timer.start()
      assert.has_error(function()
         timer.elapsed()
      end, "timer still running (missing stop())")
   end)
end)

describe("unload", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("unloads matching modules and returns count", function()
      package.loaded["mylib.core"] = { loaded = true }
      package.loaded["mylib.utils"] = { loaded = true }
      package.loaded["mylib.extra"] = { loaded = true }
      package.loaded["other_module"] = { loaded = true }

      local count = luamark.unload("^mylib%.")

      assert.are_equal(3, count)
      assert.is_nil(package.loaded["mylib.core"])
      assert.is_nil(package.loaded["mylib.utils"])
      assert.is_nil(package.loaded["mylib.extra"])
      assert.is_truthy(package.loaded["other_module"])

      package.loaded["other_module"] = nil
   end)

   test("returns 0 when no modules match", function()
      local count = luamark.unload("^nonexistent_module_pattern_xyz$")
      assert.are_equal(0, count)
   end)
end)
