-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Session lifecycle: create, resume, disconnect, pick-or-create.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')
local events = require('copilot_agent.events')
local model = require('copilot_agent.model')
local utils = require('copilot_agent.utils')

local state = cfg.state
local notify = cfg.notify
local log = cfg.log

local request = http.request

local working_directory = service.working_directory

local refresh_statuslines = sl.refresh_statuslines

local append_entry = render.append_entry
local clear_transcript = render.clear_transcript
local schedule_render = render.schedule_render

local stop_event_stream = events.stop_event_stream
local start_event_stream = events.start_event_stream

local stale_service_hint = model.stale_service_hint
local prompt_supported_model_selection = model.prompt_supported_model_selection

local format_session_id = utils.format_session_id
local truncate_session_summary = utils.truncate_session_summary
local unavailable_model_from_error = utils.unavailable_model_from_error

local M = {}

local function formatted_session_summary(summary)
  return truncate_session_summary(summary, 32)
end

local function formatted_session_label(summary, session_id)
  local formatted_id = format_session_id(session_id)
  local formatted_summary = formatted_session_summary(summary)
  if formatted_summary ~= '' then
    return formatted_summary .. ' [' .. formatted_id .. ']'
  end
  return formatted_id
end

local function session_id_of(session)
  return session and session.sessionId or nil
end

local function session_cwd_of(session)
  if not session then
    return nil
  end
  return (session.context and session.context.cwd) or session.workingDirectory or nil
end

local function session_sort_key(session)
  return (session and (session.modifiedTime or session.startTime or session.createdAt)) or ''
end

local function log_session_catalog(context, sessions, target_cwd)
  for _, session in ipairs(sessions or {}) do
    local session_cwd = session_cwd_of(session) or '<none>'
    local summary = formatted_session_summary(session.summary)
    log(
      string.format(
        '%s candidate id=%s live=%s cwd=%s target=%s match=%s summary=%s',
        context,
        format_session_id(session.sessionId),
        tostring(session.live == true),
        session_cwd,
        target_cwd or '<none>',
        tostring(session_cwd == target_cwd),
        summary ~= '' and summary or '<none>'
      ),
      vim.log.levels.DEBUG
    )
  end
end

local function merge_sessions(response)
  local merged = {}
  local order = {}

  local function upsert(session)
    local id = session_id_of(session)
    if not id or id == '' then
      return
    end
    if not merged[id] then
      order[#order + 1] = id
      merged[id] = vim.deepcopy(session)
      return
    end

    local existing = merged[id]
    if session.live then
      local combined = vim.deepcopy(session)
      combined.context = combined.context or existing.context
      combined.workingDirectory = combined.workingDirectory or existing.workingDirectory
      combined.summary = combined.summary or existing.summary
      combined.modifiedTime = combined.modifiedTime or existing.modifiedTime
      combined.startTime = combined.startTime or existing.startTime
      merged[id] = combined
      return
    end

    existing.context = existing.context or session.context
    existing.workingDirectory = existing.workingDirectory or session.workingDirectory
    existing.summary = existing.summary or session.summary
    existing.modifiedTime = existing.modifiedTime or session.modifiedTime
    existing.startTime = existing.startTime or session.startTime
    existing.createdAt = existing.createdAt or session.createdAt
  end

  for _, session in ipairs((response and response.persisted) or {}) do
    upsert(session)
  end
  for _, session in ipairs((response and response.live) or {}) do
    upsert(session)
  end

  local items = {}
  for _, id in ipairs(order) do
    items[#items + 1] = merged[id]
  end
  return items
end

-- Delete any temp files (clipboard PNGs) still waiting in pending_attachments.
function M.discard_pending_attachments()
  for _, a in ipairs(state.pending_attachments) do
    if a.temp and a.path then
      pcall(os.remove, a.path)
    end
  end
  state.pending_attachments = {}
  refresh_statuslines()
end

local function focus_input_for_active_chat()
  if not (state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid)) then
    return
  end

  vim.schedule(function()
    if not (state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid)) then
      return
    end
    require('copilot_agent')._open_input_window()
  end)
end

