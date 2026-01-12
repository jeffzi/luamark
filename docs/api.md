# luamark

## Configuration

Global configuration options can be set directly on the module:

```lua
luamark.max_iterations = 1e6  -- Maximum iterations per round
luamark.min_rounds = 100      -- Minimum benchmark rounds
luamark.max_rounds = 1e6      -- Maximum benchmark rounds
luamark.warmups = 1           -- Number of warmup rounds
```

## BenchmarkOptions

### max_time

```lua
number?
```

Maximum run time in seconds. It may be exceeded if test function is very slow.

### rounds

```lua
integer?
```

The number of times to run the benchmark. Defaults to a predetermined number if not provided.

### setup

```lua
fun()?
```

Function executed before each iteration.

### teardown

```lua
fun()?
```

Function executed after each iteration.

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
function luamark.timeit(fn: fun()|{ [string]: fun() }, opts?: BenchmarkOptions)
  -> Stats|{ [string]: Stats }
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `fn` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table for configuring the benchmark.

@_return_ — Stats for single function, or table of Stats indexed by name for multiple functions.

## memit

```lua
function luamark.memit(fn: fun()|{ [string]: fun() }, opts?: BenchmarkOptions)
  -> Stats|{ [string]: Stats }
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `fn` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table for configuring the benchmark.

@_return_ — Stats for single function, or table of Stats indexed by name for multiple functions.

## summarize

```lua
function luamark.summarize(benchmark_results: { [string]: Stats }|SuiteResult, format?: "plain"|"compact"|"markdown"|"csv")
  -> string
```

Return a string summarizing the results of multiple benchmarks.

@_param_ `benchmark_results` — The benchmark results to summarize (from `timeit`/`memit` or `suite`/`suite_memit`).

@_param_ `format` — The output format (default: "plain")

```lua
format:
    | "plain"    -- Table with bar chart
    | "compact"  -- Bar chart only
    | "markdown" -- Markdown table (no bar chart)
    | "csv"      -- CSV format (suite results only)
```

## SuiteOpts

Shared configuration for an operation.

| Field | Type | Description |
| ----- | ---- | ----------- |
| params | table<string, any[]>? | Parameter names mapped to arrays of values (cartesian product) |
| setup | fun(params: table)? | Shared setup function (untimed, runs before impl setup) |
| teardown | fun(params: table)? | Shared teardown function (untimed, runs after impl teardown) |
| rounds | integer? | Number of benchmark rounds |
| max_time | number? | Maximum time for benchmarking |

## SuiteInput

Map of operation names to operation definitions.

```lua
{
  [operation_name] = {
    -- Implementations (all keys except 'opts')
    impl1 = fn,                                            -- bare function
    impl2 = { fn = fn, setup = fn?, teardown = fn? },      -- with per-impl config

    -- Shared configuration (only reserved key)
    opts = SuiteOpts?,
  },
}
```

## SuiteResult

Nested result structure: `result[operation][impl].param[value]` → Stats

```lua
-- Single parameter
results["sort"]["quick"].n[1000]  -- → Stats

-- Multiple parameters (sorted alphabetically)
results["op"]["impl"].m[10].n[100]  -- → Stats

-- No parameters
results["op"]["impl"]._  -- → Stats
```

## suite

```lua
function luamark.suite(suite_input: SuiteInput)
  -> SuiteResult
```

Benchmarks a suite for execution time with untimed setup/teardown and parameter expansion.

@_param_ `suite_input` — Operations with implementations and optional params.

@_return_ — Nested results: `result[operation][impl].param[value]` → Stats

### Setup/Teardown Execution Order

For each (operation, implementation, param_combination):

1. `opts.setup(params)` - shared setup (untimed)
2. `impl.setup(params)` - per-implementation setup (untimed)
3. **measurement loop** - times only `impl.fn`
4. `impl.teardown(params)` - per-implementation teardown (untimed)
5. `opts.teardown(params)` - shared teardown (untimed)

## suite_memit

```lua
function luamark.suite_memit(suite_input: SuiteInput)
  -> SuiteResult
```

Benchmarks a suite for memory usage with untimed setup/teardown and parameter expansion.

@_param_ `suite_input` — Operations with implementations and optional params.

@_return_ — Nested results: `result[operation][impl].param[value]` → Stats
