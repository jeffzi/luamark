# luamark

## timeit

```lua
function luamark.timeit(func: fun():any|{ [string]: fun():any }, rounds?: integer, max_time?: number, setup?: fun():any, teardown?: fun():any)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `rounds` — The number of times to run the benchmark. Defaults to a predetermined number if not provided.

@_param_ `max_time` — Maximum run time. It may be exceeded if test function is very slow.

@_param_ `setup` — Function executed before computing each benchmark value.

@_param_ `teardown` — Function executed after computing each benchmark value.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## memit

```lua
function luamark.memit(func: fun():any|{ [string]: fun():any }, rounds?: number, max_time?: number, setup?: fun():any, teardown?: fun():any)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `rounds` — The number of times to run the benchmark. Defaults to a predetermined number if not provided.

@_param_ `max_time` — Maximum run time. It may be exceeded if test function is very slow.

@_param_ `setup` — Function executed before computing each benchmark value.

@_param_ `teardown` — Function executed after computing each benchmark value.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## print_summary

```lua
function luamark.print_summary(benchmark_results: { [string]: { [string]: any } })
```

Print a summary of multiple benchmarks.

@_param_ `benchmark_results` — The benchmark results to summarize, indexed by name.

## measure_time

```lua
function luamark.measure_time(func: fun():any)
  -> number
```

Measures the time taken to execute a function once.

@_param_ `func` — The zero-arg function to measure.

@_return_ — The time taken to execute the function (in seconds).

## measure_memory

```lua
function luamark.measure_memory(func: fun():any)
  -> number
```

Measures the memory used by a function.

@_param_ `func` — The zero-arg function to measure.

@_return_ — The amount of memory used by the function (in kilobytes).

## rank

```lua
function luamark.rank(benchmark_results: { [string]: { [string]: any } }, key: string)
  -> { [string]: { [string]: any } }
```

Rank benchmark results (`timeit` or `memit`) by specified `key` and adds a 'rank' and 'ratio' key to each.
The smallest attribute value gets the rank 1 and ratio 1.0, other ratios are relative to it.

@_param_ `benchmark_results` — The benchmark results to rank, indexed by name.

@_param_ `key` — The stats to rank by.
