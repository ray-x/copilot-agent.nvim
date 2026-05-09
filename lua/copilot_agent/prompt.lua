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

-- Wave gradient groups: 1 = brightest, 5 = dimmest (idle).
-- As the user types, a colour wave sweeps across the mode label and into the
-- arrows: each new keystroke advances the fully-lit zone by one character,
-- with a smooth gradient tail fading into the dim state.
local wave_groups = {
  'CopilotAgentPromptWave1',
  'CopilotAgentPromptWave2',
  'CopilotAgentPromptWave3',
  'CopilotAgentPromptWave4',
  'CopilotAgentPromptWaveDim',
}
local wave_palettes = {
  cold = { '#c678dd', '#a15fb5', '#7b478e', '#552e66', '#371a47' },
  warm = { '#98c379', '#79a25f', '#598045', '#3a5f2a', '#214415' },
}

local function prompt_style()
  local configured = (((state.config or {}).prompt or {}).style or 'cold')
  configured = type(configured) == 'string' and configured:lower() or 'cold'
  return palettes[configured] and configured or 'cold'
end

--- Build the prompt segments with an optional per-character wave animation.
---
--- @param icon string|nil  Emoji icon prefix (rendered as-is, outside the wave).
--- @param mode_text string|nil  Mode label text (e.g. "agent"). Each character
---   participates in the wave gradient.  When nil the prompt contains only the
---   arrows.
--- @param typed_count number|nil  Number of characters the user has typed in
---   the input buffer.  0 or nil = idle (everything dim).
--- @return string visible  Full visible prompt text (for cursor positioning).
--- @return table segments  Segment list for `apply()`.
--- @return string placeholder  Invisible placeholder string for `prompt_setprompt`.
function M.build(icon, mode_text, typed_count)
  -- Backward-compat: build() or build(nil) → no label, idle.
  icon = type(icon) == 'string' and icon or ''
  mode_text = type(mode_text) == 'string' and mode_text or ''
  typed_count = tonumber(typed_count) or 0

  local segments = {}

  -- Icon segment — emoji rendered by the terminal, no fg colour control.
  if icon ~= '' then
    segments[#segments + 1] = { text = icon }
  end

  -- Collect all animated positions: mode-text characters followed by arrows.
  -- Each position has a `lit_hl` — the highlight to use once the wave has
  -- fully passed that position.
  local positions = {}
  if mode_text ~= '' then
    local chars = vim.fn.split(mode_text, '\\zs')
    for _, c in ipairs(chars) do
      positions[#positions + 1] = { text = c, lit_hl = wave_groups[1] }
    end
  end
  for _, group in ipairs(arrow_groups) do
    positions[#positions + 1] = { text = '❯', lit_hl = group }
  end

  -- Apply the wave gradient.  When there is no mode text (e.g. the dashboard
  -- prompt) the arrows use their natural palette colours without a wave.
  local has_wave = mode_text ~= ''
  local tail = #wave_groups - 1 -- number of gradient steps after bright
  for i, pos in ipairs(positions) do
    local hl
    if not has_wave then
      hl = pos.lit_hl
    elseif typed_count <= 0 then
      hl = wave_groups[#wave_groups]
    else
      local ahead = i - typed_count -- how far ahead of the wave front
      if ahead <= 0 then
        hl = pos.lit_hl
      elseif ahead < tail then
        hl = wave_groups[ahead + 1]
      else
        hl = wave_groups[#wave_groups]
      end
    end
    segments[#segments + 1] = { text = pos.text, hl = hl }
  end

  segments[#segments + 1] = { text = ' ' }

  local parts = {}
  for _, seg in ipairs(segments) do
    parts[#parts + 1] = seg.text
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
  local style = prompt_style()
  local palette = palettes[style]
  for idx, group in ipairs(arrow_groups) do
    vim.api.nvim_set_hl(0, group, { fg = palette[idx] })
  end
  local wave_colors = wave_palettes[style]
  for idx, group in ipairs(wave_groups) do
    vim.api.nvim_set_hl(0, group, { fg = wave_colors[idx] })
  end
end

M._arrow_groups = arrow_groups
M._palettes = palettes
M._wave_groups = wave_groups
M._wave_palettes = wave_palettes

return M
