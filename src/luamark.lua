-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

---@class luamark
local luamark = {}

local CALIBRATION_PRECISION = 5
local MIN_ROUNDS = 5

local MAX_INT = 2 ^ 1023

-- ----------------------------------------------------------------------------
-- Clock
-- ----------------------------------------------------------------------------

---Get clock and clock precision from a module name.
---@param modname string
---@return (fun(): number)|nil
---@return integer|nil
function luamark.get_clock(modname)
   if modname == "os" then
      return os.clock, 3
   end

   local has_module, lib = pcall(require, modname)
   if not has_module then
      return nil, nil
   end

   local clock, clock_precision
   if modname == "chronos" then
      if has_module then
         -- 1ns
         clock, clock_precision = lib.nanotime, 9
      end
   elseif modname == "posix.time" then
      -- clock_gettime is not defined on MacOS
      if has_module and lib.clock_gettime then
         -- 1ns
         clock = function()
            local s, ns = lib.clock_gettime(lib.CLOCK_MONOTONIC)
            return s + ns / (10 ^ -clock_precision)
         end
         clock, clock_precision = clock, 9
      end
   elseif modname == "socket" then
      if has_module then
         -- 10µs
         clock, clock_precision = lib.gettime, 4
      end
   end
   return clock, clock_precision
end

local clock, clock_precision = luamark.get_clock("chronos")
if not clock then
   clock, clock_precision = luamark.get_clock("posix.time")
end
if not clock then
   clock, clock_precision = luamark.get_clock("socket")
end
if not clock then
   clock, clock_precision = luamark.get_clock("os")
end

luamark.clock = clock
luamark.clock_precision = clock_precision

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
      elseif name == "min" or name == "max" or name == "mean" or name == "stddev" or name == "median" then
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

   local headers = { "name", "rank", "ratio", "min", "max", "mean", "stddev", "median", "rounds", "iterations" }

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
         io.write(pad(row[header], widths[i]) .. "  ")
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

   stats["stats.total"] = stats.total

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
-- ----------------------------------------------------------------------------

--- Measures the time taken to execute a function once.
---@param func fun(): any The zero-arg function to measure.
---@return number # The time taken to execute the function (in seconds).
function luamark.measure_time(func)
   local start = luamark.clock()
   func()
   return luamark.clock() - start
end

--- Measures the memory used by a function.
---@param func fun(): any The zero-arg function to measure.
---@return number # The amount of memory used by the function (in kilobytes).
function luamark.measure_memory(func)
   collectgarbage("collect")
   local start_memory = collectgarbage("count")
   func()
   return collectgarbage("count") - start_memory
end

--- Determine the round parameters
---@param func function The function to benchmark.
---@return number # Duration of a round.
local function calibrate_round(func)
   local min_time = (10 ^ -clock_precision) * CALIBRATION_PRECISION
   local iterations = 1
   while true do
      local repeated_func = rerun(func, iterations)
      local duration = luamark.measure_time(repeated_func)
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
   return iterations
end

--- Runs a benchmark on a function using a specified measurement method.
---@param func function The function to benchmark.
---@param measure function The measurement function to use (e.g., measure_time or measure_memory).
---@param rounds number The number of rounds, i.e. set of runs
---@param disable_gc boolean Whether to disable garbage collection during the benchmark.
---@return table # A table containing the results of the benchmark .
local function single_benchmark(func, measure, rounds, iterations, warmups, disable_gc, unit, precision)
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

      samples[i] = math_round(measure(inner_loop) / iterations, precision)

      collectgarbage("restart")
   end

   local results = calculate_stats(samples)
   results.rounds = rounds
   results.iterations = iterations
   results.warmups = warmups
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
---@param rounds? number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.timeit(func, rounds, iterations, warmups)
   return benchmark(func, luamark.measure_time, rounds, iterations, warmups, true, "s", luamark.clock_precision)
end

--- Benchmarks a function for memory usage. The memory usage is represented in kilobytes.
---@param func (fun(): any)|({[string]: fun(): any}) A single zero-argument function or a table of zero-argument functions indexed by name.
---@param rounds? number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
---@return {[string]:any}|{[string]:{[string]: any}} # A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
function luamark.memit(func, rounds, iterations, warmups)
   return benchmark(func, luamark.measure_memory, rounds, iterations, warmups, false, "kb", 4)
end

return luamark
