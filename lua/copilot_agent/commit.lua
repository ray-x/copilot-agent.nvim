-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local utils = require('copilot_agent.utils')

local state = cfg.state
local notify = cfg.notify
local request = http.request
local split_lines = utils.split_lines
local working_directory = service.working_directory
local active_session_model = cfg.active_session_model

local M = {}

local COMMIT_AGENT_NAME = 'Git Commit Agent'
local COMMIT_MESSAGE_TIMEOUT_MS = 120000
local COMMIT_MESSAGE_POLL_INTERVAL_MS = 400
local COMMIT_MESSAGE_DIFF_LIMIT = 50000

local function run_command(args, cwd)
  if vim.system then
    local result = vim.system(args, { text = true, cwd = cwd }):wait()
    local output = (result.stdout or '') ~= '' and result.stdout or (result.stderr or '')
    if result.code ~= 0 then
      return nil, vim.trim(output ~= '' and output or table.concat(args, ' '))
    end
    return vim.trim(output), nil
  end

  local output = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(table.concat(output, '\n'))
  end
  return vim.trim(table.concat(output, '\n')), nil
end

local function now_ms()
  local uv = vim.uv or vim.loop
  return uv and uv.now and uv.now() or math.floor(vim.fn.reltimefloat(vim.fn.reltime()) * 1000)
end

local function sanitize_commit_message(text)
  if text == nil then
    return ''
  end
  if type(text) ~= 'string' then
    text = tostring(text)
  end
  text = text:gsub('%z', ''):gsub('\r\n?', '\n')

  local fenced = text:match('^```[%w_-]*\n(.*)\n```$')
  if fenced then
    text = fenced
  end

  text = text:gsub('^Commit message:%s*\n?', '')
  return vim.trim(text)
end

local function last_assistant_message()
  for idx = #(state.entries or {}), 1, -1 do
    local entry = state.entries[idx]
    if type(entry) == 'table' and entry.kind == 'assistant' then
      local content = sanitize_commit_message(entry.content)
      if content ~= '' then
        return content
      end
    end
  end
  return nil
end

local function resolve_repo_root()
  local wd = working_directory()
  local output, err = run_command({ 'git', '-C', wd, 'rev-parse', '--show-toplevel' }, wd)
  if err then
    return nil, err
  end
  if output == '' then
    return nil, 'Not inside a git repository'
  end
  return output, nil
end

local function commit_message_path(repo_root)
  local output, err = run_command({ 'git', '-C', repo_root, 'rev-parse', '--git-path', 'COMMIT_EDITMSG' }, repo_root)
  if err then
    return nil, err
  end
  if output == '' then
    return nil, 'Unable to resolve COMMIT_EDITMSG path'
  end
  if not vim.startswith(output, '/') and not output:match('^%a:[/\\]') then
    output = repo_root .. '/' .. output
  end
  return output, nil
end

local function build_commit_prompt(repo_root)
  local staged_files, names_err = run_command({ 'git', '-C', repo_root, 'diff', '--cached', '--name-only', '--' }, repo_root)
  if names_err then
    return nil, names_err
  end
  if staged_files == '' then
    return nil, 'No staged changes to commit'
  end

  local diffstat, stat_err = run_command({ 'git', '-C', repo_root, 'diff', '--cached', '--stat', '--' }, repo_root)
  if stat_err then
    return nil, stat_err
  end

  local diff, diff_err = run_command({ 'git', '-C', repo_root, 'diff', '--cached', '--no-ext-diff', '--unified=3', '--' }, repo_root)
  if diff_err then
    return nil, diff_err
  end
  if #diff > COMMIT_MESSAGE_DIFF_LIMIT then
    diff = diff:sub(1, COMMIT_MESSAGE_DIFF_LIMIT) .. '\n\n[staged diff truncated]'
  end

  return table.concat({
    'Write a git commit message for the staged changes below.',
    'Return only the commit message text.',
    'Use imperative mood.',
    'Keep the subject line at or below 72 characters.',
    'Add a blank line and a short body only when it adds useful context.',
    '',
    'Repository root: ' .. repo_root,
    '',
    'Changed files:',
    staged_files,
    '',
    'Diffstat:',
    diffstat,
    '',
    'Staged diff:',
    diff,
  }, '\n')
end

local function open_fugitive_commit(repo_root, message)
  if vim.fn.exists(':Git') ~= 2 then
    return nil, 'vim-fugitive :Git command is not available'
  end

  local sanitized = sanitize_commit_message(message)
  if sanitized == '' then
    return nil, 'Commit message is empty'
  end

  local message_path, path_err = M._commit_message_path(repo_root)
  if path_err then
    return nil, path_err
  end

  vim.fn.mkdir(vim.fn.fnamemodify(message_path, ':h'), 'p')
  vim.fn.writefile(split_lines(sanitized), message_path)

  local previous_cwd = vim.fn.getcwd()
  local ok_lcd, lcd_err = pcall(vim.cmd, 'lcd ' .. vim.fn.fnameescape(repo_root))
  if not ok_lcd then
    return nil, tostring(lcd_err)
  end

  local ok_cmd, cmd_err = pcall(vim.cmd, 'Git commit --edit --verbose --cleanup=strip --file ' .. vim.fn.fnameescape(message_path))
  local ok_restore, restore_err = pcall(vim.cmd, 'lcd ' .. vim.fn.fnameescape(previous_cwd))
  if not ok_restore then
    return nil, 'Failed to restore working directory: ' .. tostring(restore_err)
  end
  if not ok_cmd then
    return nil, tostring(cmd_err)
  end
  return true
