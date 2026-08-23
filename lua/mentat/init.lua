local transport = require("mentat.transports.pi_rpc")
local editor_bridge = require("mentat.editor_bridge")
local prompt_loader = require("mentat.prompt_loader")

local M = {}

M.debug = false
M.backend_name = "pi"
M.messages = {}
M.session_file = nil
M.repo_root = nil
M.plugin_root = nil

local function dbg(...)
  if M.debug then
    print("[mentat]", ...)
  end
end

local function get_plugin_root()
  if M.plugin_root then
    return M.plugin_root
  end

  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end

  local root = vim.fn.fnamemodify(source, ":p:h:h:h")
  M.plugin_root = root
  return root
end

M.config = {
  provider = nil,
  model = nil,
  thinking = nil,
  slots = {},
  default_slot = "quick",
  system_prompt = nil,
  system_prompt_file = ".mentat/system_prompt.md",
  pi = {
    cmd = "pi",
    offline = true,
    no_session = false,
    agent_dir = nil,
    session_dir = ".mentat/pi/sessions",
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
    extra_args = {},
  },
}

local function find_git_root(path)
  while path and path ~= "/" and path ~= "." do
    local marker = path .. "/.git"
    if vim.fn.isdirectory(marker) == 1 or vim.fn.filereadable(marker) == 1 then
      return path
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then
      break
    end
    path = parent
  end

  return nil
end

function M.capture_repo_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return M.repo_root
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return M.repo_root
  end

  local path = vim.fn.fnamemodify(name, ":p:h")
  local root = find_git_root(path)
  if root then
    M.repo_root = root
  end

  return M.repo_root
end

function M.get_repo_root()
  local current_root = M.capture_repo_root(vim.api.nvim_get_current_buf())
  if current_root then
    return current_root
  end

  if M.repo_root then
    return M.repo_root
  end

  local cwd_root = find_git_root(vim.loop.cwd())
  if cwd_root then
    M.repo_root = cwd_root
    return cwd_root
  end

  return nil
end

local function load_repo_system_prompt()
  local root = M.get_repo_root()
  if not root then
    return nil
  end

  local prompt_path = root .. "/" .. M.config.system_prompt_file
  local handle = io.open(prompt_path, "r")
  if not handle then
    return nil
  end

  local content = handle:read("*a")
  handle:close()
  return content
end

local function get_directory_tree()
  local root = M.get_repo_root()
  if not root then
    return nil
  end

  local cmd = string.format(
    "cd %s && (fd --type f --hidden --exclude .git --exclude node_modules --exclude .mentat 2>/dev/null || find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './.mentat/*' 2>/dev/null) | head -200 | sort",
    vim.fn.shellescape(root)
  )
  local handle = io.popen(cmd)
  if not handle then
    return nil
  end

  local result = handle:read("*a")
  handle:close()

  if result and result ~= "" then
    return result
  end
  return nil
end

function M.get_system_prompt()
  local prompt_parts = {}

  local base_prompt = M.config.system_prompt or load_repo_system_prompt()
  if base_prompt then
    table.insert(prompt_parts, base_prompt)
  end

  local built_in_prompt = prompt_loader.read("system.md")
  if built_in_prompt then
    table.insert(prompt_parts, built_in_prompt)
  end

  local tree = get_directory_tree()
  if tree then
    local project_structure = prompt_loader.render("project_structure.md", {
      tree = tree,
    })
    if project_structure then
      table.insert(prompt_parts, project_structure)
    end
  end

  if #prompt_parts == 0 then
    return nil
  end

  return table.concat(prompt_parts, "\n")
end

local function ensure_parent_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

local function resolve_repo_path(path, repo_root)
  if not path or path == "" then
    return nil
  end

  if path:match("^/") then
    return path
  end

  return (repo_root or vim.loop.cwd()) .. "/" .. path
end

local function set_parent_session(path, parent_session)
  if not parent_session then
    return nil
  end
  if type(path) ~= "string" or path == "" then
    return "Pi did not create a cloned session file"
  end

  local input, open_err = io.open(path, "r")
  if not input then
    return tostring(open_err)
  end
  local first = input:read("*l")
  local rest = input:read("*a") or ""
  input:close()

  local ok, header = pcall(vim.json.decode, first or "")
  if not ok or type(header) ~= "table" or header.type ~= "session" then
    return "Cloned Pi session has an invalid header"
  end
  header.parentSession = parent_session

  local temp = string.format("%s.mentat-%s", path, tostring((vim.uv or vim.loop).hrtime()))
  local output, write_err = io.open(temp, "w")
  if not output then
    return tostring(write_err)
  end
  output:write(vim.json.encode(header), "\n", rest)
  output:close()
  local uv = vim.uv or vim.loop
  uv.fs_chmod(temp, 384)

  local renamed, rename_err = os.rename(temp, path)
  if not renamed then
    vim.fn.delete(temp)
    return tostring(rename_err)
  end
  return nil
