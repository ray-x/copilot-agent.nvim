-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local approvals = require('copilot_agent.approvals')
local chat = require('copilot_agent.chat')
local checkpoints = require('copilot_agent.checkpoints')
local discovery = require('copilot_agent.discovery')
local events = require('copilot_agent.events')
local http = require('copilot_agent.http')
local init_project = require('copilot_agent.project_init')
local lsp = require('copilot_agent.lsp')
local model = require('copilot_agent.model')
local render = require('copilot_agent.render')
local service = require('copilot_agent.service')
local session = require('copilot_agent.session')
local session_names = require('copilot_agent.session_names')
local sl = require('copilot_agent.statusline')
local tasks = require('copilot_agent.tasks')
local utils = require('copilot_agent.utils')
local window = require('copilot_agent.window')

local state = cfg.state
local notify = cfg.notify
local log = cfg.log
local append_entry = render.append_entry
local open_todo_float = render.open_todo_float
local refresh_statuslines = sl.refresh_statuslines
local request = http.request
local split_lines = utils.split_lines
local is_list = vim.islist

local M = {}
local SEARCH_LABEL_MAX_LEN = 72 -- Long search hits should stay scannable inside vim.ui.select pickers.
local RESULT_FLOAT_WIDTH_RATIO = 0.8 -- Result floats should use most of the editor width without becoming full-screen.
local RESULT_FLOAT_MAX_WIDTH = 120 -- Cap result floats so long lines remain readable on very wide monitors.
local RESULT_FLOAT_MIN_HEIGHT = 12 -- Keep short result windows tall enough to show title, borders, and a few lines of content.
local RESULT_FLOAT_BORDER_LINES = 2 -- Reserve vertical space for the float border around markdown results.
local RESULT_FLOAT_HEIGHT_RATIO = 0.8 -- Leave editor context visible above and below slash-command result windows.
local SIDE_QUESTION_TIMEOUT_MS = 120000 -- Side-question sessions should fail fast rather than polling forever.
local SIDE_QUESTION_POLL_INTERVAL_MS = 400 -- Poll often enough to feel responsive without hammering the local service.
local working_directory = service.working_directory
local mode_permission = {
  ask = 'interactive',
  plan = 'interactive',
  agent = 'approve-reads',
  autopilot = 'approve-all',
}
local plan_mode_command

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

local function run_command(args, cwd)
  if vim.system then
    local result = vim.system(args, { text = true, cwd = cwd }):wait()
    local output = vim.trim((result.stdout or '') ~= '' and result.stdout or (result.stderr or ''))
    if result.code ~= 0 then
      return nil, output ~= '' and output or table.concat(args, ' ')
    end
    return output, nil
  end

  local output = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(table.concat(output, '\n'))
  end
  return vim.trim(table.concat(output, '\n')), nil
end

