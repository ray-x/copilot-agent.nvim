-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local service = require('copilot_agent.service')
local session = require('copilot_agent.session')
local session_names = require('copilot_agent.session_names')
local utils = require('copilot_agent.utils')
local win = require('copilot_agent.window')

local state = cfg.state
local notify = cfg.notify

local working_directory = service.working_directory

local M = {}

local DASHBOARD_NS = vim.api.nvim_create_namespace('copilot_agent_dashboard')
local DASHBOARD_TITLE = 'Copilot Agent Dashboard'
local DASHBOARD_SUBTITLE = 'Use the prompt below to resume the latest session in this folder or create a new one.'
local DASHBOARD_PROMPT_TITLE = 'Enter command (e.g. `/init`, `/ask` etc.)'
local DASHBOARD_SHORTCUTS = {
  { key = 'l', label = 'Connect last session' },
  { key = 's', label = 'Select session' },
  { key = 'm', label = 'Select model' },
}

local function normalize_logo_lines(text)
  local lines = vim.split(text, '\n', { plain = true })
  while #lines > 0 and lines[1]:match('^%s*$') do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match('^%s*$') do
    table.remove(lines)
  end
  for idx, line in ipairs(lines) do
    lines[idx] = line:gsub('%s+$', '')
  end

  local min_indent
  for _, line in ipairs(lines) do
    if line:match('%S') then
      local indent = #(line:match('^(%s*)') or '')
      if min_indent == nil or indent < min_indent then
        min_indent = indent
      end
    end
  end

  if min_indent and min_indent > 0 then
    for idx, line in ipairs(lines) do
      lines[idx] = line:sub(min_indent + 1)
    end
  end

  return lines
end

local DASHBOARD_LOGO_LINES = normalize_logo_lines([=[
                         =≠×
                         ≠==
                    √≈≈≈≈≠≠≈≈≈≈≈π
                 √≠≠≠≠≠≠≠≠≠≠≠≠≠≠≠≠≠
                 ≈≠∞π           π≈≠≠
       ∞≈π√≠√  ∞=≠≠√  ≈∞     ≈≈ π∞≠÷≠∞
      π=≠∞ ∞=≈ ≠≠≠≠√ ==× ∞ π√÷=∞π∞≠=≠≠∞
       ∞÷≠≈≠=∞ ≠÷≠≠√             ∞≠÷÷≠
        √≠≈≠≠≈   ≠≠≈√ππππππ ππππ∞≠=≠
         ∞≠=≠√    ∞≠============÷=∞
           ≈≈≈∞   ≈≠≠=≠≠≠≠≠≠≠≠≠≠≠=∞
           π≠≠≠==÷=≠≠≠≠≠≠≠≈≠≠≠=≠≠==×≠π
              ∞≠÷÷≠≠≈∞ πππ √≠≠≈÷≠≠=÷==≠∞
                √≠≠≠∞       ≠≠≠≠≠≠=÷≠≠∞∞≈√
                 ∞≠≠≈π π  ππ≠≠≈≠≠≠=≠   ∞≈≠∞
                 ∞≠≠≠÷≠≠≠=≠=≠≠≠≠≠≠=≠   ∞=≠≠π
                  ≠==≠=======≠===÷≠    ∞≠≠≈∞∞
                    ∞∞∞       ≠√√√     ∞×÷=÷=
                    ≠≠≠π      =≠≠√     ∞≠≠π≠π
                    ≈∞≈π      =∞∞√      ∞≠√
                  ∞≈∞≈≠≠≈   ≈∞∞≈≠≠∞
]=])

local dashboard_session_cache = {
  loaded = false,
  error = nil,
  session = nil,
  working_directory = nil,
}

local function clear_dashboard_state(bufnr)
  if state.dashboard_bufnr == bufnr then
    state.dashboard_bufnr = nil
    state.dashboard_winid = nil
  end
end

local function clear_prompt_state(bufnr)
  if state.dashboard_prompt_bufnr == bufnr then
    state.dashboard_prompt_bufnr = nil
    state.dashboard_prompt_winid = nil
  end
