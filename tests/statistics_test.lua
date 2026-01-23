---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

describe("rank", function()
   local rank

   setup(function()
      rank = h.load_luamark()._internal.rank
   end)

   test("assigns rank and ratio based on values", function()
      local data = {
         test1 = { median = 8 },
         test2 = { median = 20 },
         test3 = { median = 5 },
      }
      rank(data, "median")
      assert.are_same({ rank = 1, median = 5, ratio = 1 }, data.test3)
      assert.are_same({ rank = 2, median = 8, ratio = 1.6 }, data.test1)
      assert.are_same({ rank = 3, median = 20, ratio = 4 }, data.test2)
   end)

   test("handles zero minimum and identical values", function()
      local zero_data = {
         test1 = { median = 0 },
         test2 = { median = 10 },
      }
      rank(zero_data, "median")
      assert.are_equal(1, zero_data.test1.rank)
      assert.are_equal(1, zero_data.test1.ratio)

      local same_data = {
         test1 = { median = 10 },
         test2 = { median = 10 },
      }
      rank(same_data, "median")
      assert.are_equal(1, same_data.test1.rank)
      assert.are_equal(1, same_data.test2.rank)
   end)

   test("rejects nil and empty input", function()
      assert.has_error(function()
         rank({}, "foo")
      end, "'results' is nil or empty.")
      assert.has_error(function()
         ---@diagnostic disable-next-line: param-type-mismatch
         rank(nil, "bar")
      end, "'results' is nil or empty.")
   end)
end)

describe("calculate_stats", function()
   local calculate_stats

   setup(function()
      calculate_stats = h.load_luamark()._internal.calculate_stats
   end)

   test("computes median and CI fields", function()
      local samples = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
      local stats = calculate_stats(samples)
      assert.are_equal(10, stats.count)
      assert.are_equal(5.5, stats.median)
      assert.is_number(stats.ci_lower)
      assert.is_number(stats.ci_upper)
      assert.is_number(stats.ci_margin)
      assert.is_true(stats.ci_lower <= stats.median)
      assert.is_true(stats.ci_upper >= stats.median)
   end)

   test("handles small samples (fewer than 3)", function()
      local samples = { 5, 10 }
      local stats = calculate_stats(samples)
      assert.are_equal(7.5, stats.median)
      assert.are_equal(7.5, stats.ci_lower)
      assert.are_equal(7.5, stats.ci_upper)
      assert.are_equal(0, stats.ci_margin)
   end)

   test("handles single sample", function()
      local samples = { 42 }
      local stats = calculate_stats(samples)
      assert.are_equal(42, stats.median)
      assert.are_equal(42, stats.ci_lower)
      assert.are_equal(42, stats.ci_upper)
      assert.are_equal(0, stats.ci_margin)
   end)
end)

describe("math_median", function()
   local math_median

   setup(function()
      math_median = h.load_luamark()._internal.math_median
   end)

   test("computes median for odd-length arrays", function()
      assert.are_equal(3, math_median({ 1, 3, 5 }))
      assert.are_equal(5, math_median({ 1, 3, 5, 7, 9 }))
   end)

   test("computes median for even-length arrays", function()
      assert.are_equal(2.5, math_median({ 1, 2, 3, 4 }))
      assert.are_equal(3.5, math_median({ 1, 2, 3, 4, 5, 6 }))
   end)
end)

describe("bootstrap_ci", function()
   local bootstrap_ci

   setup(function()
      bootstrap_ci = h.load_luamark()._internal.bootstrap_ci
   end)

   test("returns lower and upper bounds", function()
      math.randomseed(12345)
      local samples = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
      local ci = bootstrap_ci(samples, 1000)
      assert.is_number(ci.lower)
      assert.is_number(ci.upper)
      assert.is_true(ci.lower <= ci.upper)
   end)

   test("CI width decreases with more samples", function()
      math.randomseed(12345)
      local small_samples = {}
      local large_samples = {}
      for i = 1, 10 do
         small_samples[i] = i
      end
      for i = 1, 100 do
         large_samples[i] = (i % 10) + 1
      end

      local ci_small = bootstrap_ci(small_samples, 1000)
      local ci_large = bootstrap_ci(large_samples, 1000)

      local width_small = ci_small.upper - ci_small.lower
      local width_large = ci_large.upper - ci_large.lower
      assert.is_true(width_large <= width_small)
   end)
end)

describe("rank_results", function()
   local rank_results

   setup(function()
      rank_results = h.load_luamark()._internal.rank_results
   end)

   --- Create mock benchmark row with specific CI.
   ---@param name string
   ---@param median number
   ---@param ci_lower number
   ---@param ci_upper number
   ---@return table
   local function make_row(name, median, ci_lower, ci_upper)
      return {
         name = name,
         params = {},
         stats = { median = median, ci_lower = ci_lower, ci_upper = ci_upper },
      }
   end

   --- Extract rank strings from results (sorted by median).
   ---@param results table[]
   ---@return string[]
   local function get_rank_strings(results)
      table.sort(results, function(a, b)
         return a.stats.median < b.stats.median
      end)
      local ranks = {}
      for i = 1, #results do
         local s = results[i].stats
         ranks[i] = s.is_approximate and ("≈" .. s.rank) or tostring(s.rank)
      end
      return ranks
   end

   -- Data-driven tests for CI overlap scenarios
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
         rank_results(results)
         assert.are_same(case.expected, get_rank_strings(results))
      end)
   end

   test("single result: no approximation", function()
      local results = { make_row("a", 5, 4, 6) }
      rank_results(results)
      assert.are_equal(1, results[1].stats.rank)
      assert.is_false(results[1].stats.is_approximate)
   end)

   test("ratio calculated from position ordering", function()
      local results = { make_row("a", 10, 9, 11), make_row("b", 30, 29, 31) }
      rank_results(results)
      table.sort(results, function(x, y)
         return x.stats.median < y.stats.median
      end)
      assert.are_equal(1, results[1].stats.ratio)
      assert.are_equal(3, results[2].stats.ratio)
   end)
end)

describe("humanize with count unit", function()
   local humanize

   setup(function()
      humanize = h.load_luamark()._internal.humanize
   end)

   test("formats counts with SI suffixes", function()
      assert.are_equal("1", humanize(1, "count"))
      assert.are_equal("500", humanize(500, "count"))
      assert.are_equal("1k", humanize(1000, "count"))
      assert.are_equal("1.5k", humanize(1500, "count"))
      assert.are_equal("10k", humanize(10000, "count"))
      assert.are_equal("1M", humanize(1000000, "count"))
      assert.are_equal("2.5M", humanize(2500000, "count"))
   end)

   test("handles zero", function()
      assert.are_equal("0", humanize(0, "count"))
   end)
end)
