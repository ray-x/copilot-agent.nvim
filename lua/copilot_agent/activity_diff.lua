-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local service = require('copilot_agent.service')
local window = require('copilot_agent.window')

local M = {}
local state = cfg.state
local uv = vim.uv or vim.loop

local function close_hover_preview()
  local timer = state.activity_hover_timer
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
    state.activity_hover_timer = nil
  end
  local winid = state.activity_hover_winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  state.activity_hover_winid = nil
  state.activity_hover_entry_idx = nil
end

local function schedule_hover_close(timeout_ms)
  local delay = tonumber(timeout_ms) or tonumber((state.config or {}).chat and state.config.chat.activity_hover_timeout_ms) or 2500
  if delay <= 0 or not uv then
    return
  end
  local timer = state.activity_hover_timer
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
  timer = uv.new_timer()
  if not timer then
    state.activity_hover_timer = nil
    return
  end
  state.activity_hover_timer = timer
  timer:start(delay, 0, function()
    vim.schedule(function()
      if state.activity_hover_timer == timer then
        close_hover_preview()
      else
        pcall(timer.stop, timer)
        pcall(timer.close, timer)
      end
    end)
  end)
end

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function anchor_winid(opts)
  local winid = type(opts) == 'table' and opts.anchor_winid or nil
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    winid = state.chat_winid
  end
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    winid = vim.api.nvim_get_current_win()
  end
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return nil
  end
  return winid
end