end

local function request_generated_commit_message(repo_root, callback)
  local prompt, prompt_err = M._build_commit_prompt(repo_root)
  if prompt_err then
    callback(nil, prompt_err)
    return
  end

  local extract_side_session_answer = require('copilot_agent.slash')._extract_side_session_answer
  local side_session_id
  local deadline = now_ms() + COMMIT_MESSAGE_TIMEOUT_MS

  local function finish(answer, err)
    if not side_session_id then
      callback(answer, err)
      return
    end

    request('DELETE', string.format('/sessions/%s?delete=true', side_session_id), nil, function(_, delete_err)
      side_session_id = nil
      if err then
        callback(nil, err)
        return
      end
      if delete_err then
        notify('Failed to clean up commit-message session: ' .. delete_err, vim.log.levels.WARN)
      end
      callback(answer, nil)
    end, { auto_start = false })
  end

  local function poll_messages()
    request('GET', string.format('/sessions/%s/messages', side_session_id), nil, function(response, err)
      if err then
        finish(nil, err)
        return
      end

      local answer, done, answer_err = extract_side_session_answer((response and response.events) or {})
      if answer_err then
        finish(nil, answer_err)
        return
      end
      if done then
        finish(M._sanitize_commit_message(answer), nil)
        return
      end
      if now_ms() >= deadline then
        finish(nil, 'timed out waiting for a commit message')
        return
      end
      vim.defer_fn(poll_messages, COMMIT_MESSAGE_POLL_INTERVAL_MS)
    end, { auto_start = false })
  end

  local function send_prompt()
    request('POST', string.format('/sessions/%s/messages', side_session_id), {
      prompt = prompt,
      clientId = service.client_id(),
    }, function(_, err)
      if err then
        finish(nil, err)
        return
      end
      poll_messages()
    end, { auto_start = false })
  end

  local function configure_mode()
    request('POST', string.format('/sessions/%s/mode', side_session_id), { mode = 'ask' }, function(_, err)
      if err then
        notify('Failed to set commit-message session mode: ' .. err, vim.log.levels.WARN)
      end
      send_prompt()
    end, { auto_start = false })
  end

  local function create_side_session(agent_name)
    request('POST', '/sessions', {
      clientId = service.client_id(),
      clientName = state.config.client_name,
      -- The commit agent must run git shell commands; approve-reads would fall
      -- back to interactive permission prompts with no UI attached here.
      permissionMode = 'approve-all',
      workingDirectory = repo_root,
      streaming = state.config.session.streaming,
      enableConfigDiscovery = state.config.session.enable_config_discovery,
      model = active_session_model(state.session_id),
      agent = agent_name,
    }, function(response, err)
      if err then
        if agent_name then
          create_side_session(nil)
          return
        end
        finish(nil, err)
        return
      end

      side_session_id = response and response.sessionId or nil
      if not side_session_id then
        finish(nil, 'Server did not return a side-session ID')
        return
      end
      configure_mode()
    end)
  end

  create_side_session(COMMIT_AGENT_NAME)
end

function M.fugitive_commit(arg)
  arg = vim.trim(arg or '')
  if arg ~= '' and arg ~= 'last' then
    notify('CopilotAgentFugitiveCommit only accepts "last" as an optional argument', vim.log.levels.WARN)
    return
  end

  local repo_root, repo_err = M._resolve_repo_root()
  if repo_err then
    notify('CopilotAgentFugitiveCommit failed: ' .. repo_err, vim.log.levels.ERROR)
    return
  end

  local function open_message(message)
    local ok, open_err = M._open_fugitive_commit(repo_root, message)
    if not ok then
      notify('CopilotAgentFugitiveCommit failed: ' .. open_err, vim.log.levels.ERROR)
    end
  end

  if arg == 'last' then
    local message = M._last_assistant_message()
    if not message then
      notify('No assistant message available to reuse as a commit message', vim.log.levels.WARN)
      return
    end
    open_message(message)
    return
  end

  notify('Generating commit message from staged changes…', vim.log.levels.INFO)
  M._request_generated_commit_message(repo_root, function(message, err)
    if err then
      notify('Failed to generate commit message: ' .. err, vim.log.levels.ERROR)
      return
    end
    open_message(message)
  end)
end

M._sanitize_commit_message = sanitize_commit_message
M._last_assistant_message = last_assistant_message
M._resolve_repo_root = resolve_repo_root
M._commit_message_path = commit_message_path
M._build_commit_prompt = build_commit_prompt
M._open_fugitive_commit = open_fugitive_commit
M._request_generated_commit_message = request_generated_commit_message
M._run_command = run_command

return M
