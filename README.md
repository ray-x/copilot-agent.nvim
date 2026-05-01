# copilot-agent.nvim

GitHub Copilot's agentic runtime, natively in Neovim. A lightweight Go bridge to the [official SDK](https://github.com/github/copilot-sdk) with native tool execution, four chat modes, session-aware permissions, persistent sessions, repository-local agent/skill discovery, and LSP code actions.

## Advanced Agentic Features

- Native SDK Agent Loop: Leverages the official Copilot SDK to perform autonomous tasks like reading/writing files, executing terminal commands, and fetching web data.
- Flexible Permission Control: Total oversight with four execution modes: from **Interactive (per-call approval)** all the way to fully autonomous **Autopilot**.
- Seamless Editor Interop: Switch between Neovim and VS Code without losing context; shares sessions, custom agents, and skill directories natively.
- Repository-Native Config: Aligns with GitHub's standards by supporting `.github/agents` and `.github/skills` for project-specific AI behaviors.
- Granular Approval UI: Review changes with precision using delta or Neovim diffs, and manage permissions by directory or specific tool.
- Undo and rewind to restore the codebase to previous conversation
- LSP-Integrated Actions: Access AI power through standard LSP code actions to explain, fix, test, or document code directly in your buffer
- Real-time Observability: Monitor background tasks and sub-agent events as they happen via a live streaming UI.

---

### Agent Tool Loop

The agentic loop is what makes this plugin different from simple chat wrappers. The assistant doesn't just answer — it acts: reading files, fetching web pages, running commands, writing code, and iterating until the task is done.

```mermaid
flowchart TD
    User(["👤 User prompt"]) --> LLM["🤖 Copilot LLM"]
    LLM --> Decision{Response type}

    Decision -->|"text"| Stream["💬 Stream to chat buffer"]
    Decision -->|"tool call"| Tool["🔧 read_file · write_file\nterminal · web_search · mcp"]
    Decision -->|"ask user"| Ask["❓ Clarifying question\nvim.ui.input / select"]

    Tool --> Perm{Permission mode}

    Perm -->|"🔐 interactive"| Pick["Allow · Deny\nAllow dir · Allow all"]
    Perm -->|"✅ approve-all"| Exec
    Perm -->|"🤖 autopilot"| AutoExec["Auto-approve +\nauto-answer ask_user"]
    Perm -->|"🚫 reject-all"| Denied["Rejected → back to LLM"]

    Pick -->|"allow"| Exec["⚡ Execute tool"]
    Pick -->|"deny"| Denied

    Exec -->|"return result"| LLM
    AutoExec -->|"return result"| LLM
    Denied --> LLM
    Ask -->|"user answers"| LLM

    Stream --> More{More work?}
    More -->|"yes"| LLM
    More -->|"no"| Done(["✅ Task complete"])

    style User fill:#4CAF50,color:#fff
    style Done fill:#4CAF50,color:#fff
    style Stream fill:#2196F3,color:#fff
    style Exec fill:#FF9800,color:#fff
    style AutoExec fill:#FF9800,color:#fff
    style Pick fill:#9C27B0,color:#fff
    style Ask fill:#9C27B0,color:#fff
```

**Key differentiators from simple chat plugins:**

- **Real tool loop** — the LLM calls tools (read_file, write_file, terminal, web_search) and iterates autonomously until the task is complete
- **Four permission modes** — interactive (per-call approval with escalation), approve-all, autopilot (fully autonomous), reject-all (read-only)
- **ask_user integration** — the agent can ask clarifying questions mid-task via `vim.ui.input()` / `vim.ui.select()`
- **Sub-agent streaming** — delegated sub-agents stream their progress in real-time

## Architecture

```mermaid
flowchart TD
    subgraph Neovim["Neovim (Lua plugin)"]
        UI["Chat buffer / input window"]
        LSPClient["vim.lsp (code actions)"]
        Cmds["CopilotAgent* commands"]
    end

    subgraph GoService["Go host service  :8088"]
        HTTP["HTTP router\n/sessions  /models  /healthz"]
        SSE["SSE fan-out\nsession.event  host.*"]
        LSPServer["LSP server (stdio)\ntextDocument/codeAction\nworkspace/executeCommand"]
        Sessions["Session manager\npermissions · tools · models"]
    end

    subgraph SDK["GitHub Copilot SDK"]
        CopilotSDK["copilot-sdk/go\nCopilot CLI / API"]
        Tools["Built-in tools\nread_file · write_file · terminal\nweb_search · ask_user · …"]
    end

    UI -->|"curl POST /sessions/{id}/messages"| HTTP
    UI -->|"curl -N SSE stream"| SSE
    Cmds -->|"curl POST/DELETE"| HTTP
    LSPClient <-->|"JSON-RPC stdio"| LSPServer
    LSPServer -->|"POST /sessions/{id}/messages"| HTTP
    HTTP --> Sessions
    SSE --> Sessions
    Sessions <-->|"copilot.Session"| CopilotSDK
    CopilotSDK --> Tools
```

