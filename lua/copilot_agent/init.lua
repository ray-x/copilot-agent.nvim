-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local uv = vim.uv or vim.loop
local utils = require('copilot_agent.utils')

local M = {}
local raw_request
local request
local ensure_service_running
local fetch_models
local open_input_window
local ensure_curl
local decode_json
local encode_json
local prompt_supported_model_selection
local render_chat
local setup_action_keymaps

local defaults = {
  -- Default base_url is used when connecting to a pre-built / externally-started
  -- service. When auto_start=true the Go process prints COPILOT_AGENT_ADDR= to
  -- stdout and this value is overwritten with the actual bound address.
  base_url = 'http://127.0.0.1:8088',
  curl_bin = 'curl',
  client_name = 'nvim-copilot',
  permission_mode = 'approve-all',
  auto_create_session = true,
  notify = true,
  service = {
    auto_start = false,
    command = nil, -- nil = auto-detect installed binary, then fall back to 'go run .'
    cwd = nil, -- defaults to <plugin_root>/server
    env = nil,
    port_range = nil, -- e.g. '18000-19000'; appended as --port-range when set
    healthcheck_path = '/healthz',
    startup_timeout_ms = 15000,
    startup_poll_interval_ms = 250,
  },
  chat = {
    split = 'botright vnew',
    title = 'Copilot Chat',
    -- Noisy system messages (permission decisions, etc.) go to vim.notify instead
    -- of the chat buffer. Set to ms > 0 to auto-clear from the cmdline area.
    system_notify_timeout = 3000,
    -- Set to true to enable render-markdown.nvim integration on the chat buffer.
    -- Useful when render-markdown causes visual lag on long responses.
    -- true  = enable on buffer creation, refresh once per completed turn (default)
    -- false = disable entirely (raw markdown text, faster)
    render_markdown = false,
    -- File picker to use when attaching files/folders from <C-a>.
    -- 'auto' detects in order: snacks → telescope → fzf-lua → mini.pick → vim.ui.input
    -- Set to 'native' to always use vim.ui.input (completion-based path entry).
    file_picker = 'auto',
    -- Offer a vimdiff review when the agent modifies a git-tracked file.
    -- true  = prompt 'Open diff / Skip' after each file update (default)
    -- false = just notify and auto-reload the buffer
    diff_review = true,
  },
  session = {
    working_directory = nil,
    model = nil,
    agent = nil,
    streaming = true,
    enable_config_discovery = true,
    -- 'prompt' (default): show a picker when multiple sessions exist for this project.
    -- 'auto': silently resume the most recent matching session without prompting.
    auto_resume = 'prompt',
  },
}

local state = {
  config = vim.deepcopy(defaults),
  session_id = nil,
  events_job_id = nil,
  sse_partial = '',
  sse_event = { event = 'message', data = {} },
  entries = {},
  assistant_entries = {},
  chat_bufnr = nil,
  chat_winid = nil,
  input_bufnr = nil,
  input_winid = nil,
  service_job_id = nil,
  service_starting = false,
  service_addr_known = false, -- set true when COPILOT_AGENT_ADDR= line received
  pending_service_callbacks = {},
  service_output = {},
  model_cache = {},
  creating_session = false,
  pending_session_callbacks = {},
  prompt_history = {},
  prompt_history_index = nil,
  prompt_history_draft = '',
  prompt_prefill = nil, -- text to pre-populate the input buffer (set by chat-buffer history nav)
  lsp_client_id = nil,
  -- Input buffer UI state
  input_mode = 'agent', -- 'ask' | 'plan' | 'agent'
  reasoning_effort = nil, -- current reasoning effort level (nil = model default)
  permission_mode = 'interactive', -- 'interactive' | 'approve-all' | 'autopilot'
  session_name = nil, -- auto-generated name from SDK (updated after each turn)
  pending_attachments = {}, -- list of {type, path, display} waiting to be sent
  chat_busy = false, -- true while the agent is processing a turn
  -- Thinking spinner
  thinking_timer = nil, -- uv timer while assistant is generating
  thinking_frame = 1, -- current spinner frame index
  thinking_entry_key = nil, -- key in assistant_entries that is currently "thinking"
  -- Incremental streaming render
  render_pending = false, -- true when a debounced render is scheduled
  stream_line_start = nil, -- 0-based buf line where current streaming entry content begins
  history_loading = false, -- true while replaying SSE history; suppresses render until done
}

-- Static list of slash commands supported by the Copilot CLI backend.
local SLASH_COMMANDS = {
  { word = '/help', info = 'Show help for interactive commands' },
  { word = '/model', info = 'Select AI model to use' },
  { word = '/resume', info = 'Switch to a different session' },
  { word = '/rename', info = 'Rename the current session' },
  { word = '/new', info = 'Start a new conversation' },
  { word = '/clear', info = 'Abandon this session and start fresh' },
  { word = '/compact', info = 'Summarize conversation history' },
  { word = '/context', info = 'Show context window token usage' },
  { word = '/usage', info = 'Display session usage metrics' },
  { word = '/session', info = 'View and manage sessions' },
  { word = '/diff', info = 'Review changes in current directory' },
  { word = '/pr', info = 'Operate on pull requests for current branch' },
  { word = '/review', info = 'Run code review agent' },
  { word = '/lsp', info = 'Manage language server configuration' },
  { word = '/plan', info = 'Create an implementation plan' },
  { word = '/research', info = 'Run deep research investigation' },
  { word = '/init', info = 'Initialize Copilot instructions for this repository' },
  { word = '/agent', info = 'Browse and select available agents' },
  { word = '/skills', info = 'Manage skills for enhanced capabilities' },
  { word = '/mcp', info = 'Manage MCP server configuration' },
  { word = '/delegate', info = 'Send this session to GitHub and create a PR' },
  { word = '/fleet', info = 'Enable fleet mode for parallel subagent execution' },
  { word = '/tasks', info = 'View and manage background tasks' },
  { word = '/ide', info = 'Connect to an IDE workspace' },
  { word = '/terminal-setup', info = 'Configure terminal for multiline input support' },
  { word = '/allow-all', info = 'Enable all permissions' },
  { word = '/add-dir', info = 'Add a directory to the allowed list' },
  { word = '/list-dirs', info = 'Display all allowed directories' },
  { word = '/cwd', info = 'Change or show working directory' },
  { word = '/reset-allowed-tools', info = 'Reset the list of allowed tools' },
  { word = '/share', info = 'Share session to markdown, HTML, or GitHub gist' },
  { word = '/remote', info = 'Show remote status or toggle remote control' },
  { word = '/copy', info = 'Copy the last response to the clipboard' },
  { word = '/rewind', info = 'Rewind the last turn and revert file changes' },
  { word = '/undo', info = 'Rewind the last turn and revert file changes' },
  { word = '/ask', info = 'Ask a quick side question without adding to history' },
  { word = '/search', info = 'Search the conversation timeline' },
  { word = '/env', info = 'Show loaded environment details' },
  { word = '/changelog', info = 'Display changelog for CLI versions' },
  { word = '/feedback', info = 'Provide feedback about the CLI' },
  { word = '/theme', info = 'View or set color mode' },
  { word = '/update', info = 'Update the CLI to the latest version' },
  { word = '/version', info = 'Display version information' },
  { word = '/experimental', info = 'Show/enable/disable experimental features' },
  { word = '/instructions', info = 'View and toggle custom instruction files' },
  { word = '/login', info = 'Log in to Copilot' },
  { word = '/logout', info = 'Log out of an OAuth login session' },
  { word = '/exit', info = 'Exit the CLI' },
  { word = '/restart', info = 'Restart the CLI, preserving current session' },
  { word = '/user', info = 'Manage GitHub user list' },
}

local function normalize_base_url(url)
  return utils.normalize_base_url(url, defaults.base_url)
end

local function notify(message, level)
  if state.config.notify == false then
    return
  end
  vim.notify('[copilot-agent] ' .. message, level or vim.log.levels.INFO)
end

-- For noisy, transient messages (permission decisions, etc.) that shouldn't
-- clutter the chat buffer. Displays via vim.notify and optionally auto-clears
-- the cmdline area after config.chat.system_notify_timeout ms.
local function notify_transient(message, level)
  notify(message, level)
  local timeout = state.config.chat and state.config.chat.system_notify_timeout or 0
  if timeout and timeout > 0 then
    vim.defer_fn(function()
      vim.cmd('echo ""')
    end, timeout)
  end
