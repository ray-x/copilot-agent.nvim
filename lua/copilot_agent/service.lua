-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Service lifecycle: binary detection, auto-start, health polling.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local state = cfg.state
local defaults = cfg.defaults
local normalize_base_url = cfg.normalize_base_url

local M = {}
local NANOSECONDS_PER_MILLISECOND = 1e6 -- uv.hrtime() and libuv timespec values are reported in nanoseconds.
local LOCK_DIRECTORY_MODE = 448 -- Decimal 0700: keep the spawn-lock directory private to the current user.
local LOCK_WAIT_MIN_DELAY_MS = 25 -- Avoid busy-waiting when another Neovim instance is already starting the service.
local LOCK_WAIT_PID_ENTROPY_PRIME = 131 -- Mix in a small prime so different PIDs spread their retry jitter more evenly.
local SERVICE_OUTPUT_HISTORY_LIMIT = 20 -- Keep only the most recent startup lines for diagnostics without unbounded memory growth.
local CONTROL_REQUEST_TIMEOUT_SECONDS = '2' -- Bound local control-socket curl calls so stale sockets cannot hang startup or exit indefinitely.
local SAVED_ADDR_PROBE_TIMEOUT_SECONDS = '1' -- Quick probe timeout when validating persisted service addresses.

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

local function is_windows()
  local uname = uv.os_uname()
  return type(uname) == 'table' and type(uname.sysname) == 'string' and uname.sysname:find('Windows', 1, true) ~= nil
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
  if type(value) == 'table' then
    local has_control_socket = false
    local has_control_addr = false
    for _, arg in ipairs(value) do
      if arg == '--control-socket' or arg == '-control-socket' then
        has_control_socket = true
      elseif arg == '--control-addr' or arg == '-control-addr' then
        has_control_addr = true
      end
      if has_control_socket or has_control_addr then
        break
      end
    end
    if not has_control_socket and not has_control_addr then
      if is_windows() then
        value = vim.list_extend(vim.deepcopy(value), { '--control-addr', '127.0.0.1:0' })
      else
        value = vim.list_extend(vim.deepcopy(value), { '--control-socket', vim.fn.stdpath('state') .. '/copilot-agent.sock' })
      end
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

local function control_socket_file()
  return vim.fn.stdpath('state') .. '/copilot-agent.sock'
end

local function control_addr_file()
  return vim.fn.stdpath('state') .. '/copilot-agent.control-addr'
end

local function addr_lock_dir()
  return vim.fn.stdpath('state') .. '/copilot-agent.addr.lock'
end

local function addr_lock_owner_file()
  return addr_lock_dir() .. '/owner'
end

local refresh_service_addr_from_state

local function json_encode(value)
  if vim.json and type(vim.json.encode) == 'function' then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function json_decode(raw)
  if vim.json and type(vim.json.decode) == 'function' then
    return vim.json.decode(raw)
  end
  return vim.fn.json_decode(raw)
end

local function append_json_request_body(args, body)
  if body == nil then
    return
  end
  table.insert(args, '-H')
  table.insert(args, 'Content-Type: application/json')
  table.insert(args, '--data-raw')
  table.insert(args, json_encode(body))
end

local build_http_request_args
local write_text_file
local read_first_line
local load_service_pid
local signal_service_pid

local function save_control_addr(addr)
  if type(addr) ~= 'string' or addr == '' then
    return
  end
  write_text_file(control_addr_file(), addr)
end

local function load_control_addr()
  return read_first_line(control_addr_file())
end

local function clear_control_addr()
  pcall(uv.fs_unlink, control_addr_file())
end

local function control_endpoint()
  if is_windows() then
    local addr = load_control_addr()
    if type(addr) == 'string' and addr ~= '' then
      return { kind = 'tcp', addr = addr }
    end
    return nil
  end

  if vim.fn.filereadable(control_socket_file()) == 1 then
    return { kind = 'unix', socket = control_socket_file() }
  end
  return nil
end

