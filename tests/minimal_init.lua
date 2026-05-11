-- Minimal Neovim init for integration tests.
-- Sets up runtimepath to include this plugin and test dependencies.
-- Usage:  nvim --headless -u tests/minimal_init.lua [...]

local dev_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h')
local original_data_home = vim.fn.stdpath('data')

-- Build a clean runtimepath containing only the Neovim runtime and the
-- plugin under test.  This prevents user-installed plugins, ftplugins,
-- and LSP configs from polluting the test environment.
local isolated_root = vim.fn.tempname()
-- Stub treesitter modules early to avoid native-call runtime errors in headless tests
package.preload['vim.treesitter'] = package.preload['vim.treesitter'] or function()
  return { get_parser = function() return nil end, start = function() end }
end
package.preload['nvim-treesitter.parsers'] = package.preload['nvim-treesitter.parsers'] or function()
  return {}
end

vim.fn.mkdir(isolated_root, 'p')
vim.env.XDG_CONFIG_HOME = isolated_root .. '/config'
vim.env.XDG_DATA_HOME = isolated_root .. '/data'
vim.env.XDG_STATE_HOME = isolated_root .. '/state'
vim.env.XDG_CACHE_HOME = isolated_root .. '/cache'
vim.fn.mkdir(vim.env.XDG_CONFIG_HOME, 'p')
vim.fn.mkdir(vim.env.XDG_DATA_HOME, 'p')
vim.fn.mkdir(vim.env.XDG_STATE_HOME, 'p')
vim.fn.mkdir(vim.env.XDG_CACHE_HOME, 'p')
vim.cmd('filetype off')
vim.cmd('syntax off')
vim.g.loaded_matchparen = 1
vim.g.loaded_tarPlugin = 1
vim.g.loaded_zipPlugin = 1
vim.g.loaded_2html_plugin = 1
-- netrw's startup plugin does `packadd netrw`, which errors once we blank
-- packpath for the isolated test harness.
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1
-- Clear FileType autocommands early to prevent runtime ftplugins (markdown/treesitter) from running
pcall(vim.api.nvim_clear_autocmds, { event = 'FileType' })
-- Also pre-disable common ftplugins that may rely on treesitter internals
vim.g.loaded_markdown = 1
vim.g.loaded_markdown_ftplugin = 1

local nvim_runtime = vim.env.VIMRUNTIME
vim.opt.runtimepath = { dev_root, nvim_runtime, nvim_runtime .. '/after' }
vim.opt.packpath = { original_data_home }

-- Further isolate test runtime: disable filetype-driven ftplugins and treesitter hooks
vim.g.did_load_filetypes = 0
vim.g.loaded_tree_sitter = 1
vim.g.loaded_treesitter = 1
vim.g.loaded_treesitter_configs = 1
vim.g.loaded_markdown = 1
vim.g.loaded_markdown_ftplugin = 1

-- Stub out problematic treesitter functions to avoid runtime errors in headless
if vim.treesitter then
  if vim.treesitter.get_parser then
    vim.treesitter._orig_get_parser = vim.treesitter.get_parser
  end
  vim.treesitter.get_parser = function() return nil end

  if vim.treesitter.start then
    vim.treesitter._orig_start = vim.treesitter.start
    vim.treesitter.start = function() end
  end
end

-- reset module cache so re-require always uses the dev copy.
if vim.loader and vim.loader.reset then
  vim.loader.reset()
end

-- Ensure require() resolves to the development tree first by inserting a
-- custom searcher at position 1 (after preload) that checks dev_root/lua/.
local dev_lua = dev_root .. '/lua/'
table.insert(package.loaders, 2, function(modname)
  local path = dev_lua .. modname:gsub('%.', '/') .. '.lua'
  if vim.uv.fs_stat(path) then
    return loadfile(path)
  end
  path = dev_lua .. modname:gsub('%.', '/') .. '/init.lua'
  if vim.uv.fs_stat(path) then
    return loadfile(path)
  end
end)

local function append_dependency(name)
  local data = vim.fn.stdpath('data')
  local candidates = {
    data .. '/site/pack/vendor/start/' .. name,
    data .. '/lazy/' .. name,
    original_data_home .. '/site/pack/vendor/start/' .. name,
    original_data_home .. '/lazy/' .. name,
  }

  for _, path in ipairs(candidates) do
    if vim.fn.isdirectory(path) == 1 then
      vim.opt.runtimepath:append(path)
      vim.cmd('silent! packadd ' .. name)
      return path
    end
  end
end

append_dependency('plenary.nvim')
vim.cmd('silent! packadd plenary.nvim')

vim.opt.swapfile = false
vim.opt.backup = false
