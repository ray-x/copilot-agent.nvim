-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local chat = require('copilot_agent.chat')
local checkpoints = require('copilot_agent.checkpoints')
local discovery = require('copilot_agent.discovery')
local events = require('copilot_agent.events')
local http = require('copilot_agent.http')
local init_project = require('copilot_agent.project_init')
local lsp = require('copilot_agent.lsp')
local model = require('copilot_agent.model')
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
local request = http.request

local M = {}
local search_label_max_len = 72
local working_directory = service.working_directory
local mode_permission = {
  ask = 'interactive',
  plan = 'interactive',
  agent = 'approve-reads',
  autopilot = 'approve-all',
}

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

local function run_command(args, cwd)
  if vim.system then
    local result = vim.system(args, { text = true, cwd = cwd }):wait()
    local output = vim.trim((result.stdout or '') ~= '' and result.stdout or (result.stderr or ''))
    if result.code ~= 0 then
      return nil, output ~= '' and output or table.concat(args, ' ')
    end
    return output, nil
  end

  local output = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(table.concat(output, '\n'))
  end
  return vim.trim(table.concat(output, '\n')), nil
end

local function open_path(path)
  if type(path) ~= 'string' or path == '' then
    return
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

local function matching_item(items, query)
  query = vim.trim(query or ''):lower()
  if query == '' then
    return nil
  end
  for _, item in ipairs(items or {}) do
    local name = (item.name or ''):lower()
    local path = (item.path or ''):lower()
    if name == query or path == query or vim.endswith(path, query) then
      return item
    end
  end
  for _, item in ipairs(items or {}) do
    if (item.name or ''):lower():find(query, 1, true) then
      return item
    end
  end
  return nil
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

local function select_model_command(args)
  if args ~= '' then
    model.select_model(args)
    return true
  end
  model.select_model()
  return true
end

local function resume_session_command(args)
  if args ~= '' then
    session.switch_to_session_id(args)
    return true
  end
  session.switch_session()
  return true
end

local function new_session_command()
  session.new_session()
  return true
end

local function clear_session_command()
  session.clear_and_new_session()
  return true
end

local function session_command(args)
  local action = vim.trim(args or '')
  if action == '' then
    session.switch_session()
    return true
  end
  if action == 'new' then
    session.new_session()
    return true
  end
  if action == 'clear' then
    session.clear_and_new_session()
    return true
  end
  session.switch_to_session_id(action)
  return true
end

local function set_input_mode(mode)
  local next_mode = vim.trim(mode or ''):lower()
  if next_mode == '' then
    notify('Mode is required', vim.log.levels.WARN)
    return
  end
  if not mode_permission[next_mode] then
    notify('Unsupported mode: ' .. next_mode, vim.log.levels.WARN)
    return
  end

  state.input_mode = next_mode
  require('copilot_agent')._set_agent_mode(next_mode)

  local had_manual = state.permission_mode_manual
  state.permission_mode_manual = false
  local natural_perm = mode_permission[next_mode]
  if natural_perm and not had_manual and natural_perm ~= state.permission_mode then
    state.permission_mode = natural_perm
    if state.session_id then
      request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = natural_perm }, function(_, err)
        if err then
          notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
        end
      end)
    end
  end

  refresh_statuslines()
  append_entry('system', 'Mode: ' .. next_mode)
end

local function plan_mode_command(args)
  set_input_mode('plan')
  args = vim.trim(args or '')
  if args ~= '' then
    state.prompt_prefill = args
    require('copilot_agent').open_chat({ activate_input_on_session_ready = false })
    require('copilot_agent')._open_input_window()
  end
  return true
end

local function allow_all_command()
  local next_mode = 'approve-all'
  state.permission_mode = next_mode
  state.permission_mode_manual = true
  if state.session_id then
    request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = next_mode }, function(_, err)
      if err then
        append_entry('error', 'Failed to set permission mode: ' .. tostring(err))
      end
    end)
  end
  refresh_statuslines()
  append_entry('system', 'Permission mode: ' .. next_mode)
  return true
end

local function context_command()
  if not state.context_tokens or not state.context_limit or state.context_limit <= 0 then
    notify('Context window usage is not available yet for this session', vim.log.levels.INFO)
    return true
  end
  local percent = math.floor((state.context_tokens / state.context_limit) * 100 + 0.5)
  append_entry('system', string.format('Context window: %d / %d tokens (%d%%)', state.context_tokens, state.context_limit, percent))
  return true
end

