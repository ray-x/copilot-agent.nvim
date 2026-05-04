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
local _statusline_small_width = 100 -- Collapse lower-priority statusline sections once the current window gets narrower than this.
local _statusline_medium_width = 140 -- Re-enable medium-detail statusline sections once there is enough room to avoid truncation.
local _intent_statusline_max_len = 30 -- Keep the intent label short enough to coexist with model, mode, and task indicators.
local _intent_statusline_preview_chars = 27 -- Trim slightly below the hard cap so the prefixed icon and ellipsis never crowd adjacent statusline sections.
local _reasoning_statusline_max_len = 32 -- Keep the rolling reasoning snippet short so it does not dominate the statusline.
local _is_list = vim.islist or vim.tbl_islist
local _statusline_component_defaults = {
  mode = true,
  permission = true,
  busy = true,
  session = true,
  model = true,
  tool = true,
  intent = true,
  context = true,
  config = true,
  attachments = true,
  help = true,
}

local function statusline_config()
  local statusline_cfg = state.config and state.config.statusline
  if type(statusline_cfg) ~= 'table' then
    return {}
  end
  return statusline_cfg
end

local function plugin_statusline_enabled()
  return statusline_config().enabled == true
end

local function statusline_component_enabled(name)
  if _statusline_component_defaults[name] ~= true then
    return false
  end

  local components = statusline_config().components
  if type(components) ~= 'table' then
    return _statusline_component_defaults[name]
  end

  if _is_list(components) then
    for _, item in ipairs(components) do
      if item == name then
        return true
      end
    end
    return false
  end

  local value = components[name]
  if value == nil then
    return _statusline_component_defaults[name]
  end
  return value == true
end

local function statusline_part(name, producer, ...)
  if not statusline_component_enabled(name) then
    return ''
  end
  return producer(...)
end

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

local function active_background_task_count()
  local count = 0
  for _, task in pairs(state.background_tasks or {}) do
    if type(task) == 'table' and (task.status == 'running' or task.status == 'inbox' or task.status == 'idle') then
      count = count + 1
    end
  end
  return count
end

function M.statusline_busy()
  if state.pending_user_input then
    return '❓input'
  end

  local pending_sync = (tonumber(state.pending_checkpoint_ops) or 0) + (tonumber(state.pending_workspace_updates) or 0)
  if state.history_loading or state.event_stream_recovery_session_id or pending_sync > 0 then
    return '📝sync'
  end

  if state.chat_busy or (state.active_tool and state.active_tool ~= '') or (state.current_intent and state.current_intent ~= '') then
    return '⏳working'
  end

  local active_background = active_background_task_count()
  if active_background > 0 then
    return string.format('🧩%d %s', active_background, active_background == 1 and 'task' or 'tasks')
  end

  return '✅ready'
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
    if #text > _intent_statusline_max_len then
      text = text:sub(1, _intent_statusline_preview_chars) .. '…'
    end
    return '📋' .. text
  end
  return ''
end

