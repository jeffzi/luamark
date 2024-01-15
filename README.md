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
   for i = 1, 1000 do
      arr[i] = math.sin(i)
   end
end

local time_stats = luamark.timeit(func)
local mem_stats = luamark.memit(func)

print(time_stats)
print(mem_stats)
-- 0.000045s ± 0.000004s per run
-- 16.0625kb ± 0.0000kb per run

```

## API Documentation

For more detailed information about LuaMark's API, please refer to the [API Documentation](docs/api.md).

## Contributing

Contributions to LuaMark are welcome! Whether it's adding new features, fixing bugs, or improving documentation, your help is appreciated.

## License

LuaMark is released under the [MIT License](LICENSE).
