# luamark

## Configuration

Global configuration options can be set directly on the module:

```lua
luamark.max_iterations = 1e6  -- Maximum iterations per round
luamark.min_rounds = 100      -- Minimum benchmark rounds
luamark.max_rounds = 1e6      -- Maximum benchmark rounds
luamark.warmups = 1           -- Number of warmup rounds
```

### get_config

```lua
function luamark.get_config() -> table
```

Return a copy of the current configuration values:

```lua
local cfg = luamark.get_config()
-- { max_iterations = 1e6, min_rounds = 100, max_rounds = 1e6, warmups = 1 }
```

## Options

### rounds

```lua
integer?
```

The number of times to run the benchmark. Defaults to a predetermined number if not provided.

**Note:** When both `rounds` and `max_time` are specified, `rounds` acts as a
maximum - the benchmark will stop at whichever limit is reached first.

### max_time

```lua
number?
```

Maximum run time in seconds. It may be exceeded if test function is very slow.

### setup

```lua
fun(p: table): any?
```

Function executed once before the benchmark starts. Receives params table,
returns context passed to fn.

### teardown

```lua
fun(ctx: any, p: table)?
```

Function executed once after the benchmark ends. Receives context and params.

### before

```lua
fun(ctx: any, p: table): any?
```

Function executed before each iteration. Receives global context (from `setup`),
returns updated context. Runs before `Spec.before`.

### after

```lua
fun(ctx: any, p: table)?
```

Function executed after each iteration. Receives context and params. Runs after `Spec.after`.

### params

```lua
table<string, any[]>?
```

Parameter combinations to benchmark across. Each key is a parameter name, each
value is an array of values to test.

```lua
-- Example: benchmark with different sizes and types
luamark.timeit(fn, {
   params = {
      size = {100, 1000, 10000},
      type = {"array", "hash"}
   }
})
```

## Spec

When passing multiple functions to `timeit`/`memit`, each function can optionally
be a Spec table with per-iteration setup/teardown. Unlike `Options.setup/teardown`
(run once per benchmark), `Spec.before/after` run before/after each iteration.

```lua
---@class Spec
---@field fn fun(ctx: any, p: table) Benchmark function.
---@field before? fun(ctx: any, p: table): any Per-iteration setup.
---@field after? fun(ctx: any, p: table) Per-iteration teardown.
```

## BenchmarkRow

Both `timeit` and `memit` return `BenchmarkRow[]` - a flat array of benchmark results:

```lua
---@class BenchmarkRow
---@field name string Benchmark name ("1" for unnamed single function).
---@field params table Parameter values for this run.
---@field stats Stats Benchmark statistics.
```

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

### When to Use Each Hook

| Hook                | Scope        | Runs                  | Use Case                       |
| ------------------- | ------------ | --------------------- | ------------------------------ |
| `Options.setup`     | Shared       | Once per param combo  | Load config, open DB           |
| `Options.teardown`  | Shared       | Once per param combo  | Close connections, cleanup     |
| `Options.before`    | Shared       | Every iteration       | Generate fresh test data       |
| `Options.after`     | Shared       | Every iteration       | Shared cleanup after each run  |
| `Spec.before`       | Per-function | Every iteration       | Function-specific setup        |
| `Spec.after`        | Per-function | Every iteration       | Function-specific cleanup      |

### Examples

**Shared test data for comparing algorithms:**

```lua
-- All search algorithms get the same fresh random data each iteration
luamark.timeit({
   linear_search = linear_search,
   binary_search = binary_search,
   hash_lookup = hash_lookup,
}, {
   params = { n = {100, 1000, 10000} },
   before = function(ctx, params)
      ctx.data = generate_random_array(params.n)
      ctx.target = ctx.data[math.random(params.n)]
      return ctx
   end,
})
```

**Per-function setup for different frameworks:**

