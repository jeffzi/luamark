# LuaMark

[![prek](https://img.shields.io/badge/prek-enabled-brightgreen?logo=pre-commit)](https://github.com/j178/prek)
[![Busted](https://github.com/jeffzi/luamark/actions/workflows/busted.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/busted.yml)
[![Luacheck](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml)
[![Luarocks](https://img.shields.io/luarocks/v/jeffzi/luamark?label=Luarocks&logo=Lua)](https://luarocks.org/modules/jeffzi/luamark)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

LuaMark is a lightweight, portable microbenchmarking library for Lua. It measures
execution time and memory usage with sensible defaults and optional high-precision clocks.

## Features

- **Measure time and memory** with optional precision via [Chronos][chronos],
  [LuaPosix][luaposix], or [LuaSocket][luasocket]
- **Statistics**: median with 95% confidence intervals
- **Standalone Timer**: `luamark.Timer()` for ad-hoc profiling outside benchmark
- **Ready to use** with sensible defaults

[chronos]: https://github.com/ldrumm/chronos
[luaposix]: https://github.com/luaposix/luaposix
[luasocket]: https://github.com/lunarmodules/luasocket

## Requirements

- Lua 5.1, 5.2, 5.3, 5.4, or LuaJIT 2.1
- Optional: [chronos], [luaposix], or [luasocket] for enhanced timing precision

## Installation

Install LuaMark using [LuaRocks](https://luarocks.org/):

```shell
luarocks install luamark
```

Alternatively, you can manually include [luamark.lua](src/luamark.lua) in your project.

## Usage

### API Overview

| Function              | Input              | Returns         | `params` support |
| --------------------- | ------------------ | --------------- | ---------------- |
| [`timeit`][1]         | single function    | [`Stats`][5]    | No               |
| [`memit`][2]          | single function    | [`Stats`][5]    | No               |
| [`compare_time`][3]   | table of functions | [`Result[]`][6] | Yes              |
| [`compare_memory`][4] | table of functions | [`Result[]`][6] | Yes              |

`params` lets you run benchmarks across parameter combinations (e.g., different input sizes).

[1]: docs/api.md#timeit
[2]: docs/api.md#memit
[3]: docs/api.md#compare_time
[4]: docs/api.md#compare_memory
[5]: docs/api.md#stats
[6]: docs/api.md#result

### Single Function

Measure execution time:

```lua
local luamark = require("luamark")

local function factorial(n)
   if n == 0 then return 1 end
   return n * factorial(n - 1)
end

local stats = luamark.timeit(function()
   factorial(10)
end)

print(stats)
-- Output: 250ns ± 0ns
```

Measure memory allocation:

```lua
local luamark = require("luamark")

local stats = luamark.memit(function()
   local t = {}
   for i = 1, 100 do t[i] = i end
end)

print(stats)
-- Output: 2.05kB ± 0B
```

### Comparing Functions

Basic comparison:

```lua
local luamark = require("luamark")

local results = luamark.compare_time({
   loop = function()
      local s = ""
      for i = 1, 100 do s = s .. tostring(i) end
   end,
   table_concat = function()
      local t = {}
      for i = 1, 100 do t[i] = tostring(i) end
      table.concat(t)
   end,
})

print(luamark.render(results))
```

With parameters and setup:

```lua
local luamark = require("luamark")

local results = luamark.compare_time({
   loop = function(ctx, p)
      local s = ""
      for i = 1, #ctx.data do s = s .. ctx.data[i] end
   end,
   table_concat = function(ctx, p)
      table.concat(ctx.data)
   end,
}, {
   params = { n = { 100, 1000 } },
   setup = function(p)
      local data = {}
      for i = 1, p.n do data[i] = tostring(i) end
      return { data = data }
   end,
})

print(luamark.render(results))
```

```text
    Name      Rank     Relative        Median      Ops
------------  ----  ---------------  ----------  --------
table_concat     1  █            1x         1us  959.7k/s
loop             2  ████████ ↓5.36x  6us ± 21ns  179.1k/s

n=1000
    Name      Rank      Relative        Median       Ops
------------  ----  ----------------  -----------  -------
table_concat     1  █             1x  10us ± 31ns  98.4k/s
loop             2  ████████ ↓13.07x  133us ± 2us   7.5k/s
```

When results have overlapping confidence intervals, they share the same rank with
an `≈` prefix (e.g., `≈1 ≈1 3`), indicating they are statistically indistinguishable.

### Per-Iteration Setup with Spec Hooks

When benchmarking functions that mutate data, use `Spec.before` for per-iteration setup:

```lua
local luamark = require("luamark")

local results = luamark.compare_time({
   table_sort = {
      fn = function(ctx, p)
         table.sort(ctx.data)
      end,
      before = function(ctx, p)
         -- Copy data before each iteration (sort mutates it)
         ctx.data = {}
         for i = 1, #ctx.source do
            ctx.data[i] = ctx.source[i]
         end
         return ctx
      end,
   },
}, {
   params = { n = {100, 1000} },
   setup = function(p)
      local source = {}
      for i = 1, p.n do
         source[i] = math.random(p.n * 10)
      end
      return { source = source }
   end,
})
```

### Standalone Timer

Use `luamark.Timer()` for ad-hoc profiling outside of benchmarks:

```lua
local luamark = require("luamark")

local timer = luamark.Timer()
timer.start()
local sum = 0
for i = 1, 1e6 do sum = sum + i end
local elapsed = timer.stop()

print(luamark.humanize_time(elapsed))  -- "4.25ms"
```

## Technical Details

### Configuration

LuaMark provides two configuration options:

- `rounds`: Target sample count (default: 100)
- `time`: Target duration in seconds (default: 1)

Benchmarks run until **either** target is met: `rounds` samples collected
or `time` seconds elapsed. For very fast functions, rounds are capped at 100
to ensure consistent sample count.

Modify these settings directly:

```lua
local luamark = require("luamark")

-- Increase minimum rounds for more statistical reliability
luamark.rounds = 1000

-- Run benchmarks for at least 2 seconds
luamark.time = 2
```

### Iterations and Rounds

LuaMark runs your code multiple times per round (iterations), then repeats for multiple
rounds. It computes statistics across rounds, handling clock granularity and filtering
system noise.

### Clock Precision

LuaMark selects the best available clock:

| Priority | Module              | Precision   | Notes                  |
| -------- | ------------------- | ----------- | ---------------------- |
| 1        | [chronos]           | nanosecond  | recommended            |
| 2        | [luaposix]          | nanosecond  | not available on macOS |
| 3        | [luasocket]         | millisecond |                        |
| 4        | os.clock (built-in) | varies      | fallback               |

## API Documentation

For detailed API information, please refer to the [API Documentation](docs/api.md).

## Contributing

Contributions welcome: bug fixes, documentation, new features.

## License

LuaMark is released under the [MIT License](LICENSE).
