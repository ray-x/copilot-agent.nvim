-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local M = {}

-- Wrap vim.treesitter.start with a safe pcall wrapper to avoid E5113 runtime
-- errors in headless or limited runtimes where internal npcalls may be nil.
if type(vim) == 'table' and type(vim.treesitter) == 'table' and type(vim.treesitter.start) == 'function' then
  local _orig_treesitter_start = vim.treesitter.start
  vim.treesitter.start = function(...)
    local ok, err = pcall(_orig_treesitter_start, ...)
    if not ok then
      local ok_log, logger = pcall(require, 'copilot_agent.log')
      if ok_log and type(logger.log) == 'function' then
        logger.log('vim.treesitter.start suppressed error: ' .. tostring(err), vim.log.levels.DEBUG)
      end
      return nil
    end
  end
end

-- ── Module requires ───────────────────────────────────────────────────────────
local cfg = require('copilot_agent.config')
local defaults = cfg.defaults
local state = cfg.state
local notify = cfg.notify
local log = cfg.log
local normalize_base_url = cfg.normalize_base_url

local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')
local events = require('copilot_agent.events')
local session = require('copilot_agent.session')
local mdl = require('copilot_agent.model')
local chat = require('copilot_agent.chat')
local dashboard = require('copilot_agent.dashboard')
local input = require('copilot_agent.input')
local lsp = require('copilot_agent.lsp')
local prompt = require('copilot_agent.prompt')
local commit = require('copilot_agent.commit')

-- ── Local aliases ─────────────────────────────────────────────────────────────
local ensure_service_running = service.ensure_service_running
local append_entry = render.append_entry
local ensure_chat_window = chat.ensure_chat_window

local function set_activity_diff_highlights()
  if vim.fn.hlexists('GitSignsAdd') == 1 then
    vim.api.nvim_set_hl(0, 'CopilotAgentActivityDiffAdd', { link = 'GitSignsAdd', default = true })
  else
    vim.api.nvim_set_hl(0, 'CopilotAgentActivityDiffAdd', { fg = '#22c55e', default = true })
  end

  if vim.fn.hlexists('GitSignsDelete') == 1 then
    vim.api.nvim_set_hl(0, 'CopilotAgentActivityDiffDelete', { link = 'GitSignsDelete', default = true })
  else
    vim.api.nvim_set_hl(0, 'CopilotAgentActivityDiffDelete', { fg = '#ef4444', default = true })
  end
end

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

function M.open_dashboard()
  return dashboard.open()
end

function M.close_dashboard()
  dashboard.close()
end

local function quoted_shell_arg(arg)
  arg = tostring(arg or '')
  if arg == '' then
    return "''"
  end
  if arg:find('%s') or arg:find('"', 1, true) or arg:find("'", 1, true) or arg:find('`', 1, true) or arg:find('$', 1, true) or arg:find('\\', 1, true) then
    return vim.fn.shellescape(arg)
  end
  return arg
end

