# Git Commit Agent Overrides

The `Git Commit Agent` should read this file before running checks or proposing commit messages.

Edit the commands and guidance below to match your workflow.

## Check policy

- default full gate: `make check`
- Lua-only changes: `make lint-lua` and `make test-lua`
- Go-only changes under `server/`: `make lint-go` and `make test-go`
- docs-only changes: skip code checks unless the documentation must stay synchronized with executable examples

## Commit message preferences

- use conventional-commit prefixes when they fit the staged diff
- keep the subject line specific and imperative
- keep the subject line under 72 characters when practical
- add a body for non-obvious rationale, follow-up work, or notable tradeoffs

## Feedback expectations

- always mention which command failed
- summarize the highest-value issues first
- suggest the smallest safe fix before proposing larger rewrites
- call out staged vs unstaged mismatches before generating the commit message

## Git and Neovim workflow

- prefer non-interactive git commands
- use the staged diff as the source of truth when staged changes exist
- if nothing is staged, ask before staging or committing broader worktree changes
