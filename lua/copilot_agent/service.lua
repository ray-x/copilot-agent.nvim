-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Service lifecycle: binary detection, auto-start, health polling.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local state = cfg.state
local defaults = cfg.defaults

local M = {}

local _root_markers = { '.git', 'go.mod', 'package.json', 'Cargo.toml', 'pyproject.toml', '.hg', '.svn' }

local function find_project_root(start_dir)
  local home = vim.fn.expand('$HOME')
  local dir = start_dir
  while dir ~= home do
    for _, marker in ipairs(_root_markers) do
      if uv.fs_stat(dir .. '/' .. marker) then
        return dir
      end
    end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

function M.cwd()
  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path and buf_path ~= '' then
    local buf_dir = vim.fn.fnamemodify(buf_path, ':p:h')
    return find_project_root(buf_dir) or buf_dir
  end
  return (uv and uv.cwd and uv.cwd()) or vim.fn.getcwd()
end

function M.working_directory()
  local value = state.config.session.working_directory
  if type(value) == 'function' then
    value = value()
  end
  if value == nil or value == '' then
    value = M.cwd()
  end
  return value
end

function M.plugin_root()
  local source = debug.getinfo(1, 'S').source
  if type(source) ~= 'string' or source == '' then
    return M.cwd()
  end
  local path = source:gsub('^@', '')
  return vim.fn.fnamemodify(path, ':p:h:h:h')
end

function M.service_cwd()
  local value = state.config.service.cwd
  if type(value) == 'function' then
    value = value()
  end
  if value == nil or value == '' then
    value = M.plugin_root() .. '/server'
  end
  return value
end

function M.installed_binary_path()
  local uname = vim.uv.os_uname()
  local ext = uname.sysname:find('Windows') and '.exe' or ''
  local root = M.plugin_root()
  local candidates = {
    root .. '/bin/copilot-agent' .. ext,
    root .. '/server/copilot-agent' .. ext,
  }
  for _, p in ipairs(candidates) do
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  return candidates[1]
end

function M.service_command()
  local value = state.config.service.command
  if type(value) == 'function' then
    value = value()
  end
  if value == nil then
    local bin = M.installed_binary_path()
    if vim.fn.executable(bin) == 1 then
      value = { bin }
    else
      value = { 'go', 'run', '.' }
    end
  end
  local pr = state.config.service.port_range
  if pr and pr ~= '' and type(value) == 'table' then
    local has_addr = false
    for _, arg in ipairs(value) do
      if arg == '--addr' or arg == '-addr' then
        has_addr = true
        break
      end
    end
    if not has_addr then
      value = vim.list_extend(vim.deepcopy(value), { '--port-range', pr })
    end
  end
  return value
end

-- Path where the bound service address is persisted across Neovim sessions.
local function addr_state_file()
  return vim.fn.stdpath('state') .. '/copilot-agent.addr'
end

local function addr_lock_dir()
  return vim.fn.stdpath('state') .. '/copilot-agent.addr.lock'
end

local function addr_lock_owner_file()
  return addr_lock_dir() .. '/owner'
end

local function now_ms()
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1e6)
  end
  return os.time() * 1000
end

local function interval_settings()
  local timeout_ms = tonumber(state.config.service.startup_timeout_ms) or defaults.service.startup_timeout_ms
  local interval_ms = tonumber(state.config.service.startup_poll_interval_ms) or defaults.service.startup_poll_interval_ms
  return timeout_ms, interval_ms
end

local function write_text_file(path, content)
  local ok, err = pcall(function()
    local f = assert(io.open(path, 'w'))
    f:write(content)
    f:close()
  end)
  if ok then
    return true
  end
  return nil, err
end

local function read_first_line(path)
  local ok, data = pcall(function()
    local f = io.open(path, 'r')
    if not f then
      return nil
    end
    local v = f:read('*l')
    f:close()
    return v
  end)
  return ok and data or nil
end

