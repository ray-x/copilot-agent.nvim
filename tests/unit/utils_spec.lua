-- busted unit tests for lua/copilot_agent/utils.lua
-- Run with:  busted tests/unit/utils_spec.lua
--  or:       busted   (picks up .busted config at repo root)

local utils = require('copilot_agent.utils')

describe('is_thinking_content', function()
  it('treats nil as thinking', function()
    assert.is_true(utils.is_thinking_content(nil))
  end)

  it('treats empty string as thinking', function()
    assert.is_true(utils.is_thinking_content(''))
  end)

  it('treats whitespace-only as thinking', function()
    assert.is_true(utils.is_thinking_content('   '))
    assert.is_true(utils.is_thinking_content('\t\n'))
  end)

  it('treats dots-only as thinking', function()
    assert.is_true(utils.is_thinking_content('.'))
    assert.is_true(utils.is_thinking_content('...'))
    assert.is_true(utils.is_thinking_content('. . .'))
  end)

  it('treats mixed dots and whitespace as thinking', function()
    assert.is_true(utils.is_thinking_content('.. .'))
  end)

  it('treats real content as not thinking', function()
    assert.is_false(utils.is_thinking_content('hello'))
    assert.is_false(utils.is_thinking_content('A'))
    assert.is_false(utils.is_thinking_content('  hello  '))
  end)
end)

describe('split_lines', function()
  it('returns single empty string for nil', function()
    local result = utils.split_lines(nil)
    assert.same({ '' }, result)
  end)

  it('returns single empty string for empty string', function()
    local result = utils.split_lines('')
    assert.same({ '' }, result)
  end)

  it('splits on newlines', function()
    local result = utils.split_lines('a\nb\nc')
    assert.same({ 'a', 'b', 'c' }, result)
  end)

  it('preserves trailing newline as empty last element', function()
    local result = utils.split_lines('a\nb\n')
    assert.same({ 'a', 'b', '' }, result)
  end)

  it('handles single line with no newline', function()
    local result = utils.split_lines('hello world')
    assert.same({ 'hello world' }, result)
  end)
end)

describe('normalize_base_url', function()
  it('strips trailing slash', function()
    assert.equal('http://localhost:8088', utils.normalize_base_url('http://localhost:8088/', 'http://default'))
  end)

  it('strips multiple trailing slashes', function()
    assert.equal('http://localhost:8088', utils.normalize_base_url('http://localhost:8088///', 'http://default'))
  end)

  it('leaves URL without trailing slash unchanged', function()
    assert.equal('http://localhost:8088', utils.normalize_base_url('http://localhost:8088', 'http://default'))
  end)

  it('falls back to default when nil', function()
    assert.equal('http://default', utils.normalize_base_url(nil, 'http://default'))
  end)
end)

describe('truncate_session_summary', function()
  it('returns the summary unchanged when it already fits', function()
    assert.equal('short summary', utils.truncate_session_summary('short summary', 32))
  end)

  it('prefers trimming at separators within the limit', function()
    assert.equal('my.long.session',
      utils.truncate_session_summary('my.long.session.name.with.extra.parts', 18))
  end)

  it('drops trailing separators from the trimmed result', function()
    assert.equal('topic:subtopic',
      utils.truncate_session_summary('topic:subtopic-detail-more', 20))
  end)

  it('falls back to hard truncation when there is no separator', function()
    assert.equal('abcdefghij', utils.truncate_session_summary('abcdefghijklmnopqrstuvwxyz', 10))
  end)
end)

describe('normalize_model_entry', function()
  it('returns nil for non-table input', function()
    assert.is_nil(utils.normalize_model_entry('string'))
    assert.is_nil(utils.normalize_model_entry(42))
    assert.is_nil(utils.normalize_model_entry(nil))
  end)

  it('returns nil when id is missing', function()
    assert.is_nil(utils.normalize_model_entry({}))
    assert.is_nil(utils.normalize_model_entry({ name = 'GPT' }))
  end)

  it('returns nil when id is empty string', function()
    assert.is_nil(utils.normalize_model_entry({ id = '' }))
  end)

  it('normalises lowercase keys', function()
    local result = utils.normalize_model_entry({ id = 'gpt-5.4', name = 'GPT 5.4' })
    assert.equal('gpt-5.4', result.id)
    assert.equal('GPT 5.4', result.name)
    assert.equal('GPT 5.4 (gpt-5.4)', result.label)
  end)

  it('normalises PascalCase keys from SDK', function()
    local result = utils.normalize_model_entry({ ID = 'claude-sonnet', Name = 'Claude Sonnet' })
    assert.equal('claude-sonnet', result.id)
    assert.equal('Claude Sonnet', result.name)
  end)

  it('uses id as name when name is absent', function()
    local result = utils.normalize_model_entry({ id = 'auto' })
    assert.equal('auto', result.id)
    assert.equal('auto', result.name)
    assert.equal('auto (auto)', result.label)
  end)

  it('prefers lowercase id over PascalCase ID', function()
    local result = utils.normalize_model_entry({ id = 'low', ID = 'HIGH' })
    assert.equal('low', result.id)
  end)
end)

describe('unavailable_model_from_error', function()
  it('returns nil for non-string input', function()
    assert.is_nil(utils.unavailable_model_from_error(nil))
    assert.is_nil(utils.unavailable_model_from_error(42))
  end)

  it('returns nil for unrelated error strings', function()
    assert.is_nil(utils.unavailable_model_from_error('connection refused'))
    assert.is_nil(utils.unavailable_model_from_error(''))
  end)

  it('extracts model name from standard error message', function()
    assert.equal('gpt-5.4',
      utils.unavailable_model_from_error('Model "gpt-5.4" is not available'))
  end)

  it('extracts model name embedded in longer message', function()
    assert.equal('claude-opus',
      utils.unavailable_model_from_error('error: Model "claude-opus" is not available in this region'))
  end)
end)

describe('is_connection_error', function()
  it('returns false for non-string input', function()
    assert.is_false(utils.is_connection_error(nil))
    assert.is_false(utils.is_connection_error(false))
    assert.is_false(utils.is_connection_error(42))
  end)

  it('returns false for unrelated error strings', function()
    assert.is_false(utils.is_connection_error('not found'))
    assert.is_false(utils.is_connection_error(''))
  end)

  it('matches "Failed to connect"', function()
    assert.is_true(utils.is_connection_error('curl: (7) Failed to connect to localhost port 8088'))
  end)

  it('matches "Couldn\'t connect to server"', function()
    assert.is_true(utils.is_connection_error("curl: (7) Couldn't connect to server"))
  end)

  it('matches "Connection refused"', function()
    assert.is_true(utils.is_connection_error('Connection refused'))
  end)

  it('matches "Empty reply from server"', function()
    assert.is_true(utils.is_connection_error('Empty reply from server'))
  end)
end)
