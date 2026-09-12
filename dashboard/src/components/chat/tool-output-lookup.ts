import { createContext } from 'preact'
import { useContext, useEffect, useState } from 'preact/hooks'
import { html } from 'htm/preact'
import { ApiRequestError } from '../../api/core'
import { ADMIN_REQUIRED_MESSAGE, isAdminRequired } from '../../api/admin-required'
import { fetchKeeperToolCall, type ToolCallEntry } from '../../api/dashboard-keeper-tool-calls'
import { recordToolCallOutputs } from '../../tool-call-output-store'
import { useInViewOnce } from '../common/use-in-view'

// Scope comes from the selected Keeper, never its mutable display label.
export const KeeperToolOutputScope = createContext<string | null>(null)
type State = { kind: 'idle' } | { kind: 'loading' }
  | { kind: 'loaded'; entry: ToolCallEntry }
  | { kind: 'missing' } | { kind: 'ambiguous' } | { kind: 'failed' } | { kind: 'admin-required' }

export function useToolOutputLookup(executionId: string | null | undefined, known: ToolCallEntry | null) {
  const keeper = useContext(KeeperToolOutputScope)
  const [ref, inView] = useInViewOnce<HTMLDivElement>()
  const [attempt, retry] = useState(0)
  const [result, setResult] = useState<{ keeper: string; executionId: string; state: State } | null>(null)
  const output = known && keeper && known.keeper === keeper && known.execution_id === executionId ? known : null
  const state: State = result?.keeper === keeper && result?.executionId === executionId
    ? result.state : { kind: 'idle' }
  // Peer hydration can replace this execution ID in the shared store. A
  // successfully loaded result for this exact scope still satisfies the lookup.
  const needsFetch = output === null && state.kind !== 'loaded'
  useEffect(() => {
    if (!keeper || !executionId || !inView || !needsFetch) return
    const controller = new AbortController()
    const set = (state: State) => {
      if (!controller.signal.aborted) setResult({ keeper, executionId, state })
    }
    set({ kind: 'loading' })
    void fetchKeeperToolCall(keeper, executionId, { signal: controller.signal }).then(entry => {
      if (controller.signal.aborted) return
      set({ kind: 'loaded', entry })
      recordToolCallOutputs([entry])
    }, error => {
      if (controller.signal.aborted) return
      if (isAdminRequired(error)) set({ kind: 'admin-required' })
      else if (error instanceof ApiRequestError && error.status === 404) set({ kind: 'missing' })
      else if (error instanceof ApiRequestError && error.status === 409) set({ kind: 'ambiguous' })
      else set({ kind: 'failed' })
    })
    return () => controller.abort()
  }, [keeper, executionId, inView, needsFetch, attempt])
  return { ref, output: output ?? (state.kind === 'loaded' ? state.entry : null),
    state: output ? { kind: 'loaded', entry: output } as const : state,
    retry: () => retry(value => value + 1) }
}

export function ToolOutputLookupNotice({ lookup }: { lookup: ReturnType<typeof useToolOutputLookup> }) {
  const { state } = lookup
  if (state.kind === 'idle' || state.kind === 'loaded') return null
  if (state.kind === 'admin-required') return html`<p role="alert" data-access-state="admin-required" class="m-2 text-xs">${ADMIN_REQUIRED_MESSAGE}</p>`
  if (state.kind === 'loading') return html`<p role="status" class="m-2 text-xs">저장된 실행 기록을 불러오고 있습니다.</p>`
  const message = state.kind === 'missing' ? '저장된 실행 기록을 찾지 못했습니다.'
    : state.kind === 'ambiguous' ? '실행 기록이 중복되어 이 도구의 결과를 확정할 수 없습니다.'
    : '저장된 실행 기록을 불러오지 못했습니다.'
  return html`<div class="m-2 text-xs" role="alert">${message}
    <button type="button" class="ml-2 underline" onClick=${lookup.retry}>다시 조회</button>
  </div>`
}
