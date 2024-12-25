# LuaMark

[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![Busted](https://github.com/jeffzi/luamark/actions/workflows/busted.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/busted.yml)
[![Luacheck](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml)
[![Luarocks](https://img.shields.io/luarocks/v/jeffzi/luamark?label=Luarocks&logo=Lua)](https://luarocks.org/modules/jeffzi/luamark)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

LuaMark is a lightweight, portable microbenchmarking library for the Lua programming language. It provides precise measurement of both execution time and memory usage through a simple yet powerful interface. Whether you're optimizing performance bottlenecks or validating code improvements, LuaMark offers the tools you need with minimal setup overhead.

## Features

- **Time and Memory Measurement**: High-precision execution timing and memory allocation tracking
  - Time: Increase timing precision with [Chronos](https://github.com/chronos-timetravel/chronos), [LuaPosix](https://github.com/luaposix/luaposix), or [LuaSocket](https://github.com/lunarmodules/luasocket)
  - Memory: Enhance allocation tracking accuracy using [AllocSpy](https://github.com/siffiejoe/lua-allocspy)
- **High-Precision Time Measurement**: Measure code execution time with configurable precision through multiple clock modules
- **Memory Usage Tracking**: Monitor memory allocation patterns and footprint of Lua functions
- **Comprehensive Statistics**: Get detailed performance insights including minimum, maximum, mean, median, and standard deviation
- **Zero Configuration**: Start benchmarking immediately with sensible defaults while retaining full configurability
- **Flexible Clock Support**: Choose from multiple high-precision clock modules including [chronos](https://github.com/chronos-timetravel/chronos), [luaposix](https://github.com/luaposix/luaposix), and [LuaSocket](https://github.com/diegonehab/luasocket)
- **Advanced Memory Tracking**: Built-in memory tracking with optional enhanced precision through [AllocSpy](https://github.com/siffiejoe/lua-allocspy)

## Requirements

- Lua 5.1, 5.2, 5.3, 5.4, LuaJIT 2.1 or Luau
- Optional: [chronos](https://github.com/ldrumm/chronos), [luaposix](https://github.com/luaposix/luaposix), or [LuaSocket](https://github.com/lunarmodules/luasocket) for enhanced timing precision
- Optional: [AllocSpy](https://github.com/siffiejoe/lua-allocspy) for enhanced memory tracking

## Installation

Install LuaMark using [LuaRocks](https://luarocks.org/):

```shell
luarocks install luamark
```

Alternatively, you can manually include [luamark.lua](src/luamark.lua) in your project.

## Usage

### Basic Time Measurement

Here's a simple example measuring factorial function performance:

```lua
local luamark = require("luamark")

function factorial(n)
   if n == 0 then
      return 1
   else
      return n * factorial(n - 1)
   end
end

-- Compare different input sizes
local time_stats = luamark.timeit({
   ["n=1"] = function()
      factorial(1)
   end,
   ["n=15"] = function()
      factorial(15)
   end,
})

-- Results can be accessed as a table
print(type(time_stats))  -- "table"

-- Or displayed via string conversion
print(time_stats)
-- Output:
-- Name  Rank  Ratio  Median   Mean     Min     Max     Stddev   Rounds
-- ----  ----  -----  ------  -------  -----  -------  --------  -------
-- n=1   1     1.00   83ns    68.17ns  1ns    15.75us  83.98ns   1000000
-- n=15  2     4.52   375ns   380.5ns  208ns  21.42us  202.67ns  1000000
```

### Single Function Timing

Measure a single function with custom rounds:

```lua
local time_stats = luamark.timeit(function()
   factorial(10)
end, { rounds = 10 })

print(time_stats)
-- Output: 42ns ± 23ns per round (10 rounds)
```

### Memory Usage Measurement

Track memory allocations:

```lua
local mem_stats = luamark.memit(function()
   local tbl = {}
   for i = 1, 100 do
      tbl[i] = i
   end
end)

-- Results can be accessed as a table
print(type(mem_stats))  -- "table"

-- Or displayed via string conversion
print(mem_stats)
-- Output: 2.06kB ± 0B per round (533081 rounds)
```

## Technical Details

### Configuration

LuaMark provides several configuration options that can be set globally:

- `max_iterations`: Maximum number of iterations per round (default: 1e6)
- `min_rounds`: Minimum number of rounds to run (default: 100)
- `max_rounds`: Maximum number of rounds to run (default: 1e6)
- `warmups`: Number of warmup rounds before measurement (default: 1)

You can modify these settings directly through the LuaMark instance:

```lua
local luamark = require("luamark")

-- Increase minimum rounds for more statistical reliability
luamark.min_rounds = 1000

-- Adjust warmup rounds
luamark.warmups = 5
```

### Understanding Iterations and Rounds

LuaMark uses a two-level measurement system to ensure accurate timing:

#### How Measurement Works

1. Each measurement consists of multiple rounds
2. Each round runs the code multiple times (iterations)
3. The time for each round is divided by the number of iterations to get the average execution time
4. Statistics are computed across all rounds

For example, with 1000 iterations and 100 rounds:

- Your code runs 1000 times within each round
- This process repeats 100 times
- Total executions = 1000 \* 100 = 100,000 times

This approach solves several problems:

- **Clock Granularity**: By running multiple iterations per round, we can measure very fast operations accurately even with low-precision clocks
- **Statistical Reliability**: Multiple rounds provide enough data points for meaningful statistics
- **System Variability**: The two-level structure helps filter out system noise

Configuration example:

```lua
luamark.timeit(function()
   -- Your code here
end, {
   iterations = 1000,  -- Code executions per round
   rounds = 100       -- Number of rounds
})
```

### Clock Precision Hierarchy

LuaMark automatically selects the best available clock module in this order:

1. **[chronos](https://github.com/ldrumm/chronos)**

   - Nanosecond precision
   - Cross-platform compatibility
   - Recommended for most use cases

2. **[luaposix](https://github.com/luaposix/luaposix)**

   - High precision on supported platforms
   - Note: Not available on MacOS

3. **[LuaSocket](https://github.com/lunarmodules/luasocket)**

   - Fallback option with good precision
   - Wide platform support

4. **Standard os.clock**
   - Default fallback
   - Platform-dependent precision

### Memory Tracking

LuaMark provides built-in Lua memory monitoring and can achieve higher precision through [AllocSpy](https://github.com/siffiejoe/lua-allocspy) when available.

## API Documentation

For detailed API information, please refer to the [API Documentation](docs/api.md).

## Contributing

Contributions to LuaMark are welcome and appreciated. Whether you're fixing bugs, improving documentation, or proposing new features, your help makes LuaMark better.

## License

LuaMark is released under the [MIT License](LICENSE).
