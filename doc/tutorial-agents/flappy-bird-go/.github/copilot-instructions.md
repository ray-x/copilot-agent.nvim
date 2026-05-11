# Copilot Instructions for Terminal Flappy Bird

## Build and run

```bash
# run the game
./scripts/run-game.sh

# run quality checks
./scripts/check-quality.sh
```

## Project goals

- build a playable terminal Flappy Bird clone in Go
- keep the project lightweight and beginner-friendly
- keep gameplay smooth and controls responsive
- maintain deterministic tests for core game logic

## File layout

- `main.go`: game loop and rendering entrypoint
- `game.go`: core gameplay state and update logic
- `game_test.go`: deterministic unit tests for physics, collisions, and scoring
- `scripts/run-game.sh`: launch helper used in terminal demos
- `scripts/check-quality.sh`: `go vet` + `go test` quality gate
- `docs/requirements.md`: concise functional requirements

## Engineering rules

- prefer Go standard library first; avoid unnecessary dependencies
- keep game constants configurable in one place
- separate pure gameplay logic from terminal I/O as much as possible
- preserve existing behavior when refactoring
- run `gofmt` on changed Go files

## Definition of done

1. requirements documented in `docs/requirements.md`
2. game is playable from `./scripts/run-game.sh`
3. `./scripts/check-quality.sh` passes
4. README has run and control instructions
