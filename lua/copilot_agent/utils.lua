-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Pure utility functions with no Neovim API dependencies.
-- Kept in a separate module so they can be unit-tested with plain Lua / busted.
local M = {}

local function escape_lua_pattern(text)
  return text:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')
end

local function normalized_home_path()
  local home = os.getenv('HOME')
  if type(home) ~= 'string' or home == '' then
    return nil
  end
  home = home:gsub('[\\/]+$', '')
  if home == '' or home == '/' then
    return nil
  end
  return home
end

-- Returns true when content is empty, whitespace, or dots-only (model "thinking").
function M.is_thinking_content(s)
  return s == nil or s == '' or s:match('^[%.%s]*$') ~= nil
end

-- Split text on newlines. Returns { '' } for nil/empty input.
-- Uses vim.split when available (Neovim runtime), falls back to pure Lua.
function M.split_lines(text)
  if text == nil or text == '' then
    return { '' }
  end
  if vim and vim.split then
    return vim.split(text, '\n', { plain = true })
  end
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    table.insert(lines, line)
  end
  return lines
end

-- Strip trailing slashes from a base URL.
function M.normalize_base_url(url, default_url)
  return (url or default_url or ''):gsub('/+$', '')
end

-- Replace absolute home-directory prefixes with "~" for UI-safe display.
function M.tilde_home_path(text)
  if type(text) ~= 'string' or text == '' then
    return text
  end

  local home = normalized_home_path()
  if not home then
    return text
  end
  local escaped = escape_lua_pattern(home)

  text = text:gsub(escaped .. '([/\\])', '~%1')
  text = text:gsub(escaped .. '([^%w%/%._%-])', '~%1')
  text = text:gsub(escaped .. '$', '~')
  return text
end

function M.truncate_session_summary(summary, max_len)
  if type(summary) ~= 'string' or summary == '' then
    return ''
  end
  max_len = tonumber(max_len) or 32
  if max_len < 1 or #summary <= max_len then
    return summary
  end

  local prefix = summary:sub(1, max_len)
  local last_sep_start
  local search_from = 1
  while true do
    local sep_start = prefix:find('[%.,:%s_-]+', search_from)
    if not sep_start then
      break
    end
    last_sep_start = sep_start
    search_from = sep_start + 1
  end

  if last_sep_start and last_sep_start > 1 then
    local trimmed = prefix:sub(1, last_sep_start - 1):gsub('[%.,:%s_-]+$', '')
    if trimmed ~= '' then
      return trimmed
    end
  end

  return prefix
end

local function format_unix_ns_timestamp(ns)
  if type(ns) ~= 'string' or #ns ~= 19 or ns:find('^%d+$') == nil then
    return nil
  end

  local seconds = tonumber(ns:sub(1, #ns - 9))
  if not seconds then
    return nil
  end

  local stamp = os.date('%Y-%m-%dT%H:%M:%S', seconds)
  if type(stamp) ~= 'string' or stamp == '' then
    return nil
  end
  return stamp
end

function M.format_session_id(session_id)
  if type(session_id) ~= 'string' or session_id == '' then
    return ''
  end

  local prefix, timestamp_ns = session_id:match('^(.-)%-(%d+)$')
  if prefix and prefix ~= '' then
    local stamp = format_unix_ns_timestamp(timestamp_ns)
    if stamp then
      return string.format('%s-%s', prefix, stamp)
    end
  end

  return session_id
end

-- Normalise a model entry from the API (handles both camelCase and PascalCase keys).
-- Returns { id, name, label } or nil when the entry is invalid.
function M.normalize_model_entry(entry)
  if type(entry) ~= 'table' then
    return nil
  end

  local id = entry.id or entry.ID
  if type(id) ~= 'string' or id == '' then
    return nil
  end

  local name = entry.name or entry.Name or id
  -- Preserve reasoning effort metadata from the SDK ModelInfo.
  local caps = entry.capabilities or {}
  local supports = caps.supports or {}
  return {
    id = id,
    name = name,
    label = string.format('%s (%s)', name, id),
    supports_reasoning = supports.reasoningEffort == true,
    supported_efforts = entry.supportedReasoningEfforts or {},
    default_effort = entry.defaultReasoningEffort or nil,
  }
end

-- Extract the model name from an "unavailable model" error string.
-- Returns the model string or nil if the error doesn't match.
function M.unavailable_model_from_error(err)
  if type(err) ~= 'string' then
    return nil
  end
  return err:match('Model "([^"]+)" is not available')
end

-- Returns true when the curl error string looks like a connection failure.
function M.is_connection_error(err)
  if type(err) ~= 'string' then
    return false
  end
  for _, pattern in ipairs({
    'Failed to connect',
    "Couldn't connect to server",
    'Connection refused',
    'Empty reply from server',
    'transfer closed with outstanding read data remaining',
    'Connection reset by peer',
    'Recv failure',
  }) do
    if err:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

-- Utility helpers moved from events.lua
function M.append_unique(items, value)
  if type(value) ~= 'string' or value == '' then
    return
  end
  for _, existing in ipairs(items) do
    if existing == value then
      return
    end
  end
  items[#items + 1] = value
end

function M.append_unique_activity_output(parts, text)
  if type(text) == 'string' then
    text = text:gsub('\r\n?', '\n')
  end
  if type(text) ~= 'string' or text == '' then
    return
  end
  for _, existing in ipairs(parts) do
    if existing == text then
      return
    end
  end
  parts[#parts + 1] = text
end

function M.summarize_file_group(verb, items)
  if #items == 0 then
    return nil
  end
  if #items == 1 then
    return verb .. ' ' .. items[1]
  end
  if #items <= 3 then
    return verb .. ' ' .. table.concat(items, ', ')
  end
  return verb .. ' ' .. tostring(#items) .. ' files'
end

function M.first_non_empty(...)
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if type(v) == 'string' and v ~= '' then
      return v
    end
  end
  return nil
end

function M.truncate_session_log_content(text, max_len)
  if type(text) ~= 'string' then
    return text or ''
  end
  max_len = tonumber(max_len) or 0
  if max_len < 1 or #text <= max_len then
    return text
  end
  return text:sub(1, max_len - 1) .. '…'
end

function M.preview_log_text(text, max_len, min_chars, default_max)
  if type(text) ~= 'string' then
    return '<non-string>'
  end
  min_chars = tonumber(min_chars) or 16
  default_max = tonumber(default_max) or math.max(min_chars, 32)
  max_len = math.max(min_chars, math.floor(tonumber(max_len) or default_max))
  if #text > max_len then
    text = text:sub(1, max_len - 1) .. '…'
  end
  return text:gsub('\r\n?', '\n'):gsub('\n', '\\n'):gsub('\t', '\\t')
end

function M.decode_json_silently(raw)
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

return M
