-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local session_names = require('copilot_agent.session_names')
local sl = require('copilot_agent.statusline')
local chat = require('copilot_agent.chat')
local utils = require('copilot_agent.utils')
local win = require('copilot_agent.window')

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
local session_label_max_len = 32
local is_list = vim.islist or vim.tbl_islist
local separator_ns = vim.api.nvim_create_namespace('copilot_agent_input_separator')

local function conversation_separator_text(width)
  width = math.max(tonumber(width) or 0, 12)
  return string.rep('-', width)
end

local function refresh_separator()
  if not state.input_bufnr or not vim.api.nvim_buf_is_valid(state.input_bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(state.input_bufnr, separator_ns, 0, -1)
  if not state.input_winid or not vim.api.nvim_win_is_valid(state.input_winid) then
    return
  end

  local width = vim.api.nvim_win_get_width(state.input_winid)
  vim.api.nvim_buf_set_extmark(state.input_bufnr, separator_ns, 0, 0, {
    virt_lines = { { { conversation_separator_text(width), 'CopilotAgentRule' } } },
    virt_lines_above = true,
    virt_lines_leftcol = true,
  })
end

local function frontmatter_name(path)
  local ok, lines = pcall(vim.fn.readfile, path, '', 32)
  if not ok or type(lines) ~= 'table' or lines[1] ~= '---' then
    return nil
  end

  for i = 2, #lines do
    local line = lines[i]
    if line == '---' then
      break
    end
    local raw = line:match('^name:%s*(.+)%s*$')
    if raw then
      raw = vim.trim(raw)
      local quoted = raw:match('^"(.*)"$') or raw:match("^'(.*)'$")
      return quoted or raw
    end
  end

  return nil
end

local function discovered_agent_names()
  local wd = working_directory()
  local files = {}
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/agents/*.agent.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/agents/**/*.agent.md', false, true))
  local items = {}
  local seen = {}

  for _, path in ipairs(files or {}) do
    local name = frontmatter_name(path) or vim.fn.fnamemodify(path, ':t:r:r')
    if type(name) == 'string' and name ~= '' and not seen[name] then
      seen[name] = true
      table.insert(items, name)
    end
  end

  table.sort(items)
  return items
end

local function discovered_skill_names()
  local wd = working_directory()
  local files = {}
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/*/SKILL.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/*/skill.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/**/SKILL.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/**/skill.md', false, true))

  local items = {}
  local seen = {}
  for _, path in ipairs(files) do
    local name = frontmatter_name(path) or vim.fn.fnamemodify(vim.fn.fnamemodify(path, ':h'), ':t')
    if type(name) == 'string' and name ~= '' and not seen[name] then
      seen[name] = true
      table.insert(items, name)
    end
  end

  table.sort(items)
  return items
end

local function command_completion_context(before)
  for _, command in ipairs({ 'agent', 'skills', 'model', 'resume', 'session', 'mcp', 'instructions' }) do
    local token = '/' .. command
    local lower_before = before:lower()
    local start_pos, end_pos
    local search_from = 1
    while true do
      local found_start, found_end = lower_before:find(token, search_from, true)
      if not found_start then
        break
      end
      local prev_char = found_start == 1 and '' or before:sub(found_start - 1, found_start - 1)
      local next_char = found_end == #before and '' or before:sub(found_end + 1, found_end + 1)
      if (found_start == 1 or prev_char:match('%s')) and (next_char == '' or next_char:match('%s')) then
        start_pos = found_start
        end_pos = found_end
      end
      search_from = found_start + 1
    end
    if start_pos then
      local raw_query = before:sub((end_pos or start_pos) + 1)
      return {
        kind = command,
        start = start_pos,
        ['end'] = end_pos,
        query = vim.trim(raw_query),
        at_token_end = (end_pos or start_pos) == #before,
      }
    end
  end

  return nil
end

local function discovered_instruction_names()
  local wd = working_directory()
  local files = {}
  local root_file = wd .. '/.github/copilot-instructions.md'
  if vim.fn.filereadable(root_file) == 1 then
    table.insert(files, root_file)
  end
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/instructions/*.instructions.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/instructions/**/*.instructions.md', false, true))

  local items = {}
  local seen = {}
  for _, path in ipairs(files) do
    local rel = path:sub(#wd + 2)
    if rel ~= '' and not seen[rel] then
      seen[rel] = true
      table.insert(items, rel)
    end
  end

  table.sort(items)
  return items
end

local function discovered_mcp_names()
  local wd = working_directory()
  local items = {}
  local seen = {}

  local function add(name)
    if type(name) ~= 'string' or name == '' or seen[name] then
      return
    end
    seen[name] = true
    table.insert(items, name)
  end

  local function add_from_value(value)
    if type(value) == 'table' then
      if is_list(value) then
        for _, entry in ipairs(value) do
          if type(entry) == 'string' then
            add(entry)
          elseif type(entry) == 'table' then
            add(entry.name or entry.id)
          end
        end
      else
        for name in pairs(value) do
          add(name)
        end
      end
    end
  end

  local function read_config(path)
    if vim.fn.filereadable(path) ~= 1 then
      return
    end
    local decoded = http.decode_json(table.concat(vim.fn.readfile(path), '\n'))
    if type(decoded) ~= 'table' then
      return
    end
    add_from_value(decoded.mcpServers)
    add_from_value(decoded.servers)
  end

  read_config(wd .. '/.mcp.json')
  read_config(wd .. '/.vscode/mcp.json')

  table.sort(items)
  return items
end

local function discovered_model_ids()
  local ok, model = pcall(require, 'copilot_agent.model')
  if not ok then
    return {}
  end

  if vim.tbl_isempty(state.model_cache) then
    local response = http.sync_request('GET', '/models', nil)
    if type(response) == 'table' then
      model.store_model_cache(response.models or {})
    end
  end

  return model.model_completion_items('')
end

local function discovered_session_items()
  local response = http.sync_request('GET', '/sessions', nil)
  if type(response) ~= 'table' then
    return {}
  end

  local merged = {}
  local order = {}
  local function upsert(session)
    local id = session and session.sessionId or nil
    if type(id) ~= 'string' or id == '' then
      return
    end
    if not merged[id] then
      merged[id] = vim.deepcopy(session)
      table.insert(order, id)
      return
    end

    local existing = merged[id]
    if session.live then
      local combined = vim.deepcopy(session)
      combined.summary = combined.summary or existing.summary
      combined.modifiedTime = combined.modifiedTime or existing.modifiedTime
      combined.startTime = combined.startTime or existing.startTime
      merged[id] = combined
      return
    end

    existing.summary = existing.summary or session.summary
    existing.modifiedTime = existing.modifiedTime or session.modifiedTime
    existing.startTime = existing.startTime or session.startTime
    existing.createdAt = existing.createdAt or session.createdAt
  end

  for _, session in ipairs(response.persisted or {}) do
    upsert(session)
  end
  for _, session in ipairs(response.live or {}) do
    upsert(session)
  end

  local items = {}
  for _, id in ipairs(order) do
    local session = merged[id]
    local summary = utils.truncate_session_summary(session_names.resolve(session.summary, id), session_label_max_len)
    local formatted_id = utils.format_session_id(id)
    local label = summary ~= '' and (summary .. ' [' .. formatted_id .. ']') or formatted_id
    table.insert(items, {
      id = id,
      label = label,
      summary = (session_names.resolve(session.summary, id) or ''):lower(),
    })
  end

  table.sort(items, function(left, right)
    return left.label < right.label
  end)
  return items
end

local function input_omnifunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local command_context = command_completion_context(before)

  if findstart == 1 then
    if command_context then
      return command_context.start - 1
    end
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
  elseif command_context and command_context.kind == 'agent' then
    local query = command_context.query:lower()
    for _, name in ipairs(discovered_agent_names()) do
      if query == '' or vim.startswith(name:lower(), query) then
        table.insert(items, {
          word = '/agent ' .. name,
          abbr = name,
          menu = '[agent]',
        })
      end
    end
  elseif command_context and command_context.kind == 'skills' then
    local query = command_context.query:lower()
    for _, name in ipairs(discovered_skill_names()) do
      if query == '' or vim.startswith(name:lower(), query) then
        table.insert(items, {
          word = '/skills ' .. name,
          abbr = name,
          menu = '[skill]',
        })
      end
    end
  elseif command_context and command_context.kind == 'model' then
    local query = command_context.query:lower()
    for _, id in ipairs(discovered_model_ids()) do
      if query == '' or vim.startswith(id:lower(), query) then
        table.insert(items, {
          word = '/model ' .. id,
          abbr = id,
          menu = '[model]',
        })
      end
    end
  elseif command_context and (command_context.kind == 'resume' or command_context.kind == 'session') then
    local query = command_context.query:lower()
    for _, session in ipairs(discovered_session_items()) do
      if query == '' or vim.startswith(session.id:lower(), query) or vim.startswith(session.summary, query) then
        table.insert(items, {
          word = '/' .. command_context.kind .. ' ' .. session.id,
          abbr = session.label,
          menu = '[session]',
        })
      end
    end
  elseif command_context and command_context.kind == 'mcp' then
    local query = command_context.query:lower()
    for _, name in ipairs(discovered_mcp_names()) do
      if query == '' or vim.startswith(name:lower(), query) then
        table.insert(items, {
          word = '/mcp ' .. name,
          abbr = name,
          menu = '[mcp]',
        })
      end
    end
  elseif command_context and command_context.kind == 'instructions' then
    local query = command_context.query:lower()
    for _, name in ipairs(discovered_instruction_names()) do
      if query == '' or vim.startswith(name:lower(), query) then
        table.insert(items, {
          word = '/instructions ' .. name,
          abbr = name,
          menu = '[instruction]',
        })
      end
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

local function resolve_chat_window()
  if type(chat.find_chat_window) == 'function' then
    return chat.find_chat_window()
  end
  if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
    return state.chat_winid
  end
  return nil
end

local function is_input_anchored_below_chat(chat_winid, input_winid)
  if not (chat_winid and input_winid) then
    return false
  end
  if not (vim.api.nvim_win_is_valid(chat_winid) and vim.api.nvim_win_is_valid(input_winid)) then
    return false
  end
  if vim.api.nvim_win_get_tabpage(chat_winid) ~= vim.api.nvim_win_get_tabpage(input_winid) then
    return false
  end

  local chat_pos = vim.api.nvim_win_get_position(chat_winid)
  local input_pos = vim.api.nvim_win_get_position(input_winid)
  local same_col = chat_pos[2] == input_pos[2]
  local same_width = vim.api.nvim_win_get_width(chat_winid) == vim.api.nvim_win_get_width(input_winid)
  local below_chat = input_pos[1] > chat_pos[1]

  return same_col and same_width and below_chat
end

local function get_existing_input_text()
  if not (state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr)) then
    return ''
  end

  local lines = vim.api.nvim_buf_get_lines(state.input_bufnr, 0, -1, false)
  local prompt = vim.fn.prompt_getprompt(state.input_bufnr)
  local text = table.concat(lines, '\n')
  if prompt ~= '' and vim.startswith(text, prompt) then
    text = text:sub(#prompt + 1)
  end
  return text
end

local function close_existing_input_window(opts)
  opts = opts or {}
  if not opts.preserve_contents and state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr) then
    vim.api.nvim_buf_set_lines(state.input_bufnr, 0, -1, false, {})
    state.prompt_history_index = nil
    state.prompt_history_draft = ''
  end
  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_win_close(state.input_winid, true)
    state.input_winid = nil
  end
  local chat_winid = resolve_chat_window()
  if not opts.skip_focus and chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
    vim.api.nvim_set_current_win(chat_winid)
  end
end

local function cancel_existing_input_window()
  local text = vim.trim(get_existing_input_text())
  if text == '' then
    close_existing_input_window()
    return
  end

  vim.ui.select({ 'Keep editing', 'Close input' }, { prompt = 'Discard unsent chat input?' }, function(choice)
    if choice == 'Close input' then
      close_existing_input_window()
      return
    end

    vim.schedule(function()
      if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
        vim.api.nvim_set_current_win(state.input_winid)
        vim.cmd('startinsert!')
      end
    end)
  end)
end

local _mode_permission = {
  ask = 'interactive',
  plan = 'interactive',
  agent = 'approve-reads',
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
    -- In a prompt buffer the prompt prefix is stored as part of the first line's
    -- content (get_input_text strips it back out). Re-prepend it here so the
    -- history text appears after "agent❯ " rather than before it.
    local prefix = vim.fn.prompt_getprompt(bufnr)
    local lines = split_lines((prefix or '') .. (text or ''))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
      vim.api.nvim_win_set_cursor(state.input_winid, { #lines, #lines[#lines] })
    end
    vim.cmd('startinsert!')
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
      if require('copilot_agent.slash').execute(text, { attachments = attachments }) then
        return
      end
      state.pending_attachments = {}
      state.chat_busy = true
      refresh_statuslines()
      require('copilot_agent').ask(text, { attachments = attachments })
    end
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
  vim.keymap.set('n', 'q', cancel_existing_input_window, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
  vim.keymap.set('n', '<Esc>', cancel_existing_input_window, { buffer = bufnr, silent = true, desc = 'Cancel prompt' })
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
    -- Respect manual overrides: if the user explicitly set permission via <M-a>,
    -- don't auto-reset it on mode change.
    local had_manual = state.permission_mode_manual
    state.permission_mode_manual = false
    local natural_perm = _mode_permission[new_mode]
    if natural_perm and not had_manual and natural_perm ~= state.permission_mode then
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

  vim.bo[bufnr].omnifunc = ''
  vim.api.nvim_buf_set_option(bufnr, 'completefunc', "v:lua.require'copilot_agent'.input_omnifunc")

  -- Store omnifunc on the module so v:lua can reach it.
  require('copilot_agent').input_omnifunc = input_omnifunc
  M._input_omnifunc = input_omnifunc

  -- Trigger completion using vim.fn.complete() which works reliably in prompt buffers.
  local function trigger_completion()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local command_context = command_completion_context(before)

    local start_col, items
    if command_context then
      start_col = command_context.start
      items = input_omnifunc(0, line:sub(start_col, col))
    else
      local pos = before:find('[@/][^%s]*$')
      if pos then
        start_col = pos
        items = input_omnifunc(0, before:sub(pos))
      end
    end

    if items and #items > 0 then
      vim.fn.complete(start_col, items)
    end
  end

  local last_auto_completion_key
  local auto_completion_scheduled = false

  local function auto_completion_key(before)
    local pos = before:find('[@/]$')
    if pos then
      local trigger = before:sub(pos, pos)
      local prev_char = pos == 1 and '' or before:sub(pos - 1, pos - 1)
      if trigger == '@' or pos == 1 or prev_char:match('%s') then
        return trigger .. ':' .. pos
      end
    end

    local command_context = command_completion_context(before)
    if command_context and command_context.at_token_end then
      return command_context.kind .. ':' .. command_context.start
    end

    return nil
  end

  local function maybe_auto_trigger_completion()
    local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
    local key = auto_completion_key(before)
    if not key then
      last_auto_completion_key = nil
      return
    end
    if key == last_auto_completion_key or auto_completion_scheduled then
      return
    end

    last_auto_completion_key = key
    auto_completion_scheduled = true
    vim.schedule(function()
      auto_completion_scheduled = false
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local mode = vim.fn.mode()
      if mode:sub(1, 1) ~= 'i' then
        return
      end
      trigger_completion()
    end)
  end

  vim.keymap.set('i', '<Tab>', trigger_completion, { buffer = bufnr, silent = true, desc = 'Trigger completion' })

  -- Auto-trigger completion once when a slash/file token becomes completable.
  -- CompleteChanged is needed because, once the generic "/" popup is open,
  -- subsequent typing is driven by Neovim's completion state rather than
  -- TextChangedI alone.
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'CompleteChanged' }, {
    buffer = bufnr,
    callback = function()
      maybe_auto_trigger_completion()
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

  local chat_winid = resolve_chat_window()
  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    if chat_winid and not is_input_anchored_below_chat(chat_winid, state.input_winid) then
      M._close_input_window({ preserve_contents = true, skip_focus = true })
    else
      vim.api.nvim_set_current_win(state.input_winid)
      vim.cmd('startinsert')
      refresh_separator()
      apply_prefill()
      return
    end
  end

  if not chat_winid then
    chat_winid = 0
  end

  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_set_current_win(state.input_winid)
    vim.cmd('startinsert')
    refresh_separator()
    apply_prefill()
    return
  end

  if not state.input_bufnr or not vim.api.nvim_buf_is_valid(state.input_bufnr) then
    state.input_bufnr = create_input_buffer()
  end

  -- Open a small horizontal split below the active chat window via the API.
  local parent_win = chat_winid
  state.input_winid = vim.api.nvim_open_win(state.input_bufnr, true, {
    split = 'below',
    win = parent_win,
    height = 5,
  })
  win.protect_markdown_buffer(state.input_bufnr, state.input_winid)

  local wo = vim.wo[state.input_winid]
  wo.winfixheight = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  -- Statusline is populated by refresh_input_statusline below.
  refresh_statuslines()
  refresh_separator()

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

M._close_input_window = close_existing_input_window
M._cancel_input = cancel_existing_input_window
M._resolve_chat_window = resolve_chat_window
M._is_input_anchored_below_chat = is_input_anchored_below_chat
M._input_omnifunc = input_omnifunc
M.refresh_separator = refresh_separator
M._discovered_agent_names = discovered_agent_names
M._discovered_skill_names = discovered_skill_names
M._discovered_instruction_names = discovered_instruction_names
M._discovered_mcp_names = discovered_mcp_names
M._discovered_model_ids = discovered_model_ids
M._discovered_session_items = discovered_session_items

return M
