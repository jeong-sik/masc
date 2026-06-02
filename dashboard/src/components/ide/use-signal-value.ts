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
