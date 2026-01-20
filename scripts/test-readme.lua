#!/usr/bin/env lua
-- Extract and run Lua code blocks from README.md
-- Usage: lua scripts/test-readme.lua [README.md]

local readme_path = arg[1] or "README.md"

local file = io.open(readme_path, "r")
if not file then
   io.stderr:write("Error: Cannot open " .. readme_path .. "\n")
   os.exit(1)
end

local content = file:read("*a")
file:close()

local snippets = {}
for block in content:gmatch("```lua\n(.-)\n```") do
   table.insert(snippets, block)
end

print(string.format("Found %d Lua code blocks in %s", #snippets, readme_path))

--- Check if a snippet should be skipped (config-only or incomplete).
--- @param snippet string Lua code snippet to check.
--- @return boolean
local function should_skip(snippet)
   local is_config_only = snippet:match("^luamark%.[%w_]+ = ") and not snippet:match("require")
   local is_incomplete = snippet:match("-- Your code here")
   return is_config_only or is_incomplete
end

--- Check if os.execute status indicates success.
--- @param status boolean|number Exit status (Lua 5.1 returns number, 5.2+ returns boolean).
--- @return boolean
local function check_exit_status(status)
   if type(status) == "boolean" then
      return status
   end
   return status == 0
end

--- Execute a Lua snippet and return the result.
--- @param snippet string Lua code to execute.
--- @return "pass"|"fail"|"skip"
local function run_snippet(snippet)
   local tmp_path = os.tmpname() .. ".lua"
   local tmp = io.open(tmp_path, "w")
   if not tmp then
      io.stderr:write(string.format("Error: Cannot open temp file %s\n", tmp_path))
      os.remove(tmp_path)
      return "skip"
   end

   tmp:write(snippet)
   tmp:close()

   local status = os.execute("lua " .. tmp_path .. " 2>&1")
   os.remove(tmp_path)

   if check_exit_status(status) then
      return "pass"
   end

   print("--- FAILED Snippet ---")
   print(snippet)
   print("----------------------")
   return "fail"
end

local passed, failed, skipped = 0, 0, 0

for i, snippet in ipairs(snippets) do
   if should_skip(snippet) then
      print(string.format("\n[%d/%d] SKIP (config/incomplete)", i, #snippets))
      skipped = skipped + 1
   else
      print(string.format("\n[%d/%d] Running snippet...", i, #snippets))
      local result = run_snippet(snippet)
      print(string.format("[%d/%d] %s", i, #snippets, result:upper()))

      if result == "pass" then
         passed = passed + 1
      elseif result == "fail" then
         failed = failed + 1
      else
         skipped = skipped + 1
      end
   end
end

print("\n=== Summary ===")
print(string.format("Passed:  %d", passed))
print(string.format("Failed:  %d", failed))
print(string.format("Skipped: %d", skipped))
print(string.format("Total:   %d", #snippets))

if failed > 0 then
   os.exit(1)
end
