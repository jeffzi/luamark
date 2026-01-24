-- luamark - A lightweight, portable micro-benchmarking library.
-- Copyright (c) 2025 Jean-Francois Zinque. MIT License.

---@class luamark
local luamark = {
   _VERSION = "0.9.0",
}

local math_ceil = math.ceil
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_random = math.random
local table_sort = table.sort

-- ----------------------------------------------------------------------------
-- Config
-- ----------------------------------------------------------------------------

-- Config defaults balance accuracy vs runtime across function speeds:
-- (config.time=5s, config.rounds=100, MAX_ROUNDS=1000, RESAMPLES=10000)
--
-- | Function    | Duration | Rounds | Iterations | Bootstrap | Total  |
-- |-------------|----------|--------|------------|-----------|--------|
-- | Very fast   | ~1μs     | 1,000  | 1,000+     | ~100ms    | ~100ms |
-- | Fast        | ~100μs   | 1,000  | 1          | ~100ms    | ~200ms |
-- | Medium      | ~10ms    | 500    | 1          | ~50ms     | ~5s    |
-- | Slow        | ~500ms   | 100    | 1          | ~10ms     | ~50s   |
--
-- MAX_ROUNDS caps fast functions to prevent excessive bootstrap overhead.
-- BOOTSTRAP_RESAMPLES (10k) provides accurate 95% CI for median.

local BOOTSTRAP_RESAMPLES = 10000
local CALIBRATION_PRECISION = 5
local DEFAULT_TERM_WIDTH = 100
local MEMORY_PRECISION = 4
local BYTES_TO_KB = 1024
local MAX_CALIBRATION_ATTEMPTS = 10
local MAX_ITERATIONS = 1e6
local MAX_ROUNDS = 1000

local config = {
   rounds = 100,
   time = 5,
}