The Go binary runs a **single process** that serves both the HTTP bridge (sessions, SSE, user-input, permissions) and an LSP server on stdio. Neovim starts it as an LSP client (`vim.lsp.start`), which owns the process lifetime. The Lua plugin communicates via `curl` shell-outs for all HTTP and SSE traffic.

**Why curl?** Neovim has no built-in HTTP client. `vim.uv` (libuv) exposes raw TCP sockets but requires a manual HTTP/1.1 implementation — headers, chunked encoding, SSE framing. `curl` is universally available on macOS and Linux, handles SSE natively, and keeps the Lua layer thin and dependency-free. The per-request process-spawn overhead (~5–20 ms) is imperceptible against LLM response latency.

---

## Comparison with Alternatives

### vs CopilotChat.nvim

[CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) calls the Copilot (or other) LLM REST APIs directly from Lua. It supports multiple providers but has no agent runtime of its own — tool execution and the agentic loop are implemented in Lua above the client.

| Feature                   | **copilot-agent.nvim**                                                | CopilotChat.nvim          |
| ------------------------- | --------------------------------------------------------------------- | ------------------------- |
| Backend                   | Official Copilot SDK (Go)                                             | Direct LLM REST API (Lua) |
| Agent / tool-use mode     | ✅ full agentic (file edits, terminal, web search, …)                 | ❌ chat only              |
| Chat modes                | ask · plan · **agent** · autopilot                                    | ask only                  |
| Permission management     | ✅ interactive / approve-reads / approve-all / autopilot / reject-all | ❌                        |
| Config discovery          | ✅ SDK-native (`.github/copilot-instructions.md`, etc.)               | ❌ manual                 |
| Custom agents             | ✅ SDK `CustomAgents` — same as VS Code                               | ❌                        |
| Skill directories         | ✅ SDK `SkillDirectories` — same as VS Code                           | ❌                        |
| Sub-agent streaming       | ✅ SDK-native events                                                  | ❌                        |
| File & folder attachments | ✅ (buffer, selection, file, folder, image, clipboard paste)          | ✅ (buffer context)       |
| Session persistence       | ✅ per working directory                                              | ❌                        |
| Model switching (live)    | ✅ mid-session with tab-complete                                      | ✅                        |
| LSP code actions          | ✅ (explain / fix / add tests / add docs)                             | ❌                        |
| ACP / MCP support         | ❌                                                                    | ❌                        |
| SSE streaming             | ✅ native                                                             | ✅                        |
| Multi-provider            | ❌ (Copilot only, or Bring your own key)                              | ✅ (provider_resolver)    |
| Dependencies              | codepilot-cli + go server + curl                                      | Pure Lua (plenary)        |

**When to choose CopilotChat.nvim**: zero-binary Lua setup, just want Copilot chat with buffer context, happy with a Lua-managed tool loop.

**When to choose copilot-agent.nvim**: you want the Copilot SDK owning the agent loop with native tools, permission control, and session persistence.

---

### vs ACP plugins (codecompanion.nvim, avante.nvim in ACP mode)

