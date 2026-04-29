-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local chat = require('copilot_agent.chat')
local checkpoints = require('copilot_agent.checkpoints')
local init_project = require('copilot_agent.project_init')
local render = require('copilot_agent.render')
local service = require('copilot_agent.service')
local session = require('copilot_agent.session')
local session_names = require('copilot_agent.session_names')
local sl = require('copilot_agent.statusline')
local tasks = require('copilot_agent.tasks')

local state = cfg.state
local notify = cfg.notify
local append_entry = render.append_entry
local refresh_statuslines = sl.refresh_statuslines

local M = {}
local search_label_max_len = 72
local working_directory = service.working_directory

local function parse(text)
  if type(text) ~= 'string' then
    return nil
  end

  local command, args = vim.trim(text):match('^/([%w%-]+)%s*(.*)$')
  if not command then
    return nil
  end
  return command:lower(), vim.trim(args or '')
end

local function rename_session(args)
  if not state.session_id then
    notify('No active session to rename', vim.log.levels.WARN)
    return true
  end

  local default_name = session_names.get(state.session_id) or state.session_name or ''
  local function apply_name(name)
    name = vim.trim(name or '')
    if name == '' then
      return
    end

    local ok, err = session_names.set(state.session_id, name)
    if not ok then
      append_entry('error', 'Failed to rename session: ' .. tostring(err))
      return
    end

    state.session_name = name
    refresh_statuslines()
    append_entry('system', 'Session renamed to ' .. name)
  end

  if args ~= '' then
    apply_name(args)
    return true
  end

  vim.ui.input({ prompt = 'Rename session: ', default = default_name }, function(input)
    apply_name(input)
  end)
  return true
end

local function truncate_label(text)
  if #text <= search_label_max_len then
    return text
  end
  return text:sub(1, search_label_max_len - 1) .. '…'
end

local function jump_to_line(line)
  require('copilot_agent').open_chat({ activate_input_on_session_ready = false })
  local winid = chat.find_chat_window()
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd('normal! zz')
  end)
end

