return function(test, eq, contains)
  local function configured(f, timeout)
    return f.client({
      no_session = true,
      rpc_timeout_ms = timeout or 1000,
      default_selection = { provider = "openai", model = "reasoner", thinking = "medium" },
    })
  end

  test("two immediate sends reserve busy synchronously and never finish before view initialization", function(f)
    local client = configured(f)
    local initialized = false
    local completions = 0
    assert(client.prompt("first", nil, function()
      assert(initialized)
      completions = completions + 1
    end))
    eq(client.is_busy(), true)
    eq(client.prompt("second", nil, function() error("Rejected send completed") end), false)
    eq(completions, 0)
    initialized = true
    f.wait(function() return #f.sent == 1 end)
    f.complete(1)
    eq(completions, 1)
  end)

  test("stopping during busy notification defers completion until the caller initializes its view", function(f)
    local client = f.client()
    local initialized = false
    local completed
    local unsubscribe
    unsubscribe = client.subscribe(function(state)
      if state.busy then
        unsubscribe()
        client.stop("Stopped during reservation")
      end
    end)
    assert(client.prompt("first", nil, function(text, err, metadata)
      assert(initialized)
      completed = { text = text, err = err, metadata = metadata }
    end))
    eq(completed, nil)
    initialized = true
    f.wait(function() return completed ~= nil end)
    eq(completed.text, "")
    eq(completed.err, "Stopped during reservation")
    eq(completed.metadata.status, "error")
    eq(#f.jobs, 0)
  end)

  test("stopping an awaited listing reports its stable public error once and ignores late replies", function(f)
    local client = configured(f)
    f.hold.get_available_models = true
    local completions = 0
    local result
    local _, _, task = client.get_available_models(function(items, err)
      completions = completions + 1
      result = { items = items, err = err }
    end)
    f.wait(function() return #f.held == 1 end)
    client.stop("Stopped listing")
    f.wait(function() return completions == 1 end)
    eq(result.items, nil)
    eq(result.err, "Stopped listing")
    eq(task:pwait(1000), false)
    f.release("get_available_models")
    f.flush()
    eq(completions, 1)
    eq(client.is_busy(), false)
    eq(f.jobs[1].stopped, true)
  end)

  test("a timed-out acceptance probe fails closed even after agent_start arrives", function(f)
    local client = configured(f, 20)
    local dispatch = f.dispatch
    f.dispatch = function(id, command)
      if command.type == "prompt" then
        f.hold.get_state = true
      end
      return dispatch(id, command)
    end
    local result
    assert(client.prompt("question", nil, function(text, err, metadata)
      result = { text = text, err = err, metadata = metadata }
    end))
    f.wait(function() return #f.sent == 1 and #f.held == 1 end)
    f.start_message(1)
    f.wait(function() return result ~= nil end)
    contains(result.err, "RPC timed out: get_state")
    eq(result.metadata.status, "error")
    eq(client.is_busy(), false)
    eq(f.jobs[1].stopped, true)
    f.release("get_state")
    f.flush()
  end)

  test("agent_settled can finish and restore a prompt before its acknowledgement arrives", function(f)
    local client = configured(f)
    f.hold.prompt = true
    local completions = 0
    local result
    assert(client.prompt("question", nil, function(text, err, metadata)
      completions = completions + 1
      result = { text = text, err = err, metadata = metadata }
    end, { override = { model = "anthropic/large", thinking = "max" } }))
    f.wait(function() return #f.held == 1 end)
    f.complete(1, "answer before acknowledgement")
    f.wait(function() return result ~= nil end)
    eq(result.text, "answer before acknowledgement")
    eq(result.err, nil)
    eq(result.metadata.models[1].model, "large")
    eq(client.state.model.id, "reasoner")
    eq(client.state.thinking_level, "medium")
    f.release("prompt")
    f.flush()
    eq(completions, 1)
  end)

  test("an in-flight abort remains busy through one-shot settings restoration", function(f)
    local client = configured(f)
    local result
    assert(client.prompt("question", nil, function(_, err, metadata)
      result = { err = err, metadata = metadata }
    end, { override = { model = "anthropic/large", thinking = "max" } }))
    f.wait(function() return #f.sent == 1 end)
    f.start_message(1)
    f.flush()
    f.hold.set_model = true
    assert(client.abort())
    f.wait(function() return #f.held == 1 end)
    eq(result, nil)
    eq(client.is_busy(), true)
    f.hold.set_model = nil
    f.release("set_model")
    f.wait(function() return result ~= nil end)
    eq(result.err, "Pi request aborted")
    eq(result.metadata.status, "aborted")
    eq(client.state.model.id, "reasoner")
    eq(client.is_busy(), false)
  end)

  test("closing an operation task stops uncertain RPC work without treating cancellation as Pi abort", function(f)
    local client = configured(f)
    f.hold.set_model = true
    local result
    local _, _, task = client.prompt("question", nil, function(_, err, metadata)
      result = { err = err, metadata = metadata }
    end, { override = { model = "anthropic/large", thinking = "max" } })
    f.wait(function() return #f.held == 1 end)
    task:close()
    f.wait(function() return result ~= nil end)
    eq(result.err, "Pi operation cancelled")
    eq(result.metadata.status, "error")
    eq(f.count("abort"), 0)
    eq(f.jobs[1].stopped, true)
    eq(client.get_restore_selection(), { provider = "openai", model = "reasoner", thinking = "medium" })
    f.hold.set_model = nil
    assert(f.await(function(done) return client.ensure_started(nil, done) end))
    eq(client.get_selection(), { provider = "openai", model = "reasoner", thinking = "medium" })
    f.release("set_model")
    f.flush()
    eq(client.state.model.id, "reasoner")
  end)

  test("clone cancellation stops the scratch client and removes an unadopted known clone", function(f)
    local client = configured(f)
    local source = f.seed(f.catalog[4], "low")
    local dispatch = f.dispatch
    f.dispatch = function(id, command)
      if command.type == "clone" then
        f.hold.get_available_thinking_levels = true
      end
      return dispatch(id, command)
    end
    local result
    local _, _, task = client.clone_from(source, function(ok, err)
      result = { ok, err }
    end, { start_config = { repo_root = f.root, no_session = true } })
    f.wait(function() return f.count("clone") == 1 and #f.held == 1 end)
    local clone = f.jobs[2].state.sessionFile
    assert(clone ~= source)
    task:close()
    f.wait(function() return result ~= nil end)
    eq(result[1], false)
    eq(f.jobs[2].stopped, true)
    eq(vim.fn.filereadable(clone), 0)
    eq(vim.fn.filereadable(source), 1)
    f.release("get_available_thinking_levels")
    f.flush()
  end)

  test("cancelling clone startup never deletes a source path normalized by Pi", function(f)
    local client = configured(f)
    local source = f.seed(f.catalog[4], "low")
    local alias = vim.fn.fnamemodify(source, ":h") .. "/./" .. vim.fn.fnamemodify(source, ":t")
    f.sessions[alias] = vim.deepcopy(f.sessions[source])
    f.hold.get_available_thinking_levels = true
    local result
    local _, _, task = client.clone_from(alias, function(ok, err) result = { ok, err } end)
    f.wait(function() return #f.held == 1 end)
    task:close()
    f.wait(function() return result ~= nil end)
    eq(result[1], false)
    eq(f.count("clone"), 0)
    eq(vim.fn.filereadable(source), 1)
    f.release("get_available_thinking_levels")
    f.flush()
  end)

  test("a successful clone response cannot prepare or adopt an unchanged normalized source", function(f)
    local client = configured(f)
    local before = client.state.session_id
    local source = f.seed(f.catalog[4], "low")
    local alias = vim.fn.fnamemodify(source, ":h") .. "/./" .. vim.fn.fnamemodify(source, ":t")
    f.sessions[alias] = vim.deepcopy(f.sessions[source])
    local dispatch = f.dispatch
    f.dispatch = function(id, command)
      if command.type == "clone" then
        f.reply(id, command, { cancelled = false })
      else
        dispatch(id, command)
      end
    end
    local prepared
    local ok, err = f.await(function(done)
      return client.clone_from(alias, done, {
        prepare_clone = function(path) prepared = path end,
      })
    end)
    eq(ok, false)
    eq(err, "Pi did not create a cloned session file")
    eq(prepared, nil)
    eq(client.state.session_id, before)
    eq(f.count("switch_session"), 0)
    eq(vim.fn.filereadable(source), 1)
    eq(f.jobs[2].stopped, true)
  end)

  test("clone preparation failure removes its file without changing the source session", function(f)
    local client = configured(f)
    local before = client.state.session_id
    local source = f.seed(f.catalog[4], "low")
    local clone
    local ok, err = f.await(function(done)
      return client.clone_from(source, done, {
        start_config = { repo_root = f.root, no_session = true },
        prepare_clone = function(path)
          clone = path
          return "Could not prepare temporary session"
        end,
      })
    end)
    eq(ok, false)
    contains(err, "Could not prepare")
    eq(vim.fn.filereadable(clone), 0)
    eq(vim.fn.filereadable(source), 1)
    eq(client.state.session_id, before)
    eq(f.jobs[2].stopped, true)
  end)

  test("extension UI awaits choices and suppresses stale or cancelled input callbacks", function(f)
    local client = configured(f)
    local choice
    local input
    f.patch(vim.ui, "select", function(_, _, done) choice = done end)
    f.patch(vim.ui, "input", function(_, done) input = done end)
    f.emit(1, { type = "extension_ui_request", id = "select", method = "select", options = { "one" } })
    f.wait(function() return choice ~= nil end)
    choice("one")
    f.wait(function() return f.count("extension_ui_response") == 1 end)
    eq(f.commands[#f.commands].command.value, "one")
    choice = nil
    f.emit(1, { type = "extension_ui_request", id = "confirm", method = "confirm", title = "Sure?" })
    f.wait(function() return choice ~= nil end)
    choice("No")
    f.wait(function() return f.count("extension_ui_response") == 2 end)
    eq(f.commands[#f.commands].command.confirmed, false)
    f.emit(1, { type = "extension_ui_request", id = "input", method = "input" })
    f.wait(function() return input ~= nil end)
    assert(f.await(function(done) return client.set_thinking_level("low", done) end))
    input("stale")
    f.flush()
    eq(f.count("extension_ui_response"), 2)
    input = nil
    f.emit(1, { type = "extension_ui_request", id = "editor", method = "editor" })
    f.wait(function() return input ~= nil end)
    client.stop()
    input("after stop")
    f.flush()
    eq(f.count("extension_ui_response"), 2)
  end)
end
