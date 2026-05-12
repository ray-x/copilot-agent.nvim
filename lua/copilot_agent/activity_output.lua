-- Activity output extraction and tool-activity summarization helpers
-- Factory that accepts dependencies to avoid circular requires in events.lua
local function factory(deps)
  deps = deps or {}
  local utils = deps.utils or require('copilot_agent.utils')
  local sanitize_permission_text = deps.sanitize_permission_text or function(x)
    return x
  end
  local normalize_activity_output_text = deps.normalize_activity_output_text or function(x)
    return x
  end
  local find_activity_string = deps.find_activity_string
  local find_activity_raw_string = deps.find_activity_raw_string
  local find_activity_value = deps.find_activity_value
  local normalize_activity_path = deps.normalize_activity_path
  local apply_patch = deps.apply_patch or require('copilot_agent.apply_patch')
  local state = deps.state
  local looks_like_shell_tool = deps.looks_like_shell_tool

  local M = {}
  local _logger_ok, _logger = pcall(require, 'copilot_agent.log')
  local _serialize_log_value = _logger_ok and _logger.serialize_log_value or function(v, _)
    return tostring(v)
  end
  local _debug_log_path = '/tmp/copilot_agent_debug.log'
  local function _dbg(msg)
    local ok, f = pcall(io.open, _debug_log_path, 'a')
    if not ok or not f then
      return
    end
    f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. tostring(msg) .. '\n')
    f:close()
  end

  local activity_nested_keys = {
    'input',
    'toolInput',
    'tool_input',
    'parameters',
    'params',
    'payload',
    'request',
    'call',
    'invocation',
    'details',
    'metadata',
    'options',
  }

  local function activity_output_is_list(value)
    if vim.islist then
      return vim.islist(value)
    end
    return false
  end

  local append_unique_activity_output = utils.append_unique_activity_output

  local function extract_tool_result_contents_text(contents)
    if type(contents) ~= 'table' then
      return nil
    end
    local parts = {}
    for _, block in ipairs(contents) do
      if type(block) == 'table' then
        local block_type = block.type
        if (block_type == 'text' or block_type == 'terminal') and type(block.text) == 'string' then
          append_unique_activity_output(parts, block.text)
        elseif block_type == 'resource' and type(block.resource) == 'table' and type(block.resource.text) == 'string' then
          append_unique_activity_output(parts, block.resource.text)
        end
      end
    end
    if #parts == 0 then
      return nil
    end
    return table.concat(parts, '\n\n')
  end

  local function inspect_activity_output_value(value)
    local ok, inspected = pcall(vim.inspect, value)
    if not ok then
      return nil
    end
    return normalize_activity_output_text(inspected)
  end

  local function extract_structured_tool_result_text(value, depth, visited)
    if type(value) ~= 'table' then
      return nil, false
    end
    local result_type = sanitize_permission_text(value.resultType)
    if type(result_type) == 'string' then
      result_type = result_type:lower()
    end
    local data = type(value.data) == 'table' and value.data or nil
    if _logger_ok then
      _logger.log(
        string.format('activity_output.extract_structured_tool_result_text result_type=%s data=%s', tostring(result_type), _serialize_log_value(data, { max_len = 600 })),
        vim.log.levels.DEBUG
      )
    end
    _dbg(string.format('activity_output.extract_structured_tool_result_text result_type=%s data=%s', tostring(result_type), _serialize_log_value(data, { max_len = 600 })))
    local handled = (result_type == 'success' or result_type == 'failed' or result_type == 'error') or (data ~= nil and (data.sessionLog ~= nil or data.textResultForLlm ~= nil))
    if not handled then
      return nil, false
    end
    local parts = {}
    if data then
      append_unique_activity_output(parts, M.extract_activity_output_value_text(data.sessionLog, depth + 1, visited))
      append_unique_activity_output(parts, M.extract_activity_output_value_text(data.textResultForLlm, depth + 1, visited))
    end
    if #parts == 0 then
      return nil, true
    end
    return table.concat(parts, '\n\n'), true
  end

  M.extract_activity_output_value_text = function(value, depth, visited)
    if _logger_ok then
      _logger.log('activity_output.extract_activity_output_value_text called with value=' .. (_serialize_log_value(value, { max_len = 300 }) or 'nil'), vim.log.levels.DEBUG)
    end
    _dbg('activity_output.extract_activity_output_value_text called with value=' .. (_serialize_log_value(value, { max_len = 300 }) or 'nil'))
    depth = math.max(1, math.floor(tonumber(depth) or 1))
    if value == nil or depth > 5 then
      return nil
    end
    local value_type = type(value)
    if value_type == 'string' then
      return normalize_activity_output_text(value)
    end
    if value_type == 'number' or value_type == 'boolean' then
      return tostring(value)
    end
    if value_type ~= 'table' then
      return nil
    end

    visited = visited or {}
    if visited[value] then
      return nil
    end
    visited[value] = true

    local structured_tool_result_text, structured_tool_result_handled = extract_structured_tool_result_text(value, depth, visited)
    if structured_tool_result_handled then
      visited[value] = nil
      return structured_tool_result_text
    end

    local parts = {}
    if activity_output_is_list(value) then
      append_unique_activity_output(parts, extract_tool_result_contents_text(value))
      if #parts == 0 then
        for _, item in ipairs(value) do
          append_unique_activity_output(parts, M.extract_activity_output_value_text(item, depth + 1, visited))
        end
      end
    else
      for _, key in ipairs({
        'modifiedResult',
        'toolResult',
        'detailedContent',
        'content',
        'text',
        'summary',
        'message',
        'stdout',
        'stderr',
        'output',
        'result',
        'additionalContext',
        'description',
      }) do
        append_unique_activity_output(parts, M.extract_activity_output_value_text(value[key], depth + 1, visited))
      end
      if type(value.contents) == 'table' then
        append_unique_activity_output(parts, extract_tool_result_contents_text(value.contents))
      end
      if type(value.resource) == 'table' then
        append_unique_activity_output(parts, M.extract_activity_output_value_text(value.resource, depth + 1, visited))
      end
      if type(value.error) == 'table' then
        append_unique_activity_output(parts, M.extract_activity_output_value_text(value.error.message, depth + 1, visited))
      elseif value.error ~= nil then
        append_unique_activity_output(parts, M.extract_activity_output_value_text(value.error, depth + 1, visited))
      end
      if #parts == 0 and find_activity_value then
        for _, key in ipairs(activity_nested_keys) do
          if type(value[key]) == 'table' then
            append_unique_activity_output(parts, M.extract_activity_output_value_text(value[key], depth + 1, visited))
          end
        end
      end
      if #parts == 0 then
        for _, nested in pairs(value) do
          if type(nested) == 'table' then
            append_unique_activity_output(parts, M.extract_activity_output_value_text(nested, depth + 1, visited))
          end
        end
      end
    end

    visited[value] = nil
    if #parts > 0 then
      return table.concat(parts, '\n\n')
    end
    -- If the table is empty (no keys/elements), treat it as no content so
    -- callers can fall back to prior output or other fallbacks instead of
    -- returning a raw '{}'. This prevents spurious '{}' summaries when the
    -- tool returned an empty payload.
    local is_empty_table = (next(value) == nil)
    if is_empty_table then
      _dbg('activity_output: empty table encountered, returning nil to allow fallback')
      return nil
    end
    local inspected = inspect_activity_output_value(value)
    if inspected then
      _dbg('activity_output.inspect fallback=' .. inspected)
    else
      _dbg('activity_output.inspect fallback=nil')
    end
    return inspected
  end

  M.extract_tool_execution_output_text = function(data)
    data = type(data) == 'table' and data or {}
    local result = type(data.result) == 'table' and data.result or nil
    local parts = {}
    if result then
      append_unique_activity_output(parts, result.detailedContent)
      if #parts == 0 then
        append_unique_activity_output(parts, extract_tool_result_contents_text(result.contents))
      end
      if #parts == 0 then
        append_unique_activity_output(parts, result.content)
      end
    end
    if #parts == 0 and type(data.error) == 'table' then
      append_unique_activity_output(parts, data.error.message)
    end
    if #parts == 0 then
      return nil
    end
    return table.concat(parts, '\n\n')
  end

  -- Summarization helpers (depend on find_activity_* helpers passed in)
  local function summarize_apply_patch_activity(data)
    local changes = apply_patch.extract_patch_changes(data)
    if type(changes) ~= 'table' or #changes == 0 then
      return 'Edited files'
    end
    local normalized_changes = {}
    for _, change in ipairs(changes) do
      local normalized = vim.deepcopy(change)
      if type(normalized) == 'table' and normalize_activity_path and type(normalized.path) == 'string' then
        normalized.path = normalize_activity_path(normalized.path) or normalized.path
      end
      normalized_changes[#normalized_changes + 1] = normalized
    end
    local summary = apply_patch.summarize_patch_changes(normalized_changes)
    if type(summary) ~= 'string' or summary == '' then
      return 'Edited files'
    end
    return summary
  end

  local function extract_apply_patch_text(data)
    return apply_patch.extract_patch_text(data)
  end

  local function extract_apply_patch_changes(data)
    return apply_patch.extract_patch_changes(data)
  end

  local function summarize_view_activity(data)
    if not find_activity_string then
      return 'Viewed file'
    end
    local path = find_activity_string(data, { 'path', 'filePath', 'file', 'fileName', 'filename', 'targetPath' })
    if not path then
      return 'Viewed file'
    end
    return 'Viewed ' .. (normalize_activity_path and (normalize_activity_path(path) or path) or path)
  end

  local function summarize_rg_activity(data)
    if not find_activity_string then
      return 'Searched code'
    end
    local pattern = find_activity_string(data, { 'pattern', 'query', 'regex' })
    if pattern and #pattern <= 48 and not pattern:find('%s%s+') then
      return 'Searched for ' .. pattern
    end
    local path = find_activity_string(data, { 'path', 'paths' })
    if path then
      return 'Searched ' .. (normalize_activity_path and normalize_activity_path(path) or path)
    end
    return 'Searched code'
  end

  local function summarize_sql_activity(data)
    if not find_activity_string then
      return 'Queried SQL'
    end
    local description = find_activity_string(data, { 'description', 'summary' })
    if description then
      return description
    end
    local database = find_activity_string(data, { 'database' })
    if database then
      return 'Queried ' .. database
    end
    return 'Queried SQL'
  end

  local function summarize_shell_command_for_activity(data)
    if not find_activity_value then
      return nil
    end
    local structured = find_activity_value(data, 1, {}, function(tbl)
      local command = sanitize_permission_text(tbl.command or tbl.executable or tbl.program or tbl.cmd)
      if not command then
        return nil
      end
      local parts = { command }
      local arg_values = tbl.arguments or tbl.args or tbl.argv or tbl.commandArgs or tbl.command_args
      if type(arg_values) == 'table' then
        local total_len = #command
        for _, value in ipairs(arg_values) do
          local arg = sanitize_permission_text(value)
          if arg then
            if #parts >= 5 or total_len + #arg + 1 > 72 then
              parts[#parts + 1] = '…'
              break
            end
            parts[#parts + 1] = arg
            total_len = total_len + #arg + 1
          end
        end
      elseif type(arg_values) == 'string' then
        local args = sanitize_permission_text(arg_values)
        if args then
          if #command + #args + 1 > 72 then
            parts[#parts + 1] = '…'
          else
            parts[#parts + 1] = args
          end
        end
      end
      return table.concat(parts, ' ')
    end)
    if structured then
      return structured
    end
    local full = find_activity_string
      and find_activity_string(data, {
        'fullCommandText',
        'commandLine',
        'commandText',
        'shellCommand',
        'rawCommand',
        'raw_command',
        'invocation',
      })
    if not full then
      return nil
    end
    local raw = (find_activity_raw_string and find_activity_raw_string(data, function(text)
      return text == full or sanitize_permission_text(text) == full
    end)) or full
    if raw:find('\n', 1, true) or #full > 96 or full:find('<<', 1, true) or full:find('*** Begin Patch', 1, true) then
      local first = full:match('^([^%s]+)')
      if first and first ~= '' then
        return first .. ' script'
      end
    end
    return full
  end

  M.summarize_tool_activity = function(tool_name, data)
    local tool = sanitize_permission_text(tool_name)
    if not tool then
      return nil
    end
    local normalized = tool:lower()
    if normalized == 'report_intent' then
      local detail = find_activity_string and find_activity_string(data, { 'intent', 'description', 'summary', 'intention' })
      if detail and detail ~= '' then
        return 'Used report_intent ' .. detail
      end
      return 'Used report_intent'
    end
    if normalized == 'apply_patch' then
      return summarize_apply_patch_activity(data)
    end
    if looks_like_shell_tool and looks_like_shell_tool(tool) then
      local detail = summarize_shell_command_for_activity(data) or (state and state.pending_tool_detail)
      if detail and detail:match(' script$') then
        return 'Ran ' .. detail
      end
      if detail and detail ~= '' and detail ~= tool then
        return 'Ran ' .. tool .. ' — ' .. detail
      end
      return 'Ran ' .. tool
    end
    if normalized == 'view' then
      return summarize_view_activity(data)
    end
    if normalized == 'rg' or normalized == 'glob' or (string.find(normalized, 'search', 1, true) ~= nil) then
      return summarize_rg_activity(data)
    end
    if normalized == 'sql' then
      return summarize_sql_activity(data)
    end
    if normalized == 'web_fetch' then
      local url = find_activity_string and find_activity_string(data, { 'url' })
      if url then
        return 'Fetched ' .. url
      end
      return 'Fetched web page'
    end
    if normalized == 'view' or (string.find(normalized, 'read', 1, true) ~= nil or string.find(normalized, 'get_file', 1, true) ~= nil) then
      local path = find_activity_string and find_activity_string(data, { 'path', 'filePath', 'file', 'fileName', 'filename', 'targetPath' })
      if path then
        return 'Read ' .. (normalize_activity_path and normalize_activity_path(path) or path)
      end
      return 'Read file'
    end
    local detail = find_activity_string and find_activity_string(data, { 'description', 'toolDescription', 'intention', 'summary' })
    if detail and detail ~= '' and detail ~= tool then
      return 'Used ' .. tool .. ' — ' .. detail
    end
    return 'Used ' .. tool
  end

  -- export helpers
  M.activity_output_is_list = activity_output_is_list
  M.extract_tool_result_contents_text = extract_tool_result_contents_text
  M.inspect_activity_output_value = inspect_activity_output_value
  M.extract_structured_tool_result_text = extract_structured_tool_result_text
  M.extract_activity_output_value_text = M.extract_activity_output_value_text
  M.extract_tool_execution_output_text = M.extract_tool_execution_output_text
  M.summarize_tool_activity = M.summarize_tool_activity
  M.summarize_apply_patch_activity = summarize_apply_patch_activity
  M.extract_apply_patch_text = extract_apply_patch_text
  M.extract_apply_patch_changes = extract_apply_patch_changes
  M.summarize_view_activity = summarize_view_activity
  M.summarize_rg_activity = summarize_rg_activity
  M.summarize_sql_activity = summarize_sql_activity
  M.summarize_shell_command_for_activity = summarize_shell_command_for_activity

  return M
end

return factory
