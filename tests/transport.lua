return function(test, eq, contains)
  local function configured(f)
    return f.client({
      no_session = true,
      default_selection = { provider = "openai", model = "reasoner", thinking = "medium" },
    })
  end

  local function submit(f, client, opts)
    local run = { chunks = {}, updates = {}, completions = 0 }
    local accepted, err = client.prompt("question", function(chunk)
      table.insert(run.chunks, chunk)
    end, function(text, rpc_err, metadata)
      run.completions = run.completions + 1
      run.text = text
      run.error = rpc_err
      run.metadata = metadata
    end, vim.tbl_extend("force", opts or {}, {
      on_metadata = function(metadata)
        table.insert(run.updates, metadata)
      end,
    }))
    assert(accepted, err)
    f.flush()
    return run
  end

  test("default and selected settings persist across normal prompts without a restart", function(f)
    local client = configured(f)
    eq(client.state.model.id, "reasoner")
    eq(client.state.thinking_level, "medium")
    local config = vim.deepcopy(require("mentat.transports.pi_rpc").config)
    local catalog = f.await(client.get_available_models)
    eq(#catalog, 4)
    eq(f.await(client.get_available_thinking_levels), { "off", "low", "medium", "high" })
    local from = #f.commands + 1
    local first = submit(f, client)
    eq(client.is_busy(), true)
    f.complete(1)
    eq(first.error, nil)
    eq(first.metadata.models, { { provider = "openai", model = "reasoner", thinking = "medium" } })
    eq(f.count("set_model", from), 0)
    eq(f.count("set_thinking_level", from), 0)
    assert(f.await(function(done) return client.set_model("anthropic", "legacy", done) end))
    assert(f.await(function(done) return client.set_thinking_level("low", done) end))
    from = #f.commands + 1
    for _ = 1, 2 do
      local run = submit(f, client)
      f.complete(1)
      eq(run.metadata.models[1], { provider = "anthropic", model = "legacy", thinking = "low" })
      eq(run.completions, 1)
    end
    eq(#f.jobs, 1)
    eq(f.count("set_model", from), 0)
    eq(f.count("set_thinking_level", from), 0)
    eq(require("mentat.transports.pi_rpc").config, config)
  end)

  test("restored sessions keep their selection and new sessions use configured defaults", function(f)
    local saved = f.seed(f.catalog[4], "low")
    local client = f.client({ session_file = saved, default_selection = { provider = "openai", model = "reasoner", thinking = "medium" } })
    eq(client.state.model.id, "legacy")
    eq(client.state.thinking_level, "low")
    eq(f.count("set_model"), 0)
    eq(f.count("set_thinking_level"), 0)
    local args = f.jobs[1].args
    for _, flag in ipairs({ "--model", "--provider", "--thinking" }) do
      eq(vim.tbl_contains(args, flag), false)
    end
    local run = submit(f, client)
    f.complete(1)
    eq(run.metadata.models[1].model, "legacy")
    assert(f.await(function(done) return client.new_session(done) end))
    eq(client.state.model.id, "reasoner")
    eq(client.state.thinking_level, "medium")
    eq(#f.jobs, 1)
    eq(client.state.session_file == saved, false)
  end)

  test("legacy presets resolve providers from the catalog without overwriting explicit defaults", function(f)
    local models = require("mentat.models")
    local config = {
      provider = "openai", model = "reasoner", thinking = "medium",
      slots = { quick = { model = "legacy", thinking = "low" }, big = { model = "large", thinking = "max" } },
    }
    eq(models.defaults(config), { provider = "openai", model = "reasoner", thinking = "medium" })
    eq(models.resolve(models.preset(config, "big"), f.catalog), { provider = "anthropic", model = "large", thinking = "max" })
    config.model = nil
    config.thinking = nil
    eq(models.resolve(models.defaults(config), f.catalog), { provider = "anthropic", model = "legacy", thinking = "low" })
    local client = f.client({ no_session = true, default_selection = models.defaults(config) })
    eq(client.state.model.id, "legacy")
    eq(client.state.thinking_level, "low")
    table.insert(f.catalog, { provider = "other", id = "legacy" })
    local _, err = models.resolve({ model = "legacy" }, f.catalog)
    contains(err, "ambiguous")
    eq(models.resolve({ model = "anthropic/large" }, f.catalog).provider, "anthropic")
    table.insert(f.catalog, { provider = "router", id = "vendor/model" })
    eq(models.resolve({ provider = "router", model = "vendor/model" }, f.catalog).model, "vendor/model")
  end)

  test("big is one request and remains busy until the selected settings are restored", function(f)
    local client = configured(f)
    assert(f.await(function(done) return client.set_thinking_level("low", done) end))
    local run = submit(f, client, { override = { model = "anthropic/large", thinking = "max" } })
    eq(f.sent[1].model.id, "large")
    eq(f.sent[1].thinking, "max")
    f.hold.set_model = true
    f.start_message(1)
    f.text(1, "big answer")
    f.finish(1, "big answer")
    f.flush()
    eq(run.completions, 0)
    eq(client.is_busy(), true)
    eq(client.state.model.id, "large")
    eq(client.get_selection(), { provider = "openai", model = "reasoner", thinking = "low" })
    eq(client.prompt("second", nil, function() error("Rejected callback") end), false)
    eq(client.set_thinking_level("high"), false)
    f.hold.set_model = nil
    assert(f.release("set_model"))
    f.wait(function() return run.completions == 1 end)
    eq(client.state.model.id, "reasoner")
    eq(client.state.thinking_level, "low")
    eq(run.metadata.models, { { provider = "anthropic", model = "large", thinking = "max" } })
    local normal = submit(f, client)
    f.complete(1)
    eq(normal.metadata.models[1], { provider = "openai", model = "reasoner", thinking = "low" })
    eq(#f.jobs, 1)
  end)

  test("model changes refresh actual thinking, supported levels, and partial failures", function(f)
    local client = configured(f)
    assert(f.await(function(done) return client.set_model("openai", "plain", done) end))
    eq(client.state.thinking_level, "off")
    eq(client.state.thinking_levels, { "off" })
    assert(f.await(function(done) return client.set_thinking_level("max", done) end))
    eq(client.state.thinking_level, "off")
    f.fail.set_model = "No API key"
    local ok, err = f.await(function(done) return client.set_model("anthropic", "large", done) end)
    eq(ok, false)
    contains(err, "No API key")
    eq(client.get_selection(), { provider = "openai", model = "plain", thinking = "off" })
    f.fail.set_model = function(job)
      job.state.model = f.catalog[4]
      job.state.thinkingLevel = "low"
      return "Extension failed after switching"
    end
    ok = f.await(function(done) return client.set_model("anthropic", "large", done) end)
    eq(ok, false)
    eq(client.get_selection(), { provider = "anthropic", model = "legacy", thinking = "low" })
    f.fail.set_model = nil
    f.fail.set_thinking_level = function(job)
      job.state.thinkingLevel = "off"
      return "Partial thinking failure"
    end
    ok = f.await(function(done) return client.set_thinking_level("high", done) end)
    eq(ok, false)
    eq(client.state.thinking_level, "off")
    f.fail.set_thinking_level = nil
    local run = submit(f, client)
    f.complete(1)
    eq(run.metadata.models[1], { provider = "anthropic", model = "legacy", thinking = "off" })
  end)

  test("unsupported levels are clamped and a failed refresh never invents a model label", function(f)
    local client = configured(f)
    assert(f.await(function(done) return client.set_model("anthropic", "large", done) end))
    eq(client.state.thinking_level, "high")
    assert(f.await(function(done) return client.set_thinking_level("medium", done) end))
    eq(client.state.thinking_level, "max")
    f.fail.set_model = function()
      f.fail.get_state = "State unavailable"
    end
    local ok, err = f.await(function(done) return client.set_model("openai", "reasoner", done) end)
    eq(ok, false)
    contains(err, "State unavailable")
    eq(client.state.model.id, "large")
    eq(client.state.thinking_level, "max")
    eq(client.get_selection(), { provider = "anthropic", model = "large", thinking = "max" })
    f.fail.get_state = nil
    f.fail.set_model = nil
    local state = f.await(client.get_state)
    eq(state.model.id, "reasoner")
  end)

  test("a request stays busy through preflight, tools, retry, and compaction until settlement", function(f)
    local client = configured(f)
    f.clock = 1000000000
    local run = submit(f, client)
    eq(client.set_model("openai", "plain"), false)
    eq(client.new_session(), false)
    eq(client.prompt("second"), false)
    eq(f.sent[1].model.id, "reasoner")
    f.start_message(1)
    f.clock = 2000000000
    f.emit(1, { type = "tool_execution_start", toolName = "bash", args = { command = "ls" } })
    f.flush()
    eq(#run.chunks, 1)
    eq(#run.updates, 1)
    eq(run.updates[1].first_text_ms, nil)
    f.emit(1, { type = "message_end", message = { role = "assistant", provider = "openai", model = "reasoner", content = {}, stopReason = "error", errorMessage = "overloaded" } })
    f.emit(1, { type = "agent_end", willRetry = true, messages = {} })
    f.emit(1, { type = "auto_retry_start", attempt = 1 })
    f.emit(1, { type = "compaction_start", reason = "overflow" })
    f.flush()
    eq(run.completions, 0)
    eq(client.is_busy(), true)
    eq(client.set_thinking_level("high"), false)
    f.emit(1, { type = "summarization_retry_scheduled" })
    f.emit(1, { type = "summarization_retry_attempt_start" })
    f.emit(1, { type = "summarization_retry_finished" })
    f.emit(1, { type = "compaction_end", willRetry = true, result = {}, aborted = false })
    f.emit(1, { type = "auto_retry_end", success = true })
    f.start_message(1)
    f.clock = 3000000000
    f.text(1, "  ")
    f.flush()
    eq(run.updates[#run.updates].first_text_ms, nil)
    f.clock = 3500000000
    f.text(1, "answer")
    f.flush()
    eq(run.updates[#run.updates].first_text_ms, 2500)
    f.clock = 5000000000
    f.emit(1, { type = "agent_end", willRetry = false, messages = {} })
    f.flush()
    eq(run.completions, 0)
    f.clock = 8000000000
    f.finish(1, "  answer")
    f.flush()
    eq(run.completions, 1)
    eq(run.error, nil)
    eq(run.metadata.status, "complete")
    eq(run.metadata.first_text_ms, 2500)
    eq(run.metadata.total_ms, 7000)
    f.emit(1, { type = "agent_settled" })
    f.flush()
    eq(run.completions, 1)
  end)

  test("no text, final errors, aborted runs, and compaction failure have distinct outcomes", function(f)
    local client = configured(f)
    local no_text = submit(f, client)
    f.start_message(1)
    f.emit(1, { type = "tool_execution_start", toolName = "read", args = { path = "file" } })
    f.finish(1, "")
    f.flush()
    eq(no_text.metadata.first_text_ms, nil)
    eq(no_text.metadata.status, "complete")
    local failed = submit(f, client)
    f.start_message(1)
    f.finish(1, "", "error")
    f.flush()
    eq(failed.metadata.status, "error")
    eq(failed.error, "Pi returned an error")
    local aborted = submit(f, client)
    f.start_message(1)
    f.flush()
    assert(client.abort())
    f.flush()
    eq(aborted.metadata.status, "aborted")
    eq(aborted.completions, 1)
    local compacted = submit(f, client)
    f.start_message(1)
    f.emit(1, { type = "compaction_start", reason = "threshold" })
    f.emit(1, { type = "compaction_end", errorMessage = "Compaction quota exceeded", aborted = false })
    f.finish(1, "")
    f.flush()
    eq(compacted.metadata.status, "error")
    contains(compacted.error, "quota exceeded")
  end)

  test("authoritative message text is displayed and timed when there were no deltas", function(f)
    local client = configured(f)
    f.clock = 1000000000
    local run = submit(f, client)
    f.start_message(1)
    f.flush()
    f.clock = 2200000000
    f.finish(1, "non-streamed answer")
    f.flush()
    eq(run.text, "non-streamed answer")
    eq(run.metadata.first_text_ms, 1200)
    eq(run.metadata.total_ms, 1200)
  end)

  test("thinking changes for the next message do not relabel a previous response", function(f)
    local client = configured(f)
    local run = submit(f, client)
    f.start_message(1)
    f.flush()
    f.jobs[1].state.thinkingLevel = "off"
    f.emit(1, { type = "thinking_level_changed", level = "off" })
    f.finish(1, "answer")
    f.flush()
    eq(run.metadata.models, { { provider = "openai", model = "reasoner", thinking = "medium" } })
    eq(client.state.thinking_level, "off")
    local next_run = submit(f, client)
    f.complete(1)
    eq(next_run.metadata.models, { { provider = "openai", model = "reasoner", thinking = "off" } })
  end)

  test("missing auth/model, JSON null, and rejected prompts complete without a false label", function(f)
    f.default = { model = vim.NIL, thinkingLevel = "off", sessionFile = vim.NIL, sessionName = vim.NIL }
    local client = f.client({ no_session = true })
    eq(client.state.model, nil)
    eq(client.state.session_file, nil)
    eq(client.state.session_name, nil)
    local missing = submit(f, client)
    f.wait(function() return missing.completions == 1 end)
    eq(missing.metadata.models, {})
    eq(missing.metadata.first_text_ms, nil)
    eq(missing.metadata.status, "error")
    eq(#f.sent, 0)
    local ok, err = f.await(function(done) return client.set_model("missing", "absent", done) end)
    eq(ok, false)
    contains(err, "unavailable")
    assert(f.await(function(done) return client.set_model("openai", "reasoner", done) end))
    f.fail.prompt = "Authentication failed"
    local rejected = submit(f, client)
    f.wait(function() return rejected.completions == 1 end)
    eq(rejected.error, "Authentication failed")
    eq(rejected.metadata.models, {})
    eq(rejected.metadata.status, "error")
  end)

  test("startup and process failures finish a preparing request exactly once", function(f)
    local client = f.client()
    f.missing_executable = true
    local missing = submit(f, client)
    eq(missing.completions, 1)
    contains(missing.error, "executable not found")
    eq(client.is_busy(), false)
    f.missing_executable = false
    f.start_error = true
    local start = submit(f, client)
    eq(start.completions, 1)
    contains(start.error, "Failed to start")
    f.start_error = false
    f.hold.get_state = true
    local preparing = submit(f, client)
    eq(preparing.completions, 0)
    eq(client.is_busy(), true)
    f.exit(1, 17)
    f.flush()
    eq(preparing.completions, 1)
    contains(preparing.error, "code 17")
    eq(preparing.metadata.status, "error")
    eq(client.is_busy(), false)
    f.exit(1, 17)
    f.release("get_state")
    f.flush()
    eq(preparing.completions, 1)
  end)

  test("real Neovim RPC timers can expire and be cleaned without double-close", function(f)
    local client = f.client()
    f.hold.get_state = true
    local completions = 0
    local ok, err = f.await(function(done)
      return client.ensure_started({ no_session = true, rpc_timeout_ms = 10 }, function(...)
        completions = completions + 1
        done(...)
      end)
    end)
    eq(ok, false)
    contains(err, "RPC timed out: get_state")
    eq(completions, 1)
    eq(client.is_busy(), false)
    eq(f.jobs[1].stopped, true)
    f.release("get_state")
    f.flush()
    eq(completions, 1)
  end)

  test("callback-triggered restart ignores trailing stdout and old process events", function(f)
    local client = f.client()
    f.tail = function(id, command)
      return id == 1 and command.type == "get_available_thinking_levels" and '{"type":' or ""
    end
    local result
    local opts = { no_session = true, rpc_timeout_ms = 100 }
    assert(client.ensure_started(opts, function(ok, err)
      assert(ok, err)
      client.stop()
      assert(client.ensure_started(opts, function(restarted, restart_err)
        result = { restarted, restart_err }
      end))
    end))
    f.wait(function() return result ~= nil end)
    eq(result[1], true)
    eq(#f.jobs, 2)
    local selected = client.get_selection()
    f.emit(1, { type = "thinking_level_changed", level = "off" })
    f.exit(1, 99)
    f.flush()
    eq(client.get_selection(), selected)
    eq(client.state.ready, true)
  end)

  test("callback-triggered restart also discards trailing stderr", function(f)
    local client = configured(f)
    local result
    f.on_notify = function()
      f.on_notify = nil
      client.stop()
      assert(client.ensure_started(nil, function(ok, err)
        result = { ok, err }
      end))
    end
    f.jobs[1].options.on_stderr(1, { "restart now", "old stderr tail" })
    f.wait(function() return result ~= nil end)
    eq(result[1], true)
    f.hold.get_state = true
    local run = submit(f, client)
    f.exit(2, 9)
    f.flush()
    contains(run.error, "code 9")
    eq(run.error:find("old stderr tail", 1, true), nil)
  end)

  test("failed override restoration is retried before the next normal prompt", function(f)
    local client = configured(f)
    local run = submit(f, client, { override = { provider = "anthropic", model = "large", thinking = "max" } })
    f.fail.set_model = "No API key during restore"
    f.complete(1)
    eq(run.completions, 1)
    eq(run.metadata.models[1].model, "large")
    contains(run.error, "restore")
    eq(client.state.model.id, "large")
    eq(client.get_selection().model, "reasoner")
    eq(client.get_restore_selection().thinking, "medium")
    f.fail.set_model = nil
    local next_run = submit(f, client)
    eq(f.sent[#f.sent].model.id, "reasoner")
    eq(f.sent[#f.sent].thinking, "medium")
    f.complete(1)
    eq(next_run.error, nil)
    eq(client.get_restore_selection(), nil)
  end)

  test("a process exit during big keeps the normal selection for restart", function(f)
    local client = configured(f)
    assert(f.await(function(done) return client.set_thinking_level("low", done) end))
    local run = submit(f, client, { override = { model = "anthropic/large", thinking = "max" } })
    f.exit(1, 2)
    f.flush()
    eq(run.completions, 1)
    eq(run.metadata.status, "error")
    assert(f.await(function(done) return client.ensure_started(nil, done) end))
    eq(client.state.model.id, "reasoner")
    eq(client.state.thinking_level, "low")
    eq(#f.jobs, 2)
    local normal = submit(f, client)
    f.complete(2)
    eq(normal.metadata.models[1].model, "reasoner")
  end)

  test("preflight abort and handled input do not leave a request busy", function(f)
    local client = configured(f)
    f.hold.prompt = true
    local run = submit(f, client)
    assert(client.abort())
    eq(client.is_busy(), false)
    eq(run.completions, 1)
    eq(run.metadata.status, "aborted")
    f.hold.prompt = nil
    assert(f.await(function(done) return client.ensure_started(nil, done) end))
    f.handled = true
    local handled = submit(f, client)
    eq(handled.completions, 1)
    eq(handled.metadata.status, "handled without a response")
    eq(handled.metadata.first_text_ms, nil)
    eq(client.is_busy(), false)
    f.release("prompt")
    f.flush()
    eq(run.completions, 1)
  end)

  test("session commands reject work discovered during the state refresh", function(f)
    local client = configured(f)
    for _, field in ipairs({ "isStreaming", "isCompacting" }) do
      f.jobs[1].state[field] = true
      local from = #f.commands + 1
      local ok, err = f.await(function(done) return client.new_session(done) end)
      eq(ok, false)
      contains(err, "already processing")
      eq(f.count("new_session", from), 0)
      eq(f.count("set_model", from), 0)
      eq(f.count("set_thinking_level", from), 0)
      eq(client.is_busy(), true)
      f.emit(1, { type = "agent_settled" })
      f.flush()
      eq(client.is_busy(), false)
    end
  end)

  test("cloning a saved conversation preserves its selection without replacing the source", function(f)
    local client = f.client({ repo_root = f.root, default_selection = { provider = "openai", model = "reasoner", thinking = "medium" } })
    local source = f.seed(f.catalog[4], "low")
    local source_state = vim.deepcopy(f.sessions[source])
    local opts = { start_config = { repo_root = f.root, default_selection = { provider = "openai", model = "reasoner", thinking = "medium" } } }
    assert(f.await(function(done) return client.clone_from(source, done, opts) end))
    eq(client.get_selection(), { provider = "anthropic", model = "legacy", thinking = "low" })
    eq(client.state.session_file == source, false)
    eq(f.sessions[source], source_state)
    eq(#f.jobs, 2)
    eq(f.jobs[2].stopped, true)
    local previous = client.state.session_file
    f.cancel_session = true
    local ok, err = f.await(function(done) return client.clone_from(source, done, opts) end)
    eq(ok, false)
    contains(err, "cancelled")
    eq(client.state.session_file, previous)
    eq(client.is_busy(), false)
    eq(f.jobs[3].stopped, true)
  end)

  test("cancelled session changes preserve confirmed selection and session", function(f)
    local client = configured(f)
    local selection = client.get_selection()
    local session = client.state.session_id
    f.cancel_session = true
    local ok, err = f.await(function(done) return client.new_session(done) end)
    eq(ok, false)
    contains(err, "cancelled")
    eq(client.get_selection(), selection)
    eq(client.state.session_id, session)
    local saved = f.seed(f.catalog[4], "low")
    ok = f.await(function(done) return client.switch_session(saved, done) end)
    eq(ok, false)
    eq(client.state.session_id, session)
    f.cancel_session = false
    assert(f.await(function(done) return client.switch_session(saved, done) end))
    eq(client.state.model.id, "legacy")
    eq(client.state.thinking_level, "low")
    eq(#f.jobs, 1)
  end)
end
