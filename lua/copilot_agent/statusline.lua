-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Statusline components and window statusline refreshers.

local cfg = require('copilot_agent.config')
local state = cfg.state

local M = {}

local _mode_icon = {
  ask = '💬',
  plan = '📋',
  agent = '🤖',
  autopilot = '🚀',
}

-- SDK loop style per input mode.
local _sdk_label = {
  ask = 'single-turn',
  plan = 'plan',
  agent = 'loop',
  autopilot = 'loop',
}

-- Human-readable permission label.
local _perm_label = {
  interactive    = 'prompt-all',
  ['approve-reads'] = 'auto-read',
  ['approve-all']   = 'approve-all',
  autopilot      = 'fully-auto',
  ['reject-all'] = 'reject-all',
}

-- Combined mode+permission description shown in the statusline.
-- Examples:
--   💬ask  (single-turn · prompt-all)
--   🤖agent  (loop · auto-read)
--   🤖agent  (loop · approve-all)   ← manual override
--   🚀autopilot  (loop · fully-auto)
function M.statusline_mode()
  local mode = state.input_mode or 'agent'
  local perm = state.permission_mode or 'interactive'
  local icon = _mode_icon[mode] or ''
  local sdk  = _sdk_label[mode] or mode
  local pl   = _perm_label[perm] or perm
  return icon .. mode .. ' (' .. sdk .. '·' .. pl .. ')'
end

function M.statusline_model()
  local m = state.current_model or (state.config.session and state.config.session.model) or ''
  local label = m ~= '' and m or 'default'
  if state.reasoning_effort and state.reasoning_effort ~= '' then
    label = label .. ' [' .. state.reasoning_effort .. ']'
  end
  return label
end

function M.statusline_busy()
  return state.chat_busy and '⏳' or '✓'
end

-- Format token count compactly: 1234 → "1k", 200000 → "200k"
local function format_tokens(n)
  if not n or n <= 0 then
    return '0'
  end
  if n < 1000 then
    return tostring(math.floor(n))
  end
  return string.format('%.0fk', n / 1000)
end

function M.statusline_tool()
  if state.active_tool and state.active_tool ~= '' then
    return '🔧' .. state.active_tool
  end
  return ''
end

function M.statusline_intent()
  if state.current_intent and state.current_intent ~= '' then
    local text = state.current_intent
    if #text > 30 then
      text = text:sub(1, 27) .. '…'
    end
    return '📋' .. text
  end
  return ''
end

function M.statusline_context()
  if state.context_tokens and state.context_limit and state.context_limit > 0 then
    return '📊' .. format_tokens(state.context_tokens) .. '/' .. format_tokens(state.context_limit)
  end
  return ''
end

function M.statusline_attachments()
  local n = #state.pending_attachments
  return n > 0 and ('📎' .. n) or ''
end

local _perm_icons = {
  interactive = '🔐',
  ['approve-reads'] = '📂',
  ['approve-all'] = '✅',
  autopilot = '🤖',
  ['reject-all'] = '🚫',
}
function M.statusline_permission()
  local mode = state.permission_mode or 'interactive'
  return (_perm_icons[mode] or '🔐') .. mode
end

-- Build a list of non-empty statusline parts.
local function build_parts(...)
  local parts = {}
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if v and v ~= '' then
      parts[#parts + 1] = v
    end
  end
  return parts
end

function M.statusline_component()
  return table.concat(
    build_parts(
      M.statusline_mode(),
      M.statusline_busy(),
      M.statusline_model(),
      M.statusline_tool(),
      M.statusline_intent(),
      M.statusline_context(),
      M.statusline_attachments()
    ),
    ' '
  )
end

function M.refresh_input_statusline()
  if not state.input_winid or not vim.api.nvim_win_is_valid(state.input_winid) then
    return
  end
  local line = ' '
    .. table.concat(
      build_parts(
        M.statusline_mode(),
        M.statusline_busy(),
        M.statusline_model(),
        M.statusline_tool(),
        M.statusline_intent(),
        M.statusline_context(),
        M.statusline_attachments()
      ),
      '  '
    )
    .. '  (? for help)'
  vim.wo[state.input_winid].statusline = line
end

function M.refresh_chat_statusline()
  if not state.chat_winid or not vim.api.nvim_win_is_valid(state.chat_winid) then
    return
  end
  local session_label = ''
  if state.session_id then
    if state.session_name and state.session_name ~= '' then
      session_label = 'session: ' .. state.session_name
    else
      session_label = '#' .. state.session_id:sub(1, 8)
    end
  end
  local line = ' '
    .. table.concat(
      build_parts(M.statusline_mode(), M.statusline_busy(), M.statusline_model(), M.statusline_tool(), M.statusline_intent(), M.statusline_context(), session_label),
      '  '
    )
  vim.wo[state.chat_winid].statusline = line
end

local _sl_timer = nil
local _sl_pending = false

function M.refresh_statuslines()
  if _sl_pending then
    return
  end
  _sl_pending = true
  -- Debounce: at most one statusline redraw per 100 ms.
  _sl_timer = vim.defer_fn(function()
    _sl_pending = false
    _sl_timer = nil
    M.refresh_input_statusline()
    M.refresh_chat_statusline()
  end, 100)
end

return M
