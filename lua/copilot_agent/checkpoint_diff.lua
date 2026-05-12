-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local M = {}

local function checkpoint_diff_workspace()
  -- Prefer explicit session-bound working directory, fall back to service.working_directory()
  local cfg = require('copilot_agent.config')
  local workspace = cfg.state.session_working_directory or require('copilot_agent.service').working_directory()
  if type(workspace) ~= 'string' or workspace == '' then
    return nil
  end
  return workspace
end

local function checkpoint_git_dir(session_id)
  local checkpoints_mod = require('copilot_agent.checkpoints')
  return checkpoints_mod._session_dir(session_id) .. '/repo/.git'
end

function M.systemlist(session_id, workspace, args)
  local cmd = {
    'git',
    '--git-dir=' .. checkpoint_git_dir(session_id),
    '--work-tree=' .. workspace,
  }
  vim.list_extend(cmd, args)
  if vim.system then
    local result = vim.system(cmd, { text = true, cwd = workspace }):wait()
    local stdout = (result.stdout or '') ~= '' and (result.stdout or '') or (result.stderr or '')
    local lines = stdout ~= '' and vim.split(stdout, '\n', { plain = true }) or {}
    if #lines > 0 and lines[#lines] == '' then
      table.remove(lines)
    end
    return lines, result.code, cmd
  end
  local output = vim.fn.systemlist(cmd)
  return output, vim.v.shell_error, cmd
end

local function picker_label(item, max_chars)
  local prompt = type(item.prompt) == 'string' and vim.trim(item.prompt) or ''
  if prompt == '' then
    return item.id
  end
  prompt = prompt:gsub('%s+', ' ')
  if #prompt > max_chars then
    prompt = prompt:sub(1, max_chars - 3) .. '...'
  end
  return string.format('%s  [%s]', prompt, item.id)
end

local function file_lines(session_id, workspace, checkpoint, path)
  local lines, exit_code = M.systemlist(session_id, workspace, {
    'show',
    checkpoint.commit .. ':' .. path,
  })
  if exit_code ~= 0 then
    return {
      string.format('[File not present in %s]', checkpoint.id),
    }
  end
  if #lines == 0 then
    return { '' }
  end
  return lines
end

local function configure_diff_buffer(bufnr, name, lines, filename)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local ft = vim.filetype.match({ filename = filename }) or ''
  if ft ~= '' then
    vim.bo[bufnr].filetype = ft
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

local function open_diff(path, older_checkpoint, newer_checkpoint)
  local cfg = require('copilot_agent.config')
  local state = cfg.state
  local notify = cfg.notify
  local window = require('copilot_agent.window')
  local session_id = state.session_id
  local workspace = checkpoint_diff_workspace()
  if not session_id or not workspace then
    notify('Checkpoint diff unavailable', vim.log.levels.WARN)
    return
  end

  local older_lines = file_lines(session_id, workspace, older_checkpoint, path)
  local newer_lines = file_lines(session_id, workspace, newer_checkpoint, path)

  vim.cmd('tabnew')
  local older_win = vim.api.nvim_get_current_win()
  local older_buf = vim.api.nvim_get_current_buf()
  configure_diff_buffer(older_buf, string.format('%s (%s)', path, older_checkpoint.id), older_lines, path)
  window.disable_folds(older_win)
  vim.cmd('diffthis')

  vim.cmd('vnew')
  local newer_win = vim.api.nvim_get_current_win()
  local newer_buf = vim.api.nvim_get_current_buf()
  configure_diff_buffer(newer_buf, string.format('%s (%s)', path, newer_checkpoint.id), newer_lines, path)
  window.disable_folds(newer_win)
  vim.cmd('diffthis')
end

function M.review_diff()
  local cfg = require('copilot_agent.config')
  local state = cfg.state
  local notify = cfg.notify

  if not state.session_id then
    notify('No active session to diff', vim.log.levels.INFO)
    return
  end

  local workspace = checkpoint_diff_workspace()
  if not workspace then
    notify('Checkpoint diff unavailable: working directory is not set', vim.log.levels.WARN)
    return
  end

  local checkpoint_items = vim.tbl_filter(function(item)
    return type(item) == 'table' and type(item.id) == 'string' and item.id ~= '' and type(item.commit) == 'string' and item.commit ~= ''
  end, require('copilot_agent.checkpoints').list(state.session_id) or {})
  if #checkpoint_items < 2 then
    notify('Need at least two checkpoints to diff', vim.log.levels.INFO)
    return
  end

  local newer_choices = {}
  for idx = #checkpoint_items, 2, -1 do
    newer_choices[#newer_choices + 1] = {
      index = idx,
      checkpoint = checkpoint_items[idx],
    }
  end

  vim.ui.select(newer_choices, {
    prompt = 'Select newer checkpoint',
    format_item = function(item)
      return picker_label(item.checkpoint, 64)
    end,
  }, function(newer_choice)
    if not newer_choice then
      return
    end

    local older_choices = {}
    for idx = newer_choice.index - 1, 1, -1 do
      older_choices[#older_choices + 1] = {
        index = idx,
        checkpoint = checkpoint_items[idx],
      }
    end

    vim.ui.select(older_choices, {
      prompt = 'Select older checkpoint to compare',
      format_item = function(item)
        return picker_label(item.checkpoint, 64)
      end,
    }, function(older_choice)
      if not older_choice then
        return
      end

      local changed, exit_code = M.systemlist(cfg.state.session_id, workspace, {
        'diff',
        '--name-only',
        older_choice.checkpoint.commit,
        newer_choice.checkpoint.commit,
        '--',
        '.',
      })
      if exit_code ~= 0 then
        notify('Checkpoint diff failed', vim.log.levels.WARN)
        return
      end

      changed = vim.tbl_filter(function(path)
        return type(path) == 'string' and path ~= ''
      end, changed)
      if #changed == 0 then
        notify(string.format('No file differences between checkpoints %s and %s', older_choice.checkpoint.id, newer_choice.checkpoint.id), vim.log.levels.INFO)
        return
      end

      vim.ui.select(changed, {
        prompt = string.format('Review file diff for %s -> %s', older_choice.checkpoint.id, newer_choice.checkpoint.id),
      }, function(path)
        if not path then
          return
        end
        open_diff(path, older_choice.checkpoint, newer_choice.checkpoint)
      end)
    end)
  end)
