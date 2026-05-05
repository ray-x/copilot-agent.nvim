# Tutorial: Build a Terminal Flappy Bird Game with Custom Agents and Skills

This tutorial shows a fast, demo-friendly workflow: bootstrap a project with ready-made Copilot assets, build a terminal Flappy Bird clone in Go, run quality checks, and launch the game from a Neovim terminal.

It assumes you already finished `tutorial-flask.md` and can open the Copilot chat UI in Neovim.

---

## Goal

In this walkthrough, you will:

1. bootstrap a fresh project with a script
2. use custom agents to define requirements and implement the game
3. use custom skills to run `go vet` and `go test`
4. run the game from a script inside Neovim

The starter pack for this tutorial lives under:

```text
doc/tutorial-agents/flappy-bird-go/
```

---

## Part 1 - Bootstrap the project folder

### Step 1 - Run the bootstrap script

```bash
bash ~/.local/share/nvim/lazy/copilot-agent.nvim/doc/tutorial-agents/flappy-bird-go/bootstrap.sh ~/flappy-bird-go
cd ~/flappy-bird-go
nvim .
```

If your plugin path is different, adjust the source path to this repository's `doc/tutorial-agents/flappy-bird-go/bootstrap.sh`.

The script copies:

- `.github/copilot-instructions.md`
- `.github/agents/`
- `.github/skills/`
- `prompts/`
- `scripts/`

### Step 2 - Open chat in agent mode

Inside Neovim:

```vim
:CopilotAgentChat
```

Press `<C-t>` until the statusline shows `agent`.

If the input buffer is not visible, press `i` or `<Enter>` in the chat window first.

### Step 3 - Start a fresh session for config discovery

```vim
:CopilotAgentNewSession
```

This ensures Copilot discovers the newly copied repo-local agents and skills.

---

## Part 2 - Generate requirements with a custom agent

### Step 4 - Use the requirements agent

Run `/agent` and select **Game Requirements Writer**, then send this message:

```text
Follow @prompts/01-requirements.md and create docs/requirements.md.
```

```text
Game Requirements Writer
Follow @prompts/01-requirements.md and create docs/requirements.md.
```

Expected output: a `docs/requirements.md` spec with controls, physics, collisions, scoring, game states, and acceptance criteria.

---

## Part 3 - Implement the game with a custom builder agent

### Step 5 - Use the game builder agent

Run `/agent` and select **Terminal Flappy Builder**, then send:

```text
Follow @prompts/02-build-game.md and implement the game now.
```

```text
Terminal Flappy Builder
Follow @prompts/02-build-game.md and implement the game now.
```

Expected output:

- Go game implementation files
- a playable terminal loop
- simple tests for core game behavior

---

## Part 4 - Run quality checks through custom skills

### Step 6 - Use the QA agent plus skills

Run `/agent` and select **Go QA and Reliability Engineer**, then send:

```text
Follow @prompts/03-quality-pass.md and run the requested quality pass.
```

That prompt asks the agent to use:

- skill `go-vet-check`
- skill `go-test-check`

This gives a clean "requirements -> implementation -> vet -> test" workflow for demos.

---

## Part 5 - Run the game inside Neovim terminal

### Step 7 - Launch from script

In Neovim:

```vim
:terminal ./scripts/run-game.sh
```

The run script executes `go run .` from the project root.

Suggested controls in your game prompt:

- `Space` or `k` to flap
- `r` to restart after game over
- `q` to quit

---

## Optional demo flow (20 seconds)

1. open chat + show `agent` mode
2. send `Follow @prompts/02-build-game.md and implement the game now.` (speed up this section in video)
3. show `go vet` and `go test` pass via `Follow @prompts/03-quality-pass.md and run the requested quality pass.`
4. run `:terminal ./scripts/run-game.sh` and show gameplay

This keeps the promo focused on an end-to-end Copilot workflow instead of raw code generation.
