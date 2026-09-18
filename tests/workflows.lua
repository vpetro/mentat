return function(test, eq, contains)
  local async = vim.async
  local uv = vim.uv

  local function opened(f)
    local mentat, buffer, editor = f.ui()
    buffer.open()
    f.wait(function() return mentat.get_client().state.ready and not mentat.get_client().is_busy() end)
    return mentat, buffer, editor
  end

  local function review_context(f)
    local mentat, buffer = opened(f)
    local source = f.seed(f.catalog[4], "low")
    local context = {
      version = 1, session_file = source, leaf_id = "second", session_name = "source review",
    }
    local lines = {
      vim.json.encode({ type = "session", id = f.sessions[source].sessionId }),
      vim.json.encode({ type = "message", id = "first", parentId = vim.NIL }),
      vim.json.encode({ type = "message", id = "second", parentId = "first" }),
      vim.json.encode({ type = "message", id = "third", parentId = "second" }),
    }
    vim.fn.writefile(lines, source)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, f.root .. "/review.md")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mentat-context: " .. vim.json.encode(context), "# Review" })
    vim.api.nvim_set_current_buf(buf)
    return mentat, buffer, buf, source, table.concat(lines, "\n") .. "\n"
  end

  test("system prompt generation keeps one captured repository across filesystem awaits", function(f)
    package.loaded["mentat.editor_bridge"] = { get_env = function() return {} end, stop = function() end }
    local mentat = require("mentat")
    local fs = require("mentat.fs")
    local boundary = require("mentat.async")
    local buffers = {}
    for _, name in ipairs({ "a", "b" }) do
      vim.fn.mkdir(f.root .. "/" .. name .. "/.git", "p")
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, f.root .. "/" .. name .. "/source.lua")
      buffers[name] = buf
    end
    vim.api.nvim_set_current_buf(buffers.a)
    local resume
    local read_path
    local tree_command
    f.patch(fs, "read", function(path)
      read_path = path
      return async.await(function(done) resume = done end)
    end)
    f.patch(boundary, "system", function(command)
      tree_command = command[3]
      return { code = 0, stdout = "directory contents" }
    end)
    local task = f.task(mentat.get_system_prompt)
    f.wait(function() return resume ~= nil end)
    vim.api.nvim_set_current_buf(buffers.b)
    resume("repository A instructions")
    contains(task:wait(1000), "repository A instructions")
    eq(read_path, f.root .. "/a/.mentat/system_prompt.md")
    contains(tree_command, f.root .. "/a")
    eq(tree_command:find(f.root .. "/b", 1, true), nil)
  end)

  test("fork preparation uses the original root even if the editor changes before startup", function(f)
    package.loaded["mentat.editor_bridge"] = { get_env = function() return {} end, stop = function() end }
    local mentat = require("mentat")
    mentat.setup({ provider = "openai", model = "reasoner", thinking = "medium", pi = { no_session = true } })
    local roots = {}
    mentat.get_system_prompt = function(root)
      roots[#roots + 1] = root
    end
    local buffers = {}
    for _, name in ipairs({ "a", "b" }) do
      vim.fn.mkdir(f.root .. "/" .. name .. "/.git", "p")
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, f.root .. "/" .. name .. "/source.lua")
      buffers[name] = buf
    end
    vim.api.nvim_set_current_buf(buffers.a)
    local branch_client
    local task = mentat.fork(function(client, err)
      assert(client, err)
      branch_client = client
      f.clients[#f.clients + 1] = client
    end)
    f.tasks[#f.tasks + 1] = task
    vim.api.nvim_set_current_buf(buffers.b)
    task:wait(2000)
    eq(roots, { f.root .. "/a", f.root .. "/a" })
    eq(f.jobs[1].options.cwd, f.root .. "/a")
    eq(f.jobs[2].options.cwd, f.root .. "/a")
    eq(branch_client.get_selection().model, "reasoner")
  end)

  test("clear-session completion writes its instance claim to the captured repository", function(f)
    local mentat, buffer = opened(f)
    local other_root = f.root .. "/other"
    vim.fn.mkdir(other_root .. "/.git", "p")
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(other, other_root .. "/source.lua")
    f.hold.new_session = true
    assert(buffer.clear())
    f.wait(function() return #f.held == 1 end)
    vim.api.nvim_set_current_buf(other)
    f.release("new_session")
    f.wait(function() return not mentat.get_client().is_busy() end)
    local claim = "/.mentat/pi/instances/" .. vim.fn.getpid() .. ".json"
    eq(vim.fn.filereadable(f.root .. claim), 1)
    eq(vim.fn.filereadable(other_root .. claim), 0)
  end)

  test("disposing a branch during its own startup does not stop the main conversation", function(f)
    local mentat = opened(f)
    local dispatch = f.dispatch
    f.dispatch = function(id, command)
      if id == 2 and command.type == "get_state" then
        f.held[#f.held + 1] = { job = id, command = command }
      else
        dispatch(id, command)
      end
    end
    local buf = require("mentat.branch").open("draft")
    f.wait(function() return #f.jobs == 2 and #f.held == 1 end)
    vim.api.nvim_buf_delete(buf, { force = true })
    f.wait(function() return f.jobs[2].stopped == true end)
    eq(f.jobs[1].stopped, nil)
    eq(mentat.get_client().state.ready, true)
    f.dispatch = dispatch
    f.release("get_state")
    local completed = false
    assert(mentat.chat("main prompt", nil, function() completed = true end))
    f.wait(function() return #f.sent == 1 end)
    f.complete(1)
    eq(completed, true)
  end)

  test("disposing a picker during catalog loading cancels its owned operation and suppresses late UI", function(f)
    local mentat, buffer = opened(f)
    local buf = buffer.target().bufnr
    local shown = false
    f.patch(vim.ui, "select", function() shown = true end)
    f.hold.get_available_models = true
    local task = require("mentat.model_picker").pick("model")
    f.wait(function() return #f.held == 1 end)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(task:pwait(1000), false)
    f.release("get_available_models")
    f.flush()
    eq(shown, false)
    eq(mentat.get_client().is_busy(), false)
    eq(f.jobs[1].stopped, true)
  end)

  test("review loading awaits a branch snapshot, preserves its source, and deletes temporary files", function(f)
    local mentat, _, buf, source, original = review_context(f)
    local fs = require("mentat.fs")
    local with_temp = fs.with_temp
    local snapshots = {}
    f.patch(fs, "with_temp", function(content, work)
      return with_temp(content, function(path)
        snapshots[#snapshots + 1] = { path = path, content = content }
        return work(path)
      end)
    end)
    local review = require("mentat.review")
    assert(review.load({ bufnr = buf }):wait(3000))
    local clone = vim.b[buf].mentat_review_session
    eq(clone, mentat.get_session_file())
    assert(clone ~= source)
    eq(vim.fn.filereadable(snapshots[1].path), 0)
    contains(snapshots[1].content, '"second"')
    eq(snapshots[1].content:find('"third"', 1, true), nil)
    eq(table.concat(vim.fn.readfile(source), "\n") .. "\n", original)
    eq(vim.json.decode(vim.fn.readfile(clone, "", 1)[1]).parentSession, source)
    eq(mentat.get_client().get_selection().model, "legacy")
    local clones = f.count("clone")
    assert(review.load({ bufnr = buf }):wait(3000))
    eq(f.count("clone"), clones)
    assert(review.load({ bufnr = buf, force = true }):wait(3000))
    eq(f.count("clone"), clones + 1)
    contains(snapshots[2].content, '"third"')
    eq(vim.fn.filereadable(snapshots[2].path), 0)
  end)

  test("review disposal during source loading does not cancel an unrelated main prompt", function(f)
    local mentat, _, buf, source, content = review_context(f)
    local fs = require("mentat.fs")
    local read = fs.read
    local resume
    f.patch(fs, "read", function(path)
      if path == source then
        return async.await(function(done) resume = done end)
      end
      return read(path)
    end)
    local task = require("mentat.review").load({ bufnr = buf })
    f.wait(function() return resume ~= nil end)
    local finished = false
    assert(mentat.chat("independent prompt", nil, function() finished = true end))
    f.wait(function() return #f.sent == 1 end)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(task:pwait(1000), false)
    resume(content)
    eq(mentat.get_client().is_busy(), true)
    eq(f.jobs[1].stopped, nil)
    f.complete(1)
    eq(finished, true)
    eq(f.count("clone"), 0)
  end)

  test("review disposal during clone closes owned work and removes its snapshot", function(f)
    local mentat, _, buf = review_context(f)
    local fs = require("mentat.fs")
    local with_temp = fs.with_temp
    local snapshot
    f.patch(fs, "with_temp", function(content, work)
      return with_temp(content, function(path)
        snapshot = path
        return work(path)
      end)
    end)
    f.hold.clone = true
    local task = require("mentat.review").load({ bufnr = buf })
    f.wait(function() return #f.held == 1 end)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(task:pwait(2000), false)
    f.wait(function() return not mentat.get_client().is_busy() end)
    eq(f.jobs[2].stopped, true)
    eq(vim.fn.filereadable(snapshot), 0)
    f.release("clone")
    f.flush()
  end)

  test("review snapshot write failures clean up before reporting a stable error", function(f)
    local _, _, buf = review_context(f)
    local open = uv.fs_open
    local snapshot
    f.patch(uv, "fs_open", function(path, flags, mode, done)
      if flags == "wx" then snapshot = path end
      return open(path, flags, mode, done)
    end)
    f.patch(uv, "fs_write", function(_, _, _, done)
      vim.schedule(function() done("ENOSPC: snapshot write failed") end)
      return {}
    end)
    local result, err = require("mentat.review").load({ bufnr = buf }):wait(2000)
    eq(result, nil)
    contains(err, "ENOSPC")
    eq(vim.fn.filereadable(snapshot), 0)
    eq(f.count("clone"), 0)
    f.flush()
    contains(f.notices[#f.notices].message, "ENOSPC")
  end)

  test("relative file context is resolved before the first yield rather than after a cwd change", function(f)
    local _, buffer = f.ui()
    local cwd = uv.cwd()
    f.cleanup(function() vim.cmd.cd(cwd) end)
    for _, name in ipairs({ "a", "b" }) do
      vim.fn.mkdir(f.root .. "/" .. name, "p")
      vim.fn.writefile({ "contents from " .. name }, f.root .. "/" .. name .. "/context.txt")
    end
    vim.cmd.cd(f.root .. "/a")
    local task = buffer.add_file("context.txt")
    vim.cmd.cd(f.root .. "/b")
    task:wait(2000)
    eq(buffer._contexts[1].content, "contents from a\n")
    eq(buffer._contexts[1].path, "context.txt")
  end)

  test("file-context cancellation suppresses late bytes without recreating a disposed buffer", function(f)
    local _, buffer = f.ui()
    local fs = require("mentat.fs")
    local resume
    f.patch(fs, "read", function()
      return async.await(function(done) resume = done end)
    end)
    local task = buffer.add_file(f.root .. "/context.txt")
    local buf = buffer.target().bufnr
    f.wait(function() return resume ~= nil end)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(task:pwait(1000), false)
    resume("late content")
    f.flush()
    eq(buffer._contexts, {})
    eq(vim.api.nvim_buf_is_loaded(buf), false)
    eq(#f.jobs, 0)
  end)

  test("a pending state read cannot replace a newer conversation or draft", function(f)
    local mentat, buffer = opened(f)
    local fs = require("mentat.fs")
    local read = fs.read
    local resume
    f.patch(fs, "read", function(path)
      if path == f.root .. "/.mentat/state.json" then
        return async.await(function(done) resume = done end)
      end
      return read(path)
    end)
    local task = buffer.load_state()
    f.wait(function() return resume ~= nil end)
    assert(buffer.send("new conversation"))
    f.wait(function() return #f.sent == 1 end)
    local buf = buffer.target().bufnr
    f.draft(buf, "new draft")
    resume(vim.json.encode({ messages = {}, contexts = {}, buffer_content = "old content" }))
    task:wait(1000)
    eq(mentat.get_client().is_busy(), true)
    contains(f.content(buf), "new draft")
    eq(f.content(buf):find("old content", 1, true), nil)
    f.complete(1)
  end)

  test("exit immediately after an accepted send saves its stopped response synchronously", function(f)
    local mentat, buffer = f.ui()
    assert(buffer.send("exit before startup"))
    mentat.stop()
    buffer.save_state_sync()
    local path = f.root .. "/.mentat/logs/" .. os.date("%Y-%m-%d") .. ".md"
    eq(vim.fn.filereadable(path), 1)
    local log = table.concat(vim.fn.readfile(path), "\n")
    contains(log, "exit before startup")
    contains(log, "Pi process stopped")
    local saved = vim.json.decode(table.concat(vim.fn.readfile(f.root .. "/.mentat/state.json"), "\n"))
    contains(saved.buffer_content, "Pi process stopped")
    f.flush()
    buffer.save_state_sync()
    local _, count = table.concat(vim.fn.readfile(path), "\n"):gsub("exit before startup", "")
    eq(count, 1)
    eq(#f.jobs, 0)
  end)

  test("late atomic-state write completion cannot replace the final synchronous snapshot", function(f)
    local _, buffer = opened(f)
    local buf = buffer.target().bufnr
    f.draft(buf, "old draft")
    local write = uv.fs_write
    local resume
    f.patch(uv, "fs_write", function(fd, text, offset, done)
      if done then
        return write(fd, text, offset, function(err, count)
          resume = function() done(err, count) end
        end)
      end
      return write(fd, text, offset)
    end)
    local task = buffer.save_state()
    f.wait(function() return resume ~= nil end)
    f.draft(buf, "final draft")
    buffer.save_state_sync()
    resume()
    eq(task:pwait(1000), false)
    local path = f.root .. "/.mentat/state.json"
    local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    contains(saved.buffer_content, "final draft")
    eq(saved.buffer_content:find("old draft", 1, true), nil)
    eq(vim.fn.glob(path .. ".mentat-*"), "")
  end)

  test("failed partial log appends retain their remainder and queue order across synchronous retries", function(f)
    local _, buffer = opened(f)
    local write = uv.fs_write
    local wrote = false
    f.patch(uv, "fs_write", function(fd, text, offset, done)
      eq(done, nil)
      if wrote then return nil, "ENOSPC" end
      wrote = true
      return write(fd, text:sub(1, 8), offset)
    end)
    assert(buffer.send("first queued prompt"))
    f.wait(function() return #f.sent == 1 end)
    f.complete(1, "FIRST QUEUED RESPONSE")
    f.wait(function() return #f.notices > 0 end)
    buffer.save_state_sync()
    assert(buffer.send("second queued prompt"))
    f.wait(function() return #f.sent == 2 end)
    f.complete(1, "SECOND QUEUED RESPONSE")
    f.patch(uv, "fs_write", write)
    buffer.save_state_sync()
    local path = f.root .. "/.mentat/logs/" .. os.date("%Y-%m-%d") .. ".md"
    local log = table.concat(vim.fn.readfile(path), "\n")
    local first = assert(log:find("FIRST QUEUED RESPONSE", 1, true))
    local second = assert(log:find("SECOND QUEUED RESPONSE", 1, true))
    assert(first < second)
    local _, count = log:gsub("FIRST QUEUED RESPONSE", "")
    eq(count, 1)
  end)

  test("daily log appends preserve another instance's entry written during async open", function(f)
    local _, buffer = opened(f)
    local path = f.root .. "/.mentat/logs/" .. os.date("%Y-%m-%d") .. ".md"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "previous" }, path)
    local open = uv.fs_open
    local resume
    f.patch(uv, "fs_open", function(name, flags, mode, done)
      if name == path and done then
        return open(name, flags, mode, function(err, fd)
          resume = function() done(err, fd) end
        end)
      end
      return open(name, flags, mode, done)
    end)
    assert(buffer.send("new prompt"))
    f.wait(function() return #f.sent == 1 end)
    f.complete(1, "new response")
    f.wait(function() return resume ~= nil end)
    vim.fn.writefile({ "OTHER INSTANCE ENTRY" }, path, "a")
    resume()
    f.wait(function() return table.concat(vim.fn.readfile(path), "\n"):find("new response", 1, true) ~= nil end)
    local content = table.concat(vim.fn.readfile(path), "\n")
    contains(content, "previous")
    contains(content, "OTHER INSTANCE ENTRY")
    contains(content, "new response")
  end)

  test("synchronous exit persistence never duplicates a log entry awaiting fd close", function(f)
    local _, buffer = opened(f)
    local path = f.root .. "/.mentat/logs/" .. os.date("%Y-%m-%d") .. ".md"
    local open = uv.fs_open
    local close = uv.fs_close
    local log_fd
    local resume
    f.patch(uv, "fs_open", function(name, flags, mode, done)
      if name == path and done then
        return open(name, flags, mode, function(err, fd)
          log_fd = fd
          done(err, fd)
        end)
      end
      return open(name, flags, mode, done)
    end)
    f.patch(uv, "fs_close", function(fd, done)
      if fd == log_fd and done then
        return close(fd, function(err) resume = function() done(err) end end)
      end
      return close(fd, done)
    end)
    assert(buffer.send("once"))
    f.wait(function() return #f.sent == 1 end)
    f.complete(1, "EXACTLY ONCE RESPONSE")
    f.wait(function() return resume ~= nil end)
    buffer.save_state_sync()
    resume()
    f.flush()
    buffer.save_state_sync()
    local content = table.concat(vim.fn.readfile(path), "\n")
    local _, count = content:gsub("EXACTLY ONCE RESPONSE", "")
    eq(count, 1)
    local saved = vim.json.decode(table.concat(vim.fn.readfile(f.root .. "/.mentat/state.json"), "\n"))
    contains(saved.buffer_content, "EXACTLY ONCE RESPONSE")
  end)

  test("synchronous exit flushes an unopened append once and suppresses its late async write", function(f)
    local _, buffer = opened(f)
    local path = f.root .. "/.mentat/logs/" .. os.date("%Y-%m-%d") .. ".md"
    local open = uv.fs_open
    local resume
    f.patch(uv, "fs_open", function(name, flags, mode, done)
      if name == path and done then
        return open(name, flags, mode, function(err, fd)
          resume = function() done(err, fd) end
        end)
      end
      return open(name, flags, mode, done)
    end)
    assert(buffer.send("once"))
    f.wait(function() return #f.sent == 1 end)
    f.complete(1, "LATE OPEN RESPONSE")
    f.wait(function() return resume ~= nil end)
    buffer.save_state_sync()
    resume()
    f.flush()
    local content = table.concat(vim.fn.readfile(path), "\n")
    local _, count = content:gsub("LATE OPEN RESPONSE", "")
    eq(count, 1)
  end)
end
