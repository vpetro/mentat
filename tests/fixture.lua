local M = {}
local uv = vim.uv or vim.loop

M.catalog = {
  { provider = "openai", id = "reasoner", name = "Reasoner", reasoning = true },
  { provider = "openai", id = "plain", name = "Plain", reasoning = false },
  { provider = "anthropic", id = "large", name = "Large", reasoning = true },
  { provider = "anthropic", id = "legacy", name = "Legacy", reasoning = true },
}

function M.new()
  local f = {
    root = vim.fn.tempname(),
    jobs = {},
    commands = {},
    sent = {},
    held = {},
    hold = {},
    fail = {},
    sessions = {},
    clients = {},
    tasks = {},
    cleanups = {},
    patches = {},
    notices = {},
    catalog = vim.deepcopy(M.catalog),
    default = { model = M.catalog[3], thinkingLevel = "high" },
    clock = nil,
    next_session = 0,
  }
  vim.fn.mkdir(f.root .. "/.git", "p")
  f.root = uv.fs_realpath(f.root)
  local originals = {}
  for _, name in ipairs({ "executable", "jobstart", "jobstop", "chansend" }) do
    originals[name] = vim.fn[name]
  end
  local notify = vim.notify
  local hrtime = uv.hrtime
  local ui_select = vim.ui.select
  local ui_input = vim.ui.input
  vim.notify = function(message, level)
    table.insert(f.notices, { message = message, level = level })
    if f.on_notify then
      f.on_notify(message)
    end
  end
  uv.hrtime = function()
    return f.clock or hrtime()
  end
  vim.fn.executable = function()
    return f.missing_executable and 0 or 1
  end

  function f.patch(object, key, replacement)
    local original = object[key]
    f.patches[#f.patches + 1] = function() object[key] = original end
    object[key] = replacement
    return original
  end

  function f.cleanup(action)
    f.cleanups[#f.cleanups + 1] = action
  end

  function f.task(work)
    local task = vim.async.run(work)
    f.tasks[#f.tasks + 1] = task
    return task
  end

  function f.levels(model)
    if not model or model == vim.NIL then
      return { "off", "medium", "high" }
    end
    if not model.reasoning then
      return { "off" }
    end
    if model.id == "large" then
      return { "off", "high", "max" }
    end
    return { "off", "low", "medium", "high" }
  end

  local function new_state(selection)
    f.next_session = f.next_session + 1
    local state = vim.deepcopy(selection or f.default)
    state.sessionId = tostring(f.next_session)
    state.sessionFile = f.root .. "/session-" .. state.sessionId .. ".jsonl"
    state.isStreaming = false
    state.isCompacting = false
    state.messageCount = state.messageCount or 0
    return state
  end

  function f.persist(state)
    if type(state.sessionFile) == "string" then
      f.sessions[state.sessionFile] = vim.deepcopy(state)
      vim.fn.writefile({ vim.json.encode({ type = "session", id = state.sessionId }) }, state.sessionFile)
    end
  end

  function f.seed(model, thinking)
    local state = new_state({ model = model, thinkingLevel = thinking, messageCount = 4 })
    f.persist(state)
    return state.sessionFile
  end

  function f.emit(id, event, tail)
    local job = assert(f.jobs[id])
    if event.type == "agent_start" then
      job.state.isStreaming = true
    elseif event.type == "agent_settled" then
      job.state.isStreaming = false
      job.state.isCompacting = false
      job.state.messageCount = job.state.messageCount + 2
      f.persist(job.state)
    elseif event.type == "compaction_start" then
      job.state.isCompacting = true
    elseif event.type == "compaction_end" then
      job.state.isCompacting = false
    end
    job.options.on_stdout(id, { vim.json.encode(event), tail or "" })
  end

  function f.reply(id, command, data, err, tail)
    f.emit(id, {
      type = "response", id = command.id, command = command.type,
      success = err == nil, error = err, data = data,
    }, tail)
  end

  function f.dispatch(id, command)
    local job = f.jobs[id]
    local state = job.state
    local err = f.fail[command.type]
    if type(err) == "function" then
      err = err(job, command)
    end
    if err then
      f.reply(id, command, nil, err)
      return
    end
    local data
    if command.type == "get_state" then
      data = vim.deepcopy(state)
    elseif command.type == "get_available_models" then
      data = { models = f.catalog }
    elseif command.type == "get_available_thinking_levels" then
      data = { levels = f.levels(state.model) }
    elseif command.type == "get_commands" then
      data = { commands = {} }
    elseif command.type == "set_model" then
      local model
      for _, candidate in ipairs(f.catalog) do
        if candidate.provider == command.provider and candidate.id == command.modelId then
          model = candidate
        end
      end
      if not model then
        f.reply(id, command, nil, "Model not found")
        return
      end
      state.model = vim.deepcopy(model)
      state.thinkingLevel = model.id == "large" and "high" or (model.reasoning and "medium" or "off")
      f.emit(id, { type = "thinking_level_changed", level = state.thinkingLevel })
      data = model
      f.persist(state)
    elseif command.type == "set_thinking_level" then
      local levels = f.levels(state.model)
      state.thinkingLevel = vim.tbl_contains(levels, command.level) and command.level or levels[#levels]
      f.emit(id, { type = "thinking_level_changed", level = state.thinkingLevel })
      f.persist(state)
    elseif command.type == "prompt" then
      table.insert(f.sent, { job = id, message = command.message, model = vim.deepcopy(state.model), thinking = state.thinkingLevel })
      state.isStreaming = not f.handled
    elseif command.type == "abort" then
      f.emit(id, {
        type = "message_end", message = { role = "assistant", provider = state.model.provider, model = state.model.id, content = {}, stopReason = "aborted" },
      })
      f.emit(id, { type = "agent_settled" })
    elseif command.type == "new_session" then
      if f.cancel_session then
        data = { cancelled = true }
      else
        job.state = new_state()
        if job.no_session then
          job.state.sessionFile = vim.NIL
        end
        data = { cancelled = false }
      end
    elseif command.type == "switch_session" then
      if f.cancel_session then
        data = { cancelled = true }
      elseif f.sessions[command.sessionPath] then
        job.state = vim.deepcopy(f.sessions[command.sessionPath])
        data = { cancelled = false }
      else
        f.reply(id, command, nil, "Session not found")
        return
      end
    elseif command.type == "clone" then
      if f.cancel_session then
        data = { cancelled = true }
      else
        job.state = new_state(state)
        f.persist(job.state)
        data = { cancelled = false }
      end
    elseif command.type == "extension_ui_response" then
      return
    else
      error("Unexpected RPC command: " .. command.type)
    end
    local tail = f.tail and f.tail(id, command) or nil
    f.reply(id, command, data, nil, tail)
  end

  vim.fn.jobstart = function(args, options)
    if f.start_error then
      return -1
    end
    local session_file
    local no_session = false
    for index, arg in ipairs(args) do
      if arg == "--session" then
        session_file = args[index + 1]
      elseif arg == "--no-session" then
        no_session = true
      end
    end
    local id = #f.jobs + 1
    local saved = session_file and f.sessions[session_file]
    if session_file and not saved and vim.fn.filereadable(session_file) == 1 then
      local ok, header = pcall(vim.json.decode, vim.fn.readfile(session_file, "", 1)[1] or "")
      if ok and type(header) == "table" then
        for _, candidate in pairs(f.sessions) do
          if candidate.sessionId == header.id then
            saved = vim.deepcopy(candidate)
            saved.sessionFile = session_file
            break
          end
        end
      end
    end
    local state = saved and vim.deepcopy(saved) or new_state()
    if no_session then
      state.sessionFile = vim.NIL
    end
    f.jobs[id] = { options = options, args = args, state = state, no_session = no_session }
    return id
  end
  vim.fn.jobstop = function(id)
    f.jobs[id].stopped = true
    return 1
  end
  vim.fn.chansend = function(id, payload)
    if f.send_error then
      return 0
    end
    local command = vim.json.decode(payload)
    table.insert(f.commands, { job = id, command = command })
    if f.hold[command.type] then
      table.insert(f.held, { job = id, command = command })
    else
      f.dispatch(id, command)
    end
    return #payload
  end

  function f.release(kind)
    for index, entry in ipairs(f.held) do
      if entry.command.type == kind then
        table.remove(f.held, index)
        f.dispatch(entry.job, entry.command)
        return true
      end
    end
    return false
  end

  function f.exit(id, code)
    f.jobs[id].options.on_exit(id, code or 1)
  end

  function f.flush()
    local drained = false
    vim.defer_fn(function() drained = true end, 25)
    vim.wait(1000, function() return drained end, 1)
  end

  function f.wait(predicate)
    local expired = false
    local timer = vim.defer_fn(function() expired = true end, 2000)
    vim.wait(3000, function() return predicate() or expired end, 1)
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    assert(not expired and predicate(), "Timed out waiting for fixture")
  end

  function f.await(start)
    local result
    local accepted, err = start(function(...)
      result = { n = select("#", ...), ... }
    end)
    assert(accepted, err)
    f.wait(function() return result ~= nil end)
    return unpack(result, 1, result.n)
  end

  function f.client(config)
    local client = require("mentat.transports.pi_rpc").new()
    table.insert(f.clients, client)
    if config then
      local ok, err = f.await(function(done) return client.ensure_started(config, done) end)
      assert(ok, err)
    end
    return client
  end

  function f.count(kind, from)
    local count = 0
    for index = from or 1, #f.commands do
      if f.commands[index].command.type == kind then
        count = count + 1
      end
    end
    return count
  end

  function f.start_message(id)
    local state = f.jobs[id].state
    f.emit(id, { type = "agent_start" })
    f.emit(id, { type = "message_start", message = { role = "assistant", provider = state.model.provider, model = state.model.id, content = {} } })
  end

  function f.text(id, text)
    f.emit(id, { type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = text } })
  end

  function f.finish(id, text, reason)
    local state = f.jobs[id].state
    f.emit(id, { type = "message_end", message = {
      role = "assistant", provider = state.model.provider, model = state.model.id,
      content = { { type = "text", text = text or "" } }, stopReason = reason or "stop",
    } })
    f.emit(id, { type = "agent_end", messages = {}, willRetry = false })
    f.emit(id, { type = "agent_settled" })
  end

  function f.complete(id, text)
    f.start_message(id)
    f.text(id, text or "answer")
    f.finish(id, text or "answer")
    f.flush()
  end

  function f.ui(config)
    package.loaded["mentat.editor_bridge"] = { get_env = function() return {} end, stop = function() end }
    local mentat = require("mentat")
    mentat.repo_root = f.root
    mentat.get_system_prompt = function() return nil end
    mentat.setup(config or {
      provider = "openai", model = "reasoner", thinking = "medium",
      slots = { quick = { provider = "anthropic", model = "legacy", thinking = "low", label = "Quick" }, big = { model = "anthropic/large", thinking = "max", label = "Big" } },
    })
    local editor = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(editor, f.root .. "/example.lua")
    vim.api.nvim_win_set_buf(0, editor)
    vim.api.nvim_set_option_value("winbar", "editor winbar", { win = 0, scope = "local" })
    vim.g.loaded_mentat = nil
    dofile("plugin/mentat.lua")
    return mentat, require("mentat.buffer"), editor
  end

  function f.press(buf, lhs)
    vim.api.nvim_set_current_buf(buf)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if mapping.lhs == lhs then
        mapping.callback()
        return
      end
    end
    error("Missing mapping: " .. lhs)
  end

  function f.draft(buf, text)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last_sep = 0
    for index, line in ipairs(lines) do
      if line == "---" then
        last_sep = index
      end
    end
    vim.api.nvim_buf_set_lines(buf, last_sep, -1, false, vim.split(text, "\n", { plain = true }))
  end

  function f.content(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  function f.picker(command)
    local picker
    vim.ui.select = function(items, options, callback)
      picker = { items = items, options = options, choose = callback }
    end
    vim.cmd(command)
    f.wait(function() return picker ~= nil end)
    return picker
  end

  function f.close()
    for _, task in ipairs(f.tasks) do
      task:close()
    end
    for index = #f.cleanups, 1, -1 do
      f.cleanups[index]()
    end
    if package.loaded["mentat.editor_bridge"] then
      package.loaded["mentat.editor_bridge"].stop()
    end
    for _, client in ipairs(f.clients) do
      client.stop()
    end
    if package.loaded["mentat.transports.pi_rpc"] then
      package.loaded["mentat.transports.pi_rpc"].stop()
    end
    vim.cmd("silent! only!")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == "nofile" or vim.api.nvim_buf_get_name(buf):sub(1, #f.root) == f.root then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    for id, job in ipairs(f.jobs) do
      if not job.stopped then
        f.exit(id)
      end
    end
    f.wait(function() return vim.async._inspect_tree() == "" end)
    f.flush()
    for index = #f.patches, 1, -1 do
      f.patches[index]()
    end
    for name, original in pairs(originals) do
      vim.fn[name] = original
    end
    vim.notify = notify
    uv.hrtime = hrtime
    vim.ui.select = ui_select
    vim.ui.input = ui_input
    for name in pairs(package.loaded) do
      if name == "mentat" or name:match("^mentat%.") then
        package.loaded[name] = nil
      end
    end
    for _, name in ipairs({ "MentatRuntime", "MentatSession", "MentatModels", "MentatEditorBridge", "MentatReview" }) do
      if vim.fn.exists("#" .. name) == 1 then
        vim.api.nvim_del_augroup_by_name(name)
      end
    end
    vim.fn.delete(f.root, "rf")
  end

  return f
end

return M
