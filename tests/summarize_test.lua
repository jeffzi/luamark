---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

--- Create a mock benchmark result row.
---@param name string
---@param median number
---@param rank_value integer
---@param ratio_value number
---@param opts? {params?: table, unit?: "s"|"kb", ci_lower?: number, ci_upper?: number, is_approximate?: boolean}
---@return table
local function make_row(name, median, rank_value, ratio_value, opts)
   opts = opts or {}
   local unit = opts.unit or "s"
   local ci_lower = opts.ci_lower or (median * 0.9)
   local ci_upper = opts.ci_upper or (median * 1.1)
   local stats = {
      median = median,
      ci_lower = ci_lower,
      ci_upper = ci_upper,
      ci_margin = (ci_upper - ci_lower) / 2,
      rounds = 10,
      iterations = 1000,
      unit = unit,
      rank = rank_value,
      ratio = ratio_value,
      is_approximate = opts.is_approximate or false,
   }
   if unit == "s" and median > 0 then
      stats.ops = 1 / median
   end
   return {
      name = name,
      params = opts.params or {},
      stats = stats,
   }
end

describe("summarize", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("rejects nil and empty input", function()
      assert.has_error(function()
         luamark.summarize({})
      end, "'results' is nil or empty.")
      assert.has_error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         luamark.summarize(nil)
      end, "'results' is nil or empty.")
   end)

   test("rejects invalid format", function()
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
      assert.matches("fast.*█", output)
   end)

   test("truncates long names to fit terminal width", function()
      local long_name =
         "very_long_function_name_that_should_definitely_be_truncated_to_fit_the_terminal_width_limit"
      local results = {
         make_row(long_name, 100, 1, 1),
         make_row("short", 500, 2, 5),
      }

      local max_width = luamark._internal.DEFAULT_TERM_WIDTH
      local output = luamark.summarize(results, "plain", max_width)
      assert.matches("%.%.%.", output)
   end)

   test("csv format outputs comma-separated values with escaping", function()
      local results = {
         make_row("fast", 0.001, 1, 1),
         make_row("has,comma", 0.002, 2, 2),
         make_row('has"quote', 0.003, 3, 3),
      }
      local output = luamark.summarize(results, "csv")

      assert.matches("name,rank,ratio,median,ci_low,ci_high,ops,iters", output)
      assert.matches("fast,1,", output)
      assert.matches('"has,comma"', output)
      assert.matches('"has""quote"', output)
   end)

   test("ops column shows in time benchmarks, empty in memory", function()
      local time_results = { make_row("fast", 0.001, 1, 1) }
      local mem_results = { make_row("test", 1.0, 1, 1, { unit = "kb" }) }

      local time_output = luamark.summarize(time_results, "plain")
      assert.matches("Ops", time_output)
      assert.matches("1000/s", time_output)

      local mem_output = luamark.summarize(mem_results, "csv")
      assert.matches(",,", mem_output)
   end)

   test("plain format includes CI columns", function()
      local results = { make_row("test", 0.001, 1, 1) }
      local output = luamark.summarize(results, "plain")
      assert.matches("CI Low", output)
      assert.matches("CI High", output)
      assert.matches("Median", output)
   end)

   test("iters column shows combined rounds x iterations format", function()
      local results = { make_row("test", 0.001, 1, 1) }
      local output = luamark.summarize(results, "plain")
      assert.matches("Iters", output)
      assert.matches("10 × 1k", output)
   end)

   test("approximate rank indicator appears when CIs overlap", function()
      local results = {
         make_row("fast", 0.001, 1, 1.0, { is_approximate = true }),
         make_row("medium", 0.0011, 1, 1.1, { is_approximate = true }),
         make_row("slow", 0.002, 3, 2.0),
      }
      local output = luamark.summarize(results, "plain")
      -- Both fast and medium should show ≈1
      assert.matches("≈1", output)
      -- slow should show 3 without ≈
      assert.matches("%s3%s", output)
      assert.not_matches("≈3", output)
   end)
end)

describe("humanize", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("humanize_time handles scale and rounds sub-nanosecond to zero", function()
      assert.are_equal("5ns", luamark.humanize_time(5 / 1e9))
      assert.are_equal("0ns", luamark.humanize_time(0.5 / 1e9))
   end)

   test("humanize_memory handles scale and rounds sub-byte to zero", function()
      local tb, gb = 1024 ^ 3, 1024 ^ 2
      assert.are_equal("1.5TB", luamark.humanize_memory(tb + 512 * gb))
      assert.are_equal("0B", luamark.humanize_memory(0.25 / 1024))
   end)
end)

describe("stats_tostring", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("shows median ± margin format", function()
      local stats = luamark.timeit(h.noop, { rounds = 10 })
      local str = tostring(stats)
      assert.matches("±", str)
      assert.matches("[0-9%.]+[a-zA-Z]+ ± [0-9%.]+[a-zA-Z]+", str)
   end)
end)

describe("summarize with benchmark results", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("summarizes compare_time results", function()
      local results = luamark.compare_time({ test = h.noop }, { rounds = 1 })
      local output = luamark.summarize(results, "plain")
      assert.matches("test", output)
      assert.matches("1%.00x", output)
   end)

   test("summarizes results with params", function()
      local results = luamark.compare_time({ test = h.noop }, {
         params = { n = { 10, 20 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "plain")
      assert.matches("n=10", output)
      assert.matches("n=20", output)
   end)

   test("csv includes param columns", function()
      local results = luamark.compare_time({ test = h.noop }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      local output = luamark.summarize(results, "csv")
      assert.matches("name,n,", output)
      assert.matches("test,10,", output)
   end)

   test("all formats work with params", function()
      local results = luamark.compare_time({ a = h.noop }, {
         params = { n = { 10 } },
         rounds = 1,
      })

      for _, fmt in ipairs({ "plain", "compact", "markdown" }) do
         local output = luamark.summarize(results, fmt)
         assert.matches("n=10", output)
      end
   end)

   test("stats have CI fields after benchmarking", function()
      local results = luamark.compare_time({ test = h.noop }, { rounds = 10 })
      local stats = results[1].stats
      assert.is_number(stats.ci_lower)
      assert.is_number(stats.ci_upper)
      assert.is_number(stats.ci_margin)
      assert.is_true(stats.ci_lower <= stats.median)
      assert.is_true(stats.ci_upper >= stats.median)
   end)

   test("rank and is_approximate are set for comparison results", function()
      local results = luamark.compare_time({
         fast = h.noop,
         slow = function()
            local x = 0
            for _ = 1, 1000 do
               x = x + 1
            end
         end,
      }, { rounds = 5 })

      for i = 1, #results do
         assert.is_number(results[i].stats.rank)
         assert.is_boolean(results[i].stats.is_approximate)
      end
   end)
end)
