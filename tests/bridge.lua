return function(test, eq, contains)
  local uv = vim.uv
  local setup = require("lsp_fixture")

  local function connect(f, bridge, method, params, raw, eof)
    local client = uv.new_tcp()
    local result = { client = client, messages = {}, errors = {} }
    local text = raw or (vim.json.encode({ method = method, params = params or {} }) .. "\n")
    local buffer = ""
    f.cleanup(function()
      if not client:is_closing() then client:close() end
    end)
    client:connect(bridge.state.host, bridge.state.port, function(err)
      assert(not err, err)
      client:read_start(function(read_err, chunk)
        if read_err then result.errors[#result.errors + 1] = read_err end
        if not chunk then
          result.closed = true
          if not client:is_closing() then client:close() end
          return
        end
        buffer = buffer .. chunk
        while true do
          local newline = buffer:find("\n", 1, true)
          if not newline then break end
          result.messages[#result.messages + 1] = vim.json.decode(buffer:sub(1, newline - 1))
          buffer = buffer:sub(newline + 1)
        end
      end)
      client:write(text, function(write_err)
        assert(not write_err, write_err)
        if eof then
          client:shutdown(function(shutdown_err) assert(not shutdown_err, shutdown_err) end)
        end
      end)
    end)
    return result
  end

  test("the TCP bridge completes a second request while the first awaits LSP", function(f)
    local lsp = setup(f)
    vim.api.nvim_set_current_buf(lsp.buf)
    local bridge = require("mentat.editor_bridge")
    bridge.ensure_started(f.root)
    local hover = connect(f, bridge, "lsp_hover", { path = lsp.path, line = 1, col = 1 })
    f.wait(function() return #lsp.requests == 1 end)
    local ping = connect(f, bridge, "ping")
    f.wait(function() return #ping.messages == 1 end)
    eq(ping.messages[1], { ok = true, result = { content = "pong", details = { ok = true } } })
    eq(#hover.messages, 0)
    lsp.reply(1, { contents = "delayed hover" })
    f.wait(function() return #hover.messages == 1 and hover.closed and ping.closed end)
    eq(hover.messages[1].result.content, "delayed hover")
    eq(#lsp.cancelled, 0)
    eq(hover.errors, {})
  end)

  test("stopping the TCP bridge cancels connection tasks and never sends late results", function(f)
    local lsp = setup(f)
    local bridge = require("mentat.editor_bridge")
    bridge.ensure_started(f.root)
    local hover = connect(f, bridge, "lsp_hover", { path = lsp.path, line = 1, col = 1 })
    f.wait(function() return #lsp.requests == 1 end)
    bridge.stop()
    bridge.stop()
    f.wait(function() return #lsp.cancelled == 1 and hover.closed end)
    lsp.reply(1, { contents = "late" })
    f.flush()
    eq(#hover.messages, 0)
    eq(#lsp.cancelled, 1)
    eq(bridge.state.port, nil)
    bridge.ensure_started(f.root)
    local ping = connect(f, bridge, "ping")
    f.wait(function() return #ping.messages == 1 end)
    eq(ping.messages[1].ok, true)
  end)

  test("disconnected bridge clients cancel LSP and tolerate late callbacks without double close", function(f)
    local lsp = setup(f)
    local bridge = require("mentat.editor_bridge")
    bridge.ensure_started(f.root)
    local hover = connect(f, bridge, "lsp_hover", { path = lsp.path, line = 1, col = 1 })
    f.wait(function() return #lsp.requests == 1 end)
    hover.client:close()
    f.wait(function() return #lsp.cancelled == 1 end)
    lsp.reply(1, { contents = "late" })
    lsp.reply(1, nil, { message = "late error" })
    bridge.stop()
    f.flush()
    eq(#hover.messages, 0)
    eq(#lsp.cancelled, 1)
  end)

  test("bridge JSON errors, unknown methods, and EOF-delimited requests keep their protocol", function(f)
    local bridge = require("mentat.editor_bridge")
    bridge.ensure_started(f.root)
    local invalid = connect(f, bridge, nil, nil, "{broken}\n")
    local unknown = connect(f, bridge, "missing")
    local eof = connect(f, bridge, nil, nil, '{"method":"ping"}', true)
    f.wait(function() return #invalid.messages == 1 and #unknown.messages == 1 and #eof.messages == 1 end)
    eq(invalid.messages[1].ok, false)
    eq(invalid.messages[1].error, "Invalid JSON request")
    eq(unknown.messages[1].error, "Unknown method: missing")
    eq(eof.messages[1].result.content, "pong")
  end)

  test("bridge disk snapshots use async reads without losing formatting or blocking ping", function(f)
    local bridge = require("mentat.editor_bridge")
    local path = f.root .. "/disk.txt"
    vim.fn.writefile({ "first", "second", "third" }, path)
    local open = uv.fs_open
    local release
    f.patch(uv, "fs_open", function(name, flags, mode, done)
      if name == path then
        release = function() return open(name, flags, mode, done) end
        return {}
      end
      return open(name, flags, mode, done)
    end)
    bridge.ensure_started(f.root)
    local disk = connect(f, bridge, "current_buffer", { path = "disk.txt", offset = 2, limit = 1 })
    f.wait(function() return release ~= nil end)
    local ping = connect(f, bridge, "ping")
    f.wait(function() return #ping.messages == 1 end)
    eq(#disk.messages, 0)
    release()
    f.wait(function() return #disk.messages == 1 end)
    contains(disk.messages[1].result.content, "   2 | second")
    eq(disk.messages[1].result.details.line_count, 3)
  end)
end