local function float_geometry(winid, lines, opts)
  local anchor_width = vim.api.nvim_win_get_width(winid)
  local anchor_height = vim.api.nvim_win_get_height(winid)
  local max_width = math.max(24, math.floor(anchor_width * 0.7))
  local max_height = math.max(6, math.floor(anchor_height * 0.5))

  local content_width = 0
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
  end
  local width = clamp(math.max(content_width + 4, 24), 24, max_width)
  local height = clamp(math.max(#lines + 1, 2), 2, max_height)
  return {
    width = width,
    height = height,
    row = 1,
    col = 0,
    timeout_ms = type(opts) == 'table' and opts.timeout_ms or nil,
  }
end

local function workspace_dir()
  local workspace = state.session_working_directory or service.working_directory() or vim.fn.getcwd()
  if type(workspace) ~= 'string' or workspace == '' then
    return nil
  end
  return workspace
end

local function normalize_rel_path(path)
  if type(path) ~= 'string' then
    return nil
  end
  path = vim.trim(path)
  if path == '' then
    return nil
  end

  local workspace = workspace_dir()
  if type(workspace) == 'string' and workspace ~= '' then
    if path:sub(1, #workspace + 1) == workspace .. '/' then
      return path:sub(#workspace + 2)
    end
    local expanded = vim.fn.fnamemodify(path, ':p')
    if type(expanded) == 'string' and expanded:sub(1, #workspace + 1) == workspace .. '/' then
      return expanded:sub(#workspace + 2)
    end
    local root_name = vim.fn.fnamemodify(workspace:gsub('/+$', ''), ':t')
    if type(root_name) == 'string' and root_name ~= '' and root_name ~= '/' then
      local marker = '/' .. root_name .. '/'
      local match_index
      local search_from = 1
      while true do
        local found = path:find(marker, search_from, true)
        if not found then
          break
        end
        match_index = found
        search_from = found + 1
      end
      if match_index then
        return path:sub(match_index + #marker)
      end
    end
  end

  local normalized = path:gsub('^%./', '')
  return normalized
end

local function current_file_lines(abs_path)
  local ok, lines = pcall(vim.fn.readfile, abs_path)
  if not ok or type(lines) ~= 'table' then
    return nil
  end
  return lines
end

local function git_head_file_lines(workspace, rel_path)
  local cmd = {
    'git',
    '-C',
    workspace,
    'show',
    'HEAD:' .. rel_path,
  }
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  if type(lines) ~= 'table' or #lines == 0 then
    return { '' }
  end
  return lines
end

local function git_head_has_file(workspace, rel_path)
  local cmd = {
    'git',
    '-C',
    workspace,
    'cat-file',
    '-e',
    'HEAD:' .. rel_path,
  }
  vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0
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

local function open_preview_float(title, diff_text, opts)
  close_hover_preview()
  local lines = vim.split(type(diff_text) == 'string' and diff_text or '', '\n', { plain = true })
  local winid = anchor_winid(opts)
  local config
  if winid then
    config = float_geometry(winid, lines, opts)
    config.relative = 'cursor'
  else
    local width = math.min(math.max(80, math.floor(vim.o.columns * 0.9)), 160)
    local height = math.min(math.max(#lines + 1, 2), math.floor(vim.o.lines * 0.85))
    config = {
      relative = 'cursor',
      width = width,
      height = height,
      row = 1,
      col = 0,
      timeout_ms = type(opts) == 'table' and opts.timeout_ms or nil,
    }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = 'diff'

  local win = vim.api.nvim_open_win(buf, false, {
    relative = config.relative,
    width = config.width,
    height = config.height,
    row = config.row,
    col = config.col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  })
  state.activity_hover_winid = win
  window.disable_folds(win)
  window.set_window_syntax(win, 'diff')
  vim.wo[win].wrap = false
  vim.wo[win].linebreak = false

  local function close()
    close_hover_preview()
  end

  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc><Esc>', close, { buffer = buf, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<C-c>', close, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    callback = function()
      if state.activity_hover_winid == win then
        close_hover_preview()
      end
    end,
    once = true,
  })
  schedule_hover_close(config.timeout_ms)
  return true, nil
end

local function file_diff_text(rel_path, old_lines, new_lines)
  local old_text = table.concat(type(old_lines) == 'table' and old_lines or {}, '\n')
  local new_text = table.concat(type(new_lines) == 'table' and new_lines or {}, '\n')
  local ok, diff_text = pcall(vim.diff, old_text, new_text, { result_type = 'unified' })
  if not ok then
    return nil, tostring(diff_text)
  end
  local unified = type(diff_text) == 'string' and diff_text or ''
  if unified == '' then
    return 'No diff for ' .. rel_path, nil
  end
  local header = table.concat({
    '--- ' .. rel_path .. ' (HEAD)',
    '+++ ' .. rel_path .. ' (current)',
  }, '\n')
  return header .. '\n' .. unified, nil
end

local function format_change(change)
  local path = type(change) == 'table' and change.path or nil
  path = type(path) == 'string' and path ~= '' and path or '<unknown>'
  local additions = type(change) == 'table' and tonumber(change.additions) or nil
  local deletions = type(change) == 'table' and tonumber(change.deletions) or nil
  local add = additions and ('+' .. tostring(additions)) or '+?'
  local del = deletions and ('-' .. tostring(deletions)) or '-?'
  return string.format('%s %s %s', path, add, del)
end

local function open_native_diff(rel_path)
  local workspace = workspace_dir()
  if type(workspace) ~= 'string' or workspace == '' then
    return false, 'working directory is not set'
  end
  rel_path = normalize_rel_path(rel_path) or rel_path

  local abs_path = rel_path:sub(1, 1) == '/' and rel_path or vim.fs.joinpath(workspace, rel_path)
  local old_exists = git_head_has_file(workspace, rel_path)
  local old_lines = old_exists and git_head_file_lines(workspace, rel_path) or {}
  local current_lines = current_file_lines(abs_path)
  if not old_exists and not current_lines then
    return false, 'file not found'
  end

  vim.cmd('tabnew')
  local old_win = vim.api.nvim_get_current_win()
  local old_buf = vim.api.nvim_get_current_buf()
  configure_diff_buffer(old_buf, string.format('%s (before)', rel_path), old_lines, rel_path)
  window.disable_folds(old_win)
  vim.cmd('diffthis')

  vim.cmd('vsplit ' .. vim.fn.fnameescape(abs_path))
  local new_win = vim.api.nvim_get_current_win()
  local new_buf = vim.api.nvim_get_current_buf()
  vim.bo[new_buf].modifiable = true
  vim.bo[new_buf].readonly = false
  if vim.api.nvim_buf_get_name(new_buf) == '' then
    vim.api.nvim_buf_set_name(new_buf, rel_path)
  end
  window.disable_folds(new_win)
  vim.cmd('diffthis')
  return true, nil
end

local function open_preview_diff(rel_path, opts)
  local workspace = workspace_dir()
  if type(workspace) ~= 'string' or workspace == '' then
    return false, 'working directory is not set'
  end
  rel_path = normalize_rel_path(rel_path) or rel_path

  local abs_path = rel_path:sub(1, 1) == '/' and rel_path or vim.fs.joinpath(workspace, rel_path)
  local old_exists = git_head_has_file(workspace, rel_path)
  local old_lines = old_exists and git_head_file_lines(workspace, rel_path) or {}
  local current_lines = current_file_lines(abs_path)
  if not old_exists and not current_lines then
    return false, 'file not found'
  end
  current_lines = current_lines or {}

  local diff_text, diff_err = file_diff_text(rel_path, old_lines, current_lines)
  if not diff_text then
    return false, diff_err or 'unable to build diff preview'
  end
  return open_preview_float('Activity preview', diff_text, opts)
end

local function open_diffview(rel_path)
  if vim.fn.exists(':DiffviewOpen') ~= 2 then
    return false, 'DiffviewOpen is not available'
  end
  local ok, err = pcall(vim.cmd, 'DiffviewOpen -- ' .. vim.fn.fnameescape(rel_path))
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

local function open_fugitive(rel_path)
  if vim.fn.exists(':Git') ~= 2 then
    return false, 'Fugitive is not available'
  end
  local ok, err = pcall(vim.cmd, 'Git diff -- ' .. vim.fn.fnameescape(rel_path))
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

local function open_tool(rel_path, tool_name)
  tool_name = vim.trim(type(tool_name) == 'string' and tool_name or 'native')
  if tool_name == '' or tool_name == 'native' then
    return open_native_diff(rel_path)
  end
  if tool_name:lower() == 'diffview' or tool_name:lower() == 'diffviewopen' then
    local ok = open_diffview(rel_path)
    if ok then
      return true, nil
    end
    return open_native_diff(rel_path)
  end
  if tool_name:lower() == 'fugitive' then
    local ok = open_fugitive(rel_path)
    if ok then
      return true, nil
    end
    return open_native_diff(rel_path)
  end
  if tool_name:lower() == 'codediff' or tool_name:lower() == 'codediffopen' then
    local ok = pcall(vim.cmd, 'CodeDiff file ' .. vim.fn.fnameescape(rel_path))
    if ok then
      return true, nil
    end
    return open_native_diff(rel_path)
  end
  local ok = pcall(vim.cmd, tool_name .. ' ' .. vim.fn.fnameescape(rel_path))
  if ok then
    return true, nil
  end
  return open_native_diff(rel_path)
end

function M.open_change(change, tool_name)
  local rel_path = type(change) == 'table' and change.path or nil
  if type(rel_path) ~= 'string' or rel_path == '' then
    return false, 'missing file path'
  end
  rel_path = normalize_rel_path(rel_path) or rel_path
  return open_tool(rel_path, tool_name)
end

function M.open_preview_change(change, opts)
  local rel_path = type(change) == 'table' and change.path or nil
  if type(rel_path) ~= 'string' or rel_path == '' then
    return false, 'missing file path'
  end
  rel_path = normalize_rel_path(rel_path) or rel_path
  return open_preview_diff(rel_path, opts)
end

function M.open_changes(changes, tool_name)
  if type(changes) ~= 'table' or #changes == 0 then
    return false, 'no changed files available'
  end
  if #changes == 1 then
    return M.open_change(changes[1], tool_name)
  end

  if type(vim.api.nvim_list_uis) == 'function' and #vim.api.nvim_list_uis() == 0 then
    return M.open_change(changes[1], tool_name)
  end

  local choices = {}
  for _, change in ipairs(changes) do
    choices[#choices + 1] = change
  end
  vim.ui.select(choices, {
    prompt = 'Select changed file to diff',
    format_item = format_change,
  }, function(choice)
    if choice then
      M.open_change(choice, tool_name)
    end
  end)
  return true, nil
end

function M.open_preview_changes(changes, opts)
  if type(changes) ~= 'table' or #changes == 0 then
    return false, 'no changed files available'
  end
  if type(opts) == 'table' and type(opts.entry_idx) == 'number' then
    state.activity_hover_entry_idx = opts.entry_idx
  end
  if #changes == 1 then
    return M.open_preview_change(changes[1], opts)
  end

  if type(vim.api.nvim_list_uis) == 'function' and #vim.api.nvim_list_uis() == 0 then
    return M.open_preview_change(changes[1], opts)
  end

  local choices = {}
  for _, change in ipairs(changes) do
    choices[#choices + 1] = change
  end
  vim.ui.select(choices, {
    prompt = 'Select changed file to preview',
    format_item = format_change,
  }, function(choice)
    if choice then
      M.open_preview_change(choice, opts)
    end
  end)
  return true, nil
end

function M.close_preview()
  close_hover_preview()
end

return M
