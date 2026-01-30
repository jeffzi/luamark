# luamark

## API Overview

luamark provides two API styles: **Single** (benchmark one function) and **Suite**
(compare multiple functions):

| Function                            | Input    | Returns               | `params` |
| ----------------------------------- | -------- | --------------------- | -------- |
| [`timeit`](#timeit)                 | function | [`Stats`](#stats)     | No       |
| [`memit`](#memit)                   | function | [`Stats`](#stats)     | No       |
| [`compare_time`](#compare_time)     | table    | [`Result[]`](#result) | Yes      |
| [`compare_memory`](#compare_memory) | table    | [`Result[]`](#result) | Yes      |

---

## Single API

Use [`timeit`](#timeit) and [`memit`](#memit) to benchmark a single function.

### timeit

```lua
function luamark.timeit(fn: fun(ctx?: any), opts?: Options) -> Stats
```

Benchmark a single function for execution time. Time is measured in seconds.
See [`Options`](#options) for configuration and [`Stats`](#stats) for return type.

```lua
local stats = luamark.timeit(function()
   -- code to benchmark
end, { rounds = 10 })

print(stats)  -- "250ns ± 0ns"
print(stats.median, stats.ci_margin)  -- Access individual fields
```

### memit

```lua
function luamark.memit(fn: fun(ctx?: any), opts?: Options) -> Stats
```

Benchmark a single function for memory usage. Memory is measured in kilobytes.
See [`Options`](#options) for configuration and [`Stats`](#stats) for return type.

```lua
local stats = luamark.memit(function()
   local t = {}
   for i = 1, 1000 do t[i] = i end
end, { rounds = 10 })

print(stats)  -- "16.05kB ± 0B"
```

### Stats

Returned by [`timeit`](#timeit) and [`memit`](#memit).

```lua
local stats = luamark.timeit(fn, { rounds = 10 })
print(stats)  -- "250ns ± 0ns"
```

| Field      | Type      | Description                                            |
| ---------- | --------- | ------------------------------------------------------ |
| median     | number    | Median value of samples                                |
| ci_lower   | number    | Lower bound of 95% CI for median                       |
| ci_upper   | number    | Upper bound of 95% CI for median                       |
| ci_margin  | number    | Half-width of CI ((upper - lower) / 2)                 |
| total      | number    | Sum of all samples                                     |
| samples    | number[]  | Raw samples (sorted)                                   |
| rounds     | integer   | Number of rounds (samples) collected                   |
| iterations | integer   | Number of iterations per round                         |
| timestamp  | string    | ISO 8601 UTC timestamp of benchmark start              |
| unit       | "s"\|"kb" | Measurement unit (seconds or kilobytes)                |
| ops        | number?   | Operations per second (1/median, time benchmarks only) |

**Output format:** The `__tostring` metamethod outputs a compact format showing only
`median ± ci_margin`. To access additional fields like `ops`, `rounds`, `iterations`,
or the full confidence interval bounds (`ci_lower`/`ci_upper`), read them directly
from the stats object:

```lua
local stats = luamark.timeit(fn)
print(stats)              -- "250ns ± 0ns" (compact)
print(stats.ops)          -- 4000000 (operations per second)
print(stats.rounds)       -- 100
print(stats.iterations)   -- 1000
print(stats.ci_lower, stats.ci_upper)  -- full CI bounds
```

### Options

```lua
---@class Options
---@field rounds? integer Target number of benchmark rounds.
---@field time? number Target duration in seconds.
---@field setup? fun(): any Function executed once before benchmark; returns context.
---@field teardown? fun(ctx?: any) Function executed once after benchmark.
```

**Execution order:**

```text
setup() → ctx
│
├─ Iteration 1: fn(ctx)
├─ Iteration 2: fn(ctx)
├─ ...
│
teardown(ctx)
```

**Note:** The [`params`](#params) option is NOT supported in [`Options`](#options).
Use [`compare_time`](#compare_time)/[`compare_memory`](#compare_memory) for parameterized benchmarks.
In single mode, hooks receive only `ctx`, not params.

---

## Suite API

Use [`compare_time`](#compare_time) and [`compare_memory`](#compare_memory) to compare
multiple functions, optionally with parameterized benchmarks.

### compare_time

```lua
function luamark.compare_time(
   funcs: table<string, fun(ctx?: any, p:table)|Spec>,
   opts?: SuiteOptions
) -> Result[]
```

Compare multiple functions for execution time. Returns ranked [`Result[]`](#result).
See [`SuiteOptions`](#suiteoptions) for configuration and [`Spec`](#spec) for per-iteration hooks.

**Note:** `funcs` keys must be strings. Arrays are not supported.

```lua
local results = luamark.compare_time({
   concat_loop = function(ctx, p)
      local s = ""
      for i = 1, p.n do s = s .. i end
   end,
   table_concat = function(ctx, p)
      local t = {}
      for i = 1, p.n do t[i] = i end
      return table.concat(t)
   end,
}, {
   params = { n = { 100, 1000 } },
})

print(results)  -- Prints formatted comparison table
```

### compare_memory

```lua
function luamark.compare_memory(
   funcs: table<string, fun(ctx?: any, p:table)|Spec>,
   opts?: SuiteOptions
) -> Result[]
```

Compare multiple functions for memory usage. Returns ranked [`Result[]`](#result).
See [`SuiteOptions`](#suiteoptions) for configuration and [`Spec`](#spec) for per-iteration hooks.

**Note:** `funcs` keys must be strings. Arrays are not supported.

### SuiteOptions

```lua
---@class SuiteOptions
---@field rounds? integer Target number of benchmark rounds.
---@field time? number Target duration in seconds.
---@field setup? fun(p: table): any Function executed once; receives params, returns context.
---@field teardown? fun(ctx: any, p: table) Function executed once after benchmark.
---@field params? table<string, ParamValue[]> Parameter combinations to benchmark across.
```

**Execution order** (for plain functions):

```text
setup(params) → ctx
│
├─ Iteration 1: fn(ctx, params)
├─ Iteration 2: fn(ctx, params)
├─ ...
│
teardown(ctx, params)
```

| Hook       | Runs                 | Use Case                      |
| ---------- | -------------------- | ----------------------------- |
| `setup`    | Once per param combo | Load config, create test data |
| `teardown` | Once per param combo | Close connections, cleanup    |

### Spec

For per-iteration setup/teardown (e.g., copying data that gets mutated), use a `Spec` object
instead of a plain function:

```lua
---@class Spec
---@field fn fun(ctx: any, p: table) Benchmark function; receives iteration context and params.
---@field before? fun(ctx: any, p: table): any Per-iteration setup; returns iteration context.
---@field after? fun(ctx: any, p: table) Per-iteration teardown.
```

**Execution order with Spec:**

```text
setup(params) → ctx
│
├─ Iteration 1:
│   ├─ Spec.before(ctx, params) → iteration_ctx
│   ├─ Spec.fn(iteration_ctx, params)      ← only this is measured
│   └─ Spec.after(iteration_ctx, params)
├─ Iteration 2:
│   ├─ Spec.before(ctx, params) → iteration_ctx
│   ├─ Spec.fn(iteration_ctx, params)      ← only this is measured
│   └─ Spec.after(iteration_ctx, params)
├─ ...
│
teardown(ctx, params)
```

| Hook          | Runs                                 | Use Case                             |
| ------------- | ------------------------------------ | ------------------------------------ |
| `setup`       | Once per param combo                 | Load config, create shared test data |
| `Spec.before` | Before each iteration (not measured) | Copy data that gets mutated          |
| `Spec.after`  | After each iteration (not measured)  | Validate results, cleanup            |
| `teardown`    | Once per param combo                 | Close connections, cleanup           |

**Example:** Benchmarking `table.sort` which mutates its input:

```lua
luamark.compare_time({
   table_sort = {
      fn = function(ctx, p)
         table.sort(ctx.copy)
      end,
      before = function(ctx, p)
         -- Copy the source array before each iteration
         local copy = {}
         for i = 1, #ctx.source do
            copy[i] = ctx.source[i]
         end
         ctx.copy = copy
         return ctx
      end,
   },
}, {
   params = { n = {100, 1000} },
   setup = function(p)
      -- Create source array once per param combo
      local source = {}
      for i = 1, p.n do
         source[i] = math.random(p.n * 10)
      end
      return { source = source }
   end,
})
```

### params

```lua
table<string, (string|number|boolean)[]>?
```

Parameter combinations to benchmark across. Each key is a parameter name, each
value is an array of values to test. Values must be strings, numbers, or booleans.

```lua
-- Example: benchmark with different sizes and types
luamark.compare_time(funcs, {
   params = {
      size = {100, 1000, 10000},
      type = {"array", "hash"}
   }
})
-- Runs benchmark for all 6 combinations (3 sizes × 2 types)
```

### Result

[`compare_time`](#compare_time) and [`compare_memory`](#compare_memory) return
[`Result[]`](#result) - a flat array of benchmark results.
The array has a `__tostring` metamethod that calls
[`render(results, true)`](#render):

```lua
local results = luamark.compare_time({ a = fn_a, b = fn_b })
print(results)  -- Prints bar chart (short format)
print(luamark.render(results))  -- Prints full table with all stats
```

**Sorting:** Results are grouped by parameter combination, then sorted by rank
within each group (fastest first). This means you can iterate over results in
display order without additional sorting.

Results have a flat structure with stats and params merged directly:

```lua
-- Accessing result fields directly (flat structure)
local result = results[1]
print(result.name)     -- "a"
print(result.median)   -- number (stats field)
print(result.n)        -- 100 (param field, if params = {n = {100}} was used)
```

| Field          | Type      | Description                                              |
| -------------- | --------- | -------------------------------------------------------- |
| name           | string    | Benchmark name                                           |
| median         | number    | Median value of samples                                  |
| ci_lower       | number    | Lower bound of 95% CI for median                         |
| ci_upper       | number    | Upper bound of 95% CI for median                         |
| ci_margin      | number    | Half-width of CI ((upper - lower) / 2)                   |
| total          | number    | Sum of all samples                                       |
| samples        | number[]  | Raw samples (sorted)                                     |
| rounds         | integer   | Number of rounds (samples) collected                     |
| iterations     | integer   | Number of iterations per round                           |
| timestamp      | string    | ISO 8601 UTC timestamp of benchmark start                |
| unit           | "s"\|"kb" | Measurement unit (seconds or kilobytes)                  |
| ops            | number?   | Operations per second (1/median, time benchmarks only)   |
| rank           | integer?  | Rank accounting for CI overlap                           |
| ratio          | number?   | Ratio to fastest                                         |
| is_approximate | boolean?  | True if rank is tied due to CI overlap                   |
| _param_name_   | any       | Any param values are inlined directly (e.g., `result.n`) |

**Rank display:** When results have overlapping confidence intervals, they share the
same rank with an `≈` prefix. For example, `≈1 ≈1 3` means the first two results have
overlapping CIs (statistically indistinguishable), while the third is clearly slower.
The gap in rank numbers (1 to 3) indicates skipped positions.

---

## Timer

The `Timer` constructor creates a timer for ad-hoc manual profiling outside of benchmarks.
It uses the same high-precision clock as the benchmark functions.

```lua
function luamark.Timer() -> luamark.Timer
```

Create a new timer instance:

```lua
local timer = luamark.Timer()
timer.start()
-- ... code to measure ...
local elapsed = timer.stop()  -- elapsed time in seconds
print(luamark.humanize_time(elapsed))  -- "42ms"
```

### timer.start()

```lua
function timer.start()
```

Start timing. Errors if the timer is already running.

### timer.stop()

```lua
function timer.stop() -> number
```

Stop timing and return elapsed time in seconds since `start()` was called.
Errors if the timer is not running.

### timer.elapsed()

```lua
function timer.elapsed() -> number
```

Get total accumulated time across all `start()`/`stop()` cycles.
Errors if the timer is still running.

### timer.reset()

```lua
function timer.reset()
```

Reset timer for reuse. Clears accumulated time.

### Example

```lua
local luamark = require("luamark")

-- Profile a specific operation
local timer = luamark.Timer()
timer.start()
local sum = 0
for i = 1, 1e6 do sum = sum + i end
local elapsed = timer.stop()

print(string.format("Operation took %s", luamark.humanize_time(elapsed)))
```

See [`humanize_time`](#humanize_time) for formatting elapsed time.

---

## Utility Functions

### render

```lua
function luamark.render(
   input: Stats | Result[],
   short?: boolean,
   max_width?: integer
) -> string
```

Render benchmark results as a formatted string.

Accepts either a single [`Stats`](#stats) object (from [`timeit`](#timeit)/[`memit`](#memit))
or an array of [`Result`](#result) objects
(from [`compare_time`](#compare_time)/[`compare_memory`](#compare_memory)).

@_param_ `input` — Single [`Stats`](#stats) object or [`Result`](#result) array.

@_param_ `short` — Output format. Ignored for single Stats.

- `false` or `nil` (default): Full table with embedded bar chart in ratio column
- `true`: Bar chart only (compact)

@_param_ `max_width` — Maximum output width (default: terminal width). Ignored for single Stats.

```lua
-- Single stats (detailed key-value format)
local stats = luamark.timeit(fn)
print(luamark.render(stats))
-- Output:
-- Median: 250ns
-- CI: 248ns - 252ns (± 2ns)
-- Ops: 4M/s
-- Rounds: 100
-- Total: 25us

-- Results array (table format)
print(luamark.render(results))

-- Bar chart only
print(luamark.render(results, true))
```

### humanize_time

```lua
function luamark.humanize_time(s: number) -> string
```

Format a time value to a human-readable string. Selects the best unit automatically (m, s, ms, us, ns).

@_param_ `s` — Time in seconds.

@_return_ — Formatted time string (e.g., "42ns", "1.5ms").

### humanize_memory

```lua
function luamark.humanize_memory(kb: number) -> string
```

Format a memory value to a human-readable string.
Selects the best unit automatically (TB, GB, MB, kB, B).

@_param_ `kb` — Memory in kilobytes.

@_return_ — Formatted memory string (e.g., "512kB", "1.5MB").

### humanize_count

```lua
function luamark.humanize_count(n: number) -> string
```

Format a count to a human-readable string with SI suffix (M, k).

@_param_ `n` — Count value.

@_return_ — Formatted count string (e.g., "1k", "12.5M").

### unload

```lua
function luamark.unload(pattern: string) -> integer
```

Unload modules matching a Lua pattern from `package.loaded`.
Useful for benchmarking module load times or resetting state between runs.

@_param_ `pattern` — Lua pattern to match module names against.

@_return_ — Number of modules unloaded.

```lua
-- Unload all modules starting with "mylib"
local count = luamark.unload("^mylib")
print(count)  -- Number of modules unloaded

-- Benchmark module load time (see timeit)
luamark.unload("^mymodule$")
local stats = luamark.timeit(function()
   require("mymodule")
end)
```

See [`timeit`](#timeit) for benchmarking the load time.

---

## Configuration

Set global configuration options directly on the module:

```lua
luamark.rounds = 100  -- Target sample count
luamark.time = 1      -- Target duration in seconds
```

Benchmarks run until **either** target is met: `rounds` samples collected
or `time` seconds elapsed. For very fast functions, rounds are capped at 100
to ensure consistent sample count.

### clock_name

```lua
luamark.clock_name  -- "chronos" | "posix.time" | "socket" | "os.clock"
```

Read-only string indicating which clock module is in use.
