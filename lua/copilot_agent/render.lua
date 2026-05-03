-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Chat buffer rendering: entry formatting, highlights, streaming, spinner.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local utils = require('copilot_agent.utils')
local window = require('copilot_agent.window')
local state = cfg.state
local log = cfg.log
local notify = cfg.notify
local normalize_base_url = cfg.normalize_base_url
local DEFAULT_LOG_CONTENT_LENGTH = 1000 -- Match config.defaults.log_content_length when setup() has not populated state.config yet.
local max_log_content_length = cfg.log_content_length or DEFAULT_LOG_CONTENT_LENGTH

local M = {}

local highlight_lines -- forward declaration; defined below
local DEFAULT_REASONING_MAX_LINES = 5 -- Show a short rolling reasoning preview without crowding the transcript.
local MAX_REASONING_PREVIEW_LINES = 20 -- Cap reasoning preview growth so the overlay cannot take over the entire window.
local LOG_PREVIEW_MIN_CHARS = 16 -- Preserve enough context for truncated log previews to stay informative.
local ACTIVITY_PREVIEW_MAX_WIDTH = 32 -- Keep activity snippets compact enough for statusline and overlay summaries.
local OVERLAY_WRAP_MIN_WIDTH = 20 -- Prevent pathological wrapping in very narrow windows.
local OVERLAY_WRAP_FALLBACK_WIDTH = 80 -- Use a terminal-friendly default width before the chat window is available.
local OVERLAY_MIN_WINDOW_WIDTH = 24 -- Reserve enough width for overlay headings and short tool labels.
local OVERLAY_HORIZONTAL_PADDING = 4 -- Leave a small gutter between virtual overlay text and the window edge.
local OVERLAY_SEPARATOR_HORIZONTAL_PADDING = 2 -- Preserve a small margin around separator rules.
local OVERLAY_BREAK_THRESHOLD_RATIO = 0.3 -- Only wrap on whitespace after at least 30% of the line to avoid tiny fragments.
local ACTIVITY_DETAIL_PREFIXES = {
  'Ran ',
  'Viewed ',
  'Read ',
  'Searched ',
  'Queried ',
  'Fetched ',
  'Updated ',
  'Added ',
  'Deleted ',
  'Moved ',
  'Edited ',
  'Used ',
  'Started ',
}

local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local CHAT_HL_NS = vim.api.nvim_create_namespace('copilot_agent_chat')
local REASONING_NS = vim.api.nvim_create_namespace('copilot_agent_reasoning')
local RENDER_DEBOUNCE_MS = 150 -- Batch transcript redraws so UI updates stay smooth during bursts of events.
local STREAM_DEBOUNCE_MS = 80 -- Coalesce token streaming updates without making responses feel laggy.
local REASONING_DEBOUNCE_MS = 80 -- Refresh reasoning overlay at the same cadence as streamed transcript updates.
local SPINNER_INTERVAL_MS = 500 -- Half-second spinner cadence keeps motion visible without looking noisy.
local CHAT_SCROLL_GUARD_MS = 80 -- Ignore WinScrolled events triggered by our own transcript repositioning.
local OVERLAY_BOTTOM_GUTTER_MIN_LINES = 5 -- Keep at least a few transcript lines visible below the activity overlay.
local OVERLAY_TAIL_SPACER_LINES = 3 -- Leave spacer rows so bottom-anchored virtual lines do not sit flush with content.

local split_lines = utils.split_lines

local function refresh_statuslines()
  local ok, sl = pcall(require, 'copilot_agent.statusline')
  if ok and type(sl.refresh_statuslines) == 'function' then
    sl.refresh_statuslines()
  end
end

local function reasoning_config()
  local reasoning = (((state.config or {}).chat or {}).reasoning or {})
  local enabled
  if reasoning.enabled == nil then
    enabled = #(state.reasoning_lines or {}) > 0
      or (type(state.reasoning_effort) == 'string' and state.reasoning_effort ~= '')
  else
    enabled = reasoning.enabled == true
  end
  local max_lines = tonumber(reasoning.max_lines) or DEFAULT_REASONING_MAX_LINES
  max_lines = math.max(1, math.min(MAX_REASONING_PREVIEW_LINES, math.floor(max_lines)))
  return enabled, max_lines
end

