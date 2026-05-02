-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- SSE event stream: parser, host/session event handlers.

local utils = require('copilot_agent.utils')
local approvals = require('copilot_agent.approvals')
local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local logger = require('copilot_agent.log')
local service = require('copilot_agent.service')
local session_names = require('copilot_agent.session_names')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')
local checkpoints = require('copilot_agent.checkpoints')
local window = require('copilot_agent.window')

local state = cfg.state
local notify = cfg.notify
local log = logger.log
local should_log = logger.should_log
local serialize_log_value = logger.serialize_log_value

local decode_json = http.decode_json
local request = http.request
local build_url = http.build_url

local working_directory = service.working_directory

local refresh_statuslines = sl.refresh_statuslines

local render_chat = render.render_chat
local schedule_render = render.schedule_render
local stream_update = render.stream_update
local append_entry = render.append_entry
local clear_transcript = render.clear_transcript
local ensure_assistant_entry = render.ensure_assistant_entry
local reset_pending_assistant_entry = render.reset_pending_assistant_entry
local append_reasoning_delta = render.append_reasoning_delta
local clear_reasoning_preview = render.clear_reasoning_preview
local refresh_reasoning_overlay = render.refresh_reasoning_overlay
local reset_frozen_render = render.reset_frozen_render
local scroll_to_bottom = render.scroll_to_bottom

-- local is_thinking_content = utils.is_thinking_content

local M = {}
local active_prompt_id = nil
local queued_prompt_requests = {}
local queued_prompt_request_ids = {}
local prompt_handoff_delay_ms = 20
local intentionally_stopped_event_jobs = {}
local sanitize_permission_text

local function preload_history_checkpoint_ids(session_id)
  local ids = {}
  for _, checkpoint in ipairs(checkpoints.list(session_id)) do
    if
      type(checkpoint.assistant_message_id) == 'string'
      and checkpoint.assistant_message_id ~= ''
      and type(checkpoint.id) == 'string'
      and checkpoint.id ~= ''
    then
      ids[checkpoint.assistant_message_id] = {
        id = checkpoint.id,
        prompt = checkpoint.prompt,
      }
    end
  end
  state.history_checkpoint_ids = ids
end

local function assign_history_checkpoint_id(assistant_message_id)
  if type(assistant_message_id) ~= 'string' or assistant_message_id == '' then
    return nil
  end
  local mapping = state.history_checkpoint_ids and state.history_checkpoint_ids[assistant_message_id] or nil
  if type(mapping) ~= 'table' or type(mapping.id) ~= 'string' or mapping.id == '' then
    return
  end
  for idx, pending in ipairs(state.history_pending_user_entries) do
    local entry = state.entries[pending.entry_index]
    local prompt_matches = type(mapping.prompt) ~= 'string' or mapping.prompt == '' or pending.content == mapping.prompt
    if entry and entry.kind == 'user' and prompt_matches then
      entry.checkpoint_id = mapping.id
      table.remove(state.history_pending_user_entries, idx)
      return
    end
  end
end

local function first_non_empty(...)
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if type(value) == 'string' and value ~= '' then
      return value
    end
  end
  return nil
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

local function log_debug_trace(message, payload, opts)
  if not should_log(vim.log.levels.DEBUG) then
    return
  end
  opts = opts or {}
  local suffix = payload == nil and '' or ' ' .. serialize_log_value(payload, opts)
  log(message .. suffix, vim.log.levels.DEBUG)
end

local function truncate_session_log_content(text)
  if type(text) ~= 'string' then
    return text
  end
  if #text > 120 then
    return text:sub(1, 119) .. '…'
  end
  return text
end

local function sanitize_session_log_value(value, seen)
  if type(value) ~= 'table' then
    return value
  end

  seen = seen or {}
  if seen[value] then
    return '<cycle>'
  end
  seen[value] = true

  local sanitized = {}
  if vim.tbl_islist(value) then
    for idx, item in ipairs(value) do
      sanitized[idx] = sanitize_session_log_value(item, seen)
    end
  else
    for key, item in pairs(value) do
      local key_name = type(key) == 'string' and key:lower() or nil
      if key_name ~= 'encryptedcontent' then
        if key_name == 'content' and type(item) == 'string' then
          sanitized[key] = truncate_session_log_content(item)
        else
          sanitized[key] = sanitize_session_log_value(item, seen)
        end
      end
    end
  end

  seen[value] = nil
  return sanitized
end

local function decode_json_silently(raw)
  if raw == nil or raw == '' then
    return nil
  end

  local decoder
  if vim.json and type(vim.json.decode) == 'function' then
    decoder = vim.json.decode
  elseif type(vim.fn.json_decode) == 'function' then
    decoder = vim.fn.json_decode
  else
    return nil, 'no JSON decoder available in this Neovim version'
  end

  local ok, decoded = pcall(decoder, raw)
  if ok then
    return decoded
  end
  return nil, decoded
end

local function log_session_event_payload(event_name, raw_data)
  if event_name ~= 'session.event' or not should_log(vim.log.levels.DEBUG) then
    return
  end

  local decoded = decode_json_silently(raw_data)
  if type(decoded) == 'table' then
    log_debug_trace('sse.event raw event=' .. tostring(event_name) .. ' payload=', sanitize_session_log_value(decoded), {
      max_len = 3200,
      depth = 8,
    })
    return
  end

  log(
    string.format(
      'sse.event raw event=%s string=%s',
      tostring(event_name),
      serialize_log_value(raw_data, { max_len = 3200 })
    ),
    vim.log.levels.DEBUG
  )
end

