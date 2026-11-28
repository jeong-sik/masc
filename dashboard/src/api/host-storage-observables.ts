import { asNumber, isRecord } from '../components/common/normalize'

export interface RuntimeObservablesStoreEntry {
  store: string
  bytes: number
  files: number | null
}

function numberOrNull(value: unknown): number | null {
  if (value === null || value === undefined) return null
  return asNumber(value) ?? null
}

function requiredNumber(value: unknown): number | undefined {
  return asNumber(value)
}

function requiredString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function decodeStoreEntry(raw: unknown): RuntimeObservablesStoreEntry | null {
  if (!isRecord(raw)) return null
  const store = requiredString(raw.store)
  const bytes = requiredNumber(raw.bytes)
  if (store === undefined || bytes === undefined) return null
  return { store, bytes, files: numberOrNull(raw.files) }
}

function decodeAll<T>(raw: unknown, decode: (entry: unknown) => T | null): T[] | null {
  if (!Array.isArray(raw)) return null
  const out: T[] = []
  for (const entry of raw) {
    const decoded = decode(entry)
    if (decoded === null) return null
    out.push(decoded)
  }
  return out
}

/** Decode the fields used by the host storage card. */
export function decodeHostStorageObservables(raw: unknown): {
  stores: RuntimeObservablesStoreEntry[]
  age_seconds: number | null
} | null {
  if (!isRecord(raw)) return null
  const stores = decodeAll(raw.stores, decodeStoreEntry)
  return stores === null ? null : { stores, age_seconds: numberOrNull(raw.age_seconds) }
}
