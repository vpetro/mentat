local async = vim.async
local boundary = require("mentat.async")
local M = {}

local TIMEOUT_MS = 5000
local is_list = vim.islist
local get_lsp_clients = vim.lsp.get_clients

function M.request(bufnr, method, params, timeout_ms)
  boundary.main()
  local clients = get_lsp_clients({ bufnr = bufnr, method = method })
  if #clients == 0 then
    return {}
  end
  local task = async.run("mentat LSP " .. method, function()
    return async.await(function(done)
      local remaining = #clients
      local results = {}
      local requests = {}
      local closed = false
      local function response(client, err, result, context)
        if closed or results[client.id] then
          return
        end
        requests[client.id] = nil
        results[client.id] = { err = err, result = result, context = context }
        remaining = remaining - 1
        if remaining == 0 then
          done(results)
        end
      end
      for _, client in ipairs(clients) do
        local accepted, id = client:request(method, params, function(err, result, context)
          response(client, err, result, context)
        end, bufnr)
        if not accepted then
          response(client, { message = "LSP client stopped before dispatch" })
        elseif not results[client.id] then
          requests[client.id] = { client = client, id = id }
        end
      end
      return {
        close = function(_, callback)
          closed = true
          local function cancel()
            for _, request in pairs(requests) do
              request.client:cancel_request(request.id)
            end
            requests = {}
            callback()
          end
          if vim.in_fast_event() then
            vim.schedule(cancel)
          else
            cancel()
          end
        end,
      }
    end)
  end)
  local ok, result = pcall(async.timeout, timeout_ms or TIMEOUT_MS, task)
  async.checkpoint()
  boundary.main()
  if not ok then
    return nil, tostring(result)
  end
  return result
end

-- ─── Constants ─────────────────────────────────────────────────────────────

local SEVERITY = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN]  = "warn",
  [vim.diagnostic.severity.INFO]  = "info",
  [vim.diagnostic.severity.HINT]  = "hint",
}

local SYMBOL_KIND = {
  [1]  = "File",        [2]  = "Module",      [3]  = "Namespace",
  [4]  = "Package",     [5]  = "Class",        [6]  = "Method",
  [7]  = "Property",    [8]  = "Field",        [9]  = "Constructor",
  [10] = "Enum",        [11] = "Interface",    [12] = "Function",
  [13] = "Variable",    [14] = "Constant",     [15] = "String",
  [16] = "Number",      [17] = "Boolean",      [18] = "Array",
  [19] = "Object",      [20] = "Key",          [21] = "Null",
  [22] = "EnumMember",  [23] = "Struct",       [24] = "Event",
  [25] = "Operator",    [26] = "TypeParameter",
}

-- ─── Internal helpers ──────────────────────────────────────────────────────

local function resolve_path(repo_root, rel_path)
  if not rel_path or rel_path == "" then
    return nil, "path is required"
  end
  -- Allow absolute paths (e.g. from a previous lsp_definition result)
  if rel_path:match("^/") then
    return rel_path
  end
  if rel_path:match("%.%.") then
    return nil, "path cannot contain '..'"
  end
  return repo_root .. "/" .. rel_path
end

local function get_or_load_buf(abs_path)
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return bufnr, false
  end
  bufnr = vim.fn.bufadd(abs_path)
  vim.fn.bufload(bufnr)
  return bufnr, true
end

local function make_position_params(bufnr, line, col)
  -- line/col are 1-indexed; LSP wants 0-indexed
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position     = { line = line - 1, character = col - 1 },
  }
end