end

local function centered_text(text, width)
  if text == '' then
    return ''
  end
  local text_width = vim.fn.strdisplaywidth(text)
  if text_width >= width then
    return text
  end
  return string.rep(' ', math.floor((width - text_width) / 2)) .. text
end

local function art_block_width()
  local max_width = 0
  for _, line in ipairs(DASHBOARD_LOGO_LINES) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end
  return max_width
end

local function centered_art_line(text, width)
  local block_width = art_block_width()
  if block_width >= width then
    return text
  end

  local left_padding = math.floor((width - block_width) / 2)
  local right_padding = math.max(0, block_width - vim.fn.strdisplaywidth(text))
  return string.rep(' ', left_padding) .. text .. string.rep(' ', right_padding)
end

local function project_display()
  return vim.fn.fnamemodify(working_directory(), ':~')
end

local function dashboard_buffer_name()
  return ((state.config or {}).dashboard or {}).buf_name or 'CopilotAgentDashboard'
end

local function dashboard_prompt_buffer_name()
  return dashboard_buffer_name() .. 'Prompt'
end

local function exclude_from_mini_sessions(bufnr)
  vim.b[bufnr].minisessions_disable = true
end

local function formatted_session_label(session_info)
  if type(session_info) ~= 'table' then
    return nil
  end
  local session_id = session_info.sessionId
  if type(session_id) ~= 'string' or session_id == '' then
    return nil
  end

  local summary = utils.truncate_session_summary(session_names.resolve(session_info.summary, session_id), 32)
  local formatted_id = utils.format_session_id(session_id)
  if summary ~= '' then
    return string.format('%s [%s]', summary, formatted_id)
  end
  return formatted_id
end

local function last_session_line()
  if not dashboard_session_cache.loaded then
    return 'Last session: loading...'
  end

  local label = formatted_session_label(dashboard_session_cache.session)
  if label then
    return 'Last session: ' .. label
  end
  if dashboard_session_cache.error then
    return 'Last session: unavailable while the service starts'
  end
  return 'Last session: none found in this folder'
end

local function shortcut_text(shortcut)
  return string.format('[%s] %s', shortcut.key, shortcut.label)
end

