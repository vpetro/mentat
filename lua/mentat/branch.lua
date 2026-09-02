local mentat = require("mentat")
local prompt_loader = require("mentat.prompt_loader")

local M = {}
local ASSISTANT_NAME = "Pi"
local STARTING_STATUS = "*Forking the main conversation...*"

local function scroll_to_bottom(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

local function append_lines(buf, lines)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  scroll_to_bottom(buf)
end

local function append_chunk(buf, text)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end

  local last_line = vim.api.nvim_buf_line_count(buf)
  local current = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1] or ""
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  if #lines == 0 then
    return
  end

  lines[1] = current .. lines[1]
  vim.api.nvim_buf_set_lines(buf, last_line - 1, last_line, false, lines)
  scroll_to_bottom(buf)
end

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

local function assistant_heading(label)
  if label then
    return string.format("%s (%s)", ASSISTANT_NAME, label)
  end
  return ASSISTANT_NAME
end

local function collect_input(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last_sep = 0
  for i, line in ipairs(lines) do
    if line:match("^%-%-%-$") then
      last_sep = i
    end
  end

  local prompt = table.concat(vim.list_slice(lines, last_sep + 1), "\n")
  prompt = prompt:gsub("^%s+", ""):gsub("%s+$", "")
  if prompt == "" then
    return nil
  end

  vim.api.nvim_buf_set_lines(buf, last_sep, -1, false, {})
  return prompt
end

local function send(buf, client, prompt, slot)
  local label = mentat.slot_label(mentat.resolve_slot(slot))
  local lines = { "", "## You", "" }
  vim.list_extend(lines, vim.split(prompt, "\n", { plain = true }))
  vim.list_extend(lines, { "", "---", "", "## " .. assistant_heading(label), "" })
  append_lines(buf, lines)

  local actual_prompt = prompt_loader.render("runtime_user_request.md", {
    hint = prompt_loader.read("runtime_hint.md") or "",
    prompt = prompt,
  }) or prompt

  mentat.chat(actual_prompt,
    function(chunk)
      append_chunk(buf, chunk)
    end,
    function(_, err)
      if err then
        append_lines(buf, { "", "**Error:** " .. err })
      else
        append_lines(buf, { "", "", "---" })
      end
    end,
    { slot = slot, client = client }
  )
end

function M.open(initial_text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "Mentat Branch " .. os.date("%H:%M:%S"))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = true

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Mentat Branch",
    "",
    STARTING_STATUS,
    "",
    "---",
    "",
  })

  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[
      syntax match MentatHeaderYou /^##\{1,2} You$/
      syntax match MentatHeaderClaude /^##\{1,2} \(Claude\|Pi\)\( ([^)]*)\)\=$/
      highlight default link MentatHeaderYou Type
      highlight default link MentatHeaderClaude Function
    ]])
  end)

  require("mentat.buffer").open()
  vim.cmd("belowright vsplit")
  vim.api.nvim_win_set_buf(0, buf)

  if initial_text and initial_text ~= "" then
    append_lines(buf, vim.split(initial_text, "\n", { plain = true }))
    append_lines(buf, { "" })
  end
  scroll_to_bottom(buf)

  local client = nil
  local start_err = nil

  local function submit(slot)
    if start_err then
      vim.notify("The branch failed to start: " .. start_err, vim.log.levels.ERROR)
      return
    end
    if not client then
      vim.notify("The branch is still starting", vim.log.levels.WARN)
      return
    end

    local prompt = collect_input(buf)
    if prompt then
      send(buf, client, prompt, slot)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    submit("quick")
  end, { buffer = buf, desc = "Send prompt (quick model)" })

  vim.keymap.set("n", "<S-CR>", function()
    submit("big")
  end, { buffer = buf, desc = "Send prompt (big model)" })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, desc = "Close branch" })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    buffer = buf,
    callback = function()
      if client then
        client.stop()
        client = nil
      end
    end,
  })

  mentat.fork(function(forked, err, source)
    if not forked then
      start_err = tostring(err)
      set_status(buf, "**Error:** could not fork the conversation: " .. start_err)
      return
    end

    if not vim.api.nvim_buf_is_loaded(buf) then
      forked.stop()
      return
    end

    client = forked
    if source then
      set_status(buf, string.format(
        "*Forked from the main conversation (%d messages). Type a question and press Enter.*",
        client.state.message_count or 0
      ))
    else
      set_status(buf, "*Started a fresh session (the main conversation has not been saved yet). Type a question and press Enter.*")
    end
  end)
end

return M
