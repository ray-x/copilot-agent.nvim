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

local function virt_line_highlight_for_text(virt_line, text)
  for _, chunk in ipairs(virt_line or {}) do
    if chunk[1] == text then
      return chunk[2]
    end
  end
  return nil
end

local function command_exists(name)
  return vim.fn.exists(':' .. name) == 2
end

local function expected_local_session_id(prefix, seconds)
  return string.format('%s-%s', prefix, os.date('%Y-%m-%dT%H:%M:%S', seconds))
end

local function expected_short_local_session_id(prefix, seconds)
  return string.format('%s-%s', prefix, os.date('%y-%m-%d', seconds))
end

local function flush_log_file_queue()
  local ok, logger = pcall(require, 'copilot_agent.log')
  if ok and type(logger.flush_pending) == 'function' then
    logger.flush_pending()
  end
end

local function wipe_copilot_test_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':t')
      if name == 'CopilotAgentChat' or name == 'copilot-agent-input' or name == 'copilot-agent-compose' or vim.startswith(name, 'copilot-agent-chat-stale-') then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
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

describe('assistant tool-call transcript filtering', function()
  local agent, events, render, state

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.render'] = nil

    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, auto_start = false, notify = false })
    events = require('copilot_agent.events')
    render = require('copilot_agent.render')
    state = require('copilot_agent.config').state
    render.clear_transcript()
    state.history_loading = false
    state.stream_line_start = 1
  end)

  after_each(function()
    if render and type(render.clear_transcript) == 'function' then
      render.clear_transcript()
    end
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.render'] = nil
  end)

  it('suppresses streamed multi_tool_use scaffolding before it reaches the transcript', function()
    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-tool-delta',
        deltaContent = 'to=multi_tool_use.parallel {"tool_uses":[{"recipient_name":"functions.report_intent"}]}',
      },
    })

    assert_eq(1, #state.entries)
    assert_eq('', state.entries[1].content)
  end)

  it('drops leaked tool-call deltas without erasing previously rendered assistant text', function()
    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-preserve-message',
        deltaContent = 'I checked the repository.',
      },
    })

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-preserve-message',
        deltaContent = 'to=multi_tool_use.parallel {"tool_uses":[{"recipient_name":"functions.report_intent"}]}',
      },
    })

    assert_eq(1, #state.entries)
    assert_eq('I checked the repository.', state.entries[1].content)
  end)

  it('clears raw tool_uses JSON when the final assistant message carries tool requests', function()
    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-tool-message',
        deltaContent = '{"tool_uses":[{"recipient_name":"functions.report_intent"}]}',
      },
    })

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-tool-message',
        toolRequests = {
          { name = 'multi_tool_use.parallel' },
        },
      },
    })

    assert_eq(1, #state.entries)
    assert_eq('', state.entries[1].content)
  end)

  it('keeps normal assistant text even when tool requests are attached', function()
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-normal-message',
        content = 'I checked the repository and applied the patch.',
        toolRequests = {
          { name = 'functions.bash' },
        },
      },
    })

    assert_eq(1, #state.entries)
    assert_eq('I checked the repository and applied the patch.', state.entries[1].content)
  end)
end)

-- Added test: verify unified-diff extraction from an edit tool activity (user-provided fixture)
describe('apply_patch extractors', function()
  it('extracts unified diff text from edit tool activity', function()
    local ap = require('copilot_agent.apply_patch')
    local activity = {
      activity_items = {
        {
          complete_data = {
            result = {
              detailedContent = [[
diff --git a/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua b/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua
index 0000000..0000000 100644
--- a/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua
+++ b/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua
@@ -101,7 +101,7 @@
     '    <C-c>           Cancel current turn',
     '    zA              Toggle Activity details',
     '    <CR>            Open the editable diff split on Activity lines',
-    '    Hover preview   Shows a read-only diff on CursorHold/CursorHoldI',
+    "    Hover preview   Toggleable read-only diff: press the configured activity hover key (default 'K') to show/hide. Set activity_hover_cursor_hold=true to use CursorHold instead.",
     '    gT              Open TODO float',
     '    [ / ]         Jump to prev/next conversation',
     '    [a / ]a        Jump to prev/next Assistant/Activity',
]],
            },
          },
          output_text = [[
diff --git a/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua b/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua
index 0000000..0000000 100644
--- a/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua
+++ b/Users/rayxu/github/ray-x/copilot-agent.nvim/lua/copilot_agent/chat.lua
@@ -101,7 +101,7 @@
     '    <C-c>           Cancel current turn',
     '    zA              Toggle Activity details',
     '    <CR>            Open the editable diff on Activity lines',
-    '    Hover preview   Shows a read-only diff on CursorHold/CursorHoldI',
+    "    Hover preview   Toggleable read-only diff: press the configured activity hover key (default 'K') to show/hide.",
     '    gT              Open TODO float',
     '    [ / ]         Jump to prev/next conversation',
     '    [a / ]a        Jump to prev/next Assistant/Activity',
]],
        },
      },
    }

    -- Validate scanning of the whole item (accept either scanning the item table, the output_text field, or the nested detailedContent)
    local item = activity.activity_items[1]
    local item_text = ap.extract_unified_patch_text(item)
      or ap.extract_unified_patch_text(item.output_text)
      or (item.complete_data and item.complete_data.result and ap.extract_unified_patch_text(item.complete_data.result.detailedContent))
    assert_true(type(item_text) == 'string' and item_text:find('diff --git', 1, true) ~= nil, 'expected unified diff in item, output_text, or nested detailedContent')
  end)
end)

