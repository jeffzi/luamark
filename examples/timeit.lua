-- Time Benchmarking
-- Use timeit for benchmarking a single function's execution time

local luamark = require("luamark")

-- ============================================================================
-- Example 1: Basic timeit usage
-- ============================================================================

local function factorial(n)
   if n == 0 then
      return 1
   else
      return n * factorial(n - 1)
   end
end

-- timeit returns Stats directly for a single function
print("=== Basic timeit ===")
local stats = luamark.timeit(function()
   factorial(10)
end, { rounds = 100 })

-- Stats has a readable __tostring
print(stats)
-- Example output: 250ns ± 0ns

-- Access individual stats fields (values are in seconds)
print(string.format("Median: %s", luamark.humanize_time(stats.median)))
print(
   string.format(
      "95%% CI: [%s, %s]",
      luamark.humanize_time(stats.ci_lower),
      luamark.humanize_time(stats.ci_upper)
   )
)
print(string.format("Rounds: %d", stats.rounds))
print(string.format("Iterations per round: %d", stats.iterations))

-- ============================================================================
-- Example 2: timeit with setup/teardown
-- ============================================================================
-- In timeit API, hooks receive no params argument

print("\n=== timeit with setup/teardown ===")
local stats_with_setup = luamark.timeit(function(ctx)
   table.sort(ctx.data)
end, {
   setup = function()
      -- setup receives no arguments
      local data = {}
      for i = 1, 100 do
         data[i] = math.random(1000)
      end
      return { data = data } -- returned value becomes ctx in benchmark function
   end,
   teardown = function(ctx)
      -- teardown receives only ctx in timeit API
      print(string.format("Sorted %d items", #ctx.data))
   end,
})
print(stats_with_setup)
