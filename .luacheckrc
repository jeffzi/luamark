std = "min"
include_files = { "src", "tests" }
exclude_files = { "tests/defold" }
globals = {
   "_G",
   "jit", -- LuaJIT
   "warn", -- Lua 5.4+
}
max_comment_line_length = 200

files["tests/**/*.lua"] = {
   std = "+busted",
}

files["tests/jit_trace_check.lua"] = {
   std = "min",
}
