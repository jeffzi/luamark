# LuaMark

[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![Busted](https://github.com/jeffzi/luamark/actions/workflows/busted.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/busted.yml)
[![Luacheck](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml)
[![Luarocks](https://img.shields.io/luarocks/v/jeffzi/luamark?label=Luarocks&logo=Lua)](https://luarocks.org/modules/jeffzi/luamark)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

LuaMark is a lightweight, portable microbenchmarking library for Lua. It measures
execution time and memory usage with sensible defaults and optional high-precision clocks.

## Features

- **Measure time and memory** with optional precision via [Chronos][chronos],
  [LuaPosix][luaposix], [LuaSocket][luasocket], or [AllocSpy][allocspy]
- **Statistics**: median with 95% confidence intervals
- **Ready to use** with sensible defaults

[chronos]: https://github.com/ldrumm/chronos
[luaposix]: https://github.com/luaposix/luaposix
[luasocket]: https://github.com/lunarmodules/luasocket
[allocspy]: https://github.com/siffiejoe/lua-allocspy

## Requirements

- Lua 5.1, 5.2, 5.3, 5.4, or LuaJIT 2.1
- Optional: [chronos], [luaposix], or [luasocket] for enhanced timing precision
- Optional: [AllocSpy][allocspy] for enhanced memory tracking

## Installation

Install LuaMark using [LuaRocks](https://luarocks.org/):

```shell
luarocks install luamark
```

Alternatively, you can manually include [luamark.lua](src/luamark.lua) in your project.

## Usage

### API Overview

| Function              | Input              | Returns               | `params` |
| --------------------- | ------------------ | --------------------- | -------- |
| [`timeit`][1]         | single function    | [`Stats`][5]          | No       |
| [`memit`][2]          | single function    | [`Stats`][5]          | No       |
| [`compare_time`][3]   | table of functions | [`Result[]`][6]       | Yes      |
| [`compare_memory`][4] | table of functions | [`Result[]`][6]       | Yes      |

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

print(results)  -- compact output (bar chart)

print(luamark.render(results))  -- detailed output (full table)
```

```text
n=100
    Name      Rank      Ratio       Median  CI Low  CI High    Ops      Iters
------------  ----  --------------  ------  ------  -------  --------  --------
table_concat  1     █        1.00x  1.12us  1.12us  1.12us   888.9k/s  1000 × 1
loop          2     ████████ 4.18x  4.71us  4.67us  4.79us   212.4k/s  1000 × 1

n=1000
    Name      Rank       Ratio        Median    CI Low   CI High     Ops     Iters
------------  ----  ---------------  --------  --------  --------  -------  --------
table_concat  1     █         1.00x  12.33us   12.29us   12.38us   81.1k/s  1000 × 1
loop          2     ████████ 15.47x  190.83us  189.46us  192.38us  5.2k/s   1000 × 1
```

When results have overlapping confidence intervals, they share the same rank with
an `≈` prefix (e.g., `≈1 ≈1 3`), indicating they are statistically indistinguishable.

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

For memory, [AllocSpy][allocspy] provides byte-level precision when available.

## API Documentation

For detailed API information, please refer to the [API Documentation](docs/api.md).

## Contributing

Contributions welcome: bug fixes, documentation, new features.

## License

LuaMark is released under the [MIT License](LICENSE).
