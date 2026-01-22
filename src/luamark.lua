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
local MEMORY_PRECISION = 4
local BYTES_TO_KB = 1024
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

local clock, clock_precision

---@return integer time The minimum measurable time difference based on clock precision
local function get_min_clocktime()
   return (10 ^ -clock_precision)
end

local CLOCK_PRIORITIES = { "chronos", "posix.time", "socket" }
local NANO_TO_SEC = 1e-9
local posix_clock_gettime, POSIX_CLOCK_MONOTONIC

-- Dispatch loaded module to a function that returns the clock function and clock precision.
local CLOCKS = {
   chronos = function(chronos)
      return chronos.nanotime, 9
   end,
   ["posix.time"] = function(posix_time)
      posix_clock_gettime = posix_time.clock_gettime
      POSIX_CLOCK_MONOTONIC = posix_time.CLOCK_MONOTONIC
      if not posix_clock_gettime then
         error("posix.time.clock_gettime is not supported on this OS.")
      end
      return function()
         local ts = posix_clock_gettime(POSIX_CLOCK_MONOTONIC)
         return ts.tv_sec + ts.tv_nsec * NANO_TO_SEC
      end,
         9
   end,
   socket = function(socket)
      return socket.gettime, 4
   end,
}

for _, name in ipairs(CLOCK_PRIORITIES) do
   local is_installed, module = pcall(require, name)
   if is_installed then
      local ok, new_clock, new_precision = pcall(CLOCKS[name], module)
      if ok then
         clock, clock_precision = new_clock, new_precision
         luamark.clock_name = name
         break
      end
   end
end

if not luamark.clock_name then
   clock, clock_precision = os.clock, _VERSION == "Luau" and 5 or 3
   luamark.clock_name = "os.clock"
end

local clock_warning_shown = false
local function warn_low_precision_clock()
   if clock_warning_shown or luamark.clock_name ~= "os.clock" then
      return
   end
   clock_warning_shown = true
   local msg = "luamark: using os.clock (low precision, CPU time). "
      .. "Install chronos, luaposix, or luasocket for better accuracy.\n"
   if warn then
      warn(msg)
   else
      io.stderr:write(msg)
   end
end

---@alias MeasureOnce fun(fn: function, ctx: any, params: table):number
---@alias Target fun()|{[string]: fun()|Spec} A function or table of named functions/Specs to benchmark.
---@alias ParamValue string|number|boolean Allowed parameter value types.

---@class Options Benchmark configuration for timeit/memit.
---@field rounds? integer Number of benchmark rounds.
---@field max_time? number Maximum run time in seconds.
---@field setup? fun(): any Function executed once before benchmark; returns context.
---@field teardown? fun(ctx?: any) Function executed once after benchmark.
---@field before? fun(ctx?: any): any Function executed before each iteration.
---@field after? fun(ctx?: any) Function executed after each iteration.

---@class SuiteOptions : Options Configuration for compare_time/compare_memory.
---@field setup? fun(p: table): any Function executed once before benchmark; receives params, returns context.
---@field teardown? fun(ctx: any, p: table) Function executed once after benchmark.
---@field before? fun(ctx: any, p: table): any Function executed before each iteration.
---@field after? fun(ctx: any, p: table) Function executed after each iteration.
---@field params? table<string, ParamValue[]> Parameter combinations to benchmark across.

-- MeasureOnce functions accept fn, ctx, params to avoid closure overhead.
-- Calling fn(ctx, params) directly eliminates ~64 byte allocation per call.
---@type MeasureOnce
local function measure_time_once(fn, ctx, params)
   local start = clock()
   fn(ctx, params)
   return clock() - start
end

---@type MeasureOnce
local measure_memory_once
do
   local is_allocspy_installed, allocspy = pcall(require, "allocspy")
   if is_allocspy_installed then
      measure_memory_once = function(fn, ctx, params)
         collectgarbage("collect")
         allocspy.enable()
         fn(ctx, params)
         return allocspy.disable() / BYTES_TO_KB
      end
   else
      measure_memory_once = function(fn, ctx, params)
         collectgarbage("collect")
         local start = collectgarbage("count")
         fn(ctx, params)
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

---@param value any
---@return string
local function escape_csv(value)
   value = tostring(value)
   if value:find('[,"]') then
      return '"' .. value:gsub('"', '""') .. '"'
   end
   return value
end

local MAX_PARAM_COMBINATIONS = 10000

---@param params table<string, any[]>?
---@return table[] # Array of param combinations
local function expand_params(params)
   if not params or not next(params) then
      return { {} }
   end

   local total_combinations = 1
   for _, values in pairs(params) do
      total_combinations = total_combinations * #values
      if total_combinations > MAX_PARAM_COMBINATIONS then
         error(
            string.format(
               "Too many parameter combinations (exceeds %d). Reduce the number of parameter values.",
               MAX_PARAM_COMBINATIONS
            )
         )
      end
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

