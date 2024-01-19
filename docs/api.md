# luamark

## memit

```lua
function luamark.memit(func: function, rounds: number)
  -> results: table
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `func` — A function with no arguments to benchmark.

@_param_ `rounds` — The number of times to run the benchmark.

@_return_ `results` — A table of memory usage measurements for each run.

## timeit

```lua
function luamark.timeit(func: function, rounds: number)
  -> results: table
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `func` — A function with no arguments to benchmark.

@_param_ `rounds` — The number of times to run the benchmark.

@_return_ `results` — A table of time measurements for each run.
