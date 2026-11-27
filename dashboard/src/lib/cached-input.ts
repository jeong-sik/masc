export interface CachedInputMetric {
  readonly input_tokens: number
  readonly cache_read_tokens: number
  readonly sample_count: number
}

export function decodeCachedInput(raw: unknown): CachedInputMetric | null {
  if (raw == null || typeof raw !== 'object' || Array.isArray(raw)) return null
  const value = raw as Record<string, unknown>
  const input = value.input_tokens
  const cached = value.cache_read_tokens
  const count = value.sample_count
  if (typeof input !== 'number' || !Number.isSafeInteger(input)
    || typeof cached !== 'number' || !Number.isSafeInteger(cached)
    || typeof count !== 'number' || !Number.isSafeInteger(count)
    || input <= 0 || cached < 0 || cached > input || count <= 0) return null
  return { input_tokens: input, cache_read_tokens: cached, sample_count: count }
}