describe('home path display sanitization', function()
  local agent, render, utils

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.render'] = nil
    package.loaded['copilot_agent.utils'] = nil

    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    render = require('copilot_agent.render')
    utils = require('copilot_agent.utils')
  end)

  it('replaces absolute home paths with a tilde in text', function()
    local home = os.getenv('HOME')
    if type(home) ~= 'string' or home == '' then
      return
    end
    local source = string.format('%s/work/file.lua:%s', home, home)
    assert_eq('~/work/file.lua:~', utils.tilde_home_path(source))
  end)

  it('sanitizes assistant transcript lines', function()
    local home = os.getenv('HOME')
    if type(home) ~= 'string' or home == '' then
      return
    end
    local lines = render.entry_lines({
      kind = 'assistant',
      content = 'Opened ' .. home .. '/project/main.go',
    }, 1)
    local text = table.concat(lines, '\n')
    assert_true(text:find('Opened ~/project/main.go', 1, true) ~= nil)
  end)

  it('sanitizes attachment display paths', function()
    local home = os.getenv('HOME')
    if type(home) ~= 'string' or home == '' then
      return
    end
    local lines = render.entry_lines({
      kind = 'user',
      content = 'Review this file',
      attachments = {
        { path = home .. '/notes/todo.md' },
      },
    }, 1)
    local text = table.concat(lines, '\n')
    assert_true(text:find('📎 ~/notes/todo.md', 1, true) ~= nil)
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

  it('session.replay_permission_history defaults to false', function()
    agent.setup({ auto_create_session = false })
    assert_false(agent.state.config.session.replay_permission_history)
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
    flush_log_file_queue()
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
    flush_log_file_queue()
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
    flush_log_file_queue()
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
    flush_log_file_queue()
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
    flush_log_file_queue()
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    assert_eq(1, #lines)
    assert_true(lines[1]:find('tests/integration/setup_spec.lua:' .. expected_line, 1, true) ~= nil)
    assert_true(lines[1]:find('caller metadata smoke test', 1, true) ~= nil)
  end)

  it('flushes batched logs immediately when max_entries is reached', function()
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
      service = {
        auto_start = false,
      },
      file_log_level = 'INFO',
      file_log_batch = {
        enabled = true,
        flush_interval_ms = 2000,
        max_entries = 2,
      },
    })
    local cfg = require('copilot_agent.config')
    cfg.log('batch max one', vim.log.levels.INFO)
    cfg.log('batch max two', vim.log.levels.INFO)

    vim.fn.stdpath = original_stdpath
    flush_log_file_queue()
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    local joined = table.concat(lines, '\n')
    assert_eq(2, #lines)
    assert_true(joined:find('batch max one', 1, true) ~= nil)
    assert_true(joined:find('batch max two', 1, true) ~= nil)
  end)

  it('flushes batched logs on flush interval when max_entries is not reached', function()
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
      service = {
        auto_start = false,
      },
      file_log_level = 'INFO',
      file_log_batch = {
        enabled = true,
        flush_interval_ms = 80,
        max_entries = 20,
      },
    })
    local cfg = require('copilot_agent.config')
    cfg.log('batch interval one', vim.log.levels.INFO)
    vim.wait(220)

    vim.fn.stdpath = original_stdpath
    flush_log_file_queue()
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    assert_true(#lines >= 1)
    local found = false
    for _, line in ipairs(lines) do
      if line:find('batch interval one', 1, true) ~= nil then
        found = true
        break
      end
    end
    assert_true(found)
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

    flush_log_file_queue()
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

    flush_log_file_queue()
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

    flush_log_file_queue()
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
  local original_jobstart
  local original_filereadable
  local original_executable
  local original_system
  local original_os_uname
  local temp_state_dir

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.service'] = nil
    package.loaded['copilot_agent.http'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    service = require('copilot_agent.service')
    original_stdpath = vim.fn.stdpath
    original_jobstart = vim.fn.jobstart
    original_filereadable = vim.fn.filereadable
    original_executable = vim.fn.executable
    original_system = vim.fn.system
    original_os_uname = vim.uv.os_uname
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
    vim.fn.jobstart = original_jobstart
    vim.fn.filereadable = original_filereadable
    vim.fn.executable = original_executable
    vim.fn.system = original_system
    vim.uv.os_uname = original_os_uname
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

  it('uses a detached shutdown request when the last client exits', function()
    local calls = {}
    local socket_path = temp_state_dir .. '/copilot-agent.sock'
    local addr_path = temp_state_dir .. '/copilot-agent.addr'

    vim.fn.writefile({ '' }, socket_path)
    vim.fn.writefile({ '127.0.0.1:43123' }, addr_path)

    vim.fn.executable = function(path)
      if path == agent.state.config.curl_bin then
        return 1
      end
      return original_executable(path)
    end
    vim.fn.filereadable = function(path)
      if path == socket_path then
        return 1
      end
      return original_filereadable(path)
    end
    vim.fn.jobstart = function(args, opts)
      calls[#calls + 1] = {
        args = vim.deepcopy(args),
        opts = vim.deepcopy(opts),
      }
      return 42
    end

    service.maybe_shutdown_detached_service_if_last_client({ nonblocking = true })

    assert_eq(1, #calls)
    assert_eq(1, calls[1].opts.detach)
    assert_true(vim.tbl_contains(calls[1].args, '--unix-socket'))
    assert_true(vim.tbl_contains(calls[1].args, socket_path))
    assert_true(vim.tbl_contains(calls[1].args, 'http://localhost/shutdown'))
    assert_eq('127.0.0.1:43123', service._load_service_addr())
  end)

  it('uses a TCP control endpoint on Windows', function()
    vim.uv.os_uname = function()
      return { sysname = 'Windows_NT' }
    end

    agent.state.config.service.command = { '/path/to/copilot-agent' }
    local command = service.service_command()

    assert_true(vim.tbl_contains(command, '--control-addr'))
    assert_true(vim.tbl_contains(command, '127.0.0.1:0'))
    assert_false(vim.tbl_contains(command, '--control-socket'))
  end)

  it('adds a default service log path when service logging is enabled', function()
    local original_service_command = vim.deepcopy(agent.state.config.service.command)
    local original_service_log = vim.deepcopy(agent.state.config.service.log)
    agent.state.config.service.command = { '/path/to/copilot-agent' }
    agent.state.config.service.log = {
      enabled = true,
      path = nil,
    }
    local command = service.service_command()
    agent.state.config.service.command = original_service_command
    agent.state.config.service.log = original_service_log

    assert_true(vim.tbl_contains(command, '--log-file'))
    local log_file_index
    for idx, arg in ipairs(command) do
      if arg == '--log-file' then
        log_file_index = idx
        break
      end
    end
    assert_true(log_file_index ~= nil)
    assert_true(type(command[log_file_index + 1]) == 'string')
    assert_true(command[log_file_index + 1]:find('copilot%-agent%-service%.log$', 1) ~= nil)
  end)

  it('does not add a service log path by default', function()
    local original_service_command = vim.deepcopy(agent.state.config.service.command)
    local original_service_log = vim.deepcopy(agent.state.config.service.log)
    agent.state.config.service.command = { '/path/to/copilot-agent' }
    agent.state.config.service.log = nil
    local command = service.service_command()
    agent.state.config.service.command = original_service_command
    agent.state.config.service.log = original_service_log

    assert_false(vim.tbl_contains(command, '--log-file'))
  end)

  it('does not add a service log path when service logging is disabled', function()
    local original_service_command = vim.deepcopy(agent.state.config.service.command)
    local original_service_log = vim.deepcopy(agent.state.config.service.log)
    agent.state.config.service.command = { '/path/to/copilot-agent' }
    agent.state.config.service.log = {
      enabled = false,
      path = '/tmp/ignored.log',
    }
    local command = service.service_command()
    agent.state.config.service.command = original_service_command
    agent.state.config.service.log = original_service_log

    assert_false(vim.tbl_contains(command, '--log-file'))
    assert_false(vim.tbl_contains(command, '/tmp/ignored.log'))
  end)

  it('uses the saved TCP control endpoint when shutting down on Windows', function()
    vim.uv.os_uname = function()
      return { sysname = 'Windows_NT' }
    end

    local calls = {}
    vim.fn.executable = function(path)
      if path == agent.state.config.curl_bin then
        return 1
      end
      return original_executable(path)
    end
    vim.fn.jobstart = function(args, opts)
      calls[#calls + 1] = {
        args = vim.deepcopy(args),
        opts = vim.deepcopy(opts),
      }
      return 77
    end

    service._save_control_addr('127.0.0.1:43123')
    service.maybe_shutdown_detached_service_if_last_client({ nonblocking = true })

    assert_eq(1, #calls)
    assert_eq(1, calls[1].opts.detach)
    assert_true(vim.tbl_contains(calls[1].args, 'http://127.0.0.1:43123/shutdown'))
    assert_false(vim.tbl_contains(calls[1].args, '--unix-socket'))
  end)

  it('does not hard-stop a detached service job during VimLeavePre cleanup', function()
    local calls = {}
    local original_jobstop = vim.fn.jobstop

    vim.fn.jobstop = function(job_id)
      calls[#calls + 1] = job_id
      return 1
    end

    service.stop_service()

    vim.fn.jobstop = original_jobstop

    assert_eq(0, #calls)
  end)

  it('uses the shared addr file when control discovery is unavailable', function()
    agent.state.base_url_managed = true
    agent.state.config.base_url = 'http://127.0.0.1:62569'
    vim.fn.writefile({ '127.0.0.1:49357' }, temp_state_dir .. '/copilot-agent.addr')

    local http = require('copilot_agent.http')

    assert_eq('http://127.0.0.1:49357/sessions', http.build_url('/sessions'))
    assert_eq('http://127.0.0.1:49357', agent.state.config.base_url)
  end)

  it('prefers control socket discovery over the shared addr file', function()
    local socket_path = temp_state_dir .. '/copilot-agent.sock'
    agent.state.base_url_managed = true
    agent.state.config.base_url = 'http://127.0.0.1:62569'
    vim.fn.writefile({ '' }, socket_path)
    vim.fn.writefile({ '127.0.0.1:49357' }, temp_state_dir .. '/copilot-agent.addr')

    vim.fn.filereadable = function(path)
      if path == socket_path then
        return 1
      end
      return original_filereadable(path)
    end

    vim.fn.executable = function(path)
      if path == agent.state.config.curl_bin then
        return 1
      end
      return original_executable(path)
    end

    vim.fn.system = function(_)
      return '{"serviceAddr":"127.0.0.1:50123"}\n200'
    end

    local http = require('copilot_agent.http')

    assert_eq('http://127.0.0.1:50123/sessions', http.build_url('/sessions'))
    assert_eq('http://127.0.0.1:50123', agent.state.config.base_url)
  end)
end)

describe('compaction activity events', function()
  local agent
  local events
  local render

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.render'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, auto_start = false, notify = false })
    events = require('copilot_agent.events')
    render = require('copilot_agent.render')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
  end)

  it('combines compaction start and complete into one activity when no other activity is appended', function()
    events.handle_session_event({
      type = 'session.compaction_start',
      data = {
        conversationTokens = 193236,
        systemTokens = 11800,
        toolDefinitionsTokens = 12799,
      },
    })

    events.handle_session_event({
      type = 'session.compaction_complete',
      data = {
        success = true,
        checkpointNumber = 4,
        preCompactionTokens = 156778,
        preCompactionMessagesLength = 90,
        compactionTokensUsed = {
          model = 'claude-opus-4.6',
          inputTokens = 159751,
          outputTokens = 3448,
        },
      },
    })

    assert_eq(1, #agent.state.entries)
    local entry = agent.state.entries[1]
    assert_eq('activity', entry.kind)
    assert_true(entry.content:find('Compaction completed', 1, true) ~= nil)
    assert_true(entry.content:find('checkpoint #4', 1, true) ~= nil)
    assert_true(entry.content:find('conversation', 1, true) ~= nil)
    assert_eq(2, #entry.activity_items)
    assert_eq('start', entry.activity_items[1].phase)
    assert_eq('complete', entry.activity_items[2].phase)
  end)

  it('keeps compaction complete separate when another activity is appended in between', function()
    events.handle_session_event({
      type = 'session.compaction_start',
      data = {
        conversationTokens = 193236,
      },
    })

    render.append_entry('activity', 'Refreshing session context')

    events.handle_session_event({
      type = 'session.compaction_complete',
      data = {
        success = true,
        checkpointNumber = 5,
      },
    })

    assert_eq(3, #agent.state.entries)
    assert_true(agent.state.entries[1].content:find('Compaction started', 1, true) ~= nil)
    assert_true(agent.state.entries[2].content:find('Refreshing session context', 1, true) ~= nil)
    assert_true(agent.state.entries[3].content:find('Compaction completed', 1, true) ~= nil)
    assert_eq(1, #(agent.state.entries[1].activity_items or {}))
    assert_eq('complete', (agent.state.entries[3].activity_items or {})[1].phase)
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
    'CopilotAgentFugitiveCommit',
  }

  for _, cmd in ipairs(expected_commands) do
    it(cmd .. ' is registered', function()
      assert_true(command_exists(cmd), cmd .. ' should exist')
    end)
  end
end)

describe('fugitive commit command', function()
  local agent
  local commit

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.commit'] = nil
    package.loaded['copilot_agent.http'] = nil

    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, auto_start = false, notify = false })
    commit = require('copilot_agent.commit')
  end)

  it('reuses the last assistant message when called with last', function()
    local opened

    commit._resolve_repo_root = function()
      return '/tmp/repo'
    end
    commit._open_fugitive_commit = function(repo_root, message)
      opened = { repo_root = repo_root, message = message }
      return true
    end

    agent.state.entries = {
      {
        kind = 'assistant',
        content = '```text\nfeat: add fugitive commit command\n\nRestore the missing command.\n```',
      },
    }

    commit.fugitive_commit('last')

    assert.same({
      repo_root = '/tmp/repo',
      message = 'feat: add fugitive commit command\n\nRestore the missing command.',
    }, opened)
  end)

  it('generates a commit message before opening fugitive', function()
    local opened

    commit._resolve_repo_root = function()
      return '/tmp/repo'
    end
    commit._request_generated_commit_message = function(repo_root, callback)
      assert_eq('/tmp/repo', repo_root)
      callback('feat: prefill fugitive commit', nil)
    end
    commit._open_fugitive_commit = function(repo_root, message)
      opened = { repo_root = repo_root, message = message }
      return true
    end

    commit.fugitive_commit()

    assert.same({
      repo_root = '/tmp/repo',
      message = 'feat: prefill fugitive commit',
    }, opened)
  end)

  it('uses approve-all when creating the side session for commit generation', function()
    local requests = {}

    package.loaded['copilot_agent.commit'] = nil
    package.loaded['copilot_agent.http'] = nil
    package.loaded['copilot_agent.slash'] = {
      _extract_side_session_answer = function()
        return 'feat: generated commit message', true, nil
      end,
    }

    local http = require('copilot_agent.http')
    http.request = function(method, path, body, callback)
      requests[#requests + 1] = {
        method = method,
        path = path,
        body = body,
      }
      if method == 'POST' and path == '/sessions' then
        callback({ sessionId = 'side-session' }, nil)
        return
      end
      if method == 'POST' and path == '/sessions/side-session/mode' then
        callback({}, nil)
        return
      end
      if method == 'POST' and path == '/sessions/side-session/messages' then
        callback({}, nil)
        return
      end
      if method == 'GET' and path == '/sessions/side-session/messages' then
        callback({ events = {} }, nil)
        return
      end
      if method == 'DELETE' and path == '/sessions/side-session?delete=true' then
        callback({}, nil)
        return
      end
      error('unexpected request: ' .. method .. ' ' .. path)
    end

    commit = require('copilot_agent.commit')
    commit._build_commit_prompt = function()
      return 'prompt'
    end

    local generated
    local err
    commit._request_generated_commit_message('/tmp/repo', function(message, callback_err)
      generated = message
      err = callback_err
    end)

    assert_eq(nil, err)
    assert_eq('feat: generated commit message', generated)
    assert_eq('POST', requests[1].method)
    assert_eq('/sessions', requests[1].path)
    assert_eq('approve-all', requests[1].body.permissionMode)
  end)

  it('writes the prepared message into COMMIT_EDITMSG before opening fugitive', function()
    local temp_root = vim.fn.tempname()
    local message_path = temp_root .. '/COMMIT_EDITMSG'
    local original_exists = vim.fn.exists
    local original_getcwd = vim.fn.getcwd
    local original_cmd = vim.cmd
    local captured_cmds = {}

    vim.fn.mkdir(temp_root, 'p')
    commit._commit_message_path = function()
      return message_path
    end
    vim.fn.exists = function(name)
      if name == ':Git' then
        return 2
      end
      return original_exists(name)
    end
    vim.fn.getcwd = function()
      return '/tmp/original'
    end
    vim.cmd = function(command_text)
      captured_cmds[#captured_cmds + 1] = command_text
    end

    local ok, err = commit._open_fugitive_commit('/tmp/repo', 'feat: seed commit buffer\n\nBody line')

    vim.fn.exists = original_exists
    vim.fn.getcwd = original_getcwd
    vim.cmd = original_cmd

    assert_true(ok)
    assert_eq(nil, err)
    assert.same({
      'lcd /tmp/repo',
      'Git commit --edit --verbose --cleanup=strip --file ' .. message_path,
      'lcd /tmp/original',
    }, captured_cmds)
    assert.same({ 'feat: seed commit buffer', '', 'Body line' }, vim.fn.readfile(message_path))
  end)
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
    if vim.loader then
      pcall(vim.loader.disable)
      if type(vim.loader.reset) == 'function' then
        pcall(vim.loader.reset)
      end
    end
    for key, _ in pairs(package.loaded) do
      if key:find('^copilot_agent') then
        package.loaded[key] = nil
      end
    end
    local dev_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
    table.insert(package.searchers or package.loaders, 1, function(modname)
      if modname:find('^copilot_agent') then
        local path = dev_root .. '/lua/' .. modname:gsub('%.', '/') .. '.lua'
        if vim.uv.fs_stat(path) then
          return loadfile(path)
        end
        path = dev_root .. '/lua/' .. modname:gsub('%.', '/') .. '/init.lua'
        if vim.uv.fs_stat(path) then
          return loadfile(path)
        end
      end
    end)
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

  it('uses the cold triple-arrow dashboard prompt by default', function()
    agent.open_dashboard()

    local prompt_bufnr = agent.state.dashboard_prompt_bufnr
    local arrow1 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptArrow1' })
    local arrow2 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptArrow2' })
    local arrow3 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptArrow3' })
    local ns = vim.api.nvim_get_namespaces().copilot_agent_prompt
    vim.wait(100, function()
      return #vim.api.nvim_buf_get_extmarks(prompt_bufnr, ns, 0, -1, { details = true }) > 0
    end)
    local extmarks = vim.api.nvim_buf_get_extmarks(prompt_bufnr, ns, 0, -1, { details = true })
    local virt_text = extmarks[1][4].virt_text

    assert_eq('❯', virt_text[1][1])
    assert_eq('CopilotAgentPromptArrow1', virt_text[1][2])
    assert_eq('❯', virt_text[2][1])
    assert_eq('CopilotAgentPromptArrow2', virt_text[2][2])
    assert_eq('❯', virt_text[3][1])
    assert_eq('CopilotAgentPromptArrow3', virt_text[3][2])
    assert_eq(tonumber('c678dd', 16), arrow1.fg)
    assert_eq(tonumber('a78bfa', 16), arrow2.fg)
    assert_eq(tonumber('61afef', 16), arrow3.fg)
  end)

  it('supports a warm triple-arrow dashboard prompt palette', function()
    agent.setup({
      auto_create_session = false,
      dashboard = {
        auto_open = false,
      },
      prompt = {
        style = 'warm',
      },
      service = {
        auto_start = false,
      },
    })

    agent.open_dashboard()

    local prompt_bufnr = agent.state.dashboard_prompt_bufnr
    local arrow1 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptArrow1' })
    local arrow2 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptArrow2' })
    local arrow3 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptArrow3' })
    local ns = vim.api.nvim_get_namespaces().copilot_agent_prompt
    vim.wait(100, function()
      return #vim.api.nvim_buf_get_extmarks(prompt_bufnr, ns, 0, -1, { details = true }) > 0
    end)
    local extmarks = vim.api.nvim_buf_get_extmarks(prompt_bufnr, ns, 0, -1, { details = true })
    local virt_text = extmarks[1][4].virt_text

    assert_eq('CopilotAgentPromptArrow1', virt_text[1][2])
    assert_eq('CopilotAgentPromptArrow2', virt_text[2][2])
    assert_eq('CopilotAgentPromptArrow3', virt_text[3][2])
    assert_eq(tonumber('e06c75', 16), arrow1.fg)
    assert_eq(tonumber('e5c07b', 16), arrow2.fg)
    assert_eq(tonumber('98c379', 16), arrow3.fg)
  end)

  it('wave animation: idle state fades mode chars before dim arrows', function()
    local p = require('copilot_agent.prompt')
    p.configure_highlights()
    local _, segments = p.build('🤖', 'agent', 0)
    -- segments: icon + 5 mode chars + 3 arrows + space = 10
    -- Icon has no hl
    assert_eq('🤖', segments[1].text)
    assert_eq(nil, segments[1].hl)
    assert_eq('CopilotAgentPromptWave2', segments[2].hl)
    assert_eq('CopilotAgentPromptWave3', segments[3].hl)
    assert_eq('CopilotAgentPromptWave4', segments[4].hl)
    assert_eq('CopilotAgentPromptWaveDim', segments[5].hl)
    assert_eq('CopilotAgentPromptWaveDim', segments[6].hl)
    -- All 3 arrows should also be WaveDim
    for i = 7, 9 do
      assert_eq('CopilotAgentPromptWaveDim', segments[i].hl, 'arrow ' .. (i - 6) .. ' should be dim at typed=0')
    end
  end)

  it('wave animation: first keystroke lights up first char with gradient tail', function()
    local p = require('copilot_agent.prompt')
    p.configure_highlights()
    local _, segments = p.build('🤖', 'agent', 1)
    assert_eq('CopilotAgentPromptWave1', segments[2].hl)
    assert_eq('CopilotAgentPromptWave2', segments[3].hl)
    assert_eq('CopilotAgentPromptWave3', segments[4].hl)
    assert_eq('CopilotAgentPromptWave4', segments[5].hl)
    assert_eq('CopilotAgentPromptWaveDim', segments[6].hl)
  end)

  it('wave animation: advances after the first key in 3-char steps', function()
    local p = require('copilot_agent.prompt')
    p.configure_highlights()
    local _, seg3 = p.build('🤖', 'agent', 3)
    local _, seg4 = p.build('🤖', 'agent', 4)
    assert_eq(p._wave_step_chars, 3)
    -- typed=3 still uses the first lit step.
    assert_eq('CopilotAgentPromptWave1', seg3[2].hl)
    assert_eq('CopilotAgentPromptWave2', seg3[3].hl)
    assert_eq('CopilotAgentPromptWave3', seg3[4].hl)
    assert_eq('CopilotAgentPromptWave4', seg3[5].hl)
    assert_eq('CopilotAgentPromptWaveDim', seg3[6].hl)
    -- typed=4 advances one more position.
    assert_eq('CopilotAgentPromptWave1', seg4[2].hl)
    assert_eq('CopilotAgentPromptWave1', seg4[3].hl)
    assert_eq('CopilotAgentPromptWave2', seg4[4].hl)
    assert_eq('CopilotAgentPromptWave3', seg4[5].hl)
    assert_eq('CopilotAgentPromptWave4', seg4[6].hl)
  end)

  it('wave animation: stepped typing fills mode text then lights arrows', function()
    local p = require('copilot_agent.prompt')
    p.configure_highlights()
    -- After 13 chars the 5-char mode label is fully lit and arrows start fading in.
    local _, seg13 = p.build('🤖', 'agent', 13)
    for i = 2, 6 do
      assert_eq('CopilotAgentPromptWave1', seg13[i].hl, 'mode char ' .. (i - 1) .. ' should be bright at typed=13')
    end
    assert_eq('CopilotAgentPromptWave2', seg13[7].hl) -- arrow 1
    assert_eq('CopilotAgentPromptWave3', seg13[8].hl) -- arrow 2
    assert_eq('CopilotAgentPromptWave4', seg13[9].hl) -- arrow 3

    -- After 22+ chars, arrows reach their natural palette colours.
    local _, seg22 = p.build('🤖', 'agent', 22)
    assert_eq('CopilotAgentPromptArrow1', seg22[7].hl)
    assert_eq('CopilotAgentPromptArrow2', seg22[8].hl)
    assert_eq('CopilotAgentPromptArrow3', seg22[9].hl)
  end)

  it('wave animation: no mode text (dashboard) shows arrows at palette colours', function()
    local p = require('copilot_agent.prompt')
    p.configure_highlights()
    local _, segments = p.build()
    -- No icon, no mode text → only 3 arrows + space
    assert_eq('❯', segments[1].text)
    assert_eq('CopilotAgentPromptArrow1', segments[1].hl)
    assert_eq('CopilotAgentPromptArrow2', segments[2].hl)
    assert_eq('CopilotAgentPromptArrow3', segments[3].hl)
  end)

  it('wave animation: wave recedes in stepped increments when characters are deleted', function()
    local p = require('copilot_agent.prompt')
    p.configure_highlights()
    local _, seg4 = p.build('', 'plan', 4)
    local _, seg1 = p.build('', 'plan', 1)
    -- At typed=4 the wave has only advanced to the second character.
    assert_eq('CopilotAgentPromptWave1', seg4[1].hl) -- p
    assert_eq('CopilotAgentPromptWave1', seg4[2].hl) -- l
    assert_eq('CopilotAgentPromptWave2', seg4[3].hl) -- a
    assert_eq('CopilotAgentPromptWave3', seg4[4].hl) -- n

    assert_eq('CopilotAgentPromptWave1', seg1[1].hl) -- p (bright)
    assert_eq('CopilotAgentPromptWave2', seg1[2].hl) -- l (gradient)
    assert_eq('CopilotAgentPromptWave3', seg1[3].hl) -- a (gradient)
    assert_eq('CopilotAgentPromptWave4', seg1[4].hl) -- n (gradient)
  end)

  it('wave highlight groups are configured for cold palette', function()
    local p = require('copilot_agent.prompt')
    p.configure_highlights()
    local w1 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptWave1' })
    local w2 = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptWave2' })
    local wdim = vim.api.nvim_get_hl(0, { name = 'CopilotAgentPromptWaveDim' })
    assert_eq(tonumber('c678dd', 16), w1.fg)
    assert_eq(tonumber('9256c7', 16), w2.fg)
    assert_eq(tonumber('462878', 16), wdim.fg)
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
      statusline = {
        enabled = true,
      },
      chat = {
        reasoning = {
          enabled = true,
          max_lines = 3,
        },
      },
      service = {
        auto_start = false,
      },
    })
  end)

  after_each(function()
    agent.state.chat_busy = false
    agent.state.pending_checkpoint_ops = 0
    agent.state.pending_workspace_updates = 0
    agent.state.background_tasks = {}
    agent.state.pending_user_input = nil
    pcall(vim.cmd, 'tabonly | only')
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

  it('sanitizes percent signs and control bytes before writing statuslines', function()
    local statusline = require('copilot_agent.statusline')
    local original_columns = vim.o.columns
    local original_laststatus = vim.o.laststatus
    vim.o.columns = 240
    vim.o.laststatus = 3
    local ok, err = pcall(function()
      agent.open_chat()

      agent.state.active_tool = 'bash 100% done\0 now'
      agent.state.current_intent = 'plan\nnext\tstep'

      local exported = agent.statusline()
      assert_true(exported:find('100%% done  now', 1, true) ~= nil)
      assert_true(exported:find('plan next step', 1, true) ~= nil)
      assert_true(exported:find('\0', 1, true) == nil)

      local refreshed, refresh_err = pcall(statusline.refresh_chat_statusline)
      assert_true(refreshed, refresh_err)

      local assigned = vim.wo[agent.state.chat_winid].statusline
      assert_true(assigned:find('100%% done  now', 1, true) ~= nil)
      assert_true(assigned:find('plan next step', 1, true) ~= nil)
      assert_true(assigned:find('\0', 1, true) == nil)
    end)
    vim.o.columns = original_columns
    vim.o.laststatus = original_laststatus
    assert_true(ok, err)
  end)

  it('preserves highlight markers in local statuslines', function()
    local input = require('copilot_agent.input')
    local statusline = require('copilot_agent.statusline')
    local original_columns = vim.o.columns
    local original_laststatus = vim.o.laststatus
    vim.o.columns = 240
    vim.o.laststatus = 3

    local ok, err = pcall(function()
      agent.open_chat()
      input.open_input_window()

      agent.state.instruction_count = 1
      agent.state.agent_count = 5
      statusline.refresh_chat_statusline()
      statusline.refresh_input_statusline()

      local highlighted = '%#CopilotAgentStatuslineCount#1%*'
      local raw = '#CopilotAgentStatuslineCount#1*'
      assert_true(vim.wo[agent.state.chat_winid].statusline:find(highlighted, 1, true) ~= nil)
      assert_true(vim.wo[agent.state.chat_winid].statusline:find(raw, 1, true) == nil)
      assert_true(vim.wo[agent.state.input_winid].statusline:find(highlighted, 1, true) ~= nil)
      assert_true(vim.wo[agent.state.input_winid].statusline:find(raw, 1, true) == nil)
    end)

    vim.o.columns = original_columns
    vim.o.laststatus = original_laststatus
    assert_true(ok, err)
  end)

  it('chat and input statuslines show responsive session labels and formatted ids', function()
    local input = require('copilot_agent.input')
    local statusline = require('copilot_agent.statusline')
    local original_laststatus = vim.o.laststatus
    local expected_id = '#' .. expected_local_session_id('nvim', 1717245296):gsub('T', ' ', 1)
    local expected_short_id = '#' .. expected_short_local_session_id('nvim', 1717245296)
    local original_get_width = vim.api.nvim_win_get_width
    local widths = {}
    agent.open_chat()
    input.open_input_window()
    local chat_winid = agent.state.chat_winid
    local input_winid = agent.state.input_winid

    agent.state.session_id = 'nvim-1717245296789000000'
    agent.state.session_name = nil
    vim.o.laststatus = 1
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
    assert_true(vim.wo[chat_winid].statusline:find('session: [' .. expected_short_id .. ']', 1, true) ~= nil)
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
    vim.o.laststatus = original_laststatus
  end)
end)

describe('statusline plugin config', function()
  after_each(function()
    pcall(vim.cmd, 'tabonly | only')
  end)

  it('supports selecting statusline components', function()
    package.loaded['copilot_agent'] = nil
    local agent = require('copilot_agent')
    local input = require('copilot_agent.input')
    local original_columns = vim.o.columns
    local original_laststatus = vim.o.laststatus
    agent.setup({
      auto_create_session = false,
      statusline = {
        enabled = true,
        components = {
          mode = true,
          permission = false,
          busy = true,
          session = true,
          model = false,
          tool = false,
          intent = false,
          context = false,
          config = false,
          attachments = false,
          help = false,
        },
      },
      service = {
        auto_start = true,
      },
    })

    local statusline = require('copilot_agent.statusline')
    agent.open_chat()
    input.open_input_window()
    local chat_winid = agent.state.chat_winid
    local input_winid = agent.state.input_winid

    vim.o.columns = 200
    vim.o.laststatus = 3
    agent.state.session_id = 'nvim-1717245296789000000'

    statusline.refresh_chat_statusline()
    statusline.refresh_input_statusline()

    assert_true(vim.wo[chat_winid].statusline:find('session: [', 1, true) ~= nil)
    assert_true(vim.wo[chat_winid].statusline:find('✅ready', 1, true) ~= nil)
    assert_true(vim.wo[chat_winid].statusline:find('✅approve-all', 1, true) == nil)
    assert_true(vim.wo[chat_winid].statusline:find('󱃕', 1, true) == nil)
    assert_true(vim.wo[input_winid].statusline:find('(g? for help)', 1, true) == nil)
    assert_true(vim.wo[input_winid].statusline:find('✅ready', 1, true) ~= nil)
    assert_true(agent.statusline():find('󱃕', 1, true) == nil)
    assert_true(agent.statusline():find('✅ready', 1, true) ~= nil)

    vim.o.columns = original_columns
    vim.o.laststatus = original_laststatus
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
      statusline = {
        enabled = true,
      },
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

  it('tracks assistant usage metrics and appends quota remaining to the statusline context', function()
    agent.state.context_tokens = 145411
    agent.state.context_limit = 200000

    events.handle_session_event({
      type = 'assistant.usage',
      data = {
        model = 'gpt-5.4',
        cost = 1,
        duration = 3019,
        inputTokens = 145411,
        outputTokens = 86,
        cacheReadTokens = 145280,
        quotaSnapshots = {
          premium_interactions = {
            entitlementRequests = 300,
            isUnlimitedEntitlement = false,
            overage = 194.8,
            overageAllowedWithExhaustedQuota = true,
            remainingPercentage = 0,
            resetDate = '2026-06-01T00:00:00Z',
            usageAllowedWithExhaustedQuota = true,
            usedRequests = 300,
          },
          chat = {
            entitlementRequests = -1,
            isUnlimitedEntitlement = true,
            overage = 0,
            overageAllowedWithExhaustedQuota = false,
            remainingPercentage = 100,
            resetDate = '2026-06-01T00:00:00Z',
            usageAllowedWithExhaustedQuota = false,
            usedRequests = 0,
          },
        },
      },
    })

    local usage = agent.state.last_assistant_usage
    assert_not_nil(usage)
    assert_eq('gpt-5.4', usage.model)
    assert_eq(145411, usage.input_tokens)
    assert_eq(86, usage.output_tokens)
    assert_eq(194.8, usage.overage)
    assert_eq(0, usage.remaining_percentage)
    assert_eq('premium_interactions', usage.primary_quota.id)
    assert_eq(0, usage.primary_quota.remaining_percentage)
    assert_eq('📊145k/200k 💳premium 0%', require('copilot_agent.statusline').statusline_context())
    assert_eq('📊145k/200k 💳premium 0%', agent.statusline_context())
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

  it('clears the reasoning preview when the host aborts the current turn', function()
    agent.state.session_id = 'session-123'
    agent.open_chat()

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-aborted-turn',
        deltaContent = 'step one\nstep two',
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)
    assert_true(agent.get_reasoning().active)

    events.handle_host_event('host.turn_aborted', {
      data = {
        sessionId = 'session-123',
      },
    })

    vim.wait(200)

    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
    assert_false(agent.get_reasoning().active)
    assert_eq('', agent.get_reasoning().text)
    assert_false(agent.state.chat_busy)

    local lines = table.concat(vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false), '\n')
    assert_true(lines:find('Turn cancelled', 1, true) ~= nil)
  end)

  it('styles markdown-like spans inside reasoning overlay virtual text', function()
    agent.open_chat()
    local original_width = vim.api.nvim_win_get_width(agent.state.chat_winid)
    vim.api.nvim_win_set_width(agent.state.chat_winid, 120)

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-markup-reasoning',
        deltaContent = [[**bold** *italic* `code` 'single' "double"]],
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    assert_eq([[  Reasoning: **bold** *italic* `code` 'single' "double"]], virt_line_text(virt_lines[1]))
    assert_eq('CopilotAgentOverlayStrong', virt_line_highlight_for_text(virt_lines[1], '**bold**'))
    assert_eq('CopilotAgentOverlayEmphasis', virt_line_highlight_for_text(virt_lines[1], '*italic*'))
    assert_eq('CopilotAgentOverlayCode', virt_line_highlight_for_text(virt_lines[1], '`code`'))
    assert_eq('CopilotAgentOverlayQuoted', virt_line_highlight_for_text(virt_lines[1], "'single'"))
    assert_eq('CopilotAgentOverlayQuoted', virt_line_highlight_for_text(virt_lines[1], '"double"'))
    vim.api.nvim_win_set_width(agent.state.chat_winid, original_width)
  end)

  it('styles markdown-like spans inside tool activity overlay virtual text', function()
    agent.open_chat()
    local original_width = vim.api.nvim_win_get_width(agent.state.chat_winid)
    vim.api.nvim_win_set_width(agent.state.chat_winid, 120)

    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'printf',
        arguments = { '**bold**', '*italic*', '`code`', "'single'", '"double"' },
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    assert_eq([[  Activity: 🔧 bash — printf **bold** *italic* `code` 'single' "double"]], virt_line_text(virt_lines[1]))
    assert_eq('CopilotAgentOverlayStrong', virt_line_highlight_for_text(virt_lines[1], '**bold**'))
    assert_eq('CopilotAgentOverlayEmphasis', virt_line_highlight_for_text(virt_lines[1], '*italic*'))
    assert_eq('CopilotAgentOverlayCode', virt_line_highlight_for_text(virt_lines[1], '`code`'))
    assert_eq('CopilotAgentOverlayQuoted', virt_line_highlight_for_text(virt_lines[1], "'single'"))
    assert_eq('CopilotAgentOverlayQuoted', virt_line_highlight_for_text(virt_lines[1], '"double"'))
    vim.api.nvim_win_set_width(agent.state.chat_winid, original_width)
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

  it('wraps long reasoning virtual text to the chat window width', function()
    agent.open_chat()
    local original_width = vim.api.nvim_win_get_width(agent.state.chat_winid)
    vim.api.nvim_win_set_width(agent.state.chat_winid, 28)

    local long_reasoning = 'this reasoning line should wrap neatly inside the overlay gutter'
    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'assistant-reasoning-wrap',
        deltaContent = long_reasoning,
      },
    })

    vim.wait(200)

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)
    local reconstructed = {}
    for idx, line in ipairs(preview) do
      if idx == 1 then
        reconstructed[#reconstructed + 1] = line:sub(#'Reasoning: ' + 1)
      else
        reconstructed[#reconstructed + 1] = line
      end
    end

    assert_true(#preview >= 2)
    assert_true(preview[1]:find('Reasoning: ', 1, true) == 1)
    assert_eq(long_reasoning, table.concat(reconstructed, ' '))
    vim.api.nvim_win_set_width(agent.state.chat_winid, original_width)
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

  it('shows postToolUse output in activity virtual text only after the hook completes', function()
    agent.open_chat()

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'status', '--short' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })
    events.handle_session_event({
      type = 'hook.start',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-1',
        input = {
          toolName = 'bash',
          toolArgs = {
            command = 'git',
            args = { 'status', '--short' },
          },
          toolResult = 'M README.md\nM lua/copilot_agent/events.lua',
        },
      },
    })

    vim.wait(200)

    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)
    assert_eq('Activity: 🔧 bash — git status --short', preview[1])
    assert_eq(nil, preview[2])

    events.handle_session_event({
      type = 'hook.end',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-1',
        success = true,
        output = {},
      },
    })

    vim.wait(200)

    extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    virt_lines = extmarks[1][4].virt_lines or {}
    preview = trimmed_virt_lines(virt_lines)
    assert_eq('Activity: 🔧 bash — git status --short', preview[1])
    assert_eq('M README.md', preview[2])
    assert_eq('M lua/copilot_agent/events.lua', preview[3])
  end)

  it('prefers modified postToolUse output over the raw tool result in activity virtual text', function()
    agent.open_chat()

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'status', '--short' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })
    events.handle_session_event({
      type = 'hook.start',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-2',
        input = {
          toolName = 'bash',
          toolArgs = {
            command = 'git',
            args = { 'status', '--short' },
          },
          toolResult = 'secret-token',
        },
      },
    })
    events.handle_session_event({
      type = 'hook.end',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-2',
        success = true,
        output = {
          modifiedResult = '[REDACTED]',
          additionalContext = 'Sensitive output redacted.',
        },
      },
    })

    vim.wait(200)

    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)
    local joined = table.concat(preview, '\n')
    assert_eq('Activity: 🔧 bash — git status --short', preview[1])
    assert_eq('[REDACTED]', preview[2])
    assert_eq('Sensitive output redacted.', preview[3])
    assert_true(joined:find('secret-token', 1, true) == nil)
  end)

  it('keeps only the newest postToolUse result lines in the activity overlay', function()
    agent.open_chat()

    local original_max_lines = agent.state.config.chat.reasoning.max_lines
    agent.state.config.chat.reasoning.max_lines = 4
    local ok, err = pcall(function()
      local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
      events.handle_session_event({
        type = 'tool.execution_start',
        data = {
          toolName = 'bash',
          command = 'git',
          arguments = { 'status', '--short' },
        },
      })
      events.handle_session_event({
        type = 'tool.execution_complete',
        data = {},
      })
      events.handle_session_event({
        type = 'hook.start',
        data = {
          hookType = 'postToolUse',
          hookInvocationId = 'hook-post-tool-use-3',
          input = {
            toolName = 'bash',
            toolArgs = {
              command = 'git',
              args = { 'status', '--short' },
            },
            toolResult = 'one\ntwo\nthree\nfour\nfive',
          },
        },
      })
      events.handle_session_event({
        type = 'hook.end',
        data = {
          hookType = 'postToolUse',
          hookInvocationId = 'hook-post-tool-use-3',
          success = true,
          output = {},
        },
      })

      vim.wait(200)

      local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
      assert_eq(1, #extmarks)

      local virt_lines = extmarks[1][4].virt_lines or {}
      local preview = trimmed_virt_lines(virt_lines)
      assert_eq('Activity: 🔧 bash — git status --short', preview[1])
      assert_eq('three', preview[2])
      assert_eq('four', preview[3])
      assert_eq('five', preview[4])
      assert_eq(nil, preview[5])
    end)
    agent.state.config.chat.reasoning.max_lines = original_max_lines
    if not ok then
      error(err)
    end
  end)

  it('shows structured toolResult session logs before textResultForLlm and rolls older lines out', function()
    agent.open_chat()

    local original_max_lines = agent.state.config.chat.reasoning.max_lines
    agent.state.config.chat.reasoning.max_lines = 4
    local ok, err = pcall(function()
      local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
      events.handle_session_event({
        type = 'tool.execution_start',
        data = {
          toolName = 'bash',
          command = 'git',
          arguments = { 'status', '--short' },
        },
      })
      events.handle_session_event({
        type = 'tool.execution_complete',
        data = {},
      })
      events.handle_session_event({
        type = 'hook.start',
        data = {
          hookType = 'postToolUse',
          hookInvocationId = 'hook-post-tool-use-structured-toolresult',
          input = {
            toolName = 'bash',
            toolArgs = {
              command = 'git',
              args = { 'status', '--short' },
            },
            toolResult = {
              resultType = 'success',
              data = {
                sessionLog = { 'one', 'two', 'three' },
                textResultForLlm = 'final answer',
              },
            },
          },
        },
      })
      events.handle_session_event({
        type = 'hook.end',
        data = {
          hookType = 'postToolUse',
          hookInvocationId = 'hook-post-tool-use-structured-toolresult',
          success = true,
          output = {},
        },
      })

      vim.wait(200)

      local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
      assert_eq(1, #extmarks)

      local virt_lines = extmarks[1][4].virt_lines or {}
      local preview = trimmed_virt_lines(virt_lines)
      assert_eq('Activity: 🔧 bash — git status --short', preview[1])
      assert_eq('two', preview[2])
      assert_eq('three', preview[3])
      assert_eq('final answer', preview[4])
      assert_eq(nil, preview[5])
    end)
    agent.state.config.chat.reasoning.max_lines = original_max_lines
    if not ok then
      error(err)
    end
  end)

  it('shows textResultForLlm when structured toolResult has no sessionLog', function()
    agent.open_chat()

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'status', '--short' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })
    events.handle_session_event({
      type = 'hook.start',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-text-result-only',
        input = {
          toolName = 'bash',
          toolArgs = {
            command = 'git',
            args = { 'status', '--short' },
          },
          toolResult = {
            resultType = 'success',
            data = {
              textResultForLlm = 'llm-only answer',
            },
          },
        },
      },
    })
    events.handle_session_event({
      type = 'hook.end',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-text-result-only',
        success = true,
        output = {},
      },
    })

    vim.wait(200)

    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)
    assert_eq('Activity: 🔧 bash — git status --short', preview[1])
    assert_eq('llm-only answer', preview[2])
    assert_eq(nil, preview[3])
  end)

  it('shows nothing for structured toolResult objects without sessionLog or textResultForLlm', function()
    agent.open_chat()

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        command = 'git',
        arguments = { 'status', '--short' },
      },
    })
    events.handle_session_event({
      type = 'tool.execution_complete',
      data = {},
    })
    events.handle_session_event({
      type = 'hook.start',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-empty-structured-result',
        input = {
          toolName = 'bash',
          toolArgs = {
            command = 'git',
            args = { 'status', '--short' },
          },
          toolResult = {
            resultType = 'error',
            data = {
              ignored = 'metadata only',
            },
          },
        },
      },
    })
    events.handle_session_event({
      type = 'hook.end',
      data = {
        hookType = 'postToolUse',
        hookInvocationId = 'hook-post-tool-use-empty-structured-result',
        success = true,
        output = {},
      },
    })

    vim.wait(200)

    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    local virt_lines = extmarks[1][4].virt_lines or {}
    local preview = trimmed_virt_lines(virt_lines)
    assert_eq('Activity: 🔧 bash — git status --short', preview[1])
    assert_eq(nil, preview[2])
  end)

  it('unwraps nested postToolUse result wrappers instead of showing inspect braces', function()
    agent.open_chat()

    local original_max_lines = agent.state.config.chat.reasoning.max_lines
    agent.state.config.chat.reasoning.max_lines = 4
    local ok, err = pcall(function()
      local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
      events.handle_session_event({
        type = 'tool.execution_start',
        data = {
          toolName = 'bash',
          command = 'git',
          arguments = { 'status', '--short' },
        },
      })
      events.handle_session_event({
        type = 'tool.execution_complete',
        data = {},
      })
      events.handle_session_event({
        type = 'hook.start',
        data = {
          hookType = 'postToolUse',
          hookInvocationId = 'hook-post-tool-use-nested-wrapper',
          input = {
            toolName = 'bash',
            toolArgs = {
              command = 'git',
              args = { 'status', '--short' },
            },
            toolResult = 'raw tool output',
          },
        },
      })
      events.handle_session_event({
        type = 'hook.end',
        data = {
          hookType = 'postToolUse',
          hookInvocationId = 'hook-post-tool-use-nested-wrapper',
          success = true,
          output = {
            modifiedResult = {
              wrapper = {
                output = { 'one', 'two', 'three', 'four', 'five' },
              },
            },
          },
        },
      })

      vim.wait(200)

      local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
      assert_eq(1, #extmarks)

      local virt_lines = extmarks[1][4].virt_lines or {}
      local preview = trimmed_virt_lines(virt_lines)
      local joined = table.concat(preview, '\n')
      assert_eq('Activity: 🔧 bash — git status --short', preview[1])
      assert_eq('three', preview[2])
      assert_eq('four', preview[3])
      assert_eq('five', preview[4])
      assert_eq(nil, preview[5])
      assert_true(joined:find('}', 1, true) == nil)
      assert_true(joined:find('"', 1, true) == nil)
    end)
    agent.state.config.chat.reasoning.max_lines = original_max_lines
    if not ok then
      error(err)
    end
  end)

  it('clears shell activity when a new assistant turn starts before execution completes', function()
    agent.open_chat()

    local ns = vim.api.nvim_get_namespaces().copilot_agent_reasoning
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'bash',
        toolCallId = 'tool-stale-overlay',
      },
    })

    vim.wait(200)

    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.chat_bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #extmarks)

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })

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

  it('defers chat buffer updates until history replay completes', function()
    local render = require('copilot_agent.render')
    render.clear_transcript()
    agent.open_chat()
    render.render_chat()

    local bufnr = agent.state.chat_bufnr
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    agent.state.history_loading = true
    local idx = render.append_entry('assistant', 'history replay line')
    local during = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert_eq(1, idx)
    assert.same(before, during)
    assert_eq('history replay line', agent.state.entries[idx].content)

    agent.state.history_loading = false
    render.render_chat()

    local after = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    assert_true(after:find('history replay line', 1, true) ~= nil)
  end)

  it('filters permission history replay by default and allows opting back in', function()
    local original_jobstart = vim.fn.jobstart
    local original_jobstop = vim.fn.jobstop
    local original_replay_permission_history = agent.state.config.session.replay_permission_history
    local original_history_loading = agent.state.history_loading
    local started = {}

    vim.fn.jobstart = function(args, opts)
      started[#started + 1] = { args = args, opts = opts }
      return #started
    end
    vim.fn.jobstop = function()
      return 1
    end

    events.start_event_stream('session-default')
    assert_true(started[1].args[6]:find('history=true', 1, true) ~= nil)
    assert_true(started[1].args[6]:find('replay_permission_history=true', 1, true) == nil)

    agent.state.events_job_id = nil
    agent.state.config.session.replay_permission_history = true
    events.start_event_stream('session-permissions')
    assert_true(started[2].args[6]:find('replay_permission_history=true', 1, true) ~= nil)

    vim.fn.jobstart = original_jobstart
    vim.fn.jobstop = original_jobstop
    agent.state.config.session.replay_permission_history = original_replay_permission_history
    agent.state.history_loading = original_history_loading
    agent.state.events_job_id = nil
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
      file_log_level = 'TRACE',
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
    flush_log_file_queue()
    local lines = vim.fn.readfile(temp_log_dir .. '/copilot_agent.log')
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('reasoning_delta received', 1, true) ~= nil)
    assert_true(joined:find('reasoning delta appended', 1, true) ~= nil)
    assert_true(joined:find('reasoning preview cleared (turn end)', 1, true) ~= nil)
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
    flush_log_file_queue()
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
    assert_true(info.topline > before.topline)
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

  it('keeps manual view stable while overlay virtual text updates when follow is paused', function()
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

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'overlay-scroll-message',
        deltaContent = 'one\ntwo\nthree',
      },
    })

    vim.wait(500)

    local view = vim.fn.getwininfo(winid)[1]
    assert_true(view.topline >= 1)

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'overlay-scroll-message',
        deltaContent = '\nfour\nfive',
      },
    })
    vim.wait(200)

    local streamed_view = vim.fn.getwininfo(winid)[1]
    assert_eq(view.topline, streamed_view.topline)
  end)

  it('clears reasoning overlay extmarks after assistant output starts', function()
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

    events.handle_session_event({
      type = 'assistant.reasoning_delta',
      data = {
        messageId = 'reasoning-restore',
        deltaContent = 'one\ntwo\nthree',
      },
    })

    vim.wait(500)

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

    extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert_eq(0, #extmarks)
  end)
end)

