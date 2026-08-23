if vim.g.loaded_mentat then
  return
end
vim.g.loaded_mentat = true

local mentat_group = vim.api.nvim_create_augroup("MentatRuntime", { clear = true })

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
  group = mentat_group,
  callback = function(args)
    local bufnr = args.buf
    if vim.bo[bufnr].buftype ~= "" then
      return
    end
    require("mentat").capture_repo_root(bufnr)
  end,
})

vim.api.nvim_create_user_command("Mentat", function(opts)
  local buf = require("mentat.buffer")
  if opts.args == "" then
    buf.open()
  else
    buf.send(opts.args, opts.bang and "big" or nil)
  end
end, { nargs = "?", bang = true, desc = "Chat with Pi (! = big model)" })

vim.api.nvim_create_user_command("MentatPromote", function()
  require("mentat.buffer").promote()
end, { desc = "Re-send last prompt to the big model" })

vim.api.nvim_create_user_command("MentatClear", function()
  require("mentat.buffer").clear()
end, { desc = "Clear chat history" })

vim.api.nvim_create_user_command("MentatRestart", function()
  require("mentat").restart()
  vim.notify("Mentat Pi backend stopped. It will restart on the next prompt.", vim.log.levels.INFO)
end, { desc = "Restart Mentat Pi backend" })

vim.api.nvim_create_user_command("MentatToggle", function()
  require("mentat.buffer").toggle()
end, { desc = "Toggle Mentat window" })

vim.keymap.set("n", "<leader>mt", function()
  require("mentat.buffer").toggle()
end, { desc = "Toggle Mentat window" })

vim.api.nvim_create_user_command("MentatFile", function(opts)
  local filepath = opts.args
  if filepath == "" then
    -- No args: show list of items in context
    require("mentat.buffer").show_context()
  else
    require("mentat.buffer").add_file(filepath)
  end
end, { nargs = "?", complete = "file", desc = "Add file to Mentat context or show context" })

vim.api.nvim_create_user_command("MentatClearContext", function()
  require("mentat.buffer").clear_context()
end, { desc = "Clear context" })

-- Alias for backward compatibility
vim.api.nvim_create_user_command("MentatClearFiles", function()
  require("mentat.buffer").clear_context()
end, { desc = "Clear context (alias)" })

vim.keymap.set("n", "<leader>mf", function()
  require("mentat.buffer").add_file(vim.fn.expand("%"))
end, { desc = "Add current file to Mentat context" })

vim.api.nvim_create_user_command("MentatDiagnostics", function()
  require("mentat.buffer").add_diagnostics(vim.api.nvim_get_current_buf())
end, { desc = "Add current buffer diagnostics to Mentat context" })

vim.keymap.set("n", "<leader>md", function()
  require("mentat.buffer").add_diagnostics(vim.api.nvim_get_current_buf())
end, { desc = "Add diagnostics to Mentat context" })

vim.api.nvim_create_user_command("MentatAddContext", function(opts)
  local buf = require("mentat.buffer")
  local start_line = opts.line1
  local end_line = opts.line2
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local filename = vim.fn.expand("%:t")
  local filetype = vim.bo.filetype
  
  buf.add_selection(lines, filetype, filename, start_line, end_line)
end, { range = true, desc = "Add selected text to Mentat context" })

vim.keymap.set(
  "v",
  "<leader>mc",
  ":MentatAddContext<CR>",
  { desc = "Add selection to Mentat context" }
)

vim.api.nvim_create_user_command("MentatSend", function(opts)
  local buf = require("mentat.buffer")
  local start_line = opts.line1
  local end_line = opts.line2
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local text = table.concat(lines, "\n")
  if text ~= "" then
    buf.send(text, opts.bang and "big" or nil)
  end
end, { range = true, bang = true, desc = "Send selected text to Pi (! = big model)" })

vim.keymap.set(
  "v",
  "<leader>ms",
  ":MentatSend<CR>",
  { desc = "Send selection to Mentat" }
)

vim.api.nvim_create_user_command("MentatLoadLast", function()
  require("mentat.buffer").load_last_session()
end, { desc = "Load the last session log" })

vim.keymap.set("n", "<leader>ml", function()
  require("mentat.buffer").load_last_session()
end, { desc = "Load last session" })

vim.api.nvim_create_user_command("MentatLoadReviewContext", function(opts)
  require("mentat.review").load({ force = opts.bang })
end, { bang = true, desc = "Load the originating Pi context from a review file" })

vim.keymap.set("n", "<leader>mL", function()
  require("mentat.review").load()
end, { desc = "Load Pi review context" })

-- Branch conversations
vim.api.nvim_create_user_command("MentatBranch", function(opts)
  local text = nil
  if opts.range > 0 then
    local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
    text = table.concat(lines, "\n")
  end
  require("mentat.branch").open(text)
end, { range = true, desc = "Open a branch conversation from current context" })

vim.keymap.set("n", "<leader>mb", function()
  require("mentat.branch").open()
end, { desc = "Branch Mentat conversation" })

vim.keymap.set("v", "<leader>mb", ":MentatBranch<CR>", { desc = "Branch with selection" })

-- Session Persistence
local group = vim.api.nvim_create_augroup("MentatSession", { clear = true })

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    local buffer = require("mentat.buffer")
    buffer.save_state()
    buffer.release_instance_claim()
  end,
})

vim.api.nvim_create_autocmd("SessionLoadPost", {
  group = group,
  callback = function()
    require("mentat.buffer").load_state()
  end,
})

vim.api.nvim_create_user_command("MentatSaveState", function()
  require("mentat.buffer").save_state()
  vim.notify("Mentat state saved", vim.log.levels.INFO)
end, { desc = "Save Mentat state to file" })

vim.api.nvim_create_user_command("MentatLoadState", function()
  require("mentat.buffer").load_state()
  vim.notify("Mentat state loaded", vim.log.levels.INFO)
end, { desc = "Load Mentat state from file" })
