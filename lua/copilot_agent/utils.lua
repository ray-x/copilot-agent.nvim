-- Pure utility functions with no Neovim API dependencies.
-- Kept in a separate module so they can be unit-tested with plain Lua / busted.
local M = {}

-- Returns true when content is empty, whitespace, or dots-only (model "thinking").
function M.is_thinking_content(s)
    return s == nil or s == '' or s:match('^[%.%s]*$') ~= nil
end

-- Split text on newlines. Returns { '' } for nil/empty input.
-- Uses vim.split when available (Neovim runtime), falls back to pure Lua.
function M.split_lines(text)
    if text == nil or text == '' then
        return { '' }
    end
    if vim and vim.split then
        return vim.split(text, '\n', { plain = true })
    end
    local lines = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(lines, line)
    end
    return lines
end

-- Strip trailing slashes from a base URL.
function M.normalize_base_url(url, default_url)
    return (url or default_url or ''):gsub('/+$', '')
end

-- Normalise a model entry from the API (handles both camelCase and PascalCase keys).
-- Returns { id, name, label } or nil when the entry is invalid.
function M.normalize_model_entry(entry)
    if type(entry) ~= 'table' then
        return nil
    end

    local id = entry.id or entry.ID
    if type(id) ~= 'string' or id == '' then
        return nil
    end

    local name = entry.name or entry.Name or id
    return {
        id = id,
        name = name,
        label = string.format('%s (%s)', name, id),
    }
end

-- Extract the model name from an "unavailable model" error string.
-- Returns the model string or nil if the error doesn't match.
function M.unavailable_model_from_error(err)
    if type(err) ~= 'string' then
        return nil
    end
    return err:match('Model "([^"]+)" is not available')
end

-- Returns true when the curl error string looks like a connection failure.
function M.is_connection_error(err)
    if type(err) ~= 'string' then
        return false
    end
    for _, pattern in ipairs({
        'Failed to connect',
        "Couldn't connect to server",
        'Connection refused',
        'Empty reply from server',
    }) do
        if err:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

return M
