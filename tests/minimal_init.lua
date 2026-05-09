-- Minimal Neovim init for integration tests.
-- Sets up runtimepath to include this plugin and test dependencies.
-- Usage:  nvim --headless -u tests/minimal_init.lua [...]

local dev_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h')

-- Build a clean runtimepath containing only the Neovim runtime and the
-- plugin under test.  This prevents user-installed plugins, ftplugins,
-- and LSP configs from polluting the test environment.
local nvim_runtime = vim.env.VIMRUNTIME
vim.opt.runtimepath = { dev_root, nvim_runtime, nvim_runtime .. '/after' }
vim.opt.packpath = {}

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
  }

  for _, path in ipairs(candidates) do
    if vim.fn.isdirectory(path) == 1 then
      vim.opt.runtimepath:append(path)
      return path
    end
  end
end

append_dependency('plenary.nvim')

if append_dependency('nvim-treesitter') then
  pcall(vim.cmd, 'runtime plugin/nvim-treesitter.lua')
  if vim.fn.exists(':TSInstallSync') == 2 then
    pcall(vim.cmd, 'silent! TSInstallSync markdown')
  end
end

vim.opt.swapfile = false
vim.opt.backup = false
