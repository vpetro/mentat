local M = {}

M.config = {
  cmd = "pi",
  provider = nil,
  model = nil,
  thinking = nil,
  offline = true,
  no_session = false,
  agent_dir = nil,
  session_dir = nil,
  session_file = nil,
  no_extensions = false,
  extensions = {},
  no_skills = false,
  skills = {},
  no_prompt_templates = false,
  prompt_templates = {},
  no_themes = false,
  themes = {},
  no_tools = false,
  tools = nil,
  env = {},
  append_system_prompt = nil,
  system_prompt = nil,
  extra_args = {},
}

M.state = {
  session_file = nil,
  session_id = nil,
  session_name = nil,
  is_streaming = false,
}

local job_id = nil
local next_request_id = 0
local pending = {}
local current_prompt = nil
local stdout_buffer = ""
local stderr_buffer = ""
local active_config = nil

local function is_running()
  if not job_id then
    return false
  end

  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function copy_table(value)
  if not value then
    return nil
  end
  return vim.deepcopy(value)
end

local function shallow_equal(left, right)
  if left == right then
    return true
  end

  if type(left) ~= "table" or type(right) ~= "table" then
    return false
  end

  local left_keys = 0
  for key, value in pairs(left) do
    left_keys = left_keys + 1
    local other = right[key]
    if type(value) == "table" then
      if not shallow_equal(value, other) then
        return false
      end
    elseif value ~= other then
      return false
    end
  end

  local right_keys = 0
  for _ in pairs(right) do
    right_keys = right_keys + 1
  end

  return left_keys == right_keys
end

local function new_request_id()
  next_request_id = next_request_id + 1
  return string.format("mentat-%d", next_request_id)
end

local function line_consumer(buffer, data, handler)
  if not data then
    return buffer
  end

  for index, chunk in ipairs(data) do
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

local function resolve_path(path, repo_root)
  if not path or path == "" then
    return nil
  end

  if path:match("^/") then
    return path
  end

  local root = repo_root or vim.loop.cwd()
  return root .. "/" .. path
end

local function build_start_config(opts)
  return vim.tbl_deep_extend("force", copy_table(M.config) or {}, opts or {})
end

local function comparable_config(config)
  local result = copy_table(config) or {}
  result.session_file = nil
  return result
end

local function update_state(data)
  if type(data) ~= "table" then
    return
  end

  if data.sessionFile ~= nil then
    M.state.session_file = data.sessionFile
  end
  if data.sessionId ~= nil then
    M.state.session_id = data.sessionId
  end
  if data.sessionName ~= nil then
    M.state.session_name = data.sessionName
  end
  if data.isStreaming ~= nil then
    M.state.is_streaming = data.isStreaming
  end
end

local function notify(level, message)
  vim.schedule(function()
    vim.notify(message, level)
  end)
end

local function send_raw(payload)
  if not is_running() then
    return false, "Pi process is not running"
  end

  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return false, "Failed to encode Pi RPC command"
  end

  local status = vim.fn.chansend(job_id, encoded .. "\n")
  if status == 0 then
    return false, "Failed to send command to Pi"
  end

  return true
end

local function send_command(command, callback)
  local payload = vim.deepcopy(command)
  payload.id = payload.id or new_request_id()

  if callback then
    pending[payload.id] = callback
  end

  local ok, err = send_raw(payload)
  if not ok then
    pending[payload.id] = nil
    if callback then
      callback({
        type = "response",
        command = payload.type,
        success = false,
        error = err,
        id = payload.id,
      })
    end
    return nil, err
  end

  return payload.id
end

