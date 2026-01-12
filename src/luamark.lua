-- luamark - A lightweight, portable micro-benchmarking library.
-- Copyright (c) 2025 Jean-Francois Zinque. MIT License.

---@class luamark
local luamark = {
   _VERSION = "0.9.0",
}

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
-- Dispatch loaded module to a function that returns the clock function and clock precision.
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

local DEFAULT_TERM_WIDTH = 100

---@return integer
local get_term_width
do
   local ok, system = pcall(require, "system")
   if ok and system.termsize then
      get_term_width = function()
         local rows, cols = system.termsize()
         if rows and cols then
            return cols
         end
         return DEFAULT_TERM_WIDTH
      end
   else
      get_term_width = function()
         return DEFAULT_TERM_WIDTH
      end
   end
end

-- ----------------------------------------------------------------------------
-- Utils
-- ----------------------------------------------------------------------------

-- Offset above 0.5 to handle floating-point edge cases in rounding
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
   return math.max(rounded, 10 ^ -(precision or 0))
end

-- ----------------------------------------------------------------------------
-- Statistics
-- ----------------------------------------------------------------------------

---@class Stats
---@field count integer Number of samples collected.
---@field mean number Arithmetic mean of samples.
---@field median number Median value of samples.
---@field min number Minimum sample value.
---@field max number Maximum sample value.
---@field stddev number Standard deviation of samples.
---@field total number Sum of all samples.
---@field samples number[] Raw samples (sorted).
---@field rounds integer Number of benchmark rounds executed.
---@field iterations integer Number of iterations per round.
---@field warmups integer Number of warmup rounds.
---@field timestamp string ISO 8601 UTC timestamp of benchmark start.
---@field unit "s"|"kb" Measurement unit (seconds or kilobytes).
---@field rank? integer Rank when comparing multiple benchmarks.
---@field ratio? number Ratio relative to fastest benchmark.

