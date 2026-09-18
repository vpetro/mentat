local mentat = require("mentat")
local prompt_loader = require("mentat.prompt_loader")
local response_view = require("mentat.response")
local model_picker = require("mentat.model_picker")
local boundary = require("mentat.async")
local fs = require("mentat.fs")
local async = vim.async

local M = {}

local bufnr = nil
local buffer_tasks = {}
local pending_files = {}
local context_epoch = 0
local load_task
local save_task
local log_task
local logs = {}

local function own(task)
  buffer_tasks[task] = true
  task:on_complete(function(err)
    buffer_tasks[task] = nil
    boundary.report(err)
  end)
  return task
end

local function get_log_path(root)
  root = root or mentat.get_repo_root()
  if not root then return nil end

  local log_dir = root .. "/.mentat/logs"
  vim.fn.mkdir(log_dir, "p")

  local date = os.date("%Y-%m-%d")
  return log_dir .. "/" .. date .. ".md"
end

local function log_conversation(prompt, response, err, metadata, root)
  local path = get_log_path(root)
  if not path then return end
  local log = string.format("\n## %s\n\n### You\n\n%s\n\n### %s\n\n%s\n---\n",
    os.date("%H:%M:%S"), prompt, response_view.log_heading(metadata), response_view.body(response, metadata, err))
  logs[#logs + 1] = { path = path, text = log, written = 0 }
  if log_task then
    return
  end
  local task = async.run("mentat log", function()
    async.await(vim.schedule)
    while logs[1] do
      local entry = logs[1]
      if entry.written < #entry.text then
        local ok, write_err = fs.append(entry.path, entry.text:sub(entry.written + 1), function(count)
          entry.written = entry.written + count
        end)
        if not ok then
          return false, write_err
        end
      end
      table.remove(logs, 1)
    end
    return true
  end):detach()
  log_task = task
  task:on_complete(function(task_err, ok, write_err)
    if log_task == task then
      log_task = nil
    end
    boundary.report(task_err or (not ok and write_err or nil))
  end)
end

local function current_pid()
  return vim.fn.getpid()
end

local function ensure_parent_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

local function write_json_file(path, payload)
  ensure_parent_dir(path)
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(vim.fn.json_encode(payload))
  f:close()
  return true
end

local function read_json_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end

  local content = f:read("*a")
  f:close()

  local ok, payload = pcall(vim.json.decode, content)
  if not ok then
    return nil
  end
  return payload
end

local function instance_claim_dir(root)
  return root .. "/.mentat/pi/instances"
end

local function instance_claim_path(root, pid)
  return string.format("%s/%s.json", instance_claim_dir(root), tostring(pid))
end

local function is_process_alive(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then
    return false
  end

  local uv = vim.uv or vim.loop
  if not uv or not uv.kill then
    return false
  end

  local ok, result, err = pcall(uv.kill, pid, 0)
  if not ok then
    return false
  end

  return result == 0 or tostring(err or ""):match("EPERM") ~= nil
end

local function other_active_instance_claims(root)
  local current = current_pid()
  local dir = instance_claim_dir(root)
  local files = vim.split(vim.fn.glob(dir .. "/*.json"), "\n", { trimempty = true })
  local claims = {}

  for _, path in ipairs(files) do
    local claim = read_json_file(path)
    local pid = claim and tonumber(claim.pid) or tonumber(vim.fn.fnamemodify(path, ":t:r"))
    if pid and is_process_alive(pid) then
      if pid ~= current then
        table.insert(claims, claim or { pid = pid })
      end
    else
      os.remove(path)
    end
  end

  return claims
end

local function claim_instance(root, session_file)
  if not root then
    return
  end

  write_json_file(instance_claim_path(root, current_pid()), {
    pid = current_pid(),
    session_file = session_file,
    updated_at = os.time(),
  })
end

local function get_or_create_buf()
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    return bufnr
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end

  bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "Mentat")
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].modifiable = true
  model_picker.attach(bufnr, mentat.get_client())
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    buffer = bufnr,
    callback = function()
      context_epoch = context_epoch + 1
      for task in pairs(buffer_tasks) do
        task:close()
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    callback = function()
      vim.wo.foldmethod = "expr"
      vim.wo.foldexpr = "v:lua.require'mentat.buffer'.foldexpr(v:lnum)"
      vim.wo.foldtext = "v:lua.require'mentat.buffer'.foldtext()"
      vim.wo.foldenable = true
      vim.wo.foldlevel = 99
    end,
  })

  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd([[
      syntax match MentatHeaderYou /^##\{1,2} You$/
      syntax match MentatHeaderClaude /^##\{1,2} \(Claude\|Pi\)\( ([^)]*)\)\=$/
      highlight default link MentatHeaderYou Type
      highlight default link MentatHeaderClaude Function
    ]])
  end)

  local function collect_input()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local last_sep = 0
    for i, line in ipairs(lines) do
      if line:match("^%-%-%-$") then
        last_sep = i
      end
    end
    local prompt_lines = {}
    for i = last_sep + 1, #lines do
      table.insert(prompt_lines, lines[i])
    end
    local prompt = table.concat(prompt_lines, "\n")
    prompt = prompt:gsub("^%s+", ""):gsub("%s+$", "")
    if prompt == "" then
      return nil
    end
    return prompt, last_sep
  end

  local function submit(slot)
    local prompt, draft_start = collect_input()
    if prompt then
      M.send(prompt, slot, draft_start)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    submit()
  end, { buffer = bufnr, desc = "Send with selected model and thinking" })

  vim.keymap.set("n", "<S-CR>", function()
    submit("big")
  end, { buffer = bufnr, desc = "Use big for one request" })

  vim.keymap.set("n", "<leader>mp", function()
    M.promote()
  end, { buffer = bufnr, desc = "Re-send last prompt to big model" })

  -- Keymap: show loaded files
  vim.keymap.set("n", "<leader>mf", function()
    M.show_files()
  end, { buffer = bufnr, desc = "Show files in context" })

  -- Keymap: yank code block
  vim.keymap.set("n", "<leader>my", function()
    M.yank_code_block()
  end, { buffer = bufnr, desc = "Yank code block" })

  -- Keymap: navigation for code blocks
  vim.keymap.set("n", "]c", function()
    vim.cmd("normal! m'")
    vim.fn.search("^```", "W")
  end, { buffer = bufnr, desc = "Next code block" })

  vim.keymap.set("n", "[c", function()
    vim.cmd("normal! m'")
    vim.fn.search("^```", "bW")
  end, { buffer = bufnr, desc = "Previous code block" })

  return bufnr
