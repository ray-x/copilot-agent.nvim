.PHONY: build fmt fmt-lua fmt-go test test-go test-lua lint lint-lua lint-go check

## build: compile the Go service binary to bin/copilot-agent
build:
	mkdir -p bin
	cd server && go build -o ../bin/copilot-agent .

## fmt: format all source code (Lua + Go)
fmt: fmt-lua fmt-go

## fmt-lua: format Lua files with stylua (uses stylua.toml)
fmt-lua:
	stylua lua/ plugin/

## fmt-go: format Go files with gofmt
fmt-go:
	gofmt -w ./server

## test: run all tests (Go + Lua)
test: test-go test-lua

## test-go: run Go unit tests for the server
test-go:
	cd server && go test ./... -v

## test-lua: run Lua integration tests with plenary
test-lua:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/integration/setup_spec.lua"

## lint: run all linters (Lua + Go)
lint: lint-lua lint-go

## lint-lua: run luacheck and stylua --check on Lua sources
lint-lua:
	luacheck lua/ --globals vim --no-max-line-length
	stylua --check lua/ plugin/

## lint-go: run go vet on the server
lint-go:
	cd server && go vet ./...

## check: lint + test (full CI gate)
check: lint test
