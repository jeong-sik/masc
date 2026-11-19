export const catalog = { providers: [
  { provider: 'openrouter.default', runtime_id: 'openrouter.default', provider_id: 'openrouter', provider_display_name: 'OpenRouter', protocol: 'openai-compatible-http', usage_read_configured: true, models: [] },
  { provider: 'ollama_cloud.default', runtime_id: 'ollama_cloud.default', provider_id: 'ollama_cloud', provider_display_name: 'Ollama Cloud', protocol: 'openai-compatible-http', usage_read_configured: true, models: [] },
  { provider: 'kimi_coding.default', runtime_id: 'kimi_coding.default', provider_id: 'kimi_coding', provider_display_name: 'Kimi Coding', protocol: 'openai-compatible-http', usage_read_configured: true, models: [] },
  { provider: 'codex.finite', runtime_id: 'codex.finite', provider_id: 'codex_finite', provider_display_name: 'Codex (finite)', protocol: 'codex-app-server', models: [] },
  { provider: 'codex.unlimited', runtime_id: 'codex.unlimited', provider_id: 'codex_unlimited', provider_display_name: 'Codex (unlimited)', protocol: 'codex-app-server', models: [] },
] }

export const metrics = {
  window_minutes: 60,
  bucket_minutes: 0,
  cost_ledger_read: { state: 'available', malformed_rows: 0, schema_violation_rows: 0, identity_conflict_rows: 0 },
  models: [{ model_id: 'fixture-model', success_count: 1, error_count: 0,
    total_input_tokens: 100, total_output_tokens: 20, p50_latency_ms: 5, p95_latency_ms: 8,
    usage_sample_count: 1, usage_missing_count: 0, telemetry_sample_count: 1, telemetry_missing_count: 0 }],
}

const creditWindow = ({ label, currency, total, remaining, source, resets_at = null }) => ({
  limit_id: null,
  window: { kind: 'provider_label', label },
  utilization: { unit: 'credit_balance', currency, total, remaining },
  resets_at,
  observed_at: 1_795_000_000,
  source,
  role: 'counts_other_use',
})

export const usage = {
  config_path: null,
  default_route: null,
  default_runtime: null,
  runtimes: [],
  lanes: [],
  assignments: [],
  provider_usage_windows_since: 1_794_999_000,
  provider_usage_windows: [
    { scope: 'account:openrouter', providers: [{ id: 'openrouter', display_name: 'OpenRouter' }], state: 'reported', windows: [
      creditWindow({ label: 'account credit balance', currency: 'USD', total: 100.5, remaining: 74.75, source: 'openrouter.credits' }),
    ] },
    { scope: 'account:ollama', providers: [{ id: 'ollama_cloud', display_name: 'Ollama Cloud' }], state: 'reported', windows: [
      creditWindow({ label: 'included credit period', currency: 'USD', total: 100, remaining: 72.5, source: 'ollama.balance', resets_at: 1_792_056_600 }),
      creditWindow({ label: 'purchased credit balance', currency: 'USD', total: null, remaining: 25, source: 'ollama.balance' }),
    ] },
    { scope: 'account:kimi', providers: [{ id: 'kimi_coding', display_name: 'Kimi Coding' }], state: 'reported', windows: [
      creditWindow({ label: 'booster credit balance', currency: 'CNY', total: 175, remaining: 103.367039, source: 'kimi_coding.usages' }),
    ] },
    { scope: 'account:codex-finite', providers: [{ id: 'codex_finite', display_name: 'Codex (finite)' }], state: 'reported', windows: [
      creditWindow({ label: 'credit balance', currency: 'credits', total: null, remaining: 2500.75, source: 'codex.account_rate_limits_read' }),
    ] },
    { scope: 'account:codex-unlimited', providers: [{ id: 'codex_unlimited', display_name: 'Codex (unlimited)' }], state: 'reported', windows: [{
      limit_id: 'codex', window: { kind: 'provider_label', label: 'credit balance' },
      utilization: { unit: 'credit_unlimited' }, resets_at: null, observed_at: 1_795_000_000,
      source: 'codex.account_rate_limits_read', role: 'counts_other_use',
    }] },
  ],
}
