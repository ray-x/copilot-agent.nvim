# Tutorial: Build a Weather Dashboard with Custom Agents

This tutorial focuses on building an app with **repo-local custom agents**.

It assumes you already finished `tutorial-flask.md` and understand the basic chat workflow. Unlike the Flask tutorial, this guide does **not** repeat plugin setup.

---

## Goal

In this walkthrough, you will:

1. start a fresh weather dashboard project
2. copy in a ready-made custom agent pack
3. let Copilot discover those agents
4. use the agents to build and refine the app

The example agent pack lives under:

```text
doc/tutorial-agents/weather-dashboard/.github/agents/
```

It includes:

- `python-flask.agent.md`
- `web-ui-designer.agent.md`
- `qa-engineer.agent.md`

These example agents are intentionally more specific than a broad role prompt. They tell Copilot how to bootstrap new files, how to handle headers and license conventions, how to organize imports, and what quality bar to follow. In this example pack, the agents use header placeholders like `{{author}}` and `{{company}}`, with instructions to resolve them from common git or environment values before falling back to example defaults.

---

## Part 1 — Prepare the project

### Step 1 — Create the project directory

```bash
mkdir ~/flask-weather-custom-agent && cd ~/flask-weather-custom-agent
cp -R ~/.local/share/nvim/lazy/copilot-agent.nvim/doc/tutorial-agents/weather-dashboard/.github .
nvim .
```

That copies the `.github/agents/` folder into the project so Copilot can discover the custom agents.

### Step 2 — Open chat and switch to agent mode

Inside Neovim:

```vim
:CopilotAgentChat
```

Press **`<C-o>`** until the statusline shows **🤖 agent**.

### Step 3 — Start a fresh session if needed so Copilot discovers the agents

```vim
:CopilotAgentNewSession
```

Because `enable_config_discovery = true` is already enabled in the recommended setup, the Copilot SDK can discover the copied `.github/agents` directory.

**Why this step is shown:**

1. In a **brand-new folder**, creating a new session is usually **not necessary**. If you copied `.github/agents` before opening chat, `:CopilotAgentChat` will create the first session for that folder and the agents should be discovered automatically. This step is included to show that **new sessions are one way to trigger agent discovery**.
2. In a **live existing session**, you cannot add agents dynamically to that same session. If you add `.github/agents` after the session already exists, you need a **new session** so Copilot re-reads the project config and discovers the new agents.

---

## Part 2 — Build the app with a custom implementation agent

### Step 4 — Use the Python Flask Engineer agent

Run `/agent` and select **Python Flask Engineer**, then send:

```text
Use the Python Flask Engineer agent to build a Flask weather dashboard web app in this directory.

Backend:
- GET / serves the app
- GET /api/weather?city=<name> fetches weather from wttr.in JSON output
- return city, temperature_c, condition, humidity, wind_kph, and a 3-day forecast
- add clean error handling for empty city names and upstream failures

Frontend:
- single-page app with vanilla JS + CSS only
- weather search bar
- current weather summary
- 3-day forecast cards
- responsive layout

Also add the normal project files needed to run it, including dependency tracking and a short README.
```

Because you are already using the **Python Flask Engineer** agent, you do not need to spell out every basic setup detail. The agent itself now carries expectations for file bootstrap, module headers, import ordering, dependency tracking, and code structure. You only need to add extra prompt detail when you want a very specific architecture or style.

Approve the file writes and shell commands.

### Step 5 — Run the app

Ask:

```text
Run the Flask app on port 5000
```

Open <http://localhost:5000>.

At this point you have a working dashboard built through a named custom agent instead of a generic assistant.

---

## Part 3 — Refine the app with specialized custom agents

### Step 6 — Use the Web UI Designer agent

Start a fresh session:

```vim
:CopilotAgentNewSession
```

Run `/agent` and select **Web UI Designer**, then ask:

```text
Use the Web UI Designer agent to refine the homepage:
- improve the search bar
- improve the hero section
- make the forecast cards feel more premium
- improve spacing and typography
- add loading and empty states
- improve mobile layout
```

This keeps visual work scoped to design and UX.

### Step 7 — Use the QA Engineer agent

Start another fresh session:

```vim
:CopilotAgentNewSession
```

Run `/agent` and select **QA Engineer**, then ask:

```text
Use the QA Engineer agent to add a pytest suite for this project.

Cover:
- GET / returns HTML
- GET /api/weather without city returns 400
- GET /api/weather with a city returns normalized JSON
- upstream failures return a clean error response

Mock wttr.in so tests never hit the network.
Add pytest to requirements.txt and run the tests.
```

This keeps testing and regression work separate from implementation and design.

---

## Part 4 — Use multiple custom agents to refine the app

### Step 8 — Ask Copilot to coordinate the custom agents

Start another fresh session:

```vim
:CopilotAgentNewSession
```

Then send:

```text
Use the available custom agents to refine this weather dashboard.

Use:
- Python Flask Engineer for backend cleanup and data handling improvements
- Web UI Designer for layout and visual polish
- QA Engineer for regression coverage

Goals:
- keep the app simple
- preserve Flask + vanilla JS
- improve the UI and robustness
- run tests at the end
```

This gives the user a practical idea of how custom agents can collaborate around a single project.

---

## Why this tutorial matters

This workflow is different from ordinary chat-only prompting because:

1. the agents are stored in the repository
2. they are reusable across sessions
3. each one has a clear role
4. the project keeps its own specialist behavior close to the code

That is one of the strongest Copilot-native workflows supported by `copilot-agent.nvim`.
