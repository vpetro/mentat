local transport = require("mentat.transports.pi_rpc")
local editor_bridge = require("mentat.editor_bridge")
local prompt_loader = require("mentat.prompt_loader")
local models = require("mentat.models")
local boundary = require("mentat.async")
local fs = require("mentat.fs")
local async = vim.async

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
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
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

local function load_repo_system_prompt(root)
  if not root then
    return nil
  end

  return fs.read(root .. "/" .. M.config.system_prompt_file)
end

local function get_directory_tree(root)
  if not root then
    return nil
  end

  local cmd = string.format(
    "cd %s && (fd --type f --hidden --exclude .git --exclude node_modules --exclude .mentat 2>/dev/null || find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './.mentat/*' 2>/dev/null) | head -200 | sort",
    vim.fn.shellescape(root)
  )
  local result = boundary.system({ "sh", "-c", cmd }, { text = true })
  if result and result.stdout and result.stdout ~= "" then
    return result.stdout
  end
  return nil
end

function M.get_system_prompt(root)
  root = root or M.get_repo_root()
  local prompt_parts = {}

  local base_prompt = M.config.system_prompt or load_repo_system_prompt(root)
  if base_prompt then
    table.insert(prompt_parts, base_prompt)
  end

  local built_in_prompt = prompt_loader.read("system.md")
  if built_in_prompt then
    table.insert(prompt_parts, built_in_prompt)
  end

  local tree = get_directory_tree(root)
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

  local content, read_err = fs.read(path)
  if not content then
    return tostring(read_err)
  end
  local first, rest = content:match("^([^\n]*)\n(.*)$")
  local ok, header = pcall(vim.json.decode, first or content)
  if not ok or type(header) ~= "table" or header.type ~= "session" then
    return "Cloned Pi session has an invalid header"
  end
  header.parentSession = parent_session
  local written, write_err = fs.atomic_write(path, vim.json.encode(header) .. "\n" .. (rest or ""))
  return not written and tostring(write_err) or nil
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
  local system_prompt = M.get_system_prompt(repo_root)
  if not system_prompt or system_prompt == "" then
    return nil
  end

  local prompt_path = repo_root .. "/.mentat/pi/system_prompt.generated.md"
  ensure_parent_dir(prompt_path)

  local ok, err = fs.atomic_write(prompt_path, system_prompt)
  if not ok then
    error("Could not write Mentat system prompt: " .. tostring(err), 0)
  end
  return prompt_path
end

local function sync_transport_state()
  if transport.state.ready then
    M.session_file = transport.state.session_file
  end
end

transport.subscribe(sync_transport_state)

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
    default_selection = models.defaults(M.config),
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
    rpc_timeout_ms = M.config.pi.rpc_timeout_ms,
    prompt_asset_signatures = build_prompt_asset_signatures(prompt_asset_paths),
  }
end

local function start_config(root)
  root = root or M.get_repo_root() or vim.loop.cwd()
  return function()
    return build_transport_opts(root)
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  dbg("setup", vim.inspect(M.config))
  transport.stop()
end

function M.get_client()
  return transport
end

function M.prepare(on_done, root)
  return transport.ensure_started(start_config(root), on_done)
end

function M.clear(on_done)
  local previous = transport.state.session_id
  return transport.new_session(function(ok, err)
    local switched = previous ~= transport.state.session_id
    if ok or switched then
      M.messages = {}
    end
    if on_done then
      on_done(ok, err, switched)
    end
  end, start_config())
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

function M.chat(prompt, on_chunk, on_done, opts)
  opts = opts or {}
  local client = opts.client or transport
  if client.is_busy() then
    return false, "Pi is busy; wait for the current operation to settle"
  end
  local override
  if opts.slot then
    local err
    override, err = models.preset(M.config, opts.slot)
    if not override then
      return false, err
    end
  end
  return client.prompt(prompt, on_chunk, on_done, {
    start_config = client == transport and start_config() or nil,
    override = override,
    on_metadata = opts.on_metadata,
  })
end

function M.fork(on_done)
  local root = M.get_repo_root() or vim.loop.cwd()
  local client
  local task = async.run("mentat fork", function()
    async.await(vim.schedule)
    local ok, prepare_err = boundary.call(function(done)
      return M.prepare(done, root)
    end, false)
    if not ok then
      return nil, prepare_err
    end
    local inherited = transport.get_selection()
    local source = M.get_session_file()
    if M.config.pi.no_session or type(source) ~= "string" or vim.fn.filereadable(source) ~= 1 then
      source = nil
    end
    local opts = build_transport_opts(root)
    opts.session_file = source
    opts.default_selection = inherited
    client = transport.new()
    local started, start_err = boundary.call(function(done)
      return client.ensure_started(opts, done)
    end)
    if not started then
      return nil, start_err
    end
    if source then
      local cloned, clone_err = boundary.call(client.clone_session)
      if not cloned then
        return nil, clone_err
      end
    end
    local selected, selection_err = boundary.call(function(done)
      return client.set_selection(inherited, done)
    end)
    return selected and client or nil, selection_err, source
  end):detach()
  task:on_complete(function(task_err, forked, err, source)
    local function complete()
      if not forked and client then
        client.stop("Mentat branch closed")
      end
      if task_err ~= "closed" then
        on_done(forked, task_err and tostring(task_err) or err, source)
      end
    end
    if vim.in_fast_event() then
      vim.schedule(complete)
    else
      complete()
    end
  end)
  return task
end

function M.get_session_file()
  return transport.state.session_file or M.session_file
end

function M.switch_session(session_file, on_done, root)
  local accepted, err, task = transport.switch_session(session_file, on_done, start_config(root))
  if not accepted and on_done then
    on_done(false, err)
  end
  return accepted, err, task
end

function M.clone_session_from(session_file, on_done, parent_session, root)
  local accepted, err, task = transport.clone_from(session_file, on_done, {
    start_config = start_config(root),
    prepare_clone = function(path)
      return set_parent_session(path, parent_session)
    end,
  })
  if not accepted and on_done then
    on_done(false, err)
  end
  return accepted, err, task
end

function M.stop()
  transport.stop()
  editor_bridge.stop()
end

function M.restart()
  M.stop()
end

return M
