-- Minimal Neovim init for integration tests.
-- Sets up runtimepath to include this plugin and plenary.nvim.
-- Usage:  nvim --headless -u tests/minimal_init.lua [...]

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h'))

-- plenary is expected at the standard pack location used by the CI workflow.
local plenary_path = vim.fn.stdpath('data') .. '/site/pack/vendor/start/plenary.nvim'
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:append(plenary_path)
end

vim.opt.swapfile = false
vim.opt.backup  = false
