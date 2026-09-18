return function(test, eq, contains)
  local setup = require("lsp_fixture")

  test("LSP awaits synchronous callback setup without cancelling successful requests", function(f)
    local lsp = setup(f)
    lsp.clients[1].synchronous = { contents = { value = "hover text" } }
    local task = f.task(function()
      return require("mentat.lsp").execute("lsp_hover", { path = lsp.path, line = 1, col = 7 }, f.root)
    end)
    eq(task:wait(1000), "hover text")
    eq(lsp.requests[1].params.position, { line = 0, character = 6 })
    eq(lsp.cancelled, {})
  end)

  test("LSP aggregates clients and error tuples while unrelated tasks keep progressing", function(f)
    local lsp = setup(f, 2)
    local completions = 0
    local task = f.task(function()
      return require("mentat.lsp").request(lsp.buf, "textDocument/hover", {}, 1000)
    end)
    task:on_complete(function() completions = completions + 1 end)
    f.wait(function() return #lsp.requests == 2 end)
    lsp.reply(1, nil, { code = -1, message = "server error" })
    lsp.reply(1, { contents = "duplicate" })
    local other = f.task(function()
      vim.async.sleep(1)
      return vim.api.nvim_buf_line_count(lsp.buf)
    end)
    eq(other:wait(1000), 2)
    eq(task:completed(), false)
    lsp.reply(2, { contents = "second client" })
    local result = task:wait(1000)
    eq(result[1].err.message, "server error")
    eq(result[1].result, nil)
    eq(result[2].result.contents, "second client")
    eq(completions, 1)
    eq(lsp.cancelled, {})
  end)

  test("LSP methods with no supporting clients finish without sending a request", function(f)
    local lsp = setup(f)
    lsp.clients[1].methods = {}
    local task = f.task(function()
      return require("mentat.lsp").execute("lsp_hover", { path = lsp.path, line = 1, col = 1 }, f.root)
    end)
    contains(task:wait(1000), "No hover info")
    eq(#lsp.requests, 0)
    lsp.clients = {}
    task = f.task(function()
      return require("mentat.lsp").execute("lsp_definition", { path = lsp.path, line = 1, col = 1 }, f.root)
    end)
    contains(task:wait(1000), "No LSP client attached")
  end)

  test("LSP clients that stop during dispatch do not leave aggregation waiting", function(f)
    local lsp = setup(f, 2)
    lsp.clients[1].reject = true
    lsp.clients[2].synchronous = { contents = "remaining client" }
    local result = f.task(function()
      return require("mentat.lsp").request(lsp.buf, "textDocument/hover", {}, 100)
    end):wait(1000)
    contains(result[1].err.message, "stopped before dispatch")
    eq(result[2].result.contents, "remaining client")
    eq(#lsp.cancelled, 0)
  end)

  test("real LSP deadlines cancel only unfinished requests and ignore late responses", function(f)
    local lsp = setup(f, 2)
    lsp.clients[1].synchronous = { contents = "first" }
    local task = f.task(function()
      return require("mentat.lsp").request(lsp.buf, "textDocument/hover", {}, 10)
    end)
    local result, err = task:wait(1000)
    eq(result, nil)
    eq(err, "timeout")
    eq(lsp.cancelled, { { client = 2, id = 2 } })
    lsp.reply(2, { contents = "too late" })
    f.flush()
    eq(#lsp.cancelled, 1)
  end)

  test("disposing an LSP task cancels requests once and suppresses late results", function(f)
    local lsp = setup(f, 2)
    local task = f.task(function()
      require("mentat.lsp").request(lsp.buf, "textDocument/hover", {}, 1000)
      error("Disposed LSP task resumed")
    end)
    f.wait(function() return #lsp.requests == 2 end)
    task:close()
    eq(task:pwait(1000), false)
    eq(#lsp.cancelled, 2)
    lsp.reply(1, { contents = "late" })
    lsp.reply(2, nil, { message = "late error" })
    task:close()
    f.flush()
    eq(#lsp.cancelled, 2)
  end)

  test("LSP definition, references, and symbol tools retain result formatting", function(f)
    local lsp = setup(f)
    local location = { uri = vim.uri_from_fname(lsp.path), range = { start = { line = 1, character = 3 } } }
    local cases = {
      { "lsp_definition", "textDocument/definition", location, "Definition(s) (1):\n  source.lua:2:4" },
      { "lsp_references", "textDocument/references", { location }, "References (1):\n  source.lua:2:4" },
      { "lsp_document_symbols", "textDocument/documentSymbol", { { name = "answer", kind = 13, range = location.range } }, "Symbols in " .. lsp.path .. ":\n[Variable] answer  (line 2)" },
      { "lsp_workspace_symbols", "workspace/symbol", { { name = "answer", kind = 13, location = location } }, 'Workspace symbols matching "answer" (1):\n[Variable] answer  @ source.lua:2:4' },
    }
    vim.api.nvim_set_current_buf(lsp.buf)
    for index, entry in ipairs(cases) do
      local task = f.task(function()
        return require("mentat.lsp").execute(entry[1], { path = lsp.path, line = 1, col = 1, query = "answer" }, f.root)
      end)
      f.wait(function() return #lsp.requests == index end)
      eq(lsp.requests[index].method, entry[2])
      lsp.reply(index, entry[3])
      eq(task:wait(1000), entry[4])
    end
  end)

  test("call hierarchy preparation and follow-up await separate sequential requests", function(f)
    local lsp = setup(f)
    local item = { name = "answer", kind = 12, uri = vim.uri_from_fname(lsp.path), selectionRange = { start = { line = 1, character = 0 } } }
    for index, direction in ipairs({ "incoming", "outgoing" }) do
      local first = (index - 1) * 2 + 1
      local task = f.task(function()
        return require("mentat.lsp").execute("lsp_" .. direction .. "_calls", { path = lsp.path, line = 1, col = 1 }, f.root)
      end)
      f.wait(function() return #lsp.requests == first end)
      eq(lsp.requests[first].method, "textDocument/prepareCallHierarchy")
      f.flush()
      eq(#lsp.requests, first)
      lsp.reply(first, { item })
      f.wait(function() return #lsp.requests == first + 1 end)
      eq(lsp.requests[first + 1].method, "callHierarchy/" .. direction .. "Calls")
      eq(lsp.requests[first + 1].params.item, item)
      lsp.reply(first + 1, { { from = item, to = item } })
      contains(task:wait(1000), "[Function] answer  @ source.lua:2")
    end
  end)

  test("cold diagnostic lookups load the buffer and preserve native BufReadPost events", function(f)
    local path = f.root .. "/cold.lua"
    vim.fn.writefile({ "return 42" }, path)
    local reads = 0
    local autocmd = vim.api.nvim_create_autocmd("BufReadPost", {
      pattern = path,
      callback = function() reads = reads + 1 end,
    })
    f.cleanup(function() vim.api.nvim_del_autocmd(autocmd) end)
    eq(vim.fn.bufnr(path), -1)
    local lsp = require("mentat.lsp")
    eq(lsp.execute("lsp_diagnostics", { path = path }, f.root), "No diagnostics for " .. path)
    eq(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(path)), true)
    eq(reads, 1)
    lsp.execute("lsp_diagnostics", { path = path }, f.root)
    eq(reads, 1)
  end)
end
