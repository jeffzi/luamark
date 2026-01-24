---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

--- Create a mock benchmark result row (flat structure).
---@param name string
---@param median number
---@param rank_value integer
---@param ratio_value number
---@param opts? {unit?: "s"|"kb", ci_lower?: number, ci_upper?: number, is_approximate?: boolean}
---@return table
local function make_row(name, median, rank_value, ratio_value, opts)
   opts = opts or {}
   local unit = opts.unit or "s"
   local ci_lower = opts.ci_lower or (median * 0.9)
   local ci_upper = opts.ci_upper or (median * 1.1)
   local row = {
      name = name,
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
      row.ops = 1 / median
   end
   return row
end

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
         make_row("fast", 0.001, 1, 1),
         make_row("slow", 0.003, 2, 3),
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
      assert.matches("fast.*█.*1%.00x", output)
      assert.matches("slow.*█.*3%.00x", output)
      assert.matches("10 × 1k", output)
      assert.matches("1k/s", output)
   end)

   test("short=true shows only bar chart without headers", function()
      local results = {
         make_row("fast", 100, 1, 1),
         make_row("slow", 300, 2, 3),
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
         make_row(long_name, 100, 1, 1),
         make_row("short", 500, 2, 5),
      }

      local max_width = luamark._internal.DEFAULT_TERM_WIDTH
      local output = luamark.render(results, false, max_width)
      assert.matches("%.%.%.", output)
   end)

   test("ops column shows in time benchmarks, empty in memory", function()
      local time_results = { make_row("fast", 0.001, 1, 1) }
      local mem_results = { make_row("test", 1.0, 1, 1, { unit = "kb" }) }

      local time_output = luamark.render(time_results)
      assert.matches("/s", time_output)

      local mem_output = luamark.render(mem_results)
      assert.not_matches("/s", mem_output)
   end)

   test("approximate rank indicator appears when CIs overlap", function()
      -- Complex scenario: 5 functions with 2 overlap groups and 1 distinct
      -- Group 1: alpha and bravo overlap (both rank 1)
      -- Group 2: charlie and delta overlap (both rank 3)
      -- Distinct: echo (rank 5)
      local results = {
         make_row("alpha", 0.001, 1, 1.0, { is_approximate = true }),
         make_row("bravo", 0.0011, 1, 1.1, { is_approximate = true }),
         make_row("charlie", 0.005, 3, 5.0, { is_approximate = true }),
         make_row("delta", 0.0055, 3, 5.5, { is_approximate = true }),
         make_row("echo", 0.010, 5, 10.0),
      }
      local output = luamark.render(results)

      -- Verify approximate ranks appear for overlapping groups
      assert.matches("≈1", output)
      assert.matches("≈3", output)
      -- Verify distinct rank appears without approximation
      assert.matches("%s5%s", output)
      assert.not_matches("≈5", output)
      -- Verify all function names appear
      assert.matches("alpha", output)
      assert.matches("bravo", output)
      assert.matches("charlie", output)
      assert.matches("delta", output)
      assert.matches("echo", output)
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

   test("renders compare_time results with CI and ranking fields", function()
      local results = luamark.compare_time({ test = h.noop }, { rounds = 10 })
      local result = results[1]

      -- Rendering works
      local output = luamark.render(results)
      assert.matches("test", output)
      assert.matches("1%.00x", output)

      -- CI fields populated
      assert.is_number(result.ci_lower)
      assert.is_number(result.ci_upper)
      assert.is_number(result.ci_margin)
      assert.is_true(result.ci_lower <= result.median)
      assert.is_true(result.ci_upper >= result.median)

      -- Ranking fields populated
      assert.is_number(result.rank)
      assert.is_boolean(result.is_approximate)
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
