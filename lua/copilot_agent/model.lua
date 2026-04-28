-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

-- Model selection, caching, and switching.

local cfg = require('copilot_agent.config')
local http = require('copilot_agent.http')
local service = require('copilot_agent.service')
local utils = require('copilot_agent.utils')
local sl = require('copilot_agent.statusline')
local render = require('copilot_agent.render')

local state = cfg.state
local notify = cfg.notify

local request = http.request
local sync_request = http.sync_request

local ensure_service_running = service.ensure_service_running

local normalize_model_entry = utils.normalize_model_entry
local unavailable_model_from_error = utils.unavailable_model_from_error

local refresh_statuslines = sl.refresh_statuslines

local append_entry = render.append_entry

local M = {}

function M.store_model_cache(models)
  local items = {}
  for _, entry in ipairs(models or {}) do
    local item = normalize_model_entry(entry)
    if item then
      table.insert(items, item)
    end
  end

  table.sort(items, function(left, right)
    return left.label < right.label
  end)
  state.model_cache = items
  return items
end

function M.model_completion_items(arglead)
  local prefix = vim.trim(arglead or ''):lower()
  local matches = {}
  local seen = {}

  local function add(id)
    if type(id) ~= 'string' or id == '' or seen[id] then
      return
    end
    if prefix == '' or id:lower():find(prefix, 1, true) == 1 then
      seen[id] = true
      table.insert(matches, id)
    end
  end

  add(state.config.session.model)
  for _, item in ipairs(state.model_cache) do
    add(item.id)
  end

  table.sort(matches)
  return matches
end

function M.stale_service_hint(unavailable_model)
  if type(unavailable_model) ~= 'string' or unavailable_model == '' then
    return nil
  end
  if state.config.session.model ~= nil then
    return nil
  end
  return string.format(
    'The running Go host selected unavailable model "%s" even though the plugin did not configure a model. This usually means the service process is an older build. Restart `go run .` and reload Neovim.',
    unavailable_model
  )
end

function M.fetch_models(callback, on_error)
  request('GET', '/models', nil, function(response, err, status)
    if err then
      if status == 404 then
        err = err .. '. The running Go host does not expose /models; restart it so Neovim and the service use the same build.'
      end
      if on_error then
        on_error(err)
      else
        callback(nil, err)
      end
      return
    end
    callback(M.store_model_cache(response and response.models or {}), nil)
  end)
end

function M.prompt_supported_model_selection(unavailable_model, prompt, callback)
  M.fetch_models(function(models, err)
    if err then
      callback(nil, 'failed to list supported models: ' .. err)
      return
    end
    if type(models) ~= 'table' or vim.tbl_isempty(models) then
      callback(nil, 'no supported models returned by service')
      return
    end

    vim.ui.select(models, {
      prompt = prompt,
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        callback(nil, string.format('model "%s" is unavailable and no replacement was selected', unavailable_model))
        return
      end
      callback(choice.id, nil)
    end)
  end)
end

function M.apply_model(model, callback, opts)
  opts = opts or {}
  local selected = vim.trim(model or '')
  local previous_model = state.config.session.model
  if selected == '' then
    if callback then
      callback(nil, 'model is required')
    end
    return
  end

  state.config.session.model = selected
  local known = false
  for _, item in ipairs(state.model_cache) do
    if item.id == selected then
      known = true
      break
    end
  end
  if not known then
    table.insert(state.model_cache, 1, {
      id = selected,
      name = selected,
      label = string.format('%s (%s)', selected, selected),
    })
  end
  if not state.session_id then
    append_entry('system', 'Model for next session: ' .. selected)
    if callback then
      callback(selected, nil)
    end
    return
  end

  local body = { model = selected }
  if opts.reasoning_effort and opts.reasoning_effort ~= '' then
    body.reasoningEffort = opts.reasoning_effort
  end
  request('POST', string.format('/sessions/%s/model', state.session_id), body, function(response, err)
    if err then
      local um = unavailable_model_from_error(err)
      if um and opts.model_selection_attempts ~= false then
        append_entry('system', string.format('Model "%s" is unavailable; choose a supported model.', um))
        M.prompt_supported_model_selection(um, 'Select a supported Copilot model', function(reselected_model, prompt_err)
          if prompt_err then
            state.config.session.model = previous_model
            if callback then
              callback(nil, prompt_err)
            end
            return
          end
          M.apply_model(reselected_model, callback, {
            model_selection_attempts = false,
          })
        end)
        return
      end
      state.config.session.model = previous_model
      if callback then
        callback(nil, err)
      end
      return
    end
    state.config.session.model = response and response.model or selected
    state.current_model = state.config.session.model
    local msg = 'Active model: ' .. state.config.session.model
    if opts.reasoning_effort and opts.reasoning_effort ~= '' then
      state.reasoning_effort = opts.reasoning_effort
      msg = msg .. ' (effort: ' .. opts.reasoning_effort .. ')'
    else
      state.reasoning_effort = nil
    end
    append_entry('system', msg)
    refresh_statuslines()
    if callback then
      callback(state.config.session.model, nil)
    end
  end)
end

--- Interactive model picker with reasoning effort support.
function M.select_model(model)
  if model and model ~= '' then
    M.apply_model(model, function(_, err)
      if err then
        notify('Failed to set model: ' .. err, vim.log.levels.ERROR)
      end
    end)
    return
  end

  M.fetch_models(function(models, err)
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
          M.apply_model(choice.id, function(_, apply_err)
            if apply_err then
              notify('Failed to set model: ' .. apply_err, vim.log.levels.ERROR)
              append_entry('error', 'Failed to set model: ' .. apply_err)
            end
          end, { reasoning_effort = reasoning })
        end)
        return
      end
      M.apply_model(choice.id, function(_, apply_err)
        if apply_err then
          notify('Failed to set model: ' .. apply_err, vim.log.levels.ERROR)
          append_entry('error', 'Failed to set model: ' .. apply_err)
        end
      end)
    end)
  end)
end

--- Tab-completion for model IDs. Fetches models synchronously on first call.
function M.complete_model(arglead)
  if #state.model_cache == 0 then
    local response = select(1, sync_request('GET', '/models', nil))
    if response and type(response.models) == 'table' then
      M.store_model_cache(response.models)
    elseif state.config.service.auto_start and not state.service_starting then
      ensure_service_running(function(err)
        if not err then
          M.fetch_models(function() end)
        end
      end)
    end
  end

  return M.model_completion_items(arglead)
end

return M