-- Offset above 0.5 to handle floating-point edge cases in rounding
local ROUNDING_EPSILON = 0.50000000000008

---@param num number
---@param precision number
---@return number
local function math_round(num, precision)
   precision = precision or 0
   local mul = 10 ^ precision
   local rounded
   if num > 0 then
      rounded = math.floor(num * mul + ROUNDING_EPSILON) / mul
   else
      rounded = math.ceil(num * mul - ROUNDING_EPSILON) / mul
   end
   return math.max(rounded, 10 ^ -precision)
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
---@field ops? number Operations per second (1/mean). Only present for time benchmarks.
---@field rank? integer Rank when comparing multiple benchmarks.
---@field ratio? number Ratio relative to fastest benchmark.

---@param samples number[]
---@return BaseStats
local function calculate_stats(samples)
   local count = #samples

   table.sort(samples)
   local mid = math.floor(count / 2)
   local median
   if count % 2 == 0 then
      median = (samples[mid] + samples[mid + 1]) / 2
   else
      median = samples[mid + 1]
   end

   local min, max = samples[1], samples[count]

   local total = 0
   for i = 1, count do
      total = total + samples[i]
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
   local stddev = math.sqrt(variance)

   return {
      count = count,
      mean = mean,
      median = median,
      min = min,
      max = max,
      stddev = stddev,
      total = total,
      samples = samples,
   }
end

