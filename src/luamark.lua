--- luamark - A lightweight, portable micro-benchmarking library for Lua.
--- Provides `timeit` and `memit` functions for measuring execution time and memory usage,
--- with automatic calibration, statistical analysis, and multiple output formats.
---@module "luamark"
-- Copyright (c) 2026 Jean-Francois Zinque. MIT License.

---@class luamark
local luamark = {
   _VERSION = "0.9.1",
}

-- ----------------------------------------------------------------------------
-- Config
-- ----------------------------------------------------------------------------

-- Minimum benchmark duration in seconds before calibration stops.
local MIN_TIME = 1

-- Multiplier for clock precision to determine minimum measurable time.
-- Higher values require longer runs but produce more stable measurements.
local CALIBRATION_PRECISION = 5

-- Precision for memory measurements (decimal places in KB).
local MEMORY_PRECISION = 4

local BYTES_TO_KB = 1024

-- Maximum attempts to calibrate iterations before giving up.
local MAX_CALIBRATION_ATTEMPTS = 10

local config = {
   max_iterations = 1e6,
   min_rounds = 100,
   max_rounds = 1e6,
   warmups = 1,
}

-- ----------------------------------------------------------------------------
-- Time & Memory measurement functions
-- ----------------------------------------------------------------------------

---@type fun(): number
local clock
---@type integer
local clock_precision

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
      return function()
         local time_spec = clock_gettime(CLOCK_MONOTONIC)
         return time_spec.tv_sec + time_spec.tv_nsec * NANO_TO_SEC
      end,
         9
   end,
   socket = function(socket)
      return socket.gettime, 4
   end,
}

for i = 1, #CLOCK_PRIORITIES do
   local name = CLOCK_PRIORITIES[i]
   local is_installed, module = pcall(require, name)
   if is_installed then
      local ok
      ok, clock, clock_precision = pcall(CLOCKS[name], module)
      if ok then
         luamark.clock_name = name
         break
      end
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
   -- Normalize allocspy (bytes) to match collectgarbage (KiB)
   if is_allocspy_installed then
      measure_memory_once = function(fn)
         collectgarbage("collect")
         allocspy.enable()
         fn()
         return allocspy.disable() / BYTES_TO_KB
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
         local _, cols = system.termsize()
         if type(cols) == "number" then
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

