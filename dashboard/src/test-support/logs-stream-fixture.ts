export function logStreamWire(seqs: readonly number[], reset = true, message = 'entry') {
  const entries = seqs.map(seq => ({
    seq, ts: '2026-11-10T00:00:00Z', level: 'INFO', source: 'structured', module: 'Keeper',
    keeper_name: 'alpha', turn_id: null, message: `${message}-${seq}`, details: null, category: null,
  }))
  return {
    reset, generated_at_iso: '2026-11-10T00:00:00Z', dashboard_surface: '/api/v1/dashboard/logs',
    source: 'masc_log_ring', retention: {
      scope: 'dashboard_logs', workspace_root: '/workspace/.masc', buffer: 'Log.Ring', capacity: 50000,
      durable_store: '/workspace/.masc/logs/system_log_2026-11-10.jsonl',
      file_pattern: 'system_log_YYYY-MM-DD.jsonl', keep_days: 7, cache_policy: 'uncached',
    },
    query: { limit: 200, level: 'INFO', applied_level: 'INFO', min_level: 1, module: '',
      since_seq: null, before_seq: null, category: null, exclude_category: null },
    returned: entries.length, total: entries.length,
    latest_seq: seqs[0] ?? null, oldest_seq: seqs[seqs.length - 1] ?? null,
    latest_ts_iso: entries[0]?.ts ?? null,
    ring: { start_seq: 0, total: (seqs[0] ?? -1) + 1, dropped_before: false }, entries,
  }
}
