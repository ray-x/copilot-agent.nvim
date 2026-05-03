-- Integration test: load the plugin and verify basic setup.
-- Requires headless Neovim with plugin on runtimepath.
-- Run via:  nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/integration/setup_spec.lua"
-- or the CI workflow.

-- Use plenary if available, otherwise a tiny shim.
local assert_eq, assert_true, assert_false, assert_not_nil
do
  local ok, luassert = pcall(require, 'luassert')
  if ok then
    assert_eq = function(a, b, msg)
      luassert.equal(a, b, msg)
    end
    assert_true = function(v, msg)
      luassert.is_true(v, msg)
    end
    assert_false = function(v, msg)
      luassert.is_false(v, msg)
    end
    assert_not_nil = function(v, msg)
      luassert.is_not_nil(v, msg)
    end
  else
    local function fail(msg)
      error(msg, 3)
    end
    assert_eq = function(a, b, msg)
      if a ~= b then
        fail(msg or ('expected ' .. tostring(b) .. ' got ' .. tostring(a)))
      end
    end
    assert_true = function(v, msg)
      if not v then
        fail(msg or 'expected true')
      end
    end
    assert_false = function(v, msg)
      if v then
        fail(msg or 'expected false')
      end
    end
    assert_not_nil = function(v, msg)
      if v == nil then
        fail(msg or 'expected non-nil')
      end
    end
  end
end

local function virt_line_text(virt_line)
  local chunks = {}
  for _, chunk in ipairs(virt_line or {}) do
    chunks[#chunks + 1] = chunk[1] or ''
  end
  return table.concat(chunks)
end

local function trimmed_virt_lines(virt_lines)
  return vim.tbl_map(function(virt_line)
    return virt_line_text(virt_line):gsub('^%s+', '')
  end, virt_lines or {})
end

local function command_exists(name)
  return vim.fn.exists(':' .. name) == 2
end

local function expected_local_session_id(prefix, seconds)
  return string.format('%s-%s', prefix, os.date('%Y-%m-%dT%H:%M:%S', seconds))
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

describe('plugin load', function()
  it('require copilot_agent does not error', function()
    local ok, mod = pcall(require, 'copilot_agent')
    assert_true(ok, 'require copilot_agent should not error')
    assert_not_nil(mod, 'module should be non-nil')
  end)

  it('require copilot_agent.utils does not error', function()
    local ok, mod = pcall(require, 'copilot_agent.utils')
    assert_true(ok, 'require copilot_agent.utils should not error')
    assert_not_nil(mod)
  end)

  it('require copilot_agent.health does not error', function()
    local ok, mod = pcall(require, 'copilot_agent.health')
    assert_true(ok, 'require copilot_agent.health should not error')
    assert_not_nil(mod)
  end)
end)

describe('M.setup', function()
  local agent

  before_each(function()
    package.loaded['copilot_agent'] = nil
    agent = require('copilot_agent')
  end)

  it('returns the module', function()
    local result = agent.setup({ auto_create_session = false })
    assert_eq(result, agent, 'setup should return the module')
  end)

  it('applies default base_url without trailing slash', function()
    agent.setup({ auto_create_session = false })
    local url = agent.state.config.base_url
    assert_not_nil(url)
    assert_false(url:sub(-1) == '/', 'base_url should not have trailing slash')
  end)

  it('merges user base_url over default', function()
    agent.setup({ auto_create_session = false, base_url = 'http://127.0.0.1:9999' })
    assert_eq('http://127.0.0.1:9999', agent.state.config.base_url)
  end)

  it('sets permission_mode from config', function()
    agent.setup({ auto_create_session = false, permission_mode = 'approve-all' })
    assert_eq('approve-all', agent.state.permission_mode)
  end)

  it('permission_mode defaults to approve-all', function()
    agent.setup({ auto_create_session = false })
    assert_eq('approve-all', agent.state.permission_mode)
  end)

  it('session_id is nil after setup', function()
    agent.setup({ auto_create_session = false })
    assert_eq(nil, agent.state.session_id)
  end)

  it('chat_busy is false after setup', function()
    agent.setup({ auto_create_session = false })
    assert_false(agent.state.chat_busy)
  end)

  it('nested service.port_range is preserved', function()
    agent.setup({ auto_create_session = false, service = { port_range = '18000-19000' } })
    assert_eq('18000-19000', agent.state.config.service.port_range)
  end)

  it('unrelated service defaults survive partial override', function()
    agent.setup({ auto_create_session = false, service = { port_range = '18000-19000' } })
    assert_not_nil(agent.state.config.service.startup_timeout_ms)
  end)

  it('entries table starts empty', function()
    agent.setup({ auto_create_session = false })
    assert_eq(0, #agent.state.entries)
  end)

  it('writes notify messages to copilot_agent.log', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false })
    require('copilot_agent.config').notify('logger smoke test', vim.log.levels.WARN)

    vim.fn.stdpath = original_stdpath
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    assert_true(#lines > 0)
    assert_true(lines[#lines]:find('logger smoke test', 1, true) ~= nil)
  end)

  it('defaults file logging to WARN threshold', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false })
    local cfg = require('copilot_agent.config')
    cfg.log('info should be skipped', vim.log.levels.INFO)
    cfg.log('warn should be written', vim.log.levels.WARN)

    vim.fn.stdpath = original_stdpath
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    assert_eq(1, #lines)
    assert_true(lines[1]:find('warn should be written', 1, true) ~= nil)
  end)

  it('allows overriding file log threshold', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false, file_log_level = 'INFO' })
    local cfg = require('copilot_agent.config')
    cfg.log('info should be written', vim.log.levels.INFO)

    vim.fn.stdpath = original_stdpath
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    assert_eq(1, #lines)
    assert_true(lines[1]:find('info should be written', 1, true) ~= nil)
  end)

  it('accepts TRACE as a file log threshold', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false, file_log_level = 'TRACE' })
    local cfg = require('copilot_agent.config')
    cfg.log('trace should be written', vim.log.levels.TRACE or vim.log.levels.DEBUG)

    vim.fn.stdpath = original_stdpath
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    assert_eq(1, #lines)
    assert_true(lines[1]:find('trace should be written', 1, true) ~= nil)
  end)

  it('includes the caller file and line number in DEBUG log entries', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false, file_log_level = 'DEBUG' })
    local cfg = require('copilot_agent.config')
    local expected_line = debug.getinfo(1, 'l').currentline + 1
    cfg.log('caller metadata smoke test', vim.log.levels.DEBUG)

    vim.fn.stdpath = original_stdpath
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    assert_eq(1, #lines)
    assert_true(lines[1]:find('tests/integration/setup_spec.lua:' .. expected_line, 1, true) ~= nil)
    assert_true(lines[1]:find('caller metadata smoke test', 1, true) ~= nil)
  end)

  it('logs HTTP actions and sanitized session events when TRACE file logging is enabled', function()
    local original_stdpath = vim.fn.stdpath
    local original_vim_system = vim.system
    local temp_log_dir = vim.fn.tempname()
    local reasoning_id = '1234567890abcdef1234567890abcdef-extra-tail'
    local truncated_reasoning_id = '1234567890abcdef1234567890abcdef'
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false, file_log_level = 'TRACE' })
    local cfg = require('copilot_agent.config')
    local http = require('copilot_agent.http')
    local events = require('copilot_agent.events')
    local encode_json = (vim.json and vim.json.encode) or vim.fn.json_encode
    local max_content_len = cfg.log_content_length or 120
    local long_content = string.rep('A', max_content_len + 10)
    local truncated_content = string.rep('A', max_content_len - 1) .. '…'

    vim.system = function()
      return {
        wait = function()
          return {
            code = 0,
            stdout = '{"ok":true}\n200',
            stderr = '',
          }
        end,
      }
    end

    http.sync_request('POST', '/debug-log', { prompt = 'trace me' })
    agent.state.sse_event = {
      event = 'session.event',
      data = {
        encode_json({
          type = 'assistant.message',
          data = {
            messageId = 'debug-turn',
            content = long_content,
            encryptedContent = 'top-secret',
            reasoningId = reasoning_id,
          },
        }),
      },
    }
    events.flush_sse_event()

    vim.system = original_vim_system
    vim.fn.stdpath = original_stdpath

    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('http.sync request method=POST path=/debug-log', 1, true) ~= nil)
    assert_true(joined:find('http.sync response method=POST path=/debug-log status=200', 1, true) ~= nil)
    assert_true(joined:find('sse.event raw event=session.event', 1, true) ~= nil)
    assert_true(joined:find('session.event received type=assistant.message', 1, true) ~= nil)
    assert_true(joined:find('content = "' .. truncated_content .. '"', 1, true) ~= nil)
    assert_true(joined:find('reasoningId = "' .. truncated_reasoning_id .. '"', 1, true) ~= nil)
    assert_true(joined:find('encryptedContent', 1, true) == nil)
    assert_true(joined:find('top-secret', 1, true) == nil)
    assert_true(joined:find(reasoning_id, 1, true) == nil)
  end)

  it('logs non-json session events as strings before decode failure handling at TRACE level', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false, file_log_level = 'TRACE' })
    local events = require('copilot_agent.events')

    agent.state.sse_event = {
      event = 'session.event',
      data = {
        'plain text session event',
      },
    }
    events.flush_sse_event()

    vim.fn.stdpath = original_stdpath

    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('sse.event raw event=session.event string=plain text session event', 1, true) ~= nil)
  end)

  it('keeps raw host and session trace payloads out of DEBUG file logging', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({ auto_create_session = false, notify = false, file_log_level = 'DEBUG' })
    local events = require('copilot_agent.events')
    local encode_json = (vim.json and vim.json.encode) or vim.fn.json_encode

    events.handle_host_event('host.session_attached', {
      data = {
        sessionId = 'session-trace-debug',
      },
    })
    agent.state.sse_event = {
      event = 'session.event',
      data = {
        encode_json({
          type = 'assistant.message',
          data = {
            messageId = 'assistant-debug-trace',
            content = 'hello',
          },
        }),
      },
    }
    events.flush_sse_event()

    vim.fn.stdpath = original_stdpath

    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('host.event received event=host.session_attached', 1, true) == nil)
    assert_true(joined:find('sse.event raw event=session.event', 1, true) == nil)
    assert_true(joined:find('session.event received type=assistant.message', 1, true) == nil)
    assert_true(joined:find('assistant.message preserving stream start', 1, true) ~= nil)
  end)
end)

describe('service coordination', function()
  local agent
  local service
  local original_stdpath
  local temp_state_dir

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.service'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    service = require('copilot_agent.service')
    original_stdpath = vim.fn.stdpath
    temp_state_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_state_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'state' then
        return temp_state_dir
      end
      return original_stdpath(kind)
    end
  end)

  after_each(function()
    vim.fn.stdpath = original_stdpath
    pcall(service._release_spawn_lock)
  end)

  it('refreshes the managed base url from the shared addr file', function()
    agent.state.base_url_managed = true
    agent.state.config.base_url = 'http://127.0.0.1:1111'

    service._save_service_addr('127.0.0.1:2222')

    assert_true(service._refresh_service_addr_from_state())
    assert_eq('http://127.0.0.1:2222', agent.state.config.base_url)
  end)

  it('does not override an explicit base url from the shared addr file', function()
    agent.state.base_url_managed = false
    agent.state.config.base_url = 'http://127.0.0.1:9999'

    service._save_service_addr('127.0.0.1:2222')

    assert_false(service._refresh_service_addr_from_state())
    assert_eq('http://127.0.0.1:9999', agent.state.config.base_url)
  end)

  it('uses a startup lock to serialize service spawns', function()
    local acquired1 = service._try_acquire_spawn_lock(1000)
    local acquired2 = service._try_acquire_spawn_lock(1000)

    service._release_spawn_lock()

    local acquired3 = service._try_acquire_spawn_lock(1000)

    assert_true(acquired1)
    assert_false(acquired2)
    assert_true(acquired3)
  end)

  it('reclaims stale startup locks', function()
    local lock_dir = service._addr_lock_dir()
    vim.fn.mkdir(lock_dir, 'p')
    vim.fn.writefile({ '0', tostring(vim.fn.getpid()) }, lock_dir .. '/owner')

    assert_true(service._try_acquire_spawn_lock(1000))
  end)
end)

describe('user commands', function()
  before_each(function()
    package.loaded['copilot_agent'] = nil
    vim.g.loaded_copilot_agent_plugin = nil
    local plugin_files = vim.api.nvim_get_runtime_file('plugin/copilot_agent.lua', false)
    if plugin_files[1] then
      vim.cmd('source ' .. vim.fn.fnameescape(plugin_files[1]))
    end
  end)

  local expected_commands = {
    'CopilotAgentChat',
    'CopilotAgentChatToggle',
    'CopilotAgentChatFocus',
    'CopilotAgentDashboard',
    'CopilotAgentNewSession',
    'CopilotAgentSwitchSession',
    'CopilotAgentDeleteSession',
    'CopilotAgentStart',
    'CopilotAgentAsk',
    'CopilotAgentModel',
    'CopilotAgentStop',
    'CopilotAgentStatus',
    'CopilotAgentLsp',
  }

  for _, cmd in ipairs(expected_commands) do
    it(cmd .. ' is registered', function()
      assert_true(command_exists(cmd), cmd .. ' should exist')
    end)
  end
end)

describe('dashboard', function()
  local agent
  local dashboard
  local session_mod
  local original_latest_project_session_sync

  local function find_line_containing(lines, needle)
    for _, line in ipairs(lines) do
      if line:find(needle, 1, true) then
        return line
      end
    end
    return nil
  end

  before_each(function()
    pcall(vim.cmd, 'tabonly | only')
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.dashboard'] = nil
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      dashboard = {
        auto_open = false,
      },
      service = {
        auto_start = false,
      },
    })
    dashboard = require('copilot_agent.dashboard')
    session_mod = require('copilot_agent.session')
    original_latest_project_session_sync = session_mod.latest_project_session_sync
    session_mod.latest_project_session_sync = function()
      return {
        sessionId = 'recent-session-id',
        summary = 'Recent project session',
        workingDirectory = vim.fn.getcwd(),
      }, nil
    end
    vim.cmd('enew')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })
    vim.bo[0].modified = false
  end)

  after_each(function()
    if session_mod then
      session_mod.latest_project_session_sync = original_latest_project_session_sync
    end
    dashboard.close()
    pcall(vim.cmd, 'tabonly | only')
  end)

  it('opens a centered dashboard with the last project session and a prompt split', function()
    local bufnr = agent.open_dashboard()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local prompt_bufnr = agent.state.dashboard_prompt_bufnr
    local title_line = find_line_containing(lines, 'Copilot Agent Dashboard')
    local session_line = find_line_containing(lines, 'Last session: Recent project session [recent-session-id]')
    local connect_line = find_line_containing(lines, '[l] Connect last session')
    local switch_line = find_line_containing(lines, '[s] Select session')
    local model_line = find_line_containing(lines, '[m] Select model')
    local logo_lines = dashboard._logo_lines
    local short_logo_line = logo_lines[1]
    local wide_logo_line = logo_lines[1]
    local logo_block_width = 0

    assert_eq(bufnr, agent.state.dashboard_bufnr)
    assert_eq('copilot-agent-dashboard', vim.bo[bufnr].filetype)
    assert_eq('nofile', vim.bo[bufnr].buftype)
    assert_eq('wipe', vim.bo[bufnr].bufhidden)
    assert_eq('copilot-agent-dashboard-prompt', vim.bo[prompt_bufnr].filetype)
    assert_true(vim.api.nvim_buf_get_name(prompt_bufnr):find('CopilotAgentDashboardPrompt', 1, true) ~= nil)
    assert_eq(2, vim.api.nvim_win_get_height(agent.state.dashboard_prompt_winid))
    assert_true(vim.wo[agent.state.dashboard_prompt_winid].winbar:find('Enter command', 1, true) ~= nil)
    assert_eq(agent.state.dashboard_prompt_winid, vim.api.nvim_get_current_win())
    assert_eq(true, vim.b[bufnr].minisessions_disable)
    assert_eq(true, vim.b[prompt_bufnr].minisessions_disable)
    assert_not_nil(find_line_containing(lines, short_logo_line))
    assert_not_nil(title_line)
    assert_not_nil(session_line)
    assert_not_nil(connect_line)
    assert_not_nil(switch_line)
    assert_not_nil(model_line)
    assert_true(find_line_containing(lines, 'Open chat') == nil)
    assert_true(find_line_containing(lines, ':CopilotAgentAsk') == nil)

    for _, logo_line in ipairs(logo_lines) do
      local logo_line_width = vim.fn.strdisplaywidth(logo_line)
      if logo_line_width > logo_block_width then
        logo_block_width = logo_line_width
        wide_logo_line = logo_line
      end
    end

    local block_padding = math.floor((vim.api.nvim_win_get_width(agent.state.dashboard_winid) - logo_block_width) / 2)
    local rendered_short_logo_line = find_line_containing(lines, short_logo_line)
    local rendered_wide_logo_line = find_line_containing(lines, wide_logo_line)

    assert_eq(string.rep(' ', block_padding) .. short_logo_line .. string.rep(' ', logo_block_width - vim.fn.strdisplaywidth(short_logo_line)), rendered_short_logo_line)
    assert_eq(string.rep(' ', block_padding) .. wide_logo_line .. string.rep(' ', logo_block_width - vim.fn.strdisplaywidth(wide_logo_line)), rendered_wide_logo_line)

    local expected_padding = math.floor((vim.api.nvim_win_get_width(agent.state.dashboard_winid) - vim.fn.strdisplaywidth('Copilot Agent Dashboard')) / 2)
    local actual_padding = (title_line:find('%S') or 1) - 1
    assert_eq(expected_padding, actual_padding)
  end)

  it('opens on startup when Neovim starts with an empty buffer', function()
    agent.state.config.dashboard.auto_open = true

    dashboard.maybe_open_on_startup()

    local bufnr = agent.state.dashboard_bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq(agent.state.dashboard_bufnr, bufnr)
    assert_eq('copilot-agent-dashboard', vim.bo[bufnr].filetype)
    assert_eq(agent.state.dashboard_prompt_winid, vim.api.nvim_get_current_win())
    assert_not_nil(find_line_containing(lines, 'Use the prompt below to resume the latest session in this folder or create a new one.'))
  end)

  it('submitting the dashboard prompt hands off to chat in the current project session', function()
    local original_attach_latest_project = session_mod.attach_latest_project_session_or_create
    local original_open_chat = agent.open_chat
    local original_ask = agent.ask
    local original_execute_slash = agent.execute_slash_command
    local calls = {}

    session_mod.attach_latest_project_session_or_create = function(callback)
      calls.attach = true
      agent.state.session_id = 'project-session'
      callback('project-session', nil)
    end
    agent.open_chat = function(opts)
      calls.open_chat = opts
    end
    agent.ask = function(prompt)
      calls.ask = prompt
    end
    agent.execute_slash_command = function(prompt)
      calls.execute = prompt
      return false
    end

    agent.open_dashboard()
    dashboard._submit_prompt('Explain the latest changes')

    session_mod.attach_latest_project_session_or_create = original_attach_latest_project
    agent.open_chat = original_open_chat
    agent.ask = original_ask
    agent.execute_slash_command = original_execute_slash

    assert_true(calls.attach == true)
    assert_eq('Explain the latest changes', calls.execute)
    assert_eq('Explain the latest changes', calls.ask)
    assert_true(calls.open_chat.replace_current)
    assert_false(agent.state.dashboard_prompt_winid ~= nil and vim.api.nvim_win_is_valid(agent.state.dashboard_prompt_winid))
  end)
