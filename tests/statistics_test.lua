---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

describe("calculate_stats", function()
   local calculate_stats

   setup(function()
      calculate_stats = h.load_luamark()._internal.calculate_stats
   end)

   -- For samples < 3, CI collapses to median with margin 0 (deterministic)
   -- For samples >= 3, CI is computed via bootstrap (stochastic, test bounds only)
   local cases = {
      {
         name = "single sample",
         samples = { 42 },
         median = 42,
         ci_lower = 42,
         ci_upper = 42,
         ci_margin = 0,
      },
      {
         name = "two samples",
         samples = { 5, 10 },
         median = 7.5,
         ci_lower = 7.5,
         ci_upper = 7.5,
         ci_margin = 0,
      },
      {
         name = "ten samples (bootstrap CI)",
         samples = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
         median = 5.5,
         ci_lower_min = 1,
         ci_upper_max = 10,
      },
      {
         name = "odd sample count",
         samples = { 1, 2, 3, 4, 5 },
         median = 3,
         ci_lower_min = 1,
         ci_upper_max = 5,
      },
   }

   for _, case in ipairs(cases) do
      test(case.name, function()
         local stats = calculate_stats(case.samples)
         assert.are_equal(case.median, stats.median)

         if case.ci_lower then
            -- Deterministic CI (small samples)
            assert.are_equal(case.ci_lower, stats.ci_lower)
            assert.are_equal(case.ci_upper, stats.ci_upper)
            assert.are_equal(case.ci_margin, stats.ci_margin)
         else
            -- Stochastic CI (bootstrap) - test bounds and relationships
            assert.is_true(stats.ci_lower >= case.ci_lower_min)
            assert.is_true(stats.ci_upper <= case.ci_upper_max)
            assert.is_true(stats.ci_lower <= stats.median)
            assert.is_true(stats.ci_upper >= stats.median)
            assert.are_equal((stats.ci_upper - stats.ci_lower) / 2, stats.ci_margin)
         end
      end)
   end
end)

describe("math_median", function()
   local math_median

   setup(function()
      math_median = h.load_luamark()._internal.math_median
   end)

   local cases = {
      { name = "odd-length array", input = { 1, 3, 5 }, expected = 3 },
      { name = "even-length array", input = { 1, 2, 3, 4 }, expected = 2.5 },
   }
   for _, case in ipairs(cases) do
      test(case.name, function()
         assert.are_equal(case.expected, math_median(case.input))
      end)
   end
end)

describe("bootstrap_ci", function()
   local bootstrap_ci

   setup(function()
      bootstrap_ci = h.load_luamark()._internal.bootstrap_ci
   end)

   test("returns lower and upper bounds", function()
      local samples = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
      local lower, upper = bootstrap_ci(samples, 1000)
      -- 95% CI should bracket the true median (5.5) with reasonable margins
      assert.is_true(lower >= 1 and lower <= 5.5)
      assert.is_true(upper >= 5.5 and upper <= 10)
      assert.is_true(lower < upper)
   end)

   test("CI width decreases with more samples", function()
      local small_samples = {}
      local large_samples = {}
      for i = 1, 10 do
         small_samples[i] = i
      end
      for i = 1, 100 do
         large_samples[i] = (i % 10) + 1
      end

      local small_lower, small_upper = bootstrap_ci(small_samples, 1000)
      local large_lower, large_upper = bootstrap_ci(large_samples, 1000)

      local width_small = small_upper - small_lower
      local width_large = large_upper - large_lower
      assert.is_true(width_large <= width_small)
   end)
end)

