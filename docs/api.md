# luamark

## memit

```lua
function luamark.memit(func: function, runs: number, warmups: number)
  -> samples: table
```

Benchmarks a function for memory usage.
The memory usage is represented in kilobytes.

@_param_ `func` — The function to benchmark.

@_param_ `runs` — The number of times to run the benchmark.

@_param_ `warmups` — The number of warm-up iterations before the benchmark.

@_return_ `samples` — A table of memory usage measurements for each run.

## timeit

```lua
function luamark.timeit(func: function, runs: number, warmups: number, disable_gc: boolean)
  -> samples: table
```

Benchmarks a function for execution time.
The time is represented in seconds.

@_param_ `func` — The function to benchmark.

@_param_ `runs` — The number of times to run the benchmark.

@_param_ `warmups` — The number of warm-up iterations before the benchmark.

@_param_ `disable_gc` — Whether to disable garbage collection during the benchmark.

@_return_ `samples` — A table of time measurements for each run.
