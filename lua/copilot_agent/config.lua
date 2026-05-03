-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local utils = require('copilot_agent.utils')
local logging = require('copilot_agent.log')

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
  file_log_level = 'WARN', -- TRACE logs raw host/session payloads; DEBUG logs plugin actions + HTTP details to stdpath('log')/copilot_agent.log
  log_content_length = 1000, -- max content length to include in logs (0 for unlimited, default 1000)
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
    -- Work around an upstream Neovim Treesitter/folding issue in plugin-owned
    -- markdown prompt buffers by disabling Treesitter for those transient UI
    -- windows. Set false if you prefer to keep Treesitter attached there.
    protect_markdown_buffer = true,
    -- Live-only reasoning preview sourced from assistant.reasoning_delta events.
    -- This is transient UI state: it is not written into the transcript/history.
    -- By default it appears automatically when reasoning deltas arrive; set
    -- enabled = false to suppress it explicitly.
    reasoning = {
      enabled = true,
      max_lines = 5,
    },
    -- File picker to use when attaching files/folders from <C-a>.
    -- 'auto' detects in order: snacks → telescope → fzf-lua → mini.pick → vim.ui.input
    -- Set to 'native' to always use vim.ui.input (completion-based path entry).
    file_picker = 'auto',
    -- Offer a vimdiff review when the agent modifies a git-tracked file.
    -- true  = prompt 'Open diff / Skip' after each file update (default)
    -- false = just notify and auto-reload changed open buffers
    diff_review = true,
    -- External diff command for the permission "Show diff" viewer.
    -- Set to a list like { 'delta' }, { 'diff-so-fancy' }, or { 'delta', '--side-by-side' }.
    -- Command output is captured and rendered into the float to avoid terminal
    -- exit messages and stream races. Falls back to builtin float if command not found.
    -- Set to false to always use the builtin floating diff window.
    diff_cmd = { 'delta' },
  },
  dashboard = {
    auto_open = true,
    buf_name = 'CopilotAgentDashboard',
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
  dashboard_bufnr = nil,
  dashboard_winid = nil,
  dashboard_prompt_bufnr = nil,
  dashboard_prompt_winid = nil,
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
  session_working_directory = nil, -- working directory bound to the active session
  pending_attachments = {}, -- list of {type, path, display} waiting to be sent
  chat_busy = false, -- true while the agent is processing a turn
  -- Thinking spinner
  thinking_timer = nil, -- uv timer while assistant is generating
  thinking_frame = 1, -- current spinner frame index
  thinking_entry_key = nil, -- key in assistant_entries that is currently "thinking"
  pending_assistant_entry_key = nil, -- stable placeholder key before the SDK assigns messageId
  pending_assistant_serial = 0, -- fallback sequence for placeholder assistant entries
  active_turn_assistant_index = nil, -- assistant transcript entry reused for the current live turn
  live_assistant_entry_index = nil, -- assistant entry still bound to the current in-flight SDK turn
  active_turn_assistant_message_id = nil, -- latest messageId mapped to the active turn assistant entry
  active_assistant_merge_group = nil, -- logical reply group for collapsing assistant transcript blocks
  assistant_merge_group_serial = 0, -- fallback sequence for assistant merge groups without a pending turn
  -- Incremental streaming render
  render_pending = false, -- true when a debounced render is scheduled
  stream_line_start = nil, -- 0-based buf line where current streaming entry content begins
  entry_row_index = {}, -- maps each transcript entry's starting chat row -> transcript entry index
  active_conversation_entry_index = nil, -- latest user entry anchoring the "current conversation" viewport
  chat_follow_topline = nil, -- last auto-managed topline for current conversation follow mode
  chat_auto_scroll_enabled = true, -- false after the user scrolls away from the live conversation; re-enabled at bottom
  chat_scroll_guard = 0, -- suppresses WinScrolled reactions for programmatic transcript scrolling
  chat_tail_spacer_lines = 0, -- real blank lines kept after transcript content while live overlay text is visible
  overlay_gutter_restore_view = nil, -- saved manual chat view to restore after temporary overlay gutter scrolling
  pending_checkpoint_turn = nil, -- active turn waiting for a completed-turn checkpoint label
  history_loading = false, -- true while replaying SSE history; suppresses render until done
  history_checkpoint_ids = nil, -- replay mapping keyed by assistant message id for completed turns
  history_pending_user_entries = {}, -- replayed user entries waiting for their completed-turn checkpoint label
  pending_user_input = nil, -- last unanswered ask_user request (for retry on dismiss)
  pending_checkpoint_ops = 0, -- completed turns still waiting on checkpoint persistence
  pending_workspace_updates = 0, -- file updates still being applied in Neovim
  background_tasks = {}, -- non-terminal background/subagent tasks still in flight
  -- Live agent activity (updated from SSE events, shown in statusline)
  current_model = nil, -- model ID from SDK events (overrides config default in display)
  active_tool = nil, -- name of currently executing tool (nil when idle)
  active_tool_run_id = nil, -- overlay queue id for the currently executing shell tool
  active_tool_detail = nil, -- detailed command/description for the active tool overlay
  pending_tool_detail = nil, -- latest tool detail seen before execution starts
  overlay_tool_display = nil, -- currently displayed shell activity item in the chat overlay
  overlay_tool_queue = {}, -- queued shell activity items waiting for minimum display time
  overlay_tool_run_id = 0, -- incrementing id assigned to shell activity items
  overlay_tool_schedule_token = 0, -- invalidates pending delayed overlay transitions
  recent_activity_lines = {}, -- deduped activity summary lines collected for the current turn
  recent_activity_items = {}, -- full per-turn activity items, including raw tool output/details for future viewers
  recent_activity_tool_calls = {}, -- maps current-turn toolCallId -> recent_activity_items index
  activity_entries_visible = false, -- show full Activity transcript blocks instead of collapsed placeholders
  current_intent = nil, -- latest intent string from assistant.intent event
  reasoning_entry_key = nil, -- assistant entry currently receiving reasoning deltas
  reasoning_text = '', -- raw reasoning delta text accumulated for the active turn
  reasoning_lines = {}, -- normalized reasoning preview lines (trimmed, not transcript)
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

return {
  defaults = defaults,
  state = state,
  SLASH_COMMANDS = SLASH_COMMANDS,
  notify = logging.notify,
  log = logging.log,
  log_path = logging.log_path,
  log_content_length = defaults.log_content_length,
  should_log = logging.should_log,
  serialize_log_value = logging.serialize_log_value,
  normalize_base_url = normalize_base_url,
}
