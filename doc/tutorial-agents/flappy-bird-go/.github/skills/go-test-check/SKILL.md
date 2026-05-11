---
type: skill
lifecycle: stable
name: "go-test-check"
description: "Run go test for the current Go project and summarize failures with actionable context."
applyTo: "**/*.go,go.mod,scripts/check-quality.sh"
---

# Go Test Check

Run the Go unit test suite for this project.

## Use this skill when

- the user asks to run tests
- gameplay logic changed and needs regression coverage
- vet already passed and you need behavior confidence

## Command

Run from the project root:

```bash
go test ./...
```

## Procedure

1. Run the command from the repository root.
2. Read the exit code and summarize pass/fail.
3. If failing, surface test names and key stack snippets.
4. If asked to fix, make minimal edits and rerun.

## Constraints

- do not replace this with alternate test runners unless requested
- do not invent additional frameworks for this tutorial-sized project
