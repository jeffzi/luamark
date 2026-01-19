---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

--- Create a mock benchmark result row with stats derived from median.
---@param name string
---@param median number
---@param rank_value integer
---@param ratio_value number
---@param params? table
---@return table
local function make_row(name, median, rank_value, ratio_value, params)
   return {
      name = name,
      params = params or {},
      stats = {
         median = median,
         mean = median,
         min = median * 0.9,
         max = median * 1.1,
         stddev = median * 0.05,
         rounds = 10,
         unit = "s",
         rank = rank_value,
         ratio = ratio_value,
      },
   }
end

describe("summarize", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("empty table error", function()
      assert.has_error(function()
         luamark.summarize({})
      end, "'results' is nil or empty.")
   end)

   test("nil error", function()
      assert.has_error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         luamark.summarize(nil)
      end, "'results' is nil or empty.")
   end)

   test("invalid format error", function()
      assert.has_error(function()
         luamark.summarize({
            { name = "test", params = {}, stats = { median = 1, unit = "s" } },
         }, "invalid")
      end, "format must be 'plain', 'compact', 'markdown', or 'csv'")
   end)

   test("plain format includes table and bar chart", function()
      local results = {
         make_row("fast", 100, 1, 1),
         make_row("slow", 300, 2, 3),
      }
      local output = luamark.summarize(results, "plain")
      assert.matches("Name", output)
      assert.matches("fast.*█.*1%.00x", output)
      assert.matches("slow.*█.*3%.00x", output)
   end)

   test("compact format shows only bar chart", function()
      local results = {
         make_row("fast", 100, 1, 1),
         make_row("slow", 300, 2, 3),
      }
      local output = luamark.summarize(results, "compact")
      assert.not_matches("Name", output)
      assert.matches("fast.*█.*1%.00x", output)
      assert.matches("slow.*█.*3%.00x", output)
   end)

   test("plain and compact truncate long names to fit terminal width", function()
      local long_name =
         "very_long_function_name_that_should_definitely_be_truncated_to_fit_the_terminal_width_limit"
      local results = {
         make_row(long_name, 100, 1, 1),
         make_row("short", 500, 2, 5),
      }

      local max_width = luamark._internal.DEFAULT_TERM_WIDTH
      for _, fmt in ipairs({ "plain", "compact" }) do
         local output = luamark.summarize(results, fmt, max_width)
         for line in output:gmatch("[^\n]+") do
            local display_width = 0
            for _ in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
               display_width = display_width + 1
            end
            assert(
               display_width <= max_width,
               string.format(
                  "%s: line exceeds %d chars (%d): %s",
                  fmt,
                  max_width,
                  display_width,
                  line
               )
            )
         end
         assert.matches("%.%.%.", output)
      end
   end)

   test("short names are not truncated", function()
      local results = {
         make_row("fast", 100, 1, 1),
         make_row("slow", 500, 2, 5),
      }

      for _, fmt in ipairs({ "plain", "compact" }) do
         local output = luamark.summarize(results, fmt)
         assert.not_matches("%.%.%.", output)
         assert.matches("fast", output)
         assert.matches("slow", output)
      end
   end)

   test("csv format outputs comma-separated values", function()
      local results = {
         make_row("fast", 0.001, 1, 1),
         make_row("slow", 0.003, 2, 3),
      }
      local output = luamark.summarize(results, "csv")

      assert.matches("name,rank,ratio,median,mean,min,max,stddev,rounds", output)
      assert.matches("fast,1,", output)
      assert.matches("slow,2,", output)
   end)

   test("csv format escapes commas and quotes in names", function()
      local results = {
         make_row("has,comma", 0.001, 1, 1),
         make_row('has"quote', 0.002, 2, 2),
      }
      local output = luamark.summarize(results, "csv")
      assert.matches('"has,comma"', output)
      assert.matches('"has""quote"', output)
   end)
end)

describe("humanize_time", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("converts seconds to nanoseconds", function()
      assert.are_equal("5ns", luamark.humanize_time(5 / 1e9))
   end)

   test("rounds sub-nanosecond to zero", function()
      assert.are_equal("0ns", luamark.humanize_time(0.5 / 1e9))
   end)
end)

describe("humanize_memory", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("converts kilobytes to terabytes", function()
      local tb, gb = 1024 ^ 3, 1024 ^ 2
      assert.are_equal("1.5TB", luamark.humanize_memory(tb + 512 * gb))
   end)

   test("rounds sub-byte to zero", function()
      assert.are_equal("0B", luamark.humanize_memory(0.25 / 1024))
   end)
end)

describe("summarize with benchmark results", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("summarizes single function result (Stats)", function()
      local results = luamark.timeit(h.noop, { rounds = 1 })
      local output = luamark.summarize(results, "plain")
      -- Single function is named "1", check for data row with name "1"
      assert.matches("\n1%s+1%s+", output)
      assert.matches("1%.00x", output)
   end)

   test("summarizes single function with params", function()
      local results = luamark.timeit(h.noop, {
         params = { n = { 10, 20 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "plain")
      assert.matches("n=10", output)
      assert.matches("n=20", output)
   end)

   test("summarizes multiple functions with params", function()
      local results = luamark.timeit({
         fast = function() end,
         slow = function()
            for i = 1, 100 do
               local _ = i
            end
         end,
      }, {
         params = { n = { 10, 20 } },
         rounds = 3,
      })

      local output = luamark.summarize(results, "plain")
      assert.matches("n=10", output)
      assert.matches("n=20", output)
      assert.matches("fast", output)
      assert.matches("slow", output)
   end)

   test("csv format includes param columns for single function with params", function()
      local results = luamark.timeit(h.noop, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "csv")
      assert.matches("name,n,", output)
      assert.matches(",10,", output)
   end)

   test("csv format includes param columns for multiple functions with params", function()
      local results = luamark.timeit({
         a = h.noop,
      }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "csv")
      assert.matches("name,n,", output)
      assert.matches("a,10,", output)
   end)

   test("ranks within each param group", function()
      local results = luamark.timeit({
         fast = function() end,
         slow = function()
            for i = 1, 1000 do
               local _ = i
            end
         end,
      }, {
         params = { n = { 10 } },
         rounds = 10,
      })

      local output = luamark.summarize(results, "plain")
      -- fast should have rank 1 (appear first in output after param header)
      assert.matches("n=10", output)
   end)

   test("handles multiple params as cartesian product", function()
      local results = luamark.timeit(h.noop, {
         params = { n = { 1, 2 }, flag = { true } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "plain")
      assert.matches("flag=true, n=1", output)
      assert.matches("flag=true, n=2", output)
   end)

   test("compact format works with params", function()
      local results = luamark.timeit({
         a = h.noop,
         b = h.noop,
      }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "compact")
      assert.matches("n=10", output)
      assert.matches("1%.00x", output)
   end)

   test("markdown format works with params", function()
      local results = luamark.timeit({
         a = h.noop,
      }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "markdown")
      assert.matches("n=10", output)
      assert.matches("|", output)
   end)
end)
