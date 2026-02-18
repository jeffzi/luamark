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

local jit_flush = jit and jit.flush
local jit_opt_start = jit and jit.opt and jit.opt.start

-- ----------------------------------------------------------------------------
-- Config
-- ----------------------------------------------------------------------------

-- Config defaults balance accuracy vs runtime across function speeds:
-- (config.time=1s, config.rounds=100, MAX_ROUNDS=100, RESAMPLES=5000)
--
-- | Function    | Duration | Rounds | Iterations | Bootstrap | Total |
-- |-------------|----------|--------|------------|-----------|-------|
-- | Very fast   | ~1μs     | 100    | 1,000+     | ~5ms      | ~10ms |
-- | Fast        | ~100μs   | 100    | 1          | ~5ms      | ~15ms |
-- | Medium      | ~10ms    | 100    | 1          | ~5ms      | ~1s   |
-- | Slow        | ~500ms   | 100    | 1          | ~5ms      | ~50s  |
--
-- MAX_ROUNDS caps fast functions to ensure consistent sample count.
-- BOOTSTRAP_RESAMPLES (5k) provides accurate 95% CI for median.

local BOOTSTRAP_RESAMPLES = 5000
local CALIBRATION_PRECISION = 5
local DEFAULT_TERM_WIDTH = 100
local MEMORY_PRECISION = 4
local JIT_MAXTRACE = 20000
local MAX_CALIBRATION_ATTEMPTS = 10
local MAX_ITERATIONS = 1e6
local MAX_ROUNDS = 100

local config = {
   rounds = 100,
   time = 1,
}

local TIME = "s"
local MEMORY = "kb"
local COUNT = "count"

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

-- Dispatch loaded module to a function that returns the clock function and clock precision.
local CLOCKS = {
   chronos = function(chronos)
      return chronos.nanotime, 9
   end,
   ["posix.time"] = function(posix_time)
      local posix_clock_gettime = posix_time.clock_gettime
      local POSIX_CLOCK_MONOTONIC = posix_time.CLOCK_MONOTONIC
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
local function measure_memory_once(fn, ctx, params)
   collectgarbage("collect")
   local start = collectgarbage("count")
   fn(ctx, params)
   return collectgarbage("count") - start
end

-- ----------------------------------------------------------------------------
-- Statistics
-- ----------------------------------------------------------------------------

---@param sorted_samples number[]
---@return number
local function math_median(sorted_samples)
   local n = #sorted_samples
   local mid = math_floor(n / 2)
   if n % 2 == 0 then
      return (sorted_samples[mid] + sorted_samples[mid + 1]) / 2
   end
   return sorted_samples[mid + 1]
end

---@param bootstrap number[]
---@param samples number[]
---@param n integer
---@return number
local function resample_median(bootstrap, samples, n)
   for j = 1, n do
      bootstrap[j] = samples[math_random(n)]
   end
   table_sort(bootstrap)
   return math_median(bootstrap)
end

--- Calculate 95% CI for median using bootstrap resampling.
---@param samples number[]
---@param n_resamples integer
---@return number lower, number upper
local function bootstrap_ci(samples, n_resamples)
   local n = #samples
   local bootstrap = {}

   local medians = {}
   for i = 1, n_resamples do
      medians[i] = resample_median(bootstrap, samples, n)
   end
   table_sort(medians)

   -- Clamp indices to valid range for small resample counts
   local lower_idx = math_max(1, math_floor(n_resamples * 0.025))
   local upper_idx = math_min(n_resamples, math_ceil(n_resamples * 0.975))

   return medians[lower_idx], medians[upper_idx]
end

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
      median = median,
      ci_lower = ci_lower,
      ci_upper = ci_upper,
      ci_margin = ci_margin,
      total = total,
      samples = samples,
   }
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
         -- termsize returns (nil, error_string) on failure; check rows to detect success
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
   { "m", 60, "%.0f" },
   { "s", 1, "%.0f" },
   { "ms", 1e-3, "%.0f" },
   { "us", 1e-6, "%.0f" },
   { "ns", 1e-9, "%.0f" },
}

