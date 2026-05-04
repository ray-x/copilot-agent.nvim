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
local append_entry = render.append_entry
local refresh_statuslines = sl.refresh_statuslines
local request = http.request
local split_lines = utils.split_lines

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

local function open_path(path)
  if type(path) ~= 'string' or path == '' then
    return
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
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
  local height =
    math.min(math.max(#normalized_lines + RESULT_FLOAT_BORDER_LINES, RESULT_FLOAT_MIN_HEIGHT), math.floor(vim.o.lines * RESULT_FLOAT_HEIGHT_RATIO))
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
      if content and vim.trim(content) ~= '' then
        answer = content
        if not has_tool_requests then
          final_message_seen = true
        end
      end
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
  return answer, (turn_finished and has_answer) or final_message_seen, nil
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

local function session_command(args)
  local action = vim.trim(args or '')
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
  session.switch_to_session_id(action)
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

local function plan_mode_command(args)
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

local function context_command()
  if not state.context_tokens or not state.context_limit or state.context_limit <= 0 then
    notify('Context window usage is not available yet for this session', vim.log.levels.INFO)
    return true
  end
  local percent = math.floor((state.context_tokens / state.context_limit) * 100 + 0.5)
  append_entry('system', string.format('Context window: %d / %d tokens (%d%%)', state.context_tokens, state.context_limit, percent))
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
      return nil, nil, nil
    end

    local from_arg, to_arg = raw_args:match('^(%S+)%.%.(%S+)$')
    if from_arg and to_arg then
      return from_arg, to_arg, nil
    end

    local tokens = {}
    for token in raw_args:gmatch('%S+') do
      tokens[#tokens + 1] = token
    end
    if #tokens == 1 then
      return nil, tokens[1], nil
    end
    if #tokens == 2 then
      return tokens[1], tokens[2], nil
    end
    return nil, nil, 'Usage: /diff [checkpoint] | /diff <from> <to> | /diff <from>..<to>'
  end

  local function resolve_diff_checkpoints(checkpoint_items, raw_args)
    if #checkpoint_items < 2 then
      return nil, nil, 'Need at least two checkpoints to diff'
    end

    local from_arg, to_arg, parse_err = parse_diff_checkpoint_args(raw_args)
    if parse_err then
      return nil, nil, parse_err
    end

    if not to_arg then
      return checkpoint_items[#checkpoint_items - 1], checkpoint_items[#checkpoint_items], nil
    end

    local to_idx, to_item = checkpoint_index_by_id(checkpoint_items, to_arg)
    if not to_item then
      return nil, nil, 'Checkpoint not found: ' .. to_arg
    end

    if not from_arg then
      if to_idx <= 1 then
        return nil, nil, 'Checkpoint ' .. to_item.id .. ' has no earlier checkpoint to compare'
      end
      return checkpoint_items[to_idx - 1], to_item, nil
    end

    local from_idx, from_item = checkpoint_index_by_id(checkpoint_items, from_arg)
    if not from_item then
      return nil, nil, 'Checkpoint not found: ' .. from_arg
    end
    if from_idx == to_idx then
      return nil, nil, 'Choose two different checkpoints'
    end
    if from_idx > to_idx then
      from_item, to_item = to_item, from_item
    end
    return from_item, to_item, nil
  end

  if not state.session_id then
    append_entry('error', 'Diff unavailable: no active session')
    return true
  end

  local checkpoint_items = vim.tbl_filter(function(item)
    return type(item) == 'table' and type(item.id) == 'string' and item.id ~= '' and type(item.commit) == 'string' and item.commit ~= ''
  end, checkpoints.list(state.session_id))
  local from_checkpoint, to_checkpoint, range_err = resolve_diff_checkpoints(checkpoint_items, args)
  if range_err then
    append_entry('error', 'Diff unavailable: ' .. range_err)
    return true
  end

  local checkpoint_git_dir = checkpoints._session_dir(state.session_id) .. '/repo/.git'
  local workspace = state.session_working_directory or working_directory()
  if type(workspace) ~= 'string' or workspace == '' then
    append_entry('error', 'Diff unavailable: working directory is not set')
    return true
  end

  local output, diff_err = run_command({
    'git',
    '--no-pager',
    '--git-dir=' .. checkpoint_git_dir,
    '--work-tree=' .. workspace,
    'diff',
    '--stat',
    from_checkpoint.commit,
    to_checkpoint.commit,
    '--',
    '.',
  }, workspace)
  if diff_err then
    append_entry('error', 'Diff failed: ' .. diff_err)
    return true
  end
  if output == '' then
    append_entry('system', string.format('No differences between checkpoints %s and %s', from_checkpoint.id, to_checkpoint.id))
    return true
  end

  append_entry('system', string.format('Checkpoint diff %s -> %s:\n%s', from_checkpoint.id, to_checkpoint.id, output))
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

local function mcp_command(args)
  return open_discovered_item('MCP config', discovery.mcp_items(), args)
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
  for idx, entry in ipairs(state.entries) do
    vim.list_extend(lines, render.entry_lines(entry, idx, true))
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
      prompt_path(choice.id)
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

local function undo_checkpoint()
  if not state.session_id then
    notify('No active session to undo', vim.log.levels.WARN)
    return true
  end

  checkpoints.undo(state.session_id, function(err)
    if err and err ~= '' then
      if err == 'No checkpoints available' then
        notify(err, vim.log.levels.INFO)
        return
      end
      append_entry('error', 'Undo failed: ' .. err)
      return
    end
    append_entry('system', 'Restored latest checkpoint')
  end)
  return true
end

local function rewind_checkpoint(args)
  if not state.session_id then
    notify('No active session to rewind', vim.log.levels.WARN)
    return true
  end

  args = vim.trim(args or '')
  checkpoints.rewind(state.session_id, args ~= '' and args or nil, function(err)
    if err and err ~= '' then
      if err == 'No checkpoints available' then
        notify(err, vim.log.levels.INFO)
        return
      end
      append_entry('error', 'Rewind failed: ' .. err)
      return
    end
  end)
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
