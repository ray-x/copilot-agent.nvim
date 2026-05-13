-- Assistant usage helpers extracted from events.lua
-- Module factory: returns a table of helper functions when passed dependency table.
local function factory(deps)
  local sanitize_permission_text = deps.sanitize_permission_text
  local remember_recent_activity_line = deps.remember_recent_activity_line
  local remember_recent_activity_item = deps.remember_recent_activity_item
  local append_entry = deps.append_entry
  local schedule_render = deps.schedule_render
  local state = deps.state
  local normalize_activity_output_text = deps.normalize_activity_output_text

  local M = {
    quota_priority = {
      premium_interactions = 1,
      chat = 2,
      completions = 3,
    },
  }

  function M.number(value)
    if type(value) == 'number' then
      return value
    end
    if type(value) == 'string' then
      return tonumber(value)
    end
    return nil
  end

  function M.normalize_percentage(value)
    local n = M.number(value)
    if not n then
      return nil
    end
    if n >= 0 and n <= 1 then
      n = n * 100
    end
    return math.max(0, n)
  end

  function M.format_decimal(value, decimals)
    local n = M.number(value)
    if not n then
      return nil
    end
    decimals = math.max(0, math.floor(tonumber(decimals) or 0))
    if decimals <= 0 then
      return tostring(math.floor(n + 0.5))
    end
    local rendered = string.format('%.' .. tostring(decimals) .. 'f', n)
    rendered = rendered:gsub('(%..-)0+$', '%1'):gsub('%.$', '')
    return rendered
  end

  function M.format_summary_tokens(value)
    local n = M.number(value)
    if not n then
      return nil
    end
    if n < 1000 then
      return tostring(math.floor(n + 0.5))
    end
    return string.format('%.0fk', n / 1000)
  end

  function M.format_summary_duration(duration_ms)
    local n = M.number(duration_ms)
    if not n then
      return nil
    end
    if n >= 1000 then
      return M.format_decimal(n / 1000, 1) .. 's'
    end
    return M.format_decimal(n, 0) .. 'ms'
  end

  function M.format_percentage(value)
    local n = M.normalize_percentage(value)
    if not n then
      return nil
    end
    local rounded = math.floor(n + 0.5)
    if math.abs(n - rounded) < 0.05 then
      return tostring(rounded) .. '%'
    end
    return string.format('%.1f%%', n)
  end

  function M.quota_display_name(quota_id)
    quota_id = sanitize_permission_text(quota_id)
    if not quota_id then
      return nil
    end
    if quota_id == 'premium_interactions' then
      return 'premium'
    end
    return quota_id:gsub('_', ' ')
  end

  function M.normalize_quotas(quota_snapshots)
    local quotas = {}
    if type(quota_snapshots) ~= 'table' then
      return quotas, nil
    end
    for quota_id, snapshot in pairs(quota_snapshots) do
      if type(snapshot) == 'table' then
        quotas[#quotas + 1] = {
          id = sanitize_permission_text(quota_id) or tostring(quota_id),
          display_name = M.quota_display_name(quota_id),
          entitlement_requests = M.number(snapshot.entitlementRequests),
          is_unlimited = snapshot.isUnlimitedEntitlement == true,
          overage = M.number(snapshot.overage),
          overage_allowed = snapshot.overageAllowedWithExhaustedQuota == true,
          remaining_percentage = M.normalize_percentage(snapshot.remainingPercentage),
          reset_date = sanitize_permission_text(snapshot.resetDate),
          usage_allowed = snapshot.usageAllowedWithExhaustedQuota == true,
          used_requests = M.number(snapshot.usedRequests),
        }
      end
    end

    table.sort(quotas, function(a, b)
      local a_overage = (tonumber(a.overage) or 0) > 0
      local b_overage = (tonumber(b.overage) or 0) > 0
      if a_overage ~= b_overage then
        return a_overage
      end
      if a.is_unlimited ~= b.is_unlimited then
        return not a.is_unlimited
      end
      local a_priority = M.quota_priority[a.id] or math.huge
      local b_priority = M.quota_priority[b.id] or math.huge
      if a_priority ~= b_priority then
        return a_priority < b_priority
      end
      local a_remaining = a.remaining_percentage ~= nil and a.remaining_percentage or math.huge
      local b_remaining = b.remaining_percentage ~= nil and b.remaining_percentage or math.huge
      if a_remaining ~= b_remaining then
        return a_remaining < b_remaining
      end
      return tostring(a.id or '') < tostring(b.id or '')
    end)

    return quotas, quotas[1]
  end

  function M.normalize(data)
    data = type(data) == 'table' and data or {}
    local model = sanitize_permission_text(data.model)
    if not model then
      return nil
    end
    local quotas, primary_quota = M.normalize_quotas(data.quotaSnapshots)
    local remaining_percentage = primary_quota and primary_quota.remaining_percentage or nil
    local overage = primary_quota and primary_quota.overage or nil
    return {
      model = model,
      initiator = sanitize_permission_text(data.initiator),
      reasoning_effort = sanitize_permission_text(data.reasoningEffort),
      cost = M.number(data.cost),
      input_tokens = M.number(data.inputTokens),
      output_tokens = M.number(data.outputTokens),
      reasoning_tokens = M.number(data.reasoningTokens),
      cache_read_tokens = M.number(data.cacheReadTokens),
      cache_write_tokens = M.number(data.cacheWriteTokens),
      duration_ms = M.number(data.duration),
      ttft_ms = M.number(data.ttftMs),
      inter_token_latency_ms = M.number(data.interTokenLatencyMs),
      api_call_id = sanitize_permission_text(data.apiCallId),
      provider_call_id = sanitize_permission_text(data.providerCallId),
      remaining_percentage = remaining_percentage,
      overage = overage,
      quotas = quotas,
      primary_quota = primary_quota and vim.deepcopy(primary_quota) or nil,
    }
  end

  function M.summarize(usage)
    if type(usage) ~= 'table' or type(usage.model) ~= 'string' or usage.model == '' then
      return nil
    end
    local parts = { usage.model }
    local cost = M.format_decimal(usage.cost, 2)
    if cost then
      parts[#parts + 1] = 'cost ' .. cost
    end
    local input_tokens = M.format_summary_tokens(usage.input_tokens)
    if input_tokens then
      parts[#parts + 1] = input_tokens .. ' in'
    end
    local output_tokens = M.format_summary_tokens(usage.output_tokens)
    if output_tokens then
      parts[#parts + 1] = output_tokens .. ' out'
    end
    local duration = M.format_summary_duration(usage.duration_ms)
    if duration then
      parts[#parts + 1] = duration
    end
    local primary_quota = type(usage.primary_quota) == 'table' and usage.primary_quota or nil
    if primary_quota and primary_quota.remaining_percentage ~= nil then
      parts[#parts + 1] = string.format('%s %s', primary_quota.display_name or primary_quota.id or 'quota', M.format_percentage(primary_quota.remaining_percentage) or '?')
    end
    return 'Usage: ' .. table.concat(parts, ' · ')
  end

  function M.current_turn_accepts()
    return state.chat_busy == true
      or state.pending_checkpoint_turn ~= nil
      or type(state.active_turn_assistant_index) == 'number'
      or type(state.live_assistant_entry_index) == 'number'
      or (type(state.active_turn_assistant_message_id) == 'string' and state.active_turn_assistant_message_id ~= '')
      or #(state.recent_activity_lines or {}) > 0
      or #(state.recent_activity_items or {}) > 0
  end

  function M.append_to_last_activity_entry(summary, item)
    if type(state.entries) ~= 'table' then
      return false
    end
    local entry = nil
    for idx = #state.entries, 1, -1 do
      local candidate = state.entries[idx]
      if type(candidate) == 'table' and candidate.kind == 'activity' then
        entry = candidate
        break
      end
    end
    if type(entry) ~= 'table' then
      return false
    end
    if type(entry.code_change) == 'table' and type(item) == 'table' and item.kind ~= 'code_change' then
      return false
    end
    local content = normalize_activity_output_text(entry.content or '')
    entry.content = content and (content .. '\n' .. summary) or summary
    if type(entry.activity_items) ~= 'table' then
      entry.activity_items = {}
    end
    entry.activity_items[#entry.activity_items + 1] = vim.deepcopy(item)
    schedule_render()
    return true
  end

  function M.capture(data, opts)
    opts = type(opts) == 'table' and opts or {}
    local record_activity = opts.record_activity ~= false
    local usage = M.normalize(data)
    if not usage then
      return nil
    end
    state.last_assistant_usage = vim.deepcopy(usage)
    state.last_assistant_usage_snapshot = vim.deepcopy(usage)
    local summary = M.summarize(usage)
    if not summary or not record_activity then
      return usage
    end
    local item = {
      kind = 'usage',
      summary = summary,
      usage = vim.deepcopy(usage),
    }
    if M.current_turn_accepts() then
      remember_recent_activity_line(summary)
      remember_recent_activity_item(item)
      return usage
    end
    if M.append_to_last_activity_entry(summary, item) then
      return usage
    end
    append_entry('activity', summary, nil, {
      activity_items = { item },
    })
    return usage
  end

  return M
end

return factory
