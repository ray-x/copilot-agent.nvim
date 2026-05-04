-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')
local win = require('copilot_agent.window')

local state = cfg.state
local notify = cfg.notify

local request = http.request

local working_directory = service.working_directory
local cwd = service.cwd

local refresh_statuslines = sl.refresh_statuslines
local refresh_chat_statusline = sl.refresh_chat_statusline

local render_chat = render.render_chat
local reset_frozen_render = render.reset_frozen_render
local scroll_to_bottom = render.scroll_to_bottom
local follow_active_conversation = render.follow_active_conversation
local append_entry = render.append_entry
local schedule_render = render.schedule_render
local refresh_reasoning_overlay = render.refresh_reasoning_overlay

local M = {}

local function attach_chat_markdown(winid)
  win.disable_folds(winid)
  win.set_window_syntax(winid, 'markdown')
  if vim.wo[winid].conceallevel == 0 then
    vim.wo[winid].conceallevel = 2
  end
  state.chat_default_conceallevel = vim.wo[winid].conceallevel
  win.sync_chat_markdown_conceal(winid)
end

local function help_lines()
  return {
    ' Copilot Agent – Help ',
    string.rep('─', 58),
    '',
    '  Send / Open input',
    '    <CR> / i / a    Open input buffer (output pane)',
    '    <C-s>           Send message / open input',
    '',
    '  Mode  (<C-t> to cycle; auto-sets permission)',
    '    💬 ask           Single-turn Q&A            → 🔐 interactive',
    '    📋 plan          Structured plan             → 🔐 interactive',
    '    🤖 agent         Agentic loop                → 📂 approve-reads',
    '    🚀 autopilot     Agentic loop, fully auto    → ✅ approve-all',
    '',
    '  Model / permissions',
    '    <M-m>           Open model picker',
    '    <M-a>           Cycle permission mode',
    '    <C-x>           Toggle session tools',
    '',
    '  Session commands',
    '    :CopilotAgentNewSession     Fresh session in current dir',
    '    :CopilotAgentSwitchSession  Switch sessions (newest first)',
    '    :CopilotAgentDeleteSession  Delete picked session by exact ID',
    '    :CopilotAgentStop!          Delete active session; checkpoints kept 7 days',
    '    Transcript separators show the completed-turn Checkpoint ID (v001...)',
    '',
    '  Attachments / completion',
    '    <C-a>           Open attachment picker',
    '    <M-v>           Paste image from clipboard',
    '    <Tab>           Trigger completion',
    '    @<path>         Attach a file',
    '    /<cmd>          Run a built-in slash command',
    '    Type / + <Tab>  Browse command completion',
    '    Examples        /model  /new  /resume  /diff  /share',
    '',
    '  Review / recovery',
    '    :CopilotAgentDiff      Review git changes vs HEAD',
    '    /search <text>         Find transcript matches',
    '    /undo, /rewind [vNNN]  Restore from session checkpoints',
    '    Diff float: q / <Esc><Esc> / <C-c> close',
    '',
    '  Output pane',
    '    q               Close chat window',
    '    <C-c>           Cancel current turn',
    '    zA              Toggle Activity details',
    '    gA              Open Activity details float',
    '    [[ / ]]         Jump to prev/next conversation',
    '    [a / ]a         Jump to prev/next Assistant/Activity',
    '    R               Refresh/re-render',
    '    ?               This help',
    '',
    '  Press any key to close',
  }
end

