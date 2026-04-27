-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local uv = vim.uv or vim.loop
local utils = require('copilot_agent.utils')

local M = {}

-- Aliases from http module (used as locals throughout for backward compat).
local build_url = http.build_url
local ensure_curl = http.ensure_curl
local decode_json = http.decode_json
local encode_json = http.encode_json
local sync_request = http.sync_request
local raw_request = http.raw_request
local request = http.request

-- Aliases from service module.
local cwd = service.cwd
local working_directory = service.working_directory
local plugin_root = service.plugin_root
local service_cwd = service.service_cwd
local installed_binary_path = service.installed_binary_path
local service_command = service.service_command
local remember_service_output = service.remember_service_output
local last_service_output = service.last_service_output
local ensure_service_running = service.ensure_service_running

-- Aliases from statusline module.
local statusline_mode = sl.statusline_mode
local statusline_model = sl.statusline_model
local statusline_busy = sl.statusline_busy
local statusline_attachments = sl.statusline_attachments
local statusline_permission = sl.statusline_permission
local statusline_component = sl.statusline_component
local refresh_input_statusline = sl.refresh_input_statusline
local refresh_chat_statusline = sl.refresh_chat_statusline
local refresh_statuslines = sl.refresh_statuslines

-- Aliases from render module.
local stop_thinking_spinner = render.stop_thinking_spinner
local start_thinking_spinner = render.start_thinking_spinner
local notify_render_plugins = render.notify_render_plugins
local entry_lines = render.entry_lines
local chat_at_bottom = render.chat_at_bottom
local scroll_to_bottom = render.scroll_to_bottom
local apply_chat_highlights = render.apply_chat_highlights
local render_chat = render.render_chat
local schedule_render = render.schedule_render
local stream_update = render.stream_update
local append_entry = render.append_entry
local ensure_assistant_entry = render.ensure_assistant_entry
local clear_transcript = render.clear_transcript

local cfg = require('copilot_agent.config')
local defaults = cfg.defaults
local state = cfg.state
local SLASH_COMMANDS = cfg.SLASH_COMMANDS
local notify = cfg.notify
local notify_transient = cfg.notify_transient
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

-- Aliases from events module.
local stop_event_stream = events.stop_event_stream
local start_event_stream = events.start_event_stream
local show_user_input_picker = events.show_user_input_picker
local handle_user_input = events.handle_user_input
local handle_host_event = events.handle_host_event
local offer_diff_review = events.offer_diff_review
local handle_session_event = events.handle_session_event
local flush_sse_event = events.flush_sse_event
local consume_sse_line = events.consume_sse_line
local handle_sse_chunk = events.handle_sse_chunk

local is_thinking_content = utils.is_thinking_content
local split_lines = utils.split_lines

-- Aliases from session module.
local discard_pending_attachments = session.discard_pending_attachments
local disconnect_session = session.disconnect_session
local resume_session = session.resume_session
local with_session = session.with_session

-- Aliases from model module.
local store_model_cache = mdl.store_model_cache
local model_completion_items = mdl.model_completion_items
local apply_model = mdl.apply_model
local fetch_models = mdl.fetch_models

-- Aliases from chat module.
local pick_path = chat.pick_path
local ensure_chat_window = chat.ensure_chat_window
local set_agent_mode = chat.set_agent_mode
local setup_action_keymaps = chat.setup_action_keymaps

-- Aliases from input module.
local open_input_window = input.open_input_window

-- Internal bridge for cross-module access to append_entry (used by service.lua).
M._append_entry = append_entry
-- Internal bridges for cross-module access from events.lua / session.lua.
M._ensure_chat_window = ensure_chat_window
M._set_agent_mode = set_agent_mode
M._open_input_window = open_input_window
M._pick_path = pick_path

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
        resume_session(picked.id)
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
M.statusline_mode = statusline_mode
M.statusline_model = statusline_model
M.statusline_busy = statusline_busy
M.statusline_attachments = statusline_attachments
M.statusline_permission = statusline_permission
M.statusline = statusline_component

-- Build the command list for the LSP server process.
-- We do NOT pass --addr so the OS assigns a free port.
-- The bound address is announced via COPILOT_AGENT_ADDR= on stdout.
local function lsp_command()
  local cmd = service_command()
  return vim.deepcopy(cmd)
end

-- Capture the clipboard image and add it to pending_attachments.
-- Saves clipboard PNG to a temp file, then inserts as an image attachment.
-- Supports macOS (pngpaste), Linux/Wayland (wl-paste), Linux/X11 (xclip, xsel).
function M.paste_clipboard_image()
  local tmpfile = vim.fn.tempname() .. '.png'
  local sysname = (uv.os_uname() or {}).sysname or ''

  local cmd
  if sysname == 'Darwin' then
    if vim.fn.executable('pngpaste') == 1 then
      cmd = { 'pngpaste', tmpfile }
    else
      notify('pngpaste not found. Install with: brew install pngpaste', vim.log.levels.ERROR)
      return
    end
  elseif sysname == 'Linux' then
    if vim.env.WAYLAND_DISPLAY and vim.fn.executable('wl-paste') == 1 then
      cmd = { 'sh', '-c', 'wl-paste --type image/png > ' .. vim.fn.shellescape(tmpfile) }
    elseif vim.fn.executable('xclip') == 1 then
      cmd = { 'sh', '-c', 'xclip -selection clipboard -t image/png -o > ' .. vim.fn.shellescape(tmpfile) }
    elseif vim.fn.executable('xsel') == 1 then
      cmd = { 'sh', '-c', 'xsel --clipboard --output --type image/png > ' .. vim.fn.shellescape(tmpfile) }
    else
      notify('No clipboard image tool found. Install pngpaste (macOS) or wl-paste/xclip (Linux).', vim.log.levels.ERROR)
      return
    end
  else
    notify('Clipboard image paste is not supported on this platform.', vim.log.levels.WARN)
    return
  end

  vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local stat = uv.fs_stat(tmpfile)
        if exit_code ~= 0 or not stat or stat.size == 0 then
          notify('No image found on clipboard (exit=' .. exit_code .. '). Copy an image first.', vim.log.levels.WARN)
          return
        end
        table.insert(state.pending_attachments, {
          type = 'image',
          path = tmpfile,
          display = '🖼️ clipboard.png',
          temp = true, -- delete after send; see M.ask()
        })
        refresh_statuslines()
        notify('Image from clipboard added as attachment.', vim.log.levels.INFO)
        if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
          vim.api.nvim_set_current_win(state.input_winid)
          vim.cmd('startinsert!')
        end
      end)
    end,
  })
