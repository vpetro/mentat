local M = {}

function M.preset(config, name)
  local slot = (config.slots or {})[name]
  if not slot then
    return nil, "No " .. tostring(name) .. " model preset configured"
  end
  return {
    provider = slot.provider,
    model = slot.model,
    thinking = slot.thinking,
    preferred_provider = config.provider,
  }
end

function M.defaults(config)
  if config.model then
    return {
      provider = config.provider,
      model = config.model,
      thinking = config.thinking,
    }
  end
  local preset = M.preset(config, config.default_slot or "quick") or {}
  preset.thinking = config.thinking or preset.thinking
  return preset
end

function M.resolve(selection, catalog)
  local result = vim.deepcopy(selection)
  if not result.model then
    return result
  end

  local matches = {}
  for _, model in ipairs(catalog) do
    if (not result.provider or result.provider == model.provider) and result.model == model.id then
      table.insert(matches, model)
    end
  end
  if #matches == 0 then
    for _, model in ipairs(catalog) do
      if result.model == model.provider .. "/" .. model.id then
        table.insert(matches, model)
      end
    end
  end

  local match = #matches == 1 and matches[1] or nil
  if not match and #matches > 1 and result.preferred_provider then
    for _, model in ipairs(matches) do
      if model.provider == result.preferred_provider then
        match = model
        break
      end
    end
  end
  if not match then
    if #matches > 1 then
      return nil, "Model is ambiguous; configure a provider: " .. result.model
    end
    return nil, "Model unavailable or missing authentication: " .. (result.provider and result.provider .. "/" or "") .. result.model
  end

  result.provider = match.provider
  result.model = match.id
  result.preferred_provider = nil
  return result
end

function M.from_state(state)
  local model = state.model
  return {
    provider = model and model.provider or nil,
    model = model and model.id or nil,
    thinking = state.thinking_level,
  }
end

function M.label(selection)
  if not selection or not selection.model then
    return "model unavailable"
  end
  return string.format("%s/%s; thinking %s", selection.provider or "?", selection.model, selection.thinking or "n/a")
end

function M.preset_labels(model, config, catalog)
  local labels = {}
  for name, slot in pairs(config.slots or {}) do
    local selection = M.resolve(M.preset(config, name), catalog)
    if selection and selection.provider == model.provider and selection.model == model.id then
      local label = name
      if slot.label and slot.label ~= name then
        label = label .. ": " .. slot.label
      end
      if selection.thinking then
        label = label .. " / " .. selection.thinking
      end
      table.insert(labels, label)
    end
  end
  table.sort(labels)
  return labels
end

return M