-- Thresholds relative to input unit (kilobytes)
local MEMORY_UNITS = {
   { "TB", 1024 ^ 3, "%.0f" },
   { "GB", 1024 ^ 2, "%.0f" },
   { "MB", 1024, "%.0f" },
   { "kB", 1, "%.0f" },
   { "B", 1 / 1024, "%.0f" },
}

local COUNT_UNITS = {
   { "M", 1e6, "%.1f" },
   { "k", 1e3, "%.1f" },
   { "", 1, "%.1f" },
}

local UNITS = {
   [TIME] = { label = "Time", scales = TIME_UNITS },
   [MEMORY] = { label = "Memory", scales = MEMORY_UNITS },
   [COUNT] = { scales = COUNT_UNITS },
}

local RENDER_UNITS = { TIME, MEMORY }

local BAR_CHAR = "█"
local BAR_MAX_WIDTH = 20
local BAR_MIN_WIDTH = 10
local NAME_MIN_WIDTH = 4
local ELLIPSIS = "..."
local EMBEDDED_BAR_WIDTH = 8

local SUMMARIZE_HEADERS = {
   "name",
   "rank",
   "relative",
   "median",
   "ops",
}

local HEADER_LABELS = {
   name = "Name",
   rank = "Rank",
   relative = "Relative",
   median = "Median",
   ops = "Ops",
}

---@param str string
---@return string
local function trim_zeroes(str)
   if not str:find("%.") then
      return str
   end
   return (str:gsub("%.?0+$", ""))
end

---@param str string
---@return integer
local function utf8_width(str)
   local width = 0
   for i = 1, #str do
      local byte = string.byte(str, i)
      -- Skip UTF-8 continuation bytes (0x80-0xBF)
      if byte < 0x80 or byte >= 0xC0 then
         width = width + 1
      end
   end
   return width
end

---@param str string
---@param width integer
---@return string
local function align_left(str, width)
   return str .. string.rep(" ", width - utf8_width(str))
end

---@param str string
---@param width integer
---@return string
local function align_right(str, width)
   return string.rep(" ", width - utf8_width(str)) .. str
end

---@param str string
---@param width integer
---@return string
local function center(str, width)
   local total_padding = math_max(0, width - utf8_width(str))
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

