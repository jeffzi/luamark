---@diagnostic disable: undefined-field, unused-local, invisible

local h = require("tests.helpers")

describe("unload", function()
   local luamark

   setup(function()
      luamark = h.load_luamark()
   end)

   test("unloads matching modules and returns count", function()
      package.loaded["mylib.core"] = { loaded = true }
      package.loaded["mylib.utils"] = { loaded = true }
      package.loaded["mylib.extra"] = { loaded = true }
      package.loaded["other_module"] = { loaded = true }

      local count = luamark.unload("^mylib%.")

      assert.are_equal(3, count)
      assert.is_nil(package.loaded["mylib.core"])
      assert.is_nil(package.loaded["mylib.utils"])
      assert.is_nil(package.loaded["mylib.extra"])
      assert.is_truthy(package.loaded["other_module"])

      package.loaded["other_module"] = nil
   end)

   test("returns 0 when no modules match", function()
      local count = luamark.unload("^nonexistent_module_pattern_xyz$")
      assert.are_equal(0, count)
   end)
end)