end)

describe('statusline API', function()
  local agent

  before_each(function()
    package.loaded['copilot_agent'] = nil
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      chat = {
        reasoning = {
          enabled = true,
          max_lines = 3,
        },
      },
      service = {
        auto_start = true,
      },
    })
  end)

  after_each(function()
    agent.state.chat_busy = false
    agent.state.pending_checkpoint_ops = 0
    agent.state.pending_workspace_updates = 0
    agent.state.background_tasks = {}
    agent.state.pending_user_input = nil
  end)

  it('statusline_mode returns a string', function()
    assert_eq('string', type(agent.statusline_mode()))
  end)

  it('statusline_model returns a string', function()
    assert_eq('string', type(agent.statusline_model()))
  end)

  it('statusline_busy returns a string', function()
    assert_eq('string', type(agent.statusline_busy()))
  end)

  it('statusline_busy reports ready, working, syncing, active tasks, and input-needed states', function()
    assert_eq('✅ready', agent.statusline_busy())

    agent.state.chat_busy = true
    assert_eq('⏳working', agent.statusline_busy())

    agent.state.chat_busy = false
    agent.state.pending_checkpoint_ops = 1
    assert_eq('📝sync', agent.statusline_busy())

    agent.state.pending_checkpoint_ops = 0
    agent.state.background_tasks = {
      ['subagent:task-1'] = { status = 'running' },
      ['background:task-2'] = { status = 'idle' },
    }
    assert_eq('🧩2 tasks', agent.statusline_busy())

    agent.state.background_tasks = {}
    agent.state.pending_user_input = { data = { request = { id = 'req-1' } } }
    assert_eq('❓input', agent.statusline_busy())
  end)

  it('statusline returns a non-empty string', function()
    local v = agent.statusline()
    assert_eq('string', type(v))
    assert_true(#v > 0)
  end)

  it('chat and input statuslines show responsive session labels and formatted ids', function()
    local statusline = require('copilot_agent.statusline')
    local expected_id = '#' .. expected_local_session_id('nvim', 1717245296):gsub('T', ' ', 1)
    local chat_winid = vim.api.nvim_get_current_win()
    local original_get_width = vim.api.nvim_win_get_width
    local widths = {}
    vim.cmd('belowright new')
    local input_winid = vim.api.nvim_get_current_win()

    agent.state.chat_winid = chat_winid
    agent.state.input_winid = input_winid
    agent.state.session_id = 'nvim-1717245296789000000'
    agent.state.session_name = nil
    widths[chat_winid] = 200
    widths[input_winid] = 200
    vim.api.nvim_win_get_width = function(winid)
      return widths[winid] or original_get_width(winid)
    end
    statusline.refresh_chat_statusline()
    statusline.refresh_input_statusline()
    assert_true(vim.wo[chat_winid].statusline:find('session: [' .. expected_id .. ']', 1, true) ~= nil)
    assert_true(vim.wo[input_winid].statusline:find('session: [' .. expected_id .. ']', 1, true) == nil)

    agent.state.session_name = 'abcdefghijklmnopqrstuvwxyz0123456789'
    statusline.refresh_chat_statusline()
    statusline.refresh_input_statusline()
    assert_true(vim.wo[chat_winid].statusline:find('session: [abcdefghijklmnopqrstuvwxyz012345 ' .. expected_id .. ']', 1, true) ~= nil)
    assert_true(vim.wo[input_winid].statusline:find('session: [abcdefghijklmnopqrstuvwxyz012345 ' .. expected_id .. ']', 1, true) == nil)
    assert_true(vim.wo[chat_winid].statusline:find('session: abcdefghijklmnopqrstuvwxyz0123456789', 1, true) == nil)

    widths[chat_winid] = 120
    statusline.refresh_chat_statusline()
    assert_true(vim.wo[chat_winid].statusline:find('session: [abcdefghijklmnop ' .. expected_id .. ']', 1, true) ~= nil)

    widths[chat_winid] = 80
    statusline.refresh_chat_statusline()
    assert_true(vim.wo[chat_winid].statusline:find('session: [' .. expected_id .. ']', 1, true) ~= nil)
    assert_true(vim.wo[chat_winid].statusline:find('session: [abcdefghijklmnop', 1, true) == nil)

    agent.state.current_model = 'claude-opus-4.7'
    agent.state.reasoning_effort = 'high'
    agent.state.current_intent = 'Running a very long shell command in a narrow split'
    widths[chat_winid] = 36
    widths[input_winid] = 36
    statusline.refresh_chat_statusline()
    statusline.refresh_input_statusline()
    local chat_text = vim.wo[chat_winid].statusline:gsub('%%#.-#', ''):gsub('%%%*', '')
    local input_text = vim.wo[input_winid].statusline:gsub('%%#.-#', ''):gsub('%%%*', '')
    assert_true(vim.fn.strdisplaywidth(chat_text) <= widths[chat_winid])
    assert_true(vim.fn.strdisplaywidth(input_text) <= widths[input_winid])

    agent.state.session_id = '123e4567-e89b-12d3-a456-426614174000'
    agent.state.session_name = 'uuid session name'
    widths[chat_winid] = 200
    statusline.refresh_chat_statusline()
    assert_true(vim.wo[chat_winid].statusline:find('session: [uuid session name #123e4567]', 1, true) ~= nil)

    vim.api.nvim_win_get_width = original_get_width
  end)
end)

describe('model state sync', function()
  local agent
  local events

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      chat = {
        reasoning = {
          enabled = true,
          max_lines = 3,
        },
      },
      service = {
        auto_start = true,
      },
    })
    events = require('copilot_agent.events')
  end)

  it('syncs model changes from host events', function()
    agent.state.current_model = 'claude-sonnet-4.6'
    agent.state.config.session.model = 'claude-sonnet-4.6'
    agent.state.reasoning_effort = 'high'

    events.handle_host_event('host.model_changed', {
      data = {
        model = 'gpt-5.5',
      },
    })

    assert_eq('gpt-5.5', agent.state.current_model)
    assert_eq('gpt-5.5', agent.state.config.session.model)
    assert_eq(nil, agent.state.reasoning_effort)
  end)

  it('syncs attached session model state from host events', function()
    events.handle_host_event('host.session_attached', {
      data = {
        sessionId = 'session-123',
        model = 'claude-opus-4.7',
        reasoningEffort = 'medium',
        summary = 'Attached session',
        instructionCount = 2,
        agentCount = 1,
        skillCount = 3,
        mcpCount = 4,
      },
    })

    assert_eq('claude-opus-4.7', agent.state.current_model)
    assert_eq('claude-opus-4.7', agent.state.config.session.model)
    assert_eq('medium', agent.state.reasoning_effort)
    assert_eq('Attached session', agent.state.session_name)
    assert_eq(2, agent.state.instruction_count)
    assert_eq(1, agent.state.agent_count)
    assert_eq(3, agent.state.skill_count)
    assert_eq(4, agent.state.mcp_count)
  end)

  it('syncs model and reasoning effort from session events', function()
    events.handle_session_event({
      type = 'session.model_change',
      data = {
        newModel = 'claude-opus-4.7',
        newReasoningEffort = 'medium',
      },
    })

    assert_eq('claude-opus-4.7', agent.state.current_model)
    assert_eq('claude-opus-4.7', agent.state.config.session.model)
    assert_eq('medium', agent.state.reasoning_effort)
  end)

  it('tracks rolling reasoning deltas and exposes them through the public API', function()
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-1',
        deltaContent = 'alpha\nbeta\n',
      },
    })
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-1',
        deltaContent = 'gamma\ndelta',
      },
    })

    local reasoning = agent.get_reasoning()
    assert_true(reasoning.active)
    assert_eq('assistant-1', reasoning.entry_key)
    assert_eq('alpha\nbeta\ngamma\ndelta', reasoning.text)
    assert_eq(3, #reasoning.lines)
    assert_eq('beta', reasoning.lines[1])
    assert_eq('gamma', reasoning.lines[2])
    assert_eq('delta', reasoning.lines[3])
    assert_true(agent.statusline_reasoning(24):find('delta', 1, true) ~= nil)

    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    reasoning = agent.get_reasoning()
    assert_false(reasoning.active)
    assert_eq('', reasoning.text)
    assert_eq(0, #reasoning.lines)
  end)

  it('renders a rolling reasoning preview in chat virtual lines', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-2',
        deltaContent = 'one\ntwo\nthree\nfour',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = vim.tbl_map(function(virt_line)
      return virt_line[1][1]
    end, virt_lines)

    assert_eq('  Reasoning: two', preview[1])
    assert_eq('             three', preview[2])
    assert_eq('             four', preview[3])

    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.wait(200)
    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
  end)

  it('renders reasoning overlay during a continuous burst of deltas', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-burst',
        deltaContent = 'one',
      },
    })
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-burst',
        deltaContent = '\ntwo',
      },
    })
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-burst',
        deltaContent = '\nthree',
      },
    })

    vim.wait(30)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)
    local virt_lines = extmarks[1][4].virt_lines or {}
    assert_true(#virt_lines > 0)

    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
  end)

  it('shows reasoning preview by default when reasoning deltas arrive', function()
    agent.state.config.chat.reasoning.enabled = nil
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-auto-reasoning',
        deltaContent = 'one\ntwo',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)
  end)

  it('clears the reasoning preview as soon as assistant output starts', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-reasoning-clear',
        deltaContent = 'step one\nstep two',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-reasoning-clear',
        deltaContent = 'final answer',
      },
    })

    vim.wait(200)

    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)

    local reasoning = agent.get_reasoning()
    assert_false(reasoning.active)
    assert_eq('', reasoning.text)
  end)

  it('keeps the reasoning preview when turn_start arrives after reasoning deltas', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-late-turn-start',
        deltaContent = 'step one\nstep two',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })

    vim.wait(200)

    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local reasoning = agent.get_reasoning()
    assert_true(reasoning.active)
    assert_eq('step one\nstep two', reasoning.text)
    assert.same({ 'step one', 'step two' }, reasoning.lines)
  end)

  it('renders only the active shell command in chat virtual lines', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.intent',
      data = {
        intent = 'Running shell command',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
      },
    })
    events.handle_session_event({
      type = 'subagent.started',
      data = {
        toolCallId = 'task-1',
        agentDisplayName = 'Document Update Agent',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    assert_eq(1, #virt_lines[1])
    assert_eq('  Activity: 🔧 bash', virt_line_text(virt_lines[1]))
    local preview = trimmed_virt_lines(virt_lines)

    assert_eq('Activity: 🔧 bash', preview[1])
    assert_eq(nil, preview[2])

    events.handle_session_event({
      type = 'subagent.completed',
      data = {
        toolCallId = 'task-1',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.intent',
      data = {},
    })

    vim.wait(200)
    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    vim.wait(3200)
    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
  end)

  it('renders the shell command text in activity virtual lines while bash runs', function()
    agent.open_chat()

    events.handle_host_event('host.permission_requested', {
      data = {
        mode = 'approve-all',
        request = {
          request = {
            kind = 'shell',
            fullCommandText = 'python scripts/build.py --target test',
          },
        },
      },
    })

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)

    assert_true(#preview >= 2)
    assert_eq('Activity: 🔧 bash — python scripts/build.py --target test', table.concat(preview, ' '))

    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })

    vim.wait(200)
    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)
    virt_lines = extmarks[1][4].virt_lines or {}
    preview = trimmed_virt_lines(virt_lines)
    assert_true(#preview >= 2)
    assert_eq('Activity: 🔧 bash — python scripts/build.py --target test', table.concat(preview, ' '))

    vim.wait(3200)
    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
  end)

  it('uses command and arguments from tool.execution_start when permission text is unavailable', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'diff', '--name-only' },
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)

    assert_eq('Activity: 🔧 bash — git diff --name-only', preview[1])
  end)

  it('uses nested shell command fields from tool.execution_start when flat fields are unavailable', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        input = {
          command = 'git',
          args = { 'status', '--short' },
        },
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)

    assert_eq('Activity: 🔧 bash — git status --short', preview[1])
  end)

  it('uses nested shell permission details when fullCommandText is unavailable', function()
    agent.open_chat()

    events.handle_host_event('host.permission_requested', {
      data = {
        mode = 'approve-all',
        request = {
          request = {
            kind = 'shell',
            input = {
              command = 'python',
              args = { 'scripts/build.py', '--target', 'test' },
            },
          },
        },
      },
    })

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)

    assert_true(#preview >= 2)
    assert_eq('Activity: 🔧 bash — python scripts/build.py --target test', table.concat(preview, ' '))
  end)

  it('does not show internal tools like sql in activity virtual lines without meaningful details', function()
    agent.open_chat()

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'sql',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
  end)

  it('does not surface historical tool activity in live virtual text after session load', function()
    agent.open_chat()
    agent.state.history_loading = true

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'diff', '--name-only' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })

    agent.state.history_loading = false
    require('copilot_agent.render').refresh_reasoning_overlay(true)
    vim.wait(50)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
  end)

  it('replaces activity immediately when a new shell command starts after the previous one finishes', function()
    agent.open_chat()

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    events.handle_host_event('host.permission_requested', {
      data = {
        mode = 'approve-all',
        request = {
          request = {
            kind = 'shell',
            fullCommandText = 'python scripts/task4.py',
          },
        },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
      },
    })

    vim.wait(200)

    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)
    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)
    assert_eq('Activity: 🔧 bash — python scripts/task4.py', preview[1])

    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })
    events.handle_host_event('host.permission_requested', {
      data = {
        mode = 'approve-all',
        request = {
          request = {
            kind = 'shell',
            fullCommandText = 'python scripts/task5.py',
          },
        },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
      },
    })

    vim.wait(200)

    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)
    virt_lines = extmarks[1][4].virt_lines or {}
    preview = trimmed_virt_lines(virt_lines)
    assert_eq('Activity: 🔧 bash — python scripts/task5.py', preview[1])
  end)

  it('logs reasoning delta activity when DEBUG file logging is enabled', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({
      auto_create_session = false,
      notify = false,
      file_log_level = 'DEBUG',
      chat = {
        reasoning = {
          enabled = true,
          max_lines = 3,
        },
      },
      service = {
        auto_start = true,
      },
    })
    events = require('copilot_agent.events')
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-log',
        deltaContent = 'alpha\nbeta',
      },
    })
    vim.wait(200)
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.fn.stdpath = original_stdpath
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('reasoning_delta received', 1, true) ~= nil)
    assert_true(joined:find('reasoning delta appended', 1, true) ~= nil)
    assert_true(joined:find('reasoning preview cleared (turn end)', 1, true) ~= nil)
  end)

  it('logs assistant merge and streaming decisions when DEBUG file logging is enabled', function()
    local original_stdpath = vim.fn.stdpath
    local temp_log_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end

    agent.setup({
      auto_create_session = false,
      notify = false,
      file_log_level = 'DEBUG',
      service = {
        auto_start = true,
      },
    })
    events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-log'
    agent.open_chat()

    local prompt_idx = render.append_entry('user', 'trace duplicates')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-log',
      prompt = 'trace duplicates',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-log',
        deltaContent = 'First line.',
      },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-log-2',
        content = 'First line.\nSecond line.',
      },
    })

    vim.wait(250)

    vim.fn.stdpath = original_stdpath
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('assistant.message_delta received', 1, true) ~= nil)
    assert_true(joined:find('assistant.message_delta appended', 1, true) ~= nil)
    assert_true(joined:find('assistant.message received', 1, true) ~= nil)
    assert_true(joined:find('assistant.message merge decision=', 1, true) ~= nil)
    assert_true(joined:find('assistant stream update applying', 1, true) ~= nil)
  end)

  it('does not emit deprecated assistant.message_delta stitch diagnostics', function()
    local original_stdpath = vim.fn.stdpath
    local original_notify = vim.notify
    local temp_log_dir = vim.fn.tempname()
    local notifications = {}
    vim.fn.mkdir(temp_log_dir, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'log' then
        return temp_log_dir
      end
      return original_stdpath(kind)
    end
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end

    agent.setup({
      auto_create_session = false,
      notify = false,
      file_log_level = 'INFO',
      service = {
        auto_start = true,
      },
    })
    events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-log'
    agent.open_chat()

    local prompt_idx = render.append_entry('user', 'trace delta stitch')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-log',
      prompt = 'trace delta stitch',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      id = 'delta-1',
      parentId = nil,
      timestamp = '2026-05-03T08:30:00Z',
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-log',
        deltaContent = 'Repeated line.',
      },
    })
    events.handle_session_event({
      id = 'delta-2',
      parentId = 'delta-1',
      timestamp = '2026-05-03T08:30:01Z',
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-log',
        deltaContent = 'Repeated line.',
      },
    })

    vim.wait(250)

    vim.fn.stdpath = original_stdpath
    vim.notify = original_notify
    local log_path = temp_log_dir .. '/copilot_agent.log'
    local joined = ''
    if vim.fn.filereadable(log_path) == 1 then
      joined = table.concat(vim.fn.readfile(log_path), '\n')
    end
    assert_true(joined:find('assistant.message_delta stitch diverged from direct append', 1, true) == nil)
    assert_eq(0, #notifications)
  end)

  it('preserves distinct assistant.message chunks when the same message id sends non-overlapping content', function()
    local render = require('copilot_agent.render')
    render.clear_transcript()
    agent.state.session_id = 'session-merge-preserve'
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-merge-preserve',
        content = 'First section.',
      },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-merge-preserve',
        content = 'Second section.',
      },
    })

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('assistant', entry.kind)
    assert_eq('First section.\nSecond section.', entry.content)
  end)

  it('replaces a corrupted streamed draft with the final assistant.message payload', function()
    local render = require('copilot_agent.render')
    render.clear_transcript()
    agent.state.session_id = 'session-merge-replace'
    agent.open_chat()

    local stable_prefix = string.rep('All five improvements are implemented. Here is a stable streamed prefix that should match the final payload. ', 3)
    local streamed = stable_prefix .. 'The activity lines are paded with spaces.'
    local final = stable_prefix .. 'The activity lines are padded with spaces.\n\nFinal line.'

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-merge-replace',
        content = streamed,
      },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-merge-replace',
        content = final,
      },
    })

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('assistant', entry.kind)
    assert_eq(final, entry.content)
  end)

  it('keeps activity virtual text visible in a bottom gutter below the transcript', function()
    local render = require('copilot_agent.render')
    agent.open_chat()

    local bufnr = agent.state.chat_bufnr
    local winid = agent.state.chat_winid
    vim.api.nvim_win_set_height(winid, 12)

    for idx = 1, 12 do
      render.append_entry('assistant', 'history line ' .. idx)
    end
    render.render_chat()
    render.scroll_to_bottom()
    local before = vim.fn.getwininfo(winid)[1]

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'status', '--short' },
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local info = vim.fn.getwininfo(winid)[1]
    assert_eq(vim.api.nvim_buf_line_count(bufnr) - 1, extmarks[1][2])
    assert_false(extmarks[1][4].virt_lines_above == true)
    assert_eq(before.topline + 8, info.topline)
  end)

  it('reserves overlay gutter when wrapped chat lines consume the visible bottom rows', function()
    local render = require('copilot_agent.render')
    agent.open_chat()

    local bufnr = agent.state.chat_bufnr
    local winid = agent.state.chat_winid
    vim.api.nvim_win_set_height(winid, 12)
    vim.api.nvim_win_set_width(winid, 30)

    local long_line = string.rep('wrapped chat output ', 6)
    for idx = 1, 6 do
      render.append_entry('assistant', long_line .. idx)
    end
    render.render_chat()
    render.scroll_to_bottom()
    vim.wait(120)

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local win_height = vim.api.nvim_win_get_height(winid)
    local before = vim.fn.getwininfo(winid)[1]
    local before_height = vim.api.nvim_win_text_height(winid, {
      start_row = before.topline - 1,
      end_row = line_count - 1,
    })
    assert_true(before_height.all <= win_height)
    assert_true(before_height.all > win_height - 5)

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'wrapped-overlay',
        deltaContent = 'one\ntwo\nthree',
      },
    })

    vim.wait(500)

    local after = vim.fn.getwininfo(winid)[1]
    local after_height = vim.api.nvim_win_text_height(winid, {
      start_row = after.topline - 1,
      end_row = line_count - 1,
    })
    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)
    assert_true(after.topline > before.topline)
    assert_true(after_height.all <= win_height - 5)
  end)

  it('keeps real spacer lines after transcript content while reasoning overlay is active', function()
    local render = require('copilot_agent.render')
    agent.open_chat()
    render.render_chat()

    local bufnr = agent.state.chat_bufnr
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'spacer-lines',
        deltaContent = 'one\ntwo\nthree',
      },
    })

    vim.wait(500)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq(3, agent.state.chat_tail_spacer_lines)
    assert_eq('', lines[#lines])
    assert_eq('', lines[#lines - 1])
    assert_eq('', lines[#lines - 2])

    local assistant_idx = render.append_entry('assistant', '')
    local assistant_entry = agent.state.entries[assistant_idx]
    assistant_entry.content = table.concat({
      'line a',
      'line b',
      'line c',
      'line d',
    }, '\n')
    render.stream_update(assistant_entry, assistant_idx)

    vim.wait(200)

    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq(3, agent.state.chat_tail_spacer_lines)
    assert_eq('', lines[#lines])
    assert_eq('', lines[#lines - 1])
    assert_eq('', lines[#lines - 2])
    assert_true(table.concat(lines, '\n'):find('line d', 1, true) ~= nil)
    local with_spacers_count = vim.api.nvim_buf_line_count(bufnr)

    render.clear_reasoning_preview('test')
    vim.wait(300)

    assert_eq(0, agent.state.chat_tail_spacer_lines)
    assert_eq(with_spacers_count - 3, vim.api.nvim_buf_line_count(bufnr))
  end)

  it('scrolls live output to reveal overlay virtual text even when follow is paused', function()
    local render = require('copilot_agent.render')
    agent.open_chat()

    local bufnr = agent.state.chat_bufnr
    local winid = agent.state.chat_winid
    vim.api.nvim_win_set_height(winid, 12)

    for idx = 1, 20 do
      render.append_entry('assistant', 'history line ' .. idx)
    end
    render.render_chat()
    vim.api.nvim_win_call(winid, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    agent.state.chat_auto_scroll_enabled = false

    local prompt_idx = render.append_entry('user', 'prompt')
    agent.state.session_id = 'overlay-scroll'
    agent.state.pending_checkpoint_turn = {
      session_id = 'overlay-scroll',
      prompt = 'prompt',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'status', '--short' },
      },
    })
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'overlay-scroll-message',
        deltaContent = 'one\ntwo\nthree',
      },
    })

    vim.wait(500)

    local view = vim.fn.getwininfo(winid)[1]
    assert_true(view.topline > 1)
    assert_eq(vim.api.nvim_buf_line_count(bufnr), view.botline)

    local assistant_idx = render.append_entry('assistant', '')
    local assistant_entry = agent.state.entries[assistant_idx]
    assistant_entry.content = table.concat({
      'line a',
      'line b',
      'line c',
      'line d',
      'line e',
      'line f',
    }, '\n')
    render.stream_update(assistant_entry, assistant_idx)
    vim.wait(200)

    local streamed_view = vim.fn.getwininfo(winid)[1]
    assert_true(streamed_view.topline > view.topline)
    assert_eq(vim.api.nvim_buf_line_count(bufnr), streamed_view.botline)
  end)

  it('restores the previous manual chat view after the reasoning overlay clears', function()
    local render = require('copilot_agent.render')
    agent.open_chat()

    local bufnr = agent.state.chat_bufnr
    local winid = agent.state.chat_winid
    vim.api.nvim_win_set_height(winid, 12)

    for idx = 1, 20 do
      render.append_entry('assistant', 'history line ' .. idx)
    end
    render.render_chat()
    vim.api.nvim_win_call(winid, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    agent.state.chat_auto_scroll_enabled = false

    local before = vim.fn.getwininfo(winid)[1]
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'reasoning-restore',
        deltaContent = 'one\ntwo\nthree',
      },
    })

    vim.wait(500)

    local shifted = vim.fn.getwininfo(winid)[1]
    assert_true(shifted.topline > before.topline)
    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'reasoning-restore',
        deltaContent = 'final answer',
      },
    })

    vim.wait(300)

    local restored = vim.fn.getwininfo(winid)[1]
    assert_eq(before.topline, restored.topline)
    extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
  end)

  it('deduplicates the thinking spinner and keeps it anchored before message ids arrive', function()
    local render = require('copilot_agent.render')
    local function assistant_entries()
      local entries = {}
      for _, entry in ipairs(agent.state.entries) do
        if entry.kind == 'assistant' then
          entries[#entries + 1] = entry
        end
      end
      return entries
    end

    render.stop_thinking_spinner()
    render.reset_pending_assistant_entry()
    render.clear_transcript()
    agent.state.chat_busy = false
    agent.state.pending_checkpoint_turn = nil
    agent.state.session_id = 'session-123'
    agent.open_chat()
    render.append_entry('user', 'pending prompt')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'pending prompt',
      entry_index = 1,
    }

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        deltaContent = '...',
      },
    })
    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        deltaContent = '   ',
      },
    })

    vim.wait(250)
    local assistants = assistant_entries()

    local lines = vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false)
    local spinner_rows = {}
    for row, line in ipairs(lines) do
      if line:find('Thinking…', 1, true) ~= nil then
        spinner_rows[#spinner_rows + 1] = row
      end
    end

    assert_eq(1, #spinner_rows)
    assert_eq(1, #assistants)

    local first_spinner_row = spinner_rows[1]
    vim.wait(650)
    lines = vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false)
    local current_spinner_row
    local spinner_count = 0
    for row, line in ipairs(lines) do
      if line:find('Thinking…', 1, true) ~= nil then
        spinner_count = spinner_count + 1
        current_spinner_row = row
      end
    end

    assert_eq(1, spinner_count)
    assert_eq(first_spinner_row, current_spinner_row)

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-42',
        deltaContent = 'final answer',
      },
    })

    vim.wait(150)
    assistants = assistant_entries()
    assert_eq(1, #assistants)
    assert_eq('final answer', assistants[1].content)

    agent.state.pending_checkpoint_turn = nil
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
  end)
