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
- **Statistics**: min, max, mean, median, standard deviation
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

| Function | Input | Returns | `params` |
| -------- | ----- | ------- | -------- |
| [`timeit`](docs/api.md#timeit) | single function | [`Stats`](docs/api.md#stats) | No |
| [`memit`](docs/api.md#memit) | single function | [`Stats`](docs/api.md#stats) | No |
| [`compare_time`](docs/api.md#compare_time) | table of functions | [`BenchmarkRow[]`](docs/api.md#benchmarkrow) | Yes |
| [`compare_memory`](docs/api.md#compare_memory) | table of functions | [`BenchmarkRow[]`](docs/api.md#benchmarkrow) | Yes |

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
-- Output: 31.34ns ± 172.86ns per round (558140 rounds)
```

Measure memory allocation:

```lua
local luamark = require("luamark")

local stats = luamark.memit(function()
   local t = {}
   for i = 1, 100 do t[i] = i end
end)

print(stats)
-- Output: 1.07kB ± 15.86B per round (8876 rounds)
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

print(results)  -- compact output

print(luamark.summarize(results, "plain"))  -- detailed output
```

```text
n=100
    Name      Rank      Ratio       Median    Mean     Min     Max     Stddev   Rounds
------------  ----  --------------  ------  --------  -----  -------  --------  -------
table_concat  1     ██       1.00x  292ns   291.41ns  167ns  50.25us  175.93ns  1000000
loop          2     ████████ 3.28x  958ns   972.18ns  833ns  89.42us  361.36ns  311688

n=1000
    Name      Rank       Ratio       Median    Mean      Min      Max      Stddev   Rounds
------------  ----  ---------------  -------  -------  -------  --------  --------  ------
table_concat  1     █         1.00x  3.92us   4us      3.79us   44.54us   405.89ns  224300
loop          2     ████████ 13.44x  52.62us  53.93us  52.12us  156.42us  3.11us    17791
```

## Technical Details

### Configuration

LuaMark provides several configuration options that can be set globally:

- `max_iterations`: Maximum number of iterations per round (default: 1e6)
- `min_rounds`: Minimum number of rounds to run (default: 100)
- `max_rounds`: Maximum number of rounds to run (default: 1e6)
- `warmups`: Number of warmup rounds before measurement (default: 1)

Modify these settings directly:

```lua
local luamark = require("luamark")

-- Increase minimum rounds for more statistical reliability
luamark.min_rounds = 1000

-- Adjust warmup rounds
luamark.warmups = 5
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
