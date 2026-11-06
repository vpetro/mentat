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

require("async")(test, eq, contains)
require("lsp")(test, eq, contains)
require("bridge")(test, eq, contains)
require("transport")(test, eq, contains)
require("transport_async")(test, eq, contains)
require("operation")(test, eq, contains)
require("ui")(test, eq, contains)
require("workflows")(test, eq, contains)

local failed = 0
for _, item in ipairs(tests) do
  local handles = {}
  vim.uv.walk(function(handle) handles[handle] = true end)
  local f = fixture.new()
  vim.v.errmsg = ""
  local ok, err = xpcall(function()
    item.run(f)
    eq(vim.v.errmsg, "", "Neovim reported an asynchronous error")
  end, debug.traceback)
  local cleaned, cleanup_err = xpcall(function()
    f.close()
    eq(vim.async._inspect_tree(), "", "Async tasks remained after cleanup")
    local active = {}
    vim.uv.walk(function(handle)
      if not handles[handle] and handle:is_active() then
        active[#active + 1] = tostring(handle)
      end
    end)
    eq(active, {}, "Active libuv handles remained after cleanup")
    eq(vim.v.errmsg, "", "Neovim reported an asynchronous cleanup error")
  end, debug.traceback)
  if not cleaned then
    ok = false
    err = (err and (err .. "\n") or "") .. cleanup_err
  end
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
