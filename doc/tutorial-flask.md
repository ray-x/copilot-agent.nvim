# Tutorial: Set Up copilot-agent.nvim and Build a Flask To-Do App

This is the best place to start with `copilot-agent.nvim`.

In this tutorial, you will:

1. Install and configure the plugin
2. Open the chat UI inside Neovim
3. Use Copilot in **agent mode** to build a simple Flask to-do app
4. Ask Copilot to refine and test the app

---

## Part 1 — Install and configure the plugin

### Step 1 — Install the GitHub Copilot CLI

The plugin uses the official GitHub Copilot CLI runtime.

```bash
# macOS (Homebrew)
brew install copilot-cli@prerelease

# Or via npm
npm install -g @github/copilot@prerelease
```

Verify it:

```bash
copilot --version
# or
npx @github/copilot --version
```

### Step 2 — Add the plugin with lazy.nvim

```lua
return {
  "ray-x/copilot-agent.nvim",
  build = ":CopilotAgentInstall",
  cmd = { "CopilotAgentChat", "CopilotAgentAsk" },
  keys = {
    { "<leader>aa", "<cmd>CopilotAgentChat<cr>", desc = "Copilot Agent Chat" },
  },
  config = function()
    require("copilot_agent").setup({
      service = {
        auto_start = true,
      },
      session = {
        enable_config_discovery = true,
      },
      chat = {
        diff_cmd = { "delta" },
      },
    })
  end,
}
```

Then run:

```vim
:Lazy sync
:CopilotAgentInstall
:checkhealth copilot_agent
```

### Step 3 — Open the chat window

Inside Neovim:

```vim
:CopilotAgentChat
```

The prompt input opens automatically. You can start typing right away.

### Step 4 — Switch to agent mode

Press **`<C-o>`** until the input statusline shows **🤖 agent**.

In agent mode, Copilot can create files, run shell commands, and iterate on fixes.

---

## Part 2 — Build a simple Flask to-do app

### Step 5 — Create a project directory

```bash
mkdir ~/flask-todo && cd ~/flask-todo
nvim .
```

Start from an empty directory.

### Step 6 — Ask Copilot to scaffold the app

Send this prompt:

```text
Build a simple Flask to-do app in this directory.

Backend:
- Create a virtual environment and install flask
- Create app.py
- Keep data in memory for now
- Add these routes:
  - GET / serves the app
  - GET /api/tasks returns all tasks
  - POST /api/tasks creates a task
  - PUT /api/tasks/<id> updates a task
  - DELETE /api/tasks/<id> deletes a task
- Each task should have: id, title, completed
- Return JSON errors for invalid input and missing tasks

Frontend:
- Single-page app with plain HTML, CSS, and vanilla JavaScript
- Show the task list on the homepage
- Support add, toggle complete, edit, and delete
- Keep the styling simple and clean
- Make it responsive

Also create requirements.txt and a README.md with run instructions.
```

Approve the file writes and shell commands as Copilot works.

### Step 7 — Run the app

Then ask:

```text
Run the Flask app on port 5000
```

Open <http://localhost:5000>.

You should now have a working Flask to-do app.

### Step 8 — Exercise the API

From a terminal:

```bash
curl http://localhost:5000/api/tasks

curl -X POST http://localhost:5000/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title": "Buy milk"}'

curl -X PUT http://localhost:5000/api/tasks/1 \
  -H 'Content-Type: application/json' \
  -d '{"title": "Buy oat milk", "completed": true}'

curl -X DELETE http://localhost:5000/api/tasks/1
```

---

## Part 3 — Refine the app

### Step 9 — Ask Copilot for a small feature pass

Send:

```text
Improve the to-do app:
- add a task counter
- add a "Clear completed" button
- improve empty-state messaging
- add smooth transitions when tasks change
```

### Step 10 — Ask Copilot to add tests

Send:

```text
Write pytest tests for the Flask to-do app.

Cover:
- GET / returns HTML
- GET /api/tasks returns JSON
- POST /api/tasks creates a task
- PUT /api/tasks/<id> updates a task
- DELETE /api/tasks/<id> deletes a task
- invalid task IDs return 404
- missing title returns 400

Add pytest to requirements.txt and run the tests.
```

### Step 11 — Review the changes

Use:

```vim
:CopilotAgentDiff
```

---

## What to do next

After this tutorial, continue with:

1. `tutorial-weather-dashboard.md` to learn how to use agents to refine an app
2. `tutorial-custom-agent-weather.md` to learn how to build with repo-local custom agents