function M.disconnect_session(session_id, delete_state, callback)
  stop_event_stream()
  if not session_id then
    if callback then
      callback(nil)
    end
    return
  end

  request('DELETE', string.format('/sessions/%s%s', session_id, delete_state and '?delete=true' or ''), nil, function(_, err)
    if callback then
      callback(err)
    end
  end, { auto_start = false })
end

local function on_session_ready(session_id, err)
  local should_open_input = session_id and not err and state.open_input_on_session_ready
  state.open_input_on_session_ready = false
  for _, callback in ipairs(state.pending_session_callbacks) do
    callback(session_id, err)
  end
  state.pending_session_callbacks = {}
  if should_open_input then
    focus_input_for_active_chat()
  end
end

function M.resume_session(session_id, callback)
  local requested_wd = working_directory()
  log(string.format('resume_session request id=%s cwd=%s', format_session_id(session_id), requested_wd), vim.log.levels.DEBUG)
  request('POST', '/sessions', {
    sessionId = session_id,
    resume = true,
    clientName = state.config.client_name,
    permissionMode = state.config.permission_mode,
    workingDirectory = requested_wd,
    streaming = state.config.session.streaming,
    enableConfigDiscovery = state.config.session.enable_config_discovery,
    model = state.config.session.model,
    agent = state.config.session.agent,
  }, function(response, err)
    state.creating_session = false
    if err then
      notify('Failed to resume session: ' .. err, vim.log.levels.ERROR)
      append_entry('error', 'Failed to resume session: ' .. err)
      on_session_ready(nil, err)
      return
    end
    state.session_id = response and response.sessionId or nil
    if not state.session_id then
      local message = 'Server did not return a sessionId'
      append_entry('error', message)
      on_session_ready(nil, message)
      return
    end
    log(
      string.format(
        'resume_session attached id=%s requested_cwd=%s response_wd=%s summary=%s',
        format_session_id(state.session_id),
        requested_wd,
        tostring(response and response.workingDirectory or '<none>'),
        tostring(response and response.summary or '<none>')
      ),
      vim.log.levels.DEBUG
    )
    start_event_stream(state.session_id)
    on_session_ready(state.session_id)
    if callback then
      callback(state.session_id)
    end
  end)
end

local create_session

