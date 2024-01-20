# luamark

## measure_memory

```lua
function luamark.measure_memory(func: fun():any)
  -> number
```

Measures the memory used by a function.

@_param_ `func` — The zero-arg function to measure.

@_return_ — The amount of memory used by the function (in kilobytes).

## measure_time

```lua
function luamark.measure_time(func: fun():any)
  -> number
```

Measures the time taken to execute a function once.

@_param_ `func` — The zero-arg function to measure.

@_return_ — The time taken to execute the function (in seconds).

## memit

```lua
function luamark.memit(func: fun():any|{ [string]: fun():any }, rounds?: number, iterations: any, warmups: any)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `rounds` — The number of times to run the benchmark. Defaults to a predetermined number if not provided.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## timeit

```lua
function luamark.timeit(func: fun():any|{ [string]: fun():any }, rounds?: number, iterations: any, warmups: any)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `rounds` — The number of times to run the benchmark. Defaults to a predetermined number if not provided.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
