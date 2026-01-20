# LuaMark Examples

Example scripts demonstrating LuaMark's features.

## Running Examples

From the project root directory:

```bash
# Set the Lua path to find the luamark module
LUA_PATH="src/?.lua;;" lua examples/<example>.lua

# Or run all examples
for f in examples/*.lua; do
    echo "=== $f ==="
    LUA_PATH="src/?.lua;;" lua "$f"
    echo
done
```

## Examples

| File | API | Description |
| ---- | --- | ----------- |
| [timeit.lua](timeit.lua) | `timeit` | Benchmark execution time |
| [memit.lua](memit.lua) | `memit` | Benchmark memory allocation |
| [compare_functions.lua](compare_functions.lua) | `compare_time`/`compare_memory` | Compare functions with `params` |