local function describe_service_launch()
  if state.config.service.auto_start ~= true then
    return 'external (auto_start=false)'
  end

  local command = service.service_command()
  local cwd = service.service_cwd()
  if type(command) == 'table' and #command > 0 then
    local parts = {}
    for _, arg in ipairs(command) do
      parts[#parts + 1] = quoted_shell_arg(arg)
    end
    return string.format('auto-start: %s  (cwd: %s)', table.concat(parts, ' '), cwd)
  end
  if type(command) == 'string' and command ~= '' then
    return string.format('auto-start: %s  (cwd: %s)', command, cwd)
  end
  return string.format('auto-start: <invalid command>  (cwd: %s)', cwd)
end

function M.setup(opts)
  local normalized_opts = vim.deepcopy(opts or {})
  -- Back-compat: allow top-level auto_start to mirror service.auto_start.
  if normalized_opts.auto_start ~= nil and (type(normalized_opts.service) ~= 'table' or normalized_opts.service.auto_start == nil) then
    normalized_opts.service = vim.tbl_deep_extend('force', normalized_opts.service or {}, {
      auto_start = normalized_opts.auto_start,
    })
  end

  state.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), normalized_opts)
  local explicit_base_url = nil
  if type(normalized_opts.base_url) == 'string' then
    explicit_base_url = vim.trim(normalized_opts.base_url):gsub('/+$', '')
    if explicit_base_url == '' then
      explicit_base_url = nil
    end
  end
  local legacy_default_base_url = defaults.base_url:gsub('/+$', '')
  local explicit_default_base_url = explicit_base_url ~= nil and explicit_base_url == legacy_default_base_url

  -- Keep backward compatibility for configs that explicitly set the historical
  -- default base_url (127.0.0.1:8088) while still using auto-started managed
  -- service discovery.
  state.base_url_managed = explicit_base_url == nil or (explicit_default_base_url and state.config.service.auto_start == true)
  if state.base_url_managed then
    -- In managed mode the service address is discovered dynamically via control socket.
    -- Do not preload the legacy 8088 fallback into UI/state before discovery completes.
    state.config.base_url = ''
  end
  state.config.base_url = normalize_base_url(state.config.base_url)
  state.service_launch_info = describe_service_launch()
  state.service_job_id = nil
  state.service_process_pid = nil
  state.client_registered_base_url = nil
  state.service_starting = false
  state.service_addr_known = false
  state.pending_service_callbacks = {}
  state.service_output = {}
  state.lsp_client_id = nil
  state.shutting_down = false
  -- Initialize runtime permission mode from config.
  state.permission_mode = state.config.permission_mode or 'interactive'
  -- Reset transient live activity / overlay state when setup is rerun.
  state.active_tool = nil
  state.active_tool_run_id = nil
  state.active_tool_detail = nil
  state.pending_tool_detail = nil
  state.overlay_tool_display = nil
  state.overlay_tool_queue = {}
  state.overlay_tool_schedule_token = (tonumber(state.overlay_tool_schedule_token) or 0) + 1
  state.post_tool_use_hooks = {}
  state.recent_activity_lines = {}
  state.recent_activity_items = {}
  state.recent_activity_tool_calls = {}
  state.activity_entries_visible = false
  state.current_intent = nil
  state.background_tasks = {}
  state.overlay_gutter_restore_view = nil
  state.chat_tail_spacer_lines = 0
  state.chat_default_conceallevel = nil
  state._rendered_line_count = nil
  state.reasoning_entry_key = nil
  state.reasoning_text = ''
  state.reasoning_lines = {}
  state.last_assistant_usage = nil
  state.dashboard_winid = nil
  state.dashboard_prompt_bufnr = nil
  state.dashboard_prompt_winid = nil
  state._toggle_restore_input = false
  state._toggle_restore_compose = false
  state.active_turn_assistant_index = nil
  state.live_assistant_entry_index = nil
  state.active_turn_assistant_message_id = nil
  state.active_assistant_merge_group = nil
  state.assistant_merge_group_serial = 0

  -- Default highlight groups for the chat buffer (link targets can be overridden
  -- by the user's colorscheme or config before calling setup()).
  vim.api.nvim_set_hl(0, 'CopilotAgentUser', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentAssistant', { link = 'Function', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDone', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentRule', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentCheckpoint', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentActivity', { link = 'DiagnosticVirtualTextInfo', default = true })
  set_activity_diff_highlights()
  vim.api.nvim_set_hl(0, 'CopilotAgentReasoning', { link = 'DiagnosticVirtualTextInfo', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentOverlayStrong', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentOverlayEmphasis', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentOverlayCode', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentOverlayQuoted', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentStatuslineCount', { link = 'Number', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDashboardHeader', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDashboardArt', { link = '@text', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDashboardKey', { link = 'Function', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDashboardHint', { link = 'Comment', default = true })
  prompt.configure_highlights()
  local ui_group = vim.api.nvim_create_augroup('CopilotAgentUI', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = ui_group,
    callback = function()
      set_activity_diff_highlights()
      prompt.configure_highlights()
    end,
  })
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized', 'WinScrolled' }, {
    group = ui_group,
    callback = function(args)
      require('copilot_agent.statusline').refresh_statuslines()
      if args.event == 'WinScrolled' then
        render.handle_chat_window_scrolled(tonumber(args.match))
      end
      render.refresh_reasoning_overlay(true)
      dashboard.refresh()
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
  -- start dashboard on VimEnter if enabled in config and there are no startup buffers (e.g. when Neovim is started with just a directory or no arguments).
  -- vim.api.nvim_create_autocmd('VimEnter', {
  -- group = ui_group,
  -- once = true,
  -- callback = function()
  -- dashboard.maybe_open_on_startup()
  -- end,
  -- })
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
      log(string.format('VimLeavePre cleanup start pid=%d', vim.fn.getpid()), vim.log.levels.DEBUG)
      state.shutting_down = true
      local ok, err = pcall(events.stop_event_stream)
      if ok then
        log('VimLeavePre stopped event stream', vim.log.levels.DEBUG)
      else
        log('VimLeavePre stop_event_stream failed: ' .. tostring(err), vim.log.levels.WARN)
      end
      local logger_ok, logger = pcall(require, 'copilot_agent.log')
      local attachments_ok, attachments_err = pcall(session.discard_pending_attachments)
      if attachments_ok then
        log('VimLeavePre discarded pending attachments', vim.log.levels.DEBUG)
      else
        log('VimLeavePre discard_pending_attachments failed: ' .. tostring(attachments_err), vim.log.levels.WARN)
      end
      local unregister_ok, unregister_err = pcall(service.unregister_client)
      if unregister_ok then
        log('VimLeavePre unregistered client', vim.log.levels.DEBUG)
      else
        log('VimLeavePre unregister_client failed: ' .. tostring(unregister_err), vim.log.levels.WARN)
      end
      local stop_ok, stop_err = pcall(service.stop_service)
      if stop_ok then
        log('VimLeavePre stop_service completed', vim.log.levels.DEBUG)
      else
        log('VimLeavePre stop_service failed: ' .. tostring(stop_err), vim.log.levels.WARN)
      end
      if logger_ok and type(logger.flush_pending) == 'function' then
        local flush_ok, flush_err = pcall(logger.flush_pending)
        if flush_ok then
          log('VimLeavePre flushed pending logs', vim.log.levels.DEBUG)
          pcall(logger.flush_pending)
        else
          log('VimLeavePre flush_pending failed: ' .. tostring(flush_err), vim.log.levels.WARN)
        end
      end
    end,
  })
  vim.schedule(function()
    require('copilot_agent.checkpoints').prune_deleted()
  end)
  -- Eagerly connect to an existing shared service or start one if needed.
  -- Session creation is still deferred until the user opens chat.
  if state.config.service.auto_start then
    vim.schedule(function()
      ensure_service_running(function(err)
        if err then
          notify('Failed to start Copilot service: ' .. err, vim.log.levels.ERROR)
          return
        end
        if state.config.lsp and state.config.lsp.enabled then
          lsp.start_lsp()
        end
      end)
    end)
  elseif state.config.lsp and state.config.lsp.enabled then
    vim.schedule(function()
      lsp.start_lsp()
    end)
  end
  return M
end

function M.open_chat(opts)
  -- Default to collapsed activity summaries whenever chat is (re)opened.
  state.activity_entries_visible = false
  ensure_chat_window(opts)

  -- If ensure_chat_window somehow didn't create the buffer (rare race), try once more.
  if not state.chat_bufnr or not vim.api.nvim_buf_is_valid(state.chat_bufnr) then
    pcall(ensure_chat_window, opts)
  end

  if state.config.auto_create_session and not state.session_id then
    session.with_session(function() end, {
      open_input_on_session_ready = opts == nil or opts.activate_input_on_session_ready ~= false,
    })
  end

  -- Defensive: ensure chat_winid is populated before returning to synchronous callers
  if not state.chat_winid then
    local ok, found = pcall(chat.find_chat_window)
    if ok and found then
      state.chat_winid = found
    end
  end

  -- Defensive: if the buffer handle was lost but the chat window still exists,
  -- recover the buffer from that window so callers can keep using it safely.
  if not state.chat_bufnr or not vim.api.nvim_buf_is_valid(state.chat_bufnr) then
    local winid = state.chat_winid
    if not (winid and vim.api.nvim_win_is_valid(winid)) then
      local ok, found = pcall(chat.find_chat_window)
      if ok and found then
        winid = found
        state.chat_winid = found
      end
    end
    if winid and vim.api.nvim_win_is_valid(winid) then
      local ok, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
      if ok and type(bufnr) == 'number' and vim.api.nvim_buf_is_valid(bufnr) then
        state.chat_bufnr = bufnr
      end
    end
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

function M.ask(prompt_text, opts)
  chat.ask(prompt_text, opts)
end

function M.open_compose(opts)
  chat.ensure_chat_window({
    activate_input_on_session_ready = false,
  })
  input.open_compose_buffer(opts)
end

function M.promote_to_compose()
  chat.ensure_chat_window({
    activate_input_on_session_ready = false,
  })
  input.promote_input_to_compose()
end

function M.send_buffer()
  input.send_buffer()
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

function M.fugitive_commit(arg)
  commit.fugitive_commit(arg)
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
  service.refresh_managed_base_url()
  local snapshot = service.debug_snapshot()
  local lines = {
    'service: ' .. normalize_base_url(state.config.base_url),
    'session: ' .. (state.session_id or '<none>'),
    'model: ' .. tostring(state.config.session.model or '<default>'),
    'service_job: ' .. tostring(state.service_job_id or '<none>'),
    'service_starting: ' .. tostring(state.service_starting),
    'streaming: ' .. tostring(state.events_job_id ~= nil),
    'buffer: ' .. tostring(state.chat_bufnr or '<none>'),
    'control_socket: ' .. tostring(snapshot.control_socket_present),
    'addr_file: ' .. tostring(snapshot.addr_file_present),
    'shared_pid: ' .. tostring(snapshot.shared_service_pid or '<none>'),
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

function M.debug_service()
  service.refresh_managed_base_url()
  local snapshot = service.debug_snapshot()
  local lines = {
    'Service debug:',
    '  managed_mode: ' .. tostring(snapshot.managed_mode),
    '  auto_start: ' .. tostring(snapshot.auto_start),
    '  detach: ' .. tostring(snapshot.detach),
    '  base_url: ' .. tostring(snapshot.base_url),
    '  service_addr_known: ' .. tostring(snapshot.service_addr_known),
    '  service_starting: ' .. tostring(snapshot.service_starting),
    '  service_job_id: ' .. tostring(snapshot.service_job_id or '<none>'),
    '  service_process_pid: ' .. tostring(snapshot.service_process_pid or '<none>'),
    '  pending_callbacks: ' .. tostring(snapshot.pending_callback_count),
    '  launch_command: ' .. tostring(snapshot.launch_command),
    '  launch_cwd: ' .. tostring(snapshot.launch_cwd),
    '  control_socket_present: ' .. tostring(snapshot.control_socket_present),
    '  control_socket_path: ' .. tostring(snapshot.control_socket_path),
    '  control_service_addr: ' .. tostring(snapshot.control_service_addr or '<none>'),
    '  control_service_addr_error: ' .. tostring(snapshot.control_service_addr_error or '<none>'),
    '  control_health_status: ' .. tostring(snapshot.control_health_status or '<none>'),
    '  control_health_error: ' .. tostring(snapshot.control_health_error or '<none>'),
    '  addr_file_present: ' .. tostring(snapshot.addr_file_present),
    '  addr_file_path: ' .. tostring(snapshot.addr_file_path),
    '  addr_file_value: ' .. tostring(snapshot.addr_file_value or '<none>'),
    '  pid_file_present: ' .. tostring(snapshot.pid_file_present),
    '  pid_file_path: ' .. tostring(snapshot.pid_file_path),
    '  pid_file_value: ' .. tostring(snapshot.pid_file_value or '<none>'),
    '  pid_file_alive: ' .. tostring(snapshot.pid_file_alive),
    '  shared_service_pid: ' .. tostring(snapshot.shared_service_pid or '<none>'),
    '  spawn_lock_present: ' .. tostring(snapshot.spawn_lock_present),
    '  spawn_lock_path: ' .. tostring(snapshot.spawn_lock_path),
    '  last_service_output: ' .. tostring(snapshot.last_service_output or '<none>'),
  }
  append_entry('system', table.concat(lines, '\n'))
  notify('Service debug snapshot added to chat', vim.log.levels.INFO)
  return snapshot
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
M.statusline_tool = sl.statusline_tool
M.statusline_intent = sl.statusline_intent
M.statusline_context = sl.statusline_context
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

function M.execute_slash_command(prompt_text, opts)
  return require('copilot_agent.slash').execute(prompt_text, opts)
end

-- Expose internal state for :checkhealth and debugging.
M.state = state

return M
