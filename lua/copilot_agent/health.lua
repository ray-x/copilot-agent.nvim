-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- :checkhealth copilot_agent
local M = {}

local function check_neovim_version()
  vim.health.start('Neovim version')
  local version = vim.version()
  if version.major > 0 or version.minor >= 10 then
    vim.health.ok(string.format('Neovim %d.%d.%d (>= 0.10 required)', version.major, version.minor, version.patch))
  else
    vim.health.error(string.format('Neovim %d.%d.%d detected — version 0.10+ is required', version.major, version.minor, version.patch))
  end
end

local function check_curl()
  vim.health.start('curl')
  local ok, ca = pcall(require, 'copilot_agent')
  local bin = (ok and ca.state and ca.state.config and ca.state.config.curl_bin) or 'curl'
  if vim.fn.executable(bin) == 1 then
    local version = vim.fn.system({ bin, '--version' }):match('curl%s+([%d%.]+)')
    vim.health.ok(string.format('`%s` found%s', bin, version and (' (v' .. version .. ')') or ''))
  else
    vim.health.error(string.format('`%s` not found — required for all HTTP/SSE communication', bin))
  end
end

local function check_go()
  vim.health.start('Go toolchain (for `go run .` / `go build`)')
  if vim.fn.executable('go') == 1 then
    local ver = vim.fn.system('go version'):match('go(%S+)')
    vim.health.ok('`go` found' .. (ver and (' (v' .. ver .. ')') or ''))
  else
    vim.health.warn('`go` not found — required only if running the service via `go run .`; not needed for a pre-built binary')
  end
end

local function check_service()
  vim.health.start('Go service')
  local ok, ca = pcall(require, 'copilot_agent')
  if not ok then
    vim.health.error('copilot_agent module failed to load: ' .. tostring(ca))
    return
  end

  local config = ok and ca.state and ca.state.config
  if not config then
    vim.health.warn('Plugin not yet set up — call require("copilot_agent").setup()')
    return
  end

  -- Service command
  local cmd = config.service and config.service.command
  if type(cmd) == 'function' then
    cmd = cmd()
  end
  if type(cmd) == 'table' and #cmd > 0 then
    local exe = cmd[1]
    if vim.fn.executable(exe) == 1 then
      vim.health.ok('service command executable: `' .. table.concat(cmd, ' ') .. '`')
    else
      vim.health.error('service command not executable: `' .. exe .. '`')
    end
  elseif type(cmd) == 'string' and cmd ~= '' then
    vim.health.ok('service command: `' .. cmd .. '`')
  else
    vim.health.warn('service.command is empty — auto_start will not work')
  end

  -- Service cwd
  local function plugin_root()
    local source = debug.getinfo(1, 'S').source
    if type(source) ~= 'string' or source == '' then
      return nil
    end
    local path = source:gsub('^@', '')
    -- health.lua is at lua/copilot_agent/health.lua → go up 3 levels
    return vim.fn.fnamemodify(path, ':p:h:h:h')
  end
  local cwd = config.service and config.service.cwd
  if type(cwd) == 'function' then
    cwd = cwd()
  end
  if cwd == nil or cwd == '' then
    local root = plugin_root()
    cwd = root and (root .. '/server') or nil
  end
  if cwd and vim.fn.isdirectory(cwd) == 1 then
    vim.health.ok('service cwd exists: ' .. cwd)
    -- Check go.mod inside server/
    local gomod = cwd .. '/go.mod'
    if vim.fn.filereadable(gomod) == 1 then
      vim.health.ok('go.mod found in service cwd')
    else
      vim.health.warn('go.mod not found in ' .. cwd .. ' — `go run .` will fail')
    end
  else
    vim.health.error('service cwd not found: ' .. tostring(cwd))
  end

  -- HTTP reachability (only meaningful if a session has already been started)
  local base_url = config.base_url or 'http://127.0.0.1:8088'
  -- If base_url is still the default and auto_start is true, the port may be
  -- dynamic and not yet known — skip the reachability check in that case.
  local is_default_url = base_url == 'http://127.0.0.1:8088'
  local auto = config.service and config.service.auto_start
  if is_default_url and auto then
    vim.health.info('service port is dynamic (auto_start=true) — reachability checked after first :CopilotAgentChat')
  else
    local healthz = base_url:gsub('/$', '') .. (config.service and config.service.healthcheck_path or '/healthz')
    vim.fn.system({ 'curl', '-sf', '--max-time', '2', healthz })
    local code = vim.v.shell_error
    if code == 0 then
      vim.health.ok('service reachable at ' .. healthz)
    else
      if auto then
        vim.health.warn('service not reachable at ' .. healthz .. ' (will be started automatically)')
      else
        vim.health.warn('service not reachable at ' .. healthz .. ' — start it manually or set service.auto_start = true')
      end
    end
  end
end

local function check_session()
  vim.health.start('Active session')
  local ok, ca = pcall(require, 'copilot_agent')
  if not ok then
    return
  end
  local session_id = ca.state and ca.state.session_id
  if session_id then
    vim.health.ok('session connected: ' .. session_id)
    local model = ca.state.config and ca.state.config.session and ca.state.config.session.model
    if model then
      vim.health.ok('model: ' .. model)
    else
      vim.health.info('model: (using server default)')
    end
  else
    vim.health.info('no active session — open the chat with :CopilotAgentChat')
  end
end

local function check_optional_deps()
  vim.health.start('Optional dependencies')

  -- render-markdown.nvim
  if pcall(require, 'render-markdown') then
    vim.health.ok('render-markdown.nvim found — markdown rendering enabled in chat buffer')
  else
    vim.health.info('render-markdown.nvim not found — install it for richer markdown in the chat buffer')
  end

  -- copilot.lua (for virtual-text suggestions in input buffer)
  if pcall(require, 'copilot.client') then
    vim.health.ok('copilot.lua found — virtual-text suggestions enabled in input buffer')
  else
    vim.health.info('copilot.lua not found — install it to get inline suggestions in the input buffer')
  end

  -- nvim-treesitter
  if pcall(require, 'nvim-treesitter') then
    vim.health.ok('nvim-treesitter found')
  else
    vim.health.info('nvim-treesitter not found — install it for syntax highlighting in the chat buffer')
  end
end

function M.check()
  check_neovim_version()
  check_curl()
  check_go()
  check_service()
  check_session()
  check_optional_deps()
end

return M
