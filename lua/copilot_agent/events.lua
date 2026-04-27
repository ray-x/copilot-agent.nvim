-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- SSE event stream: parser, host/session event handlers.

local utils = require('copilot_agent.utils')
local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')

local state = cfg.state
local notify = cfg.notify
local notify_transient = cfg.notify_transient

local decode_json = http.decode_json
local raw_request = http.raw_request
local request = http.request
local build_url = http.build_url

local working_directory = service.working_directory

local refresh_statuslines = sl.refresh_statuslines

local render_chat = render.render_chat
local schedule_render = render.schedule_render
local stream_update = render.stream_update
local append_entry = render.append_entry
local ensure_assistant_entry = render.ensure_assistant_entry
local start_thinking_spinner = render.start_thinking_spinner
local stop_thinking_spinner = render.stop_thinking_spinner
local scroll_to_bottom = render.scroll_to_bottom

local is_thinking_content = utils.is_thinking_content

local M = {}

local function show_user_input_picker(payload)
  local request_payload = payload and payload.data and payload.data.request or nil
  if type(request_payload) ~= 'table' or type(request_payload.id) ~= 'string' then
    return
  end

  local session_id = payload.data.sessionId or state.session_id
  local choices = type(request_payload.choices) == 'table' and request_payload.choices or {}
  local allow_freeform = request_payload.allowFreeform ~= false

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
  end

  local function ask_freeform()
    vim.ui.input({ prompt = request_payload.question .. ' ' }, function(input)
      if input == nil or input == '' then
        notify('Input dismissed — use :CopilotAgentRetryInput to try again', vim.log.levels.WARN)
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
  end
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

local function handle_host_event(event_name, payload)
  if event_name == 'host.user_input_requested' then
    handle_user_input(payload)
    return
  end

  local data = payload and payload.data or {}
  if event_name == 'host.session_attached' then
    if data.summary and data.summary ~= '' then
      state.session_name = data.summary
      refresh_statuslines()
    end
    append_entry('system', 'Connected to session ' .. (data.sessionId or state.session_id or '<unknown>'))
  elseif event_name == 'host.session_name_updated' then
    state.session_name = data.name or state.session_name
    refresh_statuslines()
  elseif event_name == 'host.model_changed' then
    append_entry('system', 'Model changed to ' .. tostring(data.model or '<unknown>'))
  elseif event_name == 'host.permission_requested' then
    -- In interactive mode, Go sends a request object with an ID; ask the user.
    local req = data.request or {}
    local req_id = req.id
    local mode = data.mode or 'interactive'
    if mode == 'interactive' and req_id then
      local perm = req.request or {}
      local kind = perm.kind or 'unknown'
      local parts = {}

      -- Build a descriptive prompt based on the permission kind.
      if kind == 'shell' then
        local cmd = perm.fullCommandText or perm.intention or '(shell command)'
        table.insert(parts, 'Run shell command')
        table.insert(parts, cmd)
      elseif kind == 'write' then
        local file = perm.fileName or perm.path or '(unknown file)'
        table.insert(parts, 'Write file')
        table.insert(parts, file)
      elseif kind == 'read' then
        local file = perm.path or perm.fileName or '(unknown path)'
        table.insert(parts, 'Read')
        table.insert(parts, file)
      elseif kind == 'mcp' or kind == 'custom-tool' then
        local tool = perm.toolTitle or perm.toolName or 'unknown tool'
        local server = perm.serverName or ''
        table.insert(parts, tool)
        if server ~= '' then
          table.insert(parts, '(' .. server .. ')')
        end
        if perm.toolDescription and perm.toolDescription ~= '' then
          table.insert(parts, '— ' .. perm.toolDescription)
        end
      elseif kind == 'url' then
        local url = perm.url or '(unknown URL)'
        table.insert(parts, 'Fetch URL')
        table.insert(parts, url)
      elseif kind == 'memory' then
        local action = perm.action or 'access'
        table.insert(parts, 'Memory ' .. tostring(action))
        if perm.fact then
          table.insert(parts, perm.fact)
        end
      elseif kind == 'hook' then
        table.insert(parts, 'Hook')
        if perm.hookMessage then
          table.insert(parts, perm.hookMessage)
        end
      else
        local tool = perm.toolTitle or perm.toolName or kind
        table.insert(parts, tool)
      end

      -- Append intention if present and not already shown.
      if perm.intention and kind ~= 'shell' then
        table.insert(parts, '— ' .. perm.intention)
      end

      local prompt_str = 'Allow: ' .. table.concat(parts, ' ')

      -- Build choices: Allow, Deny, Allow all for session.
      -- For read/write with a file path, also offer "Allow this directory".
      local choices = { 'Allow', 'Deny', 'Allow all for this session' }
      local dir_path = nil
      local has_diff = kind == 'write' and perm.diff and perm.diff ~= ''
      if kind == 'read' or kind == 'write' then
        local file = perm.path or perm.fileName
        if file and file ~= '' then
          dir_path = vim.fn.fnamemodify(file, ':h')
          if dir_path and dir_path ~= '' and dir_path ~= '.' then
            table.insert(choices, 3, 'Allow this directory (' .. vim.fn.fnamemodify(dir_path, ':~') .. ')')
          end
        end
      end
      if has_diff then
        table.insert(choices, 2, 'Show diff')
      end

      -- Show the diff in a floating scratch buffer.
      local function show_diff_float(diff_text, after_close)
        local lines = vim.split(diff_text, '\n', { plain = true })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].buftype = 'nofile'
        vim.bo[buf].bufhidden = 'wipe'
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = 'diff'
        vim.bo[buf].modifiable = false
        local width = math.min(math.floor(vim.o.columns * 0.8), 120)
        local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
        local win = vim.api.nvim_open_win(buf, true, {
          relative = 'editor',
          width = width,
          height = height,
          row = math.floor((vim.o.lines - height) / 2),
          col = math.floor((vim.o.columns - width) / 2),
          style = 'minimal',
          border = 'rounded',
          title = ' Proposed changes ',
          title_pos = 'center',
        })
        -- Close on q or <Esc>, then re-show the permission picker.
        local function close()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
          if after_close then
            after_close()
          end
        end
        vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
        vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true })
      end

      -- Permission picker (extracted so "Show diff" can re-invoke it).
      local function show_permission_picker()
        vim.ui.select(choices, { prompt = prompt_str }, function(choice)
          if not state.session_id then
            return
          end
          if not choice then
            return
          end

          local sid = state.session_id

          if choice == 'Show diff' then
            show_diff_float(perm.diff, function()
              vim.schedule(show_permission_picker)
            end)
            return
          end

          if choice == 'Allow all for this session' then
            -- Approve this request, then switch to approve-all mode.
            request('POST', '/sessions/' .. sid .. '/permission/' .. req_id, { approved = true }, function(_, err)
              if err then
                notify('Failed to send permission answer: ' .. tostring(err), vim.log.levels.WARN)
              end
            end)
            state.permission_mode = 'approve-all'
            request('POST', '/sessions/' .. sid .. '/permission-mode', { mode = 'approve-all' }, function(_, err)
              if err then
                notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
              else
                notify('Permission mode set to approve-all for this session', vim.log.levels.INFO)
                refresh_statuslines()
              end
            end)
          elseif choice:match('^Allow this directory') then
            -- Approve this request, then send /add-dir via the captured session.
            request('POST', '/sessions/' .. sid .. '/permission/' .. req_id, { approved = true }, function(_, err)
              if err then
                notify('Failed to send permission answer: ' .. tostring(err), vim.log.levels.WARN)
              end
            end)
            if dir_path and sid then
              request('POST', '/sessions/' .. sid .. '/messages', { message = '/add-dir ' .. dir_path }, function(_, add_err)
                if add_err then
                  notify('Failed to add directory: ' .. tostring(add_err), vim.log.levels.WARN)
                else
                  notify('Added directory: ' .. dir_path, vim.log.levels.INFO)
                end
              end)
            end
          else
            local approved = (choice == 'Allow')
            request('POST', '/sessions/' .. sid .. '/permission/' .. req_id, { approved = approved }, function(_, err)
              if err then
                notify('Failed to send permission answer: ' .. tostring(err), vim.log.levels.WARN)
              end
            end)
          end
        end)
      end

      vim.schedule(show_permission_picker)
    else
      notify_transient('Permission requested; mode=' .. tostring(mode), vim.log.levels.INFO)
    end
  elseif event_name == 'host.permission_decision' then
    notify_transient('Permission ' .. tostring(data.decision or 'unknown') .. ' (' .. tostring(data.mode or '') .. ')', vim.log.levels.INFO)
  elseif event_name == 'host.permission_mode_changed' then
    state.permission_mode = data.mode or state.permission_mode
    refresh_statuslines()
  elseif event_name == 'host.session_disconnected' then
    state.session_name = nil
    state.pending_user_input = nil
    append_entry('system', 'Session disconnected')
  elseif event_name == 'host.history_done' then
    state.history_loading = false
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
    vim.cmd('diffthis')
  end)
