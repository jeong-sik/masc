// Pure helpers for reading Vite build-time environment overrides.
//
// Kept separate from constants.ts so the parsing logic can be unit-tested
// without faking import.meta.env.

export function parseEnvInt(raw: string | undefined | null, fallback: number): number {
  if (raw == null || raw === '') return fallback
  const n = Number.parseInt(String(raw), 10)
  return Number.isFinite(n) && n > 0 ? n : fallback
}

export function envInt(key: string, fallback: number): number {
  const raw = (import.meta.env as Record<string, unknown>)[key]
  return parseEnvInt(typeof raw === 'string' ? raw : raw == null ? undefined : String(raw), fallback)
}

export function parseEnvBool(raw: string | undefined | null, fallback: boolean): boolean {
  if (raw == null || raw === '') return fallback
  const normalized = String(raw).trim().toLowerCase()
  if (normalized === 'true' || normalized === '1' || normalized === 'yes') return true
  if (normalized === 'false' || normalized === '0' || normalized === 'no') return false
  return fallback
}

export function envBool(key: string, fallback: boolean): boolean {
  const raw = (import.meta.env as Record<string, unknown>)[key]
  return parseEnvBool(typeof raw === 'string' ? raw : raw == null ? undefined : String(raw), fallback)
}
