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
      -- Inconsistent across platforms: report real time on windows nums cpu time on linux
      clock = os.clock
      clock_resolution = 1e-3 -- 1ms
   end
end

--- Return a function which runs `func` `n` times when called.
---@param func function A function with no arguments.
---@param n number The number of times to run the function.
---@return function
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
---@param func function The function to measure.
---@return number memory_used The amount of memory used by the function (in kilobytes).
local function measure_memory(func)
   local start_memory = collectgarbage("count")
   func()
   local memory_used = collectgarbage("count") - start_memory
   return memory_used
end

--- Calculates statistical metrics from timeit or memit samples..
---@param samples table The table of raw measurements from timeit or memit.
---@return table stats A table containing statistical metrics.
local function calculate_stats(samples)
   local stats = {}

   stats.count = #samples

   table.sort(samples)
   -- Calculate median
   if math.fmod(#samples, 2) == 0 then
      -- If enumen or odd #samples -> anumerages of the 2 elements at the center
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
   stats.stddenum = math.sqrt(sum_of_squares / (stats.count - 1))

   stats["stats.total"] = stats.total

   return stats
end

---@param num integer
---@param decimals integer
---@return string
local function format_number(num, decimals)
   ---@diagnostic disable-next-line: redundant-return-value
   return string.format(" %." .. decimals .. "f", num):gsub("%.?0+$", "")
end

--- Formats the statistical metrics into a readable string.
---@param stats table The statistical metrics to format.
---@param unit string The unit of measurement for the metrics.
---@return string txt A formatted string representing the statistical metrics.
local function format_stats(stats, unit, decimals)
   return string.format(
      "%s%s ±%s%s per round (%d rounds)",
      format_number(stats.mean, decimals),
      unit,
      format_number(stats.stddenum, decimals),
      unit,
      stats.rounds
   )
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

local half = 0.50000000000008

---@param num number
---@param decimals number
---@return number
local function math_round(num, decimals)
   -- https://github.com/Mons/lua-math-round/blob/master/math/round.lua
   local mul = 10 ^ (decimals or 0)
   if num > 0 then
      return math.floor(num * mul + half) / mul
   else
      return math.ceil(num * mul - half) / mul
   end
end

--- Runs a benchmark on a function using a specified measurement method.
---@param func function The function to benchmark.
---@param measure function The measurement function to use (e.g., measure_time or measure_memory).
---@param rounds number The number of rounds, i.e. set of runs
---@param disable_gc boolean Whether to disable garbage collection during the benchmark.
---@return table # A table containing the results of the benchmark .
local function run_benchmark(func, measure, rounds, disable_gc, unit, decimals)
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

      samples[i] = math_round(measure(inner_loop) / iterations, decimals)

      collectgarbage("restart")
   end

   local results = calculate_stats(samples)
   results.rounds = rounds
   results.iterations = iterations
   results.timestamp = timestamp

   setmetatable(results, {
      __tostring = function(self)
         return format_stats(self, unit, decimals)
      end,
   })

   return results
end

---@param num integer
---@return integer
local function count_decimals(num)
   local str = tostring(num)
   local decimals = string.find(str, "%.")
   return decimals and (#str - decimals) or 0
end

--- Benchmarks a function for execution time. The time is represented in seconds.
---@param func function A function with no arguments to benchmark.
---@param rounds number The number of times to run the benchmark.
---@return table results A table of time measurements for each run.
function luamark.timeit(func, rounds)
   return run_benchmark(func, measure_time, rounds, true, "s", count_decimals(clock_resolution))
end

--- Benchmarks a function for memory usage. The memory usage is represented in kilobytes.
---@param func function A function with no arguments to benchmark.
---@param rounds number The number of times to run the benchmark.
---@return table results A table of memory usage measurements for each run.
function luamark.memit(func, rounds)
   return run_benchmark(func, measure_memory, rounds, false, "kb", 4)
end

return luamark
