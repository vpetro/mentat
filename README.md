# Mentat

Mentat runs Pi conversations in Neovim. This version uses the Pi 0.85.1 RPC contract, including `agent_settled` and supported-thinking-level discovery. It targets Neovim nightly with LuaJIT.

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

Each response heading reports the provider/model and effective thinking level observed for its assistant messages. The model appears only in that header, not in a response footer. Mentat does not label a response with an unconfirmed preset before the request starts.

- First text measures elapsed time from submission to the first non-whitespace assistant text. Tool summaries and thinking events do not count. It is `n/a` when no assistant text arrives.
- Total measures submission through `agent_settled`, including tools, retries, and compaction. If a request fails before settlement, it ends at that failure. Restoring a one-shot override can keep the client busy after the measured request has settled.
- Status distinguishes completion, errors, and aborts. Main-conversation logs under `.mentat/logs/YYYY-MM-DD.md` include this metadata and any partial output.

If Pi appends a response timestamp, timing and any error appear before it. The timestamp is the final line of the response in both the chat and its log.

Mentat's saved state includes recovery settings for an interrupted one-shot override. Branch transcripts are not included in the main conversation's saved UI state or daily log.

## Tests

Run from the repository root:

```sh
nvim --headless -u NONE --noplugin -l tests/run.lua
nvim --headless -u NONE --noplugin -c 'lua local files = vim.fn.glob("{lua,plugin,tests}/**/*.lua", false, true); assert(#files > 0); for _, file in ipairs(files) do assert(loadfile(file)) end; print(#files .. " Lua files compiled")' -c qa
git diff --check
```

The tests mock Pi jobs, channels, catalogs, and session files. They use real Neovim buffers, mappings, extmarks, and timers, with bounded fixture waits. They require no Pi credentials and send no model prompts. Coverage includes selection/restoration, branch isolation, stale callbacks, draft preservation, retry/compaction timing, RPC timeout cleanup, and callback-triggered process restarts with trailing stdout/stderr.
