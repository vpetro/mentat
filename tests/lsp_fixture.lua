return function(f, count)
  local state = { clients = {}, requests = {}, cancelled = {} }
  local path = f.root .. "/source.lua"
  vim.fn.writefile({ "local answer = 42", "return answer" }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  state.buf = buf
  state.path = path
  for index = 1, count or 1 do
    local client = { id = index, requests = {} }
    function client:supports_method(method)
      return not self.methods or self.methods[method] == true
    end
    function client:request(method, params, callback, bufnr)
      if self.reject then
        return false
      end
      local id = #state.requests + 1
      local entry = { id = id, client = self, method = method, params = params, callback = callback, bufnr = bufnr }
      state.requests[#state.requests + 1] = entry
      self.requests[id] = true
      if self.synchronous then
        callback(nil, self.synchronous, { client_id = self.id })
        self.requests[id] = nil
      end
      return true, id
    end
    function client:cancel_request(id)
      state.cancelled[#state.cancelled + 1] = { client = self.id, id = id }
      self.requests[id] = nil
      return true
    end
    state.clients[index] = client
  end
  f.patch(vim.lsp, "get_clients", function(opts)
    local clients = {}
    if opts.bufnr ~= buf then
      return clients
    end
    for _, client in ipairs(state.clients) do
      if not opts.method or client:supports_method(opts.method) then
        clients[#clients + 1] = client
      end
    end
    return clients
  end)
  function state.reply(index, result, err)
    local request = assert(state.requests[index])
    request.client.requests[request.id] = nil
    request.callback(err, result, { client_id = request.client.id })
  end
  return state
end
