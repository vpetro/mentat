local models = require("mentat.models")
local uv = vim.uv or vim.loop
local M = {}

M.config = {
  cmd = "pi",
  offline = true,
  no_session = false,
  no_extensions = false,
  extensions = {},
  no_skills = false,
  skills = {},
  no_prompt_templates = false,
  prompt_templates = {},
  no_themes = false,
  themes = {},
  no_tools = false,
  env = {},
  extra_args = {},
  rpc_timeout_ms = 30000,
}

local function value(item)
  if item ~= vim.NIL then
    return item
  end
end

local function comparable_config(config)
  local result = vim.deepcopy(config or {})
  result.session_file = nil
  return result
end

local function line_consumer(buffer, data, handler)
  for index, chunk in ipairs(data or {}) do
    if index == 1 then
      buffer = buffer .. chunk
    else
      if buffer ~= "" then
        handler(buffer)
      end
      buffer = chunk
    end
  end
  return buffer
end

local function resolve_path(path, root)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return path:match("^/") and path or root .. "/" .. path
end

local function command_line(config)
  local root = config.repo_root or uv.cwd()
  local args = { config.cmd, "--mode", "rpc" }
  for _, option in ipairs({ "offline", "no_session", "no_extensions", "no_skills", "no_prompt_templates", "no_themes", "no_tools" }) do
    if config[option] then
      table.insert(args, "--" .. option:gsub("_", "-"))
    end
  end
  for _, option in ipairs({ "system_prompt", "append_system_prompt" }) do
    if config[option] then
      vim.list_extend(args, { "--" .. option:gsub("_", "-"), config[option] })
    end
  end
  if not config.no_session then
    local dir = resolve_path(config.session_dir, root)
    if dir then
      vim.fn.mkdir(dir, "p")
      vim.list_extend(args, { "--session-dir", dir })
    end
    local path = resolve_path(config.session_file, root)
    if path then
      vim.list_extend(args, { "--session", path })
    end
  end
  for _, entry in ipairs({
    { "extensions", "--extension" },
    { "skills", "--skill" },
    { "prompt_templates", "--prompt-template" },
    { "themes", "--theme" },
  }) do
    for _, path in ipairs(config[entry[1]] or {}) do
      vim.list_extend(args, { entry[2], resolve_path(path, root) or path })
    end
  end
  if not config.no_tools and config.tools and config.tools ~= "" then
    vim.list_extend(args, { "--tools", config.tools })
  end
  vim.list_extend(args, config.extra_args or {})

  local env = vim.deepcopy(config.env or {})
  if config.agent_dir then
    local dir = resolve_path(config.agent_dir, root)
    vim.fn.mkdir(dir, "p")
    env.PI_CODING_AGENT_DIR = dir
  end
  return args, env, root
end

local function text_content(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts)
end

local function tool_summary(name, args)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local arg = type(args) == "table" and (args.path or args.pattern or args.command or args.query or args.ref) or nil
  if arg then
    return string.format("\n\n> *%s: %s*\n\n", name, tostring(arg))
  end
  return string.format("\n\n> *%s*\n\n", name)
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function joined_error(first, second)
  if first and second then
    return first .. "; " .. second
  end
  return first or second
end

