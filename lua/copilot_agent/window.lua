-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local state = require('copilot_agent.config').state

local M = {}

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

return M