local function usage_command()
  local lines = {
    'Session usage snapshot:',
    '  Session: ' .. tostring(state.session_id or '<none>'),
    '  Model: ' .. tostring(state.current_model or state.config.session.model or '<default>'),
    '  Mode: ' .. tostring(state.input_mode or 'agent'),
    '  Permission: ' .. tostring(state.permission_mode or 'interactive'),
    string.format(
      '  Config discovery: %d instructions, %d agents, %d skills, %d MCP servers',
      tonumber(state.instruction_count) or 0,
      tonumber(state.agent_count) or 0,
      tonumber(state.skill_count) or 0,
      tonumber(state.mcp_count) or 0
    ),
  }
  if state.context_tokens and state.context_limit and state.context_limit > 0 then
    lines[#lines + 1] = string.format('  Context window: %d / %d tokens', state.context_tokens, state.context_limit)
  end
  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function cwd_command(args)
  args = vim.trim(args or '')
  if args == '' then
    append_entry('system', 'Working directory: ' .. working_directory())
    return true
  end

  local resolved = vim.fn.fnamemodify(args, ':p')
  if vim.fn.isdirectory(resolved) ~= 1 then
    append_entry('error', 'Directory does not exist: ' .. args)
    return true
  end

  state.config.session.working_directory = resolved
  append_entry('system', 'Working directory set to ' .. vim.fn.fnamemodify(resolved, ':~'))
  if state.session_id then
    append_entry('system', 'Use /new or /resume to attach a session in the new directory')
  end
  return true
end

local function diff_command(args)
  local cwd = working_directory()
  local git_root, git_err = run_command({ 'git', '-C', cwd, 'rev-parse', '--show-toplevel' }, cwd)
  if git_err then
    append_entry('error', 'Diff unavailable: ' .. git_err)
    return true
  end

  local prefix, prefix_err = run_command({ 'git', '-C', cwd, 'rev-parse', '--show-prefix' }, cwd)
  if prefix_err then
    append_entry('error', 'Diff unavailable: ' .. prefix_err)
    return true
  end
  local pathspec = prefix ~= '' and prefix or '.'

  local diff_args = { 'git', '--no-pager', '-C', git_root, 'diff', '--stat', '--', pathspec }
  if vim.trim(args or '') == 'cached' then
    diff_args = { 'git', '--no-pager', '-C', git_root, 'diff', '--cached', '--stat', '--', pathspec }
  end

  local output, diff_err = run_command(diff_args, git_root)
  if diff_err then
    append_entry('error', 'Diff failed: ' .. diff_err)
    return true
  end
  if output == '' then
    append_entry('system', 'Working tree is clean')
    return true
  end

  append_entry('system', 'Git diff summary for ' .. vim.fn.fnamemodify(git_root, ':~') .. ':\n' .. output)
  return true
end

local function env_command()
  local service_command = service.service_command()
  local command_text = type(service_command) == 'table' and table.concat(service_command, ' ') or tostring(service_command)
  local lines = {
    'Environment snapshot:',
    '  Working directory: ' .. tostring(working_directory()),
    '  Service cwd: ' .. tostring(service.service_cwd()),
    '  Service command: ' .. command_text,
    '  Base URL: ' .. tostring(state.config.base_url),
    '  Session: ' .. tostring(state.session_id or '<none>'),
    '  Model: ' .. tostring(state.current_model or state.config.session.model or '<default>'),
    '  Mode: ' .. tostring(state.input_mode or 'agent'),
    '  Permission: ' .. tostring(state.permission_mode or 'interactive'),
    '  Auto-start service: ' .. tostring(state.config.service.auto_start == true),
  }
  append_entry('system', table.concat(lines, '\n'))
  return true
end

local function agent_command(args)
  local items = discovery.agent_items()
  if vim.tbl_isempty(items) then
    notify('No custom agents found in .github/agents', vim.log.levels.INFO)
    return true
  end

  local function apply_agent(item)
    state.config.session.agent = item and item.name or nil
    if item then
      append_entry('system', 'Agent for next session: ' .. item.name)
      if state.session_id then
        append_entry('system', 'Use /new to start a session with the selected agent')
      end
    else
      append_entry('system', 'Reset to the default agent for future sessions')
    end
  end

  args = vim.trim(args or '')
  if args == 'default' or args == 'clear' then
    apply_agent(nil)
    return true
  end
  if args ~= '' then
    local item = matching_item(items, args)
    if not item then
      append_entry('error', 'Unknown agent: ' .. args)
      return true
    end
    apply_agent(item)
    return true
  end

  local choices = { { name = 'Default agent', path = '' } }
  vim.list_extend(choices, items)
  vim.ui.select(choices, {
    prompt = 'Select agent for future sessions',
    format_item = function(item)
      if item.path == '' then
        return item.name
      end
      return string.format('%s  [%s]', item.name, vim.fn.fnamemodify(item.path, ':~:.'))
    end,
  }, function(choice)
    if choice then
      apply_agent(choice.path == '' and nil or choice)
    end
  end)
  return true
end

local function open_discovered_item(kind, items, args)
  if vim.tbl_isempty(items) then
    notify('No ' .. kind .. ' entries found', vim.log.levels.INFO)
    return true
  end

  args = vim.trim(args or '')
  if args ~= '' then
    local item = matching_item(items, args)
    if not item then
      append_entry('error', 'Unknown ' .. kind .. ': ' .. args)
      return true
    end
    open_path(item.path)
    return true
  end

  vim.ui.select(items, {
    prompt = 'Open ' .. kind,
    format_item = function(item)
      return string.format('%s  [%s]', item.name, vim.fn.fnamemodify(item.path, ':~:.'))
    end,
  }, function(choice)
    if choice then
      open_path(choice.path)
    end
  end)
  return true
end

local function skills_command(args)
  return open_discovered_item('skill', discovery.skill_items(), args)
end

local function instructions_command(args)
  return open_discovered_item('instruction', discovery.instruction_items(), args)
end

local function mcp_command(args)
  return open_discovered_item('MCP config', discovery.mcp_items(), args)
end

local function lsp_status_message()
  local parts = {
    'LSP status:',
    '  Active client id: ' .. tostring(state.lsp_client_id or '<none>'),
    '  Root: ' .. tostring(working_directory()),
    '  Service cwd: ' .. tostring(service.service_cwd()),
  }
  return table.concat(parts, '\n')
end

local function lsp_command(args)
  local action = vim.trim(args or '')

  local function run(choice)
    if not choice or choice == '' or choice == 'status' then
      append_entry('system', lsp_status_message())
      return
    end
    if choice == 'start' then
      local client_id = lsp.start_lsp({ root_dir = working_directory() })
      append_entry('system', client_id and ('Started Copilot LSP client ' .. client_id) or 'Failed to start Copilot LSP')
      return
    end
    if choice == 'install' then
      lsp.install_binary()
      append_entry('system', 'Installing Copilot agent binary…')
      return
    end
    append_entry('error', 'Unknown /lsp action: ' .. choice)
  end

  if action ~= '' then
    run(action)
    return true
  end

  vim.ui.select({
    { id = 'status', label = 'Show LSP status' },
    { id = 'start', label = 'Start LSP for current workspace' },
    { id = 'install', label = 'Install or update binary' },
  }, {
    prompt = 'Copilot LSP',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    run(choice and choice.id or nil)
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

local function compact_result_message(result)
  if type(result) ~= 'table' then
    return 'History compaction finished'
  end

  local parts = {}
  if result.success == false then
    local err = vim.trim(result.error or '')
    return err ~= '' and ('History compaction failed: ' .. err) or 'History compaction failed'
  end
  if tonumber(result.messagesRemoved) then
    parts[#parts + 1] = string.format('%d messages removed', tonumber(result.messagesRemoved))
  end
  if tonumber(result.tokensRemoved) then
    parts[#parts + 1] = string.format('%d tokens freed', tonumber(result.tokensRemoved))
  end

  local context = result.contextWindow
  if type(context) == 'table' and tonumber(context.currentTokens) and tonumber(context.tokenLimit) then
    parts[#parts + 1] = string.format('%d/%d tokens', tonumber(context.currentTokens), tonumber(context.tokenLimit))
  end

  if #parts == 0 then
    return 'History compacted successfully'
  end
  return 'History compacted: ' .. table.concat(parts, ', ')
end

local function compact_history()
  session.with_session(function(session_id, err)
    if err then
      append_entry('error', err)
      return
    end

    request('POST', string.format('/sessions/%s/compact', session_id), {}, function(response, request_err)
      if request_err then
        append_entry('error', 'Compaction failed: ' .. request_err)
        return
      end

      local result = response and response.result or nil
      if type(result) == 'table' and result.success == false then
        append_entry('error', compact_result_message(result))
        return
      end

      if type(result) == 'table' and type(result.contextWindow) == 'table' then
        state.context_tokens = tonumber(result.contextWindow.currentTokens) or state.context_tokens
        state.context_limit = tonumber(result.contextWindow.tokenLimit) or state.context_limit
        refresh_statuslines()
      end

      events.reload_session_history(session_id, function(reload_err)
        if reload_err then
          append_entry('error', 'Compaction succeeded but history reload failed: ' .. reload_err)
          return
        end
        append_entry('system', compact_result_message(result))
      end)
    end)
  end)
  return true
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
  compact = compact_history,
  context = context_command,
  cwd = cwd_command,
  diff = diff_command,
  env = env_command,
  agent = agent_command,
  fleet = fleet_mode,
  init = init_repository,
  instructions = instructions_command,
  lsp = lsp_command,
  mcp = mcp_command,
  ['new'] = new_session_command,
  model = select_model_command,
  plan = plan_mode_command,
  rename = rename_session,
  resume = resume_session_command,
  search = search_transcript,
  session = session_command,
  share = share_session,
  skills = skills_command,
  tasks = session_tasks,
  usage = usage_command,
  ['allow-all'] = allow_all_command,
  clear = clear_session_command,
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
