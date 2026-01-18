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
---@alias Target fun()|{[string]: fun()|Spec} A function or table of named functions/Specs to benchmark.

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

---@param n number
---@return boolean
local function is_nan_or_inf(n)
   return n ~= n or n == math.huge or n == -math.huge
end

local VALID_PARAM_TYPES = { string = true, number = true, boolean = true }

---Store a value at a nested path based on parameter values.
---Creates intermediate tables as needed. Keys are sorted alphabetically.
---Example: set_nested(t, {n=100, type="array"}, stats) -> t.n[100].type["array"] = stats
---Returns false when params are empty (caller should assign value directly).
---@param tbl table Target table to store into
---@param params table Parameter names to values (values must be primitives)
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
               "param '%s' has invalid type '%s' (must be string, number, or boolean): %s",
               name,
               param_type,
               tostring(param_value)
            )
         )
      end
      if param_type == "number" and is_nan_or_inf(param_value) then
         error("param '" .. name .. "' cannot be NaN or infinite")
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

---@param params table<string, any[]>?
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

-- Offset above 0.5 to handle floating-point edge cases in rounding
local ROUNDING_EPSILON = 0.50000000000008

---@param num number
---@param precision number
---@return number
local function math_round(num, precision)
   local mul = 10 ^ (precision or 0)
   local rounded
   if num > 0 then
      rounded = math.floor(num * mul + ROUNDING_EPSILON) / mul
   else
      rounded = math.ceil(num * mul - ROUNDING_EPSILON) / mul
   end
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

---@param samples number[]
---@return BaseStats
local function calculate_stats(samples)
   local count = #samples

   table.sort(samples)
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

   local ranks = {}
   for benchmark_name, stats in pairs(results) do
      table.insert(ranks, { name = benchmark_name, value = stats[key] })
   end

   table.sort(ranks, function(a, b)
      return a.value < b.value
   end)

   local rnk = 1
   local prev_value
   local min = ranks[1].value
   for i, entry in ipairs(ranks) do
      if prev_value ~= entry.value then
         rnk = i
         prev_value = entry.value
      end
      results[entry.name].rank = rnk
      results[entry.name].ratio = (rnk == 1 or min == 0) and 1 or entry.value / min
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
      humanize(stats.mean, unit),
      humanize(stats.stddev, unit),
      stats.rounds
   )
end

local HUMANIZE_FIELDS = {
   min = true,
   max = true,
   mean = true,
   stddev = true,
   median = true,
}

