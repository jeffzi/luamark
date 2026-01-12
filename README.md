# LuaMark

[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![Busted](https://github.com/jeffzi/luamark/actions/workflows/busted.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/busted.yml)
[![Luacheck](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml)
[![Luarocks](https://img.shields.io/luarocks/v/jeffzi/luamark?label=Luarocks&logo=Lua)](https://luarocks.org/modules/jeffzi/luamark)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

LuaMark is a lightweight, portable microbenchmarking library for the Lua programming
language. It provides precise measurement of both execution time and memory usage through
a simple yet powerful interface. Whether you're optimizing performance bottlenecks or
validating code improvements, LuaMark offers the tools you need with minimal setup overhead.

## Features

- **Single File, Zero Dependencies**: Drop [luamark.lua](src/luamark.lua) into your
  project and start benchmarking. No external dependencies required.
- **Enhanced Precision** (optional): Automatically leverages installed libraries for
  better accuracy when available:
  - Time: [Chronos][chronos], [LuaPosix][luaposix], or [LuaSocket][luasocket]
  - Memory: [AllocSpy][allocspy]
- **Comprehensive Statistics**: Detailed performance insights including minimum,
  maximum, mean, median, and standard deviation
- **Zero Configuration**: Start benchmarking immediately with sensible defaults while
  retaining full configurability

[chronos]: https://github.com/ldrumm/chronos
[luaposix]: https://github.com/luaposix/luaposix
[luasocket]: https://github.com/lunarmodules/luasocket
[allocspy]: https://github.com/siffiejoe/lua-allocspy

## Requirements

- Lua 5.1, 5.2, 5.3, 5.4, LuaJIT 2.1 or Luau

No other dependencies. LuaMark works out of the box with `os.clock` and Lua's built-in
memory tracking. Install optional libraries for enhanced precision:

- [chronos], [luaposix], or [luasocket] for timing (see
  [Clock Precision Hierarchy](#clock-precision-hierarchy))
- [AllocSpy][allocspy] for memory tracking

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

-- Get the summary as a markdown table
local md = luamark.summarize(time_stats, "markdown")
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

### Suite API

Compare multiple implementations across operations and parameter values with untimed setup:

```lua
local luamark = require("luamark")

-- Compare table operations at different sizes
local results = luamark.suite({
   insert = {
      array = function() data[#data + 1] = 1 end,
      table_insert = function() table.insert(data, 1) end,

      opts = {
         params = { n = { 100, 1000, 10000 } },
         setup = function(p)
            -- Untimed: create table with initial size
            data = {}
            for i = 1, p.n do data[i] = i end
         end,
      },
   },
   concat = {
      loop = function()
         local s = ""
         for i = 1, #data do s = s .. data[i] end
      end,
      table_concat = function() table.concat(data) end,

      opts = {
         params = { n = { 10, 100, 1000 } },
         setup = function(p)
            data = {}
            for i = 1, p.n do data[i] = tostring(i) end
         end,
      },
   },
})

-- Display results
print(luamark.summarize(results, "plain"))

-- Export to CSV
local csv = luamark.summarize(results, "csv")
local f = io.open("results.csv", "w")
f:write(csv)
f:close()

-- Access individual stats
local loop_100 = results.concat.loop.n[100]
print(loop_100.median)  -- median time for loop concat with n=100
```

Key features:

- **Untimed setup/teardown**: Generate test data without affecting timing
- **Parameter expansion**: Cartesian product of all parameter values
- **Nested results**: `results[operation][impl].param[value]` → Stats

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
3. The time for each round is divided by the number of iterations to get the average
   execution time
4. Statistics are computed across all rounds

For example, with 1000 iterations and 100 rounds:

- Your code runs 1000 times within each round
- This process repeats 100 times
- Total executions = 1000 \* 100 = 100,000 times

This approach solves several problems:

- **Clock Granularity**: By running multiple iterations per round, we can measure very
  fast operations accurately even with low-precision clocks
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

1. **[chronos]**

   - Nanosecond precision
   - Cross-platform compatibility
   - Recommended for most use cases

2. **[luaposix]**

   - High precision on supported platforms
   - Note: Not available on MacOS

3. **[LuaSocket][luasocket]**

   - Fallback option with good precision
   - Wide platform support

4. **Standard os.clock**
   - Default fallback
   - Platform-dependent precision

### Memory Tracking

LuaMark provides built-in Lua memory monitoring and can achieve higher precision through
[AllocSpy][allocspy] when available.

## API Documentation

For detailed API information, please refer to the [API Documentation](docs/api.md).

## Contributing

Contributions to LuaMark are welcome and appreciated. Whether you're fixing bugs,
improving documentation, or proposing new features, your help makes LuaMark better.

## License

LuaMark is released under the [MIT License](LICENSE).
