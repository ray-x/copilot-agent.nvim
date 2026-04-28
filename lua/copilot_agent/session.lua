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

local request = http.request

local working_directory = service.working_directory

local refresh_statuslines = sl.refresh_statuslines

local append_entry = render.append_entry

local stop_event_stream = events.stop_event_stream
local start_event_stream = events.start_event_stream

local stale_service_hint = model.stale_service_hint
local prompt_supported_model_selection = model.prompt_supported_model_selection

local unavailable_model_from_error = utils.unavailable_model_from_error

local M = {}

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
  for _, callback in ipairs(state.pending_session_callbacks) do
    callback(session_id, err)
  end
  state.pending_session_callbacks = {}
end

function M.resume_session(session_id, callback)
  request('POST', '/sessions', {
    sessionId = session_id,
    resume = true,
    clientName = state.config.client_name,
    permissionMode = state.config.permission_mode,
    workingDirectory = working_directory(),
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
  request('GET', '/sessions', nil, function(response, err)
    if err then
      create_session(callback)
      return
    end

    local persisted = (response and response.persisted) or {}
    local matching = {}
    for _, s in ipairs(persisted) do
      local s_cwd = s.context and s.context.cwd or nil
      if s_cwd == wd then
        table.insert(matching, s)
      end
    end

    if #matching == 0 then
      create_session(callback)
      return
    end

    -- Auto-resume the single match silently — no need to prompt.
    if #matching == 1 then
      local s = matching[1]
      append_entry('system', 'Resuming session ' .. s.sessionId)
      M.resume_session(s.sessionId, callback)
      return
    end

    -- Multiple matches: sort newest-first.
    table.sort(matching, function(a, b)
      local ta = a.modifiedTime or a.startTime or ''
      local tb = b.modifiedTime or b.startTime or ''
      return ta > tb
    end)

    -- auto_resume='auto': silently resume the most recent without prompting.
    if state.config.session.auto_resume == 'auto' then
      local s = matching[1]
      append_entry('system', 'Resuming most recent session ' .. s.sessionId)
      M.resume_session(s.sessionId, callback)
      return
    end

    -- Show a picker; most recent session is listed first (default selection).
    local choices = {}
    for _, s in ipairs(matching) do
      local label = s.sessionId
      if s.summary and s.summary ~= '' then
        label = s.summary .. ' [' .. s.sessionId:sub(1, 8) .. ']'
      else
        local ts = s.modifiedTime or s.startTime or ''
        if ts ~= '' then
          label = s.sessionId:sub(1, 8) .. ' (' .. ts .. ')'
        end
      end
      table.insert(choices, { label = label, id = s.sessionId })
    end
    table.insert(choices, { label = 'Create new session', id = nil })

    local display = vim.tbl_map(function(c)
      return c.label
    end, choices)

    vim.ui.select(display, { prompt = 'Resume a session or start new?' }, function(_, idx)
      if not idx then
        -- <Esc> dismissed the picker — default to the most recent session.
        local default = choices[1]
        if default.id then
          append_entry('system', 'Resumed most recent session ' .. default.id:sub(1, 8) .. ' (picker cancelled)')
          M.resume_session(default.id, callback)
        else
          create_session(callback)
        end
        return
      end
      local picked = choices[idx]
      if picked.id then
        append_entry('system', 'Resuming session ' .. picked.id)
        M.resume_session(picked.id, callback)
      else
        create_session(callback)
      end
    end)
  end)
end

create_session = function(callback, opts)
  opts = opts or {}
  request('POST', '/sessions', {
    clientName = state.config.client_name,
    permissionMode = state.permission_mode or state.config.permission_mode,
    workingDirectory = working_directory(),
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
          append_entry('system', 'Retrying session creation with model ' .. reselected_model)
          state.creating_session = true
          create_session(callback, { model_selection_attempts = false })
        end)
        return
      end
      notify('Failed to create session: ' .. err, vim.log.levels.ERROR)
      append_entry('error', 'Failed to create session: ' .. err)
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

    start_event_stream(state.session_id)
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

function M.with_session(callback)
  if state.session_id then
    callback(state.session_id)
    return
  end

  table.insert(state.pending_session_callbacks, callback)
  if state.creating_session then
    return
  end

  state.creating_session = true
  M.pick_or_create_session(nil)
end

return M
