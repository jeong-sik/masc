// use-controllable-state.ts — controlled/uncontrolled state bridge
//
// Kimi design system sec01 1.2: Headless primitives must support
// both controlled (props-driven) and uncontrolled (internal state)
// modes. This hook is the standard bridge.

import { useState, useCallback } from 'preact/hooks'

export interface ControllableStateOptions<T> {
  prop?: T
  defaultProp?: T
  onChange?: (value: T) => void
}

export function useControllableState<T>({
  prop,
  defaultProp,
  onChange,
}: ControllableStateOptions<T>): [T | undefined, (value: T | ((prev: T | undefined) => T)) => void] {
  const isControlled = prop !== undefined
  const [internalState, setInternalState] = useState<T | undefined>(defaultProp)

  const value = isControlled ? prop : internalState

  const setValue = useCallback(
    (next: T | ((prev: T | undefined) => T)) => {
      const resolved = typeof next === 'function' ? (next as (prev: T | undefined) => T)(value) : next
      if (!isControlled) {
        setInternalState(resolved)
      }
      onChange?.(resolved)
    },
    [isControlled, value, onChange]
  )

  return [value, setValue]
}
