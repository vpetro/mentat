local M = {}

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level)
  end)
end

local function metadata(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Review buffer is no longer available"
  end

  local count = math.min(vim.api.nvim_buf_line_count(bufnr), 20)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, count, false)
  for _, line in ipairs(lines) do
    local encoded = line:match("^mentat%-context:%s*(.-)%s*$")
    if encoded then
      local ok, value = pcall(vim.json.decode, encoded)
      if not ok or type(value) ~= "table" then
        return nil, "Invalid mentat-context header"
      end
      if value.version ~= 1 then
        return nil, "Unsupported mentat-context version"
      end
      if type(value.session_file) ~= "string" or value.session_file == "" then
        return nil, "The originating Pi session was not persisted"
      end
      if type(value.leaf_id) ~= "string" or value.leaf_id == "" then
        return nil, "The mentat-context header has no source leaf"
      end
      return value, nil
    end
  end

  return nil, "No mentat-context header found"
end

local function locate(bufnr)
  local context, context_err = metadata(bufnr)
  if context then
    return context, bufnr, nil
  end

  local found_bufnr, found_context
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if candidate ~= bufnr and vim.api.nvim_buf_is_loaded(candidate) and vim.bo[candidate].buftype == "" then
      local candidate_context = metadata(candidate)
      if candidate_context and (not found_bufnr or candidate > found_bufnr) then
        found_bufnr = candidate
        found_context = candidate_context
      end
    end
  end

  if found_bufnr then
    return found_context, found_bufnr, nil
  end
  return nil, nil, context_err
end

local function branch_snapshot(path, target_id)
  local file, open_err = io.open(path, "r")
  if not file then
    return nil, open_err
  end

  local header
  local entries = {}
  local last_id
  for line in file:lines() do
    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" then
      file:close()
      return nil, "Invalid JSON in the originating Pi session"
    end
    if entry.type == "session" then
      header = line
    elseif type(entry.id) == "string" and entry.id ~= "" then
      entries[entry.id] = { line = line, parent_id = entry.parentId }
      last_id = entry.id
      if target_id and entry.id == target_id then
        break
      end
    else
      file:close()
      return nil, "The originating Pi session contains an entry without an ID"
    end
  end
  file:close()

  if not header then
    return nil, "The originating Pi session has no header"
  end

  local entry_id = target_id or last_id
  if not entry_id then
    return nil, "The originating Pi session has no conversation entries"
  end

  local reverse = {}
  local seen = {}
  while entry_id do
    if seen[entry_id] then
      return nil, "The originating Pi session contains a parent cycle"
    end
    seen[entry_id] = true

    local entry = entries[entry_id]
    if not entry then
      return nil, "The referenced Pi context is no longer present in the session"
    end
    table.insert(reverse, entry.line)

    local parent_id = entry.parent_id
    if parent_id == vim.NIL then
      parent_id = nil
    end
    if parent_id ~= nil and type(parent_id) ~= "string" then
      return nil, "The originating Pi session contains an invalid parent ID"
    end
    entry_id = parent_id
  end

  local snapshot = vim.fn.tempname() .. ".jsonl"
  local output, write_err = io.open(snapshot, "w")
  if not output then
    return nil, write_err
  end
  output:write(header, "\n")
  for index = #reverse, 1, -1 do
    output:write(reverse[index], "\n")
  end
  output:close()
  local uv = vim.uv or vim.loop
  uv.fs_chmod(snapshot, 384)
  return snapshot, nil
end

local function report_switch(ok, err, label)
  if ok then
    notify("Loaded " .. label .. " into Mentat", vim.log.levels.INFO)
  else
    notify("Could not load review context: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.metadata(bufnr)
  return metadata(bufnr)
end

function M.load(opts)
  opts = opts or {}
  local context, bufnr, context_err = locate(opts.bufnr or vim.api.nvim_get_current_buf())
  if not context then
    notify(context_err, vim.log.levels.ERROR)
    return
  end

  local mentat = require("mentat")
  local cached = vim.b[bufnr].mentat_review_session
  if not opts.force and type(cached) == "string" and vim.fn.filereadable(cached) == 1 then
    mentat.switch_session(cached, function(ok, switch_err)
      report_switch(ok, switch_err, "the review session")
    end)
    return
  end

  local source = vim.fn.fnamemodify(context.session_file, ":p")
  local target_id = opts.force and nil or context.leaf_id
  local snapshot, snapshot_err = branch_snapshot(source, target_id)
  if not snapshot then
    notify("Could not read the originating Pi session: " .. tostring(snapshot_err), vim.log.levels.ERROR)
    return
  end

  mentat.clone_session_from(snapshot, function(cloned, clone_err)
    vim.fn.delete(snapshot)
    if not cloned then
      report_switch(false, clone_err, "")
      return
    end

    local session_file = mentat.get_session_file()
    if type(session_file) ~= "string" or session_file == "" or session_file == snapshot then
      report_switch(false, "Pi did not create a separate review session", "")
      return
    end

    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].mentat_review_session = session_file
      end
    end)

    local label = context.session_name or context.session_id or "the Pi review context"
    report_switch(true, nil, string.format("a fork of %s", label))
  end, source)
end

return M