local function build_control_request_args(endpoint, method, path, body, opts)
  opts = opts or {}
  if type(endpoint) ~= 'table' then
    return nil
  end
  if endpoint.kind == 'tcp' then
    return build_http_request_args(method, path, body, vim.tbl_extend('force', opts, { base_url = 'http://' .. endpoint.addr }))
  end
  local args = {
    state.config.curl_bin,
    '-sS',
    '--connect-timeout',
    tostring(opts.connect_timeout or CONTROL_REQUEST_TIMEOUT_SECONDS),
    '--max-time',
    tostring(opts.max_time or CONTROL_REQUEST_TIMEOUT_SECONDS),
    '--unix-socket',
    endpoint.socket or control_socket_file(),
    '-X',
    method,
    'http://localhost' .. path,
    '-H',
    'Accept: application/json',
  }

  if opts.capture_response ~= false then
    table.insert(args, 5, '-o')
    table.insert(args, 6, '-')
    table.insert(args, 7, '-w')
    table.insert(args, 8, '\n%{http_code}')
  end
  append_json_request_body(args, body)
  return args
end

build_http_request_args = function(method, path, body, opts)
  opts = opts or {}
  local base_url = normalize_base_url(opts.base_url or state.config.base_url)
  if type(base_url) ~= 'string' or base_url == '' then
    return nil
  end
  local args = {
    state.config.curl_bin,
    '-sS',
    '--connect-timeout',
    tostring(opts.connect_timeout or CONTROL_REQUEST_TIMEOUT_SECONDS),
    '--max-time',
    tostring(opts.max_time or CONTROL_REQUEST_TIMEOUT_SECONDS),
    '-X',
    method,
    base_url .. path,
    '-H',
    'Accept: application/json',
  }
  append_json_request_body(args, body)
  return args
end

local function spawn_detached_request(args)
  if type(args) ~= 'table' or vim.tbl_isempty(args) then
    return false
  end
  local ok, job_id = pcall(vim.fn.jobstart, args, { detach = 1 })
  return ok and type(job_id) == 'number' and job_id > 0
end

local function control_request_sync(method, path, body)
  local endpoint = control_endpoint()
  if not endpoint then
    return nil, 'control socket unavailable'
  end
  if vim.fn.executable(state.config.curl_bin) ~= 1 then
    return nil, 'curl executable not found: ' .. state.config.curl_bin
  end

  local args = build_control_request_args(endpoint, method, path, body, { capture_response = true })
  if not args then
    return nil, 'control socket unavailable'
  end

  local raw_stdout = vim.fn.system(args)
  local exit_code = tonumber(vim.v.shell_error) or 0
  local stderr_text = raw_stdout

  local response_body, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
  local status = tonumber(status_text)
  if not response_body then
    response_body = raw_stdout
  end

  if exit_code ~= 0 and (status == nil or status < 400) then
    local message = vim.trim(stderr_text ~= '' and stderr_text or response_body)
    return nil, message ~= '' and message or 'control socket request failed', status
  end

  local payload = nil
  if response_body and response_body ~= '' then
    local ok, decoded = pcall(json_decode, response_body)
    if ok then
      payload = decoded
    end
  end

  if status and status >= 400 then
    local message = response_body
    if type(payload) == 'table' and type(payload.error) == 'string' then
      message = payload.error
    end
    return nil, message, status
  end

  return payload, nil, status
end

local function request_shutdown_nonblocking()
  if vim.fn.executable(state.config.curl_bin) ~= 1 then
    return false
  end

  local endpoint = control_endpoint()
  if endpoint then
    local control_args = build_control_request_args(endpoint, 'POST', '/shutdown', {}, { capture_response = false })
    if spawn_detached_request(control_args) then
      return true
    end
  end

  if refresh_service_addr_from_state() then
    local http_args = build_http_request_args('POST', '/shutdown', {}, { capture_response = false })
    if spawn_detached_request(http_args) then
      return true
    end
  end

  local pid = load_service_pid()
  if pid and signal_service_pid(pid, 0) then
    if signal_service_pid(pid, 15) then
      return true
    end
  end

  return false
end

