local M = {}

local plugin_root = nil

local function get_plugin_root()
  if plugin_root then
    return plugin_root
  end

  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end

  plugin_root = vim.fn.fnamemodify(source, ":p:h:h:h")
  return plugin_root
end

function M.path(relative_path)
  return get_plugin_root() .. "/prompts/" .. relative_path
end

function M.read(relative_path)
  local handle = io.open(M.path(relative_path), "r")
  if not handle then
    return nil
  end

  local content = handle:read("*a")
  handle:close()
  return content
end

function M.render(relative_path, vars)
  local template = M.read(relative_path)
  if not template then
    return nil
  end

  return (template:gsub("{{([%w_]+)}}", function(key)
    local value = vars and vars[key]
    if value == nil then
      return ""
    end
    return tostring(value)
  end))
end

return M
