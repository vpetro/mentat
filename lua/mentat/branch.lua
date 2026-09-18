local mentat = require("mentat")
local prompt_loader = require("mentat.prompt_loader")
local response_view = require("mentat.response")
local model_picker = require("mentat.model_picker")

local M = {}
local branches = {}
local STARTING_STATUS = "*Forking the main conversation...*"

local function set_status(buf, text)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 5, false)
  for index, line in ipairs(lines) do
    if line == STARTING_STATUS then
      vim.api.nvim_buf_set_lines(buf, index - 1, index, false, { text })
      return
    end
  end
end

local function collect_input(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last_sep = 0
  for index, line in ipairs(lines) do
    if line == "---" then
      last_sep = index
    end
  end
  local prompt = vim.trim(table.concat(vim.list_slice(lines, last_sep + 1), "\n"))
  if prompt ~= "" then
    return prompt, last_sep
  end
end

local function send(branch, prompt, slot, draft_start)
  if not branch.client then
    vim.notify(branch.error or "The branch is still starting", vim.log.levels.WARN)
    return false
  end
  local actual_prompt = prompt_loader.render("runtime_user_request.md", {
    hint = prompt_loader.read("runtime_hint.md") or "",
    prompt = prompt,
  }) or prompt
  local view
  local accepted, err = mentat.chat(actual_prompt,
    function(chunk)
      view.chunk(chunk)
    end,
    function(_, rpc_err, metadata)
      view.finish(metadata, rpc_err)
    end,
    { slot = slot, client = branch.client }
  )
  if not accepted then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  if draft_start then
    vim.api.nvim_buf_set_lines(branch.bufnr, draft_start, -1, false, {})
  end
  view = response_view.start(branch.bufnr, prompt)
  branch.last_prompt = prompt
  return true
end

function M.promote()
  local branch = branches[vim.api.nvim_get_current_buf()]
  if not branch then
    return false
  end
  if not branch.last_prompt then
    vim.notify("No prompt to promote yet", vim.log.levels.WARN)
  else
    send(branch, branch.last_prompt, "big")
  end
  return true
end

function M.open(initial_text)
  local buf = vim.api.nvim_create_buf(false, true)
  local branch = { bufnr = buf }
  branches[buf] = branch
  vim.api.nvim_buf_set_name(buf, "Mentat Branch " .. buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Mentat Branch", "", STARTING_STATUS, "", "---", "",
  })
  model_picker.attach(buf, nil, "Mentat branch")

  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[
      syntax match MentatHeaderYou /^##\{1,2} You$/
      syntax match MentatHeaderClaude /^##\{1,2} \(Claude\|Pi\)\( ([^)]*)\)\=$/
      highlight default link MentatHeaderYou Type
      highlight default link MentatHeaderClaude Function
    ]])
  end)

  require("mentat.buffer").open({ prepare = false })
  vim.cmd("belowright vsplit")
  vim.api.nvim_win_set_buf(0, buf)
  if initial_text and initial_text ~= "" then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(initial_text, "\n", { plain = true }))
  end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  model_picker.refresh()

  local function submit(slot)
    local prompt, draft_start = collect_input(buf)
    if prompt then
      send(branch, prompt, slot, draft_start)
    end
  end
  vim.keymap.set("n", "<CR>", function()
    submit()
  end, { buffer = buf, desc = "Send with selected model and thinking" })
  vim.keymap.set("n", "<S-CR>", function()
    submit("big")
  end, { buffer = buf, desc = "Use big for one request" })
  vim.keymap.set("n", "<leader>mp", M.promote, { buffer = buf, desc = "Re-send last prompt with big in this branch" })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, desc = "Close branch" })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    buffer = buf,
    callback = function()
      branches[buf] = nil
      if branch.startup_task then
        branch.startup_task:close()
      end
    end,
  })

  branch.startup_task = mentat.fork(function(client, err, source)
    if not vim.api.nvim_buf_is_loaded(buf) then
      if client then
        client.stop()
      end
      return
    end
    if not client then
      branch.error = "Could not fork the conversation: " .. tostring(err)
      set_status(buf, "**Error:** " .. branch.error)
      return
    end
    branch.client = client
    model_picker.attach(buf, client, "Mentat branch")
    if source then
      set_status(buf, string.format(
        "*Forked from the main conversation (%d messages). Type a question and press Enter.*",
        client.state.message_count or 0))
    else
      set_status(buf, "*Started with the main conversation's settings (no saved history yet). Type a question and press Enter.*")
    end
  end)
  return buf
end

return M
