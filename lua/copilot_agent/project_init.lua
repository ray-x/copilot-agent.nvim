-- Copyright 2026 ray-x. All rights reserved.
-- Use of this source code is governed by an Apache 2.0
-- license that can be found in the LICENSE file.

local uv = vim.uv or vim.loop
local cfg = require('copilot_agent.config')
local render = require('copilot_agent.render')
local service = require('copilot_agent.service')

local notify = cfg.notify
local append_entry = render.append_entry
local working_directory = service.working_directory

local M = {}

local MAX_SCANNED_FILES = 800
local MAX_SUMMARY_ITEMS = 6
local IGNORED_DIRS = {
  ['.git'] = true,
  ['.hg'] = true,
  ['.svn'] = true,
  ['.next'] = true,
  ['.turbo'] = true,
  ['.venv'] = true,
  ['dist'] = true,
  ['build'] = true,
  ['target'] = true,
  ['vendor'] = true,
  ['node_modules'] = true,
}

local LANGUAGE_BY_EXT = {
  lua = 'Lua',
  go = 'Go',
  js = 'JavaScript',
  jsx = 'JavaScript',
  ts = 'TypeScript',
  tsx = 'TypeScript',
  py = 'Python',
  rs = 'Rust',
  rb = 'Ruby',
  java = 'Java',
  c = 'C',
  h = 'C',
  cc = 'C++',
  cpp = 'C++',
  cs = 'C#',
  php = 'PHP',
  swift = 'Swift',
  kt = 'Kotlin',
  zig = 'Zig',
  sh = 'Shell',
  bash = 'Shell',
  zsh = 'Shell',
  fish = 'Shell',
  md = 'Markdown',
  vim = 'Vimscript',
}

