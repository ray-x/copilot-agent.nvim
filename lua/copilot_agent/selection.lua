-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local M = {}

local function display_name(path)
  if type(path) ~= 'string' or path == '' then
    return '[No Name]'
  end
  local name = vim.fn.fnamemodify(path, ':t')
  if type(name) == 'string' and name ~= '' then
    return name
  end
  return '[No Name]'
end

local function swap_range(start_row, start_col, end_row, end_col)
  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    return end_row, end_col, start_row, start_col
  end
  return start_row, start_col, end_row, end_col
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

local function extract_block_text(bufnr, start_row, start_col, end_row, end_col)
  local lines = {}
  for row = start_row, end_row do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    local from_col = clamp(start_col, 0, #line)
    local to_col = clamp(end_col + 1, 0, #line)
    if to_col < from_col then
      to_col = from_col
    end
    lines[#lines + 1] = line:sub(from_col + 1, to_col)
  end
  return table.concat(lines, '\n')
end

local function extract_text(bufnr, start_row, start_col, end_row, end_col, visual_mode)
  if visual_mode == '\022' then
    return extract_block_text(bufnr, start_row, start_col, end_row, end_col)
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_text, bufnr, start_row, start_col, end_row, end_col + 1, {})
  if ok and type(lines) == 'table' then
    return table.concat(lines, '\n')
  end
  return extract_block_text(bufnr, start_row, start_col, end_row, end_col)
end

function M.current_buffer_selection(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local start_mark = vim.api.nvim_buf_get_mark(bufnr, '<')
  local end_mark = vim.api.nvim_buf_get_mark(bufnr, '>')
  if not start_mark or not end_mark or start_mark[1] == 0 or end_mark[1] == 0 then
    return nil
  end

  local start_row = start_mark[1] - 1
  local start_col = math.max(0, start_mark[2])
  local end_row = end_mark[1] - 1
  local end_col = math.max(0, end_mark[2])
  start_row, start_col, end_row, end_col = swap_range(start_row, start_col, end_row, end_col)

  local text = extract_text(bufnr, start_row, start_col, end_row, end_col, opts.visual_mode)
  text = type(text) == 'string' and text or ''
  if vim.trim(text) == '' then
    return nil
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local attachment = {
    type = 'selection',
    path = path,
    text = text,
    start_line = start_row,
    end_line = end_row,
    display = string.format('selection:%s:%d-%d', display_name(path), start_row + 1, end_row + 1),
  }
  return attachment
end

return M
