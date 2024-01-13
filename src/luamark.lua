local socket = require("socket")
local now = socket.gettime

---@class luamark
local luamark = {}

--- Performs a warm-up for a given function by running it a specified number of times.
--- This helps in preparing the system for the actual luamark.
---@param func function The function to warm up.
---@param runs number The number of times to run the function.
local function warmup(func, runs)
   for _ = 1, runs do
      func()
   end
end

--- Measures the time taken to execute a function once.
---@param func function The function to measure.
---@return number elapsed The time taken to execute the function.
local function measure_time(func)
   local start = now()
   func()
   return now() - start
end

--- Measures the memory used by a function.
--- Performs garbage collection before and after the function call to measure the memory usage accurately.
---@param func function The function to measure.
---@return number memory_used The amount of memory used by the function (in kilobytes).
local function measure_memory(func)
   collectgarbage("collect")
   collectgarbage("stop")
   local start_memory = collectgarbage("count")
   func()
   local memory_used = collectgarbage("count") - start_memory
   collectgarbage("restart")
   return memory_used
end

--- Runs a benchmark on a function using a specified measurement method.
--- Collects and returns raw values from multiple runs of the function.
---@param func function The function to luamark.
---@param measure function The measurement function to use (e.g., measure_time or measure_memory).
---@param runs number The number of times to run the luamark.
---@param warmup_runs number The number of warm-up iterations performed before the actual luamark.
---@param disable_gc boolean Whether to disable garbage collection during the luamark.
---@return table samples A table of raw values from each run of the luamark.
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

--- Benchmarks a function for execution time.
--- The time is represented in seconds.
---@param func function The function to luamark.
---@param runs number The number of times to run the luamark.
---@param warmup_runs number The number of warm-up iterations before the luamark.
---@param disable_gc boolean Whether to disable garbage collection during the luamark.
---@return table samples A table of time measurements for each run.
function luamark.timeit(func, runs, warmup_runs, disable_gc)
   return run_benchmark(func, measure_time, runs, warmup_runs, disable_gc)
end

--- Benchmarks a function for memory usage.
--- The memory usage is represented in kilobytes.
---@param func function The function to luamark.
---@param runs number The number of times to run the luamark.
---@param warmup_runs number The number of warm-up iterations before the luamark.
---@return table samples A table of memory usage measurements for each run.
function luamark.memit(func, runs, warmup_runs)
   return run_benchmark(func, measure_memory, runs, warmup_runs, false)
end

--- Calculates statistical metrics from timeit or memit samples..
--- Includes count, min, max, mean, and standard deviation.
---@param samples table The table of raw values from timeit or memit.
---@return table stats A table containing statistical metrics.
function luamark.calculate_stats(samples)
   local stats = {}

   stats.count = #samples

   local min, max, total = 2 ^ 1023, 0, 0
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

--- Formats the statistical metrics into a readable string.
---@param stats table The statistical metrics to format.
---@param unit string The unit of measurement for the metrics.
---@return string txt A formatted string representing the statistical metrics.
function format_stats(stats, unit)
   return string.format(
      "%.8f %s ± %.8f %s per run (mean ± std. dev. of %d runs)",
      stats.mean,
      unit,
      stats.stddev,
      unit,
      stats.count
   )
end

--- Formats the time statistics into a readable string.
---@param stats table The statistical metrics to format, specifically for time measurements.
---@return string A formatted string representing the time statistical metrics in seconds.
function luamark.format_time_stats(stats)
   return format_stats(stats, "s")
end

--- Formats the memory statistics into a readable string.
---@param stats table The statistical metrics to format, specifically for memory measurements.
---@return string A formatted string representing the memory statistical metrics in kilobytes.
function luamark.format_mem_stats(stats)
   return format_stats(stats, "kb")
end

return luamark
