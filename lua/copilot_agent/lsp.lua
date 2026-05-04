-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- LSP integration, binary install, clipboard image paste.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local state = cfg.state
local notify = cfg.notify
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')

local M = {}
local is_list = vim.islist or vim.tbl_islist
local LSP_CONFIG_PATH = '.github/lsp.json'
local HELPER_CLIENT_NAME = 'copilot-agent'
local REQUIRED_PROJECT_CAPABILITIES = {
  'definitionProvider',
  'referencesProvider',
}
local LANGUAGE_ID_BY_FILETYPE = {
  bash = 'shellscript',
  cs = 'csharp',
  dosbatch = 'bat',
  objcpp = 'objective-cpp',
  objc = 'objective-c',
  ps1 = 'powershell',
  sh = 'shellscript',
  zsh = 'shellscript',
}
local LANGUAGE_ID_BY_EXTENSION = {
  ['.bash'] = 'shellscript',
  ['.bat'] = 'bat',
  ['.cjs'] = 'javascript',
  ['.cs'] = 'csharp',
  ['.cts'] = 'typescript',
  ['.cxx'] = 'cpp',
  ['.h'] = 'c',
  ['.hpp'] = 'cpp',
  ['.hxx'] = 'cpp',
  ['.jsx'] = 'javascriptreact',
  ['.m'] = 'objective-c',
  ['.mjs'] = 'javascript',
  ['.mm'] = 'objective-cpp',
  ['.mts'] = 'typescript',
  ['.ps1'] = 'powershell',
  ['.sh'] = 'shellscript',
  ['.tsx'] = 'typescriptreact',
  ['.zsh'] = 'shellscript',
}

local function path_join(...)
  return table.concat({ ... }, '/')
end

