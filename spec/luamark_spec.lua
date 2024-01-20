---@diagnostic disable: undefined-field, unused-local
local luamark = require("../src/luamark")
local socket = require("socket")

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local SLEEP_TIME = 0.001
local TIME_TOL = 0.001
local MEMORY_TOL = 0.0001
local ROUNDS_CASES = { nil, 2, 3 }

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

describe("luamark", function()
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
            local noop = function() end
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
      for i = 1, #ROUNDS_CASES do
         local calls = 0

         local counter = function()
            calls = calls + 1
            return socket.sleep(SLEEP_TIME * calls)
         end

         local rounds = ROUNDS_CASES[i]
         local suffix = string.format(" (%s rounds)", rounds or "nil")

         local stats = luamark.timeit(counter, rounds, 1, 0)

         test("min" .. suffix, function()
            assert.is_near(SLEEP_TIME, stats.min, TIME_TOL)
         end)
         test("max" .. suffix, function()
            assert.is_near(SLEEP_TIME * calls, stats.max, TIME_TOL * calls)
         end)

         local total = SLEEP_TIME * calls * (calls + 1) / 2
         test("total" .. suffix, function()
            assert.near(total, stats.total, TIME_TOL * calls)
         end)

         local mean = total / calls
         test("mean" .. suffix, function()
            assert.near(mean, stats.mean, TIME_TOL)
            -- assert.is_near(mean, stats.mean, 0.005)
         end)

         test("median" .. suffix, function()
            local stats = luamark.timeit(function()
               socket.sleep(SLEEP_TIME)
            end)
            assert.near(SLEEP_TIME, stats.median, TIME_TOL)
            assert.near(0, stats.stddev, TIME_TOL)
         end)
      end
   end)

   -- ----------------------------------------------------------------------------
   -- memit tests
   -- ----------------------------------------------------------------------------

   describe("memit", function()
      for i = 1, #ROUNDS_CASES do
         local funcs = {
            noop = noop,
            empty_table = function()
               local t = {}
            end,
            complex = function()
               local i = 1
               local t = { 1, 2, 3 }
               local s = "luamark"
            end,
         }
         local all_stats = luamark.memit(funcs, rounds, 1, 0)

         for func_name, stats in pairs(all_stats) do
            local single_call_memory = luamark.measure_memory(funcs[func_name])

            local rounds = ROUNDS_CASES[i]
            local suffix = string.format(" (%s %s rounds)", func_name, rounds or "nil")

            local total = single_call_memory * stats.count
            test("total" .. suffix, function()
               assert.near(total, stats.total, MEMORY_TOL * 2)
            end)

            test("mean" .. suffix, function()
               assert.near(single_call_memory, stats.mean, MEMORY_TOL)
            end)

            test("median" .. suffix, function()
               assert.near(single_call_memory, stats.median, MEMORY_TOL)
            end)
         end
      end
   end)
end)
