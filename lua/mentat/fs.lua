local async = vim.async
local boundary = require("mentat.async")
local uv = vim.uv
local M = {}
local next_temp = 0

local function request(start)
  return async.await(function(done)
    local finished = false
    local closing
    local handle, err = start(function(...)
      if finished then
        return
      end
      finished = true
      if closing then
        closing()
      else
        done(...)
      end
    end)
    if not handle and not finished then
      finished = true
      done(err or "Could not start filesystem operation")
    end
    return {
      close = function(_, callback)
        if finished then
          callback()
        else
          closing = callback
        end
      end,
    }
  end)
end

local function cleanup(resources, done)
  local function unlink(close_err)
    if resources.temp then
      uv.fs_unlink(resources.temp, function(err)
        done(close_err or (err and not err:find("ENOENT", 1, true) and err or nil))
      end)
    else
      done(close_err)
    end
  end
  if resources.fd then
    uv.fs_close(resources.fd, unlink)
  else
    unlink()
  end
end

local function file_operation(work)
  local result, err = async.await(function(done)
    local resources = {}
    local finished = false
    local closing
    local task = async.run("mentat file", function()
      return work(resources)
    end):detach()
    task:on_complete(function(task_err, output, io_err)
      cleanup(resources, function(cleanup_err)
        finished = true
        if closing then
          closing()
        else
          local failure = task_err or io_err or cleanup_err
          done(not failure and output or nil, failure and tostring(failure) or nil)
        end
      end)
    end)
    return {
      close = function(_, callback)
        if finished then
          callback()
        else
          closing = callback
          task:close()
        end
      end,
    }
  end)
  boundary.main()
  return result, err
end

local function open(resources, path, flags)
  return request(function(done)
    return uv.fs_open(path, flags, 384, function(err, fd)
      resources.fd = fd
      if fd and flags == "wx" then
        resources.temp = path
      end
      done(err)
    end)
  end)
end

local function write(resources, content)
  local offset = 0
  while offset < #content do
    local err, count = request(function(done)
      return uv.fs_write(resources.fd, content:sub(offset + 1, offset + 65536), offset, done)
    end)
    if err then
      return nil, err
    end
    if not count or count == 0 then
      return nil, "Filesystem write made no progress"
    end
    offset = offset + count
  end
  return true
end

local function close(resources)
  return request(function(done)
    return uv.fs_close(resources.fd, function(err)
      resources.fd = nil
      done(err)
    end)
  end)
end

function M.read(path)
  return file_operation(function(resources)
    local err = open(resources, path, "r")
    if err then
      return nil, err
    end
    local chunks = {}
    local offset = 0
    while true do
      local read_err, chunk = request(function(done)
        return uv.fs_read(resources.fd, 65536, offset, done)
      end)
      if read_err then
        return nil, read_err
      end
      if chunk == "" then
        return table.concat(chunks)
      end
      chunks[#chunks + 1] = chunk
      offset = offset + #chunk
    end
  end)
end

function M.read_lines(path)
  local content, err = M.read(path)
  if not content then
    return nil, err
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function append_bytes(fd, content, committed)
  local offset = 0
  while offset < #content do
    local count, err = uv.fs_write(fd, content:sub(offset + 1), -1)
    if not count then
      return nil, err
    end
    if count == 0 then
      return nil, "Filesystem append made no progress"
    end
    offset = offset + count
    committed(count)
  end
  return true
end

function M.append(path, content, committed)
  return file_operation(function(resources)
    local err = open(resources, path, "a")
    if err then
      return nil, err
    end
    boundary.main()
    async.checkpoint()
    return append_bytes(resources.fd, content, committed)
  end)
end

function M.append_sync(path, content, committed)
  local fd, err = uv.fs_open(path, "a", 384)
  if not fd then
    return nil, err
  end
  local ok, write_err = append_bytes(fd, content, committed)
  local closed, close_err = uv.fs_close(fd)
  return ok and closed, write_err or close_err
end

function M.atomic_write(path, content)
  next_temp = next_temp + 1
  local temp = string.format("%s.mentat-%d-%d", path, uv.os_getpid(), next_temp)
  return file_operation(function(resources)
    local err = open(resources, temp, "wx")
    if err then
      return nil, err
    end
    local ok, write_err = write(resources, content)
    if not ok then
      return nil, write_err
    end
    local close_err = close(resources)
    if close_err then
      return nil, close_err
    end
    boundary.main()
    async.checkpoint()
    local renamed, rename_err = uv.fs_rename(temp, path)
    if renamed then
      resources.temp = nil
    end
    return renamed, rename_err
  end)
end

function M.with_temp(content, work)
  boundary.main()
  local path = vim.fn.tempname() .. ".jsonl"
  return file_operation(function(resources)
    local err = open(resources, path, "wx")
    if err then
      return nil, err
    end
    local written, write_err = write(resources, content)
    if not written then
      return nil, write_err
    end
    local close_err = close(resources)
    if close_err then
      return nil, close_err
    end
    boundary.main()
    return work(path)
  end)
end

function M.list(path)
  local err, scan = request(function(done)
    return uv.fs_scandir(path, done)
  end)
  local files = {}
  if not err then
    while true do
      local name, kind = uv.fs_scandir_next(scan)
      if not name then
        break
      end
      files[#files + 1] = { name = name, type = kind }
    end
  end
  boundary.main()
  return not err and files or nil, err
end

return M
