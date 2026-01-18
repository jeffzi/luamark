---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

local function has_param_values(results, param_name, expected_values)
   local found = {}
   for i = 1, #results do
      found[results[i].params[param_name]] = true
   end
   for _, val in ipairs(expected_values) do
      if not found[val] then
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
      assert.has.errors(function()
         luamark.foo = 1
      end, "Invalid config option: foo")
   end)

   test("rejects non-number config value", function()
      assert.has.errors(function()
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

describe("API", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
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
         luamark.timeit(h.noop, {
            setup = function(p)
               received_p = p
               return {}
            end,
            rounds = 1,
         })

         assert.is_table(received_p)
      end)

      test("after_all receives ctx and params", function()
         local teardown_ctx, teardown_params
         luamark.timeit(h.noop, {
            setup = function()
               return { value = 42 }
            end,
            teardown = function(ctx, p)
               teardown_ctx = ctx
               teardown_params = p
            end,
            rounds = 1,
         })

         assert.is_not_nil(teardown_ctx)
         assert.are_equal(42, teardown_ctx.value)
         assert.is_table(teardown_params)
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

      test("returns flat array for single function with params", function()
         local results = luamark.timeit(function() end, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.are_equal(2, #results)
         assert.is_true(has_param_values(results, "n", { 10, 20 }))
         for i = 1, #results do
            assert.is_not_nil(results[i].stats.median)
         end
      end)

      test("returns flat array with empty params when no params", function()
         local results = luamark.timeit(h.noop, { rounds = 1 })
         assert.are_equal(1, #results)
         assert.are_equal("1", results[1].name)
         assert.is_not_nil(results[1].stats.median)
         assert.same({}, results[1].params)
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
         luamark.timeit(h.noop, {
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
         local results = luamark.timeit({
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
         assert.is_true(has_param_values(results, "n", { 10, 20 }))
         for i = 1, #results do
            assert.is_not_nil(results[i].stats.median)
         end
      end)

      test("memit also supports params", function()
         local results = luamark.memit(h.noop, {
            params = { n = { 10, 20 } },
            rounds = 1,
         })

         assert.are_equal(2, #results)
         assert.is_true(has_param_values(results, "n", { 10, 20 }))
         for i = 1, #results do
            assert.is_not_nil(results[i].stats.median)
         end
      end)
   end)

   describe("two-level setup", function()
      test("before_all runs once, before_each runs per iteration", function()
         local global_calls = 0
         local bench_calls = 0

         local results = luamark.timeit({
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

      test("before_each receives ctx and can modify it", function()
         local final_ctx
         luamark.timeit({
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

      test("after_each receives iteration_ctx", function()
         local teardown_ctx
         luamark.timeit({
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

      test("before_each receives params", function()
         local received_param
         luamark.timeit({
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

      test("two-level setup works with memit", function()
         local global_calls = 0
         local bench_calls = 0

         luamark.memit({
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
   end)

   describe("Stats tostring", function()
      test("Stats has readable __tostring", function()
         local results = luamark.timeit(h.noop, { rounds = 3 })
         local stats = results[1].stats
         local str = tostring(stats)

         assert.matches("per round", str)
         assert.matches("%d+ rounds", str)
      end)

      test("results array has __tostring that calls summarize", function()
         local results = luamark.timeit(h.noop, { rounds = 1 })
         local str = tostring(results)

         assert.matches("1%.00x", str)
      end)
   end)
end)