end

-- Folding logic
function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match("^## ") then
    return ">1"
  end
  return "="
end

function M.foldtext()
  local fs = vim.v.foldstart
  local fe = vim.v.foldend
  local line = vim.fn.getline(fs)
  local title = line:gsub("^##%s*", "")
  
  -- If it's a timestamp, try to find the prompt to add to the fold text
  if title:match("^%d%d:%d%d:%d%d$") then
    -- Read a chunk of lines to find "### You" and the prompt
    local lines = vim.api.nvim_buf_get_lines(0, fs - 1, math.min(fs + 20, fe), false)
    for i, l in ipairs(lines) do
      if l:match("^##+ You") then
        -- Look for the next non-empty line
        for j = i + 1, #lines do
          local prompt_line = lines[j]:gsub("^%s+", "")
          if prompt_line ~= "" then
             -- Truncate prompt if too long
             if #prompt_line > 60 then
               prompt_line = prompt_line:sub(1, 60) .. "..."
             end
             title = title .. " | " .. prompt_line
             break
          end
        end
        break
      end
    end
  end
  
  return string.format(" > %s (%d lines) ", title, fe - fs + 1)
end

local function scroll_to_bottom(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

-- Yank code block under cursor
function M.yank_code_block()
  local buf = get_or_create_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  
  -- Find start (search backwards)
  local start_idx = nil
  for i = cursor_line, 1, -1 do
    if lines[i] and lines[i]:match("^```") then
      start_idx = i
      break
    end
  end
  
  if not start_idx then
    vim.notify("No code block start found", vim.log.levels.WARN)
    return
  end
  
  -- Find end (search forwards)
  local end_idx = nil
  for i = cursor_line + 1, #lines do
    if lines[i] and lines[i]:match("^```") then
      end_idx = i
      break
    end
  end
  
  if not end_idx then
    vim.notify("No code block end found", vim.log.levels.WARN)
    return
  end
  
  -- Extract content (excluding the backticks)
  local content_lines = {}
  for i = start_idx + 1, end_idx - 1 do
    table.insert(content_lines, lines[i])
  end
  
  local content = table.concat(content_lines, "\n")
  
  -- Use specified register or default to unnamed
  local reg = vim.v.register
  if reg == "" or reg == nil then reg = '"' end
  
  vim.fn.setreg(reg, content)
  vim.notify("Code block copied to register @" .. reg .. " (" .. #content_lines .. " lines)", vim.log.levels.INFO)
end

local function normalize_line_items(lines)
  local normalized = {}
  for _, item in ipairs(lines or {}) do
    local text = tostring(item or "")
    local parts = vim.split(text, "\n", { plain = true })
    for _, part in ipairs(parts) do
      table.insert(normalized, part)
    end
  end
  return normalized
end

local function append_lines(lines)
  local buf = get_or_create_buf()
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, normalize_line_items(lines))
  scroll_to_bottom(buf)
end

local function find_mentat_win()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

function M.target()
  return model_picker.target(get_or_create_buf())
end

function M.open(opts)
  local buf = get_or_create_buf()
  local win = find_mentat_win()
  if not win then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  end
  model_picker.refresh()
  if not (opts and opts.prepare == false) and not mentat.get_client().is_busy() then
    mentat.prepare(function(ok, err)
      if not ok and vim.api.nvim_buf_is_loaded(buf) then
        vim.notify(err, vim.log.levels.ERROR)
      end
    end, opts and opts.repo_root)
  end
end

function M.close()
  local win = find_mentat_win()
  if win then
    model_picker.invalidate(bufnr)
    vim.api.nvim_win_close(win, false)
  end
end

function M.toggle()
  local win = find_mentat_win()
  if win then
    M.close()
  else
    M.open()
  end
end

-- Context storage (files and selections)
M._contexts = {}

-- Show list of items in context
function M.show_context()
  M.open()
  if #M._contexts == 0 then
    append_lines({ "", "## Context", "", "*No context loaded. Use `:MentatFile <path>` or select code to add context.*", "", "---", "" })
  else
    local lines = { "", "## Context", "" }
    for i, item in ipairs(M._contexts) do
      if item.type == "file" then
        table.insert(lines, string.format("%d. [File] `%s`", i, item.path))
      elseif item.type == "selection" then
        table.insert(lines, string.format("%d. [Selection] %s:%d-%d", i, item.filename, item.start_line, item.end_line))
      elseif item.type == "diagnostics" then
        table.insert(lines, string.format("%d. [Diagnostics] %s (%d issues)", i, item.filename, item.count))
      end
    end
    table.insert(lines, "")
    table.insert(lines, "*Use `:MentatClearContext` to clear, or ask a question.*")
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
    append_lines(lines)
  end
end
-- Alias for backward compatibility
M.show_files = M.show_context

function M.add_file(filepath)
  local root = mentat.get_repo_root() or vim.uv.cwd()
  local expanded = vim.fn.expand(filepath)
  local path = vim.fn.fnamemodify(expanded, ":p")
  if pending_files[expanded] then
    vim.notify("File is already loading: " .. expanded, vim.log.levels.WARN)
    return
  end
  for _, item in ipairs(M._contexts) do
    if item.type == "file" and item.path == expanded then
      vim.notify("File already in context: " .. expanded, vim.log.levels.WARN)
      return
    end
  end
  local buf = get_or_create_buf()
  local epoch = context_epoch
  local task = own(async.run("mentat file context", function()
    async.await(vim.schedule)
    local content, err = fs.read(path)
    if not content then
      vim.notify("Cannot read file: " .. expanded .. ": " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if epoch ~= context_epoch or not vim.api.nvim_buf_is_loaded(buf) then
      return
    end
    local ext = vim.fn.fnamemodify(expanded, ":e")
    local filename = vim.fn.fnamemodify(expanded, ":t")
    M.open({ repo_root = root })
    append_lines({ "", "## File Added: " .. filename, "", "```" .. ext })
    append_lines(vim.split(content, "\n", { plain = true }))
    append_lines({ "```", "", "---", "" })
    table.insert(M._contexts, {
      type = "file",
      path = expanded,
      name = filename,
      content = content,
      ext = ext,
    })
    vim.notify("File added: " .. filename .. " (" .. #M._contexts .. " items in context)", vim.log.levels.INFO)
  end):detach())
  pending_files[expanded] = task
  task:on_complete(function()
    if pending_files[expanded] == task then
      pending_files[expanded] = nil
    end
  end)
  return task
end

-- Add a selection to context
function M.add_selection(lines, filetype, filename, start_line, end_line)
  local content = table.concat(lines, "\n")
  
  M.open()
  append_lines({
    "",
    string.format("## Selection Added: %s:%d-%d", filename, start_line, end_line),
    "",
    "```" .. (filetype or ""),
  })
  append_lines(lines)
  append_lines({ "```", "", "---", "" })

  table.insert(M._contexts, {
    type = "selection",
    content = content,
    ext = filetype,
    filename = filename,
    start_line = start_line,
    end_line = end_line
  })
  
  vim.notify("Selection added (" .. #M._contexts .. " items in context)", vim.log.levels.INFO)
end

-- Add diagnostics for a buffer as a context item
function M.add_diagnostics(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not path or path == "" then
    vim.notify("Buffer has no file path", vim.log.levels.WARN)
    return
  end

  local severity_names = {
    [vim.diagnostic.severity.ERROR] = "error",
    [vim.diagnostic.severity.WARN]  = "warn",
    [vim.diagnostic.severity.INFO]  = "info",
    [vim.diagnostic.severity.HINT]  = "hint",
  }

  local diags = vim.diagnostic.get(bufnr)
  local filename = vim.fn.fnamemodify(path, ":t")

  if #diags == 0 then
    vim.notify("No diagnostics for " .. filename, vim.log.levels.INFO)
    return
  end

  local diag_lines = {}
  for _, d in ipairs(diags) do
    table.insert(diag_lines, string.format("%d:%d [%s] %s%s",
      d.lnum + 1, d.col + 1,
      severity_names[d.severity] or "?",
      d.message,
      d.source and (" (" .. d.source .. ")") or ""))
  end

  M.open()
  append_lines({
    "",
    string.format("## Diagnostics: %s (%d)", filename, #diags),
    "",
    "```",
  })
  append_lines(diag_lines)
  append_lines({ "```", "", "---", "" })

  table.insert(M._contexts, {
    type     = "diagnostics",
    path     = path,
    filename = filename,
    content  = table.concat(diag_lines, "\n"),
    count    = #diags,
  })

  vim.notify(
    string.format("Diagnostics added: %s (%d issues)", filename, #diags),
    vim.log.levels.INFO)
end

function M.clear_context()
  context_epoch = context_epoch + 1
  for _, task in pairs(pending_files) do
    task:close()
  end
  M._contexts = {}
  vim.notify("Context cleared", vim.log.levels.INFO)
end
-- Alias for backward compatibility
M.clear_files = M.clear_context

local function build_hidden_tool_hint()
  return prompt_loader.read("runtime_hint.md") or ""
end

function M.send(prompt, slot, draft_start)
  local root = mentat.get_repo_root()
  local actual_prompt = prompt_loader.render("runtime_user_request.md", {
    hint = build_hidden_tool_hint(),
    prompt = prompt,
  }) or prompt
  if #M._contexts > 0 then
    local context_parts = {}
    for _, item in ipairs(M._contexts) do
      if item.type == "file" then
        table.insert(context_parts, string.format(
          "File: %s\n```%s\n%s\n```",
          item.path,
          item.ext,
          item.content
        ))
      elseif item.type == "selection" then
        table.insert(context_parts, string.format(
          "Snippet from %s (lines %d-%d):\n```%s\n%s\n```",
          item.filename,
          item.start_line,
          item.end_line,
          item.ext,
          item.content
        ))
      elseif item.type == "diagnostics" then
        table.insert(context_parts, string.format(
          "LSP diagnostics for %s (%d issues):\n%s",
          item.path,
          item.count,
          item.content
        ))
      end
    end
    actual_prompt = prompt_loader.render("runtime_context_request.md", {
      hint = build_hidden_tool_hint(),
      context = table.concat(context_parts, "\n\n"),
      prompt = prompt,
    }) or actual_prompt
  end

  local full_response = ""
  local view
  local accepted, err = mentat.chat(actual_prompt,
    function(chunk)
      full_response = full_response .. chunk
      view.chunk(chunk)
    end,
    function(_, rpc_err, metadata)
      claim_instance(root, mentat.get_session_file())
      view.finish(metadata, rpc_err)
      log_conversation(prompt, full_response, rpc_err, metadata, root)
    end,
    { slot = slot }
  )
  if not accepted then
    vim.notify(err, vim.log.levels.WARN)
    return false, err
  end
  M.open()
  local buf = get_or_create_buf()
  if draft_start then
    vim.api.nvim_buf_set_lines(buf, draft_start, -1, false, {})
  end
  view = response_view.start(buf, prompt)
  M._last_prompt = prompt
  claim_instance(root, mentat.get_session_file())
  return true
end

function M.promote()
  if not M._last_prompt then
    vim.notify("No prompt to promote yet", vim.log.levels.WARN)
    return
  end
  M.send(M._last_prompt, "big")
end

function M.clear()
  local root = mentat.get_repo_root()
  local accepted, err = mentat.clear(function(ok, rpc_err, switched)
    if ok or switched then
      context_epoch = context_epoch + 1
      for _, task in pairs(pending_files) do
        task:close()
      end
      M._contexts = {}
      M._last_prompt = nil
      claim_instance(root, mentat.get_session_file())
      if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# Mentat Chat", "" })
      end
    end
    if not ok then
      vim.notify(rpc_err, vim.log.levels.ERROR)
    end
  end)
  if not accepted then
    vim.notify(err, vim.log.levels.WARN)
  end
  return accepted, err
end

local function restore_history_from_content(content)
  local messages = {}
  local lines = vim.split(content, "\n")
  local current_role = nil
  local buffer = {}
  
  for _, line in ipairs(lines) do
    if line:match("^### You$") or line:match("^## You$") then
      if current_role then
         local text = table.concat(buffer, "\n")
         text = text:gsub("^%s*(.-)%s*$", "%1") -- trim
         if text ~= "" then
           table.insert(messages, { role = current_role, content = text })
         end
      end
      current_role = "user"
      buffer = {}
    elseif line:match("^###? Claude$") or line:match("^###? Pi$") or line:match("^###? Pi %(.*%)$") then
      if current_role then
         local text = table.concat(buffer, "\n")
         text = text:gsub("^%s*(.-)%s*$", "%1") -- trim
         if text ~= "" then
           table.insert(messages, { role = current_role, content = text })
         end
      end
      current_role = "assistant"
      buffer = {}
    elseif line:match("^## %d%d:%d%d:%d%d$") or line:match("^%-%-%-$") then
       -- Separator/Header ends current message
       if current_role then
         local text = table.concat(buffer, "\n")
         text = text:gsub("^%s*(.-)%s*$", "%1") -- trim
         if text ~= "" then
            table.insert(messages, { role = current_role, content = text })
         end
      end
      current_role = nil
      buffer = {}
    else
      if current_role then
        table.insert(buffer, line)
      end
    end
  end
  
  -- Handle last block
  if current_role and #buffer > 0 then
     local text = table.concat(buffer, "\n")
     text = text:gsub("^%s*(.-)%s*$", "%1")
     if text ~= "" then
        table.insert(messages, { role = current_role, content = text })
     end
  end

  mentat.messages = messages
end

function M.load_last_session()
  local root = mentat.get_repo_root()
  if not root then return end
  local log_dir = root .. "/.mentat/logs"
  local buf = get_or_create_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if load_task then
    load_task:close()
  end
  load_task = own(async.run("mentat load log", function()
    async.await(vim.schedule)
    local entries = fs.list(log_dir)
    local files = {}
    for _, entry in ipairs(entries or {}) do
      if entry.name:match("%.md$") then
        files[#files + 1] = entry.name
      end
    end
    if #files == 0 then
      vim.notify("No session logs found.", vim.log.levels.WARN)
      return
    end
    table.sort(files)
    local last_log = files[#files]
    local content, err = fs.read(log_dir .. "/" .. last_log)
    if not content then
      vim.notify("Could not read log file: " .. last_log .. ": " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_buf_is_loaded(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
      vim.notify("The conversation changed; load the log again", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
    scroll_to_bottom(buf)
    M.open({ repo_root = root })
    restore_history_from_content(content)
    vim.notify("Loaded session: " .. last_log, vim.log.levels.INFO)
  end):detach())
  return load_task
end

local function state_snapshot()
  local session_file = mentat.get_session_file()
  if not bufnr and not session_file and vim.tbl_isempty(mentat.messages) and vim.tbl_isempty(M._contexts) then
    return
  end

  local root = mentat.get_repo_root()
  if not root then return end
  local state_file = root .. "/.mentat/state.json"

  local content = ""
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    content = table.concat(lines, "\n")
  end

  local state = {
    messages = mentat.messages,
    pi_session_file = session_file,
    pi_selection = mentat.get_client().get_selection(),
    pi_restore_selection = mentat.get_client().get_restore_selection(),
    contexts = M._contexts,
    buffer_content = content
  }

  return root, state_file, state
end

function M.save_state()
  local root, path, state = state_snapshot()
  if not root then return end
  local content = vim.json.encode(state)
  if save_task then
    save_task:close()
  end
  local task = async.run("mentat save state", function()
    async.await(vim.schedule)
    ensure_parent_dir(path)
    local ok, err = fs.atomic_write(path, content)
    if ok then
      claim_instance(root, state.pi_session_file)
    end
    return ok, err
  end):detach()
  save_task = task
  task:on_complete(function(task_err, ok, err)
    if save_task == task then
      save_task = nil
    end
    boundary.report(task_err or (not ok and err or nil))
  end)
  return task
end

function M.save_state_sync()
  if save_task then
    save_task:close()
  end
  if log_task then
    log_task:close()
  end
  while logs[1] do
    local entry = logs[1]
    if entry.written < #entry.text then
      local ok, err = fs.append_sync(entry.path, entry.text:sub(entry.written + 1), function(count)
        entry.written = entry.written + count
      end)
      if not ok then
        vim.notify("Could not save Mentat log: " .. tostring(err), vim.log.levels.ERROR)
        break
      end
    end
    table.remove(logs, 1)
  end
  local root, path, state = state_snapshot()
  if root then
    write_json_file(path, state)
    claim_instance(root, state.pi_session_file)
  end
end

function M.load_state()
  local client = mentat.get_client()
  if client.is_busy() then
    vim.notify("Pi is busy; wait before loading a session", vim.log.levels.WARN)
    return
  end
  local root = mentat.get_repo_root()
  if not root then return end
  local buf = get_or_create_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local revision = client.state.revision
  if load_task then
    load_task:close()
  end
  load_task = own(async.run("mentat load state", function()
    async.await(vim.schedule)
    local content, read_err = fs.read(root .. "/.mentat/state.json")
    if not content then
      if not (read_err and read_err:find("ENOENT", 1, true)) then
        vim.notify("Could not load Mentat state: " .. tostring(read_err), vim.log.levels.ERROR)
      end
      return
    end
    local decoded, state = pcall(vim.json.decode, content)
    if not decoded or type(state) ~= "table" then
      vim.notify("Could not load Mentat state: invalid JSON", vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_buf_is_loaded(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick or client.state.revision ~= revision then
      vim.notify("The conversation changed; load the state again", vim.log.levels.WARN)
      return
    end
    local current = mentat.get_session_file()
    local reuse = #other_active_instance_claims(root) == 0
    local saved = type(state.pi_session_file) == "string" and state.pi_session_file or nil
    local recovery = type(state.pi_restore_selection) == "table" and state.pi_restore_selection or nil
    if not recovery and (not saved or vim.fn.filereadable(saved) ~= 1) and type(state.pi_selection) == "table" then
      recovery = state.pi_selection
    end
    local ok, err
    if reuse and saved and current then
      ok, err = boundary.call(function(done)
        return mentat.switch_session(saved, done, root)
      end)
      if ok and recovery then
        client.restore_settings(recovery)
        ok, err = boundary.call(function(done)
          return mentat.prepare(done, root)
        end)
      end
    else
      if reuse then
        mentat.session_file = saved
        if recovery then
          client.restore_settings(recovery)
        end
      end
      ok, err = boundary.call(function(done)
        return mentat.prepare(done, root)
      end)
    end
    if not ok then
      vim.notify("Could not load Mentat state: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
      vim.notify("The draft changed while loading state; its text was kept", vim.log.levels.WARN)
      return
    end
    context_epoch = context_epoch + 1
    mentat.messages = type(state.messages) == "table" and state.messages or {}
    M._contexts = type(state.contexts) == "table" and state.contexts or {}
    M._last_prompt = nil
    claim_instance(root, mentat.get_session_file())
    if type(state.buffer_content) == "string" and state.buffer_content ~= "" then
      model_picker.invalidate(buf)
      local lines = vim.split(state.buffer_content, "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      scroll_to_bottom(buf)
      if #lines > 1 then
        M.open({ prepare = false })
      end
    end
    if not reuse and saved then
      vim.notify("Mentat is using a separate Pi session because another Neovim instance is active for this repo.", vim.log.levels.INFO)
    end
  end):detach())
  return load_task
end

function M.release_instance_claim()
  local root = mentat.get_repo_root()
  if not root then
    return
  end

  os.remove(instance_claim_path(root, current_pid()))
end

return M