---@param value number Value to format.
---@param unit_type default_unit Unit type: "s" (time), "kb" (memory), or "count".
---@return string
local function humanize(value, unit_type)
   local units = UNITS[unit_type].scales

   for i = 1, #units do
      local symbol, threshold, fmt = units[i][1], units[i][2], units[i][3]
      if value >= threshold then
         return trim_zeroes(string.format(fmt, value / threshold)) .. symbol
      end
   end

   return "0" .. units[#units][1]
end

---@param median number
---@param margin number
---@param unit default_unit
---@return string
local function format_median(median, margin, unit)
   local margin_str = humanize(margin, unit)
   if margin_str:match("^0") then
      return humanize(median, unit)
   end
   return humanize(median, unit) .. " ± " .. margin_str
end

---@param stats luamark.Stats
---@return string
local function render_stats(stats)
   local unit = stats.unit
   local lines = {
      "Median: " .. humanize(stats.median, unit),
      "CI: "
         .. humanize(stats.ci_lower, unit)
         .. " - "
         .. humanize(stats.ci_upper, unit)
         .. " (± "
         .. humanize(stats.ci_margin, unit)
         .. ")",
   }
   if stats.ops then
      lines[#lines + 1] = "Ops: " .. humanize(stats.ops, COUNT) .. "/s"
   end
   lines[#lines + 1] = "Rounds: " .. stats.rounds
   lines[#lines + 1] = "Total: " .. humanize(stats.total, unit)
   return table.concat(lines, "\n")
end

--- Format relative with arrow: 1x (baseline), ↑Nx (faster), ↓Nx (slower).
---@param relative number|nil
---@return string
local function format_relative(relative)
   if not relative then
      return ""
   end
   if relative == 1 then
      return "1x"
   elseif relative < 1 then
      return "↑" .. trim_zeroes(string.format("%.2f", 1 / relative)) .. "x"
   else
      return "↓" .. trim_zeroes(string.format("%.2f", relative)) .. "x"
   end
end

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
      relative = format_relative(stats.relative),
      median = format_median(stats.median, stats.ci_margin, unit),
      ops = stats.ops and (humanize(stats.ops, COUNT) .. "/s") or "",
   }
end

---@param rows table[]
---@return integer[]
local function calculate_column_widths(rows)
   local widths = {}
   for col, header in ipairs(SUMMARIZE_HEADERS) do
      local max_width = utf8_width(HEADER_LABELS[header])
      for row = 1, #rows do
         max_width = math_max(max_width, utf8_width(rows[row][header] or ""))
      end
      widths[col] = max_width
   end
   return widths
end

--- Mutates rows and widths in place.
---@param rows table[]
---@param widths integer[]
---@param max_width integer
local function fit_names_inplace(rows, widths, max_width)
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

---@param relative_str string
---@param bar_width integer
---@param max_relative_width integer
---@return string
local function build_relative_bar(relative_str, bar_width, max_relative_width)
   local bar = string.rep(BAR_CHAR, bar_width)
   local padded_bar = bar .. string.rep(" ", EMBEDDED_BAR_WIDTH - bar_width)
   -- Use utf8_width for UTF-8 aware padding (arrows are multi-byte)
   local padded_relative = string.rep(" ", max_relative_width - utf8_width(relative_str))
      .. relative_str
   return padded_bar .. " " .. padded_relative
end

---@param rows {name: string, relative: string, median: string, median_value: number}[]
---@param max_width? integer
---@return string[]
local function render_bar_chart(rows, max_width)
   max_width = max_width or get_term_width()

   local max_median = 0
   local max_suffix_len = 0
   local max_name_len = NAME_MIN_WIDTH
   for i = 1, #rows do
      local row = rows[i]
      max_median = math_max(max_median, row.median_value)
      -- Suffix format: " relative (median)" -> " " + " (" + ")" = 3 fixed chars
      max_suffix_len = math_max(max_suffix_len, 3 + utf8_width(row.relative) + #row.median)
      max_name_len = math_max(max_name_len, utf8_width(row.name))
   end

   -- Calculate column widths
   local available = max_width - 3 - max_suffix_len
   local bar_max = math_max(BAR_MIN_WIDTH, math_min(BAR_MAX_WIDTH, available - NAME_MIN_WIDTH))
   local name_max = math_max(NAME_MIN_WIDTH, math_min(max_name_len, available - bar_max))

   local lines = {}
   for i = 1, #rows do
      local row = rows[i]
      -- Scale bar by median (smaller bar = less time = faster)
      local bar_width = math_max(1, math_floor((row.median_value / max_median) * bar_max))
      local name = align_left(truncate_name(row.name, name_max), name_max)
      local bar = string.rep(BAR_CHAR, bar_width)
      lines[i] = string.format("%s  |%s %s (%s)", name, bar, row.relative, row.median)
   end
   return lines
end

-- Columns that should be right-aligned
local RIGHT_ALIGN_COLS = { rank = true, median = true, ops = true }

---@param rows table[]
---@param widths integer[]
---@param show_ops boolean
---@return string
local function render_plain_table(rows, widths, show_ops)
   local max_median = 0
   local max_relative_width = 0
   for i = 1, #rows do
      max_median = math_max(max_median, rows[i].median_value)
      max_relative_width = math_max(max_relative_width, utf8_width(rows[i].relative))
   end
   local relative_bar_width = EMBEDDED_BAR_WIDTH + max_relative_width + 1

   local visible_headers = {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      if header ~= "ops" or show_ops then
         visible_headers[#visible_headers + 1] = { idx = i, name = header }
      end
   end

   local header_cells, underline_cells = {}, {}
   for _, col in ipairs(visible_headers) do
      local width = (col.name == "relative") and relative_bar_width or widths[col.idx]
      header_cells[#header_cells + 1] = center(HEADER_LABELS[col.name], width)
      underline_cells[#underline_cells + 1] = string.rep("-", width)
   end

   local lines = { concat_line(header_cells), concat_line(underline_cells) }

   for r = 1, #rows do
      local row = rows[r]
      local cells = {}
      for _, col in ipairs(visible_headers) do
         if col.name == "relative" then
            -- Scale bar by median (smaller bar = less time = faster)
            local bar_width =
               math_max(1, math_floor((row.median_value / max_median) * EMBEDDED_BAR_WIDTH))
            cells[#cells + 1] = align_left(
               build_relative_bar(row.relative, bar_width, max_relative_width),
               relative_bar_width
            )
         elseif RIGHT_ALIGN_COLS[col.name] then
            cells[#cells + 1] = align_right(row[col.name], widths[col.idx])
         else
            cells[#cells + 1] = align_left(row[col.name], widths[col.idx])
         end
      end
      lines[#lines + 1] = concat_line(cells)
   end

   return table.concat(lines, "\n")
end

---@param results luamark.Result[]
---@param format "plain"|"compact"
---@param max_width? integer
---@return string
local function render_summary(results, format, max_width)
   local rows = {}
   for i = 1, #results do
      local row = format_row(results[i])
      row.name = results[i].name
      ---@diagnostic disable-next-line: assign-type-mismatch
      row.median_value = results[i].median
      rows[i] = row
   end

   max_width = max_width or get_term_width()

   if format == "compact" then
      return table.concat(render_bar_chart(rows, max_width), "\n")
   end

   local show_ops = results[1] and results[1].unit == TIME

   local widths = calculate_column_widths(rows)
   fit_names_inplace(rows, widths, max_width)
   return render_plain_table(rows, widths, show_ops)
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

---@param params table<string, any[]>?
---@return table[]
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
---@param precision integer
---@return number
local function math_round(num, precision)
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

      local scale
      if total_time > 0 then
         scale = min_time / total_time
      else
         scale = ZERO_TIME_SCALE
      end
      iterations = math_ceil(iterations * scale)

      if iterations >= MAX_ITERATIONS then
         return MAX_ITERATIONS
      end
   end

   return iterations
end

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
local function validate_benchmark_args(fn, rounds, time, setup, teardown)
   assert(type(fn) == "function", "'fn' must be a function, got " .. type(fn))
   assert(rounds == nil or rounds > 0, "'rounds' must be > 0.")
   assert(not time or time > 0, "'time' must be > 0.")
   assert(setup == nil or type(setup) == "function", "'setup' must be a function")
   assert(teardown == nil or type(teardown) == "function", "'teardown' must be a function")
end

local COMMON_OPTS = {
   rounds = "number",
   time = "number",
   setup = "function",
   teardown = "function",
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

--- Validate options for single API (timeit/memit).
--- Reject params option with helpful error message.
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
--- Reject numeric keys (arrays) since function names must be strings.
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

   if unit == TIME and stats.median > 0 then
      stats.ops = 1 / stats.median
   end

   setmetatable(stats, {
      __tostring = function(self)
         return format_median(self.median, self.ci_margin, unit)
      end,
   })
   return stats
end

-- Sentinel to avoid creating new tables for single mode (timeit/memit).
local EMPTY_PARAMS = {}

--- Run a benchmark on a function using a specified measurement method.
---@param fn luamark.Fun Function to benchmark.
---@param measure Measure Measurement function (e.g., measure_time or measure_memory).
---@param suspend_gc boolean Controls garbage collection during benchmark.
---@param unit default_unit Measurement unit.
---@param rounds? number Number of rounds.
---@param time? number Target duration in seconds.
---@param setup? function Runs once before benchmark, returns context.
---@param teardown? function Runs once after benchmark.
---@param params? table Parameter values for this run.
---@param before? function Per-iteration setup (from Spec), returns iteration context.
---@param after? function Per-iteration teardown (from Spec).
---@return luamark.Stats
local function single_benchmark(
   fn,
   measure,
   suspend_gc,
   unit,
   rounds,
   time,
   setup,
   teardown,
   params,
   before,
   after
)
   validate_benchmark_args(fn, rounds, time, setup, teardown)
   warn_low_precision_clock()

   params = params or EMPTY_PARAMS

   local ctx
   if setup then
      ctx = setup(params)
   end

   -- Using a closure avoids creating a new function per iteration.
   local iteration_ctx = ctx
   local function get_ctx()
      return iteration_ctx
   end

   -- Per-iteration setup from Spec.before.
   -- The hook can return a new context; otherwise the previous context is preserved.
   local iteration_setup
   if before then
      iteration_setup = function()
         iteration_ctx = before(ctx, params) or ctx
      end
   end

   -- Per-iteration teardown from Spec.after.
   local iteration_teardown
   if after then
      iteration_teardown = function()
         after(iteration_ctx, params)
      end
   end

   -- LuaJIT allocates GCtrace structures through the GC allocator when
   -- compiling traces. Spec hooks (before/after) can overflow the trace cache
   -- (default maxtrace=1000), causing the JIT to flush and recompile fn's
   -- trace inside the measurement window — polluting both time and memory
   -- readings. Flush stale traces from prior benchmarks and raise maxtrace
   -- so hooks and fn can coexist without overflow.
   if jit_flush and jit_opt_start and before then
      jit_flush()
      jit_opt_start("maxtrace=" .. JIT_MAXTRACE)
   end

   -- For time benchmarks, calibrate iterations for statistical accuracy.
   -- Calibration also serves as JIT warmup (traces compiled, caches hot).
   -- For memory benchmarks, skip calibration (iterations don't improve accuracy
   -- and would cause hangs with low-precision clocks due to GC overhead).
   local iterations = 1
   if suspend_gc then
      iterations = calibrate_iterations(fn, iteration_setup, iteration_teardown, get_ctx, params)
   end

   local timestamp = os.date("!%Y-%m-%d %H:%M:%SZ") --[[@as string]]
   local samples = {}
   local completed_rounds = 0
   local total_duration = 0
   local duration

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

   if suspend_gc then
      collectgarbage("stop")
   end

   local bench_ok, bench_err = pcall(run_benchmark_loop)

   collectgarbage("restart")

   if teardown then
      local teardown_ok, teardown_err = pcall(teardown, ctx, params)
      if not teardown_ok and bench_ok then
         error(teardown_err, 0)
      end
   end

   if not bench_ok then
      error(bench_err, 0)
   end

   return build_stats_result(samples, completed_rounds, iterations, timestamp, unit)
end

--- Parse a benchmark specification into its components.
---@param spec luamark.Fun|luamark.Spec Function or Spec table.
---@return luamark.Fun fn Benchmark function.
---@return luamark.before? before Per-iteration setup.
---@return luamark.after? after Per-iteration teardown.
---@return boolean? baseline If true, this function serves as 1x baseline.
local function parse_spec(spec)
   if type(spec) == "function" then
      return spec
   end
   assert(type(spec) == "table", "spec must be a function or table")
   assert(type(spec.fn) == "function", "spec.fn must be a function")
   assert(not spec.before or type(spec.before) == "function", "spec.before must be a function")
   assert(not spec.after or type(spec.after) == "function", "spec.after must be a function")
   assert(
      spec.baseline == nil or type(spec.baseline) == "boolean",
      "spec.baseline must be a boolean"
   )
   return spec.fn, spec.before, spec.after, spec.baseline
end

-- ----------------------------------------------------------------------------
-- Result helpers
-- ----------------------------------------------------------------------------

---Collect all unique parameter names from result rows.
---@param rows luamark.Result[]
---@return string[]
local function collect_param_names(rows)
   local seen = {}
   for i = 1, #rows do
      local params = rows[i].params
      if params then
         for key in pairs(params) do
            seen[key] = true
         end
      end
   end
   return sorted_keys(seen)
end

---Format parameter values as a readable string.
---@param params table<string, any>?
---@param param_names string[]
---@return string
local function format_params(params, param_names)
   if not params then
      return ""
   end
   local parts = {}
   for i = 1, #param_names do
      local name = param_names[i]
      if params[name] ~= nil then
         parts[#parts + 1] = name .. "=" .. tostring(params[name])
      end
   end
   return table.concat(parts, ", ")
end

---@param a luamark.Result
---@param b luamark.Result
---@return boolean
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
   for _, row in ipairs(results) do
      local key = format_params(row.params, param_names)
      groups[key] = groups[key] or {}
      groups[key][#groups[key] + 1] = row
   end

   for key, group in pairs(groups) do
      table_sort(group, compare_by_median)

      -- Find baseline row (if any) and validate only one exists
      local baseline_row = nil
      for _, row in ipairs(group) do
         if row.baseline then
            assert(baseline_row == nil, "multiple baselines in group: " .. key)
            baseline_row = row
         end
      end

      -- Use baseline median if specified, otherwise use fastest (first after sort)
      local baseline_median = baseline_row and baseline_row.median or group[1].median

      local first = group[1]
      if baseline_median > 0 then
         first.relative = first.median / baseline_median
      else
         first.relative = 1
      end
      first.rank = 1
      first.is_approximate = false

      for i = 2, #group do
         local r = group[i]
         local prev = group[i - 1]
         if baseline_median > 0 then
            r.relative = r.median / baseline_median
         else
            r.relative = 1
         end

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
   local i = 1
   for _, key in ipairs(sorted_keys(groups)) do
      for _, row in ipairs(groups[key]) do
         results[i] = row
         i = i + 1
      end
   end
end

--- Run benchmarks on a table of functions with optional params.
---@param funcs table<string, function|luamark.Spec> Table of named functions or Specs to benchmark.
---@param measure Measure Measurement function.
---@param suspend_gc boolean Controls garbage collection during benchmark.
---@param unit default_unit Measurement unit.
---@param opts luamark.SuiteOptions Benchmark options.
---@return luamark.Result[]
local function benchmark_suite(funcs, measure, suspend_gc, unit, opts)
   opts = opts or {}
   local params_list = expand_params(opts.params)
   local results = {}

   local names = sorted_keys(funcs)
   for j = 1, #names do
      local name = names[j]
      local fn, before, after, baseline = parse_spec(funcs[name])
      for i = 1, #params_list do
         local p = params_list[i]
         local stats = single_benchmark(
            fn,
            measure,
            suspend_gc,
            unit,
            opts.rounds,
            opts.time,
            opts.setup,
            opts.teardown,
            p,
            before,
            after
         )
         -- Build result row with nested params
         local row = { name = name, params = p }
         for sk, sv in pairs(stats) do
            row[sk] = sv
         end
         if baseline then
            row.baseline = true
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

---@class luamark.BaseStats
---@field median number Median value of samples.
---@field ci_lower number Lower bound of 95% confidence interval for median.
---@field ci_upper number Upper bound of 95% confidence interval for median.
---@field ci_margin number Half-width of confidence interval ((upper - lower) / 2).
---@field total number Sum of all samples.
---@field samples number[] Raw samples (sorted).
---@field relative? number Relative to baseline (or fastest if no baseline).
---@field rank? integer Rank within benchmark group.

---@class luamark.Stats : luamark.BaseStats
---@field rounds integer Number of rounds executed (one sample per round).
---@field iterations integer Number of iterations per round.
---@field timestamp string ISO 8601 UTC timestamp of benchmark start.
---@field unit "s"|"kb" Measurement unit (seconds or kilobytes).
---@field ops? number Operations per second (1/median). Only present for time benchmarks.
---@field relative? number Relative to baseline (or fastest if no baseline).
---@field rank? integer Rank accounting for CI overlap (tied results share the same rank).
---@field is_approximate? boolean True if rank is approximate due to overlapping CIs.

---@class luamark.Result : luamark.BaseStats
---@field name string Benchmark name.
---@field rounds integer Number of rounds executed (one sample per round).
---@field iterations integer Number of iterations per round.
---@field timestamp string ISO 8601 UTC timestamp of benchmark start.
---@field unit "s"|"kb" Measurement unit (seconds or kilobytes).
---@field ops? number Operations per second (1/median). Only present for time benchmarks.
---@field relative? number Relative to baseline (or fastest if no baseline).
---@field rank? integer Rank accounting for CI overlap (tied results share the same rank).
---@field is_approximate? boolean True if rank is approximate due to overlapping CIs.
---@field params table<string, any> User-defined parameters for this benchmark run.

---@class luamark.Options Benchmark configuration for timeit/memit.
---@field rounds? integer Target number of benchmark rounds.
---@field time? number Target duration in seconds.
---@field setup? fun(): any Called once before all iterations; returns context passed to fn.
---@field teardown? fun(ctx?: any) Called once after all rounds complete.

---@class luamark.SuiteOptions : luamark.Options Configuration for compare_time/compare_memory.
---@field setup? fun(params: table): any Called once per param combo (not per iteration); returns ctx.
---@field teardown? fun(ctx: any, params: table) Called once per param combo after all rounds.
---@field params? table<string, ParamValue[]> Parameter combinations to benchmark across.

--- Function to benchmark. Arguments can be omitted from the right.
---@alias luamark.Fun fun(ctx: any, params: table)

--- Per-iteration setup; returns iteration context.
---@alias luamark.before fun(ctx: any, params: table): any

--- Per-iteration teardown; returns iteration context.
---@alias luamark.after fun(ctx: any, params: table)

--- Per-function benchmark specification with optional lifecycle hooks.
--- Use when comparing functions that need different setup/teardown.
--- Unlike Options.setup/teardown (run once), Spec hooks run each iteration.
---@class luamark.Spec
---@field fn luamark.Fun  Benchmark function; receives iteration context and params.
---@field before? luamark.before Per-iteration setup; returns iteration context.
---@field after? luamark.after Per-iteration teardown; returns iteration context.
---@field baseline? boolean If true, this function serves as 1x baseline for relative comparison.

---@param unit_results luamark.Result[]
---@param format "plain"|"compact"
---@param max_width integer
---@return string
local function render_unit_group(unit_results, format, max_width)
   local param_names = collect_param_names(unit_results)

   -- Group by params table identity (avoids reformatting each row)
   local groups = {}
   local order = {}
   for i = 1, #unit_results do
      local p = unit_results[i].params or EMPTY_PARAMS
      if not groups[p] then
         groups[p] = {}
         order[#order + 1] = p
      end
      groups[p][#groups[p] + 1] = unit_results[i]
   end

   if #order == 1 then
      return render_summary(groups[order[1]], format, max_width)
   end

   local output = {}
   for i = 1, #order do
      local p = order[i]
      local header = format_params(p, param_names)
      if header ~= "" then
         output[#output + 1] = header
      end
      output[#output + 1] = render_summary(groups[p], format, max_width)
      if i < #order then
         output[#output + 1] = ""
      end
   end
   return table.concat(output, "\n")
end

--- Render benchmark results as a formatted string.
---
--- Mixed results (time and memory) are automatically grouped by unit.
---@param results luamark.Stats|luamark.Result[] Single stats or benchmark results array.
---@param short? boolean If true, show bar chart only; if false/nil, show full table. Ignored for single Stats.
---@param max_width? integer Maximum output width (default: terminal width). Ignored for single Stats.
---@return string
function luamark.render(results, short, max_width)
   -- Handle single Stats object (has median field, not an array)
   if results and results.median then
      ---@cast results luamark.Stats
      return render_stats(results)
   end

   assert(results and #results > 0, "'results' is nil or empty.")

   max_width = max_width or get_term_width()
   local format = short and "compact" or "plain"

   -- Group by unit
   local groups = {}
   for i = 1, #results do
      local unit = results[i].unit
      groups[unit] = groups[unit] or {}
      groups[unit][#groups[unit] + 1] = results[i]
   end

   local keys = {}
   for _, unit in ipairs(RENDER_UNITS) do
      if groups[unit] then
         keys[#keys + 1] = unit
      end
   end

   if #keys == 1 then
      return render_unit_group(groups[keys[1]], format, max_width)
   end

   local output = {}
   for i = 1, #keys do
      local unit = keys[i]
      local header = UNITS[unit].label
      output[#output + 1] = header
      output[#output + 1] = render_unit_group(groups[unit], format, max_width)
      if i < #keys then
         output[#output + 1] = ""
      end
   end
   return table.concat(output, "\n")
end

--- Benchmark a single function for execution time.
--- Time is represented in seconds.
---@param fn luamark.Fun Function to benchmark.
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
      TIME,
      opts.rounds,
      opts.time,
      opts.setup,
      opts.teardown
   )
end

--- Benchmark a single function for memory usage.
--- Memory is represented in kilobytes.
---@param fn luamark.Fun Function to benchmark.
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
      MEMORY,
      opts.rounds,
      opts.time,
      opts.setup,
      opts.teardown
   )
end

--- Compare multiple functions for execution time.
--- Time is represented in seconds.
--- Results are sorted by parameter group, then by rank (fastest first) within each group.
---@param funcs table<string, luamark.Fun|luamark.Spec> Table of named functions or Specs to benchmark.
---@param opts? luamark.SuiteOptions Benchmark configuration with optional params.
---@return luamark.Result[] Sorted array of benchmark results with ranking.
function luamark.compare_time(funcs, opts)
   assert(type(funcs) == "table", "'funcs' must be a table, got " .. type(funcs))
   validate_funcs(funcs)
   opts = opts or {}
   validate_suite_options(opts)
   return benchmark_suite(funcs, measure_time, true, TIME, opts)
end

--- Compare multiple functions for memory usage.
--- Memory is represented in kilobytes.
--- Results are sorted by parameter group, then by rank (fastest first) within each group.
---@param funcs table<string, luamark.Fun|luamark.Spec> Table of named functions or Specs to benchmark.
---@param opts? luamark.SuiteOptions Benchmark configuration with optional params.
---@return luamark.Result[] Sorted array of benchmark results with ranking.
function luamark.compare_memory(funcs, opts)
   assert(type(funcs) == "table", "'funcs' must be a table, got " .. type(funcs))
   validate_funcs(funcs)
   opts = opts or {}
   validate_suite_options(opts)
   return benchmark_suite(funcs, measure_memory, false, MEMORY, opts)
end

--- Format a time value to a human-readable string.
--- Automatically select the best unit (m, s, ms, us, ns).
---@param s number Time in seconds.
---@return string Formatted time string (e.g., "42ns", "1.5ms").
function luamark.humanize_time(s)
   return humanize(s, TIME)
end

--- Format a memory value to a human-readable string.
--- Automatically select the best unit (TB, GB, MB, kB, B).
---@param kb number Memory in kilobytes.
---@return string Formatted memory string (e.g., "512kB", "1.5MB").
function luamark.humanize_memory(kb)
   return humanize(kb, MEMORY)
end

--- Format a count to a human-readable string.
--- Automatically select the best SI suffix (M, k, or none).
---@param n number Count value.
---@return string Formatted count string (e.g., "1k", "12.5M").
function luamark.humanize_count(n)
   return humanize(n, COUNT)
end

---@class luamark.Timer
---@field start fun() Start timing.
---@field stop fun(): number Stop timing and return elapsed seconds.
---@field elapsed fun(): number Get total elapsed time.
---@field reset fun() Reset timer for reuse.

--- Create a standalone Timer for profiling outside of benchmarks.
--- @return luamark.Timer
function luamark.Timer()
   local running = false
   local start_time = 0
   local total = 0

   return {
      start = function()
         if running then
            error("timer.start() called while already running")
         end
         running = true
         start_time = clock()
      end,
      stop = function()
         if not running then
            error("timer.stop() called without start()")
         end
         local segment = clock() - start_time
         total = total + segment
         running = false
         return segment
      end,
      elapsed = function()
         if running then
            error("timer still running (missing stop())")
         end
         return total
      end,
      reset = function()
         total = 0
         running = false
      end,
   }
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
