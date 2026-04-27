-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Statusline components and window statusline refreshers.

local cfg = require('copilot_agent.config')
local state = cfg.state

local M = {}

function M.statusline_mode()
  return '[' .. (state.input_mode or 'agent') .. ']'
end

function M.statusline_model()
  local m = state.config.session and state.config.session.model or ''
  local label = m ~= '' and m or 'default'
  if state.reasoning_effort and state.reasoning_effort ~= '' then
    label = label .. ' [' .. state.reasoning_effort .. ']'
  end
  return label
end

function M.statusline_busy()
  return state.chat_busy and '⏳' or '✓'
end

function M.statusline_attachments()
  local n = #state.pending_attachments
  return n > 0 and ('📎' .. n) or ''
end

local _perm_icons = {
  interactive = '🔐',
  ['approve-all'] = '✅',
  autopilot = '🤖',
  ['reject-all'] = '🚫',
}
function M.statusline_permission()
  local mode = state.permission_mode or 'interactive'
  return (_perm_icons[mode] or '🔐') .. mode
end

function M.statusline_component()
  local parts = {
    M.statusline_mode(),
    M.statusline_busy(),
    M.statusline_model(),
    M.statusline_permission(),
  }
  local att = M.statusline_attachments()
  if att ~= '' then
    table.insert(parts, att)
  end
  return table.concat(parts, ' ')
end

function M.refresh_input_statusline()
  if not state.input_winid or not vim.api.nvim_win_is_valid(state.input_winid) then
    return
  end
  local att = M.statusline_attachments()
  vim.wo[state.input_winid].statusline =
    string.format(' %s %s  %s  %s%s  (? for help)', M.statusline_mode(), M.statusline_busy(), M.statusline_model(), M.statusline_permission(), att ~= '' and ('  ' .. att) or '')
end

function M.refresh_chat_statusline()
  if not state.chat_winid or not vim.api.nvim_win_is_valid(state.chat_winid) then
    return
  end
  local session_label = ''
  if state.session_id then
    if state.session_name and state.session_name ~= '' then
      session_label = '  session: ' .. state.session_name
    else
      session_label = '  #' .. state.session_id:sub(1, 8)
    end
  end
  vim.wo[state.chat_winid].statusline = string.format(' %s %s  %s  %s%s', M.statusline_mode(), M.statusline_busy(), M.statusline_model(), M.statusline_permission(), session_label)
end

function M.refresh_statuslines()
  M.refresh_input_statusline()
  M.refresh_chat_statusline()
end

return M
