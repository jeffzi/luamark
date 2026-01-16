-- Memory Usage Measurement
-- Compare memory allocations of different string building approaches

local luamark = require("luamark")

local mem_stats = luamark.memit({
   concat_loop = function()
      local s = "" ---@diagnostic disable-line: unused-local
      for _ = 1, 50 do
         s = s .. "x"
      end
   end,
   table_concat = function()
      local t = {}
      for i = 1, 50 do
         t[i] = "x"
      end
      local _ = table.concat(t)
   end,
})

-- Display results
print(mem_stats)
