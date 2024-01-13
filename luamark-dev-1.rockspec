package = "luamark"

local package_version = "dev"
local rockspec_revision = "1"

version = package_version .. "-" .. rockspec_revision

source = {
   url = "git+https://github.com/jeffzi/luamark.git",
}

if package_version == "dev" then
   source.branch = "main"
else
   source.tag = "v" .. package_version
end

description = {
   summary = "Human-friendly Lua code analysis powered by Lua Language Server.",
   detailed = [[
      LuaMark is a portable microbenchmarking library for Lua, offering precise measurement of
      execution time and memory usage.
   ]],
   homepage = "https://github.com/jeffzi/luamark",
   license = "MIT",
}

dependencies = {
   "lua >= 5.1",
   "socket >= 3.0.0",
}

build = {
   type = "builtin",
   modules = {
      luamark = "src/luamark.lua",
   },
}