end

local function stat_signature(path)
  if not path then
    return "missing"
  end

  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat then
    return "missing"
  end

  local mtime = stat.mtime or {}
  local sec = type(mtime) == "table" and (mtime.sec or 0) or mtime or 0
  local nsec = type(mtime) == "table" and (mtime.nsec or 0) or 0
  return table.concat({
    tostring(stat.size or 0),
    tostring(sec),
    tostring(nsec),
  }, ":")
end

local function build_prompt_asset_signatures(paths)
  local signatures = {}
  for _, path in ipairs(paths or {}) do
    signatures[path] = stat_signature(path)
  end
  return signatures
end

local function build_extension_signatures(extensions, repo_root)
  local signatures = {}
  for _, extension in ipairs(extensions or {}) do
    signatures[extension] = stat_signature(resolve_repo_path(extension, repo_root))
  end
  return signatures
end

local function prepare_system_prompt_file(repo_root)
  local system_prompt = M.get_system_prompt()
  if not system_prompt or system_prompt == "" then
    return nil
  end

  local prompt_path = repo_root .. "/.mentat/pi/system_prompt.generated.md"
  ensure_parent_dir(prompt_path)

  local handle = io.open(prompt_path, "w")
  if not handle then
    return nil
  end

  handle:write(system_prompt)
  handle:close()
  return prompt_path
end

local function sync_transport_state()
  M.session_file = transport.state.session_file or M.session_file
end

local function build_transport_opts(repo_root)
  local prompt_path = prepare_system_prompt_file(repo_root)
  local bridge_env = editor_bridge.get_env(repo_root)
  local plugin_root = get_plugin_root()
  local built_in_extensions = {
    plugin_root .. "/pi/extensions/editor-tools.ts",
  }
  local prompt_asset_paths = {
    prompt_loader.path("system.md"),
    prompt_loader.path("project_structure.md"),
    prompt_loader.path("runtime_hint.md"),
    prompt_loader.path("runtime_user_request.md"),
    prompt_loader.path("runtime_context_request.md"),
    plugin_root .. "/pi/extensions/prompt-loader.ts",
    plugin_root .. "/pi/prompts/editor-tools.json",
  }
  local seen_extensions = {}
  local extensions = {}
  for _, extension in ipairs(M.config.pi.extensions or {}) do
    if not seen_extensions[extension] then
      seen_extensions[extension] = true
      table.insert(extensions, extension)
    end
  end
  for _, extension in ipairs(built_in_extensions) do
    if not seen_extensions[extension] then
      seen_extensions[extension] = true
      table.insert(extensions, extension)
    end
  end

  return {
    repo_root = repo_root,
    cmd = M.config.pi.cmd,
    provider = M.config.provider,
    model = M.config.model,
    thinking = M.config.thinking,
    offline = M.config.pi.offline,
    no_session = M.config.pi.no_session,
    agent_dir = M.config.pi.agent_dir,
    session_dir = M.config.pi.session_dir,
    session_file = M.session_file,
    no_extensions = M.config.pi.no_extensions,
    extensions = extensions,
    extension_signatures = build_extension_signatures(extensions, repo_root),
    no_skills = M.config.pi.no_skills,
    skills = M.config.pi.skills,
    no_prompt_templates = M.config.pi.no_prompt_templates,
    prompt_templates = M.config.pi.prompt_templates,
    no_themes = M.config.pi.no_themes,
    themes = M.config.pi.themes,
    no_tools = M.config.pi.no_tools,
    tools = M.config.pi.tools,
    append_system_prompt = prompt_path,
    env = bridge_env,
    extra_args = M.config.pi.extra_args,
    prompt_asset_signatures = build_prompt_asset_signatures(prompt_asset_paths),
  }
end

local function ensure_transport(overrides)
  local repo_root = M.get_repo_root() or vim.loop.cwd()
  local opts = build_transport_opts(repo_root)
  if overrides then
    opts = vim.tbl_deep_extend("force", opts, overrides)
  end
  local ok, err = transport.ensure_started(opts)
  if not ok then
    return nil, err
  end

  sync_transport_state()
  return repo_root
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  dbg("setup", vim.inspect(M.config))
  transport.stop()
