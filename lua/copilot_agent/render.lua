-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Chat buffer rendering: entry formatting, highlights, streaming, spinner.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local utils = require('copilot_agent.utils')
local state = cfg.state
local log = cfg.log
local normalize_base_url = cfg.normalize_base_url

local M = {}

local highlight_lines -- forward declaration; defined below

local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local CHAT_HL_NS = vim.api.nvim_create_namespace('copilot_agent_chat')
local REASONING_NS = vim.api.nvim_create_namespace('copilot_agent_reasoning')
local RENDER_DEBOUNCE_MS = 150
local STREAM_DEBOUNCE_MS = 80
local REASONING_DEBOUNCE_MS = 80
local SPINNER_INTERVAL_MS = 500

local is_thinking_content = utils.is_thinking_content
local split_lines = utils.split_lines

local function refresh_statuslines()
  local ok, sl = pcall(require, 'copilot_agent.statusline')
  if ok and type(sl.refresh_statuslines) == 'function' then
    sl.refresh_statuslines()
  end
end

local function reasoning_config()
  local reasoning = (((state.config or {}).chat or {}).reasoning or {})
  local enabled = reasoning.enabled == true
  local max_lines = tonumber(reasoning.max_lines) or 5
  max_lines = math.max(1, math.min(20, math.floor(max_lines)))
  return enabled, max_lines
end

local function normalize_reasoning_lines(text)
  if type(text) ~= 'string' or text == '' then
    return {}
  end
  local lines = vim.split(text:gsub('\r\n?', '\n'), '\n', { plain = true })
  while #lines > 0 and lines[#lines] == '' do
    table.remove(lines)
  end
  return lines
end

function M.reasoning_lines(max_lines)
  local lines = vim.deepcopy(state.reasoning_lines or {})
  if max_lines == nil then
    max_lines = select(2, reasoning_config())
  else
    max_lines = math.max(1, math.floor(tonumber(max_lines) or 5))
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

local function truncate_overlay_text(text, max_len)
  text = type(text) == 'string' and text:gsub('%s+', ' '):match('^%s*(.-)%s*$') or ''
  if text == '' then
    return ''
  end
  max_len = math.max(1, math.floor(tonumber(max_len) or 72))
  if #text > max_len then
    return text:sub(1, max_len - 1) .. '…'
  end
  return text
end

local function preview_log_text(text, max_len)
  if type(text) ~= 'string' then
    return '<non-string>'
  end
  local preview = text:gsub('\r\n?', '\n'):gsub('\n', '\\n'):gsub('\t', '\\t')
  max_len = math.max(16, math.floor(tonumber(max_len) or 120))
  if #preview > max_len then
    return preview:sub(1, max_len - 1) .. '…'
  end
  return preview
end

local function tool_is_displayable_in_overlay(name)
  if type(name) ~= 'string' or name == '' then
    return false
  end
  local normalized = vim.trim(name):lower()
  if normalized == 'bash' or normalized == 'sh' or normalized == 'zsh' or normalized == 'fish' or normalized == 'pwsh' or normalized == 'powershell' or normalized == 'cmd' then
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
  if type(overlay_tool.detail) == 'string' and overlay_tool.detail ~= '' and overlay_tool.detail ~= overlay_tool.tool then
    line = line .. ' — ' .. overlay_tool.detail
  end
  return {
    '🔧 ' .. truncate_overlay_text(line, 72),
  }
end

local function append_overlay_section(virt_lines, lines, first_prefix, other_prefix, highlight)
  for idx, line in ipairs(lines) do
    local prefix = idx == 1 and first_prefix or other_prefix
    virt_lines[#virt_lines + 1] = {
      { prefix .. line, highlight },
    }
  end
end

local function reasoning_virtual_lines(task_lines, reasoning_lines)
  local virt_lines = {}
  append_overlay_section(virt_lines, task_lines, '  Activity: ', '            ', 'CopilotAgentActivity')
  append_overlay_section(virt_lines, reasoning_lines, '  Reasoning: ', '             ', 'CopilotAgentReasoning')
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
  local winid = state.chat_winid
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    local info = vim.fn.getwininfo(winid)[1]
    local botline = info and tonumber(info.botline) or nil
    if botline and botline > 0 then
      return math.max(math.min(botline, line_count) - 1, 0), true
    end
  end
  return math.max(line_count - 1, 0), false
end