function M.statusline_reasoning(max_len)
  local lines = state.reasoning_lines or {}
  if #lines == 0 then
    return ''
  end

  local text = lines[#lines] or ''
  if #lines > 1 then
    text = '… ' .. text
  end

  max_len = math.max(1, math.floor(tonumber(max_len) or _reasoning_statusline_max_len))
  if #text > max_len then
    text = text:sub(1, max_len - 1) .. '…'
  end
  return '🧠' .. text
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

local function statusline_session_id(session_id, compact)
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

  local formatted = format_session_id(session_id)
  if compact then
    local prefix, year, month, day = formatted:match('^(.-)%-(%d%d%d%d)%-(%d%d)%-(%d%d)T')
    if prefix and year and month and day then
      return string.format('#%s-%s-%s-%s', prefix, year:sub(3, 4), month, day)
    end
  end

  return '#' .. formatted:gsub('T', ' ', 1)
end

function M.statusline_session(width)
  if not state.session_id or state.session_id == '' then
    return ''
  end

  local size = statusline_size(width)
  local formatted_id = statusline_session_id(state.session_id, size == 'small')
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

local function statusline_visible_text(text)
  if type(text) ~= 'string' or text == '' then
    return ''
  end
  return text:gsub('%%#.-#', ''):gsub('%%%*', '')
end

local function statusline_text_width(text)
  return vim.fn.strdisplaywidth(statusline_visible_text(text))
end

local function truncate_plain_text(text, max_width)
  text = type(text) == 'string' and text or ''
  max_width = math.max(1, math.floor(tonumber(max_width) or 1))
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  if max_width <= 1 then
    return '…'
  end

  local out = {}
  local width = 0
  local char_count = vim.fn.strchars(text)
  for idx = 1, char_count do
    local s = vim.fn.strcharpart(text, idx - 1, 1)
    local next_width = vim.fn.strdisplaywidth(table.concat(out) .. s .. '…')
    if next_width > max_width then
      break
    end
    out[#out + 1] = s
    width = next_width
  end
  if #out == 0 or width > max_width then
    return '…'
  end
  return table.concat(out) .. '…'
end

local function fit_statusline_parts(parts, width, sep)
  sep = sep or ' '
  width = math.max(1, math.floor(tonumber(width) or 0))
  if width <= 0 then
    return ''
  end

  local out = {}
  local used = 0
  local sep_width = statusline_text_width(sep)

  for _, part in ipairs(parts) do
    if type(part) == 'string' and part ~= '' then
      local part_width = statusline_text_width(part)
      local extra = (#out > 0) and sep_width or 0
      if used + extra + part_width <= width then
        if #out > 0 then
          used = used + sep_width
        end
        out[#out + 1] = part
        used = used + part_width
      else
        local remaining = width - used - extra
        if #out == 0 and remaining > 0 then
          out[#out + 1] = truncate_plain_text(statusline_visible_text(part), remaining)
        end
        break
      end
    end
  end

  return table.concat(out, sep)
end

local function resolve_window_for_buffer(winid, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    if winid and vim.api.nvim_win_is_valid(winid) then
      return winid
    end
    return nil
  end

  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    return winid
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local windows = vim.fn.win_findbuf(bufnr)
  for _, candidate in ipairs(windows) do
    if vim.api.nvim_win_is_valid(candidate) and vim.api.nvim_win_get_buf(candidate) == bufnr and vim.api.nvim_win_get_tabpage(candidate) == current_tab then
      return candidate
    end
  end

  for _, candidate in ipairs(windows) do
    if vim.api.nvim_win_is_valid(candidate) and vim.api.nvim_win_get_buf(candidate) == bufnr then
      return candidate
    end
  end

  return nil
end

local function statusline_window_width()
  -- The exported statusline() API follows the editor-wide statusline width for
  -- the common laststatus=2/3 modes, and only falls back to the current
  -- window width when statuslines are per-window (laststatus=1).
  if vim.o.laststatus == 2 or vim.o.laststatus == 3 then
    return vim.opt.columns:get()
  end
  return vim.fn.winwidth(0)
end

local function refresh_statusline_width(winid)
  if vim.o.laststatus == 2 or vim.o.laststatus == 3 then
    return vim.opt.columns:get()
  end
  if winid and vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_width(winid)
  end
  return vim.fn.winwidth(0)
end

function M.statusline_component()
  local width = statusline_window_width()
  return fit_statusline_parts(
    build_parts(
      statusline_part('mode', M.statusline_mode),
      statusline_part('permission', M.statusline_permission),
      statusline_part('busy', M.statusline_busy),
      statusline_part('model', M.statusline_model),
      statusline_part('tool', M.statusline_tool),
      statusline_part('intent', M.statusline_intent),
      statusline_part('context', M.statusline_context),
      statusline_part('config', M.statusline_config, width),
      statusline_part('attachments', M.statusline_attachments)
    ),
    width,
    ' '
  )
end

function M.refresh_input_statusline()
  local input_winid = resolve_window_for_buffer(state.input_winid, state.input_bufnr)
  if not input_winid then
    state.input_winid = nil
    return
  end
  state.input_winid = input_winid
  local ok, input = pcall(require, 'copilot_agent.input')
  local function refresh_separator()
    if ok and type(input.refresh_separator) == 'function' then
      input.refresh_separator()
    end
  end

  if not plugin_statusline_enabled() then
    if state.input_statusline_managed then
      vim.wo[input_winid].statusline = ''
    end
    state.input_statusline_managed = false
    refresh_separator()
    return
  end

  local width = refresh_statusline_width(input_winid)
  local line = ' '
    .. fit_statusline_parts(
      build_parts(
        statusline_part('mode', M.statusline_mode),
        statusline_part('permission', M.statusline_permission),
        statusline_part('busy', M.statusline_busy),
        statusline_part('model', M.statusline_model),
        statusline_part('tool', M.statusline_tool),
        statusline_part('intent', M.statusline_intent),
        statusline_part('context', M.statusline_context),
        statusline_part('config', M.statusline_config_highlighted, width),
        statusline_part('attachments', M.statusline_attachments),
        statusline_part('help', function()
          return '(? for help)'
        end)
      ),
      math.max(1, width - 1),
      '  '
    )
  vim.wo[input_winid].statusline = line
  state.input_statusline_managed = true
  refresh_separator()
end

function M.refresh_chat_statusline()
  local chat_winid = resolve_window_for_buffer(state.chat_winid, state.chat_bufnr)
  if not chat_winid then
    state.chat_winid = nil
    return
  end
  state.chat_winid = chat_winid

  if not plugin_statusline_enabled() then
    if state.chat_statusline_managed then
      vim.wo[chat_winid].statusline = ''
    end
    state.chat_statusline_managed = false
    return
  end

  local width = refresh_statusline_width(chat_winid)
  local line = ' '
    .. fit_statusline_parts(
      build_parts(
        statusline_part('mode', M.statusline_mode),
        statusline_part('busy', M.statusline_busy),
        statusline_part('session', M.statusline_session, width),
        statusline_part('permission', M.statusline_permission),
        statusline_part('model', M.statusline_model),
        statusline_part('tool', M.statusline_tool),
        statusline_part('intent', M.statusline_intent),
        statusline_part('context', M.statusline_context),
        statusline_part('config', M.statusline_config_highlighted, width)
      ),
      math.max(1, width - 1),
      '  '
    )
  vim.wo[chat_winid].statusline = line
  state.chat_statusline_managed = true
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
