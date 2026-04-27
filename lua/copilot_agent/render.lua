-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Chat buffer rendering: entry formatting, highlights, streaming, spinner.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local utils = require('copilot_agent.utils')
local state = cfg.state
local normalize_base_url = cfg.normalize_base_url

local M = {}

local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local HEADER_LINES = 5
local CHAT_HL_NS = vim.api.nvim_create_namespace('copilot_agent_chat')
local RENDER_DEBOUNCE_MS = 150
local STREAM_DEBOUNCE_MS = 80
local SPINNER_INTERVAL_MS = 500

local is_thinking_content = utils.is_thinking_content
local split_lines = utils.split_lines

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
end

function M.start_thinking_spinner(entry_key)
  M.stop_thinking_spinner()
  state.thinking_entry_key = entry_key
  state.thinking_frame = 1
  state._spinner_line = nil -- buffer row of the spinner text (0-indexed)
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
        -- First tick: append the spinner lines at the end of the buffer
        -- instead of doing a full render_chat().
        local lc = state._rendered_line_count or vim.api.nvim_buf_line_count(bufnr)
        local spinner_lines = { 'Assistant:', '  ' .. (SPINNER_FRAMES[1] or '⠋') .. ' Thinking…', '' }
        pcall(function()
          vim.bo[bufnr].modifiable = true
          vim.bo[bufnr].readonly = false
          vim.api.nvim_buf_set_lines(bufnr, lc, -1, false, spinner_lines)
          highlight_lines(bufnr, lc, lc + #spinner_lines)
          vim.bo[bufnr].modifiable = false
          vim.bo[bufnr].readonly = true
          vim.bo[bufnr].modified = false
        end)
        -- The spinner text is the second line we just appended (0-indexed: lc + 1).
        state._spinner_line = lc + 1
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
        for _, row in ipairs(rows) do
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
    for _, l in ipairs(split_lines(entry.content)) do
      out[#out + 1] = '  ' .. l
    end
    out[#out + 1] = ''
  elseif entry.kind == 'assistant' then
    if is_thinking_content(entry.content) then
      if state.chat_busy then
        out[#out + 1] = 'Assistant:'
        out[#out + 1] = '  ' .. (SPINNER_FRAMES[state.thinking_frame] or '⠋') .. ' Thinking…'
        out[#out + 1] = ''
      end
    else
      -- Skip entries whose content is only whitespace after trimming.
      local trimmed = (entry.content or ''):match('^%s*(.-)%s*$')
      if trimmed ~= '' then
        out[#out + 1] = 'Assistant:'
        for _, l in ipairs(split_lines(entry.content)) do
          out[#out + 1] = '  ' .. l
        end
        out[#out + 1] = ''
      end
    end
  else
    if idx > 1 then
      out[#out + 1] = '---'
      out[#out + 1] = ''
    end
    out[#out + 1] = 'User:'
    for _, l in ipairs(split_lines(entry.content)) do
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

-- Highlight chat role headers using extmarks (works alongside treesitter).
-- Only processes lines in [from_row, to_row); callers pass exact ranges
-- so this never scans the full buffer.
local function highlight_lines(bufnr, from_row, to_row)
  vim.api.nvim_buf_clear_namespace(bufnr, CHAT_HL_NS, from_row, to_row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from_row, to_row, false)
  local win = state.chat_winid
  local rule_width = 72
  if win and vim.api.nvim_win_is_valid(win) then
    rule_width = vim.api.nvim_win_get_width(win) - 2
  end
  local rule_text = string.rep('─', rule_width)
  for i, line in ipairs(lines) do
    local row = from_row + i - 1
    if line == 'User:' then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentUser', row, 0, -1)
    elseif line == 'Assistant:' then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentAssistant', row, 0, -1)
    elseif line == '---' then
      vim.api.nvim_buf_set_extmark(bufnr, CHAT_HL_NS, row, 0, {
        virt_text = { { rule_text, 'CopilotAgentRule' } },
        virt_text_pos = 'overlay',
      })
    elseif line:match('^%s*Done%.$') then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentDone', row, 0, -1)
    end
  end
end

-- ── Full render ───────────────────────────────────────────────────────────────

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

  local lines = {
    state.config.chat.title,
    'service: ' .. normalize_base_url(state.config.base_url),
    'session: ' .. (state.session_id or '<none>'),
    'commands: :CopilotAgentNewSession  :CopilotAgentAsk  :CopilotAgentStop',
    string.rep('-', 72),
  }

  if #state.entries == 0 then
    lines[#lines + 1] = 'No messages yet.'
    lines[#lines + 1] = 'Press i or <Enter> to open the input buffer.'
    lines[#lines + 1] = 'Run :CopilotAgentAsk to send a prompt from the command line.'
  else
    for idx, entry in ipairs(state.entries) do
      local elines = M.entry_lines(entry, idx)
      if #elines > 0 then
        if entry.kind == 'assistant' and not is_thinking_content(entry.content) and M.should_merge_assistant(idx) then
          elines[1] = ''
        end
        for _, l in ipairs(elines) do
          lines[#lines + 1] = l
        end
      end
    end
  end

  state.stream_line_start = nil
  -- Cache the total rendered line count so incremental updates can use it.
  state._rendered_line_count = #lines

  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  highlight_lines(bufnr, 0, #lines)
  -- Refresh chat statusline via lazy require to avoid circular deps.
  local sl = require('copilot_agent.statusline')
  sl.refresh_chat_statusline()

  if at_bottom then
    M.scroll_to_bottom()
  end
  if not state.chat_busy then
    M.notify_render_plugins(bufnr)
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

-- Debounced stream update: buffers rapid token deltas instead of rendering each one.
local stream_timer = uv.new_timer()
local stream_pending = false

function M.stream_update(entry, idx)
  if state.history_loading then
    return
  end
  -- Stash latest entry/idx so the deferred callback uses the most recent data.
  state._stream_entry = entry
  state._stream_idx = idx
  if stream_pending then
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
      if e.kind == 'assistant' and not is_thinking_content(e.content) and M.should_merge_assistant(i) and #new_lines > 0 then
        new_lines[1] = ''
      end

      if not state.stream_line_start then
        -- First update for this entry: use cached line count or buffer line count
        -- to find where to start appending — avoids a full render_chat().
        local total = state._rendered_line_count or vim.api.nvim_buf_line_count(bufnr)
        state.stream_line_start = total
      end

      local at_bottom = M.chat_at_bottom()
      vim.bo[bufnr].modifiable = true
      vim.bo[bufnr].readonly = false
      vim.api.nvim_buf_set_lines(bufnr, state.stream_line_start, -1, false, new_lines)
      highlight_lines(bufnr, state.stream_line_start, state.stream_line_start + #new_lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      if at_bottom then
        M.scroll_to_bottom()
      end
    end)
  )
end

-- ── Transcript helpers ────────────────────────────────────────────────────────

function M.append_entry(kind, content, attachments)
  local entry = {
    kind = kind,
    content = content or '',
    attachments = attachments,
  }
  table.insert(state.entries, entry)
  local idx = #state.entries
  state.stream_line_start = nil

  -- Try incremental append instead of full re-render.
  local bufnr = state.chat_bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local new_lines = M.entry_lines(entry, idx)
    if #new_lines > 0 then
      if kind == 'assistant' and not is_thinking_content(content) and M.should_merge_assistant(idx) then
        new_lines[1] = ''
      end
      local at_bottom = M.chat_at_bottom()
      local lc = vim.api.nvim_buf_line_count(bufnr)
      vim.bo[bufnr].modifiable = true
      vim.bo[bufnr].readonly = false
      vim.api.nvim_buf_set_lines(bufnr, lc, -1, false, new_lines)
      highlight_lines(bufnr, lc, lc + #new_lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      state._rendered_line_count = lc + #new_lines
      if at_bottom then
        M.scroll_to_bottom()
      end
    end
  else
    M.schedule_render()
  end
  return idx
end

function M.ensure_assistant_entry(message_id)
  local key = message_id or ('assistant-' .. tostring(#state.entries + 1))
  local index = state.assistant_entries[key]
  if index and state.entries[index] then
    return state.entries[index]
  end
  table.insert(state.entries, {
    kind = 'assistant',
    content = '',
  })
  index = #state.entries
  state.assistant_entries[key] = index
  return state.entries[index]
end

function M.clear_transcript()
  state.entries = {}
  state.assistant_entries = {}
  state.stream_line_start = nil
  state.active_tool = nil
  state.current_intent = nil
  state.context_tokens = nil
  state.context_limit = nil
  M.schedule_render()
end

return M
