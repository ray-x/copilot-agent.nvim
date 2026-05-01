# Server

## Running the Service Manually

```bash
cd server/

# Development — OS assigns a free port; actual address printed to stderr
go run .

# Pin to a specific port (useful for curl testing)
go run . \
  -addr 127.0.0.1:8088 \
  -cwd /path/to/workspace \
  -cli-path /path/to/@github/copilot/index.js \
  -lsp=true      # default: true — LSP server on stdio

# Build a binary
go build -o copilot-agent .
./copilot-agent          # dynamic port
./copilot-agent -addr 127.0.0.1:8088   # fixed port
```

**Flags:**

| Flag          | Default       | Description                                           |
| ------------- | ------------- | ----------------------------------------------------- |
| `-addr`       | (free port)   | HTTP listen address; empty or `:0` → OS picks         |
| `-port-range` | —             | Try ports lo–hi (e.g. `18000-19000`); first free wins |
| `-cwd`        | current dir   | Default working directory for sessions                |
| `-model`      | (sdk default) | Default model for new sessions                        |
| `-cli-path`   | auto-detected | Path to Copilot CLI binary/JS entrypoint              |
| `-cli-url`    | —             | URL of an already-running Copilot CLI server          |
| `-log-level`  | —             | Copilot CLI log level                                 |
| `-lsp`        | `true`        | Start LSP server on stdio                             |

The service always prints `COPILOT_AGENT_ADDR=127.0.0.1:<PORT>` to stderr once the
listener is bound. When `auto_start = true`, the plugin reads this line and
configures its HTTP client automatically — no manual `base_url` needed.

---

## HTTP API Reference

| Method   | Path                                | Description                                            |
| -------- | ----------------------------------- | ------------------------------------------------------ |
| `GET`    | `/healthz`                          | Health check                                           |
| `GET`    | `/sessions`                         | List all sessions (live + persisted)                   |
| `POST`   | `/sessions`                         | Create or resume a session                             |
| `GET`    | `/sessions/{id}`                    | Get live session metadata                              |
| `DELETE` | `/sessions/{id}`                    | Disconnect; `?delete=true` removes persisted state     |
| `GET`    | `/sessions/{id}/messages`           | Fetch stored session events                            |
| `POST`   | `/sessions/{id}/messages`           | Send a prompt with optional attachments                |
| `GET`    | `/sessions/{id}/events`             | SSE stream of session + host events                    |
| `POST`   | `/sessions/{id}/user-input/{reqID}` | Answer a pending `ask_user` request                    |
| `POST`   | `/sessions/{id}/permission/{reqID}` | Answer a pending permission request (interactive mode) |
| `POST`   | `/sessions/{id}/permission-mode`    | Update permission mode on a live session               |
| `POST`   | `/sessions/{id}/model`              | Switch model for a live session                        |
| `POST`   | `/sessions/{id}/tools`              | Update excluded tools list                             |
| `GET`    | `/models`                           | List available models                                  |

## Permission modes for `POST /sessions`

```json
{ "permissionMode": "interactive" }   // prompt Neovim UI per tool use
{ "permissionMode": "approve-all" }   // auto-approve everything
{ "permissionMode": "autopilot" }     // approve-all + auto-answer user inputs
{ "permissionMode": "reject-all" }    // reject all tool uses
```

## SSE Event Types

| Event                          | Description                                                                       |
| ------------------------------ | --------------------------------------------------------------------------------- |
| `session.event`                | Raw SDK events (`assistant.message_delta`, `assistant.turn_end`, etc.)            |
| `host.user_input_requested`    | Agent needs user input — reply via `POST .../user-input/{id}`                     |
| `host.permission_requested`    | Tool use needs approval (interactive mode) — reply via `POST .../permission/{id}` |
| `host.permission_decision`     | Logged approval/rejection outcome                                                 |
| `host.permission_mode_changed` | Permission mode updated on live session                                           |
| `host.model_changed`           | Model switched on live session                                                    |
| `host.session_disconnected`    | Session was closed                                                                |
| `: keepalive`                  | SSE keepalive comment (ignore)                                                    |

## Quick Start (HTTP API)

```bash
# Terminal 1: start the service using the pre-built binary (no Go needed)
# Download it first with :CopilotAgentInstall inside Neovim, then:
~/.local/share/nvim/lazy/copilot-agent.nvim/bin/copilot-agent

# Or build from source (requires Go 1.24+)
cd server/ && go run . -cli-path ~/.local/share/github-copilot/index.js
# prints: COPILOT_AGENT_ADDR=127.0.0.1:XXXXX

# Terminal 2: create a session (replace port)
curl -s -X POST http://127.0.0.1:XXXXX/sessions \
  -H 'Content-Type: application/json' \
  -d '{"workingDirectory":".","permissionMode":"approve-all","clientName":"test"}'

# Stream events (replace SESSION_ID)
curl -N http://127.0.0.1:XXXXX/sessions/SESSION_ID/events

# Send a message
curl -X POST http://127.0.0.1:XXXXX/sessions/SESSION_ID/messages \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Explain what this project does."}'
```

## Testing

```bash
# Go tests (vet, fmt, unit tests, build)
cd server/
go vet ./...
go test -race ./...
go build ./...

# Lua unit tests (no Neovim required)
busted --lpath='lua/?.lua;lua/?/init.lua' tests/unit/

# Neovim integration tests (requires nvim on PATH)
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/integration/setup_spec.lua"
```

CI runs all of the above automatically on push and PR via GitHub Actions.
