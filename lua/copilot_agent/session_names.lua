-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local M = {}

local names_cache

local function state_file()
  return vim.fn.stdpath('state') .. '/copilot-agent-session-names.json'
end

local function load_names()
  if names_cache then
    return names_cache
  end

  names_cache = {}
  local ok, raw = pcall(function()
    local f = io.open(state_file(), 'r')
    if not f then
      return nil
    end
    local data = f:read('*a')
    f:close()
    return data
  end)
  if not ok or type(raw) ~= 'string' or raw == '' then
    return names_cache
  end

  local ok_decode, decoded = pcall(vim.json.decode, raw)
  if ok_decode and type(decoded) == 'table' then
    names_cache = decoded
  end
  return names_cache
end

local function save_names()
  local path = state_file()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f, err = io.open(path, 'w')
  if not f then
    return nil, err
  end
  f:write(vim.json.encode(load_names()))
  f:close()
  return true
end

function M.get(session_id)
  if type(session_id) ~= 'string' or session_id == '' then
    return nil
  end
  local value = load_names()[session_id]
  if type(value) == 'string' and value ~= '' then
    return value
  end
  return nil
end

function M.set(session_id, name)
  if type(session_id) ~= 'string' or session_id == '' then
    return nil, 'session_id is required'
  end

  name = vim.trim(name or '')
  if name == '' then
    load_names()[session_id] = nil
  else
    load_names()[session_id] = name
  end
  return save_names()
end

function M.resolve(summary, session_id)
  return M.get(session_id) or summary
end

return M
