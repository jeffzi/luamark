---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

describe("rank", function()
   local luamark, rank

   setup(function()
      luamark = h.load_luamark()
      rank = luamark._internal.rank
   end)

   test("handles zero minimum value", function()
      local data = {
         test1 = { mean = 0 },
         test2 = { mean = 10 },
      }
      rank(data, "mean")
      assert.are.equal(1, data.test1.rank)
      assert.are.equal(2, data.test2.rank)
      assert.are.equal(1, data.test1.ratio)
      assert.is_true(data.test2.ratio < math.huge)
      assert.are_equal(data.test2.ratio, data.test2.ratio) -- not NaN
   end)

   test("unique values", function()
      local data = {
         test1 = { mean = 8 },
         test2 = { mean = 20 },
         test3 = { mean = 5 },
         test4 = { mean = 12 },
      }
      rank(data, "mean")
      assert.are.same({ rank = 1, mean = 5, ratio = 1 }, data.test3)
      assert.are.same({ rank = 2, mean = 8, ratio = 1.6 }, data.test1)
      assert.are.same({ rank = 3, mean = 12, ratio = 2.4 }, data.test4)
      assert.are.same({ rank = 4, mean = 20, ratio = 4 }, data.test2)
   end)

   test("identical values", function()
      local data = {
         test1 = { mean = 10 },
         test2 = { mean = 10 },
         test3 = { mean = 10 },
      }
      rank(data, "mean")

      assert.are.equal(1, data.test1.rank)
      assert.are.equal(1, data.test2.rank)
      assert.are.equal(1, data.test3.rank)

      assert.are.equal(1.0, data.test1.ratio)
      assert.are.equal(1.0, data.test2.ratio)
      assert.are.equal(1.0, data.test3.ratio)
   end)

   test("ranks by specified key", function()
      local data = {
         test1 = { mean = 10, median = 18 },
         test2 = { mean = 20, median = 8 },
      }
      rank(data, "mean")
      assert.are.same({ rank = 1, mean = 10, median = 18, ratio = 1 }, data.test1)
      assert.are.same({ rank = 2, mean = 20, median = 8, ratio = 2 }, data.test2)

      rank(data, "median")
      assert.are.same({ rank = 1, mean = 20, median = 8, ratio = 1.0 }, data.test2)
      assert.are.same({ rank = 2, mean = 10, median = 18, ratio = 2.25 }, data.test1)
   end)

   test("empty table error", function()
      assert.has.error(function()
         rank({}, "foo")
      end, "'results' is nil or empty.")
   end)

   test("nil error", function()
      assert.has.error(function()
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
      assert.are.equal(-1, stats.max)
      assert.are.equal(-5, stats.min)
   end)
end)
