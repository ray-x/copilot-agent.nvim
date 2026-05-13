## - 2026-05-13 15:30:00

### Changed

- Chat activity hover flow: `K` now toggles preview in-place, `gK` focuses/opens it, and `<C-w>j` focuses hover when available before falling back to normal window-down.
- `service.auto_start` default is now `true`; top-level legacy `auto_start` is mapped to `service.auto_start` for backward compatibility.
- Commit message generation (`:CopilotAgentFugitiveCommit`) now waits for final post-tool assistant output instead of stopping on planning preamble text.
- Startup/health guidance clarified: Copilot CLI runtime resolution (`-cli-path`/env/PATH) is required, and GUI Neovim PATH differences can cause startup failures.

## - 2026-04-30 21:00:00

### Added

- Plugin created

### Fixed

- Delta display issue
