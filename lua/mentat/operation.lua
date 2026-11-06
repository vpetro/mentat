local M = {}

M.phases = {
  idle = "Idle",
  starting = "Starting",
  generating = "Generating",
  tool = "Running tool",
  compacting = "Compacting",
  cancelling = "Cancelling",
  finishing = "Finishing",
}

local function resolve()
  local target = require("mentat.model_picker").target(vim.api.nvim_get_current_buf())
  if target then
    return target.client, target.name
  end
  return require("mentat").get_client(), "Mentat"
end

local function elapsed(ms)
  if ms < 60000 then
    return string.format("%.1fs", ms / 1000)
  end
  local seconds = math.floor(ms / 1000)
  return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
end

local function truncate(text, limit)
  text = text:gsub("%s+", " ")
  if #text > limit then
    return text:sub(1, limit - 3) .. "..."
  end
  return text
end

local function tool_label(tool)
  local label = tool.name or "?"
  if tool.arg then
    label = label .. ": " .. truncate(tool.arg, 60)
  end
  return label
end

local function child_status(result)
  local exit_code = result.exitCode
  if exit_code == -1 then
    return "running"
  end
  if type(exit_code) ~= "number" and exit_code ~= vim.NIL then
    return "status unavailable"
  end
  local message = result.errorMessage
  if type(message) == "string" and message ~= "" then
    return message:find("^Subagent was aborted") and "cancelled" or "failed"
  end
  if exit_code ~= 0 or result.completed == false then
    return "failed"
  end
  if result.completed == true then
    return "finished"
  end
  return "status unavailable"
end

function M.subagent_progress(partial)
  local details = type(partial) == "table" and partial.details or nil
  local results = type(details) == "table" and details.results or nil
  if type(results) ~= "table" then
    return nil
  end
  local lines = {}
  for _, result in ipairs(results) do
    if type(result) == "table" and type(result.agent) == "string" then
      local line = result.agent .. ": " .. child_status(result)
      local turns = type(result.usage) == "table" and tonumber(result.usage.turns) or nil
      if turns and turns > 0 then
        line = line .. string.format(" (%d turn%s)", turns, turns == 1 and "" or "s")
      end
      table.insert(lines, line)
    end
  end
  if #lines > 0 then
    return lines
  end
end

function M.render(snapshot, name)
  local parts = { M.phases[snapshot.phase] or snapshot.phase }
  if snapshot.elapsed_ms then
    table.insert(parts, "Elapsed: " .. elapsed(snapshot.elapsed_ms))
  end
  for _, tool in ipairs(snapshot.tools or {}) do
    table.insert(parts, "Tool: " .. tool_label(tool))
  end
  if snapshot.model then
    table.insert(parts, "Model: " .. tostring(snapshot.model.provider) .. "/" .. tostring(snapshot.model.id))
  end
  if snapshot.thinking then
    table.insert(parts, "Thinking: " .. tostring(snapshot.thinking))
  end
  local lines = { (name or "Mentat") .. ": " .. table.concat(parts, " | ") }
  for _, tool in ipairs(snapshot.tools or {}) do
    local progress = M.subagent_progress(tool.partial)
    if progress then
      vim.list_extend(lines, progress)
    elseif tool.name == "subagent" then
      table.insert(lines, "Subagent progress is unavailable.")
    end
  end
  return table.concat(lines, "\n")
end

function M.status()
  local client, name = resolve()
  local snapshot = client and client.status() or { phase = "starting", tools = {} }
  local text = M.render(snapshot, name)
  vim.notify(text, vim.log.levels.INFO)
  return snapshot, text
end

function M.cancel()
  local client = resolve()
  local ok, err
  if client then
    ok, err = client.abort()
  else
    ok, err = false, "This operation cannot be cancelled. Wait for it to finish."
  end
  if ok then
    vim.notify("Cancellation requested.", vim.log.levels.INFO)
  else
    vim.notify(err, err == "Nothing is running." and vim.log.levels.INFO or vim.log.levels.WARN)
  end
  return ok, err
end

return M
