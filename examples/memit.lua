-- Memory Benchmarking
-- Use memit for benchmarking a single function's memory allocation

local luamark = require("luamark")

-- ============================================================================
-- Example 1: Basic memit usage
-- ============================================================================

local function allocate_strings(n)
   local t = {}
   for i = 1, n do
      t[i] = string.rep("x", 100)
   end
   return t
end

-- memit returns Stats directly for a single function
print("=== Basic memit ===")
local stats = luamark.memit(function()
   allocate_strings(1000)
end, { rounds = 100 })

-- Stats has a readable __tostring (compact format)
print(stats)
-- Example output: 138.19kB ± 0B

-- Use render() for detailed key-value format
print("\n=== Detailed output with render() ===")
print(luamark.render(stats))
-- Example output:
-- Median: 138.19kB
-- CI: 138.19kB - 138.19kB (± 0B)
-- Rounds: 100
-- Total: 13.5MB

-- ============================================================================
-- Example 2: memit with setup/teardown
-- ============================================================================
-- In memit API, hooks receive no params argument

print("\n=== memit with setup/teardown ===")
local stats_with_setup = luamark.memit(function(ctx)
   local result = ""
   for i = 1, #ctx do
      result = result .. ctx[i]
   end
end, {
   setup = function()
      -- setup receives no arguments, returns ctx for benchmark function
      local strings = {}
      for i = 1, 100 do
         strings[i] = tostring(i)
      end
      return strings
   end,
   teardown = function(ctx)
      -- teardown receives only ctx in memit API
      print(string.format("Concatenated %d strings", #ctx))
   end,
})
print(stats_with_setup)
