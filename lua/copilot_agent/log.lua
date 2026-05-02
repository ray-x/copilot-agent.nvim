-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local source_path = debug.getinfo(1, 'S').source
local module_path = type(source_path) == 'string' and vim.fn.fnamemodify(source_path:gsub('^@', ''), ':p') or nil
local plugin_root = module_path and vim.fn.fnamemodify(module_path, ':h:h:h') or nil

local M = {}

local _log_levels = {
  DEBUG = vim.log.levels.DEBUG,
  INFO = vim.log.levels.INFO,
  WARN = vim.log.levels.WARN,
  ERROR = vim.log.levels.ERROR,
}

local function current_config()
  return require('copilot_agent.config').state.config
end

function M.log_path()
  return vim.fn.stdpath('log') .. '/copilot_agent.log'
end

local function resolve_file_log_level(value)
  if type(value) == 'number' then
    return value
  end
  if type(value) == 'string' then
    return _log_levels[value:upper()]
  end
  return nil
end

function M.should_log(level)
  local configured_level = resolve_file_log_level(current_config().file_log_level) or vim.log.levels.WARN
  level = level or vim.log.levels.INFO
  return level >= configured_level
end

function M.serialize_log_value(value, opts)
  opts = opts or {}
  local max_len = math.max(32, math.floor(tonumber(opts.max_len) or 1600))
  local inspect_depth = math.max(1, math.floor(tonumber(opts.depth) or 6))
  local text

  if type(value) == 'string' then
    text = value
  else
    local ok, inspected = pcall(vim.inspect, value, {
      depth = inspect_depth,
    })
    text = ok and inspected or tostring(value)
  end

  text = tostring(text):gsub('\r\n?', '\n'):gsub('\n', '\\n'):gsub('\t', '\\t')
  if #text > max_len then
    return text:sub(1, max_len - 1) .. '…'
  end
  return text
end

local function format_log_source(path)
  if type(path) ~= 'string' or path == '' then
    return '<unknown>'
  end
  local absolute = vim.fn.fnamemodify(path:gsub('^@', ''), ':p')
  if plugin_root and vim.startswith(absolute, plugin_root .. '/') then
    return absolute:sub(#plugin_root + 2)
  end
  return vim.fn.fnamemodify(absolute, ':~')
end

local function resolve_log_caller()
  for level = 3, 12 do
    local info = debug.getinfo(level, 'Sln')
    if not info then
      break
    end
    local source = type(info.source) == 'string' and info.source or ''
    if source:sub(1, 1) == '@' then
      local absolute = vim.fn.fnamemodify(source:gsub('^@', ''), ':p')
      if absolute ~= module_path then
        local line = tonumber(info.currentline) or 0
        return string.format('%s:%d', format_log_source(absolute), line)
      end
    elseif type(info.short_src) == 'string' and info.short_src ~= '' then
      local line = tonumber(info.currentline) or 0
      return string.format('%s:%d', info.short_src, line)
    end
  end
  return '<unknown>:0'
end

function M.log(message, level)
  level = level or vim.log.levels.INFO
  if not M.should_log(level) then
    return
  end

  local prefix = ({
    [vim.log.levels.DEBUG] = 'DEBUG',
    [vim.log.levels.INFO] = 'INFO',
    [vim.log.levels.WARN] = 'WARN',
    [vim.log.levels.ERROR] = 'ERROR',
  })[level or vim.log.levels.INFO] or 'INFO'
  local caller = level == vim.log.levels.DEBUG and resolve_log_caller() or nil
  local line
  if caller then
    line = string.format('%s [%s] %s %s\n', os.date('%Y-%m-%d %H:%M:%S'), prefix, caller, tostring(message))
  else
    line = string.format('%s [%s] %s\n', os.date('%Y-%m-%d %H:%M:%S'), prefix, tostring(message))
  end
  pcall(function()
    local path = M.log_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local f = assert(io.open(path, 'a'))
    f:write(line)
    f:close()
  end)
end

function M.notify(message, level)
  M.log(message, level)
  if current_config().notify == false then
    return
  end
  vim.notify('[copilot-agent] ' .. message, level or vim.log.levels.INFO)
end

return M
