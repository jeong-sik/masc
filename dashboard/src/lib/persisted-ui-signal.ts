import { signal, effect, type Signal } from '@preact/signals'

interface PersistentSignalOptions<T> {
  /** localStorage key. Choose something namespaced like \"dashboard:sidebar-collapsed\". */
  key: string
  /** Value to use when the key is absent / unparseable / storage
      unavailable. Must be serializable; the default is written back
      only on first change, not on load. */
  defaultValue: T
  /** Optional custom serializer — default is JSON.stringify. */
  serialize?: (v: T) => string
  /** Optional custom deserializer — default is JSON.parse. */
  deserialize?: (raw: string) => T
}

/** Pure: parse a raw localStorage string into the expected type.
    Exposed for tests so we can pin the error-path behaviour without
    mounting a real localStorage. */
export function readPersistedValue<T>(
  raw: string | null,
  defaultValue: T,
  deserialize: (raw: string) => T = JSON.parse,
): T {
  if (raw === null) return defaultValue
  try {
    return deserialize(raw)
  } catch {
    // Corrupt / legacy string — fall back silently so a bad entry
    // doesn't brick the UI. The next write will overwrite it.
    return defaultValue
  }
}

/** Produce a Signal<T> whose reads/writes are mirrored to
    localStorage. Signal interface is unchanged — existing consumers
    keep using `.value`, this just adds persistence. */
export function persistentSignal<T>(options: PersistentSignalOptions<T>): Signal<T> {
  const {
    key,
    defaultValue,
    serialize = JSON.stringify,
    deserialize = JSON.parse,
  } = options

  const initial = (() => {
    try {
      if (typeof window === 'undefined') return defaultValue
      return readPersistedValue(window.localStorage.getItem(key), defaultValue, deserialize)
    } catch {
      // Reading localStorage can throw in privacy-locked browsers.
      return defaultValue
    }
  })()

  const sig = signal<T>(initial)

  if (typeof window !== 'undefined') {
    // Skip the first effect tick — that would write the initial value
    // unnecessarily. Tracking with a boolean is cheaper than reading
    // the previous stored value each time.
    let primed = false
    effect(() => {
      const next = sig.value
      if (!primed) { primed = true; return }
      try {
        window.localStorage.setItem(key, serialize(next))
      } catch {
        // Quota exceeded / private mode — swallow. Reads still work.
      }
    })
  }

  return sig
}
