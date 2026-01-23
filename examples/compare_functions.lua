-- Compare Functions
-- Use compare_time/compare_memory to compare multiple function implementations
-- Supports optional params for parameterized benchmarks across different inputs

---@diagnostic disable: redundant-parameter, unused-local

local luamark = require("luamark")

-- ============================================================================
-- Example 1: Basic compare_time
-- ============================================================================
-- When results have overlapping confidence intervals, they share the same
-- effective rank with an ≈ prefix (e.g., "≈1 ≈1 3" means ranks 1-2 overlap)

print("=== Basic compare_time ===")
local results1 = luamark.compare_time({
   concat_loop = function()
      local s = ""
      for i = 1, 100 do
         s = s .. i
      end
   end,
   -- These two are statistically indistinguishable (random variation)
   random_work_a = function()
      local x = 0
      for i = 1, 80 + math.random(40) do
         x = x + i
      end
   end,
   random_work_b = function()
      local x = 0
      for i = 1, 80 + math.random(41) do
         x = x + i
      end
   end,
})

-- Results can be displayed via string conversion (uses luamark.summarize(..., "compact"))
-- random_work_a and random_work_b will show ≈ ranks since their CIs overlap
print(results1)
print(luamark.summarize(results1, "plain"))

-- ============================================================================
-- Example 2: compare_memory
-- ============================================================================
-- Compare memory allocation patterns between implementations

print("\n=== compare_memory ===")
local results2 = luamark.compare_memory({
   string_concat = function()
      local s = ""
      for i = 1, 100 do
         s = s .. tostring(i)
      end
   end,
   table_concat = function()
      local t = {}
      for i = 1, 100 do
         t[i] = tostring(i)
      end
      local _ = table.concat(t)
   end,
})
print(results2)

-- ============================================================================
-- Example 3: Parameterized benchmarks with params
-- ============================================================================
-- Compare across different input sizes using params option

print("\n=== Parameterized benchmarks ===")
local results3 = luamark.compare_time({
   -- benchmark functions receive (ctx, params)
   -- ctx: returned by setup, params: current parameter combination
   loop = function(ctx, params)
      local s = ""
      for i = 1, params.n do
         s = s .. ctx.data[i]
      end
   end,
   table_concat = function(ctx) -- doesn't need params
      local _ = table.concat(ctx.data)
   end,
}, {
   params = { n = { 10, 100, 1000 } },
   setup = function(params)
      -- setup receives params and returns ctx
      local data = {}
      for i = 1, params.n do
         data[i] = "x"
      end
      return { data = data } -- returned value becomes ctx in benchmark functions
   end,
})
print(luamark.summarize(results3, "plain"))

-- ============================================================================
-- Example 4: Two-level setup (per-function before)
-- ============================================================================
-- setup: runs once per param combo (expensive work, consistent test data)
-- before: runs each iteration (cheap reset, e.g. copy data that gets mutated)

print("\n=== Two-level setup (sorting benchmark) ===")
local results4 = luamark.compare_time({
   table_sort = {
      fn = function(ctx)
         table.sort(ctx.copy) -- sort mutates the array
      end,
      -- before receives ctx from setup, returns ctx for fn
      before = function(ctx)
         -- copy the source array so each iteration has fresh unsorted data
         local copy = {}
         for i = 1, #ctx.source do
            copy[i] = ctx.source[i]
         end
         ctx.copy = copy
         return ctx
      end,
   },
}, {
   params = { n = { 100, 1000 } },
   setup = function(params)
      -- generate random data once (expensive, ensures fair comparison)
      local source = {}
      for i = 1, params.n do
         source[i] = math.random(params.n * 10)
      end
      return { source = source }
   end,
   rounds = 50,
})
print(luamark.summarize(results4, "compact"))

-- ============================================================================
-- Example 5: Realistic algorithm comparison
-- ============================================================================
-- Linear vs binary search with multiple params (n × sorted)

local function linear_search(arr, target)
   for i = 1, #arr do
      if arr[i] == target then
         return i
      end
   end
   return nil
end

local function binary_search(arr, target)
   local low, high = 1, #arr
   while low <= high do
      local mid = math.floor((low + high) / 2)
      if arr[mid] == target then
         return mid
      elseif arr[mid] < target then
         low = mid + 1
      else
         high = mid - 1
      end
   end
   return nil
end

print("\n=== Linear vs Binary Search ===")
print("Binary search is O(log n) but requires sorted data")
local results5 = luamark.compare_time({
   linear = function(ctx)
      linear_search(ctx.data, ctx.target)
   end,
   binary = function(ctx)
      binary_search(ctx.data, ctx.target)
   end,
}, {
   params = {
      n = { 100, 1000, 10000 },
      sorted = { true, false },
   },
   setup = function(params)
      local data = {}
      for i = 1, params.n do
         data[i] = i
      end
      if not params.sorted then
         for i = params.n, 2, -1 do
            local j = math.random(i)
            data[i], data[j] = data[j], data[i]
         end
      end
      local target = data[math.floor(params.n / 2)]
      return { data = data, target = target }
   end,
   rounds = 100,
})
print(luamark.summarize(results5, "plain"))

-- ============================================================================
-- Example 6: Output formats
-- ============================================================================

print("\n=== Output formats ===")
print("Plain:")
print(luamark.summarize(results3, "plain"))

print("\nMarkdown:")
print(luamark.summarize(results3, "markdown"))

print("\nCSV:")
print(luamark.summarize(results3, "csv"))
