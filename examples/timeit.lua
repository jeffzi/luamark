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

-- Stats has a readable __tostring (compact format)
print(stats)
-- Example output: 250ns ± 0ns

-- Use render() for detailed key-value format
print("\n=== Detailed output with render() ===")
print(luamark.render(stats))
-- Example output:
-- Median: 250ns
-- CI: 250ns - 251ns (± 0.5ns)
-- Ops: 4M/s
-- Rounds: 100
-- Total: 25us

-- ============================================================================
-- Example 2: timeit with setup/teardown
-- ============================================================================
-- In timeit API, hooks receive no params argument

print("\n=== timeit with setup/teardown ===")
local stats_with_setup = luamark.timeit(function(ctx)
   table.sort(ctx)
end, {
   setup = function()
      -- setup receives no arguments, returns ctx for benchmark function
      local data = {}
      for i = 1, 100 do
         data[i] = math.random(1000)
      end
      return data
   end,
   teardown = function(ctx)
      -- teardown receives only ctx in timeit API
      print(string.format("Sorted %d items", #ctx))
   end,
})
print(stats_with_setup)
