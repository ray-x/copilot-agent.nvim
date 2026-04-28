-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local M = {}

-- ── Module requires ───────────────────────────────────────────────────────────
local cfg = require('copilot_agent.config')
local defaults = cfg.defaults
local state = cfg.state
local notify = cfg.notify
local normalize_base_url = cfg.normalize_base_url

local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')
local events = require('copilot_agent.events')
local session = require('copilot_agent.session')
local mdl = require('copilot_agent.model')
local chat = require('copilot_agent.chat')
local input = require('copilot_agent.input')
local lsp = require('copilot_agent.lsp')

-- ── Local aliases (used by public API functions below) ────────────────────────
local request = http.request
local sync_request = http.sync_request
local ensure_service_running = service.ensure_service_running
local refresh_statuslines = sl.refresh_statuslines
local append_entry = render.append_entry
local clear_transcript = render.clear_transcript
local schedule_render = render.schedule_render
local show_user_input_picker = events.show_user_input_picker
local discard_pending_attachments = session.discard_pending_attachments
local disconnect_session = session.disconnect_session
local with_session = session.with_session
local apply_model = mdl.apply_model
local fetch_models = mdl.fetch_models
local model_completion_items = mdl.model_completion_items
local store_model_cache = mdl.store_model_cache
local ensure_chat_window = chat.ensure_chat_window
local set_agent_mode = chat.set_agent_mode
local open_input_window = input.open_input_window

-- ── Internal bridges for cross-module access ──────────────────────────────────
M._append_entry = append_entry
M._ensure_chat_window = ensure_chat_window
M._set_agent_mode = set_agent_mode
M._open_input_window = open_input_window
M._pick_path = chat.pick_path

function M.setup(opts)
  state.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  state.config.base_url = normalize_base_url(state.config.base_url)
  -- Initialize runtime permission mode from config.
  state.permission_mode = state.config.permission_mode or 'interactive'

  -- Default highlight groups for the chat buffer (link targets can be overridden
  -- by the user's colorscheme or config before calling setup()).
  vim.api.nvim_set_hl(0, 'CopilotAgentUser', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentAssistant', { link = 'Function', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDone', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentRule', { link = 'WinSeparator', default = true })
  -- Clean up clipboard temp files if Neovim exits before they were sent.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('CopilotAgentCleanup', { clear = true }),
    callback = function()
      discard_pending_attachments()
    end,
  })
  -- Eagerly start the Go service in the background so it is ready by
  -- the time the user opens the chat window. Session creation is deferred
  -- until the user actually opens the chat to avoid prompting for session
  -- selection at startup.
  if state.config.auto_create_session and state.config.service.auto_start then
    vim.schedule(function()
      ensure_service_running(function() end)
    end)
  end
  return M
end

function M.open_chat()
  ensure_chat_window()
  if state.config.auto_create_session and not state.session_id and not state.creating_session then
    with_session(function() end)
  end
  return state.chat_bufnr
end

function M.new_session()
  local previous_session_id = state.session_id
  state.session_id = nil
  state.session_name = nil
  discard_pending_attachments()
  clear_transcript()
  M.open_chat()
  disconnect_session(previous_session_id, false, function(err)
    if err then
      append_entry('error', 'Failed to disconnect previous session: ' .. err)
      return
    end
    with_session(function(session_id, create_err)
      if create_err then
        append_entry('error', create_err)
        return
      end
      append_entry('system', 'Created session ' .. session_id)
    end)
  end)
end

