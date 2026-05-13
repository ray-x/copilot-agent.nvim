-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local M = {}

local function extract_patch_text(value, visited)
  if type(value) == 'string' then
    if value:find('*** Begin Patch', 1, true) then
      return value
    end
    return nil
  end
  if type(value) ~= 'table' then
    return nil
  end

  visited = visited or {}
  if visited[value] then
    return nil
  end
  visited[value] = true

  local keys = {
    'start_input',
    'start_data',
    'complete_data',
    'data',
    'input',
    'toolResult',
    'result',
    'output',
    'content',
    'text',
    'patch',
    'diff',
    'command',
    'rawCommand',
    'raw_command',
    'fullCommandText',
    'invocation',
  }
  for _, key in ipairs(keys) do
    local found = extract_patch_text(value[key], visited)
    if found then
      visited[value] = nil
      return found
    end
  end
  for _, nested in pairs(value) do
    local found = extract_patch_text(nested, visited)
    if found then
      visited[value] = nil
      return found
    end
  end

  visited[value] = nil
  return nil
end

local function normalize_verb(header)
  header = type(header) == 'string' and vim.trim(header) or ''
  if header == '' then
    return 'update'
  end
  local lower = header:lower()
  if lower:find('update', 1, true) then
    return 'update'
  end
  if lower:find('add', 1, true) then
    return 'add'
  end
  if lower:find('delete', 1, true) then
    return 'delete'
  end
  if lower:find('move', 1, true) then
    return 'move'
  end
  return lower
end

