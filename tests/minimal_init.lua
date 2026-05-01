-- Minimal Neovim init for integration tests.
-- Sets up runtimepath to include this plugin and test dependencies.
-- Usage:  nvim --headless -u tests/minimal_init.lua [...]

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h'))

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
