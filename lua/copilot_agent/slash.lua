-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local chat = require('copilot_agent.chat')
local render = require('copilot_agent.render')
local session_names = require('copilot_agent.session_names')
local sl = require('copilot_agent.statusline')

local state = cfg.state
local notify = cfg.notify
local append_entry = render.append_entry
local refresh_statuslines = sl.refresh_statuslines

local M = {}
local search_label_max_len = 72

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

local function truncate_label(text)
  if #text <= search_label_max_len then
    return text
  end
  return text:sub(1, search_label_max_len - 1) .. '…'
end

local function jump_to_line(line)
  require('copilot_agent').open_chat({ activate_input_on_session_ready = false })
  local winid = chat.find_chat_window()
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd('normal! zz')
  end)
end

local function run_search(query)
  query = vim.trim(query or '')
  if query == '' then
    return
  end
  if vim.tbl_isempty(state.entries) then
    notify('No transcript entries to search', vim.log.levels.INFO)
    return
  end

  local needle = query:lower()
  local matches = {}
  local line_cursor = 1

  for idx, entry in ipairs(state.entries) do
    local lines = render.entry_lines(entry, idx, false)
    for offset, line in ipairs(lines) do
      if line:lower():find(needle, 1, true) then
        local kind = (entry.kind or 'entry'):gsub('^%l', string.upper)
        local text = vim.trim(line)
        matches[#matches + 1] = {
          line = line_cursor + offset - 1,
          label = string.format('%s: %s', kind, truncate_label(text ~= '' and text or line)),
        }
      end
    end
    line_cursor = line_cursor + #lines
  end

  if vim.tbl_isempty(matches) then
    notify('No transcript matches for "' .. query .. '"', vim.log.levels.INFO)
    return
  end

  vim.ui.select(matches, {
    prompt = string.format('Search transcript (%d matches)', #matches),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      jump_to_line(choice.line)
    end
  end)
end

local function search_transcript(args)
  if args ~= '' then
    run_search(args)
    return true
  end

  vim.ui.input({ prompt = 'Search transcript: ' }, function(input)
    run_search(input)
  end)
  return true
end

local handlers = {
  rename = rename_session,
  search = search_transcript,
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