---@param samples number[]
---@return table
local function calculate_stats(samples)
   local stats = {}

   stats.count = #samples

   table.sort(samples)
   local mid = math.floor(#samples / 2)
   if math.fmod(#samples, 2) == 0 then
      stats.median = (samples[mid] + samples[mid + 1]) / 2
   else
      stats.median = samples[mid + 1]
   end

   stats.total = 0
   local min, max = math.huge, -math.huge
   for i = 1, stats.count do
      local sample = samples[i]
      stats.total = stats.total + sample
      min = math.min(sample, min)
      max = math.max(sample, max)
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
   stats.stddev = math.sqrt(variance)
   stats.samples = samples

   return stats
end

--- Rank benchmark results (`timeit` or `memit`) by specified `key` and adds a 'rank' and 'ratio' key to each.
--- The smallest attribute value gets the rank 1 and ratio 1.0, other ratios are relative to it.
---@param benchmark_results {[string]: Stats} The benchmark results to rank, indexed by name.
---@param key string The stats to rank by.
---@return {[string]: Stats}
local function rank(benchmark_results, key)
   assert(benchmark_results and next(benchmark_results), "'benchmark_results' is nil or empty.")

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
---@param format? "plain"|"compact"|"markdown"
---@return string
local function concat_line(t, format)
   if format == "plain" then
      return table.concat(t, "  ")
   end
   return "| " .. table.concat(t, " | ") .. " |"
end

local BAR_CHAR = "█"
local BAR_MAX_WIDTH = 20
local BAR_MIN_WIDTH = 10
local NAME_MIN_WIDTH = 4
local ELLIPSIS = "..."

---@param name string
---@param max_len integer
---@return string
local function truncate_name(name, max_len)
   if #name <= max_len then
      return name
   end
   if max_len <= #ELLIPSIS then
      return name:sub(1, max_len)
   end
   return name:sub(1, max_len - #ELLIPSIS) .. ELLIPSIS
end

---@param rows {name: string, ratio: string, median: string}[]
---@param max_width? integer
---@return string[]
local function build_bar_chart(rows, max_width)
   max_width = max_width or get_term_width()

   local max_ratio = 1
   local max_suffix_len = 0
   local max_name_len = NAME_MIN_WIDTH
   for i = 1, #rows do
      local row = rows[i]
      local ratio = tonumber(row.ratio) or 1
      if ratio > max_ratio then
         max_ratio = ratio
      end
      local suffix_len = 5 + #row.ratio + #row.median
      if suffix_len > max_suffix_len then
         max_suffix_len = suffix_len
      end
      if #row.name > max_name_len then
         max_name_len = #row.name
      end
   end

   local available = max_width - 3 - max_suffix_len
   -- Bar gets up to BAR_MAX_WIDTH, leaving at least NAME_MIN_WIDTH for names
   local bar_max = math.min(BAR_MAX_WIDTH, available - NAME_MIN_WIDTH)
   bar_max = math.max(BAR_MIN_WIDTH, bar_max)
   -- Names get remaining space, capped at actual max name length
   local name_max = math.max(NAME_MIN_WIDTH, math.min(max_name_len, available - bar_max))

   local lines = {}
   for i = 1, #rows do
      local row = rows[i]
      local ratio = tonumber(row.ratio) or 1
      local bar_width = math.max(1, math.floor((ratio / max_ratio) * bar_max))
      local name = pad(truncate_name(row.name, name_max), name_max)
      lines[i] = string.format(
         "%s  |%s %sx (%s)",
         name,
         string.rep(BAR_CHAR, bar_width),
         row.ratio,
         row.median
      )
   end
   return lines
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

---@param rows table[]
---@return string
local function build_csv(rows)
   local lines = { table.concat(SUMMARIZE_HEADERS, ",") }
   for _, row in ipairs(rows) do
      local cells = {}
      for i, header in ipairs(SUMMARIZE_HEADERS) do
         local value = row[header] or ""
         -- Escape commas and quotes in values
         if type(value) == "string" and (value:find(",") or value:find('"')) then
            value = '"' .. value:gsub('"', '""') .. '"'
         end
         cells[i] = tostring(value)
      end
      lines[#lines + 1] = table.concat(cells, ",")
   end
   return table.concat(lines, "\n")
end

---@param rows table[]
---@param widths integer[]
---@param format "plain"|"compact"|"markdown"
---@return string[]
local function build_table(rows, widths, format)
   local lines = {}

   local header_cells, underline_cells = {}, {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      header_cells[i] = center(header:gsub("^%l", string.upper), widths[i])
      underline_cells[i] = string.rep("-", widths[i])
   end
   lines[1] = concat_line(header_cells, format)
   lines[2] = concat_line(underline_cells, format)

   for r, row in ipairs(rows) do
      local cells = {}
      for i, header in ipairs(SUMMARIZE_HEADERS) do
         cells[i] = pad(row[header], widths[i])
      end
      lines[r + 2] = concat_line(cells, format)
   end

   return lines
end

---Return a string summarizing the results of multiple benchmarks.
---@param benchmark_results {[string]: Stats} The benchmark results to summarize, indexed by name.
---@param format? "plain"|"compact"|"markdown"|"csv" The output format
---@return string
function luamark.summarize(benchmark_results, format)
   assert(benchmark_results and next(benchmark_results), "'benchmark_results' is nil or empty.")
   format = format or "plain"
   assert(
      format == "plain" or format == "compact" or format == "markdown" or format == "csv",
      "format must be 'plain', 'compact', 'markdown', or 'csv'"
   )

   benchmark_results = rank(benchmark_results, "median")
   local rows = {}
   for name, stats in pairs(benchmark_results) do
      local row = format_row(stats)
      row.name = name
      rows[#rows + 1] = row
   end
   table.sort(rows, function(a, b)
      return tonumber(a.rank) < tonumber(b.rank)
   end)

   if format == "csv" then
      return build_csv(rows)
   end

   if format == "compact" then
      return table.concat(build_bar_chart(rows), "\n")
   end

   local widths = {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      widths[i] = #header
      for _, row in ipairs(rows) do
         widths[i] = math.max(widths[i], #(row[header] or ""))
      end
   end

   if format == "plain" then
      local other_width = 0
      for i = 2, #SUMMARIZE_HEADERS do
         other_width = other_width + widths[i]
      end
      local max_name =
         math.max(NAME_MIN_WIDTH, get_term_width() - other_width - (#SUMMARIZE_HEADERS - 1) * 2)
      if widths[1] > max_name then
         widths[1] = max_name
         for _, row in ipairs(rows) do
            row.name = truncate_name(row.name, max_name)
         end
      end
   end

   ---@cast format "plain"|"compact"|"markdown"
   local lines = build_table(rows, widths, format)

   if format == "plain" then
      local table_width = 0
      for i = 1, #widths do
         table_width = table_width + widths[i]
      end
      table_width = table_width + (#SUMMARIZE_HEADERS - 1) * 2

      lines[#lines + 1] = ""
      local bar_chart = build_bar_chart(rows, table_width)
      for i = 1, #bar_chart do
         lines[#lines + 1] = bar_chart[i]
      end
   end

   return table.concat(lines, "\n")
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
      iterations = math.ceil(iterations * scale)
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
   local max_time = math.max(config.min_rounds * round_duration, MIN_TIME)
   local rounds = math.ceil(math.min(max_time / round_duration, config.max_rounds))
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
---@return Stats
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

   local timestamp = os.date("!%Y-%m-%d %H:%M:%SZ") --[[@as string]]
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
   ---@cast results Stats

   setmetatable(results, {
      __tostring = function(self)
         return __tostring_stats(self, unit)
      end,
   })

   return results
end

---@param funcs fun()|({[string]: fun()}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param ... any arguments that will be forwarded to `single_benchmark`.
---@return Stats|{[string]: Stats} # Stats for single function, or table of Stats indexed by name for multiple functions.
local function benchmark(funcs, ...)
   if type(funcs) == "function" then
      return single_benchmark(funcs, ...)
   end

   ---@type {[string]: Stats}
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
---@param fn fun()|{[string]: fun()} A single zero-argument function or a table of zero-argument functions indexed by name.
---@param opts? BenchmarkOptions Options table for configuring the benchmark.
---@return Stats|{[string]: Stats} # Stats for single function, or table of Stats indexed by name for multiple functions.
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
---@param fn fun()|{[string]: fun()} A single zero-argument function or a table of zero-argument functions indexed by name.
---@param opts? BenchmarkOptions Options table for configuring the benchmark.
---@return Stats|{[string]: Stats} # Stats for single function, or table of Stats indexed by name for multiple functions.
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

---@package
luamark._internal = {
   CALIBRATION_PRECISION = CALIBRATION_PRECISION,
   DEFAULT_TERM_WIDTH = DEFAULT_TERM_WIDTH,
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