local function path_join(...)
  return table.concat({ ... }, '/')
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function is_dir(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == 'directory' or false
end

local function relative_depth(path)
  local _, count = path:gsub('/', '')
  return count
end

local function trim(text)
  return vim.trim(text or '')
end

local function read_file(path, max_bytes)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local data = f:read(max_bytes or '*a')
  f:close()
  return data
end

local function read_lines(path, max_lines)
  local ok, lines = pcall(vim.fn.readfile, path, '', max_lines or -1)
  if ok and type(lines) == 'table' then
    return lines
  end
  return {}
end

local function basename(path)
  return vim.fn.fnamemodify(path, ':t')
end

local function parent_dir(path)
  return vim.fn.fnamemodify(path, ':h')
end

local function top_items(map, limit)
  local items = {}
  for key, value in pairs(map) do
    items[#items + 1] = { key = key, value = value }
  end
  table.sort(items, function(left, right)
    if left.value == right.value then
      return left.key < right.key
    end
    return left.value > right.value
  end)
  local out = {}
  for i = 1, math.min(limit or #items, #items) do
    out[#out + 1] = items[i]
  end
  return out
end

local function scan_entries(dir)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return {}
  end
  local entries = {}
  while true do
    local name, entry_type = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    entries[#entries + 1] = { name = name, entry_type = entry_type }
  end
  table.sort(entries, function(left, right)
    return left.name < right.name
  end)
  return entries
end

local function extension_bucket(rel_path)
  local name = basename(rel_path)
  if name == 'Makefile' then
    return 'make'
  end
  if name == 'Dockerfile' then
    return 'dockerfile'
  end
  local ext = rel_path:match('%.([^.]+)$')
  return ext and ext:lower() or '<none>'
end

local function language_summary(ext_counts)
  local counts = {}
  for ext, count in pairs(ext_counts) do
    local language = LANGUAGE_BY_EXT[ext]
    if language then
      counts[language] = (counts[language] or 0) + count
    end
  end

  local items = top_items(counts, MAX_SUMMARY_ITEMS)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = string.format('%s (%d files)', item.key, item.value)
  end
  return out
end

local function count_instruction_files(root)
  local count = 0
  if exists(path_join(root, '.github', 'copilot-instructions.md')) then
    count = count + 1
  end
  for _, path in ipairs(vim.fn.glob(path_join(root, '.github', 'instructions', '**', '*.instructions.md'), false, true)) do
    if path ~= '' then
      count = count + 1
    end
  end
  return count
end

local function count_agent_files(root)
  local count = 0
  for _, path in ipairs(vim.fn.glob(path_join(root, '.github', 'agents', '**', '*.agent.md'), false, true)) do
    if path ~= '' then
      count = count + 1
    end
  end
  return count
end

local function count_skill_files(root)
  local count = 0
  for _, pattern in ipairs({ 'SKILL.md', 'skill.md' }) do
    for _, path in ipairs(vim.fn.glob(path_join(root, '.github', 'skills', '**', pattern), false, true)) do
      if path ~= '' then
        count = count + 1
      end
    end
  end
  return count
end

local function count_mcp_servers_in_file(path)
  if not exists(path) then
    return 0
  end
  local raw = read_file(path)
  if not raw or raw == '' then
    return 0
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then
    return 0
  end
  local servers = decoded.mcpServers or decoded.servers
  if type(servers) ~= 'table' then
    return 0
  end
  if vim.islist and vim.islist(servers) then
    return #servers
  end
  local count = 0
  for _ in pairs(servers) do
    count = count + 1
  end
  return count
end

local function detect_readme_summary(root, rel_path)
  if not rel_path then
    return nil
  end
  local lines = read_lines(path_join(root, rel_path), 40)
  for _, line in ipairs(lines) do
    local heading = trim(line:match('^#%s+(.+)$'))
    if heading ~= '' then
      return heading
    end
  end
  for _, line in ipairs(lines) do
    local text = trim(line)
    if text ~= '' and not vim.startswith(text, '#') then
      return text
    end
  end
  return nil
end

local function parse_go_mod(path)
  local lines = read_lines(path, 8)
  for _, line in ipairs(lines) do
    local module_name = trim(line:match('^module%s+(.+)$'))
    if module_name ~= '' then
      return 'module `' .. module_name .. '`'
    end
  end
  return nil
end

local function parse_package_json(path)
  local raw = read_file(path)
  if not raw or raw == '' then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then
    return nil
  end

  local parts = {}
  if type(decoded.name) == 'string' and decoded.name ~= '' then
    parts[#parts + 1] = 'package `' .. decoded.name .. '`'
  end
  if type(decoded.scripts) == 'table' then
    local scripts = {}
    for _, name in ipairs({ 'build', 'test', 'lint', 'dev' }) do
      if decoded.scripts[name] then
        scripts[#scripts + 1] = name
      end
    end
    if #scripts > 0 then
      parts[#parts + 1] = 'scripts: ' .. table.concat(scripts, ', ')
    end
  end

  return #parts > 0 and table.concat(parts, '; ') or nil
end

local function parse_toml_name(path)
  local lines = read_lines(path, 60)
  for _, line in ipairs(lines) do
    local name = trim(line:match('^name%s*=%s*["' .. "'" .. '](.-)["' .. "'" .. ']'))
    if name ~= '' then
      return 'project `' .. name .. '`'
    end
  end
  return nil
end

local function parse_makefile(path)
  local lines = read_lines(path, 80)
  local targets = {}
  for _, line in ipairs(lines) do
    local target = line:match('^([A-Za-z0-9_.-]+):')
    if target and target ~= 'PHONY' and not vim.startswith(target, '.') then
      targets[#targets + 1] = target
    end
  end
  if #targets == 0 then
    return nil
  end
  local picked = {}
  for i = 1, math.min(4, #targets) do
    picked[#picked + 1] = targets[i]
  end
  return 'targets: ' .. table.concat(picked, ', ')
end

local function manifest_summary(root, rel_path)
  local full_path = path_join(root, rel_path)
  local name = basename(rel_path)
  if name == 'go.mod' then
    return parse_go_mod(full_path)
  end
  if name == 'package.json' then
    return parse_package_json(full_path)
  end
  if name == 'Cargo.toml' or name == 'pyproject.toml' then
    return parse_toml_name(full_path)
  end
  if name == 'Makefile' then
    return parse_makefile(full_path)
  end
  return nil
end

local function collect_project_snapshot(root)
  local snapshot = {
    root = root,
    root_name = basename(root),
    scanned_files = 0,
    truncated = false,
    ext_counts = {},
    top_level_dirs = {},
    top_level_files = {},
    notable_files = {},
    manifest_paths = {},
    readme_path = nil,
  }

  local function add_notable(rel_path)
    if #snapshot.notable_files >= 10 then
      return
    end
    snapshot.notable_files[#snapshot.notable_files + 1] = rel_path
  end

  local function walk(dir, rel_dir)
    if snapshot.scanned_files >= MAX_SCANNED_FILES then
      snapshot.truncated = true
      return
    end

    for _, entry in ipairs(scan_entries(dir)) do
      local rel_path = rel_dir ~= '' and (rel_dir .. '/' .. entry.name) or entry.name
      local full_path = path_join(dir, entry.name)

      if entry.entry_type == 'directory' then
        if rel_dir == '' then
          snapshot.top_level_dirs[#snapshot.top_level_dirs + 1] = entry.name
        end
        if not IGNORED_DIRS[entry.name] then
          walk(full_path, rel_path)
        end
      elseif entry.entry_type == 'file' then
        snapshot.scanned_files = snapshot.scanned_files + 1
        if rel_dir == '' then
          snapshot.top_level_files[#snapshot.top_level_files + 1] = entry.name
        end

        local ext = extension_bucket(rel_path)
        snapshot.ext_counts[ext] = (snapshot.ext_counts[ext] or 0) + 1

        if not snapshot.readme_path and entry.name:lower():match('^readme') then
          snapshot.readme_path = rel_path
        end

        if entry.name == 'go.mod' or entry.name == 'package.json' or entry.name == 'Cargo.toml' or entry.name == 'pyproject.toml' or entry.name == 'Makefile' then
          snapshot.manifest_paths[#snapshot.manifest_paths + 1] = rel_path
        end

        if rel_dir == '' or relative_depth(rel_path) <= 1 then
          add_notable(rel_path)
        end

        if snapshot.scanned_files >= MAX_SCANNED_FILES then
          snapshot.truncated = true
          return
        end
      end
    end
  end

  walk(root, '')
  table.sort(snapshot.top_level_dirs)
  table.sort(snapshot.top_level_files)
  table.sort(snapshot.notable_files)
  table.sort(snapshot.manifest_paths)
  snapshot.readme_summary = detect_readme_summary(root, snapshot.readme_path)
  snapshot.instruction_count = count_instruction_files(root)
  snapshot.agent_count = count_agent_files(root)
  snapshot.skill_count = count_skill_files(root)
  snapshot.mcp_count = count_mcp_servers_in_file(path_join(root, '.mcp.json')) + count_mcp_servers_in_file(path_join(root, '.vscode', 'mcp.json'))
  return snapshot
end

local function command_lines(snapshot)
  local lines = {}
  local seen = {}

  local function add(dir, command)
    local key = dir .. '\0' .. command
    if seen[key] then
      return
    end
    seen[key] = true
    if dir == '.' or dir == '' then
      lines[#lines + 1] = '- `' .. command .. '`'
    else
      lines[#lines + 1] = '- `cd ' .. dir .. ' && ' .. command .. '`'
    end
  end

  for _, rel_path in ipairs(snapshot.manifest_paths) do
    local dir = parent_dir(rel_path)
    local name = basename(rel_path)
    if name == 'go.mod' then
      add(dir, 'go test ./...')
    elseif name == 'package.json' then
      local full_path = path_join(snapshot.root, rel_path)
      local raw = read_file(full_path)
      if raw and raw ~= '' then
        local ok, decoded = pcall(vim.json.decode, raw)
        if ok and type(decoded) == 'table' and type(decoded.scripts) == 'table' then
          for _, script in ipairs({ 'test', 'build', 'lint' }) do
            if decoded.scripts[script] then
              add(dir, 'npm run ' .. script)
            end
          end
        end
      end
    elseif name == 'Makefile' then
      add(dir, 'make')
    end
  end

  if #lines == 0 then
    lines[1] = '- Add the project-specific build/test commands once they are confirmed.'
  end
  return lines
end

local function section_items(items)
  local out = {}
  for i = 1, math.min(MAX_SUMMARY_ITEMS, #items) do
    out[#out + 1] = '- `' .. items[i] .. '`'
  end
  if #items > MAX_SUMMARY_ITEMS then
    out[#out + 1] = string.format('- plus %d more', #items - MAX_SUMMARY_ITEMS)
  end
  if #out == 0 then
    out[1] = '- None detected'
  end
  return out
end

local function notable_file_lines(snapshot)
  if #snapshot.notable_files == 0 then
    return { '- None detected' }
  end

  local lines = {}
  for i = 1, math.min(MAX_SUMMARY_ITEMS, #snapshot.notable_files) do
    local rel_path = snapshot.notable_files[i]
    local summary = manifest_summary(snapshot.root, rel_path)
    if rel_path == snapshot.readme_path and snapshot.readme_summary then
      summary = snapshot.readme_summary
    end
    if summary and summary ~= '' then
      lines[#lines + 1] = string.format('- `%s` — %s', rel_path, summary)
    else
      lines[#lines + 1] = string.format('- `%s`', rel_path)
    end
  end
  return lines
end

local function generate_document(snapshot)
  local lines = {
    '# Copilot Instructions',
    '',
    '> Generated by `/init`. Review and tailor these notes before relying on them.',
    '',
    '## Project overview',
    string.format('- Repository root: `%s`', snapshot.root_name),
    string.format('- Files scanned: %d%s', snapshot.scanned_files, snapshot.truncated and '+' or ''),
  }

  if snapshot.readme_summary and snapshot.readme_summary ~= '' then
    lines[#lines + 1] = '- README summary: ' .. snapshot.readme_summary
  end

  local languages = language_summary(snapshot.ext_counts)
  if #languages > 0 then
    lines[#lines + 1] = '- Primary languages: ' .. table.concat(languages, ', ')
  end

  lines[#lines + 1] = string.format(
    '- Existing Copilot config: %d instruction file(s), %d agent file(s), %d skill file(s), %d MCP server definition(s)',
    snapshot.instruction_count,
    snapshot.agent_count,
    snapshot.skill_count,
    snapshot.mcp_count
  )
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Repository layout'
  vim.list_extend(lines, section_items(snapshot.top_level_dirs))
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Notable files'
  vim.list_extend(lines, notable_file_lines(snapshot))
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Build and validation'
  vim.list_extend(lines, command_lines(snapshot))
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Guidance for Copilot'
  lines[#lines + 1] = '- Read the repo README and the notable files above before making cross-cutting changes.'
  lines[#lines + 1] = '- Keep changes surgical and update related docs when behavior changes.'
  lines[#lines + 1] = '- Reuse existing helpers and request wrappers before adding new abstractions.'
  lines[#lines + 1] = '- Prefer repository-local instructions, agents, skills, and MCP config when they already exist.'
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Maintenance'
  lines[#lines + 1] = '- Update this file when the repo layout, build commands, or project conventions change.'
  lines[#lines + 1] = '- Add concrete coding conventions here as they become stable.'
  lines[#lines + 1] = ''
  return lines
end

local function write_instructions(path, lines, scanned_files)
  local parent = parent_dir(path)
  if parent ~= '' and not is_dir(parent) then
    vim.fn.mkdir(parent, 'p')
  end
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    append_entry('error', 'Failed to write instructions: ' .. tostring(err))
    return
  end
  local rel_path = vim.fn.fnamemodify(path, ':~:.')
  append_entry('system', string.format('Generated starter Copilot instructions at %s (scanned %d files)', rel_path, scanned_files))
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

function M.run(args)
  args = trim(args)
  local root = working_directory()
  local snapshot = collect_project_snapshot(root)
  local lines = generate_document(snapshot)
  local canonical_path = path_join(root, '.github', 'copilot-instructions.md')
  local draft_path = path_join(root, '.github', 'copilot-instructions.generated.md')

  local function write_target(path)
    write_instructions(path, lines, snapshot.scanned_files)
  end

  if args == 'open' and exists(canonical_path) then
    vim.cmd('edit ' .. vim.fn.fnameescape(canonical_path))
    return true
  end

  if args == 'draft' then
    write_target(draft_path)
    return true
  end

  if args == 'force' then
    write_target(canonical_path)
    return true
  end

  if exists(canonical_path) then
    vim.ui.select({
      { id = 'replace', label = 'Replace .github/copilot-instructions.md' },
      { id = 'draft', label = 'Write draft to .github/copilot-instructions.generated.md' },
      { id = 'open', label = 'Open existing instructions' },
    }, {
      prompt = 'Project instructions already exist',
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.id == 'open' then
        vim.cmd('edit ' .. vim.fn.fnameescape(canonical_path))
      elseif choice.id == 'draft' then
        write_target(draft_path)
      else
        write_target(canonical_path)
      end
    end)
    return true
  end

  write_target(canonical_path)
  return true
end

return M
