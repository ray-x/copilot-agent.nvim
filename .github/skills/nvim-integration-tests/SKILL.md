---
type: skill
lifecycle: stable
name: "nvim-integration-tests"
description: "Run the headless Neovim integration suite for copilot-agent.nvim and interpret the Plenary test results."
applyTo: "lua/**/*.lua,plugin/**/*.lua,tests/**/*.lua,tests/minimal_init.lua"
---

# Neovim Integration Tests

Run the repository's headless Neovim integration suite and interpret the Plenary summary correctly.

## Use this skill when

- the user asks to run the Lua or Neovim integration tests
- a change affects the chat UI, session handling, input window, or other Lua plugin behavior
- you need a regression check for plugin behavior under `tests/integration/setup_spec.lua`

## Command

Run from the repository root:

```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/integration/setup_spec.lua" -c qa
```

## Procedure

1. Run the command from the repository root.
2. When the user says the official release version failed, use the Homebrew-managed `nvim` binary for the run. Resolve it dynamically from the environment; do not write or rely on a hardcoded absolute path in docs or commands.
3. When the user says the nightly version failed, use `nvim-nightly` from `PATH`.
4. Read the Plenary summary at the end of the output.
5. Use the command exit code and the `Success / Failed / Errors` summary as the source of truth.
6. If a failure occurs, surface the failing test name and the relevant stack trace snippet.

## Important note for this repository

In some environments, headless Neovim may print unrelated startup noise from local user configuration before the test summary. Do not mistake that noise for a test failure if the command exits successfully and the Plenary summary reports zero failures.

## Constraints

- Do not swap this command for a different test runner.
- Do not edit tests unless the user asked for implementation or test changes.
- Keep the report concise: status first, failing tests only when there is a failure.
- Do not hardcode machine-specific Neovim paths in the skill or in generated markdown.