end

local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

-- Returns true when content is empty / whitespace / dots only (model "thinking").
local is_thinking_content = utils.is_thinking_content

local function stop_thinking_spinner()
  if state.thinking_timer then
    pcall(function()
      state.thinking_timer:stop()
    end)
    pcall(function()
      state.thinking_timer:close()
    end)
    state.thinking_timer = nil
  end
  state.thinking_entry_key = nil
end

local function start_thinking_spinner(entry_key)
  stop_thinking_spinner()
  state.thinking_entry_key = entry_key
  state.thinking_frame = 1
  local timer = uv.new_timer()
  state.thinking_timer = timer
  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      if not state.thinking_timer then
        return
      end
      state.thinking_frame = (state.thinking_frame % #SPINNER_FRAMES) + 1
      local bufnr = state.chat_bufnr
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        -- render_chat is defined below; safe to call via upvalue after module load.
        pcall(render_chat)
      end
    end)
  )
end

local function split_lines(text)
  return utils.split_lines(text)
end

local function build_url(path)
  return normalize_base_url(state.config.base_url) .. path
end

-- ── Public statusline component API ──────────────────────────────────────────
-- Each function returns a short string for embedding in external statuslines
-- (lualine, feline, heirline, etc.) via:
--   require('copilot_agent').statusline_mode()
--   %{v:lua.require'copilot_agent'.statusline()}   (for &statusline)

local function statusline_mode()
  return '[' .. (state.input_mode or 'agent') .. ']'
end

local function statusline_model()
  local m = state.config.session and state.config.session.model or ''
  local label = m ~= '' and m or 'default'
  if state.reasoning_effort and state.reasoning_effort ~= '' then
    label = label .. ' [' .. state.reasoning_effort .. ']'
  end
  return label
end

local function statusline_busy()
  return state.chat_busy and '⏳' or '✓'
end

local function statusline_attachments()
  local n = #state.pending_attachments
  return n > 0 and ('📎' .. n) or ''
end

local _perm_icons = {
  interactive = '🔐',
  ['approve-all'] = '✅',
  autopilot = '🤖',
  ['reject-all'] = '🚫',
}
local function statusline_permission()
  local mode = state.permission_mode or 'interactive'
  return (_perm_icons[mode] or '🔐') .. mode
end

-- Full one-liner component for a statusline plugin.
local function statusline_component()
  local parts = {
    statusline_mode(),
    statusline_busy(),
    statusline_model(),
    statusline_permission(),
  }
  local att = statusline_attachments()
  if att ~= '' then
    table.insert(parts, att)
  end
  return table.concat(parts, ' ')
end

-- Rebuild the input window's own statusline (state info only, no keybind noise).
local function refresh_input_statusline()
  if not state.input_winid or not vim.api.nvim_win_is_valid(state.input_winid) then
    return
  end
  local att = statusline_attachments()
  vim.wo[state.input_winid].statusline =
    string.format(' %s %s  %s  %s%s  (? for help)', statusline_mode(), statusline_busy(), statusline_model(), statusline_permission(), att ~= '' and ('  ' .. att) or '')
end

-- Rebuild the chat output window's statusline.
local function refresh_chat_statusline()
  if not state.chat_winid or not vim.api.nvim_win_is_valid(state.chat_winid) then
    return
  end
  local session_label = ''
  if state.session_id then
    if state.session_name and state.session_name ~= '' then
      session_label = '  session: ' .. state.session_name
    else
      session_label = '  #' .. state.session_id:sub(1, 8)
    end
  end
  vim.wo[state.chat_winid].statusline = string.format(' %s %s  %s  %s%s', statusline_mode(), statusline_busy(), statusline_model(), statusline_permission(), session_label)
end

-- Refresh both window statuslines at once.
local function refresh_statuslines()
  refresh_input_statusline()
  refresh_chat_statusline()
end

local function cwd()
  return (uv and uv.cwd and uv.cwd()) or vim.fn.getcwd()
end

local function working_directory()
  local value = state.config.session.working_directory
  if type(value) == 'function' then
    value = value()
  end
  if value == nil or value == '' then
    value = cwd()
  end
  return value
end

local function plugin_root()
  local source = debug.getinfo(1, 'S').source
  if type(source) ~= 'string' or source == '' then
    return cwd()
  end
  local path = source:gsub('^@', '')
  return vim.fn.fnamemodify(path, ':p:h:h:h')
end

local function service_cwd()
  local value = state.config.service.cwd
  if type(value) == 'function' then
    value = value()
  end
  if value == nil or value == '' then
    -- Go source is in server/ subdirectory of the plugin root.
    value = plugin_root() .. '/server'
  end
  return value
end

local function installed_binary_path()
  local uname = vim.uv.os_uname()
  local ext = uname.sysname:find('Windows') and '.exe' or ''
  local root = plugin_root()
  -- Prefer bin/ (built via `make build`), fall back to server/ (built via `go build` in-place).
  local candidates = {
    root .. '/bin/copilot-agent' .. ext,
    root .. '/server/copilot-agent' .. ext,
  }
  for _, p in ipairs(candidates) do
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  return candidates[1] -- default for the nil→go-run fallback path
end

local function service_command()
  local value = state.config.service.command
  if type(value) == 'function' then
    value = value()
  end
  -- nil = auto: prefer installed binary, fall back to 'go run .'
  if value == nil then
    local bin = installed_binary_path()
    if vim.fn.executable(bin) == 1 then
      value = { bin }
    else
      value = { 'go', 'run', '.' }
    end
  end
  -- Append --port-range when configured and the command doesn't already set --addr.
  local pr = state.config.service.port_range
  if pr and pr ~= '' and type(value) == 'table' then
    local has_addr = false
    for _, arg in ipairs(value) do
      if arg == '--addr' or arg == '-addr' then
        has_addr = true
        break
      end
    end
    if not has_addr then
      value = vim.list_extend(vim.deepcopy(value), { '--port-range', pr })
    end
  end
  return value
end

local function remember_service_output(data)
  if not data then
    return
  end
  for _, line in ipairs(data) do
    if line and line ~= '' then
      -- Machine-readable address announcement from the Go service.
      -- Printed to stdout once the TCP listener is bound (port 0 → actual port).
      local addr = line:match('^COPILOT_AGENT_ADDR=(.+)$')
      if addr then
        state.config.base_url = 'http://' .. addr
        -- Service is already listening; mark it ready immediately so the
        -- health-check polling loop resolves on its next tick.
        state.service_addr_known = true
      end
      table.insert(state.service_output, line)
    end
  end
  while #state.service_output > 20 do
    table.remove(state.service_output, 1)
  end
end

