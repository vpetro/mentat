local boundary = require("mentat.async")
local fs = require("mentat.fs")
local async = vim.async
local M = {}
local owners = {}
local group = vim.api.nvim_create_augroup("MentatReview", { clear = true })

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
  local lines, read_err = fs.read_lines(path)
  if not lines then
    return nil, read_err
  end

  local header
  local entries = {}
  local last_id
  for _, line in ipairs(lines) do
    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" then
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
      return nil, "The originating Pi session contains an entry without an ID"
    end
  end

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

  local snapshot = { header }
  for index = #reverse, 1, -1 do
    snapshot[#snapshot + 1] = reverse[index]
  end
  return table.concat(snapshot, "\n") .. "\n"
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
  local owner = owners[bufnr]
  if not owner then
    owner = {}
    owners[bufnr] = owner
    vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        owners[bufnr] = nil
        if owner.task then
          owner.task:close()
        end
      end,
    })
  elseif owner.task then
    owner.task:close()
  end
  local root = mentat.get_repo_root() or vim.uv.cwd()
  local client = mentat.get_client()
  local revision = client.state.revision
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = vim.b[bufnr].mentat_review_session
  local source = vim.fn.fnamemodify(context.session_file, ":p")
  local target_id = not opts.force and context.leaf_id or nil
  local label = "a fork of " .. (context.session_name or context.session_id or "the Pi review context")
  local function valid()
    return owners[bufnr] == owner and vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_changedtick(bufnr) == tick
  end
  local task = async.run("mentat review context", function()
    async.await(vim.schedule)
    if not valid() or revision ~= client.state.revision then
      return false, "The conversation or review buffer changed; load the context again"
    end
    if not opts.force and type(cached) == "string" and vim.fn.filereadable(cached) == 1 then
      label = "the review session"
      return boundary.call(function(done)
        return mentat.switch_session(cached, done, root)
      end)
    end
    local snapshot, snapshot_err = branch_snapshot(source, target_id)
    if not snapshot then
      return false, "Could not read the originating Pi session: " .. tostring(snapshot_err)
    end
    if not valid() or revision ~= client.state.revision then
      return false, "The conversation or review buffer changed; load the context again"
    end
    return fs.with_temp(snapshot, function(path)
      if not valid() or revision ~= client.state.revision then
        return false, "The conversation or review buffer changed; load the context again"
      end
      local cloned, clone_err = boundary.call(function(done)
        return mentat.clone_session_from(path, done, source, root)
      end)
      if not cloned then
        return false, clone_err
      end
      local session_file = mentat.get_session_file()
      if type(session_file) ~= "string" or session_file == "" or session_file == path then
        return false, "Pi did not create a separate review session"
      end
      if not valid() then
        return false, "The review buffer changed while loading context"
      end
      vim.b[bufnr].mentat_review_session = session_file
      return true
    end)
  end):detach()
  owner.task = task
  task:on_complete(function(task_err, ok, err)
    if owner.task == task then
      owner.task = nil
    end
    if task_err ~= "closed" then
      report_switch(ok, task_err and tostring(task_err) or err, label)
    end
  end)
  return task
end

return M
