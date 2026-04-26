.PHONY: build fmt fmt-lua fmt-go

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
