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

      -- Headers present
      assert.matches("Name", output)
      assert.matches("Rank", output)
      assert.matches("Median", output)
      -- Hidden columns stay hidden
      assert.not_matches("Rounds", output)
      -- Factor formatting
      assert.matches("fast.*1x", output)
      assert.matches("slow.*↓3x", output)
   end)

   test("short=true shows only bar chart without headers", function()
      local results = { h.make_result_row("test", 100, 1, 1) }
      local output = luamark.render(results, true)

      assert.not_matches("Name", output)
      assert.matches("test.*█", output)
   end)

   test("truncates long names to fit terminal width", function()
      local long_name =
         "very_long_function_name_that_should_definitely_be_truncated_to_fit_the_terminal_width_limit"
      local results = { h.make_result_row(long_name, 100, 1, 1) }

      local max_width = luamark._internal.DEFAULT_TERM_WIDTH
      local output = luamark.render(results, false, max_width)
      assert.matches("%.%.%.", output)
   end)

   test("ops column shows in time benchmarks, hidden in memory", function()
      local time_results = { h.make_result_row("fast", 0.001, 1, 1) }
      local mem_results = { h.make_result_row("test", 1.0, 1, 1, { unit = "kb" }) }

      local time_output = luamark.render(time_results)
      assert.matches("Ops", time_output)
      assert.matches("fast.*%d+[kMG]?/s", time_output)

      local mem_output = luamark.render(mem_results)
      assert.not_matches("Ops", mem_output)
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

   test("humanize_time handles scale and sub-unit rounding", function()
      assert.are_equal("5ns", luamark.humanize_time(5 / 1e9))
      assert.are_equal("0ns", luamark.humanize_time(0.5 / 1e9))
   end)

   test("humanize_memory handles scale and sub-unit rounding", function()
      local tb, gb = 1024 ^ 3, 1024 ^ 2
      assert.are_equal("2TB", luamark.humanize_memory(tb + 512 * gb))
      assert.are_equal("0B", luamark.humanize_memory(0.25 / 1024))
   end)

   test("margin hidden when zero, shown when non-zero", function()
      local zero_margin =
         luamark.render({ h.make_result_row("a", 100e-9, 1, 1, { ci_margin = 0 }) })
      assert.not_matches("±", zero_margin)

      local with_margin =
         luamark.render({ h.make_result_row("b", 100e-9, 1, 1, { ci_margin = 10e-9 }) })
      assert.matches("100ns ± 10ns", with_margin)
   end)

   test("renders compare_time results", function()
      local results = luamark.compare_time({ test = h.noop }, { rounds = 10 })
      local output = luamark.render(results)

      assert.matches("test", output)
      assert.matches("1x", output)
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

   test("renders single Stats in key-value format", function()
      -- Time stats include ops
      local time_stats = h.make_stats(250e-9)
      local time_output = luamark.render(time_stats)
      assert.matches("Median: 250ns", time_output)
      assert.matches("CI:", time_output)
      assert.matches("Ops:", time_output)
      assert.matches("Rounds: 100", time_output)
      assert.matches("Total:", time_output)

      -- Memory stats exclude ops
      local mem_stats = h.make_stats(2, { unit = "kb" })
      local mem_output = luamark.render(mem_stats)
      assert.matches("Median: 2kB", mem_output)
      assert.not_matches("Ops:", mem_output)

      -- short/max_width args ignored for single Stats
      assert.are_equal(time_output, luamark.render(time_stats, true))
      assert.are_equal(time_output, luamark.render(time_stats, false, 40))
   end)

   test("renders real timeit Stats", function()
      local stats = luamark.timeit(h.noop, { rounds = 10 })
      local output = luamark.render(stats)

      assert.matches("Median:", output)
      assert.matches("CI:", output)
      assert.matches("Ops:", output)
      assert.matches("Rounds: 10", output)
      assert.matches("Total:", output)
   end)

   test("groups mixed time and memory results by unit", function()
      local results = {
         h.make_result_row("time_fn", 0.001, 1, 1),
         h.make_result_row("mem_fn", 1.0, 1, 1, { unit = "kb" }),
      }
      local output = luamark.render(results)

      -- Headers in correct order: Time before Memory
      local time_pos = output:find("Time")
      local mem_pos = output:find("Memory")
      assert.is_truthy(time_pos)
      assert.is_truthy(mem_pos)
      assert.is_true(time_pos < mem_pos)

      -- Ops only in Time section (before Memory header)
      local ops_pos = output:find("Ops")
      assert.is_truthy(ops_pos)
      assert.is_true(ops_pos < mem_pos)
   end)

   test("mixed results with params groups by unit then params", function()
      local results = {
         h.make_result_row("fn", 0.001, 1, 1, { params = { n = 10 } }),
         h.make_result_row("fn", 0.002, 2, 2, { params = { n = 20 } }),
         h.make_result_row("fn", 1.0, 1, 1, { unit = "kb", params = { n = 10 } }),
         h.make_result_row("fn", 2.0, 2, 2, { unit = "kb", params = { n = 20 } }),
      }
      local output = luamark.render(results)

      -- Unit headers present
      assert.matches("Time", output)
      assert.matches("Memory", output)

      -- Params appear in both unit sections
      local _, n10_count = output:gsub("n=10", "")
      local _, n20_count = output:gsub("n=20", "")
      assert.are_equal(2, n10_count)
      assert.are_equal(2, n20_count)
   end)

   test("single unit results do not show unit header", function()
      local results = { h.make_result_row("a", 0.001, 1, 1) }
      local output = luamark.render(results)

      assert.not_matches("^Time", output)
      assert.not_matches("^Memory", output)
   end)
end)