function M.switch_session()
  request('GET', '/sessions', nil, function(response, err)
    if err then
      notify('Failed to list sessions: ' .. err, vim.log.levels.ERROR)
      return
    end

    local persisted = (response and response.persisted) or {}
    if #persisted == 0 then
      notify('No sessions found. Use :CopilotAgentNewSession to create one.', vim.log.levels.INFO)
      return
    end

    -- Sort newest-first.
    table.sort(persisted, function(a, b)
      local ta = a.modifiedTime or a.startTime or ''
      local tb = b.modifiedTime or b.startTime or ''
      return ta > tb
    end)

    local choices = {}
    for _, s in ipairs(persisted) do
      local label = s.sessionId:sub(1, 8)
      if s.summary and s.summary ~= '' then
        label = s.summary .. ' [' .. label .. ']'
      else
        local ts = s.modifiedTime or s.startTime or ''
        if ts ~= '' then
          label = label .. ' (' .. ts .. ')'
        end
      end
      local cwd_label = ''
      if s.context and s.context.cwd then
        cwd_label = '  ' .. vim.fn.fnamemodify(s.context.cwd, ':~')
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
      discard_pending_attachments()
      clear_transcript()
      ensure_chat_window()
      disconnect_session(previous_session_id, false, function(disconnect_err)
        if disconnect_err then
          append_entry('error', 'Failed to disconnect previous session: ' .. disconnect_err)
        end
        append_entry('system', 'Switching to session ' .. picked.id:sub(1, 8) .. '…')
        session.resume_session(picked.id)
      end)
    end)
  end)
end

