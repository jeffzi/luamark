# luamark

## BenchmarkOptions

### max_time

```lua
integer?
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

Function executed before the measured function.

### teardown

```lua
fun()?
```

Function executed after the measured function.

## timeit

```lua
function luamark.timeit(fn: fun()|{ [string]: fun() }, opts?: BenchmarkOptions)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `fn` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table for configuring the benchmark.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## memit

```lua
function luamark.memit(fn: fun()|{ [string]: fun() }, opts?: BenchmarkOptions)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `fn` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table for configuring the benchmark.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## summarize

```lua
function luamark.summarize(benchmark_results: { [string]: { [string]: any } }, format?: "markdown"|"plain")
  -> string
```

Return a string summarizing the results of multiple benchmarks.

@_param_ `benchmark_results` — The benchmark results to summarize, indexed by name.

@_param_ `format` — The output format

```lua
format:
    | "plain"
    | "markdown"
```