[**ACP (Agent Client Protocol)**](https://agentclientprotocol.com) lets a Neovim plugin act as a client to any external CLI agent. it supported by Claude Code, Copilot CLI, Codex, Gemini CLI, Goose, and more. The plugin sends prompts and streams back results; the CLI agent owns the tool execution and agentic loop. Both codecompanion.nvim and avante.nvim support ACP, giving them access to the full capability of whichever CLI agent you point them at.

Beyond ACP, these plugins also support direct LLM API calls (multi-provider adapters) and MCP (Model Context Protocol) tool servers, making them highly general-purpose.

`copilot-agent.nvim` is narrower in scope but deeper in Copilot integration: the Go service embeds the Copilot SDK directly, so it gets SDK-native features (config discovery, custom agents, skill directories, sub-agent streaming) that no ACP bridge can expose.

| Feature                      | **copilot-agent.nvim**                                                | codecompanion.nvim                        | avante.nvim                            |
| ---------------------------- | --------------------------------------------------------------------- | ----------------------------------------- | -------------------------------------- |
| Agent backend                | Copilot SDK (Go, embedded)                                            | ACP CLI agents or direct LLM adapters     | ACP CLI agents or direct LLM adapters  |
| ACP support                  | ❌                                                                    | ✅ (Claude Code, Codex, Copilot CLI, …)   | ✅ (Zen Mode)                          |
| MCP support                  | ❌                                                                    | ✅                                        | ✅                                     |
| Multi-provider / BYO API key | ❌ (Copilot only)                                                     | ✅ (Anthropic, OpenAI, Gemini, Ollama, …) | ✅ (Claude, OpenAI, Gemini, Ollama, …) |
| Tool-call execution          | SDK built-ins (file I/O, terminal, web search, ask_user, …)           | Lua tools + ACP agent tools               | Rust tools + ACP agent tools           |
| Sub-agent / streaming events | ✅ SDK-native                                                         | ❌                                        | ❌                                     |
| Custom agents / skill dirs   | ✅                                                                    | ❌                                        | ❌                                     |
| Config discovery             | ✅ (`.github/copilot-instructions.md`, etc.)                          | ✅ (`CLAUDE.md`, `.cursor/rules`, custom) | ✅ (`avante.md`)                       |
| Permission management        | ✅ interactive / approve-reads / approve-all / autopilot / reject-all | ❌                                        | ❌                                     |
| Session persistence          | ✅ per working directory                                              | ❌                                        | ❌                                     |
| LSP code actions             | ✅ (explain / fix / add tests / add docs)                             | ✅ (via prompt library)                   | ❌                                     |
| Chat modes                   | ask · plan · agent · autopilot                                        | chat · inline · workflow                  | ask · edit (Cursor-style)              |
| External binary required     | Go binary                                                             | Pure Lua (plenary + treesitter)           | Rust binary (compiled at install)      |
| GitHub Copilot subscription  | Required                                                              | Optional (one of many providers)          | Optional (one of many providers)       |
| Community / ecosystem        | Smaller                                                               | Large (adapters, prompts, extensions)     | Large (star count, active development) |

**When to choose codecompanion / avante**: you want model flexibility, ACP access to Claude Code / Codex / Gemini CLI, MCP tool servers, or a large community ecosystem — and you're not exclusively on GitHub Copilot.

**When to choose copilot-agent.nvim**: you're committed to GitHub Copilot and want the deepest possible SDK integration — native tools, permission management, session persistence, sub-agent events, and LSP code actions — without routing through an intermediate CLI.

---

## Prerequisites

- Go 1.24+ (only for building from source; pre-built binary skips this)
- `curl` on `PATH`
- GitHub Copilot CLI runtime (`@github/copilot/index.js`) or access via `-cli-url`
- Neovim 0.11+ (0.12+ recommended)

**Optional:**

- [`delta`](https://github.com/dandavison/delta) — rich diff viewer for permission "Show diff" (auto side-by-side for wide windows; falls back to builtin if not installed)
- `pngpaste` / `wl-paste` / `xclip` — clipboard image paste
- snacks.picker / telescope / fzf-lua / mini.pick — fuzzy file picker

Run `:checkhealth copilot_agent` after installation to verify all requirements.

---

## Installation

### Step 1 — Download the pre-built binary (recommended)

Run this command inside Neovim after installing the plugin:

```
:CopilotAgentInstall
```

This downloads the correct binary for your platform from the
[latest GitHub release](https://github.com/ray-x/copilot-agent.nvim/releases/tag/latest)
and saves it to `<plugin_root>/bin/copilot-agent` (or `copilot-agent.exe` on Windows).
No Go toolchain required.

Supported platforms:

| Platform            | Binary                            |
| ------------------- | --------------------------------- |
| Linux x86_64        | `copilot-agent-linux-amd64`       |
| Linux aarch64       | `copilot-agent-linux-arm64`       |
| Windows x86_64      | `copilot-agent-windows-amd64.exe` |
| Windows aarch64     | `copilot-agent-windows-arm64.exe` |
| macOS Apple Silicon | `copilot-agent-darwin-arm64`      |

You can also download manually from the
[releases page](https://github.com/ray-x/copilot-agent.nvim/releases/tag/latest)
and place it anywhere; then set `service.command = { "/path/to/copilot-agent" }`.

### Step 2 — Plugin setup with lazy.nvim

```lua
{
  "ray-x/copilot-agent.nvim",
  build = ":CopilotAgentInstall",
  config = function()
    require("copilot_agent").setup({
      -- When auto_start=true the plugin launches the Go service and reads its
      -- port from stderr automatically. No manual base_url needed.
      base_url = "http://127.0.0.1:8088",  -- only for externally-started services
      client_name = "nvim-copilot",
      permission_mode = "approve-all",  -- "interactive" | "approve-all" | "autopilot" | "reject-all"
      auto_create_session = true,
      session = {
        working_directory = function() return vim.fn.getcwd() end,
        model = nil,    -- nil = Copilot picks a default
        agent = nil,    -- nil = "default"; or "coding", "gpt-4.1", a custom agent name
        streaming = true,
        enable_config_discovery = true,  -- respects .github/copilot-instructions.md etc.
        auto_resume = "prompt",  -- "prompt" (default) | "auto" — when multiple sessions exist
      },
      service = {
        auto_start = true,
        -- command = nil means auto: uses <plugin_root>/bin/copilot-agent if present,
        -- otherwise falls back to { "go", "run", "." } (requires Go toolchain).
        command = nil,
        cwd = nil,                         -- defaults to <plugin_root>/server
        detach = true,                     -- default: reuse one detached background service across Neovim instances
        port_range = nil,                  -- e.g. "18000-19000" for fixed range
        startup_timeout_ms = 15000,
        startup_poll_interval_ms = 250,
      },
      chat = {
        title = "Copilot Chat",
        system_notify_timeout = 3000,    -- ms before auto-clearing transient notices
        render_markdown = true,          -- set false to disable render-markdown.nvim (faster on long responses)
        protect_markdown_buffer = true,  -- upstream Neovim Treesitter workaround for the prompt buffer; set false to disable
        diff_cmd = { 'delta' },          -- external diff viewer; false = builtin float
        diff_review = true,              -- offer vimdiff after agent modifies a git-tracked file; clean buffers auto-reload, conflicting modified buffers prompt before reload
      },
      notify = true,  -- set false to silence all [copilot-agent] vim.notify calls
      file_log_level = "WARN",  -- DEBUG | INFO | WARN | ERROR for stdpath("log") .. "/copilot_agent.log"
    })
    -- Start the combined HTTP + LSP service.
    -- Called automatically by CopilotAgentChat / CopilotAgentAsk if auto_start = true.
    -- Call explicitly here to get LSP code actions available immediately:
    require("copilot_agent").start_lsp()
  end,
}
```

If you want to point at a binary in a custom location:

```lua
-- Dynamic port (recommended for multiple nvim instances)
service = { auto_start = true, command = { "/path/to/copilot-agent" } }

-- Fixed port
service = { auto_start = true, command = { "/path/to/copilot-agent", "--addr", "127.0.0.1:8088" } }

-- Port range (first free port in 18000–19000)
service = { auto_start = true, command = { "/path/to/copilot-agent" }, port_range = "18000-19000" }
```

#### Global service vs isolated instances

By default, `auto_start = true` launches or reuses a **single detached background service** for your user account. The last bound address is stored in `stdpath("state") .. "/copilot-agent.addr"`, so new Neovim instances reconnect to that same service automatically. Session resume is still matched by `session.working_directory`, but the service process and persisted session catalog are global by default.

If you want **per-project isolation**, pin a project-specific address and disable detaching:

```lua
require("copilot_agent").setup({
  base_url = "http://127.0.0.1:18121",
  session = {
    working_directory = function() return vim.fn.getcwd() end,
  },
  service = {
    auto_start = true,
    detach = false,
    port_range = "18121-18121",
  },
})
```

Reuse the same stable port when reopening the same project later. If you open multiple isolated projects at the same time, each one needs its own port.

---

## Running the Service Manually

See [server/README.md](server/README.md#running-the-service-manually) for manual startup, build flags, and service runtime details.

---

## Commands

| Command                          | Description                                                |
| -------------------------------- | ---------------------------------------------------------- |
| `:CopilotAgentInstall`           | Download pre-built binary for the current platform         |
| `:CopilotAgentChat [fullscreen]` | Open the chat buffer; `fullscreen` opens in a new tab      |
| `:CopilotAgentChatToggle`        | Toggle chat window (open if hidden, close if visible)      |
| `:CopilotAgentChatFocus`         | Focus or switch to an open chat buffer                     |
| `:CopilotAgentAsk [prompt]`      | Send a prompt; no argument opens `vim.ui.input()`          |
| `:CopilotAgentNewSession`        | Disconnect current session and start a fresh one           |
| `:CopilotAgentSwitchSession`     | Pick from all persisted sessions and switch                |
| `:CopilotAgentDeleteSession`     | Pick a session by summary + exact ID and delete it         |
| `:CopilotAgentModel [id]`        | Pick or set a model; tab-completes from service model list |
| `:CopilotAgentStart`             | Manually start the Go service                              |
| `:CopilotAgentStop`              | Disconnect the active session                              |
| `:CopilotAgentStop!`             | Delete the active session; checkpoint cleanup waits 7 days |
| `:CopilotAgentCancel`            | Cancel the current agent turn                              |
| `:CopilotAgentDiff`              | Pick a changed file and open vimdiff against HEAD          |
| `:CopilotAgentStatus`            | Show service URL, session id, stream status                |
| `:CopilotAgentLsp`               | Start (or reuse) the LSP client for code actions           |
| `:CopilotAgentPasteImage`        | Paste clipboard image as attachment                        |
| `:CopilotAgentRetryInput`        | Re-show the last dismissed ask_user prompt                 |

---

## Input Buffer

Open with `:CopilotAgentChat`, then press `i` or `<Enter>` in the chat buffer.

### Keybindings

| Key               | Action                                                                                       |
| ----------------- | -------------------------------------------------------------------------------------------- |
| `<CR>` / `<C-s>`  | Send message                                                                                 |
| `q` / `<Esc>`     | Close input (normal mode)                                                                    |
| `<C-t>`           | Cycle chat mode: **💬 ask → 📋 plan → 🤖 agent → 🚀 autopilot**                              |
| `<M-m>`           | Open model picker                                                                            |
| `<M-a>`           | Cycle permission mode: **🔐 interactive → 📂 approve-reads → ✅ approve-all → 🤖 autopilot** |
| `<C-a>`           | Attach resource — opens picker menu (see below)                                              |
| `<M-v>`           | Paste image from clipboard as attachment                                                     |
| `<C-x>`           | Toggle session tools (enable/disable individual tools)                                       |
| `<Tab>`           | Trigger completion (`@file` or `/command`)                                                   |
| `@<path>`         | Attach a file by path (autocomplete from working directory)                                  |
| `/<cmd>`          | Run a built-in slash command (autocomplete with `<Tab>`)                                     |
| `<C-p>` / `<M-p>` | Previous prompt from history                                                                 |
| `<C-n>` / `<M-n>` | Next prompt from history                                                                     |
| `<C-c>` (output)  | Cancel current turn                                                                          |
| `?` (normal)      | Show help float with keybindings, session commands, and recovery tips                        |

### Slash Commands

The input buffer supports built-in slash commands handled by the plugin before the text is sent as a normal Copilot prompt. Type `/` and press `<Tab>` to browse and complete the available commands. Some of the commands are still experimental.

`/agent` completion is optimized for inline prompting: selecting an agent suggestion inserts the agent name without the `/agent` prefix, so `/agent Git Commit Agent` completion becomes `Git Commit Agent`.

Supported slash commands:

| Command                | Arguments                  | What it does                                                                        |
| ---------------------- | -------------------------- | ----------------------------------------------------------------------------------- |
| `/add-dir`             | `[path]`                   | Add a directory to the session's allowed-directory list; prompts if omitted         |
| `/agent`               | `[name\|default\|clear]`   | Pick a discovered custom agent, or reset back to the default agent                  |
| `/allow-all`           | —                          | Switch permission mode to `approve-all`                                             |
| `/ask`                 | `[question]`               | Ask a side question in a temporary read-only session and show the answer separately |
| `/clear`               | —                          | Clear the current conversation and start a fresh session                            |
| `/compact`             | —                          | Compact session history and refresh context usage                                   |
| `/context`             | —                          | Show current context-window token usage                                             |
| `/cwd`                 | `[path]`                   | Show or change the working directory used for future session actions                |
| `/diff`                | `[cached]`                 | Show a git diff summary for the current project; `cached` uses staged changes       |
| `/env`                 | —                          | Show the current environment, service, session, model, and mode snapshot            |
| `/fleet`               | `[prompt]`                 | Start fleet mode for the active session                                             |
| `/init`                | `[args]`                   | Run the project initialization helper                                               |
| `/instructions`        | `[name]`                   | Open a discovered instructions file from the repository                             |
| `/list-dir`            | —                          | List allowed directories for the current session                                    |
| `/list-dirs`           | —                          | Alias for `/list-dir`                                                               |
| `/lsp`                 | `[status\|start\|install]` | Show LSP status, start the LSP client, or install/update the binary                 |
| `/mcp`                 | `[name]`                   | Open a discovered MCP config file                                                   |
| `/model`               | `[id]`                     | Pick or switch the active model                                                     |
| `/new`                 | —                          | Start a fresh session                                                               |
| `/plan`                | `[draft text]`             | Switch the input buffer to plan mode and optionally prefill the prompt              |
| `/rename`              | `[name]`                   | Rename the active session                                                           |
| `/research`            | `[topic]`                  | Send a research-oriented prompt that can use GitHub and web sources                 |
| `/reset-allowed-tools` | —                          | Clear remembered tool approvals for the current session                             |
| `/resume`              | `[session-id]`             | Resume or switch to another saved session; prompts if omitted                       |
| `/review`              | `[focus]`                  | Ask Copilot to review the current changes, optionally with extra focus text         |
| `/rewind`              | `[checkpoint]`             | Rewind the session to a checkpoint such as `v003`                                   |
| `/search`              | `[text]`                   | Search the current transcript and jump to a matching entry                          |
| `/session`             | `[session-id\|new\|clear]` | Switch sessions, or use `new` / `clear` as shortcuts                                |
| `/share`               | `[markdown\|html] [path]`  | Export the current transcript as Markdown or HTML                                   |
| `/skills`              | `[name]`                   | Open a discovered skill from the repository                                         |
| `/tasks`               | `[filter]`                 | Show background task and sub-agent activity                                         |
| `/undo`                | —                          | Restore the latest checkpoint for the current session                               |
| `/usage`               | —                          | Show session usage, discovery counts, and context-window stats                      |

### Attaching Files and Images

Press `<C-a>` in the input buffer to open the resource picker:

| Choice                     | What it does                                                   |
| -------------------------- | -------------------------------------------------------------- |
| Current buffer             | Attaches the previously focused file buffer                    |
| Visual selection           | Attaches the last visual selection with file path + line range |
| File                       | Opens fuzzy picker → select one or more files (multi-select)   |
| Folder                     | Opens fuzzy picker / `vim.ui.input` to pick a directory        |
| Instructions file          | Same as File but marked as an instructions context file (📋)   |
| Image file                 | Opens fuzzy picker to select an image (png/jpg/gif/…)          |
| Paste image from clipboard | Saves clipboard image to a temp PNG and attaches it (🖼️)       |

`<M-v>` is a direct shortcut for **Paste image from clipboard** without opening the menu.
`:CopilotAgentPasteImage` is the equivalent command.

Pending attachments appear in the input statusline as `📎 N`. Each attachment is also shown below the prompt text in the chat buffer once sent.

#### Fuzzy Picker Integration

The File / Folder / Image / Instructions choices auto-detect and use the best available picker — no extra configuration needed:

| Priority | Picker            | Notes                                                  |
| -------- | ----------------- | ------------------------------------------------------ |
| 1        | **snacks.picker** | `snacks.picker.files` / `snacks.picker.directories`    |
| 2        | **telescope**     | `find_files`; `telescope-file-browser` for directories |
| 3        | **fzf-lua**       | `fzf.files`; `fzf_exec fd --type d` for directories    |
| 4        | **mini.pick**     | `mp.builtin.files` (files only)                        |
| 5        | **vim.ui.input**  | Fallback — type the path with completion               |

Override the picker or force the native fallback via config:

```lua
chat = { file_picker = 'auto' }       -- default: detect best available
chat = { file_picker = 'telescope' }  -- always use telescope
chat = { file_picker = 'fzf-lua' }    -- always use fzf-lua
chat = { file_picker = 'native' }     -- always use vim.ui.input
```

#### Clipboard Image Requirements

| Platform      | Tool required     | Install                         |
| ------------- | ----------------- | ------------------------------- |
| macOS         | `pngpaste`        | `brew install pngpaste`         |
| Linux/Wayland | `wl-paste`        | `sudo apt install wl-clipboard` |
| Linux/X11     | `xclip` or `xsel` | `sudo apt install xclip`        |

### Chat Modes

Cycled with `<C-t>` in the chat/input buffer. The mode is shown in the statusline.

| Mode          | Icon | SDK session mode | Description                                                                                                                                                                                                                             |
| ------------- | ---- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ask**       | 💬   | `interactive`    | Single-turn Q&A. The model answers once and stops. Tools are available but each call requires approval. Use for questions, explanations, and code reviews.                                                                              |
| **plan**      | 📋   | `plan`           | Like ask, but the model is guided to produce a structured implementation plan before taking any action. Good for scoping a task before committing to it.                                                                                |
| **agent**     | 🤖   | `autopilot`      | Multi-step agentic loop. The model calls tools (read files, run commands, write code) repeatedly and iterates until the task is done. Pauses to prompt you before writes/shell commands. Read access to the workspace is auto-approved. |
| **autopilot** | 🚀   | `autopilot`      | Same agentic loop as agent, but with `approve-all` permission — every tool call (reads _and_ writes) is silently approved. Fully autonomous.                                                                                            |

**SDK note:** The Copilot SDK has three session modes — `interactive`, `plan`, and `autopilot`. VS Code's four-label model maps exactly onto these: ask → `interactive`, plan → `plan`, agent and autopilot both → `autopilot` (the difference is the permission mode, not the SDK mode).

### Performance Tips

- **render-markdown.nvim** integrates automatically when installed. On very long responses it can cause visible lag. Disable with `chat = { render_markdown = false }` to use treesitter highlighting only (much faster).
- **Streaming** is enabled by default (`session.streaming = true`). The chat buffer updates incrementally as tokens arrive.
- **Session resume**: with 1 matching session it resumes silently; with multiple sessions `auto_resume = "prompt"` (default) shows a picker titled with the current project name and path so you can choose which session to continue.

### Permission Modes

Cycled with `<M-a>` in the input buffer, or set via config / `POST /sessions/{id}/permission-mode`.
Each chat mode sets a sensible default permission automatically; `<M-a>` overrides it for the current mode.

| Icon | Mode              | Behaviour                                                                                                           |
| ---- | ----------------- | ------------------------------------------------------------------------------------------------------------------- |
| 🔐   | **interactive**   | Neovim prompts `Allow / Deny` for every tool call                                                                   |
| 📂   | **approve-reads** | Workspace read-file requests are auto-approved; writes and shell commands still prompt. Default for **agent** mode. |
| ✅   | **approve-all**   | All tool calls silently approved. Default for **autopilot** mode.                                                   |
| 🤖   | **autopilot**     | Approve all + auto-answer any `ask_user` questions (fully autonomous)                                               |
| 🚫   | **reject-all**    | Reject all tool calls (safe read-only mode)                                                                         |

#### `ask_user` requests — when will Copilot ask you a question?

There are **two separate interruption points** in an agentic loop:

1. **Tool-call approval** — before the SDK executes a tool (read file, run shell, write code, etc.).
   Controlled entirely by the permission mode above.

2. **`ask_user` requests** — the _model itself_ decides to pause and ask you a clarifying question
   mid-task (e.g. "Which branch should I target?" or "There are two test files — which one?").
   This is independent of tool approval and happens at the model's discretion.

| Permission mode   | Tool calls          | `ask_user` questions                       |
| ----------------- | ------------------- | ------------------------------------------ |
| **interactive**   | prompt every call   | shown via `vim.ui.input/select`            |
| **approve-reads** | prompt writes/shell | shown via `vim.ui.input/select`            |
| **approve-all**   | silent              | shown via `vim.ui.input/select`            |
| **autopilot**     | silent              | **auto-answered** (first choice, silently) |
| **reject-all**    | all rejected        | shown via `vim.ui.input/select`            |

> **Practical rule:** use **agent** mode (`approve-reads`) for day-to-day tasks — Copilot will still
> ask you clarifying questions but won't prompt for every file read. Switch to **autopilot** permission
> only when you are confident in the task scope and want zero interruptions.

---

## LSP Code Actions

The Go binary runs an LSP server on stdio. Start it with `:CopilotAgentLsp` or `require("copilot_agent").start_lsp()`.

Available code actions (triggered on any selection via `vim.lsp.buf.code_action()`):

- **Explain selection** — Ask Copilot to explain the selected code
- **Fix selection** — Ask Copilot to suggest a fix
- **Add tests for selection** — Generate unit tests
- **Add docs for selection** — Generate documentation

The action builds a prompt from the selected text, file path, and line range, then POSTs it to the active HTTP session.

---

## Statusline

Expose Copilot state in your statusline. Each function returns a short string.

When your cursor is in a Copilot Agent window, the plugin replaces that window's local statusline with its own statusline. This applies to both the chat window and the input window, so your normal global statusline stays visible everywhere else.

Default examples:

```text
input window
🤖agent (loop·approve-all)  ✅approve-all  ✅ready  default  󱃕 Instruction: 0 󱜙 Agent: 0 󱨚 Skill: 0  MCP: 0  (? for help)

chat window
🤖agent (loop·approve-all)  ✅approve-all  ✅ready  default  󱃕 Instruction: 0 󱜙 Agent: 0 󱨚 Skill: 0  MCP: 0  session: [#20260501 0905]
```

As the session becomes active, the statusline updates live with readiness (`⏳working`, `📝sync`, `🧩2 tasks`, `❓input`, `✅ready`), the current tool/intent, token usage, pending attachments, and the active session label.

### Use statusline API

```lua
-- lualine
require("lualine").setup {
  sections = {
    lualine_x = {
      require("copilot_agent").statusline_mode,        -- [ask] / [plan] / [agent] / [autopilot]
      require("copilot_agent").statusline_model,       -- claude-sonnet-4.6 / default
      require("copilot_agent").statusline_busy,        -- ✅ready / ⏳working / 📝sync / 🧩2 tasks / ❓input
      require("copilot_agent").statusline_permission,  -- 🔐interactive / ✅approve-all / 🤖autopilot
      require("copilot_agent").statusline_attachments, -- 📎3 (when attachments pending)
      require("copilot_agent").statusline_tool,        -- 🔧 read_file (active tool)
      require("copilot_agent").statusline_intent,      -- current agent intent
      require("copilot_agent").statusline_context,     -- 12k/200k (token usage)
    }
  }
}

-- heirline / &statusline
-- %{v:lua.require'copilot_agent'.statusline()}
```

---

## Session Persistence

Session resume is scoped per project by `working_directory`: `pick_or_create_session` filters persisted sessions by working directory, so opening a different project starts a fresh session. The auto-started service itself is still global by default, which is why the startup picker now shows the current project name and path explicitly. Use `:CopilotAgentNewSession` to force a new one in the same directory, `:CopilotAgentSwitchSession` to pick from all persisted sessions across projects, or `:CopilotAgentDeleteSession` to remove one from a newest-first picker that includes the exact session ID and marks the active session with `●`.

Sessions are auto-named by the SDK after the first conversation turn. You can rename a session by typing `/rename My Session Name` in the input buffer.

When a session is deleted, its checkpoint git worktree is soft-deleted instead of being removed immediately. This applies both to `:CopilotAgentDeleteSession` and `:CopilotAgentStop!`. The checkpoint metadata records the deletion time and the worktree is pruned automatically after 7 days on the next plugin startup or checkpoint/session lifecycle operation.

The chat/output statusline shows the active session summary together with its short session ID, and transcript separators between turns render the completed-turn checkpoint label (`v001`, `v002`, ...) as a virtual rule so you can copy it for rewind/recovery workflows without opening the input buffer.

**Session selection behaviour:**

| Matching sessions for project          | Behaviour                                                         |
| -------------------------------------- | ----------------------------------------------------------------- |
| 0                                      | Creates a new session automatically                               |
| 1                                      | Resumes it silently — no prompt                                   |
| 2+ (`auto_resume = 'prompt'`, default) | Shows `vim.ui.select` picker; most recent session is listed first |
| 2+ (`auto_resume = 'auto'`)            | Silently resumes the most recent session                          |

To always skip the picker, set in your config:

```lua
session = { auto_resume = 'auto' }
```

---

## HTTP API Reference

See [server/README.md](server/README.md#http-api-reference) for the full endpoint list, session permission modes, and SSE event reference.

---

## Tutorial

1. 📖 **[Build a To-Do App with Copilot Agent](doc/tutorial-flask.md)** — Full-stack to-do list app with a REST API and responsive UI.
2. 🌤️ **[Build a Weather Dashboard with Copilot Agent](doc/tutorial-weather-dashboard.md)** — Glassmorphism weather app with wttr.in data, animated UI, and backend tests.
3. 🧩 **[Build a Weather Dashboard with Preset Copilot Agents](doc/tutorial-custom-agent-weather.md)** — Copy a ready-made `.github/agents/` pack and use separate UI, Python, and QA specialists.

---

## Included repo-local custom agents

- **Go Quality Engineer** — runs the repository's existing Go quality checks
- **Selene Lua Quality Engineer** — runs Selene against the Lua sources
- **Code Review Engineer** — reviews Lua and Go changes for correctness, code quality, performance, and security
- **Git Commit Agent** — inspects git status, runs repo-appropriate pre-commit checks, and prepares commit messages from the staged diff
- **Document Update Agent** — reviews user-facing docs against recent plugin changes and updates commands, keymaps, changelog notes, and gotchas

Customize the commit agent's default checks and feedback rules in `.github/commit-agent.md`.

---

## Development

### Formatting

The project uses `make` targets for formatting. Run from the repo root:

```bash
make fmt        # format everything (Lua + Go)
make fmt-lua    # Lua only  — stylua lua/ plugin/  (config: stylua.toml)
make fmt-go     # Go only   — gofmt -w ./server
```

Requirements: [`stylua`](https://github.com/JohnnyMorganz/StyLua) and `gofmt` (bundled with Go).

CI enforces both formatters on every push — PRs with unformatted code will fail the **Lint** workflow.

## Testing

```bash
# Lua unit tests (no Neovim required)
busted --lpath='lua/?.lua;lua/?/init.lua' tests/unit/

# Neovim integration tests (requires nvim on PATH)
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/integration/setup_spec.lua"
```

CI runs all of the above automatically on push and PR via GitHub Actions.