function M.ask(prompt, opts)
  opts = opts or {}
  local text = prompt
  if text == nil or text == '' then
    M.open_chat()
    open_input_window()
    return
  end

  M.open_chat()
  append_entry('user', text, opts.attachments and #opts.attachments > 0 and vim.deepcopy(opts.attachments) or nil)
  -- Mark busy immediately so the spinner shows before the first delta arrives.
  state.chat_busy = true
  refresh_statuslines()
  schedule_render()

  -- Build attachment list for the API.
  local api_attachments = {}
  local temp_files = {} -- clipboard image temp files to delete after send
  for _, a in ipairs(opts.attachments or {}) do
    if a.type == 'file' or a.type == 'directory' or a.type == 'image' then
      table.insert(api_attachments, { type = 'file', path = a.path })
      if a.temp then
        temp_files[#temp_files + 1] = a.path
      end
    elseif a.type == 'selection' then
      table.insert(api_attachments, {
        type = 'selection',
        filePath = a.path,
        text = a.text,
        lineRange = a.start_line and { start = a.start_line, ['end'] = a.end_line } or nil,
      })
    end
  end

  with_session(function(session_id, err)
    if err then
      state.chat_busy = false
      refresh_statuslines()
      append_entry('error', err)
      return
    end
    local body = { prompt = text }
    if #api_attachments > 0 then
      body.attachments = api_attachments
    end
    request('POST', string.format('/sessions/%s/messages', session_id), body, function(_, request_err)
      -- Clean up any clipboard temp PNGs — the HTTP request has been delivered.
      for _, p in ipairs(temp_files) do
        pcall(os.remove, p)
      end
      if request_err then
        state.chat_busy = false
        refresh_statuslines()
        append_entry('error', 'Failed to send prompt: ' .. request_err)
      end
    end)
  end)
end

function M.select_model(model)
  if model and model ~= '' then
    apply_model(model, function(_, err)
      if err then
        notify('Failed to set model: ' .. err, vim.log.levels.ERROR)
      end
    end)
    return
  end

  fetch_models(function(models, err)
    if err then
      notify('Failed to list models: ' .. err, vim.log.levels.ERROR)
      append_entry('error', 'Failed to list models: ' .. err)
      return
    end
    if type(models) ~= 'table' or vim.tbl_isempty(models) then
      append_entry('error', 'No models returned by service')
      return
    end

    vim.ui.select(models, {
      prompt = 'Select Copilot model',
      format_item = function(item)
        local label = item.label
        if item.supports_reasoning and #(item.supported_efforts or {}) > 0 then
          label = label .. ' 🧠'
        end
        return label
      end,
    }, function(choice)
      if not choice then
        return
      end
      -- If the model supports reasoning effort, prompt for it.
      if choice.supports_reasoning and #(choice.supported_efforts or {}) > 0 then
        local efforts = {}
        for _, e in ipairs(choice.supported_efforts) do
          local label = e
          if e == (choice.default_effort or '') then
            label = label .. ' (default)'
          end
          table.insert(efforts, { id = e, label = label })
        end
        vim.ui.select(efforts, {
          prompt = 'Reasoning effort for ' .. choice.name,
          format_item = function(item)
            return item.label
          end,
        }, function(effort_choice)
          local reasoning = effort_choice and effort_choice.id or nil
          apply_model(choice.id, function(_, apply_err)
            if apply_err then
              notify('Failed to set model: ' .. apply_err, vim.log.levels.ERROR)
              append_entry('error', 'Failed to set model: ' .. apply_err)
            end
          end, { reasoning_effort = reasoning })
        end)
        return
      end
      apply_model(choice.id, function(_, apply_err)
        if apply_err then
          notify('Failed to set model: ' .. apply_err, vim.log.levels.ERROR)
          append_entry('error', 'Failed to set model: ' .. apply_err)
        end
      end)
    end)
  end)
end

function M.complete_model(arglead)
  if #state.model_cache == 0 then
    local response = select(1, sync_request('GET', '/models', nil))
    if response and type(response.models) == 'table' then
      store_model_cache(response.models)
    elseif state.config.service.auto_start and not state.service_starting then
      ensure_service_running(function(err)
        if not err then
          fetch_models(function() end)
        end
      end)
    end
  end

  return model_completion_items(arglead)
end

function M.start_service(callback)
  ensure_service_running(function(err)
    if err then
      notify('Failed to start service: ' .. err, vim.log.levels.ERROR)
      append_entry('error', 'Failed to start service: ' .. err)
      if callback then
        callback(nil, err)
      end
      return
    end
    append_entry('system', 'Service ready at ' .. normalize_base_url(state.config.base_url))
    if callback then
      callback(true)
    end
  end)
end

function M.stop(delete_state)
  if not state.session_id then
    append_entry('system', 'No active session')
    return
  end

  local session_id = state.session_id
  state.session_id = nil
  discard_pending_attachments()
  clear_transcript()
  disconnect_session(session_id, delete_state, function(err)
    if err then
      append_entry('error', 'Failed to disconnect session: ' .. err)
      return
    end
    append_entry('system', 'Disconnected session ' .. session_id)
  end)
end

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

function M.retry_input()
  if not state.pending_user_input then
    notify('No pending input request to retry', vim.log.levels.INFO)
    return
  end
  show_user_input_picker(state.pending_user_input)
end

function M.status()
  local lines = {
    'service: ' .. normalize_base_url(state.config.base_url),
    'session: ' .. (state.session_id or '<none>'),
    'model: ' .. tostring(state.config.session.model or '<default>'),
    'service_job: ' .. tostring(state.service_job_id or '<none>'),
    'service_starting: ' .. tostring(state.service_starting),
    'streaming: ' .. tostring(state.events_job_id ~= nil),
    'buffer: ' .. tostring(state.chat_bufnr or '<none>'),
  }
  notify(table.concat(lines, ' | '))
  return {
    session_id = state.session_id,
    service_job_id = state.service_job_id,
    service_starting = state.service_starting,
    events_job_id = state.events_job_id,
    chat_bufnr = state.chat_bufnr,
  }
end

function M.state()
  return state
end

-- ── Statusline component API ──────────────────────────────────────────────────
-- Use these in your statusline plugin (lualine, heirline, feline, etc.)
--
-- Lualine example:
--   lualine.setup { sections = { lualine_x = {
--     require('copilot_agent').statusline_mode,
--     require('copilot_agent').statusline_model,
--     require('copilot_agent').statusline_busy,
--   }}}
--
-- &statusline / heirline example:
--   %{v:lua.require'copilot_agent'.statusline()}
--
M.statusline_mode = sl.statusline_mode
M.statusline_model = sl.statusline_model
M.statusline_busy = sl.statusline_busy
M.statusline_attachments = sl.statusline_attachments
M.statusline_permission = sl.statusline_permission
M.statusline = sl.statusline_component

-- ── LSP / install / clipboard (delegated to lsp module) ──────────────────────
function M.paste_clipboard_image()
  lsp.paste_clipboard_image()
end

function M.install_binary(opts)
  lsp.install_binary(opts)
end

function M.start_lsp(opts)
  return lsp.start_lsp(opts)
end

-- Expose internal state for :checkhealth and debugging.
M.state = state

return M
