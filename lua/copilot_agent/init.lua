-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local uv = vim.uv or vim.loop
local utils = require('copilot_agent.utils')

local M = {}
local open_input_window
local setup_action_keymaps

-- Aliases from http module (used as locals throughout for backward compat).
local build_url = http.build_url
local ensure_curl = http.ensure_curl
local decode_json = http.decode_json
local encode_json = http.encode_json
local sync_request = http.sync_request
local raw_request = http.raw_request
local request = http.request

-- Aliases from service module.
local cwd = service.cwd
local working_directory = service.working_directory
local plugin_root = service.plugin_root
local service_cwd = service.service_cwd
local installed_binary_path = service.installed_binary_path
local service_command = service.service_command
local remember_service_output = service.remember_service_output
local last_service_output = service.last_service_output
local ensure_service_running = service.ensure_service_running

-- Aliases from statusline module.
local statusline_mode = sl.statusline_mode
local statusline_model = sl.statusline_model
local statusline_busy = sl.statusline_busy
local statusline_attachments = sl.statusline_attachments
local statusline_permission = sl.statusline_permission
local statusline_component = sl.statusline_component
local refresh_input_statusline = sl.refresh_input_statusline
local refresh_chat_statusline = sl.refresh_chat_statusline
local refresh_statuslines = sl.refresh_statuslines

-- Aliases from render module.
local stop_thinking_spinner = render.stop_thinking_spinner
local start_thinking_spinner = render.start_thinking_spinner
local notify_render_plugins = render.notify_render_plugins
local entry_lines = render.entry_lines
local chat_at_bottom = render.chat_at_bottom
local scroll_to_bottom = render.scroll_to_bottom
local apply_chat_highlights = render.apply_chat_highlights
local render_chat = render.render_chat
local schedule_render = render.schedule_render
local stream_update = render.stream_update
local append_entry = render.append_entry
local ensure_assistant_entry = render.ensure_assistant_entry
local clear_transcript = render.clear_transcript

local cfg = require('copilot_agent.config')
local defaults = cfg.defaults
local state = cfg.state
local SLASH_COMMANDS = cfg.SLASH_COMMANDS
local notify = cfg.notify
local notify_transient = cfg.notify_transient
local normalize_base_url = cfg.normalize_base_url

local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')
local events = require('copilot_agent.events')
local session = require('copilot_agent.session')
local mdl = require('copilot_agent.model')

-- Aliases from events module.
local stop_event_stream = events.stop_event_stream
local start_event_stream = events.start_event_stream
local show_user_input_picker = events.show_user_input_picker
local handle_user_input = events.handle_user_input
local handle_host_event = events.handle_host_event
local offer_diff_review = events.offer_diff_review
local handle_session_event = events.handle_session_event
local flush_sse_event = events.flush_sse_event
local consume_sse_line = events.consume_sse_line
local handle_sse_chunk = events.handle_sse_chunk

local is_thinking_content = utils.is_thinking_content
local split_lines = utils.split_lines

-- Aliases from session module.
local discard_pending_attachments = session.discard_pending_attachments
local disconnect_session = session.disconnect_session
local resume_session = session.resume_session
local with_session = session.with_session

-- Aliases from model module.
local store_model_cache = mdl.store_model_cache
local model_completion_items = mdl.model_completion_items
local apply_model = mdl.apply_model
local fetch_models = mdl.fetch_models

