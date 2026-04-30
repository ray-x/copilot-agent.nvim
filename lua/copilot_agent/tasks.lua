-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local render = require('copilot_agent.render')
local session = require('copilot_agent.session')

local state = cfg.state
local notify = cfg.notify
local append_entry = render.append_entry
local request = http.request

local M = {}

local STATUS_ICON = {
  running = '[running]',
  inbox = '[inbox]',
  idle = '[idle]',
  failed = '[failed]',
  completed = '[done]',
}

local function trim(text)
  return vim.trim(text or '')
end

local function format_timestamp(value)
  value = trim(value)
  if value == '' then
    return nil
  end
  return value:gsub('T', ' '):gsub('Z$', ' UTC')
end

local function task_label(task)
  local icon = STATUS_ICON[task.status] or '[' .. trim(task.status) .. ']'
  local title = trim(task.title)
  if title == '' then
    title = trim(task.description)
  end
  if title == '' then
    title = trim(task.agentType)
  end
  if title == '' then
    title = trim(task.id)
  end

  local suffix = format_timestamp(task.updatedAt)
  if suffix then
    return string.format('%s %s — %s', icon, title, suffix)
  end
  return string.format('%s %s', icon, title)
end

local function contains_query(task, query)
  if query == '' then
    return true
  end

  local haystack = table
    .concat({
      trim(task.id),
      trim(task.kind),
      trim(task.status),
      trim(task.title),
      trim(task.description),
      trim(task.summary),
      trim(task.agentType),
      trim(task.agentName),
    }, '\n')
    :lower()

  return haystack:find(query, 1, true) ~= nil
end

local function task_details(task)
  local lines = {
    string.format('Task: %s', trim(task.title) ~= '' and task.title or task.id),
    string.format('Status: %s', trim(task.status) ~= '' and task.status or 'unknown'),
    string.format('Kind: %s', trim(task.kind) ~= '' and task.kind or 'unknown'),
  }

  local function add(label, value)
    value = trim(value)
    if value ~= '' then
      lines[#lines + 1] = string.format('%s: %s', label, value)
    end
  end

  add('Task ID', task.id)
  add('Agent ID', task.agentId)
  add('Agent type', task.agentType)
  add('Agent name', task.agentName)
  add('Tool call ID', task.toolCallId)
  add('Entry ID', task.entryId)
  add('Started', format_timestamp(task.startedAt))
  add('Updated', format_timestamp(task.updatedAt))
  add('Completed', format_timestamp(task.completedAt))
  add('Model', task.model)
  add('Description', task.description)
  add('Summary', task.summary)
  add('Error', task.error)

  if task.durationMs then
    lines[#lines + 1] = string.format('Duration: %.0f ms', tonumber(task.durationMs) or 0)
  end
  if task.totalTokens then
    lines[#lines + 1] = string.format('Total tokens: %.0f', tonumber(task.totalTokens) or 0)
  end
  if task.totalToolCalls then
    lines[#lines + 1] = string.format('Total tool calls: %.0f', tonumber(task.totalToolCalls) or 0)
  end
  if trim(task.prompt) ~= '' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Prompt:'
    for _, line in ipairs(vim.split(task.prompt, '\n', { plain = true })) do
      lines[#lines + 1] = '  ' .. line
    end
  end

  return table.concat(lines, '\n')
end

local function choose_task_action(task)
  local actions = {
    { id = 'details', label = 'Show details' },
  }
  if trim(task.prompt) ~= '' then
    actions[#actions + 1] = { id = 'reuse', label = 'Reuse prompt in input' }
  end

  vim.ui.select(actions, {
    prompt = 'Task action',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.id == 'reuse' then
      state.prompt_prefill = task.prompt
      require('copilot_agent').open_chat({ activate_input_on_session_ready = false })
      require('copilot_agent')._open_input_window()
      notify('Loaded task prompt into the input buffer', vim.log.levels.INFO)
      return
    end
    append_entry('system', task_details(task))
  end)
end

function M.show(args)
  local query = trim(args):lower()
  session.with_session(function(session_id, err)
    if err then
      append_entry('error', err)
      return
    end

    request('GET', string.format('/sessions/%s/tasks', session_id), nil, function(response, request_err)
      if request_err then
        append_entry('error', 'Failed to load tasks: ' .. request_err)
        return
      end

      local tasks = {}
      for _, task in ipairs((response and response.tasks) or {}) do
        if contains_query(task, query) then
          task.label = task_label(task)
          tasks[#tasks + 1] = task
        end
      end

      if vim.tbl_isempty(tasks) then
        notify(query ~= '' and ('No tasks match "' .. query .. '"') or 'No background tasks found for this session', vim.log.levels.INFO)
        return
      end

      vim.ui.select(tasks, {
        prompt = query ~= '' and ('Tasks matching "' .. query .. '"') or 'Session background tasks',
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if choice then
          choose_task_action(choice)
        end
      end)
    end)
  end)
  return true
end

return M
