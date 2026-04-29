-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local render = require('copilot_agent.render')
local session_names = require('copilot_agent.session_names')
local sl = require('copilot_agent.statusline')

local state = cfg.state
local notify = cfg.notify
local append_entry = render.append_entry
local refresh_statuslines = sl.refresh_statuslines

local M = {}

local function parse(text)
  if type(text) ~= 'string' then
    return nil
  end

  local command, args = vim.trim(text):match('^/([%w%-]+)%s*(.*)$')
  if not command then
    return nil
  end
  return command:lower(), vim.trim(args or '')
end

local function rename_session(args)
  if not state.session_id then
    notify('No active session to rename', vim.log.levels.WARN)
    return true
  end

  local default_name = session_names.get(state.session_id) or state.session_name or ''
  local function apply_name(name)
    name = vim.trim(name or '')
    if name == '' then
      return
    end

    local ok, err = session_names.set(state.session_id, name)
    if not ok then
      append_entry('error', 'Failed to rename session: ' .. tostring(err))
      return
    end

    state.session_name = name
    refresh_statuslines()
    append_entry('system', 'Session renamed to ' .. name)
  end

  if args ~= '' then
    apply_name(args)
    return true
  end

  vim.ui.input({ prompt = 'Rename session: ', default = default_name }, function(input)
    apply_name(input)
  end)
  return true
end

local handlers = {
  rename = rename_session,
}

function M.execute(text, opts)
  local command, args = parse(text)
  if not command then
    return false
  end

  local handler = handlers[command]
  if not handler then
    return false
  end
  return handler(args, opts or {}) == true
end

return M
