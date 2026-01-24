---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

describe("render", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("rejects nil and empty input", function()
      assert.has_error(function()
         luamark.render({})
      end, "'results' is nil or empty.")
      assert.has_error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         luamark.render(nil)
      end, "'results' is nil or empty.")
   end)

   test("full table includes all columns with bar chart", function()
      local results = {
         h.make_result_row("fast", 0.001, 1, 1),
         h.make_result_row("slow", 0.003, 2, 3),
      }
      local output = luamark.render(results)

      -- Headers
      assert.matches("Name", output)
      assert.matches("Rank", output)
      assert.matches("Ratio", output)
      assert.matches("Median", output)
      assert.matches("CI Low", output)
      assert.matches("CI High", output)
      assert.matches("Ops", output)
      assert.matches("Iters", output)

      -- Values and bar chart
      assert.matches("fast.*1%.00x", output)
      assert.matches("slow.*3%.00x", output)
      assert.matches("10 × 1k", output)
      assert.matches("1k/s", output)
   end)

   test("short=true shows only bar chart without headers", function()
      local results = {
         h.make_result_row("fast", 100, 1, 1),
         h.make_result_row("slow", 300, 2, 3),
      }
      local output = luamark.render(results, true)

      assert.not_matches("Name", output)
      assert.matches("fast.*█", output)
      assert.matches("slow.*█", output)
   end)

   test("truncates long names to fit terminal width", function()
      local long_name =
         "very_long_function_name_that_should_definitely_be_truncated_to_fit_the_terminal_width_limit"
      local results = {
         h.make_result_row(long_name, 100, 1, 1),
         h.make_result_row("short", 500, 2, 5),
      }

      local max_width = luamark._internal.DEFAULT_TERM_WIDTH
      local output = luamark.render(results, false, max_width)
      assert.matches("%.%.%.", output)
   end)

   test("ops column shows in time benchmarks, empty in memory", function()
      local time_results = { h.make_result_row("fast", 0.001, 1, 1) }
      local mem_results = { h.make_result_row("test", 1.0, 1, 1, { unit = "kb" }) }

      local time_output = luamark.render(time_results)
      assert.matches("fast.*%d+[kMG]?/s", time_output)

      local mem_output = luamark.render(mem_results)
      assert.not_matches("/s", mem_output)
   end)

   test("approximate rank indicator appears when is_approximate=true", function()
      local results = {
         h.make_result_row("approx", 0.001, 1, 1.0, { is_approximate = true }),
         h.make_result_row("exact", 0.002, 2, 2.0),
      }
      local output = luamark.render(results)

      assert.matches("≈1", output)
      assert.not_matches("≈2", output)
   end)

   test("humanize_time and humanize_memory handle scale and sub-unit rounding", function()
      -- Time: nanoseconds and sub-nanosecond
      assert.are_equal("5ns", luamark.humanize_time(5 / 1e9))
      assert.are_equal("0ns", luamark.humanize_time(0.5 / 1e9))

      -- Memory: terabytes and sub-byte
      local tb, gb = 1024 ^ 3, 1024 ^ 2
      assert.are_equal("1.5TB", luamark.humanize_memory(tb + 512 * gb))
      assert.are_equal("0B", luamark.humanize_memory(0.25 / 1024))
   end)

   test("stats __tostring shows median ± margin format", function()
      local stats = luamark.timeit(h.noop, { rounds = 10 })
      local str = tostring(stats)

      assert.matches("±", str)
      assert.matches("[0-9%.]+[a-zA-Z]+ ± [0-9%.]+[a-zA-Z]+", str)
   end)

   test("renders compare_time results", function()
      local results = luamark.compare_time({ test = h.noop }, { rounds = 10 })
      local output = luamark.render(results)

      assert.matches("test", output)
      assert.matches("1%.00x", output)
   end)

   test("renders results with params in both formats", function()
      local results = luamark.compare_time({ test = h.noop }, {
         params = { n = { 10, 20 } },
         rounds = 1,
      })

      -- Full table
      local full_output = luamark.render(results, false)
      assert.matches("n=10", full_output)
      assert.matches("n=20", full_output)

      -- Bar chart
      local short_output = luamark.render(results, true)
      assert.matches("n=10", short_output)
      assert.matches("n=20", short_output)
   end)
end)