local function update_reasoning_overlay_now()
  clear_reasoning_overlay()

  local enabled, max_lines = reasoning_config()
  if not enabled or state.history_loading then
    log(string.format('reasoning overlay skipped enabled=%s history_loading=%s', tostring(enabled), tostring(state.history_loading)), vim.log.levels.DEBUG)
    return
  end

  local bufnr = state.chat_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    log('reasoning overlay skipped chat buffer unavailable', vim.log.levels.DEBUG)
    return
  end

  local task_lines = activity_overlay_lines(max_lines)
  local reasoning_lines = M.reasoning_lines(max_lines)
  if #task_lines == 0 and #reasoning_lines == 0 then
    -- log('reasoning overlay skipped no activity or reasoning lines available', vim.log.levels.DEBUG)
    return
  end

  local anchor_row, anchor_above = overlay_anchor(bufnr)
  vim.api.nvim_buf_set_extmark(bufnr, REASONING_NS, anchor_row, 0, {
    virt_lines = reasoning_virtual_lines(task_lines, reasoning_lines),
    virt_lines_leftcol = true,
    virt_lines_above = anchor_above,
  })
  log(string.format('reasoning overlay updated activity=%d reasoning=%d anchor_row=%d above=%s', #task_lines, #reasoning_lines, anchor_row, tostring(anchor_above)), vim.log.levels.DEBUG)
end

function M.refresh_reasoning_overlay(immediate)
  if immediate then
    reasoning_timer:stop()
    reasoning_refresh_pending = false
    reasoning_last_refresh_ms = overlay_now_ms()
    vim.schedule(update_reasoning_overlay_now)
    return
  end

  local now = overlay_now_ms()
  local elapsed = now - (reasoning_last_refresh_ms or 0)
  if not reasoning_refresh_pending and (reasoning_last_refresh_ms == 0 or elapsed >= REASONING_DEBOUNCE_MS) then
    reasoning_last_refresh_ms = now
    vim.schedule(update_reasoning_overlay_now)
    return
  end

  local delay = math.max(1, REASONING_DEBOUNCE_MS - elapsed)
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
  state.reasoning_entry_key = nil
  state.reasoning_text = ''
  state.reasoning_lines = {}
  refresh_statuslines()
  M.refresh_reasoning_overlay(true)
  if had_reasoning then
    log('reasoning preview cleared (' .. tostring(reason or 'unspecified') .. ')', vim.log.levels.DEBUG)
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
      'reasoning delta appended key=%s chunk_len=%d total_len=%d lines=%d',
      tostring(state.reasoning_entry_key or '<none>'),
      #delta,
      #(state.reasoning_text or ''),
      #(state.reasoning_lines or {})
    ),
    vim.log.levels.DEBUG
  )
  M.refresh_reasoning_overlay()
  refresh_statuslines()
end

local function separator_rule_width()
  local win = state.chat_winid
  if win and vim.api.nvim_win_is_valid(win) then
    return math.max(24, vim.api.nvim_win_get_width(win) - 2)
  end
  return 72
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
    state.pending_assistant_entry_key = string.format('pending:%s:%s', pending_turn.session_id, pending_turn.entry_index)
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

-- ── Thinking spinner ──────────────────────────────────────────────────────────

function M.stop_thinking_spinner()
  if state.thinking_timer then
    pcall(function()
      state.thinking_timer:stop()
    end)
    pcall(function()
      state.thinking_timer:close()
    end)
    state.thinking_timer = nil
  end
  state.thinking_entry_key = nil
  state._spinner_line = nil
end

function M.reset_pending_assistant_entry()
  state.pending_assistant_entry_key = nil
end

