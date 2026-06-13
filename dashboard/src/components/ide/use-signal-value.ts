import { useEffect, useState } from 'preact/hooks'

export function useSignalValue<T>(
  signal: { value: T; subscribe: (fn: (value: T) => void) => () => void },
): T {
  const [value, setValue] = useState(signal.value)
  useEffect(() => {
    const unsub = signal.subscribe(next => setValue(next))
    return () => unsub()
  }, [signal])
  return value
}

export function useSubscribedValue<T>(
  read: () => T,
  subscribe: (listener: () => void) => () => void,
): T {
  const [value, setValue] = useState<T>(() => read())

  useEffect(() => {
    setValue(read())
    return subscribe(() => {
      setValue(read())
    })
  }, [read, subscribe])

  return value
}

export function useSubscribedSnapshot<T>(
  read: () => T,
  subscribe: (listener: () => void) => () => void,
): T {
  const [value, setValue] = useState<T>(() => read())

  useEffect(() => {
    let current = read()
    let sawInitialSnapshot = false
    return subscribe(() => {
      const next = read()
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        if (next === current) return
      }
      current = next
      setValue(previous => previous === next ? previous : next)
    })
  }, [read, subscribe])

  return value
}

// Subscribe to an external store for re-render side effects only. Use this when
// the component reads store state through accessor methods (in render, effects,
// or callbacks) rather than a single reactive value. useSignalValue and
// useSubscribedValue/useSubscribedSnapshot return a value; this returns nothing
// because the caller already reads via the store's own accessors. The store's
// listener is called with no argument, so a value-returning hook does not fit.
export function useStoreSubscription(
  subscribe: (listener: () => void) => () => void,
): void {
  const [, forceRender] = useState(0)
  useEffect(() => subscribe(() => forceRender(tick => tick + 1)), [subscribe])
}