local function normalize_reasoning_lines(text)
  if type(text) ~= 'string' or text == '' then
    return {}
  end
  local lines = vim.split(text:gsub('\r\n?', '\n'), '\n', { plain = true })
  local filtered = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      filtered[#filtered + 1] = line
    end
  end
  return filtered
end

function M.reasoning_lines(max_lines)
  local lines = vim.deepcopy(state.reasoning_lines or {})
  -- Filter out empty lines to save precious overlay space
  local non_empty = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      non_empty[#non_empty + 1] = line
    end
  end
  lines = non_empty
  if max_lines == nil then
    max_lines = select(2, reasoning_config())
  else
    max_lines = math.max(1, math.floor(tonumber(max_lines) or DEFAULT_REASONING_MAX_LINES))
  end
  if #lines <= max_lines then
    return lines
  end
  local trimmed = {}
  for i = #lines - max_lines + 1, #lines do
    trimmed[#trimmed + 1] = lines[i]
  end
  return trimmed
end

local function preview_log_text(text, max_len)
  if type(text) ~= 'string' then
    return '<non-string>'
  end
  local preview = text:gsub('\r\n?', '\n'):gsub('\n', '\\n'):gsub('\t', '\\t')
  max_len = math.max(LOG_PREVIEW_MIN_CHARS, math.floor(tonumber(max_len) or max_log_content_length))
  if #preview > max_len then
    return preview:sub(1, max_len - 1) .. '…'
  end
  return preview
end

local function truncate_display_text(text, max_width)
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

local function wrap_overlay_text(text, max_width)
  text = type(text) == 'string' and text:gsub('%s+', ' '):match('^%s*(.-)%s*$') or ''
  if text == '' then
    return {}
  end
  max_width = math.max(OVERLAY_WRAP_MIN_WIDTH, math.floor(tonumber(max_width) or OVERLAY_WRAP_FALLBACK_WIDTH))
  if vim.fn.strdisplaywidth(text) <= max_width then
    return { text }
  end
  local wrapped = {}
  local pos = 1
  while pos <= #text do
    local chunk = text:sub(pos, pos + max_width - 1)
    if pos + max_width - 1 < #text then
      local break_at = chunk:find('%s[^%s]*$')
      if break_at and break_at > math.floor(max_width * OVERLAY_BREAK_THRESHOLD_RATIO) then
        chunk = chunk:sub(1, break_at - 1)
      end
    end
    wrapped[#wrapped + 1] = vim.trim(chunk)
    pos = pos + #chunk
    while pos <= #text and text:sub(pos, pos) == ' ' do
      pos = pos + 1
    end
  end
  return wrapped
end

local function activity_overlay_width()
  local win = state.chat_winid
  if win and vim.api.nvim_win_is_valid(win) then
    return math.max(OVERLAY_MIN_WINDOW_WIDTH, vim.api.nvim_win_get_width(win) - OVERLAY_HORIZONTAL_PADDING)
  end
  return OVERLAY_WRAP_FALLBACK_WIDTH
end

local function tool_is_displayable_in_overlay(name)
  if type(name) ~= 'string' or name == '' then
    return false
  end
  local normalized = vim.trim(name):lower()
  if
    normalized == 'bash'
    or normalized == 'sh'
    or normalized == 'zsh'
    or normalized == 'fish'
    or normalized == 'pwsh'
    or normalized == 'powershell'
    or normalized == 'cmd'
  then
    return true
  end
  return false
end

local function activity_overlay_lines(_)
  local overlay_tool = state.overlay_tool_display
  if type(overlay_tool) ~= 'table' or not tool_is_displayable_in_overlay(overlay_tool.tool) then
    return {}
  end

  local line = overlay_tool.tool
  if
    type(overlay_tool.detail) == 'string'
    and overlay_tool.detail ~= ''
    and overlay_tool.detail ~= overlay_tool.tool
  then
    line = line .. ' — ' .. overlay_tool.detail
  end
  line = type(line) == 'string' and line:gsub('%s+', ' '):match('^%s*(.-)%s*$') or ''
  if line == '' then
    return {}
  end
  local prefix = '🔧 '
  local max_w = activity_overlay_width() - vim.fn.strdisplaywidth(prefix)
  local wrapped = wrap_overlay_text(line, max_w)
  if #wrapped == 0 then
    return {}
  end
  wrapped[1] = prefix .. wrapped[1]
  return wrapped
end

local function append_overlay_section(virt_lines, lines, first_prefix, other_prefix, highlight, right_align)
  local win_width
  if right_align then
    local win = state.chat_winid
    win_width = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_width(win) or 80
  end
  for idx, line in ipairs(lines) do
    local prefix = idx == 1 and first_prefix or other_prefix
    local display_text = prefix .. line
    if right_align and win_width then
      local text_width = vim.fn.strdisplaywidth(display_text)
      local pad = math.max(0, win_width - text_width - 1)
      virt_lines[#virt_lines + 1] = {
        { string.rep(' ', pad), '' },
        { display_text, highlight },
      }
    else
      virt_lines[#virt_lines + 1] = {
        { display_text, highlight },
      }
    end
  end
end

local function reasoning_virtual_lines(task_lines, reasoning_lines)
  local virt_lines = {}
  append_overlay_section(virt_lines, task_lines, '  Activity: ', '            ', 'CopilotAgentActivity', false)
  append_overlay_section(virt_lines, reasoning_lines, '  Reasoning: ', '             ', 'CopilotAgentReasoning', false)
  return virt_lines
end

local function clear_reasoning_overlay()
  local bufnr = state.chat_bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, REASONING_NS, 0, -1)
  end
end

local reasoning_timer = uv.new_timer()
local reasoning_refresh_pending = false
local reasoning_last_refresh_ms = 0

local function overlay_now_ms()
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1e6)
  end
  return math.floor(vim.loop.hrtime() / 1e6)
end

local function overlay_anchor(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return math.max(line_count - 1, 0), false
end

local chat_view_log_summary

local function overlay_tail_spacer_lines()
  return math.max(0, math.floor(tonumber(state.chat_tail_spacer_lines) or 0))
end

local function append_blank_lines(lines, count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  for _ = 1, count do
    lines[#lines + 1] = ''
  end
end

local function rendered_content_line_count(bufnr)
  local rendered = tonumber(state._rendered_line_count)
  if rendered ~= nil then
    rendered = math.max(0, math.floor(rendered))
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return math.min(rendered, vim.api.nvim_buf_line_count(bufnr))
    end
    return rendered
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return math.max(0, vim.api.nvim_buf_line_count(bufnr) - overlay_tail_spacer_lines())
  end
  return 0
end

local function sync_chat_tail_spacer_lines(bufnr, desired_count)
  local previous_count = overlay_tail_spacer_lines()
  desired_count = math.max(0, math.floor(tonumber(desired_count) or 0))
  state.chat_tail_spacer_lines = desired_count
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local content_end = rendered_content_line_count(bufnr)
  local spacer_lines = {}
  append_blank_lines(spacer_lines, desired_count)

  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, content_end, -1, false, spacer_lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  if previous_count ~= desired_count then
    log(
      string.format(
        'reasoning overlay tail spacers updated previous=%d current=%d content_end=%d line_count=%d %s',
        previous_count,
        desired_count,
        content_end,
        vim.api.nvim_buf_line_count(bufnr),
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
  end
end

chat_view_log_summary = function()
  local winid = state.chat_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return 'view=<invalid>'
  end
  local info = vim.fn.getwininfo(winid)
  local view = info and info[1] or nil
  if not view then
    return 'view=<unknown>'
  end
  return string.format('top=%s bot=%s height=%s', tostring(view.topline), tostring(view.botline), tostring(view.height))
end

local function update_reasoning_overlay_now()
  local bufnr = state.chat_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    log(
      string.format(
        'reasoning overlay skipped chat buffer unavailable bufnr=%s winid=%s text_len=%d stored_lines=%d',
        tostring(bufnr),
        tostring(state.chat_winid),
        #(state.reasoning_text or ''),
        #(state.reasoning_lines or {})
      ),
      vim.log.levels.DEBUG
    )
    return
  end

  local had_overlay = #vim.api.nvim_buf_get_extmarks(bufnr, REASONING_NS, 0, -1, { limit = 1 }) > 0
  clear_reasoning_overlay()

  local enabled, max_lines = reasoning_config()
  if state.history_loading then
    log(
      string.format(
        'reasoning overlay skipped enabled=%s history_loading=%s text_len=%d stored_lines=%d %s',
        tostring(enabled),
        tostring(state.history_loading),
        #(state.reasoning_text or ''),
        #(state.reasoning_lines or {}),
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
    return
  end

  local task_lines = activity_overlay_lines(max_lines)
  local reasoning_lines = enabled and M.reasoning_lines(max_lines) or {}
  if #task_lines == 0 and #reasoning_lines == 0 then
    sync_chat_tail_spacer_lines(bufnr, 0)
    if had_overlay then
      M.release_overlay_gutter()
    end
    log(
      string.format(
        'reasoning overlay skipped no lines enabled=%s had_overlay=%s text_len=%d stored_lines=%d activity=%d rendered_reasoning=%d %s',
        tostring(enabled),
        tostring(had_overlay),
        #(state.reasoning_text or ''),
        #(state.reasoning_lines or {}),
        #task_lines,
        #reasoning_lines,
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
    return
  end

  sync_chat_tail_spacer_lines(bufnr, state.chat_busy and OVERLAY_TAIL_SPACER_LINES or 0)
  local padding = M.overlay_bottom_padding(#task_lines, #reasoning_lines)
  M.reserve_overlay_gutter(#task_lines, #reasoning_lines)
  local anchor_row, anchor_above = overlay_anchor(bufnr)
  local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, REASONING_NS, anchor_row, 0, {
    virt_lines = reasoning_virtual_lines(task_lines, reasoning_lines),
    virt_lines_leftcol = true,
    virt_lines_above = anchor_above,
  })
  log(
    string.format(
      'reasoning overlay updated extmark=%s activity=%d reasoning=%d padding=%d anchor_row=%d above=%s text_len=%d stored_lines=%d %s',
      tostring(extmark_id),
      #task_lines,
      #reasoning_lines,
      padding,
      anchor_row,
      tostring(anchor_above),
      #(state.reasoning_text or ''),
      #(state.reasoning_lines or {}),
      chat_view_log_summary()
    ),
    vim.log.levels.DEBUG
  )
end

function M.refresh_reasoning_overlay(immediate)
  if immediate then
    log(
      string.format(
        'reasoning overlay refresh immediate text_len=%d stored_lines=%d pending=%s %s',
        #(state.reasoning_text or ''),
        #(state.reasoning_lines or {}),
        tostring(reasoning_refresh_pending),
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
    reasoning_timer:stop()
    reasoning_refresh_pending = false
    reasoning_last_refresh_ms = overlay_now_ms()
    vim.schedule(update_reasoning_overlay_now)
    return
  end

  local now = overlay_now_ms()
  local elapsed = now - (reasoning_last_refresh_ms or 0)
  if not reasoning_refresh_pending and (reasoning_last_refresh_ms == 0 or elapsed >= REASONING_DEBOUNCE_MS) then
    log(
      string.format(
        'reasoning overlay refresh scheduled now elapsed=%d text_len=%d stored_lines=%d %s',
        elapsed,
        #(state.reasoning_text or ''),
        #(state.reasoning_lines or {}),
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
    reasoning_last_refresh_ms = now
    vim.schedule(update_reasoning_overlay_now)
    return
  end

  local delay = math.max(1, REASONING_DEBOUNCE_MS - elapsed)
  log(
    string.format(
      'reasoning overlay refresh delayed delay=%d elapsed=%d pending=%s text_len=%d stored_lines=%d %s',
      delay,
      elapsed,
      tostring(reasoning_refresh_pending),
      #(state.reasoning_text or ''),
      #(state.reasoning_lines or {}),
      chat_view_log_summary()
    ),
    vim.log.levels.DEBUG
  )
  reasoning_refresh_pending = true
  reasoning_timer:stop()
  reasoning_timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      reasoning_refresh_pending = false
      reasoning_last_refresh_ms = overlay_now_ms()
      update_reasoning_overlay_now()
    end)
  )
end

function M.clear_reasoning_preview(reason)
  local had_reasoning = (state.reasoning_text or '') ~= '' or #(state.reasoning_lines or {}) > 0
  local previous_key = state.reasoning_entry_key
  local previous_text_len = #(state.reasoning_text or '')
  local previous_line_count = #(state.reasoning_lines or {})
  state.reasoning_entry_key = nil
  state.reasoning_text = ''
  state.reasoning_lines = {}
  refresh_statuslines()
  M.refresh_reasoning_overlay(true)
  if had_reasoning then
    log(
      string.format(
        'reasoning preview cleared (%s) key=%s text_len=%d lines=%d %s',
        tostring(reason or 'unspecified'),
        tostring(previous_key or '<none>'),
        previous_text_len,
        previous_line_count,
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
  end
end

function M.append_reasoning_delta(entry_key, delta)
  if type(delta) ~= 'string' or delta == '' then
    log('reasoning delta ignored because it was empty', vim.log.levels.DEBUG)
    return
  end
  if type(entry_key) == 'string' and entry_key ~= '' and state.reasoning_entry_key ~= entry_key then
    state.reasoning_text = ''
  end
  state.reasoning_entry_key = entry_key or state.reasoning_entry_key
  state.reasoning_text = (state.reasoning_text or '') .. delta
  state.reasoning_lines = normalize_reasoning_lines(state.reasoning_text)
  log(
    string.format(
      'reasoning delta appended key=%s chunk_len=%d total_len=%d lines=%d refresh_pending=%s',
      tostring(state.reasoning_entry_key or '<none>'),
      #delta,
      #(state.reasoning_text or ''),
      #(state.reasoning_lines or {}),
      tostring(reasoning_refresh_pending)
    ),
    vim.log.levels.DEBUG
  )
  M.refresh_reasoning_overlay()
  refresh_statuslines()
end

local function separator_rule_width()
  local win = state.chat_winid
  if win and vim.api.nvim_win_is_valid(win) then
    return math.max(OVERLAY_MIN_WINDOW_WIDTH, vim.api.nvim_win_get_width(win) - OVERLAY_SEPARATOR_HORIZONTAL_PADDING)
  end
  return OVERLAY_WRAP_FALLBACK_WIDTH
end

local function checkpoint_separator_chunks(checkpoint_id)
  if type(checkpoint_id) ~= 'string' or checkpoint_id == '' then
    checkpoint_id = '<unknown>'
  end
  local label = ' Checkpoint ID: [' .. checkpoint_id .. '] '
  local width = math.max(separator_rule_width(), vim.fn.strdisplaywidth(label) + 8)
  local padding = width - vim.fn.strdisplaywidth(label)
  local left = math.floor(padding / 2)
  local right = padding - left
  return {
    { string.rep('─', left), 'CopilotAgentRule' },
    { label, 'CopilotAgentCheckpoint' },
    { string.rep('─', right), 'CopilotAgentRule' },
  }
end

local function plain_separator_chunks()
  return {
    { string.rep('─', separator_rule_width()), 'CopilotAgentRule' },
  }
end

local function active_thinking_entry_index()
  local key = state.thinking_entry_key
  if type(key) ~= 'string' or key == '' then
    return nil
  end
  return state.assistant_entries[key]
end

local function pending_assistant_entry_key()
  if type(state.pending_assistant_entry_key) == 'string' and state.pending_assistant_entry_key ~= '' then
    return state.pending_assistant_entry_key
  end

  local pending_turn = state.pending_checkpoint_turn
  if pending_turn and pending_turn.session_id == state.session_id and pending_turn.entry_index then
    state.pending_assistant_entry_key =
      string.format('pending:%s:%s', pending_turn.session_id, pending_turn.entry_index)
    return state.pending_assistant_entry_key
  end

  state.pending_assistant_serial = (tonumber(state.pending_assistant_serial) or 0) + 1
  state.pending_assistant_entry_key = 'pending-assistant:' .. tostring(state.pending_assistant_serial)
  return state.pending_assistant_entry_key
end

local function adopt_pending_assistant_entry(message_id)
  local pending_key = state.pending_assistant_entry_key
  if type(message_id) ~= 'string' or message_id == '' or type(pending_key) ~= 'string' or pending_key == '' then
    return nil
  end

  local index = state.assistant_entries[pending_key]
  if not index or not state.entries[index] then
    state.pending_assistant_entry_key = nil
    return nil
  end

  state.assistant_entries[message_id] = index
  state.assistant_entries[pending_key] = nil
  if state.thinking_entry_key == pending_key then
    state.thinking_entry_key = message_id
  end
  state.pending_assistant_entry_key = nil
  return index
end

local function active_turn_entry_index()
  local pending_turn = state.pending_checkpoint_turn
  if state.history_loading or not pending_turn or pending_turn.session_id ~= state.session_id then
    return nil
  end
  local index = state.active_turn_assistant_index
  if type(index) ~= 'number' or not state.entries[index] or state.entries[index].kind ~= 'assistant' then
    return nil
  end
  return index
end

local function current_assistant_merge_group(create_if_missing)
  local group = state.active_assistant_merge_group
  if type(group) == 'string' and group ~= '' then
    return group
  end
  if not create_if_missing then
    return nil
  end

  local pending_turn = state.pending_checkpoint_turn
  if pending_turn and pending_turn.session_id == state.session_id and pending_turn.entry_index then
    group = string.format('turn:%s:%s', pending_turn.session_id, pending_turn.entry_index)
  else
    state.assistant_merge_group_serial = (tonumber(state.assistant_merge_group_serial) or 0) + 1
    group = 'assistant-group:' .. tostring(state.assistant_merge_group_serial)
  end

  state.active_assistant_merge_group = group
  return group
end

local function assistant_merge_group(entry)
  if type(entry) ~= 'table' then
    return nil
  end
  local group = entry._assistant_merge_group
  if type(group) == 'string' and group ~= '' then
    return group
  end
  return nil
end

local function bind_assistant_merge_group(index)
  if type(index) ~= 'number' then
    return nil
  end
  local entry = state.entries[index]
  if not entry or entry.kind ~= 'assistant' then
    return nil
  end

  local group = assistant_merge_group(entry)
  if group then
    state.active_assistant_merge_group = group
    return group
  end

  group = current_assistant_merge_group(true)
  if group then
    entry._assistant_merge_group = group
  end
  return group
end

local function bind_live_assistant_entry(index)
  if type(index) ~= 'number' then
    return
  end
  local entry = state.entries[index]
  if not entry or entry.kind ~= 'assistant' then
    return
  end
  state.live_assistant_entry_index = index
  bind_assistant_merge_group(index)
end

local function trailing_assistant_entry_index()
  if state.history_loading or state.chat_busy ~= true then
    return nil
  end
  local index = state.live_assistant_entry_index
  if type(index) ~= 'number' then
    return nil
  end
  local entry = state.entries[index]
  if not entry or entry.kind ~= 'assistant' then
    state.live_assistant_entry_index = nil
    return nil
  end
  return index
end

local function bind_active_turn_message_id(index, message_id)
  if type(index) ~= 'number' or not state.entries[index] then
    return
  end
  if type(message_id) ~= 'string' or message_id == '' then
    return
  end
  local pending_key = state.pending_assistant_entry_key
  if type(pending_key) == 'string' and pending_key ~= '' and state.assistant_entries[pending_key] == index then
    state.assistant_entries[pending_key] = nil
    if state.thinking_entry_key == pending_key then
      state.thinking_entry_key = message_id
    end
    state.pending_assistant_entry_key = nil
  end
  state.assistant_entries[message_id] = index
  state.active_turn_assistant_message_id = message_id
end

function M.reset_pending_assistant_entry()
  state.pending_assistant_entry_key = nil
end

-- ── Render-markdown plugin bridge ─────────────────────────────────────────────

function M.notify_render_plugins(bufnr)
  if state.config.chat and state.config.chat.render_markdown == false then
    return
  end
  vim.schedule(function()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if vim.b[bufnr].copilot_agent_treesitter_disabled then
      return
    end
    local ok, rm = pcall(require, 'render-markdown')
    if ok and rm.refresh then
      pcall(rm.refresh)
    end
  end)
end

-- ── Entry helpers ─────────────────────────────────────────────────────────────

function M.should_merge_assistant(idx)
  local current_entry = state.entries[idx]
  if not current_entry or current_entry.kind ~= 'assistant' then
    return false
  end
  local current_group = assistant_merge_group(current_entry)
  for i = idx - 1, 1, -1 do
    local e = state.entries[i]
    if not e then
      return false
    end
    if e.kind ~= 'assistant' then
      return false
    end
    local previous_group = assistant_merge_group(e)
    if current_group or previous_group then
      if current_group == nil or previous_group == nil or previous_group ~= current_group then
        return false
      end
    end
    -- Skip entries that are thinking-only or whitespace-only.
    local trimmed = (e.content or ''):match('^%s*(.-)%s*$')
    if trimmed ~= '' then
      return true
    end
  end
  return false
end

local function collapse_merged_assistant_lines(lines)
  if type(lines) ~= 'table' or #lines == 0 then
    return lines
  end
  table.remove(lines, 1) -- drop the repeated "Assistant:" header
  return lines
end

local function merged_assistant_replace_start(bufnr, default_start)
  default_start = math.max(0, tonumber(default_start) or 0)
  if default_start <= 0 then
    return default_start
  end
  local previous = vim.api.nvim_buf_get_lines(bufnr, default_start - 1, default_start, false)
  if previous[1] == '' then
    return default_start - 1
  end
  return default_start
end

-- Align markdown table columns in a list of lines.
-- Detects consecutive pipe-delimited rows, computes max width per column,
-- then pads each cell. Handles display-width for multibyte/emoji.
local function align_tables(lines)
  local out = {}
  local i = 1
  local n = #lines

  -- Check if a line is a markdown table row (starts with optional whitespace then |)
  local function is_table_row(line)
    return line:match('^%s*|') ~= nil
  end

  -- Parse cells from a table row, trimming whitespace.
  local function parse_cells(line)
    -- Strip leading/trailing pipe
    local inner = line:match('^%s*|(.+)|%s*$')
    if not inner then
      return nil
    end
    local raw = vim.split(inner, '|', { plain = true })
    local cells = {}
    for _, cell in ipairs(raw) do
      cells[#cells + 1] = cell:match('^%s*(.-)%s*$') or ''
    end
    return cells
  end

  -- Check if a row is a separator (all cells are dashes/colons like ---, :--:, ---:)
  local function is_separator_row(cells)
    for _, c in ipairs(cells) do
      if not c:match('^:?%-+:?$') then
        return false
      end
    end
    return true
  end

  -- Display width accounting for multibyte characters and concealed backticks.
  -- At conceallevel=2, treesitter conceals backticks in inline code spans,
  -- so they occupy zero display width.
  local strdisplaywidth = vim.fn.strdisplaywidth
  local function cell_width(text)
    local w = strdisplaywidth(text)
    -- Subtract width of backticks that treesitter will conceal.
    local _, backtick_count = text:gsub('`', '')
    return w - backtick_count
  end

  while i <= n do
    if is_table_row(lines[i]) then
      -- Collect the full table block.
      local block_start = i
      local rows = {} -- { cells = {...}, is_sep = bool, indent = str }
      while i <= n and is_table_row(lines[i]) do
        local indent = lines[i]:match('^(%s*)') or ''
        local cells = parse_cells(lines[i])
        if not cells then
          break
        end
        local sep = is_separator_row(cells)
        rows[#rows + 1] = { cells = cells, is_sep = sep, indent = indent }
        i = i + 1
      end

      if #rows < 2 then
        -- Not really a table, emit as-is.
        for _ in ipairs(rows) do
          out[#out + 1] = lines[block_start]
          block_start = block_start + 1
        end
      else
        -- Compute max column count and widths.
        local max_cols = 0
        for _, row in ipairs(rows) do
          if #row.cells > max_cols then
            max_cols = #row.cells
          end
        end

        local col_widths = {}
        for c = 1, max_cols do
          col_widths[c] = 0
        end
        for _, row in ipairs(rows) do
          if not row.is_sep then
            for c = 1, max_cols do
              local cell = row.cells[c] or ''
              local w = cell_width(cell)
              if w > col_widths[c] then
                col_widths[c] = w
              end
            end
          end
        end

        -- Rebuild each row with padded cells.
        for _, row in ipairs(rows) do
          local parts = {}
          for c = 1, max_cols do
            local cell = row.cells[c] or ''
            if row.is_sep then
              -- Rebuild separator to match column width.
              local prefix = cell:sub(1, 1) == ':' and ':' or ''
              local suffix = cell:sub(-1) == ':' and ':' or ''
              local dash_count = math.max(3, col_widths[c] - #prefix - #suffix)
              parts[#parts + 1] = prefix .. string.rep('-', dash_count) .. suffix
            else
              local pad = col_widths[c] - cell_width(cell)
              parts[#parts + 1] = cell .. string.rep(' ', math.max(0, pad))
            end
          end
          out[#out + 1] = row.indent .. '| ' .. table.concat(parts, ' | ') .. ' |'
        end
      end
    else
      out[#out + 1] = lines[i]
      i = i + 1
    end
  end
  return out
end

local function trim_text(text)
  return (type(text) == 'string' and text or ''):match('^%s*(.-)%s*$') or ''
end

local function classify_content_line(line)
  if type(line) ~= 'string' then
    return 'text'
  end
  if line == '' then
    return 'blank'
  end
  if line:match('^%s+$') then
    return 'soft_blank'
  end

  local trimmed = trim_text(line)
  if trimmed:match('^[-*+]%s+') or trimmed:match('^%d+[.)]%s+') then
    return 'list'
  end
  if trimmed:match('^Done%.$') or trimmed:match('^Status:?') then
    return 'status'
  end
  if trimmed:match('^#+%s+') then
    return 'block'
  end
  if trimmed:match('^```') or trimmed:match('^~~~') then
    return 'block'
  end
  if trimmed:match('^>') then
    return 'block'
  end
  if trimmed:match('^|') then
    return 'table'
  end
  return 'text'
end

local function needs_blank_before(kind, previous_kind)
  if kind == 'list' or kind == 'table' or kind == 'block' then
    return previous_kind == 'text' or previous_kind == 'status'
  end
  if kind == 'status' then
    return previous_kind ~= nil and previous_kind ~= 'status'
  end
  return false
end

local function needs_blank_after(previous_kind, next_kind)
  if previous_kind == 'list' or previous_kind == 'table' or previous_kind == 'block' then
    return next_kind == 'text' or next_kind == 'status'
  end
  if previous_kind == 'status' then
    return next_kind == 'text' or next_kind == 'list'
  end
  return false
end

local function normalize_content_lines(lines)
  local normalized = {}
  local previous_kind
  local in_fence = false

  local function append_blank()
    if #normalized > 0 and normalized[#normalized].line ~= '' then
      normalized[#normalized + 1] = { line = '', kind = 'blank', in_fence = false }
      previous_kind = 'blank'
    end
  end

  for _, line in ipairs(lines or {}) do
    local trimmed = trim_text(line)
    if trimmed:match('^```') or trimmed:match('^~~~') then
      if not in_fence and needs_blank_before('block', previous_kind) then
        append_blank()
      end
      normalized[#normalized + 1] = {
        line = line,
        kind = 'block',
        in_fence = true,
        fence_role = in_fence and 'close' or 'open',
      }
      previous_kind = 'block'
      in_fence = not in_fence
    elseif in_fence then
      normalized[#normalized + 1] = { line = line, kind = 'block', in_fence = true, fence_role = 'body' }
      previous_kind = 'block'
    else
      local kind = classify_content_line(line)
      if kind ~= 'blank' and kind ~= 'soft_blank' then
        if needs_blank_before(kind, previous_kind) then
          append_blank()
        end
        normalized[#normalized + 1] = { line = line, kind = kind, in_fence = false }
        previous_kind = kind
      end
    end
  end

  local with_transitions = {}
  for idx, item in ipairs(normalized) do
    with_transitions[#with_transitions + 1] = item.line
    local next_item = normalized[idx + 1]
    local current_blocks_following = item.in_fence and item.fence_role ~= 'close'
    local next_blocks_spacing = next_item and next_item.in_fence and next_item.fence_role ~= 'close'
    if
      next_item
      and not current_blocks_following
      and not next_blocks_spacing
      and next_item.kind ~= 'blank'
      and needs_blank_after(item.kind, next_item.kind)
    then
      with_transitions[#with_transitions + 1] = ''
    end
  end

  while #with_transitions > 0 and with_transitions[#with_transitions] == '' do
    table.remove(with_transitions)
  end

  return with_transitions
end

local function verbatim_content_lines(lines)
  local preserved = {}
  for _, line in ipairs(lines or {}) do
    if type(line) == 'string' and line:match('^%s+$') then
      preserved[#preserved + 1] = ''
    else
      preserved[#preserved + 1] = line
    end
  end
  return preserved
end

local function activity_entries_visible()
  return state.activity_entries_visible == true
end

local function is_activity_detail_line(line)
  if type(line) ~= 'string' or line == '' then
    return false
  end
  for _, prefix in ipairs(ACTIVITY_DETAIL_PREFIXES) do
    if line:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function activity_preview_text(line)
  if type(line) ~= 'string' or line == '' then
    return ''
  end
  local detail = line:match('^[^—]+ — (.+)$')
  return vim.trim(detail or line)
end

local function collapsed_activity_line(content)
  local lines = normalize_content_lines(split_lines(content))
  local count = 0
  local preview_source
  local fallback_line
  for _, line in ipairs(lines) do
    if type(line) == 'string' and line ~= '' then
      count = count + 1
      fallback_line = fallback_line or line
      if not preview_source and is_activity_detail_line(line) then
        preview_source = line
      end
    end
  end

  if count <= 0 then
    return 'Activity: hidden'
  end
  local count_summary = count == 1 and '1 item hidden' or tostring(count) .. ' items hidden'
  local preview =
    truncate_display_text(activity_preview_text(preview_source or fallback_line), ACTIVITY_PREVIEW_MAX_WIDTH)
  if preview == '' then
    return 'Activity: ' .. count_summary
  end
  return string.format('Activity: %s (%s)', preview, count_summary)
end

local function entry_index_at_row(row)
  row = tonumber(row)
  if not row or row < 0 then
    return nil
  end

  local candidate_row
  local candidate_idx
  for start_row, idx in pairs(state.entry_row_index or {}) do
    if type(start_row) == 'number' and type(idx) == 'number' and start_row <= row then
      if candidate_row == nil or start_row > candidate_row then
        candidate_row = start_row
        candidate_idx = idx
      end
    end
  end
  return candidate_idx
end

local function normalize_activity_detail_text(text)
  if type(text) ~= 'string' then
    return nil
  end
  text = text:gsub('\r\n?', '\n')
  if text == '' then
    return nil
  end
  return text
end

local function append_markdown_heading(lines, heading)
  if #lines > 0 and lines[#lines] ~= '' then
    lines[#lines + 1] = ''
  end
  lines[#lines + 1] = heading
end

local function append_markdown_code_block(lines, heading, text)
  text = normalize_activity_detail_text(text)
  if not text then
    return
  end
  append_markdown_heading(lines, heading)
  for _, line in ipairs(split_lines(text)) do
    lines[#lines + 1] = '    ' .. line
  end
end

local function append_markdown_inspect_block(lines, heading, value)
  if value == nil then
    return
  end
  local ok, text = pcall(vim.inspect, value, { depth = 6 })
  if not ok or type(text) ~= 'string' or text == '' then
    return
  end
  append_markdown_heading(lines, heading)
  for _, line in ipairs(split_lines(text)) do
    lines[#lines + 1] = '    ' .. line
  end
end

local function append_markdown_field(lines, label, value)
  value = type(value) == 'string' and value or nil
  if not value or value == '' then
    return
  end
  lines[#lines + 1] = string.format('- **%s:** %s', label, value)
end

local function build_activity_details_lines(entry)
  local lines = { '# Activity details' }
  local summary = normalize_activity_detail_text(entry and entry.content or '')
  if summary then
    append_markdown_heading(lines, '## Turn summary')
    for _, line in ipairs(split_lines(summary)) do
      lines[#lines + 1] = '- ' .. line
    end
  end

  local items = type(entry) == 'table' and type(entry.activity_items) == 'table' and entry.activity_items or {}
  local tool_count = 0
  for _, item in ipairs(items) do
    if
      type(item) == 'table' and (item.kind == 'tool' or item.output_text or item.partial_output or item.complete_data)
    then
      tool_count = tool_count + 1
      local title = type(item.summary) == 'string' and item.summary ~= '' and item.summary
        or ('Tool ' .. tostring(tool_count))
      append_markdown_heading(lines, string.format('## Tool %d — %s', tool_count, title))
      append_markdown_field(lines, 'Tool', item.tool_name)
      append_markdown_field(lines, 'Command', item.tool_detail)
      append_markdown_field(lines, 'Tool call ID', item.tool_call_id)
      if item.success ~= nil then
        lines[#lines + 1] = string.format('- **Status:** %s', item.success and 'success' or 'failed')
      end
      if type(item.progress_messages) == 'table' and #item.progress_messages > 0 then
        append_markdown_heading(lines, '### Progress')
        for _, message in ipairs(item.progress_messages) do
          lines[#lines + 1] = '- ' .. tostring(message)
        end
      end
      append_markdown_code_block(lines, '### Error', item.error_message)
      append_markdown_code_block(
        lines,
        item.output_text and '### Output' or '### Partial output',
        item.output_text or item.partial_output
      )
      append_markdown_inspect_block(lines, '### Telemetry', item.tool_telemetry)
    end
  end

  if summary == nil and tool_count == 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'No activity details available.'
  end
  return lines
end

local function open_activity_details_float(entry)
  local lines = build_activity_details_lines(entry)
  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.85)), 140)
  local height = math.min(math.max(#lines + 2, 12), math.floor(vim.o.lines * 0.85))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false

  local winid = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Activity details ',
    title_pos = 'center',
  })
  window.protect_markdown_buffer(buf, winid)
  window.set_window_syntax(winid, 'markdown')
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = false

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end

  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc><Esc>', close, { buffer = buf, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<C-c>', close, { buffer = buf, nowait = true })
end

-- entry_lines: format one entry into a list of display lines.
-- align: when true (default), apply align_tables. Pass false during streaming
--        to skip the O(n) table scan on every incremental update.
function M.entry_lines(entry, idx, align)
  if align == nil then
    align = true
  end
  local out = {}
  if entry.kind == 'activity' then
    if not activity_entries_visible() then
      out[#out + 1] = collapsed_activity_line(entry.content)
    else
      out[#out + 1] = 'Activity:'
      for _, l in ipairs(normalize_content_lines(split_lines(entry.content))) do
        out[#out + 1] = '  ' .. l
      end
    end
    out[#out + 1] = ''
  elseif entry.kind == 'system' or entry.kind == 'error' then
    out[#out + 1] = (entry.kind == 'error' and 'Error' or 'System') .. ':'
    for _, l in ipairs(normalize_content_lines(split_lines(entry.content))) do
      out[#out + 1] = '  ' .. l
    end
    out[#out + 1] = ''
  elseif entry.kind == 'assistant' then
    -- Skip entries whose content is only whitespace after trimming.
    local trimmed = (entry.content or ''):match('^%s*(.-)%s*$')
    if trimmed ~= '' then
      out[#out + 1] = 'Assistant:'
      for _, l in ipairs(verbatim_content_lines(split_lines(entry.content))) do
        out[#out + 1] = '  ' .. l
      end
      out[#out + 1] = ''
    end
  else
    out[#out + 1] = 'User:'
    for _, l in ipairs(normalize_content_lines(split_lines(entry.content))) do
      out[#out + 1] = '  ' .. l
    end
    if entry.attachments and #entry.attachments > 0 then
      for _, a in ipairs(entry.attachments) do
        out[#out + 1] = '  📎 ' .. (a.display or a.path or a.type)
      end
    end
    out[#out + 1] = ''
  end
  return align and align_tables(out) or out
end

-- ── Scroll helpers ────────────────────────────────────────────────────────────

local chat_text_height_from_topline
local chat_view_metrics
local chat_view_metrics_summary
local target_topline_for_padding

function M.chat_at_bottom()
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local info = vim.fn.getwininfo(winid)
  if not info or not info[1] then
    return false
  end
  local metrics = chat_view_metrics(winid, bufnr, info[1].topline, 0)
  return metrics.content_rows <= metrics.visible_height
end

local function with_programmatic_chat_scroll(callback)
  state.chat_scroll_guard = (tonumber(state.chat_scroll_guard) or 0) + 1
  local ok, result = pcall(callback)
  vim.defer_fn(function()
    state.chat_scroll_guard = math.max((tonumber(state.chat_scroll_guard) or 1) - 1, 0)
  end, CHAT_SCROLL_GUARD_MS)
  if not ok then
    error(result)
  end
  return result
end

local function set_chat_view(topline, cursor_line)
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local last_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  topline = math.max(1, math.min(math.floor(tonumber(topline) or 1), last_line))
  cursor_line = math.max(1, math.min(math.floor(tonumber(cursor_line) or topline), last_line))

  with_programmatic_chat_scroll(function()
    vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    vim.api.nvim_win_call(winid, function()
      vim.fn.winrestview({ topline = topline })
    end)
  end)
end

function M.scroll_to_bottom()
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local topline, target_metrics = target_topline_for_padding(winid, bufnr, 0, 1)
  local raw_topline = M.overlay_bottom_topline(lc, vim.api.nvim_win_get_height(winid), 0)
  if target_metrics and (target_metrics.wrapped_rows > 0 or raw_topline ~= topline) then
    log(
      string.format(
        'chat scroll_to_bottom target=%d raw_target=%d %s %s',
        topline,
        raw_topline,
        chat_view_metrics_summary(target_metrics),
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
  end
  set_chat_view(topline, lc)
end

local function current_chat_view()
  local winid = state.chat_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local info = vim.fn.getwininfo(winid)
  return info and info[1] or nil
end

chat_text_height_from_topline = function(winid, bufnr, topline)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return 0
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local start_row = math.max(0, math.min(line_count - 1, math.floor(tonumber(topline) or 1) - 1))
  local info = vim.api.nvim_win_text_height(winid, {
    start_row = start_row,
    end_row = line_count - 1,
  })
  if type(info) ~= 'table' or type(info.all) ~= 'number' then
    error('nvim_win_text_height returned invalid metrics')
  end
  return math.max(0, math.floor(info.all + (tonumber(info.fill) or 0)))
end

chat_view_metrics = function(winid, bufnr, topline, padding)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local current_topline = math.max(1, math.min(math.floor(tonumber(topline) or 1), line_count))
  local win_height = math.max(1, vim.api.nvim_win_get_height(winid))
  padding = math.max(0, math.floor(tonumber(padding) or 0))
  local visible_height = math.max(1, win_height - padding)
  local buffer_rows = math.max(0, line_count - current_topline + 1)
  local content_rows = chat_text_height_from_topline(winid, bufnr, current_topline)
  return {
    topline = current_topline,
    line_count = line_count,
    win_height = win_height,
    padding = padding,
    visible_height = visible_height,
    content_rows = content_rows,
    buffer_rows = buffer_rows,
    spare_rows = win_height - content_rows,
    wrapped_rows = math.max(0, content_rows - buffer_rows),
  }
end

chat_view_metrics_summary = function(metrics)
  if type(metrics) ~= 'table' then
    return 'metrics=<nil>'
  end
  return string.format(
    'content_rows=%d visible_rows=%d spare_rows=%d buffer_rows=%d wrapped_rows=%d',
    math.floor(tonumber(metrics.content_rows) or 0),
    math.floor(tonumber(metrics.visible_height) or 0),
    math.floor(tonumber(metrics.spare_rows) or 0),
    math.floor(tonumber(metrics.buffer_rows) or 0),
    math.floor(tonumber(metrics.wrapped_rows) or 0)
  )
end

target_topline_for_padding = function(winid, bufnr, padding, min_topline)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local low = math.max(1, math.min(math.floor(tonumber(min_topline) or 1), line_count))
  local low_metrics = chat_view_metrics(winid, bufnr, low, padding)
  if low_metrics.content_rows <= low_metrics.visible_height then
    return low, low_metrics
  end

  local best = line_count
  local best_metrics = chat_view_metrics(winid, bufnr, best, padding)
  local high = line_count
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local metrics = chat_view_metrics(winid, bufnr, mid, padding)
    if metrics.content_rows <= metrics.visible_height then
      best = mid
      best_metrics = metrics
      high = mid - 1
    else
      low = mid + 1
    end
  end
  return best, best_metrics
end

function M.overlay_bottom_padding(task_line_count, reasoning_line_count)
  local total =
    math.max(0, math.floor(tonumber(task_line_count) or 0) + math.floor(tonumber(reasoning_line_count) or 0))
  if total <= 0 then
    return 0
  end

  local winid = state.chat_winid
  local win_height = (winid and vim.api.nvim_win_is_valid(winid)) and vim.api.nvim_win_get_height(winid) or 0
  if win_height <= 1 then
    return total
  end
  return math.max(1, math.min(win_height - 1, math.max(OVERLAY_BOTTOM_GUTTER_MIN_LINES, total)))
end

local function current_overlay_follow_state()
  local overlay_active = state.chat_busy == true or type(state.overlay_tool_display) == 'table'
  if not overlay_active then
    return {
      task_count = 0,
      reasoning_count = 0,
      padding = 0,
      tail_spacers = 0,
    }
  end

  local enabled, max_lines = reasoning_config()
  local task_lines = activity_overlay_lines(max_lines)
  local reasoning_lines = enabled and M.reasoning_lines(max_lines) or {}
  return {
    task_count = #task_lines,
    reasoning_count = #reasoning_lines,
    padding = M.overlay_bottom_padding(#task_lines, #reasoning_lines),
    tail_spacers = overlay_tail_spacer_lines(),
  }
end

function M.overlay_bottom_topline(line_count, win_height, padding)
  line_count = math.max(1, math.floor(tonumber(line_count) or 1))
  win_height = math.max(1, math.floor(tonumber(win_height) or 1))
  padding = math.max(0, math.floor(tonumber(padding) or 0))
  if padding <= 0 then
    return math.max(1, line_count - win_height + 1)
  end
  local visible_height = math.max(1, win_height - padding)
  return math.max(1, line_count - visible_height + 1)
end

local function auto_follow_active_conversation()
  if state.history_loading then
    return false
  end
  if not state.active_conversation_entry_index then
    return false
  end
  return state.chat_auto_scroll_enabled ~= false
end

local function active_conversation_topline()
  local target_idx = state.active_conversation_entry_index
  if not target_idx then
    return nil
  end
  for row, idx in pairs(state.entry_row_index or {}) do
    if idx == target_idx then
      return row + 1
    end
  end
  return nil
end

function M.reserve_overlay_gutter(task_line_count, reasoning_line_count)
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local view = current_chat_view()
  if not view then
    return
  end

  local padding = M.overlay_bottom_padding(task_line_count, reasoning_line_count)
  if padding <= 0 then
    return
  end

  local current_topline = math.max(1, math.floor(tonumber(view.topline) or 1))
  local current_metrics = chat_view_metrics(winid, bufnr, current_topline, padding)
  local raw_target_topline = M.overlay_bottom_topline(current_metrics.line_count, current_metrics.win_height, padding)
  if current_metrics.content_rows <= current_metrics.visible_height then
    log(
      string.format(
        'reasoning overlay gutter unchanged current=%d target=%d raw_target=%d padding=%d line_count=%d %s %s',
        current_topline,
        current_topline,
        raw_target_topline,
        padding,
        current_metrics.line_count,
        chat_view_metrics_summary(current_metrics),
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
    return
  end

  local target_topline, target_metrics = target_topline_for_padding(winid, bufnr, padding, current_topline)
  if target_topline <= current_topline and current_metrics.content_rows > current_metrics.visible_height then
    log(
      string.format(
        'reasoning overlay gutter constrained current=%d target=%d raw_target=%d padding=%d line_count=%d current_%s target_%s %s',
        current_topline,
        target_topline,
        raw_target_topline,
        padding,
        current_metrics.line_count,
        chat_view_metrics_summary(current_metrics),
        chat_view_metrics_summary(target_metrics),
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
    return
  end

  local restore_view = state.overlay_gutter_restore_view
  if restore_view and (restore_view.winid ~= winid or restore_view.bufnr ~= bufnr) then
    state.overlay_gutter_restore_view = nil
    restore_view = nil
  end
  if not restore_view and not auto_follow_active_conversation() and not M.chat_at_bottom() then
    local cursor = vim.api.nvim_win_get_cursor(winid)
    state.overlay_gutter_restore_view = {
      winid = winid,
      bufnr = bufnr,
      topline = current_topline,
      cursor_line = (cursor and cursor[1]) or current_topline,
    }
    log(
      string.format(
        'reasoning overlay gutter saved restore view top=%d cursor=%d %s',
        state.overlay_gutter_restore_view.topline,
        state.overlay_gutter_restore_view.cursor_line,
        chat_view_log_summary()
      ),
      vim.log.levels.DEBUG
    )
  end

  local step = math.max(1, math.floor(current_metrics.win_height / 2))
  local next_topline = math.min(target_topline, current_topline + step)
  local cursor_line = next_topline
  log(
    string.format(
      'reasoning overlay gutter advanced current=%d target=%d next=%d raw_target=%d step=%d padding=%d line_count=%d current_%s target_%s %s',
      current_topline,
      target_topline,
      next_topline,
      raw_target_topline,
      step,
      padding,
      current_metrics.line_count,
      chat_view_metrics_summary(current_metrics),
      chat_view_metrics_summary(target_metrics),
      chat_view_log_summary()
    ),
    vim.log.levels.DEBUG
  )
  set_chat_view(next_topline, cursor_line)
end

function M.release_overlay_gutter()
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if auto_follow_active_conversation() then
    if state.overlay_gutter_restore_view then
      log(
        'reasoning overlay gutter dropped saved view because active conversation follow resumed',
        vim.log.levels.DEBUG
      )
      state.overlay_gutter_restore_view = nil
    end
    log('reasoning overlay gutter released via active conversation follow', vim.log.levels.DEBUG)
    M.follow_active_conversation(false)
    return
  end

  local restore_view = state.overlay_gutter_restore_view
  if restore_view then
    state.overlay_gutter_restore_view = nil
    if restore_view.winid == winid and restore_view.bufnr == bufnr then
      log(
        string.format(
          'reasoning overlay gutter restored saved view top=%d cursor=%d %s',
          restore_view.topline,
          restore_view.cursor_line or restore_view.topline,
          chat_view_log_summary()
        ),
        vim.log.levels.DEBUG
      )
      set_chat_view(restore_view.topline, restore_view.cursor_line or restore_view.topline)
      return
    end
    log('reasoning overlay gutter dropped stale saved view during release', vim.log.levels.DEBUG)
  end

  if M.chat_at_bottom() then
    log('reasoning overlay gutter released via scroll_to_bottom', vim.log.levels.DEBUG)
    M.scroll_to_bottom()
  end
end

function M.follow_active_conversation(force)
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local anchor_topline = active_conversation_topline()
  if not anchor_topline then
    return false
  end

  if force then
    state.chat_auto_scroll_enabled = true
  elseif state.chat_auto_scroll_enabled == false then
    return false
  end

  local view = current_chat_view()
  if not view then
    return false
  end

  local overlay_state = current_overlay_follow_state()
  local topline = force and anchor_topline or math.max(anchor_topline, state.chat_follow_topline or anchor_topline)
  local win_height = math.max(1, vim.api.nvim_win_get_height(winid))
  local step = math.max(1, math.floor(win_height / 2))
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  if overlay_state.padding > 0 or overlay_state.tail_spacers > 0 then
    local current_metrics = chat_view_metrics(winid, bufnr, topline, overlay_state.padding)
    step = math.max(1, math.floor(current_metrics.win_height / 2))
    last_line = current_metrics.line_count
    if current_metrics.content_rows > current_metrics.visible_height then
      local target_topline, target_metrics = target_topline_for_padding(winid, bufnr, overlay_state.padding, topline)
      local next_topline = math.min(target_topline, topline + step)
      if next_topline > topline then
        log(
          string.format(
            'conversation follow advanced current=%d target=%d next=%d step=%d padding=%d tail_spacers=%d activity=%d reasoning=%d current_%s target_%s %s',
            topline,
            target_topline,
            next_topline,
            step,
            overlay_state.padding,
            overlay_state.tail_spacers,
            overlay_state.task_count,
            overlay_state.reasoning_count,
            chat_view_metrics_summary(current_metrics),
            chat_view_metrics_summary(target_metrics),
            chat_view_log_summary()
          ),
          vim.log.levels.DEBUG
        )
        topline = next_topline
      end
    else
      log(
        string.format(
          'conversation follow unchanged current=%d padding=%d tail_spacers=%d activity=%d reasoning=%d %s %s',
          topline,
          overlay_state.padding,
          overlay_state.tail_spacers,
          overlay_state.task_count,
          overlay_state.reasoning_count,
          chat_view_metrics_summary(current_metrics),
          chat_view_log_summary()
        ),
        vim.log.levels.DEBUG
      )
    end
  elseif last_line > (topline + win_height - 1) then
    topline = math.min(last_line, topline + step)
  end

  state.chat_follow_topline = topline
  set_chat_view(topline, math.min(topline, last_line))
  return true
end

function M.handle_chat_window_scrolled(winid)
  winid = tonumber(winid)
  if not winid or not state.chat_winid or winid ~= state.chat_winid then
    return
  end
  if not vim.api.nvim_win_is_valid(winid) or state.history_loading then
    return
  end
  if (tonumber(state.chat_scroll_guard) or 0) > 0 then
    return
  end

  local view = current_chat_view()
  if not view then
    return
  end

  if state.overlay_gutter_restore_view then
    log(
      string.format(
        'reasoning overlay gutter discarded saved view due to manual scroll new_top=%s new_bot=%s',
        tostring(view.topline),
        tostring(view.botline)
      ),
      vim.log.levels.DEBUG
    )
    state.overlay_gutter_restore_view = nil
  end

  if M.chat_at_bottom() then
    state.chat_auto_scroll_enabled = true
    state.chat_follow_topline = view.topline or state.chat_follow_topline
    return
  end

  if state.active_conversation_entry_index then
    state.chat_auto_scroll_enabled = false
  end
end

-- Highlight chat role headers using extmarks (works alongside treesitter).
-- Only processes lines in [from_row, to_row); callers pass exact ranges
-- so this never scans the full buffer.
highlight_lines = function(bufnr, from_row, to_row)
  vim.api.nvim_buf_clear_namespace(bufnr, CHAT_HL_NS, from_row, to_row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from_row, to_row, false)
  for i, line in ipairs(lines) do
    local row = from_row + i - 1
    if line == 'User:' then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentUser', row, 0, -1)
      local entry_idx = state.entry_row_index[row]
      local entry = entry_idx and state.entries[entry_idx] or nil
      if entry and entry.kind == 'user' then
        local separator_chunks
        if type(entry.checkpoint_id) == 'string' and entry.checkpoint_id ~= '' then
          separator_chunks = checkpoint_separator_chunks(entry.checkpoint_id)
        elseif entry_idx > 1 then
          separator_chunks = plain_separator_chunks()
        end
        if separator_chunks then
          vim.api.nvim_buf_set_extmark(bufnr, CHAT_HL_NS, row, 0, {
            virt_lines = { separator_chunks },
            virt_lines_above = true,
            virt_lines_leftcol = true,
          })
        end
      end
    elseif line == 'Assistant:' then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentAssistant', row, 0, -1)
    elseif line:match('^Activity:') or line == 'System:' then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentActivity', row, 0, -1)
    elseif line:match('^%s*Done%.$') then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentDone', row, 0, -1)
    end
  end
end

function M.toggle_activity_entries()
  state.activity_entries_visible = not activity_entries_visible()
  M.reset_frozen_render()
  M.render_chat()
  return state.activity_entries_visible
end

function M.show_activity_details_under_cursor(winid)
  winid = winid or state.chat_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local entry_idx = entry_index_at_row((cursor and cursor[1] or 1) - 1)
  local entry = entry_idx and state.entries[entry_idx] or nil
  if not entry or entry.kind ~= 'activity' then
    notify('Move the cursor onto an Activity block first', vim.log.levels.INFO)
    return false
  end

  open_activity_details_float(entry)
  return true
end

-- ── Full render ───────────────────────────────────────────────────────────────

-- Reset the frozen-render watermark so the next render_chat() rebuilds the
-- entire buffer.  Call this before render_chat() whenever the buffer content
-- may be structurally inconsistent (session switch, history load, checkpoint
-- restore, manual refresh, transcript clear).
function M.reset_frozen_render()
  state._frozen_entry_count = 0
  state._frozen_line_count = 0
end

-- Snapshot the current buffer as the frozen watermark.  Called when the user
-- sends a new prompt so that all prior entries (the previous conversation)
-- are treated as immutable — only the new conversation is re-rendered.
function M.freeze_current_buffer()
  local bufnr = state.chat_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  state._frozen_entry_count = #state.entries
  state._frozen_line_count = state._rendered_line_count or vim.api.nvim_buf_line_count(bufnr)
end

-- Debounced stream update state: declared here so render_chat can cancel
-- pending updates when it takes over a full redraw of the streaming entry.
local stream_timer = uv.new_timer()
local stream_pending = false

function M.render_chat()
  state.render_pending = false
  if state.history_loading then
    return
  end
  local bufnr = state.chat_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local at_bottom = M.chat_at_bottom()
  state._spinner_line = nil

  -- ── Frozen-render optimisation ──────────────────────────────────────────────
  -- `frozen_entries` / `frozen_lines` describe a prefix of the buffer that is
  -- already correct and can be left untouched.  Only entries after the
  -- watermark are re-rendered, and only the corresponding buffer region is
  -- replaced + re-highlighted.
  local frozen_entries = state._frozen_entry_count or 0
  local frozen_lines = state._frozen_line_count or 0
  local tail_spacer_lines = overlay_tail_spacer_lines()

  -- Validate: if entries were removed or the buffer was externally truncated,
  -- fall back to a full render.
  if frozen_entries > 0 then
    if frozen_entries > #state.entries or vim.api.nvim_buf_line_count(bufnr) < frozen_lines then
      frozen_entries = 0
      frozen_lines = 0
    end
  end

  local lines = {}
  local entry_start_idx

  if frozen_entries > 0 and #state.entries > 0 then
    -- ── Incremental path: keep frozen lines, rebuild the rest ──
    entry_start_idx = frozen_entries + 1
    -- Preserve entry_row_index for frozen rows; clear non-frozen rows.
    for row, _ in pairs(state.entry_row_index) do
      if row >= frozen_lines then
        state.entry_row_index[row] = nil
      end
    end
  else
    -- ── Full path: rebuild everything from scratch ──
    frozen_lines = 0
    entry_start_idx = 1
    state.entry_row_index = {}

    lines[#lines + 1] = state.config.chat.title
    lines[#lines + 1] = 'service: ' .. normalize_base_url(state.config.base_url)
    lines[#lines + 1] = 'session: ' .. (state.session_id or '<none>')
    lines[#lines + 1] = 'commands: :CopilotAgentNewSession  :CopilotAgentAsk  :CopilotAgentStop'

    if #state.entries == 0 then
      lines[#lines + 1] = 'No messages yet.'
      lines[#lines + 1] = 'Press i or <Enter> to open the input buffer.'
      lines[#lines + 1] = 'Run :CopilotAgentAsk to send a prompt from the command line.'
    end
  end

  -- ── Build lines for non-frozen entries ──
  local streaming_entry_line_start
  for idx = entry_start_idx, #state.entries do
    local entry = state.entries[idx]
    local elines = M.entry_lines(entry, idx)
    if #elines > 0 then
      if entry.kind == 'assistant' and M.should_merge_assistant(idx) then
        if #lines > 0 and lines[#lines] == '' then
          table.remove(lines)
        end
        elines = collapse_merged_assistant_lines(elines)
      end
      state.entry_row_index[frozen_lines + #lines] = idx
      -- Track where the streaming assistant entry starts so stream_update
      -- can replace from the correct position after a full render.
      if entry.kind == 'assistant' and idx == state.active_turn_assistant_index then
        streaming_entry_line_start = frozen_lines + #lines
      end
      for _, l in ipairs(elines) do
        lines[#lines + 1] = l
      end
    end
  end

  local total_lines = frozen_lines + #lines
  append_blank_lines(lines, tail_spacer_lines)
  -- When actively streaming, preserve stream_line_start so a pending
  -- stream_update replaces the correct region instead of appending after
  -- the full render's output — the root cause of live duplicate lines.
  if state.chat_busy and streaming_entry_line_start then
    state.stream_line_start = streaming_entry_line_start
    -- Cancel any in-flight stream timer whose stale callback would
    -- recalculate stream_line_start from _rendered_line_count (the end
    -- of the buffer), which would append the entry a second time.
    stream_timer:stop()
    stream_pending = false
    log(
      string.format(
        'render_chat preserved streaming start idx=%s start=%d total_lines=%d',
        tostring(state.active_turn_assistant_index or '<none>'),
        state.stream_line_start,
        total_lines
      ),
      vim.log.levels.DEBUG
    )
  else
    state.stream_line_start = nil
  end
  -- Cache the total rendered line count so incremental updates can use it.
  state._rendered_line_count = total_lines
  state.chat_tail_spacer_lines = tail_spacer_lines

  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, frozen_lines, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  vim.api.nvim_buf_clear_namespace(bufnr, CHAT_HL_NS, frozen_lines, -1)
  highlight_lines(bufnr, frozen_lines, total_lines)
  -- Refresh chat statusline via lazy require to avoid circular deps.
  local sl = require('copilot_agent.statusline')
  sl.refresh_chat_statusline()

  local followed = auto_follow_active_conversation() and M.follow_active_conversation(false)
  if not followed and at_bottom then
    M.scroll_to_bottom()
  end
  M.notify_render_plugins(bufnr)
  M.refresh_reasoning_overlay()

  -- ── Advance frozen watermark ────────────────────────────────────────────────
  -- Only freeze when the transcript is stable: not streaming and no pending
  -- checkpoint callbacks that could mutate existing entries.
  if #state.entries > 0 and not state.chat_busy and (state.pending_checkpoint_ops or 0) == 0 then
    state._frozen_entry_count = #state.entries
    state._frozen_line_count = total_lines
  end
end

-- ── Debounced / incremental render ────────────────────────────────────────────

function M.schedule_render()
  if state.render_pending or state.history_loading then
    return
  end
  state.render_pending = true
  vim.defer_fn(M.render_chat, RENDER_DEBOUNCE_MS)
end

-- stream_timer / stream_pending are declared above render_chat() so both
-- render_chat and stream_update can reference them.

function M.stream_update(entry, idx)
  if state.history_loading then
    return
  end
  -- Stash latest entry/idx so the deferred callback uses the most recent data.
  state._stream_entry = entry
  state._stream_idx = idx
  if stream_pending then
    if entry.kind == 'assistant' then
      -- log(
      -- string.format(
      -- 'assistant stream update coalesced idx=%s content_len=%d content=%s',
      -- tostring(idx or '<none>'),
      -- #((entry and entry.content) or ''),
      -- preview_log_text((entry and entry.content) or '')
      -- ),
      -- vim.log.levels.DEBUG
      -- )
    end
    return
  end
  stream_pending = true
  stream_timer:start(
    STREAM_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      stream_pending = false
      local e = state._stream_entry
      local i = state._stream_idx
      if not e or not i then
        return
      end
      local bufnr = state.chat_bufnr
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      local new_lines = M.entry_lines(e, i, false) -- skip align_tables during streaming
      local merge_assistant = e.kind == 'assistant' and M.should_merge_assistant(i)
      if merge_assistant and #new_lines > 0 then
        new_lines = collapse_merged_assistant_lines(new_lines)
      end

      if not state.stream_line_start then
        -- First update for this entry: use cached line count or buffer line count
        -- to find where to start appending — avoids a full render_chat().
        local total = rendered_content_line_count(bufnr)
        if merge_assistant then
          total = merged_assistant_replace_start(bufnr, total)
        end
        state.stream_line_start = total
        if e.kind == 'assistant' then
          log(
            string.format(
              'assistant stream update initialized start idx=%s start=%d merge_assistant=%s rendered_lines=%d',
              tostring(i or '<none>'),
              state.stream_line_start,
              tostring(merge_assistant),
              tonumber(state._rendered_line_count) or -1
            ),
            vim.log.levels.DEBUG
          )
        end
      end

      local at_bottom = M.chat_at_bottom()
      local content_end = rendered_content_line_count(bufnr)
      if e.kind == 'assistant' then
        log(
          string.format(
            'assistant stream update applying idx=%s start=%d line_count=%d merge_assistant=%s content_len=%d content=%s',
            tostring(i or '<none>'),
            tonumber(state.stream_line_start) or -1,
            #new_lines,
            tostring(merge_assistant),
            #((e and e.content) or ''),
            preview_log_text((e and e.content) or '')
          ),
          vim.log.levels.DEBUG
        )
      end
      vim.bo[bufnr].modifiable = true
      vim.bo[bufnr].readonly = false
      vim.api.nvim_buf_set_lines(bufnr, state.stream_line_start, content_end, false, new_lines)
      highlight_lines(bufnr, state.stream_line_start, state.stream_line_start + #new_lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      state._rendered_line_count = state.stream_line_start + #new_lines
      local followed = auto_follow_active_conversation() and M.follow_active_conversation(false)
      if not followed and at_bottom then
        M.scroll_to_bottom()
      end
      M.refresh_reasoning_overlay()
    end)
  )
end

-- ── Transcript helpers ────────────────────────────────────────────────────────

function M.append_entry(kind, content, attachments, opts)
  opts = opts or {}
  local entry = {
    kind = kind,
    content = content or '',
    attachments = attachments,
  }
  if type(opts.checkpoint_id) == 'string' and opts.checkpoint_id ~= '' then
    entry.checkpoint_id = opts.checkpoint_id
  end
  if kind == 'activity' and type(opts.activity_items) == 'table' and #opts.activity_items > 0 then
    entry.activity_items = vim.deepcopy(opts.activity_items)
  end

  if kind == 'user' then
    -- User messages always begin a fresh assistant turn, including when we are
    -- rebuilding history. Clearing the active group here keeps replayed
    -- assistant blocks aligned with their original turn boundaries.
    state.active_assistant_merge_group = nil
  end

  -- When the user sends a new prompt, freeze everything rendered so far so
  -- that subsequent render_chat() calls only rebuild the current conversation.
  if kind == 'user' and not state.history_loading then
    M.freeze_current_buffer()
  end

  table.insert(state.entries, entry)
  local idx = #state.entries
  if kind == 'assistant' then
    bind_assistant_merge_group(idx)
  end
  if kind == 'user' and not state.history_loading then
    state.active_conversation_entry_index = idx
    state.chat_follow_topline = nil
    state.chat_auto_scroll_enabled = true
  end
  state.stream_line_start = nil

  -- Try incremental append instead of full re-render.
  local bufnr = state.chat_bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local new_lines = M.entry_lines(entry, idx)
    if #new_lines > 0 then
      local merge_assistant = kind == 'assistant' and M.should_merge_assistant(idx)
      if merge_assistant then
        new_lines = collapse_merged_assistant_lines(new_lines)
      end
      local at_bottom = M.chat_at_bottom()
      local content_end = rendered_content_line_count(bufnr)
      local insert_start = content_end
      if merge_assistant then
        insert_start = merged_assistant_replace_start(bufnr, content_end)
      end
      state.entry_row_index[insert_start] = idx
      vim.bo[bufnr].modifiable = true
      vim.bo[bufnr].readonly = false
      vim.api.nvim_buf_set_lines(bufnr, insert_start, content_end, false, new_lines)
      highlight_lines(bufnr, insert_start, insert_start + #new_lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      state._rendered_line_count = insert_start + #new_lines
      if kind == 'user' then
        M.follow_active_conversation(true)
      else
        local followed = auto_follow_active_conversation() and M.follow_active_conversation(false)
        if not followed and at_bottom then
          M.scroll_to_bottom()
        end
      end
    end
  else
    M.schedule_render()
  end
  return idx
end

function M.ensure_assistant_entry(message_id)
  local active_index = active_turn_entry_index()
  if active_index then
    bind_active_turn_message_id(active_index, message_id)
    local active_key = (type(message_id) == 'string' and message_id ~= '' and message_id)
      or state.active_turn_assistant_message_id
      or pending_assistant_entry_key()
    bind_live_assistant_entry(active_index)
    return state.entries[active_index], active_index, active_key
  end

  local key = message_id
  if type(message_id) == 'string' and message_id ~= '' then
    local adopted_index = adopt_pending_assistant_entry(message_id)
    if adopted_index and state.entries[adopted_index] then
      state.active_turn_assistant_index = adopted_index
      state.active_turn_assistant_message_id = message_id
      bind_live_assistant_entry(adopted_index)
      return state.entries[adopted_index], adopted_index, message_id
    end
  else
    key = pending_assistant_entry_key()
  end

  local index = state.assistant_entries[key]
  if index and state.entries[index] then
    if type(message_id) == 'string' and message_id ~= '' then
      state.pending_assistant_entry_key = nil
      state.active_turn_assistant_message_id = message_id
    end
    state.active_turn_assistant_index = index
    bind_live_assistant_entry(index)
    return state.entries[index], index, key
  end

  local trailing_index = trailing_assistant_entry_index()
  if trailing_index and state.entries[trailing_index] then
    state.assistant_entries[key] = trailing_index
    state.active_turn_assistant_index = trailing_index
    bind_live_assistant_entry(trailing_index)
    if type(message_id) == 'string' and message_id ~= '' then
      bind_active_turn_message_id(trailing_index, message_id)
      return state.entries[trailing_index], trailing_index, message_id
    end
    return state.entries[trailing_index], trailing_index, key
  end

  table.insert(state.entries, {
    kind = 'assistant',
    content = '',
  })
  index = #state.entries
  state.assistant_entries[key] = index
  state.active_turn_assistant_index = index
  if type(message_id) == 'string' and message_id ~= '' then
    state.active_turn_assistant_message_id = message_id
  end
  bind_live_assistant_entry(index)
  return state.entries[index], index, key
end

function M.clear_transcript()
  state.entries = {}
  state.assistant_entries = {}
  state.pending_assistant_entry_key = nil
  state.active_turn_assistant_index = nil
  state.live_assistant_entry_index = nil
  state.active_turn_assistant_message_id = nil
  state.active_assistant_merge_group = nil
  state.assistant_merge_group_serial = 0
  state.stream_line_start = nil
  state.entry_row_index = {}
  state.pending_checkpoint_turn = nil
  state.active_tool = nil
  state.active_tool_run_id = nil
  state.active_tool_detail = nil
  state.pending_tool_detail = nil
  state.overlay_tool_display = nil
  state.overlay_tool_queue = {}
  state.overlay_tool_schedule_token = (tonumber(state.overlay_tool_schedule_token) or 0) + 1
  state.recent_activity_lines = {}
  state.recent_activity_items = {}
  state.recent_activity_tool_calls = {}
  state.active_conversation_entry_index = nil
  state.chat_follow_topline = nil
  state.chat_auto_scroll_enabled = true
  state.chat_scroll_guard = 0
  state.chat_tail_spacer_lines = 0
  state.overlay_gutter_restore_view = nil
  state.current_intent = nil
  state.context_tokens = nil
  state.context_limit = nil
  state.history_checkpoint_ids = nil
  state.history_pending_user_entries = {}
  state._rendered_line_count = nil
  M.reset_frozen_render()
  M.clear_reasoning_preview()
  M.schedule_render()
end

return M