--- Rank benchmark results by specified key, adding 'rank' and 'ratio' fields.
--- Smallest value gets rank 1 and ratio 1.0; other ratios are relative to it.
---@param results {[string]: Stats} Benchmark results indexed by name.
---@param key string Stats field to rank by.
---@return {[string]: Stats}
local function rank(results, key)
   assert(results and next(results), "'results' is nil or empty.")

   local sorted = {}
   for name, stats in pairs(results) do
      sorted[#sorted + 1] = { name = name, value = stats[key] }
   end

   table.sort(sorted, function(a, b)
      return a.value < b.value
   end)

   local min_value = sorted[1].value
   local prev_value = min_value
   local current_rank = 1
   for i, entry in ipairs(sorted) do
      if entry.value ~= prev_value then
         current_rank = i
         prev_value = entry.value
      end
      results[entry.name].rank = current_rank
      if current_rank == 1 or min_value == 0 then
         results[entry.name].ratio = 1
      else
         results[entry.name].ratio = entry.value / min_value
      end
   end
   return results
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
local function humanize(value, base_unit)
   local units = base_unit == "s" and TIME_UNITS or MEMORY_UNITS

   for i = 1, #units do
      local symbol, threshold = units[i][1], units[i][2]
      if value >= threshold then
         return trim_zeroes(string.format("%.2f", value / threshold)) .. symbol
      end
   end

   return "0" .. units[#units][1]
end

--- Format statistical measurements into a readable string.
---@param stats table The statistical measurements to format.
---@param unit default_unit
---@return string # A formatted string representing the statistical metrics.
local function stats_tostring(stats, unit)
   return string.format(
      "%s ± %s per round (%d rounds)",
      humanize(stats.mean, unit),
      humanize(stats.stddev, unit),
      stats.rounds
   )
end

---@param stats Stats
---@return table<string, string>
local function format_row(stats)
   local unit = stats.unit
   return {
      rank = stats.rank and tostring(stats.rank) or "",
      ratio = stats.ratio and string.format("%.2f", stats.ratio) or "",
      median = humanize(stats.median, unit),
      mean = humanize(stats.mean, unit),
      min = humanize(stats.min, unit),
      max = humanize(stats.max, unit),
      stddev = humanize(stats.stddev, unit),
      ops = stats.ops and (trim_zeroes(string.format("%.2f", stats.ops)) .. "/s") or "",
      rounds = tostring(stats.rounds),
   }
end

---@param str string
---@param width integer
---@return string
local function pad(str, width)
   return str .. string.rep(" ", width - #str)
end

---@param str string
---@param width integer
---@return string
local function center(str, width)
   local total_padding = math.max(0, width - #str)
   local left_padding = math.floor(total_padding / 2)
   local right_padding = total_padding - left_padding
   return string.rep(" ", left_padding) .. str .. string.rep(" ", right_padding)
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
local EMBEDDED_BAR_WIDTH = 8

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

---Render compact bar chart.
---@param rows {name: string, ratio: string, median: string}[]
---@param max_width? integer
---@return string[]
local function render_bar_chart(rows, max_width)
   max_width = max_width or get_term_width()

   local max_ratio = 1
   local max_suffix_len = 0
   local max_name_len = NAME_MIN_WIDTH
   for i = 1, #rows do
      local row = rows[i]
      local ratio = tonumber(row.ratio) or 1
      max_ratio = math.max(max_ratio, ratio)
      -- Suffix format: " Nx (median)" -> space + "x" + " (" + ")" = 5 fixed chars
      max_suffix_len = math.max(max_suffix_len, 5 + #row.ratio + #row.median)
      max_name_len = math.max(max_name_len, #row.name)
   end

   -- Calculate column widths
   local available = max_width - 3 - max_suffix_len
   local bar_max = math.max(BAR_MIN_WIDTH, math.min(BAR_MAX_WIDTH, available - NAME_MIN_WIDTH))
   local name_max = math.max(NAME_MIN_WIDTH, math.min(max_name_len, available - bar_max))

   local lines = {}
   for i = 1, #rows do
      local row = rows[i]
      local ratio = tonumber(row.ratio) or 1
      local bar_width = math.max(1, math.floor((ratio / max_ratio) * bar_max))
      local name = pad(truncate_name(row.name, name_max), name_max)
      local bar = string.rep(BAR_CHAR, bar_width)
      lines[i] = string.format("%s  |%s %sx (%s)", name, bar, row.ratio, row.median)
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
   "ops",
   "rounds",
}

---Calculate column widths based on header and row content.
---@param rows table[]
---@return integer[]
local function calculate_column_widths(rows)
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

---Truncate names to fit within terminal width (for plain format).
---Mutates rows and widths in place.
---@param rows table[]
---@param widths integer[]
---@param max_width integer
local function truncate_names_to_fit(rows, widths, max_width)
   local other_width = 0
   for i = 2, #SUMMARIZE_HEADERS do
      other_width = other_width + widths[i]
   end
   local bar_col_width = EMBEDDED_BAR_WIDTH + 2
   local max_name = math.max(
      NAME_MIN_WIDTH,
      max_width - other_width - (#SUMMARIZE_HEADERS - 1) * 2 - bar_col_width
   )
   if widths[1] > max_name then
      widths[1] = max_name
      for i = 1, #rows do
         rows[i].name = truncate_name(rows[i].name, max_name)
      end
   end
end

---Build combined bar + ratio label (e.g., "█████ 1.00x")
---Bar is padded to fixed width so ratio labels align.
---@param ratio_str string
---@param bar_width integer Display width of the bar (number of █ characters)
---@param max_ratio_width integer
---@return string
local function build_ratio_bar(ratio_str, bar_width, max_ratio_width)
   local bar = string.rep(BAR_CHAR, bar_width)
   local padded_bar = bar .. string.rep(" ", EMBEDDED_BAR_WIDTH - bar_width)
   local padded_ratio = string.rep(" ", max_ratio_width - #ratio_str) .. ratio_str
   return padded_bar .. " " .. padded_ratio .. "x"
end

---Render plain text table with embedded bar chart in ratio column.
---@param rows table[]
---@param widths integer[]
---@return string
local function render_plain_table(rows, widths)
   local max_ratio = 1
   local max_ratio_width = 0
   for i = 1, #rows do
      max_ratio = math.max(max_ratio, tonumber(rows[i].ratio) or 1)
      max_ratio_width = math.max(max_ratio_width, #rows[i].ratio)
   end
   local ratio_bar_width = EMBEDDED_BAR_WIDTH + max_ratio_width + 2

   local header_cells, underline_cells = {}, {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      local width = (header == "ratio") and ratio_bar_width or widths[i]
      local label = (header == "ratio") and "Ratio"
         or (header == "ops") and "Op/s"
         or header:gsub("^%l", string.upper)
      header_cells[#header_cells + 1] = center(label, width)
      underline_cells[#underline_cells + 1] = string.rep("-", width)
   end

   local lines = { concat_line(header_cells, "plain"), concat_line(underline_cells, "plain") }

   for r = 1, #rows do
      local row = rows[r]
      local cells = {}
      for i, header in ipairs(SUMMARIZE_HEADERS) do
         if header == "ratio" then
            local ratio = tonumber(row.ratio) or 1
            local bar_width = math.max(1, math.floor((ratio / max_ratio) * EMBEDDED_BAR_WIDTH))
            cells[#cells + 1] =
               pad(build_ratio_bar(row.ratio, bar_width, max_ratio_width), ratio_bar_width)
         else
            cells[#cells + 1] = pad(row[header], widths[i])
         end
      end
      lines[#lines + 1] = concat_line(cells, "plain")
   end

   return table.concat(lines, "\n")
end

---Render markdown table.
---@param rows table[]
---@param widths integer[]
---@return string
local function render_markdown_table(rows, widths)
   local header_cells, underline_cells = {}, {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      local label = (header == "ops") and "Op/s" or header:gsub("^%l", string.upper)
      header_cells[#header_cells + 1] = center(label, widths[i])
      underline_cells[#underline_cells + 1] = string.rep("-", widths[i])
   end

   local lines = { concat_line(header_cells, "markdown"), concat_line(underline_cells, "markdown") }

   for r = 1, #rows do
      local row = rows[r]
      local cells = {}
      for i, header in ipairs(SUMMARIZE_HEADERS) do
         cells[#cells + 1] = pad(row[header], widths[i])
      end
      lines[#lines + 1] = concat_line(cells, "markdown")
   end

   return table.concat(lines, "\n")
end

-- ----------------------------------------------------------------------------
-- Parameterized result helpers
-- ----------------------------------------------------------------------------

---Format parameter values as a readable string.
---@param params table Parameter name to value mapping
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

---@class BenchmarkRow
---@field name string Benchmark name ("1" for unnamed single function).
---@field params table<string, ParamValue> Parameter values for this run.
---@field stats Stats Benchmark statistics.

---Rank benchmark results within each parameter combination.
---@param results BenchmarkRow[]
local function rank_results(results)
   local groups = {}
   for i = 1, #results do
      local row = results[i]
      local key = format_params(row.params)
      groups[key] = groups[key] or {}
      groups[key][#groups[key] + 1] = row
   end
   for _, group in pairs(groups) do
      table.sort(group, function(a, b)
         return a.stats.median < b.stats.median
      end)
      local min_median = group[1].stats.median
      for i = 1, #group do
         group[i].stats.rank = i
         if i == 1 or min_median == 0 then
            group[i].stats.ratio = 1
         else
            group[i].stats.ratio = group[i].stats.median / min_median
         end
      end
   end
end

---Collect all unique parameter names from flattened rows.
---@param rows BenchmarkRow[]
---@return string[]
local function collect_param_names(rows)
   local seen = {}
   for i = 1, #rows do
      for name in pairs(rows[i].params) do
         seen[name] = true
      end
   end
   return sorted_keys(seen)
end

---Render results as CSV with param columns for data export.
---@param rows BenchmarkRow[]
---@return string
local function render_csv(rows)
   local param_names = collect_param_names(rows)

   local headers = { "name" }
   for i = 1, #param_names do
      headers[#headers + 1] = param_names[i]
   end
   for i = 2, #SUMMARIZE_HEADERS do
      headers[i + #param_names] = SUMMARIZE_HEADERS[i]
   end

   -- Sort rows by name then params for consistent output
   table.sort(rows, function(a, b)
      if a.name ~= b.name then
         return a.name < b.name
      end
      return format_params(a.params) < format_params(b.params)
   end)

   local lines = { table.concat(headers, ",") }
   for i = 1, #rows do
      local row = rows[i]
      local formatted = format_row(row.stats)
      local cells = { escape_csv(row.name) }
      for j = 1, #param_names do
         local val = row.params[param_names[j]]
         cells[#cells + 1] = escape_csv(val ~= nil and tostring(val) or "")
      end
      for j = 2, #SUMMARIZE_HEADERS do
         cells[#cells + 1] = escape_csv(formatted[SUMMARIZE_HEADERS[j]] or "")
      end
      lines[#lines + 1] = table.concat(cells, ",")
   end

   return table.concat(lines, "\n")
end

---Render summary table (plain/compact/markdown).
---@param results {[string]: Stats}
---@param format "plain"|"compact"|"markdown"
---@param max_width? integer
---@return string
local function render_summary(results, format, max_width)
   results = rank(results, "median")

   local sorted_names = {}
   for name in pairs(results) do
      sorted_names[#sorted_names + 1] = name
   end
   table.sort(sorted_names, function(a, b)
      return results[a].rank < results[b].rank
   end)

   local rows = {}
   for i = 1, #sorted_names do
      local name = sorted_names[i]
      local row = format_row(results[name])
      row.name = name
      rows[i] = row
   end

   max_width = max_width or get_term_width()

   if format == "compact" then
      return table.concat(render_bar_chart(rows, max_width), "\n")
   end

   local widths = calculate_column_widths(rows)

   if format == "plain" then
      truncate_names_to_fit(rows, widths, max_width)
      return render_plain_table(rows, widths)
   end

   return render_markdown_table(rows, widths)
end

-- ----------------------------------------------------------------------------
-- Benchmark
-- ----------------------------------------------------------------------------

---@alias Measure fun(fn: function, iterations: integer, setup?: function, teardown?: function, get_ctx?: function, params?: table): number, number

---@param measure_once MeasureOnce
---@param precision integer
---@return Measure
local function build_measure(measure_once, precision)
   return function(fn, iterations, setup, teardown, get_ctx, params)
      local total = 0
      local ctx = get_ctx and get_ctx() or nil
      for _ = 1, iterations do
         if setup then
            setup()
         end

         if get_ctx then
            ctx = get_ctx()
         end
         total = total + measure_once(fn, ctx, params)

         if teardown then
            teardown()
         end
      end
      return total, math_round(total / iterations, precision)
   end
end

local measure_time = build_measure(measure_time_once, clock_precision)
local measure_memory = build_measure(measure_memory_once, MEMORY_PRECISION)

local ZERO_TIME_SCALE = 100

---@param fn function The function to benchmark.
---@param setup? function Function executed before each iteration.
---@param teardown? function Function executed after each iteration.
---@param get_ctx function Function that returns current iteration context.
---@param params table Parameter table to pass to fn.
---@return integer # Number of iterations per round.
local function calibrate_iterations(fn, setup, teardown, get_ctx, params)
   local min_time = get_min_clocktime() * CALIBRATION_PRECISION
   local iterations = 1

   for _ = 1, MAX_CALIBRATION_ATTEMPTS do
      local total_time = measure_time(fn, iterations, setup, teardown, get_ctx, params)
      if total_time >= min_time then
         break
      end

      local scale = total_time > 0 and (min_time / total_time) or ZERO_TIME_SCALE

      iterations = math.ceil(iterations * scale)

      if iterations >= config.max_iterations then
         return config.max_iterations
      end
   end

   return iterations
end

---Return practical rounds and max time
---@param round_duration number
---@return integer rounds
---@return number max_time
local function calibrate_stop(round_duration)
   -- Guard against division by zero for extremely fast functions on low-precision clocks.
   local safe_duration = (round_duration > 0) and round_duration or get_min_clocktime()
   local max_time = math.max(config.min_rounds * safe_duration, MIN_TIME)
   local rounds = math.ceil(math.min(max_time / safe_duration, config.max_rounds))
   return rounds, max_time
end

---@param fn any
---@param rounds? number
---@param max_time? number
---@param setup? function
---@param teardown? function
---@param before? function
---@param after? function
local function validate_benchmark_args(fn, rounds, max_time, setup, teardown, before, after)
   assert(type(fn) == "function", "'fn' must be a function, got " .. type(fn))
   assert(rounds == nil or rounds > 0, "'rounds' must be > 0.")
   assert(not max_time or max_time > 0, "'max_time' must be > 0.")

   local function_args = { setup = setup, teardown = teardown, before = before, after = after }
   for name, value in pairs(function_args) do
      assert(
         value == nil or type(value) == "function",
         string.format("'%s' must be a function", name)
      )
   end
end

---@param samples number[] Raw measurement samples.
---@param rounds integer Number of benchmark rounds executed.
---@param iterations integer Number of iterations per round.
---@param timestamp string ISO 8601 UTC timestamp.
---@param unit default_unit Measurement unit.
---@return Stats
local function build_stats_result(samples, rounds, iterations, timestamp, unit)
   local stats = calculate_stats(samples) ---@cast stats Stats
   stats.rounds = rounds
   stats.iterations = iterations
   stats.warmups = config.warmups
   stats.timestamp = timestamp
   stats.unit = unit

   if unit == "s" and stats.mean > 0 then
      stats.ops = 1 / stats.mean
   end

   setmetatable(stats, {
      __tostring = function(self)
         return stats_tostring(self, unit)
      end,
   })
   return stats
end

-- Sentinel value to indicate "no context" without using nil.
-- Required because suite mode needs to distinguish "no ctx passed" from "ctx is nil".
-- Using varargs with select("#", ...) caused memory allocation overhead.
local NIL_CTX = {}

--- Create a hook invoker that optionally appends params to all calls.
--- In single mode: passes ctx only if provided (setup gets no args, others get ctx).
--- In suite mode: passes (params) when ctx is NIL_CTX, or (ctx, params) otherwise.
---@param single_mode boolean? When true, calls hooks without params.
---@param params table Parameter table to append in suite mode.
---@return function invoke Hook invoker function.
local function make_invoke(single_mode, params)
   if single_mode then
      return function(hook, ctx)
         if not ctx or ctx == NIL_CTX then
            return hook()
         end
         return hook(ctx)
      end
   end
   -- Suite mode: use sentinel to detect "no ctx" (avoids varargs allocation overhead)
   return function(hook, ctx)
      if ctx == NIL_CTX then
         return hook(params)
      end
      return hook(ctx, params)
   end
end

--- Run a benchmark on a function using a specified measurement method.
---@param fn function Function to benchmark.
---@param measure Measure Measurement function (e.g., measure_time or measure_memory).
---@param disable_gc boolean Controls garbage collection during benchmark.
---@param unit default_unit Measurement unit.
---@param rounds? number Number of rounds.
---@param max_time? number Maximum run time in seconds.
---@param setup? function Runs once before benchmark, returns context.
---@param teardown? function Runs once after benchmark.
---@param params? table Parameter values for this run (nil for single mode).
---@param spec_before? function Per-iteration setup (from Spec), returns iteration context.
---@param spec_after? function Per-iteration teardown (from Spec).
---@param global_before? function Shared per-iteration setup (from Options).
---@param global_after? function Shared per-iteration teardown (from Options).
---@param single_mode? boolean When true, hooks receive no params argument.
---@return Stats
local function single_benchmark(
   fn,
   measure,
   disable_gc,
   unit,
   rounds,
   max_time,
   setup,
   teardown,
   params,
   spec_before,
   spec_after,
   global_before,
   global_after,
   single_mode
)
   validate_benchmark_args(fn, rounds, max_time, setup, teardown, spec_before, spec_after)
   warn_low_precision_clock()
   disable_gc = disable_gc ~= false

   params = params or {}
   local invoke = make_invoke(single_mode, params)

   local ctx
   if setup then
      ctx = invoke(setup, NIL_CTX)
   end

   local iteration_ctx = ctx

   -- Indirection avoids creating a new closure per iteration when ctx changes.
   local function get_ctx()
      return iteration_ctx
   end

   -- Per-iteration setup: runs global_before then spec_before
   local iteration_setup = (global_before or spec_before)
      and function()
         iteration_ctx = ctx
         if global_before then
            iteration_ctx = invoke(global_before, ctx) or ctx
         end
         if spec_before then
            iteration_ctx = invoke(spec_before, iteration_ctx) or iteration_ctx
         end
      end

   -- Per-iteration teardown: runs spec_after then global_after
   local iteration_teardown = (spec_after or global_after)
      and function()
         if spec_after then
            invoke(spec_after, iteration_ctx)
         end
         if global_after then
            invoke(global_after, iteration_ctx)
         end
      end

   local iterations = calibrate_iterations(fn, iteration_setup, iteration_teardown, get_ctx, params)
   for _ = 1, config.warmups do
      measure(fn, iterations, iteration_setup, iteration_teardown, get_ctx, params)
   end

   local timestamp = os.date("!%Y-%m-%d %H:%M:%SZ") --[[@as string]]
   local samples = {}
   local completed_rounds = 0
   local total_duration = 0
   local duration

   if disable_gc then
      collectgarbage("stop")
   end

   local function run_benchmark_loop()
      repeat
         completed_rounds = completed_rounds + 1
         local start = clock()

         local _, iteration_measure =
            measure(fn, iterations, iteration_setup, iteration_teardown, get_ctx, params)
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
   end

   local bench_ok, bench_err = pcall(run_benchmark_loop)
   collectgarbage("restart")

   if teardown then
      local teardown_ok, teardown_err = pcall(invoke, teardown, ctx)
      if not teardown_ok and bench_ok then
         error(teardown_err, 0)
      end
   end

   if not bench_ok then
      error(bench_err, 0)
   end

   return build_stats_result(samples, completed_rounds, iterations, timestamp, unit)
end

--- Per-function benchmark specification with optional lifecycle hooks.
--- Use when comparing functions that need different setup/teardown.
--- Unlike Options.setup/teardown (run once), Spec hooks run each iteration.
---@class Spec
---@field fn fun(ctx: any, p: table) Benchmark function; receives iteration context and params.
---@field before? fun(ctx: any, p: table): any Per-iteration setup; returns iteration context.
---@field after? fun(ctx: any, p: table) Per-iteration teardown.

--- Parse a benchmark specification into its components.
---@param spec function|Spec Function or Spec table.
---@return function fn Benchmark function.
---@return function? before Per-iteration setup.
---@return function? after Per-iteration teardown.
local function parse_spec(spec)
   if type(spec) == "function" then
      return spec
   end
   assert(type(spec) == "table", "spec must be a function or table")
   assert(type(spec.fn) == "function", "spec.fn must be a function")
   assert(spec.before == nil or type(spec.before) == "function", "spec.before must be a function")
   assert(spec.after == nil or type(spec.after) == "function", "spec.after must be a function")
   return spec.fn, spec.before, spec.after
end

--- Run benchmarks on a table of functions with optional params.
---@param funcs table<string, function|Spec> Table of named functions or Specs to benchmark.
---@param measure Measure Measurement function.
---@param disable_gc boolean Controls garbage collection during benchmark.
---@param unit default_unit Measurement unit.
---@param opts SuiteOptions Benchmark options.
---@return BenchmarkRow[]
local function benchmark_suite(funcs, measure, disable_gc, unit, opts)
   opts = opts or {}
   local params_list = expand_params(opts.params)
   local results = {}

   local names = sorted_keys(funcs)
   for j = 1, #names do
      local name = names[j]
      local fn, spec_before, spec_after = parse_spec(funcs[name])
      for i = 1, #params_list do
         local p = params_list[i]
         local stats = single_benchmark(
            fn,
            measure,
            disable_gc,
            unit,
            opts.rounds,
            opts.max_time,
            opts.setup,
            opts.teardown,
            p,
            spec_before,
            spec_after,
            opts.before,
            opts.after,
            false -- suite mode: hooks receive params
         )
         results[#results + 1] = { name = name, params = p, stats = stats }
      end
   end

   rank_results(results)
   setmetatable(results, {
      __tostring = function(self)
         return luamark.summarize(self, "compact")
      end,
   })
   return results
end

local COMMON_OPTS = {
   rounds = "number",
   max_time = "number",
   setup = "function",
   teardown = "function",
   before = "function",
   after = "function",
}

local SUITE_ONLY_OPTS = {
   params = "table",
}

--- Get the expected type for an option, checking common and extra option tables.
---@param key string Option name.
---@param extra_opts? table<string, string> Additional valid options.
---@return string? expected_type Expected type or nil if unknown option.
local function get_option_type(key, extra_opts)
   return COMMON_OPTS[key] or (extra_opts and extra_opts[key])
end

--- Validate options against allowed types.
---@param opts table Options to validate.
---@param extra_opts? table<string, string> Additional valid options beyond COMMON_OPTS.
local function validate_options(opts, extra_opts)
   for key, value in pairs(opts) do
      local expected_type = get_option_type(key, extra_opts)
      if not expected_type then
         error("Unknown option: " .. key)
      end
      if type(value) ~= expected_type then
         error(string.format("Option '%s' should be %s", key, expected_type))
      end
   end

   if opts.rounds and opts.rounds ~= math.floor(opts.rounds) then
      error("Option 'rounds' must be an integer")
   end
end

--- Validate params table structure.
---@param params table<string, ParamValue[]> Parameter combinations.
local function validate_params(params)
   for name, values in pairs(params) do
      if type(name) ~= "string" then
         error(string.format("params key must be a string, got %s", type(name)))
      end
      if type(values) ~= "table" then
         error(string.format("params['%s'] must be an array, got %s", name, type(values)))
      end
      if #values == 0 then
         error(string.format("params['%s'] must not be empty", name))
      end
      for i, v in ipairs(values) do
         local vtype = type(v)
         if vtype ~= "string" and vtype ~= "number" and vtype ~= "boolean" then
            error(
               string.format(
                  "params['%s'][%d] must be string, number, or boolean, got %s",
                  name,
                  i,
                  vtype
               )
            )
         end
      end
   end
end

--- Validate options for single API (timeit/memit).
--- Rejects params option with helpful error message.
---@param opts Options Options to validate.
local function validate_single_options(opts)
   ---@diagnostic disable-next-line: undefined-field
   if opts.params then
      error("'params' is not supported in timeit/memit. Use compare_time/compare_memory instead.")
   end
   validate_options(opts)
end

--- Validate options for suite API (compare_time/compare_memory).
---@param opts SuiteOptions Options to validate.
local function validate_suite_options(opts)
   validate_options(opts, SUITE_ONLY_OPTS)
   if opts.params then
      validate_params(opts.params)
   end
end

--- Validate funcs table for suite API (compare_time/compare_memory).
--- Rejects numeric keys (arrays) since function names must be strings.
---@param funcs table Table of functions to validate.
local function validate_funcs(funcs)
   for key in pairs(funcs) do
      if type(key) ~= "string" then
         error(
            "'funcs' keys must be strings, got " .. type(key) .. ". Use named keys: { name = fn }"
         )
      end
   end
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

local VALID_FORMATS = { plain = true, compact = true, markdown = true, csv = true }

--- Return a string summarizing benchmark results.
--- Results are now always BenchmarkRow[] (flat array).
---@param results BenchmarkRow[] Benchmark results to summarize.
---@param format? "plain"|"compact"|"markdown"|"csv" Output format.
---@param max_width? integer Maximum output width (default: terminal width).
---@return string
function luamark.summarize(results, format, max_width)
   assert(results and #results > 0, "'results' is nil or empty.")
   format = format or "plain"
   assert(VALID_FORMATS[format], "format must be 'plain', 'compact', 'markdown', or 'csv'")

   max_width = max_width or get_term_width()

   local has_params = false
   for i = 1, #results do
      if next(results[i].params) then
         has_params = true
         break
      end
   end

   -- CSV outputs flat data with param columns for export; other formats group by params for display.
   if format == "csv" then
      return render_csv(results)
   end
   ---@cast format "plain"|"compact"|"markdown"

   if not has_params then
      local by_name = {}
      for i = 1, #results do
         by_name[results[i].name] = results[i].stats
      end
      return render_summary(by_name, format, max_width)
   end

   local groups = {} ---@type table<string, {[string]: Stats}>
   for i = 1, #results do
      local row = results[i]
      local key = format_params(row.params)
      groups[key] = groups[key] or {}
      groups[key][row.name] = row.stats
   end

   local output = {}
   local group_keys = sorted_keys(groups)
   for i = 1, #group_keys do
      local param_key = group_keys[i]
      local group = groups[param_key]

      if param_key ~= "" then
         output[#output + 1] = param_key
      end

      local formatted = render_summary(group, format, max_width)
      output[#output + 1] = formatted
      output[#output + 1] = "" -- blank line between groups
   end

   return table.concat(output, "\n")
end

--- Benchmark a single function for execution time.
--- Time is represented in seconds.
---@param fn fun(ctx?: any) Function to benchmark; receives context from setup.
---@param opts? Options Benchmark configuration.
---@return Stats Benchmark statistics.
function luamark.timeit(fn, opts)
   assert(type(fn) == "function", "'fn' must be a function, got " .. type(fn))
   opts = opts or {}
   validate_single_options(opts)
   return single_benchmark(
      fn,
      measure_time,
      true,
      "s",
      opts.rounds,
      opts.max_time,
      opts.setup,
      opts.teardown,
      nil,
      nil,
      nil,
      opts.before,
      opts.after,
      true
   )
end

--- Benchmark a single function for memory usage.
--- Memory is represented in kilobytes.
---@param fn fun(ctx?: any) Function to benchmark; receives context from setup.
---@param opts? Options Benchmark configuration.
---@return Stats Benchmark statistics.
function luamark.memit(fn, opts)
   assert(type(fn) == "function", "'fn' must be a function, got " .. type(fn))
   opts = opts or {}
   validate_single_options(opts)
   return single_benchmark(
      fn,
      measure_memory,
      false,
      "kb",
      opts.rounds,
      opts.max_time,
      opts.setup,
      opts.teardown,
      nil,
      nil,
      nil,
      opts.before,
      opts.after,
      true
   )
end

--- Compare multiple functions for execution time.
--- Time is represented in seconds.
---@param funcs table<string, function|Spec> Table of named functions or Specs to benchmark.
---@param opts? SuiteOptions Benchmark configuration with optional params.
---@return BenchmarkRow[] Flat array of benchmark results with ranking.
function luamark.compare_time(funcs, opts)
   assert(type(funcs) == "table", "'funcs' must be a table, got " .. type(funcs))
   validate_funcs(funcs)
   opts = opts or {}
   validate_suite_options(opts)
   return benchmark_suite(funcs, measure_time, true, "s", opts)
end

--- Compare multiple functions for memory usage.
--- Memory is represented in kilobytes.
---@param funcs table<string, function|Spec> Table of named functions or Specs to benchmark.
---@param opts? SuiteOptions Benchmark configuration with optional params.
---@return BenchmarkRow[] Flat array of benchmark results with ranking.
function luamark.compare_memory(funcs, opts)
   assert(type(funcs) == "table", "'funcs' must be a table, got " .. type(funcs))
   validate_funcs(funcs)
   opts = opts or {}
   validate_suite_options(opts)
   return benchmark_suite(funcs, measure_memory, false, "kb", opts)
end

--- Format a time value to a human-readable string.
--- Automatically select the best unit (m, s, ms, us, ns).
---@param s number Time in seconds.
---@return string Formatted time string (e.g., "42ns", "1.5ms").
function luamark.humanize_time(s)
   return humanize(s, "s")
end

--- Format a memory value to a human-readable string.
--- Automatically select the best unit (TB, GB, MB, kB, B).
---@param kb number Memory in kilobytes.
---@return string Formatted memory string (e.g., "512kB", "1.5MB").
function luamark.humanize_memory(kb)
   return humanize(kb, "kb")
end

--- Unload modules matching a Lua pattern from package.loaded.
--- Useful for benchmarking module load times or resetting state.
---@param pattern string Lua pattern to match module names against.
---@return integer count Number of modules unloaded.
function luamark.unload(pattern)
   local count = 0
   for name in pairs(package.loaded) do
      if name:match(pattern) then
         package.loaded[name] = nil
         count = count + 1
      end
   end
   return count
end

--- Return a copy of the current configuration.
---@return table
function luamark.get_config()
   return {
      max_iterations = config.max_iterations,
      min_rounds = config.min_rounds,
      max_rounds = config.max_rounds,
      warmups = config.warmups,
   }
end

if rawget(_G, "_TEST") then
   ---@package
   luamark._internal = {
      CALIBRATION_PRECISION = CALIBRATION_PRECISION,
      DEFAULT_TERM_WIDTH = DEFAULT_TERM_WIDTH,
      calculate_stats = calculate_stats,
      get_min_clocktime = get_min_clocktime,
      measure_memory = measure_memory,
      measure_time = measure_time,
      rank = rank,
   }
end

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
