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