-- Open a fuzzy-finder to pick one or more files/directories.
-- opts.prompt  string  prompt title
-- opts.type    'file' | 'dir'   what to pick (default 'file')
-- opts.cwd     string  root directory for the picker
-- callback(paths)  receives a list of absolute path strings
--
-- Detection order (respects state.config.chat.file_picker):
--   snacks → telescope → fzf-lua → mini.pick → vim.ui.input fallback
local function pick_path(opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or 'Select'
  local pick_type = opts.type or 'file'
  local root = opts.cwd or working_directory() or cwd()
  local cfg = state.config.chat.file_picker or 'auto'

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

  if cfg == 'native' then
    use_native()
    return
  end

  -- Auto-detect: try each picker in preference order.
  if cfg == 'snacks' or cfg == 'auto' then
    if try_snacks() then
      return
    end
  end
  if cfg == 'telescope' or cfg == 'auto' then
    if try_telescope() then
      return
    end
  end
  if cfg == 'fzf-lua' or cfg == 'auto' then
    if try_fzf() then
      return
    end
  end
  if cfg == 'mini.pick' or cfg == 'auto' then
    if try_mini() then
      return
    end
  end
  use_native()
end

local function ensure_chat_window()
  if state.chat_bufnr and vim.api.nvim_buf_is_valid(state.chat_bufnr) then
    if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
      vim.api.nvim_set_current_win(state.chat_winid)
      return state.chat_bufnr
    end
    -- Buffer exists but window was closed/hidden — reopen with nvim_open_win
    -- directly so we always get the right window without an orphan buffer.
    state.chat_winid = vim.api.nvim_open_win(state.chat_bufnr, true, {
      split = 'right',
      win = 0,
    })
    render_chat()
    refresh_chat_statusline()
    scroll_to_bottom()
    return state.chat_bufnr
  end

  -- Create the chat buffer; set options once here, not on every render.
  state.chat_bufnr = vim.api.nvim_create_buf(false, true)
  local bufnr = state.chat_bufnr
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.api.nvim_buf_set_name(bufnr, 'copilot-agent-chat')

  -- Open a vertical split window via the API — no throwaway buffer created.
  state.chat_winid = vim.api.nvim_open_win(bufnr, true, {
    split = 'right',
    win = 0,
  })
  refresh_chat_statusline()

  -- Tell render-markdown.nvim (and similar) to enable on this buffer.
  -- It defaults to skipping nofile buffers, so we explicitly enable it.
  -- Skipped when chat.render_markdown = false.
  if state.config.chat and state.config.chat.render_markdown ~= false then
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local ok, rm = pcall(require, 'render-markdown')
      if ok and rm.enable then
        pcall(rm.enable, { buf = bufnr })
      end
    end)
  end

  vim.keymap.set('n', 'q', function()
    if state.chat_winid and vim.api.nvim_win_is_valid(state.chat_winid) then
      vim.api.nvim_win_close(state.chat_winid, true)
    end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set('n', 'R', function()
    render_chat()
  end, { buffer = bufnr, silent = true })

  for _, lhs in ipairs({ 'i', 'I', 'a', 'A', 'o', 'O', '<CR>' }) do
    vim.keymap.set('n', lhs, function()
      M.ask()
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = 'Prompt for a Copilot Go message',
    })
  end

  -- Shared action keymaps: mode, model, attachments, tools, permission, history, help.
  setup_action_keymaps(bufnr)

  render_chat()
  scroll_to_bottom()
  return bufnr
end

local input_modes = { 'ask', 'plan', 'agent' }
local _perm_cycle = { 'interactive', 'approve-all', 'autopilot' }

