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
    'CopilotAgentNewSession',
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

describe('statusline API', function()
  local agent

  before_each(function()
    package.loaded['copilot_agent'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
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

  it('statusline returns a non-empty string', function()
    local v = agent.statusline()
    assert_eq('string', type(v))
    assert_true(#v > 0)
  end)

  it('chat statusline truncates session summaries and formats timestamp session ids', function()
    local statusline = require('copilot_agent.statusline')
    local winid = vim.api.nvim_get_current_win()
    local expected_id = expected_local_session_id('nvim', 1717245296)

    agent.state.chat_winid = winid
    agent.state.session_id = 'nvim-1717245296789000000'
    agent.state.session_name = nil
    statusline.refresh_chat_statusline()
    assert_true(vim.wo[winid].statusline:find('session: ' .. expected_id, 1, true) ~= nil)

    agent.state.session_name = 'abcdefghijklmnopqrstuvwxyz0123456789'
    statusline.refresh_chat_statusline()
    assert_true(vim.wo[winid].statusline:find('session: abcdefghijklmnopqrstuvwxyz012345', 1, true) ~= nil)
    assert_true(vim.wo[winid].statusline:find('session: abcdefghijklmnopqrstuvwxyz0123456789', 1, true) == nil)
  end)
end)

describe('model state sync', function()
  local agent
  local events

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
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
      },
    })

    assert_eq('claude-opus-4.7', agent.state.current_model)
    assert_eq('claude-opus-4.7', agent.state.config.session.model)
    assert_eq('medium', agent.state.reasoning_effort)
    assert_eq('Attached session', agent.state.session_name)
    assert_eq(2, agent.state.instruction_count)
    assert_eq(1, agent.state.agent_count)
    assert_eq(3, agent.state.skill_count)
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
end)

describe('statusline config counts', function()
  local agent

  before_each(function()
    package.loaded['copilot_agent'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
  end)

  it('includes discovered instruction, agent, and skill counts', function()
    agent.state.instruction_count = 2
    agent.state.agent_count = 1
    agent.state.skill_count = 3

    local expected = '󱃕 instructions: 2 󱜙 agents: 1 󱨚 skills: 3'
    local highlighted = '󱃕 instructions: %#CopilotAgentStatuslineCount#2%* 󱜙 agents: %#CopilotAgentStatuslineCount#1%* 󱨚 skills: %#CopilotAgentStatuslineCount#3%*'

    assert_eq(expected, require('copilot_agent.statusline').statusline_config())
    assert_eq(highlighted, require('copilot_agent.statusline').statusline_config_highlighted())
    assert_true(agent.statusline():find(expected, 1, true) ~= nil)
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

    http.request = function(method, path, body, callback)
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

    vim.ui.select = function(items, opts, on_choice)
      captured = {
        items = items,
        prompt = opts.prompt,
      }
      on_choice(nil)
    end

    package.loaded['copilot_agent.session'] = nil
    local session = require('copilot_agent.session')
    session.switch_session()

    assert_eq('Switch session', captured.prompt)
    assert_eq('abcdefghijklmnopqrstuvwxyz012345 [' .. expected_id .. ']', captured.items[1])
    assert_eq('custom-id', captured.items[2])
    assert_eq('+ New session', captured.items[3])
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

describe('chat input behavior', function()
  local agent
  local input
  local original_ui_select

  before_each(function()
    vim.cmd('tabonly | only')
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.chat'] = nil
    package.loaded['copilot_agent.input'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    input = require('copilot_agent.input')
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    vim.ui.select = original_ui_select
    vim.cmd('tabonly | only')
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
end)
