local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.cmd.cd(root)
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local fixture = require("fixture")
local tests = {}
local function test(name, run)
  table.insert(tests, { name = name, run = run })
end
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or "Values differ") .. "\nactual: " .. vim.inspect(actual) .. "\nexpected: " .. vim.inspect(expected))
end
local function contains(text, part)
  assert(type(text) == "string" and text:find(part, 1, true), "Expected " .. vim.inspect(text) .. " to contain " .. vim.inspect(part))
end

require("transport")(test, eq, contains)
require("ui")(test, eq, contains)

local failed = 0
for _, item in ipairs(tests) do
  local f = fixture.new()
  vim.v.errmsg = ""
  local ok, err = xpcall(function()
    item.run(f)
    eq(vim.v.errmsg, "", "Neovim reported an asynchronous error")
  end, debug.traceback)
  f.close()
  if ok then
    io.stdout:write("PASS " .. item.name .. "\n")
  else
    failed = failed + 1
    io.stdout:write("FAIL " .. item.name .. "\n" .. err .. "\n")
  end
  io.stdout:flush()
end
io.stdout:write(string.format("%d passed, %d failed\n", #tests - failed, failed))
if failed > 0 then
  error("Mentat tests failed")
end