function M.start_thinking_spinner(entry_key)
  M.stop_thinking_spinner()
  state.thinking_entry_key = entry_key
  state.thinking_frame = 1
  state._spinner_line = nil -- buffer row of the spinner text (0-indexed)
  M.schedule_render()
  local timer = uv.new_timer()
  state.thinking_timer = timer
  timer:start(
    0,
    SPINNER_INTERVAL_MS,
    vim.schedule_wrap(function()
      if not state.thinking_timer then
        return
      end
      state.thinking_frame = (state.thinking_frame % #SPINNER_FRAMES) + 1
      local bufnr = state.chat_bufnr
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local row = state._spinner_line
      if row then
        -- Fast path: just replace the single spinner line in-place.
        local text = '  ' .. (SPINNER_FRAMES[state.thinking_frame] or '⠋') .. ' Thinking…'
        pcall(function()
          vim.bo[bufnr].modifiable = true
          vim.bo[bufnr].readonly = false
          vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { text })
          vim.bo[bufnr].modifiable = false
          vim.bo[bufnr].readonly = true
          vim.bo[bufnr].modified = false
        end)
      else
        M.schedule_render()
      end
    end)
  )
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
  for i = idx - 1, 1, -1 do
    local e = state.entries[i]
    if not e then
      return false
    end
    if e.kind ~= 'assistant' then
      return false
    end
    -- Skip entries that are thinking-only or whitespace-only.
    local trimmed = (e.content or ''):match('^%s*(.-)%s*$')
    if not is_thinking_content(e.content) and trimmed ~= '' then
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
    if next_item and not current_blocks_following and not next_blocks_spacing and next_item.kind ~= 'blank' and needs_blank_after(item.kind, next_item.kind) then
      with_transitions[#with_transitions + 1] = ''
    end
  end

  while #with_transitions > 0 and with_transitions[#with_transitions] == '' do
    table.remove(with_transitions)
  end

  return with_transitions
end

-- entry_lines: format one entry into a list of display lines.
-- align: when true (default), apply align_tables. Pass false during streaming
--        to skip the O(n) table scan on every incremental update.
function M.entry_lines(entry, idx, align)
  if align == nil then
    align = true
  end
  local out = {}
  if entry.kind == 'system' or entry.kind == 'error' then
    out[#out + 1] = (entry.kind == 'error' and 'Error' or 'System') .. ':'
    for _, l in ipairs(normalize_content_lines(split_lines(entry.content))) do
      out[#out + 1] = '  ' .. l
    end
    out[#out + 1] = ''
  elseif entry.kind == 'assistant' then
    if is_thinking_content(entry.content) then
      if state.chat_busy and active_thinking_entry_index() == idx then
        out[#out + 1] = 'Assistant:'
        out[#out + 1] = '  ' .. (SPINNER_FRAMES[state.thinking_frame] or '⠋') .. ' Thinking…'
        out[#out + 1] = ''
      end
    else
      -- Skip entries whose content is only whitespace after trimming.
      local trimmed = (entry.content or ''):match('^%s*(.-)%s*$')
      if trimmed ~= '' then
        out[#out + 1] = 'Assistant:'
        for _, l in ipairs(normalize_content_lines(split_lines(entry.content))) do
          out[#out + 1] = '  ' .. l
        end
        out[#out + 1] = ''
      end
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
  local lc = vim.api.nvim_buf_line_count(bufnr)
  return info[1].botline >= lc - 3
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
  -- Use API-only calls to avoid triggering extra redraws from normal-mode commands.
  vim.api.nvim_win_set_cursor(winid, { lc, 0 })
  local win_height = vim.api.nvim_win_get_height(winid)
  local topline = math.max(1, lc - win_height + 1)
  vim.api.nvim_win_call(winid, function()
    vim.fn.winrestview({ topline = topline })
  end)
end

local function current_chat_view()
  local winid = state.chat_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local info = vim.fn.getwininfo(winid)
  return info and info[1] or nil
end

local function live_turn_follow_active()
  if state.history_loading then
    return false
  end
  if not state.active_conversation_entry_index then
    return false
  end
  return state.chat_busy == true or state.pending_checkpoint_turn ~= nil
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

  local view = current_chat_view()
  if not view then
    return false
  end

  if not force and state.chat_follow_topline and math.abs((view.topline or 0) - state.chat_follow_topline) > 1 then
    state.active_conversation_entry_index = nil
    state.chat_follow_topline = nil
    return false
  end

  local win_height = math.max(1, vim.api.nvim_win_get_height(winid))
  local step = math.max(1, math.floor(win_height / 2))
  local topline = math.max(anchor_topline, state.chat_follow_topline or anchor_topline)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  if last_line > (topline + win_height - 1) then
    topline = topline + step
  end

  state.chat_follow_topline = topline
  vim.api.nvim_win_set_cursor(winid, { math.min(anchor_topline, last_line), 0 })
  vim.api.nvim_win_call(winid, function()
    vim.fn.winrestview({ topline = topline })
  end)
  return true
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
    elseif line:match('^%s*Done%.$') then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentDone', row, 0, -1)
    end
  end
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
      if entry.kind == 'assistant' and is_thinking_content(entry.content) and active_thinking_entry_index() == idx then
        state._spinner_line = frozen_lines + #lines + 1
      end
      if entry.kind == 'assistant' and not is_thinking_content(entry.content) and M.should_merge_assistant(idx) then
        if #lines > 0 and lines[#lines] == '' then
          table.remove(lines)
        end
        elines = collapse_merged_assistant_lines(elines)
      end
      if entry.kind == 'user' then
        state.entry_row_index[frozen_lines + #lines] = idx
      end
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
      string.format('render_chat preserved streaming start idx=%s start=%d total_lines=%d', tostring(state.active_turn_assistant_index or '<none>'), state.stream_line_start, total_lines),
      vim.log.levels.DEBUG
    )
  else
    state.stream_line_start = nil
  end
  -- Cache the total rendered line count so incremental updates can use it.
  state._rendered_line_count = total_lines

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

  local force_follow = live_turn_follow_active()
  local followed = M.follow_active_conversation(force_follow)
  if not followed and at_bottom and not force_follow then
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
      log(
        string.format(
          'assistant stream update coalesced idx=%s content_len=%d content=%s',
          tostring(idx or '<none>'),
          #((entry and entry.content) or ''),
          preview_log_text((entry and entry.content) or '')
        ),
        vim.log.levels.DEBUG
      )
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
      local merge_assistant = e.kind == 'assistant' and not is_thinking_content(e.content) and M.should_merge_assistant(i)
      if merge_assistant and #new_lines > 0 then
        new_lines = collapse_merged_assistant_lines(new_lines)
      end

      if not state.stream_line_start then
        -- First update for this entry: use cached line count or buffer line count
        -- to find where to start appending — avoids a full render_chat().
        local total = state._rendered_line_count or vim.api.nvim_buf_line_count(bufnr)
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
      vim.api.nvim_buf_set_lines(bufnr, state.stream_line_start, -1, false, new_lines)
      highlight_lines(bufnr, state.stream_line_start, state.stream_line_start + #new_lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      local force_follow = live_turn_follow_active()
      local followed = M.follow_active_conversation(force_follow)
      if not followed and at_bottom and not force_follow then
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

  -- When the user sends a new prompt, freeze everything rendered so far so
  -- that subsequent render_chat() calls only rebuild the current conversation.
  if kind == 'user' and not state.history_loading then
    M.freeze_current_buffer()
  end

  table.insert(state.entries, entry)
  local idx = #state.entries
  if kind == 'user' and not state.history_loading then
    state.active_conversation_entry_index = idx
    state.chat_follow_topline = nil
  end
  state.stream_line_start = nil

  -- Try incremental append instead of full re-render.
  local bufnr = state.chat_bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local new_lines = M.entry_lines(entry, idx)
    if #new_lines > 0 then
      local merge_assistant = kind == 'assistant' and not is_thinking_content(content) and M.should_merge_assistant(idx)
      if merge_assistant then
        new_lines = collapse_merged_assistant_lines(new_lines)
      end
      local at_bottom = M.chat_at_bottom()
      local lc = vim.api.nvim_buf_line_count(bufnr)
      local insert_start = lc
      if merge_assistant then
        insert_start = merged_assistant_replace_start(bufnr, lc)
      end
      if kind == 'user' then
        state.entry_row_index[lc] = idx
      end
      vim.bo[bufnr].modifiable = true
      vim.bo[bufnr].readonly = false
      vim.api.nvim_buf_set_lines(bufnr, insert_start, -1, false, new_lines)
      highlight_lines(bufnr, insert_start, insert_start + #new_lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      state._rendered_line_count = insert_start + #new_lines
      if kind == 'user' then
        M.follow_active_conversation(true)
      else
        local force_follow = live_turn_follow_active()
        local followed = M.follow_active_conversation(force_follow)
        if not followed and at_bottom and not force_follow then
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
    local active_key = (type(message_id) == 'string' and message_id ~= '' and message_id) or state.active_turn_assistant_message_id or pending_assistant_entry_key()
    return state.entries[active_index], active_index, active_key
  end

  local key = message_id
  if type(message_id) == 'string' and message_id ~= '' then
    local adopted_index = adopt_pending_assistant_entry(message_id)
    if adopted_index and state.entries[adopted_index] then
      state.active_turn_assistant_index = adopted_index
      state.active_turn_assistant_message_id = message_id
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
    return state.entries[index], index, key
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
  return state.entries[index], index, key
end

function M.clear_transcript()
  state.entries = {}
  state.assistant_entries = {}
  state.pending_assistant_entry_key = nil
  state.active_turn_assistant_index = nil
  state.active_turn_assistant_message_id = nil
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
  state.active_conversation_entry_index = nil
  state.chat_follow_topline = nil
  state.current_intent = nil
  state.context_tokens = nil
  state.context_limit = nil
  state.history_checkpoint_ids = nil
  state.history_pending_user_entries = {}
  M.reset_frozen_render()
  M.clear_reasoning_preview()
  M.schedule_render()
end

return M
