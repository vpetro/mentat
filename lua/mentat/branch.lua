local mentat = require("mentat")

local M = {}
local ASSISTANT_NAME = "Pi"

local function scroll_to_bottom(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

local function append_lines(buf, lines)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  scroll_to_bottom(buf)
end

local function append_chunk(buf, text)
  local last_line = vim.api.nvim_buf_line_count(buf)
  local current = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1] or ""

  local lines = {}
  for line in (text):gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  if lines[#lines] == "" then table.remove(lines) end

  if #lines == 0 then return end

  lines[1] = current .. lines[1]
  vim.api.nvim_buf_set_lines(buf, last_line - 1, last_line, false, lines)
  scroll_to_bottom(buf)
end

function M.open(initial_text)
  if not mentat.supports_branching() then
    vim.notify("Branch conversations are not supported with the Pi backend yet", vim.log.levels.WARN)
    return
  end

  -- Snapshot current conversation history
  local branch_messages = vim.deepcopy(mentat.messages)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "Mentat Branch " .. os.date("%H:%M:%S"))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = true

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Mentat Branch",
    "",
    "*Forked from main conversation (" .. #branch_messages .. " messages). Type a question and press Enter.*",
    "",
  })

  -- Syntax highlights
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[
      syntax match MentatHeaderYou /^##\{1,2} You$/
      syntax match MentatHeaderClaude /^##\{1,2} \(Claude\|Pi\)$/
      highlight default link MentatHeaderYou Type
      highlight default link MentatHeaderClaude Function
    ]])
  end)

  -- Open to the right of the Mentat window (or current window)
  local mentat_buf = require("mentat.buffer")
  mentat_buf.open()
  vim.cmd("belowright vsplit")
  vim.api.nvim_win_set_buf(0, buf)

  -- Branch send function
  local function branch_send(prompt)
    local prompt_lines = {}
    for line in (prompt .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(prompt_lines, line)
    end
    local header = { "", "## You", "" }
    local footer = { "", "---", "", "## " .. ASSISTANT_NAME, "" }
    vim.list_extend(header, prompt_lines)
    vim.list_extend(header, footer)
    append_lines(buf, header)

    mentat.chat(prompt,
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
      branch_messages
    )
  end

  -- Enter sends everything after the last separator
  vim.keymap.set("n", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
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
    if prompt ~= "" then
      vim.api.nvim_buf_set_lines(buf, last_sep, -1, false, {})
      branch_send(prompt)
    end
  end, { buffer = buf, desc = "Send prompt to Pi (branch)" })

  -- If opened with a selection, paste it into the buffer for editing
  if initial_text and initial_text ~= "" then
    local text_lines = {}
    for line in (initial_text .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(text_lines, line)
    end
    append_lines(buf, text_lines)
    append_lines(buf, { "" })
    scroll_to_bottom(buf)
  end

  -- q closes the branch
  vim.keymap.set("n", "q", function()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_win_close(win, true)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, desc = "Close branch" })
end

return M
