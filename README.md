# LuaMark

LuaMark is a lightweight, portable microbenchmarking library designed for the Lua programming language. It provides a simple yet powerful interface for measuring the performance of your Lua code, whether it's execution time or memory usage. LuaMark is ideal for developers looking to optimize their Lua applications by identifying performance bottlenecks and verifying the impact of optimizations.

## Features

- **Time Measurement**: Accurately measure the time taken for code execution.
- **Memory Usage Tracking**: Evaluate the memory footprint of your Lua functions.
- **Statistical Analysis**: Get detailed statistical insights such as min, max, mean, and standard deviation for your benchmarks.
- **Configurable Benchmarks**: Tailor benchmark runs to your needs, including the number of runs, warm-up iterations, and garbage collection control for precise and consistent results.

## Installation

To install LuaMark using [LuaRocks](https://luarocks.org/), run the following command:

```shell
luarocks install luamark
```

## Usage

For a quick start, here's how to use LuaMark:

```lua
luamark = require("luamark")

local function func()
   arr = {}
   for i = 1, 100 do
      arr[i] = math.sin(i)
   end
end

local time_samples = luamark.timeit(func, 10)
local mem_samples = luamark.memit(func, 10)

local time_stats = luamark.calculate_stats(time_samples)
local mem_stats = luamark.calculate_stats(mem_samples)

print(luamark.format_time_stats(time_stats))
print(luamark.format_mem_stats(mem_stats))
-- 0.00000560 s ± 0.00000072 s per run (mean ± std. dev. of 10 runs)
-- 2.06250000 kb ± 0.00000000 kb per run (mean ± std. dev. of 10 runs)

```

## API Documentation

For more detailed information about LuaMark's API, please refer to the [API Documentation](docs/api.md).

## Contributing

Contributions to LuaMark are welcome! Whether it's adding new features, fixing bugs, or improving documentation, your help is appreciated.

## License

LuaMark is released under the [MIT License](LICENSE).
