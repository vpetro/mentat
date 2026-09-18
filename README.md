# Mentat

Mentat runs Pi conversations in Neovim. This version uses the Pi 0.85.1 RPC contract, including `agent_settled` and supported-thinking-level discovery. It requires Neovim 0.13 nightly with LuaJIT and native `vim.async`.

## Model and thinking selection

| Command | Mapping | Action |
| --- | --- | --- |
| `:MentatModel` | `<leader>mm` | Select a model from Pi's available catalog. |
| `:MentatThinking` | `<leader>mr` | Select a supported thinking level for the current model. |
| `:MentatPromote` | `<leader>mp` | Resend the last prompt with `big` in the current conversation. |

The selectors target the focused branch, or the main conversation when invoked from an ordinary editor buffer. They capture that target before opening the picker. Model entries show provider/model IDs, the current choice, and matching configured preset labels. A model change can adjust the thinking level; the winbar shows the confirmed result.

Both selectors use `vim.ui.select`. A UI provider such as fzf-lua can style them through `kind = "mentat_model"` and `kind = "mentat_thinking"`; no UI provider is required.

In a conversation buffer, Enter uses its selected model and thinking level on every send. Shift-Enter, `:Mentat!`, and `:MentatSend!` use `big` for one request, then restore the normal selection. Promote is a resend in the same session, not an independent comparison.

Selection is conversation-local. A branch inherits the main conversation's settings, then changes independently. Restored sessions retain their selection. `:MentatClear` starts a new main conversation with the configured defaults. Runtime selection does not change the setup table or Pi's global defaults, and does not restart Pi.

Selectors and additional sends are rejected while a request is preparing, streaming, retrying, compacting, or restoring its normal settings. A rejected send leaves the draft intact. A picker opened before a send, session change, or buffer close must be reopened before it can apply a choice.

## Defaults and presets

Explicit `provider`, `model`, and `thinking` values define the new-chat defaults. For example:

```lua
require("mentat").setup({
  provider = "openai",
  model = "gpt-6-astra",
  thinking = "medium",
  slots = {
    big = {
      provider = "anthropic",
      model = "claude-fable-5",
      thinking = "max",
    },
  },
})
```

Without an explicit model, Mentat uses `default_slot` (normally `quick`) when configured, otherwise Pi's session defaults. Existing quick/big slots remain supported. A slot can use a provider/model string or an explicit provider. A bare model ID is resolved against Pi's catalog; ambiguous IDs need a provider.

## Response metadata

Conversation responses use a plain `## Pi` heading. The winbar shows the selected model and thinking level. Main-conversation log headings retain the model/thinking observed for the response, including one-shot overrides.

- First text measures elapsed time from submission to the first non-whitespace assistant text. Tool summaries and thinking events do not count. It is `n/a` when no assistant text arrives.
- Total measures submission through `agent_settled`, including tools, retries, and compaction. If a request fails before settlement, it ends at that failure. Restoring a one-shot override can keep the client busy after the measured request has settled.
- Status distinguishes completion, errors, and aborts. Main-conversation logs under `.mentat/logs/YYYY-MM-DD.md` include this metadata and any partial output.

Timing and Pi's trailing timestamp share one compact footer line. The timestamp shows only the date and time, and the separator follows immediately:

```markdown
## Pi
Response text.

[Status - First text: 1.64s | Total: 3.25s] - [2026-09-12 03:07:57]
---
```

Errors and aborted requests use `Status: error` or `Status: aborted`; the reason appears above the footer. When Pi supplies no timestamp, the footer contains timing only.

Mentat's saved state includes recovery settings for an interrupted one-shot override. Branch transcripts are not included in the main conversation's saved UI state or daily log.

## Async operations and persistence

LSP queries and Pi request/response workflows use native async tasks. Streaming events still update the response as they arrive. Each client, bridge connection, picker, branch startup, and review buffer owns its pending work. Disposal cancels owned tasks; it does not close a UI provider's popup. Late callbacks cannot apply a stale choice or write to a closed connection.

Runtime file reads and staged writes use asynchronous libuv I/O. Cold LSP buffers still use native `bufload` so buffer-read autocmds and LSP attachment keep working. Small bundled prompt reads, instance-claim files, and filesystem metadata checks remain synchronous.

Daily logs remain append-only across Neovim instances. Opening and closing a log file is asynchronous, but each append commits synchronously and records its byte count before yielding. This lets `VimLeavePre` stop pending work and flush only unwritten bytes without waiting for an I/O callback or appending an entry twice. State-file replacement also uses a synchronous rename after its async write and close. Final exit persistence is synchronous; it does not start a nested event loop.

## Tests

Tested with Neovim `v0.13.0-dev-1510+gce8a897f98-Homebrew`. Run from the repository root:

```sh
nvim --headless -u NONE --noplugin -l tests/run.lua
nvim --headless -u NONE --noplugin -c 'lua local files = vim.fn.glob("{lua,plugin,tests}/**/*.lua", false, true); assert(#files > 0); for _, file in ipairs(files) do assert(loadfile(file)) end; print(#files .. " Lua files compiled")' -c qa
git diff --check
```

The tests mock Pi jobs, channels, catalogs, and session files. They use real Neovim buffers, filesystem I/O, subprocesses, TCP sockets, and timers, with bounded fixture waits. They require no Pi credentials and send no model prompts.

Coverage includes response layout and timing, selection/restoration, LSP aggregation and cancellation, concurrent bridge requests, and callback-triggered process restarts with trailing stdout/stderr. Filesystem and workflow cases cover late-opened descriptors, temporary-file ownership, branch/review/picker disposal, repository capture across yields, and partial log writes with exactly-once exit flushing. Each case checks for remaining async tasks, active libuv handles, and Neovim errors after cleanup.