function M.find_chat_window()
  if not (state.chat_bufnr and vim.api.nvim_buf_is_valid(state.chat_bufnr)) then
    state.chat_winid = nil
    return nil
  end

  if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
    if vim.api.nvim_win_get_buf(state.chat_winid) == state.chat_bufnr then
      return state.chat_winid
    end
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, winid in ipairs(vim.fn.win_findbuf(state.chat_bufnr)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_tabpage(winid) == current_tab then
      state.chat_winid = winid
      return winid
    end
  end

  for _, winid in ipairs(vim.fn.win_findbuf(state.chat_bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      state.chat_winid = winid
      return winid
    end
  end

  state.chat_winid = nil
  return nil
end

local input_modes = { 'ask', 'plan', 'agent', 'autopilot' }
local _perm_cycle = { 'interactive', 'approve-reads', 'approve-all', 'autopilot' }

-- Natural permission mode for each input mode, mirroring VS Code behaviour:
--   ask/plan  → interactive   (tools need explicit approval)
--   agent     → approve-reads (workspace reads auto-approved; writes/shell prompt)
--   autopilot → approve-all   (fully autonomous, no prompts)
local _mode_permission = {
  ask = 'interactive',
  plan = 'interactive',
  agent = 'approve-reads',
  autopilot = 'approve-all',
}

-- Open a fuzzy-finder to pick one or more files/directories.
-- opts.prompt  string  prompt title
-- opts.type    'file' | 'dir'   what to pick (default 'file')
-- opts.cwd     string  root directory for the picker
-- callback(paths)  receives a list of absolute path strings
--
-- Detection order (respects state.config.chat.file_picker):
--   snacks → telescope → fzf-lua → mini.pick → vim.ui.input fallback
function M.pick_path(opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or 'Select'
  local pick_type = opts.type or 'file'
  local root = opts.cwd or working_directory() or cwd()
  local picker_cfg = state.config.chat.file_picker or 'auto'

  -- Normalize paths from a picker: make absolute, strip trailing newline.
  local function abs(p)
    if not p or p == '' then
      return nil
    end
    p = p:gsub('\n$', '')
    if vim.fn.isabsolutepath(p) == 0 then
      p = root .. '/' .. p
    end
    return vim.fn.fnamemodify(p, ':p')
  end

  -- Helper: fires callback with a single list of valid paths.
  local function done(raw_paths)
    local out = {}
    for _, p in ipairs(raw_paths or {}) do
      local a = abs(p)
      if a and a ~= '' then
        out[#out + 1] = a
      end
    end
    if #out > 0 then
      callback(out)
    end
  end

  -- ── snacks.picker ────────────────────────────────────────────────────────
  local function try_snacks()
    local ok, snacks = pcall(require, 'snacks')
    if not ok or not snacks.picker then
      return false
    end
    local picker_fn = pick_type == 'dir' and snacks.picker.directories or snacks.picker.files
    if not picker_fn then
      return false
    end
    picker_fn({
      title = prompt,
      cwd = root,
      confirm = function(picker, item)
        picker:close()
        if item then
          done({ item.file or item.path or tostring(item) })
        end
      end,
    })
    return true
  end

  -- ── telescope ────────────────────────────────────────────────────────────
  local function try_telescope()
    local ok_tb, tb = pcall(require, 'telescope.builtin')
    local ok_a, actions = pcall(require, 'telescope.actions')
    local ok_s, action_state = pcall(require, 'telescope.actions.state')
    if not (ok_tb and ok_a and ok_s) then
      return false
    end
    local picker_fn
    if pick_type == 'dir' then
      -- Try file_browser extension for directory picking.
      local ok_fb, ext = pcall(function()
        return require('telescope').extensions.file_browser
      end)
      if ok_fb and ext and ext.file_browser then
        picker_fn = function(popts)
          ext.file_browser(popts)
        end
      end
    end
    if not picker_fn then
      picker_fn = tb.find_files
    end
    picker_fn({
      prompt_title = prompt,
      cwd = root,
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local picker_obj = action_state.get_current_picker(prompt_bufnr)
          local multi = picker_obj:get_multi_selection()
          actions.close(prompt_bufnr)
          local raw = {}
          if #multi > 0 then
            for _, entry in ipairs(multi) do
              raw[#raw + 1] = entry[1] or entry.path or entry.filename or ''
            end
          else
            local sel = action_state.get_selected_entry()
            if sel then
              raw[1] = sel[1] or sel.path or sel.filename or ''
            end
          end
          done(raw)
        end)
        return true
      end,
    })
    return true
  end

  -- ── fzf-lua ───────────────────────────────────────────────────────────────
  local function try_fzf()
    local ok, fzf = pcall(require, 'fzf-lua')
    if not ok then
      return false
    end
    local picker_fn
    if pick_type == 'dir' then
      -- fzf-lua doesn't have a built-in dir picker; use fzf_exec with fd/find.
      local fd = vim.fn.executable('fd') == 1 and 'fd --type d --color never' or 'find . -type d -not -path "*/\\.*"'
      picker_fn = function(popts)
        fzf.fzf_exec(
          fd,
          vim.tbl_extend('force', popts, {
            prompt = prompt .. '> ',
            cwd = root,
            actions = {
              ['default'] = function(selected)
                done(selected or {})
              end,
            },
          })
        )
      end
    else
      picker_fn = fzf.files
    end
    picker_fn({
      prompt = prompt .. '> ',
      cwd = root,
      actions = {
        ['default'] = function(selected)
          done(selected or {})
        end,
      },
    })
    return true
  end

  -- ── mini.pick ─────────────────────────────────────────────────────────────
  local function try_mini()
    local ok, mp = pcall(require, 'mini.pick')
    if not ok then
      return false
    end
    -- mini.pick doesn't have a directory picker; only offer for files.
    if pick_type == 'dir' then
      return false
    end
    mp.builtin.files(nil, {
      source = {
        cwd = root,
        name = prompt,
        choose = function(item)
          done({ item })
        end,
        choose_marked = function(items)
          done(items)
        end,
      },
    })
    return true
  end

  -- ── vim.ui.input fallback ─────────────────────────────────────────────────
  local function use_native()
    local completion = pick_type == 'dir' and 'dir' or 'file'
    vim.ui.input({ prompt = prompt .. ': ', completion = completion }, function(path)
      if path and path ~= '' then
        done({ path })
      end
    end)
  end

  if picker_cfg == 'native' then
    use_native()
    return
  end

  -- Auto-detect: try each picker in preference order.
  if picker_cfg == 'snacks' or picker_cfg == 'auto' then
    if try_snacks() then
      return
    end
  end
  if picker_cfg == 'telescope' or picker_cfg == 'auto' then
    if try_telescope() then
      return
    end
  end
  if picker_cfg == 'fzf-lua' or picker_cfg == 'auto' then
    if try_fzf() then
      return
    end
  end
  if picker_cfg == 'mini.pick' or picker_cfg == 'auto' then
    if try_mini() then
      return
    end
  end
  use_native()
end

-- Open the chat window. Respects chat.fullscreen and chat.buf_name config.
local function open_chat_win(bufnr, opts)
  local fullscreen = (opts and opts.fullscreen) or (state.config.chat and state.config.chat.fullscreen)
  if opts and opts.replace_current then
    vim.api.nvim_win_set_buf(0, bufnr)
    state.chat_winid = vim.api.nvim_get_current_win()
  elseif fullscreen then
    -- Full-screen: open in a new tab.
    vim.cmd('tabnew')
    vim.api.nvim_win_set_buf(0, bufnr)
    state.chat_winid = vim.api.nvim_get_current_win()
  else
    local parent_win = win.resolve_split_target()
    if not parent_win then
      error('No non-floating window available for chat split')
    end
    state.chat_winid = vim.api.nvim_open_win(bufnr, true, {
      split = 'right',
      win = parent_win,
    })
  end
  attach_chat_markdown(state.chat_winid)
end

function M.ensure_chat_window(opts)
  local buf_name = (state.config.chat and state.config.chat.buf_name) or 'CopilotAgentChat'

  if state.chat_bufnr and vim.api.nvim_buf_is_valid(state.chat_bufnr) then
    local chat_winid = M.find_chat_window()
    if chat_winid then
      state.chat_winid = chat_winid
      attach_chat_markdown(chat_winid)
      vim.api.nvim_set_current_win(chat_winid)
      state._chat_was_open = true
      return state.chat_bufnr
    end
    -- Buffer exists but window was closed — reopen it.
    open_chat_win(state.chat_bufnr, opts)
    reset_frozen_render()
    render_chat()
    refresh_chat_statusline()
    if not follow_active_conversation(false) then
      scroll_to_bottom()
    end
    state._chat_was_open = true
    return state.chat_bufnr
  end

  -- Create the chat buffer; set options once here, not on every render.
  state.chat_bufnr = vim.api.nvim_create_buf(false, true)
  local bufnr = state.chat_bufnr
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.api.nvim_buf_set_name(bufnr, buf_name)

  open_chat_win(bufnr, opts)
  refresh_chat_statusline()

  -- Tell render-markdown.nvim (and similar) to enable on this buffer.
  -- It defaults to skipping nofile buffers, so we explicitly enable it.
  -- Skipped when chat.render_markdown = false.
  if state.config.chat and state.config.chat.render_markdown ~= false then
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if vim.b[bufnr].copilot_agent_treesitter_disabled then
        return
      end
      local ok, rm = pcall(require, 'render-markdown')
      if ok and rm.enable then
        pcall(rm.enable, { buf = bufnr })
      end
    end)
  end

  vim.keymap.set('n', 'q', function()
    M.close_chat_window()
  end, { buffer = bufnr, silent = true, desc = 'Close Copilot chat window' })

  vim.keymap.set('n', '<C-c>', function()
    require('copilot_agent').cancel()
  end, { buffer = bufnr, silent = true, desc = 'Cancel the current Copilot turn' })

  vim.keymap.set('n', 'R', function()
    reset_frozen_render()
    render_chat()
  end, { buffer = bufnr, silent = true })

  vim.keymap.set('n', 'zA', function()
    render.toggle_activity_entries()
  end, { buffer = bufnr, silent = true, desc = 'Toggle Activity transcript details' })

  vim.keymap.set('n', 'gA', function()
    render.show_activity_details_under_cursor()
  end, { buffer = bufnr, silent = true, desc = 'Open Activity details float' })

  vim.keymap.set('n', '[[', function()
    render.jump_conversation(-1)
  end, { buffer = bufnr, silent = true, desc = 'Jump to previous conversation' })

  vim.keymap.set('n', ']]', function()
    render.jump_conversation(1)
  end, { buffer = bufnr, silent = true, desc = 'Jump to next conversation' })

  vim.keymap.set('n', '[a', function()
    render.jump_assistant_activity(-1)
  end, { buffer = bufnr, silent = true, desc = 'Jump to previous Assistant/Activity' })

  vim.keymap.set('n', ']a', function()
    render.jump_assistant_activity(1)
  end, { buffer = bufnr, silent = true, desc = 'Jump to next Assistant/Activity' })

  for _, lhs in ipairs({ 'i', 'I', 'a', 'A', 'o', 'O', '<CR>' }) do
    vim.keymap.set('n', lhs, function()
      require('copilot_agent').ask()
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = 'Prompt for a Copilot Go message',
    })
  end

  -- Shared action keymaps: mode, model, attachments, tools, permission, history, help.
  M.setup_action_keymaps(bufnr)

  reset_frozen_render()
  render_chat()
  if not follow_active_conversation(false) then
    scroll_to_bottom()
  end
  state._chat_was_open = true
  return bufnr
end

-- Close the chat (and input) window without deleting the buffer.
function M.close_chat_window()
  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_win_close(state.input_winid, true)
  end
  if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
    vim.api.nvim_win_close(state.chat_winid, true)
  end
  state._chat_was_open = false
end

-- Toggle the chat window: close if visible, reopen if hidden.
function M.toggle_chat()
  if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
    M.close_chat_window()
  else
    M.ensure_chat_window()
  end
end

-- Focus picker: list all chat buffers and jump to the selected one.
function M.focus_chat()
  local buf_name = (state.config.chat and state.config.chat.buf_name) or 'CopilotAgentChat'
  -- Collect all matching buffers (handles multiple instances if ever created).
  local candidates = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local name = vim.api.nvim_buf_get_name(b)
      -- Match exact name or the configured pattern.
      if name == buf_name or name:find(vim.pesc(buf_name), 1, true) then
        local wins = vim.fn.win_findbuf(b)
        local status = #wins > 0 and '(open)' or '(hidden)'
        table.insert(candidates, { bufnr = b, label = name .. '  ' .. status })
      end
    end
  end

  if #candidates == 0 then
    -- No existing chat buffer — open a fresh one.
    M.ensure_chat_window()
    return
  end

  if #candidates == 1 then
    -- Single buffer: jump straight to it.
    local c = candidates[1]
    local wins = vim.fn.win_findbuf(c.bufnr)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
    else
      state.chat_bufnr = c.bufnr
      open_chat_win(c.bufnr)
      reset_frozen_render()
      render_chat()
      refresh_chat_statusline()
      if not follow_active_conversation(false) then
        scroll_to_bottom()
      end
    end
    return
  end

  -- Multiple buffers: show a picker.
  local display = vim.tbl_map(function(c)
    return c.label
  end, candidates)
  vim.ui.select(display, { prompt = 'Switch to chat buffer' }, function(_, idx)
    if not idx then
      return
    end
    local chosen = candidates[idx]
    local wins = vim.fn.win_findbuf(chosen.bufnr)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
    else
      state.chat_bufnr = chosen.bufnr
      open_chat_win(chosen.bufnr)
      reset_frozen_render()
      render_chat()
      refresh_chat_statusline()
      if not follow_active_conversation(false) then
        scroll_to_bottom()
      end
    end
  end)
end

-- Notify the server of the new agent mode so the SDK switches behaviour.
function M.set_agent_mode(mode)
  if not state.session_id then
    return
  end
  request('POST', string.format('/sessions/%s/mode', state.session_id), { mode = mode }, function(_, err)
    if err then
      notify('Failed to set agent mode: ' .. err, vim.log.levels.WARN)
    end
  end)
end

-- Keymaps shared by both the chat output buffer and the input buffer.
-- The input buffer overrides <C-s> (submit) and <C-t> (also refreshes prompt).
function M.setup_action_keymaps(bufnr)
  -- Open input window (chat: always open; input: overridden to submit).
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    require('copilot_agent').ask()
  end, { buffer = bufnr, silent = true, desc = 'Open input / send message' })

  -- History navigation: load entry into input buffer prefill then open it.
  for _, map in ipairs({
    { '<C-p>', -1 },
    { '<M-p>', -1 },
    { '<C-n>', 1 },
    { '<M-n>', 1 },
  }) do
    local lhs, dir = map[1], map[2]
    vim.keymap.set({ 'n', 'i' }, lhs, function()
      if #state.prompt_history == 0 then
        return
      end
      local draft_index = #state.prompt_history + 1
      if state.prompt_history_index == nil then
        state.prompt_history_index = draft_index
      end
      local next_index = math.max(1, math.min(draft_index, state.prompt_history_index + dir))
      state.prompt_history_index = next_index
      if next_index == draft_index then
        state.prompt_prefill = state.prompt_history_draft
      else
        state.prompt_prefill = state.prompt_history[next_index]
      end
      require('copilot_agent').ask()
    end, { buffer = bufnr, silent = true, desc = dir < 0 and 'Previous prompt' or 'Next prompt' })
  end

  -- Cycle input mode (ask / plan / agent / autopilot) and apply its natural permission mode.
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
    M.set_agent_mode(new_mode)

    -- Switching to a new mode clears any manual permission override, then
    -- applies the natural permission for the new mode.
    local had_manual = state.permission_mode_manual
    state.permission_mode_manual = false
    local natural_perm = _mode_permission[new_mode]
    if natural_perm and not had_manual and natural_perm ~= state.permission_mode then
      state.permission_mode = natural_perm
      if state.session_id then
        request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = natural_perm }, function(_, err)
          if err then
            notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
          end
        end)
      end
    end

    refresh_statuslines()
    notify('Mode: ' .. new_mode, vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true, desc = 'Cycle Copilot input mode (ask/plan/agent/autopilot)' })

  -- Quick model switch.
  vim.keymap.set({ 'n', 'i' }, '<M-m>', function()
    require('copilot_agent').select_model()
  end, { buffer = bufnr, silent = true, desc = 'Switch Copilot model' })

  -- Paste image from clipboard.
  vim.keymap.set({ 'n', 'i' }, '<M-v>', function()
    require('copilot_agent').paste_clipboard_image()
  end, { buffer = bufnr, silent = true, desc = 'Paste image from clipboard as attachment' })

  -- Cycle permission mode.
  vim.keymap.set({ 'n', 'i' }, '<M-a>', function()
    local current = state.permission_mode or 'interactive'
    local next_mode = 'interactive'
    for i, m in ipairs(_perm_cycle) do
      if m == current then
        next_mode = _perm_cycle[(i % #_perm_cycle) + 1]
        break
      end
    end
    state.permission_mode = next_mode
    state.permission_mode_manual = true -- user explicitly chose; <C-t> won't auto-reset this
    if state.session_id then
      request('POST', '/sessions/' .. state.session_id .. '/permission-mode', { mode = next_mode }, function(_, err)
        if err then
          notify('Failed to set permission mode: ' .. tostring(err), vim.log.levels.WARN)
        end
      end)
    end
    refresh_statuslines()
    notify('Permission mode: ' .. next_mode, vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true, desc = 'Cycle permission mode' })

  -- Resource / attachment picker.
  vim.keymap.set({ 'n', 'i' }, '<C-a>', function()
    local choices = {
      'Current buffer',
      'Visual selection',
      'File',
      'Folder',
      'Instructions file',
      'Image file',
      'Paste image from clipboard',
    }
    vim.ui.select(choices, { prompt = 'Add resource' }, function(choice)
      if not choice then
        return
      end

      local function add_attachment(att)
        table.insert(state.pending_attachments, att)
        refresh_statuslines()
        vim.schedule(function()
          if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
            vim.api.nvim_set_current_win(state.input_winid)
            vim.cmd('startinsert!')
          elseif state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
            vim.api.nvim_set_current_win(state.chat_winid)
          end
        end)
      end

      if choice == 'Current buffer' then
        local path = vim.api.nvim_buf_get_name(vim.fn.bufnr('#') ~= -1 and vim.fn.bufnr('#') or 0)
        if path ~= '' then
          add_attachment({ type = 'file', path = path, display = vim.fn.fnamemodify(path, ':t') })
        end
      elseif choice == 'Visual selection' then
        local sel_buf = vim.fn.bufnr('#') ~= -1 and vim.fn.bufnr('#') or 0
        local start_line = vim.fn.line("'<", vim.fn.win_getid()) - 1
        local end_line = vim.fn.line("'>", vim.fn.win_getid()) - 1
        local lines = vim.api.nvim_buf_get_lines(sel_buf, start_line, end_line + 1, false)
        local text = table.concat(lines, '\n')
        local filepath = vim.api.nvim_buf_get_name(sel_buf)
        if text ~= '' then
          add_attachment({
            type = 'selection',
            path = filepath,
            text = text,
            start_line = start_line,
            end_line = end_line,
            display = 'selection:' .. vim.fn.fnamemodify(filepath, ':t') .. ':' .. (start_line + 1) .. '-' .. (end_line + 1),
          })
        end
      elseif choice == 'File' then
        M.pick_path({ prompt = 'Attach file', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'file', path = p, display = vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Folder' then
        M.pick_path({ prompt = 'Attach folder', type = 'dir' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({
              type = 'directory',
              path = p,
              display = vim.fn.fnamemodify(p:gsub('/$', ''), ':t') .. '/',
            })
          end
        end)
      elseif choice == 'Instructions file' then
        M.pick_path({ prompt = 'Instructions file', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'file', path = p, display = '📋' .. vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Image file' then
        M.pick_path({ prompt = 'Attach image', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'image', path = p, display = '🖼️ ' .. vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Paste image from clipboard' then
        require('copilot_agent').paste_clipboard_image()
      end

      if choice == 'Current buffer' or choice == 'Visual selection' then
        if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
          vim.api.nvim_set_current_win(state.input_winid)
          vim.cmd('startinsert!')
        end
      end
    end)
  end, { buffer = bufnr, silent = true, desc = 'Add resource/attachment' })

  -- Tool config: show available tools, toggle excluded.
  vim.keymap.set({ 'n', 'i' }, '<C-x>', function()
    if not state.session_id then
      notify('No active session', vim.log.levels.WARN)
      return
    end
    request('GET', '/sessions/' .. state.session_id, nil, function(sess_data, err)
      if err or not sess_data then
        notify('Failed to fetch session: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local caps = sess_data.capabilities or {}
      local tools = caps.availableTools or {}
      local excluded = sess_data.excludedTools or {}
      local excluded_set = {}
      for _, t in ipairs(excluded) do
        excluded_set[t] = true
      end
      if #tools == 0 then
        notify('No tools available in this session', vim.log.levels.INFO)
        return
      end
      local items = {}
      for _, t in ipairs(tools) do
        table.insert(items, { name = t, excluded = excluded_set[t] == true })
      end
      vim.ui.select(items, {
        prompt = 'Toggle tool (currently marked = excluded)',
        format_item = function(item)
          return (item.excluded and '✗ ' or '✓ ') .. item.name
        end,
      }, function(choice)
        if not choice then
          return
        end
        if choice.excluded then
          excluded_set[choice.name] = nil
        else
          excluded_set[choice.name] = true
        end
        local new_excluded = vim.tbl_keys(excluded_set)
        request('POST', '/sessions/' .. state.session_id .. '/tools', { excludedTools = new_excluded }, function(_, req_err)
          if req_err then
            notify('Failed to update tools: ' .. req_err, vim.log.levels.WARN)
          else
            notify('Tools updated', vim.log.levels.INFO)
          end
        end)
      end)
    end)
  end, { buffer = bufnr, silent = true, desc = 'Configure session tools' })

  -- Help popup (? in normal mode).
  vim.keymap.set('n', '?', function()
    local lines = help_lines()
    local max_w = 0
    for _, l in ipairs(lines) do
      max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
    end
    local win_h = #lines
    local win_w = max_w + 2
    local row = math.max(0, (vim.o.lines - win_h) / 2)
    local col = math.max(0, (vim.o.columns - win_w) / 2)
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
    vim.bo[help_buf].modifiable = false
    local help_win = vim.api.nvim_open_win(help_buf, true, {
      relative = 'editor',
      row = row,
      col = col,
      width = win_w,
      height = win_h,
      style = 'minimal',
      border = 'rounded',
      title = ' Help ',
      title_pos = 'center',
    })
    win.disable_folds(help_win)
    vim.wo[help_win].cursorline = false
    for _, key in ipairs({ '<Space>', '<CR>', '<Esc>', 'q', '?' }) do
      vim.keymap.set('n', key, function()
        vim.api.nvim_win_close(help_win, true)
      end, { buffer = help_buf, silent = true, nowait = true })
    end
  end, { buffer = bufnr, silent = true, desc = 'Show keybinding help' })
end

--- Send a prompt to the active session, with optional attachments.
--- If prompt is empty, opens the input buffer instead.
function M.ask(prompt, opts)
  opts = opts or {}
  local text = prompt
  if text == nil or text == '' then
    require('copilot_agent').open_chat({ replace_current = opts.replace_current })
    require('copilot_agent.input').open_input_window()
    return
  end

  -- Build attachment list for the API.
  local api_attachments = {}
  local temp_files = {} -- clipboard image temp files to delete after send
  for _, a in ipairs(opts.attachments or {}) do
    if a.type == 'file' or a.type == 'directory' or a.type == 'image' then
      table.insert(api_attachments, { type = 'file', path = a.path })
      if a.temp then
        temp_files[#temp_files + 1] = a.path
      end
    elseif a.type == 'selection' then
      table.insert(api_attachments, {
        type = 'selection',
        filePath = a.path,
        text = a.text,
        lineRange = a.start_line and { start = a.start_line, ['end'] = a.end_line } or nil,
      })
    end
  end

  require('copilot_agent').open_chat({
    activate_input_on_session_ready = false,
    replace_current = opts.replace_current,
  })

  local with_session = require('copilot_agent.session').with_session
  with_session(function(session_id, err)
    if err then
      state.chat_busy = false
      refresh_statuslines()
      append_entry('error', err)
      return
    end

    local function dispatch_prompt()
      require('copilot_agent').open_chat({
        activate_input_on_session_ready = false,
        replace_current = opts.replace_current,
      })
      local entry_index = append_entry('user', text, opts.attachments and #opts.attachments > 0 and vim.deepcopy(opts.attachments) or nil)
      state.pending_checkpoint_turn = {
        session_id = session_id,
        prompt = text,
        entry_index = entry_index,
      }
      -- Mark busy immediately so the spinner shows before the first delta arrives.
      state.chat_busy = true
      refresh_statuslines()
      schedule_render()

      local body = { prompt = text }
      if #api_attachments > 0 then
        body.attachments = api_attachments
      end
      request('POST', string.format('/sessions/%s/messages', session_id), body, function(_, request_err)
        -- Clean up any clipboard temp PNGs — the HTTP request has been delivered.
        for _, p in ipairs(temp_files) do
          pcall(os.remove, p)
        end
        if request_err then
          state.pending_checkpoint_turn = nil
          state.active_turn_assistant_index = nil
          state.live_assistant_entry_index = nil
          state.active_turn_assistant_message_id = nil
          state.active_assistant_merge_group = nil
          state.active_tool = nil
          state.active_tool_run_id = nil
          state.active_tool_detail = nil
          state.pending_tool_detail = nil
          state.overlay_tool_display = nil
          state.overlay_tool_queue = {}
          state.overlay_tool_schedule_token = (tonumber(state.overlay_tool_schedule_token) or 0) + 1
          state.recent_activity_lines = {}
          state.recent_activity_items = {}
          state.recent_activity_tool_calls = {}
          state.current_intent = nil
          state.chat_busy = false
          refresh_statuslines()
          refresh_reasoning_overlay(true)
          append_entry('error', 'Failed to send prompt: ' .. request_err)
        end
      end)
    end

    dispatch_prompt()
  end)
end

M._help_lines = help_lines

return M
