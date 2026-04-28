-- Integration test: load the plugin and verify basic setup.
-- Requires headless Neovim with plugin on runtimepath.
-- Run via:  nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/integration/setup_spec.lua"
-- or the CI workflow.

-- Use plenary if available, otherwise a tiny shim.
local assert_eq, assert_true, assert_false, assert_not_nil
do
  local ok, luassert = pcall(require, 'luassert')
  if ok then
    assert_eq       = function(a, b, msg) luassert.equal(a, b, msg) end
    assert_true     = function(v, msg)    luassert.is_true(v, msg) end
    assert_false    = function(v, msg)    luassert.is_false(v, msg) end
    assert_not_nil  = function(v, msg)    luassert.is_not_nil(v, msg) end
  else
    local function fail(msg) error(msg, 3) end
    assert_eq      = function(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..' got '..tostring(a))) end end
    assert_true    = function(v, msg)    if not v  then fail(msg or 'expected true') end end
    assert_false   = function(v, msg)    if v      then fail(msg or 'expected false') end end
    assert_not_nil = function(v, msg)    if v == nil then fail(msg or 'expected non-nil') end end
  end
end

local function command_exists(name)
  return vim.fn.exists(':' .. name) == 2
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
end)
