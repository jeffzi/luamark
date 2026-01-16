-- Suite API
-- Compare benchmarks across parameter values with untimed setup

local luamark = require("luamark")

local data -- shared variable for setup

-- Compare string concatenation approaches at different sizes
local results = luamark.suite_timeit({
   concat = {
      loop = function()
         local s = ""
         for i = 1, #data do
            s = s .. data[i]
         end
      end,
      table_concat = function()
         local _ = table.concat(data)
      end,

      opts = {
         params = { n = { 10, 100, 1000 } },
         setup = function(p)
            -- Untimed: create table with data
            data = {}
            for i = 1, p.n do
               data[i] = tostring(i)
            end
         end,
      },
   },
})

-- Display results
print("Plain format:")
print(luamark.summarize(results, "plain"))

-- Export to CSV
print("\nCSV format:")
local csv = luamark.summarize(results, "csv")
print(csv)

-- Access individual stats
local loop_100 = results.concat.loop.n[100]
print(string.format("\nMedian time for loop concat with n=100: %.2f us", loop_100.median * 1e6))
