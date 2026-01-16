-- Basic Time Measurement
-- Compare string building approaches

local luamark = require("luamark")

-- Compare string concatenation vs table.concat
local time_stats = luamark.timeit({
   concat_loop = function()
      local s = ""
      for i = 1, 100 do
         s = s .. i
      end
   end,
   table_concat = function()
      local t = {}
      for i = 1, 100 do
         t[i] = i
      end
      local _ = table.concat(t)
   end,
})

-- Results can be accessed as a table
print("Result type:", type(time_stats))

-- Or displayed via string conversion
print("\nResults:")
print(time_stats)

-- Get the summary as a markdown table
print("\nMarkdown format:")
print(luamark.summarize(time_stats, "markdown"))

-- Get the summary as a markdown table
print("\nCSV format:")
print(luamark.summarize(time_stats, "csv"))
