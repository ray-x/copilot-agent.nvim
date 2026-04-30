-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local service = require('copilot_agent.service')

local log = cfg.log
local state = cfg.state

local M = {}
local deleted_checkpoint_ttl_seconds = 7 * 24 * 60 * 60

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

local function checkpoint_workspace()
  return state.session_working_directory or service.working_directory()
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

local function checkpoint_number(label)
  local raw = type(label) == 'string' and label:match('^v(%d+)$') or nil
  return raw and tonumber(raw) or nil
end

local function format_checkpoint_id(number)
  return string.format('v%03d', number)
end

local function normalize_checkpoint_id(checkpoint_id)
  checkpoint_id = vim.trim(checkpoint_id or '')
  if checkpoint_id == '' then
    return nil
  end
  local number = checkpoint_id:match('^[vV](%d+)$')
  if number then
    return format_checkpoint_id(tonumber(number))
  end
  return checkpoint_id
end

local function normalize_index(session_id, index)
  if type(index) ~= 'table' then
    index = { session_id = session_id, checkpoints = {} }
  end

  local normalized = {}
  local next_number = 1
  for _, item in ipairs(type(index.checkpoints) == 'table' and index.checkpoints or {}) do
    if type(item) == 'table' then
      local metadata_key = type(item.metadata_key) == 'string' and item.metadata_key ~= '' and item.metadata_key or item.id
      local commit = type(item.commit) == 'string' and item.commit ~= '' and item.commit or metadata_key
      local number = checkpoint_number(item.id)
      local checkpoint_id
      if number then
        checkpoint_id = format_checkpoint_id(number)
        next_number = math.max(next_number, number + 1)
      else
        checkpoint_id = format_checkpoint_id(next_number)
        next_number = next_number + 1
      end
      normalized[#normalized + 1] = {
        id = checkpoint_id,
        commit = commit,
        metadata_key = metadata_key,
        assistant_message_id = item.assistant_message_id,
        prompt = item.prompt,
        created_at = item.created_at,
      }
    end
  end

  index.session_id = session_id
  index.checkpoints = normalized
  index.next_checkpoint_number = math.max(tonumber(index.next_checkpoint_number) or 1, next_number)
  index.purge_after_unix = tonumber(index.purge_after_unix) or nil
  return index
end

local function load_index(session_id)
  local index = read_json(index_path(session_id))
  return normalize_index(session_id, index)
end

local function save_index(session_id, index)
  index = normalize_index(session_id, index)
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

local function configure_repo_identity(session_id, callback)
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
end

local function ensure_repo(session_id, callback)
  if vim.fn.isdirectory(git_dir(session_id)) == 1 then
    configure_repo_identity(session_id, callback)
    return
  end

  vim.fn.mkdir(checkpoints_dir(session_id), 'p')
  run_system({ 'git', 'init', '--quiet', repo_dir(session_id) }, nil, function(_, init_err)
    if init_err then
      callback(nil, init_err)
      return
    end

    configure_repo_identity(session_id, callback)
  end)
end

local function prompt_summary(prompt)
  local text = vim.trim(prompt or '')
  if text == '' then
    return 'checkpoint'
  end
  if #text > 60 then
    text = text:sub(1, 57) .. '...'
  end
  return text:gsub('%s+', ' ')
end

local function next_checkpoint_id(index)
  local number = tonumber(index.next_checkpoint_number) or 1
  index.next_checkpoint_number = number + 1
  return format_checkpoint_id(number)
end

local function current_head_commit(session_id, workspace, callback)
  git(session_id, workspace, { 'rev-parse', '--verify', 'HEAD' }, function(stdout, rev_err)
    if rev_err then
      local lowered = rev_err:lower()
      if lowered:find('needed a single revision', 1, true) or lowered:find('unknown revision', 1, true) or lowered:find('ambiguous argument', 1, true) or lowered:find('bad revision', 1, true) then
        callback(nil, nil)
        return
      end
      callback(nil, rev_err)
      return
    end
    callback(vim.trim(stdout), nil)
  end)
end

local function create_snapshot_commit(session_id, workspace, prompt, callback)
  git(session_id, workspace, {
    'commit',
    '--quiet',
    '--allow-empty',
    '-m',
    'checkpoint: ' .. prompt_summary(prompt),
  }, function(_, commit_err)
    if commit_err then
      callback(nil, commit_err)
      return
    end
    current_head_commit(session_id, workspace, callback)
  end)