---@param stats Stats
---@return table<string, string>
local function format_row(stats)
   local unit = stats.unit
   local row = {}
   for name, value in pairs(stats) do
      if name == "ratio" then
         row[name] = string.format("%.2f", value)
      elseif HUMANIZE_FIELDS[name] then
         row[name] = humanize(value, unit)
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
      -- Suffix format: " Nx (median)" -> space + "x" + " (" + ")" = 5 fixed chars
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
         cells[i] = escape_csv(row[header] or "")
      end
      lines[#lines + 1] = table.concat(cells, ",")
   end
   return table.concat(lines, "\n")
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

---@param rows table[]
---@param widths integer[]
---@param format "plain"|"compact"|"markdown"
---@return string[]
local function build_table(rows, widths, format)
   local lines = {}

   -- For plain format, compute max ratio and ratio bar column width
   local max_ratio = 1
   local max_ratio_width = 0
   local ratio_bar_width = 0
   if format == "plain" then
      for i = 1, #rows do
         local ratio = tonumber(rows[i].ratio) or 1
         max_ratio = math.max(max_ratio, ratio)
         max_ratio_width = math.max(max_ratio_width, #rows[i].ratio)
      end
      -- Width: bar + space + ratio + "x"
      ratio_bar_width = EMBEDDED_BAR_WIDTH + 1 + max_ratio_width + 1
   end

   local header_cells, underline_cells = {}, {}
   for i, header in ipairs(SUMMARIZE_HEADERS) do
      -- Replace ratio column with bar+ratio for plain format
      if format == "plain" and header == "ratio" then
         header_cells[#header_cells + 1] = center("Ratio", ratio_bar_width)
         underline_cells[#underline_cells + 1] = string.rep("-", ratio_bar_width)
      else
         header_cells[#header_cells + 1] = center(header:gsub("^%l", string.upper), widths[i])
         underline_cells[#underline_cells + 1] = string.rep("-", widths[i])
      end
   end
   lines[1] = concat_line(header_cells, format)
   lines[2] = concat_line(underline_cells, format)

   for r = 1, #rows do
      local row = rows[r]
      local cells = {}
      for i, header in ipairs(SUMMARIZE_HEADERS) do
         -- Replace ratio with bar+ratio for plain format
         if format == "plain" and header == "ratio" then
            local ratio = tonumber(row.ratio) or 1
            local bar_width = math.max(1, math.floor((ratio / max_ratio) * EMBEDDED_BAR_WIDTH))
            cells[#cells + 1] =
               pad(build_ratio_bar(row.ratio, bar_width, max_ratio_width), ratio_bar_width)
         else
            cells[#cells + 1] = pad(row[header], widths[i])
         end
      end
      lines[r + 2] = concat_line(cells, format)
   end

   return lines
end

-- ----------------------------------------------------------------------------
-- Result type detection and parameterized summarization
-- ----------------------------------------------------------------------------

---Find depth to Stats (median field) by traversing first path.
---@param tbl table
---@param depth integer
---@return integer|nil
local function find_stats_depth(tbl, depth)
   if tbl.median then
      return depth
   end
   local _, first = next(tbl)
   if type(first) ~= "table" then
      return nil
   end
   return find_stats_depth(first, depth + 1)
end

---Detect the type of benchmark results structure.
---Result structures (depth from root to Stats):
--- - Stats (depth 0): "stats"
--- - {name: Stats} (depth 1): "multi"
--- - {param: {value: Stats}} (depth 2): "params" (1 param)
--- - {name: {param: {value: Stats}}} (depth 3): "multi_params" (1 param) OR "params" (2 params)
--- - {param1: {v1: {param2: {v2: Stats}}}} (depth 4): "params" (2 params)
--- - {name: {param1: {v1: {param2: {v2: Stats}}}}} (depth 5): "multi_params" (2 params)
---
---For ambiguous cases (depth 3+), we check pattern: params has even depth, multi_params has odd depth
---@param results table
---@return "stats"|"multi"|"params"|"multi_params"
local function detect_result_type(results)
   if results.median then
      return "stats"
   end

   local depth = find_stats_depth(results, 0)
   if not depth then
      error("Invalid result structure: no Stats found")
   end

   if depth == 1 then
      return "multi" -- {name: Stats}
   end

   if depth == 2 then
      return "params" -- {param: {value: Stats}}
   end

   -- Depth >= 3: structure alternates between param layers and name layer.
   -- Each param adds 2 levels ({param_name: {param_value: ...}}), name adds 1.
   -- Even depth = only param layers = single function ("params")
   -- Odd depth = name layer + param layers = multiple functions ("multi_params")
   if depth % 2 == 0 then
      return "params"
   else
      return "multi_params"
   end
end

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

---@class FlatRow
---@field name string Benchmark name
---@field params table Parameter values
---@field stats Stats

---Traverse nested param structure to find Stats.
---Structure is: {param_name: {param_value: Stats|nested}}
---@param tbl table
---@param params table Accumulated params
---@param name string Benchmark name
---@param rows FlatRow[]
local function traverse_params(tbl, params, name, rows)
   if tbl.median then
      ---@cast tbl Stats
      rows[#rows + 1] = { name = name, params = params, stats = tbl }
      return
   end

   -- Structure is {param_name: {param_value: nested}}
   for param_name, param_values in pairs(tbl) do
      if type(param_values) == "table" then
         for param_value, nested in pairs(param_values) do
            if type(nested) == "table" then
               local new_params = shallow_copy(params)
               new_params[param_name] = param_value
               traverse_params(nested, new_params, name, rows)
            end
         end
      end
   end
end

---Collect all unique parameter names from flattened rows.
---@param rows FlatRow[]
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

---Build CSV output for parameterized results.
---@param rows FlatRow[]
---@return string
local function build_params_csv(rows)
   local param_names = collect_param_names(rows)

   -- Build header
   local headers = { "name" }
   for i = 1, #param_names do
      headers[#headers + 1] = param_names[i]
   end
   for i = 2, #SUMMARIZE_HEADERS do
      headers[#headers + 1] = SUMMARIZE_HEADERS[i]
   end

   local lines = { table.concat(headers, ",") }

   -- Sort rows by name, then by params
   table.sort(rows, function(a, b)
      if a.name ~= b.name then
         return a.name < b.name
      end
      return format_params(a.params) < format_params(b.params)
   end)

   -- Build data rows
   for i = 1, #rows do
      local row = rows[i]
      local formatted = format_row(row.stats)
      local cells = { escape_csv(row.name) }
      for j = 1, #param_names do
         local val = row.params[param_names[j]]
         cells[#cells + 1] = escape_csv(val ~= nil and tostring(val) or "")
      end
      for j = 2, #SUMMARIZE_HEADERS do
         local h = SUMMARIZE_HEADERS[j]
         cells[#cells + 1] = escape_csv(formatted[h] or "")
      end
      lines[#lines + 1] = table.concat(cells, ",")
   end

   return table.concat(lines, "\n")
end

---Summarize a {[string]: Stats} benchmark result (multi without params).
---@param results {[string]: Stats}
---@param format "plain"|"compact"|"markdown"|"csv"
---@param max_width? integer
---@return string
local function summarize_benchmark(results, format, max_width)
   results = rank(results, "median")
   local rows = {}
   for name, stats in pairs(results) do
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

   max_width = max_width or get_term_width()

   if format == "compact" then
      return table.concat(build_bar_chart(rows, max_width), "\n")
   end

   local widths = {}
   for i = 1, #SUMMARIZE_HEADERS do
      local header = SUMMARIZE_HEADERS[i]
      widths[i] = #header
      for j = 1, #rows do
         widths[i] = math.max(widths[i], #(rows[j][header] or ""))
      end
   end

   if format == "plain" then
      local other_width = 0
      for i = 2, #SUMMARIZE_HEADERS do
         other_width = other_width + widths[i]
      end
      -- Account for embedded bar column and spacing between columns
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

   ---@cast format "plain"|"compact"|"markdown"
   local lines = build_table(rows, widths, format)

   return table.concat(lines, "\n")
end

---Summarize parameterized results (single or multi with params).
---@param results table
---@param result_type "params"|"multi_params"
---@param format "plain"|"compact"|"markdown"|"csv"
---@param max_width? integer
---@return string
local function summarize_parameterized(results, result_type, format, max_width)
   -- Flatten results into rows with params
   local rows = {}

   if result_type == "params" then
      -- Single function with params: results[param][value] -> Stats
      traverse_params(results, {}, "result", rows)
   else
      -- Multi functions with params: results[name][param][value] -> Stats
      for name, bench_results in pairs(results) do
         traverse_params(bench_results, {}, name, rows)
      end
   end

   if format == "csv" then
      return build_params_csv(rows)
   end

   -- Group rows by param combination
   local groups = {} ---@type table<string, {[string]: Stats}>
   for i = 1, #rows do
      local row = rows[i]
      local key = format_params(row.params)
      groups[key] = groups[key] or {}
      groups[key][row.name] = row.stats
   end

   -- Build output for each group
   local output = {}
   local group_keys = sorted_keys(groups)
   for i = 1, #group_keys do
      local param_key = group_keys[i]
      local group = groups[param_key]

      -- Add header with params (skip if single function with empty params)
      if result_type == "multi_params" or param_key ~= "" then
         output[#output + 1] = param_key
      end

      -- Rank and format this group
      local formatted = summarize_benchmark(group, format, max_width)
      output[#output + 1] = formatted
      output[#output + 1] = "" -- blank line between groups
   end

   return table.concat(output, "\n")
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
local measure_memory = build_measure(measure_memory_once, MEMORY_PRECISION)

---@param fn NoArgFun The function to benchmark.
---@param setup? function Function executed before each iteration.
---@param teardown? function Function executed after each iteration.
---@return integer # Number of iterations per round.
local function calibrate_iterations(fn, setup, teardown)
   local min_time = get_min_clocktime() * CALIBRATION_PRECISION
   local iterations = 1
   -- Aggressive scaling factor when total_time is zero (below clock resolution).
   -- Using 100x reduces calibration rounds for very fast functions.
   local zero_time_scale = 100

   for _ = 1, MAX_CALIBRATION_ATTEMPTS do
      local total_time = measure_time(fn, iterations, setup, teardown)
      if total_time >= min_time then
         break
      end
      local scale = (total_time > 0) and (min_time / total_time) or zero_time_scale
      iterations = math.ceil(iterations * scale)
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
   assert(not rounds or rounds > 0, "'rounds' must be > 0.")
   assert(not max_time or max_time > 0, "'max_time' must be > 0.")
   assert(not setup or type(setup) == "function", "'setup' must be a function")
   assert(not teardown or type(teardown) == "function", "'teardown' must be a function")
   assert(not before or type(before) == "function", "'before' must be a function")
   assert(not after or type(after) == "function", "'after' must be a function")
end

---@param samples number[]
---@param rounds integer
---@param iterations integer
---@param timestamp string
---@param unit default_unit
---@return Stats
local function build_stats_result(samples, rounds, iterations, timestamp, unit)
   local results = calculate_stats(samples)
   ---@cast results Stats
   results.rounds = rounds
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

--- Run a benchmark on a function using a specified measurement method.
---@param fn function Function to benchmark, receives (ctx, params).
---@param measure Measure Measurement function (e.g., measure_time or measure_memory).
---@param disable_gc boolean Controls garbage collection during benchmark.
---@param unit default_unit Measurement unit.
---@param rounds? number Number of rounds.
---@param max_time? number Maximum run time in seconds.
---@param setup? fun(p: table): any Runs once before benchmark, returns context.
---@param teardown? fun(ctx: any, p: table) Runs once after benchmark.
---@param params? table Parameter values for this run.
---@param spec_before? fun(ctx: any, p: table): any Per-iteration setup (from Spec), returns iteration context.
---@param spec_after? fun(iteration_ctx: any, p: table) Per-iteration teardown (from Spec).
---@param global_before? fun(ctx: any, p: table): any Shared per-iteration setup (from Options).
---@param global_after? fun(ctx: any, p: table) Shared per-iteration teardown (from Options).
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
   global_after
)
   validate_benchmark_args(fn, rounds, max_time, setup, teardown, spec_before, spec_after)
   if disable_gc == nil then
      disable_gc = true
   end

   params = params or {}

   local ctx
   if setup then
      ctx = setup(params)
   end

   -- Track iteration context (updated by before each iteration)
   local iteration_ctx = ctx

   local bound_fn = function()
      fn(iteration_ctx, params)
   end

   -- Per-iteration setup: runs global_before then spec_before
   local iteration_setup
   if global_before or spec_before then
      iteration_setup = function()
         -- Reset to global context at start of each iteration
         iteration_ctx = ctx
         if global_before then
            iteration_ctx = global_before(ctx, params) or ctx
         end
         if spec_before then
            iteration_ctx = spec_before(iteration_ctx, params) or iteration_ctx
         end
      end
   end

   -- Per-iteration teardown: runs spec_after then global_after
   local iteration_teardown
   if spec_after or global_after then
      iteration_teardown = function()
         if spec_after then
            spec_after(iteration_ctx, params)
         end
         if global_after then
            global_after(iteration_ctx, params)
         end
      end
   end

   local iterations = calibrate_iterations(bound_fn, iteration_setup, iteration_teardown)
   for _ = 1, config.warmups do
      measure(bound_fn, iterations, iteration_setup, iteration_teardown)
   end

   local timestamp = os.date("!%Y-%m-%d %H:%M:%SZ") --[[@as string]]
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

      local _, iteration_measure =
         measure(bound_fn, iterations, iteration_setup, iteration_teardown)
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

   collectgarbage("restart")

   if teardown then
      teardown(ctx, params)
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
      return spec, nil, nil
   end
   assert(type(spec) == "table", "spec must be a function or table")
   assert(type(spec.fn) == "function", "spec.fn must be a function")
   assert(not spec.before or type(spec.before) == "function", "spec.before must be a function")
   assert(not spec.after or type(spec.after) == "function", "spec.after must be a function")
   return spec.fn, spec.before, spec.after
end

---@param target Target
---@param measure Measure
---@param disable_gc boolean
---@param unit default_unit
---@param opts Options
---@return Stats|table
local function benchmark(target, measure, disable_gc, unit, opts)
   ---@diagnostic disable: param-type-mismatch
   opts = opts or {}
   local params_spec = opts.params
   local params_list = expand_params(params_spec)
   local has_params = params_spec and next(params_spec)
   local is_single_fn = type(target) == "function"

   -- Single function, no params -> Stats
   if is_single_fn and not has_params then
      return single_benchmark(
         target,
         measure,
         disable_gc,
         unit,
         opts.rounds,
         opts.max_time,
         opts.setup,
         opts.teardown,
         {}, -- empty params
         nil, -- no per-function before
         nil, -- no per-function after
         opts.before,
         opts.after
      )
   end

   -- Single function with params -> nested by params
   if is_single_fn then
      local results = {}
      for i = 1, #params_list do
         local p = params_list[i]
         local stats = single_benchmark(
            target,
            measure,
            disable_gc,
            unit,
            opts.rounds,
            opts.max_time,
            opts.setup,
            opts.teardown,
            p,
            nil, -- no per-function before
            nil, -- no per-function after
            opts.before,
            opts.after
         )
         set_nested(results, p, stats)
      end
      return results
   end

   -- Multiple functions, no params -> {name: Stats}
   if not has_params then
      local results = {}
      for name, spec in pairs(target) do
         local fn, spec_before, spec_after = parse_spec(spec)
         results[name] = single_benchmark(
            fn,
            measure,
            disable_gc,
            unit,
            opts.rounds,
            opts.max_time,
            opts.setup,
            opts.teardown,
            {},
            spec_before,
            spec_after,
            opts.before,
            opts.after
         )
      end
      local stats = rank(results, "median")
      setmetatable(stats, {
         __tostring = function(self)
            return luamark.summarize(self)
         end,
      })
      return stats
   end

   -- Multiple functions with params -> {name: {param: {value: Stats}}}
   local results = {}
   for name, spec in pairs(target) do
      local fn, spec_before, spec_after = parse_spec(spec)
      results[name] = {}
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
            opts.after
         )
         set_nested(results[name], p, stats)
      end
   end
   return results
end

---@class Options
---@field rounds? integer The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@field max_time? number Maximum run time in seconds. It may be exceeded if test function is very slow.
---@field setup? fun(p: table): any Function executed once before benchmark; receives params table, returns context passed to fn.
---@field teardown? fun(ctx: any, p: table) Function executed once after benchmark; receives context and params.
---@field before? fun(ctx: any, p: table): any Function executed before each iteration; receives context, returns updated context.
---@field after? fun(ctx: any, p: table) Function executed after each iteration; receives context and params.
---@field params? table<string, any[]> Parameter combinations to benchmark across.

local VALID_OPTS = {
   rounds = "number",
   max_time = "number",
   setup = "function",
   teardown = "function",
   before = "function",
   after = "function",
   params = "table",
}

---@param opts Options
local function validate_options(opts)
   for k, v in pairs(opts) do
      local opt_type = VALID_OPTS[k]
      if not opt_type then
         error("Unknown option: " .. k)
      end
      if type(v) ~= opt_type then
         error(string.format("Option '%s' should be %s", k, opt_type))
      end
   end

   if opts.rounds and opts.rounds ~= math.floor(opts.rounds) then
      error("Option 'rounds' must be an integer")
   end

   -- Validate params structure
   if opts.params then
      for name, values in pairs(opts.params) do
         -- Keys must be strings (prevents table.sort errors on mixed types)
         if type(name) ~= "string" then
            error(string.format("params key must be a string, got %s", type(name)))
         end
         -- Values must be arrays
         if type(values) ~= "table" then
            error(string.format("params['%s'] must be an array, got %s", name, type(values)))
         end
         -- Array elements must be valid types
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
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

--- Return a string summarizing benchmark results.
--- Handle all result types from the unified API:
--- - Single function, no params: Stats
--- - Multiple functions, no params: {name: Stats}
--- - Single function, with params: {param: {value: Stats}}
--- - Multiple functions, with params: {name: {param: {value: Stats}}}
---@param results table Benchmark results to summarize.
---@param format? "plain"|"compact"|"markdown"|"csv" Output format.
---@param max_width? integer Maximum output width (default: terminal width).
---@return string
function luamark.summarize(results, format, max_width)
   assert(results and next(results), "'results' is nil or empty.")
   format = format or "plain"
   assert(
      format == "plain" or format == "compact" or format == "markdown" or format == "csv",
      "format must be 'plain', 'compact', 'markdown', or 'csv'"
   )

   max_width = max_width or get_term_width()

   local result_type = detect_result_type(results)

   -- Single Stats object: wrap as {"result": Stats} for consistent handling
   if result_type == "stats" then
      ---@cast results Stats
      return summarize_benchmark({ result = results }, format, max_width)
   end

   -- Multiple functions, no params: {name: Stats}
   if result_type == "multi" then
      return summarize_benchmark(results, format, max_width)
   end

   -- Single or multiple functions with params
   ---@cast result_type "params"|"multi_params"
   return summarize_parameterized(results, result_type, format, max_width)
end

--- Benchmark a function for execution time. Time is represented in seconds.
---@param target Target Function or table of functions/Specs to benchmark.
---@param opts? Options Benchmark configuration.
---@return Stats|table Stats for single function, nested results for params, or table of Stats for multiple functions.
function luamark.timeit(target, opts)
   opts = opts or {}
   validate_options(opts)
   return benchmark(target, measure_time, true, "s", opts)
end

--- Benchmark a function for memory usage. Memory is represented in kilobytes.
---@param target Target Function or table of functions/Specs to benchmark.
---@param opts? Options Benchmark configuration.
---@return Stats|table Stats for single function, nested results for params, or table of Stats for multiple functions.
function luamark.memit(target, opts)
   opts = opts or {}
   validate_options(opts)
   return benchmark(target, measure_memory, false, "kb", opts)
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
