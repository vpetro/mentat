local models = require("mentat.models")
local M = {}
local namespace = vim.api.nvim_create_namespace("mentat_response")

local function duration(ms)
  if ms == nil then
    return "n/a"
  end
  if ms < 1000 then
    return string.format("%.0fms", ms)
  end
  return string.format("%.2fs", ms / 1000)
end

function M.heading(metadata)
  local labels = {}
  for _, selection in ipairs(metadata and metadata.models or {}) do
    table.insert(labels, models.label(selection))
  end
  return "Pi (" .. (#labels > 0 and table.concat(labels, " -> ") or "model unavailable") .. ")"
end

function M.timing(metadata)
  metadata = metadata or {}
  return string.format("*First text: %s | Total: %s | Status: %s*",
    duration(metadata.first_text_ms), duration(metadata.total_ms), metadata.status or "error")
end

function M.start(buf, prompt)
  local response = {}
  local closed = false
  local lines = { "", "## You", "" }
  vim.list_extend(lines, vim.split(prompt, "\n", { plain = true }))
  vim.list_extend(lines, { "", "---", "", "## Pi", "", "", "---", "" })
  local heading_row = vim.api.nvim_buf_line_count(buf) + #lines - 5
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  local mark = vim.api.nvim_buf_set_extmark(buf, namespace, heading_row, 0, { right_gravity = false })
  local output = vim.api.nvim_buf_set_extmark(buf, namespace, heading_row + 1, 0, { right_gravity = false })

  local function valid()
    return not closed and vim.api.nvim_buf_is_loaded(buf)
  end

  local function scroll()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
      end
    end
  end

  function response.metadata(metadata)
    if not valid() then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, mark, {})
    if #pos > 0 then
      vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + 1, false, { "## " .. M.heading(metadata) })
      vim.api.nvim_buf_set_extmark(buf, namespace, pos[1], 0, { id = mark, right_gravity = false })
    end
  end

  function response.chunk(text)
    if not valid() then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, output, {})
    if #pos == 0 then
      return
    end
    local parts = vim.split(text, "\n", { plain = true, trimempty = false })
    vim.api.nvim_buf_set_text(buf, pos[1], pos[2], pos[1], pos[2], parts)
    local row = pos[1] + #parts - 1
    local col = #parts == 1 and pos[2] + #parts[1] or #parts[#parts]
    vim.api.nvim_buf_set_extmark(buf, namespace, row, col, { id = output, right_gravity = false })
    scroll()
  end

  function response.finish(metadata, err)
    if not valid() then
      return
    end
    response.metadata(metadata)
    local ending = "\n\n"
    if err then
      local label = metadata and metadata.status == "aborted" and "Aborted" or "Error"
      ending = ending .. "**" .. label .. ":** " .. err .. "\n\n"
    end
    ending = ending .. M.timing(metadata) .. "\n"
    response.chunk(ending)
    closed = true
    vim.api.nvim_buf_del_extmark(buf, namespace, mark)
    vim.api.nvim_buf_del_extmark(buf, namespace, output)
  end

  scroll()
  return response
end

return M
