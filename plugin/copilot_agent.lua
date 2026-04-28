-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

if vim.g.loaded_copilot_agent_plugin == 1 then
  return
end

vim.g.loaded_copilot_agent_plugin = 1

local copilot_agent = require('copilot_agent')

vim.api.nvim_create_user_command('CopilotAgentChat', function(opts)
  local args = opts.fargs or {}
  local fullscreen = vim.tbl_contains(args, 'fullscreen') or vim.tbl_contains(args, 'fs')
  copilot_agent.open_chat({ fullscreen = fullscreen or nil })
end, { nargs = '?', desc = 'Open Copilot Go chat (args: fullscreen)', complete = function()
  return { 'fullscreen' }
end })

vim.api.nvim_create_user_command('CopilotAgentChatToggle', function()
  copilot_agent.toggle_chat()
end, { desc = 'Toggle Copilot chat window (open if hidden, close if visible)' })

vim.api.nvim_create_user_command('CopilotAgentChatFocus', function()
  copilot_agent.focus_chat()
end, { desc = 'Focus or switch to an open Copilot chat buffer' })

vim.api.nvim_create_user_command('CopilotAgentNewSession', function()
  copilot_agent.new_session()
end, { desc = 'Create a new Copilot Go session' })

vim.api.nvim_create_user_command('CopilotAgentSwitchSession', function()
  copilot_agent.switch_session()
end, { desc = 'Switch to a different Copilot session' })

vim.api.nvim_create_user_command('CopilotAgentStart', function()
  copilot_agent.start_service()
end, { desc = 'Start the Copilot Go service' })

vim.api.nvim_create_user_command('CopilotAgentAsk', function(command)
  copilot_agent.ask(table.concat(command.fargs, ' '))
end, {
  nargs = '*',
  desc = 'Send a prompt to Copilot Go',
})

vim.api.nvim_create_user_command('CopilotAgentModel', function(command)
  copilot_agent.select_model(table.concat(command.fargs, ' '))
end, {
  nargs = '*',
  complete = function(arglead)
    return copilot_agent.complete_model(arglead)
  end,
  desc = 'Select or set the Copilot model',
})

vim.api.nvim_create_user_command('CopilotAgentStop', function(command)
  copilot_agent.stop(command.bang)
end, {
  bang = true,
  desc = 'Disconnect the active Copilot Go session',
})

vim.api.nvim_create_user_command('CopilotAgentCancel', function()
  copilot_agent.cancel()
end, { desc = 'Cancel the current in-progress Copilot turn (abort mid-stream)' })

vim.api.nvim_create_user_command('CopilotAgentStatus', function()
  copilot_agent.status()
end, { desc = 'Show Copilot Go session state' })

vim.api.nvim_create_user_command('CopilotAgentLsp', function()
  copilot_agent.start_lsp()
end, { desc = 'Start the Copilot LSP server (code actions: explain, fix, add tests, add docs)' })

vim.api.nvim_create_user_command('CopilotAgentPasteImage', function()
  copilot_agent.paste_clipboard_image()
end, { desc = 'Paste image from clipboard and add as attachment to next Copilot message' })

vim.api.nvim_create_user_command('CopilotAgentInstall', function()
  copilot_agent.install_binary()
end, { desc = 'Download the pre-built copilot-agent binary for the current platform' })

vim.api.nvim_create_user_command('CopilotAgentRetryInput', function()
  copilot_agent.retry_input()
end, { desc = 'Re-show the last dismissed ask_user prompt' })
