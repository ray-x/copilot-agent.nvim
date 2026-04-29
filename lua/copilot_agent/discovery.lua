-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local http = require('copilot_agent.http')
local service = require('copilot_agent.service')

local M = {}

local function working_directory()
  return service.working_directory()
end

local function frontmatter_name(path)
  local ok, lines = pcall(vim.fn.readfile, path, '', 32)
  if not ok or type(lines) ~= 'table' or lines[1] ~= '---' then
    return nil
  end

  for i = 2, #lines do
    local line = lines[i]
    if line == '---' then
      break
    end
    local raw = line:match('^name:%s*(.+)%s*$')
    if raw then
      raw = vim.trim(raw)
      local quoted = raw:match('^"(.*)"$') or raw:match("^'(.*)'$")
      return quoted or raw
    end
  end

  return nil
end

local function read_json_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return http.decode_json(table.concat(vim.fn.readfile(path), '\n'))
end

function M.agent_items()
  local wd = working_directory()
  local files = {}
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/agents/*.agent.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/agents/**/*.agent.md', false, true))

  local items = {}
  local seen = {}
  for _, path in ipairs(files or {}) do
    local name = frontmatter_name(path) or vim.fn.fnamemodify(path, ':t:r:r')
    if type(name) == 'string' and name ~= '' and not seen[name] then
      seen[name] = true
      items[#items + 1] = { name = name, path = path }
    end
  end
  table.sort(items, function(left, right)
    return left.name < right.name
  end)
  return items
end

function M.skill_items()
  local wd = working_directory()
  local files = {}
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/*/SKILL.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/*/skill.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/**/SKILL.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/skills/**/skill.md', false, true))

  local items = {}
  local seen = {}
  for _, path in ipairs(files) do
    local name = frontmatter_name(path) or vim.fn.fnamemodify(vim.fn.fnamemodify(path, ':h'), ':t')
    if type(name) == 'string' and name ~= '' and not seen[name] then
      seen[name] = true
      items[#items + 1] = { name = name, path = path }
    end
  end
  table.sort(items, function(left, right)
    return left.name < right.name
  end)
  return items
end

function M.instruction_items()
  local wd = working_directory()
  local files = {}
  local root_file = wd .. '/.github/copilot-instructions.md'
  if vim.fn.filereadable(root_file) == 1 then
    table.insert(files, root_file)
  end
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/instructions/*.instructions.md', false, true))
  vim.list_extend(files, vim.fn.glob(wd .. '/.github/instructions/**/*.instructions.md', false, true))

  local items = {}
  local seen = {}
  for _, path in ipairs(files) do
    local rel = path:sub(#wd + 2)
    if rel ~= '' and not seen[rel] then
      seen[rel] = true
      items[#items + 1] = { name = rel, path = path }
    end
  end
  table.sort(items, function(left, right)
    return left.name < right.name
  end)
  return items
end

function M.mcp_items()
  local wd = working_directory()
  local items = {}
  local seen = {}

  local function add_item(name, path)
    if type(name) ~= 'string' or name == '' or seen[name .. '\0' .. path] then
      return
    end
    seen[name .. '\0' .. path] = true
    items[#items + 1] = { name = name, path = path }
  end

  local function read_config(path)
    local decoded = read_json_file(path)
    if type(decoded) ~= 'table' then
      return
    end
    local servers = decoded.mcpServers or decoded.servers
    if type(servers) ~= 'table' then
      return
    end
    if vim.islist and vim.islist(servers) then
      for _, entry in ipairs(servers) do
        if type(entry) == 'string' then
          add_item(entry, path)
        elseif type(entry) == 'table' then
          add_item(entry.name or entry.id, path)
        end
      end
      return
    end
    for name in pairs(servers) do
      add_item(name, path)
    end
  end

  read_config(wd .. '/.mcp.json')
  read_config(wd .. '/.vscode/mcp.json')
  table.sort(items, function(left, right)
    if left.name == right.name then
      return left.path < right.path
    end
    return left.name < right.name
  end)
  return items
end

return M
