# luamark

## calculate_stats

```lua
function luamark.calculate_stats(samples: table)
  -> stats: table
```

Calculates statistical metrics from timeit or memit samples..
Includes count, min, max, mean, and standard deviation.

@_param_ `samples` — The table of raw values from timeit or memit.

@_return_ `stats` — A table containing statistical metrics.

## format_mem_stats

```lua
function luamark.format_mem_stats(stats: table)
  -> A: string
```

Formats the memory statistics into a readable string.

@_param_ `stats` — The statistical metrics to format, specifically for memory measurements.

@_return_ `A` — formatted string representing the memory statistical metrics in kilobytes.

## format_time_stats

```lua
function luamark.format_time_stats(stats: table)
  -> A: string
```

Formats the time statistics into a readable string.

@_param_ `stats` — The statistical metrics to format, specifically for time measurements.

@_return_ `A` — formatted string representing the time statistical metrics in seconds.

## memit

```lua
function luamark.memit(func: function, runs: number, warmup_runs: number)
  -> samples: table
```

Benchmarks a function for memory usage.
The memory usage is represented in kilobytes.

@_param_ `func` — The function to luamark.

@_param_ `runs` — The number of times to run the luamark.

@_param_ `warmup_runs` — The number of warm-up iterations before the luamark.

@_return_ `samples` — A table of memory usage measurements for each run.

## timeit

```lua
function luamark.timeit(func: function, runs: number, warmup_runs: number, disable_gc: boolean)
  -> samples: table
```

Benchmarks a function for execution time.
The time is represented in seconds.

@_param_ `func` — The function to luamark.

@_param_ `runs` — The number of times to run the luamark.

@_param_ `warmup_runs` — The number of warm-up iterations before the luamark.

@_param_ `disable_gc` — Whether to disable garbage collection during the luamark.

@_return_ `samples` — A table of time measurements for each run.