end

-- Checkpoint diff helpers moved from events.lua
local render = require('copilot_agent.render')
local logger = require('copilot_agent.log')
local log = logger.log

local function update_last_activity_with_code_change(from_commit, to_commit, diff_items)
  local summary
  if #diff_items > 0 then
    local first = diff_items[1]
    if #diff_items == 1 and type(first.path) == 'string' then
      local add = first.additions and ('+' .. tostring(first.additions)) or '+?'
      local del = first.deletions and ('-' .. tostring(first.deletions)) or '-?'
      summary = string.format('Edited %s %s %s', first.path, add, del)
    else
      summary = string.format('Edited %d file changes', #diff_items)
    end
  end
  if not summary then
    return
  end
  local updated = render.update_last_activity_entry(function(entry)
    entry.kind = 'activity'
    entry.content = summary
    entry.code_change = {
      from_commit = from_commit,
      to_commit = to_commit,
      files = diff_items,
    }
    entry.activity_items = {
      {
        kind = 'code_change',
        summary = summary,
        from_commit = from_commit,
        to_commit = to_commit,
        diffstat = diff_items,
      },
    }
  end)
  if updated then
    render.render_chat()
  end
end

function M.collect_checkpoint_diff_items(text)
  local diff_items = {}
  for line in vim.trim(text or ''):gmatch('[^\r\n]+') do
    local added, deleted, path = line:match('^(.-)\t(.-)\t(.+)$')
    if added and deleted and path then
      local function normalize_num(value)
        value = vim.trim(value or '')
        if value == '-' then
          return nil
        end
        return tonumber(value)
      end
      diff_items[#diff_items + 1] = {
        path = path,
        additions = normalize_num(added),
        deletions = normalize_num(deleted),
      }
    end
  end
  return diff_items
end

function M.run_checkpoint_numstat(session_id, workspace, from_commit, to_commit)
  local cmd = {
    'git',
    '--no-pager',
    '--git-dir=' .. checkpoint_git_dir(session_id),
    '--work-tree=' .. workspace,
    'diff',
    '--numstat',
    from_commit,
    to_commit,
    '--',
    '.',
  }
  log(string.format('checkpoint numstat cwd=%s cmd=%s', workspace, table.concat(cmd, ' ')), vim.log.levels.DEBUG)
  vim.system(cmd, { cwd = workspace, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or result.stdout or '')
        log('checkpoint diffstat unavailable: ' .. tostring(message ~= '' and message or table.concat(cmd, ' ')), vim.log.levels.DEBUG)
        return
      end
      update_last_activity_with_code_change(from_commit, to_commit, M.collect_checkpoint_diff_items(result.stdout))
    end)
  end)
end

function M.summarize_checkpoint_code_change(session_id)
  local workspace = require('copilot_agent.config').state.session_working_directory or require('copilot_agent.service').working_directory()
  if type(session_id) ~= 'string' or session_id == '' or type(workspace) ~= 'string' or workspace == '' then
    return
  end
  local checkpoint_items = require('copilot_agent.checkpoints').list(session_id)
  local current = checkpoint_items[#checkpoint_items]
  if not current or type(current.commit) ~= 'string' or current.commit == '' then
    return
  end
  local previous = checkpoint_items[#checkpoint_items - 1]
  if previous and type(previous.commit) == 'string' and previous.commit ~= '' then
    M.run_checkpoint_numstat(session_id, workspace, previous.commit, current.commit)
    return
  end
  local parent_cmd = {
    'git',
    '--no-pager',
    '--git-dir=' .. checkpoint_git_dir(session_id),
    '--work-tree=' .. workspace,
    'show',
    '-s',
    '--format=%P',
    current.commit,
  }
  vim.system(parent_cmd, { cwd = workspace, text = true }, function(parent_result)
    vim.schedule(function()
      local parent_output = vim.trim(parent_result.stdout or '')
      local parent_commit = parent_output:match('^(%S+)') or '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
      M.run_checkpoint_numstat(session_id, workspace, parent_commit, current.commit)
    end)
  end)
end

return M
