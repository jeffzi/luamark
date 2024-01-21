---@diagnostic disable: undefined-field, unused-local
local luamark = require("../src/luamark")

local function try_require(modname)
   has_module, lib = pcall(require, modname)
   assert(has_module, string.format("Dependency '%s' is required for testing.", modname))
   return lib
end

local chronos = try_require("chronos")
local posix = try_require("posix")
local socket = try_require("socket")

-- ----------------------------------------------------------------------------
-- Test parameters
-- ----------------------------------------------------------------------------

local SLEEP_TIME = 0.001
-- socket.sleep doesn't sleep the exact time
local TIME_TOL = SLEEP_TIME / 3
local MEMORY_TOL = 0.0005
local ROUNDS_CASES = { nil, 2 }
local LIBS = { "socket", "chronos" }
local LIBS = { "socket", "chronos" }

local _posix_clock, _ = luamark.get_clock("posix.time")
if _posix_clock then
   table.insert(LIBS, "posix.time")
end

local noop = function() end

local function assert_stats_not_nil(stats)
   assert.is_not_nil(stats)
   for _, stat in pairs(stats) do
      assert.is_not_nil(stat)
   end
end

-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------

for _, modname in ipairs(LIBS) do
   describe("clock=" .. modname, function()
      setup(function()
         clock, clock_precision = luamark.get_clock(modname)
         luamark.clock, luamark.clock_precision = clock, clock_precision
      end)

      -- ----------------------------------------------------------------------------
      -- Base tests
      -- ----------------------------------------------------------------------------

      describe("base", function()
         for name, benchmark in pairs({ timeit = luamark.timeit, memit = luamark.memit }) do
            local bench_suffix = string.format(" (%s)", name)

            -- ----------------------------------------------------------------------------
            -- Test table stats
            -- ----------------------------------------------------------------------------

            test("single function " .. bench_suffix, function()
               local stats = benchmark(noop)
               assert_stats_not_nil(stats)
            end)

            test("multiple functions " .. bench_suffix, function()
               local stats = benchmark({ a = noop, b = noop })

               assert.is_not_nil(stats.a)
               assert.is_not_nil(stats.b)
               local size = 0
               for _, sub_stats in pairs(stats) do
                  size = size + 1
                  assert_stats_not_nil(sub_stats)
               end
               assert.equal(size, 2)
            end)

            -- ----------------------------------------------------------------------------
            -- Test errors
            -- ----------------------------------------------------------------------------

            test("error rounds " .. bench_suffix, function()
               assert.has.errors(function()
                  benchmark(function() end, -1)
               end)
            end)

            test("error iterations " .. bench_suffix, function()
               assert.has.errors(function()
                  benchmark(function() end, nil, -1)
               end)
            end)

            test("error warmups " .. bench_suffix, function()
               assert.has.errors(function()
                  benchmark(function() end, nil, nil, -1)
               end)
            end)

            -- ----------------------------------------------------------------------------
            -- Test common stats
            -- ----------------------------------------------------------------------------

            for i = 1, #ROUNDS_CASES do
               local calls = 0

               local counter = function()
                  calls = calls + 1
               end

               local rounds = ROUNDS_CASES[i]
               local round_suffix = string.format("(%s %s rounds)", bench_suffix, rounds or "nil")

               local stats = benchmark(counter, rounds, 1, 0)

               test("count" .. round_suffix, function()
                  assert.equal(calls, stats.count)
               end)

               if rounds then
                  test("#rounds" .. round_suffix, function()
                     assert.are_equal(rounds, stats.rounds)
                     assert.are_equal(stats.count, stats.rounds * stats.iterations)
                     assert.is_true(stats.rounds * stats.iterations <= calls)
                  end)
               end
            end
         end
      end)

      -- ----------------------------------------------------------------------------
      -- timeit tests
      -- ----------------------------------------------------------------------------

      describe("timeit", function()
         local calls = 0
         local max_sleep_time = SLEEP_TIME * 2
         local counter = function()
            calls = calls + 1
            local sleep_time = calls == 1 and max_sleep_time or SLEEP_TIME
            socket.sleep(sleep_time)
         end

         local rounds = 100

         local stats = luamark.timeit(counter, rounds, 1, 0)

         test("min", function()
            assert.is_near(SLEEP_TIME, stats.min, TIME_TOL)
         end)

         test("max", function()
            assert.is_near(max_sleep_time, stats.max, TIME_TOL * 2)
         end)

         test("mean", function()
            assert.near(SLEEP_TIME, stats.mean, TIME_TOL)
         end)

         test("median", function()
            assert.near(SLEEP_TIME, stats.median, TIME_TOL)
         end)
      end)

      -- ----------------------------------------------------------------------------
      -- memit tests
      -- ----------------------------------------------------------------------------
      -- For unkown reasons, memory calls are not deterministic on 5.2 and 5.3

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
            local all_stats = luamark.memit(funcs, rounds, 1, 0)

            for func_name, stats in pairs(all_stats) do
               local single_call_memory = luamark.measure_memory(funcs[func_name])

               local rounds = 10

               local total = single_call_memory * stats.count
               test("total", function()
                  assert.near(total, stats.total, MEMORY_TOL * 2)
               end)

               test("mean", function()
                  assert.near(single_call_memory, stats.mean, MEMORY_TOL)
               end)

               test("median", function()
                  assert.near(single_call_memory, stats.median, MEMORY_TOL)
               end)
            end
         end)
      end

      -- ----------------------------------------------------------------------------
      -- Rank
      -- ----------------------------------------------------------------------------

      describe("rank", function()
         test("unique values", function()
            local data = {
               ["test1"] = { mean = 8 },
               ["test2"] = { mean = 20 },
               ["test3"] = { mean = 5 },
               ["test4"] = { mean = 12 },
            }
            luamark.rank(data, "mean")
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
            luamark.rank(data, "mean")

            assert.are.equal(1, data["test1"].rank)
            assert.are.equal(1, data["test2"].rank)
            assert.are.equal(1, data["test3"].rank)

            assert.are.equal(1.0, data["test1"].ratio)
            assert.are.equal(1.0, data["test2"].ratio)
            assert.are.equal(1.0, data["test3"].ratio)
         end)

         test("keys", function()
            local data = {
               ["test1"] = { mean = 10, median = 18 },
               ["test2"] = { mean = 20, median = 8 },
            }
            luamark.rank(data, "mean")
            assert.are.same({ rank = 1, mean = 10, median = 18, ratio = 1 }, data["test1"])
            assert.are.same({ rank = 2, mean = 20, median = 8, ratio = 2 }, data["test2"])

            luamark.rank(data, "median")
            assert.are.same({ rank = 1, mean = 20, median = 8, ratio = 1.0 }, data["test2"])
            assert.are.same({ rank = 2, mean = 10, median = 18, ratio = 2.25 }, data["test1"])
         end)

         test("error", function()
            assert.has.errors(function()
               benchmark(function()
                  luamark.rank({}, "foo")
               end, -1)
            end)
            assert.has.errors(function()
               benchmark(function()
                  ---@diagnostic disable-next-line: param-type-mismatch
                  luamark.rank(nil, "bar")
               end, -1)
            end)
         end)
      end)
   end)
end
