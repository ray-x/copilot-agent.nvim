-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local state = require('copilot_agent.config').state

local M = {}

local function is_named_chat_buffer(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end

  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':t')
  local chat_name = ((state.config.chat or {}).buf_name) or 'CopilotAgentChat'
  return name == chat_name or name == 'copilot-agent-input' or vim.startswith(name, 'copilot-agent-chat-stale-')
end

local function win_sort_key(winid)
  local pos = vim.api.nvim_win_get_position(winid)
  return pos[2], pos[1]
end

function M.is_floating_window(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local config = vim.api.nvim_win_get_config(winid)
  return type(config.relative) == 'string' and config.relative ~= ''
end

function M.resolve_split_target(preferred_winid)
  local candidates = {}
  if preferred_winid then
    candidates[#candidates + 1] = preferred_winid
  end
  candidates[#candidates + 1] = vim.api.nvim_get_current_win()

  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    candidates[#candidates + 1] = winid
  end

  local seen = {}
  for _, winid in ipairs(candidates) do
    if winid and not seen[winid] and vim.api.nvim_win_is_valid(winid) then
      seen[winid] = true
      if not M.is_floating_window(winid) then
        return winid
      end
    end
  end

  return nil
end

function M.is_chat_related_window(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return false
  end
  return is_named_chat_buffer(vim.api.nvim_win_get_buf(winid))
end

function M.is_workspace_file_window(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return false
  end
  if M.is_floating_window(winid) or M.is_chat_related_window(winid) then
    return false
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end

  return vim.api.nvim_get_option_value('buftype', { buf = bufnr }) == ''
end

function M.resolve_workspace_file_window()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local candidates = {}

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if M.is_workspace_file_window(winid) then
      candidates[#candidates + 1] = winid
    end
  end

  table.sort(candidates, function(a, b)
    local a_col, a_row = win_sort_key(a)
    local b_col, b_row = win_sort_key(b)
    if a_col == b_col then
      return a_row < b_row
    end
    return a_col < b_col
  end)

  return candidates[1]
end

function M.resolve_chat_anchor_window()
  local current_tab = vim.api.nvim_get_current_tabpage()
  if
    state.chat_winid
    and vim.api.nvim_win_is_valid(state.chat_winid)
    and vim.api.nvim_win_get_tabpage(state.chat_winid) == current_tab
    and not M.is_floating_window(state.chat_winid)
  then
    return state.chat_winid
  end
  if
    state.input_winid
    and vim.api.nvim_win_is_valid(state.input_winid)
    and vim.api.nvim_win_get_tabpage(state.input_winid) == current_tab
    and not M.is_floating_window(state.input_winid)
  then
    return state.input_winid
  end
  return nil
end

function M.open_path_safely(path)
  if type(path) ~= 'string' or path == '' then
    return nil, 'missing path'
  end

  local target_winid = M.resolve_workspace_file_window()
  if not target_winid then
    local anchor_winid = M.resolve_chat_anchor_window() or M.resolve_split_target()
    if not anchor_winid then
      return nil, 'No non-floating window available for file open'
    end
    local placeholder = vim.api.nvim_create_buf(false, true)
    target_winid = vim.api.nvim_open_win(placeholder, true, {
      split = 'left',
      win = anchor_winid,
    })
  end

  local ok, err = pcall(vim.api.nvim_win_call, target_winid, function()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  end)

  vim.api.nvim_set_current_win(target_winid)
  if ok then
    return true
  end

  local bufnr = vim.fn.bufadd(path)
  if bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, path)
  end

  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or { '' }
  vim.api.nvim_win_set_buf(target_winid, bufnr)
  vim.bo[bufnr].buftype = ''
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  return nil, err
end

function M.set_window_syntax(winid, syntax)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if type(syntax) ~= 'string' or syntax == '' then
    return
  end

  vim.api.nvim_win_call(winid, function()
    vim.cmd('setlocal syntax=' .. syntax)
  end)
end

function M.disable_folds(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local wo = vim.wo[winid]
  wo.foldmethod = 'manual'
  wo.foldexpr = '0'
  wo.foldenable = false
end

function M.protect_markdown_buffer(bufnr, winid)
  M.disable_folds(winid)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].copilot_agent_treesitter_disabled = nil
  end
  if state.config.chat and state.config.chat.protect_markdown_buffer == false then
    return
  end

  -- This is an upstream Neovim Treesitter/folding workaround for transient
  -- plugin-owned markdown UI buffers, not a markdown rendering issue in this plugin.
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].copilot_agent_treesitter_disabled = true
  end

  if not vim.treesitter or type(vim.treesitter.stop) ~= 'function' then
    return
  end

  vim.schedule(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.treesitter.stop, bufnr)
    end
  end)
end

local function chat_streaming_active()
  if state.chat_busy ~= true then
    return false
  end
  return type(state.active_turn_assistant_index) == 'number' or type(state.live_assistant_entry_index) == 'number'
end

function M.sync_chat_markdown_conceal(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local restore_level = state.chat_default_conceallevel
  if type(restore_level) ~= 'number' then
    restore_level = vim.wo[winid].conceallevel
    state.chat_default_conceallevel = restore_level
  end
  restore_level = math.max(0, math.floor(restore_level))

  local target = chat_streaming_active() and 0 or restore_level
  if vim.wo[winid].conceallevel ~= target then
    vim.wo[winid].conceallevel = target
  end
end

return M
