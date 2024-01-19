---@class luamark
local luamark = {}

local CALIBRATION_PRECISION = 5
local MIN_ROUNDS = 5

local MAX_INT = 2 ^ 1023

local clock, clock_resolution
local has_posix, posix = pcall(require, "posix.time")

-- clock_gettime is not defined on MacOS
if has_posix and posix.clock_gettime then
   clock_resolution = 1e-9 -- 1ns
   clock = function()
      local s, ns = posix.clock_gettime(posix.CLOCK_MONOTONIC)
      return s + ns / clock_resolution
   end
else
   local has_socket, socket = pcall(require, "socket")
   if has_socket then
      clock = socket.gettime
      clock_resolution = 1e-4 -- 10µs
   else
      -- Inconsistent across platforms: report real time on windows vs cpu time on linux
      clock = os.clock
      clock_resolution = 1e-3 -- 1ms
   end
end

--- Performs a warm-up for a given function by running it a specified number of times.
--- This helps in preparing the system for the actual benchmark.
---@param func function The function to warm up.
---@param n number The number of times to run the function.
local function rerun(func, n)
   return function(...)
      for _ = 1, n do
         func(...)
      end
   end
end

--- Measures the time taken to execute a function once.
---@param func function The function to measure.
---@return number duration The time taken to execute the function.
local function measure_time(func)
   local start = clock()
   func()
   return clock() - start
end

--- Measures the memory used by a function.
--- Performs garbage collection before and after the function call to measure the memory usage accurately.
---@param func function The function to measure.
---@return number memory_used The amount of memory used by the function (in kilobytes).
local function measure_memory(func)
   local start_memory = collectgarbage("count")
   func()
   local memory_used = collectgarbage("count") - start_memory
   return memory_used
end

--- Formats the statistical metrics into a readable string.
---@param stats table The statistical metrics to format.
---@param unit string The unit of measurement for the metrics.
---@return string txt A formatted string representing the statistical metrics.
local function format_stats(stats, unit)
   local decimals = unit == "s" and 6 or 4
   -- https://stackoverflow.com/questions/48258008/n-and-r-arguments-to-ipythons-timeit-magic/59543135#59543135
   -- # 259 µs ± 4.87 µs per loop (mean ± std. dev. of 7 iterations, 1000 loops each)
   local sampleslate = string.format("%%.%df%%s ± %%.%df%%s per run", decimals, decimals)

   return string.format(sampleslate, stats.mean, unit, stats.stddev, unit)
end

--- Calculates statistical metrics from timeit or memit samples..
--- Includes count, min, max, mean, and standard deviation.
---@param samples table The table of raw values from timeit or memit.
---@return table stats A table containing statistical metrics.
local function calculate_stats(samples, unit)
   local stats = {}

   stats.count = #samples

   table.sort(samples)
   -- Calculate median
   if math.fmod(#samples, 2) == 0 then
      -- If even or odd #samples -> averages of the 2 elements at the center
      stats.median = (samples[#samples / 2] + samples[(#samples / 2) + 1]) / 2
   else
      -- middle element
      stats.median = samples[math.ceil(#samples / 2)]
   end

   stats.total = 0
   local min, max = MAX_INT, 0
   for i = 1, stats.count do
      local sample = samples[i]
      stats.total = stats.total + sample
      min = math.min(sample, min)
      max = math.max(sample, max)
   end

   stats.min = min
   stats.max = max
   stats.mean = stats.total / stats.count

   local sum_of_squares = 0
   for _, sample in ipairs(samples) do
      sum_of_squares = sum_of_squares + (sample - stats.mean) ^ 2
   end
   stats.stddev = math.sqrt(sum_of_squares / (stats.count - 1))

   stats["stats.total"] = stats.total

   setmetatable(stats, {
      __tostring = function(self)
         return format_stats(self, unit)
      end,
   })

   return stats
end

--- Determine the round parameters
---@param func function The function to benchmark.
---@return number # Duration of a round.
local function calibrate_round(func)
   local min_time = clock_resolution * CALIBRATION_PRECISION
   local iterations = 1
   while true do
      local repeated_func = rerun(func, iterations)
      local duration = measure_time(repeated_func)
      if duration >= min_time then
         break
      end
      if duration >= clock_resolution then
         iterations = math.ceil(min_time * iterations / duration)
         if iterations == 1 then
            -- Nothing to calibrate anymore
            break
         end
      else
         iterations = iterations * 10
      end
   end
   return iterations
end

--- Runs a benchmark on a function using a specified measurement method.
--- Collects and returns raw values from multiple iterations of the function.
---@param func function The function to benchmark.
---@param measure function The measurement function to use (e.g., measure_time or measure_memory).
---@param rounds number The number of rounds, i.e. set of runs
---@param disable_gc boolean Whether to disable garbage collection during the benchmark.
---@return table # A table containing the results of the benchmark .
local function run_benchmark(func, measure, rounds, disable_gc)
   disable_gc = disable_gc or true
   rounds = rounds or MIN_ROUNDS
   local iterations = calibrate_round(func)
   local inner_loop = rerun(func, iterations)

   inner_loop() -- warmup 1 round

   local timestamp = os.date("!%Y-%m-%d %H:%M:%SZ")
   local samples = {}
   for i = 1, rounds do
      collectgarbage("collect")
      if disable_gc then
         collectgarbage("stop")
      end

      samples[i] = measure(inner_loop) / iterations

      collectgarbage("restart")
   end

   local results = calculate_stats(samples, measure == measure_memory and "kb" or "s")
   results.rounds = rounds
   results.iterations = iterations
   results.timestamp = timestamp
   return results
end

--- Benchmarks a function for execution time.
--- The time is represented in seconds.
---@param func function The function to benchmark.
---@param rounds number The number of times to run the benchmark.
---@return table results A table of time measurements for each run.
function luamark.timeit(func, rounds)
   return run_benchmark(func, measure_time, rounds, true)
end

--- Benchmarks a function for memory usage.
--- The memory usage is represented in kilobytes.
---@param func function The function to benchmark.
---@param rounds number The number of times to run the benchmark.
---@return table results A table of memory usage measurements for each run.
function luamark.memit(func, rounds)
   return run_benchmark(func, measure_memory, rounds, false)
end

return luamark
