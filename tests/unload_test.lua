---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

describe("unload", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("unloads modules matching pattern", function()
      -- Load a test module
      package.loaded["test_module_for_unload"] = { loaded = true }

      assert.is_truthy(package.loaded["test_module_for_unload"])

      local count = luamark.unload("^test_module_for_unload$")

      assert.are_equal(1, count)
      assert.is_nil(package.loaded["test_module_for_unload"])
   end)

   test("returns correct count of unloaded modules", function()
      -- Cleanup from any previous failed run
      package.loaded["other_module"] = nil

      -- Load multiple test modules
      package.loaded["unload_test_a"] = { loaded = true }
      package.loaded["unload_test_b"] = { loaded = true }
      package.loaded["unload_test_c"] = { loaded = true }
      package.loaded["other_module"] = { loaded = true }

      local count = luamark.unload("^unload_test_")

      assert.are_equal(3, count)
      assert.is_nil(package.loaded["unload_test_a"])
      assert.is_nil(package.loaded["unload_test_b"])
      assert.is_nil(package.loaded["unload_test_c"])
      assert.is_truthy(package.loaded["other_module"])

      -- Cleanup
      package.loaded["other_module"] = nil
   end)

   test("returns 0 when no modules match", function()
      local count = luamark.unload("^nonexistent_module_pattern_xyz$")
      assert.are_equal(0, count)
   end)

   test("supports Lua patterns", function()
      package.loaded["mylib.core"] = { loaded = true }
      package.loaded["mylib.utils"] = { loaded = true }
      package.loaded["mylib.extra"] = { loaded = true }

      local count = luamark.unload("^mylib%.")

      assert.are_equal(3, count)
      assert.is_nil(package.loaded["mylib.core"])
      assert.is_nil(package.loaded["mylib.utils"])
      assert.is_nil(package.loaded["mylib.extra"])
   end)

   test("can be used to benchmark module load time", function()
      -- This tests the typical use case: unload then re-require
      package.loaded["socket"] = nil

      local stats = luamark.timeit(function()
         require("socket")
      end, {
         rounds = 5,
         before = function()
            package.loaded["socket"] = nil
         end,
      })

      assert.is_number(stats.mean)
      assert.is_truthy(package.loaded["socket"])
   end)
end)
