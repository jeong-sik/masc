import { createContext } from 'preact'
import { useContext, useEffect, useState } from 'preact/hooks'
import { html } from 'htm/preact'
import { ApiRequestError, currentStoredTokenRevision } from '../../api/core'
import { storedTokenRevision } from '../../api/token-revision'
import { ADMIN_REQUIRED_MESSAGE, isAdminRequired } from '../../api/admin-required'
import { fetchKeeperToolCall, type ToolCallEntry } from '../../api/dashboard-keeper-tool-calls'
import { recordToolCallOutputs } from '../../tool-call-output-store'
import { useInViewOnce } from '../common/use-in-view'

// Scope comes from the selected Keeper, never its mutable display label.
export const KeeperToolOutputScope = createContext<string | null>(null)
type State = { kind: 'idle' } | { kind: 'loading' }
  | { kind: 'loaded'; entry: ToolCallEntry }
  | { kind: 'missing' } | { kind: 'ambiguous' } | { kind: 'failed' } | { kind: 'admin-required' }

export function useToolOutputLookup(executionId: string | null | undefined, _known: ToolCallEntry | null) {
  const keeper = useContext(KeeperToolOutputScope)
  const authRevision = storedTokenRevision.value
  const [ref, inView] = useInViewOnce<HTMLDivElement>()
  const [attempt, retry] = useState(0)
  const [result, setResult] = useState<{ keeper: string; executionId: string; authRevision: number; state: State } | null>(null)
  const state: State = result?.keeper === keeper && result?.executionId === executionId && result?.authRevision === authRevision
    ? result.state : { kind: 'idle' }
  // A recent-tail cache cannot prove uniqueness across the complete ledger.
  // Only the exact endpoint may supply evidence, including a cached identity.
  const needsFetch = state.kind !== 'loaded'
  useEffect(() => {
    if (!keeper || !executionId || !inView || !needsFetch) return
    const controller = new AbortController()
    const set = (state: State) => {
      if (!controller.signal.aborted && authRevision === currentStoredTokenRevision()) setResult({ keeper, executionId, authRevision, state })
    }
    set({ kind: 'loading' })
    void fetchKeeperToolCall(keeper, executionId, { signal: controller.signal }).then(entry => {
      if (controller.signal.aborted || authRevision !== currentStoredTokenRevision()) return
      set({ kind: 'loaded', entry })
      recordToolCallOutputs([entry])
    }, error => {
      if (controller.signal.aborted || authRevision !== currentStoredTokenRevision()) return
      if (isAdminRequired(error)) set({ kind: 'admin-required' })
      else if (error instanceof ApiRequestError && error.status === 404) set({ kind: 'missing' })
      else if (error instanceof ApiRequestError && error.status === 409) set({ kind: 'ambiguous' })
      else set({ kind: 'failed' })
    })
    return () => controller.abort()
  }, [keeper, executionId, inView, needsFetch, attempt, authRevision])
  return { ref, output: state.kind === 'loaded' ? state.entry : null,
    state,
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
