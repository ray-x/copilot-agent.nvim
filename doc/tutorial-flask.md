# Tutorial: Build a Flask API with Copilot Agent

This step-by-step guide walks you through installing **copilot-agent.nvim**, configuring it with lazy.nvim, and using it in **agent mode** to scaffold a Python Flask REST API — all without leaving Neovim.

---

## Part 1 — Installation

### 1.1 Install the GitHub Copilot CLI

The plugin requires the official GitHub Copilot CLI runtime (`@github/copilot`).

Install prerelease version via npm:

```bash
# macOS (Homebrew)
brew install copilot-cli@prerelease

# Or via npm (all platforms)
npm install -g @github/copilot@prerelease
```

> **Full install guide:** <https://docs.github.com/en/copilot/building-copilot-extensions/building-a-copilot-skillset>
>
> After installation, verify with:
>
> ```bash
> copilot --version               # brew
> npx @github/copilot --version   # npm
> ```

### 1.2 Add the plugin to lazy.nvim

Create or edit your lazy.nvim plugin spec. Here is a **minimal config** that gets you up and running:

```lua
-- ~/.config/nvim/lua/plugins/copilot-agent.lua  (or wherever your lazy specs live)
return {
  "ray-x/copilot-agent.nvim",
  build = ":CopilotAgentInstall",   -- auto-download the Go server binary
  cmd = { "CopilotAgentChat", "CopilotAgentAsk" },  -- lazy-load on first use
  keys = {
    { "<leader>aa", "<cmd>CopilotAgentChat<cr>", desc = "Copilot Agent Chat" },
  },
  config = function()
    require("copilot_agent").setup({
      service = {
        auto_start = true,   -- launches the Go service automatically
      },
      session = {
        enable_config_discovery = true,  -- reads .github/copilot-instructions.md
      },
      chat = {
        diff_cmd = { "delta" },  -- optional: rich diff viewer (install delta separately)
      },
    })
  end,
}
```

Save the file, restart Neovim, and run `:Lazy sync` to install.

### 1.3 Install the Go server binary

The first time you load the plugin (or on every `build`), the `:CopilotAgentInstall` command downloads a pre-built binary for your platform — **no Go toolchain needed**.

You can also trigger it manually:

```vim
:CopilotAgentInstall
```

The binary is saved to `<plugin_root>/bin/copilot-agent`. To verify in neovim:

```vim
:checkhealth copilot_agent
```

> **Building from source** (optional, requires Go 1.24+):
>
> ```bash
> cd ~/.local/share/nvim/lazy/copilot-agent.nvim/server
> go build -o ../bin/copilot-agent .
> ```

---

## Part 2 — Build a To-Do List Web App

### Step 1 — Create a project directory

```bash
mkdir ~/flask-todo && cd ~/flask-todo
nvim .
```

That's it — just an empty folder. Copilot will bootstrap everything for you.

### Step 2 — Open the chat window

Inside Neovim, run:

```vim
:CopilotAgentChat
```

Or press `<leader>aa` if you used the keymap from the config above.

The chat window opens in a vertical split. The status line shows the current model and mode.

### Step 3 — Switch to Agent mode

Press **`<C-o>`** in the input buffer to cycle through modes until you see **🤖 agent**.
In agent mode, Copilot can create files, run terminal commands, and iterate on errors autonomously.

> **Tip:** Cycle one more time to **✈️ autopilot** for full autonomy — Copilot will auto-approve every tool call.

### Step 4 — Ask Copilot to scaffold the project

Type in the input buffer:

```
Bootstrap a Python Flask to-do list web application in this directory:

Backend:
- Create a virtual environment and install flask
- Create app.py with a REST API backed by an in-memory list:
  GET    /api/tasks         → list all tasks
  POST   /api/tasks         → add a task (JSON: {"title": "...", "description": "..."})
  PUT    /api/tasks/<id>    → edit a task's title, description, or completed status
  DELETE /api/tasks/<id>    → delete a task
  PATCH  /api/tasks/<id>/complete → toggle a task's completed status
- Each task has: id, title, description, completed (bool), created_at

Frontend:
- Serve a single-page HTML UI at GET /
- Modern, clean design with CSS (no framework needed, just good defaults)
- Responsive layout that works on desktop and mobile
- Features: add task, edit task inline, delete task, mark as completed (strikethrough)
- Use fetch() to call the API — no page reloads

Also create requirements.txt and a README.md explaining how to run it.
```

