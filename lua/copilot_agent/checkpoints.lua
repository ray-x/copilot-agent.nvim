-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local service = require('copilot_agent.service')

local state = cfg.state
local notify = cfg.notify

local M = {}

local function root_dir()
  return vim.fn.stdpath('state') .. '/copilot-agent/checkpoints'
end

local function session_dir(session_id)
  return root_dir() .. '/' .. session_id
end

local function repo_dir(session_id)
  return session_dir(session_id) .. '/repo'
end

local function git_dir(session_id)
  return repo_dir(session_id) .. '/.git'
end

local function checkpoints_dir(session_id)
  return session_dir(session_id) .. '/checkpoints'
end

local function index_path(session_id)
  return session_dir(session_id) .. '/index.json'
end

local function metadata_path(session_id, checkpoint_id)
  return checkpoints_dir(session_id) .. '/' .. checkpoint_id .. '.json'
end

local function ensure_parent(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
end

local function read_json(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local raw = f:read('*a')
  f:close()
  if raw == '' then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok then
    return decoded
  end
  return nil
end

local function write_json(path, value)
  ensure_parent(path)
  local f, err = io.open(path, 'w')
  if not f then
    return nil, err
  end
  f:write(vim.json.encode(value))
  f:close()
  return true
end

local function load_index(session_id)
  local index = read_json(index_path(session_id))
  if type(index) ~= 'table' then
    return { session_id = session_id, checkpoints = {} }
  end
  index.checkpoints = type(index.checkpoints) == 'table' and index.checkpoints or {}
  return index
end

local function save_index(session_id, index)
  index.session_id = session_id
  index.checkpoints = index.checkpoints or {}
  return write_json(index_path(session_id), index)
end

local function run_system(args, opts, callback)
  if type(vim.system) ~= 'function' then
    vim.schedule(function()
      callback(nil, 'vim.system is required for checkpoint git operations')
    end)
    return
  end

  opts = vim.tbl_extend('force', { text = true }, opts or {})
  vim.system(args, opts, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or result.stdout or '')
        if message == '' then
          message = table.concat(args, ' ')
        end
        callback(nil, message, result)
        return
      end
      callback(result.stdout or '', nil, result)
    end)
  end)
end

local function git(session_id, workspace, args, callback)
  local cmd = {
    'git',
    '--git-dir=' .. git_dir(session_id),
    '--work-tree=' .. workspace,
  }
  vim.list_extend(cmd, args)
  run_system(cmd, { cwd = workspace }, callback)
end

local function ensure_repo(session_id, workspace, callback)
  if vim.fn.isdirectory(git_dir(session_id)) == 1 then
    callback(true)
    return
  end

  vim.fn.mkdir(checkpoints_dir(session_id), 'p')
  run_system({ 'git', 'init', '--quiet', repo_dir(session_id) }, nil, function(_, init_err)
    if init_err then
      callback(nil, init_err)
      return
    end

    run_system({ 'git', '-C', repo_dir(session_id), 'config', 'user.name', 'copilot-agent.nvim' }, nil, function(_, name_err)
      if name_err then
        callback(nil, name_err)
        return
      end

      run_system({ 'git', '-C', repo_dir(session_id), 'config', 'user.email', 'copilot-agent.nvim@local' }, nil, function(_, email_err)
        if email_err then
          callback(nil, email_err)
          return
        end
        callback(true)
      end)
    end)
  end)
end

local function checkpoint_label(prompt)
  local text = vim.trim(prompt or '')
  if text == '' then
    return 'checkpoint'
  end
  if #text > 60 then
    text = text:sub(1, 57) .. '...'
  end
  return text:gsub('%s+', ' ')
end

local function transcript_snapshot(prompt)
  return {
    prompt = prompt,
    created_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    entries = vim.deepcopy(state.entries),
    session_name = state.session_name,
    current_model = state.current_model,
    reasoning_effort = state.reasoning_effort,
    input_mode = state.input_mode,
    permission_mode = state.permission_mode,
  }
end

function M.create(session_id, prompt, callback)
  callback = callback or function() end
  if type(session_id) ~= 'string' or session_id == '' then
    callback('session_id is required')
    return
  end

  local workspace = service.working_directory()
  local snapshot = transcript_snapshot(prompt)
  ensure_repo(session_id, workspace, function(_, repo_err)
    if repo_err then
      callback(repo_err)
      return
    end

    git(session_id, workspace, { 'add', '-A', '--', '.' }, function(_, add_err)
      if add_err then
        callback(add_err)
        return
      end

      git(session_id, workspace, {
        'commit',
        '--quiet',
        '--allow-empty',
        '-m',
        'checkpoint: ' .. checkpoint_label(prompt),
      }, function(_, commit_err)
        if commit_err then
          callback(commit_err)
          return
        end

        git(session_id, workspace, { 'rev-parse', 'HEAD' }, function(stdout, rev_err)
          if rev_err then
            callback(rev_err)
            return
          end

          local checkpoint_id = vim.trim(stdout)
          snapshot.id = checkpoint_id
          local ok_meta, meta_err = write_json(metadata_path(session_id, checkpoint_id), snapshot)
          if not ok_meta then
            callback(meta_err)
            return
          end

          local index = load_index(session_id)
          table.insert(index.checkpoints, {
            id = checkpoint_id,
            prompt = prompt,
            created_at = snapshot.created_at,
          })
          local ok_index, index_err = save_index(session_id, index)
          if not ok_index then
            callback(index_err)
            return
          end
          callback(nil, checkpoint_id)
        end)
      end)
    end)
  end)