end

local function resolve_snapshot_commit(session_id, workspace, prompt, callback)
  git(session_id, workspace, { 'add', '-A', '--', '.' }, function(_, add_err)
    if add_err then
      callback(nil, add_err)
      return
    end

    current_head_commit(session_id, workspace, function(head_commit, head_err)
      if head_err then
        callback(nil, head_err)
        return
      end
      if not head_commit or head_commit == '' then
        create_snapshot_commit(session_id, workspace, prompt, callback)
        return
      end

      git(session_id, workspace, { 'diff', '--cached', '--name-only', 'HEAD', '--' }, function(stdout, diff_err)
        if diff_err then
          callback(nil, diff_err)
          return
        end
        if vim.trim(stdout) == '' then
          callback(head_commit, nil)
          return
        end
        create_snapshot_commit(session_id, workspace, prompt, callback)
      end)
    end)
  end)
end

local function checkpoint_lookup(index, checkpoint_id)
  checkpoint_id = normalize_checkpoint_id(checkpoint_id)
  for _, item in ipairs(index.checkpoints or {}) do
    if item.id == checkpoint_id then
      return item
    end
  end
  return nil
end

local function remap_snapshot_checkpoint_ids(snapshot, index)
  if type(snapshot) ~= 'table' or type(snapshot.entries) ~= 'table' then
    return snapshot
  end

  local id_map = {}
  for _, item in ipairs(index.checkpoints or {}) do
    if type(item.id) == 'string' and item.id ~= '' then
      id_map[item.id] = item.id
    end
    if type(item.commit) == 'string' and item.commit ~= '' then
      id_map[item.commit] = item.id
    end
    if type(item.metadata_key) == 'string' and item.metadata_key ~= '' then
      id_map[item.metadata_key] = item.id
    end
  end

  for _, entry in ipairs(snapshot.entries) do
    if type(entry) == 'table' and type(entry.checkpoint_id) == 'string' then
      entry.checkpoint_id = id_map[entry.checkpoint_id] or entry.checkpoint_id
    end
  end
  return snapshot
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

function M.create(session_id, prompt, callback, opts)
  callback = callback or function() end
  opts = opts or {}
  if type(session_id) ~= 'string' or session_id == '' then
    callback('session_id is required')
    return
  end
  M.prune_deleted()

  local workspace = checkpoint_workspace()
  ensure_repo(session_id, function(_, repo_err)
    if repo_err then
      callback(repo_err)
      return
    end

    resolve_snapshot_commit(session_id, workspace, prompt, function(commit_hash, commit_err)
      if commit_err then
        callback(commit_err)
        return
      end

      local index = load_index(session_id)
      local checkpoint_id = next_checkpoint_id(index)
      if type(opts.entry_index) == 'number' and state.entries[opts.entry_index] and state.entries[opts.entry_index].kind == 'user' then
        state.entries[opts.entry_index].checkpoint_id = checkpoint_id
      end

      local snapshot = transcript_snapshot(prompt)
      snapshot.id = checkpoint_id
      snapshot.commit = commit_hash
      snapshot.assistant_message_id = opts.assistant_message_id
      local ok_meta, meta_err = write_json(metadata_path(session_id, checkpoint_id), snapshot)
      if not ok_meta then
        callback(meta_err)
        return
      end

      table.insert(index.checkpoints, {
        id = checkpoint_id,
        commit = commit_hash,
        metadata_key = checkpoint_id,
        assistant_message_id = opts.assistant_message_id,
        prompt = prompt,
        created_at = snapshot.created_at,
      })
      local ok_index, index_err = save_index(session_id, index)
      if not ok_index then
        callback(index_err)
        return
      end
      callback(nil, checkpoint_id, commit_hash)
    end)
  end)
end

function M.list(session_id)
  if type(session_id) ~= 'string' or session_id == '' then
    return {}
  end
  return load_index(session_id).checkpoints
end