end

-- Start the Copilot agent as a single process that runs both the HTTP bridge
-- Download the pre-built copilot-agent binary for the current platform from
-- the latest GitHub release and save it to <plugin_root>/bin/copilot-agent[.exe].
-- After a successful download the binary is used automatically on next startup
-- (service.command = nil auto-detects it).
function M.install_binary(opts)
  opts = opts or {}
  local uname = vim.uv.os_uname()

  -- Detect GOOS
  local os_name
  local sysname = uname.sysname
  if sysname == 'Darwin' then
    os_name = 'darwin'
  elseif sysname == 'Linux' then
    os_name = 'linux'
  elseif sysname:find('Windows') then
    os_name = 'windows'
  else
    notify('install_binary: unsupported OS: ' .. sysname, vim.log.levels.ERROR)
    return
  end

  -- Detect GOARCH
  local arch
  local machine = uname.machine
  if machine == 'x86_64' or machine == 'AMD64' then
    arch = 'amd64'
  elseif machine == 'aarch64' or machine == 'arm64' then
    arch = 'arm64'
  else
    notify('install_binary: unsupported architecture: ' .. machine, vim.log.levels.ERROR)
    return
  end

  local ext = os_name == 'windows' and '.exe' or ''
  local target = os_name .. '-' .. arch
  local filename = 'copilot-agent-' .. target .. ext
  local repo = opts.repo or 'ray-x/copilot-agent.nvim'
  local release_tag = opts.tag or 'latest'
  local url = ('https://github.com/%s/releases/download/%s/%s'):format(repo, release_tag, filename)

  local bin_dir = plugin_root() .. '/bin'
  local out_path = bin_dir .. '/copilot-agent' .. ext

  vim.fn.mkdir(bin_dir, 'p')
  notify(('Downloading %s for %s/%s …'):format(filename, os_name, arch), vim.log.levels.INFO)

  local stderr_lines = {}
  vim.fn.jobstart({ 'curl', '-fsSL', '--progress-bar', '-o', out_path, url }, {
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then
          table.insert(stderr_lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        local detail = #stderr_lines > 0 and (': ' .. table.concat(stderr_lines, ' ')) or ''
        notify('Download failed (exit ' .. code .. ')' .. detail, vim.log.levels.ERROR)
        vim.fn.delete(out_path)
        return
      end
      if ext == '' then
        vim.fn.system({ 'chmod', '+x', out_path })
      end
      notify('copilot-agent installed → ' .. out_path .. '\nRestart Neovim or run :CopilotAgentStart', vim.log.levels.INFO)
      if opts.on_complete then
        opts.on_complete(out_path)
      end
    end,
  })
end

-- service and the LSP server on stdio. The Neovim LSP client owns the process
-- lifetime; ensure_service_running reuses it for HTTP health-checks.
function M.start_lsp(opts)
  opts = opts or {}

  -- If an LSP client with this name is already running for this root, reuse it.
  local root = opts.root_dir or working_directory()
  for _, client in ipairs(vim.lsp.get_clients({ name = 'copilot-agent' })) do
    if client.config.root_dir == root then
      return client.id
    end
  end

  local cmd = lsp_command()

  -- Wrap cmd in a shell that tees stderr so COPILOT_AGENT_ADDR= is captured.
  -- stdout is kept clean for the LSP protocol.
  local stderr_fifo = vim.fn.tempname()
  local wrapped_cmd = {
    'sh',
    '-c',
    table.concat(vim.tbl_map(vim.fn.shellescape, cmd), ' ') .. ' 2>' .. vim.fn.shellescape(stderr_fifo),
  }
  -- Read the tee'd stderr in a background job so we can parse COPILOT_AGENT_ADDR.
  vim.fn.jobstart({ 'tail', '-F', stderr_fifo }, {
    on_stdout = function(_, data)
      vim.schedule(function()
        remember_service_output(data)
      end)
    end,
  })
  local client_id = vim.lsp.start({
    name = 'copilot-agent',
    cmd = wrapped_cmd,
    cmd_cwd = service_cwd(),
    root_dir = root,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    on_init = function(client)
      -- Record the LSP client id so the service is considered started.
      state.lsp_client_id = client.id
      notify('Copilot agent started (LSP id=' .. client.id .. ')', vim.log.levels.INFO)
      -- Kick any pending service callbacks now that the HTTP port is up.
      ensure_service_running(function() end)
    end,
    on_exit = function(code, signal)
      state.lsp_client_id = nil
      pcall(os.remove, stderr_fifo)
      if code ~= 0 then
        notify('Copilot agent exited: code=' .. code .. ' signal=' .. tostring(signal), vim.log.levels.WARN)
      end
    end,
  })

  if not client_id then
    notify('Failed to start Copilot agent LSP', vim.log.levels.ERROR)
  end
  return client_id
end

-- Expose internal state for :checkhealth and debugging.
M.state = state

return M
