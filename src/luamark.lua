---@class luamark
local luamark = {}

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local MAX_ITERATIONS = 1e6
local MIN_ROUNDS = 100
local MAX_ROUNDS = 1e6
local WARMUPS = 1
local MIN_TIME = 1

local CALIBRATION_PRECISION = 5

local MAX_INT = 2 ^ 1023

--------------------------------------------------------------------------
-- Clock
-- ----------------------------------------------------------------------------

local clock, clock_precision

local function get_min_clocktime()
   return (10 ^ -clock_precision)
end

---Get clock and clock precision from a module name.
---@param modname string
---@return (fun(): number)|nil
---@return integer|nil
local function set_clock(modname)
   if modname == "os" then
      return os.clock, 3
   end

   local has_module, lib = pcall(require, modname)
   if not has_module then
      return nil, nil
   end

   if modname == "chronos" then
      if has_module then
         -- 1ns
         clock, clock_precision = lib.nanotime, 9
      end
   elseif modname == "posix.time" then
      -- clock_gettime is not defined on MacOS
      if has_module and lib.clock_gettime then
         -- 1ns
         clock_precision = 9
         clock = function()
            local time_spec = lib.clock_gettime(lib.CLOCK_MONOTONIC)
            return time_spec.tv_sec + time_spec.tv_nsec * get_min_clocktime()
         end
      end
   elseif modname == "socket" then
      if has_module then
         -- 10µs
         clock, clock_precision = lib.gettime, 4
      end
   end
end

set_clock("chronos")
if not clock then
   set_clock("posix.time")
end
if not clock then
   set_clock("socket")
end
if not clock then
   set_clock("os")
end

-- ----------------------------------------------------------------------------
-- Utils
-- ----------------------------------------------------------------------------

local half = 0.50000000000008

---@param num number
---@param precision number
---@return number
local function math_round(num, precision)
   local mul = 10 ^ (precision or 0)
   local rounded
   if num > 0 then
      rounded = math.floor(num * mul + half) / mul
   else
      rounded = math.ceil(num * mul - half) / mul
   end
   return math.max(rounded, 10 ^ -precision)
end

-- ----------------------------------------------------------------------------
-- I/O
-- ----------------------------------------------------------------------------

---@param num integer
---@param precision integer
---@return string
local function format_number(num, precision)
   local formatted, _ = string.format("%." .. precision .. "f", num):gsub("%.?0+$", "")
   return formatted
end

--- Formats statistical measurements into a readable string.
---@param stats table The statistical measurements to format.
---@param unit string The unit of measurement.
---@return string # A formatted string representing the statistical metrics.
local function __tostring_stats(stats, unit, precision)
   return string.format(
      "%s %s ±%s %s per round (%d rounds)",
      format_number(stats.mean, precision),
      unit,
      format_number(stats.stddev, precision),
      unit,
      stats.rounds
   )
end

local function format_row(stats)
   local unit = stats.unit
   local precision = stats.precision
   local row = {}
   for name, value in pairs(stats) do
      if name == "ratio" then
         row[name] = string.format("%.2f", value)
      elseif
         name == "min"
         or name == "max"
         or name == "mean"
         or name == "stddev"
         or name == "median"
      then
         row[name] = format_number(value, precision) .. " " .. unit
      else
         row[name] = tostring(value)
      end
   end
   return row
end