function M.soft_delete_session(session_id, opts, callback)
  callback = callback or function() end
  if type(session_id) ~= 'string' or session_id == '' then
    callback('session_id is required')
    return
  end

  M.prune_deleted()
  if vim.fn.isdirectory(session_dir(session_id)) ~= 1 then
    callback(nil, false)
    return
  end

  opts = opts or {}
  local now = os.time()
  local index = load_index(session_id)
  if type(index.deleted_at) ~= 'string' or index.deleted_at == '' then
    index.deleted_at = os.date('!%Y-%m-%dT%H:%M:%SZ', now)
  end
  if type(index.purge_after_unix) ~= 'number' then
    index.purge_after_unix = now + deleted_checkpoint_ttl_seconds
  end
  index.purge_after = os.date('!%Y-%m-%dT%H:%M:%SZ', index.purge_after_unix)
  if type(opts.session_name) == 'string' and opts.session_name ~= '' then
    index.deleted_session_name = opts.session_name
  end
  if type(opts.working_directory) == 'string' and opts.working_directory ~= '' then
    index.deleted_working_directory = opts.working_directory
  end

  local ok, err = save_index(session_id, index)
  if not ok then
    callback(err)
    return
  end

  log(string.format('checkpoint repo soft-deleted for %s until %s', session_id, index.purge_after), vim.log.levels.INFO)
  callback(nil, true, index)
end

function M.prune_deleted()
  local root = root_dir()
  if vim.fn.isdirectory(root) ~= 1 then
    return 0, {}
  end

  local now = os.time()
  local removed = 0
  local errors = {}
  for _, entry in ipairs(vim.fn.readdir(root)) do
    local dir = session_dir(entry)
    if entry ~= state.session_id and vim.fn.isdirectory(dir) == 1 then
      local index = read_json(index_path(entry))
      local purge_after_unix = type(index) == 'table' and tonumber(index.purge_after_unix) or nil
      if type(index) == 'table' and type(index.deleted_at) == 'string' and index.deleted_at ~= '' and purge_after_unix and purge_after_unix <= now then
        local result = vim.fn.delete(dir, 'rf')
        if result == 0 then
          removed = removed + 1
        else
          local message = 'Failed to prune deleted checkpoint repo: ' .. dir
          table.insert(errors, message)
          log(message, vim.log.levels.WARN)
        end
      end
    end
  end

  if removed > 0 then
    log(string.format('pruned %d deleted checkpoint repos', removed), vim.log.levels.INFO)
  end
  return removed, errors
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
  local index = load_index(session_id)
  local checkpoint = checkpoint_lookup(index, checkpoint_id)
  if not checkpoint then
    callback('checkpoint metadata not found')
    return
  end

  local snapshot = read_json(metadata_path(session_id, checkpoint.metadata_key or checkpoint.id))
  if type(snapshot) ~= 'table' then
    callback('checkpoint metadata not found')
    return
  end
  snapshot = remap_snapshot_checkpoint_ids(snapshot, index)

  local workspace = checkpoint_workspace()
  git(session_id, workspace, { 'reset', '--hard', '--quiet', checkpoint.commit }, function(_, reset_err)
    if reset_err then
      callback(reset_err)
      return
    end

    git(session_id, workspace, { 'clean', '-fdq' }, function(_, clean_err)
      if clean_err then
        callback(clean_err)
        return
      end

      local truncated = {}
      for _, item in ipairs(index.checkpoints) do
        truncated[#truncated + 1] = item
        if item.id == checkpoint_id then
          break
        end
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

function M.rewind(session_id, checkpoint_id, callback)
  if type(checkpoint_id) == 'function' then
    callback = checkpoint_id
    checkpoint_id = nil
  end
  callback = callback or function() end
  local checkpoints = M.list(session_id)
  if vim.tbl_isempty(checkpoints) then
    callback('No checkpoints available')
    return
  end

  local direct_checkpoint_id = normalize_checkpoint_id(checkpoint_id)
  if direct_checkpoint_id then
    if not checkpoint_lookup({ checkpoints = checkpoints }, direct_checkpoint_id) then
      callback('Checkpoint not found: ' .. direct_checkpoint_id)
      return
    end
    restore(session_id, direct_checkpoint_id, callback)
    return
  end

  local items = {}
  for i = #checkpoints, 1, -1 do
    local item = checkpoints[i]
    local prompt = prompt_summary(item.prompt)
    items[#items + 1] = {
      id = item.id,
      label = string.format('%s  [%s]', prompt, item.id),
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

M._session_dir = session_dir
M._load_index = load_index
M._save_index = save_index
M._deleted_checkpoint_ttl_seconds = deleted_checkpoint_ttl_seconds

return M
