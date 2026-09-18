local models = require("mentat.models")
local boundary = require("mentat.async")
local async = vim.async
local M = {}
local targets = {}
local windows = {}
local group = vim.api.nvim_create_augroup("MentatModels", { clear = true })

local function original_winbar(current)
  for _, saved in pairs(windows) do
    if current == saved.applied then
      return saved.previous
    end
  end
  return current
end

function M.refresh()
  local live = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    live[win] = true
    local target = targets[vim.api.nvim_win_get_buf(win)]
    local current = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
    local saved = windows[win]
    if target then
      if not saved then
        saved = { previous = original_winbar(current) }
        windows[win] = saved
      end
      local state = target.client and target.client.state
      local label = target.name .. " | "
      if not state or (not state.ready and state.busy) then
        label = label .. "starting"
      elseif not state.ready then
        label = label .. models.label(models.from_state(state)) .. " (offline)"
      else
        label = label .. models.label(models.from_state(state))
        if state.busy then
          label = label .. " (busy)"
        end
      end
      saved.applied = label:gsub("%%", "%%%%")
      vim.api.nvim_set_option_value("winbar", saved.applied, { win = win, scope = "local" })
    elseif saved then
      vim.api.nvim_set_option_value("winbar", saved.previous, { win = win, scope = "local" })
      windows[win] = nil
    else
      local previous = original_winbar(current)
      if previous ~= current then
        vim.api.nvim_set_option_value("winbar", previous, { win = win, scope = "local" })
      end
    end
  end
  for win in pairs(windows) do
    if not live[win] then
      windows[win] = nil
    end
  end
end

function M.detach(buf)
  local target = targets[buf]
  targets[buf] = nil
  if target then
    if target.picker_task then
      target.picker_task:close()
    end
    if target.unsubscribe then
      target.unsubscribe()
    end
    if target.client then
      target.client.stop("Mentat buffer closed")
    end
  end
  M.refresh()
end

function M.attach(buf, client, name)
  local target = targets[buf]
  if not target then
    target = { bufnr = buf, epoch = 0 }
    targets[buf] = target
    vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
      group = group,
      buffer = buf,
      callback = function()
        M.detach(buf)
      end,
    })
  end
  if target.unsubscribe then
    target.unsubscribe()
  end
  if target.picker_task then
    target.picker_task:close()
  end
  target.epoch = target.epoch + 1
  target.client = client
  target.name = name or "Mentat"
  target.unsubscribe = client and client.subscribe(M.refresh) or nil
  M.refresh()
  return target
end

function M.target(buf)
  return targets[buf]
end

function M.invalidate(buf)
  local target = targets[buf]
  if target then
    target.epoch = target.epoch + 1
    if target.picker_task then
      target.picker_task:close()
    end
  end
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN)
end

function M.pick(kind)
  local mentat = require("mentat")
  local target = targets[vim.api.nvim_get_current_buf()] or require("mentat.buffer").target()
  local client = target.client
  if not client then
    notify("The branch is still starting")
    return
  end
  if client.is_busy() then
    notify("Pi is busy; wait for the current operation to settle")
    return
  end
  if target.picker_task then
    target.picker_task:close()
  end
  local epoch = target.epoch
  local root = mentat.get_repo_root()
  local function valid()
    return targets[target.bufnr] == target and target.epoch == epoch and target.client == client and vim.api.nvim_buf_is_loaded(target.bufnr)
  end
  local task = async.run("mentat " .. kind .. " picker", function()
    if not valid() then
      return
    end
    local ok, err = boundary.call(function(done)
      if client == mentat.get_client() then
        return mentat.prepare(done, root)
      end
      return client.ensure_started(nil, done)
    end)
    if not valid() then
      return
    end
    if not ok then
      notify(err, vim.log.levels.ERROR)
      if not client.state.ready or client.is_busy() then
        return
      end
    end
    if kind == "thinking" and not client.state.model then
      notify("Select an available model first")
      return
    end
    local list = kind == "model" and client.get_available_models or client.get_available_thinking_levels
    local items, list_err = boundary.call(list)
    if not valid() then
      return
    end
    if not items then
      notify(list_err, vim.log.levels.ERROR)
      return
    end
    if #items == 0 then
      notify(kind == "model" and "No Pi models available; check authentication and model configuration" or "Pi returned no supported thinking levels")
      return
    end
    local revision = client.state.revision
    local session_id = client.state.session_id
    local current = models.from_state(client.state)
    local labels = {}
    if kind == "model" then
      table.sort(items, function(a, b)
        return a.provider .. "/" .. a.id < b.provider .. "/" .. b.id
      end)
      for _, model in ipairs(items) do
        local label = model.provider .. "/" .. model.id
        if model.name and model.name ~= model.id then
          label = label .. " (" .. model.name .. ")"
        end
        local presets = models.preset_labels(model, mentat.config, items)
        if #presets > 0 then
          label = label .. " [" .. table.concat(presets, ", ") .. "]"
        end
        labels[model] = (current.provider == model.provider and current.model == model.id and "* " or "  ") .. label
      end
    else
      for _, level in ipairs(items) do
        labels[level] = (current.thinking == level and "* " or "  ") .. level
      end
    end
    local choice = boundary.select(items, {
      kind = "mentat_" .. kind,
      prompt = "Mentat " .. kind .. " (" .. models.label(current) .. "):",
      format_item = function(item)
        return labels[item]
      end,
    })
    if choice == nil or not valid() then
      return
    end
    if revision ~= client.state.revision or session_id ~= client.state.session_id or client.is_busy() then
      notify("The conversation changed; reopen the picker")
      return
    end
    local selected, selection_err = boundary.call(function(done)
      if kind == "model" then
        return client.set_model(choice.provider, choice.id, done)
      end
      return client.set_thinking_level(choice, done)
    end)
    if valid() then
      local label = models.label(models.from_state(client.state))
      if selected then
        notify("Mentat: " .. label, vim.log.levels.INFO)
      else
        notify(tostring(selection_err) .. " (last confirmed: " .. label .. ")", vim.log.levels.ERROR)
      end
    end
  end):detach()
  target.picker_task = task
  task:on_complete(function(err)
    if target.picker_task == task then
      target.picker_task = nil
    end
    boundary.report(err)
  end)
  return task
end

vim.api.nvim_create_autocmd("BufWinLeave", {
  group = group,
  callback = function(args)
    if not targets[args.buf] then
      return
    end
    local restores = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == args.buf then
        local saved = windows[win]
        local current = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
        restores[win] = saved and saved.previous or original_winbar(current)
      end
    end
    for win, previous in pairs(restores) do
      vim.api.nvim_set_option_value("winbar", previous, { win = win, scope = "local" })
      windows[win] = nil
    end
    vim.schedule(M.refresh)
  end,
})

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "WinNew", "WinClosed" }, {
  group = group,
  callback = function()
    vim.schedule(M.refresh)
  end,
})

return M