function M.pick_or_create_session(callback)
  local wd = working_directory()
  -- Show a connecting indicator immediately while the async fetch runs.
  append_entry('system', 'Connecting…')
  log('pick_or_create_session cwd=' .. tostring(wd), vim.log.levels.INFO)
  request('GET', '/sessions', nil, function(response, err)
    if err then
      log('pick_or_create_session list failed: ' .. tostring(err), vim.log.levels.ERROR)
      create_session(callback)
      return
    end

    local sessions = merge_sessions(response)
    log_session_catalog('pick_or_create_session', sessions, wd)
    local matching = {}
    for _, s in ipairs(sessions) do
      local s_cwd = session_cwd_of(s)
      if s_cwd == wd then
        table.insert(matching, s)
      end
    end
    log(
      string.format(
        'pick_or_create_session cwd=%s persisted=%d live=%d merged=%d matching=%d',
        tostring(wd),
        #((response and response.persisted) or {}),
        #((response and response.live) or {}),
        #sessions,
        #matching
      ),
      vim.log.levels.INFO
    )

    if #matching == 0 then
      log('pick_or_create_session no matching session; creating new session', vim.log.levels.WARN)
      create_session(callback)
      return
    end

    -- Auto-resume the single match silently — no need to prompt.
    if #matching == 1 then
      local s = matching[1]
      append_entry('system', 'Resuming session ' .. formatted_session_label(s.summary, s.sessionId))
      log('pick_or_create_session resuming single match ' .. formatted_session_label(s.summary, s.sessionId), vim.log.levels.INFO)
      M.resume_session(s.sessionId, callback)
      return
    end

    -- Multiple matches: sort newest-first.
    table.sort(matching, function(a, b)
      local ta = session_sort_key(a)
      local tb = session_sort_key(b)
      return ta > tb
    end)

    -- auto_resume='auto': silently resume the most recent without prompting.
    if state.config.session.auto_resume == 'auto' then
      local s = matching[1]
      append_entry('system', 'Resuming most recent session ' .. formatted_session_label(s.summary, s.sessionId))
      log('pick_or_create_session auto-resume ' .. formatted_session_label(s.summary, s.sessionId), vim.log.levels.INFO)
      M.resume_session(s.sessionId, callback)
      return
    end

    -- Show a picker; most recent session is listed first (default selection).
    local choices = {}
    for _, s in ipairs(matching) do
      local label = formatted_session_label(s.summary, s.sessionId)
      if label == (s.sessionId or '') then
        local ts = s.modifiedTime or s.startTime or ''
        if ts ~= '' then
          label = label .. ' (' .. ts .. ')'
        end
      end
      table.insert(choices, { label = label, id = s.sessionId })
    end
    table.insert(choices, { label = 'Create new session', id = nil })
    -- Offer access to sessions from other directories.
    local other_count = #sessions - #matching
    if other_count > 0 then
      table.insert(choices, { label = 'Show all sessions (' .. other_count .. ' from other dirs)…', id = '__all__' })
    end

    local display = vim.tbl_map(function(c)
      return c.label
    end, choices)

    vim.ui.select(display, { prompt = 'Resume a session or start new?' }, function(_, idx)
      if not idx then
        -- <Esc> dismissed the picker — default to the most recent session.
        local default = choices[1]
        if default.id then
          append_entry('system', 'Resumed most recent session ' .. format_session_id(default.id) .. ' (picker cancelled)')
          log('pick_or_create_session picker cancelled; resuming ' .. format_session_id(default.id), vim.log.levels.INFO)
          M.resume_session(default.id, callback)
        else
          create_session(callback)
        end
        return
      end
      local picked = choices[idx]
      if picked.id == '__all__' then
        -- Re-open picker with the full unfiltered list.
        -- Deferred so the first picker fully closes before the second opens
        -- (some picker backends need time to tear down their window).
        vim.defer_fn(function()
          local all_choices = {}
          table.sort(sessions, function(a, b)
            return session_sort_key(a) > session_sort_key(b)
          end)
          for _, s in ipairs(sessions) do
            local label = formatted_session_label(s.summary, s.sessionId)
            local cwd = session_cwd_of(s) or ''
            if cwd ~= '' then
              label = label .. '  ' .. vim.fn.fnamemodify(cwd, ':~')
            end
            table.insert(all_choices, { label = label, id = s.sessionId })
          end
          table.insert(all_choices, { label = 'Create new session', id = nil })
          local all_display = vim.tbl_map(function(c)
            return c.label
          end, all_choices)
          vim.ui.select(all_display, { prompt = 'All sessions' }, function(_, idx2)
            if not idx2 then
              local def = all_choices[1]
              if def and def.id then
                M.resume_session(def.id, callback)
              else
                create_session(callback)
              end
              return
            end
            local p = all_choices[idx2]
            if p.id then
              append_entry('system', 'Resuming session ' .. format_session_id(p.id))
              log('pick_or_create_session resumed from all-sessions picker ' .. format_session_id(p.id), vim.log.levels.INFO)
              M.resume_session(p.id, callback)
            else
              create_session(callback)
            end
          end)
        end, 100)
      elseif picked.id then
        append_entry('system', 'Resuming session ' .. format_session_id(picked.id))
        log('pick_or_create_session resumed from matching picker ' .. format_session_id(picked.id), vim.log.levels.INFO)
        M.resume_session(picked.id, callback)
      else
        create_session(callback)
      end
    end)
  end)
end