local function last_service_output()
  return state.service_output[#state.service_output]
end

local normalize_model_entry = utils.normalize_model_entry

local function store_model_cache(models)
  local items = {}
  for _, entry in ipairs(models or {}) do
    local item = normalize_model_entry(entry)
    if item then
      table.insert(items, item)
    end
  end

  table.sort(items, function(left, right)
    return left.label < right.label
  end)
  state.model_cache = items
  return items
end

local function model_completion_items(arglead)
  local prefix = vim.trim(arglead or ''):lower()
  local matches = {}
  local seen = {}

  local function add(id)
    if type(id) ~= 'string' or id == '' or seen[id] then
      return
    end
    if prefix == '' or id:lower():find(prefix, 1, true) == 1 then
      seen[id] = true
      table.insert(matches, id)
    end
  end

  add(state.config.session.model)
  for _, item in ipairs(state.model_cache) do
    add(item.id)
  end

  table.sort(matches)
  return matches
end

local unavailable_model_from_error = utils.unavailable_model_from_error

local function stale_service_hint(unavailable_model)
  if type(unavailable_model) ~= 'string' or unavailable_model == '' then
    return nil
  end
  if state.config.session.model ~= nil then
    return nil
  end
  return string.format(
    'The running Go host selected unavailable model "%s" even though the plugin did not configure a model. This usually means the service process is an older build. Restart `go run .` and reload Neovim.',
    unavailable_model
  )
end

local is_connection_error = utils.is_connection_error

local function sync_request(method, path, body)
  if not ensure_curl() then
    return nil, 'curl executable not found: ' .. state.config.curl_bin
  end

  local args = {
    state.config.curl_bin,
    '-sS',
    '-o',
    '-',
    '-w',
    '\n%{http_code}',
    '-X',
    method,
    build_url(path),
    '-H',
    'Accept: application/json',
  }

  if body ~= nil then
    table.insert(args, '-H')
    table.insert(args, 'Content-Type: application/json')
    table.insert(args, '--data-raw')
    table.insert(args, encode_json(body))
  end

  if vim.system then
    local result = vim.system(args, { text = true }):wait()
    local raw_stdout = result.stdout or ''
    local response_body, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
    local status = tonumber(status_text)
    if not response_body then
      response_body = raw_stdout
    end

    if result.code ~= 0 and (status == nil or status < 400) then
      local message = (result.stderr and vim.trim(result.stderr) ~= '' and result.stderr) or response_body
      return nil, vim.trim(message), status
    end

    local payload, decode_err = decode_json(response_body)
    if status and status >= 400 then
      local message = decode_err or response_body
      if type(payload) == 'table' and type(payload.error) == 'string' then
        message = payload.error
      end
      return nil, message, status
    end

    return payload, nil, status
  end

  local raw_stdout = vim.fn.system(args)
  local code = vim.v.shell_error
  local response_body, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
  local status = tonumber(status_text)
  if not response_body then
    response_body = raw_stdout
  end

  if code ~= 0 and (status == nil or status < 400) then
    return nil, vim.trim(response_body), status
  end

  local payload, decode_err = decode_json(response_body)
  if status and status >= 400 then
    local message = decode_err or response_body
    if type(payload) == 'table' and type(payload.error) == 'string' then
      message = payload.error
    end
    return nil, message, status
  end

  return payload, nil, status
end

ensure_curl = function()
  if vim.fn.executable(state.config.curl_bin) == 1 then
    return true
  end
  notify('curl executable not found: ' .. state.config.curl_bin, vim.log.levels.ERROR)
  return false
end

-- After programmatic nvim_buf_set_lines, notify rendering plugins (e.g.
-- render-markdown.nvim) since no TextChanged event fires for nofile buffers.
-- Throttled: fires at most once per render cycle via vim.schedule.
-- Skipped entirely when chat.render_markdown = false.
local function notify_render_plugins(bufnr)
  if state.config.chat and state.config.chat.render_markdown == false then
    return
  end
  vim.schedule(function()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local ok, rm = pcall(require, 'render-markdown')
    if ok and rm.refresh then
      pcall(rm.refresh)
    end
  end)
end

-- Returns true if the assistant entry at idx should be merged under the same
-- "Assistant:" header as the nearest preceding real assistant entry.  Skips
-- over empty/thinking-only assistant entries when scanning backwards.
local function should_merge_assistant(idx)
  for i = idx - 1, 1, -1 do
    local e = state.entries[i]
    if not e then
      return false
    end
    if e.kind ~= 'assistant' then
      return false
    end -- non-assistant breaks the run
    if not is_thinking_content(e.content) then
      return true
    end
    -- empty/thinking-only: skip over and keep looking backwards
  end
  return false
end

-- Returns the rendered lines for a single entry.
local function entry_lines(entry, idx)
  local out = {}
  if entry.kind == 'system' or entry.kind == 'error' then
    out[#out + 1] = (entry.kind == 'error' and 'Error' or 'System') .. ':'
    for _, l in ipairs(split_lines(entry.content)) do
      out[#out + 1] = '  ' .. l
    end
    out[#out + 1] = ''
  elseif entry.kind == 'assistant' then
    if is_thinking_content(entry.content) then
      -- No real content yet. Show spinner while streaming; skip the entry
      -- entirely once the turn is done (avoids rendering bare "Assistant:\n..").
      if state.chat_busy then
        out[#out + 1] = 'Assistant:'
        out[#out + 1] = '  ' .. (SPINNER_FRAMES[state.thinking_frame] or '⠋') .. ' Thinking…'
        out[#out + 1] = ''
      end
    else
      out[#out + 1] = 'Assistant:'
      for _, l in ipairs(split_lines(entry.content)) do
        out[#out + 1] = '  ' .. l
      end
      out[#out + 1] = ''
    end
  else
    out[#out + 1] = 'User:'
    for _, l in ipairs(split_lines(entry.content)) do
      out[#out + 1] = '  ' .. l
    end
    -- Show image/file attachments below the prompt text.
    if entry.attachments and #entry.attachments > 0 then
      for _, a in ipairs(entry.attachments) do
        out[#out + 1] = '  📎 ' .. (a.display or a.path or a.type)
      end
    end
    out[#out + 1] = ''
  end
  return out
end

-- Returns true if the chat window's visible area ends at (or within a few lines
-- of) the buffer end. Must be called BEFORE writing new lines so we can decide
-- whether to auto-scroll after the write.
local function chat_at_bottom()
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local info = vim.fn.getwininfo(winid)
  if not info or not info[1] then
    return false
  end
  local lc = vim.api.nvim_buf_line_count(bufnr)
  -- botline = last fully-visible line; consider "at bottom" within 3 lines.
  return info[1].botline >= lc - 3
end

-- Move the cursor to the last buffer line and position that line at the bottom
-- of the chat window. Runs in the window's context so focus is not stolen.
local function scroll_to_bottom()
  local winid = state.chat_winid
  local bufnr = state.chat_bufnr
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lc = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_call(winid, function()
    vim.api.nvim_win_set_cursor(0, { lc, 0 })
    -- zb: scroll so the cursor line sits at the bottom of the visible area.
    vim.cmd('normal! zb')
  end)
end

local HEADER_LINES = 5 -- title, service, session, commands, separator

-- Highlight namespace for chat buffer role labels and completion markers.
local CHAT_HL_NS = vim.api.nvim_create_namespace('copilot_agent_chat')

-- Apply (or refresh) highlights for role labels and "Done." in the chat buffer.
-- Pass from_row (0-indexed) to restrict work to a tail of the buffer (streaming).
local function apply_chat_highlights(bufnr, from_row)
  from_row = from_row or 0
  vim.api.nvim_buf_clear_namespace(bufnr, CHAT_HL_NS, from_row, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from_row, -1, false)
  for i, line in ipairs(lines) do
    local row = from_row + i - 1
    if line == 'User:' then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentUser', row, 0, -1)
    elseif line == 'Assistant:' then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentAssistant', row, 0, -1)
    elseif line:match('^%s*Done%.$') then
      vim.api.nvim_buf_add_highlight(bufnr, CHAT_HL_NS, 'CopilotAgentDone', row, 0, -1)
    end
  end
end

render_chat = function()
  state.render_pending = false
  if state.history_loading then
    return
  end
  local bufnr = state.chat_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Snapshot scroll position BEFORE overwriting the buffer so we can restore
  -- "following" behaviour: if the user was at the bottom, keep them there.
  local at_bottom = chat_at_bottom()

  local lines = {
    state.config.chat.title,
    'service: ' .. normalize_base_url(state.config.base_url),
    'session: ' .. (state.session_id or '<none>'),
    'commands: :CopilotAgentNewSession  :CopilotAgentAsk  :CopilotAgentStop',
    string.rep('-', 72),
  }

  if #state.entries == 0 then
    lines[#lines + 1] = 'No messages yet.'
    lines[#lines + 1] = 'Press i or <Enter> to open the input buffer.'
    lines[#lines + 1] = 'Run :CopilotAgentAsk to send a prompt from the command line.'
  else
    for idx, entry in ipairs(state.entries) do
      local elines = entry_lines(entry, idx)
      if #elines > 0 then
        -- Merge consecutive real assistant entries under one "Assistant:" header.
        -- Replace the header line with "" for 2nd+ entries in a run.
        -- Line count is preserved (1→1), so stream_update offsets stay correct.
        if entry.kind == 'assistant' and not is_thinking_content(entry.content) and should_merge_assistant(idx) then
          elines[1] = ''
        end
        for _, l in ipairs(elines) do
          lines[#lines + 1] = l
        end
      end
    end
  end

  -- Invalidate incremental position cache (full render resets it).
  state.stream_line_start = nil

  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  apply_chat_highlights(bufnr)
  refresh_chat_statusline()

  if at_bottom then
    scroll_to_bottom()
  end
  -- Only notify render-markdown once streaming is done. Calling rm.refresh()
  -- on every delta causes the plugin to re-parse and re-decorate the entire
  -- buffer at streaming speed, producing visible flickering and text jumps.
  if not state.chat_busy then
    notify_render_plugins(bufnr)
  end
end

-- Debounced render: coalesces rapid calls (e.g. streaming deltas) to ~25fps.
local RENDER_DEBOUNCE_MS = 40
local function schedule_render()
  if state.render_pending or state.history_loading then
    return
  end
  state.render_pending = true
  vim.defer_fn(render_chat, RENDER_DEBOUNCE_MS)
end

-- Incremental update: only replaces the tail of the buffer starting from the
-- current streaming entry's content lines. O(entry size) instead of O(buffer).
local function stream_update(entry, idx)
  if state.history_loading then
    return
  end
  local bufnr = state.chat_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local new_lines = entry_lines(entry, idx)
  -- Apply the same merge logic as render_chat so incremental writes stay
  -- consistent with full renders (line count is preserved, so offsets are unaffected).
  if entry.kind == 'assistant' and not is_thinking_content(entry.content) and should_merge_assistant(idx) and #new_lines > 0 then
    new_lines[1] = ''
  end

  if state.stream_line_start then
    -- Fast path: replace only this entry's lines at the cached offset.
    -- Snapshot scroll position BEFORE writing so we honour "following" state.
    local at_bottom = chat_at_bottom()
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
    vim.api.nvim_buf_set_lines(bufnr, state.stream_line_start, -1, false, new_lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    vim.bo[bufnr].modified = false
    apply_chat_highlights(bufnr, state.stream_line_start)
    if at_bottom then
      scroll_to_bottom()
    end
    -- Do NOT call notify_render_plugins here — render-markdown refreshing on
    -- every streaming delta is the primary cause of visual jumping. The final
    -- render_chat() call (after turn_end) will trigger it once per turn.
  else
    -- First delta for this entry: do a full render to establish position, then cache.
    render_chat()
    -- After full render, compute where this entry's content lines start.
    -- = HEADER_LINES + sum of line counts of all prior entries (0-based).
    local offset = HEADER_LINES
    for i = 1, idx - 1 do
      if state.entries[i] then
        offset = offset + #entry_lines(state.entries[i], i)
      end
    end
    -- stream_line_start is the 0-based line where this entry's block starts ("Assistant:").
    state.stream_line_start = offset
  end
end

-- Open a fuzzy-finder to pick one or more files/directories.
-- opts.prompt  string  prompt title
-- opts.type    'file' | 'dir'   what to pick (default 'file')
-- opts.cwd     string  root directory for the picker
-- callback(paths)  receives a list of absolute path strings
--
-- Detection order (respects state.config.chat.file_picker):
--   snacks → telescope → fzf-lua → mini.pick → vim.ui.input fallback
local function pick_path(opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or 'Select'
  local pick_type = opts.type or 'file'
  local root = opts.cwd or working_directory() or cwd()
  local cfg = state.config.chat.file_picker or 'auto'

  -- Normalize paths from a picker: make absolute, strip trailing newline.
  local function abs(p)
    if not p or p == '' then
      return nil
    end
    p = p:gsub('\n$', '')
    if vim.fn.isabsolutepath(p) == 0 then
      p = root .. '/' .. p
    end
    return vim.fn.fnamemodify(p, ':p')
  end

  -- Helper: fires callback with a single list of valid paths.
  local function done(raw_paths)
    local out = {}
    for _, p in ipairs(raw_paths or {}) do
      local a = abs(p)
      if a and a ~= '' then
        out[#out + 1] = a
      end
    end
    if #out > 0 then
      callback(out)
    end
  end

  -- ── snacks.picker ────────────────────────────────────────────────────────
  local function try_snacks()
    local ok, snacks = pcall(require, 'snacks')
    if not ok or not snacks.picker then
      return false
    end
    local picker_fn = pick_type == 'dir' and snacks.picker.directories or snacks.picker.files
    if not picker_fn then
      return false
    end
    picker_fn({
      title = prompt,
      cwd = root,
      confirm = function(picker, item)
        picker:close()
        if item then
          done({ item.file or item.path or tostring(item) })
        end
      end,
    })
    return true
  end

  -- ── telescope ────────────────────────────────────────────────────────────
  local function try_telescope()
    local ok_tb, tb = pcall(require, 'telescope.builtin')
    local ok_a, actions = pcall(require, 'telescope.actions')
    local ok_s, action_state = pcall(require, 'telescope.actions.state')
    if not (ok_tb and ok_a and ok_s) then
      return false
    end
    local picker_fn
    if pick_type == 'dir' then
      -- Try file_browser extension for directory picking.
      local ok_fb, ext = pcall(function()
        return require('telescope').extensions.file_browser
      end)
      if ok_fb and ext and ext.file_browser then
        picker_fn = function(popts)
          ext.file_browser(popts)
        end
      end
    end
    if not picker_fn then
      picker_fn = tb.find_files
    end
    picker_fn({
      prompt_title = prompt,
      cwd = root,
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local picker_obj = action_state.get_current_picker(prompt_bufnr)
          local multi = picker_obj:get_multi_selection()
          actions.close(prompt_bufnr)
          local raw = {}
          if #multi > 0 then
            for _, entry in ipairs(multi) do
              raw[#raw + 1] = entry[1] or entry.path or entry.filename or ''
            end
          else
            local sel = action_state.get_selected_entry()
            if sel then
              raw[1] = sel[1] or sel.path or sel.filename or ''
            end
          end
          done(raw)
        end)
        return true
      end,
    })
    return true
  end

  -- ── fzf-lua ───────────────────────────────────────────────────────────────
  local function try_fzf()
    local ok, fzf = pcall(require, 'fzf-lua')
    if not ok then
      return false
    end
    local picker_fn
    if pick_type == 'dir' then
      -- fzf-lua doesn't have a built-in dir picker; use fzf_exec with fd/find.
      local fd = vim.fn.executable('fd') == 1 and 'fd --type d --color never' or 'find . -type d -not -path "*/\\.*"'
      picker_fn = function(popts)
        fzf.fzf_exec(
          fd,
          vim.tbl_extend('force', popts, {
            prompt = prompt .. '> ',
            cwd = root,
            actions = {
              ['default'] = function(selected)
                done(selected or {})
              end,
            },
          })
        )
      end
    else
      picker_fn = fzf.files
    end
    picker_fn({
      prompt = prompt .. '> ',
      cwd = root,
      actions = {
        ['default'] = function(selected)
          done(selected or {})
        end,
      },
    })
    return true
  end

  -- ── mini.pick ─────────────────────────────────────────────────────────────
  local function try_mini()
    local ok, mp = pcall(require, 'mini.pick')
    if not ok then
      return false
    end
    -- mini.pick doesn't have a directory picker; only offer for files.
    if pick_type == 'dir' then
      return false
    end
    mp.builtin.files(nil, {
      source = {
        cwd = root,
        name = prompt,
        choose = function(item)
          done({ item })
        end,
        choose_marked = function(items)
          done(items)
        end,
      },
    })
    return true
  end

  -- ── vim.ui.input fallback ─────────────────────────────────────────────────
  local function use_native()
    local completion = pick_type == 'dir' and 'dir' or 'file'
    vim.ui.input({ prompt = prompt .. ': ', completion = completion }, function(path)
      if path and path ~= '' then
        done({ path })
      end
    end)
  end

  if cfg == 'native' then
    use_native()
    return
  end

  -- Auto-detect: try each picker in preference order.
  if cfg == 'snacks' or cfg == 'auto' then
    if try_snacks() then
      return
    end
  end
  if cfg == 'telescope' or cfg == 'auto' then
    if try_telescope() then
      return
    end
  end
  if cfg == 'fzf-lua' or cfg == 'auto' then
    if try_fzf() then
      return
    end
  end
  if cfg == 'mini.pick' or cfg == 'auto' then
    if try_mini() then
      return
    end
  end
  use_native()
end

local function ensure_chat_window()
  if state.chat_bufnr and vim.api.nvim_buf_is_valid(state.chat_bufnr) then
    if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
      vim.api.nvim_set_current_win(state.chat_winid)
      return state.chat_bufnr
    end
    -- Buffer exists but window was closed/hidden — reopen with nvim_open_win
    -- directly so we always get the right window without an orphan buffer.
    state.chat_winid = vim.api.nvim_open_win(state.chat_bufnr, true, {
      split = 'right',
      win = 0,
    })
    render_chat()
    refresh_chat_statusline()
    scroll_to_bottom()
    return state.chat_bufnr
  end

  -- Create the chat buffer; set options once here, not on every render.
  state.chat_bufnr = vim.api.nvim_create_buf(false, true)
  local bufnr = state.chat_bufnr
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.api.nvim_buf_set_name(bufnr, 'copilot-agent-chat')

  -- Open a vertical split window via the API — no throwaway buffer created.
  state.chat_winid = vim.api.nvim_open_win(bufnr, true, {
    split = 'right',
    win = 0,
  })
  refresh_chat_statusline()

  -- Tell render-markdown.nvim (and similar) to enable on this buffer.
  -- It defaults to skipping nofile buffers, so we explicitly enable it.
  -- Skipped when chat.render_markdown = false.
  if state.config.chat and state.config.chat.render_markdown ~= false then
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local ok, rm = pcall(require, 'render-markdown')
      if ok and rm.enable then
        pcall(rm.enable, { buf = bufnr })
      end
    end)
  end

  vim.keymap.set('n', 'q', function()
    if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
      vim.api.nvim_win_close(state.chat_winid, true)
    end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set('n', 'R', function()
    render_chat()
  end, { buffer = bufnr, silent = true })

  for _, lhs in ipairs({ 'i', 'I', 'a', 'A', 'o', 'O', '<CR>' }) do
    vim.keymap.set('n', lhs, function()
      M.ask()
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = 'Prompt for a Copilot Go message',
    })
  end

  -- Shared action keymaps: mode, model, attachments, tools, permission, history, help.
  setup_action_keymaps(bufnr)

  render_chat()
  scroll_to_bottom()
  return bufnr
end

local input_modes = { 'ask', 'plan', 'agent' }
local _perm_cycle = { 'interactive', 'approve-all', 'autopilot' }

-- Notify the server of the new agent mode so the SDK switches behaviour.
local function set_agent_mode(mode)
  if not state.session_id then
    return
  end
  request('POST', string.format('/sessions/%s/mode', state.session_id), { mode = mode }, function(_, err)
    if err then
      notify('Failed to set agent mode: ' .. err, vim.log.levels.WARN)
    end
  end)
end

-- Keymaps shared by both the chat output buffer and the input buffer.
-- The input buffer overrides <C-s> (submit) and <C-t> (also refreshes prompt).
setup_action_keymaps = function(bufnr)
  -- Open input window (chat: always open; input: overridden to submit).
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    M.ask()
  end, { buffer = bufnr, silent = true, desc = 'Open input / send message' })

  -- History navigation: load entry into input buffer prefill then open it.
  for _, map in ipairs({
    { '<C-p>', -1 },
    { '<M-p>', -1 },
    { '<C-n>', 1 },
    { '<M-n>', 1 },
  }) do
    local lhs, dir = map[1], map[2]
    vim.keymap.set({ 'n', 'i' }, lhs, function()
      if #state.prompt_history == 0 then
        return
      end
      local draft_index = #state.prompt_history + 1
      if state.prompt_history_index == nil then
        state.prompt_history_index = draft_index
      end
      local next_index = math.max(1, math.min(draft_index, state.prompt_history_index + dir))
      state.prompt_history_index = next_index
      if next_index == draft_index then
        state.prompt_prefill = state.prompt_history_draft
      else
        state.prompt_prefill = state.prompt_history[next_index]
      end
      M.ask()
    end, { buffer = bufnr, silent = true, desc = dir < 0 and 'Previous prompt' or 'Next prompt' })
  end

  -- Cycle input mode (ask / plan / agent).
  vim.keymap.set({ 'n', 'i' }, '<C-t>', function()
    local idx = 1
    for i, m in ipairs(input_modes) do
      if m == state.input_mode then
        idx = i
        break
      end
    end
    state.input_mode = input_modes[(idx % #input_modes) + 1]
    set_agent_mode(state.input_mode)
    refresh_statuslines()
    notify('Mode: ' .. state.input_mode, vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true, desc = 'Cycle Copilot input mode (ask/plan/agent)' })

  -- Quick model switch.
  vim.keymap.set({ 'n', 'i' }, '<M-m>', function()
    M.select_model()
  end, { buffer = bufnr, silent = true, desc = 'Switch Copilot model' })

  -- Paste image from clipboard.
  vim.keymap.set({ 'n', 'i' }, '<M-v>', function()
    M.paste_clipboard_image()
  end, { buffer = bufnr, silent = true, desc = 'Paste image from clipboard as attachment' })

  -- Cycle permission mode.
  vim.keymap.set({ 'n', 'i' }, '<M-a>', function()
    local current = state.permission_mode or 'interactive'
    local next_mode = 'interactive'
    for i, m in ipairs(_perm_cycle) do
      if m == current then
        next_mode = _perm_cycle[(i % #_perm_cycle) + 1]
        break
      end
    end
    state.permission_mode = next_mode
    if state.session_id then
      request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = next_mode }, function(_, err)
        if err then
          notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
        end
      end)
    end
    refresh_statuslines()
    notify('Permission mode: ' .. next_mode, vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true, desc = 'Cycle permission mode' })

  -- Resource / attachment picker.
  vim.keymap.set({ 'n', 'i' }, '<C-a>', function()
    local choices = {
      'Current buffer',
      'Visual selection',
      'File',
      'Folder',
      'Instructions file',
      'Image file',
      'Paste image from clipboard',
    }
    vim.ui.select(choices, { prompt = 'Add resource' }, function(choice)
      if not choice then
        return
      end

      local function add_attachment(att)
        table.insert(state.pending_attachments, att)
        refresh_statuslines()
        vim.schedule(function()
          if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
            vim.api.nvim_set_current_win(state.input_winid)
            vim.cmd('startinsert!')
          elseif state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
            vim.api.nvim_set_current_win(state.chat_winid)
          end
        end)
      end

      if choice == 'Current buffer' then
        local path = vim.api.nvim_buf_get_name(vim.fn.bufnr('#') ~= -1 and vim.fn.bufnr('#') or 0)
        if path ~= '' then
          add_attachment({ type = 'file', path = path, display = vim.fn.fnamemodify(path, ':t') })
        end
      elseif choice == 'Visual selection' then
        local sel_buf = vim.fn.bufnr('#') ~= -1 and vim.fn.bufnr('#') or 0
        local start_line = vim.fn.line("'<", vim.fn.win_getid()) - 1
        local end_line = vim.fn.line("'>", vim.fn.win_getid()) - 1
        local lines = vim.api.nvim_buf_get_lines(sel_buf, start_line, end_line + 1, false)
        local text = table.concat(lines, '\n')
        local filepath = vim.api.nvim_buf_get_name(sel_buf)
        if text ~= '' then
          add_attachment({
            type = 'selection',
            path = filepath,
            text = text,
            start_line = start_line,
            end_line = end_line,
            display = 'selection:' .. vim.fn.fnamemodify(filepath, ':t') .. ':' .. (start_line + 1) .. '-' .. (end_line + 1),
          })
        end
      elseif choice == 'File' then
        pick_path({ prompt = 'Attach file', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'file', path = p, display = vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Folder' then
        pick_path({ prompt = 'Attach folder', type = 'dir' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({
              type = 'directory',
              path = p,
              display = vim.fn.fnamemodify(p:gsub('/$', ''), ':t') .. '/',
            })
          end
        end)
      elseif choice == 'Instructions file' then
        pick_path({ prompt = 'Instructions file', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'file', path = p, display = '📋' .. vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Image file' then
        pick_path({ prompt = 'Attach image', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'image', path = p, display = '🖼️ ' .. vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Paste image from clipboard' then
        M.paste_clipboard_image()
      end

      if choice == 'Current buffer' or choice == 'Visual selection' then
        if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
          vim.api.nvim_set_current_win(state.input_winid)
          vim.cmd('startinsert!')
        end
      end
    end)
  end, { buffer = bufnr, silent = true, desc = 'Add resource/attachment' })

  -- Tool config: show available tools, toggle excluded.
  vim.keymap.set({ 'n', 'i' }, '<C-x>', function()
    if not state.session_id then
      notify('No active session', vim.log.levels.WARN)
      return
    end
    request('GET', '/sessions/' .. state.session_id, nil, function(session, err)
      if err or not session then
        notify('Failed to fetch session: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local caps = session.capabilities or {}
      local tools = caps.availableTools or {}
      local excluded = session.excludedTools or {}
      local excluded_set = {}
      for _, t in ipairs(excluded) do
        excluded_set[t] = true
      end
      if #tools == 0 then
        notify('No tools available in this session', vim.log.levels.INFO)
        return
      end
      local items = {}
      for _, t in ipairs(tools) do
        table.insert(items, { name = t, excluded = excluded_set[t] == true })
      end
      vim.ui.select(items, {
        prompt = 'Toggle tool (currently marked = excluded)',
        format_item = function(item)
          return (item.excluded and '✗ ' or '✓ ') .. item.name
        end,
      }, function(choice)
        if not choice then
          return
        end
        if choice.excluded then
          excluded_set[choice.name] = nil
        else
          excluded_set[choice.name] = true
        end
        local new_excluded = vim.tbl_keys(excluded_set)
        request('POST', '/sessions/' .. state.session_id .. '/tools', { excludedTools = new_excluded }, function(_, req_err)
          if req_err then
            notify('Failed to update tools: ' .. req_err, vim.log.levels.WARN)
          else
            notify('Tools updated', vim.log.levels.INFO)
          end
        end)
      end)
    end)
  end, { buffer = bufnr, silent = true, desc = 'Configure session tools' })

  -- Help popup (? in normal mode).
  vim.keymap.set('n', '?', function()
    local help_lines = {
      ' Copilot Agent – Keybindings ',
      string.rep('─', 44),
      '',
      '  Send / Open input',
      '    <CR> / i / a    Open input buffer (output pane)',
      '    <C-s>           Send message / open input',
      '',
      '  Mode  (<C-t> to cycle)',
      '    ask             Standard Q&A',
      '    plan            Create an implementation plan',
      '    agent           Autonomous agent mode',
      '',
      '  Model',
      '    <M-m>           Open model picker',
      '',
      '  Permission  (<M-a> to cycle)',
      '    🔐 interactive   Prompt for each tool use',
      '    ✅ approve-all   Auto-approve everything',
      '    🤖 autopilot     Approve + auto-answer inputs',
      '',
      '  Attachments  (<C-a> to open menu)',
      '    Current buffer, visual selection,',
      '    file, folder, instructions file,',
      '    image file',
      '    <M-v>           Paste image from clipboard',
      '',
      '  Tools',
      '    <C-x>           Toggle session tools',
      '',
      '  History  (input buffer)',
      '    <C-p> / <M-p>   Previous prompt',
      '    <C-n> / <M-n>   Next prompt',
      '',
      '  Completion  (input buffer)',
      '    <Tab>           Trigger completion',
      '    @<path>         Attach a file',
      '    /<cmd>          Slash command',
      '',
      '  Output pane',
      '    q               Close chat window',
      '    R               Refresh/re-render',
      '    ?               This help',
      '',
      '  Press any key to close',
    }
    local max_w = 0
    for _, l in ipairs(help_lines) do
      max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
    end
    local win_h = #help_lines
    local win_w = max_w + 2
    local row = math.max(0, (vim.o.lines - win_h) / 2)
    local col = math.max(0, (vim.o.columns - win_w) / 2)
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
    vim.bo[help_buf].modifiable = false
    local help_win = vim.api.nvim_open_win(help_buf, true, {
      relative = 'editor',
      row = row,
      col = col,
      width = win_w,
      height = win_h,
      style = 'minimal',
      border = 'rounded',
      title = ' Help ',
      title_pos = 'center',
    })
    vim.wo[help_win].cursorline = false
    for _, key in ipairs({ '<Space>', '<CR>', '<Esc>', 'q', '?' }) do
      vim.keymap.set('n', key, function()
        vim.api.nvim_win_close(help_win, true)
      end, { buffer = help_buf, silent = true, nowait = true })
    end
  end, { buffer = bufnr, silent = true, desc = 'Show keybinding help' })
end

local function create_input_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, 'copilot-agent-input')
  vim.bo[bufnr].buftype = 'prompt'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'hide'
  -- filetype = 'markdown' enables treesitter highlighting and render-markdown.
  -- Must be set *after* buftype so FileType autocmds fire with the right buftype.
  vim.bo[bufnr].filetype = 'markdown'
  -- copilot.lua skips prompt buffers by default; this explicit flag overrides it.
  vim.b[bufnr].copilot_enabled = true

  local function prompt_prefix()
    return (state.input_mode or 'agent') .. '❯ '
  end

  local function refresh_prompt()
    vim.fn.prompt_setprompt(bufnr, prompt_prefix())
    refresh_statuslines()
  end

  local function get_input_text()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local prompt = vim.fn.prompt_getprompt(bufnr)
    local text = table.concat(lines, '\n')
    if prompt ~= '' and vim.startswith(text, prompt) then
      text = text:sub(#prompt + 1)
    end
    return text
  end

  local function set_input_text(text)
    local lines = split_lines(text or '')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
      vim.api.nvim_win_set_cursor(state.input_winid, { #lines, #lines[#lines] })
    end
    vim.cmd('startinsert')
  end

  local function remember_prompt(text)
    local prompt = vim.trim(text or '')
    if prompt == '' then
      return
    end
    if state.prompt_history[#state.prompt_history] == prompt then
      return
    end
    table.insert(state.prompt_history, prompt)
  end

  local function navigate_prompt_history(direction)
    if #state.prompt_history == 0 then
      return
    end

    local draft_index = #state.prompt_history + 1
    if state.prompt_history_index == nil then
      state.prompt_history_draft = get_input_text()
      state.prompt_history_index = draft_index
    end

    local next_index = state.prompt_history_index + direction
    if next_index < 1 then
      next_index = 1
    elseif next_index > draft_index then
      next_index = draft_index
    end

    if next_index == state.prompt_history_index then
      return
    end

    state.prompt_history_index = next_index
    if next_index == draft_index then
      set_input_text(state.prompt_history_draft)
      return
    end
    set_input_text(state.prompt_history[next_index])
  end

  local function close_input_window()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    state.prompt_history_index = nil
    state.prompt_history_draft = ''
    if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
      vim.api.nvim_win_close(state.input_winid, true)
      state.input_winid = nil
    end
    if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
      vim.api.nvim_set_current_win(state.chat_winid)
    end
  end

  local function submit(text)
    remember_prompt(text)
    -- Clear the input line and reset history navigation, but keep the window open.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    state.prompt_history_index = nil
    state.prompt_history_draft = ''
    -- Re-apply the prompt prefix (cleared by buf_set_lines).
    vim.fn.prompt_setprompt(bufnr, (state.input_mode or 'agent') .. '❯ ')
    vim.cmd('startinsert')
    if text ~= '' then
      local attachments = vim.deepcopy(state.pending_attachments)
      state.pending_attachments = {}
      state.chat_busy = true
      refresh_statuslines()
      M.ask(text, { attachments = attachments })
    end
  end

  local function cancel()
    close_input_window()
  end

  vim.fn.prompt_setcallback(bufnr, function(text)
    submit(vim.trim(text or ''))
  end)

  local function submit_buffer()
    submit(vim.trim(get_input_text()))
  end

  -- Apply all shared action keymaps, then override the ones that differ in input context.
  setup_action_keymaps(bufnr)

  -- <C-s> submits in prompt mode; <CR> submits via prompt_setcallback().
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit_buffer, { buffer = bufnr, silent = true, desc = 'Submit prompt to Copilot' })
  vim.keymap.set('n', 'q', cancel, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
  vim.keymap.set('i', '<Esc>', '<Esc>', { buffer = bufnr, silent = true, desc = 'Switch to normal mode' })
  -- <C-t> in input also refreshes the prompt prefix and returns to insert mode.
  vim.keymap.set({ 'n', 'i' }, '<C-t>', function()
    local idx = 1
    for i, m in ipairs(input_modes) do
      if m == state.input_mode then
        idx = i
        break
      end
    end
    state.input_mode = input_modes[(idx % #input_modes) + 1]
    set_agent_mode(state.input_mode)
    refresh_prompt()
    vim.cmd('startinsert!')
  end, { buffer = bufnr, silent = true, desc = 'Cycle Copilot input mode (ask/plan/agent)' })
  -- History navigation replaces buffer content directly in input context.
  vim.keymap.set({ 'n', 'i' }, '<C-p>', function()
    navigate_prompt_history(-1)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<C-n>', function()
    navigate_prompt_history(1)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-p>', function()
    navigate_prompt_history(-1)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-n>', function()
    navigate_prompt_history(1)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })

  -- Set the initial prompt prefix to reflect the current mode.
  refresh_prompt()

  -- Omnifunc for @ file mentions and / slash command completion.
  local function input_omnifunc(findstart, base)
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)

    if findstart == 1 then
      local pos = before:find('[@/][^%s]*$')
      if pos then
        return pos - 1
      end
      return -2
    end

    local items = {}
    if vim.startswith(base, '@') then
      local query = base:sub(2)
      local wd = working_directory()
      local pattern = wd .. '/' .. query .. '*'
      local files = vim.fn.glob(pattern, false, true)
      for _, f in ipairs(files) do
        local rel = f:sub(#wd + 2)
        table.insert(items, { word = '@' .. rel, abbr = rel, menu = '[file]' })
      end
    elseif vim.startswith(base, '/') then
      local query = base:sub(2):lower()
      for _, cmd in ipairs(SLASH_COMMANDS) do
        local name = cmd.word:sub(2):lower()
        if query == '' or vim.startswith(name, query) then
          table.insert(items, { word = cmd.word, menu = cmd.info })
        end
      end
    end
    return items
  end

  vim.bo[bufnr].omnifunc = ''
  vim.api.nvim_buf_set_option(bufnr, 'completefunc', "v:lua.require'copilot_agent'.input_omnifunc")

  -- Store omnifunc on the module so v:lua can reach it.
  M.input_omnifunc = input_omnifunc

  vim.keymap.set('i', '<Tab>', '<C-x><C-u>', { buffer = bufnr, silent = true, desc = 'Trigger completion' })

  -- Auto-trigger completion when @ or / is typed.
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = bufnr,
    callback = function()
      local cur_line = vim.api.nvim_get_current_line()
      local cur_col = vim.api.nvim_win_get_cursor(0)[2]
      local ch = cur_line:sub(cur_col, cur_col)
      if ch == '@' or ch == '/' then
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-x><C-u>', true, false, true), 'n')
      end
    end,
  })

  return bufnr
end

open_input_window = function()
  local function apply_prefill()
    if state.prompt_prefill and state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr) then
      local text = state.prompt_prefill
      state.prompt_prefill = nil
      vim.schedule(function()
        vim.api.nvim_buf_set_lines(state.input_bufnr, 0, -1, false, { text })
        vim.cmd('normal! $')
        vim.cmd('startinsert!')
      end)
    end
  end

  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_set_current_win(state.input_winid)
    vim.cmd('startinsert')
    apply_prefill()
    return
  end

  if not state.input_bufnr or not vim.api.nvim_buf_is_valid(state.input_bufnr) then
    state.input_bufnr = create_input_buffer()
  end

  -- Open a small horizontal split below the chat window via the API.
  local parent_win = (state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid)) and state.chat_winid or 0
  state.input_winid = vim.api.nvim_open_win(state.input_bufnr, true, {
    split = 'below',
    win = parent_win,
    height = 5,
  })

  local wo = vim.wo[state.input_winid]
  wo.winfixheight = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  -- Statusline is populated by refresh_input_statusline below.
  refresh_statuslines()

  vim.cmd('startinsert')
  apply_prefill()

  -- copilot.lua's default should_attach rejects buftype='prompt' and buflisted=false.
  -- Force-attach the LSP client directly so virtual-text suggestions work.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(state.input_bufnr) then
      return
    end
    local ok, copilot_client = pcall(require, 'copilot.client')
    if ok and type(copilot_client.buf_attach) == 'function' then
      pcall(copilot_client.buf_attach, true, state.input_bufnr)
    end
  end)
end

local function append_entry(kind, content, attachments)
  table.insert(state.entries, {
    kind = kind,
    content = content or '',
    attachments = attachments,
  })
  -- Structural change: invalidate incremental cache and schedule a full render.
  state.stream_line_start = nil
  schedule_render()
  return #state.entries
end

local function ensure_assistant_entry(message_id)
  local key = message_id or ('assistant-' .. tostring(#state.entries + 1))
  local index = state.assistant_entries[key]
  if index and state.entries[index] then
    return state.entries[index]
  end
  index = append_entry('assistant', '')
  state.assistant_entries[key] = index
  return state.entries[index]
end

local function clear_transcript()
  state.entries = {}
  state.assistant_entries = {}
  state.stream_line_start = nil
  render_chat()
end

-- Delete any temp files (clipboard PNGs) still waiting in pending_attachments.
local function discard_pending_attachments()
  for _, a in ipairs(state.pending_attachments) do
    if a.temp and a.path then
      pcall(os.remove, a.path)
    end
  end
  state.pending_attachments = {}
  refresh_statuslines()
end

local function stop_event_stream()
  if state.events_job_id then
    pcall(vim.fn.jobstop, state.events_job_id)
    state.events_job_id = nil
  end
  stop_thinking_spinner()
  state.sse_partial = ''
  state.sse_event = { event = 'message', data = {} }
end

local function disconnect_session(session_id, delete_state, callback)
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

decode_json = function(raw)
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

encode_json = function(value)
  local encoder
  if vim.json and type(vim.json.encode) == 'function' then
    encoder = vim.json.encode
  elseif type(vim.fn.json_encode) == 'function' then
    encoder = vim.fn.json_encode
  else
    error('no JSON encoder available in this Neovim version')
  end

  return encoder(value)
end

raw_request = function(method, path, body, callback)
  if not ensure_curl() then
    callback(nil, 'curl executable not found: ' .. state.config.curl_bin)
    return
  end

  local stdout = {}
  local stderr = {}
  local args = {
    state.config.curl_bin,
    '-sS',
    '-o',
    '-',
    '-w',
    '\n%{http_code}',
    '-X',
    method,
    build_url(path),
    '-H',
    'Accept: application/json',
  }

  if body ~= nil then
    table.insert(args, '-H')
    table.insert(args, 'Content-Type: application/json')
    table.insert(args, '--data-raw')
    table.insert(args, encode_json(body))
  end

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local raw_stdout = table.concat(stdout, '\n')
        local response_body, status_text = raw_stdout:match('^(.*)\n(%d%d%d)%s*$')
        local status = tonumber(status_text)
        if not response_body then
          response_body = raw_stdout
        end

        local stderr_text = table.concat(stderr, '\n')
        if code ~= 0 and (status == nil or status < 400) then
          callback(nil, stderr_text ~= '' and stderr_text or response_body, status)
          return
        end

        local payload, decode_err = decode_json(response_body)
        if status and status >= 400 then
          local message = decode_err or response_body
          if type(payload) == 'table' and type(payload.error) == 'string' then
            message = payload.error
          end
          callback(nil, message, status)
          return
        end

        callback(payload, nil, status)
      end)
    end,
  })
  if job_id <= 0 then
    vim.schedule(function()
      callback(nil, 'failed to start curl job for ' .. method .. ' ' .. path)
    end)
  end
end

ensure_service_running = function(callback)
  if type(callback) ~= 'function' then
    return
  end

  if state.config.service.auto_start ~= true then
    callback('service auto_start is disabled')
    return
  end

  table.insert(state.pending_service_callbacks, callback)
  if state.service_starting then
    return
  end

  local function finish(err)
    state.service_starting = false
    local callbacks = state.pending_service_callbacks
    state.pending_service_callbacks = {}
    for _, pending in ipairs(callbacks) do
      pending(err)
    end
  end

  local function poll_service_health(attempts_left)
    -- Short-circuit: Go printed COPILOT_AGENT_ADDR= so the port is known and
    -- the listener is already bound. Finish immediately.
    if state.service_addr_known then
      finish(nil)
      return
    end
    raw_request('GET', state.config.service.healthcheck_path, nil, function(_, err, status)
      if err == nil and status and status < 400 then
        finish(nil)
        return
      end
      if attempts_left <= 0 then
        local message = 'timed out waiting for service health check'
        local output = last_service_output()
        if output then
          message = message .. ': ' .. output
        end
        finish(message)
        return
      end
      vim.defer_fn(function()
        poll_service_health(attempts_left - 1)
      end, state.config.service.startup_poll_interval_ms)
    end)
  end

  state.service_starting = true
  state.service_output = {}
  state.service_addr_known = false

  raw_request('GET', state.config.service.healthcheck_path, nil, function(_, health_err, status)
    if health_err == nil and status and status < 400 then
      finish(nil)
      return
    end

    if state.service_job_id then
      local timeout_ms = tonumber(state.config.service.startup_timeout_ms) or defaults.service.startup_timeout_ms
      local interval_ms = tonumber(state.config.service.startup_poll_interval_ms) or defaults.service.startup_poll_interval_ms
      local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
      poll_service_health(attempts)
      return
    end

    local command = service_command()
    if command == nil or command == '' or (type(command) == 'table' and vim.tbl_isempty(command)) then
      finish('service.command is empty')
      return
    end

    local service_job_id = vim.fn.jobstart(command, {
      cwd = service_cwd(),
      env = state.config.service.env,
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(_, data)
        remember_service_output(data)
      end,
      on_stderr = function(_, data)
        remember_service_output(data)
      end,
      on_exit = function(job_id, code)
        vim.schedule(function()
          if state.service_job_id == job_id then
            state.service_job_id = nil
          end
          if state.service_starting then
            local message = 'service exited before becoming ready with code ' .. tostring(code)
            local output = last_service_output()
            if output then
              message = message .. ': ' .. output
            end
            finish(message)
            return
          end
          if code ~= 0 then
            local message = 'Service exited with code ' .. tostring(code)
            local output = last_service_output()
            if output then
              message = message .. ': ' .. output
            end
            append_entry('error', message)
          end
        end)
      end,
    })
    if service_job_id <= 0 then
      finish('failed to start service command: ' .. vim.inspect(command))
      return
    end

    state.service_job_id = service_job_id
    append_entry('system', 'Starting service: ' .. (type(command) == 'table' and table.concat(command, ' ') or command))

    local timeout_ms = tonumber(state.config.service.startup_timeout_ms) or defaults.service.startup_timeout_ms
    local interval_ms = tonumber(state.config.service.startup_poll_interval_ms) or defaults.service.startup_poll_interval_ms
    local attempts = math.max(1, math.floor(timeout_ms / interval_ms))
    poll_service_health(attempts)
  end)
end

request = function(method, path, body, callback, opts)
  opts = opts or {}
  raw_request(method, path, body, function(payload, err, status)
    if err and opts.auto_start ~= false and is_connection_error(err) then
      ensure_service_running(function(start_err)
        if start_err then
          callback(nil, err .. '\n' .. start_err, status)
          return
        end
        raw_request(method, path, body, callback)
      end)
      return
    end
    callback(payload, err, status)
  end)
end

local function on_session_ready(session_id, err)
  for _, callback in ipairs(state.pending_session_callbacks) do
    callback(session_id, err)
  end
  state.pending_session_callbacks = {}
end

local function handle_user_input(payload)
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
      answer(input, true)
    end)
  end

  append_entry('system', 'Input requested: ' .. request_payload.question)

  if #choices > 0 then
    local items = vim.deepcopy(choices)
    if allow_freeform then
      table.insert(items, 'Custom...')
    end
    vim.ui.select(items, { prompt = request_payload.question }, function(choice)
      if choice == nil then
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
    state.chat_busy = true
    refresh_statuslines()
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
    refresh_statuslines()
    render_chat() -- immediate full render on turn completion
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

local function start_event_stream(session_id)
  stop_event_stream()
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

  state.events_job_id = vim.fn.jobstart(args, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      vim.schedule(function()
        handle_sse_chunk(data)
      end)
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
      vim.schedule(function()
        state.events_job_id = nil
        if code ~= 0 and state.session_id == session_id then
          append_entry('error', 'Event stream stopped with exit code ' .. tostring(code))
        end
      end)
    end,
  })
end

local function resume_session(session_id, callback)
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

local function pick_or_create_session(callback)
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
      resume_session(s.sessionId, callback)
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
      resume_session(s.sessionId, callback)
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
        create_session(callback)
        return
      end
      local picked = choices[idx]
      if picked.id then
        append_entry('system', 'Resuming session ' .. picked.id)
        resume_session(picked.id, callback)
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
      local unavailable_model = unavailable_model_from_error(err)
      local stale_hint = stale_service_hint(unavailable_model)
      if stale_hint then
        notify(stale_hint, vim.log.levels.ERROR)
        append_entry('error', stale_hint)
        append_entry('error', 'Failed to create session: ' .. err)
        on_session_ready(nil, err)
        return
      end
      if unavailable_model and state.config.session.model == unavailable_model and opts.model_selection_attempts ~= false then
        append_entry('system', string.format('Model "%s" is unavailable; choose a supported model.', unavailable_model))
        prompt_supported_model_selection(unavailable_model, 'Select a supported Copilot model', function(reselected_model, prompt_err)
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
      set_agent_mode(state.input_mode)
    end
    on_session_ready(state.session_id)
    if callback then
      callback(state.session_id)
    end
  end)
end

fetch_models = function(callback, on_error)
  request('GET', '/models', nil, function(response, err, status)
    if err then
      if status == 404 then
        err = err .. '. The running Go host does not expose /models; restart it so Neovim and the service use the same build.'
      end
      if on_error then
        on_error(err)
      else
        callback(nil, err)
      end
      return
    end
    callback(store_model_cache(response and response.models or {}), nil)
  end)
end

prompt_supported_model_selection = function(unavailable_model, prompt, callback)
  fetch_models(function(models, err)
    if err then
      callback(nil, 'failed to list supported models: ' .. err)
      return
    end
    if type(models) ~= 'table' or vim.tbl_isempty(models) then
      callback(nil, 'no supported models returned by service')
      return
    end

    vim.ui.select(models, {
      prompt = prompt,
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        callback(nil, string.format('model "%s" is unavailable and no replacement was selected', unavailable_model))
        return
      end
      callback(choice.id, nil)
    end)
  end)
end

local function apply_model(model, callback, opts)
  opts = opts or {}
  local selected = vim.trim(model or '')
  local previous_model = state.config.session.model
  if selected == '' then
    if callback then
      callback(nil, 'model is required')
    end
    return
  end

  state.config.session.model = selected
  local known = false
  for _, item in ipairs(state.model_cache) do
    if item.id == selected then
      known = true
      break
    end
  end
  if not known then
    table.insert(state.model_cache, 1, {
      id = selected,
      name = selected,
      label = string.format('%s (%s)', selected, selected),
    })
  end
  if not state.session_id then
    append_entry('system', 'Model for next session: ' .. selected)
    if callback then
      callback(selected, nil)
    end
    return
  end

  local body = { model = selected }
  if opts.reasoning_effort and opts.reasoning_effort ~= '' then
    body.reasoningEffort = opts.reasoning_effort
  end
  request('POST', string.format('/sessions/%s/model', state.session_id), body, function(response, err)
    if err then
      local unavailable_model = unavailable_model_from_error(err)
      if unavailable_model and opts.model_selection_attempts ~= false then
        append_entry('system', string.format('Model "%s" is unavailable; choose a supported model.', unavailable_model))
        prompt_supported_model_selection(unavailable_model, 'Select a supported Copilot model', function(reselected_model, prompt_err)
          if prompt_err then
            state.config.session.model = previous_model
            if callback then
              callback(nil, prompt_err)
            end
            return
          end
          apply_model(reselected_model, callback, {
            model_selection_attempts = false,
          })
        end)
        return
      end
      state.config.session.model = previous_model
      if callback then
        callback(nil, err)
      end
      return
    end
    state.config.session.model = response and response.model or selected
    local msg = 'Active model: ' .. state.config.session.model
    if opts.reasoning_effort and opts.reasoning_effort ~= '' then
      state.reasoning_effort = opts.reasoning_effort
      msg = msg .. ' (effort: ' .. opts.reasoning_effort .. ')'
    end
    append_entry('system', msg)
    refresh_statuslines()
    if callback then
      callback(state.config.session.model, nil)
    end
  end)
end

local function with_session(callback)
  if state.session_id then
    callback(state.session_id)
    return
  end

  table.insert(state.pending_session_callbacks, callback)
  if state.creating_session then
    return
  end

  state.creating_session = true
  pick_or_create_session(nil)
end

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