local function finish_change(changes, change)
  if type(change) ~= 'table' then
    return
  end
  local path = type(change.path) == 'string' and vim.trim(change.path) or ''
  if path == '' then
    return
  end
  change.path = path
  change.additions = math.max(0, tonumber(change.additions) or 0)
  change.deletions = math.max(0, tonumber(change.deletions) or 0)
  changes[#changes + 1] = change
end

local function parse_patch_changes(patch_text)
  if type(patch_text) ~= 'string' or patch_text == '' then
    return {}
  end

  local changes = {}
  local change
  local in_hunk = false

  for line in patch_text:gmatch('[^\r\n]+') do
    local header, path = line:match('^%*%*%* ([^:]+): (.+)$')
    if header and path then
      finish_change(changes, change)
      change = {
        verb = normalize_verb(header),
        path = path,
        additions = 0,
        deletions = 0,
      }
      in_hunk = false
    elseif line:match('^@@') then
      in_hunk = true
    elseif change and in_hunk then
      if line:sub(1, 3) ~= '+++' and line:sub(1, 3) ~= '---' and line:sub(1, 1) == '+' then
        change.additions = (tonumber(change.additions) or 0) + 1
      elseif line:sub(1, 3) ~= '+++' and line:sub(1, 3) ~= '---' and line:sub(1, 1) == '-' then
        change.deletions = (tonumber(change.deletions) or 0) + 1
      end
    end
  end

  finish_change(changes, change)
  return changes
end

local function dedupe_latest_changes(changes)
  if type(changes) ~= 'table' or #changes == 0 then
    return {}
  end
  local seen = {}
  local reversed = {}
  for i = #changes, 1, -1 do
    local change = changes[i]
    local path = type(change) == 'table' and vim.trim(type(change.path) == 'string' and change.path or '') or ''
    if path ~= '' and not seen[path] then
      seen[path] = true
      reversed[#reversed + 1] = vim.deepcopy(change)
    end
  end
  local deduped = {}
  for i = #reversed, 1, -1 do
    deduped[#deduped + 1] = reversed[i]
  end
  return deduped
end

local function truncate_left_display_text(text, max_chars)
  text = type(text) == 'string' and text or ''
  max_chars = math.max(1, math.floor(tonumber(max_chars) or 1))
  if #text <= max_chars then
    return text
  end
  if max_chars <= 1 then
    return '…'
  end
  return '…' .. text:sub(#text - max_chars + 2)
end

local function format_change(change)
  if type(change) ~= 'table' then
    return nil
  end
  local path = type(change.path) == 'string' and change.path ~= '' and change.path or '<unknown>'
  local display_path = path
  if type(vim) == 'table' and type(vim.fn) == 'table' and type(vim.fn.fnamemodify) == 'function' then
    local rel_path = vim.fn.fnamemodify(path, ':.')
    if type(rel_path) == 'string' and rel_path ~= '' and rel_path ~= '.' then
      display_path = rel_path
    end
  end
  display_path = truncate_left_display_text(display_path, 48)
  local additions = math.max(0, tonumber(change.additions) or 0)
  local deletions = math.max(0, tonumber(change.deletions) or 0)
  local verb = normalize_verb(change.verb)

  if verb == 'add' then
    if additions > 0 then
      return string.format('Added %s +%d', display_path, additions)
    end
    return 'Added ' .. display_path
  end
  if verb == 'delete' then
    if deletions > 0 then
      return string.format('Deleted %s -%d', display_path, deletions)
    end
    return 'Deleted ' .. display_path
  end
  if verb == 'move' then
    return 'Moved ' .. display_path
  end

  local parts = { 'Updated ' .. display_path }
  if additions > 0 then
    parts[#parts + 1] = '+' .. tostring(additions)
  end
  if deletions > 0 then
    parts[#parts + 1] = '-' .. tostring(deletions)
  end
  return table.concat(parts, ' ')
end

function M.extract_patch_text(value)
  return extract_patch_text(value)
end

function M.extract_patch_changes(value)
  local patch_text = extract_patch_text(value)
  return dedupe_latest_changes(parse_patch_changes(patch_text))
end

-- Search nested tables/fields for a unified git diff string (e.g. lines starting with 'diff --git ')
local function strip_common_indent(s)
  local lines = {}
  local min_indent = nil
  for line in s:gmatch('[^\r\n]*') do
    if line ~= '' then
      local indent = line:match('^(%s*)') or ''
      local n = #indent
      if min_indent == nil or n < min_indent then
        min_indent = n
      end
    end
    lines[#lines + 1] = line
  end
  if not min_indent or min_indent == 0 then
    return s
  end
  local out = {}
  for _, line in ipairs(lines) do
    if #line >= min_indent then
      out[#out + 1] = line:sub(min_indent + 1)
    else
      out[#out + 1] = ''
    end
  end
  return table.concat(out, '\n')
end

local function extract_codefence_content(s)
  local start_pos = s:find('```', 1, true)
  if not start_pos then
    return nil
  end
  local end_pos = s:find('```', start_pos + 3, true)
  if not end_pos then
    return nil
  end
  return s:sub(start_pos + 3, end_pos - 1)
end

local function extract_unified_diff_text(value, visited)
  if type(value) == 'string' then
    local s = value
    -- If fenced code block, extract inner content
    local fenced = extract_codefence_content(s)
    if fenced then
      s = fenced
    end
    -- Strip common 4-space indent or blockquote markers
    if s:match('\n%s+diff --git') or s:match('\n%s+@@') or s:match('^%s+diff --git') then
      s = strip_common_indent(s)
    end
    -- Remove common leading '> ' quoting
    s = s:gsub('\n> ', '\n')
    -- Now check for indicators
    if s:find('diff --git ', 1, true) or s:find('\n@@', 1, true) or s:find('^@@', 1) then
      return s
    end
    return nil
  end
  if type(value) ~= 'table' then
    return nil
  end
  visited = visited or {}
  if visited[value] then
    return nil
  end
  visited[value] = true
  local keys = {
    'output_text',
    'output',
    'complete_data',
    'data',
    'start_input',
    'start_data',
    'result',
    'toolResult',
    'text',
    'patch',
    'diff',
  }
  for _, key in ipairs(keys) do
    local found = extract_unified_diff_text(value[key], visited)
    if found then
      visited[value] = nil
      return found
    end
  end
  for _, nested in pairs(value) do
    local found = extract_unified_diff_text(nested, visited)
    if found then
      visited[value] = nil
      return found
    end
  end

  -- Fallback: inspect the table to a string and search for embedded diff text.
  if type(vim) == 'table' and type(vim.inspect) == 'function' then
    local inspected = vim.inspect(value)
    visited[value] = nil
    return extract_unified_diff_text(inspected)
  end

  visited[value] = nil
  return nil
end

local function parse_unified_patch_changes(patch_text)
  if type(patch_text) ~= 'string' or patch_text == '' then
    return {}
  end
  local changes = {}
  local change
  local in_hunk = false

  for line in patch_text:gmatch('[^\r\n]+') do
    -- detect git diff header (be permissive; some tools embed paths without 'a/'/'b/' prefixes)
    if line:find('diff --git') then
      local function strip_path(p)
        if not p then
          return p
        end
        p = p:gsub('^%s*', '')
        p = p:gsub('^[ab]%p*', '')
        p = p:gsub('^~/', '')
        return p
      end

      local a_path = line:match('a/(%S+)') or line:match('diff --git%s+(%S+)')
      local b_path = line:match('b/(%S+)') or line:match('diff --git%s+%S+%s+(%S+)')
      a_path = strip_path(a_path)
      b_path = strip_path(b_path)
      finish_change(changes, change)
      change = { verb = 'update', path = b_path or a_path, additions = 0, deletions = 0 }
      in_hunk = false
    elseif line:match('^%-%-%-%s*[ab]?%p*/') or line:match('^%+%+%+%s*[ab]?%p*/') then
      -- ignore file markers (--- a/path or --- /path)
      in_hunk = in_hunk
    elseif line:match('^@@') then
      in_hunk = true
    elseif change and in_hunk then
      local first = line:sub(1, 1)
      if first == '+' and line:sub(1, 3) ~= '+++' then
        change.additions = (tonumber(change.additions) or 0) + 1
      elseif first == '-' and line:sub(1, 3) ~= '---' then
        change.deletions = (tonumber(change.deletions) or 0) + 1
      end
    end
  end
  finish_change(changes, change)
  return changes
end

function M.extract_unified_patch_changes(value)
  local text = extract_unified_diff_text(value)
  return dedupe_latest_changes(parse_unified_patch_changes(text))
end

function M.extract_unified_patch_text(value)
  return extract_unified_diff_text(value)
end

function M.format_change(change)
  return format_change(change)
end

function M.summarize_patch_changes(changes)
  if type(changes) ~= 'table' or #changes == 0 then
    return nil
  end
  return format_change(changes[1])
end

return M