-- Notify the server of the new agent mode so the SDK switches behaviour.
local function set_agent_mode(mode)
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
setup_action_keymaps = function(bufnr)
  -- Open input window (chat: always open; input: overridden to submit).
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    M.ask()
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
      M.ask()
    end, { buffer = bufnr, silent = true, desc = dir < 0 and 'Previous prompt' or 'Next prompt' })
  end

  -- Cycle input mode (ask / plan / agent).
  vim.keymap.set({ 'n', 'i' }, '<C-t>', function()
    local idx = 1
    for i, m in ipairs(input_modes) do
      if m == state.input_mode then
        idx = i
        break
      end
    end
    state.input_mode = input_modes[(idx % #input_modes) + 1]
    set_agent_mode(state.input_mode)
    refresh_statuslines()
    notify('Mode: ' .. state.input_mode, vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true, desc = 'Cycle Copilot input mode (ask/plan/agent)' })

  -- Quick model switch.
  vim.keymap.set({ 'n', 'i' }, '<M-m>', function()
    M.select_model()
  end, { buffer = bufnr, silent = true, desc = 'Switch Copilot model' })

  -- Paste image from clipboard.
  vim.keymap.set({ 'n', 'i' }, '<M-v>', function()
    M.paste_clipboard_image()
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
        pick_path({ prompt = 'Attach file', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'file', path = p, display = vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Folder' then
        pick_path({ prompt = 'Attach folder', type = 'dir' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({
              type = 'directory',
              path = p,
              display = vim.fn.fnamemodify(p:gsub('/$', ''), ':t') .. '/',
            })
          end
        end)
      elseif choice == 'Instructions file' then
        pick_path({ prompt = 'Instructions file', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'file', path = p, display = '📋' .. vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Image file' then
        pick_path({ prompt = 'Attach image', type = 'file' }, function(paths)
          for _, p in ipairs(paths) do
            add_attachment({ type = 'image', path = p, display = '🖼️ ' .. vim.fn.fnamemodify(p, ':t') })
          end
        end)
      elseif choice == 'Paste image from clipboard' then
        M.paste_clipboard_image()
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
    local help_lines = {
      ' Copilot Agent – Keybindings ',
      string.rep('─', 44),
      '',
      '  Send / Open input',
      '    <CR> / i / a    Open input buffer (output pane)',
      '    <C-s>           Send message / open input',
      '',
      '  Mode  (<C-t> to cycle)',
      '    ask             Standard Q&A',
      '    plan            Create an implementation plan',
      '    agent           Autonomous agent mode',
      '',
      '  Model',
      '    <M-m>           Open model picker',
      '',
      '  Permission  (<M-a> to cycle)',
      '    🔐 interactive   Prompt for each tool use',
      '    ✅ approve-all   Auto-approve everything',
      '    🤖 autopilot     Approve + auto-answer inputs',
      '',
      '  Attachments  (<C-a> to open menu)',
      '    Current buffer, visual selection,',
      '    file, folder, instructions file,',
      '    image file',
      '    <M-v>           Paste image from clipboard',
      '',
      '  Tools',
      '    <C-x>           Toggle session tools',
      '',
      '  History  (input buffer)',
      '    <C-p> / <M-p>   Previous prompt',
      '    <C-n> / <M-n>   Next prompt',
      '',
      '  Completion  (input buffer)',
      '    <Tab>           Trigger completion',
      '    @<path>         Attach a file',
      '    /<cmd>          Slash command',
      '',
      '  Output pane',
      '    q               Close chat window',
      '    R               Refresh/re-render',
      '    ?               This help',
      '',
      '  Press any key to close',
    }
    local max_w = 0
    for _, l in ipairs(help_lines) do
      max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
    end
    local win_h = #help_lines
    local win_w = max_w + 2
    local row = math.max(0, (vim.o.lines - win_h) / 2)
    local col = math.max(0, (vim.o.columns - win_w) / 2)
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
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
    vim.wo[help_win].cursorline = false
    for _, key in ipairs({ '<Space>', '<CR>', '<Esc>', 'q', '?' }) do
      vim.keymap.set('n', key, function()
        vim.api.nvim_win_close(help_win, true)
      end, { buffer = help_buf, silent = true, nowait = true })
    end
  end, { buffer = bufnr, silent = true, desc = 'Show keybinding help' })
end

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
    return (state.input_mode or 'agent') .. '❯ '
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
    vim.fn.prompt_setprompt(bufnr, (state.input_mode or 'agent') .. '❯ ')
    vim.cmd('startinsert')
    if text ~= '' then
      local attachments = vim.deepcopy(state.pending_attachments)
      state.pending_attachments = {}
      state.chat_busy = true
      refresh_statuslines()
      M.ask(text, { attachments = attachments })
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
    state.input_mode = input_modes[(idx % #input_modes) + 1]
    set_agent_mode(state.input_mode)
    refresh_prompt()
    vim.cmd('startinsert!')
  end, { buffer = bufnr, silent = true, desc = 'Cycle Copilot input mode (ask/plan/agent)' })
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
  M.input_omnifunc = input_omnifunc

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

open_input_window = function()
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

-- Internal bridge for cross-module access to append_entry (used by service.lua).
M._append_entry = append_entry
-- Internal bridges for cross-module access from events.lua.
M._ensure_chat_window = ensure_chat_window
M._set_agent_mode = set_agent_mode
M._open_input_window = open_input_window

function M.setup(opts)
  state.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  state.config.base_url = normalize_base_url(state.config.base_url)
  -- Initialize runtime permission mode from config.
  state.permission_mode = state.config.permission_mode or 'interactive'

  -- Default highlight groups for the chat buffer (link targets can be overridden
  -- by the user's colorscheme or config before calling setup()).
  vim.api.nvim_set_hl(0, 'CopilotAgentUser', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentAssistant', { link = 'Function', default = true })
  vim.api.nvim_set_hl(0, 'CopilotAgentDone', { link = 'DiagnosticOk', default = true })
  -- Clean up clipboard temp files if Neovim exits before they were sent.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('CopilotAgentCleanup', { clear = true }),
    callback = function()
      discard_pending_attachments()
    end,
  })
  -- Eagerly start the Go service in the background so it is ready by
  -- the time the user opens the chat window. Session creation is deferred
  -- until the user actually opens the chat to avoid prompting for session
  -- selection at startup.
  if state.config.auto_create_session and state.config.service.auto_start then
    vim.schedule(function()
      ensure_service_running(function() end)
    end)
  end
  return M
end

function M.open_chat()
  ensure_chat_window()
  if state.config.auto_create_session and not state.session_id and not state.creating_session then
    with_session(function() end)
  end
  return state.chat_bufnr
end

function M.new_session()
  local previous_session_id = state.session_id
  state.session_id = nil
  state.session_name = nil
  discard_pending_attachments()
  clear_transcript()
  M.open_chat()
  disconnect_session(previous_session_id, false, function(err)
    if err then
      append_entry('error', 'Failed to disconnect previous session: ' .. err)
      return
    end
    with_session(function(session_id, create_err)
      if create_err then
        append_entry('error', create_err)
        return
      end
      append_entry('system', 'Created session ' .. session_id)
    end)
  end)
end

function M.switch_session()
  request('GET', '/sessions', nil, function(response, err)
    if err then
      notify('Failed to list sessions: ' .. err, vim.log.levels.ERROR)
      return
    end

    local persisted = (response and response.persisted) or {}
    if #persisted == 0 then
      notify('No sessions found. Use :CopilotAgentNewSession to create one.', vim.log.levels.INFO)
      return
    end

    -- Sort newest-first.
    table.sort(persisted, function(a, b)
      local ta = a.modifiedTime or a.startTime or ''
      local tb = b.modifiedTime or b.startTime or ''
      return ta > tb
    end)

    local choices = {}
    for _, s in ipairs(persisted) do
      local label = s.sessionId:sub(1, 8)
      if s.summary and s.summary ~= '' then
        label = s.summary .. ' [' .. label .. ']'
      else
        local ts = s.modifiedTime or s.startTime or ''
        if ts ~= '' then
          label = label .. ' (' .. ts .. ')'
        end
      end
      local cwd_label = ''
      if s.context and s.context.cwd then
        cwd_label = '  ' .. vim.fn.fnamemodify(s.context.cwd, ':~')
      end
      -- Mark the currently active session.
      local active = (state.session_id and s.sessionId == state.session_id) and ' ●' or ''
      table.insert(choices, { label = label .. cwd_label .. active, id = s.sessionId })
    end
    table.insert(choices, { label = '+ New session', id = nil })

    local display = vim.tbl_map(function(c)
      return c.label
    end, choices)

    vim.ui.select(display, { prompt = 'Switch session' }, function(_, idx)
      if not idx then
        return
      end
      local picked = choices[idx]
      if not picked.id then
        M.new_session()
        return
      end
      if state.session_id and picked.id == state.session_id then
        notify('Already on this session', vim.log.levels.INFO)
        return
      end
      local previous_session_id = state.session_id
      state.session_id = nil
      state.session_name = nil
      state.creating_session = true
      discard_pending_attachments()
      clear_transcript()
      ensure_chat_window()
      disconnect_session(previous_session_id, false, function(disconnect_err)
        if disconnect_err then
          append_entry('error', 'Failed to disconnect previous session: ' .. disconnect_err)
        end
        append_entry('system', 'Switching to session ' .. picked.id:sub(1, 8) .. '…')
        resume_session(picked.id)
      end)
    end)
  end)
end

function M.ask(prompt, opts)
  opts = opts or {}
  local text = prompt
  if text == nil or text == '' then
    M.open_chat()
    open_input_window()
    return
  end

  M.open_chat()
  append_entry('user', text, opts.attachments and #opts.attachments > 0 and vim.deepcopy(opts.attachments) or nil)
  -- Mark busy immediately so the spinner shows before the first delta arrives.
  state.chat_busy = true
  refresh_statuslines()
  schedule_render()

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

  with_session(function(session_id, err)
    if err then
      state.chat_busy = false
      refresh_statuslines()
      append_entry('error', err)
      return
    end
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
        state.chat_busy = false
        refresh_statuslines()
        append_entry('error', 'Failed to send prompt: ' .. request_err)
      end
    end)
  end)
end

function M.select_model(model)
  if model and model ~= '' then
    apply_model(model, function(_, err)
      if err then
        notify('Failed to set model: ' .. err, vim.log.levels.ERROR)
      end
    end)
    return
  end

  fetch_models(function(models, err)
    if err then
      notify('Failed to list models: ' .. err, vim.log.levels.ERROR)
      append_entry('error', 'Failed to list models: ' .. err)
      return
    end
    if type(models) ~= 'table' or vim.tbl_isempty(models) then
      append_entry('error', 'No models returned by service')
      return
    end

    vim.ui.select(models, {
      prompt = 'Select Copilot model',
      format_item = function(item)
        local label = item.label
        if item.supports_reasoning and #(item.supported_efforts or {}) > 0 then
          label = label .. ' 🧠'
        end
        return label
      end,
    }, function(choice)
      if not choice then
        return
      end
      -- If the model supports reasoning effort, prompt for it.
      if choice.supports_reasoning and #(choice.supported_efforts or {}) > 0 then
        local efforts = {}
        for _, e in ipairs(choice.supported_efforts) do
          local label = e
          if e == (choice.default_effort or '') then
            label = label .. ' (default)'
          end
          table.insert(efforts, { id = e, label = label })
        end
        vim.ui.select(efforts, {
          prompt = 'Reasoning effort for ' .. choice.name,
          format_item = function(item)
            return item.label
          end,
        }, function(effort_choice)
          local reasoning = effort_choice and effort_choice.id or nil
          apply_model(choice.id, function(_, apply_err)
            if apply_err then
              notify('Failed to set model: ' .. apply_err, vim.log.levels.ERROR)
              append_entry('error', 'Failed to set model: ' .. apply_err)
            end
          end, { reasoning_effort = reasoning })
        end)
        return
      end
      apply_model(choice.id, function(_, apply_err)
        if apply_err then
          notify('Failed to set model: ' .. apply_err, vim.log.levels.ERROR)
          append_entry('error', 'Failed to set model: ' .. apply_err)
        end
      end)
    end)
  end)
end

function M.complete_model(arglead)
  if #state.model_cache == 0 then
    local response = select(1, sync_request('GET', '/models', nil))
    if response and type(response.models) == 'table' then
      store_model_cache(response.models)
    elseif state.config.service.auto_start and not state.service_starting then
      ensure_service_running(function(err)
        if not err then
          fetch_models(function() end)
        end
      end)
    end
  end

  return model_completion_items(arglead)
end

function M.start_service(callback)
  ensure_service_running(function(err)
    if err then
      notify('Failed to start service: ' .. err, vim.log.levels.ERROR)
      append_entry('error', 'Failed to start service: ' .. err)
      if callback then
        callback(nil, err)
      end
      return
    end
    append_entry('system', 'Service ready at ' .. normalize_base_url(state.config.base_url))
    if callback then
      callback(true)
    end
  end)
end

function M.stop(delete_state)
  if not state.session_id then
    append_entry('system', 'No active session')
    return
  end

  local session_id = state.session_id
  state.session_id = nil
  discard_pending_attachments()
  clear_transcript()
  disconnect_session(session_id, delete_state, function(err)
    if err then
      append_entry('error', 'Failed to disconnect session: ' .. err)
      return
    end
    append_entry('system', 'Disconnected session ' .. session_id)
  end)
end

function M.retry_input()
  if not state.pending_user_input then
    notify('No pending input request to retry', vim.log.levels.INFO)
    return
  end
  show_user_input_picker(state.pending_user_input)
end

function M.status()
  local lines = {
    'service: ' .. normalize_base_url(state.config.base_url),
    'session: ' .. (state.session_id or '<none>'),
    'model: ' .. tostring(state.config.session.model or '<default>'),
    'service_job: ' .. tostring(state.service_job_id or '<none>'),
    'service_starting: ' .. tostring(state.service_starting),
    'streaming: ' .. tostring(state.events_job_id ~= nil),
    'buffer: ' .. tostring(state.chat_bufnr or '<none>'),
  }
  notify(table.concat(lines, ' | '))
  return {
    session_id = state.session_id,
    service_job_id = state.service_job_id,
    service_starting = state.service_starting,
    events_job_id = state.events_job_id,
    chat_bufnr = state.chat_bufnr,
  }
end

function M.state()
  return state
end

-- ── Statusline component API ──────────────────────────────────────────────────
-- Use these in your statusline plugin (lualine, heirline, feline, etc.)
--
-- Lualine example:
--   lualine.setup { sections = { lualine_x = {
--     require('copilot_agent').statusline_mode,
--     require('copilot_agent').statusline_model,
--     require('copilot_agent').statusline_busy,
--   }}}
--
-- &statusline / heirline example:
--   %{v:lua.require'copilot_agent'.statusline()}
--
M.statusline_mode = statusline_mode
M.statusline_model = statusline_model
M.statusline_busy = statusline_busy
M.statusline_attachments = statusline_attachments
M.statusline_permission = statusline_permission
M.statusline = statusline_component

-- Build the command list for the LSP server process.
-- We do NOT pass --addr so the OS assigns a free port.
-- The bound address is announced via COPILOT_AGENT_ADDR= on stdout.
local function lsp_command()
  local cmd = service_command()
  return vim.deepcopy(cmd)
end

-- Capture the clipboard image and add it to pending_attachments.
-- Saves clipboard PNG to a temp file, then inserts as an image attachment.
-- Supports macOS (pngpaste), Linux/Wayland (wl-paste), Linux/X11 (xclip, xsel).
function M.paste_clipboard_image()
  local tmpfile = vim.fn.tempname() .. '.png'
  local sysname = (uv.os_uname() or {}).sysname or ''

  local cmd
  if sysname == 'Darwin' then
    if vim.fn.executable('pngpaste') == 1 then
      cmd = { 'pngpaste', tmpfile }
    else
      notify('pngpaste not found. Install with: brew install pngpaste', vim.log.levels.ERROR)
      return
    end
  elseif sysname == 'Linux' then
    if vim.env.WAYLAND_DISPLAY and vim.fn.executable('wl-paste') == 1 then
      cmd = { 'sh', '-c', 'wl-paste --type image/png > ' .. vim.fn.shellescape(tmpfile) }
    elseif vim.fn.executable('xclip') == 1 then
      cmd = { 'sh', '-c', 'xclip -selection clipboard -t image/png -o > ' .. vim.fn.shellescape(tmpfile) }
    elseif vim.fn.executable('xsel') == 1 then
      cmd = { 'sh', '-c', 'xsel --clipboard --output --type image/png > ' .. vim.fn.shellescape(tmpfile) }
    else
      notify('No clipboard image tool found. Install pngpaste (macOS) or wl-paste/xclip (Linux).', vim.log.levels.ERROR)
      return
    end
  else
    notify('Clipboard image paste is not supported on this platform.', vim.log.levels.WARN)
    return
  end

  vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local stat = uv.fs_stat(tmpfile)
        if exit_code ~= 0 or not stat or stat.size == 0 then
          notify('No image found on clipboard (exit=' .. exit_code .. '). Copy an image first.', vim.log.levels.WARN)
          return
        end
        table.insert(state.pending_attachments, {
          type = 'image',
          path = tmpfile,
          display = '🖼️ clipboard.png',
          temp = true, -- delete after send; see M.ask()
        })
        refresh_statuslines()
        notify('Image from clipboard added as attachment.', vim.log.levels.INFO)
        if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
          vim.api.nvim_set_current_win(state.input_winid)
          vim.cmd('startinsert!')
        end
      end)
    end,
  })
end

-- Start the Copilot agent as a single process that runs both the HTTP bridge
-- Download the pre-built copilot-agent binary for the current platform from
-- the latest GitHub release and save it to <plugin_root>/bin/copilot-agent[.exe].
-- After a successful download the binary is used automatically on next startup
-- (service.command = nil auto-detects it).
function M.install_binary(opts)
  opts = opts or {}
  local uname = vim.uv.os_uname()

  -- Detect GOOS
  local os_name
  local sysname = uname.sysname
  if sysname == 'Darwin' then
    os_name = 'darwin'
  elseif sysname == 'Linux' then
    os_name = 'linux'
  elseif sysname:find('Windows') then
    os_name = 'windows'
  else
    notify('install_binary: unsupported OS: ' .. sysname, vim.log.levels.ERROR)
    return
  end

  -- Detect GOARCH
  local arch
  local machine = uname.machine
  if machine == 'x86_64' or machine == 'AMD64' then
    arch = 'amd64'
  elseif machine == 'aarch64' or machine == 'arm64' then
    arch = 'arm64'
  else
    notify('install_binary: unsupported architecture: ' .. machine, vim.log.levels.ERROR)
    return
  end

  local ext = os_name == 'windows' and '.exe' or ''
  local target = os_name .. '-' .. arch
  local filename = 'copilot-agent-' .. target .. ext
  local repo = opts.repo or 'ray-x/copilot-agent.nvim'
  local release_tag = opts.tag or 'latest'
  local url = ('https://github.com/%s/releases/download/%s/%s'):format(repo, release_tag, filename)

  local bin_dir = plugin_root() .. '/bin'
  local out_path = bin_dir .. '/copilot-agent' .. ext

  vim.fn.mkdir(bin_dir, 'p')
  notify(('Downloading %s for %s/%s …'):format(filename, os_name, arch), vim.log.levels.INFO)

  local stderr_lines = {}
  vim.fn.jobstart({ 'curl', '-fsSL', '--progress-bar', '-o', out_path, url }, {
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then
          table.insert(stderr_lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        local detail = #stderr_lines > 0 and (': ' .. table.concat(stderr_lines, ' ')) or ''
        notify('Download failed (exit ' .. code .. ')' .. detail, vim.log.levels.ERROR)
        vim.fn.delete(out_path)
        return
      end
      if ext == '' then
        vim.fn.system({ 'chmod', '+x', out_path })
      end
      notify('copilot-agent installed → ' .. out_path .. '\nRestart Neovim or run :CopilotAgentStart', vim.log.levels.INFO)
      if opts.on_complete then
        opts.on_complete(out_path)
      end
    end,
  })
end

-- service and the LSP server on stdio. The Neovim LSP client owns the process
-- lifetime; ensure_service_running reuses it for HTTP health-checks.
function M.start_lsp(opts)
  opts = opts or {}

  -- If an LSP client with this name is already running for this root, reuse it.
  local root = opts.root_dir or working_directory()
  for _, client in ipairs(vim.lsp.get_clients({ name = 'copilot-agent' })) do
    if client.config.root_dir == root then
      return client.id
    end
  end

  local cmd = lsp_command()

  -- Wrap cmd in a shell that tees stderr so COPILOT_AGENT_ADDR= is captured.
  -- stdout is kept clean for the LSP protocol.
  local stderr_fifo = vim.fn.tempname()
  local wrapped_cmd = {
    'sh',
    '-c',
    table.concat(vim.tbl_map(vim.fn.shellescape, cmd), ' ') .. ' 2>' .. vim.fn.shellescape(stderr_fifo),
  }
  -- Read the tee'd stderr in a background job so we can parse COPILOT_AGENT_ADDR.
  vim.fn.jobstart({ 'tail', '-F', stderr_fifo }, {
    on_stdout = function(_, data)
      vim.schedule(function()
        remember_service_output(data)
      end)
    end,
  })
  local client_id = vim.lsp.start({
    name = 'copilot-agent',
    cmd = wrapped_cmd,
    cmd_cwd = service_cwd(),
    root_dir = root,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    on_init = function(client)
      -- Record the LSP client id so the service is considered started.
      state.lsp_client_id = client.id
      notify('Copilot agent started (LSP id=' .. client.id .. ')', vim.log.levels.INFO)
      -- Kick any pending service callbacks now that the HTTP port is up.
      ensure_service_running(function() end)
    end,
    on_exit = function(code, signal)
      state.lsp_client_id = nil
      pcall(os.remove, stderr_fifo)
      if code ~= 0 then
        notify('Copilot agent exited: code=' .. code .. ' signal=' .. tostring(signal), vim.log.levels.WARN)
      end
    end,
  })

  if not client_id then
    notify('Failed to start Copilot agent LSP', vim.log.levels.ERROR)
  end
  return client_id
end

-- Expose internal state for :checkhealth and debugging.
M.state = state

return M
