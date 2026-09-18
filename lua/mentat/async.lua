local async = assert(vim.async, "Mentat requires Neovim 0.13 with vim.async")
local M = {}

function M.main()
  if vim.in_fast_event() then
    async.await(vim.schedule)
  end
end

function M.call(start, owned)
  local results = vim.F.pack_len(async.await(function(done)
    local finished = false
    local accepted, err, task = start(function(...)
      finished = true
      done(...)
    end)
    if not accepted and not finished then
      finished = true
      done(false, err)
    end
    return {
      close = function(_, callback)
        if not finished and owned ~= false and task and not task:completed() then
          task:close(callback)
        else
          callback()
        end
      end,
    }
  end))
  M.main()
  return vim.F.unpack_len(results)
end

function M.select(items, opts)
  M.main()
  local choice, index = async.await(function(done)
    vim.ui.select(items, opts, done)
  end)
  M.main()
  return choice, index
end

function M.input(opts)
  M.main()
  local input = async.await(function(done)
    vim.ui.input(opts, done)
  end)
  M.main()
  return input
end

function M.system(command, opts)
  M.main()
  local result, err = async.await(function(done)
    local finished = false
    local closing
    local ok, process = pcall(vim.system, command, opts, function(output)
      finished = true
      if closing then
        closing()
      else
        done(output)
      end
    end)
    if not ok then
      finished = true
      done(nil, tostring(process))
    end
    return {
      close = function(_, callback)
        if finished then
          callback()
        else
          closing = callback
          process:kill(9)
        end
      end,
    }
  end)
  M.main()
  return result, err
end

function M.report(err)
  if err and err ~= "closed" then
    vim.schedule(function()
      vim.notify("Mentat: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

return M
