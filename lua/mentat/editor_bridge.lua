local lsp = require("mentat.lsp")

local uv = vim.uv or vim.loop

local M = {
  state = {
    repo_root = nil,
    host = "127.0.0.1",
    port = nil,
  },
}

local server = nil
local cleanup_registered = false

local function get_repo_root()
  local path = vim.fn.expand("%:p:h")
  if not path or path == "" then
    path = vim.loop.cwd()
  end

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

  return vim.loop.cwd()
end

local function normalize_path(path, repo_root)
  if not path or path == "" then
    return nil
  end

  if path:match("^/") then
    return vim.fn.fnamemodify(path, ":p")
  end

  local root = repo_root or get_repo_root()
  return vim.fn.fnamemodify(root .. "/" .. path, ":p")
end

local function rel_path(path, repo_root)
  if not path or path == "" then
    return path
  end

  local root = repo_root or get_repo_root()
  local full = vim.fn.fnamemodify(path, ":p")
  if full:sub(1, #root) == root then
    return full:sub(#root + 2)
  end
  return full
end

local function line_numbered_text(lines, start_line)
  local out = {}
  start_line = start_line or 1
  for index, line in ipairs(lines) do
    table.insert(out, string.format("%4d | %s", start_line + index - 1, line))
  end
  return table.concat(out, "\n")
end

local function find_buffer(abs_path)
  local target = abs_path and vim.fn.fnamemodify(abs_path, ":p") or nil
  if not target then
    return nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == target then
        return bufnr
      end
    end
  end

  return nil
end

local function get_target_bufnr(abs_path)
  if abs_path then
    return find_buffer(abs_path)
  end
  return vim.api.nvim_get_current_buf()
end

local function is_visible_file_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.bo[bufnr].buftype ~= "" then
    return false
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= nil and name ~= ""
end

local function get_buffer_snapshot(params, repo_root)
  local abs_path = normalize_path(params.path, repo_root)
  local bufnr = get_target_bufnr(abs_path)
  local offset = tonumber(params.offset) or 1
  if offset < 1 then
    offset = 1
  end
  local limit = tonumber(params.limit)

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local filetype = vim.bo[bufnr].filetype
    local modified = vim.bo[bufnr].modified
    local cursor = nil
    local end_line = limit and math.min(#all_lines, offset + limit - 1) or #all_lines
    local lines = vim.list_slice(all_lines, offset, end_line)

    if bufnr == vim.api.nvim_get_current_buf() then
      local pos = vim.api.nvim_win_get_cursor(0)
      cursor = { line = pos[1], col = pos[2] + 1 }
    end

    local path = name ~= "" and name or abs_path or "[No Name]"
    local title = string.format(
      "Buffer: %s%s",
      rel_path(path, repo_root),
      modified and " (unsaved changes)" or ""
    )
    if cursor then
      title = title .. string.format("\nCursor: %d:%d", cursor.line, cursor.col)
    end
    if filetype and filetype ~= "" then
      title = title .. "\nFiletype: " .. filetype
    end

    return {
      content = table.concat({
        title,
        "",
        "```" .. (filetype or ""),
        line_numbered_text(lines, offset),
        "```",
      }, "\n"),
      details = {
        path = path,
        relative_path = rel_path(path, repo_root),
        filetype = filetype,
        modified = modified,
        cursor = cursor,
        line_count = #all_lines,
        start_line = offset,
        end_line = end_line,
      },
    }
  end

  if not abs_path then
    return nil, "No current buffer"
  end

  local handle = io.open(abs_path, "r")
  if not handle then
    return nil, "Cannot read file: " .. abs_path
  end

  local all_lines = {}
  for line in handle:lines() do
    table.insert(all_lines, line)
  end
  handle:close()
  local end_line = limit and math.min(#all_lines, offset + limit - 1) or #all_lines
  local lines = vim.list_slice(all_lines, offset, end_line)

  local ext = vim.fn.fnamemodify(abs_path, ":e")
  return {
    content = table.concat({
      "File: " .. rel_path(abs_path, repo_root),
      "",
      "```" .. ext,
      line_numbered_text(lines, offset),
      "```",
    }, "\n"),
    details = {
      path = abs_path,
      relative_path = rel_path(abs_path, repo_root),
      filetype = ext,
      modified = false,
      line_count = #all_lines,
      start_line = offset,
      end_line = end_line,
    },
  }
end

local function get_selection_text(bufnr, start_mark, end_mark)
  local start_row, start_col = start_mark[1], start_mark[2]
  local end_row, end_col = end_mark[1], end_mark[2]
  if start_row == 0 or end_row == 0 then
    return nil
  end

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  local lines = vim.api.nvim_buf_get_text(bufnr, start_row - 1, start_col, end_row - 1, end_col + 1, {})
  return {
    start_line = start_row,
    start_col = start_col + 1,
    end_line = end_row,
    end_col = end_col + 1,
    lines = lines,
  }
end

local function get_selection(params, repo_root)
  local abs_path = normalize_path(params.path, repo_root)
  local bufnr = get_target_bufnr(abs_path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "No buffer available for selection"
  end

  local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
  local selection = get_selection_text(bufnr, start_mark, end_mark)
  if not selection or #selection.lines == 0 then
    return nil, "No visual selection available"
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype or ""

  return {
    content = table.concat({
      string.format(
        "Selection from %s:%d:%d-%d:%d",
        rel_path(name ~= "" and name or abs_path or "[No Name]", repo_root),
        selection.start_line,
        selection.start_col,
        selection.end_line,
        selection.end_col
      ),
      "",
      "```" .. filetype,
      table.concat(selection.lines, "\n"),
      "```",
    }, "\n"),
    details = {
      path = name ~= "" and name or abs_path,
      relative_path = rel_path(name ~= "" and name or abs_path, repo_root),
      filetype = filetype,
      start_line = selection.start_line,
      start_col = selection.start_col,
      end_line = selection.end_line,
      end_col = selection.end_col,
    },
  }
end

local function current_buffer_path(repo_root)
  local path = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if path == "" then
    return nil
  end
  return normalize_path(path, repo_root)
end

local function with_default_position(params, repo_root)
  local resolved = vim.deepcopy(params or {})
  if not resolved.path or resolved.path == "" then
    resolved.path = current_buffer_path(repo_root)
  end

  if (not resolved.line or not resolved.col) and resolved.path then
    local current_buf = vim.api.nvim_get_current_buf()
    local current_path = vim.api.nvim_buf_get_name(current_buf)
    if current_path ~= "" and vim.fn.fnamemodify(current_path, ":p") == vim.fn.fnamemodify(resolved.path, ":p") then
      local cursor = vim.api.nvim_win_get_cursor(0)
      resolved.line = resolved.line or cursor[1]
      resolved.col = resolved.col or (cursor[2] + 1)
    end
  end

  return resolved
end

local function diagnostics(params, repo_root)
  local input = vim.deepcopy(params or {})
  if input.path and input.path ~= "" then
    input.path = normalize_path(input.path, repo_root)
  end

  local result = lsp.execute("lsp_diagnostics", input, repo_root)
  return { content = result, details = { path = input.path } }
end

local function lsp_query(name, params, repo_root)
  local input = with_default_position(params, repo_root)
  if not input.path then
    return nil, "No current file available"
  end

  local result = lsp.execute(name, input, repo_root)
  return {
    content = result,
    details = {
      path = input.path,
      line = input.line,
      col = input.col,
    },
  }
end

local function visible_buffers(params, repo_root)
  local include_current = params.include_current ~= false
  local limit = tonumber(params.limit_per_buffer) or 160
  local max_buffers = tonumber(params.max_buffers) or 6
  limit = math.max(20, math.min(400, math.floor(limit)))
  max_buffers = math.max(1, math.min(12, math.floor(max_buffers)))

  local current = vim.api.nvim_get_current_buf()
  local seen = {}
  local buffers = {}

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if is_visible_file_buffer(bufnr) and (include_current or bufnr ~= current) and not seen[bufnr] then
      seen[bufnr] = true
      table.insert(buffers, bufnr)
    end
  end

  if #buffers == 0 then
    return nil, "No visible file buffers available"
  end

  local sections = {}
  local details = {}

  for index, bufnr in ipairs(buffers) do
    if index > max_buffers then
      break
    end

    local name = vim.api.nvim_buf_get_name(bufnr)
    local snapshot, err = get_buffer_snapshot({
      path = name,
      offset = 1,
      limit = limit,
    }, repo_root)

    if snapshot then
      table.insert(sections, snapshot.content)
      local buffer_details = snapshot.details or {}
      buffer_details.visible = true
      buffer_details.current = bufnr == current
      table.insert(details, buffer_details)
    elseif err then
      table.insert(sections, string.format("Buffer: %s\n\n%s", rel_path(name, repo_root), err))
    end
  end

  return {
    content = table.concat(sections, "\n\n"),
    details = {
      buffers = details,
      count = math.min(#buffers, max_buffers),
      total_visible = #buffers,
      limit_per_buffer = limit,
    },
  }
end

local handlers = {
  ping = function()
    return {
      content = "pong",
      details = { ok = true },
    }
  end,
  current_buffer = function(params, repo_root)
    return get_buffer_snapshot(params, repo_root)
  end,
  selection = function(params, repo_root)
    return get_selection(params, repo_root)
  end,
  diagnostics = function(params, repo_root)
    return diagnostics(params, repo_root)
  end,
  visible_buffers = function(params, repo_root)
    return visible_buffers(params, repo_root)
  end,
  lsp_hover = function(params, repo_root)
    return lsp_query("lsp_hover", params, repo_root)
  end,
  lsp_definition = function(params, repo_root)
    return lsp_query("lsp_definition", params, repo_root)
  end,
  lsp_references = function(params, repo_root)
    return lsp_query("lsp_references", params, repo_root)
  end,
  context = function(params, repo_root)
    local buffer_info, buffer_err = get_buffer_snapshot(params, repo_root)
    local selection_info = select(1, get_selection(params, repo_root))
    local diagnostics_info = diagnostics(params, repo_root)

    local parts = {}
    if buffer_info then
      table.insert(parts, buffer_info.content)
    end
    if selection_info then
      table.insert(parts, selection_info.content)
    end
    if diagnostics_info and diagnostics_info.content and diagnostics_info.content ~= "No diagnostics for " .. tostring(params.path) then
      table.insert(parts, diagnostics_info.content)
    end

    if #parts == 0 then
      return nil, buffer_err or "No editor context available"
    end

    return {
      content = table.concat(parts, "\n\n"),
      details = {
        buffer = buffer_info and buffer_info.details or nil,
        selection = selection_info and selection_info.details or nil,
      },
    }
  end,
}

local function send_response(client, payload)
  local encoded = vim.json.encode(payload) .. "\n"
  client:write(encoded)
  client:shutdown(function()
    client:close()
  end)
end

local function handle_request(client, raw)
  local ok, request = pcall(vim.json.decode, raw)
  if not ok or type(request) ~= "table" then
    send_response(client, { ok = false, error = "Invalid JSON request" })
    return
  end

  local handler = handlers[request.method]
  if not handler then
    send_response(client, { ok = false, error = "Unknown method: " .. tostring(request.method) })
    return
  end

  local repo_root = M.state.repo_root or get_repo_root()
  local status, result, err = pcall(handler, request.params or {}, repo_root)
  if not status then
    send_response(client, { ok = false, error = tostring(result) })
    return
  end

  if not result then
    send_response(client, { ok = false, error = tostring(err or "Unknown editor bridge error") })
    return
  end

  send_response(client, { ok = true, result = result })
end

local function dispatch_request(client, raw)
  vim.schedule(function()
    if client:is_closing() then
      return
    end
    handle_request(client, raw)
  end)
end

local function stop_server()
  if server then
    server:close()
    server = nil
  end

  M.state.repo_root = nil
  M.state.port = nil
end

local function create_server(port)
  local handle = uv.new_tcp()
  local ok, err = pcall(handle.bind, handle, M.state.host, port)
  if not ok then
    handle:close()
    return nil, err
  end
  return handle
end

local function allocate_server()
  local base_port = 43000 + (vim.fn.getpid() % 20000)

  for offset = 0, 127 do
    local port = ((base_port + offset - 1024) % 64511) + 1024
    local handle, err = create_server(port)
    if handle then
      return handle, port
    end
  end

  return nil, nil, "Could not bind a local TCP port for the Mentat editor bridge"
end

function M.stop()
  stop_server()
end

function M.ensure_started(repo_root)
  repo_root = repo_root or get_repo_root()
  if server and M.state.repo_root == repo_root and M.state.port then
    return M.state.host, M.state.port
  end

  stop_server()

  local port
  local bind_err
  server, port, bind_err = allocate_server()
  if not server then
    error(bind_err)
  end

  server:listen(128, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Mentat editor bridge error: " .. tostring(err), vim.log.levels.ERROR)
      end)
      return
    end

    local client = uv.new_tcp()
    server:accept(client)

    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err then
        client:close()
        return
      end

      if not chunk then
        if buffer ~= "" then
          client:read_stop()
          dispatch_request(client, buffer)
        else
          client:close()
        end
        return
      end

      buffer = buffer .. chunk
      while true do
        local newline = buffer:find("\n", 1, true)
        if not newline then
          break
        end
        local line = buffer:sub(1, newline - 1)
        buffer = buffer:sub(newline + 1)
        if line ~= "" then
          client:read_stop()
          dispatch_request(client, line)
          return
        end
      end
    end)
  end)

  if not cleanup_registered then
    cleanup_registered = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("MentatEditorBridge", { clear = true }),
      callback = function()
        stop_server()
      end,
    })
  end

  M.state.repo_root = repo_root
  M.state.port = port
  return M.state.host, M.state.port
end

function M.get_env(repo_root)
  local host, port = M.ensure_started(repo_root)
  return {
    MENTAT_EDITOR_BRIDGE_HOST = host,
    MENTAT_EDITOR_BRIDGE_PORT = tostring(port),
    MENTAT_EDITOR_BRIDGE_ROOT = repo_root or M.state.repo_root or get_repo_root(),
  }
end

return M
