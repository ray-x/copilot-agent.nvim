-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local utils = require('copilot_agent.utils')

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
  file_log_level = 'WARN', -- DEBUG | INFO | WARN | ERROR; threshold for stdpath('log')/copilot_agent.log
  service = {
    auto_start = false,
    command = nil, -- nil = auto-detect installed binary, then fall back to 'go run .'
    cwd = nil, -- defaults to <plugin_root>/server
    env = nil,
    port_range = nil, -- e.g. '18000-19000'; appended as --port-range when set
    -- detach: run the Go service in a new process group (setsid) so it survives
    -- Neovim exit. On the next launch the health check finds it still running and
    -- skips the start-up delay. The bound address is persisted to a state file so
    -- dynamic-port setups also reconnect correctly.
    detach = true,
    healthcheck_path = '/healthz',
    startup_timeout_ms = 15000,
    startup_poll_interval_ms = 250,
  },
  chat = {
    split = 'botright vnew',
    title = 'Copilot Chat',
    -- buf_name: name assigned to the chat buffer. Use 'CopilotAgentChat' (the
    -- asterisks make it show as [CopilotAgentChat] in some UIs and easy to :b<Tab>).
    buf_name = 'CopilotAgentChat',
    -- fullscreen: when true the chat opens in a new tab instead of a vertical split.
    fullscreen = false,
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
    -- External diff command for the permission "Show diff" viewer.
    -- Set to a list like { 'delta' }, { 'diff-so-fancy' }, or { 'delta', '--side-by-side' }.
    -- Command output is captured and rendered into the float to avoid terminal
    -- exit messages and stream races. Falls back to builtin float if command not found.
    -- Set to false to always use the builtin floating diff window.
    diff_cmd = { 'delta' },
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
  event_stream_recovery_session_id = nil,
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
  base_url_managed = true, -- true unless setup() was given an explicit base_url
  pending_service_callbacks = {},
  service_output = {},
  model_cache = {},
  creating_session = false,
  pending_session_callbacks = {},
  open_input_on_session_ready = false,
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
  pending_user_input = nil, -- last unanswered ask_user request (for retry on dismiss)
  -- Live agent activity (updated from SSE events, shown in statusline)
  current_model = nil, -- model ID from SDK events (overrides config default in display)
  active_tool = nil, -- name of currently executing tool (nil when idle)
  current_intent = nil, -- latest intent string from assistant.intent event
  context_tokens = nil, -- current token count in context window
  context_limit = nil, -- max token count for context window
  instruction_count = 0, -- discovered repository instructions for the active session
  agent_count = 0, -- discovered repository agents for the active session
  skill_count = 0, -- discovered repository skills for the active session
  mcp_count = 0, -- discovered repository MCP servers for the active session
  allowed_directories = {}, -- user-approved directories for file access in this session
  allowed_tools = {}, -- user-approved tools for the rest of this session
}

-- Static list of slash commands supported by the Copilot CLI backend.
-- Notes: follow commands are not supported by this plugin
-- { word = '/pr', info = 'Operate on pull requests for current branch' },
-- { word = '/delegate', info = 'Send this session to GitHub and create a PR' },
-- { word = '/ide', info = 'Connect to an IDE workspace' },
-- { word = '/terminal-setup', info = 'Configure terminal for multiline input support' },
-- { word = '/remote', info = 'Show remote status or toggle remote control' },
-- { word = '/changelog', info = 'Display changelog for CLI versions' },
-- { word = '/feedback', info = 'Provide feedback about the CLI' },
-- { word = '/theme', info = 'View or set color mode' },
-- { word = '/update', info = 'Update the CLI to the latest version' },
-- { word = '/version', info = 'Display version information' },
-- { word = '/login', info = 'Log in to Copilot' },
-- { word = '/logout', info = 'Log out of an OAuth login session' },
-- { word = '/restart', info = 'Restart the CLI, preserving current session' },
-- { word = '/user', info = 'Manage GitHub user list' },
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
  { word = '/review', info = 'Run code review agent' },
  { word = '/lsp', info = 'Manage language server configuration' },
  { word = '/plan', info = 'Create an implementation plan' },
  { word = '/research', info = 'Run deep research investigation' },
  { word = '/init', info = 'Initialize Copilot instructions for this repository' },
  { word = '/agent', info = 'Browse and select available agents' },
  { word = '/skills', info = 'Manage skills for enhanced capabilities' },
  { word = '/mcp', info = 'Manage MCP server configuration' },
  { word = '/fleet', info = 'Enable fleet mode for parallel subagent execution' },
  { word = '/tasks', info = 'View and manage background tasks' },
  { word = '/allow-all', info = 'Enable all permissions' },
  { word = '/add-dir', info = 'Add a directory to the allowed list' },
  { word = '/list-dirs', info = 'Display all allowed directories' },
  { word = '/cwd', info = 'Change or show working directory' },
  { word = '/reset-allowed-tools', info = 'Reset the list of allowed tools' },
  { word = '/share', info = 'Share session to markdown, HTML, or GitHub gist' },
  { word = '/copy', info = 'Copy the last response to the clipboard' },
  { word = '/rewind', info = 'Rewind the last turn and revert file changes' },
  { word = '/undo', info = 'Rewind the last turn and revert file changes' },
  { word = '/ask', info = 'Ask a quick side question without adding to history' },
  { word = '/search', info = 'Search the conversation timeline' },
  { word = '/env', info = 'Show loaded environment details' },
  { word = '/experimental', info = 'Show/enable/disable experimental features' },
  { word = '/instructions', info = 'View and toggle custom instruction files' },
  { word = '/exit', info = 'Exit the CLI' },
}

local function normalize_base_url(url)
  return utils.normalize_base_url(url, defaults.base_url)
end

local function log_path()
  return vim.fn.stdpath('log') .. '/copilot_agent.log'
end

local _log_levels = {
  DEBUG = vim.log.levels.DEBUG,
  INFO = vim.log.levels.INFO,
  WARN = vim.log.levels.WARN,
  ERROR = vim.log.levels.ERROR,
}

local function resolve_file_log_level(value)
  if type(value) == 'number' then
    return value
  end
  if type(value) == 'string' then
    return _log_levels[value:upper()]
  end
  return nil
end

local function log(message, level)
  local configured_level = resolve_file_log_level(state.config.file_log_level) or vim.log.levels.WARN
  level = level or vim.log.levels.INFO
  if level < configured_level then
    return
  end

  local prefix = ({
    [vim.log.levels.DEBUG] = 'DEBUG',
    [vim.log.levels.INFO] = 'INFO',
    [vim.log.levels.WARN] = 'WARN',
    [vim.log.levels.ERROR] = 'ERROR',
  })[level or vim.log.levels.INFO] or 'INFO'
  local line = string.format('%s [%s] %s\n', os.date('%Y-%m-%d %H:%M:%S'), prefix, tostring(message))
  pcall(function()
    local path = log_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local f = assert(io.open(path, 'a'))
    f:write(line)
    f:close()
  end)
end

local function notify(message, level)
  log(message, level)
  if state.config.notify == false then
    return
  end
  vim.notify('[copilot-agent] ' .. message, level or vim.log.levels.INFO)
end

return {
  defaults = defaults,
  state = state,
  SLASH_COMMANDS = SLASH_COMMANDS,
  notify = notify,
  log = log,
  log_path = log_path,
  normalize_base_url = normalize_base_url,
}
