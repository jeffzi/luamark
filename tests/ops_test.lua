---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

--- Create a mock benchmark result row with stats derived from median.
---@param name string
---@param median number
---@param rank_value integer
---@param ratio_value number
---@param unit "s"|"kb"
---@return table
local function make_row(name, median, rank_value, ratio_value, unit)
   local stats = {
      median = median,
      mean = median,
      min = median * 0.9,
      max = median * 1.1,
      stddev = median * 0.05,
      rounds = 10,
      unit = unit,
      rank = rank_value,
      ratio = ratio_value,
   }
   if unit == "s" and median > 0 then
      stats.ops = 1 / median
   end
   return {
      name = name,
      params = {},
      stats = stats,
   }
end

describe("ops field", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   describe("calculation", function()
      test("timeit calculates ops as 1/mean", function()
         local stats = luamark.timeit(function()
            for i = 1, 100 do
               local _ = i
            end
         end, { rounds = 10 })

         assert.is_number(stats.ops)
         assert.is_near(1 / stats.mean, stats.ops, 1e-10)
      end)

      test("memit does not include ops field", function()
         local stats = luamark.memit(function()
            local t = {}
            for i = 1, 10 do
               t[i] = i
            end
         end, { rounds = 10 })

         assert.is_nil(stats.ops)
      end)

      test("compare_time results include ops", function()
         local results = luamark.compare_time({
            test = function()
               for i = 1, 100 do
                  local _ = i
               end
            end,
         }, { rounds = 10 })

         assert.is_number(results[1].stats.ops)
         assert.is_near(1 / results[1].stats.mean, results[1].stats.ops, 1e-10)
      end)

      test("compare_memory results do not include ops", function()
         local results = luamark.compare_memory({
            test = function()
               local t = {}
               for i = 1, 10 do
                  t[i] = i
               end
            end,
         }, { rounds = 10 })

         assert.is_nil(results[1].stats.ops)
      end)
   end)

   describe("display", function()
      test("plain format shows Op/s column header", function()
         local results = {
            make_row("fast", 0.001, 1, 1, "s"),
         }
         local output = luamark.summarize(results, "plain")
         assert.matches("Op/s", output)
      end)

      test("plain format shows ops value with /s suffix", function()
         local results = {
            make_row("fast", 0.001, 1, 1, "s"), -- 1000 ops/s
         }
         local output = luamark.summarize(results, "plain")
         assert.matches("1000/s", output)
      end)

      test("markdown format shows Op/s column header", function()
         local results = {
            make_row("fast", 0.001, 1, 1, "s"),
         }
         local output = luamark.summarize(results, "markdown")
         assert.matches("Op/s", output)
      end)

      test("csv format includes ops column", function()
         local results = {
            make_row("fast", 0.001, 1, 1, "s"),
         }
         local output = luamark.summarize(results, "csv")
         assert.matches(",ops,", output)
         assert.matches(",1000/s,", output)
      end)

      test("memory benchmarks show empty ops column", function()
         local results = {
            make_row("test", 1.0, 1, 1, "kb"),
         }
         local output = luamark.summarize(results, "csv")
         assert.matches(",ops,", output)
         -- ops value should be empty for memory benchmarks
         local lines = {}
         for line in output:gmatch("[^\n]+") do
            lines[#lines + 1] = line
         end
         -- Second line is data row, ops should be empty
         local data_row = lines[2]
         -- Check that ops field is empty (consecutive commas or trailing comma before rounds)
         assert.matches(",,", data_row)
      end)
   end)
end)
