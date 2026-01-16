# LuaMark Examples

This directory contains example scripts demonstrating LuaMark's features.

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

- **[timeit.lua](timeit.lua)** - Compare function performance with different inputs
- **[single_function.lua](single_function.lua)** - Measure a single function with custom rounds
- **[memit.lua](memit.lua)** - Track memory allocations
- **[suite.lua](suite.lua)** - Suite API with groups, benchmarks, and parameters