local function refresh_service_addr_from_control()
  if state.base_url_managed == false then
    return false
  end

  local payload, err = control_request_sync('GET', '/service-addr', nil)
  if err or type(payload) ~= 'table' then
    return false
  end

  local addr = payload.serviceAddr
  if type(addr) ~= 'string' or addr == '' then
    return false
  end

  state.config.base_url = 'http://' .. addr
  state.service_addr_known = true
  return true
end

local function client_lease_dir()
  return vim.fn.stdpath('state') .. '/copilot-agent.clients'
end

local function client_lease_file(pid)
  return client_lease_dir() .. '/' .. tostring(pid)
end

local function service_pid_file()
  return vim.fn.stdpath('state') .. '/copilot-agent.pid'
end

local function now_ms()
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / NANOSECONDS_PER_MILLISECOND)
  end
  return os.time() * 1000
end

local function interval_settings()
  local timeout_ms = tonumber(state.config.service.startup_timeout_ms) or defaults.service.startup_timeout_ms
  local interval_ms = tonumber(state.config.service.startup_poll_interval_ms) or defaults.service.startup_poll_interval_ms
  return timeout_ms, interval_ms
end

write_text_file = function(path, content)
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

read_first_line = function(path)
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
    return (sec * 1000) + math.floor(nsec / NANOSECONDS_PER_MILLISECOND)
  end
  return nil
end

local function save_service_addr(addr)
  write_text_file(addr_state_file(), addr)
end

local function load_service_addr()
  return read_first_line(addr_state_file())
end

function M.forget_service_addr()
  pcall(uv.fs_unlink, addr_state_file())
  state.service_addr_known = false
  if state.base_url_managed ~= false then
    state.config.base_url = ''
  else
    state.config.base_url = defaults.base_url
  end
end

