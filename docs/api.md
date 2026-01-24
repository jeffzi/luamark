# luamark

## Configuration

Set global configuration options directly on the module:

```lua
luamark.rounds = 100  -- Target sample count
luamark.time = 5      -- Target duration in seconds
```

Benchmarks run until **either** target is met: `rounds` samples collected
or `time` seconds elapsed. For very fast functions, rounds are capped at 1,000
to prevent excessive runtime.

### clock_name

```lua
luamark.clock_name  -- "chronos" | "posix.time" | "socket" | "os.clock"
```

Read-only string indicating which clock module is in use.

## API Overview

luamark provides two APIs:

| Function | Input | Returns | `params` |
| -------- | ----- | ------- | -------- |
| [`timeit`](#timeit) | function | [`Stats`](#stats) | No |
| [`memit`](#memit) | function | [`Stats`](#stats) | No |
| [`compare_time`](#compare_time) | table | [`Result[]`](#result) | Yes |
| [`compare_memory`](#compare_memory) | table | [`Result[]`](#result) | Yes |

---

## Single API

Use [`timeit`](#timeit) and [`memit`](#memit) to benchmark a single function.

### timeit

```lua
function luamark.timeit(fn: fun(ctx?: any), opts?: Options) -> Stats
```

Benchmark a single function for execution time. Returns time in seconds.

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

Benchmark a single function for memory usage. Returns memory in kilobytes.

```lua
local stats = luamark.memit(function()
   local t = {}
   for i = 1, 1000 do t[i] = i end
end, { rounds = 10 })

print(stats)  -- "16.05kB ± 0B"
```

### Options

```lua
---@class Options
---@field rounds? integer Target number of benchmark rounds.
---@field time? number Target duration in seconds.
---@field setup? fun(): any Function executed once before benchmark; returns context.
---@field teardown? fun(ctx?: any) Function executed once after benchmark.
---@field before? fun(ctx?: any): any Function executed before each iteration.
---@field after? fun(ctx?: any) Function executed after each iteration.
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
   funcs: table<string, fun(ctx, p)|Spec>,
   opts?: SuiteOptions
) -> Result[]
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
) -> Result[]
```

Compare multiple functions for memory usage. Returns ranked results.

**Note:** `funcs` keys must be strings. Arrays are not supported.

### SuiteOptions

```lua
---@class SuiteOptions
---@field rounds? integer Target number of benchmark rounds.
---@field time? number Target duration in seconds.
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

### Result

[`compare_time`](#compare_time) and [`compare_memory`](#compare_memory) return
[`Result[]`](#result) - a flat array of benchmark results.
The array has a `__tostring` metamethod that calls
[`render(results, true)`](#render):

```lua
local results = luamark.compare_time({ a = fn_a, b = fn_b })
print(results)  -- Prints bar chart (short format)
```

**Sorting:** Results are sorted by parameter group (alphabetically), then by rank
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
| count          | integer   | Number of samples collected                              |
| median         | number    | Median value of samples                                  |
| ci_lower       | number    | Lower bound of 95% CI for median                         |
| ci_upper       | number    | Upper bound of 95% CI for median                         |
| ci_margin      | number    | Half-width of CI ((upper - lower) / 2)                   |
| total          | number    | Sum of all samples                                       |
| samples        | number[]  | Raw samples (sorted)                                     |
| rounds         | integer   | Number of benchmark rounds executed                      |
| iterations     | integer   | Number of iterations per round                           |
| timestamp      | string    | ISO 8601 UTC timestamp of benchmark start                |
| unit           | "s"\|"kb" | Measurement unit (seconds or kilobytes)                  |
| ops            | number?   | Operations per second (1/median, time benchmarks only)   |
| rank           | integer?  | Rank accounting for CI overlap                           |
| ratio          | number?   | Ratio to fastest                                         |
| is_approximate | boolean?  | True if rank is tied due to CI overlap                   |
| *param_name*   | any       | Any param values are inlined directly (e.g., `result.n`) |

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
print(stats)  -- "250ns ± 0ns"
```

| Field          | Type      | Description                                              |
| -------------- | --------- | -------------------------------------------------------- |
| count          | integer   | Number of samples collected                              |
| median         | number    | Median value of samples                                  |
| ci_lower       | number    | Lower bound of 95% CI for median                         |
| ci_upper       | number    | Upper bound of 95% CI for median                         |
| ci_margin      | number    | Half-width of CI ((upper - lower) / 2)                   |
| total          | number    | Sum of all samples                                       |
| samples        | number[]  | Raw samples (sorted)                                     |
| rounds         | integer   | Number of benchmark rounds executed                      |
| iterations     | integer   | Number of iterations per round                           |
| timestamp      | string    | ISO 8601 UTC timestamp of benchmark start                |
| unit           | "s"\|"kb" | Measurement unit (seconds or kilobytes)                  |
| ops            | number?   | Operations per second (1/median, time benchmarks only)   |
| rank           | integer?  | Rank accounting for CI overlap (`compare_*` only)        |
| ratio          | number?   | Ratio to fastest (`compare_*` only)                      |
| is_approximate | boolean?  | True if rank is tied due to CI overlap (`compare_*` only)|

**Rank display:** When results have overlapping confidence intervals, they share the
same rank with an `≈` prefix. For example, `≈1 ≈1 3` means the first two results have
overlapping CIs (statistically indistinguishable), while the third is clearly slower.
The gap in rank numbers (1 to 3) indicates skipped positions.

---

## Utility Functions

### render

```lua
function luamark.render(
   results: Result[],
   short?: boolean,
   max_width?: integer
) -> string
```

Render benchmark results as a formatted string.

@*param* `results` — Benchmark results ([`Result`](#result) array from [`compare_time`](#compare_time)/[`compare_memory`](#compare_memory)).

@*param* `short` — Output format.

- `false` or `nil` (default): Full table with embedded bar chart in ratio column
- `true`: Bar chart only (compact)

@*param* `max_width` — Maximum output width (default: terminal width).

```lua
-- Full table (default)
print(luamark.render(results))

-- Bar chart only
print(luamark.render(results, true))
```

### humanize_time

```lua
function luamark.humanize_time(s: number) -> string
```

Format a time value to a human-readable string. Selects the best unit automatically (m, s, ms, us, ns).

@*param* `s` — Time in seconds.

@*return* — Formatted time string (e.g., "42ns", "1.5ms").

### humanize_memory

```lua
function luamark.humanize_memory(kb: number) -> string
```

Format a memory value to a human-readable string.
Selects the best unit automatically (TB, GB, MB, kB, B).

@*param* `kb` — Memory in kilobytes.

@*return* — Formatted memory string (e.g., "512kB", "1.5MB").

### humanize_count

```lua
function luamark.humanize_count(n: number) -> string
```

Format a count to a human-readable string with SI suffix (M, k).

@*param* `n` — Count value.

@*return* — Formatted count string (e.g., "1k", "12.5M").

### unload

```lua
function luamark.unload(pattern: string) -> integer
```

Unload modules matching a Lua pattern from `package.loaded`.
Useful for benchmarking module load times or resetting state between runs.

@*param* `pattern` — Lua pattern to match module names against.

@*return* — Number of modules unloaded.

```lua
-- Unload all modules starting with "mylib"
local count = luamark.unload("^mylib")
print(count)  -- Number of modules unloaded

-- Benchmark module load time
luamark.unload("^mymodule$")
local stats = luamark.timeit(function()
   require("mymodule")
end)
```