describe("rank_results", function()
   local rank_results

   setup(function()
      rank_results = h.load_luamark()._internal.rank_results
   end)

   --- Create mock benchmark row with specific CI (flat structure).
   ---@param name string
   ---@param median number
   ---@param ci_lower number
   ---@param ci_upper number
   ---@return table
   local function make_row(name, median, ci_lower, ci_upper)
      return {
         name = name,
         median = median,
         ci_lower = ci_lower,
         ci_upper = ci_upper,
      }
   end

   --- Extract rank strings from results (assumes results are sorted by median).
   ---@param results table[]
   ---@return string[]
   local function get_rank_strings(results)
      local ranks = {}
      for i = 1, #results do
         local r = results[i]
         ranks[i] = r.is_approximate and ("≈" .. r.rank) or tostring(r.rank)
      end
      return ranks
   end

   local overlap_cases = {
      {
         name = "no overlap: all distinct ranks",
         rows = {
            { "a", 1.5, 1, 2 },
            { "b", 5.5, 5, 6 },
            { "c", 10.5, 10, 11 },
            { "d", 20.5, 20, 21 },
         },
         expected = { "1", "2", "3", "4" },
      },
      {
         name = "middle overlap: ranks 2 and 3 tied",
         rows = {
            { "a", 1.5, 1, 2 },
            { "b", 6.5, 5, 8 },
            { "c", 7.5, 6, 9 },
            { "d", 20.5, 20, 21 },
         },
         expected = { "1", "≈2", "≈2", "4" },
      },
      {
         name = "top overlap: ranks 1 and 2 tied",
         rows = {
            { "a", 2.5, 1, 4 },
            { "b", 3.5, 2, 5 },
            { "c", 10.5, 10, 11 },
            { "d", 20.5, 20, 21 },
         },
         expected = { "≈1", "≈1", "3", "4" },
      },
      {
         name = "chain overlap: transitive grouping",
         rows = {
            { "a", 1.5, 1, 2 },
            { "b", 6.5, 5, 8 },
            { "c", 8.5, 7, 10 },
            { "d", 10.5, 9, 12 },
         },
         expected = { "1", "≈2", "≈2", "≈2" },
      },
      {
         name = "two groups: separate overlap groups",
         rows = { { "a", 2.5, 1, 4 }, { "b", 3.5, 2, 5 }, { "c", 12, 10, 14 }, { "d", 13, 11, 15 } },
         expected = { "≈1", "≈1", "≈3", "≈3" },
      },
      {
         name = "all overlap: everyone shares rank 1",
         rows = {
            { "a", 5.5, 1, 10 },
            { "b", 6.5, 2, 11 },
            { "c", 7.5, 3, 12 },
            { "d", 8.5, 4, 13 },
         },
         expected = { "≈1", "≈1", "≈1", "≈1" },
      },
   }

   for _, case in ipairs(overlap_cases) do
      test(case.name, function()
         local results = {}
         for i, row in ipairs(case.rows) do
            results[i] = make_row(row[1], row[2], row[3], row[4])
         end
         rank_results(results, {}) -- empty param_names for no params
         assert.are_same(case.expected, get_rank_strings(results))
      end)
   end

   test("single result: no approximation", function()
      local results = { make_row("a", 5, 4, 6) }
      rank_results(results, {})
      assert.are_equal(1, results[1].rank)
      assert.is_false(results[1].is_approximate)
   end)

   test("relative calculated from position ordering", function()
      local results = { make_row("a", 10, 9, 11), make_row("b", 30, 29, 31) }
      rank_results(results, {})
      assert.are_equal(1, results[1].relative)
      assert.are_equal(3, results[2].relative)
   end)

   test("baseline function is used for relative calculation", function()
      local results = {
         make_row("fast", 10, 9, 11),
         make_row("baseline", 20, 19, 21),
         make_row("slow", 40, 39, 41),
      }
      results[2].baseline = true
      rank_results(results, {})
      -- Ratios relative to baseline (median=20), not fastest (median=10)
      assert.are_equal(0.5, results[1].relative) -- fast: 10/20 = 0.5
      assert.are_equal(1, results[2].relative) -- baseline: 20/20 = 1
      assert.are_equal(2, results[3].relative) -- slow: 40/20 = 2
   end)

   test("fallback to fastest when no baseline specified", function()
      local results = {
         make_row("fast", 10, 9, 11),
         make_row("slow", 30, 29, 31),
      }
      rank_results(results, {})
      -- Ratios relative to fastest (median=10)
      assert.are_equal(1, results[1].relative)
      assert.are_equal(3, results[2].relative)
   end)

   test("error when multiple baselines in same group", function()
      local results = {
         make_row("a", 10, 9, 11),
         make_row("b", 20, 19, 21),
      }
      results[1].baseline = true
      results[2].baseline = true
      assert.has_error(function()
         rank_results(results, {})
      end, "multiple baselines in group: ")
   end)
end)

describe("humanize with count unit", function()
   local humanize

   setup(function()
      humanize = h.load_luamark()._internal.humanize
   end)

   local cases = {
      { input = 0, expected = "0" },
      { input = 1, expected = "1" },
      { input = 1000, expected = "1k" },
      { input = 1500, expected = "1.5k" },
      { input = 1000000, expected = "1M" },
   }
   for _, case in ipairs(cases) do
      test("humanize(" .. case.input .. ") = " .. case.expected, function()
         assert.are_equal(case.expected, humanize(case.input, "count"))
      end)
   end
end)
