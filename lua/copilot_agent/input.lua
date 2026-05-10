-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local session_names = require('copilot_agent.session_names')
local sl = require('copilot_agent.statusline')
local chat = require('copilot_agent.chat')
local prompt = require('copilot_agent.prompt')
local utils = require('copilot_agent.utils')
local win = require('copilot_agent.window')

local state = cfg.state
local SLASH_COMMANDS = cfg.SLASH_COMMANDS

local request = http.request

local working_directory = service.working_directory

local refresh_statuslines = sl.refresh_statuslines

local split_lines = utils.split_lines

local set_agent_mode = chat.set_agent_mode
local setup_action_keymaps = chat.setup_action_keymaps

local M = {}

local input_modes = { 'ask', 'plan', 'agent', 'autopilot' }
local session_label_max_len = 32
local is_list = vim.islist or vim.tbl_islist
local separator_ns = vim.api.nvim_create_namespace('copilot_agent_input_separator')
local attachment_completion_max_items = 80
local completion_runtime = {}
local attachment_fd_cache = {
  cwd = nil,
  entries = nil,
  children = nil,
  last_mode = nil,
  last_query = nil,
  last_leaf = nil,
  last_parent_prefix = nil,
  last_entries = nil,
}
local mcp_action_lookup = {
  add = true,
  show = true,
  edit = true,
  delete = true,
  disable = true,
  enable = true,
  reload = true,
}
local mcp_name_action_lookup = {
  show = true,
  edit = true,
  delete = true,
  disable = true,
  enable = true,
}

local function conversation_separator_text(width)
  width = math.max(tonumber(width) or 0, 12)
  return string.rep('-', width)
end

