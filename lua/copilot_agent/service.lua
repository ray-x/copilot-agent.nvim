-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Service lifecycle: binary detection, auto-start, health polling.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local state = cfg.state
local defaults = cfg.defaults

local M = {}

function M.cwd()
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

  -- Lazy-require to break circular dependency with render/init.
  local http = require('copilot_agent.http')

  local function finish(err)
    state.service_starting = false
    local callbacks = state.pending_service_callbacks
    state.pending_service_callbacks = {}
    for _, pending in ipairs(callbacks) do
      pending(err)
    end
  end

  local function poll_service_health(attempts_left)
    if state.service_addr_known then
      finish(nil)
      return
    end
    http.raw_request('GET', state.config.service.healthcheck_path, nil, function(_, err, status)
      if err == nil and status and status < 400 then
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
      end, state.config.service.startup_poll_interval_ms)
    end)
  end

  state.service_starting = true
  state.service_output = {}
  state.service_addr_known = false

  http.raw_request('GET', state.config.service.healthcheck_path, nil, function(_, health_err, status)
    if health_err == nil and status and status < 400 then
      finish(nil)
      return
    end

    if state.service_job_id then
      local timeout_ms = tonumber(state.config.service.startup_timeout_ms) or defaults.service.startup_timeout_ms
      local interval_ms = tonumber(state.config.service.startup_poll_interval_ms) or defaults.service.startup_poll_interval_ms
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

    local timeout_ms = tonumber(state.config.service.startup_timeout_ms) or defaults.service.startup_timeout_ms
    local interval_ms = tonumber(state.config.service.startup_poll_interval_ms) or defaults.service.startup_poll_interval_ms
    local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
    poll_service_health(attempts)
  end)
end

return M