local function preview_delta_boundary(current, delta)
  current = type(current) == 'string' and current or ''
  delta = type(delta) == 'string' and delta or ''
  local current_tail = current:sub(math.max(1, #current - 23), #current)
  local delta_head = delta:sub(1, 24)
  local tail_last = current_tail:sub(-1)
  local head_first = delta_head:sub(1, 1)
  local suspicious_join = tail_last ~= ''
    and head_first ~= ''
    and tail_last:match('[%w%)]')
    and head_first:match('[%w%(]')
    and not tail_last:match('%s')
    and not head_first:match('%s')

  return string.format(
    'tail=%s head=%s suspicious=%s',
    preview_log_text(current_tail, 40),
    preview_log_text(delta_head, 40),
    tostring(suspicious_join and true or false)
  )
end

local function merge_assistant_delta_content(current, delta, ctx)
  current = type(current) == 'string' and current or ''
  delta = type(delta) == 'string' and delta or ''
  local function finish(decision, result, extra)
    extra = extra or {}
    -- log(
    -- string.format(
    -- 'assistant.message_delta merge decision=%s message_id=%s key=%s idx=%s current_len=%d delta_len=%d result_len=%d overlap=%s current=%s delta=%s result=%s',
    -- tostring(decision),
    -- tostring((ctx or {}).message_id or '<none>'),
    -- tostring((ctx or {}).entry_key or '<none>'),
    -- tostring((ctx or {}).entry_index or '<none>'),
    -- #current,
    -- #delta,
    -- #(type(result) == 'string' and result or ''),
    -- tostring(extra.overlap or '<none>'),
    -- preview_log_text(current),
    -- preview_log_text(delta),
    -- preview_log_text(result)
    -- ),
    -- vim.log.levels.DEBUG
    -- )
    return result
  end

  if delta == '' then
    return finish('ignore-empty-delta', current)
  end
  if current == '' then
    return finish('append-initial-delta', current .. delta)
  end
  if current:sub(-#delta) == delta then
    return finish('ignore-duplicate-suffix', current)
  end
  if delta:sub(1, #current) == current then
    return finish('replace-cumulative-delta', delta)
  end

  local function safe_overlap(overlap)
    if overlap > 1 then
      return true
    end

    local overlap_char = current:sub(#current, #current)
    local previous_char = current:sub(#current - 1, #current - 1)
    local next_char = delta:sub(2, 2)
    if overlap_char == '' then
      return false
    end

    -- Avoid collapsing a single repeated letter inside a word, which turns
    -- streamed content like "pad" + "ded" into "paded".
    if overlap_char:match('%w') and previous_char:match('%w') and next_char:match('%w') then
      return false
    end

    return true
  end

  local max_overlap = math.min(#current, #delta)
  for overlap = max_overlap, 1, -1 do
    if current:sub(#current - overlap + 1) == delta:sub(1, overlap) and safe_overlap(overlap) then
      return finish('merge-literal-overlap', current .. delta:sub(overlap + 1), { overlap = overlap })
    end
  end

  return finish('append-raw-delta', current .. delta)
end

local function merge_assistant_message_content(current, incoming, ctx)
  current = type(current) == 'string' and current or ''
  incoming = type(incoming) == 'string' and incoming or ''
  local function finish(decision, result, extra)
    extra = extra or {}
    log(
      string.format(
        'assistant.message merge decision=%s message_id=%s key=%s idx=%s current_len=%d incoming_len=%d result_len=%d overlap=%s current=%s incoming=%s result=%s',
        tostring(decision),
        tostring((ctx or {}).message_id or '<none>'),
        tostring((ctx or {}).entry_key or '<none>'),
        tostring((ctx or {}).entry_index or '<none>'),
        #current,
        #incoming,
        #(type(result) == 'string' and result or ''),
        tostring(extra.overlap or '<none>'),
        preview_log_text(current),
        preview_log_text(incoming),
        preview_log_text(result)
      ),
      vim.log.levels.DEBUG
    )
    return result
  end
  if incoming == '' then
    return finish('ignore-empty-incoming', current)
  end
  if current == '' then
    return finish('replace-empty-or-thinking', incoming)
  end
  local function canonicalize(text)
    return text
      :gsub('\r\n?', '\n')
      :gsub('’', "'")
      :gsub('‘', "'")
      :gsub('“', '"')
      :gsub('”', '"')
      :lower()
      :gsub('[%p%c]+', ' ')
      :gsub('%s+', ' ')
      :match('^%s*(.-)%s*$')
  end
  local function split_message_lines(text)
    return vim.split(text:gsub('\r\n?', '\n'), '\n', { plain = true })
  end
  local function common_prefix_len(left, right)
    local max_len = math.min(#left, #right)
    local shared = 0
    for idx = 1, max_len do
      if left:sub(idx, idx) ~= right:sub(idx, idx) then
        break
      end
      shared = idx
    end
    return shared
  end
  local function overlap_line_count(current_lines, incoming_lines)
    local max_overlap = math.min(#current_lines, #incoming_lines)
    for overlap = max_overlap, 1, -1 do
      local matches = true
      for idx = 1, overlap do
        local current_line = canonicalize(current_lines[#current_lines - overlap + idx] or '')
        local incoming_line = canonicalize(incoming_lines[idx] or '')
        if current_line ~= incoming_line and (current_line ~= '' or incoming_line ~= '') then
          matches = false
          break
        end
      end
      if matches then
        return overlap
      end
    end
    return 0
  end
  local canonical_current = canonicalize(current)
  local canonical_incoming = canonicalize(incoming)
  if current == incoming then
    return finish('keep-identical-literal', current)
  end
  if canonical_current ~= '' and canonical_current == canonical_incoming then
    return finish('replace-canonical-equal', incoming)
  end
  if incoming:sub(1, #current) == current then
    return finish('replace-prefix-extension', incoming)
  end
  if canonical_current ~= '' and canonical_incoming ~= '' then
    if vim.startswith(canonical_incoming, canonical_current) then
      return finish('replace-canonical-prefix-extension', incoming)
    end
    if canonical_current:find(canonical_incoming, 1, true) then
      return finish('keep-canonical-substring', current)
    end
  end
  if current:find(incoming, 1, true) then
    return finish('keep-literal-substring', current)
  end
  local current_lines = split_message_lines(current)
  local incoming_lines = split_message_lines(incoming)
  local overlap = overlap_line_count(current_lines, incoming_lines)
  if overlap > 0 then
    local merged = {}
    for idx = 1, #current_lines - overlap do
      merged[#merged + 1] = current_lines[idx]
    end
    for _, line in ipairs(incoming_lines) do
      merged[#merged + 1] = line
    end
    return finish('merge-line-overlap', table.concat(merged, '\n'), { overlap = overlap })
  end
  if canonical_current ~= '' and canonical_incoming ~= '' and #canonical_incoming >= #canonical_current then
    local shared_prefix = common_prefix_len(canonical_current, canonical_incoming)
    local min_prefix = math.max(24, math.floor(math.min(#canonical_current, #canonical_incoming) * 0.35))
    if shared_prefix >= min_prefix then
      return finish('replace-canonical-near-prefix', incoming, { overlap = shared_prefix })
    end
  end
  local separator = current:match('\n$') and '' or '\n'
  return finish('append-fallback', current .. separator .. incoming)
end

local function looks_like_shell_tool(name)
  if type(name) ~= 'string' or name == '' then
    return false
  end
  name = vim.trim(name):lower()
  return name == 'bash'
    or name == 'sh'
    or name == 'zsh'
    or name == 'fish'
    or name == 'pwsh'
    or name == 'powershell'
    or name == 'cmd'
end

local function overlay_now_ms()
  local hrtime = (vim.uv or vim.loop).hrtime
  return math.floor(hrtime() / 1e6)
end

local function cancel_overlay_tool_schedule()
  state.overlay_tool_schedule_token = (tonumber(state.overlay_tool_schedule_token) or 0) + 1
end

local function min_overlay_tool_duration_ms()
  return 3000
end

local function extract_shell_command_text(data)
  data = type(data) == 'table' and data or {}
  local function assemble_command_with_args(command_value, arg_values)
    local parts = {}
    local command = sanitize_permission_text(command_value)
    if command then
      parts[#parts + 1] = command
    end

    if type(arg_values) == 'table' then
      for _, value in ipairs(arg_values) do
        local arg = sanitize_permission_text(value)
        if arg then
          parts[#parts + 1] = arg
        end
      end
    elseif type(arg_values) == 'string' then
      local args = sanitize_permission_text(arg_values)
      if args then
        parts[#parts + 1] = args
      end
    end

    if #parts == 0 then
      return nil
    end
    return sanitize_permission_text(table.concat(parts, ' '))
  end

  local visited = {}
  local nested_keys = {
    'input',
    'toolInput',
    'tool_input',
    'parameters',
    'params',
    'payload',
    'request',
    'call',
    'invocation',
    'details',
    'metadata',
  }

  local function extract_from_table(value, depth)
    if type(value) ~= 'table' or depth > 3 or visited[value] then
      return nil
    end
    visited[value] = true

    local command_with_args = assemble_command_with_args(
      value.command or value.executable or value.program or value.cmd,
      value.arguments or value.args or value.argv or value.commandArgs or value.command_args
    )
    if command_with_args then
      return command_with_args
    end

    local detail = sanitize_permission_text(
      value.fullCommandText
        or value.commandLine
        or value.commandText
        or value.shellCommand
        or value.rawCommand
        or value.raw_command
        or value.invocation
        or value.command
        or value.toolDescription
        or value.description
        or value.intention
    )
    if detail then
      return detail
    end

    for _, key in ipairs(nested_keys) do
      local nested = extract_from_table(value[key], depth + 1)
      if nested then
        return nested
      end
    end

    for _, nested in pairs(value) do
      local detail_from_nested = extract_from_table(nested, depth + 1)
      if detail_from_nested then
        return detail_from_nested
      end
    end

    return nil
  end

  return extract_from_table(data, 1)
end

local function extract_shell_tool_detail(tool_name, data)
  local detail = extract_shell_command_text(data)
  if detail then
    return detail
  end

  if looks_like_shell_tool(tool_name) then
    return state.pending_tool_detail
  end
  return nil
end

local function schedule_overlay_tool_clear(delay_ms, run_id)
  cancel_overlay_tool_schedule()
  local token = state.overlay_tool_schedule_token
  vim.defer_fn(function()
    if state.overlay_tool_schedule_token ~= token then
      return
    end
    local current = state.overlay_tool_display
    if not current or current.run_id ~= run_id or current.completed ~= true then
      return
    end
    state.overlay_tool_display = nil
    refresh_reasoning_overlay(true)
  end, math.max(0, math.floor(tonumber(delay_ms) or 0)))
end

local function enqueue_overlay_tool(tool_name, detail)
  if not looks_like_shell_tool(tool_name) then
    return nil
  end

  state.overlay_tool_run_id = (tonumber(state.overlay_tool_run_id) or 0) + 1
  local item = {
    run_id = state.overlay_tool_run_id,
    tool = tool_name,
    detail = detail,
    completed = false,
    display_started_ms = overlay_now_ms(),
  }

  cancel_overlay_tool_schedule()
  state.overlay_tool_display = item
  refresh_reasoning_overlay(true)
  return item.run_id
end

local function complete_overlay_tool(run_id)
  if type(run_id) ~= 'number' then
    return
  end

  local current = state.overlay_tool_display
  if not current or current.run_id ~= run_id then
    return
  end

  current.completed = true
  local elapsed = overlay_now_ms() - (tonumber(current.display_started_ms) or 0)
  local remaining = math.max(0, min_overlay_tool_duration_ms() - elapsed)
  schedule_overlay_tool_clear(remaining, run_id)
end

local function reset_overlay_tool_state()
  cancel_overlay_tool_schedule()
  state.overlay_tool_display = nil
  state.overlay_tool_queue = {}
end

local active_background_task_status = {
  running = true,
  inbox = true,
  idle = true,
}

local function reset_live_activity_state()
  state.pending_checkpoint_ops = 0
  state.pending_workspace_updates = 0
  state.background_tasks = {}
  state.active_tool = nil
  state.active_tool_run_id = nil
  state.active_tool_detail = nil
  state.pending_tool_detail = nil
  state.recent_activity_lines = {}
  reset_overlay_tool_state()
  state.active_turn_assistant_index = nil
  state.active_turn_assistant_message_id = nil
  state.current_intent = nil
  clear_reasoning_preview('live activity reset')
end

local function set_background_task(key, opts)
  if type(key) ~= 'string' or key == '' then
    return
  end

  opts = opts or {}
  local status = opts.status
  if not active_background_task_status[status] then
    if state.background_tasks[key] ~= nil then
      state.background_tasks[key] = nil
      refresh_statuslines()
      refresh_reasoning_overlay()
    end
    return
  end

  local task = state.background_tasks[key] or { id = key }
  task.kind = opts.kind or task.kind
  task.status = status
  task.title = first_non_empty(opts.title, task.title)
  task.description = first_non_empty(opts.description, task.description)
  state.background_tasks[key] = task
  refresh_statuslines()
  refresh_reasoning_overlay()
end

-- Show a diff in a floating window.
-- Tries the configured external diff command (e.g. delta) in a terminal buffer;
-- falls back to a plain diff buffer if the command is unavailable.
local function show_diff_float(diff_text, after_close)
  local lines = vim.split(diff_text, '\n', { plain = true })
  local width = math.min(math.floor(vim.o.columns * 0.8), 120)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
  local win_opts = {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Proposed changes (<C-c> to exit) ',
    title_pos = 'center',
  }

  local function setup_close_keys(buf, win)
    local function close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if after_close then
        after_close()
      end
    end
    vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
    vim.keymap.set('n', '<Esc><Esc>', close, { buffer = buf, nowait = true })
    vim.keymap.set({ 'n', 'i', 't' }, '<C-c>', close, { buffer = buf, nowait = true })
  end

  local function open_ansi_float(output)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    local win = vim.api.nvim_open_win(buf, true, win_opts)
    window.disable_folds(win)
    setup_close_keys(buf, win)
    local chan = vim.api.nvim_open_term(buf, {})
    if chan and chan > 0 then
      vim.api.nvim_chan_send(chan, output)
    end
  end

  local diff_cmd = state.config.chat.diff_cmd
  if diff_cmd and type(diff_cmd) == 'table' and #diff_cmd > 0 then
    diff_cmd = vim.list_extend({}, diff_cmd)
    if diff_cmd[1] == 'delta' then
      if width >= 100 and not vim.tbl_contains(diff_cmd, '--side-by-side') then
        table.insert(diff_cmd, '--side-by-side')
      end
      if not vim.tbl_contains(diff_cmd, '--paging=never') then
        table.insert(diff_cmd, '--paging=never')
      end
    end
  end
  if diff_cmd and type(diff_cmd) == 'table' and #diff_cmd > 0 and vim.fn.executable(diff_cmd[1]) == 1 then
    local ok, output = pcall(vim.fn.system, diff_cmd, diff_text)
    if ok and type(output) == 'string' and output ~= '' then
      open_ansi_float(output)
      return
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'diff'
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, win_opts)
  window.disable_folds(win)
  setup_close_keys(buf, win)
end

local function is_recoverable_stream_exit(code, stderr_message)
  if code == 7 or code == 18 or code == 52 or code == 56 then
    return true
  end
  if utils.is_connection_error(stderr_message) then
    return true
  end
  return false
end

local function format_stream_exit_message(code, stderr_message)
  if type(stderr_message) == 'string' and stderr_message ~= '' then
    return stderr_message
  end
  return 'Event stream stopped with exit code ' .. tostring(code)
end

local function neovim_is_exiting()
  local exiting = vim.v.exiting
  if exiting == vim.NIL or exiting == nil then
    return false
  end
  if type(exiting) == 'number' then
    return exiting ~= 0
  end
  if type(exiting) == 'string' then
    return exiting ~= '' and exiting ~= '0'
  end
  return true
end

function M._handle_event_stream_exit(session_id, code, stderr_message, opts)
  opts = opts or {}
  local exit_message = format_stream_exit_message(code, stderr_message)

  if opts.stopped_intentionally or code == 0 or state.session_id ~= session_id or neovim_is_exiting() then
    return
  end

  if state.config.service.auto_start ~= true or not is_recoverable_stream_exit(code, stderr_message) then
    append_entry('error', exit_message)
    return
  end

  if state.event_stream_recovery_session_id == session_id then
    return
  end

  state.event_stream_recovery_session_id = session_id
  state.history_loading = false
  state.chat_busy = false
  refresh_statuslines()
  append_entry('system', 'Event stream disconnected. Reconnecting...')

  service.ensure_service_live(function(service_err)
    if state.session_id ~= session_id then
      state.event_stream_recovery_session_id = nil
      return
    end

    if service_err then
      state.event_stream_recovery_session_id = nil
      append_entry('error', exit_message)
      append_entry('error', 'Failed to recover event stream: ' .. service_err)
      return
    end

    state.creating_session = true
    require('copilot_agent.session').resume_session(session_id, function(_, resume_err)
      if state.session_id ~= session_id then
        state.event_stream_recovery_session_id = nil
        return
      end
      state.event_stream_recovery_session_id = nil
      if resume_err then
        append_entry('error', 'Failed to recover event stream: ' .. resume_err)
      end
    end, {
      guard_current_session_id = session_id,
    })
  end)
end

sanitize_permission_text = function(text)
  if type(text) ~= 'string' then
    return nil
  end
  text = text:gsub('[\r\n]+', ' '):gsub('\t', ' ')
  text = vim.trim(text)
  if text == '' then
    return nil
  end
  return text
end

local function build_permission_prompt(permission)
  permission = permission or {}
  local kind = permission.kind or 'unknown'
  local parts = {}

  if kind == 'shell' then
    local cmd = extract_shell_command_text(permission) or '(shell command)'
    parts[#parts + 1] = 'Run shell command'
    parts[#parts + 1] = cmd
  elseif kind == 'write' then
    parts[#parts + 1] = 'Write file'
    parts[#parts + 1] = sanitize_permission_text(permission.fileName or permission.path) or '(unknown file)'
  elseif kind == 'read' then
    parts[#parts + 1] = 'Read'
    parts[#parts + 1] = sanitize_permission_text(permission.path or permission.fileName) or '(unknown path)'
  elseif kind == 'mcp' or kind == 'custom-tool' then
    local tool = sanitize_permission_text(permission.toolTitle or permission.toolName) or 'unknown tool'
    local server = sanitize_permission_text(permission.serverName) or ''
    parts[#parts + 1] = tool
    if server ~= '' then
      parts[#parts + 1] = '(' .. server .. ')'
    end
    local description = sanitize_permission_text(permission.toolDescription)
    if description then
      parts[#parts + 1] = '— ' .. description
    end
  elseif kind == 'url' then
    parts[#parts + 1] = 'Fetch URL'
    parts[#parts + 1] = sanitize_permission_text(permission.url) or '(unknown URL)'
  elseif kind == 'memory' then
    parts[#parts + 1] = 'Memory ' .. tostring(permission.action or 'access')
    local fact = sanitize_permission_text(permission.fact)
    if fact then
      parts[#parts + 1] = fact
    end
  elseif kind == 'hook' then
    parts[#parts + 1] = 'Hook'
    local hook_message = sanitize_permission_text(permission.hookMessage)
    if hook_message then
      parts[#parts + 1] = hook_message
    end
  else
    parts[#parts + 1] = sanitize_permission_text(permission.toolTitle or permission.toolName or kind) or kind
  end

  local intention = sanitize_permission_text(permission.intention)
  if intention and kind ~= 'shell' and kind ~= 'read' and kind ~= 'write' then
    parts[#parts + 1] = '— ' .. intention
  end

  return 'Allow: ' .. table.concat(parts, ' ')
end

local function prompt_request_id(payload)
  local req = payload and payload.data and payload.data.request or {}
  local req_id = req and req.id or nil
  if type(req_id) ~= 'string' or req_id == '' then
    return nil
  end
  return req_id
end

local function reset_prompt_state()
  active_prompt_id = nil
  queued_prompt_requests = {}
  queued_prompt_request_ids = {}
end

local function enqueue_prompt(kind, payload)
  local req_id = prompt_request_id(payload)
  if not req_id then
    return false
  end
  if active_prompt_id == req_id or queued_prompt_request_ids[req_id] then
    return false
  end
  queued_prompt_request_ids[req_id] = true
  queued_prompt_requests[#queued_prompt_requests + 1] = {
    kind = kind,
    payload = payload,
  }
  return true
end

local function pop_prompt()
  while #queued_prompt_requests > 0 do
    local entry = table.remove(queued_prompt_requests, 1)
    local req_id = prompt_request_id(entry.payload)
    if req_id then
      queued_prompt_request_ids[req_id] = nil
      return entry
    end
  end
  return nil
end

local function finish_prompt(req_id)
  if active_prompt_id == req_id then
    active_prompt_id = nil
  end
end

local function defer_prompt(callback)
  vim.defer_fn(function()
    callback()
  end, prompt_handoff_delay_ms)
end

local function answer_permission(session_id, request_id, approved, callback)
  request(
    'POST',
    '/sessions/' .. session_id .. '/permission/' .. request_id,
    { approved = approved },
    callback
      or function(_, err)
        if err then
          notify('Failed to send permission answer: ' .. tostring(err), vim.log.levels.WARN)
        end
      end
  )
end

local function sync_model_state(model, reasoning_effort)
  if type(model) == 'string' and model ~= '' then
    state.current_model = model
    state.config.session.model = model
  elseif model == '' or model == nil then
    state.current_model = nil
  end

  if type(reasoning_effort) == 'string' and reasoning_effort ~= '' then
    state.reasoning_effort = reasoning_effort
  elseif reasoning_effort == '' or reasoning_effort == nil then
    state.reasoning_effort = nil
  end
end

local function sync_config_counts(data)
  state.instruction_count = tonumber(data.instructionCount) or 0
  state.agent_count = tonumber(data.agentCount) or 0
  state.skill_count = tonumber(data.skillCount) or 0
  state.mcp_count = tonumber(data.mcpCount) or 0
end

local show_next_prompt

local function present_user_input_picker(payload)
  local request_payload = payload and payload.data and payload.data.request or nil
  if type(request_payload) ~= 'table' or type(request_payload.id) ~= 'string' then
    return
  end

  local req_id = request_payload.id
  local session_id = payload.data.sessionId or state.session_id
  if type(session_id) ~= 'string' or session_id == '' then
    finish_prompt(req_id)
    defer_prompt(show_next_prompt)
    return
  end

  active_prompt_id = req_id
  local choices = type(request_payload.choices) == 'table' and request_payload.choices or {}
  local allow_freeform = request_payload.allowFreeform ~= false

  local function complete()
    finish_prompt(req_id)
    defer_prompt(show_next_prompt)
  end

  local function answer(value, was_freeform)
    if value == nil or value == '' then
      return
    end
    state.pending_user_input = nil
    append_entry('user', value)
    request('POST', string.format('/sessions/%s/user-input/%s', session_id, request_payload.id), {
      answer = value,
      wasFreeform = was_freeform,
    }, function(_, err)
      if err then
        append_entry('error', 'Failed to answer user input: ' .. err)
      end
    end)
    complete()
  end

  local function ask_freeform()
    vim.ui.input({ prompt = request_payload.question .. ' ' }, function(input)
      if input == nil or input == '' then
        notify('Input dismissed — use :CopilotAgentRetryInput to try again', vim.log.levels.WARN)
        complete()
        return
      end
      answer(input, true)
    end)
  end

  if #choices > 0 then
    local items = vim.deepcopy(choices)
    if allow_freeform then
      table.insert(items, 'Custom...')
    end
    vim.ui.select(items, { prompt = request_payload.question }, function(choice)
      if choice == nil then
        notify('Selection dismissed — use :CopilotAgentRetryInput to try again', vim.log.levels.WARN)
        complete()
        return
      end
      if choice == 'Custom...' then
        ask_freeform()
        return
      end
      answer(choice, false)
    end)
    return
  end

  if allow_freeform then
    ask_freeform()
    return
  end

  complete()
end

local function show_user_input_picker(payload)
  if not enqueue_prompt('user_input', payload) then
    return
  end

  vim.schedule(show_next_prompt)
end

local function handle_user_input(payload)
  local request_payload = payload and payload.data and payload.data.request or nil
  if type(request_payload) ~= 'table' or type(request_payload.id) ~= 'string' then
    return
  end

  -- Store for retry if dismissed.
  state.pending_user_input = payload

  append_entry('system', 'Input requested: ' .. request_payload.question)
  show_user_input_picker(payload)
end

local function present_permission_picker(payload)
  local data = payload and payload.data or {}
  local req = data.request or {}
  local req_id = req.id
  local sid = state.session_id
  local event_session_id = data.sessionId
  if not sid or sid == '' then
    finish_prompt(req_id)
    defer_prompt(show_next_prompt)
    return
  end
  if type(event_session_id) == 'string' and sid ~= event_session_id then
    finish_prompt(req_id)
    defer_prompt(show_next_prompt)
    return
  end

  local perm = req.request or {}
  local kind = perm.kind or 'unknown'
  local prompt_str = build_permission_prompt(perm)

  -- Build choices: Allow, Deny, Allow all for session.
  -- For read/write with a file path, also offer "Allow this directory".
  local choices = { 'Allow', 'Deny', 'Allow all for this session' }
  local dir_path = nil
  local tool_label = approvals.tool_label(perm)
  local allow_tool_choice = nil
  local has_diff = kind == 'write' and perm.diff and perm.diff ~= ''
  if kind == 'read' or kind == 'write' then
    local file = perm.path or perm.fileName
    if file and file ~= '' then
      dir_path = vim.fn.fnamemodify(file, ':h')
      if dir_path and dir_path ~= '' and dir_path ~= '.' then
        table.insert(choices, 3, 'Allow this directory (' .. vim.fn.fnamemodify(dir_path, ':~') .. ')')
      end
    end
  elseif tool_label then
    allow_tool_choice = 'Allow ' .. tool_label .. ' for the rest of this session'
    table.insert(choices, 2, allow_tool_choice)
  end
  if has_diff then
    table.insert(choices, 2, 'Show diff')
  end

  active_prompt_id = req_id

  -- Permission picker (extracted so "Show diff" can re-invoke it).
  local function show_permission_picker()
    vim.ui.select(choices, { prompt = prompt_str }, function(choice)
      if not state.session_id or state.session_id ~= sid then
        finish_prompt(req_id)
        defer_prompt(show_next_prompt)
        return
      end
      if not choice then
        finish_prompt(req_id)
        defer_prompt(show_next_prompt)
        return
      end

      if choice == 'Show diff' then
        show_diff_float(perm.diff, function()
          vim.schedule(show_permission_picker)
        end)
        return
      end

      if choice == 'Allow all for this session' then
        -- Approve this request, then switch to approve-all mode.
        answer_permission(sid, req_id, true)
        state.permission_mode = 'approve-all'
        request('POST', '/sessions/' .. sid .. '/permission-mode', { mode = 'approve-all' }, function(_, err)
          if err then
            notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
          else
            notify('Permission mode set to approve-all for this session', vim.log.levels.INFO)
            refresh_statuslines()
          end
        end)
      elseif allow_tool_choice and choice == allow_tool_choice then
        local ok, allow_err = approvals.allow_tool(perm)
        if not ok then
          notify('Failed to allow tool: ' .. tostring(allow_err), vim.log.levels.WARN)
          return
        end
        answer_permission(sid, req_id, true)
        notify('Allowed ' .. tool_label .. ' for this session', vim.log.levels.INFO)
      elseif choice:match('^Allow this directory') then
        answer_permission(sid, req_id, true)
        if dir_path then
          local normalized = approvals.add_directory(dir_path)
          if normalized then
            notify('Added directory: ' .. vim.fn.fnamemodify(normalized, ':~'), vim.log.levels.INFO)
          end
        end
      else
        local approved = (choice == 'Allow')
        answer_permission(sid, req_id, approved)
      end

      finish_prompt(req_id)
      defer_prompt(show_next_prompt)
    end)
  end

  vim.schedule(show_permission_picker)
end

show_next_prompt = function()
  if active_prompt_id then
    return
  end

  local next_prompt = pop_prompt()
  if not next_prompt then
    return
  end

  if next_prompt.kind == 'permission' then
    present_permission_picker(next_prompt.payload)
  elseif next_prompt.kind == 'user_input' then
    present_user_input_picker(next_prompt.payload)
  end
end

local function handle_host_event(event_name, payload)
  log_debug_trace('host.event received event=' .. tostring(event_name) .. ' payload=', payload, { max_len = 2400 })
  if event_name == 'host.user_input_requested' then
    handle_user_input(payload)
    return
  end

  local data = payload and payload.data or {}
  if event_name == 'host.session_attached' then
    clear_reasoning_preview('session attached')
    sync_model_state(data.model, data.reasoningEffort)
    sync_config_counts(data)
    state.session_name = session_names.resolve(data.summary, data.sessionId or state.session_id)
    refresh_statuslines()
    append_entry('system', 'Connected to session ' .. (data.sessionId or state.session_id or '<unknown>'))
  elseif event_name == 'host.session_name_updated' then
    if not session_names.get(data.sessionId or state.session_id) then
      state.session_name = data.name or state.session_name
    end
    refresh_statuslines()
  elseif event_name == 'host.model_changed' then
    sync_model_state(data.model, data.reasoningEffort)
    refresh_statuslines()
    append_entry('system', 'Model changed to ' .. tostring(data.model or '<unknown>'))
  elseif event_name == 'host.session_disconnected' then
    state.instruction_count = 0
    state.agent_count = 0
    state.skill_count = 0
    state.mcp_count = 0
    state.session_name = nil
    state.pending_user_input = nil
    reset_live_activity_state()
    reset_prompt_state()
    refresh_statuslines()
    append_entry('system', 'Session disconnected')
  elseif event_name == 'host.permission_requested' then
    -- In interactive mode, Go sends a request object with an ID; ask the user.
    local req = data.request or {}
    local req_id = req.id
    local mode = data.mode or 'interactive'
    local perm = req.request or {}
    if perm.kind == 'shell' then
      state.pending_tool_detail = extract_shell_command_text(perm)
    elseif perm.kind == 'mcp' or perm.kind == 'custom-tool' then
      state.pending_tool_detail = sanitize_permission_text(perm.toolDescription or perm.intention)
    else
      state.pending_tool_detail = nil
    end
    if mode == 'interactive' and req_id then
      local kind = perm.kind or 'unknown'
      local sid = state.session_id
      local event_session_id = data.sessionId
      if type(event_session_id) == 'string' and sid and event_session_id ~= sid then
        log(
          string.format(
            'host.permission_requested ignored event_session_id=%s active_session_id=%s',
            tostring(event_session_id),
            tostring(sid)
          ),
          vim.log.levels.DEBUG
        )
        return
      end
      local auto_allowed = (kind == 'read' or kind == 'write')
          and approvals.directory_allowed(perm.path or perm.fileName)
        or approvals.tool_allowed(perm)
      if auto_allowed and sid then
        log(
          string.format(
            'host.permission_requested auto-approved kind=%s request_id=%s detail=%s',
            tostring(kind),
            tostring(req_id),
            serialize_log_value(perm, { max_len = 1200 })
          ),
          vim.log.levels.DEBUG
        )
        answer_permission(sid, req_id, true)
        return
      end
      if not enqueue_prompt('permission', payload) then
        log(
          string.format(
            'host.permission_requested dropped duplicate request_id=%s kind=%s',
            tostring(req_id),
            tostring(kind)
          ),
          vim.log.levels.DEBUG
        )
        return
      end
      log(
        string.format(
          'host.permission_requested enqueued request_id=%s kind=%s detail=%s',
          tostring(req_id),
          tostring(kind),
          serialize_log_value(perm, { max_len = 1200 })
        ),
        vim.log.levels.DEBUG
      )
      vim.schedule(show_next_prompt)
    end
    -- Auto-approved/rejected decisions are reflected in the statusline; no notify needed.
  elseif event_name == 'host.permission_decision' then
    -- Silently update the statusline; avoid noisy "Permission approved (autopilot)" spam.
    refresh_statuslines()
  elseif event_name == 'host.permission_mode_changed' then
    state.permission_mode = data.mode or state.permission_mode
    refresh_statuslines()
  elseif event_name == 'host.history_done' then
    state.history_loading = false
    state.history_checkpoint_ids = nil
    state.history_pending_user_entries = {}
    refresh_statuslines()
    reset_frozen_render()
    render_chat()
    scroll_to_bottom()
  end
end

-- Open a diff split for a file that the agent just modified.
-- Uses git to show the diff if the file is tracked; otherwise skips.
local function offer_diff_review(abs_path, rel_path)
  -- Only offer if file is git-tracked (has a HEAD version).
  local wd = working_directory()
  vim.fn.systemlist({ 'git', '-C', wd, 'cat-file', '-e', 'HEAD:' .. rel_path })
  if vim.v.shell_error ~= 0 then
    return -- not tracked or no HEAD version
  end

  vim.ui.select({ 'Open diff', 'Skip' }, {
    prompt = 'Review changes to ' .. rel_path .. '?',
  }, function(choice)
    if choice ~= 'Open diff' then
      return
    end
    -- Get the old (HEAD) version.
    local old_lines = vim.fn.systemlist({ 'git', '-C', wd, 'show', 'HEAD:' .. rel_path })
    if vim.v.shell_error ~= 0 then
      notify('Could not read old version of ' .. rel_path, vim.log.levels.WARN)
      return
    end

    -- Open the current file.
    vim.cmd('tabnew ' .. vim.fn.fnameescape(abs_path))
    vim.cmd('diffthis')

    -- Create a scratch buffer with the old version.
    vim.cmd('vnew')
    local scratch = vim.api.nvim_get_current_buf()
    vim.bo[scratch].buftype = 'nofile'
    vim.bo[scratch].bufhidden = 'wipe'
    vim.bo[scratch].swapfile = false
    vim.api.nvim_buf_set_name(scratch, rel_path .. ' (before agent)')
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, old_lines)
    -- Set filetype from the original for syntax highlighting.
    local ft = vim.filetype.match({ filename = abs_path }) or ''
    if ft ~= '' then
      vim.bo[scratch].filetype = ft
    end
    vim.bo[scratch].modifiable = false
    window.disable_folds(vim.api.nvim_get_current_win())
    vim.cmd('diffthis')
  end)
end

local function read_disk_lines(abs_path)
  local ok, lines = pcall(vim.fn.readfile, abs_path)
  if not ok or type(lines) ~= 'table' then
    return nil, lines
  end
  return lines
end

local function file_change_summary(old_lines, new_lines)
  old_lines = old_lines or {}
  new_lines = new_lines or {}
  local old_text = table.concat(old_lines, '\n')
  local new_text = table.concat(new_lines, '\n')
  if old_text == new_text then
    return 'no content change'
  end

  if not vim.diff then
    local delta = #new_lines - #old_lines
    if delta > 0 then
      return string.format('+%d lines', delta)
    elseif delta < 0 then
      return string.format('-%d lines', math.abs(delta))
    end
    return 'content updated'
  end

  local hunks = vim.diff(old_text, new_text, { result_type = 'indices' }) or {}
  local added = 0
  local removed = 0
  local changed = 0
  for _, hunk in ipairs(hunks) do
    local old_count = tonumber(hunk[2]) or 0
    local new_count = tonumber(hunk[4]) or 0
    changed = changed + math.min(old_count, new_count)
    if new_count > old_count then
      added = added + (new_count - old_count)
    elseif old_count > new_count then
      removed = removed + (old_count - new_count)
    end
  end

  local parts = {}
  if added > 0 then
    parts[#parts + 1] = '+' .. added
  end
  if removed > 0 then
    parts[#parts + 1] = '-' .. removed
  end
  if changed > 0 then
    parts[#parts + 1] = '~' .. changed
  end
  parts[#parts + 1] = string.format('%d %s', #hunks, #hunks == 1 and 'hunk' or 'hunks')
  return table.concat(parts, ' ')
end

local function restore_window_views(bufnr, views)
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) and views[winid] then
      pcall(vim.api.nvim_win_call, winid, function()
        vim.fn.winrestview(views[winid])
      end)
    end
  end
end

local external_reload_prompt = 'The open buffer has been updated externally. Do you want to reload it? (yes/no)'
local buffer_disk_state = {}

local function confirm_external_buffer_reload()
  return vim.fn.confirm(external_reload_prompt, '&yes\n&no', 2) == 1
end

local function file_stat_signature(abs_path)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(abs_path)
  if not stat then
    return nil
  end
  local mtime = stat.mtime or {}
  return table.concat({
    tostring(tonumber(mtime.sec) or 0),
    tostring(tonumber(mtime.nsec) or 0),
    tostring(tonumber(stat.size) or 0),
    tostring(tonumber(stat.mode) or 0),
  }, ':')
end

local function buffer_abs_path(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil
  end
  return vim.fn.fnamemodify(name, ':p')
end

local function remember_buffer_disk_state(bufnr, abs_path)
  abs_path = abs_path or buffer_abs_path(bufnr)
  if not abs_path then
    buffer_disk_state[bufnr] = nil
    return nil
  end
  buffer_disk_state[bufnr] = file_stat_signature(abs_path)
  return buffer_disk_state[bufnr]
end

local function forget_buffer_disk_state(bufnr)
  buffer_disk_state[bufnr] = nil
end

local function remember_open_buffer_disk_state()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.api.nvim_get_option_value('buftype', { buf = bufnr }) == '' then
        remember_buffer_disk_state(bufnr)
      end
    end
  end
end

local function modified_buffer_changed_on_disk(bufnr, abs_path)
  local current = file_stat_signature(abs_path)
  if not current then
    return false
  end
  local known = buffer_disk_state[bufnr]
  if known == nil then
    buffer_disk_state[bufnr] = current
    return false
  end
  return known ~= current
end

local function clean_buffer_changed_on_disk(bufnr, abs_path)
  local current = file_stat_signature(abs_path)
  if not current then
    return false
  end
  local known = buffer_disk_state[bufnr]
  if known == nil then
    buffer_disk_state[bufnr] = current
    return false
  end
  return known ~= current
end

local function reload_buffer_from_disk(bufnr, abs_path, opts)
  opts = opts or {}
  local new_lines, read_err = read_disk_lines(abs_path)
  if not new_lines then
    return nil, read_err
  end

  local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local summary = file_change_summary(old_lines, new_lines)
  local wins = vim.fn.win_findbuf(bufnr)
  local views = {}
  for _, winid in ipairs(wins) do
    if vim.api.nvim_win_is_valid(winid) then
      views[winid] = vim.api.nvim_win_call(winid, function()
        return vim.fn.winsaveview()
      end)
    end
  end

  local modified = vim.bo[bufnr].modified
  if modified and opts.force ~= true then
    return summary, 'buffer has unsaved changes'
  end

  if #wins > 0 then
    local ok, reload_err = pcall(vim.api.nvim_win_call, wins[1], function()
      vim.cmd('silent keepalt keepjumps edit')
    end)
    if not ok then
      return summary, reload_err
    end
    restore_window_views(bufnr, views)
    remember_buffer_disk_state(bufnr, abs_path)
    return summary, nil
  end

  if modified then
    return summary, 'buffer has unsaved changes'
  end

  local was_modifiable = vim.bo[bufnr].modifiable
  local was_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = was_modifiable
  vim.bo[bufnr].readonly = was_readonly
  restore_window_views(bufnr, views)
  remember_buffer_disk_state(bufnr, abs_path)
  return summary, nil
end

local function sanitize_reload_error(err)
  if err == nil then
    return nil
  end

  local line = tostring(err):match('([^\n]+)')
  return line or tostring(err)
end

local function is_expected_reload_attention(err)
  local message = sanitize_reload_error(err)
  if not message then
    return false
  end

  return message == 'buffer has unsaved changes'
    or message:find('E37:', 1, true) ~= nil
    or message:find('No write since last change', 1, true) ~= nil
end

local function reload_attention_level(err)
  if is_expected_reload_attention(err) then
    return vim.log.levels.INFO
  end
  return vim.log.levels.WARN
end

local function check_open_buffers_for_external_changes(opts)
  opts = opts or {}
  local uv = vim.uv or vim.loop
  local target_path = type(opts.path) == 'string' and vim.fn.fnamemodify(opts.path, ':p') or nil
  local target_prefix = type(opts.prefix) == 'string' and vim.fn.fnamemodify(opts.prefix, ':p') or nil
  local skip_path = type(opts.skip_path) == 'string' and vim.fn.fnamemodify(opts.skip_path, ':p') or nil

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.api.nvim_get_option_value('buftype', { buf = bufnr }) == '' then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= '' then
          local path = vim.fn.fnamemodify(name, ':p')
          local matches_path = not target_path or path == target_path
          local matches_prefix = not target_prefix or vim.startswith(path, target_prefix)
          local is_skipped = skip_path and path == skip_path
          if matches_path and matches_prefix and not is_skipped and uv.fs_stat(path) then
            if vim.bo[bufnr].modified then
              if modified_buffer_changed_on_disk(bufnr, path) and confirm_external_buffer_reload() then
                local summary, reload_err = reload_buffer_from_disk(bufnr, path, { force = true })
                if reload_err then
                  notify(
                    'External reload needs attention: '
                      .. vim.fn.fnamemodify(path, ':t')
                      .. ' ('
                      .. tostring(summary or 'content updated')
                      .. '); '
                      .. tostring(sanitize_reload_error(reload_err)),
                    reload_attention_level(reload_err)
                  )
                end
              end
            else
              if clean_buffer_changed_on_disk(bufnr, path) then
                reload_buffer_from_disk(bufnr, path)
              end
            end
          end
        end
      end
    end
  end
end

local open_buffer_refresh_pending = false

local function schedule_open_buffer_refresh()
  if open_buffer_refresh_pending then
    return
  end

  open_buffer_refresh_pending = true
  vim.defer_fn(function()
    open_buffer_refresh_pending = false
    check_open_buffers_for_external_changes()
  end, 60)
end

local function handle_session_event(payload)
  local event_type = payload and payload.type or nil
  local data = payload and payload.data or {}
  log_debug_trace(
    'session.event received type=' .. tostring(event_type) .. ' data=',
    sanitize_session_log_value(data),
    { max_len = 2400, depth = 8 }
  )

  if event_type == 'assistant.message_delta' then
    -- Only redraw statuslines on the busy state *transition* (false→true).
    -- Calling refresh_statuslines() on every token (potentially 50+/sec)
    -- causes continuous Neovim statusline redraws and is a primary CPU hotspot.
    local was_busy = state.chat_busy
    state.chat_busy = true
    if not was_busy then
      refresh_statuslines()
    end
    local pending_turn = state.pending_checkpoint_turn
    if
      not state.history_loading
      and pending_turn
      and pending_turn.session_id == state.session_id
      and type(data.messageId) == 'string'
      and data.messageId ~= ''
    then
      pending_turn.assistant_message_id = data.messageId
    end
    local entry, idx, key = ensure_assistant_entry(data.messageId)
    local delta = data.deltaContent or ''

    local previous_content = entry.content or ''
    entry.content = merge_assistant_delta_content(previous_content, delta, {
      message_id = data.messageId,
      entry_key = key,
      entry_index = idx,
    })
    log(
      string.format(
        'assistant.message_delta appended message_id=%s key=%s idx=%s result_len=%d boundary={%s} content=%s',
        tostring(data.messageId or '<none>'),
        tostring(key or '<none>'),
        tostring(idx or '<none>'),
        #(entry.content or ''),
        preview_delta_boundary(previous_content, delta),
        preview_log_text(entry.content)
      ),
      vim.log.levels.DEBUG
    )
    if idx then
      stream_update(entry, idx)
    else
      schedule_render()
    end
    return
  end

  if event_type == 'user.message' then
    -- Only add during history replay; during active conversation the input
    -- handler already called append_entry('user', ...) before sending.
    if state.history_loading then
      local content = type(data.content) == 'string' and data.content or ''
      if content ~= '' then
        local entry_index = append_entry('user', content)
        state.history_pending_user_entries[#state.history_pending_user_entries + 1] = {
          entry_index = entry_index,
          content = content,
        }
      end
    else
      log(
        string.format('user.message ignored during live session message_id=%s', tostring(data.messageId or '<none>')),
        vim.log.levels.DEBUG
      )
    end
    return
  end

  if event_type == 'assistant.message' then
    local entry, idx, key = ensure_assistant_entry(data.messageId)
    local first_message_for_entry = (entry.content or '') == ''
    local had_stream_start = state.stream_line_start ~= nil
    if type(data.content) == 'string' then
      entry.content = merge_assistant_message_content(entry.content, data.content, {
        message_id = data.messageId,
        entry_key = key,
        entry_index = idx,
      })
    end
    if state.history_loading and first_message_for_entry then
      assign_history_checkpoint_id(data.messageId)
    elseif not state.history_loading then
      local pending_turn = state.pending_checkpoint_turn
      if
        pending_turn
        and pending_turn.session_id == state.session_id
        and type(data.messageId) == 'string'
        and data.messageId ~= ''
      then
        pending_turn.assistant_message_id = data.messageId
      end
    end
    log(
      string.format(
        'assistant.message preserving stream start message_id=%s idx=%s stream_line_start=%s had_stream_start=%s',
        tostring(data.messageId or '<none>'),
        tostring(idx or '<none>'),
        tostring(state.stream_line_start or '<none>'),
        tostring(had_stream_start)
      ),
      vim.log.levels.DEBUG
    )
    schedule_render()
    return
  end

  if state.history_loading then
    if
      event_type == 'subagent.started'
      or event_type == 'subagent.completed'
      or event_type == 'subagent.failed'
      or event_type == 'assistant.intent'
      or event_type == 'tool.execution_start'
      or event_type == 'tool.execution_complete'
      or event_type == 'assistant.reasoning_delta'
    then
      log(
        string.format('session.event skipped during history replay type=%s', tostring(event_type)),
        vim.log.levels.DEBUG
      )
      return
    end
  end

  if event_type == 'assistant.turn_end' then
    if not state.history_loading then
      local pending_turn = state.pending_checkpoint_turn
      if pending_turn and pending_turn.session_id == state.session_id then
        log(
          string.format(
            'assistant.turn_end creating checkpoint session_id=%s entry_index=%s message_id=%s prompt=%s',
            tostring(state.session_id or '<none>'),
            tostring(pending_turn.entry_index or '<none>'),
            tostring(pending_turn.assistant_message_id or '<none>'),
            preview_log_text(pending_turn.prompt or '', 200)
          ),
          vim.log.levels.DEBUG
        )
        state.pending_checkpoint_turn = nil
        state.pending_checkpoint_ops = state.pending_checkpoint_ops + 1
        checkpoints.create(state.session_id, pending_turn.prompt, function(checkpoint_err)
          state.pending_checkpoint_ops = math.max((tonumber(state.pending_checkpoint_ops) or 1) - 1, 0)
          if checkpoint_err then
            notify('Checkpoint unavailable: ' .. checkpoint_err, vim.log.levels.WARN)
          end
          refresh_statuslines()
          render_chat()
        end, {
          assistant_message_id = pending_turn.assistant_message_id,
          entry_index = pending_turn.entry_index,
        })
      end
    end
    reset_pending_assistant_entry()
    clear_reasoning_preview('turn end')
    state.stream_line_start = nil
    state.chat_busy = false
    complete_overlay_tool(state.active_tool_run_id)
    state.recent_activity_lines = {}
    state.active_tool = nil
    state.active_tool_run_id = nil
    state.active_tool_detail = nil
    state.pending_tool_detail = nil
    state.active_turn_assistant_index = nil
    state.active_turn_assistant_message_id = nil
    state.current_intent = nil
    refresh_statuslines()
    refresh_reasoning_overlay()
    render_chat() -- immediate full render on turn completion
    schedule_open_buffer_refresh()
    return
  end

  if event_type == 'subagent.started' then
    set_background_task('subagent:' .. (data.toolCallId or ''), {
      kind = 'subagent',
      status = 'running',
      title = first_non_empty(data.agentDisplayName, data.agentName, 'Subagent'),
      description = data.agentDescription,
    })
    return
  end

  if event_type == 'subagent.completed' then
    set_background_task('subagent:' .. (data.toolCallId or ''), {
      kind = 'subagent',
      status = 'completed',
    })
    schedule_open_buffer_refresh()
    return
  end

  if event_type == 'subagent.failed' then
    set_background_task('subagent:' .. (data.toolCallId or ''), {
      kind = 'subagent',
      status = 'failed',
    })
    schedule_open_buffer_refresh()
    return
  end

  if event_type == 'assistant.intent' then
    state.current_intent = data.intent or nil
    refresh_statuslines()
    refresh_reasoning_overlay()
    return
  end

  if event_type == 'assistant.turn_start' then
    clear_reasoning_preview('turn start')
    state.active_tool = nil
    state.active_tool_run_id = nil
    state.active_tool_detail = nil
    state.current_intent = nil
    refresh_statuslines()
    refresh_reasoning_overlay()
    return
  end

  if event_type == 'tool.execution_start' then
    log(
      string.format(
        'tool.execution_start tool=%s detail=%s payload=%s',
        tostring(data.toolName or '<none>'),
        serialize_log_value(extract_shell_tool_detail(data.toolName, data), { max_len = 800 }),
        serialize_log_value(data, { max_len = 1600 })
      ),
      vim.log.levels.DEBUG
    )
    state.chat_busy = true
    state.active_tool = data.toolName or nil
    state.active_tool_detail = extract_shell_tool_detail(state.active_tool, data)
    state.active_tool_run_id = enqueue_overlay_tool(state.active_tool, state.active_tool_detail)
    state.pending_tool_detail = nil
    refresh_statuslines()
    refresh_reasoning_overlay()
    return
  end

  if event_type == 'tool.execution_complete' then
    log(
      string.format(
        'tool.execution_complete tool=%s payload=%s',
        tostring(state.active_tool or data.toolName or '<none>'),
        serialize_log_value(data, { max_len = 1600 })
      ),
      vim.log.levels.DEBUG
    )
    complete_overlay_tool(state.active_tool_run_id)
    state.active_tool = nil
    state.active_tool_run_id = nil
    state.active_tool_detail = nil
    refresh_statuslines()
    refresh_reasoning_overlay()
    return
  end

  if event_type == 'session.model_change' then
    sync_model_state(data.model or data.newModel, data.reasoningEffort or data.newReasoningEffort)
    refresh_statuslines()
    return
  end

  if event_type == 'session.usage_info' then
    state.context_tokens = data.currentTokens
    state.context_limit = data.tokenLimit
    refresh_statuslines()
    return
  end

  if event_type == 'assistant.reasoning_delta' then
    local was_busy = state.chat_busy
    state.chat_busy = true
    if not was_busy then
      refresh_statuslines()
    end
    local _, _, key = ensure_assistant_entry(data.messageId)
    local delta = first_non_empty(data.deltaContent, data.content, data.delta, data.text) or ''
    log(
      string.format(
        'reasoning_delta received message_id=%s key=%s len=%d chat_open=%s enabled=%s',
        tostring(data.messageId or '<none>'),
        tostring(key or '<none>'),
        #delta,
        tostring(state.chat_bufnr ~= nil and vim.api.nvim_buf_is_valid(state.chat_bufnr)),
        tostring((((state.config or {}).chat or {}).reasoning or {}).enabled == true)
      ),
      vim.log.levels.DEBUG
    )
    append_reasoning_delta(key, delta)
    return
  end

  if event_type == 'assistant.streaming_delta' then
    log(
      'assistant.streaming_delta ignored payload=' .. serialize_log_value(data, { max_len = 1600 }),
      vim.log.levels.DEBUG
    )
    return
  end

  if event_type == 'system.notification' then
    local kind = data.kind or {}
    local key = first_non_empty(kind.agentId, kind.entryId)
    if not key then
      log(
        'system.notification ignored without key payload=' .. serialize_log_value(data, { max_len = 1600 }),
        vim.log.levels.DEBUG
      )
      return
    end

    if kind.type == 'agent_idle' then
      set_background_task('background:' .. key, {
        kind = 'background',
        status = 'idle',
        title = first_non_empty(kind.description, kind.summary, kind.agentType, 'Background agent'),
        description = kind.description,
      })
    elseif kind.type == 'new_inbox_message' then
      set_background_task('background:' .. key, {
        kind = 'background',
        status = 'inbox',
        title = first_non_empty(kind.description, kind.summary, kind.agentType, 'Background agent'),
        description = kind.description,
      })
    elseif kind.type == 'agent_completed' then
      set_background_task('background:' .. key, {
        kind = 'background',
        status = kind.status == 'failed' and 'failed' or 'completed',
      })
      schedule_open_buffer_refresh()
    end
    return
  end

  if event_type == 'session.workspace_file_changed' then
    local op = data.operation or 'update'
    local rel_path = data.path or ''
    if rel_path == '' then
      log(
        'session.workspace_file_changed ignored without path payload=' .. serialize_log_value(data, { max_len = 1600 }),
        vim.log.levels.DEBUG
      )
      return
    end

    -- Resolve to absolute path relative to working directory.
    local wd = working_directory()
    local abs_path = vim.fn.fnamemodify(wd .. '/' .. rel_path, ':p')

    state.pending_workspace_updates = state.pending_workspace_updates + 1
    refresh_statuslines()
    vim.schedule(function()
      -- Find any loaded buffer for this file.
      local bufnr_match = nil
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          local bname = vim.api.nvim_buf_get_name(b)
          if bname ~= '' and vim.fn.fnamemodify(bname, ':p') == abs_path then
            bufnr_match = b
            break
          end
        end
      end

      if op == 'create' then
        log(string.format('workspace change create path=%s abs=%s', rel_path, abs_path), vim.log.levels.DEBUG)
        notify('Agent created: ' .. rel_path, vim.log.levels.INFO)
      elseif op == 'update' and bufnr_match then
        local summary, reload_err = reload_buffer_from_disk(bufnr_match, abs_path)
        if reload_err == 'buffer has unsaved changes' then
          if confirm_external_buffer_reload() then
            summary, reload_err = reload_buffer_from_disk(bufnr_match, abs_path, { force = true })
          else
            reload_err = 'user declined reload'
          end
        end
        if reload_err then
          log(
            string.format(
              'workspace change update reload skipped path=%s summary=%s error=%s',
              rel_path,
              tostring(summary or '<none>'),
              tostring(sanitize_reload_error(reload_err))
            ),
            reload_attention_level(reload_err)
          )
          if reload_err ~= 'user declined reload' then
            notify(
              'Agent updated on disk: '
                .. rel_path
                .. ' ('
                .. tostring(summary or 'content updated')
                .. '); reload skipped: '
                .. tostring(sanitize_reload_error(reload_err)),
              reload_attention_level(reload_err)
            )
          end
        else
          log(
            string.format(
              'workspace change update reloaded path=%s summary=%s',
              rel_path,
              tostring(summary or '<none>')
            ),
            vim.log.levels.DEBUG
          )
          notify(
            'Agent reloaded: ' .. rel_path .. ' (' .. tostring(summary or 'content updated') .. ')',
            vim.log.levels.INFO
          )
        end
        -- Offer diff review if the file is tracked by git.
        if state.config.chat.diff_review ~= false and not reload_err then
          offer_diff_review(abs_path, rel_path)
        end
      else
        log(
          string.format('workspace change update without open buffer path=%s abs=%s', rel_path, abs_path),
          vim.log.levels.DEBUG
        )
        notify('Agent updated: ' .. rel_path, vim.log.levels.INFO)
      end
      check_open_buffers_for_external_changes({ skip_path = abs_path })
      state.pending_workspace_updates = math.max((tonumber(state.pending_workspace_updates) or 1) - 1, 0)
      refresh_statuslines()
    end)
    return
  end

  if event_type == 'error' then
    log('session.error payload=' .. serialize_log_value(data, { max_len = 2400 }), vim.log.levels.WARN)
    reset_pending_assistant_entry()
    clear_reasoning_preview('error')
    state.stream_line_start = nil
    state.chat_busy = false
    complete_overlay_tool(state.active_tool_run_id)
    state.recent_activity_lines = {}
    state.active_tool = nil
    state.active_tool_run_id = nil
    state.active_tool_detail = nil
    state.pending_tool_detail = nil
    state.active_turn_assistant_index = nil
    state.active_turn_assistant_message_id = nil
    state.current_intent = nil
    refresh_statuslines()
    refresh_reasoning_overlay()
    append_entry('error', vim.inspect(data))
    return
  end

  log(
    'session.event unhandled type=' .. tostring(event_type) .. ' data=' .. serialize_log_value(data, { max_len = 1600 }),
    vim.log.levels.DEBUG
  )
end

local function flush_sse_event()
  local raw_data = table.concat(state.sse_event.data, '\n')
  local event_name = state.sse_event.event or 'message'
  state.sse_event = { event = 'message', data = {} }

  if raw_data == '' then
    return
  end

  log_session_event_payload(event_name, raw_data)
  local payload, decode_err = decode_json(raw_data, { log = false })
  if not payload then
    log(
      string.format(
        'sse.event decode failed event=%s error=%s data=%s',
        tostring(event_name),
        tostring(decode_err),
        serialize_log_value(raw_data, { max_len = 3200 })
      ),
      vim.log.levels.WARN
    )
    append_entry('error', 'Failed to decode event ' .. event_name .. ': ' .. tostring(decode_err or raw_data))
    return
  end

  if event_name == 'session.event' then
    handle_session_event(payload)
    return
  end

  handle_host_event(event_name, payload)
end

local function consume_sse_line(line)
  if line == '' then
    flush_sse_event()
    return
  end

  if line:sub(1, 1) == ':' then
    return
  end

  local field, value = line:match('^([^:]+):%s?(.*)$')
  if not field then
    return
  end

  if field == 'event' then
    state.sse_event.event = value
  elseif field == 'data' then
    table.insert(state.sse_event.data, value)
  end
end

local function handle_sse_chunk(data)
  if not data or vim.tbl_isempty(data) then
    return
  end

  data[1] = state.sse_partial .. data[1]
  state.sse_partial = table.remove(data) or ''
  for _, line in ipairs(data) do
    consume_sse_line(line)
  end
end

function M.stop_event_stream()
  if state.events_job_id then
    log(string.format('sse.stream stop job_id=%s', tostring(state.events_job_id)), vim.log.levels.DEBUG)
    intentionally_stopped_event_jobs[state.events_job_id] = true
    pcall(vim.fn.jobstop, state.events_job_id)
    state.events_job_id = nil
  end
  state.sse_partial = ''
  state.sse_event = { event = 'message', data = {} }
end

function M.start_event_stream(session_id)
  M.stop_event_stream()
  state.sse_event = { event = 'message', data = {} }
  state.sse_partial = ''
  reset_live_activity_state()
  state.history_loading = true -- suppress rendering until host.history_done arrives
  state.history_pending_user_entries = {}
  preload_history_checkpoint_ids(session_id)
  refresh_statuslines()

  local args = {
    state.config.curl_bin,
    '-sS',
    '-N',
    '-H',
    'Accept: text/event-stream',
    build_url(string.format('/sessions/%s/events?history=true', session_id)),
  }
  log(
    string.format(
      'sse.stream start session_id=%s url=%s',
      tostring(session_id or '<none>'),
      build_url(string.format('/sessions/%s/events?history=true', session_id))
    ),
    vim.log.levels.DEBUG
  )

  -- Batch incoming SSE chunks to avoid flooding the Neovim event loop.
  -- on_stdout fires for every curl output chunk (potentially hundreds/sec);
  -- we accumulate chunks and drain them on a debounced timer.
  local uv = vim.uv or vim.loop
  local sse_batch = {}
  local sse_stderr = {}
  local sse_batch_timer = uv.new_timer()
  local sse_batch_pending = false
  local SSE_BATCH_MS = 50

  local function drain_sse_batch()
    sse_batch_pending = false
    local chunks = sse_batch
    sse_batch = {}
    for _, chunk in ipairs(chunks) do
      handle_sse_chunk(chunk)
    end
  end

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      table.insert(sse_batch, data)
      if not sse_batch_pending then
        sse_batch_pending = true
        sse_batch_timer:start(SSE_BATCH_MS, 0, vim.schedule_wrap(drain_sse_batch))
      end
    end,
    on_stderr = function(_, data)
      if data and not vim.tbl_isempty(data) then
        for _, line in ipairs(data) do
          if type(line) == 'string' and line ~= '' then
            table.insert(sse_stderr, line)
            log('sse.stream stderr line=' .. serialize_log_value(line, { max_len = 1000 }), vim.log.levels.WARN)
          end
        end
      end
    end,
    on_exit = function(exited_job_id, code)
      -- Drain any remaining chunks before handling exit.
      sse_batch_timer:stop()
      pcall(function()
        sse_batch_timer:close()
      end)
      vim.schedule(function()
        local stopped_intentionally = intentionally_stopped_event_jobs[exited_job_id] == true
        intentionally_stopped_event_jobs[exited_job_id] = nil
        -- Process any remaining buffered chunks.
        for _, chunk in ipairs(sse_batch) do
          handle_sse_chunk(chunk)
        end
        sse_batch = {}
        if state.events_job_id == exited_job_id then
          state.events_job_id = nil
        end
        M._handle_event_stream_exit(session_id, code, table.concat(sse_stderr, '\n'), {
          stopped_intentionally = stopped_intentionally,
        })
      end)
    end,
  })
  if job_id <= 0 then
    pcall(function()
      sse_batch_timer:close()
    end)
    state.history_loading = false
    state.history_pending_user_entries = {}
    log(
      string.format('sse.stream failed to start session_id=%s', tostring(session_id or '<none>')),
      vim.log.levels.WARN
    )
    append_entry('error', 'failed to start event stream')
    return
  end
  log(
    string.format('sse.stream started session_id=%s job_id=%s', tostring(session_id or '<none>'), tostring(job_id)),
    vim.log.levels.DEBUG
  )
  state.events_job_id = job_id
end

function M.reload_session_history(session_id, callback)
  callback = callback or function() end
  session_id = session_id or state.session_id
  if not session_id then
    callback('No active session')
    return
  end

  clear_transcript()
  state.history_loading = true
  state.history_pending_user_entries = {}
  preload_history_checkpoint_ids(session_id)
  request('GET', string.format('/sessions/%s/messages', session_id), nil, function(response, err)
    if err then
      log(
        string.format(
          'session.history reload failed session_id=%s error=%s',
          tostring(session_id),
          serialize_log_value(err, { max_len = 1200 })
        ),
        vim.log.levels.WARN
      )
      state.history_loading = false
      state.history_checkpoint_ids = nil
      state.history_pending_user_entries = {}
      callback(err)
      return
    end

    for _, event in ipairs((response and response.events) or {}) do
      handle_session_event(event)
    end

    log(
      string.format(
        'session.history reloaded session_id=%s event_count=%d',
        tostring(session_id),
        #((response and response.events) or {})
      ),
      vim.log.levels.DEBUG
    )

    state.history_loading = false
    state.history_checkpoint_ids = nil
    state.history_pending_user_entries = {}
    reset_frozen_render()
    render_chat()
    scroll_to_bottom()
    callback(nil, #((response and response.events) or {}))
  end)
end

M.show_user_input_picker = show_user_input_picker
M.handle_user_input = handle_user_input
M.handle_host_event = handle_host_event
M.check_open_buffers_for_external_changes = check_open_buffers_for_external_changes
M.confirm_external_buffer_reload = confirm_external_buffer_reload
M.remember_buffer_disk_state = remember_buffer_disk_state
M.remember_open_buffer_disk_state = remember_open_buffer_disk_state
M.forget_buffer_disk_state = forget_buffer_disk_state
M.offer_diff_review = offer_diff_review

--- List all uncommitted changed files and open vimdiff for the selected one.
--- Shows a picker of files with unstaged/staged changes relative to HEAD.
local function review_diff()
  local wd = working_directory()
  -- Get files with changes (staged + unstaged) relative to HEAD.
  local changed = vim.fn.systemlist({ 'git', '-C', wd, 'diff', '--name-only', 'HEAD' })
  if vim.v.shell_error ~= 0 or #changed == 0 or (changed[1] or '') == '' then
    -- Also check for untracked files that were newly created.
    local untracked = vim.fn.systemlist({ 'git', '-C', wd, 'ls-files', '--others', '--exclude-standard' })
    if vim.v.shell_error ~= 0 or #untracked == 0 or (untracked[1] or '') == '' then
      notify('No uncommitted changes found', vim.log.levels.INFO)
      return
    end
    changed = untracked
  end
  -- Filter out empty strings.
  changed = vim.tbl_filter(function(f)
    return f and f ~= ''
  end, changed)
  if #changed == 0 then
    notify('No uncommitted changes found', vim.log.levels.INFO)
    return
  end

  vim.ui.select(changed, { prompt = 'Review diff for:' }, function(choice)
    if not choice then
      return
    end
    local abs_path = vim.fn.fnamemodify(wd .. '/' .. choice, ':p')
    -- Check if file is tracked (has a HEAD version) for vimdiff.
    vim.fn.systemlist({ 'git', '-C', wd, 'cat-file', '-e', 'HEAD:' .. choice })
    if vim.v.shell_error ~= 0 then
      -- New untracked file — just open it.
      vim.cmd('tabnew ' .. vim.fn.fnameescape(abs_path))
      notify('New file (no HEAD version): ' .. choice, vim.log.levels.INFO)
      return
    end
    -- Get the old (HEAD) version and open vimdiff.
    local old_lines = vim.fn.systemlist({ 'git', '-C', wd, 'show', 'HEAD:' .. choice })
    if vim.v.shell_error ~= 0 then
      notify('Could not read old version of ' .. choice, vim.log.levels.WARN)
      return
    end
    vim.cmd('tabnew ' .. vim.fn.fnameescape(abs_path))
    vim.cmd('diffthis')
    vim.cmd('vnew')
    local scratch = vim.api.nvim_get_current_buf()
    vim.bo[scratch].buftype = 'nofile'
    vim.bo[scratch].bufhidden = 'wipe'
    vim.bo[scratch].swapfile = false
    vim.api.nvim_buf_set_name(scratch, choice .. ' (HEAD)')
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, old_lines)
    local ft = vim.filetype.match({ filename = abs_path }) or ''
    if ft ~= '' then
      vim.bo[scratch].filetype = ft
    end
    vim.bo[scratch].modifiable = false
    window.disable_folds(vim.api.nvim_get_current_win())
    vim.cmd('diffthis')
  end)
end

M.review_diff = review_diff
M.handle_session_event = handle_session_event
M.flush_sse_event = flush_sse_event
M.consume_sse_line = consume_sse_line
M.handle_sse_chunk = handle_sse_chunk

return M
