# luamark

## timeit

```lua
function luamark.timeit(func: fun():any|{ [string]: fun():any }, opts: table)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table which may include rounds, max_time, setup, teardown.

- rounds: number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
- max_time: number Maximum run time. It may be exceeded if test function is very slow.
- setup: fun():any Function executed before the measured function.
- teardown: fun():any Function executed after the measured function.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## memit

```lua
function luamark.memit(func: fun():any|{ [string]: fun():any }, opts: table)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `opts` — Options table which may include rounds, max_time, setup, teardown.

- rounds: number The number of times to run the benchmark. Defaults to a predetermined number if not provided.
- max_time: number Maximum run time. It may be exceeded if test function is very slow.
- setup: fun():any Function executed before the measured function.
- teardown: fun():any Function executed after the measured function.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## summarize

```lua
function luamark.summarize(benchmark_results: { [string]: { [string]: any } })
  -> string
```

Return a string summarizing the results of multiple benchmarks.

## rank

```lua
function luamark.rank(benchmark_results: { [string]: { [string]: any } }, key: string)
  -> { [string]: { [string]: any } }
```

Rank benchmark results (`timeit` or `memit`) by specified `key` and adds a 'rank' and 'ratio' key to each.
The smallest attribute value gets the rank 1 and ratio 1.0, other ratios are relative to it.

@_param_ `benchmark_results` — The benchmark results to rank, indexed by name.

@_param_ `key` — The stats to rank by.
