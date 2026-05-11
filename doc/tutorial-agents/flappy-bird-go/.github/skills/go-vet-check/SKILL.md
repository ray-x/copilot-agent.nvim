---
type: skill
lifecycle: stable
name: "go-vet-check"
description: "Run go vet for the current Go project and report actionable diagnostics."
applyTo: "**/*.go,go.mod,scripts/check-quality.sh"
---

# Go Vet Check

Run Go vetting for this project.

## Use this skill when

- Go files changed and you need static diagnostics
- the user asks for a Go quality pass
- you need a quick sanity check before or after tests

## Command

Run from the project root:

```bash
go vet ./...
```

## Procedure

1. Run the command from the repository root.
2. If findings appear, summarize by file and line.
3. If the user asked for fixes, apply minimal safe edits and rerun.

## Constraints

- do not swap this for a different linter unless the user asks
- report missing toolchain issues clearly if Go is unavailable
