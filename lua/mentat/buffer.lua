local mentat = require("mentat")
local prompt_loader = require("mentat.prompt_loader")

local M = {}

local bufnr = nil
local ASSISTANT_NAME = "Pi"

-- Logging functions
local function get_log_path()
  local root = mentat.get_repo_root()
  if not root then return nil end

  local log_dir = root .. "/.mentat/logs"
  vim.fn.mkdir(log_dir, "p")

  local date = os.date("%Y-%m-%d")
  return log_dir .. "/" .. date .. ".md"
end

local function log_to_file(text)
  local path = get_log_path()
  if not path then return end

  local f = io.open(path, "a")
  if not f then return end
  f:write(text)
  f:close()
end

local function assistant_heading(label)
  if label then
    return string.format("%s (%s)", ASSISTANT_NAME, label)
  end
  return ASSISTANT_NAME
end

local function log_conversation(prompt, response, err, label)
  local timestamp = os.date("%H:%M:%S")
  local log = string.format("\n## %s\n\n### You\n\n%s\n\n### %s\n\n%s\n\n---\n",
    timestamp,
    prompt,
    assistant_heading(label),
    err and ("**Error:** " .. err) or response
  )
  log_to_file(log)
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
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end

  bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "Mentat")
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].modifiable = true

  -- Configure folding (must be done in window context)
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
    vim.api.nvim_buf_set_lines(bufnr, last_sep, -1, false, {})
    return prompt
  end

  local function submit(slot)
    local prompt = collect_input()
    if prompt then
      M.send(prompt, slot)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    submit("quick")
  end, { buffer = bufnr, desc = "Send prompt (quick model)" })

  vim.keymap.set("n", "<S-CR>", function()
    submit("big")
  end, { buffer = bufnr, desc = "Send prompt (big model)" })

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

local function append_chunk(text)
  local buf = get_or_create_buf()

  local last_line = vim.api.nvim_buf_line_count(buf)
  local current = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1] or ""

  -- Preserve trailing empty lines so streamed markdown keeps its paragraph and code fence structure.
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })

  if #lines == 0 then
    return
  end

  -- first part appends to current line
  lines[1] = current .. lines[1]
  vim.api.nvim_buf_set_lines(buf, last_line - 1, last_line, false, lines)
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

function M.open()
  local buf = get_or_create_buf()
  local win = find_mentat_win()
  if not win then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  end
end

function M.close()
  local win = find_mentat_win()
  if win then
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