describe('model picker', function()
  local model
  local original_ui_select
  local original_defer_fn

  before_each(function()
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent.http'] = nil
    package.loaded['copilot_agent.log'] = nil
    package.loaded['copilot_agent.model'] = nil
    package.loaded['copilot_agent.render'] = nil
    package.loaded['copilot_agent.service'] = nil
    package.loaded['copilot_agent.statusline'] = nil
    package.loaded['copilot_agent.utils'] = nil

    original_ui_select = vim.ui.select
    original_defer_fn = vim.defer_fn
    local dev_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
    table.insert(package.searchers or package.loaders, 1, function(modname)
      if modname:find('^copilot_agent') then
        local path = dev_root .. '/lua/' .. modname:gsub('%.', '/') .. '.lua'
        if vim.uv.fs_stat(path) then
          return loadfile(path)
        end
        path = dev_root .. '/lua/' .. modname:gsub('%.', '/') .. '/init.lua'
        if vim.uv.fs_stat(path) then
          return loadfile(path)
        end
      end
    end)
    model = require('copilot_agent.model')
  end)

  after_each(function()
    vim.ui.select = original_ui_select
    vim.defer_fn = original_defer_fn
  end)

  it('defers the reasoning effort picker until after the model picker closes', function()
    local prompts = {}
    local deferred = {}
    local applied

    model.fetch_models = function(callback)
      callback({
        {
          id = 'gpt-5.5',
          name = 'GPT-5.5 Thinking',
          label = 'GPT-5.5 Thinking (gpt-5.5)',
          supports_reasoning = true,
          supported_efforts = { 'low', 'medium', 'high' },
          default_effort = 'medium',
        },
      }, nil)
    end

    model.apply_model = function(selected_model, callback, opts)
      applied = {
        model = selected_model,
        reasoning_effort = opts and opts.reasoning_effort or nil,
      }
      if callback then
        callback(selected_model, nil)
      end
    end

    vim.defer_fn = function(callback, ms)
      deferred[#deferred + 1] = { callback = callback, ms = ms }
    end

    vim.ui.select = function(items, opts, on_choice)
      prompts[#prompts + 1] = opts.prompt
      if opts.prompt == 'Select Copilot model' then
        on_choice(items[1])
        return
      end
      on_choice(items[2])
    end

    model.select_model()

    assert_eq(0, #prompts)
    assert_eq(1, #deferred)
    assert_eq(20, deferred[1].ms)

    deferred[1].callback()

    assert_eq(1, #prompts)
    assert_eq('Select Copilot model', prompts[1])
    assert_eq(2, #deferred)
    assert_eq(20, deferred[2].ms)

    deferred[2].callback()

    assert_eq(2, #prompts)
    assert_eq('Reasoning effort for GPT-5.5 Thinking', prompts[2])
    assert_not_nil(applied)
    assert_eq('gpt-5.5', applied.model)
    assert_eq('medium', applied.reasoning_effort)
  end)

  it('defers the top-level model picker so popup providers can reopen reliably', function()
    local prompts = {}
    local deferred
    local deferred_ms

    model.fetch_models = function(callback)
      callback({
        {
          id = 'gpt-5.4',
          name = 'GPT-5.4',
          label = 'GPT-5.4 (gpt-5.4)',
          supports_reasoning = false,
        },
      }, nil)
    end

    vim.defer_fn = function(callback, ms)
      deferred = callback
      deferred_ms = ms
    end

    vim.ui.select = function(_, opts, on_choice)
      prompts[#prompts + 1] = opts.prompt
      on_choice(nil)
    end

    model.select_model()

    assert_eq(0, #prompts)
    assert_not_nil(deferred)
    assert_eq(20, deferred_ms)

    deferred()

    assert_eq(1, #prompts)
    assert_eq('Select Copilot model', prompts[1])
  end)
end)

describe('statusline config counts', function()
  local agent

  before_each(function()
    package.loaded['copilot_agent'] = nil
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      statusline = {
        enabled = true,
      },
      service = {
        auto_start = true,
      },
    })
  end)

  it('uses responsive labels for discovered instruction, agent, skill, and MCP counts', function()
    local original_laststatus = vim.o.laststatus
    local original_winwidth = vim.fn.winwidth
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
    vim.o.laststatus = 1
    vim.fn.winwidth = function(winid)
      if winid == 0 then
        return 200
      end
      return original_winwidth(winid)
    end
    assert_true(agent.statusline():find(large, 1, true) ~= nil)
    vim.o.laststatus = original_laststatus
    vim.fn.winwidth = original_winwidth
  end)

  it('uses editor columns when laststatus is 2', function()
    local statusline = require('copilot_agent.statusline')
    local original_laststatus = vim.o.laststatus
    local original_columns = vim.o.columns
    local original_winwidth = vim.fn.winwidth

    agent.state.instruction_count = 2
    agent.state.agent_count = 1
    agent.state.skill_count = 3
    agent.state.mcp_count = 4
    agent.state.current_model = 'claude-opus-4.7'
    agent.state.reasoning_effort = 'high'
    agent.state.current_intent = 'Running a very long shell command in a narrow split'

    vim.fn.winwidth = function(winid)
      if winid == 0 then
        return 80
      end
      return original_winwidth(winid)
    end

    vim.o.columns = 200
    vim.o.laststatus = 2
    local columns_statusline = statusline.statusline_component()

    vim.fn.winwidth = function(winid)
      if winid == 0 then
        return 200
      end
      return original_winwidth(winid)
    end
    vim.o.laststatus = 1
    local wide_window_statusline = statusline.statusline_component()

    assert_eq(wide_window_statusline, columns_statusline)

    vim.fn.winwidth = original_winwidth
    vim.o.columns = original_columns
    vim.o.laststatus = original_laststatus
  end)

  it('uses editor columns for the exported global statusline API', function()
    local statusline = require('copilot_agent.statusline')
    local original_laststatus = vim.o.laststatus
    local original_columns = vim.o.columns
    local original_winwidth = vim.fn.winwidth

    agent.state.instruction_count = 2
    agent.state.agent_count = 1
    agent.state.skill_count = 3
    agent.state.mcp_count = 4
    agent.state.current_model = 'claude-opus-4.7'
    agent.state.reasoning_effort = 'high'
    agent.state.current_intent = 'Running a very long shell command in a narrow split'

    vim.fn.winwidth = function(winid)
      if winid == 0 then
        return 80
      end
      return original_winwidth(winid)
    end

    vim.o.columns = 200
    vim.o.laststatus = 3
    local global_statusline = statusline.statusline_component()

    vim.fn.winwidth = function(winid)
      if winid == 0 then
        return 200
      end
      return original_winwidth(winid)
    end
    vim.o.laststatus = 1
    local wide_window_statusline = statusline.statusline_component()

    assert_eq(wide_window_statusline, global_statusline)

    vim.fn.winwidth = original_winwidth
    vim.o.columns = original_columns
    vim.o.laststatus = original_laststatus
  end)

  it('refreshes chat statusline from editor columns when laststatus is 3', function()
    local statusline = require('copilot_agent.statusline')
    local original_laststatus = vim.o.laststatus
    local original_columns = vim.o.columns
    local original_get_width = vim.api.nvim_win_get_width
    local widths = {}

    agent.open_chat()
    local chat_winid = agent.state.chat_winid

    agent.state.session_id = 'nvim-1717245296789000000'
    agent.state.session_name = 'abcdefghijklmnopqrstuvwxyz0123456789'

    widths[chat_winid] = 80
    vim.api.nvim_win_get_width = function(winid)
      return widths[winid] or original_get_width(winid)
    end

    vim.o.columns = 200
    vim.o.laststatus = 3
    statusline.refresh_chat_statusline()
    local wide_columns_statusline = vim.wo[chat_winid].statusline

    widths[chat_winid] = 40
    statusline.refresh_chat_statusline()
    local resized_split_statusline = vim.wo[chat_winid].statusline
    assert_eq(wide_columns_statusline, resized_split_statusline)

    vim.o.columns = 120
    statusline.refresh_chat_statusline()
    local smaller_columns_statusline = vim.wo[chat_winid].statusline
    assert_true(smaller_columns_statusline ~= resized_split_statusline)

    vim.api.nvim_win_get_width = original_get_width
    vim.o.columns = original_columns
    vim.o.laststatus = original_laststatus
  end)

  it('uses winwidth(0) when laststatus is 1', function()
    local statusline = require('copilot_agent.statusline')
    local original_laststatus = vim.o.laststatus
    local original_columns = vim.o.columns
    local original_winwidth = vim.fn.winwidth

    agent.state.instruction_count = 2
    agent.state.agent_count = 1
    agent.state.skill_count = 3
    agent.state.mcp_count = 4
    agent.state.current_model = 'claude-opus-4.7'
    agent.state.reasoning_effort = 'high'
    agent.state.current_intent = 'Running a very long shell command in a narrow split'

    vim.o.columns = 200
    vim.o.laststatus = 1
    vim.fn.winwidth = function(winid)
      if winid == 0 then
        return 80
      end
      return original_winwidth(winid)
    end
    local narrow_window_statusline = statusline.statusline_component()

    vim.fn.winwidth = function(winid)
      if winid == 0 then
        return 200
      end
      return original_winwidth(winid)
    end
    local wide_window_statusline = statusline.statusline_component()

    assert_true(narrow_window_statusline ~= wide_window_statusline)

    vim.fn.winwidth = original_winwidth
    vim.o.columns = original_columns
    vim.o.laststatus = original_laststatus
  end)

  it('resolves the moved chat window before computing chat statusline width', function()
    local statusline = require('copilot_agent.statusline')
    agent.open_chat()

    local stale_chat_win = agent.state.chat_winid
    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.cmd('leftabove vnew')
    local moved_chat_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(moved_chat_win, agent.state.chat_bufnr)
    vim.api.nvim_win_set_buf(stale_chat_win, source_buf)
    agent.state.chat_winid = stale_chat_win

    local original_get_width = vim.api.nvim_win_get_width
    local stale_width_used = false
    vim.api.nvim_win_get_width = function(winid)
      if winid == stale_chat_win then
        stale_width_used = true
      end
      return original_get_width(winid)
    end

    statusline.refresh_chat_statusline()

    vim.api.nvim_win_get_width = original_get_width

    assert_eq(moved_chat_win, agent.state.chat_winid)
    assert_false(stale_width_used)
  end)
end)

describe('workspace file reload', function()
  local agent
  local events
  local original_notify
  local original_confirm
  local original_eventignore
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
    original_eventignore = vim.o.eventignore
    vim.o.eventignore = 'BufEnter,FileType'
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

  local function open_file(path)
    vim.cmd('noautocmd edit ' .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    events.remember_buffer_disk_state(bufnr)
    return bufnr
  end

  local function open_split(path)
    vim.cmd('noautocmd vsplit ' .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    events.remember_buffer_disk_state(bufnr)
    return bufnr
  end

  local function focus_buffer(bufnr)
    vim.cmd('noautocmd buffer ' .. bufnr)
    events.remember_buffer_disk_state(bufnr)
  end

  after_each(function()
    vim.notify = original_notify
    vim.fn.confirm = original_confirm
    vim.o.eventignore = original_eventignore
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

  it('prompts before reloading a modified buffer updated by the plugin', function()
    local bufnr = open_file(temp_file)
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
    local bufnr_one = open_file(temp_file)
    local bufnr_two = open_split(temp_file_two)
    focus_buffer(bufnr_one)

    vim.fn.writefile({ 'local other = 2', 'print(other)', 'return other' }, temp_file_two)
    vim.api.nvim_exec_autocmds('FocusGained', {})
    vim.wait(100)

    local lines = vim.api.nvim_buf_get_lines(bufnr_two, 0, -1, false)
    assert_eq('local other = 2', lines[1])
    assert_eq('print(other)', lines[2])
  end)

  it('reloads clean visible buffers during sweeps with edit instead of checktime', function()
    local bufnr = open_file(temp_file)
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
    local bufnr = open_file(temp_file)
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
    local bufnr = open_file(temp_file)

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
    local bufnr = open_file(temp_file)

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
    local bufnr_one = open_file(temp_file)
    local bufnr_two = open_split(temp_file_two)
    focus_buffer(bufnr_one)

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
    local bufnr = open_file(temp_file_two)
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
    agent.setup({
      auto_create_session = false,
      service = {
        auto_start = false,
      },
    })
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
    local expected_path = require('copilot_agent.utils').tilde_home_path(path)

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

    assert_eq('Allow: Read ' .. expected_path, captured.prompt)
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
    local original_columns = vim.o.columns
    local system_cmd
    local system_input

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
    vim.o.columns = original_columns

    assert_eq('delta', system_cmd[1])
    assert_true(vim.tbl_contains(system_cmd, '--paging=never'))
    assert_true(vim.tbl_contains(system_cmd, '--side-by-side'))
    assert_true(system_input:find('--- a/tmp/one.lua', 1, true) ~= nil)

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
  local original_recover_after_service_restart

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
    original_recover_after_service_restart = session.recover_after_service_restart
  end)

  after_each(function()
    service.ensure_service_live = original_ensure_service_live
    session.resume_session = original_resume_session
    session.recover_after_service_restart = original_recover_after_service_restart
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

  it('reattaches to the project when the restarted service no longer has the old session', function()
    local ensured = 0
    local resumed_session_id
    local recovered_session_id

    service.ensure_service_live = function(callback)
      ensured = ensured + 1
      callback(nil)
    end
    session.resume_session = function(session_id, callback, opts)
      resumed_session_id = session_id
      assert_true(opts.suppress_error_ui)
      callback(nil, 'resume session: failed to resume session: JSON-RPC Error -32603: Request session.resume failed with message: Session not found: ' .. session_id)
    end
    session.recover_after_service_restart = function(session_id, callback)
      recovered_session_id = session_id
      if callback then
        callback(session_id, nil)
      end
    end

    events._handle_event_stream_exit('session-123', 18, 'curl: (18) transfer closed with outstanding read data remaining')

    assert_eq(1, ensured)
    assert_eq('session-123', resumed_session_id)
    assert_eq('session-123', recovered_session_id)
    assert_eq('system', agent.state.entries[#agent.state.entries].kind)
    assert_eq('Event stream disconnected. Reconnecting...', agent.state.entries[#agent.state.entries].content)
    assert_eq(nil, agent.state.event_stream_recovery_session_id)
  end)

  it('skips stream recovery while Neovim is shutting down', function()
    local ensured = 0
    agent.state.shutting_down = true

    service.ensure_service_live = function(callback)
      ensured = ensured + 1
      callback(nil)
    end

    events._handle_event_stream_exit('session-123', 18, 'curl: (18) transfer closed with outstanding read data remaining')

    assert_eq(0, ensured)
    assert_eq(0, #agent.state.entries)
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

  it('keeps polling when a tool-using side turn only has a planning preamble so far', function()
    local answer, done, err = slash._extract_side_session_answer({
      { Type = 'assistant.turn_start' },
      { Type = 'assistant.message_delta', Data = { DeltaContent = "I'll inspect the staged state first." } },
      { Type = 'tool.execution_start', Data = { toolName = 'bash' } },
      { Type = 'assistant.turn_end' },
    })

    assert_eq("I'll inspect the staged state first.", answer)
    assert_false(done)
    assert_eq(nil, err)
  end)

  it('shows the side answer for /ask from message history', function()
    local result_buf

    vim.api.nvim_open_win = function(buf, enter, config)
      result_buf = buf
      return original_open_win(buf, enter, config)
    end

    http.request = function(method, path, _body, callback)
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

    http.request = function(method, path, _body, callback)
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

    http.request = function(method, path, _body, callback)
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
  local original_undo

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
    original_undo = checkpoints.undo
  end)

  after_each(function()
    checkpoints.rewind = original_rewind
    checkpoints.undo = original_undo
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

  it('queues restore context for the next prompt after /rewind', function()
    checkpoints.rewind = function(_, checkpoint_id, callback)
      assert_eq('v004', checkpoint_id)
      callback(nil, {
        previous_head = '9999999999999999999999999999999999999999',
        target = {
          id = 'v004',
          commit = '4444444444444444444444444444444444444444',
          prompt_summary = 'add a slash command list',
        },
        reverted = {
          {
            id = 'v006',
            commit = '6666666666666666666666666666666666666666',
            prompt_summary = 'add a slash command list',
            assistant_summary = 'updated slash command list output and tests',
          },
          {
            id = 'v005',
            commit = '5555555555555555555555555555555555555555',
            prompt_summary = 'add a slash command remove',
            assistant_summary = 'added /remove handling and docs',
          },
        },
      })
    end

    assert_true(slash.execute('/rewind v004'))

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('system', entry.kind)
    assert_true(entry.content:find('Command: /rewind v004', 1, true) ~= nil)
    assert_true(entry.content:find('Target checkpoint git hash: 4444444444444444444444444444444444444444', 1, true) ~= nil)
    assert_true(entry.content:find('v006', 1, true) ~= nil)
    assert_true(entry.content:find('v005', 1, true) ~= nil)
    assert_true(entry.content:find('git diff', 1, true) ~= nil)
    assert_eq('session-123', agent.state.pending_session_context.session_id)
    assert_eq(entry.content, agent.state.pending_session_context.text)
  end)

  it('queues restore context for the next prompt after /undo', function()
    checkpoints.undo = function(_, callback)
      callback(nil, {
        target = {
          id = 'v006',
          commit = '6666666666666666666666666666666666666666',
          prompt_summary = 'latest checkpoint',
        },
        reverted = {},
      })
    end

    assert_true(slash.execute('/undo'))

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq('system', entry.kind)
    assert_true(entry.content:find('Command: /undo', 1, true) ~= nil)
    assert_true(entry.content:find('Target checkpoint: v006', 1, true) ~= nil)
    assert_true(entry.content:find('Reverted checkpoints: none', 1, true) ~= nil)
    assert_true(entry.content:find('next prompt sent to Copilot', 1, true) ~= nil)
    assert_eq(entry.content, agent.state.pending_session_context.text)
  end)
end)

describe('restore context prompt injection', function()
  local agent
  local chat
  local http
  local session
  local original_request
  local original_with_session

  before_each(function()
    pcall(vim.cmd, 'tabonly | only')
    wipe_copilot_test_buffers()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.chat'] = nil
    package.loaded['copilot_agent.http'] = nil
    package.loaded['copilot_agent.session'] = nil
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      notify = false,
      chat = {
        render_markdown = false,
      },
    })
    agent.state.session_id = 'session-123'
    chat = require('copilot_agent.chat')
    http = require('copilot_agent.http')
    session = require('copilot_agent.session')
    original_request = http.request
    original_with_session = session.with_session
  end)

  after_each(function()
    http.request = original_request
    session.with_session = original_with_session
    wipe_copilot_test_buffers()
    pcall(vim.cmd, 'tabonly | only')
  end)

  it('injects queued restore context into the next session prompt without changing the user transcript entry', function()
    local captured_body

    agent.state.pending_session_context = {
      session_id = 'session-123',
      text = table.concat({
        'Checkpoint restore context for the next Copilot turn:',
        '- Command: /rewind v004',
        '- Target checkpoint git hash: 4444444444444444444444444444444444444444',
      }, '\n'),
    }

    session.with_session = function(callback)
      callback('session-123', nil)
    end
    http.request = function(method, path, body, callback)
      if method == 'POST' and path == '/sessions/session-123/messages' then
        captured_body = body
      end
      callback({}, nil)
    end

    package.loaded['copilot_agent.chat'] = nil
    chat = require('copilot_agent.chat')
    chat.ask('Please continue from here')

    assert_not_nil(captured_body)
    assert_true(captured_body.prompt:find('Checkpoint restore context for the next Copilot turn:', 1, true) ~= nil)
    assert_true(captured_body.prompt:find('Current user request:\nPlease continue from here', 1, true) ~= nil)
    assert_eq('Please continue from here', agent.state.entries[#agent.state.entries].content)
    assert_eq(nil, agent.state.pending_session_context)
  end)

  it('includes attachment display names in the API payload so resumed sessions stay valid', function()
    local captured_body

    session.with_session = function(callback)
      callback('session-123', nil)
    end
    http.request = function(method, path, body, callback)
      if method == 'POST' and path == '/sessions/session-123/messages' then
        captured_body = body
      end
      callback({}, nil)
    end

    package.loaded['copilot_agent.chat'] = nil
    chat = require('copilot_agent.chat')
    chat.ask('Review these attachments', {
      attachments = {
        { type = 'file', path = '/tmp/example.lua', display = 'example.lua' },
        {
          type = 'selection',
          path = '/tmp/example.lua',
          text = 'local value = 1',
          start_line = 0,
          end_line = 0,
          display = 'selection:example.lua:1-1',
        },
      },
    })

    assert_not_nil(captured_body)
    assert_eq(2, #(captured_body.attachments or {}))
    assert_eq('example.lua', captured_body.attachments[1].displayName)
    assert_eq('selection:example.lua:1-1', captured_body.attachments[2].displayName)
  end)
end)

describe('diff command', function()
  local agent
  local slash
  local checkpoints
  local original_list
  local original_system
  local original_cmd
  local original_select
  local original_filereadable

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    agent.state.session_id = 'session-123'
    agent.state.session_working_directory = '/tmp/checkpoint-workspace'
    slash = require('copilot_agent.slash')
    checkpoints = require('copilot_agent.checkpoints')
    original_list = checkpoints.list
    original_system = vim.system
    original_cmd = vim.cmd
    original_select = vim.ui.select
    original_filereadable = vim.fn.filereadable
  end)

  after_each(function()
    checkpoints.list = original_list
    vim.system = original_system
    vim.cmd = original_cmd
    vim.ui.select = original_select
    vim.fn.filereadable = original_filereadable
  end)

  it('uses parent->checkpoint commits for /diff vNNN summaries', function()
    local captured_commands = {}

    checkpoints.list = function(session_id)
      assert_eq('session-123', session_id)
      return {
        { id = 'v001', commit = 'aaa111', prompt = 'first prompt' },
        { id = 'v002', commit = 'bbb222', prompt = 'second prompt' },
      }
    end

    vim.system = function(args, opts)
      captured_commands[#captured_commands + 1] = { args = args, cwd = opts.cwd }
      return {
        wait = function()
          if args[5] == 'show' then
            return {
              code = 0,
              stdout = 'aaa111\n',
              stderr = '',
            }
          end
          return {
            code = 0,
            stdout = 'lua/copilot_agent/init.lua | 2 +-\n1 file changed, 1 insertion(+), 1 deletion(-)\n',
            stderr = '',
          }
        end,
      }
    end

    assert_true(slash.execute('/diff v002'))

    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'show',
      '-s',
      '--format=%P',
      'bbb222',
    }, captured_commands[1].args)
    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'diff',
      '--stat',
      'aaa111',
      'bbb222',
      '--',
      '.',
    }, captured_commands[2].args)
    assert_eq('/tmp/checkpoint-workspace', captured_commands[1].cwd)
    assert_eq('/tmp/checkpoint-workspace', captured_commands[2].cwd)
    assert_eq('system', agent.state.entries[#agent.state.entries].kind)
    assert_eq('Checkpoint diff v002:\nlua/copilot_agent/init.lua | 2 +-\n1 file changed, 1 insertion(+), 1 deletion(-)', agent.state.entries[#agent.state.entries].content)
  end)

  it('uses latest checkpoint parent->checkpoint commits for /diff with no args', function()
    local captured_commands = {}

    checkpoints.list = function(session_id)
      assert_eq('session-123', session_id)
      return {
        { id = 'v001', commit = 'aaa111', prompt = 'first prompt' },
        { id = 'v002', commit = 'bbb222', prompt = 'second prompt' },
        { id = 'v003', commit = 'ccc333', prompt = 'third prompt' },
      }
    end

    vim.system = function(args, opts)
      captured_commands[#captured_commands + 1] = { args = args, cwd = opts.cwd }
      return {
        wait = function()
          if args[5] == 'show' then
            return {
              code = 0,
              stdout = 'bbb222\n',
              stderr = '',
            }
          end
          return {
            code = 0,
            stdout = 'lua/copilot_agent/slash.lua | 3 ++-\n1 file changed, 2 insertions(+), 1 deletion(-)\n',
            stderr = '',
          }
        end,
      }
    end

    assert_true(slash.execute('/diff'))

    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'show',
      '-s',
      '--format=%P',
      'ccc333',
    }, captured_commands[1].args)
    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'diff',
      '--stat',
      'bbb222',
      'ccc333',
      '--',
      '.',
    }, captured_commands[2].args)
    assert_eq('/tmp/checkpoint-workspace', captured_commands[1].cwd)
    assert_eq('/tmp/checkpoint-workspace', captured_commands[2].cwd)
    assert_eq('system', agent.state.entries[#agent.state.entries].kind)
    assert_eq('Checkpoint diff v003:\nlua/copilot_agent/slash.lua | 3 ++-\n1 file changed, 2 insertions(+), 1 deletion(-)', agent.state.entries[#agent.state.entries].content)
  end)

  it('opens Diffview when /diff is given --difftool Diffview', function()
    local captured_cmds = {}

    checkpoints.list = function(session_id)
      assert_eq('session-123', session_id)
      return {
        { id = 'v001', commit = 'aaa111', prompt = 'first prompt' },
        { id = 'v002', commit = 'bbb222', prompt = 'second prompt' },
      }
    end

    vim.cmd = function(command)
      captured_cmds[#captured_cmds + 1] = command
    end

    assert_true(slash.execute('/diff v001..v002 --difftool Diffview'))

    assert.same({
      'lcd ' .. vim.fn.fnameescape(checkpoints._session_dir('session-123') .. '/repo'),
      'DiffviewOpen aaa111..bbb222',
    }, captured_cmds)
    assert_eq('system', agent.state.entries[#agent.state.entries].kind)
    assert_eq('Opened Checkpoint diff v001 -> v002 in Diffview', agent.state.entries[#agent.state.entries].content)
  end)

  it('opens CodeDiff against a temporary checkpoint worktree', function()
    local captured_cmds = {}
    local system_commands = {}

    checkpoints.list = function(session_id)
      assert_eq('session-123', session_id)
      return {
        { id = 'v001', commit = 'aaa111', prompt = 'first prompt' },
        { id = 'v002', commit = 'bbb222', prompt = 'second prompt' },
      }
    end

    vim.system = function(args, opts)
      system_commands[#system_commands + 1] = { args = args, cwd = opts.cwd }
      return {
        wait = function()
          if args[5] == 'diff' and args[6] == '--name-only' then
            return {
              code = 0,
              stdout = 'lua/copilot_agent/slash.lua\n',
              stderr = '',
            }
          end
          return {
            code = 0,
            stdout = '',
            stderr = '',
          }
        end,
      }
    end

    vim.ui.select = function(items, _, on_choice)
      on_choice(items[1])
    end

    vim.fn.filereadable = function()
      return 1
    end

    vim.cmd = function(command)
      captured_cmds[#captured_cmds + 1] = command
    end

    assert_true(slash.execute('/diff --difftool CodeDiff v001..v002'))

    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'diff',
      '--name-only',
      'aaa111',
      'bbb222',
      '--',
      '.',
    }, system_commands[1].args)
    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'cat-file',
      '-e',
      'bbb222:lua/copilot_agent/slash.lua',
    }, system_commands[2].args)
    assert.same({
      'git',
      '-C',
      checkpoints._session_dir('session-123') .. '/repo',
      'worktree',
      'add',
      '--detach',
      '--force',
    }, {
      system_commands[3].args[1],
      system_commands[3].args[2],
      system_commands[3].args[3],
      system_commands[3].args[4],
      system_commands[3].args[5],
      system_commands[3].args[6],
      system_commands[3].args[7],
    })
    assert_eq('bbb222', system_commands[3].args[9])
    assert_true(system_commands[3].args[8]:find('/copilot%-agent/difftool%-worktrees/', 1) ~= nil)
    assert.same({
      'tabnew ' .. vim.fn.fnameescape(system_commands[3].args[8] .. '/lua/copilot_agent/slash.lua'),
      'CodeDiff file aaa111',
    }, captured_cmds)
    assert_eq('system', agent.state.entries[#agent.state.entries].kind)
    assert_eq('Opened Checkpoint diff v001 -> v002 in CodeDiff', agent.state.entries[#agent.state.entries].content)
  end)

  it('opens native vim diff when /diff is given -difftool with no name', function()
    local captured_commands = {}
    local native_cmds = {}

    checkpoints.list = function(session_id)
      assert_eq('session-123', session_id)
      return {
        { id = 'v001', commit = 'aaa111', prompt = 'first prompt' },
        { id = 'v002', commit = 'bbb222', prompt = 'second prompt' },
      }
    end

    vim.system = function(args, opts)
      captured_commands[#captured_commands + 1] = { args = args, cwd = opts.cwd }
      return {
        wait = function()
          if args[5] == 'diff' and args[6] == '--name-only' then
            return {
              code = 0,
              stdout = 'lua/copilot_agent/slash.lua\n',
              stderr = '',
            }
          end
          return {
            code = 0,
            stdout = 'local before = true\n',
            stderr = '',
          }
        end,
      }
    end

    vim.ui.select = function(items, _, on_choice)
      on_choice(items[1])
    end

    vim.cmd = function(command)
      native_cmds[#native_cmds + 1] = command
    end

    assert_true(slash.execute('/diff -difftool v001..v002'))

    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'diff',
      '--name-only',
      'aaa111',
      'bbb222',
      '--',
      '.',
    }, captured_commands[1].args)
    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'show',
      'aaa111:lua/copilot_agent/slash.lua',
    }, captured_commands[2].args)
    assert.same({
      'git',
      '--no-pager',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'show',
      'bbb222:lua/copilot_agent/slash.lua',
    }, captured_commands[3].args)
    assert.same({
      'tabnew',
      'diffthis',
      'vnew',
      'diffthis',
    }, native_cmds)
    assert_eq('/tmp/checkpoint-workspace', captured_commands[1].cwd)
    assert_eq('/tmp/checkpoint-workspace', captured_commands[2].cwd)
    assert_eq('/tmp/checkpoint-workspace', captured_commands[3].cwd)
    assert_eq('system', agent.state.entries[#agent.state.entries].kind)
    assert_eq('Opened Checkpoint diff v001 -> v002 in native vim diff', agent.state.entries[#agent.state.entries].content)
  end)
end)

describe('share command', function()
  local agent
  local slash
  local render
  local original_ui_select
  local original_ui_input
  local original_entry_lines
  local export_path

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.render'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    agent.state.entries = {
      { kind = 'user', content = 'share this session' },
      { kind = 'assistant', content = 'done' },
    }
    slash = require('copilot_agent.slash')
    render = require('copilot_agent.render')
    original_ui_select = vim.ui.select
    original_ui_input = vim.ui.input
    original_entry_lines = render.entry_lines
    export_path = vim.fn.tempname() .. '.md'
  end)

  after_each(function()
    vim.ui.select = original_ui_select
    vim.ui.input = original_ui_input
    render.entry_lines = original_entry_lines
    pcall(os.remove, export_path)
  end)

  it('exports markdown through the interactive /share picker flow', function()
    vim.ui.select = function(items, opts, on_choice)
      assert_eq('Share session as', opts.prompt)
      on_choice(items[1], 1)
    end
    vim.ui.input = function(opts, on_input)
      assert_true(opts.default:sub(-3) == '.md')
      on_input(export_path)
    end

    assert_true(slash.execute('/share'))
    vim.wait(100, function()
      return vim.fn.filereadable(export_path) == 1
    end)

    assert_eq(1, vim.fn.filereadable(export_path))
    local lines = vim.fn.readfile(export_path)
    assert_true(vim.tbl_contains(lines, 'User:'))
    assert_true(vim.tbl_contains(lines, '  share this session'))
    assert_true(vim.tbl_contains(lines, 'Assistant:'))
    assert_true(vim.tbl_contains(lines, '  done'))
  end)

  it('falls back to raw transcript formatting when render.entry_lines fails during /share', function()
    render.entry_lines = function()
      error('boom')
    end
    agent.state.entries = {
      { kind = 'user', content = 'share this session', attachments = { { type = 'file', path = '/tmp/example.lua' } } },
      { kind = 'assistant', content = 'done' },
    }

    assert_true(slash.execute('/share markdown ' .. export_path))

    assert_eq(1, vim.fn.filereadable(export_path))
    local lines = vim.fn.readfile(export_path)
    assert_true(vim.tbl_contains(lines, 'User:'))
    assert_true(vim.tbl_contains(lines, '  share this session'))
    assert_true(vim.tbl_contains(lines, '  📎 /tmp/example.lua'))
    assert_true(vim.tbl_contains(lines, 'Assistant:'))
    assert_true(vim.tbl_contains(lines, '  done'))
  end)
end)

describe('session slash command', function()
  local agent
  local slash
  local http
  local session
  local checkpoints
  local session_names
  local original_request
  local original_delete_session_by_id
  local original_session_info
  local original_list_details
  local original_list_files
  local original_prune_history
  local original_session_name_get

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.http'] = nil
    package.loaded['copilot_agent.session'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    package.loaded['copilot_agent.session_names'] = nil

    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    http = require('copilot_agent.http')
    session = require('copilot_agent.session')
    checkpoints = require('copilot_agent.checkpoints')
    session_names = require('copilot_agent.session_names')

    original_request = http.request
    original_delete_session_by_id = session.delete_session_by_id
    original_session_info = checkpoints.session_info
    original_list_details = checkpoints.list_details
    original_list_files = checkpoints.list_files
    original_prune_history = checkpoints.prune_history
    original_session_name_get = session_names.get
  end)

  after_each(function()
    http.request = original_request
    session.delete_session_by_id = original_delete_session_by_id
    checkpoints.session_info = original_session_info
    checkpoints.list_details = original_list_details
    checkpoints.list_files = original_list_files
    checkpoints.prune_history = original_prune_history
    session_names.get = original_session_name_get
  end)

  it('shows session info for the active session', function()
    agent.state.session_id = 'active-session'
    agent.state.session_working_directory = '/tmp/project'

    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions/active-session', path)
      callback({
        sessionId = 'active-session',
        summary = 'Current session',
        workingDirectory = '/tmp/project',
        workspacePath = '/tmp/project',
        model = 'gpt-5.4',
        agentMode = 'plan',
        permissionMode = 'interactive',
        live = true,
        instructionCount = 2,
        agentCount = 1,
        skillCount = 3,
        mcpCount = 4,
      }, nil)
    end
    checkpoints.session_info = function(session_id)
      assert_eq('active-session', session_id)
      return {
        session_id = session_id,
        checkpoint_count = 2,
      }
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session info'))

    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session info:', 1, true) ~= nil)
    assert_true(content:find('Label: Current session [active-session]', 1, true) ~= nil)
    assert_true(content:find('Model: gpt%-5%.4') ~= nil)
    assert_true(content:find('Checkpoints: 2', 1, true) ~= nil)
  end)

  it('shows checkpoint summaries for the active session', function()
    agent.state.session_id = 'active-session'
    checkpoints.list_details = function(session_id)
      assert_eq('active-session', session_id)
      return {
        {
          id = 'v001',
          prompt_summary = 'initial prompt',
          assistant_summary = 'first reply',
          created_at = '2026-05-01T00:00:00Z',
        },
      }, {
        session_id = session_id,
        checkpoint_count = 1,
      }
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session checkpoints'))

    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session checkpoints:', 1, true) ~= nil)
    assert_true(content:find('v001', 1, true) ~= nil)
    assert_true(content:find('prompt: initial prompt', 1, true) ~= nil)
    assert_true(content:find('reply: first reply', 1, true) ~= nil)
  end)

  it('shows snapshot files for the active session', function()
    agent.state.session_id = 'active-session'
    checkpoints.list_files = function(session_id)
      assert_eq('active-session', session_id)
      return {
        'README.md',
        'lua/copilot_agent/slash.lua',
      }, nil
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session files'))

    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session files:', 1, true) ~= nil)
    assert_true(content:find('README.md', 1, true) ~= nil)
    assert_true(content:find('lua/copilot_agent/slash.lua', 1, true) ~= nil)
  end)

  it('shows context usage details through /context', function()
    agent.state.session_id = 'active-session'
    agent.state.last_assistant_usage = {
      model = 'gpt-5.4',
      cost = 1,
      input_tokens = 145411,
      output_tokens = 86,
      cache_read_tokens = 145280,
      duration_ms = 3019,
      primary_quota = {
        id = 'premium_interactions',
        display_name = 'premium',
        used_requests = 300,
        entitlement_requests = 300,
        remaining_percentage = 0,
      },
    }
    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions/active-session/context', path)
      callback({
        sessionId = 'active-session',
        available = true,
        contextWindow = {
          currentTokens = 30000,
          tokenLimit = 304000,
          promptTokenLimit = 258400,
          messagesLength = 0,
          systemTokens = 21000,
          toolDefinitionsTokens = 8700,
          systemToolsTokens = 29700,
          conversationTokens = 0,
          freeTokens = 228400,
          bufferTokens = 45600,
        },
      }, nil)
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/context'))

    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Context usage snapshot:', 1, true) ~= nil)
    assert_true(content:find('Context window: 30000 / 304000 tokens (10%)', 1, true) ~= nil)
    assert_true(content:find('System/Tools: 29700 tokens (10%)', 1, true) ~= nil)
    assert_true(content:find('Messages: 0 tokens (0%) across 0 messages', 1, true) ~= nil)
    assert_true(content:find('Free space: 228400 tokens (75%)', 1, true) ~= nil)
    assert_true(content:find('Buffer: 45600 tokens (15%)', 1, true) ~= nil)
    assert_true(content:find('Quota: premium 300/300 (0%)', 1, true) ~= nil)
    assert_true(content:find('Last usage: model=gpt-5.4', 1, true) ~= nil)
    assert_true(content:find('cache_read=145280', 1, true) ~= nil)
  end)

  it('shows expanded usage details through /usage', function()
    agent.state.session_id = 'active-session'
    agent.state.context_tokens = 145411
    agent.state.context_limit = 200000
    agent.state.last_assistant_usage = {
      model = 'gpt-5.4',
      cost = 1,
      input_tokens = 145411,
      output_tokens = 86,
      reasoning_tokens = 64,
      cache_read_tokens = 145280,
      duration_ms = 3019,
      primary_quota = {
        id = 'premium_interactions',
        display_name = 'premium',
        used_requests = 300,
        entitlement_requests = 300,
        remaining_percentage = 0,
      },
    }

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/usage'))

    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session usage snapshot:', 1, true) ~= nil)
    assert_true(content:find('Context window: 145411 / 200000 tokens', 1, true) ~= nil)
    assert_true(content:find('Quota: premium 300/300 (0%)', 1, true) ~= nil)
    assert_true(content:find('Last usage: model=gpt-5.4', 1, true) ~= nil)
    assert_true(content:find('reasoning=64', 1, true) ~= nil)
    assert_true(content:find('duration=3019ms', 1, true) ~= nil)
  end)

  it('deletes a named target session through the session slash subcommand', function()
    local deleted

    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions', path)
      callback({
        persisted = {
          {
            sessionId = 'delete-me',
            summary = 'Delete me',
            workingDirectory = '/tmp/delete-me',
          },
        },
      }, nil)
    end
    session.delete_session_by_id = function(session_id, session_record, callback)
      deleted = {
        session_id = session_id,
        session_record = session_record,
      }
      callback(nil)
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session delete delete-me'))

    assert_eq('delete-me', deleted.session_id)
    assert_eq('Delete me', deleted.session_record.summary)
  end)

  it('previews session prune candidates while skipping named and live sessions by default', function()
    local now = os.time()
    local old_timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', now - 45 * 24 * 60 * 60)
    local recent_timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', now - 5 * 24 * 60 * 60)

    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions', path)
      callback({
        persisted = {
          {
            sessionId = 'old-session',
            summary = 'Old session',
            modifiedTime = old_timestamp,
          },
          {
            sessionId = 'named-session',
            summary = 'Named session',
            modifiedTime = old_timestamp,
          },
          {
            sessionId = 'recent-session',
            summary = 'Recent session',
            modifiedTime = recent_timestamp,
          },
        },
        live = {
          {
            sessionId = 'live-session',
            summary = 'Live session',
            modifiedTime = old_timestamp,
            live = true,
          },
        },
      }, nil)
    end
    session_names.get = function(session_id)
      if session_id == 'named-session' then
        return 'Important session'
      end
      return nil
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session prune --older-than 30 --dry-run'))

    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session prune preview:', 1, true) ~= nil)
    assert_true(content:find('Candidates: 1', 1, true) ~= nil)
    assert_true(content:find('Old session %[old%-session%]') ~= nil)
    assert_true(content:find('Skipped named sessions: 1', 1, true) ~= nil)
    assert_true(content:find('Skipped live sessions: 1', 1, true) ~= nil)
    assert_true(content:find('named-session', 1, true) == nil)
  end)

  it('prunes matching saved sessions when dry-run is omitted', function()
    local now = os.time()
    local old_timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', now - 45 * 24 * 60 * 60)
    local deleted = {}

    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions', path)
      callback({
        persisted = {
          {
            sessionId = 'old-session',
            summary = 'Old session',
            modifiedTime = old_timestamp,
          },
        },
      }, nil)
    end
    session.delete_session_by_id = function(session_id, session_record, callback)
      deleted[#deleted + 1] = {
        session_id = session_id,
        summary = session_record.summary,
      }
      callback(nil)
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session prune --older-than 30'))

    assert_eq(1, #deleted)
    assert_eq('old-session', deleted[1].session_id)
    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session prune:', 1, true) ~= nil)
    assert_true(content:find('Old session %[old%-session%]') ~= nil)
  end)

  it('previews checkpoint pruning for the active session', function()
    agent.state.session_id = 'active-session'
    checkpoints.session_info = function(session_id)
      assert_eq('active-session', session_id)
      return {
        session_id = session_id,
        checkpoint_count = 5,
      }
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session prune --keep-last 2 --dry-run'))

    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session prune preview:', 1, true) ~= nil)
    assert_true(content:find('Mode: checkpoints', 1, true) ~= nil)
    assert_true(content:find('Keep last: 2', 1, true) ~= nil)
    assert_true(content:find('Would remove: 3', 1, true) ~= nil)
  end)

  it('prunes checkpoint snapshots for a target session', function()
    local prune_call

    http.request = function(method, path, _, callback)
      assert_eq('GET', method)
      assert_eq('/sessions', path)
      callback({
        persisted = {},
      }, nil)
    end
    checkpoints.session_info = function(session_id)
      if session_id == 'target-session' then
        return {
          session_id = session_id,
          checkpoint_count = 6,
        }
      end
      return nil
    end
    checkpoints.prune_history = function(session_id, keep_last)
      prune_call = {
        session_id = session_id,
        keep_last = keep_last,
      }
      return {
        removed = 4,
        kept = 2,
        first_kept = 'v005',
        last_kept = 'v006',
      }, nil
    end

    package.loaded['copilot_agent.slash'] = nil
    slash = require('copilot_agent.slash')
    assert_true(slash.execute('/session prune --keep-last 2 --session target-session'))

    assert_eq('target-session', prune_call.session_id)
    assert_eq(2, prune_call.keep_last)
    local content = agent.state.entries[#agent.state.entries].content
    assert_true(content:find('Session prune:', 1, true) ~= nil)
    assert_true(content:find('Mode: checkpoints', 1, true) ~= nil)
    assert_true(content:find('Removed: 4', 1, true) ~= nil)
    assert_true(content:find('First kept: v005', 1, true) ~= nil)
  end)
end)

describe('lsp slash command', function()
  local agent
  local slash
  local temp_workspace
  local go_buf
  local lua_buf
  local notifications
  local original_notify
  local original_buf_get_clients
  local original_get_clients
  local original_executable
  local gopls_client
  local lua_ls_client
  local helper_client

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.lsp'] = nil
    agent = require('copilot_agent')
    temp_workspace = vim.fn.tempname()
    vim.fn.mkdir(temp_workspace .. '/lua', 'p')
    vim.fn.writefile({ 'package main', 'func main() {}' }, temp_workspace .. '/main.go')
    vim.fn.writefile({ 'return {}' }, temp_workspace .. '/lua/init.lua')

    agent.setup({
      auto_create_session = false,
      notify = true,
      session = {
        working_directory = function()
          return temp_workspace
        end,
      },
    })
    agent.state.session_working_directory = temp_workspace
    slash = require('copilot_agent.slash')

    go_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(go_buf, temp_workspace .. '/main.go')
    vim.bo[go_buf].filetype = 'go'

    lua_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(lua_buf, temp_workspace .. '/lua/init.lua')
    vim.bo[lua_buf].filetype = 'lua'

    gopls_client = {
      id = 11,
      name = 'gopls',
      config = {
        cmd = { 'gopls' },
        root_dir = temp_workspace,
      },
      server_capabilities = {
        definitionProvider = true,
        referencesProvider = true,
      },
    }
    lua_ls_client = {
      id = 12,
      name = 'lua_ls',
      config = {
        cmd = { 'lua-language-server' },
        root_dir = temp_workspace,
      },
      server_capabilities = {
        definitionProvider = true,
        referencesProvider = true,
      },
    }
    helper_client = {
      id = 99,
      name = 'copilot-agent',
      config = {
        root_dir = temp_workspace,
      },
      server_capabilities = {
        definitionProvider = true,
        referencesProvider = true,
      },
    }

    notifications = {}
    original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = {
        message = message,
        level = level,
      }
    end

    original_buf_get_clients = vim.lsp.buf_get_clients
    vim.lsp.buf_get_clients = function(bufnr)
      if bufnr == go_buf then
        return { gopls_client }
      end
      if bufnr == lua_buf then
        return { lua_ls_client }
      end
      return {}
    end

    original_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(opts)
      opts = opts or {}
      if opts.name == 'copilot-agent' then
        return { helper_client }
      end
      if opts.bufnr == go_buf then
        return { gopls_client }
      end
      if opts.bufnr == lua_buf then
        return { lua_ls_client }
      end
      return { helper_client, gopls_client, lua_ls_client }
    end

    original_executable = vim.fn.executable
    vim.fn.executable = function(command)
      if command == 'gopls' or command == 'lua-language-server' then
        return 1
      end
      return original_executable(command)
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.lsp.buf_get_clients = original_buf_get_clients
    vim.lsp.get_clients = original_get_clients
    vim.fn.executable = original_executable
    vim.fn.delete(temp_workspace, 'rf')
  end)

  it('bootstraps .github/lsp.json from active project clients and opens it', function()
    local config_path = temp_workspace .. '/.github/lsp.json'

    assert_true(slash.execute('/lsp create'))

    local decoded = vim.json.decode(table.concat(vim.fn.readfile(config_path), '\n'))
    assert_eq('gopls', decoded.lspServers.gopls.command)
    assert_true(vim.tbl_isempty(decoded.lspServers.gopls.args))
    assert_eq('go', decoded.lspServers.gopls.fileExtensions['.go'])
    assert_eq('lua-language-server', decoded.lspServers.lua_ls.command)
    assert_eq('lua', decoded.lspServers.lua_ls.fileExtensions['.lua'])
    local uv = vim.uv or vim.loop
    assert_eq(
      (uv and uv.fs_realpath and uv.fs_realpath(config_path)) or vim.fn.fnamemodify(config_path, ':p'),
      (uv and uv.fs_realpath and uv.fs_realpath(vim.api.nvim_buf_get_name(0))) or vim.api.nvim_buf_get_name(0)
    )
    assert_true(notifications[#notifications].message:find('Wrote 2 project LSP servers', 1, true) ~= nil)
    assert_true(notifications[#notifications].message:find('Restart the Copilot service', 1, true) ~= nil)
  end)

  it('reports status, show, test, and help through notifications', function()
    local config_path = temp_workspace .. '/.github/lsp.json'
    vim.fn.mkdir(temp_workspace .. '/.github', 'p')
    vim.fn.writefile(
      vim.split(
        vim.json.encode({
          lspServers = {
            gopls = {
              command = 'gopls',
              args = {},
              fileExtensions = {
                ['.go'] = 'go',
              },
            },
          },
        }, { indent = '  ' }),
        '\n',
        { plain = true }
      ),
      config_path
    )

    assert_true(slash.execute('/lsp status'))
    assert_true(notifications[#notifications].message:find('LSP status', 1, true) ~= nil)
    assert_true(notifications[#notifications].message:find('gopls', 1, true) ~= nil)
    assert_true(notifications[#notifications].message:find('copilot-agent', 1, true) ~= nil)

    assert_true(slash.execute('/lsp show'))
    assert_true(notifications[#notifications].message:find('Configured LSP servers', 1, true) ~= nil)
    assert_true(notifications[#notifications].message:find('.go -> go', 1, true) ~= nil)

    assert_true(slash.execute('/lsp test'))
    assert_true(notifications[#notifications].message:find('LSP test', 1, true) ~= nil)
    assert_true(notifications[#notifications].message:find('Result: 1/1 configured server matched an active project LSP client.', 1, true) ~= nil)

    assert_true(slash.execute('/lsp help'))
    assert_true(notifications[#notifications].message:find('/lsp create', 1, true) ~= nil)
    assert_true(notifications[#notifications].message:find(':CopilotAgentLsp still starts the plugin helper LSP', 1, true) ~= nil)
  end)
end)

describe('workspace file opening avoids chat windows', function()
  local window
  local state
  local temp_file
  local temp_file_two

  before_each(function()
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent.window'] = nil
    wipe_copilot_test_buffers()
    window = require('copilot_agent.window')
    state = require('copilot_agent.config').state
    temp_file = vim.fn.tempname() .. '.lua'
    temp_file_two = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'return 1' }, temp_file)
    vim.fn.writefile({ 'return 2' }, temp_file_two)
    state.chat_bufnr = nil
    state.chat_winid = nil
    state.input_bufnr = nil
    state.input_winid = nil
    pcall(vim.cmd, 'tabonly | only')
    vim.cmd('enew')
  end)

  after_each(function()
    state.chat_bufnr = nil
    state.chat_winid = nil
    state.input_bufnr = nil
    state.input_winid = nil
    wipe_copilot_test_buffers()
    vim.fn.delete(temp_file)
    vim.fn.delete(temp_file_two)
    pcall(vim.cmd, 'tabonly | only')
  end)

  local function resolve(path)
    return vim.fn.resolve(vim.fn.fnamemodify(path, ':p'))
  end

  it('reuses the left workspace split instead of replacing the chat window', function()
    vim.cmd('noautocmd edit ' .. vim.fn.fnameescape(temp_file))
    local file_winid = vim.api.nvim_get_current_win()
    local chat_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(chat_bufnr, 'CopilotAgentChat')
    local chat_winid = vim.api.nvim_open_win(chat_bufnr, true, {
      split = 'right',
      win = file_winid,
    })
    state.chat_bufnr = chat_bufnr
    state.chat_winid = chat_winid

    local opened, err = window.open_path_safely(temp_file_two)

    assert_true(opened or err ~= nil)
    assert_eq(file_winid, vim.api.nvim_get_current_win())
    assert_eq(resolve(temp_file_two), resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(file_winid))))
    assert_eq(chat_bufnr, vim.api.nvim_win_get_buf(chat_winid))
  end)

  it('creates a split to the left of the chat column when only chat windows are present', function()
    local chat_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(chat_bufnr, 'CopilotAgentChat')
    vim.api.nvim_set_current_buf(chat_bufnr)
    local chat_winid = vim.api.nvim_get_current_win()
    state.chat_bufnr = chat_bufnr
    state.chat_winid = chat_winid

    local tree_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_bufnr].buftype = 'nofile'
    vim.api.nvim_buf_set_name(tree_bufnr, 'NvimTree_1')
    vim.api.nvim_open_win(tree_bufnr, false, {
      split = 'left',
      win = chat_winid,
    })

    local input_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(input_bufnr, 'copilot-agent-input')
    local input_winid = vim.api.nvim_open_win(input_bufnr, false, {
      split = 'below',
      win = chat_winid,
      height = 4,
    })
    state.input_bufnr = input_bufnr
    state.input_winid = input_winid

    local opened, err = window.open_path_safely(temp_file)
    local file_winid = vim.api.nvim_get_current_win()
    local file_pos = vim.api.nvim_win_get_position(file_winid)
    local chat_pos = vim.api.nvim_win_get_position(chat_winid)

    assert_true(opened or err ~= nil)
    assert_true(file_winid ~= chat_winid)
    assert_eq(resolve(temp_file), resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(file_winid))))
    assert_eq(chat_bufnr, vim.api.nvim_win_get_buf(chat_winid))
    assert_eq(input_bufnr, vim.api.nvim_win_get_buf(input_winid))
    assert_true(file_pos[2] < chat_pos[2])
  end)
end)

describe('mcp slash command', function()
  local agent
  local slash
  local session
  local temp_workspace
  local root_mcp
  local vscode_mcp
  local original_disconnect_session
  local original_resume_session

  before_each(function()
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.session'] = nil
    package.loaded['copilot_agent.service'] = nil
    package.loaded['copilot_agent.render'] = nil
    package.loaded['copilot_agent.statusline'] = nil
    agent = require('copilot_agent')
    temp_workspace = vim.fn.tempname()
    root_mcp = temp_workspace .. '/.mcp.json'
    vscode_mcp = temp_workspace .. '/.vscode/mcp.json'

    vim.fn.mkdir(temp_workspace .. '/.vscode', 'p')
    vim.fn.writefile({ '{"mcpServers":{"local":{"command":"uvx","args":["local-tool"]}}}' }, root_mcp)
    vim.fn.writefile({ '{"servers":[{"name":"browser","command":"browser-mcp"}]}' }, vscode_mcp)

    agent.setup({
      auto_create_session = false,
      notify = false,
      session = {
        working_directory = function()
          return temp_workspace
        end,
      },
    })
    agent.state.entries = {}
    agent.state.creating_session = false
    slash = require('copilot_agent.slash')
    session = require('copilot_agent.session')
    original_disconnect_session = session.disconnect_session
    original_resume_session = session.resume_session
  end)

  after_each(function()
    session.disconnect_session = original_disconnect_session
    session.resume_session = original_resume_session
    vim.fn.delete(temp_workspace, 'rf')
  end)

  it('supports show, add, disable, enable, delete, and edit actions', function()
    local original_system = vim.system
    local original_filereadable = vim.fn.filereadable
    local global_mcp = vim.fn.expand('~/.copilot/mcp-config.json')
    local mcp_list_output = [[
{
  "mcpServers": {
    "local": {
      "type": "stdio",
      "command": "/Users/rayxu/.local/bin/local-mcp",
      "args": ["--stdio"],
      "source": "workspace"
    },
    "docs": {
      "type": "stdio",
      "command": "docs-mcp",
      "source": "workspace"
    },
    "browser": {
      "type": "sse",
      "url": "https://mcp.browser.example/v1/mcp",
      "source": "plugin:ravi"
    }
  }
}
]]

    vim.system = function(args, opts)
      if args[1] == 'copilot' and args[2] == 'mcp' and args[3] == 'list' and args[4] == '--json' then
        return {
          wait = function()
            return { code = 0, stdout = mcp_list_output, stderr = '' }
          end,
        }
      end
      if args[1] == '/Users/rayxu/.local/bin/local-mcp' then
        return {
          wait = function()
            assert_true(type(opts) == 'table' and type(opts.stdin) == 'string' and opts.stdin:find('"method":"initialize"', 1, true) ~= nil)
            return { code = 0, stdout = '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}', stderr = '' }
          end,
        }
      end
      if args[1] == 'docs-mcp' then
        return {
          wait = function()
            return { code = 1, stdout = '', stderr = 'spawn docs-mcp ENOENT' }
          end,
        }
      end
      if args[1] == 'curl' and args[#args] == 'https://mcp.browser.example/v1/mcp' then
        return {
          wait = function()
            return { code = 0, stdout = '200', stderr = '' }
          end,
        }
      end
      return original_system(args, opts)
    end
    vim.fn.filereadable = function(path)
      if path == global_mcp then
        return 0
      end
      return original_filereadable(path)
    end

    local ok, err = pcall(function()
      assert_true(slash.execute('/mcp show'))
      vim.wait(20)
      local show_message = agent.state.entries[#agent.state.entries].content
      assert_true(show_message:find('MCP server check:', 1, true) ~= nil)
      assert_true(show_message:find('local', 1, true) ~= nil)
      assert_true(show_message:find('docs', 1, true) ~= nil)
      assert_true(show_message:find('browser', 1, true) ~= nil)
      assert_true(show_message:find('check: initialize responded', 1, true) ~= nil)
      assert_true(show_message:find('check: spawn docs-mcp ENOENT', 1, true) ~= nil)
      assert_true(show_message:find('check: http 200', 1, true) ~= nil)
      assert_true(show_message:lower():find('double-check the same mcp server in copilot cli', 1, true) ~= nil)

      assert_true(slash.execute('/mcp show local'))
      vim.wait(20)
      local local_message = agent.state.entries[#agent.state.entries].content
      assert_true(local_message:find('local', 1, true) ~= nil)
      assert_true(local_message:find('docs', 1, true) == nil)
      assert_true(local_message:find('browser', 1, true) == nil)
      assert_true(local_message:find('check: initialize responded', 1, true) ~= nil)

      assert_true(slash.execute('/mcp add docs docs-mcp --stdio'))
      local added = vim.json.decode(table.concat(vim.fn.readfile(root_mcp), '\n'))
      assert_eq('docs-mcp', added.mcpServers.docs.command)
      assert.same({ '--stdio' }, added.mcpServers.docs.args)

      assert_true(slash.execute('/mcp disable docs'))
      local disabled = vim.json.decode(table.concat(vim.fn.readfile(root_mcp), '\n'))
      assert_true(disabled.mcpServers.docs.disabled == true)

      assert_true(slash.execute('/mcp enable docs'))
      local enabled = vim.json.decode(table.concat(vim.fn.readfile(root_mcp), '\n'))
      assert_false(enabled.mcpServers.docs.disabled == true)

      local original_cmd = vim.cmd
      local edit_command = nil
      vim.cmd = function(command)
        edit_command = command
      end
      assert_true(slash.execute('/mcp edit docs'))
      vim.cmd = original_cmd
      assert_true(type(edit_command) == 'string' and edit_command:find('edit ', 1, true) == 1)
      assert_true(edit_command:find(vim.fn.fnameescape(root_mcp), 1, true) ~= nil)

      assert_true(slash.execute('/mcp delete docs'))
      local deleted = vim.json.decode(table.concat(vim.fn.readfile(root_mcp), '\n'))
      assert_eq(nil, deleted.mcpServers.docs)
    end)

    vim.system = original_system
    vim.fn.filereadable = original_filereadable
    assert_true(ok, err)
  end)

  it('reconnects the current session for /mcp reload', function()
    local calls = {}
    agent.state.session_id = 'session-123'
    agent.state.creating_session = false
    session.disconnect_session = function(session_id, delete_state, callback)
      calls[#calls + 1] = { kind = 'disconnect', session_id = session_id, delete_state = delete_state }
      callback(nil)
    end
    session.resume_session = function(session_id, callback)
      calls[#calls + 1] = { kind = 'resume', session_id = session_id }
      agent.state.session_id = session_id
      callback(session_id, nil)
    end

    assert_true(slash.execute('/mcp reload'))
    vim.wait(20)
    assert_eq('disconnect', calls[1].kind)
    assert_eq('session-123', calls[1].session_id)
    assert_eq(false, calls[1].delete_state)
    assert_eq('resume', calls[2].kind)
    assert_eq('session-123', calls[2].session_id)
    assert_true(agent.state.entries[#agent.state.entries].content:find('Reloaded MCP config', 1, true) ~= nil)
  end)

  it('reports when /mcp reload is called without an active session', function()
    agent.state.session_id = nil
    agent.state.creating_session = false
    assert_true(slash.execute('/mcp reload'))
    vim.wait(20)
    local saw_no_session = false
    for _, entry in ipairs(agent.state.entries) do
      if type(entry.content) == 'string' and entry.content:find('No active session', 1, true) ~= nil then
        saw_no_session = true
        break
      end
    end
    assert_true(saw_no_session)
  end)
end)

describe('tool approval slash command', function()
  local agent
  local slash
  local approvals
  local state

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent.render'] = nil
    package.loaded['copilot_agent.slash'] = nil
    package.loaded['copilot_agent.approvals'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    state = require('copilot_agent.config').state
    state.entries = {}
    slash = require('copilot_agent.slash')
    approvals = require('copilot_agent.approvals')
  end)

  it('lists remembered tool approvals for the current session', function()
    approvals.allow_tool({ toolName = 'web_search' })
    approvals.allow_tool({ toolName = 'edit' })

    assert_true(slash.execute('/list-tools'))

    local message = state.entries[#state.entries].content
    assert_true(message:find('Approved tools for this session:', 1, true) ~= nil)
    assert_true(message:find('  %- edit') ~= nil)
    assert_true(message:find('  %- web_search') ~= nil)
    assert_true(message:find('available%-tools inventory', 1) ~= nil)
  end)

  it('explains when no tool approvals have been remembered yet', function()
    assert_true(slash.execute('/list-tools'))

    local message = state.entries[#state.entries].content
    assert_true(message:find('No approved tools in this session', 1, true) ~= nil)
    assert_true(message:find('available%-tools inventory', 1) ~= nil)
  end)
end)

describe('checkpoint diff review', function()
  local agent
  local events
  local checkpoints
  local original_list
  local original_system
  local original_ui_select

  before_each(function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, notify = false })
    agent.state.session_id = 'session-123'
    agent.state.session_working_directory = '/tmp/checkpoint-workspace'
    events = require('copilot_agent.events')
    checkpoints = require('copilot_agent.checkpoints')
    original_list = checkpoints.list
    original_system = vim.system
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    checkpoints.list = original_list
    vim.system = original_system
    vim.ui.select = original_ui_select
    pcall(vim.cmd, 'tabonly | only')
  end)

  it('uses checkpoint commits for CopilotAgentDiff review', function()
    local select_call = 0
    local commands = {}

    checkpoints.list = function()
      return {
        { id = 'v001', commit = 'aaa111', prompt = 'first prompt' },
        { id = 'v002', commit = 'bbb222', prompt = 'second prompt' },
        { id = 'v003', commit = 'ccc333', prompt = 'third prompt' },
      }
    end

    vim.ui.select = function(items, _, on_choice)
      select_call = select_call + 1
      on_choice(items[1], 1)
    end

    vim.system = function(cmd, _)
      commands[#commands + 1] = cmd
      local stdout = ''
      if cmd[4] == 'diff' and cmd[5] == '--name-only' then
        stdout = 'lua/copilot_agent/init.lua\n'
      elseif cmd[4] == 'show' and cmd[5] == 'bbb222:lua/copilot_agent/init.lua' then
        stdout = 'return "before"\n'
      elseif cmd[4] == 'show' and cmd[5] == 'ccc333:lua/copilot_agent/init.lua' then
        stdout = 'return "after"\n'
      end
      return {
        wait = function()
          return {
            code = 0,
            stdout = stdout,
            stderr = '',
          }
        end,
      }
    end

    events.review_diff()

    assert_eq(3, select_call)
    assert.same({
      'git',
      '--git-dir=' .. checkpoints._session_dir('session-123') .. '/repo/.git',
      '--work-tree=/tmp/checkpoint-workspace',
      'diff',
      '--name-only',
      'bbb222',
      'ccc333',
      '--',
      '.',
    }, commands[1])
    assert_true(table.concat(commands[1], ' '):find('HEAD', 1, true) == nil)
    assert_eq('bbb222:lua/copilot_agent/init.lua', commands[2][5])
    assert_eq('ccc333:lua/copilot_agent/init.lua', commands[3][5])

    local saw_before = false
    local saw_after = false
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        if lines[1] == 'return "before"' then
          saw_before = true
        elseif lines[1] == 'return "after"' then
          saw_after = true
        end
      end
    end
    assert_true(saw_before)
    assert_true(saw_after)
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

  it('drops a corrupted saved session and creates a fresh one instead', function()
    local requests = {}
    local callback_session_id
    local callback_error
    local started_session_id
    local cwd = require('copilot_agent.service').working_directory()

    agent._ensure_chat_window = function() end
    events.start_event_stream = function(session_id)
      started_session_id = session_id
    end

    http.request = function(method, path, body, callback)
      requests[#requests + 1] = {
        method = method,
        path = path,
        body = body,
      }

      if method == 'GET' then
        assert_eq('/sessions', path)
        callback({
          persisted = {
            {
              sessionId = 'bad-session',
              summary = 'Broken session',
              workingDirectory = cwd,
            },
          },
          live = {},
        }, nil)
        return
      end

      if method == 'POST' and body and body.resume == true then
        assert_eq('/sessions', path)
        assert_eq('bad-session', body.sessionId)
        callback(
          nil,
          'resume session: failed to resume session: JSON-RPC Error -32603: Request session.resume failed with message: Session file is corrupted (line 74: ephemeral: Invalid literal value, expected true)'
        )
        return
      end

      if method == 'DELETE' then
        assert_eq('/sessions/bad-session?delete=true', path)
        callback({}, nil)
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

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.pick_or_create_session(function(session_id, err)
      callback_session_id = session_id
      callback_error = err
    end)

    assert_eq('GET', requests[1].method)
    assert_eq('POST', requests[2].method)
    assert_eq('DELETE', requests[3].method)
    assert_eq('POST', requests[4].method)
    assert_eq('fresh-session', started_session_id)
    assert_eq('fresh-session', callback_session_id)
    assert_eq(nil, callback_error)
    local saw_corrupt_notice = false
    for _, entry in ipairs(agent.state.entries) do
      if type(entry.content) == 'string' and entry.content:find('Saved session bad-session is corrupted. Creating a new session...', 1, true) ~= nil then
        saw_corrupt_notice = true
        break
      end
    end
    assert_true(saw_corrupt_notice)
  end)

  it('recovers by recreating the missing session under the same session id', function()
    local requests = {}
    local callback_session_id
    local callback_error
    local started_session_id
    local cwd = require('copilot_agent.service').working_directory()

    agent.state.session_id = 'stale-session'
    agent.state.session_name = 'Stale session'
    agent.state.session_working_directory = cwd
    agent._ensure_chat_window = function() end
    events.start_event_stream = function(session_id)
      started_session_id = session_id
    end

    http.request = function(method, path, body, callback)
      requests[#requests + 1] = {
        method = method,
        path = path,
        body = body,
      }
      assert_eq('POST', method)
      assert_eq('/sessions', path)
      assert_eq('stale-session', body.sessionId)
      assert_eq(nil, body.resume)
      callback({
        sessionId = 'stale-session',
        summary = 'Stale session',
        workingDirectory = cwd,
      }, nil)
    end

    package.loaded['copilot_agent.session'] = nil
    session = require('copilot_agent.session')
    session.recover_after_service_restart('stale-session', function(session_id, err)
      callback_session_id = session_id
      callback_error = err
    end)

    assert_eq(1, #requests)
    assert_eq('POST', requests[1].method)
    assert_eq('stale-session', started_session_id)
    assert_eq('stale-session', agent.state.session_id)
    assert_eq('stale-session', callback_session_id)
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
    package.loaded['copilot_agent.chat'] = nil
    package.loaded['copilot_agent.input'] = nil
    package.loaded['copilot_agent.window'] = nil
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
    package.loaded['copilot_agent.service'] = nil
    package.loaded['copilot_agent.render'] = nil
    package.loaded['copilot_agent.statusline'] = nil
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
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.chat'] = nil
    package.loaded['copilot_agent.session'] = nil
    package.loaded['copilot_agent.service'] = nil
    package.loaded['copilot_agent.render'] = nil
    package.loaded['copilot_agent.statusline'] = nil
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false })
    agent.state.session_id = nil
    agent.state.session_name = nil
    agent.state.creating_session = false
    agent.state.open_input_on_session_ready = false
    agent.state.pending_session_callbacks = {}
    pcall(vim.cmd, 'silent! bwipeout CopilotAgentChat')
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

  it('re-requests session activation instead of opening input when no session is active', function()
    local original_with_session = session.with_session
    local captured_opts = {}

    session.with_session = function(_, opts)
      captured_opts[#captured_opts + 1] = opts
    end

    agent.state.config.auto_create_session = true
    agent.open_chat()
    agent.state.session_id = nil
    agent.state.creating_session = false
    agent.state.pending_session_callbacks = {}
    agent.ask()

    session.with_session = original_with_session

    assert_eq(2, #captured_opts)
    assert_true(type(captured_opts[1]) == 'table')
    assert_true(captured_opts[1].open_input_on_session_ready)
    assert_true(type(captured_opts[2]) == 'table')
    assert_true(captured_opts[2].open_input_on_session_ready)
    assert_true(not (agent.state.input_winid and vim.api.nvim_win_is_valid(agent.state.input_winid)))
  end)

  it('reuses an existing chat buffer when naming a freshly created one collides', function()
    local original_list_bufs = vim.api.nvim_list_bufs
    local hidden_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(hidden_buf, 'CopilotAgentChat')

    local list_calls = 0
    vim.api.nvim_list_bufs = function()
      list_calls = list_calls + 1
      if list_calls == 1 then
        return {}
      end
      return original_list_bufs()
    end

    local ok, err = pcall(agent.open_chat)
    vim.api.nvim_list_bufs = original_list_bufs
    if not ok then
      error(err)
    end

    assert_eq(hidden_buf, agent.state.chat_bufnr)
    assert_true(vim.api.nvim_buf_is_valid(agent.state.chat_bufnr))
    pcall(vim.api.nvim_buf_delete, hidden_buf, { force = true })
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

  it('opens input immediately when a session is already active', function()
    local input = require('copilot_agent.input')
    local original_open_input_window = input.open_input_window
    local opened = false

    agent.state.session_id = 'session-123'
    input.open_input_window = function()
      opened = true
    end

    agent.ask()

    input.open_input_window = original_open_input_window

    assert_true(opened)
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
    assert_true(text:find('Hover preview', 1, true) ~= nil)
    assert_true(text:find("default 'K'", 1, true) ~= nil)
    assert_true(text:find("default 'gK'", 1, true) ~= nil)
  end)

  it('opens the help popup without depending on render.show_help', function()
    pcall(vim.cmd, 'tabonly | only')
    wipe_copilot_test_buffers()

    package.loaded['copilot_agent.chat'] = nil
    local chat = require('copilot_agent.chat')
    local before = #vim.api.nvim_list_wins()

    local ok, err = pcall(chat._show_help_popup)
    assert_true(ok, err)

    local after = #vim.api.nvim_list_wins()
    assert_eq(before + 1, after)

    local help_win = vim.api.nvim_get_current_win()
    assert_eq('editor', vim.api.nvim_win_get_config(help_win).relative)
    pcall(vim.api.nvim_win_close, help_win, true)
  end)

  it('registers g? in the chat buffer keymaps', function()
    package.loaded['copilot_agent'] = nil
    package.loaded['copilot_agent.chat'] = nil
    local agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, auto_start = false, notify = false })
    agent.open_chat()

    local keymaps = vim.api.nvim_buf_get_keymap(agent.state.chat_bufnr, 'n')
    local has_help_keymap = false
    for _, map in ipairs(keymaps) do
      if map.lhs == 'g?' then
        has_help_keymap = true
        break
      end
    end

    assert_true(has_help_keymap)
  end)
end)

describe('chat input behavior', function()
  local agent
  local input
  local http
  local original_ui_select
  local original_sync_request
  local original_vim_system
  local original_executable
  local root_mcp
  local vscode_mcp
  local root_mcp_backup
  local vscode_mcp_backup

  before_each(function()
    pcall(vim.cmd, 'tabonly | only')
    wipe_copilot_test_buffers()
    if vim.loader then
      pcall(vim.loader.disable)
      if type(vim.loader.reset) == 'function' then
        pcall(vim.loader.reset)
      end
    end
    for key, _ in pairs(package.loaded) do
      if key:find('^copilot_agent') then
        package.loaded[key] = nil
      end
    end
    agent = require('copilot_agent')
    agent.setup({
      auto_create_session = false,
      service = {
        auto_start = false,
      },
      lsp = {
        enabled = false,
      },
      chat = {
        render_markdown = false,
      },
    })
    input = require('copilot_agent.input')
    http = require('copilot_agent.http')
    original_ui_select = vim.ui.select
    original_sync_request = http.sync_request
    original_vim_system = vim.system
    original_executable = vim.fn.executable
    local cwd = require('copilot_agent.service').working_directory()
    root_mcp = cwd .. '/.mcp.json'
    vscode_mcp = cwd .. '/.vscode/mcp.json'
    root_mcp_backup = nil
    vscode_mcp_backup = nil
  end)

  after_each(function()
    vim.ui.select = original_ui_select
    http.sync_request = original_sync_request
    vim.system = original_vim_system
    vim.fn.executable = original_executable
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
    wipe_copilot_test_buffers()
  end)

  local function ensure_dev_input_module()
    local dev_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
    local dev_input_path = dev_root .. '/lua/copilot_agent/input.lua'
    if debug.getinfo(input._input_omnifunc, 'S').source == '@' .. dev_input_path then
      return
    end

    if vim.loader then
      pcall(vim.loader.disable)
      if type(vim.loader.reset) == 'function' then
        pcall(vim.loader.reset)
      end
    end
    for key, _ in pairs(package.loaded) do
      if key:find('^copilot_agent') then
        package.loaded[key] = nil
      end
    end
    table.insert(package.searchers or package.loaders, 1, function(modname)
      if modname:find('^copilot_agent') then
        local path = dev_root .. '/lua/' .. modname:gsub('%.', '/') .. '.lua'
        if vim.uv.fs_stat(path) then
          return loadfile(path)
        end
        path = dev_root .. '/lua/' .. modname:gsub('%.', '/') .. '/init.lua'
        if vim.uv.fs_stat(path) then
          return loadfile(path)
        end
      end
    end)
    agent = require('copilot_agent')
    agent.setup({ auto_create_session = false, chat = { render_markdown = false } })
    http = require('copilot_agent.http')
    input = require('copilot_agent.input')
  end

  local function stub_fd_output(lines)
    vim.fn.executable = function(bin)
      if bin == 'fd' then
        return 1
      end
      return original_executable(bin)
    end
    vim.system = function(args, opts)
      assert_eq('fd', args[1])
      assert_eq(require('copilot_agent.service').working_directory(), opts.cwd)
      return {
        wait = function()
          return {
            code = 0,
            stdout = table.concat(lines, '\n') .. '\n',
            stderr = '',
          }
        end,
      }
    end
  end

  it('prompts before closing input with unsent text', function()
    local captured

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
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

  it('registers insert-mode prompt-boundary keymaps in the input buffer', function()
    agent.open_chat()
    input.open_input_window()

    local insert_maps = vim.api.nvim_buf_get_keymap(agent.state.input_bufnr, 'i')
    local has_ctrl_w = false
    local has_ctrl_u = false
    local has_backspace = false
    local has_ctrl_h = false
    for _, map in ipairs(insert_maps) do
      if map.lhs == '<C-W>' then
        has_ctrl_w = true
      elseif map.lhs == '<C-U>' then
        has_ctrl_u = true
      elseif map.lhs == '<BS>' then
        has_backspace = true
      elseif map.lhs == '<C-H>' or map.lhs == '<C-h>' then
        has_ctrl_h = true
      end
    end

    assert_true(has_backspace)
    assert_true(has_ctrl_h)
    assert_true(has_ctrl_w)
    assert_true(has_ctrl_u)
  end)

  it('uses the triple-arrow prompt prefix in the input buffer', function()
    ensure_dev_input_module()
    agent.open_chat()
    input.open_input_window()

    local ns = vim.api.nvim_get_namespaces().copilot_agent_prompt
    vim.wait(100, function()
      return #vim.api.nvim_buf_get_extmarks(agent.state.input_bufnr, ns, 0, -1, { details = true }) > 0
    end)
    local extmarks = vim.api.nvim_buf_get_extmarks(agent.state.input_bufnr, ns, 0, -1, { details = true })
    local virt_text = extmarks[1][4].virt_text

    -- With wave animation the segments are: icon, 5 mode chars, 3 arrows, space.
    -- At idle (typed=0 in fresh buffer) the mode label fades before dim arrows.
    assert_eq('🤖', virt_text[1][1]) -- icon (no hl)
    assert_eq('a', virt_text[2][1])
    assert_eq('CopilotAgentPromptWave2', virt_text[2][2])
    assert_eq('g', virt_text[3][1])
    assert_eq('CopilotAgentPromptWave3', virt_text[3][2])
    assert_eq('e', virt_text[4][1])
    assert_eq('CopilotAgentPromptWave4', virt_text[4][2])
    -- Arrows (segments 7–9)
    assert_eq('❯', virt_text[7][1])
    assert_eq('CopilotAgentPromptWaveDim', virt_text[7][2])
    assert_eq('❯', virt_text[8][1])
    assert_eq('CopilotAgentPromptWaveDim', virt_text[8][2])
    assert_eq('❯', virt_text[9][1])
    assert_eq('CopilotAgentPromptWaveDim', virt_text[9][2])
  end)

  it('places the input cursor after the prompt prefix when opening the buffer', function()
    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    assert_eq(#prefix, vim.api.nvim_win_get_cursor(agent.state.input_winid)[2])
  end)

  it('does not let Backspace move the cursor into the prompt prefix', function()
    agent.open_chat()
    input.open_input_window()

    local bufnr = agent.state.input_bufnr
    local winid = agent.state.input_winid
    local prefix = input._input_prompt_prefix(bufnr)
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix })
    vim.api.nvim_win_set_cursor(winid, { 1, #prefix })

    local backspace_map = vim.fn.maparg('<BS>', 'i', false, true)
    assert_true(type(backspace_map.callback) == 'function')
    assert_eq('', backspace_map.callback())
    assert_eq(prefix, vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    assert_eq(#prefix, vim.api.nvim_win_get_cursor(winid)[2])
  end)

  it('does not let Ctrl-H move the cursor into the prompt prefix', function()
    agent.open_chat()
    input.open_input_window()

    local bufnr = agent.state.input_bufnr
    local winid = agent.state.input_winid
    local prefix = input._input_prompt_prefix(bufnr)
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix })
    vim.api.nvim_win_set_cursor(winid, { 1, #prefix })

    local ctrl_h_map = vim.fn.maparg('<C-h>', 'i', false, true)
    assert_true(type(ctrl_h_map.callback) == 'function')
    assert_eq('', ctrl_h_map.callback())
    assert_eq(prefix, vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    assert_eq(#prefix, vim.api.nvim_win_get_cursor(winid)[2])
  end)

  it('restores the prompt prefix if text changes delete into it', function()
    agent.open_chat()
    input.open_input_window()

    local bufnr = agent.state.input_bufnr
    local winid = agent.state.input_winid
    local prefix = input._input_prompt_prefix(bufnr)
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix:sub(1, #prefix - 1) })
    vim.api.nvim_win_set_cursor(winid, { 1, #prefix - 1 })

    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })

    local restored_prefix = input._input_prompt_prefix(bufnr)
    assert_eq(restored_prefix, vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    assert_eq(#restored_prefix, vim.api.nvim_win_get_cursor(winid)[2])
  end)

  it('clamps cursor movement to the end of the prompt prefix in insert mode', function()
    agent.open_chat()
    input.open_input_window()

    local bufnr = agent.state.input_bufnr
    local winid = agent.state.input_winid
    local prefix = input._input_prompt_prefix(bufnr)
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix })
    vim.api.nvim_win_set_cursor(winid, { 1, math.max(0, #prefix - 1) })

    vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

    assert_eq(#prefix, vim.api.nvim_win_get_cursor(winid)[2])
  end)

  it('submits input buffer text without the leading prompt prefix', function()
    local original_ask = agent.ask
    local sent

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. 'ship this change' })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #(prefix .. 'ship this change') })
    agent.ask = function(prompt, opts)
      sent = {
        prompt = prompt,
        attachments = opts and opts.attachments or nil,
      }
    end

    local submit_map = vim.fn.maparg('<C-s>', 'i', false, true)
    assert_true(type(submit_map.callback) == 'function')
    submit_map.callback()
    vim.wait(100, function()
      return sent ~= nil
    end)

    agent.ask = original_ask

    assert_eq('ship this change', sent.prompt)
    assert_true(type(sent.attachments) == 'table')
    assert_eq(nil, next(sent.attachments))
    assert_eq(prefix, vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1])
  end)

  it('preserves the prompt prefix when applying prompt prefill text', function()
    agent.open_chat()
    agent.state.prompt_prefill = 'restore this draft'
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.wait(100, function()
      local line = vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1] or ''
      return line == prefix .. 'restore this draft'
    end)

    local line = vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1] or ''
    assert_eq(prefix .. 'restore this draft', line)
    assert_eq(#line, vim.api.nvim_win_get_cursor(agent.state.input_winid)[2])
  end)

  it('deletes previous input word with Ctrl-W without removing the prompt prefix', function()
    agent.open_chat()
    input.open_input_window()

    local bufnr = agent.state.input_bufnr
    local winid = agent.state.input_winid
    local prefix = input._input_prompt_prefix(bufnr)
    vim.api.nvim_set_current_win(winid)

    local sentence = prefix .. 'alpha beta gamma'
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { sentence })
    vim.api.nvim_win_set_cursor(winid, { 1, #sentence })
    input._delete_input_previous_word()

    assert_eq(prefix .. 'alpha beta ', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert_eq(#(prefix .. 'alpha beta '), vim.api.nvim_win_get_cursor(winid)[2])

    local short = prefix .. 'x'
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { short })
    vim.api.nvim_win_set_cursor(winid, { 1, #short })
    input._delete_input_previous_word()
    assert_eq(prefix, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])

    vim.api.nvim_win_set_cursor(winid, { 1, #prefix })
    input._delete_input_previous_word()
    assert_eq(prefix, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
  end)

  it('deletes to prompt boundary with Ctrl-U while keeping the prompt prefix intact', function()
    agent.open_chat()
    input.open_input_window()

    local bufnr = agent.state.input_bufnr
    local winid = agent.state.input_winid
    local prefix = input._input_prompt_prefix(bufnr)
    vim.api.nvim_set_current_win(winid)

    local line = prefix .. 'alpha beta'
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(winid, { 1, #prefix + 5 })
    input._delete_input_to_prompt_start()

    assert_eq(prefix .. ' beta', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert_eq(#prefix, vim.api.nvim_win_get_cursor(winid)[2])

    vim.api.nvim_win_set_cursor(winid, { 1, #prefix })
    input._delete_input_to_prompt_start()
    assert_eq(prefix .. ' beta', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
  end)

  it('uses markdown filetype for the input prompt buffer', function()
    agent.open_chat()
    input.open_input_window()

    assert_eq('markdown', vim.bo[agent.state.input_bufnr].filetype)
  end)

  it('opens a markdown compose scratch buffer', function()
    agent.open_chat()
    input.open_compose_buffer()

    assert_eq('markdown', vim.bo[agent.state.compose_bufnr].filetype)
    assert_eq('acwrite', vim.bo[agent.state.compose_bufnr].buftype)
    assert_true(agent.state.chat_bufnr ~= agent.state.compose_bufnr)
  end)

  it('opens compose to the left of the chat window by default', function()
    agent.open_chat()
    input.open_compose_buffer()

    local compose_pos = vim.api.nvim_win_get_position(agent.state.compose_winid)
    local chat_pos = vim.api.nvim_win_get_position(agent.state.chat_winid)

    assert_true(compose_pos[2] < chat_pos[2])
  end)

  it('uses configured compose split width limits', function()
    agent.setup({
      auto_create_session = false,
      chat = {
        render_markdown = false,
      },
      compose = {
        width = 0.5,
        min_width = 20,
        max_width = 30,
      },
    })

    agent.open_chat()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
      if winid ~= agent.state.chat_winid then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    input.open_compose_buffer()

    assert_eq(30, vim.api.nvim_win_get_width(agent.state.compose_winid))
  end)

  it('reuses an existing left workspace split for compose instead of stacking another split', function()
    agent.open_chat()

    local left_bufnr = vim.api.nvim_create_buf(false, true)
    local left_winid = vim.api.nvim_open_win(left_bufnr, true, {
      split = 'left',
      win = agent.state.chat_winid,
      width = 24,
    })
    local wins_before = #vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
    vim.api.nvim_set_current_win(agent.state.chat_winid)

    input.open_compose_buffer()

    assert_eq(wins_before, #vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage()))
    assert_eq(left_winid, agent.state.compose_winid)
    assert_eq(agent.state.compose_bufnr, vim.api.nvim_win_get_buf(left_winid))
  end)

  it('promotes prompt text into the compose buffer', function()
    agent.open_chat()
    input.open_input_window()

    local prompt = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prompt .. 'move this into compose' })

    input._promote_input_to_compose()

    assert_true(not (agent.state.input_winid and vim.api.nvim_win_is_valid(agent.state.input_winid)))
    assert_eq('move this into compose', table.concat(vim.api.nvim_buf_get_lines(agent.state.compose_bufnr, 0, -1, false), '\n'))
    assert_eq(agent.state.compose_winid, vim.api.nvim_get_current_win())

    input.open_input_window()
    local restored_prompt = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.wait(100, function()
      local line = vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1] or ''
      return line ~= '' and line ~= restored_prompt
    end)
    local restored_line = vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1] or ''
    if vim.startswith(restored_line, restored_prompt) then
      restored_line = restored_line:sub(#restored_prompt + 1)
    end
    assert_eq('move this into compose', restored_line)
  end)

  it('uses the configured prompt-to-compose keymap', function()
    agent.setup({
      auto_create_session = false,
      chat = {
        render_markdown = false,
      },
      compose = {
        promote_keymap = '<F12>',
      },
    })

    agent.open_chat()
    input.open_input_window()
    vim.api.nvim_set_current_win(agent.state.input_winid)

    assert_true(vim.fn.maparg('<F12>', 'n') ~= '')
  end)

  it('promotes prompt text through CopilotAgentPromoteToCompose', function()
    local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')

    agent.open_chat()
    input.open_input_window()
    pcall(vim.api.nvim_del_user_command, 'CopilotAgentPromoteToCompose')
    vim.g.loaded_copilot_agent_plugin = 0
    dofile(plugin_root .. '/plugin/copilot_agent.lua')

    local prompt = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prompt .. 'promote by command' })
    vim.cmd('CopilotAgentPromoteToCompose')

    assert_eq('promote by command', table.concat(vim.api.nvim_buf_get_lines(agent.state.compose_bufnr, 0, -1, false), '\n'))
  end)

  it('opens compose in a new tab when requested', function()
    local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
    local tabs_before = vim.fn.tabpagenr('$')

    agent.open_chat()
    pcall(vim.api.nvim_del_user_command, 'CopilotAgentCompose')
    pcall(vim.api.nvim_del_user_command, 'CopilotAgentSendBuffer')
    vim.g.loaded_copilot_agent_plugin = 0
    dofile(plugin_root .. '/plugin/copilot_agent.lua')

    vim.cmd('CopilotAgentCompose tab')

    assert_eq(tabs_before + 1, vim.fn.tabpagenr('$'))
    assert_eq(agent.state.compose_bufnr, vim.api.nvim_get_current_buf())
    vim.cmd('tabclose')
    assert_true(not (agent.state.compose_winid and vim.api.nvim_win_is_valid(agent.state.compose_winid)))
  end)

  it('focuses an existing compose window in another tab instead of opening a duplicate', function()
    agent.open_chat()
    input.open_compose_buffer({ layout = 'tab' })

    local compose_tab = vim.fn.tabpagenr()
    local tabs_before = vim.fn.tabpagenr('$')
    vim.cmd('tabprevious')

    input.open_compose_buffer()

    assert_eq(tabs_before, vim.fn.tabpagenr('$'))
    assert_eq(compose_tab, vim.fn.tabpagenr())
    assert_eq(agent.state.compose_bufnr, vim.api.nvim_get_current_buf())
    vim.cmd('tabclose')
  end)

  it('warns instead of throwing when CopilotAgentCompose gets an unsupported argument', function()
    local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
    local original_notify = vim.notify
    local warned

    pcall(vim.api.nvim_del_user_command, 'CopilotAgentCompose')
    vim.g.loaded_copilot_agent_plugin = 0
    dofile(plugin_root .. '/plugin/copilot_agent.lua')
    vim.notify = function(message, level)
      warned = { message = message, level = level }
    end

    local ok = pcall(vim.cmd, 'CopilotAgentCompose split')

    vim.notify = original_notify
    assert_true(ok)
    assert_eq(vim.log.levels.WARN, warned.level)
    assert_true(warned.message:find('only accepts "tab"', 1, true) ~= nil)
  end)

  it('submits the compose buffer with :wq', function()
    local original_ask = agent.ask
    local sent

    agent.open_chat()
    input.open_compose_buffer()
    agent.ask = function(prompt, opts)
      sent = {
        prompt = prompt,
        attachments = opts and opts.attachments or nil,
      }
    end

    vim.api.nvim_set_current_win(agent.state.compose_winid)
    vim.api.nvim_buf_set_lines(agent.state.compose_bufnr, 0, -1, false, {
      '# Draft',
      '',
      'hello world',
    })
    vim.cmd('wq')

    agent.ask = original_ask

    assert_eq('# Draft\n\nhello world', sent.prompt)
    assert_true(not (agent.state.compose_winid and vim.api.nvim_win_is_valid(agent.state.compose_winid)))
  end)

  it('submits the compose buffer through CopilotAgentSendBuffer', function()
    local original_ask = agent.ask
    local sent

    agent.open_chat()
    input.open_compose_buffer()
    local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
    pcall(vim.api.nvim_del_user_command, 'CopilotAgentCompose')
    pcall(vim.api.nvim_del_user_command, 'CopilotAgentSendBuffer')
    vim.g.loaded_copilot_agent_plugin = 0
    dofile(plugin_root .. '/plugin/copilot_agent.lua')
    agent.ask = function(prompt, opts)
      sent = {
        prompt = prompt,
        attachments = opts and opts.attachments or nil,
      }
    end

    vim.api.nvim_buf_set_lines(agent.state.compose_bufnr, 0, -1, false, { 'send via command' })
    vim.cmd('CopilotAgentSendBuffer')

    agent.ask = original_ask

    assert_eq('send via command', sent.prompt)
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

  it('temporarily disables chat markdown conceal while assistant text is streaming', function()
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()

    local winid = agent.state.chat_winid
    local restore_level = agent.state.chat_default_conceallevel
    assert_true(type(restore_level) == 'number' and restore_level > 0)
    assert_eq(restore_level, vim.wo[winid].conceallevel)

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-inline-code',
        deltaContent = '  - row0: `[sky][sky][sky][sky][Wup-tri]',
      },
    })

    assert_true(vim.wait(1000, function()
      return vim.wo[winid].conceallevel == 0
    end))

    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    assert_true(vim.wait(1000, function()
      return vim.wo[winid].conceallevel == restore_level
    end))
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
      'commands: :CopilotAgentNewSession  :CopilotAgentAsk  :CopilotAgentStop',
      'No messages yet.',
      'Press i or <Enter> to open the input buffer.',
      'Run :CopilotAgentAsk to send a prompt from the command line.',
    }, { unpack(lines, 5, 8) })
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

  it('extends a delta-built live draft when assistant.message resumes from an overlapping mid-line suffix', function()
    local render = require('copilot_agent.render')
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()

    local prompt_idx = render.append_entry('user', 'debug transcript splice')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'debug transcript splice',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message_delta',
      data = {
        messageId = 'assistant-overlap',
        deltaContent = "You can get **most of `cmp-cmdline-history` natively in Neovim 0.12**. It's **not** part of `vim.l",
      },
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-overlap',
        content = 'part of `vim.lua.wildmenu`.\n\n```lua\nvim.opt.wildmenu = true\n```',
      },
    })

    vim.wait(250)

    local entry = agent.state.entries[#agent.state.entries]
    assert_eq("You can get **most of `cmp-cmdline-history` natively in Neovim 0.12**. It's **not** part of `vim.lua.wildmenu`.\n\n```lua\nvim.opt.wildmenu = true\n```", entry.content)
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

  it('registers conversation and Assistant/Activity jump keymaps in the chat buffer', function()
    agent.open_chat()
    local normal_maps = vim.api.nvim_buf_get_keymap(agent.state.chat_bufnr, 'n')
    local lhs_index = {}
    for _, map in ipairs(normal_maps) do
      lhs_index[map.lhs] = true
    end

    assert_true(lhs_index['[['] == true)
    assert_true(lhs_index[']]'] == true)
    assert_true(lhs_index['[a'] == true)
    assert_true(lhs_index[']a'] == true)
  end)

  it('jumps across conversation and Assistant/Activity transcript blocks in order', function()
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-123'
    render.clear_transcript()
    agent.open_chat()

    local bufnr = agent.state.chat_bufnr
    local winid = agent.state.chat_winid
    local user_one = render.append_entry('user', 'first prompt')
    render.append_entry('activity', 'Ran bash — ls')
    local assistant_one = render.append_entry('assistant', 'first answer')
    local user_two = render.append_entry('user', 'second prompt')
    local activity_two = render.append_entry('activity', 'Ran bash — rg foo')
    local assistant_two = render.append_entry('assistant', 'second answer')
    render.render_chat()
    vim.api.nvim_set_current_win(winid)

    local function row_for_entry(entry_idx)
      for row, idx in pairs(agent.state.entry_row_index or {}) do
        if idx == entry_idx then
          return row + 1
        end
      end
      return nil
    end

    local row_user_one = row_for_entry(user_one)
    local row_user_two = row_for_entry(user_two)
    local row_assistant_one = row_for_entry(assistant_one)
    local row_activity_two = row_for_entry(activity_two)
    local row_assistant_two = row_for_entry(assistant_two)
    assert_not_nil(row_user_one)
    assert_not_nil(row_user_two)
    assert_not_nil(row_assistant_one)
    assert_not_nil(row_activity_two)
    assert_not_nil(row_assistant_two)

    vim.api.nvim_win_set_cursor(winid, { vim.api.nvim_buf_line_count(bufnr), 0 })
    assert_true(render.jump_conversation(-1))
    assert_eq(row_user_two, vim.api.nvim_win_get_cursor(winid)[1])
    assert_true(render.jump_conversation(-1))
    assert_eq(row_user_one, vim.api.nvim_win_get_cursor(winid)[1])
    assert_true(render.jump_conversation(1))
    assert_eq(row_user_two, vim.api.nvim_win_get_cursor(winid)[1])
    assert_false(render.jump_conversation(1))
    assert_eq(row_user_two, vim.api.nvim_win_get_cursor(winid)[1])

    vim.api.nvim_win_set_cursor(winid, { vim.api.nvim_buf_line_count(bufnr), 0 })
    assert_true(render.jump_assistant_activity(-1))
    assert_eq(row_assistant_two, vim.api.nvim_win_get_cursor(winid)[1])
    assert_true(render.jump_assistant_activity(-1))
    assert_eq(row_activity_two, vim.api.nvim_win_get_cursor(winid)[1])
    assert_true(render.jump_assistant_activity(-1))
    assert_eq(row_assistant_one, vim.api.nvim_win_get_cursor(winid)[1])

    vim.api.nvim_win_set_cursor(winid, { row_assistant_one, 0 })
    assert_true(render.jump_assistant_activity(1))
    assert_eq(row_activity_two, vim.api.nvim_win_get_cursor(winid)[1])
    assert_true(render.jump_assistant_activity(1))
    assert_eq(row_assistant_two, vim.api.nvim_win_get_cursor(winid)[1])
    assert_false(render.jump_assistant_activity(1))
    assert_eq(row_assistant_two, vim.api.nvim_win_get_cursor(winid)[1])
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
      progress_messages = { 'Collecting diff output' },
      partial_output = 'partial line 1\n',
      success = true,
      tool_telemetry = {
        filesChanged = 3,
      },
      output_text = 'full diff output\nsecond line',
    }, entry.activity_items[1])
  end)

  it('does not append assistant usage into trailing activity blocks and keeps tool previews stable', function()
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
        command = 'git',
        arguments = { 'status', '--short' },
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.usage',
      data = {
        model = 'gpt-5.4',
        cost = 1,
        duration = 3019,
        inputTokens = 145411,
        outputTokens = 86,
        quotaSnapshots = {
          premium_interactions = {
            entitlementRequests = 300,
            isUnlimitedEntitlement = false,
            overage = 194.8,
            overageAllowedWithExhaustedQuota = true,
            remainingPercentage = 0,
            resetDate = '2026-06-01T00:00:00Z',
            usageAllowedWithExhaustedQuota = true,
            usedRequests = 300,
          },
        },
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-after-usage',
        content = 'Usage is visible in the transcript now.',
      },
    })

    vim.wait(250)

    local activity_entries = {}
    for _, entry in ipairs(agent.state.entries) do
      if entry.kind == 'activity' then
        activity_entries[#activity_entries + 1] = entry
      end
    end
    assert_eq(1, #activity_entries)
    assert_eq('Ran bash — git status --short', activity_entries[1].content)
    assert_eq('tool', activity_entries[1].activity_items[1].kind)
    assert_eq(1, #activity_entries[1].activity_items)
    assert_not_nil(agent.state.last_assistant_usage)
    assert_eq(194.8, agent.state.last_assistant_usage.overage)
    assert_eq(0, agent.state.last_assistant_usage.remaining_percentage)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Activity: git status --short (1 item hidden)',
      '',
      'Assistant:',
      '  Usage is visible in the transcript now.',
      '',
    }, { unpack(lines, #lines - 4, #lines) })

    assert_true(render.toggle_activity_entries())
    local joined = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    assert_true(joined:find('Ran bash — git status --short', 1, true) ~= nil)
    assert_true(joined:find('Usage: gpt-5.4 · cost 1 · 145k in · 86 out · 3s · premium 0%', 1, true) == nil)
  end)

  it('shows report_intent details when no higher-priority activity exists', function()
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
      type = 'tool.execution_start',
      data = {
        toolName = 'report_intent',
        intent = 'Finalizing process',
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.usage',
      data = {
        model = 'gpt-5.3-codex',
        cost = 1,
        inputTokens = 149,
        outputTokens = 17,
        duration = 901,
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-after-report-intent',
        content = 'Intent summary rendered.',
      },
    })

    vim.wait(250)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Activity: Used report_intent Finalizing process (1 item hidden)',
      '',
      'Assistant:',
      '  Intent summary rendered.',
      '',
    }, { unpack(lines, #lines - 4, #lines) })
  end)

  it('prefers tool execution over report_intent and usage in collapsed activity preview', function()
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
      type = 'tool.execution_start',
      data = {
        toolName = 'report_intent',
        intent = 'Validating statusline fix',
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
    events.handle_session_event({
      type = 'assistant.usage',
      data = {
        model = 'gpt-5.3-codex',
        cost = 1,
        inputTokens = 149,
        outputTokens = 17,
        duration = 901,
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-after-priority',
        content = 'Priority summary rendered.',
      },
    })

    vim.wait(250)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({
      'Activity: rg activity lua/copilot_agent (2 items hidden)',
      '',
      'Assistant:',
      '  Priority summary rendered.',
      '',
    }, { unpack(lines, #lines - 4, #lines) })
  end)

  it('captures assistant usage metrics without creating activity entries', function()
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    events.handle_session_event({
      type = 'assistant.usage',
      data = {
        model = 'gpt-5.4',
        initiator = 'agent',
        cost = 1,
        duration = 3019,
        inputTokens = 145411,
        outputTokens = 86,
        cacheReadTokens = 145280,
        quotaSnapshots = {
          premium_interactions = {
            entitlementRequests = 300,
            isUnlimitedEntitlement = false,
            overage = 194.8,
            overageAllowedWithExhaustedQuota = true,
            remainingPercentage = 0,
            resetDate = '2026-06-01T00:00:00Z',
            usageAllowedWithExhaustedQuota = true,
            usedRequests = 300,
          },
        },
      },
    })

    vim.wait(100)
    assert_not_nil(agent.state.last_assistant_usage)
    assert_eq('gpt-5.4', agent.state.last_assistant_usage.model)
    assert_eq(145411, agent.state.last_assistant_usage.input_tokens)
    local activity_count = 0
    for _, entry in ipairs(agent.state.entries) do
      if entry.kind == 'activity' then
        activity_count = activity_count + 1
      end
    end
    assert_eq(0, activity_count)
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
      if map.lhs == '<CR>' then
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

  it('opens a direct diff for file-change activity instead of the activity float', function()
    local events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    local service = require('copilot_agent.service')
    local project_root_name = vim.fn.fnamemodify(service.working_directory(), ':t')
    local foreign_absolute_path = '/tmp/other-machine/workspaces/' .. project_root_name .. '/lua/copilot_agent/events.lua'
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({ type = 'assistant.message', data = { messageId = 'assistant-first', content = 'Applying the update now.' } })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'apply_patch',
        input = table.concat({
          '*** Begin Patch',
          '*** Update File: ' .. foreign_absolute_path,
          '@@',
          '-old line',
          '+new line',
          '*** Update File: ' .. foreign_absolute_path:gsub('events.lua', 'chat.lua'),
          '@@',
          '-old line 2',
          '+new line 2',
          '*** End Patch',
        }, '\n'),
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.wait(250)
    local activity_idx
    for idx, entry in ipairs(agent.state.entries) do
      if type(entry) == 'table' and entry.kind == 'activity' and type(entry.content) == 'string' and entry.content:find('Updated', 1, true) then
        activity_idx = idx
        break
      end
    end
    assert_not_nil(activity_idx)
    local activity_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == activity_idx then
        activity_row = row
        break
      end
    end
    assert_not_nil(activity_row)

    local collapsed_lines = vim.api.nvim_buf_get_lines(bufnr, activity_row, activity_row + 1, false)
    local collapsed_line = collapsed_lines[1] or ''
    assert_true(collapsed_line:find('Activity: Updated', 1, true) ~= nil)
    assert_true(collapsed_line:find('+1', 1, true) ~= nil)
    assert_true(collapsed_line:find('-1', 1, true) ~= nil)
    assert_true(collapsed_line:find('(1 more file update hidden)', 1, true) ~= nil)
    assert_true(collapsed_line:find('…', 1, true) ~= nil or collapsed_line:find('events.lua', 1, true) ~= nil)

    local original_cmd = vim.cmd
    local original_open_win = vim.api.nvim_open_win
    local commands = {}
    local viewer_buf
    vim.cmd = function(cmd)
      commands[#commands + 1] = cmd
      return original_cmd(cmd)
    end
    vim.api.nvim_open_win = function(buf, enter, config)
      local winid = original_open_win(buf, enter, config)
      if buf ~= agent.state.chat_bufnr then
        viewer_buf = buf
      end
      return winid
    end

    vim.api.nvim_win_set_cursor(agent.state.chat_winid, { activity_row + 1, 0 })
    local opened = render.show_activity_details_under_cursor(agent.state.chat_winid)
    vim.cmd = original_cmd
    vim.api.nvim_open_win = original_open_win

    assert_true(opened)
    assert_eq(nil, viewer_buf)
    local diff_bufs = {}
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(winid)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find('lua/copilot_agent/events.lua', 1, true) then
        diff_bufs[#diff_bufs + 1] = buf
      end
    end
    assert_true(#diff_bufs >= 2)
    assert_true(vim.bo[diff_bufs[1]].modifiable or vim.bo[diff_bufs[2]].modifiable)
    local joined_cmds = table.concat(commands, '\n')
    assert_true(
      joined_cmds:find('tabnew', 1, true) ~= nil
        or joined_cmds:find('vsplit', 1, true) ~= nil
        or joined_cmds:find('DiffviewOpen', 1, true) ~= nil
        or joined_cmds:find('Git diff', 1, true) ~= nil
        or joined_cmds:find('CodeDiff file', 1, true) ~= nil
    )
  end)

  it('opens an apply_patch hover preview for multi-file activity changes', function()
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.state.config.chat.activity_view = 'hover'
    agent.state.config.chat.activity_hover_cursor_hold = true
    agent.state.config.chat.activity_hover_timeout_ms = 100
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'apply_patch',
        input = table.concat({
          '*** Begin Patch',
          '*** Update File: lua/copilot_agent/activity_diff.lua',
          '@@',
          '-old line',
          '+new line',
          '*** Update File: lua/copilot_agent/chat.lua',
          '@@',
          '-old line 2',
          '+new line 2',
          '*** End Patch',
        }, '\n'),
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })

    vim.wait(250)
    local activity_idx
    for idx, entry in ipairs(agent.state.entries) do
      if type(entry) == 'table' and entry.kind == 'activity' and type(entry.content) == 'string' and entry.content:find('Updated', 1, true) then
        activity_idx = idx
        break
      end
    end
    assert_not_nil(activity_idx)
    local activity_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == activity_idx then
        activity_row = row
        break
      end
    end
    assert_not_nil(activity_row)

    local original_open_win = vim.api.nvim_open_win
    local preview_buf
    local preview_title
    local preview_config
    local preview_winid
    vim.api.nvim_open_win = function(buf, enter, config)
      local winid = original_open_win(buf, enter, config)
      if buf ~= bufnr then
        preview_buf = buf
        preview_title = config.title
        preview_config = vim.deepcopy(config)
        preview_winid = winid
      end
      return winid
    end

    vim.api.nvim_win_set_cursor(agent.state.chat_winid, { activity_row + 1, 0 })
    vim.api.nvim_exec_autocmds('CursorHold', { buffer = bufnr })
    vim.api.nvim_open_win = original_open_win

    assert_not_nil(preview_buf)
    assert_eq(' Activity preview ', preview_title)
    assert_not_nil(preview_config)
    assert_eq('cursor', preview_config.relative)
    assert_eq(1, preview_config.row)
    assert_eq(0, preview_config.col)
    assert_true(preview_config.width > 0)
    assert_true(preview_config.height > 0)
    assert_true(preview_config.width <= math.floor(vim.api.nvim_win_get_width(agent.state.chat_winid) * 0.7))
    assert_true(preview_config.height <= math.floor(vim.api.nvim_win_get_height(agent.state.chat_winid) * 0.5))
    assert_eq(agent.state.chat_winid, vim.api.nvim_get_current_win())
    assert_eq('diff', vim.bo[preview_buf].filetype)
    assert_eq(false, vim.bo[preview_buf].modifiable)
    assert_eq(true, vim.bo[preview_buf].readonly)
    local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('*** Begin Patch', 1, true) ~= nil)
    assert_true(joined:find('*** Update File: lua/copilot_agent/activity_diff.lua', 1, true) ~= nil)
    assert_true(joined:find('*** Update File: lua/copilot_agent/chat.lua', 1, true) ~= nil)
    assert_true(joined:find('@@', 1, true) ~= nil)
    vim.wait(180)
    assert_true(preview_winid == nil or not vim.api.nvim_win_is_valid(preview_winid))
  end)

  it('opens a hover diff preview for single-file activity changes', function()
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.state.config.chat.activity_view = 'hover'
    agent.state.config.chat.activity_hover_cursor_hold = true
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'apply_patch',
        input = table.concat({
          '*** Begin Patch',
          '*** Update File: lua/copilot_agent/activity_diff.lua',
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
    local activity_idx
    for idx, entry in ipairs(agent.state.entries) do
      if type(entry) == 'table' and entry.kind == 'activity' and type(entry.content) == 'string' and entry.content:find('Updated', 1, true) then
        activity_idx = idx
        break
      end
    end
    assert_not_nil(activity_idx)
    local activity_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == activity_idx then
        activity_row = row
        break
      end
    end
    assert_not_nil(activity_row)

    local original_open_win = vim.api.nvim_open_win
    local preview_buf
    local preview_title
    local preview_config
    vim.api.nvim_open_win = function(buf, enter, config)
      local winid = original_open_win(buf, enter, config)
      if buf ~= bufnr then
        preview_buf = buf
        preview_title = config.title
        preview_config = vim.deepcopy(config)
      end
      return winid
    end

    vim.api.nvim_win_set_cursor(agent.state.chat_winid, { activity_row + 1, 0 })
    vim.api.nvim_exec_autocmds('CursorHold', { buffer = bufnr })
    vim.api.nvim_open_win = original_open_win

    assert_not_nil(preview_buf)
    assert_eq(' Activity preview ', preview_title)
    assert_not_nil(preview_config)
    assert_eq('cursor', preview_config.relative)
    assert_eq(1, preview_config.row)
    assert_eq(0, preview_config.col)
    assert_true(preview_config.width > 0)
    assert_true(preview_config.height > 0)
    assert_true(preview_config.width <= math.floor(vim.api.nvim_win_get_width(agent.state.chat_winid) * 0.7))
    assert_true(preview_config.height <= math.floor(vim.api.nvim_win_get_height(agent.state.chat_winid) * 0.5))
    assert_eq(agent.state.chat_winid, vim.api.nvim_get_current_win())
    assert_eq('diff', vim.bo[preview_buf].filetype)
    assert_eq(false, vim.bo[preview_buf].modifiable)
    assert_eq(true, vim.bo[preview_buf].readonly)
    local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('*** Begin Patch', 1, true) ~= nil)
    assert_true(joined:find('*** Update File: lua/copilot_agent/activity_diff.lua', 1, true) ~= nil)
    assert_true(joined:find('@@', 1, true) ~= nil)
  end)

  it('opens a hover activity summary for tool activity', function()
    local events = require('copilot_agent.events')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.state.config.chat.activity_view = 'hover'
    agent.state.config.chat.activity_hover_cursor_hold = true
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

    local original_open_win = vim.api.nvim_open_win
    local preview_buf
    local preview_title
    vim.api.nvim_open_win = function(buf, enter, config)
      local winid = original_open_win(buf, enter, config)
      if buf ~= bufnr then
        preview_buf = buf
        preview_title = config.title
      end
      return winid
    end

    vim.api.nvim_win_set_cursor(agent.state.chat_winid, { activity_row + 1, 0 })
    vim.api.nvim_exec_autocmds('CursorHold', { buffer = bufnr })
    vim.api.nvim_open_win = original_open_win

    assert_not_nil(preview_buf)
    assert_eq(' Activity preview ', preview_title)
    assert_eq('markdown', vim.bo[preview_buf].filetype)
    local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
    local joined = table.concat(lines, '\n')
    assert_true(joined:find('## Activities', 1, true) ~= nil)
    assert_true(joined:find('Ran bash — git diff --stat', 1, true) ~= nil)
    assert_true(joined:find('## Turn summary', 1, true) == nil)
    assert_true(joined:find('Collecting diff output', 1, true) == nil)
    assert_true(joined:find('full diff output', 1, true) == nil)
  end)

  it('keeps focus in chat when K opens a hover diff and uses gK to enter the preview', function()
    local events = require('copilot_agent.events')
    local render = require('copilot_agent.render')
    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.state.config.chat.activity_view = 'hover'
    agent.state.config.chat.activity_hover_cursor_hold = false
    agent.state.config.chat.activity_hover_key = 'K'
    agent.state.config.chat.activity_hover_focus_key = 'gK'
    agent.state.config.chat.activity_hover_timeout_ms = 0
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr

    events.handle_session_event({
      type = 'assistant.turn_start',
      data = {},
    })
    events.handle_session_event({
      type = 'tool.execution_start',
      data = {
        toolName = 'apply_patch',
        input = table.concat({
          '*** Begin Patch',
          '*** Update File: lua/copilot_agent/activity_diff.lua',
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
    local activity_idx
    for idx, entry in ipairs(agent.state.entries) do
      if type(entry) == 'table' and entry.kind == 'activity' and type(entry.content) == 'string' and entry.content:find('Updated', 1, true) then
        activity_idx = idx
        break
      end
    end
    assert_not_nil(activity_idx)
    local activity_row
    for row, entry_idx in pairs(agent.state.entry_row_index) do
      if entry_idx == activity_idx then
        activity_row = row
        break
      end
    end
    assert_not_nil(activity_row)

    local keymaps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
    local hover_mapped = false
    local hover_focus_mapped = false
    local hover_ctrl_w_j_mapped = false
    for _, map in ipairs(keymaps) do
      if map.lhs == 'K' then
        hover_mapped = true
      elseif map.lhs == 'gK' then
        hover_focus_mapped = true
      elseif map.lhs == '<C-W>j' or map.lhs == '<C-w>j' then
        hover_ctrl_w_j_mapped = true
      end
    end
    assert_true(hover_mapped)
    assert_true(hover_focus_mapped)
    assert_true(hover_ctrl_w_j_mapped)

    local original_open_win = vim.api.nvim_open_win
    local preview_buf
    local preview_enter
    local preview_winid
    vim.api.nvim_open_win = function(buf, enter, config)
      local winid = original_open_win(buf, enter, config)
      if buf ~= bufnr then
        preview_buf = buf
        preview_enter = enter
        preview_winid = winid
      end
      return winid
    end

    local ok, err = pcall(function()
      vim.api.nvim_set_current_win(agent.state.chat_winid)
      vim.api.nvim_win_set_cursor(agent.state.chat_winid, { activity_row + 1, 0 })
      agent.state.activity_hover_opened_by_key = true
      assert_true(render.refresh_activity_hover_preview(agent.state.chat_winid))

      assert_not_nil(preview_buf)
      assert_eq(false, preview_enter)
      assert_eq(agent.state.chat_winid, vim.api.nvim_get_current_win())
      assert_eq('diff', vim.bo[preview_buf].filetype)

      vim.api.nvim_set_current_win(agent.state.chat_winid)
      assert_true(render.focus_activity_hover_preview(agent.state.chat_winid))
      assert_eq(preview_winid, vim.api.nvim_get_current_win())
    end)
    vim.api.nvim_open_win = original_open_win
    assert(ok, err)
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

  it('keeps the current view stable while browsing history even when overlay gutter updates', function()
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

    local view_before = vim.fn.getwininfo(winid)[1]
    render.reserve_overlay_gutter(4, 3)
    local view_after = vim.fn.getwininfo(winid)[1]
    assert_eq(view_before.topline, view_after.topline)

    agent.state.chat_busy = false
    agent.state.stream_line_start = nil
    agent.state.active_turn_assistant_index = nil
    agent.state.live_assistant_entry_index = nil
    agent.state.active_turn_assistant_message_id = nil
    agent.state.active_assistant_merge_group = nil
    agent.state.pending_checkpoint_turn = nil
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
    local original_complete_info = vim.fn.complete_info
    local original_pumvisible = vim.fn.pumvisible

    vim.fn.complete_info = function()
      return {
        mode = 'eval',
        pum_visible = 1,
        selected = -1,
        items = { { word = '/share' } },
      }
    end
    vim.fn.pumvisible = function()
      return 1
    end
    local confirm_keys = input._confirm_completion_or_submit()
    vim.fn.complete_info = function()
      return {
        mode = '',
        pum_visible = 0,
        selected = -1,
        items = {},
      }
    end
    vim.fn.pumvisible = function()
      return 0
    end
    local submit_keys = input._confirm_completion_or_submit()
    vim.fn.complete_info = original_complete_info
    vim.fn.pumvisible = original_pumvisible

    assert_eq(vim.api.nvim_replace_termcodes('<C-n><C-y>', true, false, true), confirm_keys)
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

  it('hides and re-shows chat without replaying the transcript buffer', function()
    agent.open_chat()
    local bufnr = agent.state.chat_bufnr
    local sentinel = 'toggle should preserve existing buffer lines'

    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { sentinel })
    vim.bo[bufnr].readonly = true
    vim.bo[bufnr].modifiable = false
    agent.state.entries = {}

    agent.toggle_chat()
    assert_eq(nil, agent.state.chat_winid)

    agent.toggle_chat()

    assert_true(agent.state.chat_winid and vim.api.nvim_win_is_valid(agent.state.chat_winid))
    assert_eq(bufnr, agent.state.chat_bufnr)
    assert_eq(sentinel, (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false) or {})[1])
  end)

  it('restores the prompt input window when chat UI is toggled back on', function()
    agent.open_chat()
    input.open_input_window()

    local input_bufnr = agent.state.input_bufnr
    local prefix = input._input_prompt_prefix(input_bufnr)
    vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { prefix .. 'draft after toggle' })

    agent.toggle_chat()
    assert_eq(nil, agent.state.input_winid)

    agent.toggle_chat()

    assert_true(agent.state.input_winid and vim.api.nvim_win_is_valid(agent.state.input_winid))
    assert_eq(input_bufnr, agent.state.input_bufnr)
    assert_eq(prefix .. 'draft after toggle', (vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false) or {})[1])
  end)

  it('reanchors the input window below the active chat window', function()
    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
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

  it('does not crash render metrics when the chat window no longer shows the chat buffer', function()
    local render = require('copilot_agent.render')
    agent.open_chat()

    render.append_entry('assistant', 'render stale window guard')
    render.render_chat()

    local stale_chat_win = agent.state.chat_winid
    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { '# markdown buffer' })
    vim.api.nvim_win_set_buf(stale_chat_win, source_buf)

    local ok_at_bottom, at_bottom = pcall(render.chat_at_bottom)
    assert_true(ok_at_bottom)
    assert_false(at_bottom)

    local ok_render = pcall(render.render_chat)
    assert_true(ok_render)
  end)

  it('completes discovered command arguments from the chat input', function()
    ensure_dev_input_module()
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

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
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
    local lsp_words = completion_words('/lsp ')
    local resume_words = completion_words('/resume ')
    local session_words = completion_words('/session ')
    local session_info_words = completion_words('/session info ')
    local session_delete_words = completion_words('/session delete ')
    local session_prune_words = completion_words('/session prune ')
    local mcp_root_words = completion_words('/mcp')
    local mcp_words = completion_words('/mcp ')
    local mcp_show_words = completion_words('/mcp show ')
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
    assert_true(vim.tbl_contains(lsp_words, '/lsp create'))
    assert_true(vim.tbl_contains(lsp_words, '/lsp status'))
    assert_true(vim.tbl_contains(lsp_words, '/lsp test'))
    assert_true(vim.tbl_contains(resume_words, '/resume session-123'))
    assert_true(vim.tbl_contains(resume_words, '/resume live-456'))
    assert_true(vim.tbl_contains(session_words, '/session info'))
    assert_true(vim.tbl_contains(session_words, '/session checkpoints'))
    assert_true(vim.tbl_contains(session_words, '/session files'))
    assert_true(vim.tbl_contains(session_words, '/session plan'))
    assert_true(vim.tbl_contains(session_words, '/session rename'))
    assert_true(vim.tbl_contains(session_words, '/session cleanup'))
    assert_true(vim.tbl_contains(session_words, '/session prune'))
    assert_true(vim.tbl_contains(session_words, '/session delete'))
    assert_true(vim.tbl_contains(session_info_words, '/session info session-123'))
    assert_true(vim.tbl_contains(session_info_words, '/session info live-456'))
    assert_true(vim.tbl_contains(session_delete_words, '/session delete session-123'))
    assert_true(vim.tbl_contains(session_delete_words, '/session delete live-456'))
    assert_true(vim.tbl_contains(session_prune_words, '/session prune --older-than'))
    assert_true(vim.tbl_contains(session_prune_words, '/session prune --keep-last'))
    assert_true(vim.tbl_contains(session_prune_words, '/session prune --session'))
    assert_true(vim.tbl_contains(session_prune_words, '/session prune --dry-run'))
    assert_true(vim.tbl_contains(session_prune_words, '/session prune --include-named'))
    assert_true(vim.tbl_contains(mcp_root_words, '/mcp'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp add'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp show'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp edit'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp delete'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp disable'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp enable'))
    assert_true(vim.tbl_contains(mcp_words, '/mcp reload'))
    assert_true(vim.tbl_contains(mcp_words, 'local'))
    assert_true(vim.tbl_contains(mcp_words, 'docs'))
    assert_true(vim.tbl_contains(mcp_words, 'browser'))
    assert_true(vim.tbl_contains(mcp_show_words, '/mcp show local'))
    assert_true(vim.tbl_contains(mcp_show_words, '/mcp show docs'))
    assert_true(vim.tbl_contains(mcp_show_words, '/mcp show browser'))
    assert_true(vim.tbl_contains(instruction_words, '/instructions .github/copilot-instructions.md'))
  end)

  it('shows mcp status details in slash completion labels', function()
    ensure_dev_input_module()

    local original_system = vim.system
    local original_executable = vim.fn.executable
    local sample_json = [[
{
  "mcpServers": {
    "fff finder": {
      "type": "stdio",
      "command": "/Users/rayxu/.local/bin/fff-mcp",
      "args": [],
      "source": "user"
    }
  }
}
]]

    vim.fn.executable = function(name)
      if name == 'copilot' then
        return 1
      end
      return original_executable(name)
    end

    vim.system = function(args, opts)
      if args[1] == 'copilot' and args[2] == 'mcp' and args[3] == 'list' and args[4] == '--json' then
        return {
          wait = function()
            return { code = 0, stdout = sample_json, stderr = '' }
          end,
        }
      end
      return original_system(args, opts)
    end

    local ok, items = pcall(function()
      agent.open_chat()
      input.open_input_window()

      local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
      local line = prefix .. '/mcp show '
      vim.api.nvim_set_current_win(agent.state.input_winid)
      vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
      vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })
      return input._input_omnifunc(0, '')
    end)

    vim.system = original_system
    vim.fn.executable = original_executable
    input.invalidate_mcp_completion_cache()

    assert_true(ok)
    local by_word = {}
    for _, item in ipairs(items) do
      by_word[item.word] = item
    end

    local item = by_word['/mcp show fff finder']
    assert_not_nil(item)
    assert_true(item.abbr:find('^✓ fff finder') ~= nil)
    assert_true(item.menu:find('stdio', 1, true) ~= nil)
    assert_true(item.menu:find('fff-mcp', 1, true) ~= nil)
  end)

  it('treats a single trailing space as a trigger character for sub-command completion', function()
    ensure_dev_input_module()
    -- has_completion_trigger_space helper
    assert_false(input._has_completion_trigger_space(nil))
    assert_false(input._has_completion_trigger_space(''))
    assert_true(input._has_completion_trigger_space(' '))
    assert_true(input._has_completion_trigger_space('add '))
    assert_false(input._has_completion_trigger_space('add  '))
    assert_false(input._has_completion_trigger_space('  '))
    assert_true(input._has_completion_trigger_space('show local '))
    assert_false(input._has_completion_trigger_space('show local  '))
  end)

  it('includes raw_query length in auto_key so space re-triggers the popup', function()
    ensure_dev_input_module()
    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.api.nvim_set_current_win(agent.state.input_winid)

    local function get_auto_key(command_text)
      vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. command_text })
      vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #(prefix .. command_text) })
      local line = vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1]
      local ctx = input._input_completion_context(line:sub(1, #(prefix .. command_text)))
      return ctx and ctx.auto_key or nil
    end

    -- "/mcp" at end of token → has auto_key
    local key_mcp = get_auto_key('/mcp')
    assert_true(key_mcp ~= nil)
    -- "/mcp " (single space) → has auto_key with different value
    local key_mcp_space = get_auto_key('/mcp ')
    assert_true(key_mcp_space ~= nil)
    assert_true(key_mcp ~= key_mcp_space, 'auto_key should differ after space')
    -- "/mcp  " (double space) → no auto_key
    local key_mcp_double = get_auto_key('/mcp  ')
    assert_eq(nil, key_mcp_double)
  end)

  it('shows full command paths in completion abbr for slash commands', function()
    ensure_dev_input_module()
    http.sync_request = function(_, path)
      if path == '/models' then
        return { models = { { id = 'test-model', name = 'Test Model' } } }, nil, 200
      end
      if path == '/sessions' then
        return { persisted = {}, live = {} }, nil, 200
      end
      return nil, 'unexpected', 404
    end

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.api.nvim_set_current_win(agent.state.input_winid)

    local function completion_items(command_text)
      vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. command_text })
      vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #(prefix .. command_text) })
      return input._input_omnifunc(0, '')
    end

    local model_items = completion_items('/model ')
    local model_item = vim.tbl_filter(function(i)
      return i.word == '/model test-model'
    end, model_items)[1]
    assert_true(model_item ~= nil)
    assert_eq('/model test-model', model_item.abbr)

    local lsp_items = completion_items('/lsp ')
    local lsp_item = vim.tbl_filter(function(i)
      return i.word == '/lsp create'
    end, lsp_items)[1]
    assert_true(lsp_item ~= nil)
    assert_eq('/lsp create', lsp_item.abbr)

    local mcp_items = completion_items('/mcp ')
    local mcp_item = vim.tbl_filter(function(i)
      return i.word == '/mcp add'
    end, mcp_items)[1]
    assert_true(mcp_item ~= nil)
    assert_eq('/mcp add', mcp_item.abbr)
  end)

  it('treats completion items as a visible popup even when pumvisible falls out of sync', function()
    ensure_dev_input_module()
    local original_complete_info = vim.fn.complete_info
    local original_pumvisible = vim.fn.pumvisible
    local original_select_popupmenu_item = vim.api.nvim_select_popupmenu_item
    local selected_call

    vim.fn.complete_info = function()
      return {
        mode = '',
        pum_visible = 0,
        selected = -1,
        items = { { word = '/share' } },
      }
    end
    vim.fn.pumvisible = function()
      return 0
    end
    vim.api.nvim_select_popupmenu_item = function(idx, insert, finish, opts)
      selected_call = {
        idx = idx,
        insert = insert,
        finish = finish,
        opts = opts,
      }
    end

    assert_true(input._select_visible_completion())
    assert.same({
      idx = 0,
      insert = true,
      finish = true,
      opts = {},
    }, selected_call)

    vim.fn.complete_info = original_complete_info
    vim.fn.pumvisible = original_pumvisible
    vim.api.nvim_select_popupmenu_item = original_select_popupmenu_item
  end)

  it('registers expr completion maps for Enter and Tab in the input buffer', function()
    ensure_dev_input_module()
    agent.open_chat()
    input.open_input_window()

    local insert_maps = vim.api.nvim_buf_get_keymap(agent.state.input_bufnr, 'i')
    local tab_map
    local enter_map
    for _, map in ipairs(insert_maps) do
      if map.lhs == '<Tab>' then
        tab_map = map
      elseif map.lhs == '<CR>' then
        enter_map = map
      end
    end

    assert_true(tab_map ~= nil)
    assert_true(enter_map ~= nil)
    assert_eq(1, tab_map.expr)
    assert_eq(1, enter_map.expr)
  end)

  it('uses the input-buffer Enter mapping to accept slash completion', function()
    ensure_dev_input_module()
    local original_complete_info = vim.fn.complete_info
    local original_pumvisible = vim.fn.pumvisible

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '/share'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    vim.fn.complete_info = function()
      return {
        mode = 'eval',
        pum_visible = 1,
        selected = -1,
        items = { { word = '/share' } },
      }
    end
    vim.fn.pumvisible = function()
      return 1
    end

    local enter_map = vim.fn.maparg('<CR>', 'i', false, true)
    assert_true(type(enter_map.callback) == 'function')
    local result = enter_map.callback()

    vim.fn.complete_info = original_complete_info
    vim.fn.pumvisible = original_pumvisible

    assert_eq(vim.api.nvim_replace_termcodes('<C-n><C-y>', true, false, true), result)
    assert_eq(line, vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1])
  end)

  it('uses the input-buffer Tab mapping to accept slash completion', function()
    ensure_dev_input_module()
    local original_complete_info = vim.fn.complete_info
    local original_pumvisible = vim.fn.pumvisible
    local original_select_popupmenu_item = vim.api.nvim_select_popupmenu_item
    local selected_call

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '/share'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    vim.fn.complete_info = function()
      return {
        mode = 'eval',
        pum_visible = 1,
        selected = -1,
        items = { { word = '/share' } },
      }
    end
    vim.fn.pumvisible = function()
      return 1
    end
    vim.api.nvim_select_popupmenu_item = function(idx, insert, finish, opts)
      selected_call = {
        idx = idx,
        insert = insert,
        finish = finish,
        opts = opts,
      }
    end

    local tab_map = vim.fn.maparg('<Tab>', 'i', false, true)
    assert_true(type(tab_map.callback) == 'function')
    local result = tab_map.callback()

    vim.fn.complete_info = original_complete_info
    vim.fn.pumvisible = original_pumvisible
    vim.api.nvim_select_popupmenu_item = original_select_popupmenu_item

    assert_eq('', result)
    assert.same({
      idx = 0,
      insert = true,
      finish = true,
      opts = {},
    }, selected_call)
    assert_eq(line, vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, 1, false)[1])
  end)

  it('removes prompt placeholder padding from continuation lines', function()
    ensure_dev_input_module()
    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.cmd('startinsert!')
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, {
      prefix .. 'first line',
      prefix .. 'second line',
    })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 2, #prefix + #'second line' })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = agent.state.input_bufnr })
    vim.wait(50)

    assert.same({
      prefix .. 'first line',
      'second line',
    }, vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, -1, false))
    assert_eq('first line\nsecond line', table.concat(input._strip_prompt_prefix_from_text_lines(vim.api.nvim_buf_get_lines(agent.state.input_bufnr, 0, -1, false), prefix), '\n'))
    assert_eq(#'second line', vim.api.nvim_win_get_cursor(agent.state.input_winid)[2])
  end)

  it('re-renders a frozen assistant entry when a late final message updates it', function()
    local events = require('copilot_agent.events')
    local render = require('copilot_agent.render')

    agent.state.session_id = 'session-123'
    agent.state.entries = {}
    agent.state.entry_row_index = {}
    agent.open_chat()

    local prompt_idx = render.append_entry('user', 'commit the messages')
    agent.state.pending_checkpoint_turn = {
      session_id = 'session-123',
      prompt = 'commit the messages',
      entry_index = prompt_idx,
    }

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-commit',
        content = 'Running the commit now…',
      },
    })
    events.handle_session_event({
      type = 'assistant.turn_end',
      data = {},
    })
    vim.wait(50)

    events.handle_session_event({
      type = 'assistant.message',
      data = {
        messageId = 'assistant-commit',
        content = 'Committed as `67b9268`.',
      },
    })
    vim.wait(250)

    local lines = vim.api.nvim_buf_get_lines(agent.state.chat_bufnr, 0, -1, false)
    assert_true(vim.tbl_contains(lines, '  Committed as `67b9268`.'))
    assert_false(vim.tbl_contains(lines, '  Running the commit now…'))
  end)

  it('completes nested attachment paths inside subfolders', function()
    ensure_dev_input_module()
    stub_fd_output({
      'README.md',
      'lua/',
      'lua/copilot_agent/',
      'lua/copilot_agent/init.lua',
    })
    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '@lua/cop'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local replace_start = input._input_omnifunc(1, '')
    local items = vim.tbl_map(function(item)
      return item.word
    end, input._input_omnifunc(0, ''))

    assert_eq(#prefix, replace_start)
    assert_true(vim.tbl_contains(items, '@lua/copilot_agent/') or vim.tbl_contains(items, '@lua/copilot_agent'))
  end)

  it('uses fd-backed fuzzy attachment completion for nested file matches', function()
    ensure_dev_input_module()
    stub_fd_output({
      'README.md',
      'lua/',
      'lua/copilot_agent/',
      'lua/copilot_agent/init.lua',
      'lua/init.lua',
    })

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '@init'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local items = input._input_omnifunc(0, '')
    local words = vim.tbl_map(function(item)
      return item.word
    end, items)

    assert_true(vim.tbl_contains(words, '@lua/copilot_agent/init.lua'))
    assert_true(vim.tbl_contains(words, '@lua/init.lua'))
  end)

  it('supports quoted attachment completion for paths with spaces', function()
    ensure_dev_input_module()
    stub_fd_output({
      'my file name.txt',
      'lua/',
      'lua/init.lua',
    })

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '@"my fi'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local replace_start = input._input_omnifunc(1, '')
    local items = input._input_omnifunc(0, '')
    local words = vim.tbl_map(function(item)
      return item.word
    end, items)

    assert_eq(#prefix, replace_start)
    assert_true(vim.tbl_contains(words, '@"my file name.txt"'))
  end)

  it('completes named open buffers and expands them to attachment paths', function()
    ensure_dev_input_module()

    local cwd = require('copilot_agent.service').working_directory()
    local repo_file = cwd .. '/lua/copilot_agent/init.lua'
    local repo_bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(repo_bufnr, repo_file)
    vim.api.nvim_buf_set_lines(repo_bufnr, 0, -1, false, { '-- stub' })
    vim.bo[repo_bufnr].modified = false

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '@init'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local replace_start = input._input_omnifunc(1, '')
    local items = input._input_omnifunc(0, '')
    local words = vim.tbl_map(function(item)
      return item.word
    end, items)

    assert_eq(#prefix, replace_start)
    assert_true(vim.tbl_contains(words, '@lua/copilot_agent/init.lua'))
    assert_false(vim.tbl_contains(words, '@CopilotAgentChat'))

    local replaced = line:sub(1, replace_start) .. '@lua/copilot_agent/init.lua' .. line:sub(#line + 1)
    assert_eq(prefix .. '@lua/copilot_agent/init.lua', replaced)
  end)

  it('auto-triggers attachment completion after entering a nested folder slash', function()
    ensure_dev_input_module()
    stub_fd_output({
      'lua/',
      'lua/copilot_agent/',
      'lua/copilot_agent/init.lua',
    })
    local original_complete = vim.fn.complete
    local original_mode = vim.fn.mode
    local completions = {}

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.cmd('startinsert!')
    vim.fn.mode = function()
      return 'i'
    end
    vim.fn.complete = function(col, items)
      table.insert(completions, { col = col, items = items })
    end

    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { prefix .. '@lua/' })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #(prefix .. '@lua/') })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = agent.state.input_bufnr })
    vim.wait(50, function()
      return #completions > 0
    end)

    vim.fn.complete = original_complete
    vim.fn.mode = original_mode

    assert_eq(1, #completions)
    assert_eq(#prefix + 1, completions[1].col)
    local words = vim.tbl_map(function(item)
      return item.word
    end, completions[1].items)
    assert_true(vim.tbl_contains(words, '@lua/copilot_agent/') or vim.tbl_contains(words, '@lua/copilot_agent'))
  end)

  it('defers manual <Tab> completion so it can run outside textlock', function()
    ensure_dev_input_module()
    stub_fd_output({
      'lua/',
      'lua/copilot_agent/',
      'lua/copilot_agent/init.lua',
    })
    local original_complete = vim.fn.complete
    local original_mode = vim.fn.mode
    local completions = {}

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '@lua/'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.cmd('startinsert!')
    vim.fn.mode = function()
      return 'i'
    end
    vim.fn.complete = function(col, items)
      table.insert(completions, { col = col, items = items })
    end

    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local tab_map = vim.fn.maparg('<Tab>', 'i', false, true)
    assert_true(type(tab_map.callback) == 'function')
    assert_eq('', tab_map.callback())

    vim.wait(50, function()
      return #completions > 0
    end)

    vim.fn.complete = original_complete
    vim.fn.mode = original_mode

    assert_eq(1, #completions)
    assert_eq(#prefix + 1, completions[1].col)
    local words = vim.tbl_map(function(item)
      return item.word
    end, completions[1].items)
    assert_true(vim.tbl_contains(words, '@lua/copilot_agent/') or vim.tbl_contains(words, '@lua/copilot_agent'))
  end)

  it('distinguishes directory and file attachment suggestions when fd is available', function()
    ensure_dev_input_module()
    stub_fd_output({
      'lua/',
      'lua/copilot_agent/',
      'lua/init.lua',
    })

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '@lua/'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local items = input._input_omnifunc(0, '')
    local by_word = {}
    for _, item in ipairs(items) do
      by_word[item.word] = item
    end

    assert_eq('[dir]', by_word['@lua/copilot_agent/'].menu)
    assert_eq('[file]', by_word['@lua/init.lua'].menu)
  end)

  it('extracts inline attachment tokens into real attachments', function()
    local cwd = require('copilot_agent.service').working_directory()
    agent.state.config.session.working_directory = cwd
    local spaced_path = cwd .. '/my file name.txt'
    vim.fn.writefile({ 'hello' }, spaced_path)

    local cleaned, attachments = input._extract_inline_attachments('review @"my file name.txt" and @README.md')

    pcall(vim.fn.delete, spaced_path)

    assert_eq('review my file name.txt and README.md', cleaned)
    assert_eq(2, #attachments)
    assert_eq('file', attachments[1].type)
    assert_eq(true, input._attachment_completion_context('@"my fi').quoted)
    assert_true(attachments[1].path:sub(-#'my file name.txt') == 'my file name.txt')
    assert_true(attachments[2].path:sub(-#'README.md') == 'README.md')
  end)

  it('replaces the generic slash completion with agent completion when typing /agent', function()
    ensure_dev_input_module()
    local original_complete = vim.fn.complete
    local original_mode = vim.fn.mode
    local completions = {}

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
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
    ensure_dev_input_module()
    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
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

  it('replaces /mcp completion text with only the selected mcp name', function()
    ensure_dev_input_module()
    local vscode_dir = vim.fn.fnamemodify(vscode_mcp, ':h')
    root_mcp_backup = vim.fn.filereadable(root_mcp) == 1 and vim.fn.readfile(root_mcp) or nil
    vscode_mcp_backup = vim.fn.filereadable(vscode_mcp) == 1 and vim.fn.readfile(vscode_mcp) or nil
    vim.fn.mkdir(vscode_dir, 'p')
    vim.fn.writefile({ '{"mcpServers":{"local":{},"docs":{}}}' }, root_mcp)
    vim.fn.writefile({ '{"servers":[{"name":"browser"}]}' }, vscode_mcp)

    agent.open_chat()
    input.open_input_window()

    local prefix = input._input_prompt_prefix(agent.state.input_bufnr)
    local line = prefix .. '/mcp bro'
    vim.api.nvim_set_current_win(agent.state.input_winid)
    vim.api.nvim_buf_set_lines(agent.state.input_bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(agent.state.input_winid, { 1, #line })

    local replace_start = input._input_omnifunc(1, '')
    local items = input._input_omnifunc(0, '')
    local selected
    for _, item in ipairs(items) do
      if item.word == 'browser' then
        selected = item.word
        break
      end
    end

    assert_eq(#prefix, replace_start)
    assert_eq('browser', selected)

    local replaced = line:sub(1, replace_start) .. selected .. line:sub(#line + 1)
    assert_eq(prefix .. 'browser', replaced)
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
      progress_messages = {},
      success = true,
      output_text = 'lua/copilot_agent/events.lua:1:match\n\n1 match found',
      start_data = {
        toolName = 'bash',
        toolCallId = 'tool-456',
        command = 'rg',
        arguments = { 'activity', 'lua' },
      },
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
    package.loaded['copilot_agent.config'] = nil
    package.loaded['copilot_agent.events'] = nil
    package.loaded['copilot_agent.checkpoints'] = nil
    package.loaded['copilot_agent.statusline'] = nil
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
