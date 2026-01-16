# luamark

## Configuration

Global configuration options can be set directly on the module:

```lua
luamark.max_iterations = 1e6  -- Maximum iterations per round
luamark.min_rounds = 100      -- Minimum benchmark rounds
luamark.max_rounds = 1e6      -- Maximum benchmark rounds
luamark.warmups = 1           -- Number of warmup rounds
```

Read-only fields:

```lua
luamark._VERSION    -- Library version (e.g., "0.9.0")
luamark.clock_name  -- Active clock backend ("chronos", "posix.time", "socket", or "os.clock")
```

---

## Core API

### BenchmarkOptions

#### max_time

```lua
number?
```

Maximum run time in seconds. It may be exceeded if test function is very slow.

#### rounds

```lua
integer?
```

The number of times to run the benchmark. Defaults to a predetermined number if not provided.

#### setup

```lua
fun()?
```

Function executed before each iteration.

#### teardown

```lua
fun()?
```

Function executed after each iteration.

### Stats

Returned by `timeit` and `memit`.

| Field      | Type      | Description                               |
| ---------- | --------- | ----------------------------------------- |
| count      | integer   | Number of samples collected               |
| mean       | number    | Arithmetic mean of samples                |
| median     | number    | Median value of samples                   |
| min        | number    | Minimum sample value                      |
| max        | number    | Maximum sample value                      |
| stddev     | number    | Standard deviation of samples             |
| total      | number    | Sum of all samples                        |
| samples    | number[]  | Raw samples (sorted)                      |
| rounds     | integer   | Number of benchmark rounds executed       |
| iterations | integer   | Number of iterations per round            |
| warmups    | integer   | Number of warmup rounds                   |
| timestamp  | string    | ISO 8601 UTC timestamp of benchmark start |
| unit       | "s"\|"kb" | Measurement unit (seconds or kilobytes)   |
| rank       | integer?  | Rank when comparing multiple benchmarks   |
| ratio      | number?   | Ratio relative to fastest benchmark       |

### timeit

```lua
function luamark.timeit(fn: fun()|{ [string]: fun() }, opts?: BenchmarkOptions)
  -> Stats|{ [string]: Stats }
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `fn` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table for configuring the benchmark.

@_return_ — Stats for single function, or table of Stats indexed by name for multiple functions.

### memit

```lua
function luamark.memit(fn: fun()|{ [string]: fun() }, opts?: BenchmarkOptions)
  -> Stats|{ [string]: Stats }
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `fn` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table for configuring the benchmark.

@_return_ — Stats for single function, or table of Stats indexed by name for multiple functions.

### summarize

```lua
function luamark.summarize(
   results: { [string]: Stats }|SuiteResult,
   format?: "plain"|"compact"|"markdown"|"csv",
   max_width?: integer
) -> string
```

Return a string summarizing the results of multiple benchmarks.

@_param_ `results` — The benchmark results (from `timeit`/`memit` or `suite_timeit`/`suite_memit`).

@_param_ `format` — The output format (default: "plain")

@_param_ `max_width` — Maximum output width in characters (default: terminal width or 100)

```lua
format:
    | "plain"    -- Table with bar chart
    | "compact"  -- Bar chart only
    | "markdown" -- Markdown table (no bar chart)
    | "csv"      -- CSV format
```

---

## Suite API

### Hierarchy

A suite spec is organized into **groups**, each containing **benchmarks**:

```text
spec (table passed to suite_timeit/suite_memit)
└── group (named collection of related benchmarks)
    ├── benchmark (function to measure)
    ├── benchmark ...
    └── opts (shared configuration: params, setup, teardown)
```

- **Spec**: The top-level table containing all groups
- **Group**: A named collection of benchmarks that share configuration (setup, params)
- **Benchmark**: An individual function to measure

### SuiteOpts

Shared configuration for a group.

| Field    | Type                  | Description                                        |
| -------- | --------------------- | -------------------------------------------------- |
| params   | table<string, any[]>? | Parameter names mapped to arrays of values         |
| setup    | fun(params: table)?   | Shared setup (untimed, runs before benchmark)      |
| teardown | fun(params: table)?   | Shared teardown (untimed, runs after benchmark)    |
| rounds   | integer?              | Number of benchmark rounds                         |
| max_time | number?               | Maximum time for benchmarking                      |

### SuiteSpec

Map of group names to group definitions.

```lua
{
  [group_name] = {
    -- Benchmarks (all keys except 'opts')
    bench1 = fn,                                            -- bare function
    bench2 = { fn = fn, setup = fn(params)?, teardown = fn(params)? },  -- with per-benchmark config

    -- Shared configuration (only reserved key)
    opts = SuiteOpts?,
  },
}
```

### SuiteResult

Nested result structure:

```lua
-- With parameters: result[group][benchmark].param[value] → Stats
results["sort"]["quick"].n[1000]  -- → Stats
results["group"]["bench"].m[10].n[100]  -- → Stats (multiple params, sorted alphabetically)

-- No parameters: result[group][benchmark] → Stats (directly)
results["group"]["bench"]  -- → Stats
```

### suite_timeit

```lua
function luamark.suite_timeit(spec: SuiteSpec) -> SuiteResult
```

Benchmarks a suite for execution time with untimed setup/teardown and parameter expansion.

@_param_ `spec` — Groups with benchmarks and optional params.

@_return_ — Nested results: `result[group][benchmark].param[value]` → Stats

#### Setup/Teardown Execution Order

For each (group, benchmark, param_combination):

1. `opts.setup(params)` - shared setup (untimed)
2. `bench.setup(params)` - per-benchmark setup (untimed)
3. **measurement loop** - times only `bench.fn`
4. `bench.teardown(params)` - per-benchmark teardown (untimed)
5. `opts.teardown(params)` - shared teardown (untimed)

### suite_memit

```lua
function luamark.suite_memit(spec: SuiteSpec) -> SuiteResult
```

Benchmarks a suite for memory usage with untimed setup/teardown and parameter expansion.

@_param_ `spec` — Groups with benchmarks and optional params.

@_return_ — Nested results: `result[group][benchmark].param[value]` → Stats