local function lock_started_at_ms()
  local line = read_first_line(addr_lock_owner_file())
  if line and line:find('^%d+$') then
    return tonumber(line)
  end
  local stat = uv.fs_stat(addr_lock_dir())
  if not stat or not stat.mtime then
    return nil
  end
  if type(stat.mtime) == 'number' then
    return math.floor(stat.mtime * 1000)
  end
  if type(stat.mtime) == 'table' then
    local sec = stat.mtime.sec or stat.mtime.tv_sec or stat.mtime[1] or 0
    local nsec = stat.mtime.nsec or stat.mtime.tv_nsec or stat.mtime[2] or 0
    return (sec * 1000) + math.floor(nsec / 1e6)
  end
  return nil
end

local function save_service_addr(addr)
  write_text_file(addr_state_file(), addr)
end

local function load_service_addr()
  return read_first_line(addr_state_file())
end

local function refresh_service_addr_from_state()
  if state.base_url_managed == false then
    return false
  end
  local saved_addr = load_service_addr()
  if saved_addr and saved_addr ~= '' then
    state.config.base_url = 'http://' .. saved_addr
    return true
  end
  return false
end

local function release_spawn_lock()
  pcall(uv.fs_unlink, addr_lock_owner_file())
  pcall(uv.fs_rmdir, addr_lock_dir())
end

local function try_acquire_spawn_lock(stale_after_ms)
  local ok, err = uv.fs_mkdir(addr_lock_dir(), 448)
  if ok then
    local write_ok, write_err = write_text_file(addr_lock_owner_file(), string.format('%d\n%d\n', now_ms(), vim.fn.getpid()))
    if not write_ok then
      release_spawn_lock()
      return nil, 'failed to write service lock metadata: ' .. tostring(write_err)
    end
    return true
  end

  local message = tostring(err or '')
  if not message:find('EEXIST', 1, true) then
    return nil, 'failed to create service lock: ' .. message
  end

  local started_at_ms = lock_started_at_ms()
  if started_at_ms and (now_ms() - started_at_ms) > stale_after_ms then
    release_spawn_lock()
    ok, err = uv.fs_mkdir(addr_lock_dir(), 448)
    if ok then
      local write_ok, write_err = write_text_file(addr_lock_owner_file(), string.format('%d\n%d\n', now_ms(), vim.fn.getpid()))
      if not write_ok then
        release_spawn_lock()
        return nil, 'failed to write service lock metadata: ' .. tostring(write_err)
      end
      return true
    end
    message = tostring(err or '')
    if not message:find('EEXIST', 1, true) then
      return nil, 'failed to create service lock: ' .. message
    end
  end

  return false
end

local function lock_wait_delay_ms(interval_ms)
  local base = math.max(25, math.floor(interval_ms / 2))
  local span = math.max(25, interval_ms)
  local entropy = ((uv and uv.hrtime and uv.hrtime()) or 0) + (vim.fn.getpid() * 131)
  return base + (entropy % span)
end

function M.remember_service_output(data)
  if not data then
    return
  end
  for _, line in ipairs(data) do
    if line and line ~= '' then
      local addr = line:match('^COPILOT_AGENT_ADDR=(.+)$')
      if addr then
        state.config.base_url = 'http://' .. addr
        state.service_addr_known = true
        save_service_addr(addr)
      end
      table.insert(state.service_output, line)
    end
  end
  while #state.service_output > 20 do
    table.remove(state.service_output, 1)
  end
end

