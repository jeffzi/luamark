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
      assert.has_errors(function()
         luamark.rounds = "not a number"
      end)
   end)
end)

describe("simple API (timeit/memit)", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("setup/teardown receive and pass context", function()
      local received_ctx, teardown_ctx

      luamark.timeit(function(ctx)
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
   end)

   test("ctx is nil when no setup provided", function()
      local received_ctx = "sentinel"
      luamark.timeit(function(ctx)
         received_ctx = ctx
      end, { rounds = 1 })

      assert.is_nil(received_ctx)
   end)

   test("before/after hooks run per iteration", function()
      local before_calls, after_calls = 0, 0
      local final_ctx

      luamark.timeit(function(ctx)
         final_ctx = ctx
      end, {
         setup = function()
            return { base = true }
         end,
         before = function(ctx)
            before_calls = before_calls + 1
            return { base = ctx.base, modified = true }
         end,
         after = function()
            after_calls = after_calls + 1
         end,
         rounds = 3,
      })

      assert.is_true(before_calls >= 3)
      assert.is_true(after_calls >= 3)
      assert.is_true(final_ctx.modified)
   end)

   test("Stats has readable __tostring", function()
      local stats = luamark.timeit(h.noop, { rounds = 3 })
      local str = tostring(stats)

      assert.matches("±", str)
   end)
end)

describe("suite API (compare_time/compare_memory)", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("params are passed to function and returned in results", function()
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
      assert.is_not_nil(results[1].stats.median)
   end)

   test("no params returns empty params table", function()
      local results = luamark.compare_time({ test = h.noop }, { rounds = 1 })
      assert.same({}, results[1].params)
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
         params = { n = { 10, 20 } },
         rounds = 1,
      })

      assert.are_equal(4, #results)
   end)

   test("compare_memory also supports params", function()
      local results = luamark.compare_memory({ test = h.noop }, {
         params = { n = { 10, 20 } },
         rounds = 1,
      })

      assert.are_equal(2, #results)
   end)

   test("two-level setup: global setup once, bench before per iteration", function()
      local global_calls, bench_calls = 0, 0
      local final_ctx

      luamark.compare_time({
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

      assert.are_equal(1, global_calls)
      assert.is_true(bench_calls >= 3)
      assert.is_true(final_ctx.modified)
      assert.is_true(final_ctx.original)
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

   test("results array has __tostring", function()
      local results = luamark.compare_time({ test = h.noop }, { rounds = 1 })
      assert.matches("1%.00x", tostring(results))
   end)

   describe("funcs validation", function()
      for _, name in ipairs({ "compare_time", "compare_memory" }) do
         test(name .. " rejects array (numeric keys)", function()
            assert.has_error(function()
               luamark[name]({ h.noop, h.noop }, { rounds = 1 })
            end, "'funcs' keys must be strings, got number. Use named keys: { name = fn }")
         end)
      end
   end)
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
