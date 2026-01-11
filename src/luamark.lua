-- luamark - A lightweight, portable micro-benchmarking library.
-- Copyright (c) 2025 Jean-Francois Zinque. MIT License.

---@class luamark
local luamark = {
   _VERSION = "0.9.0",
}

local tconcat, tinsert, tsort = table.concat, table.insert, table.sort
local mmin, mmax, mhuge = math.min, math.max, math.huge
local msqrt, mfloor, mceil, mfmod = math.sqrt, math.floor, math.ceil, math.fmod
local pairs, ipairs, collectgarbage = pairs, ipairs, collectgarbage
local os_date = os.date

-- ----------------------------------------------------------------------------
-- Config
-- ----------------------------------------------------------------------------

local MIN_TIME = 1
local CALIBRATION_PRECISION = 5

local config = {
   max_iterations = 1e6,
   min_rounds = 100,
   max_rounds = 1e6,
   warmups = 1,
}

--------------------------------------------------------------------------
-- Time & Memory measurement functions
--------------------------------------------------------------------------------

local clock, clock_precision

---@return integer time The minimum measurable time difference based on clock precision
local function get_min_clocktime()
   return (10 ^ -clock_precision)
end

local CLOCK_PRIORITIES = { "chronos", "posix.time", "socket" }
--Dispatch loaded module to a function that returns the clock function and clock precision.
local CLOCKS = {
   chronos = function(chronos)
      return chronos.nanotime, 9
   end,
   ["posix.time"] = function(posix_time)
      local clock_gettime, CLOCK_MONOTONIC = posix_time.clock_gettime, posix_time.CLOCK_MONOTONIC
      if not clock_gettime then
         error("posix.time.clock_gettime is not supported on this OS.")
      end
      local NANO_TO_SEC = 1e-9
      clock = function()
         local time_spec = clock_gettime(CLOCK_MONOTONIC)
         return time_spec.tv_sec + time_spec.tv_nsec * NANO_TO_SEC
      end
      return clock, 9
   end,
   socket = function(socket)
      return socket.gettime, 4
   end,
}

for _, name in ipairs(CLOCK_PRIORITIES) do
   local is_installed, module = pcall(require, name)
   local ok
   if is_installed then
      ok, clock, clock_precision = pcall(CLOCKS[name], module)
   end
   if ok then
      luamark.clock_name = name
      break
   end
end

if not luamark.clock_name then
   clock, clock_precision = os.clock, _VERSION == "Luau" and 5 or 3
   luamark.clock_name = "os.clock"
end

---@alias NoArgFun fun()
---@alias MeasureOnce fun(fn: NoArgFun):number

---@type MeasureOnce
local function measure_time_once(fn)
   local start = clock()
   fn()
   return clock() - start
end

