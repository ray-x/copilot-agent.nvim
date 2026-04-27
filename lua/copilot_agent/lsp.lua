-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- LSP integration, binary install, clipboard image paste.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local state = cfg.state
local notify = cfg.notify
local service = require('copilot_agent.service')

local M = {}

local function lsp_command()
  local cmd = service.service_command()
  return vim.deepcopy(cmd)
end

function M.paste_clipboard_image()
  local sl = require('copilot_agent.statusline')
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
          temp = true,
        })
        sl.refresh_statuslines()
        notify('Image from clipboard added as attachment.', vim.log.levels.INFO)
        if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
          vim.api.nvim_set_current_win(state.input_winid)
          vim.cmd('startinsert!')
        end
      end)
    end,
  })
end

function M.install_binary(opts)
  opts = opts or {}
  local uname = vim.uv.os_uname()

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

  local bin_dir = service.plugin_root() .. '/bin'
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

function M.start_lsp(opts)
  opts = opts or {}

  local root = opts.root_dir or service.working_directory()
  for _, client in ipairs(vim.lsp.get_clients({ name = 'copilot-agent' })) do
    if client.config.root_dir == root then
      return client.id
    end
  end

  local cmd = lsp_command()

  local stderr_fifo = vim.fn.tempname()
  local wrapped_cmd = {
    'sh',
    '-c',
    table.concat(vim.tbl_map(vim.fn.shellescape, cmd), ' ') .. ' 2>' .. vim.fn.shellescape(stderr_fifo),
  }
  vim.fn.jobstart({ 'tail', '-F', stderr_fifo }, {
    on_stdout = function(_, data)
      vim.schedule(function()
        service.remember_service_output(data)
      end)
    end,
  })
  local client_id = vim.lsp.start({
    name = 'copilot-agent',
    cmd = wrapped_cmd,
    cmd_cwd = service.service_cwd(),
    root_dir = root,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    on_init = function(client)
      state.lsp_client_id = client.id
      notify('Copilot agent started (LSP id=' .. client.id .. ')', vim.log.levels.INFO)
      service.ensure_service_running(function() end)
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

return M
