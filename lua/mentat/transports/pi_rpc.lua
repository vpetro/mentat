local models = require("mentat.models")
local boundary = require("mentat.async")
local uv = vim.uv
local async = vim.async
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

local function joined_error(first, second)
  if first and second then
    return first .. "; " .. second
  end
  return first or second
end

local function on_main(callback)
  if vim.in_fast_event() then
    vim.schedule(callback)
  else
    callback()
  end
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
  local ui_tasks = {}
  local needs_defaults = false
  local selection_error
  local restore_selection
  local resume_selection
  local terminate

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
    if operation ~= op or op.finishing then
      return
    end
    op.finishing = true
    local results = vim.F.pack_len(...)
    if op.abort_task then
      op.abort_task:close()
    end
    local function complete()
      local function deliver()
        if operation ~= op then
          return
        end
        operation = nil
        state.busy = false
        changed()
        op.on_done(vim.F.unpack_len(results))
      end
      if op.launching then
        vim.schedule(deliver)
      else
        on_main(deliver)
      end
    end
    if op.cleanup then
      op.cleanup(complete)
    else
      complete()
    end
  end

  local function prompt_result(op, err, status)
    local prompt = op.prompt
    prompt.metadata.total_ms = prompt.metadata.total_ms or (uv.hrtime() - prompt.started) / 1e6
    prompt.metadata.status = status or (err and "error" or "complete")
    return prompt.text, err, vim.deepcopy(prompt.metadata)
  end

  local function begin(kind, on_done)
    if client.is_busy() then
      return nil, "Pi is busy; wait for the current operation to settle"
    end
    local op = { kind = kind, on_done = on_done or function() end }
    op.fail = function(err, status)
      if op.prompt then
        finish(op, prompt_result(op, err, status))
      elseif op.list then
        finish(op, nil, err)
      else
        finish(op, false, err)
      end
    end
    operation = op
    state.busy = true
    state.revision = state.revision + 1
    return op
  end

  local function launch(op, work)
    op.launching = true
    local task = async.run("mentat Pi " .. op.kind, function()
      async.await(vim.schedule)
      return work()
    end):detach()
    op.task = task
    task:on_complete(function(task_err, ...)
      local results = vim.F.pack_len(...)
      on_main(function()
        if operation ~= op or op.failure then
          return
        end
        if task_err then
          local err = task_err == "closed" and "Pi operation cancelled" or tostring(task_err)
          terminate(err, nil, true)
          op.fail(err)
        else
          finish(op, vim.F.unpack_len(results))
        end
      end)
    end)
    changed()
    op.launching = false
    return true, nil, task
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

  local function request(op, command, no_timeout, until_settled)
    local function response()
      return async.await(function(done)
        next_id = next_id + 1
        local id = "mentat-" .. next_id
        command.id = id
        local entry = { callback = done, op = op }
        pending[id] = entry
        local wake
        if until_settled then
          wake = function() done(nil) end
          op.prompt.wake = wake
        end
        if command.type == "prompt" then
          op.prompt.sent = true
        end
        local ok, err = send_raw(command)
        if not ok then
          done(nil, err)
        end
        return {
          close = function(_, callback)
            if pending[id] == entry then
              pending[id] = nil
            end
            if wake and op.prompt.wake == wake then
              op.prompt.wake = nil
            end
            callback()
          end,
        }
      end)
    end
    local ok, payload, err
    if no_timeout then
      payload, err = response()
      ok = true
    else
      local task = async.run("mentat RPC " .. command.type, response)
      ok, payload, err = pcall(async.timeout, (active_config or M.config).rpc_timeout_ms or 30000, task)
      async.checkpoint()
    end
    boundary.main()
    if not ok then
      err = payload == "timeout" and ("Pi RPC timed out: " .. command.type) or tostring(payload)
      payload = nil
    end
    if err then
      terminate(err, nil, true)
    end
    return payload, err
  end

  local function refresh(op)
    local response, rpc_err = request(op, { type = "get_state" })
    if not response or not response.success then
      return false, rpc_err or (response and response.error) or "Failed to read Pi state"
    end
    local ok, err = update_state(response.data)
    if not ok then
      return false, err
    end
    state.thinking_levels = nil
    local levels_response, levels_err = request(op, { type = "get_available_thinking_levels" })
    local data = levels_response and value(levels_response.data)
    if not levels_response or not levels_response.success or type(data) ~= "table" or type(data.levels) ~= "table" then
      return false, levels_err or (levels_response and levels_response.error) or "Pi returned invalid thinking levels"
    end
    state.thinking_levels = vim.deepcopy(data.levels)
    changed()
    return true
  end

  local function apply_selection(op, selection)
    local resolved = selection
    if selection.model then
      local response, rpc_err = request(op, { type = "get_available_models" })
      local data = response and value(response.data)
      if not response or not response.success or type(data) ~= "table" or type(data.models) ~= "table" then
        return false, rpc_err or (response and response.error) or "Pi returned an invalid model catalog"
      end
      local err
      resolved, err = models.resolve(selection, data.models)
      if not resolved then
        return false, err
      end
    end
    if resolved.model and not (state.model and state.model.provider == resolved.provider and state.model.id == resolved.model) then
      local response, rpc_err = request(op, { type = "set_model", provider = resolved.provider, modelId = resolved.model })
      if not response then
        return false, rpc_err
      end
      local ok, err = refresh(op)
      if not response.success or not ok then
        local setter_err = not response.success and (response.error or "Failed to switch model") or nil
        return false, joined_error(setter_err, err)
      end
    end
    if resolved.thinking and state.thinking_level ~= resolved.thinking then
      local response, rpc_err = request(op, { type = "set_thinking_level", level = resolved.thinking })
      if not response then
        return false, rpc_err
      end
      local ok, err = refresh(op)
      local setter_err = not response.success and (response.error or "Failed to set thinking level") or nil
      return response.success and ok, joined_error(setter_err, err)
    end
    return true
  end

  local function restore(op)
    if not restore_selection then
      return true
    end
    local ok, err = apply_selection(op, restore_selection)
    if ok then
      restore_selection = nil
      state.selection = models.from_state(state)
      selection_error = nil
      changed()
    end
    return ok, err and ("Could not restore the selected settings: " .. err) or nil
  end

  terminate = function(err, status, keep_operation)
    local old_job = job_id
    job_id = nil
    generation = generation + 1
    pending = {}
    resume_selection = vim.deepcopy(state.selection)
    active_config = nil
    stdout_buffer = ""
    stderr_buffer = ""
    state.ready = false
    state.is_streaming = false
    state.is_compacting = false
    state.revision = state.revision + 1
    for task in pairs(ui_tasks) do
      task:close()
    end
    if old_job then
      pcall(vim.fn.jobstop, old_job)
    end
    local op = operation
    if op and not keep_operation then
      op.failure = err or "Pi process stopped"
      if op.task then
        op.task:close()
      end
      op.fail(op.failure, status)
    end
    changed()
  end

  function client.stop(reason)
    terminate(reason or "Pi process stopped")
  end

  local function handle_ui_request(ui_request)
    local epoch = generation
    local revision = state.revision
    local task = async.run("mentat extension UI", function()
      async.await(vim.schedule)
      local fields
      if ui_request.method == "notify" then
        local levels = { info = vim.log.levels.INFO, warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
        vim.notify(ui_request.message or "", levels[ui_request.notifyType] or vim.log.levels.INFO)
      elseif ui_request.method == "select" then
        local choice = boundary.select(ui_request.options or {}, { prompt = ui_request.title or "Select" })
        fields = choice == nil and { cancelled = true } or { value = choice }
      elseif ui_request.method == "confirm" then
        local title = ui_request.title or "Confirm"
        if ui_request.message then
          title = title .. ": " .. ui_request.message
        end
        local choice = boundary.select({ "Yes", "No" }, { prompt = title })
        fields = choice == nil and { cancelled = true } or { confirmed = choice == "Yes" }
      elseif ui_request.method == "input" or ui_request.method == "editor" then
        local input = boundary.input({ prompt = (ui_request.title or "Input") .. ": ", default = ui_request.prefill or "" })
        fields = input == nil and { cancelled = true } or { value = input }
      elseif ui_request.method ~= "setStatus" and ui_request.method ~= "setWidget" and ui_request.method ~= "setTitle" and ui_request.method ~= "set_editor_text" then
        fields = { cancelled = true }
      end
      if fields and epoch == generation and revision == state.revision then
        fields.type = "extension_ui_response"
        fields.id = ui_request.id
        local ok, err = send_raw(fields)
        if not ok then
          terminate(err)
        end
      end
    end):detach()
    ui_tasks[task] = true
    task:on_complete(function(err)
      ui_tasks[task] = nil
      boundary.report(err)
    end)
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

  local function settled(prompt, err, status)
    if prompt.settled then
      return
    end
    prompt.settled = true
    prompt.error = err
    prompt.status = status
    prompt.metadata.total_ms = (uv.hrtime() - prompt.started) / 1e6
    if prompt.wake then
      prompt.wake()
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
      if prompt and prompt.sent then
        settled(prompt)
      end
      changed()
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
              if epoch == generation and id == job_id then
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
              if epoch == generation and id == job_id then
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

  local function ensure_ready(op, opts)
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
        return false, err
      end
    end
    local ok, err = refresh(op)
    if not ok then
      return false, err
    end
    if state.is_streaming or state.is_compacting then
      return false, "Pi is already processing a request"
    end
    if restore_selection then
      return restore(op)
    elseif needs_defaults then
      needs_defaults = false
      local selected, selection_err = apply_selection(op, config.default_selection or models.defaults(config))
      selection_error = selection_err
      return selected, selection_err
    end
    return selection_error == nil, selection_error
  end

  function client.ensure_started(opts, on_done)
    local op, err = begin("starting", on_done)
    if not op then
      return false, err
    end
    return launch(op, function()
      return ensure_ready(op, opts)
    end)
  end

  local function settle_prompt(op)
    local prompt = op.prompt
    local err = prompt.error or prompt.message_error or prompt.retry_error or prompt.compaction_error
    local status = prompt.status or prompt.message_status or prompt.compaction_status
    if prompt.aborted then
      err = "Pi request aborted"
      status = "aborted"
    end
    local ok, refresh_err = refresh(op)
    err = joined_error(err, not ok and refresh_err or nil)
    if job_id then
      local restored, restore_err = restore(op)
      err = joined_error(err, not restored and restore_err or nil)
    end
    if err and status ~= "aborted" then
      status = "error"
    end
    return prompt_result(op, err, status)
  end

  function client.prompt(message, on_chunk, on_done, opts)
    opts = opts or {}
    local op, err = begin("prompt", on_done)
    if not op then
      return false, err
    end
    local prompt = {
      started = uv.hrtime(),
      text = "",
      metadata = { models = {}, status = "pending" },
      on_chunk = on_chunk,
      on_metadata = opts.on_metadata,
    }
    op.prompt = prompt
    return launch(op, function()
      local ok, prepare_err = ensure_ready(op, opts.start_config)
      if not ok then
        return prompt_result(op, prepare_err)
      end
      if opts.override then
        restore_selection = models.from_state(state)
        local selected, selection_err = apply_selection(op, opts.override)
        if not selected then
          settled(prompt, selection_err, "error")
          return settle_prompt(op)
        end
      end
      if not state.model then
        settled(prompt, "No Pi model selected; check model availability and authentication", "error")
        return settle_prompt(op)
      end
      local response, rpc_err = request(op, { type = "prompt", message = message }, true, true)
      if rpc_err then
        return prompt_result(op, rpc_err)
      end
      if not prompt.settled and not response.success then
        settled(prompt, response.error or "Pi rejected the prompt", "error")
      elseif not prompt.settled and not prompt.agent_started then
        local idle_response, idle_err = request(op, { type = "get_state" }, false, true)
        if idle_err then
          return prompt_result(op, idle_err)
        end
        if not prompt.settled and not prompt.agent_started then
          if not idle_response or not idle_response.success then
            local failure = idle_err or (idle_response and idle_response.error) or "Failed to confirm prompt acceptance"
            terminate(failure, nil, true)
            return prompt_result(op, failure)
          end
          local valid, state_err = update_state(idle_response.data)
          if not valid then
            terminate(state_err, nil, true)
            return prompt_result(op, state_err)
          elseif not state.is_streaming and not state.is_compacting then
            settled(prompt, nil, "handled without a response")
          end
        end
      end
      if not prompt.settled then
        async.await(function(done)
          prompt.wake = done
          return {
            close = function(_, callback)
              prompt.wake = nil
              callback()
            end,
          }
        end)
      end
      return settle_prompt(op)
    end)
  end

  function client.abort()
    local op = operation
    if not op or not op.prompt then
      return false, "No Pi prompt to abort"
    end
    op.prompt.aborted = true
    if not op.prompt.agent_started or op.prompt.settled then
      terminate("Pi request aborted", "aborted")
    elseif not op.abort_task then
      local task = async.run("mentat Pi abort", function()
        async.await(vim.schedule)
        local response, err = request(op, { type = "abort" }, true)
        if not response or not response.success then
          terminate(err or (response and response.error) or "Failed to abort Pi", "aborted")
        end
      end):detach()
      op.abort_task = task
      task:on_complete(function(err)
        on_main(function()
          if err and err ~= "closed" and operation == op then
            terminate(tostring(err), "aborted")
          end
        end)
      end)
    end
    return true
  end

  local function select_settings(selection, on_done)
    local op, err = begin("selecting", on_done)
    if not op then
      return false, err
    end
    return launch(op, function()
      local ok, refresh_err = refresh(op)
      if not ok then
        return false, refresh_err
      end
      if state.is_streaming or state.is_compacting then
        return false, "Pi is already processing a request"
      end
      local selected, selection_err = apply_selection(op, selection)
      if selected then
        restore_selection = nil
        selection_error = nil
      end
      if not restore_selection then
        state.selection = models.from_state(state)
      end
      return selected, selection_err, vim.deepcopy(state)
    end)
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
    local op, err = begin("refreshing", on_done)
    if not op then
      return false, err
    end
    op.list = true
    return launch(op, function()
      local ok, refresh_err = refresh(op)
      return ok and vim.deepcopy(state) or nil, refresh_err
    end)
  end

  local function get_list(command, key, on_done)
    local op, err = begin("listing", on_done)
    if not op then
      return false, err
    end
    op.list = true
    return launch(op, function()
      local response, rpc_err = request(op, { type = command })
      local data = response and value(response.data)
      local list = type(data) == "table" and data[key] or nil
      if not response or not response.success or type(list) ~= "table" then
        return nil, rpc_err or (response and response.error) or ("Pi returned invalid " .. key)
      end
      return list
    end)
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

  local function switch(op, command)
    local response, rpc_err = request(op, command, true)
    local data = response and value(response.data)
    if not response or not response.success or (type(data) == "table" and data.cancelled == true) then
      return false, rpc_err or (response and response.error) or ("Pi " .. command.type .. " request was cancelled")
    end
    op.adopted_path = command.sessionPath
    restore_selection = nil
    resume_selection = nil
    selection_error = nil
    return refresh(op)
  end

  local function session_command(command, on_done, opts, reset_defaults)
    local op, err = begin("switching", on_done)
    if not op then
      return false, err
    end
    return launch(op, function()
      local ok, start_err = ensure_ready(op, opts)
      if not ok and (not state.ready or state.is_streaming or state.is_compacting) then
        return false, start_err
      end
      local switched, switch_err = switch(op, command)
      if not switched or not reset_defaults then
        return switched, switch_err
      end
      local selected, selection_err = apply_selection(op, active_config.default_selection or models.defaults(active_config))
      selection_error = selection_err
      return selected, selection_err
    end)
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
    opts = opts or {}
    local scratch = new_client()
    local unused_path
    local clone_source
    local cloning = false
    op.cleanup = function(done)
      local path = unused_path or (cloning and scratch.state.session_file)
      scratch.stop()
      if type(path) == "string" and path ~= "" and path ~= source and path ~= clone_source and path ~= op.adopted_path then
        uv.fs_unlink(path, function(unlink_err)
          if unlink_err and not unlink_err:find("ENOENT", 1, true) then
            boundary.report(unlink_err)
          end
          done()
        end)
      else
        done()
      end
    end
    return launch(op, function()
      local config = type(opts.start_config) == "function" and opts.start_config() or opts.start_config or {}
      local clone_config = vim.deepcopy(config)
      clone_config.session_file = source
      clone_config.no_session = false
      clone_config.no_extensions = true
      clone_config.no_skills = true
      clone_config.no_prompt_templates = true
      clone_config.no_themes = true
      local started, start_err = boundary.call(function(done)
        return scratch.ensure_started(clone_config, done)
      end)
      if not started then
        return false, start_err
      end
      clone_source = scratch.state.session_file
      cloning = true
      local cloned, clone_err = boundary.call(function(done)
        return scratch.clone_session(done)
      end)
      if not cloned then
        return false, clone_err
      end
      local path = scratch.state.session_file
      scratch.stop()
      if type(path) ~= "string" or path == "" or path == source or path == clone_source then
        return false, "Pi did not create a cloned session file"
      end
      unused_path = path
      local prepare_err = opts.prepare_clone and opts.prepare_clone(path)
      if prepare_err then
        return false, prepare_err
      end
      local ready, ready_err = ensure_ready(op, config)
      if not ready then
        return false, ready_err
      end
      local switched, switch_err = switch(op, { type = "switch_session", sessionPath = path })
      if switched or state.session_file == path then
        unused_path = nil
      end
      return switched, switch_err
    end)
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