local function shell_command_text(args)
  local parts = {}
  for _, arg in ipairs(args or {}) do
    parts[#parts + 1] = vim.fn.shellescape(tostring(arg))
  end
  return table.concat(parts, ' ')
end

local function open_path(path)
  if type(path) ~= 'string' or path == '' then
    return
  end
  local _, err = window.open_path_safely(path)
  if err then
    notify('Opened with a fallback buffer after :edit failed: ' .. tostring(err), vim.log.levels.WARN)
  end
end

local function now_ms()
  local uv = vim.uv or vim.loop
  return uv and uv.now and uv.now() or math.floor(vim.fn.reltimefloat(vim.fn.reltime()) * 1000)
end

local function clear_consumed_attachments(opts)
  if not opts or type(opts.attachments) ~= 'table' or vim.tbl_isempty(opts.attachments) then
    return
  end
  state.pending_attachments = {}
  refresh_statuslines()
end

local function build_api_attachments(attachments)
  local api_attachments = {}
  local temp_files = {}
  for _, attachment in ipairs(attachments or {}) do
    if attachment.type == 'file' or attachment.type == 'directory' or attachment.type == 'image' then
      api_attachments[#api_attachments + 1] = { type = 'file', path = attachment.path }
      if attachment.temp then
        temp_files[#temp_files + 1] = attachment.path
      end
    elseif attachment.type == 'selection' then
      api_attachments[#api_attachments + 1] = {
        type = 'selection',
        filePath = attachment.path,
        text = attachment.text,
        lineRange = attachment.start_line and { start = attachment.start_line, ['end'] = attachment.end_line } or nil,
      }
    end
  end
  return api_attachments, temp_files
end

local function cleanup_temp_files(paths)
  for _, path in ipairs(paths or {}) do
    pcall(os.remove, path)
  end
end

local function resolve_path_arg(path)
  path = vim.trim(path or '')
  if path == '' then
    return nil
  end
  local expanded = vim.fn.expand(path)
  if not vim.startswith(expanded, '/') and not expanded:match('^%a:[/\\]') then
    expanded = working_directory() .. '/' .. expanded
  end
  return approvals.normalize_directory(expanded)
end

local function dispatch_prompt(prompt, opts)
  clear_consumed_attachments(opts)
  require('copilot_agent').ask(prompt, { attachments = vim.deepcopy((opts or {}).attachments or {}) })
end

local function show_markdown_result(title, lines)
  local normalized_lines = {}
  for _, line in ipairs(lines or {}) do
    vim.list_extend(normalized_lines, split_lines(type(line) == 'string' and line or tostring(line or '')))
  end
  if vim.tbl_isempty(normalized_lines) then
    normalized_lines = { '' }
  end

  local width = math.min(math.floor(vim.o.columns * RESULT_FLOAT_WIDTH_RATIO), RESULT_FLOAT_MAX_WIDTH)
  local height = math.min(math.max(#normalized_lines + RESULT_FLOAT_BORDER_LINES, RESULT_FLOAT_MIN_HEIGHT), math.floor(vim.o.lines * RESULT_FLOAT_HEIGHT_RATIO))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, normalized_lines)
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
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  })
  window.disable_folds(winid)
  window.set_window_syntax(winid, 'markdown')
  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true })
end

local function delete_side_session(session_id, callback)
  request('DELETE', string.format('/sessions/%s?delete=true', session_id), nil, function(_, err)
    if callback then
      callback(err)
    end
  end, { auto_start = false })
end

local function first_non_empty_string(...)
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if type(value) == 'string' and value ~= '' then
      return value
    end
  end
  return nil
end

local function event_type_of(event)
  if type(event) ~= 'table' then
    return nil
  end
  return event.type or event.Type
end

local function event_data_of(event)
  if type(event) ~= 'table' then
    return {}
  end
  local data = event.data or event.Data
  return type(data) == 'table' and data or {}
end

local function extract_side_session_answer(session_events)
  local answer = nil
  local answer_parts = {}
  local turn_started = false
  local turn_finished = false
  local final_message_seen = false
  local saw_tool_activity = false
  for _, event in ipairs(session_events or {}) do
    local event_type = event_type_of(event)
    local data = event_data_of(event)
    if event_type == 'assistant.turn_start' then
      turn_started = true
    elseif event_type == 'assistant.message_delta' then
      local delta = first_non_empty_string(data.deltaContent, data.DeltaContent, data.content, data.Content)
      if delta and vim.trim(delta) ~= '' then
        answer_parts[#answer_parts + 1] = delta
      end
    elseif event_type == 'assistant.message' then
      local tool_requests = data.toolRequests or data.ToolRequests
      local has_tool_requests = type(tool_requests) == 'table' and not vim.tbl_isempty(tool_requests)
      local content = first_non_empty_string(data.content, data.Content)
      if has_tool_requests then
        saw_tool_activity = true
      end
      if content and vim.trim(content) ~= '' then
        answer = content
        if not has_tool_requests then
          final_message_seen = true
        end
      end
    elseif type(event_type) == 'string' and vim.startswith(event_type, 'tool.') then
      saw_tool_activity = true
    elseif event_type == 'assistant.turn_end' and turn_started then
      turn_finished = true
    elseif event_type == 'session.error' or event_type == 'error' then
      return nil, true, first_non_empty_string(data.message, data.Message) or vim.inspect(data)
    end
  end
  if (answer == nil or answer == '') and #answer_parts > 0 then
    answer = table.concat(answer_parts)
  end
  local has_answer = type(answer) == 'string' and vim.trim(answer) ~= ''
  return answer, final_message_seen or (turn_finished and has_answer and not saw_tool_activity), nil
end

local function show_side_question_result(prompt, answer)
  local lines = {
    '# /ask',
    '',
    '## Question',
    '',
    prompt,
    '',
    '## Answer',
    '',
  }
  vim.list_extend(lines, vim.split(vim.trim(answer or 'No answer returned.'), '\n', { plain = true }))
  show_markdown_result('Copilot /ask', lines)
end

local function matching_item(items, query)
  query = vim.trim(query or ''):lower()
  if query == '' then
    return nil
  end
  for _, item in ipairs(items or {}) do
    local name = (item.name or ''):lower()
    local path = (item.path or ''):lower()
    if name == query or path == query or vim.endswith(path, query) then
      return item
    end
  end
  for _, item in ipairs(items or {}) do
    if (item.name or ''):lower():find(query, 1, true) then
      return item
    end
  end
  return nil
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
  if #text <= SEARCH_LABEL_MAX_LEN then
    return text
  end
  return text:sub(1, SEARCH_LABEL_MAX_LEN - 1) .. '…'
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

local function select_model_command(args)
  if args ~= '' then
    model.select_model(args)
    return true
  end
  model.select_model()
  return true
end

local function resume_session_command(args)
  if args ~= '' then
    session.switch_to_session_id(args)
    return true
  end
  session.switch_session()
  return true
end

local function new_session_command()
  session.new_session()
  return true
end

local function clear_session_command()
  session.clear_and_new_session()
  return true
end

local function merge_session_catalog(response)
  local merged = {}
  local order = {}

  local function upsert(item, live_source)
    local session_id = item and item.sessionId or nil
    if type(session_id) ~= 'string' or session_id == '' then
      return
    end

    local normalized = vim.deepcopy(item)
    normalized.live = live_source == true or normalized.live == true
    if not merged[session_id] then
      merged[session_id] = normalized
      order[#order + 1] = session_id
      return
    end

    local existing = merged[session_id]
    if normalized.live then
      normalized.summary = normalized.summary or existing.summary
      normalized.workingDirectory = normalized.workingDirectory or existing.workingDirectory
      normalized.workspacePath = normalized.workspacePath or existing.workspacePath
      normalized.modifiedTime = normalized.modifiedTime or existing.modifiedTime
      normalized.startTime = normalized.startTime or existing.startTime
      normalized.createdAt = normalized.createdAt or existing.createdAt
      merged[session_id] = normalized
      return
    end

    existing.summary = existing.summary or normalized.summary
    existing.workingDirectory = existing.workingDirectory or normalized.workingDirectory
    existing.workspacePath = existing.workspacePath or normalized.workspacePath
    existing.modifiedTime = existing.modifiedTime or normalized.modifiedTime
    existing.startTime = existing.startTime or normalized.startTime
    existing.createdAt = existing.createdAt or normalized.createdAt
  end

  for _, item in ipairs((response and response.persisted) or {}) do
    upsert(item, false)
  end
  for _, item in ipairs((response and response.live) or {}) do
    upsert(item, true)
  end

  local sessions = {}
  for _, session_id in ipairs(order) do
    sessions[#sessions + 1] = merged[session_id]
  end
  table.sort(sessions, function(left, right)
    local left_key = first_non_empty_string(left.modifiedTime, left.startTime, left.createdAt) or ''
    local right_key = first_non_empty_string(right.modifiedTime, right.startTime, right.createdAt) or ''
    return left_key > right_key
  end)
  return sessions
end

local function fetch_session_catalog(callback)
  request('GET', '/sessions', nil, function(response, err)
    if err then
      callback(nil, err)
      return
    end
    callback(merge_session_catalog(response), nil)
  end)
end

local function session_label(session_id, summary)
  local resolved = session_names.resolve(summary, session_id)
  local formatted_id = utils.format_session_id(session_id)
  if type(resolved) == 'string' and resolved ~= '' then
    return resolved .. ' [' .. formatted_id .. ']'
  end
  return formatted_id
end

local function find_session_record(sessions, token)
  token = vim.trim(token or '')
  if token == '' then
    return nil
  end

  local lowered = token:lower()
  for _, item in ipairs(sessions or {}) do
    local session_id = item.sessionId or ''
    if session_id:lower() == lowered then
      return item
    end
  end

  for _, item in ipairs(sessions or {}) do
    local session_id = item.sessionId or ''
    if utils.format_session_id(session_id):lower() == lowered then
      return item
    end
  end

  for _, item in ipairs(sessions or {}) do
    local resolved = session_names.resolve(item.summary, item.sessionId)
    if type(resolved) == 'string' and resolved:lower() == lowered then
      return item
    end
  end

  local prefix_matches = {}
  for _, item in ipairs(sessions or {}) do
    local session_id = (item.sessionId or ''):lower()
    if lowered ~= '' and vim.startswith(session_id, lowered) then
      prefix_matches[#prefix_matches + 1] = item
    end
  end
  if #prefix_matches == 1 then
    return prefix_matches[1]
  end

  return nil
end

local function resolve_session_target(raw, opts, callback)
  opts = opts or {}
  raw = vim.trim(raw or '')
  if raw == '' then
    if state.session_id and state.session_id ~= '' then
      callback({
        session_id = state.session_id,
        session = nil,
        checkpoint_info = checkpoints.session_info(state.session_id),
      }, nil)
      return
    end
    callback(nil, opts.missing_message or 'No active session')
    return
  end

  fetch_session_catalog(function(sessions, err)
    if err then
      callback(nil, err)
      return
    end

    local record = find_session_record(sessions, raw)
    local session_id = record and record.sessionId or raw
    local checkpoint_info = checkpoints.session_info(session_id)
    if not record and not checkpoint_info and not opts.allow_raw_id then
      callback(nil, 'Session not found: ' .. raw)
      return
    end
    callback({
      session_id = session_id,
      session = record,
      checkpoint_info = checkpoint_info,
    }, nil)
  end)
end

local function parse_session_timestamp(value)
  value = vim.trim(value or '')
  if value == '' then
    return nil
  end

  local normalized = value:gsub('%.%d+', '')
  local zulu = normalized:match('^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)Z$')
  if zulu then
    local parsed = tonumber(vim.fn.strptime('%Y-%m-%dT%H:%M:%S', zulu))
    if parsed and parsed >= 0 then
      return parsed
    end
    return nil
  end

  local base, sign, hours, minutes = normalized:match('^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)([+-])(%d%d):?(%d%d)$')
  if base and sign and hours and minutes then
    local parsed = tonumber(vim.fn.strptime('%Y-%m-%dT%H:%M:%S', base))
    if parsed then
      local offset = tonumber(hours) * 3600 + tonumber(minutes) * 60
      if sign == '+' then
        return parsed - offset
      end
      return parsed + offset
    end
  end

  local parsed = tonumber(vim.fn.strptime('%Y-%m-%dT%H:%M:%S', normalized))
  if parsed and parsed >= 0 then
    return parsed
  end
  return nil
end

local function render_session_info(target, live_summary)
  local session_id = target.session_id
  local summary = (live_summary and live_summary.summary) or (target.session and target.session.summary) or nil
  local custom_name = session_names.get(session_id)
  local checkpoint_info = target.checkpoint_info or checkpoints.session_info(session_id)
  local lines = {
    'Session info:',
    '  Label: ' .. session_label(session_id, summary),
    '  Session ID: ' .. session_id,
  }

  if custom_name and custom_name ~= '' then
    lines[#lines + 1] = '  Saved name: ' .. custom_name
  end
  if type(summary) == 'string' and summary ~= '' and summary ~= custom_name then
    lines[#lines + 1] = '  Summary: ' .. summary
  end

  local session_working_directory = first_non_empty_string(
    live_summary and live_summary.workingDirectory,
    target.session and target.session.workingDirectory,
    checkpoint_info and checkpoint_info.deleted_working_directory,
    session_id == state.session_id and state.session_working_directory or nil
  )
  if session_working_directory then
    lines[#lines + 1] = '  Working directory: ' .. vim.fn.fnamemodify(session_working_directory, ':~')
  end

  local workspace_path = first_non_empty_string(live_summary and live_summary.workspacePath, target.session and target.session.workspacePath)
  if workspace_path then
    lines[#lines + 1] = '  Workspace path: ' .. workspace_path
  end

  local created_at = first_non_empty_string(live_summary and live_summary.createdAt, target.session and target.session.createdAt)
  if created_at then
    lines[#lines + 1] = '  Created: ' .. created_at
  end
  local modified_at = first_non_empty_string(target.session and target.session.modifiedTime, target.session and target.session.startTime)
  if modified_at then
    lines[#lines + 1] = '  Last activity: ' .. modified_at
  end

  lines[#lines + 1] = '  Attached here: ' .. ((session_id == state.session_id) and 'yes' or 'no')
  lines[#lines + 1] = '  Live: ' .. (((live_summary and live_summary.live) or (target.session and target.session.live)) and 'yes' or 'no')

  local model_name = first_non_empty_string(live_summary and live_summary.model, session_id == state.session_id and state.current_model or nil)
  if model_name then
    lines[#lines + 1] = '  Model: ' .. model_name
  end
  if live_summary and live_summary.agentMode then
    lines[#lines + 1] = '  Mode: ' .. live_summary.agentMode
  elseif session_id == state.session_id and state.input_mode then
    lines[#lines + 1] = '  Mode: ' .. state.input_mode
  end
  if live_summary and live_summary.permissionMode then
    lines[#lines + 1] = '  Permission: ' .. live_summary.permissionMode
  elseif session_id == state.session_id and state.permission_mode then
    lines[#lines + 1] = '  Permission: ' .. state.permission_mode
  end
  if live_summary and live_summary.agent then
    lines[#lines + 1] = '  Agent: ' .. live_summary.agent
  end

  if checkpoint_info then
    lines[#lines + 1] = '  Checkpoints: ' .. tostring(checkpoint_info.checkpoint_count or 0)
    if checkpoint_info.deleted_at then
      lines[#lines + 1] = '  Soft-deleted: ' .. checkpoint_info.deleted_at
    end
    if checkpoint_info.purge_after then
      lines[#lines + 1] = '  Purge after: ' .. checkpoint_info.purge_after
    end
  end

  if live_summary and live_summary.live then
    lines[#lines + 1] = string.format(
      '  Discovery: %d instructions, %d agents, %d skills, %d MCP servers',
      tonumber(live_summary.instructionCount) or 0,
      tonumber(live_summary.agentCount) or 0,
      tonumber(live_summary.skillCount) or 0,
      tonumber(live_summary.mcpCount) or 0
    )
  end

  append_entry('system', table.concat(lines, '\n'))
end

local function session_info_command(args)
  resolve_session_target(args, { missing_message = 'No active session to inspect' }, function(target, err)
    if err then
      append_entry('error', err)
      return
    end

    if target.session_id == state.session_id then
      request('GET', '/sessions/' .. target.session_id, nil, function(response, request_err)
        if request_err then
          render_session_info(target, target.session)
          return
        end
        render_session_info(target, response)
      end)
      return
    end

    render_session_info(target, target.session)
  end)
  return true
end

local function session_checkpoints_command(args)
  resolve_session_target(args, { missing_message = 'No active session to inspect checkpoints for' }, function(target, err)
    if err then
      append_entry('error', err)
      return
    end

    local details, checkpoint_info = checkpoints.list_details(target.session_id)
    local lines = {
      'Session checkpoints:',
      '  Session: ' .. session_label(target.session_id, target.session and target.session.summary),
    }
    if checkpoint_info and checkpoint_info.deleted_at then
      lines[#lines + 1] = '  Soft-deleted: ' .. checkpoint_info.deleted_at
    end
    if checkpoint_info and checkpoint_info.purge_after then
      lines[#lines + 1] = '  Purge after: ' .. checkpoint_info.purge_after
    end

    if vim.tbl_isempty(details) then
      lines[#lines + 1] = '  No checkpoints recorded.'
      append_entry('system', table.concat(lines, '\n'))
      return
    end

    for _, item in ipairs(details) do
      local header = '  - ' .. tostring(item.id or '<unknown>')
      if item.created_at then
        header = header .. '  ' .. item.created_at
      end
      lines[#lines + 1] = header
      if item.prompt_summary then
        lines[#lines + 1] = '    prompt: ' .. item.prompt_summary
      end
      if item.assistant_summary then
        lines[#lines + 1] = '    reply: ' .. item.assistant_summary
      end
    end

    append_entry('system', table.concat(lines, '\n'))
  end)
  return true
end

local function session_files_command(args)
  resolve_session_target(args, { missing_message = 'No active session to inspect files for' }, function(target, err)
    if err then
      append_entry('error', err)
      return
    end

    local files, file_err = checkpoints.list_files(target.session_id)
    if file_err then
      append_entry('error', 'Failed to list session files: ' .. file_err)
      return
    end

    local lines = {
      'Session files:',
      '  Session: ' .. session_label(target.session_id, target.session and target.session.summary),
    }
    if not files or vim.tbl_isempty(files) then
      lines[#lines + 1] = '  No checkpoint snapshot files recorded.'
      append_entry('system', table.concat(lines, '\n'))
      return
    end

    local max_items = 200
    lines[#lines + 1] = '  Files: ' .. tostring(#files)
    for idx = 1, math.min(#files, max_items) do
      lines[#lines + 1] = '  - ' .. files[idx]
    end
    if #files > max_items then
      lines[#lines + 1] = string.format('  … %d more files', #files - max_items)
    end
    append_entry('system', table.concat(lines, '\n'))
  end)
  return true
end

local function session_cleanup_command(args)
  if vim.trim(args or '') ~= '' then
    append_entry('error', 'Usage: /session cleanup')
    return true
  end

  local removed, errors = checkpoints.prune_deleted()
  local lines = {
    'Session cleanup:',
    string.format('  Pruned %d deleted checkpoint repo(s)', removed),
  }
  for _, message in ipairs(errors or {}) do
    lines[#lines + 1] = '  - ' .. message
  end
  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function parse_session_prune_args(args)
  local usage = 'Usage: /session prune (--older-than <days> [--include-named] | --keep-last <count> [--session <id>]) [--dry-run]'
  local tokens = vim.split(vim.trim(args or ''), '%s+', { trimempty = true })
  local parsed = {
    dry_run = false,
    include_named = false,
    older_than_days = nil,
    keep_last = nil,
    session_id = nil,
    mode = nil,
  }

  local idx = 1
  while idx <= #tokens do
    local token = tokens[idx]
    if token == '--dry-run' then
      parsed.dry_run = true
    elseif token == '--include-named' then
      parsed.include_named = true
    elseif token == '--older-than' then
      idx = idx + 1
      local value = tonumber(tokens[idx] or '')
      if not value or value < 0 then
        return nil, usage
      end
      parsed.older_than_days = value
    elseif token == '--keep-last' then
      idx = idx + 1
      local value = tonumber(tokens[idx] or '')
      if not value or value < 1 then
        return nil, usage
      end
      parsed.keep_last = math.floor(value)
    elseif token == '--session' then
      idx = idx + 1
      local value = vim.trim(tokens[idx] or '')
      if value == '' then
        return nil, usage
      end
      parsed.session_id = value
    else
      local inline = token:match('^%-%-older%-than=(.+)$')
      if inline then
        local value = tonumber(inline)
        if not value or value < 0 then
          return nil, usage
        end
        parsed.older_than_days = value
      else
        inline = token:match('^%-%-keep%-last=(.+)$')
        if inline then
          local value = tonumber(inline)
          if not value or value < 1 then
            return nil, usage
          end
          parsed.keep_last = math.floor(value)
        else
          inline = token:match('^%-%-session=(.+)$')
          if inline then
            inline = vim.trim(inline)
            if inline == '' then
              return nil, usage
            end
            parsed.session_id = inline
          elseif vim.startswith(token, '--') then
            return nil, usage
          elseif not parsed.session_id then
            parsed.session_id = token
          else
            return nil, usage
          end
        end
      end
    end
    idx = idx + 1
  end

  if parsed.older_than_days ~= nil and parsed.keep_last ~= nil then
    return nil, usage
  end

  if parsed.older_than_days ~= nil then
    parsed.mode = 'sessions'
  elseif parsed.keep_last ~= nil then
    parsed.mode = 'checkpoints'
  else
    return nil, usage
  end

  if parsed.mode == 'sessions' and parsed.session_id then
    return nil, usage
  end
  if parsed.mode == 'checkpoints' and parsed.include_named then
    return nil, usage
  end
  return parsed, nil
end

local function append_session_prune_report(title, opts, candidates, skipped, failures)
  local lines = {
    title,
    string.format('  Older than: %d day(s)', opts.older_than_days),
    '  Include named: ' .. (opts.include_named and 'yes' or 'no'),
    '  Candidates: ' .. tostring(#candidates),
  }

  if skipped.live > 0 then
    lines[#lines + 1] = '  Skipped live sessions: ' .. tostring(skipped.live)
  end
  if skipped.active > 0 then
    lines[#lines + 1] = '  Skipped active sessions: ' .. tostring(skipped.active)
  end
  if skipped.named > 0 then
    lines[#lines + 1] = '  Skipped named sessions: ' .. tostring(skipped.named)
  end
  if skipped.untimed > 0 then
    lines[#lines + 1] = '  Skipped untimed sessions: ' .. tostring(skipped.untimed)
  end

  if vim.tbl_isempty(candidates) then
    lines[#lines + 1] = '  No sessions matched.'
  else
    for _, candidate in ipairs(candidates) do
      local line = '  - ' .. candidate.label
      if candidate.timestamp then
        line = line .. '  ' .. candidate.timestamp
      end
      if candidate.named then
        line = line .. '  [named]'
      end
      lines[#lines + 1] = line
    end
  end

  for _, failure in ipairs(failures or {}) do
    lines[#lines + 1] = '  ! ' .. failure.label .. ' — ' .. failure.error
  end

  append_entry('system', table.concat(lines, '\n'))
end

local function append_checkpoint_prune_report(title, target, parsed, total, result, dry_run)
  local summary = target and target.session and target.session.summary or nil
  local session_id = target and target.session_id or state.session_id or '<unknown>'
  local removed = result and (tonumber(result.removed) or 0) or math.max(total - parsed.keep_last, 0)
  local kept = result and (tonumber(result.kept) or 0) or math.min(total, parsed.keep_last)
  local lines = {
    title,
    '  Mode: checkpoints',
    '  Session: ' .. session_label(session_id, summary),
    '  Keep last: ' .. tostring(parsed.keep_last),
    '  Current checkpoints: ' .. tostring(total),
  }

  if dry_run then
    lines[#lines + 1] = '  Would remove: ' .. tostring(removed)
  else
    lines[#lines + 1] = '  Removed: ' .. tostring(removed)
    lines[#lines + 1] = '  Kept: ' .. tostring(kept)
  end

  if result and result.first_kept then
    lines[#lines + 1] = '  First kept: ' .. tostring(result.first_kept)
  end
  if result and result.last_kept then
    lines[#lines + 1] = '  Last kept: ' .. tostring(result.last_kept)
  end
  if removed == 0 then
    lines[#lines + 1] = '  No checkpoint pruning needed.'
  end

  append_entry('system', table.concat(lines, '\n'))
end

local function session_prune_command(args)
  local parsed, parse_err = parse_session_prune_args(args)
  if parse_err then
    append_entry('error', parse_err)
    return true
  end

  if parsed.mode == 'checkpoints' then
    resolve_session_target(parsed.session_id or '', {
      missing_message = 'No active session to prune checkpoints for',
      allow_raw_id = true,
    }, function(target, err)
      if err then
        append_entry('error', err)
        return
      end

      local checkpoint_info = target.checkpoint_info or checkpoints.session_info(target.session_id)
      local total = tonumber(checkpoint_info and checkpoint_info.checkpoint_count) or #(checkpoints.list(target.session_id) or {})
      if parsed.dry_run then
        append_checkpoint_prune_report('Session prune preview:', target, parsed, total, nil, true)
        return
      end

      local result, prune_err = checkpoints.prune_history(target.session_id, parsed.keep_last)
      if prune_err then
        append_entry('error', 'Failed to prune checkpoints: ' .. tostring(prune_err))
        return
      end

      append_checkpoint_prune_report('Session prune:', target, parsed, total, result, false)
    end)
    return true
  end

  if parsed.mode ~= 'sessions' then
    append_entry('error', 'Unsupported prune mode')
    return true
  end

  fetch_session_catalog(function(sessions, err)
    if err then
      append_entry('error', 'Failed to list sessions: ' .. err)
      return
    end

    local cutoff = os.time() - math.floor(parsed.older_than_days * 24 * 60 * 60)
    local candidates = {}
    local skipped = {
      live = 0,
      active = 0,
      named = 0,
      untimed = 0,
    }

    for _, item in ipairs(sessions) do
      if item.live then
        skipped.live = skipped.live + 1
      elseif state.session_id and item.sessionId == state.session_id then
        skipped.active = skipped.active + 1
      else
        local timestamp_text = first_non_empty_string(item.modifiedTime, item.startTime, item.createdAt)
        local timestamp_unix = parse_session_timestamp(timestamp_text)
        local named = type(session_names.get(item.sessionId)) == 'string' and session_names.get(item.sessionId) ~= ''
        if named and not parsed.include_named then
          skipped.named = skipped.named + 1
        elseif not timestamp_unix then
          skipped.untimed = skipped.untimed + 1
        elseif timestamp_unix <= cutoff then
          candidates[#candidates + 1] = {
            id = item.sessionId,
            label = session_label(item.sessionId, item.summary),
            timestamp = timestamp_text,
            named = named,
            session = item,
          }
        end
      end
    end

    if parsed.dry_run then
      append_session_prune_report('Session prune preview:', parsed, candidates, skipped, {})
      return
    end
    if vim.tbl_isempty(candidates) then
      append_session_prune_report('Session prune:', parsed, candidates, skipped, {})
      return
    end

    local failures = {}
    local deleted = {}
    local function prune_next(index)
      if index > #candidates then
        append_session_prune_report('Session prune:', parsed, deleted, skipped, failures)
        return
      end

      local candidate = candidates[index]
      session.delete_session_by_id(candidate.id, candidate.session, function(delete_err)
        if delete_err then
          failures[#failures + 1] = {
            label = candidate.label,
            error = delete_err,
          }
        else
          deleted[#deleted + 1] = candidate
        end
        prune_next(index + 1)
      end)
    end

    prune_next(1)
  end)
  return true
end

local function session_delete_command(args)
  args = vim.trim(args or '')
  if args == '' then
    session.delete_session()
    return true
  end

  fetch_session_catalog(function(sessions, err)
    local picked = nil
    if not err then
      picked = find_session_record(sessions, args)
    end
    local session_id = picked and picked.sessionId or args
    session.delete_session_by_id(session_id, picked, function(delete_err)
      if delete_err then
        local message = 'Failed to delete session ' .. utils.format_session_id(session_id) .. ': ' .. delete_err
        append_entry('error', message)
        notify(message, vim.log.levels.ERROR)
      end
    end)
  end)
  return true
end

local function session_command(args)
  local action, rest = vim.trim(args or ''):match('^(%S+)%s*(.*)$')
  action = action and action:lower() or ''
  rest = rest or ''

  if action == '' then
    session.switch_session()
    return true
  end
  if action == 'new' then
    session.new_session()
    return true
  end
  if action == 'clear' then
    session.clear_and_new_session()
    return true
  end
  if action == 'info' then
    return session_info_command(rest)
  end
  if action == 'checkpoints' then
    return session_checkpoints_command(rest)
  end
  if action == 'files' then
    return session_files_command(rest)
  end
  if action == 'plan' then
    return plan_mode_command(rest)
  end
  if action == 'rename' then
    return rename_session(rest)
  end
  if action == 'cleanup' then
    return session_cleanup_command(rest)
  end
  if action == 'prune' then
    return session_prune_command(rest)
  end
  if action == 'delete' then
    return session_delete_command(rest)
  end
  session.switch_to_session_id(vim.trim(args or ''))
  return true
end

local function set_input_mode(mode)
  local next_mode = vim.trim(mode or ''):lower()
  if next_mode == '' then
    notify('Mode is required', vim.log.levels.WARN)
    return
  end
  if not mode_permission[next_mode] then
    notify('Unsupported mode: ' .. next_mode, vim.log.levels.WARN)
    return
  end

  state.input_mode = next_mode
  require('copilot_agent')._set_agent_mode(next_mode)

  local had_manual = state.permission_mode_manual
  state.permission_mode_manual = false
  local natural_perm = mode_permission[next_mode]
  if natural_perm and not had_manual and natural_perm ~= state.permission_mode then
    state.permission_mode = natural_perm
    if state.session_id then
      request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = natural_perm }, function(_, err)
        if err then
          notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
        end
      end)
    end
  end

  refresh_statuslines()
  append_entry('system', 'Mode: ' .. next_mode)
end

plan_mode_command = function(args)
  set_input_mode('plan')
  args = vim.trim(args or '')
  if args ~= '' then
    state.prompt_prefill = args
    require('copilot_agent').open_chat({ activate_input_on_session_ready = false })
    require('copilot_agent')._open_input_window()
  end
  return true
end

local function allow_all_command()
  local next_mode = 'approve-all'
  state.permission_mode = next_mode
  state.permission_mode_manual = true
  if state.session_id then
    request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = next_mode }, function(_, err)
      if err then
        append_entry('error', 'Failed to set permission mode: ' .. tostring(err))
      end
    end)
  end
  refresh_statuslines()
  append_entry('system', 'Permission mode: ' .. next_mode)
  return true
end

local function latest_usage_snapshot()
  if type(state.last_assistant_usage) == 'table' then
    return state.last_assistant_usage
  end
  if type(state.last_assistant_usage_snapshot) == 'table' then
    return state.last_assistant_usage_snapshot
  end
  return nil
end

local function format_usage_snapshot_percentage(value)
  local rem_num = tonumber(value)
  if rem_num == nil then
    return nil
  end
  if rem_num >= 0 and rem_num <= 1 then
    rem_num = rem_num * 100
  end
  return string.format('%d%%', math.floor(rem_num + 0.5))
end

local function append_usage_snapshot_lines(lines, usage)
  if type(usage) ~= 'table' then
    return false
  end

  local primary = type(usage.primary_quota) == 'table' and usage.primary_quota or (type(usage.quotas) == 'table' and usage.quotas[1])
  if primary then
    local label = tostring(primary.display_name or primary.id or '<quota>')
    local used = tonumber(primary.used_requests) or tonumber(primary.used) or nil
    local total = tonumber(primary.entitlement_requests) or tonumber(primary.entitlement) or nil
    local rem_str = format_usage_snapshot_percentage(primary.remaining_percentage)
    local quota_line = '  Quota: ' .. label
    if total and total > 0 then
      quota_line = quota_line .. string.format(' %d/%d', (used or 0), total)
    elseif used and used > 0 then
      quota_line = quota_line .. ' ' .. tostring(used)
    end
    if rem_str then
      quota_line = quota_line .. ' (' .. rem_str .. ')'
    end
    lines[#lines + 1] = quota_line
  end

  if usage.model or usage.input_tokens or usage.output_tokens or usage.cost or usage.duration_ms then
    local metrics = {
      'model=' .. tostring(usage.model or '<unknown>'),
      'cost=' .. tostring(usage.cost or '<unknown>'),
      'input=' .. tostring(usage.input_tokens or '<unknown>'),
      'output=' .. tostring(usage.output_tokens or '<unknown>'),
    }
    if usage.reasoning_tokens ~= nil then
      metrics[#metrics + 1] = 'reasoning=' .. tostring(usage.reasoning_tokens)
    end
    if usage.cache_read_tokens ~= nil then
      metrics[#metrics + 1] = 'cache_read=' .. tostring(usage.cache_read_tokens)
    end
    if usage.cache_write_tokens ~= nil then
      metrics[#metrics + 1] = 'cache_write=' .. tostring(usage.cache_write_tokens)
    end
    if usage.duration_ms ~= nil then
      metrics[#metrics + 1] = 'duration=' .. tostring(usage.duration_ms) .. 'ms'
    end
    lines[#lines + 1] = '  Last usage: ' .. table.concat(metrics, ' ')
  end

  return true
end

local function format_context_percentage(tokens, total)
  local token_num = tonumber(tokens)
  local total_num = tonumber(total)
  if not token_num or not total_num or total_num <= 0 then
    return nil
  end
  return math.floor((token_num / total_num) * 100 + 0.5)
end

local function append_context_breakdown_lines(lines, context_window)
  if type(context_window) ~= 'table' then
    return false
  end

  local current_tokens = tonumber(context_window.currentTokens)
  local token_limit = tonumber(context_window.tokenLimit)
  if not current_tokens or not token_limit or token_limit <= 0 then
    return false
  end

  local current_percent = format_context_percentage(current_tokens, token_limit) or 0
  lines[#lines + 1] = string.format('  Context window: %d / %d tokens (%d%%)', current_tokens, token_limit, current_percent)

  local categories = {
    { label = 'System/Tools', tokens = tonumber(context_window.systemToolsTokens), extra = nil },
    { label = 'Messages', tokens = tonumber(context_window.conversationTokens), extra = tonumber(context_window.messagesLength) },
    { label = 'Free space', tokens = tonumber(context_window.freeTokens), extra = nil },
    { label = 'Buffer', tokens = tonumber(context_window.bufferTokens), extra = nil },
  }
  for _, category in ipairs(categories) do
    if category.tokens then
      local percent = format_context_percentage(category.tokens, token_limit) or 0
      local line = string.format('  %s: %d tokens (%d%%)', category.label, category.tokens, percent)
      if category.label == 'Messages' and category.extra then
        line = line .. string.format(' across %d messages', category.extra)
      end
      lines[#lines + 1] = line
    end
  end

  return true
end

local function context_command()
  session.with_session(function(session_id)
    request('GET', string.format('/sessions/%s/context', session_id), nil, function(response, err)
      if err then
        append_entry('error', 'Failed to fetch context usage: ' .. tostring(err))
        return
      end

      local lines = { 'Context usage snapshot:' }
      local has_context = append_context_breakdown_lines(lines, response and response.contextWindow)
      local has_usage = append_usage_snapshot_lines(lines, latest_usage_snapshot())
      if not has_context and not has_usage then
        notify('Context window usage is not available yet for this session', vim.log.levels.INFO)
        return
      end

      append_entry('system', table.concat(lines, '\n'))
    end)
  end)
  return true
end

local function usage_command()
  local lines = {
    'Session usage snapshot:',
    '  Session: ' .. tostring(state.session_id or '<none>'),
    '  Model: ' .. tostring(state.current_model or state.config.session.model or '<default>'),
    '  Mode: ' .. tostring(state.input_mode or 'agent'),
    '  Permission: ' .. tostring(state.permission_mode or 'interactive'),
    string.format(
      '  Config discovery: %d instructions, %d agents, %d skills, %d MCP servers',
      tonumber(state.instruction_count) or 0,
      tonumber(state.agent_count) or 0,
      tonumber(state.skill_count) or 0,
      tonumber(state.mcp_count) or 0
    ),
  }
  if state.context_tokens and state.context_limit and state.context_limit > 0 then
    lines[#lines + 1] = string.format('  Context window: %d / %d tokens', state.context_tokens, state.context_limit)
  end

  if not append_usage_snapshot_lines(lines, latest_usage_snapshot()) then
    lines[#lines + 1] = '  Last usage: unavailable'
  end

  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function add_directory(args)
  local resolved = resolve_path_arg(args)
  if not resolved then
    vim.ui.input({
      prompt = 'Directory to allow: ',
      default = working_directory(),
      completion = 'dir',
    }, function(input)
      local picked = resolve_path_arg(input)
      if not picked then
        return
      end
      if vim.fn.isdirectory(picked) ~= 1 then
        append_entry('error', 'Directory does not exist: ' .. tostring(input))
        return
      end
      approvals.add_directory(picked)
      append_entry('system', 'Allowed directory: ' .. vim.fn.fnamemodify(picked, ':~'))
    end)
    return true
  end

  if vim.fn.isdirectory(resolved) ~= 1 then
    append_entry('error', 'Directory does not exist: ' .. args)
    return true
  end
  approvals.add_directory(resolved)
  append_entry('system', 'Allowed directory: ' .. vim.fn.fnamemodify(resolved, ':~'))
  return true
end

local function list_directories_command()
  local directories = approvals.list_directories()
  if vim.tbl_isempty(directories) then
    append_entry('system', 'No allowed directories in this session')
    return true
  end

  local lines = { 'Allowed directories:' }
  for _, directory in ipairs(directories) do
    lines[#lines + 1] = '  - ' .. vim.fn.fnamemodify(directory, ':~')
  end
  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function reset_allowed_tools_command()
  local cleared = approvals.reset_tools()
  append_entry('system', cleared > 0 and ('Cleared ' .. cleared .. ' allowed tools for this session') or 'No allowed tools were set')
  return true
end

local function list_tools_command()
  local tools = approvals.list_tools()
  if vim.tbl_isempty(tools) then
    append_entry('system', 'No approved tools in this session\nNote: the backend does not expose the full available-tools inventory to the plugin')
    return true
  end

  table.sort(tools)
  local lines = {
    'Approved tools for this session:',
  }
  for _, tool in ipairs(tools) do
    lines[#lines + 1] = '  - ' .. tool
  end
  lines[#lines + 1] = 'Note: the backend does not expose the full available-tools inventory to the plugin'
  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function cwd_command(args)
  args = vim.trim(args or '')
  if args == '' then
    append_entry('system', 'Working directory: ' .. working_directory())
    return true
  end

  local resolved = vim.fn.fnamemodify(args, ':p')
  if vim.fn.isdirectory(resolved) ~= 1 then
    append_entry('error', 'Directory does not exist: ' .. args)
    return true
  end

  state.config.session.working_directory = resolved
  append_entry('system', 'Working directory set to ' .. vim.fn.fnamemodify(resolved, ':~'))
  if state.session_id then
    append_entry('system', 'Use /new or /resume to attach a session in the new directory')
  end
  return true
end

local function diff_command(args)
  local empty_tree_hash = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

  local function normalize_checkpoint_id(checkpoint_id)
    checkpoint_id = vim.trim(checkpoint_id or '')
    if checkpoint_id == '' then
      return nil
    end
    local number = checkpoint_id:match('^[vV](%d+)$')
    if number then
      return string.format('v%03d', tonumber(number))
    end
    return checkpoint_id
  end

  local function checkpoint_index_by_id(checkpoint_items, checkpoint_id)
    local normalized = normalize_checkpoint_id(checkpoint_id)
    if not normalized then
      return nil, nil
    end
    for idx, item in ipairs(checkpoint_items or {}) do
      if type(item.id) == 'string' and item.id == normalized then
        return idx, item
      end
    end
    return nil, nil
  end

  local function parse_diff_checkpoint_args(raw_args)
    raw_args = vim.trim(raw_args or '')
    if raw_args == '' then
      return { mode = 'single-latest' }, nil
    end

    local from_arg, to_arg = raw_args:match('^(%S+)%.%.(%S+)$')
    if from_arg and to_arg then
      return { mode = 'range', from_arg = from_arg, to_arg = to_arg }, nil
    end

    local tokens = {}
    for token in raw_args:gmatch('%S+') do
      tokens[#tokens + 1] = token
    end
    if #tokens == 1 then
      return { mode = 'single', checkpoint_arg = tokens[1] }, nil
    end
    if #tokens == 2 then
      return { mode = 'range', from_arg = tokens[1], to_arg = tokens[2] }, nil
    end
    return nil, 'Usage: /diff [checkpoint] | /diff <from> <to> | /diff <from>..<to> [--difftool [name]]'
  end

  local function parse_diff_args(raw_args)
    local function looks_like_checkpoint_selector(value)
      if type(value) ~= 'string' then
        return false
      end
      return value:match('^[vV]%d+$') ~= nil or value:match('^[vV]%d+%.%.[vV]%d+$') ~= nil
    end

    local tokens = {}
    for token in vim.trim(raw_args or ''):gmatch('%S+') do
      tokens[#tokens + 1] = token
    end

    local checkpoint_tokens = {}
    local difftool_requested = false
    local difftool_name
    local idx = 1
    while idx <= #tokens do
      local token = tokens[idx]
      local inline_difftool = token:match('^%-%-difftool=(.+)$') or token:match('^%-difftool=(.+)$')
      if inline_difftool then
        if difftool_requested then
          return nil, 'Only one difftool option is allowed'
        end
        difftool_requested = true
        difftool_name = inline_difftool
      elseif token == '--difftool' or token == '-difftool' then
        if difftool_requested then
          return nil, 'Only one difftool option is allowed'
        end
        difftool_requested = true
        local next_token = tokens[idx + 1]
        if next_token and not next_token:match('^%-') and not looks_like_checkpoint_selector(next_token) then
          difftool_name = next_token
          idx = idx + 1
        end
      else
        checkpoint_tokens[#checkpoint_tokens + 1] = token
      end
      idx = idx + 1
    end

    local checkpoint_args, checkpoint_err = parse_diff_checkpoint_args(table.concat(checkpoint_tokens, ' '))
    if checkpoint_err then
      return nil, checkpoint_err
    end

    if type(difftool_name) == 'string' then
      difftool_name = vim.trim(difftool_name)
      if difftool_name == '' then
        difftool_name = nil
      end
    end

    return {
      checkpoint = checkpoint_args,
      difftool = {
        requested = difftool_requested,
        name = difftool_name,
      },
    }, nil
  end

  local function resolve_diff_checkpoints(checkpoint_items, parsed_checkpoint_args)
    if parsed_checkpoint_args.mode == 'single-latest' then
      if #checkpoint_items < 1 then
        return nil, nil, nil, 'Need at least one checkpoint to diff'
      end
      return 'single', checkpoint_items[#checkpoint_items], nil, nil
    end

    if parsed_checkpoint_args.mode == 'single' then
      local _, checkpoint_item = checkpoint_index_by_id(checkpoint_items, parsed_checkpoint_args.checkpoint_arg)
      if not checkpoint_item then
        return nil, nil, nil, 'Checkpoint not found: ' .. parsed_checkpoint_args.checkpoint_arg
      end
      return 'single', checkpoint_item, nil, nil
    end

    if #checkpoint_items < 2 then
      return nil, nil, nil, 'Need at least two checkpoints to diff'
    end

    local to_idx, to_item = checkpoint_index_by_id(checkpoint_items, parsed_checkpoint_args.to_arg)
    if not to_item then
      return nil, nil, nil, 'Checkpoint not found: ' .. parsed_checkpoint_args.to_arg
    end

    if not parsed_checkpoint_args.from_arg then
      if to_idx <= 1 then
        return nil, nil, nil, 'Checkpoint ' .. to_item.id .. ' has no earlier checkpoint to compare'
      end
      return 'range', checkpoint_items[to_idx - 1], to_item, nil
    end

    local from_idx, from_item = checkpoint_index_by_id(checkpoint_items, parsed_checkpoint_args.from_arg)
    if not from_item then
      return nil, nil, nil, 'Checkpoint not found: ' .. parsed_checkpoint_args.from_arg
    end
    if from_idx == to_idx then
      return nil, nil, nil, 'Choose two different checkpoints'
    end
    if from_idx > to_idx then
      from_item, to_item = to_item, from_item
    end
    return 'range', from_item, to_item, nil
  end

  local function open_external_difftool(tool_name, checkpoint_repo_dir, from_commit, to_commit)
    local selected_tool = vim.trim(tool_name or '')
    if selected_tool == '' then
      return false, 'Diff tool name is required'
    end

    local range_spec = from_commit .. '..' .. to_commit
    local lower_tool = selected_tool:lower()
    local candidates
    if lower_tool == 'diffview' or lower_tool == 'diffviewopen' then
      candidates = {
        {
          command = 'DiffviewOpen ' .. range_spec,
          preserve_cwd = true,
        },
      }
    elseif lower_tool == 'fugitive' then
      candidates = {
        {
          command = string.format('Git diff %s %s -- .', from_commit, to_commit),
          preserve_cwd = false,
        },
      }
    else
      candidates = {
        {
          command = string.format('%s %s %s', selected_tool, from_commit, to_commit),
          preserve_cwd = false,
        },
        {
          command = string.format('%s %s', selected_tool, range_spec),
          preserve_cwd = false,
        },
        {
          command = string.format('%s %s', selected_tool, from_commit),
          preserve_cwd = false,
        },
      }
    end

    local previous_cwd = vim.fn.getcwd()
    local attempt_errors = {}
    for _, candidate in ipairs(candidates) do
      local ok_lcd, lcd_err = pcall(vim.cmd, 'lcd ' .. vim.fn.fnameescape(checkpoint_repo_dir))
      if not ok_lcd then
        return false, tostring(lcd_err)
      end

      log(string.format('/diff difftool command repo=%s cmd=%s', checkpoint_repo_dir, candidate.command), vim.log.levels.DEBUG)
      local ok_cmd, cmd_err = pcall(vim.cmd, candidate.command)
      if ok_cmd then
        if not candidate.preserve_cwd then
          local ok_restore, restore_err = pcall(vim.cmd, 'lcd ' .. vim.fn.fnameescape(previous_cwd))
          if not ok_restore then
            return false, 'Failed to restore working directory: ' .. tostring(restore_err)
          end
        end
        return true, nil
      end

      local err_text = tostring(cmd_err)
      attempt_errors[#attempt_errors + 1] = string.format('%s => %s', candidate.command, err_text)
      log(string.format('/diff difftool failed repo=%s cmd=%s err=%s', checkpoint_repo_dir, candidate.command, err_text), vim.log.levels.DEBUG)
      pcall(vim.cmd, 'lcd ' .. vim.fn.fnameescape(previous_cwd))
    end

    return false, attempt_errors[#attempt_errors] or ('Failed to run difftool ' .. selected_tool)
  end

  local function checkpoint_file_lines(checkpoint_git_dir, workspace, commit, path)
    local show_cmd = {
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoint_git_dir,
      '--work-tree=' .. workspace,
      'show',
      string.format('%s:%s', commit, path),
    }
    log(string.format('/diff git command cwd=%s cmd=%s', workspace, shell_command_text(show_cmd)), vim.log.levels.DEBUG)
    local output, show_err = run_command(show_cmd, workspace)
    if show_err then
      local lowered = string.lower(show_err)
      if lowered:find('does not exist in', 1, true) or lowered:find('exists on disk, but not in', 1, true) then
        return {}
      end
      return nil, show_err
    end
    if output == '' then
      return {}
    end
    return split_lines(output)
  end

  local function checkpoint_file_exists(checkpoint_git_dir, workspace, commit, path)
    local exists_cmd = {
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoint_git_dir,
      '--work-tree=' .. workspace,
      'cat-file',
      '-e',
      string.format('%s:%s', commit, path),
    }
    log(string.format('/diff git command cwd=%s cmd=%s', workspace, shell_command_text(exists_cmd)), vim.log.levels.DEBUG)
    local _, exists_err = run_command(exists_cmd, workspace)
    return exists_err == nil
  end

  local function build_changed_files(checkpoint_git_dir, workspace, from_commit, to_commit)
    local changed_cmd = {
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoint_git_dir,
      '--work-tree=' .. workspace,
      'diff',
      '--name-only',
      from_commit,
      to_commit,
      '--',
      '.',
    }
    log(string.format('/diff git command cwd=%s cmd=%s', workspace, shell_command_text(changed_cmd)), vim.log.levels.DEBUG)
    local changed_output, changed_err = run_command(changed_cmd, workspace)
    if changed_err then
      return nil, changed_err
    end
    if changed_output == '' then
      return {}, nil
    end
    return vim.tbl_filter(function(path)
      return type(path) == 'string' and path ~= ''
    end, split_lines(changed_output)), nil
  end

  local function create_diff_worktree(checkpoint_repo_dir, commit)
    local worktree_root = vim.fn.stdpath('state') .. '/copilot-agent/difftool-worktrees'
    vim.fn.mkdir(worktree_root, 'p')
    local suffix = tostring(now_ms()) .. '-' .. tostring(math.random(1000, 9999))
    local worktree_dir = worktree_root .. '/' .. suffix
    local add_cmd = {
      'git',
      '-C',
      checkpoint_repo_dir,
      'worktree',
      'add',
      '--detach',
      '--force',
      worktree_dir,
      commit,
    }
    log(string.format('/diff git command cwd=%s cmd=%s', checkpoint_repo_dir, shell_command_text(add_cmd)), vim.log.levels.DEBUG)
    local _, add_err = run_command(add_cmd, checkpoint_repo_dir)
    if add_err then
      return nil, add_err
    end
    return worktree_dir, nil
  end

  local function remove_diff_worktree(checkpoint_repo_dir, worktree_dir)
    if type(worktree_dir) ~= 'string' or worktree_dir == '' then
      return
    end
    local remove_cmd = {
      'git',
      '-C',
      checkpoint_repo_dir,
      'worktree',
      'remove',
      '--force',
      worktree_dir,
    }
    log(string.format('/diff git command cwd=%s cmd=%s', checkpoint_repo_dir, shell_command_text(remove_cmd)), vim.log.levels.DEBUG)
    run_command(remove_cmd, checkpoint_repo_dir)
    pcall(vim.fn.delete, worktree_dir, 'rf')
  end

  local function open_codediff_tool(tool_name, checkpoint_repo_dir, checkpoint_git_dir, workspace, from_commit, to_commit, summary_label)
    local changed_files, changed_err = build_changed_files(checkpoint_git_dir, workspace, from_commit, to_commit)
    if changed_err then
      return false, changed_err
    end
    if vim.tbl_isempty(changed_files) then
      return false, 'No changed files available for CodeDiff'
    end

    vim.ui.select(changed_files, {
      prompt = summary_label .. ' (' .. tool_name .. ' file)',
    }, function(path)
      if not path then
        return
      end

      local anchor_commit = to_commit
      local compare_commit = from_commit
      if not checkpoint_file_exists(checkpoint_git_dir, workspace, anchor_commit, path) and checkpoint_file_exists(checkpoint_git_dir, workspace, from_commit, path) then
        anchor_commit = from_commit
        compare_commit = to_commit
      end

      local worktree_dir, worktree_err = create_diff_worktree(checkpoint_repo_dir, anchor_commit)
      if worktree_err then
        append_entry('error', 'Diff unavailable: ' .. worktree_err)
        return
      end

      local file_path = worktree_dir .. '/' .. path
      if vim.fn.filereadable(file_path) ~= 1 then
        remove_diff_worktree(checkpoint_repo_dir, worktree_dir)
        append_entry('error', 'Diff unavailable: file not found in checkpoint worktree: ' .. path)
        return
      end

      log(string.format('/diff difftool open file tool=%s file=%s anchor=%s compare=%s', tool_name, file_path, anchor_commit, compare_commit), vim.log.levels.DEBUG)
      vim.cmd('tabnew ' .. vim.fn.fnameescape(file_path))
      local bufnr = vim.api.nvim_get_current_buf()
      local group = vim.api.nvim_create_augroup('CopilotAgentDiffToolWorktree' .. tostring(bufnr), { clear = true })
      local cleaned = false
      local function cleanup()
        if cleaned then
          return
        end
        cleaned = true
        remove_diff_worktree(checkpoint_repo_dir, worktree_dir)
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end
      vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'CodeDiffClose',
        callback = cleanup,
      })
      vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = bufnr,
        callback = cleanup,
      })

      local code_diff_command = string.format('%s file %s', tool_name, compare_commit)
      log(string.format('/diff difftool command repo=%s cmd=%s', worktree_dir, code_diff_command), vim.log.levels.DEBUG)
      local ok_cmd, cmd_err = pcall(vim.cmd, code_diff_command)
      if not ok_cmd then
        cleanup()
        append_entry('error', 'Diff unavailable: ' .. tostring(cmd_err))
        return
      end
      append_entry('system', string.format('Opened %s in %s', summary_label, tool_name))
    end)
    return true, nil
  end

  local function configure_native_diff_buffer(bufnr, name, lines)
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'wipe'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
  end

  local function open_native_diff(path, from_commit_label, to_commit_label, from_lines, to_lines)
    vim.cmd('tabnew')
    local from_win = vim.api.nvim_get_current_win()
    local from_buf = vim.api.nvim_get_current_buf()
    configure_native_diff_buffer(from_buf, string.format('%s (%s)', path, from_commit_label), from_lines)
    window.disable_folds(from_win)
    vim.cmd('diffthis')

    vim.cmd('vnew')
    local to_win = vim.api.nvim_get_current_win()
    local to_buf = vim.api.nvim_get_current_buf()
    configure_native_diff_buffer(to_buf, string.format('%s (%s)', path, to_commit_label), to_lines)
    window.disable_folds(to_win)
    vim.cmd('diffthis')
  end

  local parsed_args, parse_err = parse_diff_args(args)
  if parse_err then
    append_entry('error', 'Diff unavailable: ' .. parse_err)
    return true
  end

  if not state.session_id then
    append_entry('error', 'Diff unavailable: no active session')
    return true
  end

  local checkpoint_items = vim.tbl_filter(function(item)
    return type(item) == 'table' and type(item.id) == 'string' and item.id ~= '' and type(item.commit) == 'string' and item.commit ~= ''
  end, checkpoints.list(state.session_id))
  local diff_mode, from_checkpoint, to_checkpoint, range_err = resolve_diff_checkpoints(checkpoint_items, parsed_args.checkpoint)
  if range_err then
    append_entry('error', 'Diff unavailable: ' .. range_err)
    return true
  end

  local checkpoint_repo_dir = checkpoints._session_dir(state.session_id) .. '/repo'
  local checkpoint_git_dir = checkpoint_repo_dir .. '/.git'
  local workspace = state.session_working_directory or working_directory()
  if type(workspace) ~= 'string' or workspace == '' then
    append_entry('error', 'Diff unavailable: working directory is not set')
    return true
  end

  local from_commit = from_checkpoint.commit
  local to_commit = (to_checkpoint and to_checkpoint.commit) or from_checkpoint.commit
  if diff_mode == 'single' then
    local parent_cmd = {
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoint_git_dir,
      '--work-tree=' .. workspace,
      'show',
      '-s',
      '--format=%P',
      from_checkpoint.commit,
    }
    log(string.format('/diff git command cwd=%s cmd=%s', workspace, shell_command_text(parent_cmd)), vim.log.levels.DEBUG)
    local parent_output, parent_err = run_command(parent_cmd, workspace)
    if parent_err then
      append_entry('error', 'Diff failed: ' .. parent_err)
      return true
    end
    local parent_commit = vim.trim(parent_output or ''):match('^(%S+)')
    from_commit = parent_commit or empty_tree_hash
    to_commit = from_checkpoint.commit
  end

  local summary_label
  if diff_mode == 'single' then
    summary_label = string.format('Checkpoint diff %s', from_checkpoint.id)
  else
    summary_label = string.format('Checkpoint diff %s -> %s', from_checkpoint.id, to_checkpoint.id)
  end

  if parsed_args.difftool.requested then
    if parsed_args.difftool.name then
      local named_tool = vim.trim(parsed_args.difftool.name)
      if named_tool:lower() == 'codediff' then
        log(string.format('/diff launch mode=%s from=%s to=%s difftool=%s', diff_mode, from_commit, to_commit, named_tool), vim.log.levels.DEBUG)
        local ok_tool, tool_err = open_codediff_tool(named_tool, checkpoint_repo_dir, checkpoint_git_dir, workspace, from_commit, to_commit, summary_label)
        if not ok_tool then
          append_entry('error', 'Diff unavailable: ' .. tool_err)
        end
        return true
      end

      log(string.format('/diff launch mode=%s from=%s to=%s difftool=%s', diff_mode, from_commit, to_commit, parsed_args.difftool.name), vim.log.levels.DEBUG)
      local ok_tool, tool_err = open_external_difftool(parsed_args.difftool.name, checkpoint_repo_dir, from_commit, to_commit)
      if not ok_tool then
        append_entry('error', 'Diff unavailable: ' .. tool_err)
        return true
      end
      append_entry('system', string.format('Opened %s in %s', summary_label, parsed_args.difftool.name))
      return true
    end

    local changed_files, changed_err = build_changed_files(checkpoint_git_dir, workspace, from_commit, to_commit)
    if changed_err then
      append_entry('error', 'Diff failed: ' .. changed_err)
      return true
    end
    if vim.tbl_isempty(changed_files) then
      if diff_mode == 'single' then
        append_entry('system', string.format('No differences in checkpoint %s', from_checkpoint.id))
        return true
      end
      append_entry('system', string.format('No differences between checkpoints %s and %s', from_checkpoint.id, to_checkpoint.id))
      return true
    end

    vim.ui.select(changed_files, {
      prompt = summary_label .. ' (native diff file)',
    }, function(path)
      if not path then
        return
      end

      log(string.format('/diff native vim diff file=%s from=%s to=%s', path, from_commit, to_commit), vim.log.levels.DEBUG)
      local from_lines, from_err = checkpoint_file_lines(checkpoint_git_dir, workspace, from_commit, path)
      if from_err then
        append_entry('error', 'Diff failed: ' .. from_err)
        return
      end

      local to_lines, to_err = checkpoint_file_lines(checkpoint_git_dir, workspace, to_commit, path)
      if to_err then
        append_entry('error', 'Diff failed: ' .. to_err)
        return
      end

      local from_label = diff_mode == 'single' and (from_commit == empty_tree_hash and 'empty' or 'parent') or from_checkpoint.id
      local to_label = to_checkpoint and to_checkpoint.id or from_checkpoint.id
      open_native_diff(path, from_label, to_label, from_lines, to_lines)
      append_entry('system', string.format('Opened %s in native vim diff', summary_label))
    end)
    return true
  end

  local stat_cmd = {
    'git',
    '--no-pager',
    '--git-dir=' .. checkpoint_git_dir,
    '--work-tree=' .. workspace,
    'diff',
    '--stat',
    from_commit,
    to_commit,
    '--',
    '.',
  }
  log(string.format('/diff git command cwd=%s cmd=%s', workspace, shell_command_text(stat_cmd)), vim.log.levels.DEBUG)
  local output, diff_err = run_command(stat_cmd, workspace)
  if diff_err then
    append_entry('error', 'Diff failed: ' .. diff_err)
    return true
  end
  if output == '' then
    if diff_mode == 'single' then
      append_entry('system', string.format('No differences in checkpoint %s', from_checkpoint.id))
      return true
    end
    append_entry('system', string.format('No differences between checkpoints %s and %s', from_checkpoint.id, to_checkpoint.id))
    return true
  end
  append_entry('system', string.format('%s:\n%s', summary_label, output))
  return true
end

local function env_command()
  local service_command = service.service_command()
  local command_text = type(service_command) == 'table' and table.concat(service_command, ' ') or tostring(service_command)
  local lines = {
    'Environment snapshot:',
    '  Working directory: ' .. tostring(working_directory()),
    '  Service cwd: ' .. tostring(service.service_cwd()),
    '  Service command: ' .. command_text,
    '  Base URL: ' .. tostring(state.config.base_url),
    '  Session: ' .. tostring(state.session_id or '<none>'),
    '  Model: ' .. tostring(state.current_model or state.config.session.model or '<default>'),
    '  Mode: ' .. tostring(state.input_mode or 'agent'),
    '  Permission: ' .. tostring(state.permission_mode or 'interactive'),
    '  Auto-start service: ' .. tostring(state.config.service.auto_start == true),
  }
  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function agent_command(args, opts)
  local items = discovery.agent_items()
  if vim.tbl_isempty(items) then
    notify('No custom agents found in .github/agents', vim.log.levels.INFO)
    return true
  end

  local function apply_agent(item)
    state.config.session.agent = item and item.name or nil
    if item then
      if state.session_id then
        dispatch_prompt('/agent ' .. item.name, opts)
        return
      end
      append_entry('system', 'Agent for next conversation: ' .. item.name)
      return
    end

    if state.session_id then
      append_entry('system', 'Reset to the default agent for future conversations (active session unchanged)')
      return
    end
    append_entry('system', 'Reset to the default agent for future conversations')
  end

  args = vim.trim(args or '')
  if args == 'default' or args == 'clear' then
    apply_agent(nil)
    return true
  end
  if args ~= '' then
    local item = matching_item(items, args)
    if not item then
      append_entry('error', 'Unknown agent: ' .. args)
      return true
    end
    apply_agent(item)
    return true
  end

  local choices = { { name = 'Default agent', path = '' } }
  vim.list_extend(choices, items)
  vim.ui.select(choices, {
    prompt = state.session_id and 'Select agent for this conversation' or 'Select agent for next conversation',
    format_item = function(item)
      if item.path == '' then
        return item.name
      end
      return string.format('%s  [%s]', item.name, vim.fn.fnamemodify(item.path, ':~:.'))
    end,
  }, function(choice)
    if choice then
      apply_agent(choice.path == '' and nil or choice)
    end
  end)
  return true
end

local function open_discovered_item(kind, items, args)
  if vim.tbl_isempty(items) then
    notify('No ' .. kind .. ' entries found', vim.log.levels.INFO)
    return true
  end

  args = vim.trim(args or '')
  if args ~= '' then
    local item = matching_item(items, args)
    if not item then
      append_entry('error', 'Unknown ' .. kind .. ': ' .. args)
      return true
    end
    open_path(item.path)
    return true
  end

  vim.ui.select(items, {
    prompt = 'Open ' .. kind,
    format_item = function(item)
      return string.format('%s  [%s]', item.name, vim.fn.fnamemodify(item.path, ':~:.'))
    end,
  }, function(choice)
    if choice then
      open_path(choice.path)
    end
  end)
  return true
end

local function skills_command(args)
  return open_discovered_item('skill', discovery.skill_items(), args)
end

local function instructions_command(args)
  return open_discovered_item('instruction', discovery.instruction_items(), args)
end

local function mcp_config_paths()
  local wd = working_directory()
  return {
    root = wd .. '/.mcp.json',
    vscode = wd .. '/.vscode/mcp.json',
    global = vim.fn.expand('~/.copilot/mcp-config.json'),
  }
end

local function encode_json_pretty(value)
  if vim.json and type(vim.json.encode) == 'function' then
    return vim.json.encode(value, { indent = '  ' })
  end
  return http.encode_json(value)
end

local function read_mcp_config(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, nil
  end

  local decoded, decode_err = http.decode_json(table.concat(vim.fn.readfile(path), '\n'), { log = false })
  if type(decoded) ~= 'table' then
    return nil, 'Failed to parse ' .. vim.fn.fnamemodify(path, ':~:.') .. ': ' .. tostring(decode_err)
  end
  return decoded, nil
end

local function write_mcp_config(path, payload)
  local parent = vim.fn.fnamemodify(path, ':h')
  if parent ~= '' then
    vim.fn.mkdir(parent, 'p')
  end

  local encoded = encode_json_pretty(payload)
  local ok, err = pcall(vim.fn.writefile, vim.split(encoded, '\n', { plain = true }), path)
  if not ok then
    return nil, err
  end
  return true
end

local function load_mcp_sources()
  local sources = {}
  local paths = mcp_config_paths()
  for _, path in ipairs({ paths.root, paths.vscode, paths.global }) do
    local payload, err = read_mcp_config(path)
    if err then
      return nil, err
    end
    if payload then
      sources[#sources + 1] = { path = path, payload = payload }
    end
  end
  return sources, nil
end

local function collect_mcp_entries(sources)
  local entries = {}
  for _, source in ipairs(sources or {}) do
    for _, container in ipairs({ 'mcpServers', 'servers' }) do
      local servers = source.payload[container]
      if type(servers) == 'table' then
        if is_list and is_list(servers) then
          for index, entry in ipairs(servers) do
            local name = nil
            local disabled = false
            if type(entry) == 'string' then
              name = entry
            elseif type(entry) == 'table' then
              name = entry.name or entry.id
              disabled = entry.disabled == true
            end
            if type(name) == 'string' and name ~= '' then
              entries[#entries + 1] = {
                name = name,
                path = source.path,
                container = container,
                list = true,
                index = index,
                disabled = disabled,
              }
            end
          end
        else
          for name, entry in pairs(servers) do
            if type(name) == 'string' and name ~= '' then
              entries[#entries + 1] = {
                name = name,
                path = source.path,
                container = container,
                list = false,
                key = name,
                disabled = type(entry) == 'table' and entry.disabled == true,
              }
            end
          end
        end
      end
    end
  end

  table.sort(entries, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    if left.path ~= right.path then
      return left.path < right.path
    end
    if left.container ~= right.container then
      return left.container < right.container
    end
    return (left.index or 0) < (right.index or 0)
  end)
  return entries
end

local function find_mcp_entries(entries, target_name)
  local needle = vim.trim(target_name or '')
  if needle == '' then
    return entries
  end

  needle = needle:lower()
  local matches = {}
  for _, entry in ipairs(entries or {}) do
    if entry.name:lower() == needle then
      matches[#matches + 1] = entry
    end
  end
  return matches
end

local function mcp_entry_label(entry)
  local status = entry.disabled and 'disabled' or 'enabled'
  return string.format('%s (%s)  [%s]', entry.name, status, vim.fn.fnamemodify(entry.path, ':~:.'))
end

local function mcp_source_map(sources)
  local map = {}
  for _, source in ipairs(sources or {}) do
    map[source.path] = source
  end
  return map
end

local function ensure_root_mcp_config()
  local path = mcp_config_paths().root
  local payload, err = read_mcp_config(path)
  if err then
    return nil, nil, err
  end
  return path, payload or {}, nil
end

local function mcp_show_command(target_name)
  local sources, source_err = load_mcp_sources()
  if source_err then
    append_entry('error', source_err)
    return true
  end

  local entries = collect_mcp_entries(sources)
  if vim.tbl_isempty(entries) then
    append_entry('system', 'No MCP servers configured in .mcp.json, .vscode/mcp.json, or ~/.copilot/mcp-config.json')
    return true
  end

  local selected = find_mcp_entries(entries, target_name)
  if vim.tbl_isempty(selected) then
    append_entry('error', 'Unknown MCP server: ' .. target_name)
    return true
  end

  local lines = {}
  if vim.trim(target_name or '') == '' then
    lines[#lines + 1] = 'Discovered MCP servers:'
  else
    lines[#lines + 1] = 'MCP server "' .. target_name .. '":'
  end

  for _, entry in ipairs(selected) do
    lines[#lines + 1] = '  - ' .. mcp_entry_label(entry)
  end

  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function mcp_edit_command(target_name)
  target_name = vim.trim(target_name or '')

  if target_name == '' then
    local items = discovery.mcp_items()
    if not vim.tbl_isempty(items) then
      return open_discovered_item('MCP config', items, '')
    end

    local path, payload, ensure_err = ensure_root_mcp_config()
    if ensure_err then
      append_entry('error', ensure_err)
      return true
    end

    if type(payload.mcpServers) ~= 'table' or (is_list and is_list(payload.mcpServers)) then
      payload.mcpServers = {}
    end
    if vim.fn.filereadable(path) ~= 1 then
      local ok, write_err = write_mcp_config(path, payload)
      if not ok then
        append_entry('error', 'Failed to write ' .. vim.fn.fnamemodify(path, ':~:.') .. ': ' .. tostring(write_err))
        return true
      end
      append_entry('system', 'Created ' .. vim.fn.fnamemodify(path, ':~:.') .. ' for MCP configuration')
    end
    open_path(path)
    return true
  end

  local sources, source_err = load_mcp_sources()
  if source_err then
    append_entry('error', source_err)
    return true
  end

  local entries = find_mcp_entries(collect_mcp_entries(sources), target_name)
  if vim.tbl_isempty(entries) then
    append_entry('error', 'Unknown MCP server: ' .. target_name)
    return true
  end
  if #entries == 1 then
    open_path(entries[1].path)
    return true
  end

  vim.ui.select(entries, {
    prompt = 'Select MCP config to edit',
    format_item = mcp_entry_label,
  }, function(choice)
    if choice then
      open_path(choice.path)
    end
  end)
  return true
end

local function parse_add_mcp_args(args)
  local name, rest = vim.trim(args or ''):match('^(%S+)%s*(.*)$')
  if not name then
    return nil, nil, {}
  end
  local parts = {}
  if vim.trim(rest or '') ~= '' then
    parts = vim.split(vim.trim(rest), '%s+', { trimempty = true })
  end

  local command = parts[1]
  local command_args = {}
  if #parts > 1 then
    for idx = 2, #parts do
      command_args[#command_args + 1] = parts[idx]
    end
  end
  return name, command, command_args
end

local function mcp_add_command(args)
  local name, command, command_args = parse_add_mcp_args(args)
  if not name then
    append_entry('error', 'Usage: /mcp add <name> [command [arg...]]')
    return true
  end

  local sources, source_err = load_mcp_sources()
  if source_err then
    append_entry('error', source_err)
    return true
  end
  local existing = find_mcp_entries(collect_mcp_entries(sources), name)
  if not vim.tbl_isempty(existing) then
    append_entry('error', 'MCP server "' .. name .. '" already exists')
    return true
  end

  local path, payload, ensure_err = ensure_root_mcp_config()
  if ensure_err then
    append_entry('error', ensure_err)
    return true
  end

  local container
  local list_container = false
  if type(payload.mcpServers) == 'table' and not (is_list and is_list(payload.mcpServers)) then
    container = payload.mcpServers
  elseif type(payload.servers) == 'table' then
    container = payload.servers
    list_container = is_list and is_list(container)
  else
    payload.mcpServers = {}
    container = payload.mcpServers
  end

  if list_container then
    local list_entry = { name = name }
    if command then
      list_entry.command = command
      list_entry.args = command_args
    end
    table.insert(container, list_entry)
  else
    local map_entry = {}
    if command then
      map_entry.command = command
      map_entry.args = command_args
    end
    container[name] = map_entry
  end

  local ok, write_err = write_mcp_config(path, payload)
  if not ok then
    append_entry('error', 'Failed to write ' .. vim.fn.fnamemodify(path, ':~:.') .. ': ' .. tostring(write_err))
    return true
  end

  open_path(path)
  append_entry('system', 'Added MCP server "' .. name .. '" to ' .. vim.fn.fnamemodify(path, ':~:.'))
  return true
end

local function mcp_delete_command(target_name)
  target_name = vim.trim(target_name or '')
  if target_name == '' then
    append_entry('error', 'Usage: /mcp delete <name>')
    return true
  end

  local sources, source_err = load_mcp_sources()
  if source_err then
    append_entry('error', source_err)
    return true
  end

  local entries = find_mcp_entries(collect_mcp_entries(sources), target_name)
  if vim.tbl_isempty(entries) then
    append_entry('error', 'Unknown MCP server: ' .. target_name)
    return true
  end

  local source_map = mcp_source_map(sources)
  local list_removals = {}
  local changed_paths = {}
  for _, entry in ipairs(entries) do
    local source = source_map[entry.path]
    if source then
      local servers = source.payload[entry.container]
      if type(servers) == 'table' then
        if entry.list then
          local group_key = entry.path .. '\0' .. entry.container
          local group = list_removals[group_key]
          if not group then
            group = { source = source, container = entry.container, indices = {} }
            list_removals[group_key] = group
          end
          group.indices[#group.indices + 1] = entry.index
        else
          servers[entry.key] = nil
          changed_paths[entry.path] = true
        end
      end
    end
  end

  for _, removal in pairs(list_removals) do
    local servers = removal.source.payload[removal.container]
    table.sort(removal.indices, function(left, right)
      return left > right
    end)
    for _, index in ipairs(removal.indices) do
      table.remove(servers, index)
    end
    changed_paths[removal.source.path] = true
  end

  for path in pairs(changed_paths) do
    local ok, write_err = write_mcp_config(path, source_map[path].payload)
    if not ok then
      append_entry('error', 'Failed to write ' .. vim.fn.fnamemodify(path, ':~:.') .. ': ' .. tostring(write_err))
      return true
    end
  end

  append_entry('system', string.format('Deleted MCP server "%s" from %d entr%s', target_name, #entries, #entries == 1 and 'y' or 'ies'))
  return true
end

local function mcp_set_disabled(target_name, disabled)
  target_name = vim.trim(target_name or '')
  if target_name == '' then
    append_entry('error', string.format('Usage: /mcp %s <name>', disabled and 'disable' or 'enable'))
    return true
  end

  local sources, source_err = load_mcp_sources()
  if source_err then
    append_entry('error', source_err)
    return true
  end

  local entries = find_mcp_entries(collect_mcp_entries(sources), target_name)
  if vim.tbl_isempty(entries) then
    append_entry('error', 'Unknown MCP server: ' .. target_name)
    return true
  end

  local source_map = mcp_source_map(sources)
  local changed_paths = {}
  for _, entry in ipairs(entries) do
    local source = source_map[entry.path]
    local servers = source and source.payload[entry.container] or nil
    if type(servers) ~= 'table' then
      append_entry('error', 'Invalid MCP config shape in ' .. vim.fn.fnamemodify(entry.path, ':~:.'))
      return true
    end

    if entry.list then
      local current = servers[entry.index]
      if type(current) == 'string' then
        servers[entry.index] = { name = entry.name, disabled = disabled }
      elseif type(current) == 'table' then
        current.disabled = disabled
      else
        append_entry('error', 'Cannot update MCP server "' .. entry.name .. '" in ' .. vim.fn.fnamemodify(entry.path, ':~:.'))
        return true
      end
    else
      local current = servers[entry.key]
      if type(current) ~= 'table' then
        append_entry('error', 'Cannot update MCP server "' .. entry.name .. '" in ' .. vim.fn.fnamemodify(entry.path, ':~:.'))
        return true
      end
      current.disabled = disabled
    end
    changed_paths[entry.path] = true
  end

  for path in pairs(changed_paths) do
    local ok, write_err = write_mcp_config(path, source_map[path].payload)
    if not ok then
      append_entry('error', 'Failed to write ' .. vim.fn.fnamemodify(path, ':~:.') .. ': ' .. tostring(write_err))
      return true
    end
  end

  append_entry('system', string.format('%s MCP server "%s" in %d entr%s', disabled and 'Disabled' or 'Enabled', target_name, #entries, #entries == 1 and 'y' or 'ies'))
  return true
end

local function mcp_reload_command(args)
  if vim.trim(args or '') ~= '' then
    append_entry('error', 'Usage: /mcp reload')
    return true
  end
  if state.creating_session then
    append_entry('system', 'Session attach is already in progress')
    return true
  end

  local session_id = state.session_id
  if not session_id then
    append_entry('system', 'No active session. MCP changes will apply when the next session starts.')
    return true
  end

  append_entry('system', 'Reloading MCP config for session ' .. session_id .. '…')
  state.session_id = nil
  state.session_name = nil
  state.session_working_directory = nil
  refresh_statuslines()
  state.creating_session = true

  session.disconnect_session(session_id, false, function(disconnect_err)
    if disconnect_err then
      state.creating_session = false
      append_entry('error', 'MCP reload failed: ' .. disconnect_err)
      return
    end
    session.resume_session(session_id, function(_, resume_err)
      if resume_err then
        append_entry('error', 'MCP reload failed: ' .. resume_err)
        return
      end
      append_entry('system', 'Reloaded MCP config for session ' .. session_id)
    end)
  end)

  return true
end

local function mcp_command(args)
  args = vim.trim(args or '')
  if args == '' then
    return mcp_edit_command('')
  end

  local action, rest = args:match('^(%S+)%s*(.*)$')
  action = (action or ''):lower()
  rest = vim.trim(rest or '')

  if action == 'add' then
    return mcp_add_command(rest)
  end
  if action == 'show' then
    return mcp_show_command(rest)
  end
  if action == 'edit' then
    return mcp_edit_command(rest)
  end
  if action == 'delete' then
    return mcp_delete_command(rest)
  end
  if action == 'disable' then
    return mcp_set_disabled(rest, true)
  end
  if action == 'enable' then
    return mcp_set_disabled(rest, false)
  end
  if action == 'reload' then
    return mcp_reload_command(rest)
  end

  return mcp_edit_command(args)
end

local function lsp_status_message()
  return lsp.status_message()
end

local function lsp_command(args)
  local action = vim.trim(args or '')

  local function run(choice)
    if not choice or choice == '' then
      lsp.help()
      return
    end
    if choice == 'create' then
      lsp.create_config()
      return
    end
    if choice == 'status' then
      notify(lsp_status_message(), vim.log.levels.INFO)
      return
    end
    if choice == 'show' then
      lsp.show_config()
      return
    end
    if choice == 'test' then
      lsp.test()
      return
    end
    if choice == 'help' then
      lsp.help()
      return
    end
    notify('Unknown /lsp action: ' .. choice, vim.log.levels.ERROR)
  end

  if action ~= '' then
    run(action)
    return true
  end

  vim.ui.select({
    { id = 'create', label = 'Create or update .github/lsp.json from active project LSP clients' },
    { id = 'status', label = 'Show project LSP status' },
    { id = 'show', label = 'Show configured servers from .github/lsp.json' },
    { id = 'test', label = 'Test configured servers against active project clients' },
    { id = 'help', label = 'Show /lsp help' },
  }, {
    prompt = 'Copilot LSP',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    run(choice and choice.id or nil)
  end)
  return true
end

local function transcript_lines()
  local lines = {}
  local function sanitize_export_text(text)
    if text == nil then
      return ''
    end
    if type(text) ~= 'string' then
      text = tostring(text)
    end
    return text:gsub('%z', ''):gsub('\r\n?', '\n')
  end
  local function fallback_entry_lines(entry)
    local kind = type(entry) == 'table' and entry.kind or 'system'
    local label = ({
      activity = 'Activity',
      assistant = 'Assistant',
      error = 'Error',
      system = 'System',
      user = 'User',
    })[kind] or 'System'
    local content = sanitize_export_text(type(entry) == 'table' and entry.content or '')
    if kind == 'assistant' and vim.trim(content) == '' then
      return {}
    end
    local entry_lines = { label .. ':' }
    for _, line in ipairs(split_lines(content)) do
      entry_lines[#entry_lines + 1] = '  ' .. sanitize_export_text(line)
    end
    if kind == 'user' and type(entry) == 'table' and type(entry.attachments) == 'table' then
      for _, attachment in ipairs(entry.attachments) do
        local display = sanitize_export_text(attachment.display or attachment.path or attachment.type or '')
        entry_lines[#entry_lines + 1] = '  📎 ' .. display
      end
    end
    entry_lines[#entry_lines + 1] = ''
    return entry_lines
  end
  for idx, entry in ipairs(state.entries) do
    local ok, entry_lines = pcall(render.entry_lines, entry, idx, false)
    if not ok or type(entry_lines) ~= 'table' then
      log(string.format('share export falling back to raw transcript lines for entry %d: %s', idx, tostring(entry_lines)), vim.log.levels.WARN)
      entry_lines = fallback_entry_lines(entry)
    end
    for _, line in ipairs(entry_lines) do
      lines[#lines + 1] = sanitize_export_text(line)
    end
  end
  return lines
end

local function markdown_document()
  return table.concat(transcript_lines(), '\n') .. '\n'
end

local function html_escape(text)
  return (text:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

local function html_document()
  local body = html_escape(table.concat(transcript_lines(), '\n'))
  return table.concat({
    '<!DOCTYPE html>',
    '<html lang="en">',
    '<head>',
    '  <meta charset="utf-8">',
    '  <meta name="viewport" content="width=device-width, initial-scale=1">',
    '  <title>Copilot Agent Session Export</title>',
    '  <style>',
    '    body { margin: 0; background: #0d1117; color: #c9d1d9; font: 14px/1.5 ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace; }',
    '    main { max-width: 960px; margin: 0 auto; padding: 24px; }',
    '    pre { white-space: pre-wrap; word-break: break-word; }',
    '  </style>',
    '</head>',
    '<body>',
    '  <main>',
    '    <pre>' .. body .. '</pre>',
    '  </main>',
    '</body>',
    '</html>',
  }, '\n')
end

local function write_export(path, content)
  path = vim.fn.fnamemodify(path, ':p')
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f, err = io.open(path, 'w')
  if not f then
    return nil, err
  end
  f:write(content)
  f:close()
  return path
end

local function export_session(format_name, path)
  if vim.tbl_isempty(state.entries) then
    notify('No transcript entries to share', vim.log.levels.INFO)
    return
  end

  local content = format_name == 'html' and html_document() or markdown_document()
  local written, err = write_export(path, content)
  if not written then
    append_entry('error', 'Failed to export session: ' .. tostring(err))
    return
  end
  append_entry('system', 'Session export written to ' .. vim.fn.fnamemodify(written, ':~'))
end

local function default_export_path(format_name)
  local ext = format_name == 'html' and 'html' or 'md'
  return string.format('%s/copilot-session-%s.%s', working_directory(), os.date('%Y%m%d-%H%M%S'), ext)
end

local function resolve_share_request(args)
  local format_name
  local path
  local first, rest = vim.trim(args or ''):match('^(%S+)%s*(.*)$')
  if first == 'html' then
    format_name = 'html'
    path = rest
  elseif first == 'markdown' or first == 'md' or first == 'file' then
    format_name = 'markdown'
    path = rest
  elseif first and first ~= '' then
    path = args
  end
  return format_name, vim.trim(path or '')
end

local function share_session(args)
  local requested_format, requested_path = resolve_share_request(args)
  local function prompt_path(format_name)
    vim.ui.input({
      prompt = 'Export path: ',
      default = requested_path ~= '' and requested_path or default_export_path(format_name),
      completion = 'file',
    }, function(path)
      path = vim.trim(path or '')
      if path ~= '' then
        export_session(format_name, path)
      end
    end)
  end

  if requested_format then
    -- If the caller provided an explicit path, write the export synchronously and skip
    -- prompting the user (headless environments or programmatic callers expect this).
    if requested_path and requested_path ~= '' then
      export_session(requested_format, requested_path)
      return true
    end
    prompt_path(requested_format)
    return true
  end

  vim.ui.select({
    { id = 'markdown', label = 'Markdown (.md)' },
    { id = 'html', label = 'HTML (.html)' },
  }, {
    prompt = 'Share session as',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      vim.schedule(function()
        prompt_path(choice.id)
      end)
    end
  end)
  return true
end

local function review_command(args, opts)
  local scope = vim.trim(args or '')
  local lines = {
    'Review the current changes in the working directory.',
    'If a code-review subagent is available, use it.',
    'Focus only on genuine bugs, security vulnerabilities, regressions, and logic errors.',
    'Ignore style-only or formatting-only feedback.',
    'Reference files and lines when possible.',
  }
  if scope ~= '' then
    lines[#lines + 1] = 'Additional review focus: ' .. scope
  end
  local prompt = table.concat(lines, '\n')
  dispatch_prompt(prompt, opts)
  return true
end

local function research_command(args, opts)
  local topic = vim.trim(args or '')
  local function run(topic_text)
    topic_text = vim.trim(topic_text or '')
    if topic_text == '' then
      return
    end
    local prompt = table.concat({
      'Investigate the following topic using GitHub search and web sources when helpful:',
      topic_text,
      '',
      'Summarize the findings, cite the sources you relied on, and call out uncertainty clearly.',
    }, '\n')
    dispatch_prompt(prompt, opts)
  end

  if topic ~= '' then
    run(topic)
    return true
  end

  vim.ui.input({ prompt = 'Research topic: ' }, run)
  return true
end

local function ask_side_question(prompt, opts)
  prompt = vim.trim(prompt or '')
  if prompt == '' then
    return
  end

  local request_prompt = table.concat({
    'Answer this side question briefly.',
    'Use read-only tools only. Do not modify files, write files, or run shell commands.',
    '',
    prompt,
  }, '\n')
  local api_attachments, temp_files = build_api_attachments((opts or {}).attachments or {})
  clear_consumed_attachments(opts)
  notify('Running side question…', vim.log.levels.INFO)

  local side_session_id
  local deadline = now_ms() + SIDE_QUESTION_TIMEOUT_MS

  local function finish(answer, err)
    cleanup_temp_files(temp_files)
    if not side_session_id then
      if err then
        append_entry('error', '/ask failed: ' .. err)
      end
      return
    end
    delete_side_session(side_session_id, function(delete_err)
      if err then
        append_entry('error', '/ask failed: ' .. err)
        return
      end
      if delete_err then
        notify('Failed to clean up side session: ' .. delete_err, vim.log.levels.WARN)
      end
      show_side_question_result(prompt, answer)
    end)
  end

  local function poll_messages()
    request('GET', string.format('/sessions/%s/messages', side_session_id), nil, function(response, err)
      if err then
        finish(nil, err)
        return
      end

      local answer, done, answer_err = extract_side_session_answer((response and response.events) or {})
      if answer_err then
        finish(nil, answer_err)
        return
      end
      if done then
        finish(answer, nil)
        return
      end
      if now_ms() >= deadline then
        finish(nil, 'timed out waiting for side response')
        return
      end
      vim.defer_fn(poll_messages, SIDE_QUESTION_POLL_INTERVAL_MS)
    end, { auto_start = false })
  end

  local function send_prompt()
    local body = { prompt = request_prompt }
    if #api_attachments > 0 then
      body.attachments = api_attachments
    end
    request('POST', string.format('/sessions/%s/messages', side_session_id), body, function(_, err)
      if err then
        finish(nil, err)
        return
      end
      poll_messages()
    end, { auto_start = false })
  end

  local function configure_mode()
    request('POST', string.format('/sessions/%s/mode', side_session_id), { mode = 'ask' }, function(_, err)
      if err then
        notify('Failed to set /ask mode: ' .. err, vim.log.levels.WARN)
      end
      send_prompt()
    end, { auto_start = false })
  end

  request('POST', '/sessions', {
    clientName = state.config.client_name,
    permissionMode = 'approve-reads',
    workingDirectory = working_directory(),
    streaming = state.config.session.streaming,
    enableConfigDiscovery = state.config.session.enable_config_discovery,
    model = state.current_model or state.config.session.model,
    agent = state.config.session.agent,
  }, function(response, err)
    if err then
      finish(nil, err)
      return
    end
    side_session_id = response and response.sessionId or nil
    if not side_session_id then
      finish(nil, 'Server did not return a side-session ID')
      return
    end
    configure_mode()
  end)
end

local function ask_command(args, opts)
  local prompt = vim.trim(args or '')
  if prompt ~= '' then
    ask_side_question(prompt, opts)
    return true
  end

  vim.ui.input({ prompt = 'Side question: ' }, function(input)
    ask_side_question(input, opts)
  end)
  return true
end

local function init_repository(args)
  return init_project.run(args)
end

local function start_fleet(prompt)
  session.with_session(function(session_id, err)
    if err then
      append_entry('error', err)
      return
    end

    request('POST', string.format('/sessions/%s/fleet', session_id), { prompt = prompt ~= '' and prompt or nil }, function(response, request_err)
      if request_err then
        append_entry('error', 'Fleet start failed: ' .. request_err)
        return
      end

      if response and response.started then
        append_entry('system', prompt ~= '' and ('Fleet mode started: ' .. prompt) or 'Fleet mode started')
        return
      end

      append_entry('system', 'Fleet mode request was accepted, but the runtime did not report a started state')
    end)
  end)
end

local function fleet_mode(args)
  if args ~= '' then
    start_fleet(args)
    return true
  end

  vim.ui.input({ prompt = 'Fleet prompt (optional): ' }, function(input)
    if input == nil then
      return
    end
    start_fleet(vim.trim(input))
  end)
  return true
end

local function session_tasks(args)
  return tasks.show(args)
end

local function compact_result_message(result)
  if type(result) ~= 'table' then
    return 'History compaction finished'
  end

  local parts = {}
  if result.success == false then
    local err = vim.trim(result.error or '')
    return err ~= '' and ('History compaction failed: ' .. err) or 'History compaction failed'
  end
  if tonumber(result.messagesRemoved) then
    parts[#parts + 1] = string.format('%d messages removed', tonumber(result.messagesRemoved))
  end
  if tonumber(result.tokensRemoved) then
    parts[#parts + 1] = string.format('%d tokens freed', tonumber(result.tokensRemoved))
  end

  local context = result.contextWindow
  if type(context) == 'table' and tonumber(context.currentTokens) and tonumber(context.tokenLimit) then
    parts[#parts + 1] = string.format('%d/%d tokens', tonumber(context.currentTokens), tonumber(context.tokenLimit))
  end

  if #parts == 0 then
    return 'History compacted successfully'
  end
  return 'History compacted: ' .. table.concat(parts, ', ')
end

local function compact_history()
  session.with_session(function(session_id, err)
    if err then
      append_entry('error', err)
      return
    end

    request('POST', string.format('/sessions/%s/compact', session_id), {}, function(response, request_err)
      if request_err then
        append_entry('error', 'Compaction failed: ' .. request_err)
        return
      end

      local result = response and response.result or nil
      if type(result) == 'table' and result.success == false then
        append_entry('error', compact_result_message(result))
        return
      end

      if type(result) == 'table' and type(result.contextWindow) == 'table' then
        state.context_tokens = tonumber(result.contextWindow.currentTokens) or state.context_tokens
        state.context_limit = tonumber(result.contextWindow.tokenLimit) or state.context_limit
        refresh_statuslines()
      end

      events.reload_session_history(session_id, function(reload_err)
        if reload_err then
          append_entry('error', 'Compaction succeeded but history reload failed: ' .. reload_err)
          return
        end
        append_entry('system', compact_result_message(result))
      end)
    end)
  end)
  return true
end

local function short_hash(commit)
  local text = vim.trim(commit or '')
  if text == '' then
    return 'unknown'
  end
  return #text > 12 and text:sub(1, 12) or text
end

local function restore_command_label(command_name, requested_checkpoint, result)
  if command_name == 'undo' then
    return '/undo'
  end
  local target_id = type(result) == 'table' and type(result.target) == 'table' and result.target.id or nil
  local checkpoint = vim.trim(requested_checkpoint or '')
  if checkpoint ~= '' then
    return '/rewind ' .. checkpoint
  end
  if target_id and target_id ~= '' then
    return '/rewind ' .. target_id
  end
  return '/rewind'
end

local function restore_context_text(command_label, result)
  local target = type(result) == 'table' and type(result.target) == 'table' and result.target or nil
  if not target or type(target.id) ~= 'string' or target.id == '' then
    return nil
  end

  local lines = {
    'Checkpoint restore context for the next Copilot turn:',
    '- Command: ' .. command_label,
    '- Target checkpoint: ' .. target.id,
    '- Target checkpoint git hash: ' .. tostring(target.commit or 'unknown'),
  }

  if type(result.previous_head) == 'string' and result.previous_head ~= '' and result.previous_head ~= target.commit then
    lines[#lines + 1] = '- Previous checkpoint git hash: ' .. result.previous_head
  end

  if type(result.reverted) == 'table' and not vim.tbl_isempty(result.reverted) then
    lines[#lines + 1] = '- Reverted checkpoints:'
    for _, item in ipairs(result.reverted) do
      local detail = string.format('  - %s (%s): User asked %s', tostring(item.id or '?'), short_hash(item.commit), tostring(item.prompt_summary or 'checkpoint'))
      if type(item.assistant_summary) == 'string' and item.assistant_summary ~= '' then
        detail = detail .. '; Copilot updated ' .. item.assistant_summary
      end
      lines[#lines + 1] = detail
    end
  else
    lines[#lines + 1] = '- Reverted checkpoints: none; the workspace was restored to the latest saved checkpoint state.'
  end

  lines[#lines + 1] = '- This restore context will be included automatically with the next prompt sent to Copilot.'
  lines[#lines + 1] = '- Copilot may run `git diff` in the workspace to inspect the reverted code before making more changes.'
  return table.concat(lines, '\n')
end

local function queue_restore_context(command_name, requested_checkpoint, result)
  local context_text = restore_context_text(restore_command_label(command_name, requested_checkpoint, result), result)
  if not context_text then
    return nil
  end
  state.pending_session_context = {
    session_id = state.session_id,
    text = context_text,
  }
  return context_text
end

local function undo_checkpoint()
  if not state.session_id then
    notify('No active session to undo', vim.log.levels.WARN)
    return true
  end

  checkpoints.undo(state.session_id, function(err, result)
    if err and err ~= '' then
      if err == 'No checkpoints available' then
        notify(err, vim.log.levels.INFO)
        return
      end
      append_entry('error', 'Undo failed: ' .. err)
      return
    end
    append_entry('system', queue_restore_context('undo', nil, result) or 'Restored latest checkpoint')
  end)
  return true
end

local function rewind_checkpoint(args)
  if not state.session_id then
    notify('No active session to rewind', vim.log.levels.WARN)
    return true
  end

  args = vim.trim(args or '')
  checkpoints.rewind(state.session_id, args ~= '' and args or nil, function(err, result)
    if err and err ~= '' then
      if err == 'No checkpoints available' then
        notify(err, vim.log.levels.INFO)
        return
      end
      append_entry('error', 'Rewind failed: ' .. err)
      return
    end
    local context_text = queue_restore_context('rewind', args, result)
    if context_text then
      append_entry('system', context_text)
    end
  end)
  return true
end

local function todo_command()
  open_todo_float()
  return true
end

local handlers = {
  ['add-dir'] = add_directory,
  ask = ask_command,
  compact = compact_history,
  context = context_command,
  cwd = cwd_command,
  diff = diff_command,
  env = env_command,
  agent = agent_command,
  fleet = fleet_mode,
  init = init_repository,
  instructions = instructions_command,
  ['list-dir'] = list_directories_command,
  ['list-dirs'] = list_directories_command,
  ['list-tools'] = list_tools_command,
  lsp = lsp_command,
  mcp = mcp_command,
  ['new'] = new_session_command,
  model = select_model_command,
  plan = plan_mode_command,
  rename = rename_session,
  research = research_command,
  ['reset-allowed-tools'] = reset_allowed_tools_command,
  review = review_command,
  resume = resume_session_command,
  search = search_transcript,
  session = session_command,
  share = share_session,
  skills = skills_command,
  tasks = session_tasks,
  todo = todo_command,
  usage = usage_command,
  ['allow-all'] = allow_all_command,
  clear = clear_session_command,
  undo = undo_checkpoint,
  rewind = rewind_checkpoint,
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

M._extract_side_session_answer = extract_side_session_answer

return M