local function normalized_path(path)
  if type(path) ~= 'string' or path == '' then
    return path
  end

  local absolute = vim.fn.fnamemodify(path, ':p')
  local probe = absolute
  local suffix = {}

  while type(probe) == 'string' and probe ~= '' do
    local real = uv.fs_realpath(probe)
    if real then
      for i = #suffix, 1, -1 do
        real = path_join(real, suffix[i])
      end
      return real
    end
    local parent = vim.fn.fnamemodify(probe, ':h')
    if parent == probe then
      break
    end
    suffix[#suffix + 1] = vim.fn.fnamemodify(probe, ':t')
    probe = parent
  end

  return absolute
end

local function project_root()
  return state.session_working_directory or service.working_directory()
end

local function config_path(root)
  return path_join(root, LSP_CONFIG_PATH)
end

local function normalize_client_list(clients)
  if type(clients) ~= 'table' then
    return {}
  end
  if is_list(clients) then
    return clients
  end

  local normalized = {}
  for _, client in pairs(clients) do
    normalized[#normalized + 1] = client
  end
  table.sort(normalized, function(left, right)
    return tonumber(left.id or 0) < tonumber(right.id or 0)
  end)
  return normalized
end

local function client_root_dir(client)
  local root = client and client.config and client.config.root_dir or nil
  if type(root) == 'string' and root ~= '' then
    return root
  end

  local folders = client and client.workspace_folders or nil
  if type(folders) ~= 'table' or vim.tbl_isempty(folders) then
    return nil
  end
  local first = folders[1]
  if type(first) ~= 'table' then
    return nil
  end
  if type(first.name) == 'string' and first.name ~= '' then
    return first.name
  end
  if type(first.uri) == 'string' and first.uri ~= '' and type(vim.uri_to_fname) == 'function' then
    return vim.uri_to_fname(first.uri)
  end
  return nil
end

local function client_capability_enabled(client, capability)
  local caps = client and client.server_capabilities or {}
  local value = caps[capability]
  if value ~= nil then
    return value ~= false
  end

  local legacy = client and client.resolved_capabilities or {}
  if capability == 'definitionProvider' and legacy.definition ~= nil then
    return legacy.definition == true
  end
  if capability == 'referencesProvider' and legacy.references ~= nil then
    return legacy.references == true
  end
  return false
end

local function client_supports_required_capabilities(client)
  for _, capability in ipairs(REQUIRED_PROJECT_CAPABILITIES) do
    if not client_capability_enabled(client, capability) then
      return false
    end
  end
  return true
end

local function list_buffer_clients(bufnr)
  if vim.lsp and type(vim.lsp.buf_get_clients) == 'function' then
    local ok, clients = pcall(vim.lsp.buf_get_clients, bufnr)
    if ok then
      return normalize_client_list(clients)
    end
  end
  if vim.lsp and type(vim.lsp.get_clients) == 'function' then
    local ok, clients = pcall(vim.lsp.get_clients, { bufnr = bufnr })
    if ok then
      return normalize_client_list(clients)
    end
  end
  if vim.lsp and type(vim.lsp.get_active_clients) == 'function' then
    local ok, clients = pcall(vim.lsp.get_active_clients, { bufnr = bufnr })
    if ok then
      return normalize_client_list(clients)
    end
  end
  return {}
end

local function list_global_clients(filter)
  filter = filter or {}
  local clients
  if vim.lsp and type(vim.lsp.get_clients) == 'function' then
    local ok, value = pcall(vim.lsp.get_clients, filter)
    clients = ok and value or nil
  elseif vim.lsp and type(vim.lsp.get_active_clients) == 'function' then
    local ok, value = pcall(vim.lsp.get_active_clients)
    clients = ok and value or nil
  end

  local normalized = normalize_client_list(clients)
  if filter.name == nil or filter.name == '' then
    return normalized
  end

  local filtered = {}
  for _, client in ipairs(normalized) do
    if client.name == filter.name then
      filtered[#filtered + 1] = client
    end
  end
  return filtered
end

local function file_extension(path)
  local ext = vim.fn.fnamemodify(path or '', ':e')
  if type(ext) ~= 'string' or ext == '' then
    return nil
  end
  return '.' .. ext:lower()
end

local function language_id_for(path, filetype)
  local ext = file_extension(path)
  if ext and LANGUAGE_ID_BY_EXTENSION[ext] then
    return LANGUAGE_ID_BY_EXTENSION[ext]
  end
  if type(filetype) == 'string' and filetype ~= '' then
    return LANGUAGE_ID_BY_FILETYPE[filetype] or filetype
  end
  return nil
end

local function unique_server_key(seed, used_keys)
  local base = tostring(seed or 'lsp-server'):lower():gsub('%s+', '-'):gsub('[^%w%-%._]', '-')
  base = base:gsub('%-+', '-')
  if base == '' then
    base = 'lsp-server'
  end

  local key = base
  local suffix = 2
  while used_keys[key] do
    key = string.format('%s-%d', base, suffix)
    suffix = suffix + 1
  end
  used_keys[key] = true
  return key
end

local function slice(tbl, start_index)
  local out = {}
  for i = start_index, #(tbl or {}) do
    out[#out + 1] = tostring(tbl[i])
  end
  return out
end

local function client_command_parts(client)
  local cmd = client and client.config and client.config.cmd or nil
  if type(cmd) == 'table' and #cmd > 0 then
    return slice(cmd, 1)
  end
  if type(cmd) == 'string' and cmd ~= '' then
    return { cmd }
  end
  return nil
end

local function path_in_root(path, root)
  if type(path) ~= 'string' or path == '' or type(root) ~= 'string' or root == '' then
    return false
  end
  path = normalized_path(path)
  root = normalized_path(root)
  return path == root or vim.startswith(path, root .. '/')
end

local function project_file_buffers(root)
  local bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == '' then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' and path_in_root(name, root) then
        bufs[#bufs + 1] = bufnr
      end
    end
  end
  table.sort(bufs)
  return bufs
end

local function discover_project_clients(root)
  local discovered = {}
  local seen_by_id = {}
  local used_keys = {}

  for _, bufnr in ipairs(project_file_buffers(root)) do
    local path = vim.api.nvim_buf_get_name(bufnr)
    local filetype = vim.bo[bufnr].filetype
    if filetype == '' and vim.filetype and type(vim.filetype.match) == 'function' then
      filetype = vim.filetype.match({ filename = path }) or ''
    end
    local ext = file_extension(path)
    local language_id = language_id_for(path, filetype)

    for _, client in ipairs(list_buffer_clients(bufnr)) do
      if client.name ~= HELPER_CLIENT_NAME and client_supports_required_capabilities(client) then
        local entry = seen_by_id[client.id]
        if not entry then
          local cmd = client_command_parts(client)
          entry = {
            id = client.id,
            name = client.name or ('client-' .. tostring(client.id)),
            key = unique_server_key(client.name or (cmd and cmd[1]) or ('client-' .. tostring(client.id)), used_keys),
            root_dir = client_root_dir(client),
            command = cmd and cmd[1] or nil,
            args = cmd and slice(cmd, 2) or {},
            fileExtensions = {},
          }
          seen_by_id[client.id] = entry
          discovered[#discovered + 1] = entry
        end

        if ext and language_id then
          entry.fileExtensions[ext] = language_id
        end
      end
    end
  end

  table.sort(discovered, function(left, right)
    return left.key < right.key
  end)
  return discovered
end

local function encode_json_pretty(value)
  if vim.json and type(vim.json.encode) == 'function' then
    return vim.json.encode(value, { indent = '  ' })
  end
  return http.encode_json(value)
end

local function read_lsp_config(root)
  local path = config_path(root)
  if vim.fn.filereadable(path) ~= 1 then
    return {
      lspServers = {},
    }, path, false
  end

  local raw = table.concat(vim.fn.readfile(path), '\n')
  local decoded, err = http.decode_json(raw, { log = false })
  if type(decoded) ~= 'table' then
    return nil, path, 'Failed to parse ' .. LSP_CONFIG_PATH .. ': ' .. tostring(err)
  end
  decoded.lspServers = type(decoded.lspServers) == 'table' and decoded.lspServers or {}
  return decoded, path, true
end

local function write_lsp_config(path, config)
  local parent = vim.fn.fnamemodify(path, ':h')
  if parent ~= '' then
    vim.fn.mkdir(parent, 'p')
  end

  local encoded = encode_json_pretty(config)
  local ok, err = pcall(vim.fn.writefile, vim.split(encoded, '\n', { plain = true }), path)
  if not ok then
    return nil, err
  end
  return true
end

local function server_keys(lsp_servers)
  local keys = {}
  for key in pairs(lsp_servers or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function extension_keys(file_extensions)
  local keys = {}
  for ext in pairs(file_extensions or {}) do
    keys[#keys + 1] = ext
  end
  table.sort(keys)
  return keys
end

local function relative_path(path, root)
  path = normalized_path(path)
  root = normalized_path(root)
  if path_in_root(path, root) then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ':~:.')
end

local function command_label(command, args)
  args = args or {}
  if type(command) ~= 'string' or command == '' then
    return '<missing>'
  end
  if vim.tbl_isempty(args) then
    return command
  end
  return command .. ' ' .. table.concat(args, ' ')
end

local function open_path_safely(path)
  local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path))
  if ok then
    return true
  end

  local bufnr = vim.fn.bufadd(path)
  if bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, path)
  end

  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or { '' }
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].buftype = ''
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  return nil, err
end

local function normalize_command(command)
  if type(command) ~= 'string' or command == '' then
    return nil
  end
  return vim.fn.fnamemodify(command, ':t')
end

local function executable_found(command)
  if type(command) ~= 'string' or command == '' then
    return false
  end
  return vim.fn.executable(command) == 1
end

local function project_helper_clients()
  return list_global_clients({ name = HELPER_CLIENT_NAME })
end

local function notify_message(message, level)
  notify(message, level or vim.log.levels.INFO)
end

function M.create_config()
  local root = project_root()
  local discovered = discover_project_clients(root)
  local eligible = {}
  local skipped = {}

  for _, client in ipairs(discovered) do
    if client.command and not vim.tbl_isempty(client.fileExtensions) then
      eligible[#eligible + 1] = client
    else
      skipped[#skipped + 1] = client.name
    end
  end

  if vim.tbl_isempty(eligible) then
    notify_message(
      'No project LSP clients with definitionProvider + referencesProvider were found under ' .. root
        .. '. Open a project file with an attached language server first.',
      vim.log.levels.WARN
    )
    return false
  end

  local config, path, err = read_lsp_config(root)
  if not config then
    notify_message(err, vim.log.levels.ERROR)
    return false
  end

  for _, client in ipairs(eligible) do
    config.lspServers[client.key] = {
      command = client.command,
      args = vim.deepcopy(client.args),
      fileExtensions = vim.deepcopy(client.fileExtensions),
    }
  end

  local ok, write_err = write_lsp_config(path, config)
  if not ok then
    notify_message('Failed to write ' .. LSP_CONFIG_PATH .. ': ' .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end

  local message = string.format(
    'Wrote %d project LSP server%s to %s from active Neovim clients: %s',
    #eligible,
    #eligible == 1 and '' or 's',
    relative_path(path, root),
    table.concat(vim.tbl_map(function(client)
      return client.key
    end, eligible), ', ')
  )
  if not vim.tbl_isempty(skipped) then
    message = message .. '\nSkipped clients without command or file-extension data: ' .. table.concat(skipped, ', ')
  end
  message = message .. '\nRestart the Copilot service after editing this file so config discovery reloads it.'

  local opened, open_err = open_path_safely(path)
  if not opened and open_err then
    message = message .. '\nOpened with a fallback buffer after :edit failed: ' .. tostring(open_err)
  end

  notify_message(message, open_err and vim.log.levels.WARN or vim.log.levels.INFO)
  return true
end

function M.status_message()
  local root = project_root()
  local path = config_path(root)
  local config_discovery = state.config.session.enable_config_discovery ~= false
  local project_clients = discover_project_clients(root)
  local helper_clients = project_helper_clients()
  local lines = {
    'LSP status',
    '  Project root: ' .. root,
    '  Config discovery: ' .. (config_discovery and 'enabled' or 'disabled'),
    '  Config file: ' .. relative_path(path, root) .. (vim.fn.filereadable(path) == 1 and ' (present)' or ' (missing)'),
    '  Project clients:',
  }

  if vim.tbl_isempty(project_clients) then
    lines[#lines + 1] = '    - none with definitionProvider + referencesProvider'
  else
    for _, client in ipairs(project_clients) do
      lines[#lines + 1] = string.format(
        '    - %s (id=%s, cmd=%s, root=%s)',
        client.name,
        tostring(client.id),
        command_label(client.command, client.args),
        client.root_dir or '<none>'
      )
    end
  end

  lines[#lines + 1] = '  Helper client:'
  if vim.tbl_isempty(helper_clients) then
    lines[#lines + 1] = '    - copilot-agent inactive'
  else
    for _, client in ipairs(helper_clients) do
      lines[#lines + 1] = string.format(
        '    - %s (id=%s, root=%s)',
        client.name or HELPER_CLIENT_NAME,
        tostring(client.id),
        client_root_dir(client) or '<none>'
      )
    end
  end

  lines[#lines + 1] = '  Restart required after editing ' .. relative_path(path, root) .. ' while the service is running.'
  return table.concat(lines, '\n')
end

function M.status()
  notify_message(M.status_message(), vim.log.levels.INFO)
  return true
end

function M.show_config()
  local root = project_root()
  local config, path, err = read_lsp_config(root)
  if not config then
    notify_message(err, vim.log.levels.ERROR)
    return false
  end

  if vim.tbl_isempty(config.lspServers) then
    notify_message('No LSP servers are configured in ' .. relative_path(path, root), vim.log.levels.WARN)
    return false
  end

  local lines = {
    'Configured LSP servers in ' .. relative_path(path, root),
  }
  for _, key in ipairs(server_keys(config.lspServers)) do
    local server = config.lspServers[key] or {}
    local args = is_list(server.args) and server.args or {}
    lines[#lines + 1] = string.format('  - %s: %s', key, command_label(server.command, args))
    if type(server.fileExtensions) == 'table' and not vim.tbl_isempty(server.fileExtensions) then
      lines[#lines + 1] = '    fileExtensions:'
      for _, ext in ipairs(extension_keys(server.fileExtensions)) do
        lines[#lines + 1] = string.format('      %s -> %s', ext, tostring(server.fileExtensions[ext]))
      end
    else
      lines[#lines + 1] = '    fileExtensions: <none>'
    end
  end

  notify_message(table.concat(lines, '\n'), vim.log.levels.INFO)
  return true
end

function M.test()
  local root = project_root()
  local config, path, err = read_lsp_config(root)
  if not config then
    notify_message(err, vim.log.levels.ERROR)
    return false
  end
  if vim.tbl_isempty(config.lspServers) then
    notify_message('No LSP servers are configured in ' .. relative_path(path, root), vim.log.levels.WARN)
    return false
  end

  local project_clients = discover_project_clients(root)
  local lines = {
    'LSP test',
    '  Config file: ' .. relative_path(path, root),
  }
  local failures = 0

  for _, key in ipairs(server_keys(config.lspServers)) do
    local server = config.lspServers[key] or {}
    local configured_command = normalize_command(server.command)
    local matched = {}
    for _, client in ipairs(project_clients) do
      if client.key == key or normalize_command(client.command) == configured_command then
        matched[#matched + 1] = client
      end
    end

    local executable_ok = executable_found(server.command)
    local active_ok = not vim.tbl_isempty(matched)
    if not executable_ok or not active_ok then
      failures = failures + 1
    end

    lines[#lines + 1] = string.format(
      '  - %s: executable=%s, active=%s',
      key,
      executable_ok and 'yes' or 'no',
      active_ok and 'yes' or 'no'
    )
    if active_ok then
      lines[#lines + 1] = '      matched clients: ' .. table.concat(vim.tbl_map(function(client)
        return string.format('%s(id=%s)', client.name, tostring(client.id))
      end, matched), ', ')
    end
  end

  lines[#lines + 1] = string.format(
    '  Result: %d/%d configured server%s matched an active project LSP client.',
    #server_keys(config.lspServers) - failures,
    #server_keys(config.lspServers),
    #server_keys(config.lspServers) == 1 and '' or 's'
  )
  notify_message(table.concat(lines, '\n'), failures == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
  return failures == 0
end

function M.help_message()
  return table.concat({
    '/lsp create  - Bootstrap .github/lsp.json from active project LSP clients and open it',
    '/lsp status  - Show project LSP status, config discovery, and helper-client state',
    '/lsp show    - List configured servers from .github/lsp.json',
    '/lsp test    - Check configured binaries and whether they match active project clients',
    '/lsp help    - Show this message',
    '',
    ':CopilotAgentLsp still starts the plugin helper LSP used for code actions.',
    'Restart the Copilot service after editing .github/lsp.json so Copilot CLI reloads it.',
  }, '\n')
end

function M.help()
  notify_message(M.help_message(), vim.log.levels.INFO)
  return true
end

M._config_path = config_path
M._discover_project_clients = discover_project_clients

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
