### 🥇 Workflow 1 — Agentic task with permission control

**"Implement this feature for me"**

1. Open `:CopilotAgentChat` with `permission_mode = "interactive"`
2. Type: _"Add pagination to the `/users` endpoint and write tests for it"_
3. Watch the agent autonomously **read files → write code → run tests** — each tool call pauses for your approval
4. Toggle to `approve-all` mid-session when you trust it: `:CopilotAgentModel` → permission picker

**Unique to this plugin:** Real agentic loop with per-tool-call approval. Other plugins only suggest edits; this one executes them.

---

### 🥈 Workflow 2 — Image → code

**"Build this UI"**

1. Take a screenshot of a design or error
2. `<M-v>` to paste clipboard image into the input buffer
3. _"Implement a Neovim float that looks like this"_

**Unique:** Clipboard image paste directly into an agentic session.

---

### 🥉 Workflow 3 — LSP code actions on any selection

**"Explain / fix / test this"**

1. Visual-select a suspicious function
2. LSP code action menu → **Explain**, **Fix**, **Add tests**, **Add docs**
3. Answer lands in the chat buffer with full context

**Unique:** LSP integration means it works from any file type via the standard `vim.lsp` code-action flow — no custom keymaps needed.

---

### Combined demo script (most impressive)

```
1. CopilotAgentChat  →  "Read the codebase and list all endpoints"
2. Agent reads files autonomously (approve each tool call)
3. <C-a> attach a PDF spec → "Now implement the missing /login endpoint"
4. Agent writes the file
5. Visual-select the new function → LSP → Add tests
6. <M-v> paste a screenshot of a test failure → "Fix this"
```

This chain — **autonomous reading → writing → LSP actions → image debugging** — can't be done in a single session in any other Neovim Copilot plugin today.
