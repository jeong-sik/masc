/**
 * useInlineSuggestion — Preact adapter over headless-core/InlineSuggestion
 * (RFC 0011 §3.4).
 *
 * Hooks for file-scoped suggestion lists and per-suggestion
 * controller props. Manager is provided externally so editor and
 * preview surfaces share the same state.
 */

import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  createSuggestionController,
  type InlineSuggestion,
  type InlineSuggestionManager,
  type SuggestionController,
} from '../headless-core/inline-suggestion'

function sameSuggestions(
  a: ReadonlyArray<InlineSuggestion>,
  b: ReadonlyArray<InlineSuggestion>,
): boolean {
  if (a.length !== b.length) return false
  return a.every((suggestion, index) => suggestion.id === b[index]?.id)
}

export function useFileSuggestions(
  manager: InlineSuggestionManager,
  file: string,
): ReadonlyArray<InlineSuggestion> {
  const [list, setList] = useState<ReadonlyArray<InlineSuggestion>>(() =>
    manager.inFile(file),
  )
  useEffect(() => {
    const updateList = (next: ReadonlyArray<InlineSuggestion>): void => {
      setList((prev) => sameSuggestions(prev, next) ? prev : next)
    }
    updateList(manager.inFile(file))
    const dispose = manager.subscribeFile(file, updateList)
    return dispose
  }, [manager, file])
  return list
}

export function useTopSuggestion(
  manager: InlineSuggestionManager,
  file: string,
  line: number,
): InlineSuggestion | undefined {
  const list = useFileSuggestions(manager, file)
  return useMemo(() => {
    void list
    return manager.topAtLine(file, line)
  }, [manager, file, line, list])
}

export function useSuggestionController(
  manager: InlineSuggestionManager,
  suggestionId: string,
): SuggestionController | undefined {
  return useMemo(() => {
    try {
      return createSuggestionController(manager, suggestionId)
    } catch {
      return undefined
    }
  }, [manager, suggestionId])
}