local function new_client()
  local client = { state = { busy = false, ready = false, revision = 0, is_streaming = false, is_compacting = false } }
  local state = client.state
  local job_id
  local generation = 0
  local next_id = 0
  local pending = {}
  local operation
  local active_config
  local last_config
  local stdout_buffer = ""
  local stderr_buffer = ""
  local listeners = {}
  local needs_defaults = false
  local selection_error
  local restore_selection
  local resume_selection
  local terminate
  local settle_prompt

  local function changed()
    for listener in pairs(listeners) do
      listener(state)
    end
  end

  function client.subscribe(listener)
    listeners[listener] = true
    return function()
      listeners[listener] = nil
    end
  end

  function client.is_busy()
    return operation ~= nil or state.is_streaming or state.is_compacting
  end

  function client.get_selection()
    return vim.deepcopy(restore_selection or state.selection)
  end

  function client.get_restore_selection()
    return vim.deepcopy(restore_selection)
  end

  function client.restore_settings(selection)
    if client.is_busy() then
      return false, "Pi is busy"
    end
    restore_selection = vim.deepcopy(selection)
    state.revision = state.revision + 1
    return true
  end

  local function update_state(data)
    if type(data) ~= "table" then
      return false, "Pi returned invalid state"
    end
    local model = value(data.model)
    if model ~= nil and type(model) ~= "table" then
      return false, "Pi returned an invalid model"
    end
    if not vim.deep_equal(state.model, model) then
      state.thinking_levels = nil
    end
    state.model = vim.deepcopy(model)
    state.thinking_level = value(data.thinkingLevel)
    state.session_file = value(data.sessionFile)
    state.session_id = value(data.sessionId)
    state.session_name = value(data.sessionName)
    state.message_count = value(data.messageCount)
    state.is_streaming = data.isStreaming == true
    state.is_compacting = data.isCompacting == true
    state.ready = true
    if not restore_selection then
      state.selection = models.from_state(state)
    end
    changed()
    return true
  end

  local function finish(op, ...)
    if operation ~= op then
      return
    end
    operation = nil
    for id, entry in pairs(pending) do
      if entry.op == op then
        close_timer(entry.timer)
        pending[id] = nil
      end
    end
    if op.cleanup then
      op.cleanup()
    end
    state.busy = false
    changed()
    op.on_done(...)
  end

  local function finish_prompt(op, err, status)
    local prompt = op.prompt
    prompt.metadata.total_ms = prompt.metadata.total_ms or (uv.hrtime() - prompt.started) / 1e6
    prompt.metadata.status = status or (err and "error" or "complete")
    finish(op, prompt.text, err, vim.deepcopy(prompt.metadata))
  end

  local function begin(kind, on_done)
    if client.is_busy() then
      return nil, "Pi is busy; wait for the current operation to settle"
    end
    local op = { kind = kind, on_done = on_done or function() end }
    op.fail = function(err, status)
      if op.prompt then
        finish_prompt(op, err, status)
      else
        finish(op, false, err)
      end
    end
    operation = op
    state.busy = true
    state.revision = state.revision + 1
    changed()
    return op
  end

  local function schedule(op, action)
    vim.schedule(function()
      if operation == op then
        action()
      end
    end)
  end

  local function clear_pending()
    for _, request in pairs(pending) do
      close_timer(request.timer)
    end
    pending = {}
  end

  local function send_raw(payload)
    if not job_id then
      return false, "Pi process is not running"
    end
    local encoded_ok, encoded = pcall(vim.json.encode, payload)
    if not encoded_ok then
      return false, "Failed to encode Pi RPC command"
    end
    local ok, sent = pcall(vim.fn.chansend, job_id, encoded .. "\n")
    if not ok or sent == 0 then
      return false, "Failed to send command to Pi"
    end
    return true
  end

  local function request(op, command, callback, no_timeout)
    if operation ~= op then
      return
    end
    next_id = next_id + 1
    local id = "mentat-" .. next_id
    command.id = id
    local entry = { callback = callback, op = op }
    pending[id] = entry
    if not no_timeout then
      local epoch = generation
      entry.timer = vim.defer_fn(function()
        if pending[id] == entry and epoch == generation then
          terminate("Pi RPC timed out: " .. command.type)
        end
      end, (active_config or M.config).rpc_timeout_ms or 30000)
    end
    local ok, err = send_raw(command)
    if not ok then
      terminate(err)
    end
  end

  local function refresh(op, on_done)
    request(op, { type = "get_state" }, function(response)
      if not response.success then
        on_done(false, response.error or "Failed to read Pi state")
        return
      end
      local ok, err = update_state(response.data)
      if not ok then
        on_done(false, err)
        return
      end
      state.thinking_levels = nil
      request(op, { type = "get_available_thinking_levels" }, function(levels_response)
        local data = value(levels_response.data)
        if not levels_response.success or type(data) ~= "table" or type(data.levels) ~= "table" then
          on_done(false, levels_response.error or "Pi returned invalid thinking levels")
          return
        end
        state.thinking_levels = vim.deepcopy(data.levels)
        changed()
        on_done(true)
      end)
    end)
  end

  local function apply_selection(op, selection, on_done)
    local function apply(resolved)
      local function set_thinking()
        if not resolved.thinking or state.thinking_level == resolved.thinking then
          on_done(true)
          return
        end
        request(op, { type = "set_thinking_level", level = resolved.thinking }, function(response)
          refresh(op, function(ok, err)
            local setter_err = not response.success and (response.error or "Failed to set thinking level") or nil
            on_done(response.success and ok, joined_error(setter_err, err))
          end)
        end)
      end
      if not resolved.model or (state.model and state.model.provider == resolved.provider and state.model.id == resolved.model) then
        set_thinking()
        return
      end
      request(op, { type = "set_model", provider = resolved.provider, modelId = resolved.model }, function(response)
        refresh(op, function(ok, err)
          if not response.success or not ok then
            local setter_err = not response.success and (response.error or "Failed to switch model") or nil
            on_done(false, joined_error(setter_err, err))
            return
          end
          set_thinking()
        end)
      end)
    end
    if not selection.model then
      apply(selection)
      return
    end
    request(op, { type = "get_available_models" }, function(response)
      local data = value(response.data)
      if not response.success or type(data) ~= "table" or type(data.models) ~= "table" then
        on_done(false, response.error or "Pi returned an invalid model catalog")
        return
      end
      local resolved, err = models.resolve(selection, data.models)
      if not resolved then
        on_done(false, err)
        return
      end
      apply(resolved)
    end)
  end

  local function restore(op, on_done)
    if not restore_selection then
      on_done(true)
      return
    end
    apply_selection(op, restore_selection, function(ok, err)
      if ok then
        restore_selection = nil
        state.selection = models.from_state(state)
        selection_error = nil
        changed()
      end
      on_done(ok, err and ("Could not restore the selected settings: " .. err) or nil)
    end)
  end

  terminate = function(err, status, keep_operation)
    local old_job = job_id
    job_id = nil
    generation = generation + 1
    clear_pending()
    resume_selection = vim.deepcopy(state.selection)
    active_config = nil
    stdout_buffer = ""
    stderr_buffer = ""
    state.ready = false
    state.is_streaming = false
    state.is_compacting = false
    state.revision = state.revision + 1
    changed()
    if old_job then
      pcall(vim.fn.jobstop, old_job)
    end
    if operation and not keep_operation then
      operation.fail(err or "Pi process stopped", status)
    end
  end

  function client.stop(reason)
    terminate(reason or "Pi process stopped")
  end

  local function handle_ui_request(ui_request)
    local epoch = generation
    local revision = state.revision
    local function respond(fields)
      if epoch ~= generation or revision ~= state.revision then
        return
      end
      fields.type = "extension_ui_response"
      fields.id = ui_request.id
      send_raw(fields)
    end
    if ui_request.method == "notify" then
      local levels = { info = vim.log.levels.INFO, warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
      vim.notify(ui_request.message or "", levels[ui_request.notifyType] or vim.log.levels.INFO)
    elseif ui_request.method == "select" then
      vim.ui.select(ui_request.options or {}, { prompt = ui_request.title or "Select" }, function(choice)
        respond(choice == nil and { cancelled = true } or { value = choice })
      end)
    elseif ui_request.method == "confirm" then
      local title = ui_request.title or "Confirm"
      if ui_request.message then
        title = title .. ": " .. ui_request.message
      end
      vim.ui.select({ "Yes", "No" }, { prompt = title }, function(choice)
        respond(choice == nil and { cancelled = true } or { confirmed = choice == "Yes" })
      end)
    elseif ui_request.method == "input" or ui_request.method == "editor" then
      vim.ui.input({ prompt = (ui_request.title or "Input") .. ": ", default = ui_request.prefill or "" }, function(input)
        respond(input == nil and { cancelled = true } or { value = input })
      end)
    elseif ui_request.method ~= "setStatus" and ui_request.method ~= "setWidget" and ui_request.method ~= "setTitle" and ui_request.method ~= "set_editor_text" then
      respond({ cancelled = true })
    end
  end

  local function metadata_changed(prompt)
    if prompt.on_metadata then
      prompt.on_metadata(vim.deepcopy(prompt.metadata))
    end
  end

  local function record_model(prompt, message)
    if type(message.provider) ~= "string" or type(message.model) ~= "string" then
      return
    end
    local selection = { provider = message.provider, model = message.model, thinking = prompt.message_thinking or state.thinking_level }
    local used = prompt.metadata.models
    if not vim.deep_equal(used[#used], selection) then
      table.insert(used, selection)
      metadata_changed(prompt)
    end
  end

  local function assistant_text(prompt, text)
    if text == "" then
      return
    end
    if not prompt.metadata.first_text_ms and text:find("%S") then
      prompt.metadata.first_text_ms = (uv.hrtime() - prompt.started) / 1e6
      metadata_changed(prompt)
    end
    prompt.text = prompt.text .. text
    prompt.message_text = (prompt.message_text or "") .. text
    if prompt.on_chunk then
      prompt.on_chunk(text)
    end
  end

  local function final_message(prompt, message)
    record_model(prompt, message)
    prompt.message_thinking = nil
    local text = text_content(message.content)
    local streamed = prompt.message_text or ""
    if text:sub(1, #streamed) == streamed then
      assistant_text(prompt, text:sub(#streamed + 1))
    end
    if message.stopReason == "error" then
      prompt.message_error = value(message.errorMessage) or "Pi returned an error"
      prompt.message_status = "error"
    elseif message.stopReason == "aborted" then
      prompt.message_error = value(message.errorMessage) or "Pi request aborted"
      prompt.message_status = "aborted"
    else
      prompt.message_error = nil
      prompt.message_status = message.stopReason == "length" and "length limit" or nil
    end
  end

  local function handle_event(event)
    local op = operation
    local prompt = op and op.prompt
    if event.type == "thinking_level_changed" then
      if prompt and prompt.sent and not prompt.settled then
        state.thinking_level = value(event.level)
        changed()
      end
    elseif event.type == "agent_start" then
      state.is_streaming = true
      if prompt then
        prompt.agent_started = true
      end
      changed()
    elseif event.type == "compaction_start" then
      state.is_compacting = true
      if prompt then
        prompt.compaction_error = nil
        prompt.compaction_status = nil
      end
      changed()
    elseif event.type == "compaction_end" then
      state.is_compacting = false
      if prompt then
        prompt.compaction_error = value(event.errorMessage) or (event.aborted and "Pi compaction aborted" or nil)
        prompt.compaction_status = event.aborted and "aborted" or nil
      end
      changed()
    elseif event.type == "agent_settled" then
      state.is_streaming = false
      state.is_compacting = false
      if prompt and not prompt.settled then
        settle_prompt(op)
      else
        changed()
      end
    elseif event.type == "extension_error" then
      vim.notify("Pi extension error: " .. tostring(event.error), vim.log.levels.ERROR)
    elseif prompt and not prompt.settled then
      if event.type == "message_start" and type(event.message) == "table" and event.message.role == "assistant" then
        prompt.message_text = ""
        prompt.message_thinking = state.thinking_level
        record_model(prompt, event.message)
      elseif event.type == "message_update" and type(event.assistantMessageEvent) == "table" then
        local delta = event.assistantMessageEvent
        if delta.type == "text_delta" and type(delta.delta) == "string" then
          assistant_text(prompt, delta.delta)
        end
      elseif event.type == "message_end" and type(event.message) == "table" and event.message.role == "assistant" then
        final_message(prompt, event.message)
      elseif event.type == "tool_execution_start" and prompt.on_chunk then
        local summary = tool_summary(event.toolName, event.args)
        if summary then
          prompt.on_chunk(summary)
        end
      elseif event.type == "auto_retry_end" then
        prompt.retry_error = event.success == false and (value(event.finalError) or "Pi retries failed") or nil
      end
    end
  end

  local function handle_line(line)
    local ok, payload = pcall(vim.json.decode, line)
    if not ok or type(payload) ~= "table" then
      return
    end
    if payload.type == "response" then
      local entry = payload.id and pending[payload.id]
      if not entry then
        return
      end
      pending[payload.id] = nil
      close_timer(entry.timer)
      if operation == entry.op then
        entry.callback(payload)
      end
    elseif payload.type == "extension_ui_request" then
      handle_ui_request(payload)
    else
      handle_event(payload)
    end
  end

  local function start_process(config)
    if vim.fn.executable(config.cmd) ~= 1 then
      return false, "Pi executable not found: " .. tostring(config.cmd)
    end
    local args, env, root = command_line(config)
    local epoch = generation
    local options = {
      cwd = root,
      pty = false,
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(id, data)
        vim.schedule(function()
          if epoch == generation and id == job_id then
            local remaining = line_consumer(stdout_buffer, data, function(line)
              if epoch == generation then
                handle_line(line)
              end
            end)
            if epoch == generation and id == job_id then
              stdout_buffer = remaining
            end
          end
        end)
      end,
      on_stderr = function(id, data)
        vim.schedule(function()
          if epoch == generation and id == job_id then
            local remaining = line_consumer(stderr_buffer, data, function(line)
              if epoch == generation then
                vim.notify("Pi stderr: " .. line, vim.log.levels.WARN)
              end
            end)
            if epoch == generation and id == job_id then
              stderr_buffer = remaining
            end
          end
        end)
      end,
      on_exit = function(id, code)
        vim.schedule(function()
          if epoch ~= generation or id ~= job_id then
            return
          end
          local err = "Pi process exited" .. (code and (" with code " .. code) or "")
          if stderr_buffer ~= "" then
            err = err .. ": " .. stderr_buffer
          end
          terminate(err)
        end)
      end,
    }
    if not vim.tbl_isempty(env) then
      options.env = env
    end
    local ok, id = pcall(vim.fn.jobstart, args, options)
    if not ok or id <= 0 then
      return false, "Failed to start Pi RPC process: " .. tostring(id)
    end
    job_id = id
    active_config = config
    last_config = config
    state.ready = false
    return true
  end

  local function ensure_ready(op, opts, on_done)
    if type(opts) == "function" then
      opts = opts()
    end
    local config = vim.tbl_deep_extend("force", vim.deepcopy(M.config), opts or active_config or last_config or {})
    if not opts and state.session_file then
      config.session_file = state.session_file
    end
    local same = job_id and vim.deep_equal(comparable_config(config), comparable_config(active_config))
    if not same then
      local previous_file = state.session_file
      if job_id then
        terminate(nil, nil, true)
      end
      config.session_file = value(config.session_file) or previous_file
      if config.no_session then
        config.session_file = nil
      end
      local resumed = config.session_file and vim.fn.filereadable(config.session_file) == 1
      needs_defaults = not resumed
      if not restore_selection and resume_selection and (not resumed or config.session_file == previous_file) then
        restore_selection = resume_selection
        needs_defaults = false
      end
      selection_error = nil
      local ok, err = start_process(config)
      if not ok then
        on_done(false, err)
        return
      end
    end
    refresh(op, function(ok, err)
      if not ok then
        on_done(false, err)
        return
      end
      if state.is_streaming or state.is_compacting then
        on_done(false, "Pi is already processing a request")
        return
      end
      if restore_selection then
        restore(op, on_done)
      elseif needs_defaults then
        needs_defaults = false
        apply_selection(op, config.default_selection or models.defaults(config), function(selected, selection_err)
          selection_error = selection_err
          on_done(selected, selection_err)
        end)
      else
        on_done(selection_error == nil, selection_error)
      end
    end)
  end

  function client.ensure_started(opts, on_done)
    local op, err = begin("starting", on_done)
    if not op then
      return false, err
    end
    schedule(op, function()
      ensure_ready(op, opts, function(ok, start_err)
        finish(op, ok, start_err)
      end)
    end)
    return true
  end

  settle_prompt = function(op, forced_error, forced_status)
    local prompt = op.prompt
    if prompt.settled then
      return
    end
    prompt.settled = true
    prompt.metadata.total_ms = (uv.hrtime() - prompt.started) / 1e6
    local err = forced_error or prompt.message_error or prompt.retry_error or prompt.compaction_error
    local status = forced_status or prompt.message_status or prompt.compaction_status
    if prompt.aborted then
      err = "Pi request aborted"
      status = "aborted"
    end
    refresh(op, function(ok, refresh_err)
      err = joined_error(err, not ok and refresh_err or nil)
      restore(op, function(restored, restore_err)
        err = joined_error(err, not restored and restore_err or nil)
        if err and status ~= "aborted" then
          status = "error"
        end
        finish_prompt(op, err, status)
      end)
    end)
  end

  function client.prompt(message, on_chunk, on_done, opts)
    opts = opts or {}
    local op, err = begin("prompt", on_done)
    if not op then
      return false, err
    end
    op.prompt = {
      started = uv.hrtime(),
      text = "",
      metadata = { models = {}, status = "pending" },
      on_chunk = on_chunk,
      on_metadata = opts.on_metadata,
    }
    schedule(op, function()
      ensure_ready(op, opts.start_config, function(ok, prepare_err)
        if not ok then
          finish_prompt(op, prepare_err)
          return
        end
        local function submit(selected, selection_err)
          if not selected then
            settle_prompt(op, selection_err, "error")
            return
          end
          if not state.model then
            settle_prompt(op, "No Pi model selected; check model availability and authentication", "error")
            return
          end
          op.prompt.sent = true
          request(op, { type = "prompt", message = message }, function(response)
            if not response.success then
              settle_prompt(op, response.error or "Pi rejected the prompt", "error")
            elseif not op.prompt.agent_started and not op.prompt.settled then
              request(op, { type = "get_state" }, function(idle_response)
                if op.prompt.agent_started or op.prompt.settled then
                  return
                end
                if not idle_response.success then
                  terminate(idle_response.error or "Failed to confirm prompt acceptance")
                  return
                end
                local valid, state_err = update_state(idle_response.data)
                if not valid then
                  terminate(state_err)
                elseif not state.is_streaming and not state.is_compacting then
                  settle_prompt(op, nil, "handled without a response")
                end
              end)
            end
          end, true)
        end
        if opts.override then
          restore_selection = models.from_state(state)
          apply_selection(op, opts.override, submit)
        else
          submit(true)
        end
      end)
    end)
    return true
  end

  function client.abort()
    local op = operation
    if not op or not op.prompt then
      return false, "No Pi prompt to abort"
    end
    op.prompt.aborted = true
    if not op.prompt.agent_started or op.prompt.settled then
      terminate("Pi request aborted", "aborted")
    else
      request(op, { type = "abort" }, function(response)
        if not response.success then
          terminate(response.error or "Failed to abort Pi", "aborted")
        end
      end, true)
    end
    return true
  end

  local function select_settings(selection, on_done)
    local op, err = begin("selecting", on_done)
    if not op then
      return false, err
    end
    schedule(op, function()
      refresh(op, function(ok, refresh_err)
        if not ok then
          finish(op, false, refresh_err)
          return
        end
        if state.is_streaming or state.is_compacting then
          finish(op, false, "Pi is already processing a request")
          return
        end
        apply_selection(op, selection, function(selected, selection_err)
          if selected then
            restore_selection = nil
            selection_error = nil
          end
          if not restore_selection then
            state.selection = models.from_state(state)
          end
          finish(op, selected, selection_err, vim.deepcopy(state))
        end)
      end)
    end)
    return true
  end

  function client.set_model(provider, model_id, on_done)
    return select_settings({ provider = provider, model = model_id }, on_done)
  end

  function client.set_thinking_level(level, on_done)
    return select_settings({ thinking = level }, on_done)
  end

  function client.set_selection(selection, on_done)
    return select_settings(selection, on_done)
  end

  function client.get_state(on_done)
    local op, err = begin("refreshing", function(ok, rpc_err, data)
      on_done(ok and data or nil, rpc_err)
    end)
    if not op then
      return false, err
    end
    schedule(op, function()
      refresh(op, function(ok, refresh_err)
        finish(op, ok, refresh_err, vim.deepcopy(state))
      end)
    end)
    return true
  end

  local function get_list(command, key, on_done)
    local op, err = begin("listing", function(ok, rpc_err, data)
      on_done(ok and data or nil, rpc_err)
    end)
    if not op then
      return false, err
    end
    schedule(op, function()
      request(op, { type = command }, function(response)
        local data = value(response.data)
        local list = type(data) == "table" and data[key] or nil
        if not response.success or type(list) ~= "table" then
          finish(op, false, response.error or ("Pi returned invalid " .. key))
        else
          finish(op, true, nil, list)
        end
      end)
    end)
    return true
  end

  function client.get_available_models(on_done)
    return get_list("get_available_models", "models", on_done)
  end

  function client.get_available_thinking_levels(on_done)
    return get_list("get_available_thinking_levels", "levels", on_done)
  end

  function client.get_commands(on_done)
    return get_list("get_commands", "commands", on_done)
  end

  local function session_command(command, on_done, opts, reset_defaults)
    local op, err = begin("switching", on_done)
    if not op then
      return false, err
    end
    schedule(op, function()
      ensure_ready(op, opts, function(ok, start_err)
        if not ok and (not state.ready or state.is_streaming or state.is_compacting) then
          finish(op, false, start_err)
          return
        end
        request(op, command, function(response)
          local data = value(response.data)
          if not response.success or (type(data) == "table" and data.cancelled == true) then
            finish(op, false, response.error or ("Pi " .. command.type .. " request was cancelled"))
            return
          end
          restore_selection = nil
          resume_selection = nil
          selection_error = nil
          refresh(op, function(refreshed, refresh_err)
            if not refreshed or not reset_defaults then
              finish(op, refreshed, refresh_err)
              return
            end
            apply_selection(op, active_config.default_selection or models.defaults(active_config), function(selected, selection_err)
              selection_error = selection_err
              finish(op, selected, selection_err)
            end)
          end)
        end, true)
      end)
    end)
    return true
  end

  function client.new_session(on_done, opts)
    return session_command({ type = "new_session" }, on_done, opts, true)
  end

  function client.switch_session(path, on_done, opts)
    return session_command({ type = "switch_session", sessionPath = path }, on_done, opts)
  end

  function client.clone_session(on_done, opts)
    return session_command({ type = "clone" }, on_done, opts)
  end

  function client.clone_from(source, on_done, opts)
    local op, err = begin("cloning", on_done)
    if not op then
      return false, err
    end
    schedule(op, function()
      local config = type(opts.start_config) == "function" and opts.start_config() or opts.start_config
      local clone_config = vim.deepcopy(config)
      clone_config.session_file = source
      clone_config.no_session = false
      clone_config.no_extensions = true
      clone_config.no_skills = true
      clone_config.no_prompt_templates = true
      clone_config.no_themes = true
      local scratch = new_client()
      op.cleanup = scratch.stop
      scratch.ensure_started(clone_config, function(started, start_err)
        if operation ~= op then
          return
        end
        if not started then
          finish(op, false, start_err)
          return
        end
        scratch.clone_session(function(cloned, clone_err)
          if operation ~= op then
            return
          end
          if not cloned then
            finish(op, false, clone_err)
            return
          end
          local path = scratch.state.session_file
          scratch.stop()
          if type(path) ~= "string" or path == source then
            finish(op, false, "Pi did not create a cloned session file")
            return
          end
          local prepare_err = opts.prepare_clone and opts.prepare_clone(path)
          if prepare_err then
            vim.fn.delete(path)
            finish(op, false, prepare_err)
            return
          end
          ensure_ready(op, config, function(start_ok, ready_err)
            if not start_ok then
              finish(op, false, ready_err)
              return
            end
            request(op, { type = "switch_session", sessionPath = path }, function(response)
              local data = value(response.data)
              if not response.success or (type(data) == "table" and data.cancelled == true) then
                finish(op, false, response.error or "Pi switch_session request was cancelled")
                return
              end
              restore_selection = nil
              resume_selection = nil
              selection_error = nil
              refresh(op, function(ok, refresh_err)
                finish(op, ok, refresh_err)
              end)
            end, true)
          end)
        end)
      end)
    end)
    return true
  end

  return client
end

M.new = new_client
for key, item in pairs(new_client()) do
  M[key] = item
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M
