-- Single Function Timing
-- Measure a single function with custom rounds

local luamark = require("luamark")

local function factorial(n)
   if n == 0 then
      return 1
   else
      return n * factorial(n - 1)
   end
end

local time_stats = luamark.timeit(function()
   factorial(10)
end, { rounds = 10 })

print(time_stats)
-- Example output: 42ns ± 23ns per round (10 rounds)
