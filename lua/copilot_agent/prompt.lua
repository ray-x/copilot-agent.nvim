-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')

local state = cfg.state

local M = {}

local prompt_ns = vim.api.nvim_create_namespace('copilot_agent_prompt')
local arrow_groups = {
  'CopilotAgentPromptArrow1',
  'CopilotAgentPromptArrow2',
  'CopilotAgentPromptArrow3',
}
local palettes = {
  cold = { '#c678dd', '#a78bfa', '#61afef' },
  warm = { '#e06c75', '#e5c07b', '#98c379' },
}

local function prompt_style()
  local configured = (((state.config or {}).prompt or {}).style or 'cold')
  configured = type(configured) == 'string' and configured:lower() or 'cold'
  return palettes[configured] and configured or 'cold'
end

function M.build(label)
  local prefix = type(label) == 'string' and label or ''
  local segments = {}
  if prefix ~= '' then
    segments[#segments + 1] = { text = prefix }
  end
  segments[#segments + 1] = { text = '❯', hl = arrow_groups[1] }
  segments[#segments + 1] = { text = '❯', hl = arrow_groups[2] }
  segments[#segments + 1] = { text = '❯', hl = arrow_groups[3] }
  segments[#segments + 1] = { text = ' ' }

  local parts = {}
  for _, segment in ipairs(segments) do
    parts[#parts + 1] = segment.text
  end
  local visible = table.concat(parts)
  local placeholder = string.rep(' ', vim.fn.strdisplaywidth(visible))
  return visible, segments, placeholder
end

function M.apply(bufnr, segments, row)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  row = math.max(0, tonumber(row) or 0)
  segments = type(segments) == 'table' and segments or {}

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, prompt_ns, row, row + 1)
    if vim.api.nvim_buf_line_count(bufnr) <= row then
      return
    end

    local virt_text = {}
    for _, segment in ipairs(segments) do
      local text = segment.text or ''
      if text ~= '' then
        if segment.hl then
          virt_text[#virt_text + 1] = { text, segment.hl }
        else
          virt_text[#virt_text + 1] = { text }
        end
      end
    end
    if vim.tbl_isempty(virt_text) then
      return
    end

    vim.api.nvim_buf_set_extmark(bufnr, prompt_ns, row, 0, {
      virt_text = virt_text,
      virt_text_pos = 'overlay',
      virt_text_win_col = 0,
      hl_mode = 'combine',
      priority = 4096,
    })
  end)
end

function M.configure_highlights()
  local palette = palettes[prompt_style()]
  for idx, group in ipairs(arrow_groups) do
    vim.api.nvim_set_hl(0, group, { fg = palette[idx] })
  end
end

M._arrow_groups = arrow_groups
M._palettes = palettes

return M