---@generic K, V
---@param tbl table<K, V>
---@return K[]
local function sorted_keys(tbl)
   local keys = {}
   for key in pairs(tbl) do
      keys[#keys + 1] = key
   end
   table.sort(keys)
   return keys
end

---@generic K, V
---@param tbl table<K, V>
---@return table<K, V>
local function shallow_copy(tbl)
   local copy = {}
   for key, value in pairs(tbl) do
      copy[key] = value
   end
   return copy
end

---@param target any[]
---@param source any[]
local function array_extend(target, source)
   for i = 1, #source do
      target[#target + 1] = source[i]
   end
end

-- Offset above 0.5 to handle floating-point edge cases in rounding.
local half = 0.50000000000008

---@param num number Non-negative number to round.
---@param precision number
---@return number
local function math_round(num, precision)
   assert(num >= 0, "math_round expects a non-negative number")
   local mul = 10 ^ (precision or 0)
   local rounded = math.floor(num * mul + half) / mul
   return math.max(rounded, 10 ^ -(precision or 0))
end

-- ----------------------------------------------------------------------------
-- Statistics
-- ----------------------------------------------------------------------------

---@class BaseStats
---@field count integer Number of samples collected.
---@field mean number Arithmetic mean of samples.
---@field median number Median value of samples.
---@field min number Minimum sample value.
---@field max number Maximum sample value.
---@field stddev number Standard deviation of samples.
---@field total number Sum of all samples.
---@field samples number[] Raw samples (sorted).

---@class Stats : BaseStats
---@field rounds integer Number of benchmark rounds executed.
---@field iterations integer Number of iterations per round.
---@field warmups integer Number of warmup rounds.
---@field timestamp string ISO 8601 UTC timestamp of benchmark start.
---@field unit "s"|"kb" Measurement unit (seconds or kilobytes).
---@field rank? integer Rank when comparing multiple benchmarks.
---@field ratio? number Ratio relative to fastest benchmark.

--- WARNING: Sorts samples array in place.
---@param samples number[]
---@return BaseStats
local function calculate_stats(samples)
   assert(#samples > 0, "samples cannot be empty")

   table.sort(samples)

   local count = #samples
   local mid = math.floor(count / 2)
   local median
   if math.fmod(count, 2) == 0 then
      median = (samples[mid] + samples[mid + 1]) / 2
   else
      median = samples[mid + 1]
   end

   local total = 0
   local min, max = math.huge, -math.huge
   for i = 1, count do
      local sample = samples[i]
      total = total + sample
      min = math.min(sample, min)
      max = math.max(sample, max)
   end

   local mean = total / count

   local variance = 0
   if count > 1 then
      local sum_of_squares = 0
      for i = 1, count do
         local d = samples[i] - mean
         sum_of_squares = sum_of_squares + d * d
      end
      variance = sum_of_squares / (count - 1)
   end

   local stats = {
      count = count,
      mean = mean,
      median = median,
      min = min,
      max = max,
      stddev = math.sqrt(variance),
      total = total,
      samples = samples,
   }

   return stats
end

--- Rank results by `key`, adding 'rank' and 'ratio' fields (smallest = rank 1, ratio 1.0).
---@param benchmark_results {[string]: Stats}
---@param key string Field to rank by (e.g., "median", "mean").
---@return {[string]: Stats}
local function rank(benchmark_results, key)
   assert(benchmark_results and next(benchmark_results), "'benchmark_results' is nil or empty.")

   local ranks = {}
   for benchmark_name, stats in pairs(benchmark_results) do
      local value = stats[key]
      assert(
         value ~= nil,
         string.format("stats['%s'] is nil for benchmark '%s'", key, benchmark_name)
      )
      table.insert(ranks, { name = benchmark_name, value = value })
   end

   table.sort(ranks, function(a, b)
      return a.value < b.value
   end)

   local rnk = 1
   local prev_value = nil
   local min = ranks[1].value
   for i = 1, #ranks do
      local entry = ranks[i]
      if prev_value ~= entry.value then
         rnk = i
         prev_value = entry.value
      end
      local result = benchmark_results[entry.name]
      result.rank = rnk
      if rnk == 1 or min == 0 then
         result.ratio = 1
      else
         result.ratio = entry.value / min
      end
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

   for i = 1, #units do
      local symbol, threshold = units[i][1], units[i][2]
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

local UNIT_FIELDS = { min = true, max = true, mean = true, stddev = true, median = true }

--- Fields to include in formatted output (SUMMARIZE_HEADERS minus 'name', plus 'ratio').
local FORMAT_ROW_FIELDS = {
   "rank",
   "ratio",
   "median",
   "mean",
   "min",
   "max",
   "stddev",
   "rounds",
}

--- Format stats fields into strings for display.
---@param stats Stats
---@return table<string, string>
local function format_row(stats)
   local unit = stats.unit
   local row = {}
   for i = 1, #FORMAT_ROW_FIELDS do
      local name = FORMAT_ROW_FIELDS[i]
      local value = stats[name]
      if value ~= nil then
         if name == "ratio" then
            row[name] = string.format("%.2f", value)
         elseif UNIT_FIELDS[name] then
            row[name] = format_stat(value, unit)
         else
            row[name] = tostring(value)
         end
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
      max_ratio = math.max(max_ratio, ratio)
      max_suffix_len = math.max(max_suffix_len, 5 + #row.ratio + #row.median)
      max_name_len = math.max(max_name_len, #row.name)
   end

   local available = max_width - 3 - max_suffix_len
   -- Ensure we have minimum space for both bar and name
   local min_total = BAR_MIN_WIDTH + NAME_MIN_WIDTH
   if available < min_total then
      available = min_total
   end
   -- Bar gets up to BAR_MAX_WIDTH, leaving at least NAME_MIN_WIDTH for names
   local bar_max = math.min(BAR_MAX_WIDTH, available - NAME_MIN_WIDTH)
   bar_max = math.max(BAR_MIN_WIDTH, bar_max)
   -- Names get remaining space, capped at actual max name length
   -- Clamp to ensure bar_max + name_max never exceeds available
   local name_max = math.min(max_name_len, available - bar_max)
   name_max = math.max(NAME_MIN_WIDTH, name_max)

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

---@param results {[string]: Stats}|SuiteResult
---@return boolean
local function is_suite_result(results)
   -- Suite results have group -> benchmark -> params -> stats structure
   -- Check if first level contains tables with nested stats (only check first element)
   local _, group_value = next(results)
   if type(group_value) ~= "table" or group_value.median then
      return false
   end
   local _, bench_value = next(group_value)
   return type(bench_value) == "table" and not bench_value.median
end

---@alias ParamValues table<string, any> Map of parameter names to their current values

---@param params ParamValues
---@return string
local function format_params(params)
   local keys = sorted_keys(params)
   local parts = {}
   for i = 1, #keys do
      local name = keys[i]
      parts[i] = name .. "=" .. tostring(params[name])
   end
   return table.concat(parts, ", ")
end

---@class FlattenedRow
---@field group string Group name
---@field benchmark string Benchmark name
---@field params ParamValues Parameter values for this run
---@field stats Stats Benchmark statistics

---Traverse nested param structure to find stats and collect rows
---@param tbl table Nested structure to traverse (terminates at Stats with median field)
---@param params ParamValues Accumulated parameter values
---@param group_name string
---@param bench_name string
---@param rows FlattenedRow[]
local function traverse_params(tbl, params, group_name, bench_name, rows)
   if tbl.median then
      ---@cast tbl Stats
      rows[#rows + 1] = {
         group = group_name,
         benchmark = bench_name,
         params = params,
         stats = tbl,
      }
      return
   end

   for key, value in pairs(tbl) do
      if type(value) == "table" then
         for param_value, nested in pairs(value) do
            local new_params = shallow_copy(params)
            new_params[key] = param_value
            traverse_params(nested, new_params, group_name, bench_name, rows)
         end
      end
   end
end

---@param results SuiteResult
---@return FlattenedRow[]
local function flatten_suite_results(results)
   local rows = {}

   for group_name, group in pairs(results) do
      for bench_name, bench in pairs(group) do
         traverse_params(bench, {}, group_name, bench_name, rows)
      end
   end

   return rows
end

---@param value any
---@return string
local function escape_csv(value)
   value = tostring(value)
   if value:find(",") or value:find('"') then
      return '"' .. value:gsub('"', '""') .. '"'
   end
   return value
end

---@param flat FlattenedRow[]
---@return string[]
local function collect_param_names(flat)
   local seen = {}
   for i = 1, #flat do
      for name in pairs(flat[i].params) do
         seen[name] = true
      end
   end
   return sorted_keys(seen)
end

---@param flat FlattenedRow[]
---@return string
local function build_suite_csv(flat)
   local param_names = collect_param_names(flat)

   -- Build header
   local headers = { "group", "benchmark" }
   for i = 1, #param_names do
      headers[#headers + 1] = param_names[i]
   end
   for i = 1, #SUMMARIZE_HEADERS do
      local h = SUMMARIZE_HEADERS[i]
      if h ~= "name" then
         headers[#headers + 1] = h
      end
   end

   local lines = { table.concat(headers, ",") }

   table.sort(flat, function(a, b)
      if a.group ~= b.group then
         return a.group < b.group
      end
      if a.benchmark ~= b.benchmark then
         return a.benchmark < b.benchmark
      end
      return format_params(a.params) < format_params(b.params)
   end)

   for i = 1, #flat do
      local row = flat[i]
      local cells = { escape_csv(row.group), escape_csv(row.benchmark) }
      for j = 1, #param_names do
         cells[#cells + 1] = escape_csv(row.params[param_names[j]] or "")
      end

      local formatted = format_row(row.stats)
      for j = 1, #SUMMARIZE_HEADERS do
         local h = SUMMARIZE_HEADERS[j]
         if h ~= "name" then
            cells[#cells + 1] = escape_csv(formatted[h] or "")
         end
      end

      lines[#lines + 1] = table.concat(cells, ",")
   end

   return table.concat(lines, "\n")
end

---@param rows table[]
---@return string
local function build_csv(rows)
   local lines = { table.concat(SUMMARIZE_HEADERS, ",") }
   for i = 1, #rows do
      local row = rows[i]
      local cells = {}
      for j = 1, #SUMMARIZE_HEADERS do
         cells[j] = escape_csv(row[SUMMARIZE_HEADERS[j]] or "")
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
   for i = 1, #SUMMARIZE_HEADERS do
      local header = SUMMARIZE_HEADERS[i]
      header_cells[i] = center(header:gsub("^%l", string.upper), widths[i])
      underline_cells[i] = string.rep("-", widths[i])
   end
   lines[1] = concat_line(header_cells, format)
   lines[2] = concat_line(underline_cells, format)

   for r = 1, #rows do
      local row = rows[r]
      local cells = {}
      for i = 1, #SUMMARIZE_HEADERS do
         cells[i] = pad(row[SUMMARIZE_HEADERS[i]], widths[i])
      end
      lines[r + 2] = concat_line(cells, format)
   end

   return lines
end

---@param ranked_results {[string]: Stats}
---@return table[]
local function format_ranked_rows(ranked_results)
   local rows = {}
   for name, stats in pairs(ranked_results) do
      local row = format_row(stats)
      row.name = name
      rows[#rows + 1] = row
   end
   table.sort(rows, function(a, b)
      local rank_a, rank_b = tonumber(a.rank), tonumber(b.rank)
      if rank_a ~= rank_b then
         return rank_a < rank_b
      end
      return a.name < b.name
   end)
   return rows
end

---@param rows table[]
---@return integer[]
local function calculate_widths(rows)
   local widths = {}
   for i = 1, #SUMMARIZE_HEADERS do
      local header = SUMMARIZE_HEADERS[i]
      widths[i] = #header
      for j = 1, #rows do
         widths[i] = math.max(widths[i], #(rows[j][header] or ""))
      end
   end
   return widths
end

---@class GroupedBenchmarks
---@field name string Group name
---@field params ParamValues Parameter values for this group
---@field benchmarks table<string, Stats> Benchmark name to stats

---@param flat FlattenedRow[]
---@return GroupedBenchmarks[]
local function collect_benchmark_groups(flat)
   local groups = {} ---@type table<string, GroupedBenchmarks>
   for i = 1, #flat do
      local row = flat[i]
      local key = row.group .. "|" .. format_params(row.params)
      if not groups[key] then
         groups[key] = {
            name = row.group,
            params = row.params,
            benchmarks = {},
         }
      end
      groups[key].benchmarks[row.benchmark] = row.stats
   end

   local sorted = {}
   for _, group in pairs(groups) do
      sorted[#sorted + 1] = group
   end
   table.sort(sorted, function(a, b)
      if a.name ~= b.name then
         return a.name < b.name
      end
      return format_params(a.params) < format_params(b.params)
   end)
   return sorted
end

---@param results SuiteResult
---@param format "plain"|"compact"|"markdown"|"csv"
---@param max_width? integer
---@return string
local function summarize_suite(results, format, max_width)
   local flat = flatten_suite_results(results)

   if format == "csv" then
      return build_suite_csv(flat)
   end
   ---@cast format "plain"|"compact"|"markdown"

   max_width = max_width or get_term_width()
   local output = {}
   local benchmark_groups = collect_benchmark_groups(flat)
   for i = 1, #benchmark_groups do
      local group = benchmark_groups[i]
      local header = group.name
      if next(group.params) then
         header = header .. " (" .. format_params(group.params) .. ")"
      end
      output[#output + 1] = header

      local ranked = rank(group.benchmarks, "median")
      local rows = format_ranked_rows(ranked)

      if format == "compact" then
         array_extend(output, build_bar_chart(rows, max_width))
      else
         local widths = calculate_widths(rows)
         array_extend(output, build_table(rows, widths, format))
         if format == "plain" then
            output[#output + 1] = ""
            array_extend(output, build_bar_chart(rows, max_width))
         end
      end
      output[#output + 1] = ""
   end

   return table.concat(output, "\n")
end

---@param results {[string]: Stats}
---@param format "plain"|"compact"|"markdown"|"csv"
---@param max_width? integer
---@return string
local function summarize_benchmark(results, format, max_width)
   results = rank(results, "median")
   local rows = format_ranked_rows(results)

   if format == "csv" then
      return build_csv(rows)
   end

   max_width = max_width or get_term_width()

   if format == "compact" then
      return table.concat(build_bar_chart(rows, max_width), "\n")
   end

   local widths = calculate_widths(rows)

   if format == "plain" then
      local other_width = 0
      for i = 2, #SUMMARIZE_HEADERS do
         other_width = other_width + widths[i]
      end
      local max_name =
         math.max(NAME_MIN_WIDTH, max_width - other_width - (#SUMMARIZE_HEADERS - 1) * 2)
      if widths[1] > max_name then
         widths[1] = max_name
         for i = 1, #rows do
            rows[i].name = truncate_name(rows[i].name, max_name)
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
      array_extend(lines, build_bar_chart(rows, table_width))
   end

   return table.concat(lines, "\n")
end

-- ----------------------------------------------------------------------------
-- Benchmark
-- ----------------------------------------------------------------------------

---@alias Measure fun(fn: NoArgFun, iterations: integer, setup?: function, teardown?: function): number, number

--- Build a measurement function that runs fn multiple iterations and returns totals.
---@param measure_once MeasureOnce Function to measure a single execution.
---@param precision integer Decimal precision for rounding results.
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
local measure_memory = build_measure(measure_memory_once, MEMORY_PRECISION)

---@param fn NoArgFun The function to benchmark.
---@param setup? function Function executed before each iteration.
---@param teardown? function Function executed after each iteration.
---@return integer # Number of iterations per round.
local function calibrate_iterations(fn, setup, teardown)
   local min_time = get_min_clocktime() * CALIBRATION_PRECISION
   local iterations = 1

   for _ = 1, MAX_CALIBRATION_ATTEMPTS do
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

---Return practical rounds and max time
---@param round_duration number
---@return integer rounds
---@return number max_time
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

   -- Use pcall because some Lua environments (e.g., older versions, embedded) may not support "restart".
   pcall(collectgarbage, "restart")

   local results = calculate_stats(samples) --[[@as Stats]]
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

--- Validate benchmark options, raising an error for unknown or mistyped options.
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
   if opts.rounds ~= nil then
      if opts.rounds ~= math.floor(opts.rounds) then
         error("Option 'rounds' must be an integer")
      end
      if opts.rounds <= 0 then
         error("Option 'rounds' must be positive")
      end
   end
   if opts.max_time ~= nil and opts.max_time <= 0 then
      error("Option 'max_time' must be positive")
   end
end

-- ----------------------------------------------------------------------------
-- Suite
-- ----------------------------------------------------------------------------

-- Suite Input Types

---@class SuiteBenchmarkOpts Benchmark with optional setup/teardown
---@field fn function The function to benchmark
---@field setup? fun(params: ParamValues) Per-benchmark setup (untimed)
---@field teardown? fun(params: ParamValues) Per-benchmark teardown (untimed)

---@class SuiteOpts Shared configuration for a group
---@field params? table<string, any[]> Parameter names to value arrays (cartesian product)
---@field setup? fun(params: ParamValues) Shared setup (untimed, runs before benchmark setup)
---@field teardown? fun(params: ParamValues) Shared teardown (untimed, runs after benchmark teardown)
---@field rounds? integer Number of benchmark rounds
---@field max_time? number Maximum time for benchmarking

---@alias SuiteBenchmark function|SuiteBenchmarkOpts Either a bare function or config with fn

---@class SuiteGroup Group definition with benchmarks
---@field opts? SuiteOpts Shared configuration (only reserved key)
---@field [string] SuiteBenchmark Benchmarks (all other keys)

---@alias SuiteSpec table<string, SuiteGroup> Map of group names to group definitions

-- Suite Result Types

---@alias SuiteParamResult table<any, Stats|SuiteParamResult> Nested params leading to Stats

---@alias SuiteBenchmarkResult table<string, SuiteParamResult>|Stats Stats keyed by params, or Stats directly if no params

---@alias SuiteGroupResult table<string, SuiteBenchmarkResult> Benchmark name to param results

---@alias SuiteResult table<string, SuiteGroupResult> Group name to benchmark results

-- Internal Types

---@class ParsedBenchmark
---@field fn function
---@field setup? function
---@field teardown? function

---@class ParsedGroup
---@field [string] ParsedBenchmark
---@field opts? SuiteOpts

---@param spec SuiteSpec
---@return table<string, ParsedGroup>
local function parse_suite(spec)
   assert(spec and next(spec), "spec is empty")

   local parsed = {}

   for group_name, group_config in pairs(spec) do
      assert(type(group_config) == "table", string.format("group '%s' must be a table", group_name))

      parsed[group_name] = { opts = {} }
      local has_benchmark = false

      for key, value in pairs(group_config) do
         if key == "opts" then
            assert(
               type(value) == "table" and not value.fn,
               "'opts' is reserved for configuration, cannot be used as benchmark name"
            )
            parsed[group_name].opts = value
         elseif type(value) == "function" then
            parsed[group_name][key] = { fn = value }
            has_benchmark = true
         elseif type(value) == "table" then
            assert(
               type(value.fn) == "function",
               string.format("benchmark '%s' must be a function or table with 'fn' function", key)
            )
            parsed[group_name][key] = {
               fn = value.fn,
               setup = value.setup,
               teardown = value.teardown,
            }
            has_benchmark = true
         else
            error(string.format("benchmark '%s' must be a function or table with 'fn'", key))
         end
      end

      assert(has_benchmark, string.format("group '%s' has no benchmarks", group_name))
   end

   return parsed
end

local VALID_PARAM_TYPES = { string = true, number = true, boolean = true }

---@param n number
---@return boolean
local function is_nan_or_inf(n)
   return n ~= n or n == math.huge or n == -math.huge
end

---Store a value at a nested path based on parameter values.
---Creates intermediate tables as needed. Keys are sorted alphabetically.
---Example: set_nested(t, {n=100, type="array"}, stats) -> t.n[100].type["array"] = stats
---Returns false when params are empty (caller should assign value directly).
---Note: Param values must be primitives (string, number, boolean) for stable table keys and CSV output.
---@param tbl table Target table to store into
---@param params ParamValues Parameter names to values defining the path (values must be primitives)
---@param value any Value to store at the nested path
---@return boolean stored True if value was stored, false if params were empty
local function set_nested(tbl, params, value)
   local names = sorted_keys(params)

   if #names == 0 then
      return false
   end

   local current = tbl
   for i = 1, #names do
      local name = names[i]
      local param_value = params[name]
      local param_type = type(param_value)
      if not VALID_PARAM_TYPES[param_type] then
         error(
            string.format(
               "param '%s' has invalid type '%s' (must be string, number, or boolean)",
               name,
               param_type
            )
         )
      end
      if param_type == "number" and is_nan_or_inf(param_value) then
         error(string.format("param '%s' cannot be NaN or infinite", name))
      end
      if i == #names then
         current[name] = current[name] or {}
         current[name][param_value] = value
      else
         current[name] = current[name] or {}
         current[name][param_value] = current[name][param_value] or {}
         current = current[name][param_value]
      end
   end
   return true
end

---@param params table<string, any[]>
---@return table[] # Array of param combinations
local function expand_params(params)
   if not params or not next(params) then
      return { {} }
   end

   local combos = { {} }
   local keys = sorted_keys(params)

   for i = 1, #keys do
      local name = keys[i]
      local values = params[name]
      local new_combos = {}

      for j = 1, #combos do
         local combo = combos[j]
         for k = 1, #values do
            local new_combo = shallow_copy(combo)
            new_combo[name] = values[k]
            new_combos[#new_combos + 1] = new_combo
         end
      end

      combos = new_combos
   end

   return combos
end

---@param opts SuiteOpts
---@param bench ParsedBenchmark
---@param params ParamValues
---@return function?
local function build_combined_setup(opts, bench, params)
   if not opts.setup and not bench.setup then
      return nil
   end
   return function()
      if opts.setup then
         opts.setup(params)
      end
      if bench.setup then
         bench.setup(params)
      end
   end
end

---@param opts SuiteOpts
---@param bench ParsedBenchmark
---@param params ParamValues
---@return function?
local function build_combined_teardown(opts, bench, params)
   if not bench.teardown and not opts.teardown then
      return nil
   end
   return function()
      if bench.teardown then
         bench.teardown(params)
      end
      if opts.teardown then
         opts.teardown(params)
      end
   end
end

---@param bench ParsedBenchmark
---@param opts SuiteOpts
---@param params ParamValues
---@param measure_fn Measure
---@param unit default_unit
---@return Stats
local function run_benchmark(bench, opts, params, measure_fn, unit)
   return single_benchmark(
      bench.fn,
      measure_fn,
      measure_fn == measure_time,
      unit,
      opts.rounds,
      opts.max_time,
      build_combined_setup(opts, bench, params),
      build_combined_teardown(opts, bench, params)
   )
end

--- Run a suite of groups with benchmarks and parameters.
---@param spec SuiteSpec
---@param measure_fn Measure
---@param unit? default_unit
---@return SuiteResult
local function run_suite(spec, measure_fn, unit)
   unit = unit or "s"

   local parsed = parse_suite(spec)
   local results = {}

   for group_name, group in pairs(parsed) do
      results[group_name] = {}
      local group_opts = group.opts or {} ---@type SuiteOpts
      local params_list = expand_params(group_opts.params)

      for bench_name, bench in pairs(group) do
         if bench_name ~= "opts" then
            ---@cast bench ParsedBenchmark
            results[group_name][bench_name] = {}
            for i = 1, #params_list do
               local p = params_list[i]
               local stats = run_benchmark(bench, group_opts, p, measure_fn, unit)
               if not set_nested(results[group_name][bench_name], p, stats) then
                  -- No params: assign Stats directly instead of nesting
                  results[group_name][bench_name] = stats
               end
            end
         end
      end
   end

   return results
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

---Return a string summarizing benchmark results.
---@param results {[string]: Stats}|SuiteResult Benchmark or suite results
---@param format? "plain"|"compact"|"markdown"|"csv" The output format
---@param max_width? integer Maximum output width (default: terminal width)
---@return string
function luamark.summarize(results, format, max_width)
   assert(results and next(results), "'results' is nil or empty.")
   format = format or "plain"
   assert(
      format == "plain" or format == "compact" or format == "markdown" or format == "csv",
      "format must be 'plain', 'compact', 'markdown', or 'csv'"
   )

   if is_suite_result(results) then
      return summarize_suite(results, format, max_width)
   end
   ---@cast results {[string]: Stats}
   return summarize_benchmark(results, format, max_width)
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

--- Benchmarks a suite for execution time.
---@param spec SuiteSpec Groups with benchmarks and optional params
---@return SuiteResult Nested results: result[group][benchmark].param[value] -> Stats
function luamark.suite_timeit(spec)
   return run_suite(spec, measure_time, "s")
end

--- Benchmarks a suite for memory usage.
---@param spec SuiteSpec Groups with benchmarks and optional params
---@return SuiteResult Nested results: result[group][benchmark].param[value] -> Stats
function luamark.suite_memit(spec)
   return run_suite(spec, measure_memory, "kb")
end

-- ----------------------------------------------------------------------------
-- Internals (for testing)
-- ----------------------------------------------------------------------------

---@package
luamark._internal = {
   CALIBRATION_PRECISION = CALIBRATION_PRECISION,
   DEFAULT_TERM_WIDTH = DEFAULT_TERM_WIDTH,
   calculate_stats = calculate_stats,
   expand_params = expand_params,
   flatten_suite_results = flatten_suite_results,
   format_stat = format_stat,
   get_min_clocktime = get_min_clocktime,
   is_suite_result = is_suite_result,
   measure_memory = measure_memory,
   measure_time = measure_time,
   parse_suite = parse_suite,
   rank = rank,
   set_nested = set_nested,
}

-- Allow direct config access (luamark.max_rounds) with validation on write
return setmetatable(luamark, {
   __index = config,
   __newindex = function(_, k, v)
      if config[k] == nil then
         error("Invalid config option: " .. k)
      end
      if type(v) ~= "number" then
         error("Config value must be a number")
      end
      if k == "warmups" then
         if v < 0 then
            error("warmups must be >= 0")
         end
      elseif v <= 0 then
         error("Config value must be a positive number")
      end
      config[k] = v
   end,
})
