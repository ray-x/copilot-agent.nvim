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
local approvals = require('copilot_agent.approvals')
local checkpoints = require('copilot_agent.checkpoints')
local session_names = require('copilot_agent.session_names')
local utils = require('copilot_agent.utils')

local state = cfg.state
local notify = cfg.notify
local log = cfg.log

local request = http.request
local sync_request = http.sync_request

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
local create_session

local function formatted_session_summary(summary)
  return truncate_session_summary(summary, 32)
end

local function formatted_session_label(summary, session_id)
  local formatted_id = format_session_id(session_id)
  local formatted_summary = formatted_session_summary(session_names.resolve(summary, session_id))
  if formatted_summary ~= '' then
    return formatted_summary .. ' [' .. formatted_id .. ']'
  end
  return formatted_id
end

local function project_picker_label(path)
  if type(path) ~= 'string' or path == '' then
    return 'current project'
  end

  local display = vim.fn.fnamemodify(path, ':~')
  local name = vim.fn.fnamemodify(path, ':t')
  if name == '' or name == '.' or name == display then
    return display
  end
  return string.format('%s (%s)', name, display)
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
    local summary = formatted_session_summary(session_names.resolve(session.summary, session.sessionId))
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

  local function upsert(session, live_source)
    local id = session_id_of(session)
    if not id or id == '' then
      return
    end
    local normalized = vim.deepcopy(session)
    normalized.live = live_source == true
    if not merged[id] then
      order[#order + 1] = id
      merged[id] = normalized
      return
    end

    local existing = merged[id]
    if live_source then
      local combined = normalized
      combined.context = combined.context or existing.context
      combined.workingDirectory = combined.workingDirectory or existing.workingDirectory
      combined.summary = combined.summary or existing.summary
      combined.modifiedTime = combined.modifiedTime or existing.modifiedTime
      combined.startTime = combined.startTime or existing.startTime
      combined.createdAt = combined.createdAt or existing.createdAt
      merged[id] = combined
      return
    end

    existing.context = existing.context or normalized.context
    existing.workingDirectory = existing.workingDirectory or normalized.workingDirectory
    existing.summary = existing.summary or normalized.summary
    existing.modifiedTime = existing.modifiedTime or normalized.modifiedTime
    existing.startTime = existing.startTime or normalized.startTime
    existing.createdAt = existing.createdAt or normalized.createdAt
  end

  for _, session in ipairs((response and response.persisted) or {}) do
    upsert(session, false)
  end
  for _, session in ipairs((response and response.live) or {}) do
    upsert(session, true)
  end

  local items = {}
  for _, id in ipairs(order) do
    items[#items + 1] = merged[id]
  end
  return items
end

local function fetch_sorted_sessions(context, callback)
  request('GET', '/sessions', nil, function(response, err)
    if err then
      callback(nil, err, response)
      return
    end

    local sessions = merge_sessions(response)
    log_session_catalog(context, sessions)
    log(string.format('%s persisted=%d live=%d merged=%d', context, #((response and response.persisted) or {}), #((response and response.live) or {}), #sessions), vim.log.levels.INFO)
    table.sort(sessions, function(a, b)
      local ta = session_sort_key(a)
      local tb = session_sort_key(b)
      return ta > tb
    end)
    callback(sessions, nil, response)
  end)
end

local function latest_matching_session(sessions, target_cwd)
  local matching = {}
  for _, session in ipairs(sessions or {}) do
    if session_cwd_of(session) == target_cwd then
      matching[#matching + 1] = session
    end
  end

  table.sort(matching, function(a, b)
    return session_sort_key(a) > session_sort_key(b)
  end)

  return matching[1]
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

local function active_session_working_directory()
  return state.session_working_directory or working_directory()
end

local function delete_session_request(session_id, delete_state, callback)
  request('DELETE', string.format('/sessions/%s%s', session_id, delete_state and '?delete=true' or ''), nil, function(_, err)
    if callback then
      callback(err)
    end
  end, { auto_start = false })
end

function M.disconnect_session(session_id, delete_state, callback)
  stop_event_stream()
  approvals.reset()
  if not session_id then
    if callback then
      callback(nil)
    end
    return
  end

  delete_session_request(session_id, delete_state, callback)
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

local function cancel_attach_attempt(message, callback, opts)
  opts = opts or {}
  state.creating_session = false
  append_entry('system', message)
  if opts.resolve_pending then
    on_session_ready(nil, message)
  end
  if callback then
    callback(nil, message)
  end
end

local function confirm_takeover_if_live(session, callback)
  if not (session and session.live == true) then
    callback('resume')
    return
  end

  local session_label = formatted_session_label(session.summary, session.sessionId)
  vim.ui.select({
    'Keep older instance attached',
    'Kick older instance out',
    'New Session',
  }, {
    prompt = 'Session ' .. session_label .. ' is already attached in another Neovim instance. Kick the older instance out?',
  }, function(choice)
    if choice == 'Kick older instance out' then
      log('resume takeover confirmed for ' .. format_session_id(session.sessionId), vim.log.levels.INFO)
      callback('resume')
      return
    end

    if choice == 'New Session' then
      log('resume takeover creating replacement session instead of resuming ' .. format_session_id(session.sessionId), vim.log.levels.INFO)
      callback('new')
      return
    end

    local message = 'Kept older instance attached; did not connect to session ' .. format_session_id(session.sessionId)
    log('resume takeover declined for ' .. format_session_id(session.sessionId), vim.log.levels.INFO)
    callback('cancel', message)
  end)
end

local function resume_known_session(session, callback, opts)
  opts = opts or {}
  confirm_takeover_if_live(session, function(decision, message)
    if decision == 'new' then
      append_entry('system', 'Creating a new session instead of resuming ' .. format_session_id(session.sessionId))
      create_session(callback)
      return
    end

    if decision ~= 'resume' then
      cancel_attach_attempt(message, callback, { resolve_pending = opts.resolve_pending })
      return
    end

    if opts.append_message then
      append_entry('system', opts.append_message)
    end
    if opts.log_message then
      log(opts.log_message, vim.log.levels.INFO)
    end
    M.resume_session(session.sessionId, callback, opts.resume_opts)
  end)
end

function M.resume_session(session_id, callback, opts)
  opts = opts or {}
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
      if callback then
        callback(nil, err)
      end
      return
    end
    local resumed_session_id = response and response.sessionId or nil
    if opts.guard_current_session_id and state.session_id ~= nil and state.session_id ~= opts.guard_current_session_id then
      local message = 'resume cancelled: active session changed'
      log(
        string.format(
          'resume_session ignored stale response id=%s current=%s expected=%s',
          format_session_id(resumed_session_id),
          format_session_id(state.session_id),
          format_session_id(opts.guard_current_session_id)
        ),
        vim.log.levels.DEBUG
      )
      if callback then
        callback(nil, message)
      end
      return
    end
    state.session_id = resumed_session_id
    state.session_working_directory = (response and response.workingDirectory) or requested_wd
    if not resumed_session_id then
      local message = 'Server did not return a sessionId'
      append_entry('error', message)
      on_session_ready(nil, message)
      if callback then
        callback(nil, message)
      end
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
    approvals.reset()
    start_event_stream(state.session_id)
    on_session_ready(state.session_id)
    if callback then
      callback(state.session_id, nil)
    end
  end)
end

function M.latest_project_session_sync()
  local wd = working_directory()
  local response, err = sync_request('GET', '/sessions', nil)
  if err or type(response) ~= 'table' then
    return nil, err
  end

  local sessions = merge_sessions(response)
  table.sort(sessions, function(a, b)
    return session_sort_key(a) > session_sort_key(b)
  end)
  log_session_catalog('latest_project_session_sync', sessions, wd)
  return latest_matching_session(sessions, wd), nil
end

local function reset_for_session_switch()
  state.session_id = nil
  state.session_name = nil
  state.session_working_directory = nil
  state.creating_session = true
  M.discard_pending_attachments()
  clear_transcript()
  require('copilot_agent')._ensure_chat_window()
end

local function disconnect_current_session_for_project_attach(callback)
  local previous_session_id = state.session_id
  if not previous_session_id then
    callback(nil)
    return
  end

  reset_for_session_switch()
  M.disconnect_session(previous_session_id, false, function(disconnect_err)
    if disconnect_err then
      append_entry('error', 'Failed to disconnect previous session: ' .. disconnect_err)
      log('attach_latest_project_session_or_create disconnect failed: ' .. tostring(disconnect_err), vim.log.levels.ERROR)
      callback(disconnect_err)
      return
    end
    callback(nil)
  end)
end

function M.attach_latest_project_session_or_create(callback)
  callback = callback or function() end

  local wd = working_directory()
  local active_wd = state.session_working_directory
  if state.session_id and active_wd == wd then
    callback(state.session_id, nil)
    return
  end

  log('attach_latest_project_session_or_create cwd=' .. tostring(wd), vim.log.levels.INFO)
  fetch_sorted_sessions('attach_latest_project_session_or_create', function(sessions, err)
    if err then
      log('attach_latest_project_session_or_create list failed: ' .. tostring(err), vim.log.levels.WARN)
      disconnect_current_session_for_project_attach(function(disconnect_err)
        if disconnect_err then
          callback(nil, disconnect_err)
          return
        end
        create_session(callback)
      end)
      return
    end

    local latest = latest_matching_session(sessions, wd)
    if latest then
      disconnect_current_session_for_project_attach(function(disconnect_err)
        if disconnect_err then
          callback(nil, disconnect_err)
          return
        end
        resume_known_session(latest, callback, {
          resolve_pending = true,
          append_message = 'Resuming most recent session ' .. formatted_session_label(latest.summary, latest.sessionId),
          log_message = 'attach_latest_project_session_or_create resume ' .. formatted_session_label(latest.summary, latest.sessionId),
        })
      end)
      return
    end

    log('attach_latest_project_session_or_create no matching session; creating new session', vim.log.levels.INFO)
    disconnect_current_session_for_project_attach(function(disconnect_err)
      if disconnect_err then
        callback(nil, disconnect_err)
        return
      end
      create_session(callback)
    end)
  end)
end

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
      resume_known_session(s, callback, {
        resolve_pending = true,
        append_message = 'Resuming session ' .. formatted_session_label(s.summary, s.sessionId),
        log_message = 'pick_or_create_session resuming single match ' .. formatted_session_label(s.summary, s.sessionId),
      })
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
      resume_known_session(s, callback, {
        resolve_pending = true,
        append_message = 'Resuming most recent session ' .. formatted_session_label(s.summary, s.sessionId),
        log_message = 'pick_or_create_session auto-resume ' .. formatted_session_label(s.summary, s.sessionId),
      })
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
      table.insert(choices, { label = label, id = s.sessionId, session = s })
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

    vim.ui.select(display, { prompt = 'Select session for project: ' .. project_picker_label(wd) }, function(_, idx)
      if not idx then
        -- <Esc> dismissed the picker — default to the most recent session.
        local default = choices[1]
        if default.id then
          resume_known_session(default.session, callback, {
            resolve_pending = true,
            append_message = 'Resumed most recent session ' .. format_session_id(default.id) .. ' (picker cancelled)',
            log_message = 'pick_or_create_session picker cancelled; resuming ' .. format_session_id(default.id),
          })
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
            table.insert(all_choices, { label = label, id = s.sessionId, session = s })
          end
          table.insert(all_choices, { label = 'Create new session', id = nil })
          local all_display = vim.tbl_map(function(c)
            return c.label
          end, all_choices)
          vim.ui.select(all_display, { prompt = 'All sessions (current project: ' .. project_picker_label(wd) .. ')' }, function(_, idx2)
            if not idx2 then
              local def = all_choices[1]
              if def and def.id then
                resume_known_session(def.session, callback, {
                  resolve_pending = true,
                })
              else
                create_session(callback)
              end
              return
            end
            local p = all_choices[idx2]
            if p.id then
              resume_known_session(p.session, callback, {
                resolve_pending = true,
                append_message = 'Resuming session ' .. format_session_id(p.id),
                log_message = 'pick_or_create_session resumed from all-sessions picker ' .. format_session_id(p.id),
              })
            else
              create_session(callback)
            end
          end)
        end, 100)
      elseif picked.id then
        resume_known_session(picked.session, callback, {
          resolve_pending = true,
          append_message = 'Resuming session ' .. format_session_id(picked.id),
          log_message = 'pick_or_create_session resumed from matching picker ' .. format_session_id(picked.id),
        })
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
    state.session_working_directory = (response and response.workingDirectory) or requested_wd
    if not state.session_id then
      local message = 'Server did not return a sessionId'
      append_entry('error', message)
      log(message, vim.log.levels.ERROR)
      on_session_ready(nil, message)
      return
    end

    approvals.reset()
    start_event_stream(state.session_id)

    -- Announce the new session.
    local wd = (response.workingDirectory and response.workingDirectory ~= '') and vim.fn.fnamemodify(response.workingDirectory, ':~') or vim.fn.fnamemodify(working_directory(), ':~')
    local name = formatted_session_summary(session_names.resolve(response.summary, state.session_id))
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
  state.session_working_directory = nil
  M.discard_pending_attachments()
  clear_transcript()
  -- Ensure chat window via lazy require to avoid circular dependency.
  require('copilot_agent')._ensure_chat_window()
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

function M.clear_and_new_session()
  local previous_session_id = state.session_id
  local previous_session_name = state.session_name
  local previous_working_directory = state.session_working_directory
  M.discard_pending_attachments()
  clear_transcript()
  require('copilot_agent')._ensure_chat_window()

  local function create_replacement()
    M.create_new_session(function(session_id, create_err)
      if create_err then
        append_entry('error', create_err)
        return
      end
      append_entry('system', 'Created session ' .. session_id)
    end)
  end

  if not previous_session_id then
    create_replacement()
    return
  end

  M.delete_session_by_id(previous_session_id, {
    sessionId = previous_session_id,
    summary = previous_session_name,
    workingDirectory = previous_working_directory or working_directory(),
  }, function(err)
    if err then
      append_entry('error', 'Failed to clear previous session: ' .. err)
      return
    end
    create_replacement()
  end)
end

function M.switch_to_session_id(target_session_id, target_session)
  target_session_id = vim.trim(target_session_id or '')
  if target_session_id == '' then
    notify('Session ID is required', vim.log.levels.WARN)
    return
  end
  if state.session_id and target_session_id == state.session_id then
    notify('Already on this session', vim.log.levels.INFO)
    return
  end

  local function perform_switch()
    local previous_session_id = state.session_id
    state.session_id = nil
    state.session_name = nil
    state.session_working_directory = nil
    state.creating_session = true
    M.discard_pending_attachments()
    clear_transcript()
    require('copilot_agent')._ensure_chat_window()
    M.disconnect_session(previous_session_id, false, function(disconnect_err)
      if disconnect_err then
        append_entry('error', 'Failed to disconnect previous session: ' .. disconnect_err)
        log('switch_to_session_id disconnect failed: ' .. tostring(disconnect_err), vim.log.levels.ERROR)
      end
      append_entry('system', 'Switching to session ' .. format_session_id(target_session_id) .. '…')
      log('switch_to_session_id switching to ' .. format_session_id(target_session_id), vim.log.levels.INFO)
      M.resume_session(target_session_id)
    end)
  end

  if target_session then
    confirm_takeover_if_live(target_session, function(decision, message)
      if decision == 'new' then
        M.new_session()
        return
      end

      if decision ~= 'resume' then
        append_entry('system', message)
        return
      end
      perform_switch()
    end)
    return
  end

  fetch_sorted_sessions('switch_to_session_id', function(sessions, err)
    if err then
      perform_switch()
      return
    end

    local found_session = nil
    for _, session in ipairs(sessions) do
      if session.sessionId == target_session_id then
        found_session = session
        break
      end
    end

    confirm_takeover_if_live(found_session, function(decision, message)
      if decision == 'new' then
        M.new_session()
        return
      end

      if decision ~= 'resume' then
        append_entry('system', message)
        return
      end
      perform_switch()
    end)
  end)
end

--- Show a picker of all persisted sessions and switch to the selected one.
function M.switch_session()
  fetch_sorted_sessions('switch_session', function(sessions, err)
    if err then
      notify('Failed to list sessions: ' .. err, vim.log.levels.ERROR)
      return
    end
    if #sessions == 0 then
      notify('No sessions found. Use :CopilotAgentNewSession to create one.', vim.log.levels.INFO)
      return
    end

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
      table.insert(choices, { label = label .. cwd_label .. active, id = s.sessionId, session = s })
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
      M.switch_to_session_id(picked.id, picked.session)
    end)
  end)
end

local function delete_session_label(session)
  local parts = {}
  local summary = formatted_session_summary(session_names.resolve(session.summary, session.sessionId))
  if summary ~= '' then
    parts[#parts + 1] = summary
  end
  parts[#parts + 1] = '[' .. (session.sessionId or '') .. ']'

  local session_cwd = session_cwd_of(session)
  if session_cwd then
    parts[#parts + 1] = vim.fn.fnamemodify(session_cwd, ':~')
  end

  local label = table.concat(parts, '  ')
  if state.session_id and session.sessionId == state.session_id then
    label = label .. ' ●'
  end
  return label
end

local function soft_delete_checkpoint_repo(session_id, opts, callback)
  checkpoints.soft_delete_session(session_id, opts, function(checkpoint_err)
    if checkpoint_err then
      local message = 'Deleted session ' .. format_session_id(session_id) .. ', but failed to retain its checkpoint repo: ' .. checkpoint_err
      append_entry('error', message)
      notify(message, vim.log.levels.WARN)
    end
    if callback then
      callback(checkpoint_err)
    end
  end)
end

function M.delete_session_by_id(target_session_id, session_record, callback)
  callback = callback or function() end
  target_session_id = vim.trim(target_session_id or '')
  if target_session_id == '' then
    callback('Session ID is required')
    return
  end

  local active_session = state.session_id and target_session_id == state.session_id
  local current_session_name = active_session and state.session_name or nil
  local current_working_directory = active_session and active_session_working_directory() or nil
  local checkpoint_opts = {
    session_name = current_session_name or session_names.resolve(session_record and session_record.summary, target_session_id),
    working_directory = current_working_directory or session_cwd_of(session_record),
  }
  local formatted_id = format_session_id(target_session_id)

  local function finish_delete()
    append_entry('system', 'Deleted session ' .. formatted_id)
    notify('Deleted session ' .. formatted_id, vim.log.levels.INFO)
    soft_delete_checkpoint_repo(target_session_id, checkpoint_opts, function(checkpoint_err)
      callback(nil, checkpoint_err)
    end)
  end

  if active_session then
    state.session_id = nil
    state.session_name = nil
    state.session_working_directory = nil
    M.discard_pending_attachments()
    clear_transcript()
    M.disconnect_session(target_session_id, true, function(err)
      if err then
        callback(err)
        return
      end
      finish_delete()
    end)
    return
  end

  delete_session_request(target_session_id, true, function(err)
    if err then
      callback(err)
      return
    end
    finish_delete()
  end)
end

function M.delete_session()
  fetch_sorted_sessions('delete_session', function(sessions, err)
    if err then
      notify('Failed to list sessions: ' .. err, vim.log.levels.ERROR)
      return
    end
    if #sessions == 0 then
      notify('No sessions found to delete.', vim.log.levels.INFO)
      return
    end

    local choices = {}
    for _, session in ipairs(sessions) do
      table.insert(choices, {
        id = session.sessionId,
        label = delete_session_label(session),
        session = session,
      })
    end
    local display = vim.tbl_map(function(choice)
      return choice.label
    end, choices)

    vim.ui.select(display, { prompt = 'Delete session' }, function(_, idx)
      if not idx then
        return
      end

      local picked = choices[idx]
      M.delete_session_by_id(picked.id, picked.session, function(delete_err)
        if delete_err then
          local message = 'Failed to delete session ' .. format_session_id(picked.id) .. ': ' .. delete_err
          append_entry('error', message)
          notify(message, vim.log.levels.ERROR)
        end
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

  if delete_state then
    local session_id = state.session_id
    local session_summary = state.session_name
    M.delete_session_by_id(session_id, {
      sessionId = session_id,
      summary = session_summary,
      workingDirectory = active_session_working_directory(),
    }, function(err)
      if err then
        append_entry('error', 'Failed to delete session: ' .. err)
      end
    end)
    return
  end

  local session_id = state.session_id
  state.session_id = nil
  state.session_working_directory = nil
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
