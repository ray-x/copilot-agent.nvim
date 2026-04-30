-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Statusline components and window statusline refreshers.

local cfg = require('copilot_agent.config')
local utils = require('copilot_agent.utils')
local state = cfg.state
local format_session_id = utils.format_session_id
local truncate_session_summary = utils.truncate_session_summary

local M = {}
local _statusline_count_hl = '%#CopilotAgentStatuslineCount#'
local _statusline_reset_hl = '%*'
local _statusline_small_width = 100
local _statusline_medium_width = 140

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
  interactive = 'prompt-all',
  ['approve-reads'] = 'auto-read',
  ['approve-all'] = 'approve-all',
  autopilot = 'fully-auto',
  ['reject-all'] = 'reject-all',
}

function M.statusline_mode()
  local mode = state.input_mode or 'agent'
  local perm = state.permission_mode or 'interactive'
  local icon = _mode_icon[mode] or ''
  local sdk = _sdk_label[mode] or mode
  local pl = _perm_label[perm] or perm
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

local function statusline_size(width)
  width = tonumber(width) or 0
  if width > 0 and width < _statusline_small_width then
    return 'small'
  end
  if width > 0 and width < _statusline_medium_width then
    return 'medium'
  end
  return 'large'
end

local function config_labels(width)
  local size = statusline_size(width)
  if size == 'small' then
    return {
      instructions = 'I',
      agents = 'A',
      skills = 'S',
      mcp = 'M',
    }
  end
  if size == 'medium' then
    return {
      instructions = 'Ins',
      agents = 'Ag',
      skills = 'Sk',
      mcp = 'Mc',
    }
  end
  return {
    instructions = 'Instruction',
    agents = 'Agent',
    skills = 'Skill',
    mcp = 'MCP',
  }
end

local function statusline_session_id(session_id)
  if
    type(session_id) == 'string'
    and #session_id == 36
    and session_id:sub(9, 9) == '-'
    and session_id:sub(14, 14) == '-'
    and session_id:sub(19, 19) == '-'
    and session_id:sub(24, 24) == '-'
    and session_id:gsub('%-', ''):match('^[0-9a-fA-F]+$')
  then
    return '#' .. session_id:sub(1, 8)
  end
  return '#' .. format_session_id(session_id):gsub('T', ' ', 1)
end

function M.statusline_session(width)
  if not state.session_id or state.session_id == '' then
    return ''
  end

  local formatted_id = statusline_session_id(state.session_id)
  local size = statusline_size(width)
  if size == 'small' then
    return 'session: [' .. formatted_id .. ']'
  end
  local name_max_len = size == 'medium' and 16 or 32
  if state.session_name and state.session_name ~= '' then
    return 'session: [' .. truncate_session_summary(state.session_name, name_max_len) .. ' ' .. formatted_id .. ']'
  end

  return 'session: [' .. formatted_id .. ']'
end

local function statusline_count_segment(icon, label, value, highlight_number)
  local rendered = tostring(value)
  if highlight_number then
    rendered = _statusline_count_hl .. rendered .. _statusline_reset_hl
  end
  return string.format('%s %s: %s', icon, label, rendered)
end

local function statusline_config_segments(highlight_numbers, width)
  local instructions = tonumber(state.instruction_count) or 0
  local agents = tonumber(state.agent_count) or 0
  local skills = tonumber(state.skill_count) or 0
  local mcp = tonumber(state.mcp_count) or 0
  local labels = config_labels(width)

  return {
    statusline_count_segment('󱃕', labels.instructions, instructions, highlight_numbers),
    statusline_count_segment('󱜙', labels.agents, agents, highlight_numbers),
    statusline_count_segment('󱨚', labels.skills, skills, highlight_numbers),
    statusline_count_segment('', labels.mcp, mcp, highlight_numbers),
  }
end

function M.statusline_config(width)
  return table.concat(statusline_config_segments(false, width), ' ')
end

function M.statusline_config_highlighted(width)
  return table.concat(statusline_config_segments(true, width), ' ')
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
  local width = vim.api.nvim_win_get_width(0)
  return table.concat(
    build_parts(
      M.statusline_mode(),
      M.statusline_permission(),
      M.statusline_busy(),
      M.statusline_model(),
      M.statusline_tool(),
      M.statusline_intent(),
      M.statusline_context(),
      M.statusline_config(width),
      M.statusline_attachments()
    ),
    ' '
  )
end

function M.refresh_input_statusline()
  if not state.input_winid or not vim.api.nvim_win_is_valid(state.input_winid) then
    return
  end
  local width = vim.api.nvim_win_get_width(state.input_winid)
  local line = ' '
    .. table.concat(
      build_parts(
        M.statusline_mode(),
        M.statusline_permission(),
        M.statusline_busy(),
        M.statusline_model(),
        M.statusline_tool(),
        M.statusline_intent(),
        M.statusline_context(),
        M.statusline_config_highlighted(width),
        M.statusline_session(width),
        M.statusline_attachments()
      ),
      '  '
    )
    .. '  (? for help)'
  vim.wo[state.input_winid].statusline = line
  local ok, input = pcall(require, 'copilot_agent.input')
  if ok and type(input.refresh_separator) == 'function' then
    input.refresh_separator()
  end
end

function M.refresh_chat_statusline()
  if not state.chat_winid or not vim.api.nvim_win_is_valid(state.chat_winid) then
    return
  end
  local width = vim.api.nvim_win_get_width(state.chat_winid)
  local line = ' '
    .. table.concat(
      build_parts(
        M.statusline_mode(),
        M.statusline_permission(),
        M.statusline_busy(),
        M.statusline_model(),
        M.statusline_tool(),
        M.statusline_intent(),
        M.statusline_context(),
        M.statusline_config_highlighted(width),
        M.statusline_session(width)
      ),
      '  '
    )
  vim.wo[state.chat_winid].statusline = line
end

local _sl_pending = false

function M.refresh_statuslines()
  if _sl_pending then
    return
  end
  _sl_pending = true
  -- Debounce: at most one statusline redraw per 100 ms.
  vim.defer_fn(function()
    _sl_pending = false
    M.refresh_input_statusline()
    M.refresh_chat_statusline()
  end, 100)
end

return M
