.PHONY: fmt fmt-lua fmt-go

## fmt: format all source code (Lua + Go)
fmt: fmt-lua fmt-go

## fmt-lua: format Lua files with stylua (uses stylua.toml)
fmt-lua:
	stylua lua/ plugin/

## fmt-go: format Go files with gofmt
fmt-go:
	gofmt -w ./server