end)

describe('statusline config counts', function()
  local agent

  before_each(function()
    package.loaded['copilot_agent'] = nil
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      service = {
        auto_start = true,
      },
    })
  end)

  it('uses responsive labels for discovered instruction, agent, skill, and MCP counts', function()
    local original_get_width = vim.api.nvim_win_get_width
    agent.state.instruction_count = 2
    agent.state.agent_count = 1
    agent.state.skill_count = 3
    agent.state.mcp_count = 4

    local small = '󱃕 I: 2 󱜙 A: 1 󱨚 S: 3  M: 4'
    local medium = '󱃕 Ins: 2 󱜙 Ag: 1 󱨚 Sk: 3  Mc: 4'
    local large = '󱃕 Instruction: 2 󱜙 Agent: 1 󱨚 Skill: 3  MCP: 4'
    local highlighted =
      '󱃕 Instruction: %#CopilotAgentStatuslineCount#2%* 󱜙 Agent: %#CopilotAgentStatuslineCount#1%* 󱨚 Skill: %#CopilotAgentStatuslineCount#3%*  MCP: %#CopilotAgentStatuslineCount#4%*'

    assert_eq(small, require('copilot_agent.statusline').statusline_config(80))
    assert_eq(medium, require('copilot_agent.statusline').statusline_config(120))
    assert_eq(large, require('copilot_agent.statusline').statusline_config(200))
    assert_eq(highlighted, require('copilot_agent.statusline').statusline_config_highlighted(200))
    vim.api.nvim_win_get_width = function(winid)
      if winid == 0 then
        return 200
      end
      return original_get_width(winid)
    end
    assert_true(agent.statusline():find(large, 1, true) ~= nil)
    vim.api.nvim_win_get_width = original_get_width
  end)
end)

