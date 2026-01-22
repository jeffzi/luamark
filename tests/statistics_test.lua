---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

describe("rank", function()
   local rank

   setup(function()
      rank = h.load_luamark()._internal.rank
   end)

   test("assigns rank and ratio based on values", function()
      local data = {
         test1 = { mean = 8 },
         test2 = { mean = 20 },
         test3 = { mean = 5 },
      }
      rank(data, "mean")
      assert.are_same({ rank = 1, mean = 5, ratio = 1 }, data.test3)
      assert.are_same({ rank = 2, mean = 8, ratio = 1.6 }, data.test1)
      assert.are_same({ rank = 3, mean = 20, ratio = 4 }, data.test2)
   end)

   test("handles zero minimum and identical values", function()
      local zero_data = {
         test1 = { mean = 0 },
         test2 = { mean = 10 },
      }
      rank(zero_data, "mean")
      assert.are_equal(1, zero_data.test1.rank)
      assert.are_equal(1, zero_data.test1.ratio)

      local same_data = {
         test1 = { mean = 10 },
         test2 = { mean = 10 },
      }
      rank(same_data, "mean")
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

   test("handles negative values", function()
      local samples = { -5, -3, -1 }
      local stats = calculate_stats(samples)
      assert.are_equal(-1, stats.max)
      assert.are_equal(-5, stats.min)
   end)
end)
