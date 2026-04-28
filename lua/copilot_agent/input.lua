-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local chat = require('copilot_agent.chat')
local utils = require('copilot_agent.utils')

local state = cfg.state
local SLASH_COMMANDS = cfg.SLASH_COMMANDS

local request = http.request

local working_directory = service.working_directory

local refresh_statuslines = sl.refresh_statuslines

local split_lines = utils.split_lines

local set_agent_mode = chat.set_agent_mode
local setup_action_keymaps = chat.setup_action_keymaps

local M = {}

local input_modes = { 'ask', 'plan', 'agent', 'autopilot' }

local _mode_permission = {
  ask = 'interactive',
  plan = 'interactive',
  agent = 'interactive',
  autopilot = 'approve-all',
}

local _mode_icon = {
  ask = '💬',
  plan = '📋',
  agent = '🤖',
  autopilot = '🚀',
}

local function create_input_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, 'copilot-agent-input')
  vim.bo[bufnr].buftype = 'prompt'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'hide'
  -- filetype = 'markdown' enables treesitter highlighting and render-markdown.
  -- Must be set *after* buftype so FileType autocmds fire with the right buftype.
  vim.bo[bufnr].filetype = 'markdown'
  -- copilot.lua skips prompt buffers by default; this explicit flag overrides it.
  vim.b[bufnr].copilot_enabled = true

  local function prompt_prefix()
    local mode = state.input_mode or 'agent'
    local icon = _mode_icon[mode] or ''
    return icon .. mode .. '❯ '
  end

  local function refresh_prompt()
    vim.fn.prompt_setprompt(bufnr, prompt_prefix())
    refresh_statuslines()
  end

  local function get_input_text()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local prompt = vim.fn.prompt_getprompt(bufnr)
    local text = table.concat(lines, '\n')
    if prompt ~= '' and vim.startswith(text, prompt) then
      text = text:sub(#prompt + 1)
    end
    return text
  end

  local function set_input_text(text)
    local lines = split_lines(text or '')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
      vim.api.nvim_win_set_cursor(state.input_winid, { #lines, #lines[#lines] })
    end
    vim.cmd('startinsert')
  end

  local function remember_prompt(text)
    local prompt = vim.trim(text or '')
    if prompt == '' then
      return
    end
    if state.prompt_history[#state.prompt_history] == prompt then
      return
    end
    table.insert(state.prompt_history, prompt)
  end

  local function navigate_prompt_history(direction)
    if #state.prompt_history == 0 then
      return
    end

    local draft_index = #state.prompt_history + 1
    if state.prompt_history_index == nil then
      state.prompt_history_draft = get_input_text()
      state.prompt_history_index = draft_index
    end

    local next_index = state.prompt_history_index + direction
    if next_index < 1 then
      next_index = 1
    elseif next_index > draft_index then
      next_index = draft_index
    end

    if next_index == state.prompt_history_index then
      return
    end

    state.prompt_history_index = next_index
    if next_index == draft_index then
      set_input_text(state.prompt_history_draft)
      return
    end
    set_input_text(state.prompt_history[next_index])
  end

  local function close_input_window()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    state.prompt_history_index = nil
    state.prompt_history_draft = ''
    if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
      vim.api.nvim_win_close(state.input_winid, true)
      state.input_winid = nil
    end
    if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
      vim.api.nvim_set_current_win(state.chat_winid)
    end
  end

  local function submit(text)
    remember_prompt(text)
    -- Clear the input line and reset history navigation, but keep the window open.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    state.prompt_history_index = nil
    state.prompt_history_draft = ''
    -- Re-apply the prompt prefix (cleared by buf_set_lines).
    vim.fn.prompt_setprompt(bufnr, prompt_prefix())
    vim.cmd('startinsert')
    if text ~= '' then
      local attachments = vim.deepcopy(state.pending_attachments)
      state.pending_attachments = {}
      state.chat_busy = true
      refresh_statuslines()
      require('copilot_agent').ask(text, { attachments = attachments })
    end
  end

  local function cancel()
    close_input_window()
  end

  vim.fn.prompt_setcallback(bufnr, function(text)
    submit(vim.trim(text or ''))
  end)

  local function submit_buffer()
    submit(vim.trim(get_input_text()))
  end

  -- Apply all shared action keymaps, then override the ones that differ in input context.
  setup_action_keymaps(bufnr)

  -- <C-s> submits in prompt mode; <CR> submits via prompt_setcallback().
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit_buffer, { buffer = bufnr, silent = true, desc = 'Submit prompt to Copilot' })
  vim.keymap.set('n', 'q', cancel, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
  vim.keymap.set('i', '<Esc>', '<Esc>', { buffer = bufnr, silent = true, desc = 'Switch to normal mode' })
  -- <C-t> in input also refreshes the prompt prefix and returns to insert mode.
  vim.keymap.set({ 'n', 'i' }, '<C-t>', function()
    local idx = 1
    for i, m in ipairs(input_modes) do
      if m == state.input_mode then
        idx = i
        break
      end
    end
    local new_mode = input_modes[(idx % #input_modes) + 1]
    state.input_mode = new_mode
    set_agent_mode(new_mode)

    -- Apply the natural permission mode for this input mode.
    local natural_perm = _mode_permission[new_mode]
    if natural_perm and natural_perm ~= state.permission_mode then
      state.permission_mode = natural_perm
      if state.session_id then
        request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = natural_perm }, function(_, err)
          if err then
            cfg.notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
          end
        end)
      end
    end

    refresh_prompt()
    require('copilot_agent.statusline').refresh_statuslines()
    vim.cmd('startinsert!')
  end, { buffer = bufnr, silent = true, desc = 'Cycle Copilot input mode (ask/plan/agent/autopilot)' })
  -- History navigation replaces buffer content directly in input context.
  vim.keymap.set({ 'n', 'i' }, '<C-p>', function()
    navigate_prompt_history(-1)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<C-n>', function()
    navigate_prompt_history(1)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-p>', function()
    navigate_prompt_history(-1)
  end, { buffer = bufnr, silent = true, desc = 'Previous Copilot prompt' })
  vim.keymap.set({ 'n', 'i' }, '<M-n>', function()
    navigate_prompt_history(1)
  end, { buffer = bufnr, silent = true, desc = 'Next Copilot prompt' })

  -- Set the initial prompt prefix to reflect the current mode.
  refresh_prompt()

  -- Omnifunc for @ file mentions and / slash command completion.
  local function input_omnifunc(findstart, base)
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)

    if findstart == 1 then
      local pos = before:find('[@/][^%s]*$')
      if pos then
        return pos - 1
      end
      return -2
    end

    local items = {}
    if vim.startswith(base, '@') then
      local query = base:sub(2)
      local wd = working_directory()
      local pattern = wd .. '/' .. query .. '*'
      local files = vim.fn.glob(pattern, false, true)
      for _, f in ipairs(files) do
        local rel = f:sub(#wd + 2)
        table.insert(items, { word = '@' .. rel, abbr = rel, menu = '[file]' })
      end
    elseif vim.startswith(base, '/') then
      local query = base:sub(2):lower()
      for _, cmd in ipairs(SLASH_COMMANDS) do
        local name = cmd.word:sub(2):lower()
        if query == '' or vim.startswith(name, query) then
          table.insert(items, { word = cmd.word, menu = cmd.info })
        end
      end
    end
    return items
  end

  vim.bo[bufnr].omnifunc = ''
  vim.api.nvim_buf_set_option(bufnr, 'completefunc', "v:lua.require'copilot_agent'.input_omnifunc")

  -- Store omnifunc on the module so v:lua can reach it.
  require('copilot_agent').input_omnifunc = input_omnifunc

  vim.keymap.set('i', '<Tab>', '<C-x><C-u>', { buffer = bufnr, silent = true, desc = 'Trigger completion' })

  -- Auto-trigger completion when @ or / is typed.
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = bufnr,
    callback = function()
      local cur_line = vim.api.nvim_get_current_line()
      local cur_col = vim.api.nvim_win_get_cursor(0)[2]
      local ch = cur_line:sub(cur_col, cur_col)
      if ch == '@' or ch == '/' then
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-x><C-u>', true, false, true), 'n')
      end
    end,
  })

  return bufnr
end

function M.open_input_window()
  local function apply_prefill()
    if state.prompt_prefill and state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr) then
      local text = state.prompt_prefill
      state.prompt_prefill = nil
      vim.schedule(function()
        vim.api.nvim_buf_set_lines(state.input_bufnr, 0, -1, false, { text })
        vim.cmd('normal! $')
        vim.cmd('startinsert!')
      end)
    end
  end

  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_set_current_win(state.input_winid)
    vim.cmd('startinsert')
    apply_prefill()
    return
  end

  if not state.input_bufnr or not vim.api.nvim_buf_is_valid(state.input_bufnr) then
    state.input_bufnr = create_input_buffer()
  end

  -- Open a small horizontal split below the chat window via the API.
  local parent_win = (state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid)) and state.chat_winid or 0
  state.input_winid = vim.api.nvim_open_win(state.input_bufnr, true, {
    split = 'below',
    win = parent_win,
    height = 5,
  })

  local wo = vim.wo[state.input_winid]
  wo.winfixheight = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  -- Statusline is populated by refresh_input_statusline below.
  refresh_statuslines()

  vim.cmd('startinsert')
  apply_prefill()

  -- copilot.lua's default should_attach rejects buftype='prompt' and buflisted=false.
  -- Force-attach the LSP client directly so virtual-text suggestions work.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(state.input_bufnr) then
      return
    end
    local ok, copilot_client = pcall(require, 'copilot.client')
    if ok and type(copilot_client.buf_attach) == 'function' then
      pcall(copilot_client.buf_attach, true, state.input_bufnr)
    end
  end)
end

return M
