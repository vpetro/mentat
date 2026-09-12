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

function M.body(text, metadata, err)
  text = text or ""
  local stamp_pattern = "(%[%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d[^\r\n%]]*%])[ \t\r\n]*$"
  local body, stamp = text:match("^(.-)\n+" .. stamp_pattern)
  if not body then
    stamp = text:match("^" .. stamp_pattern)
    body = stamp and "" or text
  end
  local parts = {}
  body = body:gsub("%s+$", "")
  if body ~= "" then
    table.insert(parts, body)
  end
  if err then
    local label = metadata and metadata.status == "aborted" and "Aborted" or "Error"
    table.insert(parts, "**" .. label .. ":** " .. err)
  end
  table.insert(parts, M.timing(metadata))
  if stamp then
    table.insert(parts, stamp)
  end
  return table.concat(parts, "\n\n")
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
      local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1]
      vim.api.nvim_buf_set_text(buf, pos[1], 0, pos[1], #line, { "## " .. M.heading(metadata) })
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
    local first = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, mark, {})
    local last = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, output, {})
    if #first > 0 and #last > 0 then
      local body = table.concat(vim.api.nvim_buf_get_text(buf, first[1] + 1, 0, last[1], last[2], {}), "\n")
      local lines = vim.split(M.body(body, metadata, err), "\n", { plain = true })
      vim.api.nvim_buf_set_text(buf, first[1] + 1, 0, last[1], last[2], lines)
      scroll()
    end
    closed = true
    vim.api.nvim_buf_del_extmark(buf, namespace, mark)
    vim.api.nvim_buf_del_extmark(buf, namespace, output)
  end

  scroll()
  return response
end

return M