create_session = function(callback, opts)
  opts = opts or {}
  local requested_wd = working_directory()
  log(
    string.format(
      'create_session request cwd=%s model=%s agent=%s permission=%s',
      requested_wd,
      tostring(state.config.session.model or '<default>'),
      tostring(state.config.session.agent or '<default>'),
      tostring(state.permission_mode or state.config.permission_mode)
    ),
    vim.log.levels.DEBUG
  )
  request('POST', '/sessions', {
    clientName = state.config.client_name,
    permissionMode = state.permission_mode or state.config.permission_mode,
    workingDirectory = requested_wd,
    streaming = state.config.session.streaming,
    enableConfigDiscovery = state.config.session.enable_config_discovery,
    model = state.config.session.model,
    agent = state.config.session.agent,
  }, function(response, err)
    state.creating_session = false
    if err then
      local um = unavailable_model_from_error(err)
      local hint = stale_service_hint(um)
      if hint then
        notify(hint, vim.log.levels.ERROR)
        append_entry('error', hint)
        append_entry('error', 'Failed to create session: ' .. err)
        on_session_ready(nil, err)
        return
      end
      if um and state.config.session.model == um and opts.model_selection_attempts ~= false then
        append_entry('system', string.format('Model "%s" is unavailable; choose a supported model.', um))
        prompt_supported_model_selection(um, 'Select a supported Copilot model', function(reselected_model, prompt_err)
          if prompt_err then
            notify('Failed to create session: ' .. prompt_err, vim.log.levels.ERROR)
            append_entry('error', 'Failed to create session: ' .. prompt_err)
            on_session_ready(nil, prompt_err)
            return
          end
          state.config.session.model = reselected_model
          state.current_model = reselected_model
          append_entry('system', 'Retrying session creation with model ' .. reselected_model)
          state.creating_session = true
          create_session(callback, { model_selection_attempts = false })
        end)
        return
      end
      notify('Failed to create session: ' .. err, vim.log.levels.ERROR)
      append_entry('error', 'Failed to create session: ' .. err)
      log('create_session failed: ' .. tostring(err), vim.log.levels.ERROR)
      on_session_ready(nil, err)
      return
    end

    state.session_id = response and response.sessionId or nil
    if not state.session_id then
      local message = 'Server did not return a sessionId'
      append_entry('error', message)
      log(message, vim.log.levels.ERROR)
      on_session_ready(nil, message)
      return
    end

    start_event_stream(state.session_id)

    -- Announce the new session.
    local wd = (response.workingDirectory and response.workingDirectory ~= '') and vim.fn.fnamemodify(response.workingDirectory, ':~') or vim.fn.fnamemodify(working_directory(), ':~')
    local name = formatted_session_summary(response.summary)
    local formatted_id = format_session_id(state.session_id)
    local msg = 'New session created' .. '  id:' .. formatted_id .. (name ~= '' and ('  name:' .. name) or '') .. '  dir:' .. wd
    append_entry('system', msg)
    log(msg, vim.log.levels.INFO)
    log(
      string.format(
        'create_session attached id=%s requested_cwd=%s response_wd=%s workspace=%s summary=%s',
        formatted_id,
        requested_wd,
        tostring(response and response.workingDirectory or '<none>'),
        tostring(response and response.workspacePath or '<none>'),
        name ~= '' and name or '<none>'
      ),
      vim.log.levels.DEBUG
    )

    -- Sync the agent mode with the server if the user already picked one.
    if state.input_mode and state.input_mode ~= 'agent' then
      require('copilot_agent')._set_agent_mode(state.input_mode)
    end
    on_session_ready(state.session_id)
    if callback then
      callback(state.session_id)
    end
  end)
end

-- Force-create a brand-new session, bypassing any pick/resume logic.
function M.create_new_session(callback)
  table.insert(state.pending_session_callbacks, callback or function() end)
  if state.creating_session then
    return
  end
  state.creating_session = true
  create_session(callback)
end

function M.with_session(callback, opts)
  opts = opts or {}
  if state.session_id then
    if opts.open_input_on_session_ready then
      focus_input_for_active_chat()
    end
    callback(state.session_id)
    return
  end

  table.insert(state.pending_session_callbacks, callback)
  if opts.open_input_on_session_ready then
    state.open_input_on_session_ready = true
  end
  if state.creating_session then
    return
  end

  state.creating_session = true
  M.pick_or_create_session(nil)
end

-- ── High-level session operations (moved from init.lua) ──────────────────────

--- Create a new session, disconnecting the previous one.
function M.new_session()
  local previous_session_id = state.session_id
  state.session_id = nil
  state.session_name = nil
  M.discard_pending_attachments()
  clear_transcript()
  -- Ensure chat window via lazy require to avoid circular dependency.
  require('copilot_agent').open_chat()
  M.disconnect_session(previous_session_id, false, function(err)
    if err then
      append_entry('error', 'Failed to disconnect previous session: ' .. err)
      return
    end
    M.create_new_session(function(session_id, create_err)
      if create_err then
        append_entry('error', create_err)
        return
      end
      append_entry('system', 'Created session ' .. session_id)
    end)
  end)
