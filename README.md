[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![Busted](https://github.com/jeffzi/luamark/actions/workflows/busted.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/busted.yml)
[![Luacheck](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml/badge.svg)](https://github.com/jeffzi/luamark/actions/workflows/luacheck.yml)
[![GitHub tag (latest SemVer)](https://img.shields.io/github/v/tag/lunarmodules/busted?label=Tag&logo=GitHub)](https://github.com/lunarmodules/busted/releases)
[![Luarocks](https://img.shields.io/luarocks/v/jeffzi/luamark?label=Luarocks&logo=Lua)](https://luarocks.org/modules/jeffzi/luamark)

# LuaMark

LuaMark is a lightweight, portable microbenchmarking library designed for the Lua programming language. It provides a simple yet powerful interface for measuring the performance of your Lua code, whether it's execution time or memory usage. LuaMark is ideal for developers looking to optimize their Lua applications by identifying performance bottlenecks and verifying the impact of optimizations.

## Features

- **Time Measurement**: Accurately measure the time taken for code execution.
- **Memory Usage Tracking**: Evaluate the memory footprint of your Lua functions.
- **Statistical Analysis**: Get detailed statistical insights such as min, max, mean, and standard deviation for your benchmarks.
- **Configurable Benchmarks**: Tailor benchmark runs to your needs, including the number of runs and warm-up iterations for precise and consistent results.
- **Support for Multiple Clock Modules**: LuaMark supports a range of clock modules like [Chronos](https://github.com/ldrumm/chronos), [LuaPosix](https://github.com/luaposix/luaposix), and [LuaSocket](https://github.com/lunarmodules/luasocket), offering flexibility and enhanced precision in time measurement.

## Installation

To install LuaMark using [LuaRocks](https://luarocks.org/), run the following command:

```shell
luarocks install luamark
```

## Usage

For a quick start, here's how to use LuaMark:

```lua
local luamark = require("luamark")

function factorial(n)
   if n == 0 then
      return 1
   else
      return n * factorial(n - 1)
   end
end

local time_stats = luamark.timeit({
   ["n=1"] = function()
      factorial(1)
   end,
   ["n=15"] = function()
      factorial(15)
   end,
})
luamark.print_summary(time_stats)

-- Name  Rank  Ratio  Min            Max            Mean           Stddev         Median         Rounds  Iterations
-- ----  ----  -----  -------------  -------------  -------------  -------------  -------------  ------  ----------
-- n=1   1     1.00   0.000000083 s  0.000000375 s  0.000000175 s  0.000000123 s  0.000000125 s  5       1
-- n=15  2     2.19   0.000000375 s  0.000000417 s  0.000000383 s  0.000000019 s  0.000000375 s  5       1
-- 0.000000254 s ±0.000000037 s per round (10 rounds)

local time_stats = luamark.timeit(function()
   factorial(10)
end, 10)
print(time_stats)
-- 0.000000254 s ± 0.000000037 s per round (10 rounds)

local mem_stats = luamark.memit(function()
   local tbl = {"hello", "world"}
end)
print(mem_stats)
-- 0.0938 kb ± 0 kb per round (5 rounds)

```

## Understanding Iterations and Rounds in Time Measurement

In LuaMark, the `timeit` function employs a combination of _iterations_ and _rounds_ to accurately measure execution times, addressing the granularity issue of system clocks. An _iteration_ refers to the number of times the code is executed in a single round, while a _round_ is one of the multiple individual trials in which these iterations occur. System clocks often have limited precision, which can make it challenging to measure very short durations accurately. By executing the code multiple times (iterations) within a round and repeating this across several rounds, LuaMark can average the results, effectively reducing the impact of any single measurement's inaccuracies due to clock granularity.

This method ensures more reliable and precise measurements, especially for quick operations. Iterations help in smoothing out quick variations in execution time, whereas rounds provide a broader base for statistical analysis, enhancing the overall accuracy of the benchmark. Importantly, if not specified manually, LuaMark configures the optimal number of iterations and rounds automatically. For a more detailed understanding of how iterations and rounds improve timing benchmarks, refer to this [Pytest Benchmark Documentation](https://pytest-benchmark.readthedocs.io/en/latest/calibration.html).

## Clock Precision and Supported Modules in LuaMark

LuaMark optimizes timing accuracy by supporting various Lua modules for high-precision clock functionality. The library selects the most suitable module based on availability and platform compatibility, following this priority order:

1. **Chronos**: Offers nanosecond precision and is compatible across all platforms, making it the most recommended choice for precise benchmarking. [Chronos Project](https://github.com/ldrumm/chronos)

2. **LuaPosix**: Provides a reliable alternative if Chronos is not available. Note that LuaPosix's `posix.time.clock_gettime` does not support MacOS and will be skipped on such systems. [LuaPosix Project](https://github.com/luaposix/luaposix)

3. **LuaSocket**: Another option if neither Chronos nor LuaPosix is available. [LuaSocket Project](https://github.com/lunarmodules/luasocket)

4. **Standard os.clock**: This is the default option used if none of the above modules are detected. However, installing an external module like Chronos or LuaPosix is recommended for higher resolution clocks, as `os.clock` offers limited precision.

Users are encouraged to install either Chronos or LuaPosix (considering platform compatibility) to achieve the most accurate timing benchmarks, especially in critical high-resolution timing scenarios.

## API Documentation

For more detailed information about LuaMark's API, please refer to the [API Documentation](docs/api.md).

## Contributing

Contributions to LuaMark are welcome! Whether it's adding new features, fixing bugs, or improving documentation, your help is appreciated.

## License

LuaMark is released under the [MIT License](LICENSE).
