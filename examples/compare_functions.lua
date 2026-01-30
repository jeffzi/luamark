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

-- Results can be displayed via string conversion (uses luamark.render(..., true))
-- random_work_a and random_work_b will show ≈ ranks since their CIs overlap
print(results1)
print(luamark.render(results1))

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
   -- benchmark functions receive (ctx, timer, params)
   -- ctx: returned by setup, timer. for manual timing, params: current parameter combination
   loop = function(ctx) -- doesn't need timer or params
      local s = ""
      for i = 1, #ctx do
         s = s .. ctx[i]
      end
   end,
   table_concat = function(ctx) -- doesn't need timer or params
      local _ = table.concat(ctx)
   end,
}, {
   params = { n = { 10, 100, 1000 } },
   setup = function(params)
      -- setup receives params and returns ctx
      local ctx = {}
      for i = 1, params.n do
         ctx[i] = "x"
      end
      return ctx -- returned value becomes ctx in benchmark functions
   end,
})
print(luamark.render(results3))

-- ============================================================================
-- Example 4: Multiple timed sections
-- ============================================================================
-- timer.start() and timer.stop() can be called multiple times
-- All timed sections are accumulated

print("\n=== Multiple timed sections ===")
local results4 = luamark.compare_time({
   copy_and_sort = function(ctx, timer)
      -- First timed section: copy the array
      timer.start()
      local copy = {}
      for i = 1, #ctx do
         copy[i] = ctx[i]
      end
      timer.stop()

      -- Untimed: verify copy succeeded
      assert(#copy == #ctx)

      -- Second timed section: sort
      timer.start()
      table.sort(copy)
      timer.stop()
   end,
}, {
   params = { n = { 100, 1000 } },
   setup = function(params)
      local data = {}
      for i = 1, params.n do
         data[i] = math.random(params.n * 10)
      end
      return data
   end,
   rounds = 50,
})
print(luamark.render(results4))

-- ============================================================================
-- Example 5: Realistic algorithm comparison
-- ============================================================================
-- Linear vs binary search with multiple params (n × sorted)
-- Note: binary search requires sorted data; results are wrong when sorted=false

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
print(luamark.render(results5))