local function extract_text_blocks(content)
  local parts = {}
  if type(content) ~= "table" then
    return nil
  end

  for _, block in ipairs(content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      table.insert(parts, block.text)
    end
  end

  if #parts == 0 then
    return nil
  end

  return table.concat(parts, "")
end

local function extract_latest_assistant_text(messages)
  if type(messages) ~= "table" then
    return nil
  end

  for index = #messages, 1, -1 do
    local message = messages[index]
    if type(message) == "table" and message.role == "assistant" then
      if type(message.content) == "string" then
        return message.content
      end

      local text = extract_text_blocks(message.content)
      if text and text ~= "" then
        return text
      end
    end
  end

  return nil
end

local function tool_call_summary(tool_name, args)
  if type(tool_name) ~= "string" or tool_name == "" then
    return nil
  end

  local arg = ""
  if type(args) == "table" then
    arg = tostring(args.path or args.pattern or args.command or args.query or args.ref or "")
  end

  if arg ~= "" then
    return string.format("\n\n> *%s: %s*\n\n", tool_name, arg)
  end

  return string.format("\n\n> *%s*\n\n", tool_name)
end

local function finish_prompt(text, err)
  if not current_prompt then
    return
  end

  local callback = current_prompt.on_done
  current_prompt = nil
  M.state.is_streaming = false

  if callback then
    vim.schedule(function()
      callback(text, err)
    end)
  end
end

local function handle_ui_request(request)
  local function cancel()
    send_raw({
      type = "extension_ui_response",
      id = request.id,
      cancelled = true,
    })
  end

  if request.method == "notify" then
    local levels = {
      info = vim.log.levels.INFO,
      warning = vim.log.levels.WARN,
      error = vim.log.levels.ERROR,
    }
    notify(levels[request.notifyType] or vim.log.levels.INFO, request.message)
    return
  end

  if request.method == "setStatus"
    or request.method == "setWidget"
    or request.method == "setTitle"
    or request.method == "set_editor_text"
  then
    return
  end

  vim.schedule(function()
    if request.method == "select" then
      vim.ui.select(request.options or {}, { prompt = request.title or "Select" }, function(choice)
        if choice == nil then
          cancel()
        else
          send_raw({
            type = "extension_ui_response",
            id = request.id,
            value = choice,
          })
        end
      end)
      return
    end

    if request.method == "confirm" then
      local options = { "Yes", "No" }
      local prompt = request.title or "Confirm"
      if request.message and request.message ~= "" then
        prompt = prompt .. ": " .. request.message
      end
      vim.ui.select(options, { prompt = prompt }, function(choice)
        if choice == nil then
          cancel()
        else
          send_raw({
            type = "extension_ui_response",
            id = request.id,
            confirmed = choice == "Yes",
          })
        end
      end)
      return
    end

    if request.method == "input" or request.method == "editor" then
      vim.ui.input({
        prompt = (request.title or "Input") .. ": ",
        default = request.prefill or "",
      }, function(value)
        if value == nil then
          cancel()
        else
          send_raw({
            type = "extension_ui_response",
            id = request.id,
            value = value,
          })
        end
      end)
      return
    end

    cancel()
  end)
end

local function handle_event(event)
  if type(event) ~= "table" then
    return
  end

  if event.type == "agent_start" then
    M.state.is_streaming = true
    return
  end

  if event.type == "message_update" and current_prompt then
    local assistant_event = event.assistantMessageEvent
    if type(assistant_event) ~= "table" then
      return
    end

    if assistant_event.type == "text_delta" and type(assistant_event.delta) == "string" then
      current_prompt.text = current_prompt.text .. assistant_event.delta
      local on_chunk = current_prompt.on_chunk
      if on_chunk then
        vim.schedule(function()
          on_chunk(assistant_event.delta)
        end)
      end
    elseif assistant_event.type == "error" then
      current_prompt.error = assistant_event.errorMessage or current_prompt.error or "Pi returned an error"
    end
    return
  end

  if event.type == "tool_execution_start" and current_prompt and current_prompt.on_chunk then
    local summary = tool_call_summary(event.toolName, event.args)
    local on_chunk = current_prompt.on_chunk
    if summary then
      vim.schedule(function()
        on_chunk(summary)
      end)
    end
    return
  end

  if event.type == "agent_end" then
    local text = current_prompt and current_prompt.text or nil
    if (not text or text == "") and type(event.messages) == "table" then
      text = extract_latest_assistant_text(event.messages)
    end
    local err = current_prompt and current_prompt.error or nil
    finish_prompt(text, err)
    send_command({ type = "get_state" }, function(response)
      if response.success then
        update_state(response.data)
      end
    end)
    return
  end

  if event.type == "extension_error" then
    notify(vim.log.levels.ERROR, "Pi extension error: " .. tostring(event.error))
    return
  end
end

local function handle_stdout_line(line)
  local ok, payload = pcall(vim.json.decode, line)
  if not ok or type(payload) ~= "table" then
    return
  end

  if payload.type == "response" then
    if payload.command == "get_state" and payload.success then
      update_state(payload.data)
    end

    local callback = payload.id and pending[payload.id] or nil
    if payload.id then
      pending[payload.id] = nil
    end
    if callback then
      callback(payload)
    end
    return
  end

  if payload.type == "extension_ui_request" then
    handle_ui_request(payload)
    return
  end

  handle_event(payload)
end

function M.stop()
  if not is_running() then
    job_id = nil
    active_config = nil
    return
  end

  vim.fn.jobstop(job_id)
  job_id = nil
  stdout_buffer = ""
  stderr_buffer = ""
  pending = {}
  current_prompt = nil
  M.state.is_streaming = false
  active_config = nil
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.ensure_started(opts)
  local start_config = build_start_config(opts)

  if is_running() and shallow_equal(comparable_config(active_config), comparable_config(start_config)) then
    return true
  end

  if is_running() then
    M.stop()
  end

  if vim.fn.executable(start_config.cmd) ~= 1 then
    return false, "Pi executable not found: " .. tostring(start_config.cmd)
  end

  local repo_root = start_config.repo_root or vim.loop.cwd()
  local args = { start_config.cmd, "--mode", "rpc" }

  if start_config.offline then
    table.insert(args, "--offline")
  end
  if start_config.provider then
    table.insert(args, "--provider")
    table.insert(args, start_config.provider)
  end
  if start_config.model then
    table.insert(args, "--model")
    table.insert(args, start_config.model)
  end
  if start_config.thinking then
    table.insert(args, "--thinking")
    table.insert(args, start_config.thinking)
  end
  if start_config.system_prompt then
    table.insert(args, "--system-prompt")
    table.insert(args, start_config.system_prompt)
  end
  if start_config.append_system_prompt then
    table.insert(args, "--append-system-prompt")
    table.insert(args, start_config.append_system_prompt)
  end
  if start_config.no_session then
    table.insert(args, "--no-session")
  end

  local session_dir = resolve_path(start_config.session_dir, repo_root)
  if session_dir and not start_config.no_session then
    vim.fn.mkdir(session_dir, "p")
    table.insert(args, "--session-dir")
    table.insert(args, session_dir)
  end

  local session_file = resolve_path(start_config.session_file, repo_root)
  if session_file and not start_config.no_session then
    table.insert(args, "--session")
    table.insert(args, session_file)
  end

  if start_config.no_extensions then
    table.insert(args, "--no-extensions")
  end
  for _, extension in ipairs(start_config.extensions or {}) do
    table.insert(args, "--extension")
    table.insert(args, resolve_path(extension, repo_root) or extension)
  end

  if start_config.no_skills then
    table.insert(args, "--no-skills")
  end
  for _, skill in ipairs(start_config.skills or {}) do
    table.insert(args, "--skill")
    table.insert(args, resolve_path(skill, repo_root) or skill)
  end

  if start_config.no_prompt_templates then
    table.insert(args, "--no-prompt-templates")
  end
  for _, prompt_template in ipairs(start_config.prompt_templates or {}) do
    table.insert(args, "--prompt-template")
    table.insert(args, resolve_path(prompt_template, repo_root) or prompt_template)
  end

  if start_config.no_themes then
    table.insert(args, "--no-themes")
  end
  for _, theme in ipairs(start_config.themes or {}) do
    table.insert(args, "--theme")
    table.insert(args, resolve_path(theme, repo_root) or theme)
  end

  if start_config.no_tools then
    table.insert(args, "--no-tools")
  elseif start_config.tools and start_config.tools ~= "" then
    table.insert(args, "--tools")
    table.insert(args, start_config.tools)
  end

  for _, extra_arg in ipairs(start_config.extra_args or {}) do
    table.insert(args, extra_arg)
  end

  local env = {}
  for key, value in pairs(start_config.env or {}) do
    env[key] = value
  end

  if start_config.agent_dir then
    local agent_dir = resolve_path(start_config.agent_dir, repo_root)
    if agent_dir then
      vim.fn.mkdir(agent_dir, "p")
      env.PI_CODING_AGENT_DIR = agent_dir
    end
  end

  local job_opts = {
    cwd = repo_root,
    pty = false,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(exited_job_id, data)
      if exited_job_id ~= job_id then
        return
      end
      stdout_buffer = line_consumer(stdout_buffer, data, handle_stdout_line)
    end,
    on_stderr = function(exited_job_id, data)
      if exited_job_id ~= job_id then
        return
      end
      stderr_buffer = line_consumer(stderr_buffer, data, function(line)
        if line ~= "" then
          notify(vim.log.levels.WARN, "Pi stderr: " .. line)
        end
      end)
    end,
    on_exit = function(exited_job_id, code)
      if exited_job_id ~= job_id then
        return
      end

      local err = "Pi process exited"
      if code and code ~= 0 then
        err = err .. " with code " .. tostring(code)
      end
      if stderr_buffer ~= "" then
        err = err .. ": " .. stderr_buffer
      end

      if current_prompt then
        finish_prompt(nil, err)
      end

      job_id = nil
      stdout_buffer = ""
      stderr_buffer = ""
      pending = {}
      current_prompt = nil
      M.state.is_streaming = false
      active_config = nil
    end,
  }

  if not vim.tbl_isempty(env) then
    job_opts.env = env
  end

  job_id = vim.fn.jobstart(args, job_opts)

  if job_id <= 0 then
    job_id = nil
    return false, "Failed to start Pi RPC process"
  end

  active_config = start_config
  send_command({ type = "get_state" }, function(response)
    if response.success then
      update_state(response.data)
    end
  end)
  return true
end

function M.prompt(message, on_chunk, on_done)
  if current_prompt then
    on_done(nil, "Pi is already processing a prompt")
    return
  end

  current_prompt = {
    text = "",
    error = nil,
    on_chunk = on_chunk,
    on_done = on_done,
  }

  local _, err = send_command({
    type = "prompt",
    message = message,
  }, function(response)
    if not response.success then
      finish_prompt(nil, response.error)
    end
  end)

  if err then
    finish_prompt(nil, err)
  end
end

function M.set_model(provider, model_id, on_done)
  send_command({
    type = "set_model",
    provider = provider,
    modelId = model_id,
  }, function(response)
    if on_done then
      on_done(response.success, response.error)
    end
  end)
end

function M.set_thinking_level(level, on_done)
  send_command({
    type = "set_thinking_level",
    level = level,
  }, function(response)
    if on_done then
      on_done(response.success, response.error)
    end
  end)
end

function M.new_session(on_done)
  send_command({ type = "new_session" }, function(response)
    if response.success and response.data and response.data.cancelled then
      if on_done then
        on_done(false, "Pi new_session request was cancelled")
      end
    elseif response.success then
      send_command({ type = "get_state" }, function(state_response)
        if state_response.success then
          update_state(state_response.data)
        end
        if on_done then
          on_done(true, nil)
        end
      end)
    elseif on_done then
      on_done(false, response.error)
    end
  end)
end

function M.switch_session(session_file, on_done)
  send_command({
    type = "switch_session",
    sessionPath = session_file,
  }, function(response)
    if response.success and response.data and response.data.cancelled then
      if on_done then
        on_done(false, "Pi switch_session request was cancelled")
      end
    elseif response.success then
      send_command({ type = "get_state" }, function(state_response)
        if state_response.success then
          update_state(state_response.data)
        end
        if on_done then
          on_done(true, nil)
        end
      end)
    elseif on_done then
      on_done(false, response.error)
    end
  end)
end

function M.clone_session(on_done)
  send_command({ type = "clone" }, function(response)
    if response.success and response.data and response.data.cancelled then
      if on_done then
        on_done(false, "Pi clone request was cancelled")
      end
    elseif response.success then
      send_command({ type = "get_state" }, function(state_response)
        if state_response.success then
          update_state(state_response.data)
          if on_done then
            on_done(true, nil)
          end
        elseif on_done then
          on_done(false, state_response.error)
        end
      end)
    elseif on_done then
      on_done(false, response.error)
    end
  end)
end

function M.get_state(on_done)
  send_command({ type = "get_state" }, function(response)
    if response.success then
      update_state(response.data)
      if on_done then
        on_done(response.data, nil)
      end
    elseif on_done then
      on_done(nil, response.error)
    end
  end)
end

function M.get_commands(on_done)
  send_command({ type = "get_commands" }, function(response)
    if response.success then
      if on_done then
        on_done(response.data and response.data.commands or {}, nil)
      end
    elseif on_done then
      on_done(nil, response.error)
    end
  end)
end

return M
