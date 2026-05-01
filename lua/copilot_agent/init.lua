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

local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')
local events = require('copilot_agent.events')
local session = require('copilot_agent.session')
local mdl = require('copilot_agent.model')
local chat = require('copilot_agent.chat')
local input = require('copilot_agent.input')
local lsp = require('copilot_agent.lsp')

-- ── Local aliases ─────────────────────────────────────────────────────────────
local ensure_service_running = service.ensure_service_running
local append_entry = render.append_entry
local ensure_chat_window = chat.ensure_chat_window

-- ── Internal bridges for cross-module access ──────────────────────────────────
M._append_entry = append_entry
M._ensure_chat_window = ensure_chat_window
M._set_agent_mode = chat.set_agent_mode
M._open_input_window = input.open_input_window
M._pick_path = chat.pick_path

function M.toggle_chat()
  chat.toggle_chat()
end

function M.focus_chat()
  chat.focus_chat()
end

function M.setup(opts)
  state.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  state.config.base_url = normalize_base_url(state.config.base_url)
  state.base_url_managed = opts == nil or opts.base_url == nil
  -- Initialize runtime permission mode from config.
  state.permission_mode = state.config.permission_mode or 'interactive'

  -- Default highlight groups for the chat buffer (link targets can be overridden
  -- by the user's colorscheme or config before calling setup()).
  vim.api.nvim_set_hl(0, 'CopilotAgentUser', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentAssistant', { link = 'Function', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDone', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentRule', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentCheckpoint', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentReasoning', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentStatuslineCount', { link = 'Number', default = true })
  local ui_group = vim.api.nvim_create_augroup('CopilotAgentUI', { clear = true })
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = ui_group,
    callback = function()
      require('copilot_agent.statusline').refresh_statuslines()
    end,
  })
  vim.api.nvim_create_autocmd('FileChangedShell', {
    group = ui_group,
    callback = function(args)
      if not args.buf or not vim.api.nvim_buf_is_valid(args.buf) then
        return
      end
      if vim.api.nvim_get_option_value('buftype', { buf = args.buf }) ~= '' then
        return
      end
      if vim.v.fcs_reason == 'conflict' or vim.bo[args.buf].modified then
        vim.v.fcs_choice = events.confirm_external_buffer_reload() and 'reload' or ''
        return
      end
      vim.v.fcs_choice = 'reload'
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = ui_group,
    callback = function()
      events.check_open_buffers_for_external_changes()
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'FileChangedShellPost' }, {
    group = ui_group,
    callback = function(args)
      events.remember_buffer_disk_state(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = ui_group,
    callback = function(args)
      events.forget_buffer_disk_state(args.buf)
    end,
  })
  events.remember_open_buffer_disk_state()
  -- Clean up clipboard temp files if Neovim exits before they were sent.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('CopilotAgentCleanup', { clear = true }),
    callback = function()
      session.discard_pending_attachments()
    end,
  })
  vim.schedule(function()
    require('copilot_agent.checkpoints').prune_deleted()
  end)
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

function M.open_chat(opts)
  ensure_chat_window(opts)
  if state.config.auto_create_session and not state.session_id then
    session.with_session(function() end, {
      open_input_on_session_ready = opts == nil or opts.activate_input_on_session_ready ~= false,
    })
  end
  return state.chat_bufnr
end

-- ── Delegated to session.lua ─────────────────────────────────────────────────

function M.new_session()
  session.new_session()
end

function M.switch_session()
  session.switch_session()
end

function M.delete_session()
  session.delete_session()
end

function M.stop(delete_state)
  session.stop(delete_state)
end

function M.cancel()
  session.cancel()
end

-- ── Delegated to chat.lua ────────────────────────────────────────────────────

function M.ask(prompt, opts)
  chat.ask(prompt, opts)
end

-- ── Delegated to model.lua ───────────────────────────────────────────────────

function M.select_model(model)
  mdl.select_model(model)
end

function M.complete_model(arglead)
  return mdl.complete_model(arglead)
end

-- ── Service / misc ───────────────────────────────────────────────────────────

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

function M.retry_input()
  if not state.pending_user_input then
    notify('No pending input request to retry', vim.log.levels.INFO)
    return
  end
  events.show_user_input_picker(state.pending_user_input)
end

function M.review_diff()
  events.review_diff()
end

function M.get_reasoning(max_lines)
  local lines = render.reasoning_lines(max_lines)
  return {
    active = state.reasoning_entry_key ~= nil and #lines > 0,
    entry_key = state.reasoning_entry_key,
    text = state.reasoning_text or '',
    lines = lines,
  }
end

function M.get_reasoning_text()
  return state.reasoning_text or ''
end

function M.get_reasoning_lines(max_lines)
  return render.reasoning_lines(max_lines)
end

function M.statusline_reasoning(max_len)
  return sl.statusline_reasoning(max_len)
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

function M.execute_slash_command(prompt, opts)
  return require('copilot_agent.slash').execute(prompt, opts)
end

-- Expose internal state for :checkhealth and debugging.
M.state = state

return M
