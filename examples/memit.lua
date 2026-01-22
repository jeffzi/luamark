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

-- Stats has a readable __tostring
print(stats)
-- Example output: 8.1kB ± 141.23B per iter (100 rounds × 1 iter)

-- Access individual stats fields (values are in kilobytes)
print(string.format("Mean: %s", luamark.humanize_memory(stats.mean)))
print(string.format("Median: %s", luamark.humanize_memory(stats.median)))
print(string.format("Min: %s", luamark.humanize_memory(stats.min)))
print(string.format("Max: %s", luamark.humanize_memory(stats.max)))
print(string.format("Rounds: %d", stats.rounds))
print(string.format("Iterations per round: %d", stats.iterations))

-- ============================================================================
-- Example 2: memit with setup/teardown
-- ============================================================================
-- In memit API, hooks receive no params argument

print("\n=== memit with setup/teardown ===")
local stats_with_setup = luamark.memit(function(ctx)
   local result = ""
   for i = 1, #ctx.strings do
      result = result .. ctx.strings[i]
   end
end, {
   setup = function()
      -- setup receives no arguments
      local strings = {}
      for i = 1, 100 do
         strings[i] = tostring(i)
      end
      return { strings = strings } -- returned value becomes ctx in benchmark function
   end,
   teardown = function(ctx)
      -- teardown receives only ctx in memit API
      print(string.format("Concatenated %d strings", #ctx.strings))
   end,
})
print(stats_with_setup)
