---@diagnostic disable: undefined-field, unused-local, unused-function, invisible

local h = require("tests.helpers")

--- Check if results contain all expected parameter values.
local function has_all_param_values(results, param_name, expected_values)
   local found = {}
   for i = 1, #results do
      found[results[i].params[param_name]] = true
   end
   for i = 1, #expected_values do
      if not found[expected_values[i]] then
         return false
      end
   end
   return true
end

describe("config", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("accepts valid config options", function()
      local valid_options = { "max_iterations", "min_rounds", "max_rounds", "warmups" }
      for _, opt in ipairs(valid_options) do
         luamark[opt] = 1
      end
   end)

   test("rejects invalid config option", function()
      assert.has_errors(function()
         luamark.foo = 1
      end, "Invalid config option: foo")
   end)

   test("rejects non-number config value", function()
      assert.has_errors(function()
         luamark.warmups = "not a number"
      end)
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

describe("simple API (timeit/memit)", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   describe("setup returns context", function()
      test("benchmark receives ctx from setup", function()
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

      test("ctx is nil when no setup provided", function()
         local received_ctx = "sentinel"
         luamark.timeit(function(ctx)
            received_ctx = ctx
         end, {
            rounds = 1,
         })

         assert.is_nil(received_ctx)
      end)

      test("setup receives no args in simple mode", function()
         local arg_count = -1
         luamark.timeit(h.noop, {
            setup = function(...)
               arg_count = select("#", ...)
               return {}
            end,
            rounds = 1,
         })

         assert.are_equal(0, arg_count)
      end)

      test("teardown receives ctx only in simple mode", function()
         local teardown_ctx, arg_count
         luamark.timeit(h.noop, {
            setup = function()
               return { value = 42 }
            end,
            teardown = function(ctx, ...)
               teardown_ctx = ctx
               arg_count = select("#", ...) + 1
            end,
            rounds = 1,
         })

         assert.is_not_nil(teardown_ctx)
         assert.are_equal(42, teardown_ctx.value)
         assert.are_equal(1, arg_count)
      end)
   end)

   describe("Options.before and Options.after hooks", function()
      test("Options.before runs per iteration and can modify context", function()
         local before_calls = 0
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
            rounds = 3,
         })

         assert.is_true(before_calls >= 3)
         assert.is_true(final_ctx.base)
         assert.is_true(final_ctx.modified)
      end)

      test("Options.after runs per iteration", function()
         local after_calls = 0

         luamark.timeit(h.noop, {
            after = function()
               after_calls = after_calls + 1
            end,
            rounds = 3,
         })

         assert.is_true(after_calls >= 3)
      end)

      test("before receives only ctx in simple mode", function()
         local arg_count = -1
         luamark.timeit(h.noop, {
            setup = function()
               return { test = true }
            end,
            before = function(...)
               arg_count = select("#", ...)
               return select(1, ...)
            end,
            rounds = 1,
         })

         assert.are_equal(1, arg_count)
      end)

      test("after receives only ctx in simple mode", function()
         local arg_count = -1
         luamark.timeit(h.noop, {
            setup = function()
               return { test = true }
            end,
            after = function(...)
               arg_count = select("#", ...)
            end,
            rounds = 1,
         })

         assert.are_equal(1, arg_count)
      end)
   end)

   describe("Stats tostring", function()
      test("Stats has readable __tostring", function()
         local stats = luamark.timeit(h.noop, { rounds = 3 })
         local str = tostring(stats)

         assert.matches("per round", str)
         assert.matches("%d+ rounds", str)
      end)
   end)
end)

describe("suite API (compare_time/compare_memory)", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   describe("params", function()
      test("accepts params option", function()
         local seen_n = {}
         luamark.compare_time({
            test = function(ctx, p)
               seen_n[p.n] = true
            end,
         }, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.is_true(seen_n[10])
         assert.is_true(seen_n[20])
      end)

      test("returns flat array with params", function()
         local results = luamark.compare_time({
            test = function() end,
         }, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.are_equal(2, #results)
         assert.is_true(has_all_param_values(results, "n", { 10, 20 }))
         for i = 1, #results do
            assert.is_not_nil(results[i].stats.median)
         end
      end)

      test("returns flat array with empty params when no params", function()
         local results = luamark.compare_time({ test = h.noop }, { rounds = 1 })
         assert.are_equal(1, #results)
         assert.are_equal("test", results[1].name)
         assert.is_not_nil(results[1].stats.median)
         assert.same({}, results[1].params)
      end)

      test("expands multiple params as cartesian product", function()
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

      test("setup and teardown receive params", function()
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

         -- 2 functions x 2 params = 4 rows
         assert.are_equal(4, #results)
         local names = {}
         for i = 1, #results do
            names[results[i].name] = true
         end
         assert.is_true(names.fast)
         assert.is_true(names.slow)
         assert.is_true(has_all_param_values(results, "n", { 10, 20 }))
         for i = 1, #results do
            assert.is_not_nil(results[i].stats.median)
         end
      end)

      test("compare_memory also supports params", function()
         local results = luamark.compare_memory({ test = h.noop }, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.are_equal(2, #results)
         assert.is_true(has_all_param_values(results, "n", { 10, 20 }))
         for i = 1, #results do
            assert.is_not_nil(results[i].stats.median)
         end
      end)
   end)

   describe("two-level setup", function()
      test("setup runs once, before runs per iteration", function()
         local global_calls = 0
         local bench_calls = 0

         local results = luamark.compare_time({
            test_bench = {
               fn = h.noop,
               before = function(ctx)
                  bench_calls = bench_calls + 1
                  return ctx
               end,
            },
         }, {
            setup = function()
               global_calls = global_calls + 1
               return { value = 1 }
            end,
            rounds = 5,
         })

         local stats = results[1].stats
         assert.are_equal(1, global_calls)
         assert(
            bench_calls >= stats.rounds,
            string.format(
               "bench_calls=%d should be >= rounds=%d (iterations=%d, warmups=%d)",
               bench_calls,
               stats.rounds,
               stats.iterations,
               stats.warmups
            )
         )
      end)

      test("before receives ctx and can modify it", function()
         local final_ctx
         luamark.compare_time({
            test_bench = {
               fn = function(ctx)
                  final_ctx = ctx
               end,
               before = function(ctx)
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

      test("after receives iteration_ctx", function()
         local teardown_ctx
         luamark.compare_time({
            test_bench = {
               fn = h.noop,
               before = function()
                  return { iteration_value = 42 }
               end,
               after = function(ctx)
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

         luamark.compare_time({
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

      test("before without setup receives nil ctx", function()
         local received_ctx = "sentinel"
         luamark.compare_time({
            test_bench = {
               fn = h.noop,
               before = function(ctx)
                  received_ctx = ctx
                  return { new = true }
               end,
            },
         }, {
            rounds = 1,
         })

         assert.is_nil(received_ctx)
      end)

      test("before receives params", function()
         local received_param
         luamark.compare_time({
            test_bench = {
               fn = h.noop,
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

      test("two-level setup works with compare_memory", function()
         local global_calls = 0
         local bench_calls = 0

         luamark.compare_memory({
            test_bench = {
               fn = h.noop,
               before = function(ctx)
                  bench_calls = bench_calls + 1
                  return ctx
               end,
            },
         }, {
            setup = function()
               global_calls = global_calls + 1
               return {}
            end,
            rounds = 3,
         })

         assert.are_equal(1, global_calls)
         assert.is_true(bench_calls >= 3)
      end)
   end)

   describe("results tostring", function()
      test("results array has __tostring that calls summarize", function()
         local results = luamark.compare_time({ test = h.noop }, { rounds = 1 })
         local str = tostring(results)

         assert.matches("1%.00x", str)
      end)
   end)
end)
