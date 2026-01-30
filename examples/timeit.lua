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

-- ============================================================================
-- Example 3: Manual timing with timer API
-- ============================================================================
-- Use timer.start() and timer.stop() to control what gets measured

print("\n=== Manual timing with timer ===")
local stats_manual = luamark.timeit(function(ctx, timer)
   -- Setup work (not timed)
   local copy = {}
   for i = 1, #ctx do
      copy[i] = ctx[i]
   end

   -- Only time the sort operation
   timer.start()
   table.sort(copy)
   timer.stop()

   -- Cleanup work (not timed)
   local _ = copy[1]
end, {
   setup = function()
      local data = {}
      for i = 1, 1000 do
         data[i] = math.random(10000)
      end
      return data
   end,
   rounds = 50,
})
print(stats_manual)

-- ============================================================================
-- Example 4: Multiple timed sections
-- ============================================================================
-- timer.start() and timer.stop() can be called multiple times
-- All timed sections are accumulated

print("\n=== Multiple timed sections ===")
local stats_multi = luamark.timeit(function(_, timer)
   -- First timed section
   timer.start()
   local sum = 0
   for i = 1, 1000 do
      sum = sum + i
   end
   timer.stop()

   -- Untimed work
   local _ = sum * 2

   -- Second timed section
   timer.start()
   local product = 1
   for _ = 1, 100 do
      product = product * 1.001
   end
   timer.stop()
end, { rounds = 50 })
print(stats_multi)
