-- luamark - A lightweight, portable micro-benchmarking library.
-- Copyright (c) 2024 Jean-Francois Zinque. MIT License.

---@class luamark
local luamark = {
   _VERSION = "0.7.0",
}

-- ----------------------------------------------------------------------------
-- Config
-- ----------------------------------------------------------------------------

local MIN_TIME = 1
local CALIBRATION_PRECISION = 5
local MAX_INT = 2 ^ 1023

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
      clock = function()
         local time_spec = clock_gettime(CLOCK_MONOTONIC)
         return time_spec.tv_sec + time_spec.tv_nsec * get_min_clocktime()
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

---@alias NoArgFun fun(): any
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
      rounded = math.floor(num * mul + half) / mul
   else
      rounded = math.ceil(num * mul - half) / mul
   end
   return math.max(rounded, 10 ^ -precision)
end

---@alias default_unit `s` | `kb`

-- ----------------------------------------------------------------------------
-- Pretty Printing
-- ----------------------------------------------------------------------------

local TIME_UNITS = {
   { "m", 60 * 1e9 },
   { "s", 1e9 },
   { "ms", 1e6 },
   { "us", 1e3 },
   { "ns", 1 },
}

local MEMORY_UNITS = {
   { "TB", 1024 ^ 4 },
   { "GB", 1024 ^ 3 },
   { "MB", 1024 ^ 2 },
   { "kB", 1024 },
   { "B", 1 },
}

local function trim_zeroes(str)
   return str:gsub("%.?0+$", "")
end

---@param value integer
---@param base_unit default_unit
---@return string
local function format_stat(value, base_unit)
   local units
   if base_unit == "s" then
      units = TIME_UNITS
      base_unit = "ns"
      value = value * 1e9
   else
      units = MEMORY_UNITS
      base_unit = "B"
      value = value * 1024
   end

   for _, unit in ipairs(units) do
      local symbol, factor = unit[1], unit[2]
      if value >= factor then
         return trim_zeroes(string.format("%.2f", value / factor)) .. symbol
      end
   end

   return math.floor(value) .. base_unit
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

local function pad(content, width)
   local padding = width - string.len(content)
   return content .. string.rep(" ", padding)
end

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