end

function M.clear()
  M.messages = {}

  local _, err = ensure_transport()
  if err then
    M.session_file = nil
    return
  end

  transport.new_session(function(ok, rpc_err)
    if ok then
      sync_transport_state()
    else
      vim.schedule(function()
        vim.notify("Failed to start a new Pi session: " .. tostring(rpc_err), vim.log.levels.ERROR)
      end)
    end
  end)
end

function M.resolve_slot(name)
  local slots = M.config.slots or {}
  return slots[name or M.config.default_slot]
end

function M.slot_label(slot)
  if not slot then
    return nil
  end
  if slot.label then
    return slot.label
  end

  local id = (slot.model or ""):gsub("^[^/]+/", ""):gsub("^claude%-", "")
  if id == "" then
    return nil
  end
  return id
end

local function split_slot_model(slot)
  local provider, id = (slot.model or ""):match("^([^/]+)/(.+)$")
  if provider then
    return provider, id
  end
  return slot.provider or M.config.provider, slot.model
end

local function apply_slot(slot, on_done)
  if not slot or not slot.model then
    on_done(true, nil)
    return
  end

  local provider, model_id = split_slot_model(slot)
  if not provider then
    on_done(false, "Slot needs a provider: set slot.provider, config.provider, or use provider/model")
    return
  end

  transport.set_model(provider, model_id, function(ok, err)
    if not ok then
      on_done(false, string.format("Failed to switch model to %s: %s", model_id, tostring(err)))
      return
    end

    if not slot.thinking then
      on_done(true, nil)
      return
    end

    transport.set_thinking_level(slot.thinking, function(thinking_ok, thinking_err)
      if not thinking_ok then
        on_done(false, "Failed to set thinking level: " .. tostring(thinking_err))
        return
      end
      on_done(true, nil)
    end)
  end)
end

function M.chat(prompt, on_chunk, on_done, history, opts)
  if history and #history > 0 then
    on_done(nil, "Branch conversations are not supported with the Pi backend yet")
    return
  end

  local _, err = ensure_transport()
  if err then
    on_done(nil, err)
    return
  end

  local slot = M.resolve_slot(opts and opts.slot)
  apply_slot(slot, function(ok, slot_err)
    if not ok then
      on_done(nil, slot_err)
      return
    end

    transport.prompt(prompt, on_chunk, function(text, rpc_err)
      sync_transport_state()
      on_done(text, rpc_err)
    end)
  end)
end

function M.get_session_file()
  return transport.state.session_file or M.session_file
end

function M.switch_session(session_file, on_done)
  M.session_file = session_file

  local _, err = ensure_transport()
  if err then
    if on_done then
      on_done(false, err)
    end
    return
  end

  transport.switch_session(session_file, function(ok, rpc_err)
    if ok then
      sync_transport_state()
    end
    if on_done then
      on_done(ok, rpc_err)
    end
  end)
end

function M.clone_session_from(session_file, on_done, parent_session)
  local previous_session = M.get_session_file()
  transport.stop()
  transport.state.session_file = session_file
  M.session_file = session_file

  local _, err = ensure_transport({
    no_extensions = true,
    no_skills = true,
    no_prompt_templates = true,
    no_themes = true,
  })
  if err then
    transport.state.session_file = previous_session
    M.session_file = previous_session
    if on_done then
      on_done(false, err)
    end
    return
  end

  transport.clone_session(function(ok, rpc_err)
    if not ok then
      transport.stop()
      transport.state.session_file = previous_session
      M.session_file = previous_session
      if on_done then
        on_done(false, rpc_err)
      end
      return
    end

    sync_transport_state()
    local cloned_session = M.get_session_file()
    transport.stop()

    local parent_err = set_parent_session(cloned_session, parent_session)
    if parent_err then
      vim.fn.delete(cloned_session)
      transport.state.session_file = previous_session
      M.session_file = previous_session
      if on_done then
        on_done(false, parent_err)
      end
      return
    end

    transport.state.session_file = cloned_session
    M.session_file = cloned_session

    local _, restart_err = ensure_transport()
    if on_done then
      on_done(restart_err == nil, restart_err)
    end
  end)
end

function M.supports_branching()
  return false
end

function M.stop()
  transport.stop()
  editor_bridge.stop()
end

function M.restart()
  M.stop()
end

return M