local function shorten_path(abs_path, repo_root)
  if repo_root and abs_path:sub(1, #repo_root) == repo_root then
    return abs_path:sub(#repo_root + 2)   -- strip "root/"
  end
  return abs_path
end

-- Format a Location or LocationLink into "path:line:col"
local function format_location(loc, repo_root)
  local uri   = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange
  local path  = shorten_path(vim.uri_to_fname(uri), repo_root)
  local line  = range.start.line + 1
  local col   = range.start.character + 1
  return string.format("%s:%d:%d", path, line, col)
end

-- Normalise an LSP response result into a flat list of Location/LocationLink tables.
-- The spec allows null, a single Location, or an array.
local function collect_locations(responses)
  local locs = {}
  for _, resp in pairs(responses or {}) do
    local r = resp.result
    if r then
      if type(r) == "table" then
        if r.uri or r.targetUri then
          -- Single Location / LocationLink
          table.insert(locs, r)
        elseif is_list(r) then
          for _, loc in ipairs(r) do
            table.insert(locs, loc)
          end
        end
      end
    end
  end
  return locs
end

-- Guard: return an error string if no LSP client is attached to bufnr.
-- Used by tools that need a live language server.
local function require_lsp_client(bufnr, path)
  local clients = get_lsp_clients({ bufnr = bufnr })
  if #clients == 0 then
    return string.format(
      "No LSP client attached to '%s'. The file must be open in Neovim (and have a running language server) for this tool to work.",
      path
    )
  end
  return nil  -- ok
end

-- ─── lsp_diagnostics ──────────────────────────────────────────────────────
-- Uses vim.diagnostic.get(), which is populated by LSP but also by other
-- sources (null-ls, lint.nvim, etc.). Works even without a live LSP client.

local function exec_lsp_diagnostics(input, repo_root)
  local lines = {}

  if input.path and input.path ~= "" then
    -- Single file
    local abs_path, err = resolve_path(repo_root, input.path)
    if not abs_path then return "Error: " .. err end

    local bufnr = get_or_load_buf(abs_path)
    local diags = vim.diagnostic.get(bufnr)

    if #diags == 0 then
      return "No diagnostics for " .. input.path
    end

    table.insert(lines, string.format("Diagnostics for %s (%d):", input.path, #diags))
    for _, d in ipairs(diags) do
      table.insert(lines, string.format("  %d:%d [%s] %s%s",
        d.lnum + 1, d.col + 1,
        SEVERITY[d.severity] or "?",
        d.message,
        d.source and (" (" .. d.source .. ")") or ""))
    end
  else
    -- All open buffers with a file name
    local diags = vim.diagnostic.get(nil)
    if #diags == 0 then
      return "No diagnostics in any open buffer."
    end

    local by_buf = {}
    for _, d in ipairs(diags) do
      if vim.api.nvim_buf_is_valid(d.bufnr)
        and vim.bo[d.bufnr].buftype == ""
      then
        local name = vim.api.nvim_buf_get_name(d.bufnr)
        if name and name ~= "" then
          if not by_buf[d.bufnr] then by_buf[d.bufnr] = {} end
          table.insert(by_buf[d.bufnr], d)
        end
      end
    end

    local total = 0
    for bufnr, buf_diags in pairs(by_buf) do
      local name = shorten_path(vim.api.nvim_buf_get_name(bufnr), repo_root)
      table.insert(lines, string.format("%s (%d):", name, #buf_diags))
      for _, d in ipairs(buf_diags) do
        table.insert(lines, string.format("  %d:%d [%s] %s%s",
          d.lnum + 1, d.col + 1,
          SEVERITY[d.severity] or "?",
          d.message,
          d.source and (" (" .. d.source .. ")") or ""))
        total = total + 1
      end
      table.insert(lines, "")
    end
    table.insert(lines, 1, string.format("Total diagnostics: %d\n", total))
  end

  return table.concat(lines, "\n")
end

-- ─── lsp_hover ────────────────────────────────────────────────────────────

local function exec_lsp_hover(input, repo_root)
  if not input.path then return "Error: path is required" end
  if not input.line then return "Error: line is required" end
  if not input.col  then return "Error: col is required"  end

  local abs_path, err = resolve_path(repo_root, input.path)
  if not abs_path then return "Error: " .. err end

  local bufnr = get_or_load_buf(abs_path)
  local client_err = require_lsp_client(bufnr, input.path)
  if client_err then return client_err end

  local params = make_position_params(bufnr, input.line, input.col)
  local responses, rpc_err = M.request(bufnr, "textDocument/hover", params)
  if rpc_err then return "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return "No hover info at " .. input.path .. ":" .. input.line .. ":" .. input.col
  end

  local parts = {}
  for _, resp in pairs(responses) do
    local result = resp.result
    if result and result.contents then
      local c = result.contents
      if type(c) == "string" then
        table.insert(parts, c)
      elseif type(c) == "table" then
        if c.value then
          table.insert(parts, c.value)
        elseif is_list(c) then
          for _, item in ipairs(c) do
            if type(item) == "string" then
              table.insert(parts, item)
            elseif type(item) == "table" and item.value then
              table.insert(parts, item.value)
            end
          end
        end
      end
    end
  end

  if #parts == 0 then
    return "No hover content returned at " .. input.path .. ":" .. input.line .. ":" .. input.col
  end
  return table.concat(parts, "\n\n")
end

-- ─── lsp_definition ───────────────────────────────────────────────────────

local function exec_lsp_definition(input, repo_root)
  if not input.path then return "Error: path is required" end
  if not input.line then return "Error: line is required" end
  if not input.col  then return "Error: col is required"  end

  local abs_path, err = resolve_path(repo_root, input.path)
  if not abs_path then return "Error: " .. err end

  local bufnr = get_or_load_buf(abs_path)
  local client_err = require_lsp_client(bufnr, input.path)
  if client_err then return client_err end

  local params = make_position_params(bufnr, input.line, input.col)
  local responses, rpc_err = M.request(bufnr, "textDocument/definition", params)
  if rpc_err then return "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return "No definition found"
  end

  local locs = collect_locations(responses)
  if #locs == 0 then return "No definition found" end

  local out = { string.format("Definition(s) (%d):", #locs) }
  for _, loc in ipairs(locs) do
    table.insert(out, "  " .. format_location(loc, repo_root))
  end
  return table.concat(out, "\n")
end

-- ─── lsp_references ───────────────────────────────────────────────────────

local function exec_lsp_references(input, repo_root)
  if not input.path then return "Error: path is required" end
  if not input.line then return "Error: line is required" end
  if not input.col  then return "Error: col is required"  end

  local abs_path, err = resolve_path(repo_root, input.path)
  if not abs_path then return "Error: " .. err end

  local bufnr = get_or_load_buf(abs_path)
  local client_err = require_lsp_client(bufnr, input.path)
  if client_err then return client_err end

  local params = make_position_params(bufnr, input.line, input.col)
  params.context = { includeDeclaration = true }

  local responses, rpc_err = M.request(bufnr, "textDocument/references", params)
  if rpc_err then return "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return "No references found"
  end

  local locs = collect_locations(responses)
  if #locs == 0 then return "No references found" end

  local out = { string.format("References (%d):", #locs) }
  for _, loc in ipairs(locs) do
    table.insert(out, "  " .. format_location(loc, repo_root))
  end
  return table.concat(out, "\n")
end

-- ─── lsp_document_symbols ─────────────────────────────────────────────────

-- Recursively flatten DocumentSymbol trees (which nest via `children`)
local function flatten_doc_symbols(symbols, depth, out)
  for _, sym in ipairs(symbols or {}) do
    local indent = string.rep("  ", depth)
    local kind   = SYMBOL_KIND[sym.kind] or ("Kind" .. sym.kind)
    local range  = sym.selectionRange or sym.range
    local line   = range and (range.start.line + 1) or "?"
    table.insert(out, string.format("%s[%s] %s  (line %s)", indent, kind, sym.name, line))
    if sym.children and #sym.children > 0 then
      flatten_doc_symbols(sym.children, depth + 1, out)
    end
  end
end

local function exec_lsp_document_symbols(input, repo_root)
  if not input.path then return "Error: path is required" end

  local abs_path, err = resolve_path(repo_root, input.path)
  if not abs_path then return "Error: " .. err end

  local bufnr = get_or_load_buf(abs_path)
  local client_err = require_lsp_client(bufnr, input.path)
  if client_err then return client_err end

  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  local responses, rpc_err = M.request(bufnr, "textDocument/documentSymbol", params)
  if rpc_err then return "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return "No symbols found"
  end

  local sym_lines = {}
  for _, resp in pairs(responses) do
    if resp.result and #resp.result > 0 then
      flatten_doc_symbols(resp.result, 0, sym_lines)
    end
  end

  if #sym_lines == 0 then
    return "No symbols found in " .. input.path
  end
  table.insert(sym_lines, 1, "Symbols in " .. input.path .. ":")
  return table.concat(sym_lines, "\n")
end

-- ─── lsp_workspace_symbols ────────────────────────────────────────────────

local function exec_lsp_workspace_symbols(input, repo_root)
  if not input.query then return "Error: query is required" end

  local bufnr = vim.api.nvim_get_current_buf()
  if #get_lsp_clients({ bufnr = bufnr }) == 0 then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if #get_lsp_clients({ bufnr = b }) > 0 then
        bufnr = b
        break
      end
    end
  end
  if #get_lsp_clients({ bufnr = bufnr }) == 0 then
    return "No LSP clients are running. Open a source file with an active language server first."
  end

  local responses, rpc_err = M.request(
    bufnr, "workspace/symbol", { query = input.query })
  if rpc_err then return "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return "No workspace symbols matched: " .. input.query
  end

  local sym_lines = {}
  for _, resp in pairs(responses) do
    for _, sym in ipairs(resp.result or {}) do
      local kind = SYMBOL_KIND[sym.kind] or ("Kind" .. sym.kind)
      local loc_str
      if sym.location then
        loc_str = format_location(sym.location, repo_root)
      elseif sym.locationUri then
        loc_str = shorten_path(vim.uri_to_fname(sym.locationUri), repo_root)
      else
        loc_str = "unknown location"
      end
      local entry = string.format("[%s] %s  @ %s", kind, sym.name, loc_str)
      if sym.containerName and sym.containerName ~= "" then
        entry = entry .. "  (in " .. sym.containerName .. ")"
      end
      table.insert(sym_lines, entry)
    end
  end

  if #sym_lines == 0 then
    return "No workspace symbols matched: " .. input.query
  end
  table.sort(sym_lines)
  table.insert(sym_lines, 1, string.format("Workspace symbols matching %q (%d):", input.query, #sym_lines))
  return table.concat(sym_lines, "\n")
end

-- ─── Call hierarchy (shared prepare step) ────────────────────────────────

local function prepare_call_hierarchy(input, repo_root)
  if not input.path then return nil, nil, "Error: path is required" end
  if not input.line then return nil, nil, "Error: line is required" end
  if not input.col  then return nil, nil, "Error: col is required"  end

  local abs_path, err = resolve_path(repo_root, input.path)
  if not abs_path then return nil, nil, "Error: " .. err end

  local bufnr = get_or_load_buf(abs_path)
  local client_err = require_lsp_client(bufnr, input.path)
  if client_err then return nil, nil, client_err end

  local params = make_position_params(bufnr, input.line, input.col)
  local responses, rpc_err = M.request(
    bufnr, "textDocument/prepareCallHierarchy", params)
  if rpc_err then return nil, nil, "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return nil, nil, "No call hierarchy item at " .. input.path .. ":" .. input.line .. ":" .. input.col
  end

  local item = nil
  for _, resp in pairs(responses) do
    if resp.result and type(resp.result) == "table" then
      if is_list(resp.result) and #resp.result > 0 then
        item = resp.result[1]
      elseif resp.result.name then
        item = resp.result
      end
    end
    if item then break end
  end
  if not item then
    return nil, nil, "No call hierarchy item at " .. input.path .. ":" .. input.line .. ":" .. input.col
  end

  return bufnr, item, nil
end

-- ─── lsp_incoming_calls ─────────────────────────────────────────────────

local function exec_lsp_incoming_calls(input, repo_root)
  local bufnr, item, err = prepare_call_hierarchy(input, repo_root)
  if err then return err end

  local responses, rpc_err = M.request(
    bufnr, "callHierarchy/incomingCalls", { item = item })
  if rpc_err then return "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return "No incoming calls found for " .. item.name
  end

  local out = {}
  for _, resp in pairs(responses) do
    for _, call in ipairs(resp.result or {}) do
      local caller = call.from
      if caller then
        local kind = SYMBOL_KIND[caller.kind] or ("Kind" .. caller.kind)
        local path = shorten_path(vim.uri_to_fname(caller.uri), repo_root)
        local line = caller.selectionRange.start.line + 1
        table.insert(out, string.format("  [%s] %s  @ %s:%d", kind, caller.name, path, line))
      end
    end
  end

  if #out == 0 then
    return "No incoming calls found for " .. item.name
  end
  table.insert(out, 1, string.format("Incoming calls to %s (%d):", item.name, #out))
  return table.concat(out, "\n")
end

-- ─── lsp_outgoing_calls ─────────────────────────────────────────────────

local function exec_lsp_outgoing_calls(input, repo_root)
  local bufnr, item, err = prepare_call_hierarchy(input, repo_root)
  if err then return err end

  local responses, rpc_err = M.request(
    bufnr, "callHierarchy/outgoingCalls", { item = item })
  if rpc_err then return "LSP error: " .. tostring(rpc_err) end
  if not responses or vim.tbl_isempty(responses) then
    return "No outgoing calls found from " .. item.name
  end

  local out = {}
  for _, resp in pairs(responses) do
    for _, call in ipairs(resp.result or {}) do
      local callee = call.to
      if callee then
        local kind = SYMBOL_KIND[callee.kind] or ("Kind" .. callee.kind)
        local path = shorten_path(vim.uri_to_fname(callee.uri), repo_root)
        local line = callee.selectionRange.start.line + 1
        table.insert(out, string.format("  [%s] %s  @ %s:%d", kind, callee.name, path, line))
      end
    end
  end

  if #out == 0 then
    return "No outgoing calls found from " .. item.name
  end
  table.insert(out, 1, string.format("Outgoing calls from %s (%d):", item.name, #out))
  return table.concat(out, "\n")
end

-- ─── Public dispatch ───────────────────────────────────────────────────────

function M.execute(name, input, repo_root)
  if     name == "lsp_diagnostics"       then return exec_lsp_diagnostics(input, repo_root)
  elseif name == "lsp_hover"             then return exec_lsp_hover(input, repo_root)
  elseif name == "lsp_definition"        then return exec_lsp_definition(input, repo_root)
  elseif name == "lsp_references"        then return exec_lsp_references(input, repo_root)
  elseif name == "lsp_document_symbols"  then return exec_lsp_document_symbols(input, repo_root)
  elseif name == "lsp_workspace_symbols" then return exec_lsp_workspace_symbols(input, repo_root)
  elseif name == "lsp_incoming_calls"   then return exec_lsp_incoming_calls(input, repo_root)
  elseif name == "lsp_outgoing_calls"   then return exec_lsp_outgoing_calls(input, repo_root)
  else   return "Error: unknown LSP tool: " .. name
  end
end

return M
