// Generic unknown → typed coercion helpers.
//
// These were originally part of `components/common/normalize.ts`, but they have
// no component-layer dependency. Moving them to `lib/` lets other `lib/`
// modules (e.g. `fusion-meta.ts`) share a single SSOT without importing upward
// into `components/`, which would create a layer cycle.

import { isRecord } from './type-guards'

export function asString(value: unknown): string | undefined
export function asString(value: unknown, fallback: string): string
export function asString(value: unknown, fallback?: string): string | undefined {
  if (typeof value === 'string') {
    if (fallback === undefined) {
      const trimmed = value.trim()
      return trimmed !== '' ? trimmed : undefined
    }
    return value
  }
  return fallback ?? undefined
}

export function asNumber(value: unknown): number | undefined
export function asNumber(value: unknown, fallback: number): number
export function asNumber(value: unknown, fallback?: number): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : (fallback ?? undefined)
}

export function asBoolean(value: unknown): boolean | undefined
export function asBoolean(value: unknown, fallback: boolean): boolean
export function asBoolean(value: unknown, fallback?: boolean): boolean | undefined {
  return typeof value === 'boolean' ? value : (fallback ?? undefined)
}

export function asInt(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
  if (typeof value !== 'string') return undefined
  const parsed = Number.parseInt(value.trim(), 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

export function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => (typeof item === 'string' ? item.trim() : ''))
    .filter(Boolean)
}

export function asRecordArray(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) return []
  return value.filter(isRecord)
}

export function asNullableString(value: unknown): string | null {
  return asString(value) ?? null
}

export function asRecord(value: unknown): Record<string, unknown> | null {
  return isRecord(value) ? value : null
}

export function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => {
      if (typeof item === 'string') return item.trim()
      if (isRecord(item)) {
        return asString(item.name, '').trim()
          || asString(item.id, '').trim()
          || asString(item.skill, '').trim()
      }
      return ''
    })
    .filter((item): item is string => item.length > 0)
}

export function extractArray(value: unknown, keys: string[] = []): unknown[] {
  if (Array.isArray(value)) return value
  if (!isRecord(value)) return []
  for (const key of keys) {
    const candidate = value[key]
    if (Array.isArray(candidate)) return candidate
  }
  return []
}
