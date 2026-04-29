-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local M = {}

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
