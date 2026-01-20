# luamark

## Configuration

Set global configuration options directly on the module:

```lua
luamark.max_iterations = 1e6  -- Maximum iterations per round
luamark.min_rounds = 100      -- Minimum benchmark rounds
luamark.max_rounds = 1e6      -- Maximum benchmark rounds
luamark.warmups = 1           -- Number of warmup rounds
```

### clock_name

```lua
luamark.clock_name  -- "chronos" | "posix.time" | "socket" | "os.clock"
```

Read-only string indicating which clock module is in use.

### get_config

```lua
function luamark.get_config() -> table
```

Return a copy of the current configuration values:

```lua
local cfg = luamark.get_config()
-- { max_iterations = 1e6, min_rounds = 100, max_rounds = 1e6, warmups = 1 }
```

## API Overview

luamark provides two APIs:

| Function | Input | Returns | `params` |
| -------- | ----- | ------- | -------- |
| [`timeit`](#timeit) | function | [`Stats`](#stats) | No |
| [`memit`](#memit) | function | [`Stats`](#stats) | No |
| [`compare_time`](#compare_time) | table | [`BenchmarkRow[]`](#benchmarkrow) | Yes |
| [`compare_memory`](#compare_memory) | table | [`BenchmarkRow[]`](#benchmarkrow) | Yes |

---

## Single API

Use [`timeit`](#timeit) and [`memit`](#memit) to benchmark a single function.

### timeit

```lua
function luamark.timeit(fn: fun(ctx?: any), opts?: SimpleOptions) -> Stats
```

Benchmark a single function for execution time. Returns time in seconds.

```lua
local stats = luamark.timeit(function()
   -- code to benchmark
end, { rounds = 10 })

print(stats)  -- "1.5ms ± 0.1ms per round (10 rounds)"
print(stats.mean, stats.median)  -- Access individual fields
```

### memit

```lua
function luamark.memit(fn: fun(ctx?: any), opts?: SimpleOptions) -> Stats
```

Benchmark a single function for memory usage. Returns memory in kilobytes.

```lua
local stats = luamark.memit(function()
   local t = {}
   for i = 1, 1000 do t[i] = i end
end, { rounds = 10 })

print(stats)  -- "1.2kB ± 0.05kB per round (10 rounds)"
```

### SimpleOptions

```lua
---@class SimpleOptions
---@field rounds? integer Number of benchmark rounds.
---@field max_time? number Maximum run time in seconds.
---@field setup? fun(): any Function executed once before benchmark; returns context.
---@field teardown? fun(ctx?: any) Function executed once after benchmark.
---@field before? fun(ctx?: any): any Function executed before each iteration.
---@field after? fun(ctx?: any) Function executed after each iteration.
```

**Note:** The [`params`](#params) option is NOT supported in the single API.
Use [`compare_time`](#compare_time)/[`compare_memory`](#compare_memory) for parameterized benchmarks.
In single mode, hooks receive only `ctx`, not params.

---

## Suite API

Use [`compare_time`](#compare_time) and [`compare_memory`](#compare_memory) to compare
multiple functions, optionally with parameterized benchmarks.

### compare_time

```lua
function luamark.compare_time(
   funcs: table<string, fun(ctx, p)|Spec>,
   opts?: SuiteOptions
) -> BenchmarkRow[]
```

Compare multiple functions for execution time. Returns ranked results.

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
   funcs: table<string, fun(ctx, p)|Spec>,
   opts?: SuiteOptions
) -> BenchmarkRow[]
```

Compare multiple functions for memory usage. Returns ranked results.

**Note:** `funcs` keys must be strings. Arrays are not supported.

### SuiteOptions

```lua
---@class SuiteOptions
---@field rounds? integer Number of benchmark rounds.
---@field max_time? number Maximum run time in seconds.
---@field setup? fun(p: table): any Function executed once; receives params, returns context.
---@field teardown? fun(ctx: any, p: table) Function executed once after benchmark.
---@field before? fun(ctx: any, p: table): any Function executed before each iteration.
---@field after? fun(ctx: any, p: table) Function executed after each iteration.
---@field params? table<string, ParamValue[]> Parameter combinations to benchmark across.
```

**Note:** In suite mode, all hooks receive the params table:

```lua
luamark.compare_time({ test = test_fn }, {
   params = { n = { 100, 1000 } },
   setup = function(p)
      return { data = generate_data(p.n) }
   end,
   teardown = function(ctx, p)
      cleanup(p.n)
   end,
   before = function(ctx, p)
      ctx.fresh = generate_fresh(p.n)
      return ctx
   end,
   after = function(ctx, p)
      -- ...
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

### Spec

When passing multiple functions to [`compare_time`](#compare_time)/[`compare_memory`](#compare_memory),
each function can optionally be a Spec table with per-iteration setup/teardown.
Unlike [`SuiteOptions`](#suiteoptions).setup/teardown (run once per benchmark),
[`Spec`](#spec).before/after run before/after each iteration.

```lua
---@class Spec
---@field fn fun(ctx: any, p: table) Benchmark function.
---@field before? fun(ctx: any, p: table): any Per-iteration setup.
---@field after? fun(ctx: any, p: table) Per-iteration teardown.
```

### BenchmarkRow

[`compare_time`](#compare_time) and [`compare_memory`](#compare_memory) return
[`BenchmarkRow[]`](#benchmarkrow) - a flat array of benchmark results.
The array has a `__tostring` metamethod that calls
[`summarize(results, "compact")`](#summarize):

```lua
local results = luamark.compare_time({ a = fn_a, b = fn_b })
print(results)  -- Prints formatted summary table
```

```lua
---@class BenchmarkRow
---@field name string Benchmark name.
---@field params table<string, string|number|boolean> Parameter values for this run.
---@field stats Stats Benchmark statistics.
```

---

## Lifecycle Hooks

### Execution Order

```text
setup(params) → ctx
│
├─ Iteration 1:
│   Options.before(ctx, params) → iteration_ctx
│   Spec.before(iteration_ctx, params) → iteration_ctx
│   fn(iteration_ctx, params)
│   Spec.after(iteration_ctx, params)
│   Options.after(iteration_ctx, params)
│
├─ Iteration 2: ...
│
teardown(ctx, params)
```

**Note:** In single API ([`timeit`](#timeit)/[`memit`](#memit)), hooks receive no
[`params`](#params) argument.

### When to Use Each Hook

| Hook               | Scope        | Runs                 | Use Case                      |
| ------------------ | ------------ | -------------------- | ----------------------------- |
| `Options.setup`    | Shared       | Once per param combo | Load config, open DB          |
| `Options.teardown` | Shared       | Once per param combo | Close connections, cleanup    |
| `Options.before`   | Shared       | Every iteration      | Generate fresh test data      |
| `Options.after`    | Shared       | Every iteration      | Shared cleanup after each run |
| `Spec.before`      | Per-function | Every iteration      | Function-specific setup       |
| `Spec.after`       | Per-function | Every iteration      | Function-specific cleanup     |

### Example

```lua
-- Options.before: shared data for all functions
-- Spec.before: per-function initialization
luamark.compare_time({
   algorithm_a = {
      fn = algorithm_a,
      before = function(ctx, p)
         ctx.state = initialize_a(ctx.data)
         return ctx
      end,
   },
   algorithm_b = {
      fn = algorithm_b,
      before = function(ctx, p)
         ctx.state = initialize_b(ctx.data)
         return ctx
      end,
   },
}, {
   params = { n = {100, 1000} },
   before = function(ctx, p)
      ctx.data = generate_data(p.n)
      return ctx
   end,
})
```

---

## Stats

Returned by all benchmark functions. Has a `__tostring` metamethod for readable output:

```lua
local stats = luamark.timeit(fn, { rounds = 10 })
print(stats)  -- "1.5ms ± 0.1ms per round (10 rounds)"
```

| Field      | Type      | Description                                    |
| ---------- | --------- | ---------------------------------------------- |
| count      | integer   | Number of samples collected                    |
| mean       | number    | Arithmetic mean of samples                     |
| median     | number    | Median value of samples                        |
| min        | number    | Minimum sample value                           |
| max        | number    | Maximum sample value                           |
| stddev     | number    | Standard deviation of samples                  |
| total      | number    | Sum of all samples                             |
| samples    | number[]  | Raw samples (sorted)                           |
| rounds     | integer   | Number of benchmark rounds executed            |
| iterations | integer   | Number of iterations per round                 |
| warmups    | integer   | Number of warmup rounds                        |
| timestamp  | string    | ISO 8601 UTC timestamp of benchmark start      |
| unit       | "s"\|"kb" | Measurement unit (seconds or kilobytes)        |
| rank       | integer?  | Rank (only in `compare_*` results)             |
| ratio      | number?   | Ratio to fastest (only in `compare_*` results) |

---

## Utility Functions

### summarize

```lua
function luamark.summarize(
   results: BenchmarkRow[],
   format?: "plain"|"compact"|"markdown"|"csv",
   max_width?: integer
) -> string
```

Return a string summarizing benchmark results.

@_param_ `results` — Benchmark results ([`BenchmarkRow`](#benchmarkrow) array from [`compare_time`](#compare_time)/[`compare_memory`](#compare_memory)).

@_param_ `format` — Output format (default: "plain").

```lua
format:
    | "plain"    -- Table with embedded bar chart in ratio column
    | "compact"  -- Bar chart only
    | "markdown" -- Markdown table (no bar chart)
    | "csv"      -- CSV format
```

@_param_ `max_width` — Maximum output width (default: terminal width).

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