end

local function handle_session_event(payload)
  local event_type = payload and payload.type or nil
  local data = payload and payload.data or {}

  if event_type == 'assistant.message_delta' then
    -- Only redraw statuslines on the busy state *transition* (false→true).
    -- Calling refresh_statuslines() on every token (potentially 50+/sec)
    -- causes continuous Neovim statusline redraws and is a primary CPU hotspot.
    local was_busy = state.chat_busy
    state.chat_busy = true
    if not was_busy then
      refresh_statuslines()
    end
    local key = data.messageId or ('assistant-' .. tostring(#state.entries + 1))
    local entry = ensure_assistant_entry(data.messageId)
    local delta = data.deltaContent or ''

    -- Always discard thinking-only tokens (dots, whitespace) regardless of
    -- whether real content has already accumulated. Start the spinner on the
    -- first such token so the user sees activity.
    if is_thinking_content(delta) then
      if state.thinking_entry_key == nil and is_thinking_content(entry.content) then
        start_thinking_spinner(key)
      end
      -- Spinner timer drives render; no buffer update needed.
      return
    end

    -- Real content: stop spinner, clear any accumulated dots, then append.
    if state.thinking_entry_key ~= nil then
      stop_thinking_spinner()
      if is_thinking_content(entry.content) then
        entry.content = ''
      end
    end
    entry.content = (entry.content or '') .. delta
    local idx = state.assistant_entries[key]
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
        append_entry('user', content)
      end
    end
    return
  end

  if event_type == 'assistant.message' then
    local entry = ensure_assistant_entry(data.messageId)
    if type(data.content) == 'string' and not is_thinking_content(data.content) then
      stop_thinking_spinner()
      entry.content = data.content
    end
    state.stream_line_start = nil
    schedule_render()
    return
  end

  if event_type == 'assistant.turn_end' then
    stop_thinking_spinner()
    state.stream_line_start = nil
    state.chat_busy = false
    state.active_tool = nil
    state.current_intent = nil
    refresh_statuslines()
    render_chat() -- immediate full render on turn completion
    return
  end

  if event_type == 'assistant.intent' then
    state.current_intent = data.intent or nil
    refresh_statuslines()
    return
  end

  if event_type == 'assistant.turn_start' then
    state.active_tool = nil
    state.current_intent = nil
    refresh_statuslines()
    return
  end

  if event_type == 'tool.execution_start' then
    state.active_tool = data.toolName or nil
    refresh_statuslines()
    return
  end

  if event_type == 'tool.execution_complete' then
    state.active_tool = nil
    refresh_statuslines()
    return
  end

  if event_type == 'session.model_change' then
    state.current_model = data.model or data.newModel or nil
    refresh_statuslines()
    return
  end

  if event_type == 'session.usage_info' then
    state.context_tokens = data.currentTokens
    state.context_limit = data.tokenLimit
    refresh_statuslines()
    return
  end

  if event_type == 'assistant.reasoning_delta' or event_type == 'assistant.streaming_delta' then
    return
  end

  if event_type == 'session.workspace_file_changed' then
    local op = data.operation or 'update'
    local rel_path = data.path or ''
    if rel_path == '' then
      return
    end

    -- Resolve to absolute path relative to working directory.
    local wd = working_directory()
    local abs_path = vim.fn.fnamemodify(wd .. '/' .. rel_path, ':p')

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
        notify('Agent created: ' .. rel_path, vim.log.levels.INFO)
      elseif op == 'update' and bufnr_match then
        -- Reload the buffer from disk.
        vim.api.nvim_buf_call(bufnr_match, function()
          vim.cmd('silent! checktime')
        end)
        notify('Agent updated: ' .. rel_path, vim.log.levels.INFO)
        -- Offer diff review if the file is tracked by git.
        if state.config.chat.diff_review ~= false then
          offer_diff_review(abs_path, rel_path)
        end
      else
        notify('Agent updated: ' .. rel_path, vim.log.levels.INFO)
      end
    end)
    return
  end

  if event_type == 'error' then
    stop_thinking_spinner()
    state.stream_line_start = nil
    state.chat_busy = false
    refresh_statuslines()
    append_entry('error', vim.inspect(data))
  end
end

local function flush_sse_event()
  local raw_data = table.concat(state.sse_event.data, '\n')
  local event_name = state.sse_event.event or 'message'
  state.sse_event = { event = 'message', data = {} }

  if raw_data == '' then
    return
  end

  local payload, decode_err = decode_json(raw_data)
  if not payload then
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
    pcall(vim.fn.jobstop, state.events_job_id)
    state.events_job_id = nil
  end
  stop_thinking_spinner()
  state.sse_partial = ''
  state.sse_event = { event = 'message', data = {} }
end

function M.start_event_stream(session_id)
  M.stop_event_stream()
  state.sse_event = { event = 'message', data = {} }
  state.sse_partial = ''
  state.history_loading = true -- suppress rendering until host.history_done arrives

  local args = {
    state.config.curl_bin,
    '-sS',
    '-N',
    '-H',
    'Accept: text/event-stream',
    build_url(string.format('/sessions/%s/events?history=true', session_id)),
  }

  -- Batch incoming SSE chunks to avoid flooding the Neovim event loop.
  -- on_stdout fires for every curl output chunk (potentially hundreds/sec);
  -- we accumulate chunks and drain them on a debounced timer.
  local uv = vim.uv or vim.loop
  local sse_batch = {}
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

  state.events_job_id = vim.fn.jobstart(args, {
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
        local message = table.concat(data, '\n')
        if message ~= '' then
          vim.schedule(function()
            append_entry('error', message)
          end)
        end
      end
    end,
    on_exit = function(_, code)
      -- Drain any remaining chunks before handling exit.
      sse_batch_timer:stop()
      pcall(function()
        sse_batch_timer:close()
      end)
      vim.schedule(function()
        -- Process any remaining buffered chunks.
        for _, chunk in ipairs(sse_batch) do
          handle_sse_chunk(chunk)
        end
        sse_batch = {}
        state.events_job_id = nil
        if code ~= 0 and state.session_id == session_id then
          append_entry('error', 'Event stream stopped with exit code ' .. tostring(code))
        end
      end)
    end,
  })
end

M.show_user_input_picker = show_user_input_picker
M.handle_user_input = handle_user_input
M.handle_host_event = handle_host_event
M.offer_diff_review = offer_diff_review
M.handle_session_event = handle_session_event
M.flush_sse_event = flush_sse_event
M.consume_sse_line = consume_sse_line
M.handle_sse_chunk = handle_sse_chunk

return M