local function run_search(query)
  query = vim.trim(query or '')
  if query == '' then
    return
  end
  if vim.tbl_isempty(state.entries) then
    notify('No transcript entries to search', vim.log.levels.INFO)
    return
  end

  local needle = query:lower()
  local matches = {}
  local line_cursor = 1

  for idx, entry in ipairs(state.entries) do
    local lines = render.entry_lines(entry, idx, false)
    for offset, line in ipairs(lines) do
      if line:lower():find(needle, 1, true) then
        local kind = (entry.kind or 'entry'):gsub('^%l', string.upper)
        local text = vim.trim(line)
        matches[#matches + 1] = {
          line = line_cursor + offset - 1,
          label = string.format('%s: %s', kind, truncate_label(text ~= '' and text or line)),
        }
      end
    end
    line_cursor = line_cursor + #lines
  end

  if vim.tbl_isempty(matches) then
    notify('No transcript matches for "' .. query .. '"', vim.log.levels.INFO)
    return
  end

  vim.ui.select(matches, {
    prompt = string.format('Search transcript (%d matches)', #matches),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      jump_to_line(choice.line)
    end
  end)
end

local function search_transcript(args)
  if args ~= '' then
    run_search(args)
    return true
  end

  vim.ui.input({ prompt = 'Search transcript: ' }, function(input)
    run_search(input)
  end)
  return true
end

local function transcript_lines()
  local lines = {}
  for idx, entry in ipairs(state.entries) do
    vim.list_extend(lines, render.entry_lines(entry, idx, true))
  end
  return lines
end

local function markdown_document()
  return table.concat(transcript_lines(), '\n') .. '\n'
end

local function html_escape(text)
  return (text:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

local function html_document()
  local body = html_escape(table.concat(transcript_lines(), '\n'))
  return table.concat({
    '<!DOCTYPE html>',
    '<html lang="en">',
    '<head>',
    '  <meta charset="utf-8">',
    '  <meta name="viewport" content="width=device-width, initial-scale=1">',
    '  <title>Copilot Agent Session Export</title>',
    '  <style>',
    '    body { margin: 0; background: #0d1117; color: #c9d1d9; font: 14px/1.5 ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace; }',
    '    main { max-width: 960px; margin: 0 auto; padding: 24px; }',
    '    pre { white-space: pre-wrap; word-break: break-word; }',
    '  </style>',
    '</head>',
    '<body>',
    '  <main>',
    '    <pre>' .. body .. '</pre>',
    '  </main>',
    '</body>',
    '</html>',
  }, '\n')
end

local function write_export(path, content)
  path = vim.fn.fnamemodify(path, ':p')
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f, err = io.open(path, 'w')
  if not f then
    return nil, err
  end
  f:write(content)
  f:close()
  return path
end

local function export_session(format_name, path)
  if vim.tbl_isempty(state.entries) then
    notify('No transcript entries to share', vim.log.levels.INFO)
    return
  end

  local content = format_name == 'html' and html_document() or markdown_document()
  local written, err = write_export(path, content)
  if not written then
    append_entry('error', 'Failed to export session: ' .. tostring(err))
    return
  end
  append_entry('system', 'Session export written to ' .. vim.fn.fnamemodify(written, ':~'))
end

local function default_export_path(format_name)
  local ext = format_name == 'html' and 'html' or 'md'
  return string.format('%s/copilot-session-%s.%s', working_directory(), os.date('%Y%m%d-%H%M%S'), ext)
end

local function resolve_share_request(args)
  local format_name
  local path
  local first, rest = vim.trim(args or ''):match('^(%S+)%s*(.*)$')
  if first == 'html' then
    format_name = 'html'
    path = rest
  elseif first == 'markdown' or first == 'md' or first == 'file' then
    format_name = 'markdown'
    path = rest
  elseif first and first ~= '' then
    path = args
  end
  return format_name, vim.trim(path or '')
end

local function share_session(args)
  local requested_format, requested_path = resolve_share_request(args)
  local function prompt_path(format_name)
    vim.ui.input({
      prompt = 'Export path: ',
      default = requested_path ~= '' and requested_path or default_export_path(format_name),
      completion = 'file',
    }, function(path)
      path = vim.trim(path or '')
      if path ~= '' then
        export_session(format_name, path)
      end
    end)
  end

  if requested_format then
    prompt_path(requested_format)
    return true
  end

  vim.ui.select({
    { id = 'markdown', label = 'Markdown (.md)' },
    { id = 'html', label = 'HTML (.html)' },
  }, {
    prompt = 'Share session as',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      prompt_path(choice.id)
    end
  end)
  return true
end

local function init_repository(args)
  return init_project.run(args)
end

local function start_fleet(prompt)
  session.with_session(function(session_id, err)
    if err then
      append_entry('error', err)
      return
    end

    request('POST', string.format('/sessions/%s/fleet', session_id), { prompt = prompt ~= '' and prompt or nil }, function(response, request_err)
      if request_err then
        append_entry('error', 'Fleet start failed: ' .. request_err)
        return
      end

      if response and response.started then
        append_entry('system', prompt ~= '' and ('Fleet mode started: ' .. prompt) or 'Fleet mode started')
        return
      end

      append_entry('system', 'Fleet mode request was accepted, but the runtime did not report a started state')
    end)
  end)
end

local function fleet_mode(args)
  if args ~= '' then
    start_fleet(args)
    return true
  end

  vim.ui.input({ prompt = 'Fleet prompt (optional): ' }, function(input)
    if input == nil then
      return
    end
    start_fleet(vim.trim(input))
  end)
  return true
end

local function session_tasks(args)
  return tasks.show(args)
end

local function undo_checkpoint()
  if not state.session_id then
    notify('No active session to undo', vim.log.levels.WARN)
    return true
  end

  checkpoints.undo(state.session_id, function(err)
    if err and err ~= '' then
      if err == 'No checkpoints available' then
        notify(err, vim.log.levels.INFO)
        return
      end
      append_entry('error', 'Undo failed: ' .. err)
      return
    end
    append_entry('system', 'Restored latest checkpoint')
  end)
  return true
end

local function rewind_checkpoint()
  if not state.session_id then
    notify('No active session to rewind', vim.log.levels.WARN)
    return true
  end

  checkpoints.rewind(state.session_id, function(err)
    if err and err ~= '' then
      if err == 'No checkpoints available' then
        notify(err, vim.log.levels.INFO)
        return
      end
      append_entry('error', 'Rewind failed: ' .. err)
      return
    end
  end)
  return true
end

local handlers = {
  fleet = fleet_mode,
  init = init_repository,
  rename = rename_session,
  search = search_transcript,
  share = share_session,
  tasks = session_tasks,
  undo = undo_checkpoint,
  rewind = rewind_checkpoint,
}

function M.execute(text, opts)
  local command, args = parse(text)
  if not command then
    return false
  end

  local handler = handlers[command]
  if not handler then
    return false
  end
  return handler(args, opts or {}) == true
end

return M