---@generic K, V
---@param tbl table<K, V>
---@return K[]
local function sorted_keys(tbl)
   local keys = {}
   for key in pairs(tbl) do
      keys[#keys + 1] = key
   end
   table_sort(keys)
   return keys
end

-- ----------------------------------------------------------------------------
-- Measurement
-- ----------------------------------------------------------------------------

local clock, clock_precision

---@return integer time The minimum measurable time difference based on clock precision
local function get_min_clocktime()
   return 10 ^ -clock_precision
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
   clock, clock_precision = os.clock, 3
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
   ---@diagnostic disable-next-line: deprecated
   if warn then
      warn(msg) ---@diagnostic disable-line: deprecated
   else
      io.stderr:write(msg)
   end
end

---@alias MeasureOnce fun(fn: function, ctx: any, params: table):number
---@alias Target fun()|{[string]: fun()|luamark.Spec} A function or table of named functions/Specs to benchmark.
---@alias ParamValue string|number|boolean Allowed parameter value types.

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

-- ----------------------------------------------------------------------------
-- Statistics
-- ----------------------------------------------------------------------------

--- Calculate median of a sorted array.
---@param sorted number[] Sorted array of numbers.
---@return number
local function math_median(sorted)
   local n = #sorted
   local mid = math_floor(n / 2)
   if n % 2 == 0 then
      return (sorted[mid] + sorted[mid + 1]) / 2
   end
   return sorted[mid + 1]
end

--- Calculate median by reusing a pre-allocated array.
--- Sorts the array in place and computes median.
---@param bootstrap number[] Pre-allocated array to fill with resampled values.
---@param samples number[] Source samples to resample from.
---@param n integer Number of samples.
---@return number
local function resample_median(bootstrap, samples, n)
   for j = 1, n do
      bootstrap[j] = samples[math_random(n)]
   end
   table_sort(bootstrap)
   return math_median(bootstrap)
end

--- Calculate 95% confidence interval for median using bootstrap resampling.
---@param samples number[] Raw samples (will be sorted in place).
---@param n_resamples integer Number of bootstrap resamples.
---@return number lower, number upper
local function bootstrap_ci(samples, n_resamples)
   local n = #samples

   -- Pre-allocate bootstrap array to avoid repeated allocations
   local bootstrap = {}
   for j = 1, n do
      bootstrap[j] = 0
   end

   -- Generate bootstrap distribution of medians
   local medians = {}
   for i = 1, n_resamples do
      medians[i] = resample_median(bootstrap, samples, n)
   end
   table_sort(medians)

   -- Extract 2.5th and 97.5th percentiles (95% CI bounds)
   -- Clamp indices to valid range for small resample counts
   local lower_idx = math_max(1, math_floor(n_resamples * 0.025))
   local upper_idx = math_min(n_resamples, math_ceil(n_resamples * 0.975))

   return medians[lower_idx], medians[upper_idx]
end

---@class luamark.BaseStats
---@field count integer Number of samples collected.
---@field median number Median value of samples.
---@field ci_lower number Lower bound of 95% confidence interval for median.
---@field ci_upper number Upper bound of 95% confidence interval for median.
---@field ci_margin number Half-width of confidence interval ((upper - lower) / 2).
---@field total number Sum of all samples.
---@field samples number[] Raw samples (sorted).
---@field ratio? number Ratio relative to fastest benchmark.
---@field rank? integer Rank within benchmark group.

---@class luamark.Stats : luamark.BaseStats
---@field rounds integer Number of benchmark rounds executed.
---@field iterations integer Number of iterations per round.
---@field timestamp string ISO 8601 UTC timestamp of benchmark start.
---@field unit "s"|"kb" Measurement unit (seconds or kilobytes).
---@field ops? number Operations per second (1/median). Only present for time benchmarks.
---@field ratio? number Ratio relative to fastest benchmark.
---@field rank? integer Rank accounting for CI overlap (tied results share the same rank).
---@field is_approximate? boolean True if rank is approximate due to overlapping CIs.

---@param samples number[]
---@return luamark.BaseStats
local function calculate_stats(samples)
   local count = #samples

   table_sort(samples)
   local median = math_median(samples)

   local total = 0
   for i = 1, count do
      total = total + samples[i]
   end

   local ci_lower, ci_upper, ci_margin
   -- Bootstrap CI requires at least 3 samples for meaningful resampling variation
   if count >= 3 then
      ci_lower, ci_upper = bootstrap_ci(samples, BOOTSTRAP_RESAMPLES)
      ci_margin = (ci_upper - ci_lower) / 2
   else
      ci_lower = median
      ci_upper = median
      ci_margin = 0
   end

   return {
      count = count,
      median = median,
      ci_lower = ci_lower,
      ci_upper = ci_upper,
      ci_margin = ci_margin,
      total = total,
      samples = samples,
   }
end

-- ----------------------------------------------------------------------------
-- Result helpers
-- ----------------------------------------------------------------------------

---@class luamark.Result : luamark.BaseStats
---@field name string Benchmark name.
---@field rounds integer Number of benchmark rounds executed.
---@field iterations integer Number of iterations per round.
---@field timestamp string ISO 8601 UTC timestamp of benchmark start.
---@field unit "s"|"kb" Measurement unit (seconds or kilobytes).
---@field ops? number Operations per second (1/median). Only present for time benchmarks.
---@field ratio? number Ratio relative to fastest benchmark.
---@field rank? integer Rank accounting for CI overlap (tied results share the same rank).
---@field is_approximate? boolean True if rank is approximate due to overlapping CIs.
-- Plus any param keys inlined directly on the result (e.g., result.n, result.size)

-- Keys that are part of stats, not user params
local STAT_KEYS = {
   name = true,
   count = true,
   median = true,
   ci_lower = true,
   ci_upper = true,
   ci_margin = true,
   total = true,
   samples = true,
   rounds = true,
   iterations = true,
   timestamp = true,
   unit = true,
   ops = true,
   ratio = true,
   rank = true,
   is_approximate = true,
}

---Collect all unique parameter names from flat result rows.
---@param rows luamark.Result[]
---@return string[]
local function collect_param_names(rows)
   local seen = {}
   for i = 1, #rows do
      for key in pairs(rows[i]) do
         if not STAT_KEYS[key] then
            seen[key] = true
         end
      end
   end
   return sorted_keys(seen)
end

---Format parameter values as a readable string from flat result.
---@param row luamark.Result
---@param param_names string[]
---@return string
local function format_params(row, param_names)
   local parts = {}
   for i = 1, #param_names do
      local name = param_names[i]
      if row[name] ~= nil then
         parts[#parts + 1] = name .. "=" .. tostring(row[name])
      end
   end
   return table.concat(parts, ", ")
end

local function compare_by_median(a, b)
   return a.median < b.median
end

---Rank benchmark results within each parameter combination.
---Uses transitive overlap grouping: results with overlapping CIs share the same rank.
---Results are sorted in place: grouped by parameters, then by rank within each group.
---@param results luamark.Result[]
---@param param_names string[]
local function rank_results(results, param_names)
   local groups = {}
   for i = 1, #results do
      local row = results[i]
      local key = format_params(row, param_names)
      groups[key] = groups[key] or {}
      groups[key][#groups[key] + 1] = row
   end

   for _, group in pairs(groups) do
      table_sort(group, compare_by_median)

      local first = group[1]
      local min_median = first.median
      first.ratio = 1
      first.rank = 1
      first.is_approximate = false

      for i = 2, #group do
         local r = group[i]
         local prev = group[i - 1]
         r.ratio = min_median > 0 and (r.median / min_median) or 1

         if r.ci_lower <= prev.ci_upper and prev.ci_lower <= r.ci_upper then
            r.rank = prev.rank
            r.is_approximate = true
            prev.is_approximate = true
         else
            r.rank = i
            r.is_approximate = false
         end
      end
   end

   -- Reorder results: grouped by params (sorted), then by rank within each group
   local idx = 1
   for _, key in ipairs(sorted_keys(groups)) do
      for _, row in ipairs(groups[key]) do
         results[idx] = row
         idx = idx + 1
      end
   end
end

-- ----------------------------------------------------------------------------
-- Rendering
-- ----------------------------------------------------------------------------

---@return integer
local get_term_width
do
   local ok, system = pcall(require, "system")
   if ok and system.termsize then
      get_term_width = function()
         local rows, cols = system.termsize()
         return rows and cols or DEFAULT_TERM_WIDTH
      end
   else
      get_term_width = function()
         return DEFAULT_TERM_WIDTH
      end
   end
end

---@alias default_unit `s` | `kb` | `count`

-- Thresholds relative to input unit (seconds)
local TIME_UNITS = {
   { "m", 60, "%.2f" },
   { "s", 1, "%.2f" },
   { "ms", 1e-3, "%.2f" },
   { "us", 1e-6, "%.2f" },
   { "ns", 1e-9, "%.2f" },
}

-- Thresholds relative to input unit (kilobytes)
local MEMORY_UNITS = {
   { "TB", 1024 ^ 3, "%.2f" },
   { "GB", 1024 ^ 2, "%.2f" },
   { "MB", 1024, "%.2f" },
   { "kB", 1, "%.2f" },
   { "B", 1 / 1024, "%.2f" },
}

local COUNT_UNITS = {
   { "M", 1e6, "%.1f" },
   { "k", 1e3, "%.1f" },
   { "", 1, "%.1f" },
}

local UNIT_TABLES = {
   s = TIME_UNITS,
   kb = MEMORY_UNITS,
   count = COUNT_UNITS,
}

local BAR_CHAR = "█"
local BAR_MAX_WIDTH = 20
local BAR_MIN_WIDTH = 10
local NAME_MIN_WIDTH = 4
local ELLIPSIS = "..."
local EMBEDDED_BAR_WIDTH = 8

local SUMMARIZE_HEADERS = {
   "name",
   "rank",
   "ratio",
   "median",
   "ci_low",
   "ci_high",
   "ops",
   "iters",
}

local HEADER_LABELS = {
   name = "Name",
   rank = "Rank",
   ratio = "Ratio",
   median = "Median",
   ci_low = "CI Low",
   ci_high = "CI High",
   ops = "Ops",
   iters = "Iters",
}

---@param str string
---@return string
local function trim_zeroes(str)
   return (str:gsub("%.?0+$", ""))
end

--- Count display width (UTF-8 aware). Counts characters, not bytes.
---@param str string
---@return integer
local function display_width(str)
   -- Count bytes that are NOT UTF-8 continuation bytes (0x80-0xBF)
   local width = 0
   for i = 1, #str do
      local byte = string.byte(str, i)
      if byte < 0x80 or byte >= 0xC0 then
         width = width + 1
      end
   end
   return width
end

---@param str string
---@param width integer
---@return string
local function pad(str, width)
   return str .. string.rep(" ", width - display_width(str))
end

---@param str string
---@param width integer
---@return string
local function center(str, width)
   local total_padding = math_max(0, width - display_width(str))
   local left_padding = math_floor(total_padding / 2)
   local right_padding = total_padding - left_padding
   return string.rep(" ", left_padding) .. str .. string.rep(" ", right_padding)
end

---@param t string[]
---@return string
local function concat_line(t)
   return table.concat(t, "  ")
end

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

--- Format a value to a human-readable string with appropriate unit suffix.
---@param value number Value to format.
---@param unit_type default_unit Unit type: "s" (time), "kb" (memory), or "count".
---@return string
local function humanize(value, unit_type)
   local units = UNIT_TABLES[unit_type]

   for i = 1, #units do
      local symbol, threshold, fmt = units[i][1], units[i][2], units[i][3]
      if value >= threshold then
         return trim_zeroes(string.format(fmt, value / threshold)) .. symbol
      end
   end

   return "0" .. units[#units][1]
end

--- Format statistical measurements into a readable string.
---@param stats table The statistical measurements to format.
---@param unit default_unit
---@return string # A formatted string representing the statistical metrics.
local function stats_tostring(stats, unit)
   return humanize(stats.median, unit) .. " ± " .. humanize(stats.ci_margin, unit)
end

--- Format stats into display strings for table rendering.
---@param stats luamark.Stats|luamark.Result
---@return table<string, string>
local function format_row(stats)
   local unit = stats.unit

   -- Format rank with approximate marker if CIs overlap
   local rank_str = ""
   if stats.rank then
      local prefix = stats.is_approximate and "≈" or ""
      rank_str = prefix .. stats.rank
   end

   return {
      rank = rank_str,
      ratio = stats.ratio and string.format("%.2f", stats.ratio) or "",
      median = humanize(stats.median, unit),
      ci_low = humanize(stats.ci_lower, unit),
      ci_high = humanize(stats.ci_upper, unit),
      ops = stats.ops and (humanize(stats.ops, "count") .. "/s") or "",
      iters = stats.rounds .. " × " .. humanize(stats.iterations, "count"),
   }
end

---Calculate column widths based on header labels and row content.
---@param rows table[]
---@return integer[]
local function calculate_column_widths(rows)
   local widths = {}
   for col, header in ipairs(SUMMARIZE_HEADERS) do
      local max_width = display_width(HEADER_LABELS[header])
      for row = 1, #rows do
         max_width = math_max(max_width, display_width(rows[row][header] or ""))
      end
      widths[col] = max_width
   end
   return widths
end

---Truncate names to fit within terminal width (for plain format).
---Mutates rows and widths in place.
---@param rows table[]
---@param widths integer[]
---@param max_width integer
local function fit_names(rows, widths, max_width)
   local other_width = 0
   for i = 2, #SUMMARIZE_HEADERS do
      other_width = other_width + widths[i]
   end
   local bar_col_width = EMBEDDED_BAR_WIDTH + 2
   local max_name = math_max(
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
      max_ratio = math_max(max_ratio, ratio)
      -- Suffix format: " Nx (median)" -> space + "x" + " (" + ")" = 5 fixed chars
      max_suffix_len = math_max(max_suffix_len, 5 + #row.ratio + #row.median)
      max_name_len = math_max(max_name_len, #row.name)
   end

   -- Calculate column widths
   local available = max_width - 3 - max_suffix_len
   local bar_max = math_max(BAR_MIN_WIDTH, math_min(BAR_MAX_WIDTH, available - NAME_MIN_WIDTH))
   local name_max = math_max(NAME_MIN_WIDTH, math_min(max_name_len, available - bar_max))

   local lines = {}
   for i = 1, #rows do
      local row = rows[i]
      local ratio = tonumber(row.ratio) or 1
      local bar_width = math_max(1, math_floor((ratio / max_ratio) * bar_max))
      local name = pad(truncate_name(row.name, name_max), name_max)
      local bar = string.rep(BAR_CHAR, bar_width)
      lines[i] = string.format("%s  |%s %sx (%s)", name, bar, row.ratio, row.median)
   end
   return lines
end

---Render plain text table with embedded bar chart in ratio column.
---@param rows table[]
---@param widths integer[]
---@return string
local function render_plain_table(rows, widths)
   local max_ratio = 1
   local max_ratio_width = 0
   for i = 1, #rows do
      max_ratio = math_max(max_ratio, tonumber(rows[i].ratio) or 1)
      max_ratio_width = math_max(max_ratio_width, #rows[i].ratio)
   end
   local ratio_bar_width = EMBEDDED_BAR_WIDTH + max_ratio_width + 2

   local header_cells, underline_cells = {}, {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      local width = (header == "ratio") and ratio_bar_width or widths[i]
      local label = HEADER_LABELS[header]
      header_cells[#header_cells + 1] = center(label, width)
      underline_cells[#underline_cells + 1] = string.rep("-", width)
   end

   local lines = { concat_line(header_cells), concat_line(underline_cells) }

   for r = 1, #rows do
      local row = rows[r]
      local cells = {}
      for i, header in ipairs(SUMMARIZE_HEADERS) do
         if header == "ratio" then
            local ratio = tonumber(row.ratio) or 1
            local bar_width = math_max(1, math_floor((ratio / max_ratio) * EMBEDDED_BAR_WIDTH))
            cells[#cells + 1] =
               pad(build_ratio_bar(row.ratio, bar_width, max_ratio_width), ratio_bar_width)
         else
            cells[#cells + 1] = pad(row[header], widths[i])
         end
      end
      lines[#lines + 1] = concat_line(cells)
   end

   return table.concat(lines, "\n")
end

---Render summary table (plain/compact).
---@param results luamark.Result[] Results array (already sorted by rank).
---@param format "plain"|"compact"
---@param max_width? integer
---@return string
local function render_summary(results, format, max_width)
   local rows = {}
   for i = 1, #results do
      local row = format_row(results[i])
      row.name = results[i].name
      rows[i] = row
   end

   max_width = max_width or get_term_width()

   if format == "compact" then
      return table.concat(render_bar_chart(rows, max_width), "\n")
   end

   local widths = calculate_column_widths(rows)
   fit_names(rows, widths, max_width)
   return render_plain_table(rows, widths)
end

-- ----------------------------------------------------------------------------
-- Benchmark
-- ----------------------------------------------------------------------------

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

local MAX_PARAM_COMBINATIONS = 10000

--- Generate cartesian product of all parameter values.
---@param params table<string, any[]>?
---@return table[] # Array of param combinations
local function expand_params(params)
   if not params or not next(params) then
      return { {} }
   end

   -- Check for combinatorial explosion before allocating
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

   -- Build combinations iteratively: for each parameter, expand existing combinations
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
      rounded = math_floor(num * mul + ROUNDING_EPSILON) / mul
   else
      rounded = math_ceil(num * mul - ROUNDING_EPSILON) / mul
   end
   return math_max(rounded, 10 ^ -precision)
end

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

---@param precision integer
---@return Measure
local function build_measure_time(precision)
   local slow_path = build_measure(measure_time_once, precision)
   return function(fn, iterations, setup, teardown, get_ctx, params)
      -- Fast path: 2 clock() calls total instead of 2N when no hooks need to run
      -- between iterations. Reduces timing overhead for fast functions.
      if not setup and not teardown then
         local ctx = get_ctx and get_ctx() or nil
         local t1 = clock()
         for _ = 1, iterations do
            fn(ctx, params)
         end
         local total = clock() - t1
         return total, math_round(total / iterations, precision)
      end

      return slow_path(fn, iterations, setup, teardown, get_ctx, params)
   end
end

local measure_time = build_measure_time(clock_precision)
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
      iterations = math_ceil(iterations * scale)

      if iterations >= MAX_ITERATIONS then
         return MAX_ITERATIONS
      end
   end

   return iterations
end

---Return practical rounds and max time.
---Benchmark runs until both targets are met: at least `rounds` samples and `time` seconds.
---@param round_duration number
---@return integer rounds
---@return number time
local function calibrate_stop(round_duration)
   -- Guard against division by zero for extremely fast functions on low-precision clocks.
   local safe_duration = (round_duration > 0) and round_duration or get_min_clocktime()
   local time = math_max(config.rounds * safe_duration, config.time)
   local rounds = math_min(MAX_ROUNDS, math_ceil(time / safe_duration))
   return rounds, time
end

---@param fn any
---@param rounds? number
---@param time? number
---@param setup? function
---@param teardown? function
---@param before? function
---@param after? function
local function validate_benchmark_args(fn, rounds, time, setup, teardown, before, after)
   assert(type(fn) == "function", "'fn' must be a function, got " .. type(fn))
   assert(rounds == nil or rounds > 0, "'rounds' must be > 0.")
   assert(not time or time > 0, "'time' must be > 0.")
   assert(setup == nil or type(setup) == "function", "'setup' must be a function")
   assert(teardown == nil or type(teardown) == "function", "'teardown' must be a function")
   assert(before == nil or type(before) == "function", "'before' must be a function")
   assert(after == nil or type(after) == "function", "'after' must be a function")
end

local COMMON_OPTS = {
   rounds = "number",
   time = "number",
   setup = "function",
   teardown = "function",
   before = "function",
   after = "function",
}

local SUITE_ONLY_OPTS = {
   params = "table",
}

--- Validate options against allowed types.
---@param opts table Options to validate.
---@param extra_opts? table<string, string> Additional valid options beyond COMMON_OPTS.
local function validate_options(opts, extra_opts)
   for key, value in pairs(opts) do
      local expected_type = COMMON_OPTS[key] or (extra_opts and extra_opts[key])
      if not expected_type then
         error("Unknown option: " .. key)
      end
      if type(value) ~= expected_type then
         error(string.format("Option '%s' should be %s", key, expected_type))
      end
   end

   if opts.rounds and opts.rounds ~= math_floor(opts.rounds) then
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

---@class luamark.Options Benchmark configuration for timeit/memit.
---@field rounds? integer Target number of benchmark rounds.
---@field time? number Target duration in seconds.
---@field setup? fun(): any Function executed once before benchmark; returns context.
---@field teardown? fun(ctx?: any) Function executed once after benchmark.
---@field before? fun(ctx?: any): any Function executed before each iteration.
---@field after? fun(ctx?: any) Function executed after each iteration.

---@class luamark.SuiteOptions : luamark.Options Configuration for compare_time/compare_memory.
---@field setup? fun(p: table): any Function executed once before benchmark; receives params, returns context.
---@field teardown? fun(ctx: any, p: table) Function executed once after benchmark.
---@field before? fun(ctx: any, p: table): any Function executed before each iteration.
---@field after? fun(ctx: any, p: table) Function executed after each iteration.
---@field params? table<string, ParamValue[]> Parameter combinations to benchmark across.

--- Validate options for single API (timeit/memit).
--- Rejects params option with helpful error message.
---@param opts luamark.Options Options to validate.
local function validate_single_options(opts)
   ---@diagnostic disable-next-line: undefined-field
   if opts.params then
      error("'params' is not supported in timeit/memit. Use compare_time/compare_memory instead.")
   end
   validate_options(opts)
end

--- Validate options for suite API (compare_time/compare_memory).
---@param opts luamark.SuiteOptions Options to validate.
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

---@param samples number[] Raw measurement samples.
---@param rounds integer Number of benchmark rounds executed.
---@param iterations integer Number of iterations per round.
---@param timestamp string ISO 8601 UTC timestamp.
---@param unit default_unit Measurement unit.
---@return luamark.Stats
local function build_stats_result(samples, rounds, iterations, timestamp, unit)
   local stats = calculate_stats(samples) ---@cast stats luamark.Stats
   stats.rounds = rounds
   stats.iterations = iterations
   stats.timestamp = timestamp
   stats.unit = unit

   if unit == "s" and stats.median > 0 then
      stats.ops = 1 / stats.median
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
---@param time? number Target duration in seconds.
---@param setup? function Runs once before benchmark, returns context.
---@param teardown? function Runs once after benchmark.
---@param params? table Parameter values for this run (nil for single mode).
---@param spec_before? function Per-iteration setup (from Spec), returns iteration context.
---@param spec_after? function Per-iteration teardown (from Spec).
---@param global_before? function Shared per-iteration setup (from Options).
---@param global_after? function Shared per-iteration teardown (from Options).
---@param single_mode? boolean When true, hooks receive no params argument.
---@return luamark.Stats
local function single_benchmark(
   fn,
   measure,
   disable_gc,
   unit,
   rounds,
   time,
   setup,
   teardown,
   params,
   spec_before,
   spec_after,
   global_before,
   global_after,
   single_mode
)
   validate_benchmark_args(fn, rounds, time, setup, teardown, spec_before, spec_after)
   warn_low_precision_clock()
   disable_gc = disable_gc ~= false

   params = params or {}
   local invoke = make_invoke(single_mode, params)

   local ctx
   if setup then
      ctx = invoke(setup, NIL_CTX)
   end

   -- Using a closure avoids creating a new function per iteration.
   local iteration_ctx = ctx
   local function get_ctx()
      return iteration_ctx
   end

   -- Per-iteration setup: runs global_before then spec_before.
   -- Each hook can return a new context; otherwise the previous context is preserved.
   local iteration_setup
   if global_before or spec_before then
      iteration_setup = function()
         iteration_ctx = ctx
         if global_before then
            iteration_ctx = invoke(global_before, ctx) or ctx
         end
         if spec_before then
            iteration_ctx = invoke(spec_before, iteration_ctx) or iteration_ctx
         end
      end
   end

   -- Per-iteration teardown: runs spec_after then global_after.
   local iteration_teardown
   if spec_after or global_after then
      iteration_teardown = function()
         if spec_after then
            invoke(spec_after, iteration_ctx)
         end
         if global_after then
            invoke(global_after, iteration_ctx)
         end
      end
   end

   -- Calibration serves as warmup: by the time this completes,
   -- the function has been called many times (JIT compiled, caches hot).
   local iterations = calibrate_iterations(fn, iteration_setup, iteration_teardown, get_ctx, params)

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
         if completed_rounds == 1 and not rounds and not time then
            -- Wait 1 round to gather a sample of loop duration,
            -- as memit can slow down the loop significantly because of the collectgarbage calls.
            rounds, time = calibrate_stop(duration)
         end
      until (time and total_duration >= (time - duration))
         or (rounds and completed_rounds == rounds)
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
---@class luamark.Spec
---@field fn fun(ctx: any, p: table) Benchmark function; receives iteration context and params.
---@field before? fun(ctx: any, p: table): any Per-iteration setup; returns iteration context.
---@field after? fun(ctx: any, p: table) Per-iteration teardown.

--- Parse a benchmark specification into its components.
---@param spec function|luamark.Spec Function or Spec table.
---@return function fn Benchmark function.
---@return function? before Per-iteration setup.
---@return function? after Per-iteration teardown.
local function parse_spec(spec)
   if type(spec) == "function" then
      return spec
   end
   assert(type(spec) == "table", "spec must be a function or table")
   assert(type(spec.fn) == "function", "spec.fn must be a function")
   assert(not spec.before or type(spec.before) == "function", "spec.before must be a function")
   assert(not spec.after or type(spec.after) == "function", "spec.after must be a function")
   return spec.fn, spec.before, spec.after
end

--- Run benchmarks on a table of functions with optional params.
---@param funcs table<string, function|luamark.Spec> Table of named functions or Specs to benchmark.
---@param measure Measure Measurement function.
---@param disable_gc boolean Controls garbage collection during benchmark.
---@param unit default_unit Measurement unit.
---@param opts luamark.SuiteOptions Benchmark options.
---@return luamark.Result[]
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
            opts.time,
            opts.setup,
            opts.teardown,
            p,
            spec_before,
            spec_after,
            opts.before,
            opts.after,
            false -- suite mode: hooks receive params
         )
         -- Flatten: merge params and stats into single row
         local row = { name = name }
         for pk, pv in pairs(p) do
            row[pk] = pv
         end
         for sk, sv in pairs(stats) do
            row[sk] = sv
         end
         results[#results + 1] = row
      end
   end

   local param_names = collect_param_names(results)
   rank_results(results, param_names)
   setmetatable(results, {
      __tostring = function(self)
         return luamark.render(self, true)
      end,
   })
   return results
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

--- Render benchmark results as a formatted string.
---@param results luamark.Result[] Benchmark results (flat array from compare_time/compare_memory).
---@param short? boolean If true, show bar chart only; if false/nil, show full table.
---@param max_width? integer Maximum output width (default: terminal width).
---@return string
function luamark.render(results, short, max_width)
   assert(results and #results > 0, "'results' is nil or empty.")

   max_width = max_width or get_term_width()
   local format = short and "compact" or "plain"
   local param_names = collect_param_names(results)

   -- Group by params (single group with key "" if no params)
   local groups = {} ---@type table<string, luamark.Result[]>
   for i = 1, #results do
      local row = results[i]
      local key = format_params(row, param_names)
      groups[key] = groups[key] or {}
      groups[key][#groups[key] + 1] = row
   end

   local group_keys = sorted_keys(groups)

   if #group_keys == 1 then
      return render_summary(groups[group_keys[1]], format, max_width)
   end

   -- Multiple groups = add param headers
   local output = {}
   for i = 1, #group_keys do
      local key = group_keys[i]
      if key ~= "" then
         output[#output + 1] = key
      end
      output[#output + 1] = render_summary(groups[key], format, max_width)
      output[#output + 1] = ""
   end

   return table.concat(output, "\n")
end

--- Benchmark a single function for execution time.
--- Time is represented in seconds.
---@param fn fun(ctx?: any) Function to benchmark; receives context from setup.
---@param opts? luamark.Options Benchmark configuration.
---@return luamark.Stats Benchmark statistics.
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
      opts.time,
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
---@param opts? luamark.Options Benchmark configuration.
---@return luamark.Stats Benchmark statistics.
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
      opts.time,
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
--- Results are sorted by parameter group, then by rank (fastest first) within each group.
---@param funcs table<string, function|luamark.Spec> Table of named functions or Specs to benchmark.
---@param opts? luamark.SuiteOptions Benchmark configuration with optional params.
---@return luamark.Result[] Sorted array of benchmark results with ranking.
function luamark.compare_time(funcs, opts)
   assert(type(funcs) == "table", "'funcs' must be a table, got " .. type(funcs))
   validate_funcs(funcs)
   opts = opts or {}
   validate_suite_options(opts)
   return benchmark_suite(funcs, measure_time, true, "s", opts)
end

--- Compare multiple functions for memory usage.
--- Memory is represented in kilobytes.
--- Results are sorted by parameter group, then by rank (fastest first) within each group.
---@param funcs table<string, function|luamark.Spec> Table of named functions or Specs to benchmark.
---@param opts? luamark.SuiteOptions Benchmark configuration with optional params.
---@return luamark.Result[] Sorted array of benchmark results with ranking.
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

--- Format a count to a human-readable string.
--- Automatically select the best SI suffix (M, k, or none).
---@param n number Count value.
---@return string Formatted count string (e.g., "1k", "12.5M").
function luamark.humanize_count(n)
   return humanize(n, "count")
end

--- Unload modules matching a Lua pattern from package.loaded.
--- Useful for benchmarking module load times or resetting state.
---@param pattern string Lua pattern to match module names against.
---@return integer count Number of modules unloaded.
function luamark.unload(pattern)
   local to_unload = {}
   for name in pairs(package.loaded) do
      if name:match(pattern) then
         to_unload[#to_unload + 1] = name
      end
   end
   for _, name in ipairs(to_unload) do
      package.loaded[name] = nil
   end
   return #to_unload
end

if rawget(_G, "_TEST") then
   ---@package
   luamark._internal = {
      BOOTSTRAP_RESAMPLES = BOOTSTRAP_RESAMPLES,
      CALIBRATION_PRECISION = CALIBRATION_PRECISION,
      DEFAULT_TERM_WIDTH = DEFAULT_TERM_WIDTH,
      MAX_ROUNDS = MAX_ROUNDS,
      bootstrap_ci = bootstrap_ci,
      math_median = math_median,
      calculate_stats = calculate_stats,
      get_min_clocktime = get_min_clocktime,
      humanize = humanize,
      measure_memory = measure_memory,
      measure_time = measure_time,
      rank_results = rank_results,
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
