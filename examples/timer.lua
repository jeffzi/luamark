-- Standalone Timer for Manual Profiling
-- Use luamark.Timer() for ad-hoc timing outside of benchmarks

local luamark = require("luamark")

-- ============================================================================
-- Example 1: Basic Timer usage
-- ============================================================================

print("=== Basic Timer usage ===")
local timer = luamark.Timer()

timer.start()
local sum = 0
for i = 1, 1000000 do
   sum = sum + i
end
local elapsed = timer.stop()

print(string.format("Elapsed: %s", luamark.humanize_time(elapsed)))

-- ============================================================================
-- Example 2: Accumulating time across operations
-- ============================================================================

print("\n=== Accumulating time across operations ===")
local work_timer = luamark.Timer()

-- Simulate a loop where we only want to time the "work" portions,
-- not the setup/teardown between iterations
local total_work = 0
for iteration = 1, 5 do
   -- Setup (not timed)
   local data = {}
   for i = 1, 10000 do
      data[i] = i * iteration
   end

   -- Time only the actual work
   work_timer.start()
   local result = 0
   for _, v in ipairs(data) do
      result = result + math.sqrt(v)
   end
   work_timer.stop()
   total_work = total_work + result

   -- Cleanup/logging (not timed)
   data = nil
end

print(string.format("Total accumulated work time: %s", luamark.humanize_time(work_timer.elapsed())))

-- ============================================================================
-- Example 3: Profiling a function
-- ============================================================================

print("\n=== Profiling a function ===")

local function fibonacci(n)
   if n <= 1 then
      return n
   end
   return fibonacci(n - 1) + fibonacci(n - 2)
end

local function profile_fibonacci(n)
   local t = luamark.Timer()
   t.start()
   local result = fibonacci(n)
   local elapsed = t.stop()
   return result, elapsed
end

for _, n in ipairs({ 20, 25, 30 }) do
   local result, elapsed = profile_fibonacci(n)
   print(string.format("fibonacci(%d) = %d in %s", n, result, luamark.humanize_time(elapsed)))
end