Press **`<C-s>`** to send.

Copilot will create the venv, install dependencies, and write all the files — you just approve each step.

### Step 5 — Review and approve tool calls

Copilot will start creating files. In **agent mode**, each tool call triggers a permission prompt:

```
 copilot-agent: Copilot wants to create file: app.py
 [1] Approve  [2] Approve All  [3] Reject
```

- Press **1** to approve each file one by one (recommended for learning)
- Press **2** to approve all remaining tool calls in this turn

If you have [`delta`](https://github.com/dandavison/delta) installed, you'll see a syntax-highlighted diff in a floating window before approving.

### Step 6 — Ask Copilot to run it

After the files are created, type:

```
Run the Flask app on port 5000
```

Copilot will execute the command. Approve it, then open <http://localhost:5000> in your browser — you should see the to-do app.

### Step 7 — Test the API from the terminal

Open a Neovim terminal (`:terminal`) or use another shell:

```bash
# Add tasks
curl -X POST http://localhost:5000/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title": "Buy coffee", "description": "Get the good beans"}'

curl -X POST http://localhost:5000/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title": "Write docs", "description": "Update the README"}'

# List all tasks
curl http://localhost:5000/api/tasks

# Mark a task as completed
curl -X PATCH http://localhost:5000/api/tasks/1/complete

# Edit a task
curl -X PUT http://localhost:5000/api/tasks/1 \
  -H 'Content-Type: application/json' \
  -d '{"title": "Write better docs", "description": "Add examples"}'

# Delete a task
curl -X DELETE http://localhost:5000/api/tasks/1
```

### Step 8 — Iterate with Copilot

Back in the chat window, ask for improvements:

```
Add these features to the to-do app:
- Error handling for invalid JSON and missing tasks (return 404 with a message)
- A task count summary at the top ("3 tasks, 1 completed")
- Smooth CSS transitions when marking tasks complete
- A "Clear completed" button
```

Copilot will edit the files in place — you'll see the diff for each change.

### Step 9 — Ask Copilot to write tests

Now let Copilot test its own work. Type:

```
Write pytest tests for the to-do API in test_app.py. Cover:
- POST /api/tasks creates a task with title and description
- GET /api/tasks returns all tasks
- PUT /api/tasks/<id> updates title and description
- PATCH /api/tasks/<id>/complete toggles completed status
- DELETE /api/tasks/<id> removes a task
- GET/PUT/DELETE with invalid id returns 404
- POST with missing title returns 400

Add pytest to requirements.txt and run the tests.
```

Copilot will:

1. Create `test_app.py` using Flask's test client
2. Update `requirements.txt` to include `pytest`
3. Run `pip install -r requirements.txt && pytest -v`

You'll see the test output directly in the chat. If any test fails, Copilot will fix the code and re-run automatically (in agent/autopilot mode).

Example output you should see:

```
test_app.py::test_create_task          PASSED
test_app.py::test_list_tasks           PASSED
test_app.py::test_update_task          PASSED
test_app.py::test_toggle_complete      PASSED
test_app.py::test_delete_task          PASSED
test_app.py::test_not_found            PASSED
test_app.py::test_missing_title        PASSED
```

> **Tip:** You can also ask: `"Add integration tests that start the server on a random port"` or `"Test the frontend with playwright"`.

### Step 10 — Review all changes

Run `:CopilotAgentDiff` to see every file Copilot modified. A picker lists all changed files; select one to open a side-by-side vimdiff.

### Step 11 — Start a new conversation

When you're done, run `:CopilotAgentNew` to start a fresh session, or `:CopilotAgentSwitch` to pick a previous one. Sessions are persisted per working directory, so reopening `~/flask-todo` later will resume where you left off.

---

## Quick Reference

| Keymap / Command      | What it does                                |
| --------------------- | ------------------------------------------- |
| `<C-o>`               | Cycle mode (ask → plan → agent → autopilot) |
| `<C-s>`               | Send message                                |
| `<C-a>`               | Attach file / folder / image                |
| `<C-x>`               | Cancel a running agent turn                 |
| `:CopilotAgentModel`  | Switch to a different model mid-chat        |
| `:CopilotAgentDiff`   | Review all file changes (vimdiff)           |
| `:CopilotAgentNew`    | Start a fresh session                       |
| `:CopilotAgentSwitch` | Pick a different session                    |

---

## Full Configuration Reference

For all available options, see the [README](../README.md#installation) or run `:help copilot-agent-config` inside Neovim.
