-- Regression check: GCtrace allocations must not leak into memory measurements.
--
-- collectgarbage("count") includes LuaJIT GCtrace structs in its total.
-- Without mitigation, fn's loop compiles traces *inside*
-- measure_memory_once's collectgarbage delta, and the GCtrace structs (~1 KB)
-- appear as spurious memory allocations.
-- Workaround: call jit.off() before memory benchmarks (see docs/api.md).
--
-- Must run outside busted — LuaJIT does not compile traces in coroutines.
-- Run: lua tests/jit_trace_check.lua
-- Exit code: 0 = pass, 1 = bug present.

package.path = "src/?.lua;src/?/init.lua;" .. package.path

if type(jit) ~= "table" or not jit.status() then
   print("SKIP: requires LuaJIT with JIT enabled")
   os.exit(0)
end

_G._TEST = true
local luamark = require("luamark")

-- A zero-allocation fn with a hot loop (1000 iterations exceeds the JIT hot
-- counter of 56). The before hook triggers jit.flush() inside luamark,
-- clearing all compiled traces. Without warmup, fn's loop compiles traces
-- during the first measured round, and the GCtrace structs (~1 KB) appear
-- in the collectgarbage("count") delta.
local N = 1000
local funcs = {
   read_loop = {
      fn = function(ctx)
         local t = ctx.data
         local s = 0
         for i = 1, #t do
            s = s + t[i]
         end
      end,
      before = function()
         local t = {}
         for i = 1, N do
            t[i] = i
         end
         return { data = t }
      end,
   },
}

jit.off()
local results = luamark.compare_memory(funcs)
jit.on()
local median = results[1].median

if median > 0.0001 then
   print(string.format("FAIL: median %.4f KB (expected 0.0001 KB)", median))
   os.exit(1)
else
   print("OK: zero-allocation fn correctly reports floor")
   os.exit(0)
end
