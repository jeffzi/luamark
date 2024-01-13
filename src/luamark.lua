local socket = require("socket")
local time = socket.gettime

---@class benchmark
local benchmark = {}

local function warmup(func, runs)
   for _ = 1, runs do
      func()
   end
end

local function measure_time(func)
   local start = time()
   func()
   return time() - start
end

local function measure_memory(func)
   collectgarbage("collect")
   collectgarbage("stop")
   local start_memory = collectgarbage("count")
   func()
   local memory_used = collectgarbage("count") - start_memory
   collectgarbage("restart")
   return memory_used
end

--- Benchmark function with raw values subtables
---@param func function
---@param runs number
---@param warmup_runs number The number of warm-up iterations performed before the actual benchmark.
--- These are used to estimate the timing overhead as well as spinning up the processor from any
--- sleep or idle states it might be in.
---@return table
local function run_benchmark(func, measure, runs, warmup_runs, disable_gc)
   warmup_runs = warmup_runs or 10
   warmup(func, warmup_runs)

   disable_gc = disable_gc or false
   if disable_gc then
      collectgarbage("collect")
      collectgarbage("stop")
   end

   runs = runs or 100
   local samples = {}
   for run = 1, runs do
      samples[run] = measure(func)
   end

   if disable_gc then
      collectgarbage("restart")
   end

   return samples
end

---comment
---@param func any
---@param runs any
---@param warmup_runs any
---@param disable_gc any
---@return table
function benchmark.timeit(func, runs, warmup_runs, disable_gc)
   return run_benchmark(func, measure_time, runs, warmup_runs, disable_gc)
end

function benchmark.memit(func, runs, warmup_runs)
   return run_benchmark(func, measure_memory, runs, warmup_runs)
end

function benchmark.calculate_stats(samples)
   local stats = {}

   stats.count = #samples

   local min, max, total = 10000, 0, 0
   for i = 1, stats.count do
      local sample = samples[i]
      total = total + sample
      min = math.min(sample, min)
      max = math.max(sample, max)
   end

   stats.min = min
   stats.max = max
   stats.mean = total / stats.count

   local sum_of_squares = 0
   for _, sample in ipairs(samples) do
      sum_of_squares = sum_of_squares + (sample - stats.mean) ^ 2
   end
   stats.stddev = math.sqrt(sum_of_squares / (stats.count - 1))

   return stats
end

---@param stats any
---@param unit any
---@return string
function benchmark.format_stats(stats, unit)
   return string.format(
      "%.8f %s ± %.8f %s per run (mean ± std. dev. of %d runs)",
      stats.mean,
      unit,
      stats.stddev,
      unit,
      stats.count
   )
end

return benchmark
