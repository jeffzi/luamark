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
function luamark.summarize(benchmark_results: { [string]: Stats }, format?: "plain"|"markdown")
  -> string
```

Return a string summarizing the results of multiple benchmarks.

@_param_ `benchmark_results` — The benchmark results to summarize, indexed by name.

@_param_ `format` — The output format (default: "plain")

```lua
format:
    | "plain"
    | "markdown"
```