end

function M.list(session_id)
  if type(session_id) ~= 'string' or session_id == '' then
    return {}
  end
  return load_index(session_id).checkpoints
end

local function apply_snapshot(snapshot)
  state.entries = vim.deepcopy(snapshot.entries or {})
  state.assistant_entries = {}
  state.stream_line_start = nil
  state.active_tool = nil
  state.current_intent = nil
  state.context_tokens = nil
  state.context_limit = nil
  state.chat_busy = false
  state.pending_attachments = {}
  state.session_name = snapshot.session_name
  state.current_model = snapshot.current_model
  state.reasoning_effort = snapshot.reasoning_effort
  state.input_mode = snapshot.input_mode or state.input_mode
  state.permission_mode = snapshot.permission_mode or state.permission_mode
  state.prompt_prefill = snapshot.prompt or nil
end

local function refresh_workspace_buffers(workspace)
  local prefix = vim.fn.fnamemodify(workspace, ':p')
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local path = name ~= '' and vim.fn.fnamemodify(name, ':p') or nil
      if path and vim.startswith(path, prefix) then
        if vim.uv.fs_stat(path) then
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd('silent! checktime')
          end)
        else
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
    end
  end
end

local function replace_with_new_session(snapshot, callback)
  local session = require('copilot_agent.session')
  local render = require('copilot_agent.render')
  local sl = require('copilot_agent.statusline')
  local current_session_id = state.session_id

  local function finish(err)
    if err then
      callback(err)
      return
    end
    apply_snapshot(snapshot)
    render.render_chat()
    sl.refresh_statuslines()
    require('copilot_agent').open_chat({ activate_input_on_session_ready = false })
    require('copilot_agent')._open_input_window()
    callback(nil)
  end

  if not current_session_id then
    finish(nil)
    return
  end

  session.disconnect_session(current_session_id, false, function(disconnect_err)
    if disconnect_err then
      callback(disconnect_err)
      return
    end
    state.session_id = nil
    state.session_name = nil
    session.create_new_session(function(_, create_err)
      finish(create_err)
    end)
  end)
end

local function restore(session_id, checkpoint_id, callback)
  local snapshot = read_json(metadata_path(session_id, checkpoint_id))
  if type(snapshot) ~= 'table' then
    callback('checkpoint metadata not found')
    return
  end

  local workspace = service.working_directory()
  git(session_id, workspace, { 'reset', '--hard', '--quiet', checkpoint_id }, function(_, reset_err)
    if reset_err then
      callback(reset_err)
      return
    end

    git(session_id, workspace, { 'clean', '-fdq' }, function(_, clean_err)
      if clean_err then
        callback(clean_err)
        return
      end

      local index = load_index(session_id)
      local truncated = {}
      for _, item in ipairs(index.checkpoints) do
        if item.id == checkpoint_id then
          break
        end
        truncated[#truncated + 1] = item
      end
      index.checkpoints = truncated
      save_index(session_id, index)

      refresh_workspace_buffers(workspace)
      replace_with_new_session(snapshot, callback)
    end)
  end)
end

function M.undo(session_id, callback)
  callback = callback or function() end
  local checkpoints = M.list(session_id)
  local latest = checkpoints[#checkpoints]
  if not latest then
    callback('No checkpoints available')
    return
  end
  restore(session_id, latest.id, callback)
end

function M.rewind(session_id, callback)
  callback = callback or function() end
  local checkpoints = M.list(session_id)
  if vim.tbl_isempty(checkpoints) then
    callback('No checkpoints available')
    return
  end

  local items = {}
  for i = #checkpoints, 1, -1 do
    local item = checkpoints[i]
    local prompt = checkpoint_label(item.prompt)
    items[#items + 1] = {
      id = item.id,
      label = string.format('%s  [%s]', prompt, item.id:sub(1, 7)),
    }
  end

  vim.ui.select(items, {
    prompt = 'Rewind to checkpoint',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      callback(nil)
      return
    end
    restore(session_id, choice.id, callback)
  end)
end

return M