describe('workspace file reload', function()
  local agent
  local events
  local original_notify
  local original_confirm
  local notifications
  local temp_file
  local temp_file_two

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = true })
    events = require('copilot_agent.events')
    original_notify = vim.notify
    original_confirm = vim.fn.confirm
    notifications = {}
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local cwd = require('copilot_agent.service').working_directory()
    temp_file = cwd .. '/tmp-copilot-agent-reload-spec.txt'
    temp_file_two = cwd .. '/tmp-copilot-agent-reload-spec-2.txt'
    vim.fn.writefile({ 'local value = 1', 'return value' }, temp_file)
    vim.fn.writefile({ 'local other = 1', 'return other' }, temp_file_two)
    agent.state.config.chat.diff_review = false
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.confirm = original_confirm
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == temp_file then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    if temp_file and temp_file ~= '' then
      vim.fn.delete(temp_file)
    end
    if temp_file_two and temp_file_two ~= '' then
      vim.fn.delete(temp_file_two)
    end
    pcall(vim.cmd, 'tabonly | only')
  end)

  it('reloads changed buffers immediately and reports a diff summary', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr = vim.api.nvim_get_current_buf()
    vim.fn.writefile({ 'local value = 2', 'print(value)', 'return value' }, temp_file)

    events.handle_session_event({
      type = 'session.workspace_file_changed',
      data = {
        operation = 'update',
        path = vim.fn.fnamemodify(temp_file, ':t'),
      },
    })

    assert_eq('📝sync', agent.statusline_busy())
    vim.wait(100)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq('local value = 2', lines[1])
    assert_eq('print(value)', lines[2])
    assert_eq('✅ready', agent.statusline_busy())
    assert_true(#notifications > 0)
    assert_true(notifications[#notifications].message:find('Agent reloaded:', 1, true) ~= nil)
    assert_true(notifications[#notifications].message:find('+1', 1, true) ~= nil)
  end)

  it('prompts before reloading a modified buffer updated by the plugin', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr = vim.api.nvim_get_current_buf()
    local confirm_message
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local value = 99', 'return value' })
    vim.bo[bufnr].modified = true
    vim.fn.writefile({ 'local value = 3', 'return value' }, temp_file)
    vim.fn.confirm = function(message, _, _)
      confirm_message = message
      return 2
    end

    events.handle_session_event({
      type = 'session.workspace_file_changed',
      data = {
        operation = 'update',
        path = vim.fn.fnamemodify(temp_file, ':t'),
      },
    })

    vim.wait(100)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq('local value = 99', lines[1])
    assert_eq('The open buffer has been updated externally. Do you want to reload it? (yes/no)', confirm_message)
    vim.bo[bufnr].modified = false
  end)

  it('checks all loaded file buffers on focus changes and reloads hidden ones', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr_one = vim.api.nvim_get_current_buf()
    vim.cmd('vsplit ' .. vim.fn.fnameescape(temp_file_two))
    local bufnr_two = vim.api.nvim_get_current_buf()
    vim.cmd('buffer ' .. bufnr_one)

    vim.fn.writefile({ 'local other = 2', 'print(other)', 'return other' }, temp_file_two)
    vim.api.nvim_exec_autocmds('FocusGained', {})
    vim.wait(100)

    local lines = vim.api.nvim_buf_get_lines(bufnr_two, 0, -1, false)
    assert_eq('local other = 2', lines[1])
    assert_eq('print(other)', lines[2])
  end)

  it('reloads clean visible buffers during sweeps with edit instead of checktime', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr = vim.api.nvim_get_current_buf()
    local original_cmd = vim.cmd
    local checktime_called = false
    local edit_called = false

    local ok, err = pcall(function()
      vim.cmd = function(command)
        if type(command) == 'string' and command:match('^silent! checktime%s+') then
          checktime_called = true
          return
        end
        if type(command) == 'string' and command:match('^silent keepalt keepjumps edit$') then
          edit_called = true
        end
        return original_cmd(command)
      end

      vim.fn.writefile({ 'local value = 7', 'print(value)', 'return value' }, temp_file)
      events.check_open_buffers_for_external_changes()
      vim.wait(100)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert_eq('local value = 7', lines[1])
      assert_eq('print(value)', lines[2])
      assert_false(checktime_called)
      assert_true(edit_called)
    end)

    vim.cmd = original_cmd
    if not ok then
      error(err)
    end
  end)

  it('does not force overwrite a modified visible buffer during sweeps', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr = vim.api.nvim_get_current_buf()
    local original_cmd = vim.cmd
    local confirm_message
    local edit_called = false
    local edit_bang_called = false

    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local value = 99', 'return value' })
      vim.bo[bufnr].modified = true
      vim.fn.writefile({ 'local value = 8', 'print(value)', 'return value' }, temp_file)
      vim.fn.confirm = function(message, _, _)
        confirm_message = message
        return 1
      end
      vim.cmd = function(command)
        if type(command) == 'string' and command:match('^silent keepalt keepjumps edit!$') then
          edit_bang_called = true
        end
        if type(command) == 'string' and command:match('^silent keepalt keepjumps edit$') then
          edit_called = true
          error('E37: No write since last change')
        end
        return original_cmd(command)
      end

      events.check_open_buffers_for_external_changes()
      vim.wait(100)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert_eq('local value = 99', lines[1])
      assert_eq('The open buffer has been updated externally. Do you want to reload it? (yes/no)', confirm_message)
      assert_true(edit_called)
      assert_false(edit_bang_called)
      assert_true(notifications[#notifications].message:find('External reload needs attention:', 1, true) ~= nil)
      assert_true(notifications[#notifications].message:find('stack traceback:', 1, true) == nil)
      assert_eq(vim.log.levels.INFO, notifications[#notifications].level)
    end)

    vim.cmd = original_cmd
    vim.bo[bufnr].modified = false
    if not ok then
      error(err)
    end
  end)

  it('checks open file buffers when the turn completes', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr = vim.api.nvim_get_current_buf()

    vim.fn.writefile({ 'local value = 4', 'print(value)', 'return value' }, temp_file)
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    vim.wait(150)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq('local value = 4', lines[1])
    assert_eq('print(value)', lines[2])
  end)

  it('checks open file buffers when a background task completes', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr = vim.api.nvim_get_current_buf()

    vim.fn.writefile({ 'local value = 5', 'print(value)', 'return value' }, temp_file)
    events.handle_session_event({
      type = 'system.notification',
      data = {
        kind = {
          type = 'agent_completed',
          agentId = 'bg-1',
        },
      },
    })
    vim.wait(150)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq('local value = 5', lines[1])
    assert_eq('print(value)', lines[2])
  end)

  it('checks all open clean file buffers when the turn completes', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file))
    local bufnr_one = vim.api.nvim_get_current_buf()
    vim.cmd('vsplit ' .. vim.fn.fnameescape(temp_file_two))
    local bufnr_two = vim.api.nvim_get_current_buf()
    vim.cmd('buffer ' .. bufnr_one)

    vim.fn.writefile({ 'local value = 6', 'print(value)', 'return value' }, temp_file)
    vim.fn.writefile({ 'local other = 6', 'print(other)', 'return other' }, temp_file_two)
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    vim.wait(150)

    local lines_one = vim.api.nvim_buf_get_lines(bufnr_one, 0, -1, false)
    local lines_two = vim.api.nvim_buf_get_lines(bufnr_two, 0, -1, false)
    assert_eq('local value = 6', lines_one[1])
    assert_eq('print(value)', lines_one[2])
    assert_eq('local other = 6', lines_two[1])
    assert_eq('print(other)', lines_two[2])
  end)

  it('prompts before reloading externally changed buffers with unsaved edits during focus checks', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(temp_file_two))
    local bufnr = vim.api.nvim_get_current_buf()
    local confirm_message
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local other = 99', 'return other' })
    vim.bo[bufnr].modified = true

    vim.fn.writefile({ 'local other = 3', 'return other' }, temp_file_two)
    vim.fn.confirm = function(message, _, _)
      confirm_message = message
      return 2
    end
    vim.api.nvim_exec_autocmds('FocusGained', {})
    vim.wait(100)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert_eq('local other = 99', lines[1])
    assert_eq('The open buffer has been updated externally. Do you want to reload it? (yes/no)', confirm_message)
    vim.bo[bufnr].modified = false
  end)
end)

describe('permission request prompts', function()
  local agent
  local events
  local original_ui_select
  local original_ui_input

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    agent.state.session_id = 'session-123'
    events = require('copilot_agent.events')
    original_ui_select = vim.ui.select
    original_ui_input = vim.ui.input
  end)

  after_each(function()
    vim.ui.select = original_ui_select
    vim.ui.input = original_ui_input
  end)

  it('uses a single-line read prompt without duplicating the file intention', function()
    local captured
    local path = '/Users/rayxu/github/ray-x/go.nvim/lua/go/commands.lua'

    vim.ui.select = function(items, opts, _)
      captured = { items = items, prompt = opts.prompt }
    end

    events.handle_host_event('host.permission_requested', {
      data = {
        sessionId = 'session-123',
        mode = 'interactive',
        request = {
          id = 'perm-read-1',
          request = {
            kind = 'read',
            path = path,
            intention = 'Read file:\n' .. path,
          },
        },
      },
    })

    vim.wait(100, function()
      return captured ~= nil
    end)

    assert_eq('Allow: Read ' .. path, captured.prompt)
    assert_true(captured.prompt:find('\n', 1, true) == nil)
    assert_eq('Allow', captured.items[1])
    assert_eq('Deny', captured.items[2])
  end)

  it('queues overlapping mixed permission requests instead of opening stacked pickers', function()
    local calls = {}

    vim.ui.select = function(items, opts, on_choice)
      calls[#calls + 1] = {
        items = items,
        prompt = opts.prompt,
        on_choice = on_choice,
      }
    end

    events.handle_host_event('host.permission_requested', {
      data = {
        sessionId = 'session-123',
        mode = 'interactive',
        request = {
          id = 'perm-read-1',
          request = {
            kind = 'read',
            path = '/tmp/one.lua',
            intention = 'Read file:\n/tmp/one.lua',
          },
        },
      },
    })

    events.handle_host_event('host.permission_requested', {
      data = {
        sessionId = 'session-123',
        mode = 'interactive',
        request = {
          id = 'perm-tool-1',
          request = {
            kind = 'custom-tool',
            toolTitle = 'Search files',
            serverName = 'workspace',
          },
        },
      },
    })

    vim.wait(100)

    assert_eq(1, #calls)
    assert_eq('Allow: Read /tmp/one.lua', calls[1].prompt)

    calls[1].on_choice(nil)

    vim.wait(10)
    assert_eq(1, #calls)

    vim.wait(100, function()
      return #calls == 2
    end)
    assert_eq('Allow: Search files (workspace)', calls[2].prompt)
  end)

  it('serializes user-input prompts behind an active permission prompt', function()
    local permission_calls = {}
    local input_calls = {}

    vim.ui.select = function(items, opts, on_choice)
      permission_calls[#permission_calls + 1] = {
        items = items,
        prompt = opts.prompt,
        on_choice = on_choice,
      }
    end

    vim.ui.input = function(opts, on_input)
      input_calls[#input_calls + 1] = {
        prompt = opts.prompt,
        on_input = on_input,
      }
    end

    events.handle_host_event('host.permission_requested', {
      data = {
        sessionId = 'session-123',
        mode = 'interactive',
        request = {
          id = 'perm-read-1',
          request = {
            kind = 'read',
            path = '/tmp/one.lua',
            intention = 'Read file:\n/tmp/one.lua',
          },
        },
      },
    })

    events.handle_host_event('host.user_input_requested', {
      data = {
        sessionId = 'session-123',
        request = {
          id = 'input-1',
          question = 'Need a value?',
          allowFreeform = true,
        },
      },
    })

    vim.wait(100)

    assert_eq(1, #permission_calls)
    assert_eq(0, #input_calls)

    permission_calls[1].on_choice(nil)

    vim.wait(100, function()
      return #input_calls == 1
    end)

    assert_eq('Need a value? ', input_calls[1].prompt)
  end)

  it('renders external diff output without a live terminal job when showing a write diff', function()
    local permission_calls = {}
    local original_executable = vim.fn.executable
    local original_system = vim.fn.system
    local original_jobstart = vim.fn.jobstart
    local original_columns = vim.o.columns
    local system_cmd
    local system_input
    local job_started = false

    vim.ui.select = function(items, opts, on_choice)
      permission_calls[#permission_calls + 1] = {
        items = items,
        prompt = opts.prompt,
        on_choice = on_choice,
      }
    end
    vim.o.columns = 160

    vim.fn.executable = function(cmd)
      if cmd == 'delta' then
        return 1
      end
      return original_executable(cmd)
    end
    vim.fn.system = function(cmd, input)
      system_cmd = cmd
      system_input = input
      vim.api.nvim_set_vvar('shell_error', 0)
      return '\27[31mrendered diff\27[0m'
    end
    vim.fn.jobstart = function(...)
      job_started = true
      return original_jobstart(...)
    end

    events.handle_host_event('host.permission_requested', {
      data = {
        sessionId = 'session-123',
        mode = 'interactive',
        request = {
          id = 'perm-write-1',
          request = {
            kind = 'write',
            path = '/tmp/one.lua',
            intention = 'Write file:\n/tmp/one.lua',
            diff = table.concat({
              '--- a/tmp/one.lua',
              '+++ b/tmp/one.lua',
              '@@ -1 +1 @@',
              '-old',
              '+new',
            }, '\n'),
          },
        },
      },
    })

    vim.wait(100, function()
      return #permission_calls == 1
    end)

    assert_true(vim.tbl_contains(permission_calls[1].items, 'Show diff'))
    permission_calls[1].on_choice('Show diff')

    vim.fn.executable = original_executable
    vim.fn.system = original_system
    vim.fn.jobstart = original_jobstart
    vim.o.columns = original_columns

    assert_eq('delta', system_cmd[1])
    assert_true(vim.tbl_contains(system_cmd, '--paging=never'))
    assert_true(vim.tbl_contains(system_cmd, '--side-by-side'))
    assert_true(system_input:find('--- a/tmp/one.lua', 1, true) ~= nil)
    assert_false(job_started)

    pcall(vim.cmd, 'tabonly | only')
  end)
  it('shows the close hint in the diff title and requires double escape or ctrl-c to close', function()
    local permission_calls = {}

    vim.ui.select = function(items, opts, on_choice)
      permission_calls[#permission_calls + 1] = {
        items = items,
        prompt = opts.prompt,
        on_choice = on_choice,
      }
    end

    agent.state.config.chat.diff_cmd = false
    events.handle_host_event('host.permission_requested', {
      data = {
        sessionId = 'session-123',
        mode = 'interactive',
        request = {
          id = 'perm-write-2',
          request = {
            kind = 'write',
            path = '/tmp/two.lua',
            intention = 'Write file:\n/tmp/two.lua',
            diff = table.concat({
              '--- a/tmp/two.lua',
              '+++ b/tmp/two.lua',
              '@@ -1 +1 @@',
              '-old',
              '+new',
            }, '\n'),
          },
        },
      },
    })

    vim.wait(100, function()
      return #permission_calls == 1
    end)

    permission_calls[1].on_choice('Show diff')

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local config = vim.api.nvim_win_get_config(win)
    local normal_maps = vim.api.nvim_buf_get_keymap(buf, 'n')

    local function has_lhs(lhs)
      for _, map in ipairs(normal_maps) do
        if map.lhs == lhs then
          return true
        end
      end
      return false
    end

    assert_eq(' Proposed changes (<C-c> to exit) ', config.title[1][1])
    assert_false(has_lhs('<Esc>'))
    assert_true(has_lhs('<Esc><Esc>'))
    assert_true(has_lhs('<C-C>'))

    pcall(vim.cmd, 'tabonly | only')
  end)
end)

describe('event stream recovery', function()
  local agent
  local events
  local service
  local session
  local original_ensure_service_live
  local original_resume_session

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.session'] = nil
    package.loaded['copilot_agent.service'] = nil
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      service = {
        auto_start = true,
      },
    })
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.event_stream_recovery_session_id = nil
    events = require('copilot_agent.events')
    service = require('copilot_agent.service')
    session = require('copilot_agent.session')
    original_ensure_service_live = service.ensure_service_live
    original_resume_session = session.resume_session
  end)

  after_each(function()
    service.ensure_service_live = original_ensure_service_live
    session.resume_session = original_resume_session
  end)

  it('reconnects the active session after a recoverable stream disconnect', function()
    local ensured = 0
    local resumed_session_id

    service.ensure_service_live = function(callback)
      ensured = ensured + 1
      callback(nil)
    end
    session.resume_session = function(session_id, callback)
      resumed_session_id = session_id
      if callback then
        callback(session_id, nil)
      end
    end

    events._handle_event_stream_exit('session-123', 18, 'curl: (18) transfer closed with outstanding read data remaining')

    assert_eq(1, ensured)
    assert_eq('session-123', resumed_session_id)
    assert_eq('system', agent.state.entries[#agent.state.entries].kind)
    assert_eq('Event stream disconnected. Reconnecting...', agent.state.entries[#agent.state.entries].content)
    assert_eq(nil, agent.state.event_stream_recovery_session_id)
  end)
end)

describe('agent command', function()
  local agent
  local slash
  local original_ask

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    slash = require('copilot_agent.slash')
    original_ask = agent.ask
  end)

  after_each(function()
    agent.ask = original_ask
  end)

  it('switches the active conversation agent immediately', function()
    local captured_prompt

    agent.state.session_id = 'session-123'
    agent.ask = function(prompt)
      captured_prompt = prompt
    end

    assert_true(slash.execute('/agent Code Review Engineer'))
    assert_eq('Code Review Engineer', agent.state.config.session.agent)
    assert_eq('/agent Code Review Engineer', captured_prompt)
  end)
end)

describe('ask command', function()
  local agent
  local slash
  local http
  local original_request
  local original_open_win

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.http'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    slash = require('copilot_agent.slash')
    http = require('copilot_agent.http')
    original_request = http.request
    original_open_win = vim.api.nvim_open_win
  end)

  after_each(function()
    http.request = original_request
    vim.api.nvim_open_win = original_open_win
  end)

  it('extracts side answers from Go-style message history payloads', function()
    local answer, done, err = slash._extract_side_session_answer({
      { Type = 'assistant.turn_start' },
      { Type = 'assistant.message', Data = { Content = 'Five intro options' } },
      { Type = 'assistant.turn_end' },
    })

    assert_eq('Five intro options', answer)
    assert_true(done)
    assert_eq(nil, err)
  end)

  it('keeps polling when turn completion arrives before the final side answer', function()
    local answer, done, err = slash._extract_side_session_answer({
      { Type = 'assistant.turn_start' },
      { Type = 'assistant.turn_end' },
    })

    assert_eq(nil, answer)
    assert_false(done)
    assert_eq(nil, err)
  end)

  it('shows the side answer for /ask from message history', function()
    local result_buf

    vim.api.nvim_open_win = function(buf, enter, config)
      result_buf = buf
      return original_open_win(buf, enter, config)
    end

    http.request = function(method, path, body, callback)
      if method == 'POST' and path == '/sessions' then
        callback({ sessionId = 'side-1' }, nil)
      elseif method == 'POST' and path == '/sessions/side-1/mode' then
        callback({}, nil)
      elseif method == 'POST' and path == '/sessions/side-1/messages' then
        callback({}, nil)
      elseif method == 'GET' and path == '/sessions/side-1/messages' then
        callback({
          events = {
            { Type = 'assistant.turn_start' },
            { Type = 'assistant.message', Data = { Content = '1. Intro one\n2. Intro two' } },
            { Type = 'assistant.turn_end' },
          },
        }, nil)
      elseif method == 'DELETE' and path == '/sessions/side-1?delete=true' then
        callback({}, nil)
      else
        error('unexpected request: ' .. method .. ' ' .. path)
      end
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')

    assert_true(slash.execute('/ask based on README generate 2 intros'))
    assert_true(result_buf ~= nil)

    local lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
    assert_true(vim.tbl_contains(lines, '# /ask'))
    assert_true(vim.tbl_contains(lines, '## Answer'))
    assert_true(vim.tbl_contains(lines, '1. Intro one'))
    assert_true(vim.tbl_contains(lines, '2. Intro two'))
  end)

  it('renders multiline /ask questions without crashing the result window', function()
    local result_buf

    vim.api.nvim_open_win = function(buf, enter, config)
      result_buf = buf
      return original_open_win(buf, enter, config)
    end

    http.request = function(method, path, body, callback)
      if method == 'POST' and path == '/sessions' then
        callback({ sessionId = 'side-1' }, nil)
      elseif method == 'POST' and path == '/sessions/side-1/mode' then
        callback({}, nil)
      elseif method == 'POST' and path == '/sessions/side-1/messages' then
        callback({}, nil)
      elseif method == 'GET' and path == '/sessions/side-1/messages' then
        callback({
          events = {
            { Type = 'assistant.turn_start' },
            { Type = 'assistant.message', Data = { Content = 'answer line' } },
            { Type = 'assistant.turn_end' },
          },
        }, nil)
      elseif method == 'DELETE' and path == '/sessions/side-1?delete=true' then
        callback({}, nil)
      else
        error('unexpected request: ' .. method .. ' ' .. path)
      end
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')

    assert_true(slash.execute('/ask first line\nsecond line'))
    assert_true(result_buf ~= nil)

    local lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
    assert_true(vim.tbl_contains(lines, 'first line'))
    assert_true(vim.tbl_contains(lines, 'second line'))
    assert_true(vim.tbl_contains(lines, 'answer line'))
  end)

  it('waits for the final answer when history briefly ends before the answer is persisted', function()
    local result_buf
    local message_reads = 0

    vim.api.nvim_open_win = function(buf, enter, config)
      result_buf = buf
      return original_open_win(buf, enter, config)
    end

    http.request = function(method, path, body, callback)
      if method == 'POST' and path == '/sessions' then
        callback({ sessionId = 'side-1' }, nil)
      elseif method == 'POST' and path == '/sessions/side-1/mode' then
        callback({}, nil)
      elseif method == 'POST' and path == '/sessions/side-1/messages' then
        callback({}, nil)
      elseif method == 'GET' and path == '/sessions/side-1/messages' then
        message_reads = message_reads + 1
        if message_reads == 1 then
          callback({
            events = {
              { Type = 'assistant.turn_start' },
              { Type = 'assistant.turn_end' },
            },
          }, nil)
        else
          callback({
            events = {
              { Type = 'assistant.turn_start' },
              { Type = 'assistant.message', Data = { Content = 'Recovered final answer' } },
              { Type = 'assistant.turn_end' },
            },
          }, nil)
        end
      elseif method == 'DELETE' and path == '/sessions/side-1?delete=true' then
        callback({}, nil)
      else
        error('unexpected request: ' .. method .. ' ' .. path)
      end
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')

    assert_true(slash.execute('/ask based on README generate 2 intros'))
    assert_true(vim.wait(1200, function()
      return result_buf ~= nil
    end, 50))

    local lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
    assert_true(vim.tbl_contains(lines, 'Recovered final answer'))
    assert_eq(2, message_reads)
  end)
end)

describe('rewind command', function()
  local agent
  local slash
  local checkpoints
  local original_rewind

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    agent.state.session_id = 'session-123'
    slash = require('copilot_agent.slash')
    checkpoints = require('copilot_agent.checkpoints')
    original_rewind = checkpoints.rewind
  end)

  after_each(function()
    checkpoints.rewind = original_rewind
  end)

  it('rewinds directly to a checkpoint label argument', function()
    local captured

    checkpoints.rewind = function(session_id, checkpoint_id, callback)
      captured = {
        session_id = session_id,
        checkpoint_id = checkpoint_id,
      }
      callback(nil)
    end

    assert_true(slash.execute('/rewind v042'))
    assert_eq('session-123', captured.session_id)
    assert_eq('v042', captured.checkpoint_id)
  end)

  it('accepts uppercase checkpoint labels for direct rewind', function()
    local captured

    checkpoints.rewind = function(_, checkpoint_id, callback)
      captured = checkpoint_id
      callback(nil)
    end

    assert_true(slash.execute('/rewind V059'))
    assert_eq('V059', captured)
  end)
end)

describe('session resume guards', function()
  local agent
  local http
  local events
  local session
  local original_request
  local original_start_event_stream
  local original_ui_select
  local original_ensure_chat_window

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.session'] = nil
    package.loaded['copilot_agent.http'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    http = require('copilot_agent.http')
    events = require('copilot_agent.events')
    original_request = http.request
    original_start_event_stream = events.start_event_stream
    original_ui_select = vim.ui.select
    original_ensure_chat_window = agent._ensure_chat_window
  end)

  after_each(function()
    http.request = original_request
    events.start_event_stream = original_start_event_stream
    vim.ui.select = original_ui_select
    agent._ensure_chat_window = original_ensure_chat_window
  end)

  it('ignores stale recovery resumes after the active session changes', function()
    local started_session_id
    local callback_error

    agent.state.session_id = 'session-a'
    http.request = function(_, _, _, callback)
      agent.state.session_id = 'session-b'
      callback({
        sessionId = 'session-a',
        workingDirectory = '/tmp/project-a',
        summary = 'Recovered session',
      }, nil)
    end
    events.start_event_stream = function(session_id)
      started_session_id = session_id
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.resume_session('session-a', function(_, err)
      callback_error = err
    end, {
      guard_current_session_id = 'session-a',
    })

    assert_eq('session-b', agent.state.session_id)
    assert_eq(nil, started_session_id)
    assert_eq('resume cancelled: active session changed', callback_error)
  end)

  it('prompts before auto-resuming a live session and cancels when takeover is declined', function()
    local callback_error
    local prompt
    local items
    local resumed = false

    http.request = function(method, path, _, callback)
      if method == 'GET' then
        assert_eq('/sessions', path)
        callback({
          persisted = {},
          live = {
            {
              sessionId = 'live-session',
              summary = 'Live session summary',
              workingDirectory = require('copilot_agent.service').working_directory(),
              live = true,
            },
          },
        }, nil)
        return
      end

      resumed = true
      callback({}, nil)
    end

    vim.ui.select = function(choice_items, opts, on_choice)
      items = choice_items
      prompt = opts.prompt
      on_choice(choice_items[1], 1)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.pick_or_create_session(function(_, err)
      callback_error = err
    end)

    assert_eq('Session Live session summary [live-session] is already attached in another Neovim instance. Kick the older instance out?', prompt)
    assert_eq('Keep older instance attached', items[1])
    assert_eq('Kick older instance out', items[2])
    assert_eq('New Session', items[3])
    assert_false(resumed)
    assert_eq('Kept older instance attached; did not connect to session live-session', callback_error)
  end)

  it('creates a new session when takeover prompt chooses New Session during auto-resume', function()
    local requests = {}
    local callback_session_id
    local callback_error
    local prompt
    local items
    local cwd = require('copilot_agent.service').working_directory()

    events.start_event_stream = function() end

    http.request = function(method, path, body, callback)
      requests[#requests + 1] = {
        method = method,
        path = path,
        body = body,
      }
      if method == 'GET' then
        assert_eq('/sessions', path)
        callback({
          persisted = {},
          live = {
            {
              sessionId = 'live-session',
              summary = 'Live session summary',
              workingDirectory = cwd,
              live = true,
            },
          },
        }, nil)
        return
      end

      assert_eq('POST', method)
      assert_eq('/sessions', path)
      assert_eq(nil, body.sessionId)
      assert_eq(nil, body.resume)
      callback({
        sessionId = 'fresh-session',
        workingDirectory = cwd,
      }, nil)
    end

    vim.ui.select = function(choice_items, opts, on_choice)
      items = choice_items
      prompt = opts.prompt
      on_choice('New Session', 3)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.pick_or_create_session(function(session_id, err)
      callback_session_id = session_id
      callback_error = err
    end)

    assert_eq('Session Live session summary [live-session] is already attached in another Neovim instance. Kick the older instance out?', prompt)
    assert_eq('Keep older instance attached', items[1])
    assert_eq('Kick older instance out', items[2])
    assert_eq('New Session', items[3])
    assert_eq('GET', requests[1].method)
    assert_eq('POST', requests[2].method)
    assert_eq(nil, callback_error)
    assert_eq('fresh-session', callback_session_id)
  end)

  it('does not prompt when only persisted metadata marks the target session live', function()
    local callback_error
    local prompted = false
    local resumed_session_id
    local cwd = require('copilot_agent.service').working_directory()

    http.request = function(method, path, body, callback)
      if method == 'GET' then
        assert_eq('/sessions', path)
        callback({
          persisted = {
            {
              sessionId = 'stale-live-session',
              summary = 'Repo session',
              workingDirectory = cwd,
              live = true,
            },
          },
          live = {
            {
              sessionId = 'other-live-session',
              summary = 'Other attached session',
              workingDirectory = '/tmp/other-project',
              live = true,
            },
          },
        }, nil)
        return
      end

      resumed_session_id = body.sessionId
      callback({
        sessionId = 'stale-live-session',
        summary = 'Repo session',
        workingDirectory = cwd,
      }, nil)
    end

    vim.ui.select = function()
      prompted = true
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.pick_or_create_session(function(_, err)
      callback_error = err
    end)

    assert_false(prompted)
    assert_eq('stale-live-session', resumed_session_id)
    assert_eq(nil, callback_error)
  end)

  it('keeps the current session attached when switching to a live session is declined', function()
    local delete_called = false
    local resume_called = false
    local prompt

    agent.state.session_id = 'current-session'
    agent.state.session_name = 'Current session'

    http.request = function(method, path, _, callback)
      if method == 'GET' then
        assert_eq('/sessions', path)
        callback({
          persisted = {
            {
              sessionId = 'current-session',
              summary = 'Current session',
              workingDirectory = '/tmp/current',
            },
            {
              sessionId = 'live-target',
              summary = 'Target session',
              workingDirectory = '/tmp/target',
            },
          },
          live = {
            {
              sessionId = 'live-target',
              summary = 'Target session',
              workingDirectory = '/tmp/target',
              live = true,
            },
          },
        }, nil)
        return
      end
      if method == 'DELETE' then
        delete_called = true
      elseif method == 'POST' then
        resume_called = true
      end
      callback({}, nil)
    end

    vim.ui.select = function(_, opts, on_choice)
      prompt = opts.prompt
      on_choice('Keep older instance attached', 1)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    agent._ensure_chat_window = function() end
    session.switch_to_session_id('live-target')

    assert_eq('Session Target session [live-target] is already attached in another Neovim instance. Kick the older instance out?', prompt)
    assert_false(delete_called)
    assert_false(resume_called)
    assert_eq('current-session', agent.state.session_id)
  end)

  it('creates a new session when switching to a live session and choosing New Session', function()
    local requests = {}
    local prompt
    local items

    agent.state.session_id = 'current-session'
    agent.state.session_name = 'Current session'
    events.start_event_stream = function() end

    http.request = function(method, path, body, callback)
      requests[#requests + 1] = {
        method = method,
        path = path,
        body = body,
      }

      if method == 'GET' then
        callback({
          persisted = {
            {
              sessionId = 'current-session',
              summary = 'Current session',
              workingDirectory = '/tmp/current',
            },
            {
              sessionId = 'live-target',
              summary = 'Target session',
              workingDirectory = '/tmp/target',
            },
          },
          live = {
            {
              sessionId = 'live-target',
              summary = 'Target session',
              workingDirectory = '/tmp/target',
              live = true,
            },
          },
        }, nil)
        return
      end

      if method == 'DELETE' then
        callback({}, nil)
        return
      end

      assert_eq('POST', method)
      assert_eq('/sessions', path)
      assert_eq(nil, body.sessionId)
      assert_eq(nil, body.resume)
      callback({
        sessionId = 'fresh-session',
        summary = 'Fresh session',
        workingDirectory = '/tmp/current',
      }, nil)
    end

    vim.ui.select = function(choice_items, opts, on_choice)
      prompt = opts.prompt
      items = choice_items
      on_choice('New Session', 3)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    agent._ensure_chat_window = function() end
    session.switch_to_session_id('live-target')

    assert_eq('Session Target session [live-target] is already attached in another Neovim instance. Kick the older instance out?', prompt)
    assert_eq('Keep older instance attached', items[1])
    assert_eq('Kick older instance out', items[2])
    assert_eq('New Session', items[3])
    assert_eq('GET', requests[1].method)
    assert_eq('DELETE', requests[2].method)
    assert_eq('/sessions/current-session', requests[2].path)
    assert_eq('POST', requests[3].method)
    assert_eq('/sessions', requests[3].path)
    assert_eq('fresh-session', agent.state.session_id)
  end)

  it('switches after confirming takeover of a live session', function()
    local requests = {}

    agent.state.session_id = 'current-session'
    agent.state.session_name = 'Current session'
    events.start_event_stream = function() end

    http.request = function(method, path, body, callback)
      requests[#requests + 1] = {
        method = method,
        path = path,
        body = body,
      }

      if method == 'GET' then
        callback({
          persisted = {
            {
              sessionId = 'current-session',
              summary = 'Current session',
              workingDirectory = '/tmp/current',
            },
            {
              sessionId = 'live-target',
              summary = 'Target session',
              workingDirectory = '/tmp/target',
              live = true,
            },
          },
        }, nil)
        return
      end

      if method == 'DELETE' then
        callback({}, nil)
        return
      end

      assert_eq('POST', method)
      assert_eq('/sessions', path)
      assert_eq('live-target', body.sessionId)
      callback({
        sessionId = 'live-target',
        summary = 'Target session',
        workingDirectory = '/tmp/target',
      }, nil)
    end

    vim.ui.select = function(_, _, on_choice)
      on_choice('Kick older instance out', 2)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    agent._ensure_chat_window = function() end
    session.switch_to_session_id('live-target')

    assert_eq('GET', requests[1].method)
    assert_eq('DELETE', requests[2].method)
    assert_eq('/sessions/current-session', requests[2].path)
    assert_eq('POST', requests[3].method)
    assert_eq('/sessions', requests[3].path)
    assert_eq('live-target', agent.state.session_id)
  end)

  it('does not prompt on direct switch when only persisted metadata marks the target session live', function()
    local requests = {}
    local prompted = false

    agent.state.session_id = 'current-session'
    agent.state.session_name = 'Current session'
    events.start_event_stream = function() end

    http.request = function(method, path, body, callback)
      requests[#requests + 1] = {
        method = method,
        path = path,
        body = body,
      }

      if method == 'GET' then
        callback({
          persisted = {
            {
              sessionId = 'current-session',
              summary = 'Current session',
              workingDirectory = '/tmp/current',
            },
            {
              sessionId = 'stale-live-target',
              summary = 'Target session',
              workingDirectory = '/tmp/target',
              live = true,
            },
          },
          live = {
            {
              sessionId = 'other-live-session',
              summary = 'Other attached session',
              workingDirectory = '/tmp/elsewhere',
              live = true,
            },
          },
        }, nil)
        return
      end

      if method == 'DELETE' then
        callback({}, nil)
        return
      end

      callback({
        sessionId = 'stale-live-target',
        summary = 'Target session',
        workingDirectory = '/tmp/target',
      }, nil)
    end

    vim.ui.select = function()
      prompted = true
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    agent._ensure_chat_window = function() end
    session.switch_to_session_id('stale-live-target')

    assert_false(prompted)
    assert_eq('GET', requests[1].method)
    assert_eq('DELETE', requests[2].method)
    assert_eq('/sessions/current-session', requests[2].path)
    assert_eq('POST', requests[3].method)
    assert_eq('stale-live-target', requests[3].body.sessionId)
    assert_eq('stale-live-target', agent.state.session_id)
  end)
end)

describe('session picker labels', function()
  local agent
  local http
  local original_request
  local original_ui_select

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.session'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    agent.state.session_id = nil
    agent.state.session_name = nil
    http = require('copilot_agent.http')
    original_request = http.request
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    http.request = original_request
    vim.ui.select = original_ui_select
  end)

  it('uses truncated summaries and readable timestamp ids in the switch-session picker', function()
    local captured
    local expected_id = expected_local_session_id('nvim', 1717245296)

    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions', path)
      callback({
        persisted = {
          {
            sessionId = 'nvim-1717245296789000000',
            summary = 'abcdefghijklmnopqrstuvwxyz0123456789',
          },
          {
            sessionId = 'custom-id',
          },
        },
      }, nil)
    end

    vim.ui.select = function(items, opts, _)
      captured = {
        items = items,
        prompt = opts.prompt,
      }
    end

    package.loaded['copilot_agent.session'] = nil
    local session = require('copilot_agent.session')
    session.switch_session()

    assert_eq('Switch session', captured.prompt)
    assert_eq('abcdefghijklmnopqrstuvwxyz012345 [' .. expected_id .. ']', captured.items[1])
    assert_eq('custom-id', captured.items[2])
    assert_eq('+ New session', captured.items[3])
  end)

  it('includes live sessions in the startup session picker matching', function()
    local captured
    local expected_id = expected_local_session_id('nvim', 1717245296)
    local expected_id_2 = expected_local_session_id('nvim', 1717245297)
    local cwd = require('copilot_agent.service').working_directory()
    local expected_prompt = 'Select session for project: ' .. vim.fn.fnamemodify(cwd, ':t') .. ' (' .. vim.fn.fnamemodify(cwd, ':~') .. ')'

    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions', path)
      callback({
        persisted = {},
        live = {
          {
            sessionId = 'nvim-1717245296789000000',
            summary = 'abcdefghijklmnopqrstuvwxyz0123456789',
            workingDirectory = require('copilot_agent.service').working_directory(),
            live = true,
          },
          {
            sessionId = 'nvim-1717245297789000000',
            summary = 'second live session summary',
            workingDirectory = require('copilot_agent.service').working_directory(),
            live = true,
          },
        },
      }, nil)
    end

    vim.ui.select = function(items, opts, _)
      captured = {
        items = items,
        prompt = opts.prompt,
      }
    end

    package.loaded['copilot_agent.session'] = nil
    local session = require('copilot_agent.session')
    session.pick_or_create_session(function() end)

    assert_eq(expected_prompt, captured.prompt)
    assert_eq('abcdefghijklmnopqrstuvwxyz012345 [' .. expected_id .. ']', captured.items[1])
    assert_eq('second live session summary [' .. expected_id_2 .. ']', captured.items[2])
    assert_eq('Create new session', captured.items[3])
  end)
end)

describe('new session creation', function()
  local agent
  local session
  local http
  local events
  local original_request
  local original_start_event_stream
  local original_ui_select
  local original_ensure_chat_window

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.session'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    agent.state.config.auto_create_session = true
    http = require('copilot_agent.http')
    events = require('copilot_agent.events')
    original_request = http.request
    original_start_event_stream = events.start_event_stream
    original_ui_select = vim.ui.select
    original_ensure_chat_window = agent._ensure_chat_window
  end)

  after_each(function()
    http.request = original_request
    events.start_event_stream = original_start_event_stream
    vim.ui.select = original_ui_select
    agent._ensure_chat_window = original_ensure_chat_window
  end)

  it('creates a fresh session without re-entering the attach-or-resume flow', function()
    local requests = {}
    local ensured_chat = false

    agent.state.session_id = 'current-session'
    agent.state.session_name = 'Current session'
    events.start_event_stream = function() end
    agent._ensure_chat_window = function()
      ensured_chat = true
    end

    http.request = function(method, path, body, callback)
      requests[#requests + 1] = method .. ' ' .. path
      if method == 'GET' then
        error('new_session unexpectedly tried to list existing sessions')
      end
      if method == 'DELETE' then
        assert_eq('/sessions/current-session', path)
        callback({}, nil)
        return
      end

      assert_eq('POST', method)
      assert_eq('/sessions', path)
      assert_eq(nil, body.sessionId)
      assert_eq(nil, body.resume)
      callback({
        sessionId = 'new-session',
        workingDirectory = require('copilot_agent.service').working_directory(),
      }, nil)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.new_session()

    assert_true(ensured_chat)
    assert_eq('new-session', agent.state.session_id)
    assert.same({
      'DELETE /sessions/current-session',
      'POST /sessions',
    }, requests)
  end)

  it('creates a fresh session from the switch-session picker new entry', function()
    local get_requests = 0
    local extra_prompt = nil

    agent.state.session_id = 'current-session'
    agent.state.session_name = 'Current session'
    events.start_event_stream = function() end
    agent._ensure_chat_window = function() end

    http.request = function(method, path, body, callback)
      if method == 'GET' then
        get_requests = get_requests + 1
        assert_eq('/sessions', path)
        callback({
          persisted = {
            {
              sessionId = 'current-session',
              summary = 'Current session',
              workingDirectory = require('copilot_agent.service').working_directory(),
            },
          },
          live = {
            {
              sessionId = 'current-session',
              summary = 'Current session',
              workingDirectory = require('copilot_agent.service').working_directory(),
              live = true,
            },
          },
        }, nil)
        return
      end

      if method == 'DELETE' then
        assert_eq('/sessions/current-session', path)
        callback({}, nil)
        return
      end

      assert_eq('POST', method)
      assert_eq('/sessions', path)
      assert_eq(nil, body.sessionId)
      assert_eq(nil, body.resume)
      callback({
        sessionId = 'new-session',
        workingDirectory = require('copilot_agent.service').working_directory(),
      }, nil)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    vim.ui.select = function(items, opts, on_choice)
      if opts.prompt == 'Switch session' then
        on_choice(items[#items], #items)
        return
      end
      extra_prompt = opts.prompt
    end

    session.switch_session()

    assert_eq(1, get_requests)
    assert_eq(nil, extra_prompt)
    assert_eq('new-session', agent.state.session_id)
  end)
end)

describe('session deletion', function()
  local agent
  local session
  local checkpoints
  local http
  local original_request
  local original_ui_select
  local original_soft_delete_session

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.session'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    session = require('copilot_agent.session')
    checkpoints = require('copilot_agent.checkpoints')
    http = require('copilot_agent.http')
    original_request = http.request
    original_ui_select = vim.ui.select
    original_soft_delete_session = checkpoints.soft_delete_session
  end)

  after_each(function()
    http.request = original_request
    vim.ui.select = original_ui_select
    checkpoints.soft_delete_session = original_soft_delete_session
  end)

  it('shows exact session ids in the delete-session picker and deletes a non-active session', function()
    local requests = {}
    local captured_picker
    local soft_deleted

    agent.state.session_id = 'active-session'
    agent.state.session_name = 'Current session'

    http.request = function(method, path, _, callback)
      requests[#requests + 1] = { method = method, path = path }
      if method == 'GET' then
        callback({
          persisted = {
            {
              sessionId = 'delete-me-raw-id',
              summary = 'Delete me',
              workingDirectory = '/tmp/delete-me',
              modifiedTime = '2026-05-01T00:00:00Z',
            },
            {
              sessionId = 'active-session',
              summary = 'Current session',
              workingDirectory = '/tmp/current',
              modifiedTime = '2026-04-01T00:00:00Z',
            },
          },
        }, nil)
        return
      end
      assert_eq('DELETE', method)
      assert_eq('/sessions/delete-me-raw-id?delete=true', path)
      callback({}, nil)
    end

    checkpoints.soft_delete_session = function(session_id, opts, callback)
      soft_deleted = {
        session_id = session_id,
        opts = opts,
      }
      callback(nil, true)
    end

    vim.ui.select = function(items, opts, on_choice)
      captured_picker = {
        items = items,
        prompt = opts.prompt,
      }
      on_choice(items[1], 1)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.delete_session()

    assert_eq('Delete session', captured_picker.prompt)
    assert_true(captured_picker.items[1]:find('[delete-me-raw-id]', 1, true) ~= nil)
    assert_eq('active-session', agent.state.session_id)
    assert_eq(2, #requests)
    assert_eq('delete-me-raw-id', soft_deleted.session_id)
    assert_eq('Delete me', soft_deleted.opts.session_name)
    assert_eq('/tmp/delete-me', soft_deleted.opts.working_directory)
  end)

  it('soft-deletes checkpoint metadata when deleting the active session', function()
    local soft_deleted
    local delete_path

    agent.state.session_id = 'active-session-id'
    agent.state.session_name = 'Active session'
    agent.state.session_working_directory = '/tmp/active-session-workspace'

    http.request = function(method, path, _, callback)
      assert_eq('DELETE', method)
      delete_path = path
      callback({}, nil)
    end

    checkpoints.soft_delete_session = function(session_id, opts, callback)
      soft_deleted = {
        session_id = session_id,
        opts = opts,
      }
      callback(nil, true)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.stop(true)

    assert_eq('/sessions/active-session-id?delete=true', delete_path)
    assert_eq(nil, agent.state.session_id)
    assert_eq('active-session-id', soft_deleted.session_id)
    assert_eq('Active session', soft_deleted.opts.session_name)
    assert_eq('/tmp/active-session-workspace', soft_deleted.opts.working_directory)
  end)
end)

describe('checkpoint retention', function()
  local checkpoints
  local agent
  local original_stdpath
  local temp_state
  local temp_workspace

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    original_stdpath = vim.fn.stdpath
    temp_state = vim.fn.tempname()
    temp_workspace = vim.fn.tempname()
    vim.fn.mkdir(temp_state, 'p')
    vim.fn.mkdir(temp_workspace, 'p')
    vim.fn.stdpath = function(kind)
      if kind == 'state' then
        return temp_state
      end
      return original_stdpath(kind)
    end
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      notify = false,
      session = {
        working_directory = temp_workspace,
      },
    })
    checkpoints = require('copilot_agent.checkpoints')
  end)

  after_each(function()
    vim.fn.stdpath = original_stdpath
    if temp_workspace and temp_workspace ~= '' then
      vim.fn.delete(temp_workspace, 'rf')
    end
    if temp_state and temp_state ~= '' then
      vim.fn.delete(temp_state, 'rf')
    end
  end)

  it('marks deleted checkpoint repos and prunes them after the retention window', function()
    local session_id = 'retained-session'
    local ok, err = checkpoints._save_index(session_id, {
      session_id = session_id,
      checkpoints = {},
    })
    assert_true(ok ~= nil, err)

    local soft_delete_err
    checkpoints.soft_delete_session(session_id, {
      session_name = 'Deleted session',
      working_directory = '/tmp/project',
    }, function(callback_err)
      soft_delete_err = callback_err
    end)

    assert_eq(nil, soft_delete_err)

    local index = checkpoints._load_index(session_id)
    assert_eq('Deleted session', index.deleted_session_name)
    assert_eq('/tmp/project', index.deleted_working_directory)
    assert_true(type(index.deleted_at) == 'string' and index.deleted_at ~= '')
    assert_true(type(index.purge_after_unix) == 'number')

    index.purge_after_unix = os.time() - 1
    index.purge_after = os.date('!%Y-%m-%dT%H:%M:%SZ', index.purge_after_unix)
    local saved, save_err = checkpoints._save_index(session_id, index)
    assert_true(saved ~= nil, save_err)

    local removed, errors = checkpoints.prune_deleted()
    assert_eq(1, removed)
    assert_eq(0, #errors)
    assert_eq(nil, vim.uv.fs_stat(checkpoints._session_dir(session_id)))
  end)

  it('repairs git identity for existing checkpoint repos before creating a checkpoint', function()
    local session_id = 'legacy-session'
    local repo = checkpoints._session_dir(session_id) .. '/repo'
    local init_result = vim.system({ 'git', 'init', '--quiet', repo }, { text = true }):wait()
    assert_eq(0, init_result.code)

    local callback_done = false
    local callback_err
    local checkpoint_id
    local commit_hash
    checkpoints.create(session_id, 'legacy prompt', function(err, id, commit)
      callback_err = err
      checkpoint_id = id
      commit_hash = commit
      callback_done = true
    end)

    vim.wait(5000, function()
      return callback_done
    end)

    assert_eq(nil, callback_err)
    assert_eq('v001', checkpoint_id)
    assert_true(type(commit_hash) == 'string' and commit_hash ~= '')

    local name_result = vim.system({ 'git', '-C', repo, 'config', 'user.name' }, { text = true }):wait()
    local email_result = vim.system({ 'git', '-C', repo, 'config', 'user.email' }, { text = true }):wait()
    assert_eq(0, name_result.code)
    assert_eq(0, email_result.code)
    assert_eq('copilot-agent.nvim', vim.trim(name_result.stdout or ''))
    assert_eq('copilot-agent.nvim@local', vim.trim(email_result.stdout or ''))
  end)

  it('uses the active session workspace instead of the current editor working directory', function()
    local session_id = 'workspace-locked-session'
    local callback_done = false
    local callback_err
    local checkpoint_id

    agent.state.session_id = session_id
    agent.state.session_working_directory = temp_workspace
    agent.state.config.session.working_directory = temp_workspace .. '-different'

    checkpoints.create(session_id, 'workspace locked prompt', function(err, id)
      callback_err = err
      checkpoint_id = id
      callback_done = true
    end)

    vim.wait(5000, function()
      return callback_done
    end)

    assert_eq(nil, callback_err)
    assert_eq('v001', checkpoint_id)
  end)
end)

describe('chat session activation', function()
  local agent
  local session

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.session'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    agent.state.session_id = nil
    agent.state.session_name = nil
    session = require('copilot_agent.session')
  end)

  it('requests prompt activation when chat opens without a session', function()
    local original_with_session = session.with_session
    local captured_opts

    session.with_session = function(_, opts)
      captured_opts = opts
    end

    agent.state.config.auto_create_session = true
    agent.open_chat()

    session.with_session = original_with_session

    assert_true(type(captured_opts) == 'table')
    assert_true(captured_opts.open_input_on_session_ready)
  end)

  it('opens chat from a floating current window by splitting a normal window instead', function()
    local float_buf = vim.api.nvim_create_buf(false, true)
    local float_win = vim.api.nvim_open_win(float_buf, true, {
      relative = 'editor',
      width = 20,
      height = 4,
      row = 1,
      col = 1,
      style = 'minimal',
      border = 'rounded',
    })

    agent.open_chat()

    assert_true(agent.state.chat_winid and vim.api.nvim_win_is_valid(agent.state.chat_winid))
    assert_true(vim.api.nvim_win_get_config(agent.state.chat_winid).relative == '')

    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end)

  it('does not request prompt activation when sending a direct prompt', function()
    local original_open_chat = agent.open_chat
    local original_with_session = session.with_session
    local captured_opts

    agent.open_chat = function(opts)
      captured_opts = opts
    end
    session.with_session = function(_, opts)
      captured_opts = captured_opts or opts
    end

    agent.state.config.auto_create_session = true
    agent.ask('hello')

    agent.open_chat = original_open_chat
    session.with_session = original_with_session

    assert_true(type(captured_opts) == 'table')
    assert_eq(false, captured_opts.activate_input_on_session_ready)
  end)

  it('opens the input window when the selected session becomes ready', function()
    local original_open_input = agent._open_input_window
    local opened = false

    agent.open_chat()
    agent.state.open_input_on_session_ready = true
    agent._open_input_window = function()
      opened = true
    end

    session._on_session_ready('session-123')

    vim.wait(100, function()
      return opened
    end)

    agent._open_input_window = original_open_input

    assert_true(opened)
    assert_false(agent.state.open_input_on_session_ready)
  end)
end)

describe('chat help', function()
  it('includes session deletion and checkpoint retention guidance', function()
    package.loaded['copilot_agent.chat'] = nil
    local chat = require('copilot_agent.chat')
    local lines = chat._help_lines()
    local text = table.concat(lines, '\n')

    assert_true(text:find(':CopilotAgentDeleteSession', 1, true) ~= nil)
    assert_true(text:find('checkpoints kept 7 days', 1, true) ~= nil)
    assert_true(text:find('Transcript separators show the completed-turn Checkpoint ID (v001...)', 1, true) ~= nil)
  end)
end)

describe('chat input behavior', function()
  local agent
  local input
  local http
  local original_ui_select
  local original_sync_request
  local root_mcp
  local vscode_mcp
  local root_mcp_backup
  local vscode_mcp_backup

  before_each(function()
    pcall(vim.cmd, 'tabonly | only')
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.chat'] = nil
    package.loaded['copilot_agent.input'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    input = require('copilot_agent.input')
    http = require('copilot_agent.http')
    original_ui_select = vim.ui.select
    original_sync_request = http.sync_request
    local cwd = require('copilot_agent.service').working_directory()
    root_mcp = cwd .. '/.mcp.json'
    vscode_mcp = cwd .. '/.vscode/mcp.json'
    root_mcp_backup = nil
    vscode_mcp_backup = nil
  end)

  after_each(function()
    vim.ui.select = original_ui_select
    http.sync_request = original_sync_request
    if root_mcp then
      if root_mcp_backup then
        vim.fn.writefile(root_mcp_backup, root_mcp)
      else
        vim.fn.delete(root_mcp)
      end
    end
    if vscode_mcp then
      if vscode_mcp_backup then
        vim.fn.writefile(vscode_mcp_backup, vscode_mcp)
      else
        vim.fn.delete(vscode_mcp)
      end
    end
    pcall(vim.cmd, 'tabonly | only')
  end)

  it('prompts before closing input with unsent text', function()
    local captured

    agent.open_chat()
    input.open_input_window()

    local prefix = vim.fn.prompt_getprompt(agent.state.input_bufnr)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. 'draft message' })

    vim.ui.select = function(items, opts, on_choice)
      captured = {
        items = items,
        prompt = opts.prompt,
      }
      on_choice(nil)
    end

    input._cancel_input()
    vim.wait(100)

    assert_eq('Discard unsent chat input?', captured.prompt)
    assert_eq('Keep editing', captured.items[1])
    assert_eq('Close input', captured.items[2])
    assert_true(agent.state.input_winid and vim.api.nvim_win_is_valid(agent.state.input_winid))
  end)

  it('uses markdown filetype for the input prompt buffer', function()
    agent.open_chat()
    input.open_input_window()

    assert_eq('markdown', vim.bo[agent.state.input_bufnr].filetype)
  end)

  it('protects the input prompt buffer by default for the upstream treesitter workaround', function()
    agent.open_chat()
    input.open_input_window()

    assert_eq(true, vim.b[agent.state.input_bufnr].copilot_agent_treesitter_disabled)
  end)

  it('allows disabling input markdown protection via config', function()
    agent.setup({
      auto_create_session = false,
      chat = {
        protect_markdown_buffer = false,
      },
    })

    agent.open_chat()
    input.open_input_window()

    assert_true(vim.b[agent.state.input_bufnr].copilot_agent_treesitter_disabled ~= true)
  end)

  it('uses markdown filetype for the chat scratch buffer', function()
    agent.open_chat()

    assert_eq('markdown', vim.bo[agent.state.chat_bufnr].filetype)
  end)

  it('activates markdown syntax in the chat window so conceal works immediately', function()
    agent.open_chat()

    local syntax = vim.api.nvim_win_call(agent.state.chat_winid, function()
      return vim.bo.syntax
    end)

    assert_eq('markdown', syntax)
  end)

  it('keeps treesitter enabled for the chat scratch buffer', function()
    agent.open_chat()

    assert_true(vim.b[agent.state.chat_bufnr].copilot_agent_treesitter_disabled ~= true)
  end)

  it('refreshes render-markdown after a busy chat re-render', function()
    local render = require('copilot_agent.render')
    local original_notify_render_plugins = render.notify_render_plugins
    local refresh_calls = 0
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid

    render.notify_render_plugins = function(_)
      refresh_calls = refresh_calls + 1
    end

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.entries = {
      { kind = 'assistant', content = 'busy **markdown** reply' },
    }
    vim.api.nvim_win_set_buf(winid, bufnr)
    agent.state.chat_busy = true
    render.render_chat()

    render.notify_render_plugins = original_notify_render_plugins
    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    assert_true(refresh_calls > 0)
  end)

  it('shows the default empty-state message when the chat buffer has no messages', function()
    local render = require('copilot_agent.render')
    render.clear_transcript()
    agent.state.entry_row_index = {}
    agent.open_chat()
    render.render_chat()

    local lines = vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false)
    assert.same({
      'No messages yet.',
      'Press i or <Enter> to open the input buffer.',
      'Run :CopilotAgentAsk to send a prompt from the command line.',
    }, { unpack(lines, 5, 7) })
  end)

  it('preserves assistant blank lines instead of compacting prose spacing', function()
    local render = require('copilot_agent.render')
    local lines = render.entry_lines({
      kind = 'assistant',
      content = table.concat({
        'First sentence.',
        '   ',
        'Second sentence.',
        '- item one',
        '- item two',
        'After list.',
        'Done.',
      }, '\n'),
    }, 1, false)

    assert.same({
      'Assistant:',
      '  First sentence.',
      '  ',
      '  Second sentence.',
      '  - item one',
      '  - item two',
      '  After list.',
      '  Done.',
      '',
    }, lines)
  end)

  it('preserves fenced code blocks without injecting extra blank lines around them', function()
    local render = require('copilot_agent.render')
    local lines = render.entry_lines({
      kind = 'assistant',
      content = table.concat({
        'Before code.',
        '```lua',
        '# heading-like comment',
        '- list-like line',
        'print("hello")',
        '```',
        'After code.',
      }, '\n'),
    }, 1, false)

    assert.same({
      'Assistant:',
      '  Before code.',
      '  ```lua',
      '  # heading-like comment',
      '  - list-like line',
      '  print("hello")',
      '  ```',
      '  After code.',
      '',
    }, lines)
  end)

  it('does not truncate long assistant lines in transcript rendering', function()
    local render = require('copilot_agent.render')
    local content = string.rep('Long assistant output segment. ', 80)
    local lines = render.entry_lines({
      kind = 'assistant',
      content = content,
    }, 1, false)

    assert.same({
      'Assistant:',
      '  ' .. content,
      '',
    }, lines)
  end)

  it('merges consecutive assistant entries without blank gaps between prose lines', function()
    local render = require('copilot_agent.render')
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr
    render.reset_frozen_render()
    render.render_chat()

    render.append_entry('assistant', 'First sentence.')
    render.append_entry('assistant', 'Second sentence.')
    render.append_entry('assistant', 'Third sentence.')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  First sentence.',
      '  Second sentence.',
      '  Third sentence.',
      '',
    }, { unpack(lines, #lines - 4, #lines) })
  end)

  it('coalesces multiple assistant.message events in one turn without duplicating live lines', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'review changes')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'review changes',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-1', content = 'First update.' },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-2', content = 'Second update.' },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-3', content = 'Second update.' },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-4', content = 'First update.\nSecond update.\nFinal update.' },
    })

    vim.wait(200)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  First update.',
      '  Second update.',
      '  Final update.',
      '',
    }, { unpack(lines, #lines - 4, #lines) })
  end)

  it('does not duplicate a punctuation-refined assistant.message after a streamed delta', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'summarize diff')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'summarize diff',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-1',
        deltaContent = "I've got the changed file list Now I'm reading the actual hunks so I can explain the behavior changes, not just the filenames",
      },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-1',
        content = "I've got the changed file list. Now I'm reading the actual hunks so I can explain the behavior changes, not just the filenames.",
      },
    })

    vim.wait(250)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      "  I've got the changed file list. Now I'm reading the actual hunks so I can explain the behavior changes, not just the filenames.",
      '',
    }, { unpack(lines, #lines - 2, #lines) })
  end)

  it('replaces a delta-built live draft when assistant.message sends a shorter suffix snapshot', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'debug live transcript')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'debug live transcript',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-1',
        deltaContent = 'Still tracing the live log for duplicate assistant items.',
      },
    })
    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-1',
        deltaContent = 'I found the merge helper issue.',
      },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-1',
        content = 'I found the merge helper issue.',
      },
    })

    vim.wait(250)

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('I found the merge helper issue.', entry.content)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  I found the merge helper issue.',
      '',
    }, { unpack(lines, #lines - 2, #lines) })
  end)

  it('reuses the trailing live assistant entry when turn tracking is briefly missing', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'debug duplicates')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'debug duplicates',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        deltaContent = 'I found the mismatch and I am tracing the render race now',
      },
    })

    -- Simulate a transient loss of active-turn metadata before the final
    -- assistant.message arrives with a concrete messageId.
    agent.state.pending_checkpoint_turn = nil
    agent.state.active_turn_assistant_index = nil
    agent.state.active_turn_assistant_message_id = nil
    agent.state.chat_busy = true

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-final',
        content = 'I found the mismatch, and I am tracing the render race now.',
      },
    })

    vim.wait(250)

    local assistant_entries = {}
    for _, entry in ipairs(agent.state.entries) do
      if entry.kind == 'assistant' then
        assistant_entries[#assistant_entries + 1] = entry
      end
    end
    assert_eq(1, #assistant_entries)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  I found the mismatch, and I am tracing the render race now.',
      '',
    }, { unpack(lines, #lines - 2, #lines) })
  end)

  it('starts a fresh assistant block after turn_end even when tool activity makes chat busy again', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'check transcript state')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'check transcript state',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-first',
        content = 'First turn summary.',
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
      },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-second',
        content = 'Second turn summary.',
      },
    })

    vim.wait(250)

    local assistant_entries = {}
    for _, entry in ipairs(agent.state.entries) do
      if entry.kind == 'assistant' then
        assistant_entries[#assistant_entries + 1] = entry
      end
    end

    assert_eq(2, #assistant_entries)
    assert_eq('First turn summary.', assistant_entries[1].content)
    assert_eq('Second turn summary.', assistant_entries[2].content)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local transcript_end = #lines - (agent.state.chat_tail_spacer_lines or 0)
    assert.same({
      'Assistant:',
      '  First turn summary.',
      '',
      'Assistant:',
      '  Second turn summary.',
      '',
    }, { unpack(lines, transcript_end - 5, transcript_end) })
  end)

  it('starts streamed assistant output in a fresh block after assistant.turn_end', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'inspect duplicate rendering')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'inspect duplicate rendering',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-first',
        content = 'First turn summary.',
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-second',
        deltaContent = 'Second turn live reply.',
      },
    })

    vim.wait(250)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  First turn summary.',
      '',
      'Assistant:',
      '  Second turn live reply.',
      '',
    }, { unpack(lines, #lines - 5, #lines) })
  end)

  it('keeps a transcript activity summary between assistant turns', function()
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-first',
        content = 'I am investigating the mismatch now.',
      },
    })
    events.handle_session_event({
      type = 'assistant.intent',
      data = {
        intent = 'Inspecting activity strings',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'rg',
        arguments = { 'activity', 'lua/copilot_agent' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-second',
        content = 'I found the activity summary hook.',
      },
    })

    vim.wait(250)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  I am investigating the mismatch now.',
      '',
      'Activity: rg activity lua/copilot_agent (2 items hidden)',
      '',
      'Assistant:',
      '  I found the activity summary hook.',
      '',
    }, { unpack(lines, #lines - 7, #lines) })
  end)

  it('toggles collapsed activity transcript blocks with zA in the chat buffer', function()
    local events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.intent',
      data = {
        intent = 'Inspecting activity strings',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'rg',
        arguments = { 'activity', 'lua/copilot_agent' },
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.wait(250)

    local normal_maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
    local has_toggle = false
    for _, map in ipairs(normal_maps) do
      if map.lhs == 'zA' then
        has_toggle = true
        break
      end
    end
    assert_true(has_toggle)

    local joined = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    assert_true(joined:find('Activity: rg activity lua/copilot_agent (2 items hidden)', 1, true) ~= nil)
    assert_true(joined:find('Ran bash — rg activity lua/copilot_agent', 1, true) == nil)

    assert_true(render.toggle_activity_entries())
    joined = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    assert_true(joined:find('Activity:\n  Inspecting activity strings\n  Ran bash — rg activity lua/copilot_agent', 1, true) ~= nil)

    assert_false(render.toggle_activity_entries())
    joined = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    assert_true(joined:find('Activity: rg activity lua/copilot_agent (2 items hidden)', 1, true) ~= nil)
  end)

  it('captures tool execution output details in activity transcript entries', function()
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        toolCallId = 'tool-123',
        command = 'git',
        arguments = { 'diff', '--stat' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_partial_result',
      data = {
        toolCallId = 'tool-123',
        partialOutput = 'partial line 1\n',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_progress',
      data = {
        toolCallId = 'tool-123',
        progressMessage = 'Collecting diff output',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {
        success = true,
        toolCallId = 'tool-123',
        result = {
          content = 'diff summary',
          detailedContent = 'full diff output\nsecond line',
        },
        toolTelemetry = {
          filesChanged = 3,
        },
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('activity', entry.kind)
    assert_eq('Ran bash — git diff --stat', entry.content)
    assert.same({
      kind = 'tool',
      summary = 'Ran bash — git diff --stat',
      tool_name = 'bash',
      tool_call_id = 'tool-123',
      tool_detail = 'git diff --stat',
      start_data = {
        toolName = 'bash',
        toolCallId = 'tool-123',
        command = 'git',
        arguments = { 'diff', '--stat' },
      },
      progress_messages = { 'Collecting diff output' },
      partial_output = 'partial line 1\n',
      complete_data = {
        success = true,
        toolCallId = 'tool-123',
        result = {
          content = 'diff summary',
          detailedContent = 'full diff output\nsecond line',
        },
        toolTelemetry = {
          filesChanged = 3,
        },
      },
      success = true,
      tool_telemetry = {
        filesChanged = 3,
      },
      output_text = 'full diff output\nsecond line',
    }, entry.activity_items[1])
  end)

  it('opens a floating activity details viewer for the activity block under the cursor', function()
    local events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local chat_bufnr = agent.state.chat_bufnr
    local chat_winid = agent.state.chat_winid

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        toolCallId = 'tool-789',
        command = 'git',
        arguments = { 'diff', '--stat' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_progress',
      data = {
        toolCallId = 'tool-789',
        progressMessage = 'Collecting diff output',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {
        success = true,
        toolCallId = 'tool-789',
        result = {
          detailedContent = 'full diff output\nsecond line',
        },
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.wait(250)

    local activity_idx = #agent.state.entries
    local activity_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == activity_idx then
        activity_row = row
        break
      end
    end
    assert_not_nil(activity_row)

    local normal_maps = vim.api.nvim_buf_get_keymap(chat_bufnr, 'n')
    local has_viewer = false
    for _, map in ipairs(normal_maps) do
      if map.lhs == 'gA' then
        has_viewer = true
        break
      end
    end
    assert_true(has_viewer)

    local original_open_win = vim.api.nvim_open_win
    local viewer_buf
    local viewer_title
    vim.api.nvim_open_win = function(buf, enter, config)
      local winid = original_open_win(buf, enter, config)
      if buf ~= chat_bufnr then
        viewer_buf = buf
        viewer_title = config.title
      end
      return winid
    end

    vim.api.nvim_win_set_cursor(chat_winid, { activity_row + 1, 0 })
    local opened = render.show_activity_details_under_cursor(chat_winid)
    vim.api.nvim_open_win = original_open_win

    assert_true(opened)
    assert_not_nil(viewer_buf)
    assert_eq(' Activity details ', viewer_title)
    local lines = vim.api.nvim_buf_get_lines(viewer_buf, 0, -1, false)
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('# Activity details', 1, true) ~= nil)
    assert_true(joined:find('## Tool 1 — Ran bash — git diff --stat', 1, true) ~= nil)
    assert_true(joined:find('Collecting diff output', 1, true) ~= nil)
    assert_true(joined:find('full diff output', 1, true) ~= nil)
    assert_true(joined:find('second line', 1, true) ~= nil)
  end)

  it('summarizes apply_patch activity by changed file instead of raw patch text', function()
    local events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-first',
        content = 'Applying the update now.',
      },
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'apply_patch',
        input = table.concat({
          '*** Begin Patch',
          '*** Update File: /Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/events.lua',
          '@@',
          '-old line',
          '+new line',
          '*** End Patch',
        }, '\n'),
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.wait(250)
    assert_true(render.toggle_activity_entries())

    local joined = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    assert_true(joined:find('Updated lua/copilot_agent/events.lua', 1, true) ~= nil)
    assert_true(joined:find('*** Begin Patch', 1, true) == nil)
    assert_true(joined:find('-old line', 1, true) == nil)
    assert_true(joined:find('+new line', 1, true) == nil)
  end)

  it('summarizes multiline shell scripts instead of showing the full script body', function()
    local events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        fullCommandText = table.concat({
          "python - <<'PY'",
          'print("hello from inline script")',
          'PY',
        }, '\n'),
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.wait(250)
    assert_true(render.toggle_activity_entries())

    local joined = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    assert_true(joined:find('Ran python script', 1, true) ~= nil)
    assert_true(joined:find('hello from inline script', 1, true) == nil)
    assert_true(joined:find("<<'PY'", 1, true) == nil)
  end)

  it('preserves punctuation and blank-line deltas after real streamed content starts', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'explain fix')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'explain fix',
      entry_index = prompt_idx,
    }

    local function delta(chunk)
      events.handle_session_event({
        type = 'assistant.message_delta',
        data = {
          messageId = 'assistant-1',
          deltaContent = chunk,
        },
      })
    end

    delta('Sentence')
    delta('.')
    delta('\n\n')
    delta('1')
    delta('.')
    delta(' item')

    vim.wait(250)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  Sentence.',
      '  ',
      '  1. item',
      '',
    }, { unpack(lines, #lines - 4, #lines) })
  end)

  it('appends repeated full-line assistant.message_delta chunks exactly as streamed', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'review live status')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'review live status',
      entry_index = prompt_idx,
    }

    local function delta(chunk)
      events.handle_session_event({
        type = 'assistant.message_delta',
        data = {
          messageId = 'assistant-1',
          deltaContent = chunk,
        },
      })
    end

    delta('I am checking the request error path.')
    delta('I am checking the request error path.')
    delta('\nI am adding a focused regression.')
    delta('\nI am adding a focused regression.')

    vim.wait(250)

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('I am checking the request error path.I am checking the request error path.\nI am adding a focused regression.\nI am adding a focused regression.', entry.content)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  I am checking the request error path.I am checking the request error path.',
      '  I am adding a focused regression.',
      '  I am adding a focused regression.',
      '',
    }, { unpack(lines, #lines - 4, #lines) })
  end)

  it('does not collapse indentation spaces or fence backticks across assistant.message_delta chunks', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()

    local prompt_idx = render.append_entry('user', 'check raw append')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'check raw append',
      entry_index = prompt_idx,
    }

    local function delta(chunk)
      events.handle_session_event({
        type = 'assistant.message_delta',
        data = {
          messageId = 'assistant-1',
          deltaContent = chunk,
        },
      })
    end

    delta('  ')
    delta(' local value = 1')
    delta('\n  ``')
    delta('`\n\n')

    vim.wait(250)

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('   local value = 1\n  ```\n\n', entry.content)
  end)

  it('prefers punctuation-refined assistant.message snapshots instead of appending near-duplicates', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'review spacing')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'review spacing',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-1', content = 'Fence state is lost in the second pass I am fixing that now' },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-2', content = 'Fence state is lost in the second pass. I am fixing that now.' },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-3', content = 'Fence state is lost in the second pass. I am fixing that now.' },
    })

    vim.wait(200)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  Fence state is lost in the second pass. I am fixing that now.',
      '',
    }, { unpack(lines, #lines - 2, #lines) })
  end)

  it('merges overlapping assistant.message snapshots that include blank lines', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    local prompt_idx = render.append_entry('user', 'review paragraphs')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'review paragraphs',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-1', content = 'First paragraph.\n\nSecond paragraph.' },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-2', content = '\nSecond paragraph.\n\nThird paragraph.' },
    })

    vim.wait(200)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local second_count = 0
    for _, line in ipairs(lines) do
      if line == '  Second paragraph.' then
        second_count = second_count + 1
      end
    end
    assert_eq(1, second_count)
    assert.same({
      'Assistant:',
      '  First paragraph.',
      '  Second paragraph.',
      '  Third paragraph.',
      '',
    }, { unpack(lines, #lines - 4, #lines) })
  end)

  it('keeps the current conversation anchored until the window fills, then advances by half pages', function()
    local render = require('copilot_agent.render')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid
    local original_get_height = vim.api.nvim_win_get_height

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.entries = {
      {
        kind = 'assistant',
        content = table.concat({
          'old line 1',
          'old line 2',
          'old line 3',
          'old line 4',
          'old line 5',
          'old line 6',
        }, '\n'),
      },
    }
    agent.state.entry_row_index = {}
    agent.state.active_conversation_entry_index = nil
    agent.state.chat_follow_topline = nil
    agent.state.chat_auto_scroll_enabled = true
    agent.state.chat_scroll_guard = 0
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_get_height = function(target_winid)
      if target_winid == winid then
        return 8
      end
      return original_get_height(target_winid)
    end

    render.reset_frozen_render()
    render.render_chat()
    render.scroll_to_bottom()
    vim.api.nvim_win_set_cursor(winid, { vim.api.nvim_buf_line_count(bufnr), 0 })

    local prompt_idx = render.append_entry('user', 'new prompt')
    local anchor_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == prompt_idx then
        anchor_row = row
        break
      end
    end
    assert_not_nil(anchor_row)

    local view = vim.fn.getwininfo(winid)[1]
    assert_eq(anchor_row + 1, view.topline)

    local assistant_idx = render.append_entry('assistant', '')
    local assistant_entry = agent.state.entries[assistant_idx]
    assistant_entry.content = 'line a\nline b\nline c'
    render.stream_update(assistant_entry, assistant_idx)
    vim.wait(200)
    view = vim.fn.getwininfo(winid)[1]
    assert_eq(anchor_row + 1, view.topline)

    assistant_entry.content = table.concat({
      'line a',
      'line b',
      'line c',
      'line d',
      'line e',
      'line f',
      'line g',
      'line h',
      'line i',
      'line j',
    }, '\n')
    render.stream_update(assistant_entry, assistant_idx)
    vim.wait(200)

    view = vim.fn.getwininfo(winid)[1]
    assert_eq(anchor_row + 1 + 4, view.topline)

    vim.api.nvim_win_get_height = original_get_height
    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('counts overlay virtual lines and spacer tail when deciding half-page conversation follow', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid
    local original_get_height = vim.api.nvim_win_get_height

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.entries = {
      {
        kind = 'assistant',
        content = table.concat({
          'old line 1',
          'old line 2',
          'old line 3',
          'old line 4',
          'old line 5',
          'old line 6',
        }, '\n'),
      },
    }
    agent.state.entry_row_index = {}
    agent.state.active_conversation_entry_index = nil
    agent.state.chat_follow_topline = nil
    agent.state.chat_auto_scroll_enabled = true
    agent.state.chat_scroll_guard = 0
    agent.state.chat_tail_spacer_lines = 0
    agent.state.reasoning_text = ''
    agent.state.reasoning_lines = {}
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_get_height = function(target_winid)
      if target_winid == winid then
        return 12
      end
      return original_get_height(target_winid)
    end

    render.reset_frozen_render()
    render.render_chat()
    render.scroll_to_bottom()
    vim.api.nvim_win_set_cursor(winid, { vim.api.nvim_buf_line_count(bufnr), 0 })

    local prompt_idx = render.append_entry('user', 'overlay follow')
    local anchor_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == prompt_idx then
        anchor_row = row
        break
      end
    end
    assert_not_nil(anchor_row)

    local view = vim.fn.getwininfo(winid)[1]
    assert_eq(anchor_row + 1, view.topline)

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'overlay-follow',
        deltaContent = 'step one\nstep two',
      },
    })

    vim.wait(500)

    assert_eq(3, agent.state.chat_tail_spacer_lines)
    local assistant_idx = agent.state.active_turn_assistant_index
    assert_not_nil(assistant_idx)
    local assistant_entry = agent.state.entries[assistant_idx]
    assistant_entry.content = table.concat({
      'line a',
      'line b',
      'line c',
      'line d',
    }, '\n')
    render.stream_update(assistant_entry, assistant_idx)

    vim.wait(200)

    view = vim.fn.getwininfo(winid)[1]
    assert_true(view.topline > anchor_row + 1)

    agent.state.chat_busy = false
    agent.state.stream_line_start = nil
    agent.state.active_turn_assistant_index = nil
    agent.state.live_assistant_entry_index = nil
    agent.state.active_turn_assistant_message_id = nil
    agent.state.active_assistant_merge_group = nil
    agent.state.reasoning_entry_key = nil
    agent.state.reasoning_text = ''
    agent.state.reasoning_lines = {}
    agent.state.chat_tail_spacer_lines = 0
    agent.state.overlay_tool_display = nil
    agent.state.active_tool = nil
    agent.state.active_tool_run_id = nil
    agent.state.active_tool_detail = nil
    agent.state.pending_tool_detail = nil
    agent.state._rendered_line_count = nil
    vim.api.nvim_win_get_height = original_get_height
    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('does not fall back to bottom-follow while a live turn anchor is active', function()
    local render = require('copilot_agent.render')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid
    local original_get_height = vim.api.nvim_win_get_height

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.entries = {
      { kind = 'assistant', content = table.concat({
        'old line 1',
        'old line 2',
        'old line 3',
        'old line 4',
      }, '\n') },
    }
    agent.state.entry_row_index = {}
    agent.state.active_conversation_entry_index = nil
    agent.state.chat_follow_topline = nil
    agent.state.chat_auto_scroll_enabled = true
    agent.state.chat_scroll_guard = 0
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_get_height = function(target_winid)
      if target_winid == winid then
        return 20
      end
      return original_get_height(target_winid)
    end

    render.reset_frozen_render()
    render.render_chat()
    render.scroll_to_bottom()

    local prompt_idx = render.append_entry('user', 'anchored prompt')
    agent.state.pending_checkpoint_turn = {
      session_id = agent.state.session_id,
      prompt = 'anchored prompt',
      entry_index = prompt_idx,
    }
    agent.state.chat_busy = true

    local anchor_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == prompt_idx then
        anchor_row = row
        break
      end
    end
    assert_not_nil(anchor_row)

    local assistant_idx = render.append_entry('assistant', '')
    local assistant_entry = agent.state.entries[assistant_idx]
    assistant_entry.content = 'first line'
    render.stream_update(assistant_entry, assistant_idx)
    vim.wait(200)

    local view = vim.fn.getwininfo(winid)[1]
    assert_eq(anchor_row + 1, view.topline)

    vim.api.nvim_win_get_height = original_get_height
    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('pauses auto-follow after manual scrolling and resumes it again at the bottom', function()
    local render = require('copilot_agent.render')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid
    local original_get_height = vim.api.nvim_win_get_height

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.entries = {
      {
        kind = 'assistant',
        content = table.concat({
          'old line 1',
          'old line 2',
          'old line 3',
          'old line 4',
          'old line 5',
          'old line 6',
        }, '\n'),
      },
    }
    agent.state.entry_row_index = {}
    agent.state.active_conversation_entry_index = nil
    agent.state.chat_follow_topline = nil
    agent.state.chat_auto_scroll_enabled = true
    agent.state.chat_scroll_guard = 0
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_get_height = function(target_winid)
      if target_winid == winid then
        return 8
      end
      return original_get_height(target_winid)
    end

    render.reset_frozen_render()
    render.render_chat()
    render.scroll_to_bottom()
    vim.wait(120)

    local prompt_idx = render.append_entry('user', 'new prompt')
    local anchor_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == prompt_idx then
        anchor_row = row
        break
      end
    end
    assert_not_nil(anchor_row)

    local assistant_idx = render.append_entry('assistant', '')
    local assistant_entry = agent.state.entries[assistant_idx]
    assistant_entry.content = table.concat({
      'line a',
      'line b',
      'line c',
      'line d',
      'line e',
      'line f',
      'line g',
      'line h',
      'line i',
      'line j',
    }, '\n')
    render.stream_update(assistant_entry, assistant_idx)
    vim.wait(200)

    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    vim.api.nvim_win_call(winid, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    render.handle_chat_window_scrolled(winid)

    assert_false(agent.state.chat_auto_scroll_enabled)

    assistant_entry.content = table.concat({
      'line a',
      'line b',
      'line c',
      'line d',
      'line e',
      'line f',
      'line g',
      'line h',
      'line i',
      'line j',
      'line k',
      'line l',
      'line m',
      'line n',
    }, '\n')
    render.stream_update(assistant_entry, assistant_idx)
    vim.wait(200)

    local view = vim.fn.getwininfo(winid)[1]
    assert_eq(1, view.topline)

    local win_height = vim.api.nvim_win_get_height(winid)
    local last_line = vim.api.nvim_buf_line_count(bufnr)
    local bottom_topline = math.max(1, last_line - win_height + 1)
    vim.api.nvim_win_set_cursor(winid, { last_line, 0 })
    vim.api.nvim_win_call(winid, function()
      vim.fn.winrestview({ topline = bottom_topline })
    end)
    render.handle_chat_window_scrolled(winid)

    assert_true(agent.state.chat_auto_scroll_enabled)

    assistant_entry.content = table.concat({
      'line a',
      'line b',
      'line c',
      'line d',
      'line e',
      'line f',
      'line g',
      'line h',
      'line i',
      'line j',
      'line k',
      'line l',
      'line m',
      'line n',
      'line o',
      'line p',
      'line q',
      'line r',
    }, '\n')
    render.stream_update(assistant_entry, assistant_idx)
    vim.wait(200)

    view = vim.fn.getwininfo(winid)[1]
    assert_true(view.topline > bottom_topline)

    vim.api.nvim_win_get_height = original_get_height
    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('uses frozen render to skip unchanged entries on subsequent render_chat calls', function()
    local render = require('copilot_agent.render')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.chat_busy = false
    agent.state.pending_checkpoint_ops = 0
    vim.api.nvim_win_set_buf(winid, bufnr)

    -- Populate transcript with several entries.
    agent.state.entries = {
      { kind = 'user', content = 'hello' },
      { kind = 'assistant', content = 'world' },
      { kind = 'user', content = 'second turn' },
      { kind = 'assistant', content = 'second reply' },
    }

    -- First render: full, should set frozen watermark.
    render.reset_frozen_render()
    render.render_chat()
    local lines_after_first = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local frozen_entry_count = agent.state._frozen_entry_count or 0
    local frozen_line_count = agent.state._frozen_line_count or 0
    assert_eq(4, frozen_entry_count, 'should freeze all 4 entries')
    assert_true(frozen_line_count > 0, 'frozen_line_count should be positive')

    -- Add a new entry and render again; frozen region should be untouched.
    agent.state.entries[#agent.state.entries + 1] = { kind = 'user', content = 'third turn' }
    agent.state.entries[#agent.state.entries + 1] = { kind = 'assistant', content = 'third reply' }
    render.render_chat()
    local lines_after_second = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- First frozen_line_count lines should be identical.
    for i = 1, frozen_line_count do
      assert_eq(lines_after_first[i], lines_after_second[i], 'frozen line ' .. i .. ' should be unchanged')
    end
    -- Buffer should now have more lines (new entries appended).
    assert_true(#lines_after_second > #lines_after_first, 'buffer should grow after adding entries')
    -- New frozen watermark should cover all 6 entries.
    assert_eq(6, agent.state._frozen_entry_count or 0, 'should freeze all 6 entries')

    render.notify_render_plugins = render.notify_render_plugins
    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('does not advance frozen watermark while chat is busy', function()
    local render = require('copilot_agent.render')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.pending_checkpoint_ops = 0
    vim.api.nvim_win_set_buf(winid, bufnr)

    -- Initial idle render to establish frozen state.
    agent.state.entries = {
      { kind = 'user', content = 'hello' },
      { kind = 'assistant', content = 'world' },
    }
    agent.state.chat_busy = false
    render.reset_frozen_render()
    render.render_chat()
    local frozen_before = agent.state._frozen_entry_count or 0
    assert_eq(2, frozen_before, 'should freeze 2 entries when idle')

    -- Simulate busy: add a new entry and render while chat_busy=true.
    agent.state.entries[#agent.state.entries + 1] = { kind = 'user', content = 'busy msg' }
    agent.state.entries[#agent.state.entries + 1] = { kind = 'assistant', content = 'streaming...' }
    agent.state.chat_busy = true
    render.render_chat()
    -- Frozen watermark should NOT have advanced past the idle-frozen count.
    assert_eq(frozen_before, agent.state._frozen_entry_count or 0, 'should not advance frozen while busy')

    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('does not advance frozen watermark while checkpoint ops are pending', function()
    local render = require('copilot_agent.render')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.chat_busy = false
    vim.api.nvim_win_set_buf(winid, bufnr)

    agent.state.entries = {
      { kind = 'user', content = 'hello' },
      { kind = 'assistant', content = 'world' },
    }

    -- Simulate pending checkpoint ops.
    agent.state.pending_checkpoint_ops = 1
    render.reset_frozen_render()
    render.render_chat()
    assert_eq(0, agent.state._frozen_entry_count or 0, 'should not freeze with pending checkpoint ops')

    -- Clear pending ops and re-render — now it should freeze.
    agent.state.pending_checkpoint_ops = 0
    render.render_chat()
    assert_eq(2, agent.state._frozen_entry_count or 0, 'should freeze after checkpoint ops clear')

    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('freezes current buffer when a user prompt is appended via append_entry', function()
    local render = require('copilot_agent.render')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_get_current_win()
    local original_chat_bufnr = agent.state.chat_bufnr
    local original_chat_winid = agent.state.chat_winid

    agent.state.history_loading = false
    agent.state.chat_bufnr = bufnr
    agent.state.chat_winid = winid
    agent.state.chat_busy = false
    agent.state.pending_checkpoint_ops = 0
    vim.api.nvim_win_set_buf(winid, bufnr)

    -- Populate a complete first turn.
    agent.state.entries = {
      { kind = 'user', content = 'first prompt' },
      { kind = 'assistant', content = 'first reply' },
    }
    render.reset_frozen_render()
    render.render_chat()
    local lines_after_turn1 = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Simulate pending checkpoint (turn just ended but callback hasn't arrived).
    agent.state.pending_checkpoint_ops = 1

    -- Append a new user prompt — should freeze at the current buffer state
    -- even though checkpoint ops are pending.
    render.append_entry('user', 'second prompt')
    local frozen_after_prompt = agent.state._frozen_entry_count or 0
    assert_eq(2, frozen_after_prompt, 'freeze_current_buffer should freeze the 2 entries before the new prompt')

    -- render_chat should only rebuild the new user entry, not the whole buffer.
    render.render_chat()
    local lines_after_turn2 = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local frozen_lines = agent.state._frozen_line_count or 0
    for i = 1, frozen_lines do
      assert_eq(lines_after_turn1[i], lines_after_turn2[i], 'frozen line ' .. i .. ' should be unchanged')
    end
    assert_true(#lines_after_turn2 > #lines_after_turn1, 'buffer should grow with new prompt')

    agent.state.chat_bufnr = original_chat_bufnr
    agent.state.chat_winid = original_chat_winid
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('uses Enter to confirm popup completion before prompt submission', function()
    local original_pumvisible = vim.fn.pumvisible

    vim.fn.pumvisible = function()
      return 1
    end
    local confirm_keys = input._confirm_completion_or_submit()
    vim.fn.pumvisible = function()
      return 0
    end
    local submit_keys = input._confirm_completion_or_submit()
    vim.fn.pumvisible = original_pumvisible

    assert_eq(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), confirm_keys)
    assert_eq(vim.api.nvim_replace_termcodes('<CR>', true, false, true), submit_keys)
  end)

  it('does not show the checkpoint id in the input separator', function()
    agent.state.session_id = 'nvim-1717245296789000000'

    agent.open_chat()
    input.open_input_window()

    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.input_bufnr, -1, 0, -1, { details = true })
    local separator_text = nil
    for _, mark in ipairs(extmarks) do
      local details = mark[4] or {}
      local virt_lines = details.virt_lines
      if type(virt_lines) == 'table' and virt_lines[1] and virt_lines[1][1] and virt_lines[1][1][1] then
        separator_text = virt_lines[1][1][1]
        break
      end
    end

    assert_true(type(separator_text) == 'string' and separator_text ~= '')
    assert_true(separator_text:find('Conversation ID', 1, true) == nil)
    assert_true(separator_text:find('Checkpoint ID', 1, true) == nil)
    assert_true(separator_text:find(expected_local_session_id('nvim', 1717245296), 1, true) == nil)
  end)

  it('shows the checkpoint id in virtual transcript separators between turns', function()
    local render = require('copilot_agent.render')
    agent.state.session_id = 'nvim-1717245296789000000'
    agent.state.entries = {
      { kind = 'user', content = 'first prompt', checkpoint_id = 'v001' },
      { kind = 'assistant', content = 'first reply' },
      { kind = 'user', content = 'second prompt', checkpoint_id = 'v002' },
      { kind = 'assistant', content = 'second reply' },
    }
    if agent.state.chat_bufnr and vim.api.nvim_buf_is_valid(agent.state.chat_bufnr) then
      vim.api.nvim_buf_set_name(agent.state.chat_bufnr, 'copilot-agent-chat-stale-' .. agent.state.chat_bufnr)
    end
    agent.state.chat_bufnr = nil
    agent.state.chat_winid = nil

    agent.open_chat()
    render.render_chat()
    vim.wait(20)

    local lines = vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false)
    local chat_ns = vim.api.nvim_get_namespaces().copilot_agent_chat
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, chat_ns, 0, -1, { details = true })
    local separators = {}
    for _, mark in ipairs(extmarks) do
      local details = mark[4] or {}
      local virt_lines = details.virt_lines
      if details.virt_lines_above and type(virt_lines) == 'table' and virt_lines[1] and virt_lines[1][1] then
        local text = {}
        for _, chunk in ipairs(virt_lines[1]) do
          if type(chunk[1]) == 'string' then
            text[#text + 1] = chunk[1]
          end
        end
        local joined = table.concat(text)
        if joined:find('Checkpoint ID', 1, true) ~= nil then
          separators[#separators + 1] = joined
        end
      end
    end

    for _, text in ipairs(separators) do
      assert_true(text:find('---', 1, true) == nil)
    end
    for _, line in ipairs(lines) do
      assert_true(line:find('Conversation ID', 1, true) == nil)
      assert_true(line:find('Checkpoint ID', 1, true) == nil)
    end
  end)

  it('reanchors the input window below the active chat window', function()
    agent.open_chat()
    input.open_input_window()

    local prefix = vim.fn.prompt_getprompt(agent.state.input_bufnr)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. 'draft message' })

    local stale_chat_win = agent.state.chat_winid
    local source_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('leftabove vnew')
    local moved_chat_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(moved_chat_win, agent.state.chat_bufnr)
    vim.api.nvim_win_set_buf(stale_chat_win, source_buf)
    agent.state.chat_winid = stale_chat_win

    input.open_input_window()

    assert_eq(moved_chat_win, input._resolve_chat_window())
    assert_true(input._is_input_anchored_below_chat(moved_chat_win, agent.state.input_winid))
    assert_eq(prefix .. 'draft message', vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, -1, false)[1])
  end)

  it('completes discovered command arguments from the chat input', function()
    local vscode_dir = vim.fn.fnamemodify(vscode_mcp, ':h')
    root_mcp_backup = vim.fn.filereadable(root_mcp) == 1 and vim.fn.readfile(root_mcp) or nil
    vscode_mcp_backup = vim.fn.filereadable(vscode_mcp) == 1 and vim.fn.readfile(vscode_mcp) or nil

    vim.fn.mkdir(vscode_dir, 'p')
    vim.fn.writefile({ '{"mcpServers":{"local":{},"docs":{}}}' }, root_mcp)
    vim.fn.writefile({ '{"servers":[{"name":"browser"}]}' }, vscode_mcp)

    http.sync_request = function(method, path)
      assert_eq('GET', method)
      if path == '/models' then
        return {
          models = {
            { id = 'gpt-5.4', name = 'GPT 5.4' },
            { id = 'claude-sonnet-4.6', name = 'Claude Sonnet 4.6' },
          },
        }, nil, 200
      end
      if path == '/sessions' then
        return {
          persisted = {
            { sessionId = 'session-123', summary = 'Existing repo session' },
          },
          live = {
            { sessionId = 'live-456', summary = 'Live repo session', live = true },
          },
        },
          nil,
          200
      end
      return nil, 'unexpected path: ' .. tostring(path), 404
    end

    agent.open_chat()
    input.open_input_window()

    local prefix = vim.fn.prompt_getprompt(agent.state.input_bufnr)
    vim.api.nvim_set_current_win(agent.state.input_winid)

    local function completion_words(command_text, cursor_col)
      vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. command_text })
      vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, cursor_col or #(prefix .. command_text) })
      return vim.tbl_map(function(item)
        return item.word
      end, input._input_omnifunc(0, ''))
    end

    local agent_words = completion_words('/agent ')
    local inline_agent_words = completion_words('use /agent to do code review', #(prefix .. 'use /agent'))
    local skill_words = completion_words('/skills ')
    local model_words = completion_words('/model ')
    local resume_words = completion_words('/resume ')
    local session_words = completion_words('/session ')
    local mcp_words = completion_words('/mcp ')
    local instruction_words = completion_words('/instructions ')

    assert_true(vim.tbl_contains(agent_words, 'Code Review Engineer'))
    assert_true(vim.tbl_contains(agent_words, 'Document Update Agent'))
    assert_true(vim.tbl_contains(agent_words, 'Go Quality Engineer'))
    assert_true(vim.tbl_contains(agent_words, 'Selene Lua Quality Engineer'))
    assert_true(vim.tbl_contains(inline_agent_words, 'Code Review Engineer'))
    assert_true(vim.tbl_contains(skill_words, '/skills nvim-integration-tests'))
    assert_true(vim.tbl_contains(skill_words, '/skills selene-check'))
    assert_true(vim.tbl_contains(model_words, '/model gpt-5.4'))
    assert_true(vim.tbl_contains(model_words, '/model claude-sonnet-4.6'))
    assert_true(vim.tbl_contains(resume_words, '/resume session-123'))
    assert_true(vim.tbl_contains(resume_words, '/resume live-456'))
    assert_true(vim.tbl_contains(session_words, '/session session-123'))
    assert_true(vim.tbl_contains(session_words, '/session live-456'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp local'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp docs'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp browser'))
    assert_true(vim.tbl_contains(instruction_words, '/instructions .github/copilot-instructions.md'))
  end)

  it('replaces the generic slash completion with agent completion when typing /agent', function()
    local original_complete = vim.fn.complete
    local original_mode = vim.fn.mode
    local completions = {}

    agent.open_chat()
    input.open_input_window()

    local prefix = vim.fn.prompt_getprompt(agent.state.input_bufnr)
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.cmd('startinsert!')
    vim.fn.mode = function()
      return 'i'
    end
    vim.fn.complete = function(col, items)
      table.insert(completions, { col = col, items = items })
    end

    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. '/' })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #(prefix .. '/') })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = agent.state.input_bufnr })
    vim.wait(50, function()
      return #completions > 0
    end)

    -- Typing "/agent" should replace the generic slash completion while the
    -- popup is already open, which is observed via CompleteChanged.
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. '/agent' })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #(prefix .. '/agent') })
    vim.api.nvim_exec_autocmds('CompleteChanged', { buffer = agent.state.input_bufnr })
    vim.wait(50, function()
      return #completions > 1
    end)
    vim.api.nvim_exec_autocmds('CompleteChanged', { buffer = agent.state.input_bufnr })

    vim.fn.complete = original_complete
    vim.fn.mode = original_mode

    assert_eq(2, #completions)
    assert_true(vim.tbl_contains(
      vim.tbl_map(function(item)
        return item.word
      end, completions[1].items),
      '/agent'
    ))
    assert_eq(#prefix + 1, completions[2].col)
    assert_true(vim.tbl_contains(
      vim.tbl_map(function(item)
        return item.word
      end, completions[2].items),
      'Code Review Engineer'
    ))
  end)

  it('replaces /agent completion text with only the selected agent name', function()
    agent.open_chat()
    input.open_input_window()

    local prefix = vim.fn.prompt_getprompt(agent.state.input_bufnr)
    local line = prefix .. '/agent Git'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local replace_start = input._input_omnifunc(1, '')
    local items = input._input_omnifunc(0, '')
    local selected
    for _, item in ipairs(items) do
      if item.word == 'Git Commit Agent' then
        selected = item.word
        break
      end
    end

    assert_eq(#prefix, replace_start)
    assert_eq('Git Commit Agent', selected)

    local replaced = line:sub(1, replace_start) .. selected .. line:sub(#line + 1)
    assert_eq(prefix .. 'Git Commit Agent', replaced)
  end)
end)

describe('checkpoint id replay', function()
  local agent
  local events
  local http
  local checkpoints
  local original_request
  local original_list

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.http'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    agent.state.session_id = 'session-123'
    http = require('copilot_agent.http')
    checkpoints = require('copilot_agent.checkpoints')
    original_request = http.request
    original_list = checkpoints.list
  end)

  after_each(function()
    http.request = original_request
    checkpoints.list = original_list
  end)

  it('reattaches checkpoint ids when session history is reloaded', function()
    local callback_err
    local callback_count

    checkpoints.list = function(session_id)
      assert_eq('session-123', session_id)
      return {
        { id = 'v001', assistant_message_id = 'assistant-1', prompt = 'first prompt' },
        { id = 'v002', assistant_message_id = 'assistant-2', prompt = 'second prompt' },
      }
    end
    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions/session-123/messages', path)
      callback({
        events = {
          { type = 'user.message', data = { content = 'first prompt' } },
          { type = 'assistant.message', data = { messageId = 'assistant-1', content = 'first reply' } },
          { type = 'user.message', data = { content = 'second prompt' } },
          { type = 'assistant.message', data = { messageId = 'assistant-2', content = 'second reply' } },
        },
      }, nil)
    end

    package.loaded['copilot_agent.events'] = nil
    events = require('copilot_agent.events')
    events.reload_session_history('session-123', function(err, count)
      callback_err = err
      callback_count = count
    end)

    assert_eq(nil, callback_err)
    assert_eq(4, callback_count)
    assert_eq('v001', agent.state.entries[1].checkpoint_id)
    assert_eq('v002', agent.state.entries[3].checkpoint_id)
    assert_eq(nil, agent.state.history_checkpoint_ids)
  end)

  it('does not randomly assign checkpoint ids when replay metadata is missing assistant message mapping', function()
    checkpoints.list = function()
      return {
        { id = 'v001' },
        { id = 'v002' },
      }
    end
    http.request = function(_, _, _, callback)
      callback({
        events = {
          { type = 'user.message', data = { content = 'first prompt' } },
          { type = 'assistant.message', data = { messageId = 'assistant-1', content = 'first reply' } },
          { type = 'user.message', data = { content = 'second prompt' } },
          { type = 'assistant.message', data = { messageId = 'assistant-2', content = 'second reply' } },
        },
      }, nil)
    end

    package.loaded['copilot_agent.events'] = nil
    events = require('copilot_agent.events')
    events.reload_session_history('session-123', function() end)

    assert_eq(nil, agent.state.entries[1].checkpoint_id)
    assert_eq(nil, agent.state.entries[3].checkpoint_id)
  end)

  it('preserves assistant block boundaries when session history is reloaded', function()
    local callback_err
    local callback_count

    checkpoints.list = function()
      return {}
    end
    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions/session-123/messages', path)
      callback({
        events = {
          { type = 'assistant.turn_start', data = {} },
          { type = 'assistant.message', data = { messageId = 'assistant-1', content = 'First rebuild note.' } },
          { type = 'assistant.turn_end', data = {} },
          { type = 'assistant.turn_start', data = {} },
          { type = 'assistant.message', data = { messageId = 'assistant-2', content = 'Second rebuild note.' } },
          { type = 'assistant.turn_end', data = {} },
          { type = 'assistant.turn_start', data = {} },
          { type = 'assistant.message', data = { messageId = 'assistant-3', content = 'Third rebuild note.' } },
          { type = 'assistant.turn_end', data = {} },
        },
      }, nil)
    end

    package.loaded['copilot_agent.events'] = nil
    events = require('copilot_agent.events')
    agent.open_chat()
    events.reload_session_history('session-123', function(err, count)
      callback_err = err
      callback_count = count
    end)

    assert_eq(nil, callback_err)
    assert_eq(9, callback_count)

    local lines = vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  First rebuild note.',
      '',
      'Assistant:',
      '  Second rebuild note.',
      '',
      'Assistant:',
      '  Third rebuild note.',
      '',
    }, { unpack(lines, #lines - 8, #lines) })
  end)

  it('rebuilds transcript activity summaries when session history is reloaded', function()
    local callback_err
    local callback_count

    checkpoints.list = function()
      return {}
    end
    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions/session-123/messages', path)
      callback({
        events = {
          { type = 'assistant.turn_start', data = {} },
          { type = 'assistant.message', data = { messageId = 'assistant-1', content = 'First rebuild note.' } },
          { type = 'assistant.intent', data = { intent = 'Inspecting activity strings' } },
          { type = 'tool.execution_start', data = { toolName = 'bash', command = 'rg', arguments = { 'activity' } } },
          { type = 'tool.execution_complete', data = {} },
          { type = 'assistant.turn_end', data = {} },
          { type = 'assistant.turn_start', data = {} },
          { type = 'assistant.message', data = { messageId = 'assistant-2', content = 'Second rebuild note.' } },
          { type = 'assistant.turn_end', data = {} },
        },
      }, nil)
    end

    package.loaded['copilot_agent.events'] = nil
    events = require('copilot_agent.events')
    agent.open_chat()
    events.reload_session_history('session-123', function(err, count)
      callback_err = err
      callback_count = count
    end)

    assert_eq(nil, callback_err)
    assert_eq(9, callback_count)

    local lines = vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false)
    assert.same({
      'Assistant:',
      '  First rebuild note.',
      '',
      'Activity: rg activity (2 items hidden)',
      '',
      'Assistant:',
      '  Second rebuild note.',
      '',
    }, { unpack(lines, #lines - 7, #lines) })
  end)

  it('rebuilds tool execution output details when session history is reloaded', function()
    local callback_err
    local callback_count

    checkpoints.list = function()
      return {}
    end
    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions/session-123/messages', path)
      callback({
        events = {
          { type = 'assistant.turn_start', data = {} },
          {
            type = 'tool.execution_start',
            data = {
              toolName = 'bash',
              toolCallId = 'tool-456',
              command = 'rg',
              arguments = { 'activity', 'lua' },
            },
          },
          {
            type = 'tool.execution_complete',
            data = {
              success = true,
              toolCallId = 'tool-456',
              result = {
                content = 'rg summary',
                contents = {
                  { type = 'terminal', text = 'lua/copilot_agent/events.lua:1:match' },
                  { type = 'text', text = '1 match found' },
                },
              },
            },
          },
          { type = 'assistant.turn_end', data = {} },
        },
      }, nil)
    end

    package.loaded['copilot_agent.events'] = nil
    events = require('copilot_agent.events')
    agent.open_chat()
    events.reload_session_history('session-123', function(err, count)
      callback_err = err
      callback_count = count
    end)

    assert_eq(nil, callback_err)
    assert_eq(4, callback_count)

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('activity', entry.kind)
    assert_eq('Ran bash — rg activity lua', entry.content)
    assert.same({
      kind = 'tool',
      summary = 'Ran bash — rg activity lua',
      tool_name = 'bash',
      tool_call_id = 'tool-456',
      tool_detail = 'rg activity lua',
      start_data = {
        toolName = 'bash',
        toolCallId = 'tool-456',
        command = 'rg',
        arguments = { 'activity', 'lua' },
      },
      progress_messages = {},
      complete_data = {
        success = true,
        toolCallId = 'tool-456',
        result = {
          content = 'rg summary',
          contents = {
            { type = 'terminal', text = 'lua/copilot_agent/events.lua:1:match' },
            { type = 'text', text = '1 match found' },
          },
        },
      },
      success = true,
      output_text = 'lua/copilot_agent/events.lua:1:match\n\n1 match found',
    }, entry.activity_items[1])
  end)
end)

describe('checkpoint id assignment', function()
  local agent
  local events
  local checkpoints
  local original_create

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    agent.state.session_id = 'session-123'
    agent.state.chat_busy = false
    agent.state.pending_checkpoint_ops = 0
    agent.state.pending_workspace_updates = 0
    agent.state.background_tasks = {}
    agent.state.pending_user_input = nil
    events = require('copilot_agent.events')
    checkpoints = require('copilot_agent.checkpoints')
    original_create = checkpoints.create
  end)

  after_each(function()
    checkpoints.create = original_create
  end)

  it('assigns the checkpoint id after assistant.turn_end for the active turn', function()
    local captured
    local checkpoint_callback
    agent.state.entries = {
      { kind = 'user', content = 'prompt without id yet' },
      { kind = 'assistant', content = 'final answer' },
    }
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'prompt without id yet',
      entry_index = 1,
    }

    checkpoints.create = function(session_id, prompt, callback, opts)
      captured = {
        session_id = session_id,
        prompt = prompt,
        opts = opts,
      }
      checkpoint_callback = function()
        agent.state.entries[opts.entry_index].checkpoint_id = 'v001'
        callback(nil, 'v001', 'deadbeef')
      end
    end

    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    assert_eq('📝sync', agent.statusline_busy())
    checkpoint_callback()

    assert_eq('session-123', captured.session_id)
    assert_eq('prompt without id yet', captured.prompt)
    assert_eq(1, captured.opts.entry_index)
    assert_eq('v001', agent.state.entries[1].checkpoint_id)
    assert_eq(nil, agent.state.pending_checkpoint_turn)
    assert_eq('✅ready', agent.statusline_busy())
  end)

  it('records the assistant message id with the completed turn checkpoint', function()
    local captured
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'prompt with streamed reply',
      entry_index = 1,
    }
    agent.state.entries = {
      { kind = 'user', content = 'prompt with streamed reply' },
      { kind = 'assistant', content = '' },
    }

    checkpoints.create = function(_, _, callback, opts)
      captured = opts
      callback(nil, 'v001', 'deadbeef')
    end

    events.handle_session_event({
      type = 'assistant.message',
      data = { messageId = 'assistant-42', content = 'reply' },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    assert_eq('assistant-42', captured.assistant_message_id)
  end)

  it('tracks background tasks until they complete', function()
    events.handle_session_event({
      type = 'subagent.started',
      data = {
        toolCallId = 'task-1',
        agentDisplayName = 'Document Update Agent',
      },
    })
    assert_eq('🧩1 task', agent.statusline_busy())

    events.handle_session_event({
      type = 'system.notification',
      data = {
        kind = {
          type = 'agent_idle',
          agentId = 'bg-1',
          description = 'Git Commit Agent',
        },
      },
    })
    assert_eq('🧩2 tasks', agent.statusline_busy())

    events.handle_session_event({
      type = 'subagent.completed',
      data = {
        toolCallId = 'task-1',
      },
    })
    assert_eq('🧩1 task', agent.statusline_busy())

    events.handle_session_event({
      type = 'system.notification',
      data = {
        kind = {
          type = 'agent_completed',
          agentId = 'bg-1',
        },
      },
    })
    assert_eq('✅ready', agent.statusline_busy())
  end)
end)