---Return a string summarizing the results of multiple benchmarks.
---@param benchmark_results {[string]:{[string]: any}} The benchmark results to summarize, indexed by name.
---@return string
function luamark.summarize(benchmark_results)
   local pretty_rows = {}
   for benchmark_name, stats in pairs(benchmark_results) do
      local formatted = format_row(stats)
      formatted["name"] = benchmark_name
      table.insert(pretty_rows, formatted)
   end
   table.sort(pretty_rows, function(a, b)
      return tonumber(a.rank) < tonumber(b.rank)
   end)

   local headers = { "name", "rank", "ratio", "median", "mean", "min", "max", "stddev", "rounds" }

   -- Calculate column widths
   local widths = {}
   for i, header in ipairs(headers) do
      widths[i] = string.len(header)
      for _, row in pairs(pretty_rows) do
         local cell = tostring(row[header] or "")
         widths[i] = math.max(widths[i], string.len(cell))
      end
   end

   local lines = {}

   -- Header row
   local cells = {}
   for i, header in ipairs(headers) do
      header = header:gsub("^%l", string.upper)
      table.insert(cells, center(header, widths[i]) .. "  ")
   end
   table.insert(lines, table.concat(cells))

   -- Header separator
   cells = {}
   for i, _ in ipairs(headers) do
      table.insert(cells, string.rep("-", widths[i]) .. "  ")
   end
   table.insert(lines, table.concat(cells))

   -- Data rows
   for _, row in pairs(pretty_rows) do
      cells = {}
      for i, header in ipairs(headers) do
         if row[header] then
            table.insert(cells, pad(row[header], widths[i]))
         end
      end
      table.insert(lines, table.concat(cells, "  "))
   end

   return table.concat(lines, "\n")
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
local function rank(benchmark_results, key)
   assert(benchmark_results, "'benchmark_results' is nil or empty.")

   local ranks = {}
   for benchmark_name, stats in pairs(benchmark_results) do
      table.insert(ranks, { name = benchmark_name, value = stats[key] })
   end

   table.sort(ranks, function(a, b)
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
      benchmark_results[entry.name].ratio = rnk == 1 and 1 or entry.value / min
   end
   return benchmark_results
end

-- ----------------------------------------------------------------------------
-- Benchmark
-- -----------------------------------------------s-----------------------------

---@alias Measure fun(fn: NoArgFun, iterations: integer, setup?: function, teardown?: function): number

---@param measure_once MeasureOnce
---@param precision integer
---@return Measure
local function build_measure(measure_once, precision)
   return function(fn, iterations, setup, teardown)
      local total = 0
      for _ = 1, (iterations or 1) do
         if setup then
            setup()
         end

         total = total + measure_once(fn)

         if teardown then
            teardown()
         end
      end
      return math_round(total, precision)
   end
end

local measure_time = build_measure(measure_time_once, clock_precision)
local measure_memory = build_measure(measure_memory_once, 4)

--- Determine the round parameters
---@param fn NoArgFun The function to benchmark.
---@return number # Duration of a round.
local function calibrate_iterations(fn, setup, teardown)
   local min_time = get_min_clocktime() * CALIBRATION_PRECISION

   local duration
   local iterations = 1
   while true do
      duration = measure_time(fn, iterations, setup, teardown)
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

   return math.min(iterations, config.max_iterations)
end

---Return pratical rounds and max time
---@param round_duration number
---@return integer rounds
---@return integer max_time
local function calibrate_stop(round_duration)
   local max_time = math.max(config.min_rounds * round_duration, MIN_TIME)
   return math.min(max_time / round_duration, config.max_rounds), max_time
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
   assert(
      type(fn) == "function" or type("function") == "table",
      "'fn' must be a function or a table of functions indexed by name."
   )
   assert(not rounds or rounds > 0, "'rounds' must be > 0.")
   assert(not max_time or max_time > 0, "'max_time' must be > 0.")
   assert(not setup or type(setup) == "function")
   assert(not teardown or type(teardown) == "function")
   disable_gc = disable_gc or true

   local iterations = calibrate_iterations(fn, setup, teardown)
   for _ = 1, config.warmups do
      measure(fn, iterations, setup, teardown)
   end

   local timestamp = os.date("!%Y-%m-%d %H:%M:%SZ")
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

      samples[completed_rounds] = measure(fn, iterations, setup, teardown)

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

---@param funcs (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
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

local VALID_OPTS = {
   rounds = "number",
   max_time = "number",
   setup = "function",
   teardown = "function",
}

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
---@param fn (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param opts table Options table which may include rounds, max_time, setup, teardown.
---   - rounds: number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---   - max_time: number Maximum run time. It may be exceeded if test function is very slow.
---   - setup: function Function executed before the measured function.
---   - teardown: function Function executed after the measured function.
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
---@param fn (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param opts table Options table which may include rounds, max_time, setup, teardown.
---   - rounds: number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---   - max_time: number Maximum run time. It may be exceeded if test function is very slow.
---   - setup: function Function executed before the measured function.
---   - teardown: function Function executed after the measured function.
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

-- Expose private to busted
-- luacheck:ignore 113
if _TEST then
   luamark.CALIBRATION_PRECISION = CALIBRATION_PRECISION
   luamark.format_stat = format_stat
   luamark.get_min_clocktime = get_min_clocktime
   luamark.rank = rank
   luamark.measure_time = measure_time
   luamark.measure_memory = measure_memory
end

return setmetatable(luamark, {
   __index = config,
   __newindex = function(_, k, v)
      if config[k] == nil then
         error("Invalid config option: " .. k)
      end

      config[k] = v
   end,
})