```lua
-- Each ECS framework needs its own world creation
luamark.timeit({
   tinyecs = {
      fn = function(ctx, params)
         for _ = 1, params.n_entities do
            tiny.addEntity(ctx.world, {})
         end
      end,
      before = function(ctx, params)
         ctx.world = tiny.world()
         return ctx
      end,
   },
   evolved = {
      fn = function(ctx, params)
         for _ = 1, params.n_entities do
            evolved.spawn(ctx.world)
         end
      end,
      before = function(ctx, params)
         ctx.world = evolved.world()
         return ctx
      end,
   },
}, {
   params = { n_entities = {100, 1000} },
})
```

**Combined: shared data + per-function setup:**

```lua
luamark.timeit({
   algorithm_a = {
      fn = algorithm_a,
      before = function(ctx)
         -- Algorithm-specific initialization using shared data
         ctx.state = initialize_a(ctx.data)
         return ctx
      end,
   },
   algorithm_b = {
      fn = algorithm_b,
      before = function(ctx)
         ctx.state = initialize_b(ctx.data)
         return ctx
      end,
   },
}, {
   before = function(ctx, params)
      -- Shared: generate data that all algorithms use
      ctx.data = generate_data(params.n)
      return ctx
   end,
   params = { n = {100, 1000} },
})
```

## Stats

Returned by `timeit` and `memit`.

| Field | Type | Description |
| ----- | ---- | ----------- |
| count | integer | Number of samples collected |
| mean | number | Arithmetic mean of samples |
| median | number | Median value of samples |
| min | number | Minimum sample value |
| max | number | Maximum sample value |
| stddev | number | Standard deviation of samples |
| total | number | Sum of all samples |
| samples | number[] | Raw samples (sorted) |
| rounds | integer | Number of benchmark rounds executed |
| iterations | integer | Number of iterations per round |
| warmups | integer | Number of warmup rounds |
| timestamp | string | ISO 8601 UTC timestamp of benchmark start |
| unit | "s"\|"kb" | Measurement unit (seconds or kilobytes) |
| rank | integer? | Rank when comparing multiple benchmarks |
| ratio | number? | Ratio relative to fastest benchmark |

## timeit

```lua
function luamark.timeit(target: fun()|{ [string]: fun()|Spec }, opts?: Options)
  -> BenchmarkRow[]
```

Benchmark a function for execution time. Time is represented in seconds.

@_param_ `target` — Function or table of functions/Specs to benchmark.

@_param_ `opts` — Benchmark configuration.

@_return_ — Flat array of BenchmarkRow results.

## memit

```lua
function luamark.memit(target: fun()|{ [string]: fun()|Spec }, opts?: Options)
  -> BenchmarkRow[]
```

Benchmark a function for memory usage. Memory is represented in kilobytes.

@_param_ `target` — Function or table of functions/Specs to benchmark.

@_param_ `opts` — Benchmark configuration.

@_return_ — Flat array of BenchmarkRow results.

## summarize

```lua
function luamark.summarize(
   results: BenchmarkRow[],
   format?: "plain"|"compact"|"markdown"|"csv",
   max_width?: integer
) -> string
```

Return a string summarizing benchmark results.

@_param_ `results` — Benchmark results (BenchmarkRow array from timeit/memit).

@_param_ `format` — Output format (default: "plain").

```lua
format:
    | "plain"    -- Table with embedded bar chart in ratio column
    | "compact"  -- Bar chart only
    | "markdown" -- Markdown table (no bar chart)
    | "csv"      -- CSV format
```

@_param_ `max_width` — Maximum output width (default: terminal width).

## humanize_time

```lua
function luamark.humanize_time(s: number)
  -> string
```

Format a time value to a human-readable string. Automatically select the best unit (m, s, ms, us, ns).

@_param_ `s` — Time in seconds.

@_return_ — Formatted time string (e.g., "42ns", "1.5ms").

## humanize_memory

```lua
function luamark.humanize_memory(kb: number)
  -> string
```

Format a memory value to a human-readable string.
Automatically select the best unit (TB, GB, MB, kB, B).

@_param_ `kb` — Memory in kilobytes.

@_return_ — Formatted memory string (e.g., "512kB", "1.5MB").