-- Read a file and add it to context
function M.add_file(filepath)
  local expanded = vim.fn.expand(filepath)

  -- Check if already added
  for _, item in ipairs(M._contexts) do
    if item.type == "file" and item.path == expanded then
      vim.notify("File already in context: " .. expanded, vim.log.levels.WARN)
      return
    end
  end

  local f = io.open(expanded, "r")
  if not f then
    vim.notify("Cannot read file: " .. expanded, vim.log.levels.ERROR)
    return
  end

  local content = f:read("*a")
  f:close()

  -- Detect filetype for syntax highlighting hint
  local ext = vim.fn.fnamemodify(expanded, ":e")
  local filename = vim.fn.fnamemodify(expanded, ":t")

  M.open()
  append_lines({
    "",
    "## File Added: " .. filename,
    "",
    "```" .. ext,
  })

  -- Split content into lines
  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  append_lines(lines)
  append_lines({ "```", "", "---", "" })

  -- Store context
  table.insert(M._contexts, {
    type = "file",
    path = expanded,
    name = filename,
    content = content,
    ext = ext,
  })

  vim.notify("File added: " .. filename .. " (" .. #M._contexts .. " items in context)", vim.log.levels.INFO)
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

-- Clear contexts
function M.clear_context()
  M._contexts = {}
  vim.notify("Context cleared", vim.log.levels.INFO)
end
-- Alias for backward compatibility
M.clear_files = M.clear_context

local function build_hidden_tool_hint()
  return prompt_loader.read("runtime_hint.md") or ""
end

function M.send(prompt, slot)
  M.open()
  claim_instance(mentat.get_repo_root(), mentat.get_session_file())
  M._last_prompt = prompt
  local label = mentat.slot_label(mentat.resolve_slot(slot))
  local prompt_lines = {}
  for line in (prompt .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(prompt_lines, line)
  end
  local header = { "", "## You", "" }
  local footer = { "", "---", "", "## " .. assistant_heading(label), "" }
  vim.list_extend(header, prompt_lines)
  vim.list_extend(header, footer)
  append_lines(header)

  -- Add invisible runtime guidance so Pi prefers editor-aware tools for "current file" requests.
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

  mentat.chat(actual_prompt,
    function(chunk)
      full_response = full_response .. chunk
      append_chunk(chunk)
    end,
    function(_, err)
      claim_instance(mentat.get_repo_root(), mentat.get_session_file())
      if err then
        append_lines({ "", "**Error:** " .. err })
      else
        append_lines({ "", "", "---" })
      end
      log_conversation(prompt, full_response, err, label)
    end,
    { slot = slot }
  )
end

function M.promote()
  if not M._last_prompt then
    vim.notify("No prompt to promote yet", vim.log.levels.WARN)
    return
  end
  M.send(M._last_prompt, "big")
end

function M.clear()
  mentat.clear()
  M._contexts = {}
  claim_instance(mentat.get_repo_root(), mentat.get_session_file())
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# Mentat Chat", "" })
  end
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
  
  local files = vim.split(vim.fn.glob(log_dir .. "/*.md"), "\n", { trimempty = true })
  if #files == 0 then
    vim.notify("No session logs found.", vim.log.levels.WARN)
    return
  end
  
  table.sort(files)
  local last_log = files[#files]
  
  local f = io.open(last_log, "r")
  if not f then 
    vim.notify("Could not read log file: " .. last_log, vim.log.levels.ERROR)
    return 
  end
  local content = f:read("*a")
  f:close()
  
  -- Restore buffer content
  local buf = get_or_create_buf()
  local lines = vim.split(content, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  scroll_to_bottom(buf)
  M.open()
  
  -- Restore transcript history
  restore_history_from_content(content)
  
  vim.notify("Loaded session: " .. vim.fn.fnamemodify(last_log, ":t"), vim.log.levels.INFO)
end

function M.save_state()
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
    contexts = M._contexts,
    buffer_content = content
  }

  write_json_file(state_file, state)
  claim_instance(root, state.pi_session_file)
end

function M.load_state()
  local root = mentat.get_repo_root()
  if not root then return end
  local state_file = root .. "/.mentat/state.json"
  
  local f = io.open(state_file, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  
  local ok, state = pcall(vim.json.decode, content)
  if not ok or not state then return end
  
  local current_session_file = mentat.get_session_file()
  local other_instances = other_active_instance_claims(root)
  local reuse_saved_session = #other_instances == 0
  mentat.messages = state.messages or {}
  if reuse_saved_session then
    mentat.session_file = state.pi_session_file or nil
  elseif not current_session_file then
    mentat.session_file = nil
  end
  M._contexts = state.contexts or {}

  if reuse_saved_session and state.pi_session_file and current_session_file and current_session_file ~= state.pi_session_file then
    mentat.switch_session(state.pi_session_file)
  end

  claim_instance(root, mentat.get_session_file())
  
  if state.buffer_content and state.buffer_content ~= "" then
     local buf = get_or_create_buf()
     local lines = vim.split(state.buffer_content, "\n")
     vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
     scroll_to_bottom(buf)
     -- Ensure window is open if we have content
     if #lines > 1 then
       M.open()
     end
  end

  if not reuse_saved_session and state.pi_session_file then
    vim.schedule(function()
      vim.notify(
        "Mentat opened a fresh Pi session because another Neovim instance is already active for this repo.",
        vim.log.levels.INFO
      )
    end)
  end
end

function M.release_instance_claim()
  local root = mentat.get_repo_root()
  if not root then
    return
  end

  os.remove(instance_claim_path(root, current_pid()))
end

return M
