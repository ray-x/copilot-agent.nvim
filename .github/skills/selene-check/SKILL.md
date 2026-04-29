---
type: skill
lifecycle: stable
name: "selene-check"
description: "Run Selene with selene.toml against the repository's Lua sources and report actionable diagnostics."
applyTo: "lua/**/*.lua,plugin/**/*.lua,tests/**/*.lua,selene.toml"
---

# Selene Check

Run static analysis for the repository's Lua code using the checked-in Selene configuration.

## Use this skill when

- the user asks to run Selene
- the user asks for Lua linting based on `selene.toml`
- a change touches `lua/`, `plugin/`, or Lua tests and needs static-analysis feedback

## Command

Run from the repository root:

```bash
selene --config selene.toml lua/ plugin/ tests/
```

## Procedure

1. Treat `selene.toml` as authoritative.
2. Run the Selene command from the repository root.
3. If Selene reports findings, summarize them by file and line.
4. If the user asked for fixes, make the smallest safe edits that satisfy Selene and rerun the command.

## Reporting format

- Start with pass/fail.
- For failures, include:
  - file path
  - line number
  - Selene rule or message
  - whether the issue was fixed or is still pending

## Constraints

- Do not replace this check with `luacheck`; this skill is specifically for Selene.
- Do not change `selene.toml` unless the user explicitly asks to modify lint policy.
- Prefer code fixes over suppression comments.
- If `selene` is missing on `PATH`, report that clearly instead of fabricating results.