---@type MeasureOnce
local measure_memory_once
do
   local is_allocspy_installed, allocspy = pcall(require, "allocspy")
   if is_allocspy_installed then
      measure_memory_once = function(fn)
         collectgarbage("collect")
         allocspy.enable()
         fn()
         return allocspy.disable() / 1000
      end
   else
      measure_memory_once = function(fn)
         collectgarbage("collect")
         local start = collectgarbage("count")
         fn()
         return collectgarbage("count") - start
      end
   end
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
      rounded = mfloor(num * mul + half) / mul
   else
      rounded = mceil(num * mul - half) / mul
   end
   return mmax(rounded, 10 ^ -(precision or 0))
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

   tsort(samples)
   local mid = mfloor(#samples / 2)
   if mfmod(#samples, 2) == 0 then
      stats.median = (samples[mid] + samples[mid + 1]) / 2
   else
      stats.median = samples[mid + 1]
   end

   stats.total = 0
   local min, max = mhuge, -mhuge
   for i = 1, stats.count do
      local sample = samples[i]
      stats.total = stats.total + sample
      min = mmin(sample, min)
      max = mmax(sample, max)
   end

   stats.min = min
   stats.max = max
   stats.mean = stats.total / stats.count

   local variance = 0
   if stats.count > 1 then
      local sum_of_squares = 0
      for i = 1, stats.count do
         local d = samples[i] - stats.mean
         sum_of_squares = sum_of_squares + d * d
      end
      variance = sum_of_squares / (stats.count - 1)
   end
   stats.stddev = msqrt(variance)

   return stats
end

--- Rank benchmark results (`timeit` or `memit`) by specified `key` and adds a 'rank' and 'ratio' key to each.
--- The smallest attribute value gets the rank 1 and ratio 1.0, other ratios are relative to it.
---@param benchmark_results {[string]:{[string]: any}} The benchmark results to rank, indexed by name.
---@param key string The stats to rank by.
---@return {[string]:{[string]: any}}
local function rank(benchmark_results, key)
   assert(benchmark_results and next(benchmark_results), "'benchmark_results' is nil or empty.")

   local ranks = {}
   for benchmark_name, stats in pairs(benchmark_results) do
      tinsert(ranks, { name = benchmark_name, value = stats[key] })
   end

   tsort(ranks, function(a, b)
      return a.value < b.value
   end)

   local rnk = 1
   local prev_value = nil
   local min = ranks[1].value
   for i, entry in ipairs(ranks) do
      if prev_value ~= entry.value then
         rnk = i
         prev_value = entry.value
      end
      benchmark_results[entry.name].rank = rnk
      benchmark_results[entry.name].ratio = (rnk == 1 or min == 0) and 1 or entry.value / min
   end
   return benchmark_results
end

-- ----------------------------------------------------------------------------
-- Pretty Printing
-- ----------------------------------------------------------------------------

---@alias default_unit `s` | `kb`

-- Thresholds relative to input unit (seconds)
local TIME_UNITS = {
   { "m", 60 },
   { "s", 1 },
   { "ms", 1e-3 },
   { "us", 1e-6 },
   { "ns", 1e-9 },
}

-- Thresholds relative to input unit (kilobytes)
local MEMORY_UNITS = {
   { "TB", 1024 ^ 3 },
   { "GB", 1024 ^ 2 },
   { "MB", 1024 },
   { "kB", 1 },
   { "B", 1 / 1024 },
}

---@param str string
---@return string
local function trim_zeroes(str)
   return (str:gsub("%.?0+$", ""))
end

---@param value number
---@param base_unit default_unit
---@return string
local function format_stat(value, base_unit)
   local units = base_unit == "s" and TIME_UNITS or MEMORY_UNITS

   for _, unit in ipairs(units) do
      local symbol, threshold = unit[1], unit[2]
      if value >= threshold then
         return trim_zeroes(string.format("%.2f", value / threshold)) .. symbol
      end
   end

   local smallest = units[#units]
   return "0" .. smallest[1]
end

--- Formats statistical measurements into a readable string.
---@param stats table The statistical measurements to format.
---@param unit default_unit
---@return string # A formatted string representing the statistical metrics.
local function __tostring_stats(stats, unit)
   return string.format(
      "%s ± %s per round (%d rounds)",
      format_stat(stats.mean, unit),
      format_stat(stats.stddev, unit),
      stats.rounds
   )
end

---@param stats table
---@return table<string, string>
local function format_row(stats)
   local unit = stats.unit
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
         row[name] = format_stat(value, unit)
      else
         row[name] = tostring(value)
      end
   end
   return row
end

---@param content string
---@param width integer
---@return string
local function pad(content, width)
   local padding = width - string.len(content)
   return content .. string.rep(" ", padding)
end

---@param content string
---@param expected_width integer
---@return string
local function center(content, expected_width)
   local total_padding_size = expected_width - string.len(content)
   if total_padding_size < 0 then
      total_padding_size = 0
   end

   local left_padding_size = math.floor(total_padding_size / 2)
   local right_padding_size = total_padding_size - left_padding_size

   local left_padding = string.rep(" ", left_padding_size)
   local right_padding = string.rep(" ", right_padding_size)

   return left_padding .. content .. right_padding
end

---@param t string[]
---@param format? "plain"|"markdown"
---@return string
local function concat_line(t, format)
   if format == "plain" then
      return tconcat(t, "  ")
   end
   return "| " .. tconcat(t, " | ") .. " |"
end

local SUMMARIZE_HEADERS = {
   "name",
   "rank",
   "ratio",
   "median",
   "mean",
   "min",
   "max",
   "stddev",
   "rounds",
}

---Return a string summarizing the results of multiple benchmarks.
---@param benchmark_results {[string]:{[string]: any}} The benchmark results to summarize, indexed by name.
---@param format? "plain"|"markdown" The output format
---@return string
function luamark.summarize(benchmark_results, format)
   assert(benchmark_results and next(benchmark_results), "'benchmark_results' is nil or empty.")
   format = format or "plain"
   assert(format == "plain" or format == "markdown", "format must be 'plain' or 'markdown'")

   -- Format rows
   benchmark_results = rank(benchmark_results, "median")
   local rows = {}
   for benchmark_name, stats in pairs(benchmark_results) do
      local formatted = format_row(stats)
      formatted["name"] = benchmark_name
      tinsert(rows, formatted)
   end
   tsort(rows, function(a, b)
      return tonumber(a.rank) < tonumber(b.rank)
   end)

   -- Calculate column widths
   local widths = {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      widths[i] = #header
      for _, row in ipairs(rows) do
         widths[i] = math.max(widths[i], #tostring(row[header] or ""))
      end
   end

   local lines = {}

   -- Header row
   local header_row, header_underline = {}, {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      header = header:gsub("^%l", string.upper)
      tinsert(header_row, center(header, widths[i]))
      tinsert(header_underline, string.rep("-", widths[i]))
   end
   tinsert(lines, concat_line(header_row, format))
   tinsert(lines, concat_line(header_underline, format))

   -- Data rows
   for _, row in ipairs(rows) do
      local cells = {}
      for i, header in ipairs(SUMMARIZE_HEADERS) do
         cells[#cells + 1] = pad(row[header], widths[i])
      end
      lines[#lines + 1] = concat_line(cells, format)
   end

   return tconcat(lines, "\n")
end

-- ----------------------------------------------------------------------------
-- Benchmark
-- ----------------------------------------------------------------------------

---@alias Measure fun(fn: NoArgFun, iterations: integer, setup?: function, teardown?: function): number, number

---@param measure_once MeasureOnce
---@param precision integer
---@return Measure
local function build_measure(measure_once, precision)
   return function(fn, iterations, setup, teardown)
      local total = 0
      for _ = 1, iterations do
         if setup then
            setup()
         end

         total = total + measure_once(fn)

         if teardown then
            teardown()
         end
      end
      return total, math_round(total / iterations, precision)
   end
end

local measure_time = build_measure(measure_time_once, clock_precision)
local measure_memory = build_measure(measure_memory_once, 4)

---@param fn NoArgFun The function to benchmark.
---@param setup? function Function executed before each iteration.
---@param teardown? function Function executed after each iteration.
---@return integer # Number of iterations per round.
local function calibrate_iterations(fn, setup, teardown)
   local min_time = get_min_clocktime() * CALIBRATION_PRECISION
   local iterations = 1

   while true do
      local round_total = measure_time(fn, iterations, setup, teardown)
      if round_total >= min_time then
         break
      end
      local scale = min_time / ((round_total > 0) and round_total or get_min_clocktime())
      iterations = mceil(iterations * scale)
      if iterations <= 1 then
         iterations = 1
         break
      end
      if iterations >= config.max_iterations then
         iterations = config.max_iterations
         break
      end
   end

   return iterations
end

---Return pratical rounds and max time
---@param round_duration number
---@return integer rounds
---@return integer max_time
local function calibrate_stop(round_duration)
   local max_time = mmax(config.min_rounds * round_duration, MIN_TIME)
   local rounds = mceil(mmin(max_time / round_duration, config.max_rounds))
   return rounds, max_time
end

--- Runs a benchmark on a function using a specified measurement method.
---@param fn NoArgFun The function to benchmark.
---@param measure Measure The measurement function to use (e.g., measure_time or measure_memory).
---@param disable_gc boolean Whether to disable garbage collection during the benchmark.
---@param unit default_unit The unit of the measurement result.
---@param rounds? number The number of rounds, i.e. set of runs
---@param max_time? number Maximum run time. It may be exceeded if test function is very slow.
---@param setup? function Function executed before computing each benchmark value.
---@param teardown? function Function executed after computing each benchmark value.
---@return table # A table containing the results of the benchmark .
local function single_benchmark(fn, measure, disable_gc, unit, rounds, max_time, setup, teardown)
   assert(type(fn) == "function", "'fn' must be a function.")
   assert(not rounds or rounds > 0, "'rounds' must be > 0.")
   assert(not max_time or max_time > 0, "'max_time' must be > 0.")
   assert(not setup or type(setup) == "function")
   assert(not teardown or type(teardown) == "function")
   if disable_gc == nil then
      disable_gc = true
   end

   local iterations = calibrate_iterations(fn, setup, teardown)
   for _ = 1, config.warmups do
      measure(fn, iterations, setup, teardown)
   end

   local timestamp = os_date("!%Y-%m-%d %H:%M:%SZ")
   local samples = {}
   local completed_rounds = 0
   local total_duration = 0
   local duration, start

   if disable_gc then
      pcall(collectgarbage, "stop")
   end

   repeat
      completed_rounds = completed_rounds + 1
      start = clock()

      local _, iteration_measure = measure(fn, iterations, setup, teardown)
      samples[completed_rounds] = iteration_measure

      duration = clock() - start
      total_duration = total_duration + duration
      if completed_rounds == 1 and not rounds and not max_time then
         -- Wait 1 round to gather a sample of loop duration,
         -- as memit can slow down the loop significantly because of the collectgarbage calls.
         rounds, max_time = calibrate_stop(duration)
      end
   until (max_time and total_duration >= (max_time - duration))
      or (rounds and completed_rounds == rounds)
      or (completed_rounds == config.max_rounds)

   pcall(collectgarbage, "restart")

   local results = calculate_stats(samples)
   results.rounds = completed_rounds
   results.iterations = iterations
   results.warmups = config.warmups
   results.timestamp = timestamp
   results.unit = unit

   setmetatable(results, {
      __tostring = function(self)
         return __tostring_stats(self, unit)
      end,
   })

   return results
end

---@param funcs fun()|({[string]: fun()}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param ... any arguments that will be forwarded to `single_benchmark`.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
local function benchmark(funcs, ...)
   if type(funcs) == "function" then
      return single_benchmark(funcs, ...)
   end

   local results = {}
   for name, fn in pairs(funcs) do
      results[name] = single_benchmark(fn, ...)
   end

   local stats = rank(results, "median")
   setmetatable(stats, {
      __tostring = function(self)
         return luamark.summarize(self)
      end,
   })
   return stats
end

---@class BenchmarkOptions
---@field rounds? integer The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@field max_time? number Maximum run time in seconds. It may be exceeded if test function is very slow.
---@field setup? fun()  Function executed before the measured function.
---@field teardown? fun() Function executed after the measured function.

local VALID_OPTS = {
   rounds = "number",
   max_time = "number",
   setup = "function",
   teardown = "function",
}

---@param opts BenchmarkOptions
local function check_options(opts)
   for k, v in pairs(opts) do
      local opt_type = VALID_OPTS[k]
      if not opt_type then
         error("Unknown option: " .. k)
      end
      if type(v) ~= opt_type then
         error(string.format("Option '%s' should be %s", k, opt_type))
      end
   end
end

--- Benchmarks a function for execution time. The time is represented in seconds.
---@param fn fun()|({[string]: fun()}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param opts? BenchmarkOptions Options table for configuring the benchmark.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.timeit(fn, opts)
   opts = opts or {}
   check_options(opts)
   return benchmark(
      fn,
      measure_time,
      true,
      "s",
      opts.rounds,
      opts.max_time,
      opts.setup,
      opts.teardown
   )
end

--- Benchmarks a function for memory usage. The memory usage is represented in kilobytes.
---@param fn fun()|({[string]: fun()}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param opts? BenchmarkOptions Options table for configuring the benchmark.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.memit(fn, opts)
   opts = opts or {}
   check_options(opts)
   return benchmark(
      fn,
      measure_memory,
      false,
      "kb",
      opts.rounds,
      opts.max_time,
      opts.setup,
      opts.teardown
   )
end

luamark._internal = {
   CALIBRATION_PRECISION = CALIBRATION_PRECISION,
   calculate_stats = calculate_stats,
   format_stat = format_stat,
   get_min_clocktime = get_min_clocktime,
   measure_memory = measure_memory,
   measure_time = measure_time,
   rank = rank,
}

return setmetatable(luamark, {
   __index = config,
   __newindex = function(_, k, v)
      if config[k] == nil then
         error("Invalid config option: " .. k)
      end
      if type(v) ~= "number" or v <= 0 then
         error("Config value must be a positive number")
      end
      config[k] = v
   end,
})
