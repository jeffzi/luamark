-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- Utils
-- ----------------------------------------------------------------------------

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

---@param num integer
---@return integer
local function count_decimals(num)
   local str = tostring(num)
   local decimals = string.find(str, "%.")
   return decimals and (#str - decimals) or 0
end

--- Return a function which runs `func` `n` times when called.
---@param func fun(any): any A zero-argument function.
---@param n number The number of times to run the function.
---@return fun(any): any
local function rerun(func, n)
   return function(...)
      for _ = 1, n do
         func(...)
      end
   end
end

-- ----------------------------------------------------------------------------
-- I/O
-- ----------------------------------------------------------------------------

---@param num integer
---@param decimals integer
---@return string
local function format_number(num, decimals)
   ---@diagnostic disable-next-line: redundant-return-value
   return string.format(" %." .. decimals .. "f", num):gsub("%.?0+$", "")
end

--- Formats statistical measurements into a readable string.
---@param stats table The statistical measurements to format.
---@param unit string The unit of measurement.
---@return string # A formatted string representing the statistical metrics.
local function format_stats(stats, unit, decimals)
   return string.format(
      "%s%s ±%s%s per round (%d rounds)",
      format_number(stats.mean, decimals),
      unit,
      format_number(stats.stddev, decimals),
      unit,
      stats.rounds
   )
end

-- ----------------------------------------------------------------------------
-- Statistics
-- ----------------------------------------------------------------------------

--- Calculates measurements from timeit or memit samples..
---@param samples table The table of raw measurements from timeit or memit.
---@return table # A table of statistical measurements.
local function calculate_stats(samples)
   local stats = {}

   stats.count = #samples

   table.sort(samples)
   -- Calculate median
   if math.fmod(#samples, 2) == 0 then
      -- If even or odd #samples -> mean of the 2 elements at the center
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

   return stats
end

-- ----------------------------------------------------------------------------
-- Benchmark
-- ----------------------------------------------------------------------------

--- Measures the time taken to execute a function once.
---@param func fun(): any The zero-arg function to measure.
---@return number # The time taken to execute the function (in seconds).
function luamark.measure_time(func)
   local start = clock()
   func()
   return clock() - start
end

--- Measures the memory used by a function.
---@param func fun(): any The zero-arg function to measure.
---@return number # The amount of memory used by the function (in kilobytes).
function luamark.measure_memory(func)
   local start_memory = collectgarbage("count")
   func()
   local memory_used = collectgarbage("count") - start_memory
   return memory_used
end

--- Determine the round parameters
---@param func function The function to benchmark.
---@return number # Duration of a round.
local function calibrate_round(func)
   local min_time = clock_resolution * CALIBRATION_PRECISION
   local iterations = 1
   while true do
      local repeated_func = rerun(func, iterations)
      local duration = luamark.measure_time(repeated_func)
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
---@param func function The function to benchmark.
---@param measure function The measurement function to use (e.g., measure_time or measure_memory).
---@param rounds number The number of rounds, i.e. set of runs
---@param disable_gc boolean Whether to disable garbage collection during the benchmark.
---@return table # A table containing the results of the benchmark .
local function single_benchmark(func, measure, rounds, iterations, warmups, disable_gc, unit, decimals)
   assert(
      type(func) == "function" or type("function") == "table",
      "'func' must be a function or a table of functions indexed by name."
   )
   rounds = rounds or MIN_ROUNDS
   assert(rounds > 0, "'rounds' must be > 0.")

   iterations = iterations or calibrate_round(func)
   assert(iterations > 0, "'iterations' must be > 0.")

   local inner_loop = rerun(func, iterations)

   warmups = warmups or 1
   assert(warmups >= 0, "'warmups' must be >= 0.")
   for _ = 1, warmups do
      inner_loop()
   end

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
   results.warmups = warmups
   results.timestamp = timestamp

   setmetatable(results, {
      __tostring = function(self)
         return format_stats(self, unit, decimals)
      end,
   })

   return results
end

---@param funcs (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param ... any arguments that will be forwarded to `single_benchmark`.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
local function benchmark(funcs, ...)
   if type(funcs) == "function" then
      return single_benchmark(funcs, ...)
   end

   local results = {}
   for name, func in pairs(funcs) do
      results[name] = single_benchmark(func, ...)
   end
   return results
end

--- Benchmarks a function for execution time. The time is represented in seconds.
---@param func (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param rounds? number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.timeit(func, rounds, iterations, warmups)
   return benchmark(
      func,
      luamark.measure_time,
      rounds,
      iterations,
      warmups,
      true,
      "s",
      count_decimals(clock_resolution)
   )
end

--- Benchmarks a function for memory usage. The memory usage is represented in kilobytes.
---@param func (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param rounds? number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.memit(func, rounds, iterations, warmups)
   return benchmark(func, luamark.measure_memory, rounds, iterations, warmups, false, "kb", 4)
end

return luamark
