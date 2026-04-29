# Tutorial: Build and Refine a Weather Dashboard with Agents

This is the second tutorial.

It assumes you already finished `tutorial-flask.md` and have:

1. `copilot-agent.nvim` installed
2. the chat UI working in Neovim
3. a basic understanding of **agent mode**

This tutorial focuses on using agents to shape and refine an app.

---

## Goal

You will build a Flask weather dashboard, then create a couple of simple agents so you can see how agent roles help refine the app.

In this walkthrough, you will create:

- a **UI Design Agent**
- a **QA Agent**

Then you will use those agents to improve the app in separate passes.

---

## Part 1 — Build the base weather dashboard

### Step 1 — Create a project directory

```bash
mkdir ~/flask-weather-dashboard && cd ~/flask-weather-dashboard
nvim .
```

### Step 2 — Open chat and switch to agent mode

Inside Neovim:

```vim
:CopilotAgentChat
```

Press **`<C-o>`** until you see **🤖 agent**.

### Step 3 — Ask Copilot to build the first version

Send this prompt:

```text
Build a Flask weather dashboard app in this directory.

Backend:
- Create a virtual environment and install flask
- Create a Flask app
- GET / serves the app
- GET /api/weather?city=<name> returns weather data
- Use wttr.in JSON output as the upstream weather source
- Return city, temperature_c, condition, humidity, wind_kph, and a 3-day forecast
- Handle empty city names and upstream failures cleanly

Frontend:
- Single-page app with vanilla JavaScript and CSS
- Search input for city lookup
- Current weather summary card
- 3-day forecast cards
- Clean responsive layout
- Keep the first version simple but pleasant

Also create requirements.txt and README.md.
```

### Step 4 — Run the app

Then ask:

```text
Run the Flask app on port 5000
```

Open <http://localhost:5000>.

At this point you have a base weather dashboard.

---

## Part 2 — Create simple repo-local agents

### Step 5 — Ask Copilot to create two agents

Send this prompt:

```text
Create two repo-local agents for this project in .github/agents:

1. ui-design.agent.md
- Focus on layout, visual polish, spacing, typography, responsive behavior, loading states, and overall UX
- Do not make backend architecture changes unless absolutely necessary for UI work

2. qa.agent.md
- Focus on test coverage, edge cases, regression checks, and validation
- Prefer pytest for backend tests
- Mock network calls instead of using live weather APIs in tests

Keep both agent files short, practical, and easy to understand.
```

Because the plugin uses Copilot config discovery, these agents become available to the session after they are created.

### Step 6 — Start a fresh session so Copilot discovers the agents cleanly

```vim
:CopilotAgentNewSession
```

Open chat again if needed:

```vim
:CopilotAgentChat
```

---

## Part 3 — Use the agents to refine the app

### Step 7 — Use the UI Design Agent

Run `/agent` and select **UI Design Agent**, then send:

```text
Use the UI Design Agent to refine this weather dashboard.

Improve:
- the overall layout
- visual hierarchy
- spacing and typography
- search bar styling
- forecast card styling
- loading and empty states
- mobile responsiveness

Keep the app lightweight and stay with vanilla JS + CSS.
```

This gives the user a clear example of using an agent for a focused responsibility instead of a generic prompt.

### Step 8 — Use the QA Agent

Start a fresh session:

```vim
:CopilotAgentNewSession
```

Run `/agent` and select **QA Agent**, then send:

```text
Use the QA Agent to add backend tests for this weather dashboard.

Cover:
- GET / returns HTML
- GET /api/weather without city returns 400
- GET /api/weather with a city returns normalized JSON
- upstream failures return a clean error response

Use pytest.
Mock wttr.in so the tests never hit the network.
Update requirements.txt if needed and run the tests.
```

Now the user sees the same app being refined by a different specialized agent.

---

## Part 4 — Use the agents for another refinement pass

### Step 9 — Ask the UI Design Agent for a second iteration

Start another session:

```vim
:CopilotAgentNewSession
```

Run `/agent` and select **UI Design Agent**, then ask:

```text
Refine the dashboard again:
- add a better hero area for the current weather
- make the background feel more dynamic
- improve the forecast card balance
- make error messages feel more polished
- improve the dashboard for narrow mobile screens
```

This is a good example of how agents become reusable project tools instead of one-off prompts.

---

## Why this tutorial matters

The key idea is not just building a weather app.

It is learning how to:

1. create small repo-local agents
2. give each agent a narrow job
3. use fresh sessions to let each agent work with a clear role
4. refine an app in stages

That is the mental model you will use in the next tutorial too.
