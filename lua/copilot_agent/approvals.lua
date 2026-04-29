-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')

local state = cfg.state

local M = {}

local function ensure_tables()
  state.allowed_directories = state.allowed_directories or {}
  state.allowed_tools = state.allowed_tools or {}
end

local function normalize_path(path)
  path = vim.trim(path or '')
  if path == '' then
    return nil
  end

  local normalized = path
  if vim.fs and type(vim.fs.normalize) == 'function' then
    normalized = vim.fs.normalize(path)
  else
    normalized = vim.fn.fnamemodify(path, ':p')
  end
  normalized = normalized:gsub('\\', '/')
  if normalized ~= '/' then
    normalized = normalized:gsub('/+$', '')
  end
  if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    normalized = normalized:lower()
  end
  return normalized
end

local function contains(items, value)
  for _, item in ipairs(items or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function shell_tool_name(permission)
  local command = permission.command
  if type(command) == 'table' and type(command[1]) == 'string' and command[1] ~= '' then
    return vim.fn.fnamemodify(command[1], ':t')
  end

  local full = permission.fullCommandText or permission.intention or ''
  local token = full:match('^%s*([%w%._%-%+/\\:]+)')
  if token and token ~= '' then
    return vim.fn.fnamemodify(token, ':t')
  end
  return nil
end

function M.reset()
  state.allowed_directories = {}
  state.allowed_tools = {}
end

function M.normalize_directory(path)
  return normalize_path(path)
end

function M.add_directory(path)
  ensure_tables()
  local normalized = normalize_path(path)
  if not normalized then
    return nil, 'directory is required'
  end
  if not contains(state.allowed_directories, normalized) then
    state.allowed_directories[#state.allowed_directories + 1] = normalized
  end
  return normalized
end

function M.list_directories()
  ensure_tables()
  return vim.deepcopy(state.allowed_directories)
end

function M.directory_allowed(path)
  ensure_tables()
  local candidate = normalize_path(path)
  if not candidate then
    return false
  end
  for _, root in ipairs(state.allowed_directories) do
    if candidate == root or vim.startswith(candidate, root .. '/') then
      return true
    end
  end
  return false
end

function M.tool_key(permission)
  permission = permission or {}
  local kind = permission.kind or ''
  if kind == 'shell' then
    local name = shell_tool_name(permission)
    return name and name:lower() or nil
  end

  local tool_name = permission.toolName or permission.toolTitle
  if type(tool_name) ~= 'string' or tool_name == '' then
    return nil
  end
  local server = vim.trim(permission.serverName or ''):lower()
  local name = vim.trim(tool_name):lower()
  if server ~= '' then
    return server .. ':' .. name
  end
  return name
end

function M.tool_label(permission)
  permission = permission or {}
  local kind = permission.kind or ''
  if kind == 'shell' then
    return shell_tool_name(permission)
  end

  local tool_name = permission.toolTitle or permission.toolName
  if type(tool_name) ~= 'string' or tool_name == '' then
    return nil
  end
  local server = vim.trim(permission.serverName or '')
  if server ~= '' then
    return server .. '/' .. tool_name
  end
  return tool_name
end

function M.allow_tool(permission)
  ensure_tables()
  local key = M.tool_key(permission)
  if not key then
    return nil, 'tool is not allow-listable'
  end
  if not contains(state.allowed_tools, key) then
    state.allowed_tools[#state.allowed_tools + 1] = key
  end
  return key
end

function M.list_tools()
  ensure_tables()
  return vim.deepcopy(state.allowed_tools)
end

function M.reset_tools()
  ensure_tables()
  local count = #state.allowed_tools
  state.allowed_tools = {}
  return count
end

function M.tool_allowed(permission)
  ensure_tables()
  local key = M.tool_key(permission)
  return key ~= nil and contains(state.allowed_tools, key)
end

return M