---Print a summary of multiple benchmarks.
---@param benchmark_results {[string]:{[string]: any}} The benchmark results to summarize, indexed by name.
function luamark.print_summary(benchmark_results)
   local pretty_rows = {}
   for benchmark_name, stats in pairs(benchmark_results) do
      local formatted = format_row(stats)
      formatted["name"] = benchmark_name
      table.insert(pretty_rows, formatted)
   end
   table.sort(pretty_rows, function(a, b)
      return a.rank < b.rank
   end)

   local headers =
      { "name", "rank", "ratio", "min", "max", "mean", "stddev", "median", "rounds", "iterations" }

   -- Calculate column widths
   local widths = {}
   for i, header in ipairs(headers) do
      widths[i] = #header
      for _, row in pairs(pretty_rows) do
         local cell = tostring(row[header] or "")
         widths[i] = math.max(widths[i], #cell)
      end
   end

   local function pad(content, width)
      local padding = width - #content
      return content .. string.rep(" ", padding)
   end

   -- Print header row
   for i, header in ipairs(headers) do
      local title_header = header:gsub("^%l", string.upper)
      io.write(pad(title_header, widths[i]) .. "  ")
   end
   io.write("\n")

   -- Print header separator
   for i, _ in ipairs(headers) do
      io.write(string.rep("-", widths[i]) .. "  ")
   end
   io.write("\n")

   -- Print data rows
   for _, row in pairs(pretty_rows) do
      for i, header in ipairs(headers) do
         if row[header] then
            io.write(pad(row[header], widths[i]) .. "  ")
         end
      end
      io.write("\n")
   end
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

   return stats
end

--- Rank benchmark results (`timeit` or `memit`) by specified `key` and adds a 'rank' and 'ratio' key to each.
--- The smallest attribute value gets the rank 1 and ratio 1.0, other ratios are relative to it.
---@param benchmark_results {[string]:{[string]: any}} The benchmark results to rank, indexed by name.
---@param key string The stats to rank by.
---@return {[string]:{[string]: any}}
function luamark.rank(benchmark_results, key)
   assert(benchmark_results, "'benchmark_results' is nil or empty.")

   local ranks = {}
   for benchmark_name, stats in pairs(benchmark_results) do
      table.insert(ranks, { name = benchmark_name, value = stats[key] })
   end

   table.sort(ranks, function(a, b)
      return a.value < b.value
   end)

   local rank = 1
   local prev_value = nil
   local min = ranks[1].value
   for i, entry in ipairs(ranks) do
      if prev_value ~= entry.value then
         rank = i
         prev_value = entry.value
      end
      benchmark_results[entry.name].rank = rank
      benchmark_results[entry.name].ratio = rank == 1 and 1 or entry.value / min
   end
   return benchmark_results
end

-- ----------------------------------------------------------------------------
-- Benchmark
-- -----------------------------------------------s-----------------------------

---@param func fun(): any
---@param iterations? integer
---@param setup? fun():any
---@param teardown? fun():any
---@return number
local function _measure(measure_func, func, iterations, setup, teardown)
   local sum = 0
   for _ = 1, (iterations or 1) do
      if setup then
         setup()
      end

      local start = measure_func()
      func()
      sum = sum + measure_func() - start

      if teardown then
         teardown()
      end
   end
   return sum
end

---@param func fun(): any
---@param iterations? integer
---@param setup? fun():any
---@param teardown? fun():any
---@return number
local function measure_time(func, iterations, setup, teardown)
   return _measure(clock, func, iterations, setup, teardown)
end

---@param func fun(): any
---@param iterations? integer
---@param setup? fun():any
---@param teardown? fun():any
---@return number
local function measure_memory(func, iterations, setup, teardown)
   return _measure(function()
      return collectgarbage("count")
   end, func, iterations, setup, teardown)
end

--- Determine the round parameters
---@param func function The function to benchmark.
---@return number # Duration of a round.
local function calibrate_iterations(func, setup, teardown)
   local min_time = get_min_clocktime() * CALIBRATION_PRECISION

   local duration
   local iterations = 1
   while true do
      duration = measure_time(func, iterations, setup, teardown)
      if duration >= min_time then
         break
      end
      if duration >= clock_precision then
         iterations = math.ceil(min_time * iterations / duration)
         if iterations == 1 then
            -- Nothing to calibrate anymore
            break
         end
      else
         iterations = iterations * 10
      end
   end

   return math.min(iterations, MAX_ITERATIONS)
end

---Return pratical rounds and max time
---@param round_duration number
---@return integer rounds
---@return integer max_time
local function calibrate_stop(round_duration)
   local max_time = math.max(MIN_ROUNDS * round_duration, MIN_TIME)
   return math.min(max_time / round_duration, MAX_ROUNDS), max_time
end

--- Runs a benchmark on a function using a specified measurement method.
---@param func function The function to benchmark.
---@param measure function The measurement function to use (e.g., measure_time or measure_memory).
---@param rounds? number The number of rounds, i.e. set of runs
---@param max_time? number Maximum run time. It may be exceeded if test function is very slow.
---@param setup? fun():any Function executed before computing each benchmark value.
---@param teardown? fun():any Function executed after computing each benchmark value.
---@param disable_gc? boolean Whether to disable garbage collection during the benchmark.
---@return table # A table containing the results of the benchmark .
local function single_benchmark(
   func,
   measure,
   rounds,
   max_time,
   setup,
   teardown,
   disable_gc,
   unit,
   precision
)
   assert(
      type(func) == "function" or type("function") == "table",
      "'func' must be a function or a table of functions indexed by name."
   )
   assert(not rounds or rounds > 0, "'rounds' must be > 0.")
   assert(not max_time or max_time > 0, "'max_time' must be > 0.")
   assert(not setup or type(setup) == "function")
   assert(not teardown or type(teardown) == "function")
   disable_gc = disable_gc or true

   local iterations = calibrate_iterations(func, setup, teardown)
   for _ = 1, WARMUPS do
      measure(func, iterations, setup, teardown)
   end

   local timestamp = os.date("!%Y-%m-%d %H:%M:%SZ")
   local samples = {}
   local completed_rounds = 0
   local total_duration = 0
   local duration, start

   if disable_gc then
      collectgarbage("stop")
   end

   repeat
      completed_rounds = completed_rounds + 1
      start = clock()

      samples[completed_rounds] =
         math_round(measure(func, iterations, setup, teardown) / iterations, precision)

      duration = clock() - start
      total_duration = total_duration + duration
      if completed_rounds == 1 and not rounds and not max_time then
         -- Wait 1 round to gather a sample of loop duration,
         -- as memit can slow down the loop significantly because of the collectgarbage calls.
         rounds, max_time = calibrate_stop(duration)
      end
   until (max_time and total_duration >= (max_time - duration))
      or (rounds and completed_rounds == rounds)
      or (completed_rounds == MAX_ROUNDS)

   collectgarbage("restart")

   local results = calculate_stats(samples)
   results.rounds = completed_rounds
   results.iterations = iterations
   results.warmups = WARMUPS
   results.timestamp = timestamp
   results.unit = unit
   results.precision = precision

   setmetatable(results, {
      __tostring = function(self)
         return __tostring_stats(self, unit, precision)
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

   return luamark.rank(results, "mean")
end

--- Benchmarks a function for execution time. The time is represented in seconds.
---@param func (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param rounds? integer The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@param max_time? number Maximum run time. It may be exceeded if test function is very slow.
---@param setup? fun():any Function executed before the measured function.
---@param teardown? fun():any Function executed after the measured function.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.timeit(func, rounds, max_time, setup, teardown)
   return benchmark(
      func,
      measure_time,
      rounds,
      max_time,
      setup,
      teardown,
      true,
      "s",
      clock_precision
   )
end

--- Benchmarks a function for memory usage. The memory usage is represented in kilobytes.
---@param func (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param rounds? number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@param max_time? number Maximum run time. It may be exceeded if test function is very slow.
---@param setup? fun():any Function executed before the measured function.
---@param teardown? fun():any Function executed after the measured function.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.memit(func, rounds, max_time, setup, teardown)
   return benchmark(func, measure_memory, rounds, max_time, setup, teardown, false, "kb", 4)
end

-- Expose private to busted
-- luacheck:ignore 113
if _TEST then
   luamark.set_clock = set_clock
   luamark.get_min_clocktime = get_min_clocktime
   luamark.CALIBRATION_PRECISION = CALIBRATION_PRECISION
   luamark.measure_time = measure_time
   luamark.measure_memory = measure_memory
end

return luamark