end

--- Show a picker of all persisted sessions and switch to the selected one.
function M.switch_session()
  request('GET', '/sessions', nil, function(response, err)
    if err then
      notify('Failed to list sessions: ' .. err, vim.log.levels.ERROR)
      return
    end

    local sessions = merge_sessions(response)
    log_session_catalog('switch_session', sessions)
    log(string.format('switch_session persisted=%d live=%d merged=%d', #((response and response.persisted) or {}), #((response and response.live) or {}), #sessions), vim.log.levels.INFO)
    if #sessions == 0 then
      notify('No sessions found. Use :CopilotAgentNewSession to create one.', vim.log.levels.INFO)
      return
    end

    -- Sort newest-first.
    table.sort(sessions, function(a, b)
      local ta = session_sort_key(a)
      local tb = session_sort_key(b)
      return ta > tb
    end)

    local choices = {}
    for _, s in ipairs(sessions) do
      local label = formatted_session_label(s.summary, s.sessionId)
      if label == (s.sessionId or '') then
        local ts = session_sort_key(s)
        if ts ~= '' then
          label = label .. ' (' .. ts .. ')'
        end
      end
      local cwd_label = ''
      local session_cwd = session_cwd_of(s)
      if session_cwd then
        cwd_label = '  ' .. vim.fn.fnamemodify(session_cwd, ':~')
      end
      -- Mark the currently active session.
      local active = (state.session_id and s.sessionId == state.session_id) and ' ●' or ''
      table.insert(choices, { label = label .. cwd_label .. active, id = s.sessionId })
    end
    table.insert(choices, { label = '+ New session', id = nil })

    local display = vim.tbl_map(function(c)
      return c.label
    end, choices)

    vim.ui.select(display, { prompt = 'Switch session' }, function(_, idx)
      if not idx then
        return
      end
      local picked = choices[idx]
      if not picked.id then
        M.new_session()
        return
      end
      if state.session_id and picked.id == state.session_id then
        notify('Already on this session', vim.log.levels.INFO)
        return
      end
      local previous_session_id = state.session_id
      state.session_id = nil
      state.session_name = nil
      state.creating_session = true
      M.discard_pending_attachments()
      clear_transcript()
      require('copilot_agent')._ensure_chat_window()
      M.disconnect_session(previous_session_id, false, function(disconnect_err)
        if disconnect_err then
          append_entry('error', 'Failed to disconnect previous session: ' .. disconnect_err)
          log('switch_session disconnect failed: ' .. tostring(disconnect_err), vim.log.levels.ERROR)
        end
        append_entry('system', 'Switching to session ' .. format_session_id(picked.id) .. '…')
        log('switch_session switching to ' .. format_session_id(picked.id), vim.log.levels.INFO)
        M.resume_session(picked.id)
      end)
    end)
  end)
end

--- Disconnect the active session.
function M.stop(delete_state)
  if not state.session_id then
    append_entry('system', 'No active session')
    return
  end

  local session_id = state.session_id
  state.session_id = nil
  M.discard_pending_attachments()
  clear_transcript()
  M.disconnect_session(session_id, delete_state, function(err)
    if err then
      append_entry('error', 'Failed to disconnect session: ' .. err)
      return
    end
    append_entry('system', 'Disconnected session ' .. session_id)
  end)
end

--- Cancel the current in-progress turn.
function M.cancel()
  if not state.session_id then
    notify('No active session to cancel', vim.log.levels.WARN)
    return
  end
  request('POST', '/sessions/' .. state.session_id .. '/abort', {}, function(_, err)
    if err then
      append_entry('error', 'Cancel failed: ' .. err)
      return
    end
    state.chat_busy = false
    refresh_statuslines()
    append_entry('system', 'Turn cancelled')
    schedule_render()
  end)
end

M._on_session_ready = on_session_ready
M._focus_input_for_active_chat = focus_input_for_active_chat

return M
