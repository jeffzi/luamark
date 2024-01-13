# LuaMark

## calculate_stats

```lua
function benchmark.calculate_stats(samples: table)
  -> stats: table
```

Calculates statistical metrics from benchmark samples.
Includes count, min, max, mean, and standard deviation.

@_param_ `samples` — The table of raw values from timeit or memit.

@_return_ `stats` — A table containing statistical metrics.

## format_stats

```lua
function benchmark.format_stats(stats: table, unit: string)
  -> txt: string
```

Formats the statistical metrics into a readable string.

@_param_ `stats` — The statistical metrics to format.

@_param_ `unit` — The unit of measurement for the metrics.

@_return_ `txt` — A formatted string representing the statistical metrics.

## memit

```lua
function benchmark.memit(func: function, runs: number, warmup_runs: number)
  -> samples: table
```

Benchmarks a function for memory usage.

@_param_ `func` — The function to benchmark.

@_param_ `runs` — The number of times to run the benchmark.

@_param_ `warmup_runs` — The number of warm-up iterations before the benchmark.

@_return_ `samples` — A table of memory usage measurements for each run.

## timeit

```lua
function benchmark.timeit(func: function, runs: number, warmup_runs: number, disable_gc: boolean)
  -> samples: table
```

Benchmarks a function for execution time.

@_param_ `func` — The function to benchmark.

@_param_ `runs` — The number of times to run the benchmark.

@_param_ `warmup_runs` — The number of warm-up iterations before the benchmark.

@_param_ `disable_gc` — Whether to disable garbage collection during the benchmark.

@_return_ `samples` — A table of time measurements for each run.
