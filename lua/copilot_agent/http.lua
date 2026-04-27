-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Pure HTTP / JSON helpers. No session or service logic.

local cfg = require('copilot_agent.config')
local utils = require('copilot_agent.utils')
local state = cfg.state
local notify = cfg.notify
local normalize_base_url = cfg.normalize_base_url
local is_connection_error = utils.is_connection_error

local M = {}

function M.build_url(path)
  return normalize_base_url(state.config.base_url) .. path
end

function M.ensure_curl()
  if vim.fn.executable(state.config.curl_bin) == 1 then
    return true
  end
  notify('curl executable not found: ' .. state.config.curl_bin, vim.log.levels.ERROR)
  return false
end

function M.decode_json(raw)
  if raw == nil or raw == '' then
    return nil
  end

  local decoder
  if vim.json and type(vim.json.decode) == 'function' then
    decoder = vim.json.decode
  elseif type(vim.fn.json_decode) == 'function' then
    decoder = vim.fn.json_decode
  else
    return nil, 'no JSON decoder available in this Neovim version'
  end

  local ok, decoded = pcall(decoder, raw)
  if ok then
    return decoded
  end
  return nil, decoded
end

function M.encode_json(value)
  local encoder
  if vim.json and type(vim.json.encode) == 'function' then
    encoder = vim.json.encode
  elseif type(vim.fn.json_encode) == 'function' then
    encoder = vim.fn.json_encode
  else
    error('no JSON encoder available in this Neovim version')
  end

  return encoder(value)
end

-- Synchronous HTTP request via vim.system / vim.fn.system.
function M.sync_request(method, path, body)
  if not M.ensure_curl() then
    return nil, 'curl executable not found: ' .. state.config.curl_bin
  end

  local args = {
    state.config.curl_bin,
    '-sS',
    '-o',
    '-',
    '-w',
    '\n%{http_code}',
    '-X',
    method,
    M.build_url(path),
    '-H',
    'Accept: application/json',
  }

  if body ~= nil then
    table.insert(args, '-H')
    table.insert(args, 'Content-Type: application/json')
    table.insert(args, '--data-raw')
    table.insert(args, M.encode_json(body))
  end

  if vim.system then
    local result = vim.system(args, { text = true }):wait()
    local raw_stdout = result.stdout or ''
    local response_body, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
    local status = tonumber(status_text)
    if not response_body then
      response_body = raw_stdout
    end

    if result.code ~= 0 and (status == nil or status < 400) then
      local message = (result.stderr and vim.trim(result.stderr) ~= '' and result.stderr) or response_body
      return nil, vim.trim(message), status
    end

    local payload, decode_err = M.decode_json(response_body)
    if status and status >= 400 then
      local message = decode_err or response_body
      if type(payload) == 'table' and type(payload.error) == 'string' then
        message = payload.error
      end
      return nil, message, status
    end

    return payload, nil, status
  end

  local raw_stdout = vim.fn.system(args)
  local code = vim.v.shell_error
  local response_body, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
  local status = tonumber(status_text)
  if not response_body then
    response_body = raw_stdout
  end

  if code ~= 0 and (status == nil or status < 400) then
    return nil, vim.trim(response_body), status
  end

  local payload, decode_err = M.decode_json(response_body)
  if status and status >= 400 then
    local message = decode_err or response_body
    if type(payload) == 'table' and type(payload.error) == 'string' then
      message = payload.error
    end
    return nil, message, status
  end

  return payload, nil, status
end

-- Async HTTP request via vim.fn.jobstart.
function M.raw_request(method, path, body, callback)
  if not M.ensure_curl() then
    callback(nil, 'curl executable not found: ' .. state.config.curl_bin)
    return
  end

  local stdout = {}
  local stderr = {}
  local args = {
    state.config.curl_bin,
    '-sS',
    '-o',
    '-',
    '-w',
    '\n%{http_code}',
    '-X',
    method,
    M.build_url(path),
    '-H',
    'Accept: application/json',
  }

  if body ~= nil then
    table.insert(args, '-H')
    table.insert(args, 'Content-Type: application/json')
    table.insert(args, '--data-raw')
    table.insert(args, M.encode_json(body))
  end

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local raw_stdout = table.concat(stdout, '\n')
        local response_body, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
        local status = tonumber(status_text)
        if not response_body then
          response_body = raw_stdout
        end

        local stderr_text = table.concat(stderr, '\n')
        if code ~= 0 and (status == nil or status < 400) then
          callback(nil, stderr_text ~= '' and stderr_text or response_body, status)
          return
        end

        local payload, decode_err = M.decode_json(response_body)
        if status and status >= 400 then
          local message = decode_err or response_body
          if type(payload) == 'table' and type(payload.error) == 'string' then
            message = payload.error
          end
          callback(nil, message, status)
          return
        end

        callback(payload, nil, status)
      end)
    end,
  })
  if job_id <= 0 then
    vim.schedule(function()
      callback(nil, 'failed to start curl job for ' .. method .. ' ' .. path)
    end)
  end
end

-- Async HTTP request with auto-start: retries via ensure_service_running on
-- connection errors. The ensure_service_running dependency is resolved lazily
-- to avoid circular requires between http and service modules.
function M.request(method, path, body, callback, opts)
  opts = opts or {}
  M.raw_request(method, path, body, function(payload, err, status)
    if err and opts.auto_start ~= false and is_connection_error(err) then
      -- Lazy-require to break http↔service circular dependency.
      local service = require('copilot_agent.service')
      service.ensure_service_running(function(start_err)
        if start_err then
          callback(nil, err .. '\n' .. start_err, status)
          return
        end
        M.raw_request(method, path, body, callback)
      end)
      return
    end
    callback(payload, err, status)
  end)
end

return M