local function find_named_buffer(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

local function completion_popup_info()
  -- Prefer complete_info when it reports an active completion mode. If complete_info
  -- reports no active mode (empty string) fall back to vim.fn.pumvisible() which
  -- is easier to monkey-patch in tests and more consistent across Neovim versions.
  local ok, info = pcall(vim.fn.complete_info, { 'mode', 'pum_visible', 'selected', 'items' })
  local fallback_visible = vim.fn.pumvisible()

  local mode = ''
  local info_pum = nil
  local selected = -1
  local items = {}
  if ok and type(info) == 'table' then
    mode = info.mode or ''
    if info.pum_visible ~= nil then
      info_pum = tonumber(info.pum_visible)
    end
    if info.selected ~= nil then
      selected = tonumber(info.selected) or -1
    end
    if type(info.items) == 'table' then
      items = info.items
    end
  end

  local pum_visible = info_pum
  if pum_visible == nil or mode == '' then
    pum_visible = fallback_visible
  end
  if pum_visible ~= 1 and (selected >= 0 or #items > 0) then
    pum_visible = 1
  end

  return {
    mode = mode,
    pum_visible = pum_visible,
    selected = selected or -1,
    items = items,
  }
end

local function replace_termcodes(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

local completed_line_for_word
local set_completion_suppression

local function selected_completion_item(info)
  info = type(info) == 'table' and info or completion_popup_info()
  if type(info.items) ~= 'table' or vim.tbl_isempty(info.items) then
    return nil, nil
  end

  local selected = tonumber(info.selected) or -1
  local item_index = selected >= 0 and (selected + 1) or 1
  local item = info.items[item_index] or info.items[1]
  if type(item) ~= 'table' then
    return nil, nil
  end

  local word = item.word or item.abbr
  if type(word) ~= 'string' or word == '' then
    return nil, nil
  end
  return item, word
end

local function visible_completion_accept_keys(opts)
  opts = opts or {}
  local info = completion_popup_info()
  local item, word = selected_completion_item(info)
  if not item or not word then
    return nil
  end

  local selected = tonumber(info.selected) or -1
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.api.nvim_get_current_line()
  local cursor_col = opts.cursor_col
  if cursor_col == nil then
    cursor_col = vim.api.nvim_win_get_cursor(0)[2]
  end
  set_completion_suppression(bufnr, completed_line_for_word(line, cursor_col, word), #(completed_line_for_word(line, cursor_col, word)))
  return replace_termcodes(selected >= 0 and '<C-y>' or '<C-n><C-y>')
end

local function select_visible_completion(opts)
  opts = opts or {}
  local info = completion_popup_info()
  local item, word = selected_completion_item(info)
  if not item or not word then
    return false
  end

  local selected = tonumber(info.selected) or -1
  local item_index = selected >= 0 and selected or 0
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.api.nvim_get_current_line()
  local cursor_col = opts.cursor_col
  if cursor_col == nil then
    cursor_col = vim.api.nvim_win_get_cursor(0)[2]
  end
  set_completion_suppression(bufnr, completed_line_for_word(line, cursor_col, word), #(completed_line_for_word(line, cursor_col, word)))

  if item_index >= 0 and type(vim.api.nvim_select_popupmenu_item) == 'function' then
    local ok = pcall(vim.api.nvim_select_popupmenu_item, item_index, true, true, {})
    if ok then
      return true
    end
  end

  vim.api.nvim_feedkeys(replace_termcodes(selected >= 0 and '<C-y>' or '<C-n><C-y>'), 'n', false)
  return true
end

local function strip_prompt_prefix_from_text_lines(lines, prompt_prefix_text)
  if type(lines) ~= 'table' or #lines == 0 then
    return {}, false
  end
  if type(prompt_prefix_text) ~= 'string' or prompt_prefix_text == '' then
    return vim.deepcopy(lines), false
  end

  local normalized = vim.deepcopy(lines)
  local changed = false
  for idx, line in ipairs(normalized) do
    if type(line) == 'string' and vim.startswith(line, prompt_prefix_text) then
      normalized[idx] = line:sub(#prompt_prefix_text + 1)
      changed = true
    end
  end
  return normalized, changed
end

local function input_prompt_prefix(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return ''
  end
  local prefix = vim.b[bufnr].copilot_prompt_placeholder
  return type(prefix) == 'string' and prefix or ''
end

local function set_input_prompt_prefix(bufnr, prompt_prefix_text)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  local previous = input_prompt_prefix(bufnr)
  prompt_prefix_text = type(prompt_prefix_text) == 'string' and prompt_prefix_text or ''
  vim.b[bufnr].copilot_prompt_placeholder = prompt_prefix_text

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local normalized = strip_prompt_prefix_from_text_lines(lines, previous)
  if vim.tbl_isempty(normalized) then
    normalized = { '' }
  end
  normalized[1] = prompt_prefix_text .. (normalized[1] or '')

  local cursor
  local winid = state.input_winid
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    cursor = vim.api.nvim_win_get_cursor(winid)
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized)
  if cursor and state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    local row = math.min(cursor[1], #normalized)
    local col = cursor[2]
    if row == 1 then
      col = math.max(#prompt_prefix_text, col - #previous + #prompt_prefix_text)
    end
    vim.api.nvim_win_set_cursor(state.input_winid, { row, math.min(col, #(normalized[row] or '')) })
  end
end

local function clamp_input_cursor_to_prompt(bufnr, winid)
  if not (bufnr and winid and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row, col = cursor[1], cursor[2]
  if row ~= 1 then
    return
  end

  local prefix = input_prompt_prefix(bufnr)
  local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ''
  if prefix ~= '' and not vim.startswith(line, prefix) then
    line = prefix .. line
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { line })
  end
  vim.api.nvim_win_set_cursor(winid, { row, math.min(math.max(col, #prefix), #line) })
end

local function set_input_buffer_text(bufnr, text)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  local prefix = input_prompt_prefix(bufnr)
  local lines = split_lines((prefix or '') .. (text or ''))
  if vim.tbl_isempty(lines) then
    lines = { prefix ~= '' and prefix or '' }
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local winid = state.input_winid
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    vim.api.nvim_win_set_cursor(winid, { #lines, #(lines[#lines] or '') })
    clamp_input_cursor_to_prompt(bufnr, winid)
  end
end

local function confirm_completion_or_submit()
  local keys = visible_completion_accept_keys()
  if keys then
    return keys
  end
  return replace_termcodes('<CR>')
end

local function refresh_separator()
  if not state.input_bufnr or not vim.api.nvim_buf_is_valid(state.input_bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(state.input_bufnr, separator_ns, 0, -1)
  if not state.input_winid or not vim.api.nvim_win_is_valid(state.input_winid) then
    return
  end

  local width = vim.api.nvim_win_get_width(state.input_winid)
  vim.api.nvim_buf_set_extmark(state.input_bufnr, separator_ns, 0, 0, {
    virt_lines = { { { conversation_separator_text(width), 'CopilotAgentRule' } } },
    virt_lines_above = true,
    virt_lines_leftcol = true,
  })
end

local function frontmatter_name(path)
  local ok, lines = pcall(vim.fn.readfile, path, '', 32)
  if not ok or type(lines) ~= 'table' or lines[1] ~= '---' then
    return nil
  end

  for i = 2, #lines do
    local line = lines[i]
    if line == '---' then
      break
    end
    local raw = line:match('^name:%s*(.+)%s*$')
    if raw then
      raw = vim.trim(raw)
      local quoted = raw:match('^"(.*)"$') or raw:match("^'(.*)'$")
      return quoted or raw
    end
  end

  return nil
end

local function discovered_agent_names()
  local wd = working_directory()
  local files = {}
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/agents/*.agent.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/agents/**/*.agent.md', false, true))
  local items = {}
  local seen = {}

  for _, path in ipairs(files or {}) do
    local name = frontmatter_name(path) or vim.fn.fnamemodify(path, ':t:r:r')
    if type(name) == 'string' and name ~= '' and not seen[name] then
      seen[name] = true
      table.insert(items, name)
    end
  end

  table.sort(items)
  return items
end

local function discovered_skill_names()
  local wd = working_directory()
  local files = {}
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/*/SKILL.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/*/skill.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/**/SKILL.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/**/skill.md', false, true))

  local items = {}
  local seen = {}
  for _, path in ipairs(files) do
    local name = frontmatter_name(path) or vim.fn.fnamemodify(vim.fn.fnamemodify(path, ':h'), ':t')
    if type(name) == 'string' and name ~= '' and not seen[name] then
      seen[name] = true
      table.insert(items, name)
    end
  end

  table.sort(items)
  return items
end

local function command_completion_context(before)
  for _, command in ipairs({ 'agent', 'skills', 'model', 'resume', 'session', 'mcp', 'instructions', 'lsp' }) do
    local token = '/' .. command
    local lower_before = before:lower()
    local start_pos, end_pos
    local search_from = 1
    while true do
      local found_start, found_end = lower_before:find(token, search_from, true)
      if not found_start then
        break
      end
      local prev_char = found_start == 1 and '' or before:sub(found_start - 1, found_start - 1)
      local next_char = found_end == #before and '' or before:sub(found_end + 1, found_end + 1)
      if (found_start == 1 or prev_char:match('%s')) and (next_char == '' or next_char:match('%s')) then
        start_pos = found_start
        end_pos = found_end
      end
      search_from = found_start + 1
    end
    if start_pos then
      local raw_query = before:sub((end_pos or start_pos) + 1)
      return {
        kind = command,
        start = start_pos,
        ['end'] = end_pos,
        raw_query = raw_query,
        query = vim.trim(raw_query),
        at_token_end = (end_pos or start_pos) == #before,
      }
    end
  end

  return nil
end

local function is_attachment_token_boundary(before, start_pos)
  if start_pos == 1 then
    return true
  end
  return (before:sub(start_pos - 1, start_pos - 1) or ''):match('%s') ~= nil
end

local function attachment_completion_context(before)
  before = type(before) == 'string' and before or ''

  local quoted_start
  local search_from = 1
  while true do
    local found_start = before:find('@"', search_from, true)
    if not found_start then
      break
    end
    if is_attachment_token_boundary(before, found_start) then
      local remainder = before:sub(found_start + 2)
      if not remainder:find('"', 1, true) then
        quoted_start = found_start
      end
    end
    search_from = found_start + 2
  end

  if quoted_start then
    return {
      start = quoted_start,
      token = before:sub(quoted_start),
      query = before:sub(quoted_start + 2),
      quoted = true,
    }
  end

  local start_pos = before:find('@[^%s"]*$')
  if not start_pos or not is_attachment_token_boundary(before, start_pos) then
    return nil
  end

  return {
    start = start_pos,
    token = before:sub(start_pos),
    query = before:sub(start_pos + 1),
    quoted = false,
  }
end

-- A single trailing space in the raw_query acts like a trigger character
-- (similar to '.' in C++) that reopens the popup for the next argument slot.
-- Multiple trailing spaces disable auto-completion.
local function has_completion_trigger_space(raw_query)
  if type(raw_query) ~= 'string' or raw_query == '' then
    return false
  end
  if raw_query == ' ' then
    return true
  end
  return raw_query:match('[^%s]%s$') ~= nil and raw_query:match('%s%s$') == nil
end

local function generic_slash_completion_context(before)
  before = type(before) == 'string' and before or ''
  local start_pos = before:find('/[^%s]*$')
  if not start_pos then
    return nil
  end

  local prev_char = start_pos == 1 and '' or before:sub(start_pos - 1, start_pos - 1)
  if start_pos ~= 1 and not prev_char:match('%s') then
    return nil
  end

  return {
    start = start_pos,
    token = before:sub(start_pos),
    query = before:sub(start_pos + 1),
  }
end

local function input_completion_context(before)
  local attachment_context = attachment_completion_context(before)
  if attachment_context then
    return {
      kind = 'attachment',
      start = attachment_context.start,
      token = attachment_context.token,
      query = attachment_context.query,
      quoted = attachment_context.quoted == true,
      popup_key = string.format('attachment:%d', attachment_context.start),
      auto_key = (
        attachment_context.query == '' and string.format('attachment:%d', attachment_context.start)
        or (attachment_context.token:sub(-1) == '/' and string.format('attachment:%d:%s', attachment_context.start, attachment_context.query) or nil)
      ),
    }
  end

  local command_context = command_completion_context(before)
  if command_context then
    local trigger_space = has_completion_trigger_space(command_context.raw_query)
    return {
      kind = 'slash-command',
      command = command_context.kind,
      start = command_context.start,
      ['end'] = command_context['end'],
      query = command_context.query,
      raw_query = command_context.raw_query,
      at_token_end = command_context.at_token_end,
      popup_key = string.format('slash:%s:%d', command_context.kind, command_context.start),
      auto_key = (command_context.at_token_end or trigger_space) and string.format('slash:%s:%d:%d', command_context.kind, command_context.start, #(command_context.raw_query or '')) or nil,
    }
  end

  local slash_context = generic_slash_completion_context(before)
  if slash_context then
    return {
      kind = 'slash-root',
      start = slash_context.start,
      token = slash_context.token,
      query = slash_context.query,
      popup_key = string.format('slash:root:%d', slash_context.start),
      auto_key = string.format('slash:root:%d', slash_context.start),
    }
  end

  return nil
end

completed_line_for_word = function(line, cursor_col, word)
  line = type(line) == 'string' and line or ''
  cursor_col = math.max(0, math.floor(tonumber(cursor_col) or #line))
  local completion_request = input_completion_context(line:sub(1, cursor_col))
  if not completion_request then
    return line
  end
  return line:sub(1, completion_request.start - 1) .. word .. line:sub(cursor_col + 1)
end

set_completion_suppression = function(bufnr, line, cursor_col)
  local runtime = completion_runtime[bufnr]
  if type(runtime) ~= 'table' then
    return
  end

  local completion_request = input_completion_context((line or ''):sub(1, math.max(0, math.floor(tonumber(cursor_col) or 0))))
  runtime.suppressed_line = line
  runtime.suppressed_auto_key = completion_request and completion_request.auto_key or nil
end

local function normalize_attachment_path(path)
  path = vim.trim(path or '')
  if path == '' then
    return nil
  end

  local normalized
  if vim.fs and type(vim.fs.normalize) == 'function' then
    normalized = vim.fs.normalize(path)
  else
    normalized = vim.fn.fnamemodify(path, ':p')
  end
  return normalized:gsub('\\', '/')
end

local function normalize_attachment_query(query)
  return vim.trim(type(query) == 'string' and query or ''):gsub('\\', '/')
end

local function attachment_display_path(path)
  local normalized = normalize_attachment_path(path)
  if not normalized then
    return nil
  end

  local wd = normalize_attachment_path(working_directory())
  if wd and vim.startswith(normalized, wd .. '/') then
    return normalized:sub(#wd + 2)
  end
  return normalized
end

local function attachment_display_for_kind(path, kind)
  local display = attachment_display_path(path)
  if not display or display == '' then
    return nil
  end
  if kind == 'directory' and display:sub(-1) ~= '/' then
    return display .. '/'
  end
  return display
end

local function attachment_completion_word(display, quoted)
  if type(display) ~= 'string' or display == '' then
    return nil
  end
  if quoted then
    return '@"' .. display .. '"'
  end
  return '@' .. display
end

local function is_absolute_attachment_path(path)
  return vim.startswith(path, '/') or path:match('^%a:[/\\]') ~= nil
end

local function resolve_attachment_candidate(raw_path)
  raw_path = vim.trim(type(raw_path) == 'string' and raw_path or '')
  if raw_path == '' then
    return nil
  end

  local expanded = vim.fn.expand(raw_path)
  if expanded == '' then
    expanded = raw_path
  end
  if not is_absolute_attachment_path(expanded) then
    local wd = working_directory()
    expanded = wd ~= '' and (wd .. '/' .. expanded) or expanded
  end

  local normalized = normalize_attachment_path(expanded)
  local stat = normalized and (vim.uv or vim.loop).fs_stat(normalized) or nil
  if not stat then
    return nil
  end

  local kind = stat.type == 'directory' and 'directory' or 'file'
  return {
    type = kind,
    path = normalized,
    display = attachment_display_for_kind(normalized, kind),
  }
end

local function attachment_identity(attachment)
  if type(attachment) ~= 'table' then
    return nil
  end
  if attachment.type == 'selection' then
    return table.concat({
      'selection',
      attachment.path or '',
      tostring(attachment.start_line or ''),
      tostring(attachment.end_line or ''),
      attachment.text or '',
    }, '\0')
  end
  return table.concat({
    attachment.type or '',
    normalize_attachment_path(attachment.path or '') or (attachment.path or ''),
  }, '\0')
end

local function merge_attachments(...)
  local merged = {}
  local seen = {}

  local function add(attachment)
    if type(attachment) ~= 'table' then
      return
    end
    local key = attachment_identity(attachment)
    if key and seen[key] then
      return
    end
    if key then
      seen[key] = true
    end
    merged[#merged + 1] = attachment
  end

  for _, attachment_list in ipairs({ ... }) do
    for _, attachment in ipairs(attachment_list or {}) do
      add(attachment)
    end
  end

  return merged
end

local function extract_inline_attachments(text)
  text = type(text) == 'string' and text or ''
  local attachments = {}
  local pieces = {}
  local idx = 1
  local len = #text

  while idx <= len do
    local token_start = text:find('@', idx, true)
    if not token_start then
      pieces[#pieces + 1] = text:sub(idx)
      break
    end

    if not is_attachment_token_boundary(text, token_start) then
      pieces[#pieces + 1] = text:sub(idx, token_start)
      idx = token_start + 1
    else
      local raw_path
      local token_end
      local replacement
      if text:sub(token_start + 1, token_start + 1) == '"' then
        local closing_quote = text:find('"', token_start + 2, true)
        if closing_quote then
          raw_path = text:sub(token_start + 2, closing_quote - 1)
          token_end = closing_quote
          replacement = raw_path
        end
      else
        local _, match_end = text:find('@[^%s"]+', token_start)
        if match_end == token_start then
          raw_path = ''
        elseif match_end then
          raw_path = text:sub(token_start + 1, match_end)
          token_end = match_end
          replacement = raw_path
        end
      end

      local attachment = raw_path and resolve_attachment_candidate(raw_path) or nil
      if attachment and token_end then
        attachments[#attachments + 1] = attachment
        pieces[#pieces + 1] = text:sub(idx, token_start - 1)
        pieces[#pieces + 1] = replacement or ''
        idx = token_end + 1
      else
        pieces[#pieces + 1] = text:sub(idx, token_start)
        idx = token_start + 1
      end
    end
  end

  return table.concat(pieces), attachments
end

local function is_chat_related_buffer_name(path)
  local name = vim.fn.fnamemodify(path or '', ':t')
  local chat_name = (state.config.chat or {}).buf_name or 'CopilotAgentChat'
  return name == chat_name or name == 'copilot-agent-input' or name == 'copilot-agent-compose' or vim.startswith(name, 'copilot-agent-chat-stale-')
end

local function attachment_path_basename(path)
  local trimmed = type(path) == 'string' and path:gsub('/+$', '') or ''
  return vim.fn.fnamemodify(trimmed, ':t')
end

local function segment_chain_score(path, query)
  local path_segments = vim.split((path or ''):gsub('/+$', ''), '/', { plain = true, trimempty = true })
  local query_segments = vim.split((query or ''):gsub('/+$', ''), '/', { plain = true, trimempty = true })
  if vim.tbl_isempty(path_segments) or vim.tbl_isempty(query_segments) then
    return nil
  end

  local search_from = 1
  local score = 0
  for _, segment in ipairs(query_segments) do
    local matched = false
    for idx = search_from, #path_segments do
      local candidate = path_segments[idx]
      if candidate:find(segment, 1, true) then
        score = score + 50 - ((idx - search_from) * 2)
        if vim.startswith(candidate, segment) then
          score = score + 15
        end
        matched = true
        search_from = idx + 1
        break
      end
    end
    if not matched then
      return nil
    end
  end
  return score
end

local function attachment_query_score(path, query)
  local candidate = ((path or ''):gsub('/+$', '')):lower()
  local needle = normalize_attachment_query(query):lower()
  local basename = attachment_path_basename(candidate)
  if needle == '' then
    return 0
  end
  if candidate == needle or basename == needle then
    return 1000
  end
  if vim.startswith(candidate, needle) then
    return 900
  end
  if vim.startswith(basename, needle) then
    return 850
  end

  local substring_pos = candidate:find(needle, 1, true)
  if substring_pos then
    return 700 - substring_pos
  end

  local chained = needle:find('/', 1, true) and segment_chain_score(candidate, needle) or nil
  if chained then
    return 600 + chained
  end
  return nil
end

local function attachment_direct_child_name(path, prefix)
  local candidate = (path or ''):gsub('/+$', '')
  local normalized_prefix = (prefix or ''):gsub('/+$', '')
  if normalized_prefix == '' then
    return candidate
  end
  return candidate:sub(#normalized_prefix + 2)
end

local function attachment_fd_entries()
  local wd = working_directory()
  if wd == '' or vim.fn.executable('fd') ~= 1 then
    attachment_fd_cache.cwd = wd
    attachment_fd_cache.entries = nil
    attachment_fd_cache.children = nil
    attachment_fd_cache.last_mode = nil
    attachment_fd_cache.last_query = nil
    attachment_fd_cache.last_leaf = nil
    attachment_fd_cache.last_parent_prefix = nil
    attachment_fd_cache.last_entries = nil
    return nil
  end
  if attachment_fd_cache.cwd == wd and type(attachment_fd_cache.entries) == 'table' then
    return attachment_fd_cache.entries
  end

  local lines
  if vim.system then
    local result = vim
      .system({
        'fd',
        '--color',
        'never',
        '--strip-cwd-prefix',
        '--exclude',
        '.git',
        '.',
      }, {
        text = true,
        cwd = wd,
      })
      :wait()
    if result.code ~= 0 then
      attachment_fd_cache.cwd = wd
      attachment_fd_cache.entries = nil
      return nil
    end
    lines = split_lines(result.stdout or '')
  else
    local cmd = table.concat({
      'cd',
      vim.fn.shellescape(wd),
      '&&',
      'fd',
      '--color',
      'never',
      '--strip-cwd-prefix',
      '--exclude',
      '.git',
      '.',
    }, ' ')
    lines = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
      attachment_fd_cache.cwd = wd
      attachment_fd_cache.entries = nil
      return nil
    end
  end

  local entries = {}
  local children = { [''] = {} }
  for _, line in ipairs(lines or {}) do
    local relative = vim.trim(line or '')
    if relative ~= '' then
      local is_directory = relative:sub(-1) == '/'
      local relative_path = is_directory and relative:sub(1, -2) or relative
      if relative_path ~= '' then
        local entry = {
          path = wd .. '/' .. relative_path,
          display = relative,
          kind = is_directory and 'directory' or 'file',
        }
        entries[#entries + 1] = entry
        local parent = vim.fn.fnamemodify(relative_path, ':h'):gsub('\\', '/')
        if parent == '.' then
          parent = ''
        end
        children[parent] = children[parent] or {}
        children[parent][#children[parent] + 1] = entry
      end
    end
  end
  attachment_fd_cache.cwd = wd
  attachment_fd_cache.entries = entries
  attachment_fd_cache.children = children
  attachment_fd_cache.last_mode = nil
  attachment_fd_cache.last_query = nil
  attachment_fd_cache.last_leaf = nil
  attachment_fd_cache.last_parent_prefix = nil
  attachment_fd_cache.last_entries = nil
  return entries
end

local function attachment_completion_items(completion_request)
  completion_request = type(completion_request) == 'table' and completion_request or { query = completion_request }
  local quoted = completion_request.quoted == true
  local query = normalize_attachment_query(completion_request.query)
  local items = {}
  local seen = {}
  local ranked = {}
  local fd_entries = attachment_fd_entries()

  local function build_ranked_items()
    table.sort(ranked, function(left, right)
      if left.score ~= right.score then
        return left.score > right.score
      end
      if left.menu_rank ~= right.menu_rank then
        return left.menu_rank < right.menu_rank
      end
      return left.item.abbr < right.item.abbr
    end)
    for idx, entry in ipairs(ranked) do
      if idx > attachment_completion_max_items then
        break
      end
      items[#items + 1] = entry.item
    end
    return items
  end

  local function add_item(path, menu, kind, score)
    local display = attachment_display_for_kind(path, kind)
    if display and display ~= '' and not seen[display] then
      seen[display] = true
      table.insert(ranked, {
        score = score or 0,
        menu_rank = menu == '[buffer]' and 0 or (kind == 'directory' and 1 or 2),
        item = {
          word = attachment_completion_word(display, quoted),
          abbr = display,
          menu = menu,
        },
      })
    end
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_option_value('buftype', { buf = bufnr }) == '' then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= '' then
        local is_chat = is_chat_related_buffer_name(path)
        local display = attachment_display_for_kind(path, 'file')
        local score = display and attachment_query_score(display, query) or nil
        if display and not is_chat and score ~= nil then
          add_item(path, '[buffer]', 'file', score + 100)
        end
      end
    end
  end

  if type(fd_entries) == 'table' then
    local parent_prefix, leaf
    local source_entries = fd_entries
    local mode = 'search'
    local short_circuit_fd = false
    if query == '' then
      parent_prefix = ''
      leaf = ''
    else
      parent_prefix, leaf = query:match('^(.*)/([^/]*)$')
    end
    if query ~= '' and query:sub(-1) == '/' then
      parent_prefix = query:sub(1, -2)
      leaf = ''
    end
    if parent_prefix ~= nil then
      mode = 'browse'
      source_entries = ((attachment_fd_cache.children or {})[parent_prefix or ''] or {})
      if
        attachment_fd_cache.last_mode == 'browse'
        and attachment_fd_cache.last_parent_prefix == parent_prefix
        and type(attachment_fd_cache.last_entries) == 'table'
        and vim.startswith(leaf or '', attachment_fd_cache.last_leaf or '')
      then
        source_entries = attachment_fd_cache.last_entries
        short_circuit_fd = #source_entries == 0
      end
    elseif attachment_fd_cache.last_mode == 'search' and type(attachment_fd_cache.last_entries) == 'table' and vim.startswith(query, attachment_fd_cache.last_query or '') then
      source_entries = attachment_fd_cache.last_entries
      short_circuit_fd = #source_entries == 0
    end

    if short_circuit_fd then
      attachment_fd_cache.last_mode = mode
      attachment_fd_cache.last_query = query
      attachment_fd_cache.last_leaf = leaf
      attachment_fd_cache.last_parent_prefix = parent_prefix
      attachment_fd_cache.last_entries = source_entries
      return build_ranked_items()
    end

    local matched_entries = {}
    for _, entry in ipairs(source_entries) do
      if parent_prefix ~= nil then
        local child_name = attachment_direct_child_name(entry.display, parent_prefix)
        local score = leaf == '' and 1000 or attachment_query_score(child_name, leaf)
        if score ~= nil then
          matched_entries[#matched_entries + 1] = entry
          add_item(entry.path, entry.kind == 'directory' and '[dir]' or '[file]', entry.kind, score)
        end
      else
        local score = attachment_query_score(entry.display, query)
        if score ~= nil then
          matched_entries[#matched_entries + 1] = entry
          add_item(entry.path, entry.kind == 'directory' and '[dir]' or '[file]', entry.kind, score)
        end
      end
    end
    attachment_fd_cache.last_mode = mode
    attachment_fd_cache.last_query = query
    attachment_fd_cache.last_leaf = leaf
    attachment_fd_cache.last_parent_prefix = parent_prefix
    attachment_fd_cache.last_entries = matched_entries
  else
    local wd = working_directory()
    if wd ~= '' then
      local pattern = wd .. '/' .. query .. '*'
      for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
        local stat = (vim.uv or vim.loop).fs_stat(path)
        local kind = stat and stat.type == 'directory' and 'directory' or 'file'
        add_item(path, kind == 'directory' and '[dir]' or '[file]', kind, 0)
      end
    end
  end

  return build_ranked_items()
end

local function lsp_action_items()
  return {
    'create',
    'status',
    'show',
    'test',
    'help',
  }
end

local function mcp_action_items()
  return {
    'add',
    'show',
    'edit',
    'delete',
    'disable',
    'enable',
    'reload',
  }
end

local function discovered_instruction_names()
  local wd = working_directory()
  local files = {}
  local root_file = wd .. '/.github/copilot-instructions.md'
  if vim.fn.filereadable(root_file) == 1 then
    table.insert(files, root_file)
  end
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/instructions/*.instructions.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/instructions/**/*.instructions.md', false, true))

  local items = {}
  local seen = {}
  for _, path in ipairs(files) do
    local rel = path:sub(#wd + 2)
    if rel ~= '' and not seen[rel] then
      seen[rel] = true
      table.insert(items, rel)
    end
  end

  table.sort(items)
  return items
end

local function discovered_mcp_names()
  local wd = working_directory()
  local items = {}
  local seen = {}

  local function add(name)
    if type(name) ~= 'string' or name == '' or seen[name] then
      return
    end
    seen[name] = true
    table.insert(items, name)
  end

  local function add_from_value(value)
    if type(value) == 'table' then
      if is_list(value) then
        for _, entry in ipairs(value) do
          if type(entry) == 'string' then
            add(entry)
          elseif type(entry) == 'table' then
            add(entry.name or entry.id)
          end
        end
      else
        for name in pairs(value) do
          add(name)
        end
      end
    end
  end

  local function read_config(path)
    if vim.fn.filereadable(path) ~= 1 then
      return
    end
    local decoded = http.decode_json(table.concat(vim.fn.readfile(path), '\n'))
    if type(decoded) ~= 'table' then
      return
    end
    add_from_value(decoded.mcpServers)
    add_from_value(decoded.servers)
  end

  read_config(wd .. '/.mcp.json')
  read_config(wd .. '/.vscode/mcp.json')
  read_config(vim.fn.expand('~/.copilot/mcp-config.json'))

  table.sort(items)
  return items
end

local function discovered_model_ids()
  local ok, model = pcall(require, 'copilot_agent.model')
  if not ok then
    return {}
  end

  if vim.tbl_isempty(state.model_cache) then
    local response = http.sync_request('GET', '/models', nil)
    if type(response) == 'table' then
      model.store_model_cache(response.models or {})
    end
  end

  return model.model_completion_items('')
end

local function discovered_session_items()
  local response = http.sync_request('GET', '/sessions', nil)
  if type(response) ~= 'table' then
    return {}
  end

  local merged = {}
  local order = {}
  local function upsert(session)
    local id = session and session.sessionId or nil
    if type(id) ~= 'string' or id == '' then
      return
    end
    if not merged[id] then
      merged[id] = vim.deepcopy(session)
      table.insert(order, id)
      return
    end

    local existing = merged[id]
    if session.live then
      local combined = vim.deepcopy(session)
      combined.summary = combined.summary or existing.summary
      combined.modifiedTime = combined.modifiedTime or existing.modifiedTime
      combined.startTime = combined.startTime or existing.startTime
      merged[id] = combined
      return
    end

    existing.summary = existing.summary or session.summary
    existing.modifiedTime = existing.modifiedTime or session.modifiedTime
    existing.startTime = existing.startTime or session.startTime
    existing.createdAt = existing.createdAt or session.createdAt
  end

  for _, session in ipairs(response.persisted or {}) do
    upsert(session)
  end
  for _, session in ipairs(response.live or {}) do
    upsert(session)
  end

  local items = {}
  for _, id in ipairs(order) do
    local session = merged[id]
    local summary = utils.truncate_session_summary(session_names.resolve(session.summary, id), session_label_max_len)
    local formatted_id = utils.format_session_id(id)
    local label = summary ~= '' and (summary .. ' [' .. formatted_id .. ']') or formatted_id
    table.insert(items, {
      id = id,
      label = label,
      summary = (session_names.resolve(session.summary, id) or ''):lower(),
    })
  end

  table.sort(items, function(left, right)
    return left.label < right.label
  end)
  return items
end

local function slash_root_completion_items(query)
  local items = {}
  local lowered_query = (query or ''):lower()
  for _, cmd in ipairs(SLASH_COMMANDS) do
    local name = cmd.word:sub(2):lower()
    if lowered_query == '' or vim.startswith(name, lowered_query) then
      items[#items + 1] = {
        word = cmd.word,
        abbr = cmd.word,
        menu = cmd.info,
      }
    end
  end
  return items
end

local function slash_command_completion_items(completion_request)
  local items = {}
  local command = completion_request and completion_request.command or nil
  if type(command) ~= 'string' or command == '' then
    return items
  end

  if command == 'agent' then
    local query = (completion_request.query or ''):lower()
    for _, name in ipairs(discovered_agent_names()) do
      if query == '' or vim.startswith(name:lower(), query) then
        items[#items + 1] = {
          word = name,
          abbr = name,
          menu = '[agent]',
        }
      end
    end
    return items
  end

  if command == 'skills' then
    local query = (completion_request.query or ''):lower()
    for _, name in ipairs(discovered_skill_names()) do
      if query == '' or vim.startswith(name:lower(), query) then
        items[#items + 1] = {
          word = '/skills ' .. name,
          abbr = '/skills ' .. name,
          menu = '[skill]',
        }
      end
    end
    return items
  end

  if command == 'model' then
    local query = (completion_request.query or ''):lower()
    for _, id in ipairs(discovered_model_ids()) do
      if query == '' or vim.startswith(id:lower(), query) then
        items[#items + 1] = {
          word = '/model ' .. id,
          abbr = '/model ' .. id,
          menu = '[model]',
        }
      end
    end
    return items
  end

  if command == 'resume' or command == 'session' then
    local query = (completion_request.query or ''):lower()
    for _, session in ipairs(discovered_session_items()) do
      if query == '' or vim.startswith(session.id:lower(), query) or vim.startswith(session.summary, query) then
        items[#items + 1] = {
          word = '/' .. command .. ' ' .. session.id,
          abbr = '/' .. command .. ' ' .. session.label,
          menu = '[session]',
        }
      end
    end
    return items
  end

  if command == 'mcp' then
    local raw_query = completion_request.raw_query or completion_request.query or ''
    local query = vim.trim(raw_query)
    local tokens = query == '' and {} or vim.split(query, '%s+', { trimempty = true })
    local has_trailing_space = type(raw_query) == 'string' and raw_query:match('%s$') ~= nil
    local action = (#tokens > 0 and tokens[1]:lower()) or ''
    local completing_name = mcp_name_action_lookup[action] and (#tokens > 1 or has_trailing_space)

    if completing_name then
      local name_query = ''
      if #tokens > 1 and not has_trailing_space then
        name_query = tokens[#tokens]:lower()
      end
      for _, name in ipairs(discovered_mcp_names()) do
        if name_query == '' or vim.startswith(name:lower(), name_query) then
          local full_word = '/mcp ' .. action .. ' ' .. name
          items[#items + 1] = {
            word = full_word,
            abbr = full_word,
            menu = '[mcp]',
          }
        end
      end
      return items
    end

    if query == '' then
      items[#items + 1] = {
        word = '/mcp',
        abbr = '/mcp',
        menu = 'Manage MCP server configuration',
      }
    end

    local action_query = action
    for _, item in ipairs(mcp_action_items()) do
      if action_query == '' or vim.startswith(item, action_query) then
        items[#items + 1] = {
          word = '/mcp ' .. item,
          abbr = '/mcp ' .. item,
          menu = '[mcp]',
        }
      end
    end

    if #tokens == 0 or not mcp_action_lookup[action] then
      local name_query = (#tokens > 0 and action or ''):lower()
      for _, name in ipairs(discovered_mcp_names()) do
        if name_query == '' or vim.startswith(name:lower(), name_query) then
          items[#items + 1] = {
            word = name,
            abbr = name,
            menu = '[mcp]',
          }
        end
      end
    end
    return items
  end

  if command == 'instructions' then
    local query = (completion_request.query or ''):lower()
    for _, name in ipairs(discovered_instruction_names()) do
      if query == '' or vim.startswith(name:lower(), query) then
        items[#items + 1] = {
          word = '/instructions ' .. name,
          abbr = '/instructions ' .. name,
          menu = '[instruction]',
        }
      end
    end
    return items
  end

  if command == 'lsp' then
    local query = (completion_request.query or ''):lower()
    for _, action in ipairs(lsp_action_items()) do
      if query == '' or vim.startswith(action, query) then
        items[#items + 1] = {
          word = '/lsp ' .. action,
          abbr = '/lsp ' .. action,
          menu = '[lsp]',
        }
      end
    end
  end

  return items
end

local function input_completion_items(completion_request, base)
  if completion_request and completion_request.kind == 'attachment' then
    return attachment_completion_items(completion_request)
  end
  if completion_request and completion_request.kind == 'slash-command' then
    return slash_command_completion_items(completion_request)
  end
  if completion_request and completion_request.kind == 'slash-root' then
    return slash_root_completion_items(completion_request.query or '')
  end

  if vim.startswith(base or '', '@') then
    if vim.startswith(base or '', '@"') then
      return attachment_completion_items({
        query = (base or ''):sub(3),
        quoted = true,
      })
    end
    return attachment_completion_items({
      query = (base or ''):sub(2),
      quoted = false,
    })
  end
  if vim.startswith(base or '', '/') then
    return slash_root_completion_items((base or ''):sub(2))
  end
  return {}
end

local function input_completefunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local completion_request = input_completion_context(line:sub(1, col))

  if findstart == 1 then
    if completion_request then
      return completion_request.start - 1
    end
    return -2
  end

  return input_completion_items(completion_request, base)
end

local function current_completion_request()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return input_completion_context(line:sub(1, col))
end

local function publish_input_completefunc()
  local agent = require('copilot_agent')
  agent.input_completefunc = input_completefunc
  agent.input_omnifunc = input_completefunc
  M._input_completefunc = input_completefunc
  M._input_omnifunc = input_completefunc
end

local function setup_completion_keymaps(bufnr)
  vim.bo[bufnr].omnifunc = ''
  vim.api.nvim_buf_set_option(bufnr, 'completefunc', "v:lua.require'copilot_agent'.input_completefunc")
  publish_input_completefunc()

  local runtime = completion_runtime[bufnr] or {}
  completion_runtime[bufnr] = runtime
  runtime.active_completion_key = nil
  runtime.last_auto_completion_key = nil
  runtime.auto_completion_scheduled = false

  local function trigger_completion(opts)
    opts = opts or {}
    local completion_request = current_completion_request()
    if not completion_request then
      return false
    end

    local start_col = input_completefunc(1, '')
    if start_col < 0 then
      return false
    end

    local items = input_completefunc(0, completion_request.token or '')
    if not items or vim.tbl_isempty(items) then
      if opts.auto then
        runtime.active_completion_key = nil
      end
      return false
    end

    runtime.active_completion_key = completion_request.popup_key
    vim.fn.complete(start_col + 1, items)
    return true
  end
  runtime.trigger_completion = trigger_completion

  local function maybe_auto_trigger_completion()
    local completion_request = current_completion_request()
    local popup = completion_popup_info()
    local key = completion_request and completion_request.auto_key or nil
    local line = vim.api.nvim_get_current_line()
    if runtime.suppressed_line and runtime.suppressed_line ~= line then
      runtime.suppressed_line = nil
      runtime.suppressed_auto_key = nil
    end
    if not key then
      runtime.last_auto_completion_key = nil
      if popup.pum_visible ~= 1 then
        runtime.active_completion_key = nil
      end
      return
    end
    if runtime.suppressed_line == line and runtime.suppressed_auto_key == key then
      return
    end
    if runtime.auto_completion_scheduled then
      return
    end
    if key == runtime.last_auto_completion_key and popup.pum_visible == 1 and runtime.active_completion_key == completion_request.popup_key then
      return
    end

    runtime.auto_completion_scheduled = true
    vim.schedule(function()
      runtime.auto_completion_scheduled = false
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local mode = vim.fn.mode()
      if mode:sub(1, 1) ~= 'i' then
        return
      end
      local current = current_completion_request()
      if not current or current.auto_key ~= key then
        return
      end
      if trigger_completion({ auto = true }) then
        runtime.last_auto_completion_key = key
      end
    end)
  end

  local function confirm_or_trigger_completion()
    if select_visible_completion() then
      return ''
    end
    trigger_completion()
    return ''
  end

  vim.keymap.set('i', '<Tab>', confirm_or_trigger_completion, {
    buffer = bufnr,
    expr = true,
    replace_keycodes = false,
    silent = true,
    desc = 'Trigger or accept completion',
  })
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'CompleteChanged' }, {
    buffer = bufnr,
    callback = maybe_auto_trigger_completion,
  })
end

local function resolve_chat_window()
  if type(chat.find_chat_window) == 'function' then
    return chat.find_chat_window()
  end
  if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
    return state.chat_winid
  end
  return nil
end

local function is_input_anchored_below_chat(chat_winid, input_winid)
  if not (chat_winid and input_winid) then
    return false
  end
  if not (vim.api.nvim_win_is_valid(chat_winid) and vim.api.nvim_win_is_valid(input_winid)) then
    return false
  end
  if vim.api.nvim_win_get_tabpage(chat_winid) ~= vim.api.nvim_win_get_tabpage(input_winid) then
    return false
  end

  local chat_pos = vim.api.nvim_win_get_position(chat_winid)
  local input_pos = vim.api.nvim_win_get_position(input_winid)
  local same_col = chat_pos[2] == input_pos[2]
  local same_width = vim.api.nvim_win_get_width(chat_winid) == vim.api.nvim_win_get_width(input_winid)
  local below_chat = input_pos[1] > chat_pos[1]

  return same_col and same_width and below_chat
end

local function get_existing_input_text()
  if not (state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr)) then
    return ''
  end

  local lines = vim.api.nvim_buf_get_lines(state.input_bufnr, 0, -1, false)
  local prompt_prefix_text = input_prompt_prefix(state.input_bufnr)
  local text = table.concat(lines, '\n')
  if prompt_prefix_text ~= '' and vim.startswith(text, prompt_prefix_text) then
    text = text:sub(#prompt_prefix_text + 1)
  end
  return text
end

local function normalize_submission_text(text)
  text = type(text) == 'string' and text or ''
  return text:gsub('\r\n?', '\n'):gsub('\n+$', '')
end

local function set_buffer_text(bufnr, text)
  local lines = split_lines(normalize_submission_text(text))
  if vim.tbl_isempty(lines) then
    lines = { '' }
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

local function merge_compose_text(existing_text, incoming_text)
  local existing = normalize_submission_text(existing_text)
  local incoming = normalize_submission_text(incoming_text)
  if incoming == '' then
    return existing
  end
  if existing == '' or existing == incoming then
    return incoming
  end
  return existing .. '\n\n' .. incoming
end

local function remember_prompt(text)
  local prompt_text = vim.trim(text or '')
  if prompt_text == '' then
    return
  end
  if state.prompt_history[#state.prompt_history] == prompt_text then
    return
  end
  table.insert(state.prompt_history, prompt_text)
end

local function submit_message_text(text)
  local normalized_text = normalize_submission_text(text)
  local prompt_text, inline_attachments = extract_inline_attachments(normalized_text)
  local attachments = merge_attachments(vim.deepcopy(state.pending_attachments), inline_attachments)

  if vim.trim(prompt_text) == '' and #attachments == 0 then
    return false
  end
  if require('copilot_agent.slash').execute(prompt_text, { attachments = attachments }) then
    return true
  end

  state.pending_attachments = {}
  state.chat_busy = true
  refresh_statuslines()
  require('copilot_agent').ask(prompt_text, { attachments = attachments })
  return true
end

local function get_existing_compose_text()
  if not (state.compose_bufnr and vim.api.nvim_buf_is_valid(state.compose_bufnr)) then
    return ''
  end
  return table.concat(vim.api.nvim_buf_get_lines(state.compose_bufnr, 0, -1, false), '\n')
end

local function reset_prompt_history_navigation()
  state.prompt_history_index = nil
  state.prompt_history_draft = ''
end

local function close_existing_input_window(opts)
  opts = opts or {}
  if not opts.preserve_contents and state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr) then
    vim.api.nvim_buf_set_lines(state.input_bufnr, 0, -1, false, {})
    reset_prompt_history_navigation()
  end
  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_win_close(state.input_winid, true)
    state.input_winid = nil
  end
  local chat_winid = resolve_chat_window()
  if not opts.skip_focus and chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
    vim.api.nvim_set_current_win(chat_winid)
  end
end

local function cancel_existing_input_window()
  local text = vim.trim(get_existing_input_text())
  if text == '' then
    close_existing_input_window()
    return
  end

  vim.ui.select({ 'Keep editing', 'Close input' }, { prompt = 'Discard unsent chat input?' }, function(choice)
    if choice == 'Close input' then
      close_existing_input_window()
      return
    end

    vim.schedule(function()
      if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
        vim.api.nvim_set_current_win(state.input_winid)
        vim.cmd('startinsert!')
      end
    end)
  end)
end

local function set_compose_buffer_text(text)
  if not (state.compose_bufnr and vim.api.nvim_buf_is_valid(state.compose_bufnr)) then
    return
  end

  set_buffer_text(state.compose_bufnr, text)
  vim.bo[state.compose_bufnr].modified = false

  local lines = vim.api.nvim_buf_get_lines(state.compose_bufnr, 0, -1, false)
  if state.compose_winid and vim.api.nvim_win_is_valid(state.compose_winid) then
    vim.api.nvim_win_set_cursor(state.compose_winid, { #lines, #(lines[#lines] or '') })
  end
end

local function navigate_prompt_history(direction, get_current_text, set_current_text)
  if #state.prompt_history == 0 then
    return
  end

  local draft_index = #state.prompt_history + 1
  if state.prompt_history_index == nil then
    state.prompt_history_draft = get_current_text()
    state.prompt_history_index = draft_index
  end

  local next_index = state.prompt_history_index + direction
  if next_index < 1 then
    next_index = 1
  elseif next_index > draft_index then
    next_index = draft_index
  end

  if next_index == state.prompt_history_index then
    return
  end

  state.prompt_history_index = next_index
  if next_index == draft_index then
    set_current_text(state.prompt_history_draft)
    return
  end
  set_current_text(state.prompt_history[next_index])
end

local function apply_compose_initial_text(opts)
  if opts.initial_text == nil then
    return
  end

  local next_text = opts.replace_text and opts.initial_text or merge_compose_text(get_existing_compose_text(), opts.initial_text)
  set_compose_buffer_text(next_text)
end

local function promote_input_to_compose()
  local input_text = get_existing_input_text()
  state.prompt_prefill = input_text ~= '' and input_text or nil
  close_existing_input_window({ preserve_contents = false, skip_focus = true })
  M.open_compose_buffer({
    initial_text = input_text,
    replace_text = true,
  })
end

local function configured_promote_keymaps()
  local compose_config = state.config.compose or {}
  local keymap = compose_config.promote_keymap
  if keymap == false or keymap == nil or keymap == '' then
    return {}
  end
  if type(keymap) == 'string' then
    return { keymap }
  end
  if type(keymap) == 'table' and is_list(keymap) then
    return keymap
  end
  cfg.notify('compose.promote_keymap must be a string, list, or false', vim.log.levels.WARN)
  return {}
end

local function setup_promote_keymaps(bufnr)
  for _, lhs in ipairs(configured_promote_keymaps()) do
    if type(lhs) == 'string' and lhs ~= '' then
      vim.keymap.set({ 'n', 'i' }, lhs, promote_input_to_compose, {
        buffer = bufnr,
        silent = true,
        desc = 'Promote prompt into compose buffer',
      })
    end
  end
end

local function clamp_width(width, min_width, max_width)
  if min_width and min_width > 0 then
    width = math.max(width, min_width)
  end
  if max_width and max_width > 0 then
    width = math.min(width, max_width)
  end
  return math.max(1, width)
end

local function compose_split_width(parent_win)
  local compose_config = state.config.compose or {}
  local available = vim.o.columns
  if parent_win and vim.api.nvim_win_is_valid(parent_win) then
    available = vim.api.nvim_win_get_width(parent_win)
  end

  local configured = tonumber(compose_config.width) or 0.4
  local width = configured
  if configured > 0 and configured < 1 then
    width = math.floor(available * configured)
  end

  local min_width = tonumber(compose_config.min_width) or 40
  local max_width = tonumber(compose_config.max_width) or 100
  local max_available = math.max(1, available - 20)
  return math.min(clamp_width(math.floor(width), min_width, max_width), max_available)
end

local compose_window_group = vim.api.nvim_create_augroup('CopilotAgentComposeWindow', { clear = false })

local function focus_window(winid)
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  if vim.api.nvim_get_current_tabpage() ~= tabpage then
    vim.api.nvim_set_current_tabpage(tabpage)
  end
  vim.api.nvim_set_current_win(winid)
end

local function track_compose_window(winid)
  state.compose_winid = winid
  vim.api.nvim_create_autocmd('WinClosed', {
    group = compose_window_group,
    pattern = tostring(winid),
    once = true,
    callback = function()
      if state.compose_winid == winid then
        state.compose_winid = nil
      end
    end,
  })
end

local function find_window_showing_buffer(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end

  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      if vim.api.nvim_win_is_valid(winid) and not win.is_floating_window(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
        return winid
      end
    end
  end
  return nil
end

local function resolve_compose_window()
  if
    state.compose_winid
    and vim.api.nvim_win_is_valid(state.compose_winid)
    and state.compose_bufnr
    and vim.api.nvim_buf_is_valid(state.compose_bufnr)
    and vim.api.nvim_win_get_buf(state.compose_winid) == state.compose_bufnr
  then
    return state.compose_winid
  end

  state.compose_winid = nil
  local winid = find_window_showing_buffer(state.compose_bufnr)
  if winid then
    track_compose_window(winid)
  end
  return winid
end

local function find_reusable_left_window(parent_win)
  if not (parent_win and vim.api.nvim_win_is_valid(parent_win)) then
    return nil
  end

  local parent_tab = vim.api.nvim_win_get_tabpage(parent_win)
  local parent_pos = vim.api.nvim_win_get_position(parent_win)
  local parent_row = parent_pos[1]
  local parent_col = parent_pos[2]
  local parent_bottom = parent_row + vim.api.nvim_win_get_height(parent_win)
  local best_winid
  local best_col = -1

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(parent_tab)) do
    if winid ~= parent_win and vim.api.nvim_win_is_valid(winid) and not win.is_floating_window(winid) and not win.is_chat_related_window(winid) then
      local pos = vim.api.nvim_win_get_position(winid)
      local row = pos[1]
      local col = pos[2]
      local bottom = row + vim.api.nvim_win_get_height(winid)
      local overlaps_parent = row < parent_bottom and parent_row < bottom
      if overlaps_parent and col < parent_col and col > best_col then
        best_winid = winid
        best_col = col
      end
    end
  end

  return best_winid
end

local function active_input_cursor_context()
  local bufnr = state.input_bufnr
  local winid = state.input_winid
  if not (bufnr and winid and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_is_valid(winid)) then
    return nil
  end
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row, col = cursor[1], cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local prompt_col = row == 1 and #input_prompt_prefix(bufnr) or 0

  return {
    bufnr = bufnr,
    winid = winid,
    row = row,
    col = col,
    line = line,
    prompt_col = prompt_col,
  }
end

local function replace_input_segment(ctx, start_col, end_col)
  start_col = math.max(ctx.prompt_col, math.floor(tonumber(start_col) or ctx.col))
  end_col = math.max(start_col, math.min(ctx.col, math.floor(tonumber(end_col) or ctx.col)))
  if end_col <= start_col then
    return
  end

  local updated = ctx.line:sub(1, start_col) .. ctx.line:sub(end_col + 1)
  vim.api.nvim_buf_set_lines(ctx.bufnr, ctx.row - 1, ctx.row, false, { updated })
  vim.api.nvim_win_set_cursor(ctx.winid, { ctx.row, start_col })
end

local function delete_input_to_prompt_start()
  local ctx = active_input_cursor_context()
  if not ctx or ctx.col <= ctx.prompt_col then
    return
  end
  replace_input_segment(ctx, ctx.prompt_col, ctx.col)
end

local function delete_input_previous_word()
  local ctx = active_input_cursor_context()
  if not ctx or ctx.col <= ctx.prompt_col then
    return
  end

  local idx = ctx.col
  while idx > ctx.prompt_col and ctx.line:sub(idx, idx):match('%s') do
    idx = idx - 1
  end
  while idx > ctx.prompt_col and not ctx.line:sub(idx, idx):match('%s') do
    idx = idx - 1
  end
  replace_input_segment(ctx, idx, ctx.col)
end

local function input_backspace_or_ignore()
  local ctx = active_input_cursor_context()
  if not ctx then
    return replace_termcodes('<BS>')
  end
  if ctx.col <= ctx.prompt_col then
    vim.api.nvim_win_set_cursor(ctx.winid, { ctx.row, ctx.prompt_col })
    return ''
  end
  return replace_termcodes('<BS>')
end

local _mode_permission = {
  ask = 'interactive',
  plan = 'interactive',
  agent = 'approve-reads',
  autopilot = 'approve-all',
}

local _mode_icon = {
  ask = '💬',
  plan = '📋',
  agent = '🤖',
  autopilot = '🚀',
}

local function create_input_buffer()
  local bufnr = find_named_buffer('copilot-agent-input') or vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, 'copilot-agent-input')
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].filetype = 'markdown'
  -- Keep copilot.lua enabled for the dedicated chat input buffer.
  vim.b[bufnr].copilot_enabled = true

  local function get_input_text()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local prompt_prefix_text = input_prompt_prefix(bufnr)
    local normalized = strip_prompt_prefix_from_text_lines(lines, prompt_prefix_text)
    return table.concat(normalized, '\n')
  end

  local function refresh_prompt()
    local mode = state.input_mode or 'agent'
    local icon = _mode_icon[mode] or ''
    local typed_count = vim.fn.strchars(get_input_text())
    local _, segments, placeholder = prompt.build(icon, mode, typed_count)
    set_input_prompt_prefix(bufnr, placeholder)
    prompt.apply(bufnr, segments)
    refresh_statuslines()
  end

  local cleaning_prompt_padding = false
  local function sanitize_multiline_prompt_padding()
    if cleaning_prompt_padding or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #lines < 2 then
      return
    end

    local prompt_prefix_text = input_prompt_prefix(bufnr)
    if type(prompt_prefix_text) ~= 'string' or prompt_prefix_text == '' then
      return
    end

    local changed = false
    local normalized = vim.deepcopy(lines)
    for idx = 2, #normalized do
      local line = normalized[idx]
      if type(line) == 'string' and vim.startswith(line, prompt_prefix_text) then
        normalized[idx] = line:sub(#prompt_prefix_text + 1)
        changed = true
      end
    end
    if not changed then
      return
    end

    local cursor
    local winid = state.input_winid
    if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      cursor = vim.api.nvim_win_get_cursor(winid)
    end

    cleaning_prompt_padding = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized)
    if cursor and cursor[1] > 1 then
      local row = math.min(cursor[1], #normalized)
      local col = cursor[2]
      local original = lines[row] or ''
      if vim.startswith(original, prompt_prefix_text) then
        col = math.max(0, col - #prompt_prefix_text)
      end
      vim.api.nvim_win_set_cursor(winid, { row, math.min(col, #(normalized[row] or '')) })
    end
    cleaning_prompt_padding = false
    refresh_prompt()
  end

  local function set_input_text(text)
    set_input_buffer_text(bufnr, text)
    vim.cmd('startinsert!')
  end

  local function submit(text)
    remember_prompt(text)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- Clear the input line and reset history navigation, but keep the window open.
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      reset_prompt_history_navigation()
      -- Re-apply the prompt prefix and overlay (cleared by buf_set_lines).
      refresh_prompt()
      vim.cmd('startinsert')
      submit_message_text(text)
    end)
  end

  local function submit_buffer()
    submit(vim.trim(get_input_text()))
  end

  local function confirm_completion_or_submit_input()
    local keys = visible_completion_accept_keys({ bufnr = bufnr })
    if keys then
      return keys
    end
    submit_buffer()
    return ''
  end

  -- Apply all shared action keymaps, then override the ones that differ in input context.
  setup_action_keymaps(bufnr)

  -- <C-s> submits directly; <CR> first accepts completion, otherwise submits.
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit_buffer, { buffer = bufnr, silent = true, desc = 'Submit prompt to Copilot' })
  vim.keymap.set('i', '<CR>', confirm_completion_or_submit_input, {
    buffer = bufnr,
    expr = true,
    replace_keycodes = false,
    silent = true,
    desc = 'Confirm completion or submit prompt',
  })
  vim.keymap.set('n', 'q', cancel_existing_input_window, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
  vim.keymap.set('n', '<Esc>', cancel_existing_input_window, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
  vim.keymap.set('i', '<Esc>', '<Esc>', { buffer = bufnr, silent = true, desc = 'Switch to normal mode' })
  vim.keymap.set('i', '<BS>', input_backspace_or_ignore, {
    buffer = bufnr,
    expr = true,
    replace_keycodes = false,
    silent = true,
    desc = 'Delete previous character without crossing the prompt prefix',
  })
  vim.keymap.set('i', '<C-w>', delete_input_previous_word, { buffer = bufnr, silent = true, desc = 'Delete previous input word (keep prompt prefix)' })
  vim.keymap.set('i', '<C-u>', delete_input_to_prompt_start, { buffer = bufnr, silent = true, desc = 'Delete input to prompt start' })
  -- <C-t> in input also refreshes the prompt prefix and returns to insert mode.
  vim.keymap.set({ 'n', 'i' }, '<C-t>', function()
    local idx = 1
    for i, m in ipairs(input_modes) do
      if m == state.input_mode then
        idx = i
        break
      end
    end
    local new_mode = input_modes[(idx % #input_modes) + 1]
    state.input_mode = new_mode
    set_agent_mode(new_mode)

    -- Apply the natural permission mode for this input mode.
    -- Respect manual overrides: if the user explicitly set permission via <M-a>,
    -- don't auto-reset it on mode change.
    local had_manual = state.permission_mode_manual
    state.permission_mode_manual = false
    local natural_perm = _mode_permission[new_mode]
    if natural_perm and not had_manual and natural_perm ~= state.permission_mode then
      state.permission_mode = natural_perm
      if state.session_id then
        request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = natural_perm }, function(_, err)
          if err then
            cfg.notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
          end
        end)
      end
    end

    refresh_prompt()
    require('copilot_agent.statusline').refresh_statuslines()
    vim.cmd('startinsert!')
  end, { buffer = bufnr, silent = true, desc = 'Cycle Copilot input mode (ask/plan/agent/autopilot)' })
  -- History navigation replaces buffer content directly in input context.
  vim.keymap.set({ 'n', 'i' }, '<C-p>', function()
    navigate_prompt_history(-1, get_input_text, set_input_text)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<C-n>', function()
    navigate_prompt_history(1, get_input_text, set_input_text)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-p>', function()
    navigate_prompt_history(-1, get_input_text, set_input_text)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-n>', function()
    navigate_prompt_history(1, get_input_text, set_input_text)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })
  setup_promote_keymaps(bufnr)

  -- Set the initial prompt prefix to reflect the current mode.
  refresh_prompt()

  -- Update the wave gradient on every keystroke (and normal-mode text edits).
  local function update_prompt_wave()
    local mode = state.input_mode or 'agent'
    local icon = _mode_icon[mode] or ''
    local typed_count = vim.fn.strchars(get_input_text())
    local _, segments = prompt.build(icon, mode, typed_count)
    prompt.apply(bufnr, segments)
  end
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = bufnr,
    callback = function()
      sanitize_multiline_prompt_padding()
      update_prompt_wave()
    end,
  })

  setup_completion_keymaps(bufnr)

  return bufnr
end

function M.open_input_window()
  local function apply_prefill()
    if state.prompt_prefill and state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr) then
      local text = state.prompt_prefill
      state.prompt_prefill = nil
      vim.schedule(function()
        set_input_buffer_text(state.input_bufnr, text)
        vim.cmd('startinsert!')
      end)
    end
  end

  local chat_winid = resolve_chat_window()
  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    if chat_winid and not is_input_anchored_below_chat(chat_winid, state.input_winid) then
      M._close_input_window({ preserve_contents = true, skip_focus = true })
    else
      vim.api.nvim_set_current_win(state.input_winid)
      clamp_input_cursor_to_prompt(state.input_bufnr, state.input_winid)
      vim.cmd('startinsert')
      refresh_separator()
      apply_prefill()
      return
    end
  end

  if not chat_winid then
    chat_winid = win.resolve_split_target()
  end

  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_set_current_win(state.input_winid)
    clamp_input_cursor_to_prompt(state.input_bufnr, state.input_winid)
    vim.cmd('startinsert')
    refresh_separator()
    apply_prefill()
    return
  end

  if not state.input_bufnr or not vim.api.nvim_buf_is_valid(state.input_bufnr) then
    state.input_bufnr = create_input_buffer()
  end

  -- Open a small horizontal split below the active chat window via the API.
  local parent_win = chat_winid
  if not parent_win then
    error('No non-floating window available for input split')
  end
  state.input_winid = vim.api.nvim_open_win(state.input_bufnr, true, {
    split = 'below',
    win = parent_win,
    height = 5,
  })
  win.protect_markdown_buffer(state.input_bufnr, state.input_winid)

  local wo = vim.wo[state.input_winid]
  wo.winfixheight = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  -- Statusline is populated by refresh_input_statusline below.
  refresh_statuslines()
  refresh_separator()

  clamp_input_cursor_to_prompt(state.input_bufnr, state.input_winid)
  vim.cmd('startinsert')
  apply_prefill()

  -- copilot.lua's default should_attach rejects unlisted scratch buffers.
  -- Force-attach the LSP client directly so virtual-text suggestions work.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(state.input_bufnr) then
      return
    end
    local ok, copilot_client = pcall(require, 'copilot.client')
    if ok and type(copilot_client.buf_attach) == 'function' then
      pcall(copilot_client.buf_attach, true, state.input_bufnr)
    end
  end)
end

local function close_existing_compose_window(opts)
  opts = opts or {}
  if not opts.preserve_contents and state.compose_bufnr and vim.api.nvim_buf_is_valid(state.compose_bufnr) then
    set_buffer_text(state.compose_bufnr, '')
    vim.bo[state.compose_bufnr].modified = false
  end
  if state.compose_winid and vim.api.nvim_win_is_valid(state.compose_winid) then
    vim.api.nvim_win_close(state.compose_winid, true)
    state.compose_winid = nil
  end
  local chat_winid = resolve_chat_window()
  if not opts.skip_focus and chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
    vim.api.nvim_set_current_win(chat_winid)
  end
end

local function cancel_existing_compose_window()
  if vim.trim(get_existing_compose_text()) == '' then
    close_existing_compose_window()
    return
  end

  vim.ui.select({ 'Keep editing', 'Close compose buffer' }, { prompt = 'Discard unsent compose draft?' }, function(choice)
    if choice == 'Close compose buffer' then
      close_existing_compose_window()
      return
    end
    vim.schedule(function()
      if state.compose_winid and vim.api.nvim_win_is_valid(state.compose_winid) then
        vim.api.nvim_set_current_win(state.compose_winid)
        vim.cmd('startinsert!')
      end
    end)
  end)
end

local function create_compose_buffer()
  local bufnr = find_named_buffer('copilot-agent-compose') or vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, 'copilot-agent-compose')
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].filetype = 'markdown'
  vim.b[bufnr].copilot_enabled = true

  local function get_compose_text()
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  end

  local function submit_buffer()
    local text = get_compose_text()
    remember_prompt(text)
    if submit_message_text(text) then
      set_compose_buffer_text('')
      state.prompt_prefill = nil
      reset_prompt_history_navigation()
    end
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      submit_buffer()
      vim.bo[bufnr].modified = false
      vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr, modeline = false })
    end,
  })

  setup_action_keymaps(bufnr)

  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit_buffer, { buffer = bufnr, silent = true, desc = 'Submit compose buffer to Copilot' })
  vim.keymap.set({ 'n', 'i' }, '<leader>cs', submit_buffer, { buffer = bufnr, silent = true, desc = 'Submit compose buffer to Copilot' })
  vim.keymap.set('i', '<CR>', confirm_completion_or_submit, {
    buffer = bufnr,
    expr = true,
    replace_keycodes = false,
    silent = true,
    desc = 'Confirm completion or insert newline',
  })
  vim.keymap.set('n', 'q', cancel_existing_compose_window, { buffer = bufnr, silent = true, desc = 'Close compose buffer' })
  vim.keymap.set('n', '<Esc>', cancel_existing_compose_window, { buffer = bufnr, silent = true, desc = 'Close compose buffer' })
  vim.keymap.set('i', '<Esc>', '<Esc>', { buffer = bufnr, silent = true, desc = 'Switch to normal mode' })
  vim.keymap.set({ 'n', 'i' }, '<C-p>', function()
    navigate_prompt_history(-1, get_compose_text, set_compose_buffer_text)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<C-n>', function()
    navigate_prompt_history(1, get_compose_text, set_compose_buffer_text)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-p>', function()
    navigate_prompt_history(-1, get_compose_text, set_compose_buffer_text)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-n>', function()
    navigate_prompt_history(1, get_compose_text, set_compose_buffer_text)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })

  setup_completion_keymaps(bufnr)

  return bufnr
end

function M.open_compose_buffer(opts)
  opts = opts or {}
  if not state.compose_bufnr or not vim.api.nvim_buf_is_valid(state.compose_bufnr) then
    state.compose_bufnr = create_compose_buffer()
  end

  local existing_compose_winid = resolve_compose_window()
  if existing_compose_winid then
    focus_window(existing_compose_winid)
    apply_compose_initial_text(opts)
    vim.cmd('startinsert')
    return state.compose_bufnr
  end

  local chat_winid = resolve_chat_window()
  if not chat_winid then
    chat_winid = win.resolve_split_target()
  end

  local parent_win = chat_winid
  if not parent_win then
    error('No non-floating window available for compose split')
  end

  if opts.layout == 'tab' then
    vim.cmd('tabnew')
    track_compose_window(vim.api.nvim_get_current_win())
    vim.api.nvim_win_set_buf(state.compose_winid, state.compose_bufnr)
  else
    local reusable_winid = find_reusable_left_window(parent_win)
    if reusable_winid then
      focus_window(reusable_winid)
      vim.api.nvim_win_set_buf(reusable_winid, state.compose_bufnr)
      track_compose_window(reusable_winid)
    else
      track_compose_window(vim.api.nvim_open_win(state.compose_bufnr, true, {
        split = 'left',
        win = parent_win,
        width = compose_split_width(parent_win),
      }))
    end
  end
  win.protect_markdown_buffer(state.compose_bufnr, state.compose_winid)

  local wo = vim.wo[state.compose_winid]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'

  apply_compose_initial_text(opts)

  vim.cmd('startinsert')
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(state.compose_bufnr) then
      return
    end
    local ok, copilot_client = pcall(require, 'copilot.client')
    if ok and type(copilot_client.buf_attach) == 'function' then
      pcall(copilot_client.buf_attach, true, state.compose_bufnr)
    end
  end)
  return state.compose_bufnr
end

function M.promote_input_to_compose()
  promote_input_to_compose()
end

function M.send_buffer()
  local bufnr = state.compose_bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    cfg.notify('No Copilot compose buffer is open', vim.log.levels.INFO)
    return
  end
  local compose_winid = state.compose_winid
  local call = compose_winid and vim.api.nvim_win_is_valid(compose_winid) and vim.api.nvim_win_call or vim.api.nvim_buf_call
  local target = call == vim.api.nvim_win_call and compose_winid or bufnr
  call(target, function()
    vim.cmd('write')
  end)
end

M._close_input_window = close_existing_input_window
M._cancel_input = cancel_existing_input_window
M._close_compose_window = close_existing_compose_window
M._promote_input_to_compose = promote_input_to_compose
M._resolve_chat_window = resolve_chat_window
M._is_input_anchored_below_chat = is_input_anchored_below_chat
M._input_completefunc = input_completefunc
M._input_omnifunc = input_completefunc
M.refresh_separator = refresh_separator
M._discovered_agent_names = discovered_agent_names
M._discovered_skill_names = discovered_skill_names
M._discovered_instruction_names = discovered_instruction_names
M._discovered_mcp_names = discovered_mcp_names
M._discovered_model_ids = discovered_model_ids
M._discovered_session_items = discovered_session_items
M._attachment_completion_context = attachment_completion_context
M._extract_inline_attachments = extract_inline_attachments
M._confirm_completion_or_submit = confirm_completion_or_submit
M._select_visible_completion = select_visible_completion
M._input_backspace_or_ignore = input_backspace_or_ignore
M._delete_input_previous_word = delete_input_previous_word
M._delete_input_to_prompt_start = delete_input_to_prompt_start
M._has_completion_trigger_space = has_completion_trigger_space
M._input_completion_context = input_completion_context
M._input_prompt_prefix = input_prompt_prefix
M._strip_prompt_prefix_from_text_lines = strip_prompt_prefix_from_text_lines

return M