function M.last_service_output()
  return state.service_output[#state.service_output]
end

local function check_service_health(callback)
  refresh_service_addr_from_state()
  local http = require('copilot_agent.http')
  http.raw_request('GET', state.config.service.healthcheck_path, nil, function(_, err, status)
    callback(err == nil and status and status < 400, err, status)
  end)
end

function M.ensure_service_live(callback)
  if type(callback) ~= 'function' then
    return
  end

  check_service_health(function(healthy, err, status)
    if healthy then
      callback(nil)
      return
    end

    if state.config.service.auto_start ~= true then
      local message = err
      if not message then
        message = 'service health check failed'
        if status then
          message = message .. ' with status ' .. tostring(status)
        end
      end
      callback(message)
      return
    end

    M.ensure_service_running(callback)
  end)
end

function M.ensure_service_running(callback)
  if type(callback) ~= 'function' then
    return
  end

  if state.config.service.auto_start ~= true then
    callback('service auto_start is disabled')
    return
  end

  table.insert(state.pending_service_callbacks, callback)
  if state.service_starting then
    return
  end

  local timeout_ms, interval_ms = interval_settings()
  local deadline_ms = now_ms() + timeout_ms
  local spawn_lock_owned = false

  local function finish(err)
    if spawn_lock_owned then
      release_spawn_lock()
      spawn_lock_owned = false
    end
    state.service_starting = false
    local callbacks = state.pending_service_callbacks
    state.pending_service_callbacks = {}
    for _, pending in ipairs(callbacks) do
      pending(err)
    end
  end

  local function poll_service_health(attempts_left)
    check_service_health(function(healthy)
      if healthy then
        finish(nil)
        return
      end
      if attempts_left <= 0 then
        local message = 'timed out waiting for service health check'
        local output = M.last_service_output()
        if output then
          message = message .. ': ' .. output
        end
        finish(message)
        return
      end
      vim.defer_fn(function()
        poll_service_health(attempts_left - 1)
      end, interval_ms)
    end)
  end

  local function start_service_with_lock()
    check_service_health(function(healthy)
      if healthy then
        finish(nil)
        return
      end

      if state.service_job_id then
        local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
        poll_service_health(attempts)
        return
      end

      local command = M.service_command()
      if command == nil or command == '' or (type(command) == 'table' and vim.tbl_isempty(command)) then
        finish('service.command is empty')
        return
      end

      -- Lazy-require append_entry to avoid circular dependency with render.
      local function append_entry(kind, content)
        local init = require('copilot_agent')
        if init._append_entry then
          init._append_entry(kind, content)
        end
      end

      local service_job_id = vim.fn.jobstart(command, {
        cwd = M.service_cwd(),
        env = state.config.service.env,
        detach = state.config.service.detach and 1 or 0,
        stdout_buffered = false,
        stderr_buffered = false,
        on_stdout = function(_, data)
          M.remember_service_output(data)
        end,
        on_stderr = function(_, data)
          M.remember_service_output(data)
        end,
        on_exit = function(job_id, code)
          vim.schedule(function()
            if state.service_job_id == job_id then
              state.service_job_id = nil
            end
            if state.service_starting then
              local message = 'service exited before becoming ready with code ' .. tostring(code)
              local output = M.last_service_output()
              if output then
                message = message .. ': ' .. output
              end
              finish(message)
              return
            end
            if code ~= 0 then
              local message = 'Service exited with code ' .. tostring(code)
              local output = M.last_service_output()
              if output then
                message = message .. ': ' .. output
              end
              append_entry('error', message)
            end
          end)
        end,
      })
      if service_job_id <= 0 then
        finish('failed to start service command: ' .. vim.inspect(command))
        return
      end

      state.service_job_id = service_job_id
      append_entry('system', 'Starting service: ' .. (type(command) == 'table' and table.concat(command, ' ') or command))

      local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
      poll_service_health(attempts)
    end)
  end

  local function wait_for_service_start()
    check_service_health(function(healthy)
      if healthy then
        finish(nil)
        return
      end

      local acquired, acquire_err = try_acquire_spawn_lock(timeout_ms)
      if acquire_err then
        finish(acquire_err)
        return
      end
      if acquired then
        spawn_lock_owned = true
        start_service_with_lock()
        return
      end

      if now_ms() >= deadline_ms then
        finish('timed out waiting for another Neovim instance to start the service')
        return
      end

      vim.defer_fn(wait_for_service_start, lock_wait_delay_ms(interval_ms))
    end)
  end

  state.service_starting = true
  state.service_output = {}
  state.service_addr_known = false

  refresh_service_addr_from_state()

  check_service_health(function(healthy)
    if healthy then
      finish(nil)
      return
    end

    if state.service_job_id then
      local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
      poll_service_health(attempts)
      return
    end
    local acquired, acquire_err = try_acquire_spawn_lock(timeout_ms)
    if acquire_err then
      finish(acquire_err)
      return
    end
    if acquired then
      spawn_lock_owned = true
      start_service_with_lock()
      return
    end
    wait_for_service_start()
  end)
end

M._save_service_addr = save_service_addr
M._load_service_addr = load_service_addr
M._refresh_service_addr_from_state = refresh_service_addr_from_state
M._try_acquire_spawn_lock = try_acquire_spawn_lock
M._release_spawn_lock = release_spawn_lock
M._addr_lock_dir = addr_lock_dir

return M
