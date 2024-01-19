# luamark

## memit

```lua
function luamark.memit(func: fun():any|{ [string]: fun():any }, rounds?: number)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for memory usage. The memory usage is represented in kilobytes.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `rounds` — The number of times to run the benchmark. Defaults to a predetermined number if not provided.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.

## timeit

```lua
function luamark.timeit(func: fun():any|{ [string]: fun():any }, rounds?: number)
  -> { [string]: any }|{ [string]: { [string]: any } }
```

Benchmarks a function for execution time. The time is represented in seconds.

@_param_ `func` — A single zero-argument function or a table of zero-argument functions indexed by name.

@_param_ `rounds` — The number of times to run the benchmark. Defaults to a predetermined number if not provided.

@_return_ — A table of statistical measurements for the function(s) benchmarked, indexed by the function name if multiple functions were given.