local function process_exists(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then
    return false
  end
  if uv and uv.kill then
    return pcall(uv.kill, pid, 0)
  end
  vim.fn.system({ 'kill', '-0', tostring(pid) })
  return vim.v.shell_error == 0
end

load_service_pid = function()
  local line = read_first_line(service_pid_file())
  if line and line:find('^%d+$') then
    return tonumber(line)
  end
  return nil
end

local function save_service_pid(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then
    return
  end
  write_text_file(service_pid_file(), tostring(pid) .. '\n')
end

local function clear_service_pid(expected_pid)
  expected_pid = tonumber(expected_pid)
  if not expected_pid or expected_pid <= 0 then
    return
  end
  local current_pid = load_service_pid()
  if current_pid == expected_pid then
    pcall(uv.fs_unlink, service_pid_file())
  end
end

signal_service_pid = function(pid, signal)
  pid = tonumber(pid)
  if not pid or pid <= 0 or not process_exists(pid) then
    return false
  end
  return pcall(uv.kill, pid, signal or 15)
end

local function saved_addr_healthy(addr)
  if type(addr) ~= 'string' or addr == '' then
    return false
  end
  if vim.fn.executable(state.config.curl_bin) ~= 1 then
    return false
  end

  local args = {
    state.config.curl_bin,
    '-sS',
    '-o',
    '-',
    '-w',
    '\n%{http_code}',
    '--connect-timeout',
    SAVED_ADDR_PROBE_TIMEOUT_SECONDS,
    '--max-time',
    SAVED_ADDR_PROBE_TIMEOUT_SECONDS,
    'http://' .. addr .. state.config.service.healthcheck_path,
  }

  local raw_stdout = vim.fn.system(args)
  local exit_code = tonumber(vim.v.shell_error) or 0

  local _, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
  local status = tonumber(status_text)
  return exit_code == 0 and status and status < 400
end

local function shared_service_pid_alive()
  local pid = load_service_pid()
  if pid and process_exists(pid) then
    local has_control_socket = not is_windows() and vim.fn.filereadable(control_socket_file()) == 1
    local has_control_addr = is_windows() and vim.fn.filereadable(control_addr_file()) == 1
    local saved_addr = load_service_addr()
    local has_saved_addr = saved_addr_healthy(saved_addr)
    if has_control_socket or has_control_addr or has_saved_addr then
      return pid
    end

    -- A live PID without discoverable control/address artifacts is stale for
    -- managed-mode startup; clear it so this instance can spawn a fresh service.
    pcall(uv.fs_unlink, service_pid_file())
    pcall(uv.fs_unlink, addr_state_file())
    clear_control_addr()
    return nil
  end
  if pid then
    pcall(uv.fs_unlink, service_pid_file())
  end
  clear_control_addr()
  return nil
end

local function prune_stale_client_leases()
  local files = vim.fn.glob(client_lease_dir() .. '/*', false, true)
  for _, path in ipairs(files) do
    local pid = tonumber(vim.fn.fnamemodify(path, ':t'))
    if not process_exists(pid) then
      pcall(uv.fs_unlink, path)
    end
  end
end

local function has_live_client_leases()
  prune_stale_client_leases()
  local files = vim.fn.glob(client_lease_dir() .. '/*', false, true)
  return type(files) == 'table' and #files > 0
end

function M.register_client_lease()
  vim.fn.mkdir(client_lease_dir(), 'p')
  write_text_file(client_lease_file(vim.fn.getpid()), string.format('%d\n', now_ms()))
end

function M.unregister_client_lease()
  pcall(uv.fs_unlink, client_lease_file(vim.fn.getpid()))
end

function M.maybe_shutdown_detached_service_if_last_client(opts)
  opts = opts or {}
  if state.config.service.detach ~= true then
    return
  end

  if has_live_client_leases() then
    return
  end

  if opts.nonblocking ~= false then
    if request_shutdown_nonblocking() then
      return
    end
    return
  end

  local _, err = control_request_sync('POST', '/shutdown', {})
  if not err then
    M.forget_service_addr()
    return
  end

  if refresh_service_addr_from_state() then
    local http = require('copilot_agent.http')
    http.raw_request('POST', '/shutdown', {}, function()
      M.forget_service_addr()
    end)
  end
end

refresh_service_addr_from_state = function()
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
  vim.fn.mkdir(vim.fn.fnamemodify(addr_lock_dir(), ':h'), 'p')
  local ok, err = uv.fs_mkdir(addr_lock_dir(), LOCK_DIRECTORY_MODE)
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
    ok, err = uv.fs_mkdir(addr_lock_dir(), LOCK_DIRECTORY_MODE)
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
  local base = math.max(LOCK_WAIT_MIN_DELAY_MS, math.floor(interval_ms / 2))
  local span = math.max(LOCK_WAIT_MIN_DELAY_MS, interval_ms)
  local entropy = ((uv and uv.hrtime and uv.hrtime()) or 0) + (vim.fn.getpid() * LOCK_WAIT_PID_ENTROPY_PRIME)
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
        if state.config.service.detach == true then
          save_service_addr(addr)
        end
      end
      local control_addr = line:match('^COPILOT_AGENT_CONTROL_ADDR=(.+)$')
      if control_addr then
        save_control_addr(control_addr)
      end
      table.insert(state.service_output, line)
    end
  end
  while #state.service_output > SERVICE_OUTPUT_HISTORY_LIMIT do
    table.remove(state.service_output, 1)
  end
end

function M.stop_service()
  if state.service_job_id and state.service_job_id > 0 then
    pcall(vim.fn.jobstop, state.service_job_id)
    state.service_job_id = nil
  end
  if state.config.service.detach ~= true then
    M.forget_service_addr()
    clear_control_addr()
  end
end

function M.last_service_output()
  return state.service_output[#state.service_output]
end

function M.check_service_health(callback)
  local discovered = refresh_service_addr_from_control()
  if not discovered then
    discovered = refresh_service_addr_from_state()
  end
  if state.base_url_managed ~= false and not discovered then
    callback(false, 'service address not discovered yet', nil)
    return
  end
  local http = require('copilot_agent.http')
  http.raw_request('GET', state.config.service.healthcheck_path, nil, function(_, err, status)
    callback(err == nil and status and status < 400, err, status)
  end)
end

function M.ensure_service_live(callback)
  if type(callback) ~= 'function' then
    return
  end

  M.check_service_health(function(healthy, err, status)
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
    M.check_service_health(function(healthy, err, status)
      if healthy then
        callback(nil)
        return
      end
      local message = err
      if not message then
        message = 'service auto_start is disabled'
        if status then
          message = message .. ' with status ' .. tostring(status)
        end
      end
      callback(message)
    end)
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
    M.check_service_health(function(healthy)
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
    M.check_service_health(function(healthy)
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
              if state.service_process_pid then
                clear_service_pid(state.service_process_pid)
              end
              state.service_process_pid = nil
            end
            if state.service_starting then
              M.forget_service_addr()
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
      state.service_process_pid = tonumber(vim.fn.jobpid(service_job_id)) or nil
      if state.service_process_pid then
        save_service_pid(state.service_process_pid)
      end
      append_entry('system', 'Starting service: ' .. (type(command) == 'table' and table.concat(command, ' ') or command))

      local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
      poll_service_health(attempts)
    end)
  end

  local function wait_for_service_start()
    M.check_service_health(function(healthy)
      if healthy then
        finish(nil)
        return
      end

      if shared_service_pid_alive() then
        vim.defer_fn(wait_for_service_start, lock_wait_delay_ms(interval_ms))
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

  M.check_service_health(function(healthy)
    if healthy then
      finish(nil)
      return
    end

    if state.service_job_id then
      local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
      poll_service_health(attempts)
      return
    end
    if shared_service_pid_alive() then
      wait_for_service_start()
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

function M.debug_snapshot()
  local command = M.service_command()
  local command_text = type(command) == 'table' and table.concat(command, ' ') or tostring(command)
  local base_url = normalize_base_url(state.config.base_url)
  local control_socket = control_socket_file()
  local control_addr_path = control_addr_file()
  local addr_file = addr_state_file()
  local lock_path = addr_lock_dir()
  local pid_file = service_pid_file()
  local control_payload, control_err = control_request_sync('GET', '/service-addr', nil)
  local control_health_payload, control_health_err, control_health_status = control_request_sync('GET', '/healthz', nil)
  local saved_addr = load_service_addr()
  local saved_pid = load_service_pid()
  local shared_pid_alive = shared_service_pid_alive()
  local snapshot = {
    managed_mode = state.base_url_managed ~= false,
    auto_start = state.config.service.auto_start == true,
    detach = state.config.service.detach == true,
    base_url = base_url,
    service_addr_known = state.service_addr_known == true,
    service_job_id = state.service_job_id,
    service_process_pid = state.service_process_pid,
    service_starting = state.service_starting == true,
    launch_command = command_text,
    launch_cwd = M.service_cwd(),
    last_service_output = M.last_service_output(),
    control_socket_path = control_socket,
    control_socket_present = vim.fn.filereadable(control_socket) == 1,
    control_addr_path = control_addr_path,
    control_addr_present = vim.fn.filereadable(control_addr_path) == 1,
    control_addr_value = load_control_addr(),
    control_service_addr = type(control_payload) == 'table' and control_payload.serviceAddr or nil,
    control_service_addr_error = control_err,
    control_health_status = control_health_status,
    control_health_error = control_health_err,
    control_health_payload = control_health_payload,
    addr_file_path = addr_file,
    addr_file_present = vim.fn.filereadable(addr_file) == 1,
    addr_file_value = saved_addr,
    pid_file_path = pid_file,
    pid_file_present = vim.fn.filereadable(pid_file) == 1,
    pid_file_value = saved_pid,
    pid_file_alive = saved_pid and process_exists(saved_pid) or false,
    shared_service_pid = shared_pid_alive,
    spawn_lock_path = lock_path,
    spawn_lock_present = uv.fs_stat(lock_path) ~= nil,
    pending_callback_count = #state.pending_service_callbacks,
  }
  return snapshot
end

M._save_service_addr = save_service_addr
M._load_service_addr = load_service_addr
M._save_control_addr = save_control_addr
M._load_control_addr = load_control_addr
M._refresh_service_addr_from_state = refresh_service_addr_from_state
M._try_acquire_spawn_lock = try_acquire_spawn_lock
M._release_spawn_lock = release_spawn_lock
M._addr_lock_dir = addr_lock_dir
M._load_service_pid = load_service_pid
M._save_service_pid = save_service_pid
M._clear_service_pid = clear_service_pid
M._control_addr_file = control_addr_file

return M
