return function(test, eq, contains)
  local async = vim.async
  local uv = vim.uv

  test("callback adapters preserve synchronous tuples, rejection, and exactly-once results", function(f)
    local boundary = require("mentat.async")
    local closes = 0
    local fake = {
      completed = function() return false end,
      close = function(_, done) closes = closes + 1; done() end,
    }
    local task = f.task(function()
      local err, result = boundary.call(function(done)
        done("API error", nil)
        done(nil, "duplicate")
        return true, nil, fake
      end)
      eq(err, "API error")
      eq(result, nil)
      eq(boundary.call(function() return false, "rejected" end), false)
      return boundary.call(function(done)
        done(true, "value", nil, 4)
        return true, nil, fake
      end)
    end)
    local ok, result, missing, last = task:wait(1000)
    eq(ok, true)
    eq(result, "value")
    eq(missing, nil)
    eq(last, 4)
    eq(closes, 0)
  end)

  test("owned callback adapters close once and ignore late completion after cancellation", function(f)
    local boundary = require("mentat.async")
    local callback
    local closes = 0
    local completions = 0
    local task = f.task(function()
      boundary.call(function(done)
        callback = done
        return true, nil, {
          completed = function() return false end,
          close = function(_, closed)
            closes = closes + 1
            closed()
          end,
        }
      end)
      error("Cancelled callback resumed")
    end)
    task:on_complete(function() completions = completions + 1 end)
    task:close()
    task:close()
    callback(true)
    callback(false, "late error")
    local ok, err = task:pwait(1000)
    eq(ok, false)
    contains(err, "closed")
    eq(closes, 1)
    eq(completions, 1)
  end)

  test("native deadlines clean up owned callback adapters before reporting timeout", function(f)
    local boundary = require("mentat.async")
    local callback
    local closes = 0
    local task = f.task(function()
      local child = async.run(function()
        return boundary.call(function(done)
          callback = done
          return true, nil, {
            completed = function() return false end,
            close = function(_, closed)
              closes = closes + 1
              closed()
            end,
          }
        end)
      end)
      return pcall(async.timeout, 10, child)
    end)
    local ok, err = task:wait(1000)
    eq(ok, false)
    eq(err, "timeout")
    eq(closes, 1)
    callback(true)
    f.flush()
    eq(closes, 1)
  end)

  test("unowned waits do not cancel shared work and UI cancellation does not close a provider", function(f)
    local boundary = require("mentat.async")
    local closes = 0
    local late
    local task = f.task(function()
      return boundary.call(function(done)
        late = done
        return true, nil, {
          completed = function() return false end,
          close = function() closes = closes + 1 end,
        }
      end, false)
    end)
    task:close()
    late(true)
    eq(task:pwait(1000), false)
    eq(closes, 0)
    f.patch(vim.ui, "select", function(_, _, done)
      late = done
      return { close = function() closes = closes + 1 end }
    end)
    task = f.task(function() return boundary.select({ "one" }, {}) end)
    task:close()
    late("one")
    eq(task:pwait(1000), false)
    eq(closes, 0)
  end)

  test("UI input callbacks from libuv resume editor work on the main loop", function(f)
    local boundary = require("mentat.async")
    f.patch(vim.ui, "input", function(_, done)
      local timer = uv.new_timer()
      f.cleanup(function()
        if not timer:is_closing() then timer:close() end
      end)
      timer:start(1, 0, function()
        timer:close()
        done("input")
      end)
    end)
    local task = f.task(function()
      local input = boundary.input({})
      eq(vim.in_fast_event(), false)
      vim.api.nvim_get_current_buf()
      return input
    end)
    eq(task:wait(1000), "input")
  end)

  test("subprocess awaits return exit metadata on the main loop and report spawn failures", function(f)
    local boundary = require("mentat.async")
    local task = f.task(function()
      local result, err = boundary.system({ "sh", "-c", "printf output; printf failure >&2; exit 7" }, { text = true })
      eq(err, nil)
      eq(vim.in_fast_event(), false)
      return result
    end)
    local result = task:wait(2000)
    eq(result.code, 7)
    eq(result.stdout, "output")
    eq(result.stderr, "failure")
    local output, err = f.task(function()
      return boundary.system({ f.root .. "/missing-command" })
    end):wait(2000)
    eq(output, nil)
    assert(type(err) == "string" and err ~= "")
  end)

  test("closing a subprocess await kills it and waits for exactly one exit callback", function(f)
    local boundary = require("mentat.async")
    local system = vim.system
    local process
    local exits = 0
    f.patch(vim, "system", function(args, opts, done)
      process = system(args, opts, function(result)
        exits = exits + 1
        done(result)
      end)
      return process
    end)
    local task = f.task(function() return boundary.system({ "sleep", "30" }) end)
    eq(task:completed(), false)
    assert(process.pid > 0)
    task:close()
    eq(task:pwait(2000), false)
    eq(exits, 1)
    eq(uv.kill(process.pid, 0), nil)
    task:close()
    eq(exits, 1)
  end)

  test("filesystem reads and atomic writes yield, preserve bytes, and return on the main loop", function(f)
    local fs = require("mentat.fs")
    local path = f.root .. "/large.txt"
    local content = string.rep("abc\n", 50000)
    local returned = false
    local task = f.task(function()
      assert(fs.atomic_write(path, content))
      local text = assert(fs.read(path))
      eq(vim.in_fast_event(), false)
      returned = true
      return text
    end)
    eq(returned, false)
    eq(task:wait(3000), content)
    eq(vim.fn.glob(path .. ".mentat-*"), "")
    local missing = f.task(function() return fs.read(path .. ".missing") end)
    local result, err = missing:wait(1000)
    eq(result, nil)
    contains(err, "ENOENT")
  end)

  test("cancellation during fs_open closes a late successful descriptor", function(f)
    local fs = require("mentat.fs")
    local path = f.root .. "/open.txt"
    vim.fn.writefile({ "contents" }, path)
    local open = uv.fs_open
    local close = uv.fs_close
    local callback
    local fd
    local closes = 0
    f.patch(uv, "fs_open", function(name, flags, mode, done)
      if name ~= path then return open(name, flags, mode, done) end
      callback = done
      return {}
    end)
    f.patch(uv, "fs_close", function(number, done)
      if number == fd then closes = closes + 1 end
      return close(number, done)
    end)
    local task = f.task(function() return fs.read(path) end)
    f.wait(function() return callback ~= nil end)
    task:close()
    eq(task:completed(), false)
    fd = assert(open(path, "r", 384))
    callback(nil, fd)
    eq(task:pwait(1000), false)
    eq(closes, 1)
    eq(uv.fs_fstat(fd), nil)
  end)

  test("cancellation during fs_read waits for I/O before closing its descriptor", function(f)
    local fs = require("mentat.fs")
    local path = f.root .. "/read.txt"
    vim.fn.writefile({ "contents" }, path)
    local callback
    local fd
    local closes = 0
    local close = uv.fs_close
    f.patch(uv, "fs_read", function(number, _, _, done)
      fd = number
      callback = done
      return {}
    end)
    f.patch(uv, "fs_close", function(number, done)
      if number == fd then closes = closes + 1 end
      return close(number, done)
    end)
    local task = f.task(function() return fs.read(path) end)
    f.wait(function() return callback ~= nil end)
    task:close()
    eq(closes, 0)
    callback(nil, "late bytes")
    eq(task:pwait(1000), false)
    eq(closes, 1)
    eq(uv.fs_fstat(fd), nil)
  end)

  test("cancelled exclusive open never unlinks another owner's existing temporary file", function(f)
    local fs = require("mentat.fs")
    local path = f.root .. "/state.json"
    local callback
    local temp
    f.patch(uv, "fs_open", function(name, flags, _, done)
      eq(flags, "wx")
      temp = name
      vim.fn.writefile({ "existing owner" }, temp)
      callback = done
      return {}
    end)
    local task = f.task(function() return fs.atomic_write(path, "replacement") end)
    f.wait(function() return callback ~= nil end)
    task:close()
    callback("EEXIST: file already exists")
    eq(task:pwait(1000), false)
    eq(vim.fn.readfile(temp), { "existing owner" })
    eq(vim.fn.filereadable(path), 0)
  end)

  test("atomic writes handle partial writes and clean up failed writes and renames", function(f)
    local fs = require("mentat.fs")
    local path = f.root .. "/state.json"
    vim.fn.writefile({ "previous" }, path)
    local write = uv.fs_write
    f.patch(uv, "fs_write", function(fd, text, offset, done)
      return write(fd, text:sub(1, 3), offset, done)
    end)
    eq(f.task(function() return fs.atomic_write(path, "a complete replacement") end):wait(1000), true)
    eq(vim.fn.readfile(path), { "a complete replacement" })
    f.patch(uv, "fs_write", function(_, _, _, done)
      vim.schedule(function() done("ENOSPC: no space left") end)
      return {}
    end)
    local result, err = f.task(function() return fs.atomic_write(path, "lost") end):wait(1000)
    eq(result, nil)
    contains(err, "ENOSPC")
    eq(vim.fn.readfile(path), { "a complete replacement" })
    eq(vim.fn.glob(path .. ".mentat-*"), "")
    f.patch(uv, "fs_write", write)
    f.patch(uv, "fs_rename", function() return nil, "EACCES: rename denied" end)
    result, err = f.task(function() return fs.atomic_write(path, "lost") end):wait(1000)
    eq(result, nil)
    contains(err, "EACCES")
    eq(vim.fn.glob(path .. ".mentat-*"), "")
  end)

  test("temporary session scopes remove their file after success, error, and cancellation", function(f)
    local fs = require("mentat.fs")
    local path
    local ok = f.task(function()
      return fs.with_temp("session\n", function(temp)
        path = temp
        eq(vim.fn.readfile(path), { "session" })
        return true
      end)
    end):wait(1000)
    eq(ok, true)
    eq(vim.fn.filereadable(path), 0)
    local result, err = f.task(function()
      return fs.with_temp("session\n", function(temp)
        path = temp
        error("clone failed", 0)
      end)
    end):wait(1000)
    eq(result, nil)
    contains(err, "clone failed")
    eq(vim.fn.filereadable(path), 0)
    local ready = false
    local task = f.task(function()
      return fs.with_temp("session\n", function(temp)
        path = temp
        ready = true
        async.await(function() end)
      end)
    end)
    f.wait(function() return ready end)
    task:close()
    eq(task:pwait(1000), false)
    eq(vim.fn.filereadable(path), 0)
  end)

  test("append progress is committed synchronously and partial failures can resume without duplication", function(f)
    local fs = require("mentat.fs")
    local path = f.root .. "/append.log"
    vim.fn.writefile({ "external" }, path)
    local write = uv.fs_write
    local committed = 0
    local calls = 0
    f.patch(uv, "fs_write", function(fd, text, offset, done)
      eq(done, nil)
      calls = calls + 1
      if calls == 2 then return nil, "ENOSPC" end
      return write(fd, text:sub(1, 4), offset)
    end)
    local result, err = f.task(function()
      return fs.append(path, "abcdefgh\n", function(count) committed = committed + count end)
    end):wait(1000)
    eq(result, nil)
    contains(err, "ENOSPC")
    eq(committed, 4)
    f.patch(uv, "fs_write", write)
    assert(fs.append_sync(path, ("abcdefgh\n"):sub(committed + 1), function(count) committed = committed + count end))
    eq(committed, 9)
    eq(vim.fn.readfile(path), { "external", "abcdefgh" })
  end)
end