local function dashboard_items()
  local items = {}
  for _, line in ipairs(DASHBOARD_LOGO_LINES) do
    items[#items + 1] = { text = line, kind = 'art' }
  end
  items[#items + 1] = { text = '', kind = 'blank' }
  items[#items + 1] = { text = DASHBOARD_TITLE, kind = 'title' }
  items[#items + 1] = { text = DASHBOARD_SUBTITLE, kind = 'hint' }
  items[#items + 1] = { text = '', kind = 'blank' }
  items[#items + 1] = { text = 'Project: ' .. project_display(), kind = 'info' }
  items[#items + 1] = { text = last_session_line(), kind = 'info' }
  items[#items + 1] = { text = '', kind = 'blank' }
  for _, shortcut in ipairs(DASHBOARD_SHORTCUTS) do
    items[#items + 1] = { text = shortcut_text(shortcut), kind = 'shortcut' }
  end
  return items
end

local function dashboard_layout(winid)
  local width = vim.api.nvim_win_get_width(winid)
  local height = vim.api.nvim_win_get_height(winid)
  local items = dashboard_items()
  local lines = {}
  local kinds = {}
  local top_padding = math.max(0, math.floor((height - #items) / 2))

  for _ = 1, top_padding do
    lines[#lines + 1] = ''
    kinds[#kinds + 1] = 'blank'
  end

  for _, item in ipairs(items) do
    if item.kind == 'art' then
      lines[#lines + 1] = centered_art_line(item.text, width)
    else
      lines[#lines + 1] = centered_text(item.text, width)
    end
    kinds[#kinds + 1] = item.kind
  end

  return lines, kinds
end

local function add_prefix_highlight(bufnr, row, line, prefix)
  local start_col = line:find(prefix, 1, true)
  if not start_col then
    return
  end
  vim.api.nvim_buf_add_highlight(bufnr, DASHBOARD_NS, 'CopilotAgentDashboardKey', row, start_col - 1, start_col - 1 + #prefix)
end

local function add_bracket_key_highlight(bufnr, row, line)
  local key_start, key_end = line:find('%[[^%]]+%]')
  if not key_start or not key_end then
    return
  end
  vim.api.nvim_buf_add_highlight(bufnr, DASHBOARD_NS, 'CopilotAgentDashboardKey', row, key_start - 1, key_end)
end

local function apply_highlights(bufnr, lines, kinds)
  vim.api.nvim_buf_clear_namespace(bufnr, DASHBOARD_NS, 0, -1)
  for idx, kind in ipairs(kinds) do
    local row = idx - 1
    if kind == 'art' then
      vim.api.nvim_buf_add_highlight(bufnr, DASHBOARD_NS, 'CopilotAgentDashboardArt', row, 0, -1)
    elseif kind == 'title' then
      vim.api.nvim_buf_add_highlight(bufnr, DASHBOARD_NS, 'CopilotAgentDashboardHeader', row, 0, -1)
    elseif kind == 'hint' then
      vim.api.nvim_buf_add_highlight(bufnr, DASHBOARD_NS, 'CopilotAgentDashboardHint', row, 0, -1)
    elseif kind == 'info' then
      vim.api.nvim_buf_add_highlight(bufnr, DASHBOARD_NS, 'CopilotAgentDashboardHint', row, 0, -1)
      add_prefix_highlight(bufnr, row, lines[idx], 'Project:')
      add_prefix_highlight(bufnr, row, lines[idx], 'Last session:')
    elseif kind == 'shortcut' then
      vim.api.nvim_buf_add_highlight(bufnr, DASHBOARD_NS, 'CopilotAgentDashboardHint', row, 0, -1)
      add_bracket_key_highlight(bufnr, row, lines[idx])
    end
  end
end

local function render(bufnr)
  local winid = state.dashboard_winid
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end

  local lines, kinds = dashboard_layout(winid)
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  apply_highlights(bufnr, lines, kinds)
end

local function apply_dashboard_window_options(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  win.disable_folds(winid)
  local wo = vim.wo[winid]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.spell = false
  wo.list = false
  wo.wrap = false
  wo.cursorline = false
  wo.colorcolumn = ''
end

local function apply_prompt_window_options(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  win.disable_folds(winid)
  local wo = vim.wo[winid]
  wo.winfixheight = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.spell = false
  wo.list = false
  wo.wrap = false
  wo.cursorline = false
  wo.colorcolumn = ''
  wo.winbar = '%#CopilotAgentDashboardHeader#%=' .. DASHBOARD_PROMPT_TITLE .. '%='
end

local function focus_prompt()
  if state.dashboard_prompt_winid and vim.api.nvim_win_is_valid(state.dashboard_prompt_winid) then
    vim.api.nvim_set_current_win(state.dashboard_prompt_winid)
    vim.cmd('startinsert!')
  end
end

local function close_prompt_window()
  if state.dashboard_prompt_winid and vim.api.nvim_win_is_valid(state.dashboard_prompt_winid) then
    pcall(vim.api.nvim_win_close, state.dashboard_prompt_winid, true)
  end
  if state.dashboard_prompt_bufnr and vim.api.nvim_buf_is_valid(state.dashboard_prompt_bufnr) then
    pcall(vim.api.nvim_buf_delete, state.dashboard_prompt_bufnr, { force = true })
  end
  state.dashboard_prompt_bufnr = nil
  state.dashboard_prompt_winid = nil
end

local function refresh_last_session_cache()
  dashboard_session_cache.working_directory = working_directory()
  dashboard_session_cache.session, dashboard_session_cache.error = session.latest_project_session_sync()
  dashboard_session_cache.loaded = true
end

local function ensure_dashboard_service_refresh()
  if not (state.config and state.config.service and state.config.service.auto_start) then
    return
  end

  service.ensure_service_running(function(err)
    if err then
      return
    end
    refresh_last_session_cache()
    M.refresh()
  end)
end

local function replace_dashboard_with_chat()
  local dashboard_winid = state.dashboard_winid
  close_prompt_window()
  if dashboard_winid and vim.api.nvim_win_is_valid(dashboard_winid) then
    vim.api.nvim_set_current_win(dashboard_winid)
  end

  local agent = require('copilot_agent')
  agent.open_chat({ replace_current = true, activate_input_on_session_ready = false })
  return agent
end

local function handoff_to_chat(text)
  local agent = replace_dashboard_with_chat()
  if agent.execute_slash_command(text, {}) then
    return
  end
  agent.ask(text)
end

local function connect_last_session()
  local agent = replace_dashboard_with_chat()
  session.attach_latest_project_session_or_create(function(_, err)
    if err then
      notify('Failed to connect session: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.schedule(function()
      agent._open_input_window()
    end)
  end)
end

local function select_session()
  local agent = replace_dashboard_with_chat()
  agent.switch_session()
end

local function select_model()
  require('copilot_agent').select_model('')
end

local function submit_prompt(text)
  local prompt = vim.trim(text or '')
  if prompt == '' then
    focus_prompt()
    return
  end

  session.attach_latest_project_session_or_create(function(_, err)
    if err then
      notify('Failed to connect session: ' .. tostring(err), vim.log.levels.ERROR)
      focus_prompt()
      return
    end
    handoff_to_chat(prompt)
  end)
end

local function run_shortcut(key)
  if key == 'l' then
    connect_last_session()
    return
  end
  if key == 's' then
    select_session()
    return
  end
  if key == 'm' then
    select_model()
  end
end

local function attach_dashboard_keymaps(bufnr)
  vim.keymap.set('n', 'q', function()
    M.close()
  end, { buffer = bufnr, silent = true, desc = 'Close Copilot Agent dashboard' })

  for _, shortcut in ipairs(DASHBOARD_SHORTCUTS) do
    vim.keymap.set('n', shortcut.key, function()
      run_shortcut(shortcut.key)
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = 'Copilot Agent dashboard: ' .. shortcut.label,
    })
  end

  for _, key in ipairs({ '<CR>', 'i', 'a' }) do
    vim.keymap.set('n', key, function()
      focus_prompt()
    end, { buffer = bufnr, silent = true, desc = 'Focus Copilot Agent dashboard prompt' })
  end
end

local function attach_prompt_keymaps(bufnr)
  vim.keymap.set('n', 'q', function()
    M.close()
  end, { buffer = bufnr, silent = true, desc = 'Close Copilot Agent dashboard' })

  for _, shortcut in ipairs(DASHBOARD_SHORTCUTS) do
    vim.keymap.set('n', shortcut.key, function()
      run_shortcut(shortcut.key)
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = 'Copilot Agent dashboard: ' .. shortcut.label,
    })
  end

  vim.keymap.set('n', '<Esc>', function()
    M.close()
  end, { buffer = bufnr, silent = true, desc = 'Close Copilot Agent dashboard' })
  vim.keymap.set('i', '<Esc>', '<Esc>', { buffer = bufnr, silent = true, desc = 'Switch to normal mode' })
end

local function create_dashboard_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local buf_name = dashboard_buffer_name()
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'copilot-agent-dashboard'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.api.nvim_buf_set_name(bufnr, buf_name)
  exclude_from_mini_sessions(bufnr)
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      clear_dashboard_state(bufnr)
      close_prompt_window()
    end,
  })
  attach_dashboard_keymaps(bufnr)
  return bufnr
end

local function create_prompt_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'prompt'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'copilot-agent-dashboard-prompt'
  vim.api.nvim_buf_set_name(bufnr, dashboard_prompt_buffer_name())
  exclude_from_mini_sessions(bufnr)
  vim.fn.prompt_setprompt(bufnr, '❯ ')
  vim.fn.prompt_setcallback(bufnr, function(text)
    submit_prompt(text)
  end)
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      clear_prompt_state(bufnr)
    end,
  })
  attach_prompt_keymaps(bufnr)
  return bufnr
end

function M.find_window()
  if not (state.dashboard_bufnr and vim.api.nvim_buf_is_valid(state.dashboard_bufnr)) then
    state.dashboard_winid = nil
    return nil
  end

  if state.dashboard_winid and vim.api.nvim_win_is_valid(state.dashboard_winid) then
    if vim.api.nvim_win_get_buf(state.dashboard_winid) == state.dashboard_bufnr then
      return state.dashboard_winid
    end
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, winid in ipairs(vim.fn.win_findbuf(state.dashboard_bufnr)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_tabpage(winid) == current_tab then
      state.dashboard_winid = winid
      return winid
    end
  end

  for _, winid in ipairs(vim.fn.win_findbuf(state.dashboard_bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      state.dashboard_winid = winid
      return winid
    end
  end

  state.dashboard_winid = nil
  return nil
end

function M.is_dashboard_buffer(bufnr)
  return type(bufnr) == 'number' and state.dashboard_bufnr == bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

function M.refresh()
  if state.dashboard_bufnr and vim.api.nvim_buf_is_valid(state.dashboard_bufnr) then
    render(state.dashboard_bufnr)
  end
  if state.dashboard_prompt_winid and vim.api.nvim_win_is_valid(state.dashboard_prompt_winid) then
    apply_prompt_window_options(state.dashboard_prompt_winid)
  end
end

function M.open()
  local bufnr = state.dashboard_bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = create_dashboard_buffer()
    state.dashboard_bufnr = bufnr
  end

  local winid = M.find_window()
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_current_win(winid)
  else
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end

  state.dashboard_winid = winid
  apply_dashboard_window_options(winid)

  close_prompt_window()
  local prompt_bufnr = create_prompt_buffer()
  state.dashboard_prompt_bufnr = prompt_bufnr
  state.dashboard_prompt_winid = vim.api.nvim_open_win(prompt_bufnr, true, {
    split = 'below',
    win = winid,
    height = 2,
  })
  apply_prompt_window_options(state.dashboard_prompt_winid)

  refresh_last_session_cache()
  M.refresh()
  ensure_dashboard_service_refresh()
  focus_prompt()
  return bufnr
end

function M.close()
  close_prompt_window()

  local winid = M.find_window()
  if winid and vim.api.nvim_win_is_valid(winid) then
    local tab = vim.api.nvim_win_get_tabpage(winid)
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    if #wins > 1 then
      vim.api.nvim_win_close(winid, true)
      return
    end
    local current = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(winid)
    vim.cmd('enew')
    if current ~= winid and vim.api.nvim_win_is_valid(current) then
      vim.api.nvim_set_current_win(current)
    end
    return
  end

  if state.dashboard_bufnr and vim.api.nvim_buf_is_valid(state.dashboard_bufnr) then
    pcall(vim.api.nvim_buf_delete, state.dashboard_bufnr, { force = true })
  end
  state.dashboard_bufnr = nil
  state.dashboard_winid = nil
end

local function current_buffer_is_empty_startup_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].modified or vim.bo[bufnr].buftype ~= '' then
    return false
  end
  if vim.api.nvim_buf_get_name(bufnr) ~= '' then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return #lines == 1 and lines[1] == ''
end

function M.should_open_on_startup()
  local dashboard_cfg = ((state.config or {}).dashboard or {})
  if dashboard_cfg.auto_open == false then
    return false
  end
  if vim.fn.argc() ~= 0 then
    return false
  end
  return current_buffer_is_empty_startup_buffer()
end

function M.maybe_open_on_startup()
  if M.should_open_on_startup() then
    M.open()
  end
end

M._submit_prompt = submit_prompt
M._logo_lines = DASHBOARD_LOGO_LINES

return M
